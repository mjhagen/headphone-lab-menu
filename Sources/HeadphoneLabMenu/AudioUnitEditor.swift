import AVFoundation
import AppKit
import AudioUnitUIBridge

enum AudioUnitEditor {
  static func makeView(for effect: AVAudioUnit) throws -> NSView {
    var error: NSError?
    guard
      let view = HLMCreateAudioUnitView(
        effect.audioUnit,
        NSSize(width: 900, height: 620),
        &error
      )
    else {
      throw error ?? AudioRouteError.pluginMissing
    }
    return view
  }
}
