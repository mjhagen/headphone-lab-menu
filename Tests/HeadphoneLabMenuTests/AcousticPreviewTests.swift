import XCTest
@testable import HeadphoneEQ

final class AcousticPreviewTests: XCTestCase {
  func testSphericalWavefrontIncludesVerticalReflectionDelay() throws {
    let direct = AcousticWavefront(source: 0, image: SpatialVector(x: 1,y: 0,z: 0),
      reflected: false, listenerDistance: 1, listenerGain: 0.5)
    XCTAssertEqual(try XCTUnwrap(direct.radius(at: 3.0/343)), 3, accuracy: 0.0001)
    let floor = AcousticWavefront(source: 0, image: SpatialVector(x: 1,y: 0,z: -2.4),
      reflected: true, listenerDistance: 2.6, listenerGain: 0.1)
    XCTAssertNil(floor.radius(at: 2.0/343))
    XCTAssertEqual(try XCTUnwrap(floor.radius(at: 3.0/343)), 1.8, accuracy: 0.0001)
  }

  func testEarPeakTimesMatchMeasuredHRTFAndSoundTravel() async throws {
    var settings = SpatialAudioSettings()
    settings.enabled = true
    settings.roomAmount = 0
    let engine = AcousticPreviewEngine()
    let probe = try await engine.snapshot(settings: settings, source: .left, band: .mid)
    let direct = try XCTUnwrap(SpatialImpulseBuilder.paths(settings: settings).first)
    let hrtf = try HRTFDatabase(profile: settings.hrtf).interpolate(direction: direct.direction)
    for ear in 0..<2 {
      let expected = Double(direct.distance/343)+Double(hrtf.peaks[ear])/48_000
      XCTAssertEqual(probe.earPeakTimes[ear], expected, accuracy: 2.0/48_000)
    }
    XCTAssertLessThan(probe.earPeakTimes[0], probe.earPeakTimes[1])
    XCTAssertEqual(probe.wavefronts.count, 7)
    XCTAssertTrue(probe.wavefronts.allSatisfy { $0.source == 0 })
    let right = try await engine.snapshot(settings: settings, source: .right, band: .mid)
    XCTAssertLessThan(right.earPeakTimes[1], right.earPeakTimes[0])
  }

  func testTreatmentAndFrequencyAffectActualRenderedDecay() async throws {
    let engine = AcousticPreviewEngine()
    var settings = SpatialAudioSettings()
    settings.enabled = true
    settings.roomAmount = 0.6
    settings.treatment = 0
    let bare = try await engine.snapshot(settings: settings, source: .stereo, band: .mid)
    settings.treatment = 1
    let treated = try await engine.snapshot(settings: settings, source: .stereo, band: .mid)
    XCTAssertEqual(bare.wavefronts.count, 14)
    XCTAssertGreaterThan(bare.lateEnergy, 0)
    XCTAssertLessThan(treated.lateEnergy, bare.lateEnergy*0.7)
    XCTAssertLessThan(treated.surfaceMagnitude, bare.surfaceMagnitude)
    for curve in [bare.decay,treated.decay] {
      XCTAssertEqual(curve.first, 0)
      XCTAssertTrue(curve.allSatisfy { $0.isFinite && $0 >= -60 && $0 <= 0 })
      for i in 1..<curve.count { XCTAssertLessThanOrEqual(curve[i],curve[i-1]+0.00001) }
    }
    let low = SpatialImpulseBuilder.reflectionMagnitude(treatment: 1, frequency: 125)
    let high = SpatialImpulseBuilder.reflectionMagnitude(treatment: 1, frequency: 4000)
    XCTAssertGreaterThan(low,high)
    let alternative = try await engine.snapshot(settings: settings, source: .stereo, band: .high)
    XCTAssertNotEqual(alternative.decay,treated.decay)
    XCTAssertEqual(alternative.early[0].map(\.maximum),treated.early[0].map(\.maximum))
  }

  func testHRTFSelectionChangesEarResponseAndBypassRemovesRoom() async throws {
    let engine = AcousticPreviewEngine()
    var settings = SpatialAudioSettings()
    settings.enabled = true
    let ku100 = try await engine.snapshot(settings: settings, source: .left, band: .high)
    settings.hrtf = .kemar
    let kemar = try await engine.snapshot(settings: settings, source: .left, band: .high)
    XCTAssertNotEqual(ku100.early[0].map(\.maximum),kemar.early[0].map(\.maximum))
    settings.enabled = false
    let bypass = try await engine.snapshot(settings: settings, source: .stereo, band: .mid)
    XCTAssertEqual(bypass.earPeakTimes,[0,0])
    XCTAssertLessThan(bypass.lateEnergy,0.0000001)
  }
}
