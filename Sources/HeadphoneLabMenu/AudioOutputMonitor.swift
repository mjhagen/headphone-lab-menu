import CoreAudio
import Foundation

/// A snapshot of the selected system playback destination, not merely connected devices.
struct AudioOutputRoute: Equatable, Sendable {
  let deviceID: AudioDeviceID
  let uid: String
  let name: String
  var transport: UInt32 = 0
  var dataSources: [UInt32] = []
  var sourceNames: [String] = []
  var terminalTypes: [UInt32] = []
  var jackConnected: Bool? = nil
  var isAlive = true
  var sampleRate: Double = 0

  // Older Macs can switch between speakers and the jack on the same device UID.
  // Remember manual identification for the selected source, never the entire device.
  var headphonePreferenceKey: String {
    ([uid] + dataSources.map(String.init)).joined(separator: "|")
  }

  var allowsHeadphoneIdentification: Bool {
    guard ![kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeHDMI,
      kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeVirtual,
      kAudioDeviceTransportTypeAggregate].contains(transport) else { return false }
    // A known speaker source must win over a device name or a saved identification.
    guard !dataSources.contains(fourCC("ispk")), !dataSources.contains(fourCC("spkr")),
      !sourceNames.contains(where: { $0.localizedCaseInsensitiveContains("speaker") })
    else { return false }
    return !(terminalTypes.contains(kAudioStreamTerminalTypeHeadphones)
      && terminalTypes.contains(kAudioStreamTerminalTypeSpeaker))
  }

  var detectedHeadphones: Bool {
    guard isAlive, jackConnected != false, allowsHeadphoneIdentification else { return false }
    if !dataSources.isEmpty {
      // Legacy built-in headphone source IDs, supplemented by the driver's source names.
      if dataSources.contains(fourCC("hdpn")) || dataSources.contains(fourCC("hdph"))
        || sourceNames.contains(where: Self.hasHeadphoneName) { return true }
    }
    if terminalTypes.contains(kAudioStreamTerminalTypeHeadphones) { return true }
    return Self.hasHeadphoneName(name)
  }

  private static func hasHeadphoneName(_ name: String) -> Bool {
    ["headphone", "headset", "earphone", "earbud", "airpods"].contains {
      name.localizedCaseInsensitiveContains($0)
    }
  }

  static func current() -> AudioOutputRoute? {
    guard let device = try? readAudioObjectID(
      from: AudioObjectID(kAudioObjectSystemObject),
      selector: kAudioHardwarePropertyDefaultOutputDevice
    ), device != kAudioObjectUnknown,
      let uid = try? readString(from: device, selector: kAudioDevicePropertyDeviceUID)
    else { return nil }
    let sources = audioUInt32Array(device, kAudioDevicePropertyDataSource,
      scope: kAudioObjectPropertyScopeOutput)
    let streams = audioUInt32Array(device, kAudioDevicePropertyStreams,
      scope: kAudioObjectPropertyScopeOutput)
    var route = AudioOutputRoute(deviceID: device, uid: uid,
      name: (try? readString(from: device, selector: kAudioObjectPropertyName)) ?? "Current output")
    route.transport = audioUInt32(device, kAudioDevicePropertyTransportType) ?? 0
    route.dataSources = sources.sorted()
    route.sourceNames = sources.compactMap { audioSourceName(device, source: $0) }
    route.terminalTypes = streams.compactMap { audioUInt32($0, kAudioStreamPropertyTerminalType) }
    route.jackConnected = audioUInt32(device, kAudioDevicePropertyJackIsConnected,
      scope: kAudioObjectPropertyScopeOutput).map { $0 != 0 }
    route.isAlive = audioUInt32(device, kAudioDevicePropertyDeviceIsAlive) == 1
    var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
    var size = UInt32(MemoryLayout<Double>.size)
    _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &route.sampleRate)
    return route
  }
}

@MainActor
final class AudioOutputMonitor {
  var onChange: ((AudioOutputRoute?) -> Void)?
  private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
  private var systemListenerCount = 0
  private var watchedDevice: AudioDeviceID?
  private var watchedStreams: [AudioStreamID] = []
  private var current: AudioOutputRoute?
  private var started = false

  func start() throws {
    guard !started else { return }
    started = true
    do {
      try listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
      try listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
      systemListenerCount = listeners.count
      refresh(force: true)
    } catch {
      stop()
      throw error
    }
  }

  func stop() {
    started = false
    removeListeners(startingAt: 0)
    systemListenerCount = 0
    watchedDevice = nil
    watchedStreams = []
    current = nil
  }

  func refresh(force: Bool = false) {
    guard started else { return }
    let route = AudioOutputRoute.current()
    let streams = route.map {
      audioUInt32Array($0.deviceID, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
    } ?? []
    if watchedDevice != route?.deviceID || watchedStreams != streams {
      removeListeners(startingAt: systemListenerCount)
      watchedDevice = route?.deviceID
      watchedStreams = streams
      if let device = watchedDevice {
        for selector in [kAudioDevicePropertyDataSource, kAudioDevicePropertyJackIsConnected] {
          try? listen(device, selector, scope: kAudioObjectPropertyScopeOutput)
        }
        for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyStreams,
          kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyName] {
          try? listen(device, selector)
        }
        // Stream topology is scoped to output on some drivers.
        try? listen(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        for stream in streams { try? listen(stream, kAudioStreamPropertyTerminalType) }
      }
    }
    if force || route != current {
      current = route
      onChange?(route)
    }
  }

  private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws {
    var address = propertyAddress(selector, scope: scope)
    guard AudioObjectHasProperty(object, &address) else { return }
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
    try check(AudioObjectAddPropertyListenerBlock(object, &address, .main, listener),
      "Watching the audio output")
    listeners.append((object, address, listener))
  }

  private func removeListeners(startingAt index: Int) {
    guard index < listeners.count else { return }
    for (object, var address, listener) in listeners[index...] {
      _ = AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener)
    }
    listeners.removeSubrange(index...)
  }
}

private func audioUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
  var address = propertyAddress(selector, scope: scope)
  var value: UInt32 = 0
  var size = UInt32(MemoryLayout<UInt32>.size)
  guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
  return value
}

private func audioUInt32Array(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [UInt32] {
  var address = propertyAddress(selector, scope: scope)
  var size: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
    size > 0, size % UInt32(MemoryLayout<UInt32>.size) == 0 else { return [] }
  var values = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
  let status = values.withUnsafeMutableBytes {
    AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
  }
  guard status == noErr else { return [] }
  return Array(values.prefix(Int(size) / MemoryLayout<UInt32>.size))
}

private func audioSourceName(_ device: AudioDeviceID, source: UInt32) -> String? {
  var address = propertyAddress(kAudioDevicePropertyDataSourceNameForIDCFString,
    scope: kAudioObjectPropertyScopeOutput)
  var input = source
  var result: Unmanaged<CFString>?
  let status = withUnsafeMutablePointer(to: &input) { inputPointer in
    withUnsafeMutablePointer(to: &result) { outputPointer in
      var translation = AudioValueTranslation(mInputData: inputPointer,
        mInputDataSize: UInt32(MemoryLayout<UInt32>.size), mOutputData: outputPointer,
        mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
      var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
      return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &translation)
    }
  }
  guard status == noErr else { return nil }
  return result?.takeRetainedValue() as String?
}
