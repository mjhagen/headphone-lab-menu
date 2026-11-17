import AudioBridge
import AVFoundation
import XCTest
@testable import HeadphoneEQ

final class SpatialAudioTests: XCTestCase {
  func testAllBundledProfilesHaveValidDirectionalAndTimingData() throws {
    for profile in HRTFProfile.allCases {
      let database = try HRTFDatabase(profile: profile)
      XCTAssertGreaterThan(database.measurements.count, 350)
      let left = database.interpolate(direction: SpatialVector(x: 0, y: 1, z: 0))
      let right = database.interpolate(direction: SpatialVector(x: 0, y: -1, z: 0))
      // The ipsilateral ear must receive lateral sound before the opposite ear.
      XCTAssertLessThan(left.peaks[0], left.peaks[1], profile.title)
      XCTAssertLessThan(right.peaks[1], right.peaks[0], profile.title)
      XCTAssertGreaterThan(left.ears[0].map { $0*$0 }.reduce(0,+), 0.01)
      XCTAssertEqual(left.ears[0].count, 512)
    }
  }

  func testGeometryGivesTwoSpeakersAndSixLongerDirectionalReflectionsEach() {
    let settings = SpatialAudioSettings()
    let paths = SpatialImpulseBuilder.paths(settings: settings)
    XCTAssertEqual(paths.count, 14)
    for input in 0..<2 {
      let group = paths.filter { $0.input == input }
      let direct = group.first!
      XCTAssertFalse(direct.reflected)
      XCTAssertEqual(direct.distance, settings.speakerDistance, accuracy: 0.0001)
      XCTAssertEqual(direct.direction.y, input == 0 ? 0.5 : -0.5, accuracy: 0.0001)
      for reflected in group.dropFirst() {
        XCTAssertTrue(reflected.reflected)
        XCTAssertGreaterThan(reflected.distance, direct.distance)
        XCTAssertLessThan(reflected.gain, direct.gain)
      }
      XCTAssertLessThan(group[5].direction.z, 0)
      XCTAssertGreaterThan(group[6].direction.z, 0)
    }
    var bigger = settings
    bigger.width = 9
    let expanded = SpatialImpulseBuilder.paths(settings: bigger)
    XCTAssertGreaterThan(expanded[1].distance, paths[1].distance)
  }

  func testInvalidPreferencesAreBoundedAndSpeakersStayInsideRoom() {
    var s = SpatialAudioSettings()
    s.width = .nan
    s.depth = -.infinity
    s.treatment = 3
    s.roomAmount = -1
    s.speakerDistance = 100
    s.speakerAngle = 60
    s = s.normalized
    XCTAssertEqual(s.width, 5)
    XCTAssertEqual(s.depth, 6)
    XCTAssertEqual(s.treatment, 1)
    XCTAssertEqual(s.roomAmount, 0)
    XCTAssertLessThanOrEqual(s.speakerDistance, s.maximumSpeakerDistance)
    for path in SpatialImpulseBuilder.paths(settings: s) where !path.reflected {
      XCTAssertLessThan(abs(path.direction.y*path.distance), s.width/2)
      XCTAssertLessThan(path.direction.x*path.distance, s.depth*0.62)
    }
    XCTAssertEqual(try? JSONDecoder().decode(SpatialAudioSettings.self,
      from: JSONEncoder().encode(s)), s)
  }

  func testResampledFilterPreservesGainAndSuppressesAliasing() {
    let input = (0..<512).map { index -> Float in
      index == 180 ? 1 : 0
    }
    for ratio in [44_100.0/48_000, 2, 4] {
      let output = SpatialImpulseBuilder.resample(input, ratio: ratio)
      XCTAssertEqual(output.reduce(0,+), 1, accuracy: 0.02)
      let peak = output.indices.max(by: { abs(output[$0]) < abs(output[$1]) })!
      XCTAssertEqual(Double(peak), 180*ratio, accuracy: 1)
    }
    let high = (0..<1024).map { Float(cos(2*Double.pi*22_000*Double($0)/48_000)) }
    let down = SpatialImpulseBuilder.resample(high, ratio: 32_000.0/48_000)
    let middle = down.dropFirst(60).dropLast(60)
    let rms = sqrt(middle.reduce(Float(0)) { $0+$1*$1 }/Float(middle.count))
    XCTAssertLessThan(rms, 0.02)
  }

  func testMatrixConvolutionMatchesDirectReferenceAcrossPartitionsAndCallbackSizes() throws {
    let renderer = try XCTUnwrap(HLMSpatialCreate(48_000))
    defer { HLMSpatialDestroy(renderer) }
    let frames = 410
    var matrix = [Float](repeating: 0, count: 4*frames)
    matrix[0] = 0.7
    matrix[129] = -0.13
    matrix[frames+7] = 0.23
    matrix[frames+300] = 0.11
    matrix[2*frames+191] = -0.17
    matrix[3*frames] = 0.6
    matrix[3*frames+409] = 0.09
    try publish(renderer, matrix: matrix, frames: frames, enabled: true)
    // Complete the transition before injecting the verification signal.
    _ = process(renderer, left: [Float](repeating: 0, count: 4096),
      right: [Float](repeating: 0, count: 4096), chunks: [17,511,1,128])
    let left = (0..<1000).map { Float(sin(Double($0)*0.31))*0.2 }
    let right = (0..<1000).map { Float(cos(Double($0)*0.17))*0.15 }
    let tail = [Float](repeating: 0, count: 700)
    let result = process(renderer, left: left+tail, right: right+tail, chunks: [1,7,129,256,73])
    var expected = Array(repeating: [Float](repeating: 0, count: 1700), count: 2)
    for input in 0..<2 {
      let source = input == 0 ? left : right
      for ear in 0..<2 {
        for tap in 0..<frames where matrix[(input*2+ear)*frames+tap] != 0 {
          let gain = matrix[(input*2+ear)*frames+tap]
          for n in source.indices {
            expected[ear][128+n+tap] += source[n]*gain
          }
        }
      }
    }
    for ear in 0..<2 {
      for n in 0..<1700 {
        XCTAssertEqual(result[ear][n], expected[ear][n], accuracy: 0.00001,
          "ear \(ear), sample \(n)")
      }
    }
  }

  func testBypassIsUnityWithFixedLatencyAndNoChannelMixing() throws {
    let renderer = try XCTUnwrap(HLMSpatialCreate(44_100))
    defer { HLMSpatialDestroy(renderer) }
    let left: [Float] = [0.1,-0.7,0.4] + Array(repeating: 0, count: 200)
    let right: [Float] = [-0.2,0.3,-0.8] + Array(repeating: 0, count: 200)
    let result = process(renderer, left: left, right: right, chunks: [31,1,170])
    XCTAssertEqual(HLMSpatialLatencyFrames(), 128)
    for i in 0..<203 {
      XCTAssertEqual(result[0][i], i < 128 ? 0 : left[i-128])
      XCTAssertEqual(result[1][i], i < 128 ? 0 : right[i-128])
    }
  }

  func testTreatmentReducesLateEnergyAndPreservesSideOnlyExcitation() throws {
    func tail(treatment: Float) throws -> [[Float]] {
      let renderer = try XCTUnwrap(HLMSpatialCreate(48_000))
      defer { HLMSpatialDestroy(renderer) }
      try publish(renderer, matrix: [0,0,0,0], frames: 1, enabled: true,
        treatment: treatment, amount: 0.5)
      _ = process(renderer, left: .init(repeating: 0, count: 4096),
        right: .init(repeating: 0, count: 4096))
      var left = [Float](repeating: 0, count: 96_000)
      var right = left
      left[0] = 1
      right[0] = -1
      return process(renderer, left: left, right: right)
    }
    let bare = try tail(treatment: 0)
    let treated = try tail(treatment: 1)
    func energy(_ signal: [[Float]], _ range: Range<Int>) -> Float {
      signal.reduce(0) { sum, ear in sum + range.reduce(0) { $0+ear[$1]*ear[$1] } }
    }
    XCTAssertGreaterThan(energy(bare, 0..<20_000), 0.0001)
    XCTAssertLessThan(energy(treated, 14_000..<96_000), energy(bare, 14_000..<96_000)*0.1)
    XCTAssertLessThan(energy(bare, 80_000..<96_000), energy(bare, 1000..<17_000)*0.01)
    XCTAssertNotEqual(bare[0], bare[1])
  }

  func testRealProfilesProduceFiniteBinauralOutputAtDeviceSampleRates() throws {
    let database = try HRTFDatabase(profile: .ku100)
    for rate in [44_100.0, 48_000, 96_000, 192_000] {
      var s = SpatialAudioSettings()
      s.enabled = true
      let impulse = SpatialImpulseBuilder.build(settings: s, database: database, sampleRate: rate)
      XCTAssertTrue(impulse.samples.allSatisfy(\.isFinite))
      let renderer = try XCTUnwrap(HLMSpatialCreate(rate))
      defer { HLMSpatialDestroy(renderer) }
      try publish(renderer, matrix: impulse.samples, frames: impulse.frames, enabled: true, sampleRate: rate)
      _ = process(renderer, left: .init(repeating: 0, count: Int(rate*0.07)),
        right: .init(repeating: 0, count: Int(rate*0.07)))
      var source = [Float](repeating: 0, count: Int(rate*0.15))
      source[0] = 1
      let result = process(renderer, left: source, right: .init(repeating: 0, count: source.count))
      XCTAssertTrue(result.flatMap { $0 }.allSatisfy(\.isFinite))
      let peakL = result[0].indices.max { abs(result[0][$0]) < abs(result[0][$1]) }!
      let peakR = result[1].indices.max { abs(result[1][$0]) < abs(result[1][$1]) }!
      XCTAssertLessThan(peakL, peakR, "L speaker timing at \(rate)")
      XCTAssertGreaterThan(result[1].map { $0*$0 }.reduce(0,+), 0.001)
    }
  }

  func testLiveUpdatesCrossfadeAndRejectNonFiniteKernels() throws {
    let renderer = try XCTUnwrap(HLMSpatialCreate(48_000))
    defer { HLMSpatialDestroy(renderer) }
    _ = process(renderer, left: .init(repeating: 0.2, count: 512),
      right: .init(repeating: -0.2, count: 512))
    for gain: Float in [0.3,0.7,0.1,1,0.5] {
      try publish(renderer, matrix: [gain,0,0,gain], frames: 1, enabled: true)
      let result = process(renderer, left: .init(repeating: 0.2, count: 3000),
        right: .init(repeating: -0.2, count: 3000), chunks: [19,313,7])
      for i in 1..<result[0].count {
        XCTAssertLessThan(abs(result[0][i]-result[0][i-1]), 0.002)
      }
      XCTAssertEqual(result[0].last!, 0.2*gain, accuracy: 0.00001)
      XCTAssertEqual(result[1].last!, -0.2*gain, accuracy: 0.00001)
    }
    let bad: [Float] = [.nan,0,0,1]
    XCTAssertNil(bad.withUnsafeBufferPointer {
      HLMSpatialStateCreate(48_000, $0.baseAddress!, 1, true, 5,6,2.7,0.5,0.2)
    })
    XCTAssertNil(HLMSpatialCreate(.nan))
    HLMSpatialCollect(renderer)
  }

  func testTreatmentChangesReflectionsWithoutChangingDirectSpeakers() throws {
    let database = try HRTFDatabase(profile: .kemar)
    var s = SpatialAudioSettings()
    s.enabled = true
    s.roomAmount = 0
    let direct = SpatialImpulseBuilder.build(settings: s, database: database, sampleRate: 48_000)
    s.roomAmount = 0.6
    s.treatment = 0
    let bare = SpatialImpulseBuilder.build(settings: s, database: database, sampleRate: 48_000)
    s.treatment = 1
    let treated = SpatialImpulseBuilder.build(settings: s, database: database, sampleRate: 48_000)
    func reflectedEnergy(_ impulse: SpatialImpulseResponse) -> Float {
      zip(impulse.samples, direct.samples).reduce(0) {
        let delta = $1.0-$1.1
        return $0+delta*delta
      }
    }
    XCTAssertLessThan(reflectedEnergy(treated), reflectedEnergy(bare)*0.7)
    let originalPaths = bare.paths.filter { !$0.reflected }
    let treatedPaths = treated.paths.filter { !$0.reflected }
    XCTAssertEqual(originalPaths.map(\.gain), treatedPaths.map(\.gain))
    XCTAssertEqual(originalPaths.map(\.distance), treatedPaths.map(\.distance))
  }

  func testPendingReplacementAndInterleavedRendering() throws {
    let renderer = try XCTUnwrap(HLMSpatialCreate(48_000))
    let planar = try XCTUnwrap(HLMSpatialCreate(48_000))
    defer { HLMSpatialDestroy(renderer); HLMSpatialDestroy(planar) }
    for i in 1...40 {
      let gain = Float(i)/80
      try publish(renderer, matrix: [gain,0.1,-0.1,gain], frames: 1, enabled: true)
    }
    try publish(planar, matrix: [0.5,0.1,-0.1,0.5], frames: 1, enabled: true)
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
      sampleRate: 48_000, channels: 2, interleaved: true))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192))
    buffer.frameLength = 8192
    let samples = try XCTUnwrap(buffer.mutableAudioBufferList.pointee.mBuffers.mData?
      .assumingMemoryBound(to: Float.self))
    let left = (0..<8192).map { Float(sin(Double($0)*0.05))*0.2 }
    let right = (0..<8192).map { Float(cos(Double($0)*0.03))*0.2 }
    for i in 0..<8192 { samples[2*i] = left[i]; samples[2*i+1] = right[i] }
    HLMSpatialProcess(renderer, buffer.mutableAudioBufferList, buffer.frameLength)
    let expected = process(planar, left: left, right: right, chunks: [8192])
    for i in 0..<8192 {
      XCTAssertEqual(samples[2*i], expected[0][i], accuracy: 0.00001)
      XCTAssertEqual(samples[2*i+1], expected[1][i], accuracy: 0.00001)
    }
  }

  func testControlQueueCanPublishWhileAudioRenders() throws {
    let renderer = try SpatialAudioRenderer(sampleRate: 48_000, settings: SpatialAudioSettings())
    let updates = expectation(description: "All queued room changes prepared")
    updates.expectedFulfillmentCount = 12
    for i in 0..<12 {
      var s = SpatialAudioSettings()
      s.enabled = true
      s.hrtf = HRTFProfile.allCases[i%3]
      s.width = 3+Float(i)*0.5
      renderer.update(s) { error in
        XCTAssertNil(error)
        updates.fulfill()
      }
    }
    let input = (0..<96_000).map { Float(sin(Double($0)*0.07))*0.1 }
    let result = process(renderer.handle, left: input, right: input, chunks: [128,17,511])
    XCTAssertTrue(result.flatMap { $0 }.allSatisfy(\.isFinite))
    wait(for: [updates], timeout: 10)
    let settled = process(renderer.handle, left: input, right: input)
    XCTAssertTrue(settled.flatMap { $0 }.allSatisfy(\.isFinite))
  }

  private func publish(_ renderer: OpaquePointer, matrix: [Float], frames: Int,
                       enabled: Bool, treatment: Float = 0.65, amount: Float = 0,
                       sampleRate: Double = 48_000) throws {
    let state = matrix.withUnsafeBufferPointer {
      HLMSpatialStateCreate(sampleRate, $0.baseAddress!, UInt32(frames), enabled,
        5,6,2.7,treatment,amount)
    }
    HLMSpatialPublish(renderer, try XCTUnwrap(state))
  }

  private func process(_ renderer: OpaquePointer, left: [Float], right: [Float],
                       chunks: [Int] = [512]) -> [[Float]] {
    var l = left, r = right
    l.withUnsafeMutableBufferPointer { lp in
      r.withUnsafeMutableBufferPointer { rp in
        var position = 0, chunk = 0
        while position < left.count {
          let count = min(chunks[chunk%chunks.count], left.count-position)
          HLMSpatialProcessPlanar(renderer, lp.baseAddress!+position, rp.baseAddress!+position, UInt32(count))
          position += count
          chunk += 1
        }
      }
    }
    return [l,r]
  }
}
