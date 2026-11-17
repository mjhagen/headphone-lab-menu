import Foundation

/// Keeps the user's enable preference separate from whether this route may be processed.
@MainActor
final class HeadphoneRoutingController {
  private(set) var enabled: Bool
  private(set) var output: AudioOutputRoute?
  private(set) var runningOutput: AudioOutputRoute?
  private(set) var headphoneOutputKeys: Set<String>
  private(set) var error: Error?
  var onChange: (() -> Void)?
  var onError: ((Error) -> Void)?
  private let startProcessing: (AudioOutputRoute) throws -> Void
  private let stopProcessing: () -> Void
  private var attemptedOutput: AudioOutputRoute?

  init(enabled: Bool, headphoneOutputKeys: Set<String> = [],
    start: @escaping (AudioOutputRoute) throws -> Void, stop: @escaping () -> Void) {
    self.enabled = enabled
    self.headphoneOutputKeys = headphoneOutputKeys
    startProcessing = start
    stopProcessing = stop
  }

  var usesHeadphoneOverride: Bool {
    output.map { headphoneOutputKeys.contains($0.headphonePreferenceKey) } ?? false
  }

  var headphonesSelected: Bool {
    guard let output, output.isAlive, output.jackConnected != false,
      output.allowsHeadphoneIdentification else { return false }
    return output.detectedHeadphones || usesHeadphoneOverride
  }

  func updateOutput(_ output: AudioOutputRoute?) {
    self.output = output
    reconcile()
  }

  func setEnabled(_ enabled: Bool) {
    self.enabled = enabled
    attemptedOutput = nil // A deliberate enable action may retry a failed start.
    reconcile()
  }

  func setHeadphoneOverride(_ enabled: Bool) {
    guard let output, !enabled || output.allowsHeadphoneIdentification else { return }
    if enabled { headphoneOutputKeys.insert(output.headphonePreferenceKey) }
    else { headphoneOutputKeys.remove(output.headphonePreferenceKey) }
    attemptedOutput = nil
    reconcile()
  }

  private func reconcile() {
    let desired = enabled && headphonesSelected ? output : nil
    if desired != runningOutput {
      if runningOutput != nil {
        stopProcessing()
        runningOutput = nil
      }
      if let desired, desired != attemptedOutput {
        attemptedOutput = desired
        do {
          try startProcessing(desired)
          runningOutput = desired
          error = nil
        } catch {
          self.error = error
          onChange?()
          onError?(error)
          return
        }
      }
    }
    if desired == nil {
      attemptedOutput = nil
      error = nil
    }
    onChange?()
  }
}
