import XCTest
@testable import HeadphoneEQ

final class CabinetWavefrontTests: XCTestCase {
  func testTrebleFrontIsVisibleAndRearShadowIsNotAnotherCompleteRing() throws {
    let layer = try XCTUnwrap(CabinetWavefront.layers(band:.high,energy:[]).first)
    let front = SpeakerCabinet.bandMagnitudes(cosine:1)
    let rear = SpeakerCabinet.bandMagnitudes(cosine:-1)
    XCTAssertEqual(layer.opacity(base:0.8,magnitude:front.high),0.8,accuracy:0.000001)
    XCTAssertEqual(layer.opacity(base:0.8,magnitude:rear.high),0)
    let bass = try XCTUnwrap(CabinetWavefront.layers(band:.low,energy:[]).first)
    XCTAssertGreaterThan(bass.opacity(base:0.8,magnitude:rear.low),0.7)
  }

  func testFullViewRetainsBassWrapButMakesForwardMidsAndTrebleDistinct() throws {
    let layers = CabinetWavefront.layers(band:.full,energy:[1,1,1])
    XCTAssertEqual(layers.count,3)
    let bass = layers[0], mid = layers[1], treble = layers[2]
    XCTAssertLessThan(bass.lineWidth,mid.lineWidth)
    XCTAssertLessThan(mid.lineWidth,treble.lineWidth)
    let front = layers.map { $0.opacity(base:0.8,magnitude:1) }
    XCTAssertLessThan(front[0],front[1])
    XCTAssertLessThan(front[1],front[2])
    let rear = SpeakerCabinet.bandMagnitudes(cosine:-1)
    XCTAssertGreaterThan(bass.opacity(base:0.8,magnitude:rear.low),0)
    XCTAssertEqual(treble.opacity(base:0.8,magnitude:rear.high),0)
  }

  func testFrequencyLayersFollowRealSpectrumWithoutInventingMissingBands() throws {
    let bassOnly = CabinetWavefront.layers(band:.full,energy:[1,0,0])
    XCTAssertEqual(bassOnly.map(\.meterIndex),[0])
    let trebleOnly = CabinetWavefront.layers(band:.full,energy:[0,0,1])
    XCTAssertEqual(trebleOnly.map(\.meterIndex),[2])
    let mixed = CabinetWavefront.layers(band:.full,energy:[0,1,3])
    XCTAssertEqual(mixed.map(\.meterIndex),[1,2])
    XCTAssertEqual(mixed[0].weight,0.65*0.5,accuracy:0.000001)
    XCTAssertEqual(mixed[1].weight,sqrt(0.75),accuracy:0.000001)
    for energy: [Float] in [[0,0,0],[.nan,-1,0],[],[1]] {
      XCTAssertTrue(CabinetWavefront.layers(band:.full,energy:energy).isEmpty)
    }
  }

  func testDisplayEnergyFadeAndSurfaceAbsorptionRemainEffective() throws {
    let layer = try XCTUnwrap(CabinetWavefront.layers(band:.mid,energy:[]).first)
    let full = layer.opacity(base:0.8,magnitude:0.8)
    XCTAssertEqual(layer.opacity(base:0.4,magnitude:0.8),full/2,accuracy:0.000001)
    XCTAssertEqual(layer.opacity(base:0.8,magnitude:0.8,surfaceMagnitude:0.5),full/4,accuracy:0.000001)
    XCTAssertEqual(layer.opacity(base:0,magnitude:1),0)
    XCTAssertEqual(layer.opacity(base:1,magnitude:sqrt(0.05)),0,accuracy:0.000001)
    let justAboveFloor = layer.opacity(base:1,magnitude:sqrt(0.051))
    XCTAssertGreaterThan(justAboveFloor,0)
    XCTAssertLessThan(justAboveFloor,0.002)
  }
}
