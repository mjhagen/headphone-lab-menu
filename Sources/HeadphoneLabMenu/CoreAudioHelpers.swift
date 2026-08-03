import CoreAudio
import Foundation

enum AudioRouteError: LocalizedError {
  case osStatus(OSStatus, String)
  case noOutputDevice
  case unexpectedInputChannels(UInt32)
  case unsupportedAudioFormat

  var errorDescription: String? {
    switch self {
    case .osStatus(let status, let operation):
      let code = UInt32(bitPattern: status)
      let bytes = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff),
      ]
      let fourCC =
        bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        ? String(bytes: bytes, encoding: .ascii).map { " (\($0))" } ?? ""
        : ""
      return "\(operation) failed: \(status)\(fourCC)"
    case .noOutputDevice:
      return "No audio output device is selected."
    case .unexpectedInputChannels(let channels):
      return
        "The audio tap exposed \(channels) channels instead of stereo. Select an output-only device, such as headphones, and try again."
    case .unsupportedAudioFormat:
      return "The selected output device did not provide 32-bit floating-point PCM audio."
    }
  }
}

@inline(__always)
func check(_ status: OSStatus, _ operation: String) throws {
  guard status == noErr else { throw AudioRouteError.osStatus(status, operation) }
}

func propertyAddress(
  _ selector: AudioObjectPropertySelector,
  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
  element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(
    mSelector: selector,
    mScope: scope,
    mElement: element
  )
}

func readAudioObjectID(
  from objectID: AudioObjectID,
  selector: AudioObjectPropertySelector
) throws -> AudioObjectID {
  var address = propertyAddress(selector)
  var value = AudioObjectID(kAudioObjectUnknown)
  var size = UInt32(MemoryLayout.size(ofValue: value))
  try check(
    AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
    "Reading Core Audio object"
  )
  return value
}

func readString(
  from objectID: AudioObjectID,
  selector: AudioObjectPropertySelector
) throws -> String {
  var address = propertyAddress(selector)
  var value: CFString = "" as CFString
  var size = UInt32(MemoryLayout<CFString>.size)
  try withUnsafeMutablePointer(to: &value) { pointer in
    try check(
      AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer),
      "Reading Core Audio string"
    )
  }
  return value as String
}

func processObjectID(for pid: pid_t) throws -> AudioObjectID {
  var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
  var processID = pid
  var objectID = AudioObjectID(kAudioObjectUnknown)
  var size = UInt32(MemoryLayout.size(ofValue: objectID))
  try check(
    AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      UInt32(MemoryLayout.size(ofValue: processID)),
      &processID,
      &size,
      &objectID
    ),
    "Finding this app’s audio process"
  )
  return objectID
}

func fourCC(_ value: String) -> OSType {
  value.utf8.reduce(0) { ($0 << 8) | OSType($1) }
}
