import AppKit
import AVFoundation
import CoreAudio
import FlutterMacOS
import Foundation

/// Routes D3200 PCM16@16kHz into BlackHole (virtual mic loopback).
///
/// Uses AVAudioSourceNode + ring buffer (not scheduleBuffer bursts) so Core Audio
/// continuously pulls samples into BlackHole's output → other apps hear them on
/// BlackHole's input.
final class MacMicBridge: NSObject {
  static let shared = MacMicBridge()

  private let methodChannelName = "com.doumic.app/mic_bridge"
  private let eventChannelName = "com.doumic.app/mic_bridge_events"

  private var methodChannel: FlutterMethodChannel?
  private var eventSink: FlutterEventSink?

  private var engine: AVAudioEngine?
  private var sourceNode: AVAudioSourceNode?
  private var running = false
  private var enabled = false
  private var statusMessage = "未启用"
  private var outputDeviceName = ""
  private var outputDeviceID: AudioDeviceID = 0
  private var bytesForwarded: Int64 = 0
  private var renderFrames: Int64 = 0
  private var underruns: Int64 = 0

  private let ringLock = NSLock()
  // Interleaved stereo float32 @ device sample rate.
  private var ring = [Float](repeating: 0, count: 48_000 * 2 * 2) // ~2s stereo @ 48k
  private var ringRead = 0
  private var ringWrite = 0
  private var ringFilled = 0
  private var deviceRate: Double = 48_000
  private var deviceChannels: Int = 2

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
      let on = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
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
        result(FlutterError(code: "mac_mic", message: statusMessage, details: nil))
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
      result(
        [
          "message": injectBeep(durationMs: 800),
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
    let filledMs = deviceRate > 0 ? Int(Double(ringFilled / max(deviceChannels, 1)) / deviceRate * 1000) : 0
    return
      "device=\(outputDeviceName.isEmpty ? "-" : outputDeviceName) bytes=\(bytesForwarded) "
      + "render=\(renderFrames) underrun=\(underruns) buf=\(filledMs)ms running=\(running)"
  }

  private func start() throws {
    if running { return }

    guard let device = findVirtualOutputDevice() else {
      statusMessage = "未找到 BlackHole 2ch。请运行 DMG 里的「一键安装」或安装 BlackHole 2ch"
      throw NSError(domain: "DouMic", code: 1, userInfo: [NSLocalizedDescriptionKey: statusMessage])
    }

    maxVolume(deviceID: device.id)

    let engine = AVAudioEngine()
    // Set output device BEFORE reading hardware format / connecting graph.
    try engine.outputNode.auAudioUnit.setDeviceID(device.id)

    let hw = engine.outputNode.outputFormat(forBus: 0)
    let rate = hw.sampleRate > 0 ? hw.sampleRate : 48_000
    let ch = Int(max(hw.channelCount, 1))
    deviceRate = rate
    deviceChannels = min(ch, 2)

    guard
      let outFmt = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: rate,
        channels: AVAudioChannelCount(deviceChannels),
        interleaved: false
      )
    else {
      throw NSError(domain: "DouMic", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建输出格式"])
    }

    // Resize ring for ~2s at device rate.
    let ringSamples = Int(rate) * deviceChannels * 2
    ringLock.lock()
    ring = [Float](repeating: 0, count: max(ringSamples, 8192))
    ringRead = 0
    ringWrite = 0
    ringFilled = 0
    ringLock.unlock()

    let source = AVAudioSourceNode {
      [weak self] _, _, frameCount, audioBufferList -> OSStatus in
      guard let self else { return noErr }
      let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
      let frames = Int(frameCount)
      self.ringLock.lock()
      let availableFrames = self.ringFilled / self.deviceChannels
      let take = min(frames, availableFrames)
      for f in 0..<take {
        for c in 0..<self.deviceChannels {
          let idx = (self.ringRead + f * self.deviceChannels + c) % self.ring.count
          let sample = self.ring[idx]
          if c < abl.count, let data = abl[c].mData?.assumingMemoryBound(to: Float.self) {
            data[f] = sample
          }
        }
      }
      // Silence for the rest (underrun).
      for f in take..<frames {
        for c in 0..<abl.count {
          if let data = abl[c].mData?.assumingMemoryBound(to: Float.self) {
            data[f] = 0
          }
        }
      }
      let consumed = take * self.deviceChannels
      self.ringRead = (self.ringRead + consumed) % self.ring.count
      self.ringFilled -= consumed
      if take < frames { self.underruns += 1 }
      self.renderFrames += Int64(frames)
      self.ringLock.unlock()
      return noErr
    }

    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: outFmt)
    engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
    engine.mainMixerNode.outputVolume = 1.0

    try engine.start()

    // Confirm device stuck.
    let actualID = engine.outputNode.auAudioUnit.deviceID
    let actualName = deviceName(id: actualID) ?? device.name

    self.engine = engine
    self.sourceNode = source
    self.outputDeviceID = actualID
    self.outputDeviceName = actualName
    self.running = true
    self.bytesForwarded = 0
    self.renderFrames = 0
    self.underruns = 0

    // Immediate proof tone so System Settings → BlackHole input meter should jump.
    _ = injectBeep(durationMs: 500)

    statusMessage =
      "虚拟麦已开启 → \(actualName)。请看系统设置里 BlackHole 输入电平是否跳动"
    emitStatus()
  }

  private func stop() {
    engine?.stop()
    if let source = sourceNode {
      engine?.detach(source)
    }
    sourceNode = nil
    engine = nil
    running = false
    ringLock.lock()
    ringFilled = 0
    ringRead = 0
    ringWrite = 0
    ringLock.unlock()
    statusMessage = "虚拟麦克风已关闭"
    emitStatus()
  }

  private func pushPcm(_ data: Data) {
    guard running, !data.isEmpty else { return }
    bytesForwarded += Int64(data.count)
    let samples = resampleToDevice(pcm16leMono16k: data)
    guard !samples.isEmpty else { return }
    enqueue(samples)
  }

  private func enqueue(_ samples: [Float]) {
    ringLock.lock()
    defer { ringLock.unlock() }
    var offset = 0
    while offset < samples.count {
      if ringFilled >= ring.count {
        // Drop oldest ~20ms to keep latency bounded.
        let drop = min(deviceChannels * Int(deviceRate * 0.02), ringFilled)
        ringRead = (ringRead + drop) % ring.count
        ringFilled -= drop
      }
      let space = ring.count - ringFilled
      if space <= 0 { break }
      let n = min(space, samples.count - offset, ring.count - ringWrite)
      for i in 0..<n {
        ring[ringWrite + i] = samples[offset + i]
      }
      ringWrite = (ringWrite + n) % ring.count
      ringFilled += n
      offset += n
    }
  }

  /// 16 kHz mono PCM16 → interleaved float stereo (or mono) @ deviceRate.
  private func resampleToDevice(pcm16leMono16k data: Data) -> [Float] {
    let inSamples = data.count / 2
    guard inSamples > 0 else { return [] }
    let ratio = deviceRate / 16_000.0
    let outFrames = Int((Double(inSamples) * ratio).rounded(.down))
    guard outFrames > 0 else { return [] }

    var out = [Float](repeating: 0, count: outFrames * deviceChannels)
    data.withUnsafeBytes { raw in
      let src = raw.bindMemory(to: Int16.self)
      for i in 0..<outFrames {
        let srcPos = Double(i) / ratio
        let i0 = min(Int(srcPos), inSamples - 1)
        let i1 = min(i0 + 1, inSamples - 1)
        let frac = Float(srcPos - Double(i0))
        let s0 = Float(src[i0]) / 32768.0
        let s1 = Float(src[i1]) / 32768.0
        let s = s0 + (s1 - s0) * frac
        let base = i * deviceChannels
        out[base] = s
        if deviceChannels > 1 { out[base + 1] = s }
      }
    }
    return out
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
        // Louder beep so System Settings meter is obvious.
        let s = sin(2.0 * Double.pi * 880.0 * Double(i) / Double(rate)) * 30000.0
        ptr[i] = Int16(clamping: Int(s))
      }
    }
    pushPcm(data)
    statusMessage =
      "已注入测试音到 \(outputDeviceName)。请立刻看「系统设置→声音→输入→BlackHole」电平是否跳动"
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
    guard
      AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &dataSize)
        == noErr
    else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &dataSize, &ids) == noErr
    else { return [] }

    var result: [AudioDev] = []
    for id in ids {
      if channelCount(device: id, scope: kAudioDevicePropertyScopeOutput) == 0 { continue }
      if let name = deviceName(id: id) {
        result.append(AudioDev(id: id, name: name))
      }
    }
    return result
  }

  private func channelCount(device id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var streamProp = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain
    )
    var streamSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &streamProp, 0, nil, &streamSize) == noErr else {
      return 0
    }
    let raw = UnsafeMutableRawPointer.allocate(
      byteCount: Int(streamSize),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &streamProp, 0, nil, &streamSize, raw) == noErr else {
      return 0
    }
    let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
    var n = 0
    for b in UnsafeMutableAudioBufferListPointer(abl) {
      n += Int(b.mNumberChannels)
    }
    return n
  }

  private func deviceName(id: AudioDeviceID) -> String? {
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
    guard err == noErr else { return nil }
    return name as String?
  }

  /// Pull BlackHole I/O volumes to max — otherwise System Settings meter stays flat.
  private func maxVolume(deviceID: AudioDeviceID) {
    let scopes: [AudioObjectPropertyScope] = [
      kAudioDevicePropertyScopeOutput,
      kAudioDevicePropertyScopeInput,
    ]
    for scope in scopes {
      var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
      )
      if AudioObjectHasProperty(deviceID, &addr) {
        var vol: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &vol)
      }
      // Per-channel volumes (BlackHole often exposes channels 1..N).
      for element: UInt32 in 1...8 {
        var chAddr = AudioObjectPropertyAddress(
          mSelector: kAudioDevicePropertyVolumeScalar,
          mScope: scope,
          mElement: element
        )
        if AudioObjectHasProperty(deviceID, &chAddr) {
          var vol: Float32 = 1.0
          var size = UInt32(MemoryLayout<Float32>.size)
          AudioObjectSetPropertyData(deviceID, &chAddr, 0, nil, size, &vol)
        }
      }
    }
  }

  private func openBlackHolePage() {
    if let url = URL(string: "https://existential.audio/blackhole/") {
      NSWorkspace.shared.open(url)
    }
    statusMessage = "已打开 BlackHole 下载页"
    emitStatus()
  }

  private func openAudioMidiSetup() {
    NSWorkspace.shared.open(
      URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
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
