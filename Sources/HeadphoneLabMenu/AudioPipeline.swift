import AVFoundation
import AudioBridge
import AudioToolbox
import CoreAudio
import Foundation

@MainActor
@available(macOS 14.2, *)
final class AudioPipeline {
  private(set) var isRunning = false
  private(set) var outputName = "Current output"
  private var engine: AVAudioEngine?
  private var sourceNode: AVAudioSourceNode?
  private var equalizer: AVAudioUnitEQ?
  private var peakLimiter: AVAudioUnitEffect?
  private var safetyTrim: AVAudioUnitEQ?
  private var ioProcID: AudioDeviceIOProcID?
  private var ring: OpaquePointer?
  private var analysisRing: OpaquePointer?
  private var analysisTapInstalled = false
  private var analysisSampleRate = 48_000.0
  private let spectrumAnalyzer = AudioSpectrumAnalyzer()
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)

  func start(
    profile: EQProfile?,
    userGain: Float = 0,
    peakLimiterEnabled: Bool = false
  ) async throws {
    guard !isRunning else { return }

    let newEngine = AVAudioEngine()
    let newEqualizer = AVAudioUnitEQ(numberOfBands: EQProfile.maximumFilterCount)
    let limiterDescription = AudioComponentDescription(
      componentType: kAudioUnitType_Effect,
      componentSubType: kAudioUnitSubType_PeakLimiter,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0
    )
    let newPeakLimiter = AVAudioUnitEffect(audioComponentDescription: limiterDescription)
    let newSafetyTrim = AVAudioUnitEQ(numberOfBands: 1)
    newSafetyTrim.bands[0].bypass = true
    configure(newEqualizer, with: profile, userGain: userGain)
    configurePeakLimiter(
      newPeakLimiter,
      safetyTrim: newSafetyTrim,
      enabled: peakLimiterEnabled
    )
    newEngine.attach(newEqualizer)
    newEngine.attach(newPeakLimiter)
    newEngine.attach(newSafetyTrim)
    // Instantiating the engine registers this process with Core Audio, which lets
    // the global tap exclude the app and avoid a feedback loop.
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
      tapDescription.name = "Headphone EQ System Audio"
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
        kAudioAggregateDeviceNameKey: "Headphone EQ Route",
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
      newEngine.connect(source, to: newEqualizer, format: format)
      newEngine.connect(newEqualizer, to: newPeakLimiter, format: format)
      newEngine.connect(newPeakLimiter, to: newSafetyTrim, format: format)
      newEngine.connect(newSafetyTrim, to: newEngine.mainMixerNode, format: format)
      guard let newAnalysisRing = HLMRingCreate(32_768) else {
        throw AudioRouteError.osStatus(
          kAudio_MemFullError,
          "Allocating the spectrum buffer"
        )
      }
      analysisRing = newAnalysisRing
      analysisSampleRate = format.sampleRate
      newSafetyTrim.installTap(onBus: 0, bufferSize: 1_024, format: format) {
        buffer, _ in
        HLMRingWriteAnalyzed(newAnalysisRing, buffer.audioBufferList, buffer.frameLength)
      }
      analysisTapInstalled = true
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
      equalizer = newEqualizer
      peakLimiter = newPeakLimiter
      safetyTrim = newSafetyTrim
      isRunning = true
    } catch {
      newEngine.stop()
      if analysisTapInstalled {
        newSafetyTrim.removeTap(onBus: 0)
        analysisTapInstalled = false
      }
      newEngine.detach(newSafetyTrim)
      newEngine.detach(newPeakLimiter)
      newEngine.detach(newEqualizer)
      cleanupCoreAudioObjects()
      throw error
    }
  }

  func stop() {
    engine?.stop()
    stopCapture()
    if analysisTapInstalled {
      safetyTrim?.removeTap(onBus: 0)
      analysisTapInstalled = false
    }
    if let safetyTrim, let engine {
      engine.detach(safetyTrim)
    }
    if let peakLimiter, let engine {
      engine.detach(peakLimiter)
    }
    if let equalizer, let engine {
      engine.detach(equalizer)
    }
    if let sourceNode, let engine {
      engine.detach(sourceNode)
    }
    engine = nil
    equalizer = nil
    peakLimiter = nil
    safetyTrim = nil
    sourceNode = nil
    isRunning = false
    cleanupCoreAudioObjects()
  }

  func apply(profile: EQProfile?, userGain: Float = 0) {
    guard let equalizer else { return }
    configure(equalizer, with: profile, userGain: userGain)
  }

  func setPeakLimiter(_ enabled: Bool) {
    guard let peakLimiter, let safetyTrim else { return }
    configurePeakLimiter(peakLimiter, safetyTrim: safetyTrim, enabled: enabled)
  }

  func spectrumSnapshot() -> SpectrumSnapshot? {
    guard let analysisRing else { return nil }
    return spectrumAnalyzer.snapshot(from: analysisRing, sampleRate: analysisSampleRate)
  }

  private func configure(
    _ equalizer: AVAudioUnitEQ,
    with profile: EQProfile?,
    userGain: Float
  ) {
    guard let profile else {
      equalizer.globalGain = userGain
      for band in equalizer.bands { band.bypass = true }
      return
    }
    profile.configure(equalizer, userGain: userGain)
  }

  private func configurePeakLimiter(
    _ limiter: AVAudioUnitEffect,
    safetyTrim: AVAudioUnitEQ,
    enabled: Bool
  ) {
    AudioUnitSetParameter(
      limiter.audioUnit,
      kLimiterParam_AttackTime,
      kAudioUnitScope_Global,
      0,
      0.001,
      0
    )
    AudioUnitSetParameter(
      limiter.audioUnit,
      kLimiterParam_DecayTime,
      kAudioUnitScope_Global,
      0,
      0.04,
      0
    )
    AudioUnitSetParameter(
      limiter.audioUnit,
      kLimiterParam_PreGain,
      kAudioUnitScope_Global,
      0,
      0,
      0
    )
    limiter.auAudioUnit.shouldBypassEffect = !enabled
    safetyTrim.globalGain = enabled ? -0.3 : 0
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
    if let analysisRing {
      HLMRingDestroy(analysisRing)
      self.analysisRing = nil
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
