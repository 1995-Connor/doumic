import AVFoundation
import CoreAudio
import FlutterMacOS
import Foundation

/// Routes D3200 PCM16@16kHz into a macOS virtual audio device (BlackHole).
///
/// Pattern: App plays into BlackHole's **output** side → other apps (Typeless,
/// Zoom, …) select BlackHole as **input** microphone. This is the supported
/// macOS approach (same idea as SayAll → MiRemoteV).
final class MacMicBridge: NSObject {
  static let shared = MacMicBridge()

  private let methodChannelName = "com.doumic.app/mic_bridge"
  private let eventChannelName = "com.doumic.app/mic_bridge_events"

  private var methodChannel: FlutterMethodChannel?
  private var eventSink: FlutterEventSink?

  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var running = false
  private var enabled = false
  private var statusMessage = "未启用"
  private var outputDeviceName = ""
  private var bytesForwarded: Int64 = 0

  private let pcmQueue = DispatchQueue(label: "com.doumic.macmic.pcm")
  private var sourceFormat: AVAudioFormat?
  private var playerFormat: AVAudioFormat?

  func register(with controller: FlutterViewController) {
    let messenger = controller.engine.binaryMessenger
    let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    methodChannel = methods
    methods.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
    events.setStreamHandler(self)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isReady":
      result(true)
    case "setEnabled":
      let args = call.arguments as? [String: Any]
      let on = args?["enabled"] as? Bool ?? false
      do {
        if on {
          try start()
          enabled = true
        } else {
          stop()
          enabled = false
        }
        result(
          [
            "virtualMic": statusMessage,
            "running": running,
            "shizuku": privilegeLabel(),
          ] as [String: Any]
        )
      } catch {
        statusMessage = "启动失败: \(error.localizedDescription)"
        result(
          FlutterError(
            code: "mac_mic",
            message: statusMessage,
            details: nil
          )
        )
      }
    case "getVirtualMicStatus":
      result(
        [
          "message": statusMessage,
          "running": running,
          "shizuku": privilegeLabel(),
          "enabled": enabled,
          "debug": debugLine(),
        ] as [String: Any]
      )
    case "requestShizukuPermission", "openShizukuApp":
      // macOS: open BlackHole install page instead of Shizuku.
      openBlackHolePage()
      result(
        [
          "ok": true,
          "shizuku": privilegeLabel(),
          "message": statusMessage,
        ] as [String: Any]
      )
    case "openDeveloperOptions":
      openAudioMidiSetup()
      result(true)
    case "selfTestLoopback":
      let msg = injectBeep(durationMs: 600)
      result(
        [
          "message": msg,
          "running": running,
          "debug": debugLine(),
        ] as [String: Any]
      )
    case "pushPcm":
      if let data = call.arguments as? FlutterStandardTypedData {
        pushPcm(data.data)
      } else if let bytes = call.arguments as? [UInt8] {
        pushPcm(Data(bytes))
      }
      result(nil)
    case "pushPartialText", "pushFinalText", "openImeSettings", "showImePicker":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func privilegeLabel() -> String {
    if findVirtualOutputDevice() != nil {
      return "macOS · 已检测到虚拟声卡（BlackHole）"
    }
    return "macOS · 未检测到 BlackHole，请先安装虚拟声卡"
  }

  private func debugLine() -> String {
    "device=\(outputDeviceName.isEmpty ? "-" : outputDeviceName) bytes=\(bytesForwarded) running=\(running)"
  }

  private func start() throws {
    if running { return }

    guard let device = findVirtualOutputDevice() else {
      statusMessage =
        "未找到 BlackHole。请先: brew install blackhole-2ch ，然后在「音频 MIDI 设置」确认出现 BlackHole 2ch"
      throw NSError(
        domain: "DouMic",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: statusMessage]
      )
    }

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)

    // Prefer 48 kHz float mono → upmix to device channels if needed.
    guard
      let src = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
      )
    else {
      throw NSError(
        domain: "DouMic",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "无法创建 PCM 格式"]
      )
    }

    let outUnit = engine.outputNode.auAudioUnit
    try outUnit.setDeviceID(device.id)

    let hwFormat = engine.outputNode.outputFormat(forBus: 0)
    // Player feeds float32 non-interleaved at hardware rate, mono or stereo.
    let playChannels: AVAudioChannelCount = hwFormat.channelCount >= 2 ? 2 : 1
    guard
      let playFmt = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: hwFormat.sampleRate,
        channels: playChannels,
        interleaved: false
      )
    else {
      throw NSError(
        domain: "DouMic",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "无法创建播放格式"]
      )
    }

    engine.connect(player, to: engine.mainMixerNode, format: playFmt)
    engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
    engine.mainMixerNode.outputVolume = 1.0

    try engine.start()
    player.play()

    self.engine = engine
    self.player = player
    self.sourceFormat = src
    self.playerFormat = playFmt
    self.outputDeviceName = device.name
    self.running = true
    self.bytesForwarded = 0
    self.statusMessage = "虚拟麦已开启 → \(device.name)（请在 Typeless 里选它作麦克风）"
    emitStatus()
  }

  private func stop() {
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    sourceFormat = nil
    playerFormat = nil
    running = false
    statusMessage = "虚拟麦克风已关闭"
    emitStatus()
  }

  private func pushPcm(_ data: Data) {
    guard running, let player, let playFmt = playerFormat, !data.isEmpty else { return }
    bytesForwarded += Int64(data.count)

    pcmQueue.async { [weak self] in
      guard let self else { return }
      guard let buffer = self.makePlayerBuffer(pcm16leMono16k: data, playFormat: playFmt) else {
        return
      }
      DispatchQueue.main.async {
        // Keep ~250 ms of queued audio to avoid underruns without huge latency.
        if player.engine != nil {
          player.scheduleBuffer(buffer, completionHandler: nil)
        }
      }
    }
  }

  private func makePlayerBuffer(pcm16leMono16k data: Data, playFormat: AVAudioFormat)
    -> AVAudioPCMBuffer?
  {
    let inSamples = data.count / 2
    guard inSamples > 0 else { return nil }

    let ratio = playFormat.sampleRate / 16_000.0
    let outFrames = AVAudioFrameCount(Double(inSamples) * ratio)
    guard outFrames > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: outFrames)
    else {
      return nil
    }
    buffer.frameLength = outFrames

    let src = data.withUnsafeBytes { raw -> [Int16] in
      let bind = raw.bindMemory(to: Int16.self)
      return Array(bind)
    }

    let ch = Int(playFormat.channelCount)
    for c in 0..<ch {
      guard let dst = buffer.floatChannelData?[c] else { continue }
      for i in 0..<Int(outFrames) {
        let srcPos = Double(i) / ratio
        let i0 = min(Int(srcPos), inSamples - 1)
        let i1 = min(i0 + 1, inSamples - 1)
        let frac = Float(srcPos - Double(i0))
        let s0 = Float(src[i0]) / 32768.0
        let s1 = Float(src[i1]) / 32768.0
        dst[i] = s0 + (s1 - s0) * frac
      }
    }
    return buffer
  }

  @discardableResult
  private func injectBeep(durationMs: Int) -> String {
    guard running else { return "请先开启虚拟麦克风" }
    let rate = 16_000
    let n = rate * durationMs / 1000
    var data = Data(count: n * 2)
    data.withUnsafeMutableBytes { raw in
      let ptr = raw.bindMemory(to: Int16.self)
      for i in 0..<n {
        let s = sin(2.0 * Double.pi * 880.0 * Double(i) / Double(rate)) * 28000.0
        ptr[i] = Int16(clamping: Int(s))
      }
    }
    pushPcm(data)
    statusMessage = "已注入测试音到 \(outputDeviceName)。在 Typeless 选 BlackHole，波形应跳动"
    emitStatus()
    return statusMessage
  }

  private struct AudioDev {
    let id: AudioDeviceID
    let name: String
  }

  private func findVirtualOutputDevice() -> AudioDev? {
    let devices = listOutputDevices()
    let preferred = ["BlackHole 2ch", "BlackHole", "豆麦", "DouMic", "Loopback", "Soundflower"]
    for key in preferred {
      if let hit = devices.first(where: { $0.name.localizedCaseInsensitiveContains(key) }) {
        return hit
      }
    }
    return nil
  }

  private func listOutputDevices() -> [AudioDev] {
    var prop = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &dataSize)
      == noErr
    else {
      return []
    }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &prop,
        0,
        nil,
        &dataSize,
        &ids
      ) == noErr
    else {
      return []
    }

    var result: [AudioDev] = []
    for id in ids {
      // Must have output channels.
      var streamProp = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
      )
      var streamSize: UInt32 = 0
      if AudioObjectGetPropertyDataSize(id, &streamProp, 0, nil, &streamSize) != noErr {
        continue
      }
      let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(streamSize),
        alignment: MemoryLayout<AudioBufferList>.alignment
      )
      defer { raw.deallocate() }
      if AudioObjectGetPropertyData(id, &streamProp, 0, nil, &streamSize, raw) != noErr {
        continue
      }
      let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
      var outs = 0
      let bufs = UnsafeMutableAudioBufferListPointer(abl)
      for b in bufs {
        outs += Int(b.mNumberChannels)
      }
      if outs == 0 { continue }

      var nameProp = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )
      var name: CFString? = nil
      var nameSize = UInt32(MemoryLayout<CFString?>.size)
      let err = withUnsafeMutablePointer(to: &name) { ptr in
        AudioObjectGetPropertyData(id, &nameProp, 0, nil, &nameSize, ptr)
      }
      if err != noErr { continue }
      let label = (name as String?) ?? "Device \(id)"
      result.append(AudioDev(id: id, name: label))
    }
    return result
  }

  private func openBlackHolePage() {
    if let url = URL(string: "https://existential.audio/blackhole/") {
      NSWorkspace.shared.open(url)
    }
    statusMessage = "已打开 BlackHole 下载页。安装 2ch 后回到豆麦打开虚拟麦"
    emitStatus()
  }

  private func openAudioMidiSetup() {
    let path = "/System/Applications/Utilities/Audio MIDI Setup.app"
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
  }

  private func emitStatus() {
    eventSink?(
      [
        "type": "virtualMicStatus",
        "message": statusMessage,
        "running": running,
        "shizuku": privilegeLabel(),
      ] as [String: Any]
    )
  }
}

extension MacMicBridge: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
