import AVFoundation
import AudioToolbox
import AudioUnitUIBridge
import CoreAudio
import Foundation

@MainActor
@available(macOS 14.2, *)
final class AudioPipeline {
  private(set) var isRunning = false
  private(set) var outputName = "Current output"
  private(set) var effect: AVAudioUnit?

  private var engine: AVAudioEngine?
  private var sourceNode: AVAudioSourceNode?
  private var ioProcID: AudioDeviceIOProcID?
  private var ring: OpaquePointer?
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)

  private let stateDefaultsKey = "HeadphoneLabAudioUnitState"

  func start() async throws {
    guard !isRunning else { return }

    var component = AudioComponentDescription(
      componentType: kAudioUnitType_Effect,
      componentSubType: fourCC("BdHL"),
      componentManufacturer: fourCC("Beyd"),
      componentFlags: 0,
      componentFlagsMask: 0
    )
    guard AudioComponentFindNext(nil, &component) != nil else {
      throw AudioRouteError.pluginMissing
    }

    let loadedEffect = try await AVAudioUnit.instantiate(
      with: component,
      options: []
    )
    if let savedState = UserDefaults.standard.data(forKey: stateDefaultsKey),
      let state = try? PropertyListSerialization.propertyList(
        from: savedState,
        options: [],
        format: nil
      ) as? [String: Any]
    {
      loadedEffect.auAudioUnit.fullState = state
    }

    let newEngine = AVAudioEngine()
    newEngine.attach(loadedEffect)
    // Instantiating the engine and effect registers this process with Core Audio,
    // which lets the global tap exclude the app and avoid a feedback loop.
    _ = newEngine.outputNode

    do {
      let defaultOutput = try readAudioObjectID(
        from: AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyDefaultOutputDevice
      )
      guard defaultOutput != kAudioObjectUnknown else {
        throw AudioRouteError.noOutputDevice
      }

      let outputUID = try readString(
        from: defaultOutput,
        selector: kAudioDevicePropertyDeviceUID
      )
      outputName = try readString(
        from: defaultOutput,
        selector: kAudioObjectPropertyName
      )

      let ownProcess = try processObjectID(for: getpid())
      let tapDescription = CATapDescription(
        stereoGlobalTapButExcludeProcesses: [ownProcess]
      )
      tapDescription.name = "Headphone Lab System Audio"
      tapDescription.uuid = UUID()
      tapDescription.isPrivate = true
      tapDescription.muteBehavior = .mutedWhenTapped
      tapDescription.deviceUID = outputUID

      var newTapID = AudioObjectID(kAudioObjectUnknown)
      try check(
        AudioHardwareCreateProcessTap(tapDescription, &newTapID),
        "Creating the system audio tap"
      )
      tapID = newTapID

      let tapUID = try readString(
        from: tapID,
        selector: kAudioTapPropertyUID
      )
      let bundleIdentifier =
        Bundle.main.bundleIdentifier
        ?? "nl.mingo.HeadphoneLabMenu"
      let aggregateUID = "\(bundleIdentifier).route.\(UUID().uuidString)"
      let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Headphone Lab Route",
        kAudioAggregateDeviceUIDKey: aggregateUID,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceTapListKey: [
          [
            kAudioSubTapUIDKey: tapUID
          ]
        ],
      ]
      var newAggregateID = AudioObjectID(kAudioObjectUnknown)
      try check(
        AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID),
        "Creating the private audio route"
      )
      aggregateID = newAggregateID

      var streamAddress = propertyAddress(
        kAudioDevicePropertyStreamFormat,
        scope: kAudioDevicePropertyScopeInput
      )
      var streamFormat = AudioStreamBasicDescription()
      var streamFormatSize = UInt32(MemoryLayout.size(ofValue: streamFormat))
      try check(
        AudioObjectGetPropertyData(
          aggregateID,
          &streamAddress,
          0,
          nil,
          &streamFormatSize,
          &streamFormat
        ),
        "Reading the system audio tap format"
      )
      guard streamFormat.mChannelsPerFrame == 2 else {
        throw AudioRouteError.unexpectedInputChannels(streamFormat.mChannelsPerFrame)
      }
      guard streamFormat.mFormatID == kAudioFormatLinearPCM,
        streamFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
        streamFormat.mBitsPerChannel == 32
      else {
        throw AudioRouteError.unsupportedAudioFormat
      }

      guard
        let format = AVAudioFormat(
          standardFormatWithSampleRate: streamFormat.mSampleRate,
          channels: 2
        )
      else {
        throw AudioRouteError.unsupportedAudioFormat
      }
      guard let newRing = HLMRingCreate(16_384) else {
        throw AudioRouteError.osStatus(
          kAudio_MemFullError,
          "Allocating the stereo audio buffer"
        )
      }
      ring = newRing

      nonisolated(unsafe) let renderBlock: AVAudioSourceNodeRenderBlock = {
        [newRing] _, _, frameCount, audioBufferList -> OSStatus in
        HLMRingRead(newRing, audioBufferList, frameCount)
        return noErr
      }
      let source = AVAudioSourceNode(format: format, renderBlock: renderBlock)
      sourceNode = source
      newEngine.attach(source)
      newEngine.connect(source, to: loadedEffect, format: format)
      newEngine.connect(loadedEffect, to: newEngine.mainMixerNode, format: format)
      newEngine.prepare()
      try newEngine.start()

      let bytesPerFrame = max(streamFormat.mBytesPerFrame, 1)
      nonisolated(unsafe) let captureBlock: AudioDeviceIOBlock = {
        [newRing] _, inputData, _, _, _ in
        guard inputData.pointee.mNumberBuffers > 0 else { return }
        let byteCount = inputData.pointee.mBuffers.mDataByteSize
        HLMRingWrite(newRing, inputData, byteCount / bytesPerFrame)
      }
      var newIOProcID: AudioDeviceIOProcID?
      try check(
        AudioDeviceCreateIOProcIDWithBlock(
          &newIOProcID,
          aggregateID,
          nil,
          captureBlock
        ),
        "Connecting the system audio tap"
      )
      ioProcID = newIOProcID
      try check(
        AudioDeviceStart(aggregateID, newIOProcID),
        "Starting the system audio tap"
      )

      engine = newEngine
      effect = loadedEffect
      isRunning = true
    } catch {
      newEngine.stop()
      newEngine.detach(loadedEffect)
      cleanupCoreAudioObjects()
      throw error
    }
  }

  func stop() {
    saveState()
    engine?.stop()
    stopCapture()
    if let effect, let engine {
      engine.detach(effect)
    }
    if let sourceNode, let engine {
      engine.detach(sourceNode)
    }
    engine = nil
    effect = nil
    sourceNode = nil
    isRunning = false
    cleanupCoreAudioObjects()
  }

  func saveState() {
    guard let state = effect?.auAudioUnit.fullState,
      let data = try? PropertyListSerialization.data(
        fromPropertyList: state,
        format: .binary,
        options: 0
      )
    else { return }
    UserDefaults.standard.set(data, forKey: stateDefaultsKey)
  }

  private func cleanupCoreAudioObjects() {
    stopCapture()
    if aggregateID != kAudioObjectUnknown {
      AudioHardwareDestroyAggregateDevice(aggregateID)
      aggregateID = AudioObjectID(kAudioObjectUnknown)
    }
    if tapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = AudioObjectID(kAudioObjectUnknown)
    }
    if let ring {
      HLMRingDestroy(ring)
      self.ring = nil
    }
  }

  private func stopCapture() {
    if let ioProcID, aggregateID != kAudioObjectUnknown {
      AudioDeviceStop(aggregateID, ioProcID)
      AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
      self.ioProcID = nil
    }
  }

}
