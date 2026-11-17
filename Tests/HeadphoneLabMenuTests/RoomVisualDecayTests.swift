import AudioBridge
import XCTest
@testable import HeadphoneEQ

final class RoomVisualDecayTests: XCTestCase {
  func testSharedAudioDecayReachesMinusSixtyDecibels() {
    let settings = SpatialAudioSettings()
    let profile = settings.decayTimes
    let audio = HLMSpatialRoomDecayTimes(settings.width,settings.depth,settings.height,settings.treatment)
    XCTAssertEqual(profile.low,audio.low)
    XCTAssertEqual(profile.mid,audio.mid)
    XCTAssertEqual(profile.high,audio.high)
    for band in [LiveAudioBand.low,.mid,.high] {
      XCTAssertEqual(profile.amplitude(after:Double(profile.time(for:band)),band:band,energy:[]),0.001,accuracy:0.000001)
      XCTAssertEqual(profile.amplitude(after:-1,band:band,energy:[]),1)
    }
  }

  func testRoomSizeTreatmentAndMeasuredSpectrumChangeFade() {
    var settings = SpatialAudioSettings()
    settings.treatment = 0
    let bare = settings.decayTimes
    settings.treatment = 1
    let treated = settings.decayTimes
    for band in [LiveAudioBand.low,.mid,.high] {
      XCTAssertLessThan(treated.time(for:band),bare.time(for:band))
      XCTAssertLessThan(treated.amplitude(after:0.05,band:band,energy:[]),
                        bare.amplitude(after:0.05,band:band,energy:[]))
    }
    settings.width = 12; settings.depth = 16; settings.height = 5
    XCTAssertGreaterThan(settings.decayTimes.mid,treated.mid)
    let bass = treated.amplitude(after:0.05,band:.full,energy:[1,0,0])
    let treble = treated.amplitude(after:0.05,band:.full,energy:[0,0,1])
    XCTAssertEqual(bass,treated.amplitude(after:0.05,band:.low,energy:[]),accuracy:0.000001)
    XCTAssertEqual(treble,treated.amplitude(after:0.05,band:.high,energy:[]),accuracy:0.000001)
    XCTAssertGreaterThan(bass,treble)
    let mixed = treated.amplitude(after:0.05,band:.full,energy:[1,0,1])
    XCTAssertEqual(mixed,sqrt((bass*bass+treble*treble)/2),accuracy:0.000001)
  }

  func testDirectFrontRetiresSmoothlyOnlyAfterListenerArrival() {
    let arrival = Double(Float(1.5)/343)
    XCTAssertEqual(RoomVisualDecay.directEnvelope(age:0,distance:1.5),1)
    XCTAssertEqual(RoomVisualDecay.directEnvelope(age:arrival,distance:1.5),1)
    XCTAssertEqual(RoomVisualDecay.directEnvelope(age:arrival+0.0025,distance:1.5),0.5,accuracy:0.000001)
    XCTAssertEqual(RoomVisualDecay.directEnvelope(age:arrival+0.006,distance:1.5),0)
  }

  func testReflectionFadeStartsAtItsFirstWallContact() throws {
    let settings = SpatialAudioSettings()
    let paths = SpatialImpulseBuilder.paths(settings:settings)
    let source = try XCTUnwrap(paths.first { $0.input == 0 && !$0.reflected })
    let wall = try XCTUnwrap(paths.first { $0.input == 0 && $0.reflected })
    let dx = wall.direction.x*wall.distance-source.direction.x*source.distance
    let dy = wall.direction.y*wall.distance-source.direction.y*source.distance
    let dz = wall.direction.z*wall.distance-source.direction.z*source.distance
    let contact = Double(sqrt(dx*dx+dy*dy+dz*dz)/2/343)
    let profile = settings.decayTimes
    func envelope(_ t:Double) -> Float {
      RoomVisualDecay.reflectedEnvelope(age:t,path:wall,source:source,profile:profile,band:.mid,energy:[])
    }
    XCTAssertEqual(envelope(0),1)
    XCTAssertEqual(envelope(contact),1,accuracy:0.000001)
    XCTAssertEqual(envelope(contact+Double(profile.mid)),0.001,accuracy:0.000001)
  }
}
