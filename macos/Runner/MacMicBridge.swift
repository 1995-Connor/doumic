import AppKit
import AudioToolbox
import CoreAudio
import FlutterMacOS
import Foundation

/// Routes D3200 PCM16@16kHz into BlackHole via AUHAL (not AVAudioEngine).
///
/// BlackHole loopback: play on BlackHole **output** → other apps record BlackHole **input**.
/// AVAudioEngine.setDeviceID often silently keeps the default speakers; AUHAL
/// `kAudioOutputUnitProperty_CurrentDevice` is the reliable path.
final class MacMicBridge: NSObject {
  static let shared = MacMicBridge()

  private let methodChannelName = "com.doumic.app/mic_bridge"
  private let eventChannelName = "com.doumic.app/mic_bridge_events"

  private var methodChannel: FlutterMethodChannel?
  private var eventSink: FlutterEventSink?

  private var audioUnit: AudioUnit?
  private var running = false
  private var enabled = false
  private var statusMessage = "未启用"
  private var outputDeviceName = ""
  private var outputDeviceID: AudioDeviceID = 0
  private var bytesForwarded: Int64 = 0
  private var renderFrames: Int64 = 0
  private var underruns: Int64 = 0
  private var lastAUError: OSStatus = noErr

  private let ringLock = NSLock()
  private var ring = [Float](repeating: 0, count: 48_000 * 2 * 2)
  private var ringRead = 0
  private var ringWrite = 0
  private var ringFilled = 0
  private var deviceRate: Double = 48_000
  private var deviceChannels: UInt32 = 2

  /// Remaining frames of loud proof-tone generated inside the AU callback
  /// (does not depend on Flutter pushPcm / ring).
  private var toneFramesLeft: Int64 = 0
  private var tonePhase: Double = 0

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
          "message": injectBeep(durationMs: 1200),
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
    ringLock.lock()
    let filled = ringFilled
    let rf = renderFrames
    let ur = underruns
    let tone = toneFramesLeft
    ringLock.unlock()
    let filledMs =
      deviceRate > 0 ? Int(Double(filled / max(Int(deviceChannels), 1)) / deviceRate * 1000) : 0
    return
      "hal=\(outputDeviceName.isEmpty ? "-" : outputDeviceName) id=\(outputDeviceID) "
      + "bytes=\(bytesForwarded) render=\(rf) underrun=\(ur) buf=\(filledMs)ms "
      + "tone=\(tone) auErr=\(lastAUError) rate=\(Int(deviceRate)) running=\(running)"
  }

  private func start() throws {
    if running { return }

    guard let device = findVirtualOutputDevice() else {
      statusMessage = "未找到 BlackHole 2ch。请运行 DMG 里的「一键安装」或安装 BlackHole 2ch"
      throw NSError(domain: "DouMic", code: 1, userInfo: [NSLocalizedDescriptionKey: statusMessage])
    }

    // Prefer 48 kHz — matches BlackHole default and System Settings meters.
    setNominalSampleRate(deviceID: device.id, rate: 48_000)
    unmuteAndMaxVolume(deviceID: device.id)

    let rate = nominalSampleRate(deviceID: device.id) ?? 48_000
    let chCount = max(1, min(2, channelCount(device: device.id, scope: kAudioDevicePropertyScopeOutput)))
    deviceRate = rate
    deviceChannels = UInt32(chCount)

    let ringSamples = Int(rate) * Int(deviceChannels) * 2
    ringLock.lock()
    ring = [Float](repeating: 0, count: max(ringSamples, 8192))
    ringRead = 0
    ringWrite = 0
    ringFilled = 0
    toneFramesLeft = 0
    tonePhase = 0
    ringLock.unlock()

    var desc = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_HALOutput,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0
    )
    guard let comp = AudioComponentFindNext(nil, &desc) else {
      throw NSError(domain: "DouMic", code: 2, userInfo: [NSLocalizedDescriptionKey: "找不到 HAL 音频单元"])
    }
    var au: AudioUnit?
    var err = AudioComponentInstanceNew(comp, &au)
    guard err == noErr, let audioUnit = au else {
      throw NSError(
        domain: "DouMic", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "创建 HAL 失败 (\(err))"])
    }

    // Output only (element 0). Disable input side (element 1).
    var enableOut: UInt32 = 1
    var enableIn: UInt32 = 0
    err = AudioUnitSetProperty(
      audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableOut,
      UInt32(MemoryLayout<UInt32>.size))
    check(err, "EnableIO out")
    err = AudioUnitSetProperty(
      audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIn,
      UInt32(MemoryLayout<UInt32>.size))
    check(err, "EnableIO in")

    var deviceID = device.id
    err = AudioUnitSetProperty(
      audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID,
      UInt32(MemoryLayout<AudioDeviceID>.size))
    if err != noErr {
      AudioComponentInstanceDispose(audioUnit)
      throw NSError(
        domain: "DouMic", code: 4,
        userInfo: [
          NSLocalizedDescriptionKey: "无法把输出设为 \(device.name)（错误 \(err)）。请确认已关闭沙盒/重装 BlackHole"
        ])
    }

    // Client format: non-interleaved float32 @ device rate — what AUHAL expects on
    // input scope of output element 0.
    var asbd = AudioStreamBasicDescription(
      mSampleRate: rate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved
        | kAudioFormatFlagsNativeEndian,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: deviceChannels,
      mBitsPerChannel: 32,
      mReserved: 0
    )
    err = AudioUnitSetProperty(
      audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd,
      UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    check(err, "StreamFormat")

    var callback = AURenderCallbackStruct(
      inputProc: MacMicBridgeRenderCallback,
      inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
    )
    err = AudioUnitSetProperty(
      audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
      UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    check(err, "SetRenderCallback")

    err = AudioUnitInitialize(audioUnit)
    if err != noErr {
      AudioComponentInstanceDispose(audioUnit)
      throw NSError(
        domain: "DouMic", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "AudioUnitInitialize 失败 (\(err))"])
    }

    err = AudioOutputUnitStart(audioUnit)
    if err != noErr {
      AudioUnitUninitialize(audioUnit)
      AudioComponentInstanceDispose(audioUnit)
      throw NSError(
        domain: "DouMic", code: 6,
        userInfo: [NSLocalizedDescriptionKey: "AudioOutputUnitStart 失败 (\(err))"])
    }

    // Verify device stuck on BlackHole.
    var actualID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioUnitGetProperty(
      audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actualID, &size)
    let actualName = deviceName(id: actualID) ?? device.name
    if actualID != device.id {
      AudioOutputUnitStop(audioUnit)
      AudioUnitUninitialize(audioUnit)
      AudioComponentInstanceDispose(audioUnit)
      throw NSError(
        domain: "DouMic", code: 7,
        userInfo: [
          NSLocalizedDescriptionKey:
            "输出设备被改回 \(actualName)，未能锁定 BlackHole。请重启 Mac 或重装 BlackHole"
        ])
    }

    self.audioUnit = audioUnit
    self.outputDeviceID = actualID
    self.outputDeviceName = actualName
    self.running = true
    self.bytesForwarded = 0
    self.renderFrames = 0
    self.underruns = 0
    self.lastAUError = noErr

    // ~1.2s loud tone generated inside the AU callback itself.
    _ = injectBeep(durationMs: 1200)

    statusMessage =
      "HAL 已锁定 \(actualName) @ \(Int(rate))Hz。点「注入测试音」后看系统设置 BlackHole 输入电平"
    emitStatus()
  }

  private func stop() {
    if let au = audioUnit {
      AudioOutputUnitStop(au)
      AudioUnitUninitialize(au)
      AudioComponentInstanceDispose(au)
    }
    audioUnit = nil
    running = false
    ringLock.lock()
    ringFilled = 0
    ringRead = 0
    ringWrite = 0
    toneFramesLeft = 0
    ringLock.unlock()
    statusMessage = "虚拟麦克风已关闭"
    emitStatus()
  }

  private func check(_ err: OSStatus, _ label: String) {
    if err != noErr {
      lastAUError = err
      NSLog("[DouMic] AudioUnit \(label) error: \(err)")
    }
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
        let drop = min(Int(deviceChannels) * Int(deviceRate * 0.02), ringFilled)
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

  /// 16 kHz mono PCM16 → interleaved float @ deviceRate / deviceChannels.
  private func resampleToDevice(pcm16leMono16k data: Data) -> [Float] {
    let inSamples = data.count / 2
    guard inSamples > 0 else { return [] }
    let ratio = deviceRate / 16_000.0
    let outFrames = Int((Double(inSamples) * ratio).rounded(.down))
    guard outFrames > 0 else { return [] }
    let ch = Int(deviceChannels)

    var out = [Float](repeating: 0, count: outFrames * ch)
    data.withUnsafeBytes { raw in
      let src = raw.bindMemory(to: Int16.self)
      for i in 0..<outFrames {
        let srcPos = Double(i) / ratio
        let i0 = min(Int(srcPos), inSamples - 1)
        let i1 = min(i0 + 1, inSamples - 1)
        let frac = Float(srcPos - Double(i0))
        let s0 = Float(src[i0]) / 32768.0
        let s1 = Float(src[i1]) / 32768.0
        // Soft speech boost for Typeless gate (~+12 dB, soft clip).
        var s = (s0 + (s1 - s0) * frac) * 4.0
        if s > 1 { s = 1 }
        if s < -1 { s = -1 }
        let base = i * ch
        out[base] = s
        if ch > 1 { out[base + 1] = s }
      }
    }
    return out
  }

  @discardableResult
  private func injectBeep(durationMs: Int) -> String {
    guard running else { return "请先开启虚拟麦克风" }
    let frames = Int64(deviceRate * Double(durationMs) / 1000.0)
    ringLock.lock()
    toneFramesLeft = max(frames, 1)
    tonePhase = 0
    ringLock.unlock()
    statusMessage =
      "HAL 测试音 → \(outputDeviceName)（\(durationMs)ms）。请看「系统设置→声音→输入→BlackHole」电平是否跳动"
    emitStatus()
    return statusMessage
  }

  /// Called from real-time audio thread — keep it lock-short and allocation-free.
  fileprivate func render(
    frameCount: UInt32, audioBufferList: UnsafeMutablePointer<AudioBufferList>
  ) -> OSStatus {
    let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let frames = Int(frameCount)
    let ch = Int(deviceChannels)

    ringLock.lock()
    let availableFrames = ringFilled / max(ch, 1)
    let take = min(frames, availableFrames)
    var toneLeft = toneFramesLeft
    var phase = tonePhase

    for f in 0..<frames {
      var sample: Float = 0
      if f < take {
        let idx = (ringRead + f * ch) % ring.count
        sample = ring[idx]
      }
      if toneLeft > 0 {
        // ~0.7 peak 880 Hz — loud enough for System Settings meter.
        let t = Float(sin(phase) * 0.7)
        sample = max(-1, min(1, sample + t))
        phase += 2.0 * Double.pi * 880.0 / deviceRate
        if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
        toneLeft -= 1
      }
      for c in 0..<abl.count {
        if let data = abl[c].mData?.assumingMemoryBound(to: Float.self) {
          data[f] = sample
        }
      }
    }

    let consumed = take * ch
    ringRead = (ringRead + consumed) % ring.count
    ringFilled -= consumed
    if take < frames && toneFramesLeft <= 0 { underruns += 1 }
    toneFramesLeft = max(toneLeft, 0)
    tonePhase = phase
    renderFrames += Int64(frames)
    ringLock.unlock()
    return noErr
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

  private func nominalSampleRate(deviceID: AudioDeviceID) -> Double? {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr else {
      return nil
    }
    return rate
  }

  private func setNominalSampleRate(deviceID: AudioDeviceID, rate: Float64) {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var r = rate
    let size = UInt32(MemoryLayout<Float64>.size)
    AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &r)
  }

  private func unmuteAndMaxVolume(deviceID: AudioDeviceID) {
    let scopes: [AudioObjectPropertyScope] = [
      kAudioDevicePropertyScopeOutput,
      kAudioDevicePropertyScopeInput,
    ]
    for scope in scopes {
      var muteAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
      )
      if AudioObjectHasProperty(deviceID, &muteAddr) {
        var mute: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectSetPropertyData(deviceID, &muteAddr, 0, nil, size, &mute)
      }
      for element: UInt32 in 0...8 {
        var volAddr = AudioObjectPropertyAddress(
          mSelector: kAudioDevicePropertyVolumeScalar,
          mScope: scope,
          mElement: element
        )
        if AudioObjectHasProperty(deviceID, &volAddr) {
          var vol: Float32 = 1.0
          let size = UInt32(MemoryLayout<Float32>.size)
          AudioObjectSetPropertyData(deviceID, &volAddr, 0, nil, size, &vol)
        }
        var chMute = AudioObjectPropertyAddress(
          mSelector: kAudioDevicePropertyMute,
          mScope: scope,
          mElement: element
        )
        if AudioObjectHasProperty(deviceID, &chMute) {
          var mute: UInt32 = 0
          let size = UInt32(MemoryLayout<UInt32>.size)
          AudioObjectSetPropertyData(deviceID, &chMute, 0, nil, size, &mute)
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

/// Real-time AUHAL render callback (C convention).
private func MacMicBridgeRenderCallback(
  inRefCon: UnsafeMutableRawPointer,
  ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
  inTimeStamp: UnsafePointer<AudioTimeStamp>,
  inBusNumber: UInt32,
  inNumberFrames: UInt32,
  ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
  guard let ioData else { return noErr }
  let bridge = Unmanaged<MacMicBridge>.fromOpaque(inRefCon).takeUnretainedValue()
  return bridge.render(frameCount: inNumberFrames, audioBufferList: ioData)
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
