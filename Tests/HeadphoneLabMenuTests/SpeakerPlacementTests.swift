import XCTest
@testable import HeadphoneEQ

final class SpeakerPlacementTests: XCTestCase {
  func testPlacementFormsAnEquilateralTriangleWithCabinetsAimedAtListener() {
    let placed = SpatialAudioSettings().placingSpeakersOptimally()
    let speakers = SpatialImpulseBuilder.paths(settings:placed).filter { !$0.reflected }
    XCTAssertEqual(placed.speakerAngle,30)
    let positions = speakers.map { SpatialVector(x:$0.direction.x*$0.distance,y:$0.direction.y*$0.distance,z:0) }
    XCTAssertEqual(sqrt(positions[0].squaredDistance(to:positions[1])),placed.speakerDistance,accuracy:0.00001)
    XCTAssertEqual(positions[0].x,positions[1].x)
    XCTAssertEqual(positions[0].y,-positions[1].y)
    XCTAssertTrue(speakers.allSatisfy { abs($0.emissionCosine-1)<0.000001 })
  }

  func testRotatedCabinetsClearWallsAcrossSupportedRoomDimensions() {
    for width: Float in [3,3.5,5,8,12] {
      for depth: Float in [3,3.5,6,10,16] {
        var s = SpatialAudioSettings()
        s.width = width; s.depth = depth
        s = s.placingSpeakersOptimally()
        XCTAssertGreaterThanOrEqual(s.speakerDistance,0.6)
        XCTAssertLessThanOrEqual(s.speakerDistance,s.maximumSpeakerDistance)
        for speaker in SpatialImpulseBuilder.paths(settings:s) where !speaker.reflected {
          let axis = speaker.emissionAxis
          let front = SpatialVector(x:speaker.direction.x*speaker.distance,y:speaker.direction.y*speaker.distance,z:0)
          // All four physical cabinet corners, including toe-in rotation.
          for back: Float in [0,SpeakerCabinet.depth] {
            for side in [-SpeakerCabinet.width/2,SpeakerCabinet.width/2] {
              let x = front.x-axis.x*back-axis.y*side
              let y = front.y-axis.y*back+axis.x*side
              XCTAssertLessThanOrEqual(x,0.62*depth-0.5+0.00001)
              XCTAssertGreaterThanOrEqual(x,-0.38*depth+0.5-0.00001)
              XCTAssertLessThanOrEqual(abs(y),width/2-0.5+0.00001)
            }
          }
        }
      }
    }
  }

  func testPlacementUsesRoomSizeAndPreservesOtherControls() {
    var original = SpatialAudioSettings()
    original.enabled = true; original.hrtf = .listenerH10
    original.treatment = 0.4; original.roomAmount = 0.6; original.height = 4
    original.speakerAngle = 57; original.speakerDistance = 0.7
    let placed = original.placingSpeakersOptimally()
    var expected = original
    expected.speakerAngle = placed.speakerAngle; expected.speakerDistance = placed.speakerDistance
    XCTAssertEqual(placed,expected)
    XCTAssertEqual(placed.placingSpeakersOptimally(),placed)
    var small = original; small.width = 3; small.depth = 3
    var wideShallow = original; wideShallow.width = 12; wideShallow.depth = 3
    var narrowDeep = original; narrowDeep.width = 3; narrowDeep.depth = 16
    var large = original; large.width = 12; large.depth = 16
    XCTAssertLessThan(small.placingSpeakersOptimally().speakerDistance,placed.speakerDistance)
    XCTAssertLessThan(wideShallow.placingSpeakersOptimally().speakerDistance,placed.speakerDistance)
    XCTAssertLessThan(narrowDeep.placingSpeakersOptimally().speakerDistance,placed.speakerDistance)
    XCTAssertGreaterThan(large.placingSpeakersOptimally().speakerDistance,placed.speakerDistance)
    XCTAssertEqual(large.placingSpeakersOptimally().speakerDistance,3.5)
  }

  func testAutomaticPlacementTracksDimensionsWithoutLosingItsMode() {
    var s = SpatialAudioSettings()
    s.automaticPlacement = true
    s = s.normalized
    let initial = s.speakerDistance
    s.width = 12; s.depth = 16
    s = s.normalized
    XCTAssertTrue(s.automaticPlacement)
    XCTAssertGreaterThan(s.speakerDistance,initial)
    XCTAssertEqual(s.speakerDistance,3.5)
    s.width = 3; s.depth = 3
    // Simulate old dial values arriving with the new room dimensions.
    s.speakerAngle = 50; s.speakerDistance = 3.5
    s = s.normalized
    XCTAssertTrue(s.automaticPlacement)
    XCTAssertEqual(s.speakerAngle,30)
    XCTAssertEqual(s.speakerDistance,1.2,accuracy:0.00001)
    XCTAssertEqual(s.normalized,s)
    s.height = 5; s.treatment = 0.9; s.roomAmount = 0.5; s.hrtf = .kemar
    let changed = s.normalized
    XCTAssertTrue(changed.automaticPlacement)
    XCTAssertEqual(changed.speakerDistance,s.speakerDistance)
    XCTAssertEqual(changed.hrtf,.kemar)
    XCTAssertEqual(changed.roomAmount,0.5)
  }

  func testAutomaticModePersistsAndOlderSavedRoomsKeepManualSettings() throws {
    var s = SpatialAudioSettings()
    s.automaticPlacement = true; s.width = 8; s.depth = 4
    s = s.normalized
    let encoded = try JSONEncoder().encode(s)
    let restored = try JSONDecoder().decode(SpatialAudioSettings.self,from:encoded).normalized
    XCTAssertEqual(restored,s)
    XCTAssertTrue(restored.automaticPlacement)
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
    legacy.removeValue(forKey:"automaticPlacement")
    legacy["speakerAngle"] = 42; legacy["speakerDistance"] = 1.7
    let oldRoom = try JSONDecoder().decode(SpatialAudioSettings.self,
      from:JSONSerialization.data(withJSONObject:legacy)).normalized
    XCTAssertFalse(oldRoom.automaticPlacement)
    XCTAssertEqual(oldRoom.speakerAngle,42)
    XCTAssertEqual(oldRoom.speakerDistance,1.7)
    XCTAssertEqual(oldRoom.width,8); XCTAssertEqual(oldRoom.depth,4)
  }

  func testTurningAutomaticPlacementOffKeepsCurrentPositionsAndAllowsManualChanges() {
    var s = SpatialAudioSettings()
    s.automaticPlacement = true; s = s.normalized
    let distance = s.speakerDistance
    s.automaticPlacement = false; s.width = 12; s.depth = 16
    s = s.normalized
    XCTAssertFalse(s.automaticPlacement)
    XCTAssertEqual(s.speakerDistance,distance)
    s.speakerAngle = 44; s.speakerDistance = 2.8
    s = s.normalized
    XCTAssertEqual(s.speakerAngle,44)
    XCTAssertEqual(s.speakerDistance,2.8)
  }

  func testPlacementNormalizesInvalidRoomInput() {
    var s = SpatialAudioSettings()
    s.width = .nan; s.depth = -.infinity; s.speakerAngle = .nan; s.speakerDistance = .infinity
    let result = s.placingSpeakersOptimally()
    XCTAssertEqual(result.width,5); XCTAssertEqual(result.depth,6)
    XCTAssertTrue(result.speakerDistance.isFinite)
    XCTAssertEqual(result,result.normalized)
  }
}
