import AudioBridge
import Foundation
import XCTest
@testable import HeadphoneEQ

final class SpeakerCabinetTests: XCTestCase {
  func testCabinetPreservesOnAxisSoundAndBassWrapsAround() {
    let signal: [Float] = [1,-0.25,0.5,0,-0.1]
    XCTAssertEqual(SpeakerCabinet.filter(signal,cosine:1),signal)
    for frequency: Float in [20,125,1000,4000,20_000] {
      XCTAssertEqual(SpeakerCabinet.magnitude(cosine:1,frequency:frequency),1,accuracy:0.000001)
      var previous: Float = 0
      for i in 0...100 {
        let response = SpeakerCabinet.magnitude(cosine:Float(i)/50-1,frequency:frequency)
        XCTAssertGreaterThanOrEqual(response+0.000001,previous)
        XCTAssertLessThanOrEqual(response,1.000001)
        previous = response
      }
    }
    XCTAssertGreaterThan(SpeakerCabinet.magnitude(cosine:-1,frequency:30),0.99)
    XCTAssertLessThan(SpeakerCabinet.magnitude(cosine:-1,frequency:4000),0.25)
    XCTAssertGreaterThan(SpeakerCabinet.magnitude(cosine:-1,frequency:125),
                         SpeakerCabinet.magnitude(cosine:-1,frequency:1000))
  }

  func testVisualPolarResponseMatchesActualCausalFilter() {
    for cosine: Float in [-1,-0.75,-0.2,0,0.4,0.9,1] {
      let impulse = SpeakerCabinet.filter([1],cosine:cosine)
      XCTAssertTrue(impulse.allSatisfy(\.isFinite))
      XCTAssertEqual(impulse.reduce(0,+),1,accuracy:0.00001)
      for frequency: Float in [20,125,1000,4000,15_000] {
        let omega = 2*Float.pi*frequency/48_000
        var re: Float = 0, im: Float = 0
        for (i,sample) in impulse.enumerated() {
          re += sample*cos(omega*Float(i)); im -= sample*sin(omega*Float(i))
        }
        XCTAssertEqual(sqrt(re*re+im*im),SpeakerCabinet.magnitude(cosine:cosine,frequency:frequency),accuracy:0.00001)
      }
      let cached = SpeakerCabinet.bandMagnitudes(cosine:cosine)
      for (actual,frequency): (Float,Float) in [(cached.low,125),(cached.mid,1000),(cached.high,4000)] {
        XCTAssertEqual(actual,SpeakerCabinet.magnitude(cosine:cosine,frequency:frequency),accuracy:0.000001)
      }
    }
  }

  func testSourceDirectivityUsesDepartureAngleForAllSixSurfaces() {
    for angle: Float in [15,30,60] {
      var settings = SpatialAudioSettings()
      settings.speakerAngle = angle
      let s = settings.normalized
      let paths = SpatialImpulseBuilder.paths(settings:s)
      for input in 0..<2 {
        let group = paths.filter { $0.input == input }
        let direct = group[0]
        XCTAssertEqual(direct.emissionCosine,1,accuracy:0.000001)
        let source = position(direct)
        // Intersect listener-to-image ray with the actual reflecting plane.
        let surfaces: [(axis:Int,coordinate:Float)] = [
          (1,s.width/2),(1,-s.width/2),(0,0.62*s.depth),(0,-0.38*s.depth),
          (2,-1.2),(2,s.height-1.2)]
        for i in 0..<6 {
          let path = group[i+1], image = position(path)
          let components = [image.x,image.y,image.z]
          let fraction = surfaces[i].coordinate/components[surfaces[i].axis]
          XCTAssertGreaterThan(fraction,0); XCTAssertLessThan(fraction,1)
          let departure = SpatialVector(x:image.x*fraction-source.x,
            y:image.y*fraction-source.y,z:image.z*fraction-source.z).unit
          let expected = -(departure.x*direct.direction.x+departure.y*direct.direction.y)
          XCTAssertEqual(path.emissionCosine,expected,accuracy:0.00001,
            "source \(input), surface \(i), toe-in \(angle)")
          XCTAssertLessThan(path.emissionCosine,1)
        }
      }
    }
  }

  func testLateFieldHasLessOffAxisTreblePowerAndRetainsSideOnlyInput() throws {
    var ratios: [Float] = []
    for frequency: Float in [100,1000,8000] {
      let reference = try XCTUnwrap(HLMSpatialCreate(48_000))
      let cabinet = try XCTUnwrap(HLMSpatialCreate(48_000))
      defer { HLMSpatialDestroy(reference); HLMSpatialDestroy(cabinet) }
      for renderer in [reference,cabinet] {
        let matrix: [Float] = [0,0,0,0] // isolate the actual late FDN
        let state = try XCTUnwrap(matrix.withUnsafeBufferPointer {
          HLMSpatialStateCreate(48_000,$0.baseAddress!,1,true,5,6,2.7,0.65,0.6)
        })
        if renderer == cabinet { SpeakerCabinet.configureLateField(state) }
        HLMSpatialPublish(renderer,state)
        _ = render(renderer,left:[Float](repeating:0,count:4096),right:[Float](repeating:0,count:4096))
      }
      let signal = (0..<72_000).map { sin(2*Float.pi*frequency*Float($0)/48_000)*0.2 }
      let a = render(reference,left:signal,right:signal.map { -$0 })
      let b = render(cabinet,left:signal,right:signal.map { -$0 })
      func energy(_ channels:[[Float]]) -> Float {
        channels.reduce(Float(0)) { sum,channel in sum+channel.suffix(24_000).reduce(0) { $0+$1*$1 } }
      }
      let baseline = energy(a), actual = energy(b)
      XCTAssertGreaterThan(baseline,0.000001)
      XCTAssertGreaterThan(actual,0.000001)
      XCTAssertTrue(b.flatMap { $0 }.allSatisfy(\.isFinite))
      ratios.append(sqrt(actual/baseline))
    }
    XCTAssertGreaterThan(ratios[0],0.95)
    XCTAssertLessThan(ratios[1],0.85)
    XCTAssertLessThan(ratios[2],0.6)
    XCTAssertGreaterThan(ratios[0],ratios[1])
    XCTAssertGreaterThan(ratios[1],ratios[2])
  }

  func testCabinetAudioRemainsFiniteAcrossDeviceRates() throws {
    let db = try HRTFDatabase(profile:.ku100)
    for rate in [44_100.0,48_000,96_000] {
      var s = SpatialAudioSettings()
      s.enabled = true; s.roomAmount = 0.6
      let ir = SpatialImpulseBuilder.build(settings:s,database:db,sampleRate:rate)
      XCTAssertTrue(ir.samples.allSatisfy(\.isFinite))
      XCTAssertGreaterThan(ir.frames,Int((ir.paths.map(\.distance).max()! / 343)*Float(rate)))
      // Both source axes face the listener exactly, even for extreme angles.
      XCTAssertTrue(ir.paths.filter { !$0.reflected }.allSatisfy { abs($0.emissionCosine-1)<0.000001 })
    }
  }

  private func position(_ path:SpatialPath) -> SpatialVector {
    SpatialVector(x:path.direction.x*path.distance,y:path.direction.y*path.distance,z:path.direction.z*path.distance)
  }
  private func render(_ renderer:OpaquePointer,left:[Float],right:[Float]) -> [[Float]] {
    var l = left, r = right
    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
      HLMSpatialProcessPlanar(renderer,lp.baseAddress!,rp.baseAddress!,UInt32(left.count))
    } }
    return [l,r]
  }
}
