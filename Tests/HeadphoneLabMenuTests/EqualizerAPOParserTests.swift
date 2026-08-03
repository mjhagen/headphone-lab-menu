import AVFoundation
import XCTest

@testable import HeadphoneEQ

final class EqualizerAPOParserTests: XCTestCase {
  func testParsesAutoEQParametricProfile() throws {
    let profile = try EqualizerAPOParser.parse(
      """
      # AutoEq profile
      Preamp: -6.4 dB
      Filter 1: ON PK Fc 31 Hz Gain 4.2 dB Q 0.50
      Filter 2: ON LS Fc 105 Hz Gain 3.0 dB Q 0.71
      Filter 3: OFF PK Fc 900 Hz Gain -1.0 dB Q 2.0
      Filter 4: ON HS Fc 10000 Hz Gain -2.5 dB BW Oct 1.5
      """,
      name: "HD 25"
    )

    XCTAssertEqual(profile.name, "HD 25")
    XCTAssertEqual(profile.preamp, -6.4)
    XCTAssertEqual(profile.filters.count, 3)
    XCTAssertEqual(profile.filters[0].kind, .parametric)
    XCTAssertEqual(profile.filters[0].frequency, 31)
    XCTAssertEqual(profile.filters[0].gain, 4.2)
    XCTAssertEqual(profile.filters[1].kind, .lowShelf)
    XCTAssertEqual(profile.filters[2].kind, .highShelf)
    XCTAssertEqual(profile.filters[2].bandwidth, 1.5)
  }

  func testAddsMultiplePreamps() throws {
    let profile = try EqualizerAPOParser.parse(
      """
      Preamp: -3 dB
      Preamp: -2.5 dB
      Filter: ON HPQ Fc 20 Hz Q 0.7
      """,
      name: "Combined"
    )
    XCTAssertEqual(profile.preamp, -5.5)
    XCTAssertEqual(profile.filters[0].kind, .highPass)
  }

  func testUsesEqualizerAPODefaultsAndIgnoresProseHeaders() throws {
    let profile = try EqualizerAPOParser.parse(
      """
      Filter Settings file
      Equaliser: Generic
      Filter 1: ON HP Fc 20 Hz
      Filter 2: ON NO Fc 800 Hz
      """,
      name: "REW"
    )
    XCTAssertEqual(profile.filters.count, 2)
    XCTAssertEqual(profile.filters[0].bandwidth, 1.899_97, accuracy: 0.000_1)
    XCTAssertEqual(profile.filters[1].bandwidth, 0.048_087, accuracy: 0.000_1)
  }

  func testRejectsParametricFilterWithoutQ() {
    XCTAssertThrowsError(
      try EqualizerAPOParser.parse(
        "Filter: ON PK Fc 100 Hz Gain 2 dB",
        name: "Missing Q"
      )
    ) { error in
      XCTAssertEqual(error as? EQProfileError, .missingValue(1, "Q or bandwidth"))
    }
  }

  func testRejectsShelfSlopeVariantInsteadOfSilentlyMisapplyingIt() {
    XCTAssertThrowsError(
      try EqualizerAPOParser.parse(
        "Filter: ON LS 6dB Fc 100 Hz Gain 2 dB",
        name: "Slope"
      )
    ) { error in
      XCTAssertEqual(
        error as? EQProfileError,
        .unsupportedFilter(1, "LS slope/corner-frequency")
      )
    }
  }

  func testRejectsUnsupportedCommands() {
    XCTAssertThrowsError(
      try EqualizerAPOParser.parse(
        "GraphicEQ: 20 0; 100 2",
        name: "Graphic"
      )
    ) { error in
      XCTAssertEqual(error as? EQProfileError, .unsupportedCommand(1, "GraphicEQ"))
    }
  }

  func testRejectsProfileWithoutEnabledFilters() {
    XCTAssertThrowsError(
      try EqualizerAPOParser.parse(
        "Filter: OFF PK Fc 100 Hz Gain 2 dB Q 1",
        name: "Off"
      )
    ) { error in
      XCTAssertEqual(error as? EQProfileError, .noFilters)
    }
  }

  func testRejectsMoreThanMaximumFilterCount() {
    let filters = (1...(EQProfile.maximumFilterCount + 1))
      .map { "Filter \($0): ON PK Fc 1000 Hz Gain 1 dB Q 1" }
      .joined(separator: "\n")
    XCTAssertThrowsError(
      try EqualizerAPOParser.parse(filters, name: "Too many")
    ) { error in
      XCTAssertEqual(
        error as? EQProfileError,
        .tooManyFilters(EQProfile.maximumFilterCount + 1)
      )
    }
  }

  func testConfiguresNativeEqualizerBands() throws {
    let profile = try EqualizerAPOParser.parse(
      """
      Preamp: -4 dB
      Filter: ON PK Fc 1000 Hz Gain 3 dB Q 2
      """,
      name: "Native"
    )
    let equalizer = AVAudioUnitEQ(numberOfBands: profile.filters.count)
    profile.configure(equalizer, userGain: -2)

    XCTAssertEqual(equalizer.globalGain, -6)
    XCTAssertEqual(equalizer.bands[0].filterType, .parametric)
    XCTAssertEqual(equalizer.bands[0].frequency, 1000)
    XCTAssertEqual(equalizer.bands[0].gain, 3)
    XCTAssertFalse(equalizer.bands[0].bypass)
  }

  func testFrequencyResponseIncludesProfileAndUserGain() throws {
    let profile = try EqualizerAPOParser.parse(
      """
      Preamp: -5 dB
      Filter: ON PK Fc 1000 Hz Gain 4 dB Q 1
      """,
      name: "Response"
    )

    XCTAssertEqual(
      EQResponse.decibels(
        profile: profile,
        frequency: 1_000,
        sampleRate: 48_000,
        userGain: -2
      ),
      -3,
      accuracy: 0.01
    )
  }

  func testProfileSourceRoundTripsThroughPreferencesEncoding() throws {
    let profile = EQProfile(
      name: "HD 25",
      preamp: -6.4,
      filters: [
        EQProfile.Filter(kind: .parametric, frequency: 1_000, gain: 2, bandwidth: 1)
      ],
      source: "oratory1990"
    )

    let decoded = try JSONDecoder().decode(
      EQProfile.self,
      from: JSONEncoder().encode(profile)
    )

    XCTAssertEqual(decoded, profile)
    XCTAssertEqual(decoded.source, "oratory1990")
  }

  func testDecodesProfilesSavedBeforeSourceWasAdded() throws {
    let data = Data(
      #"{"name":"HD 25","preamp":-6.4,"filters":[{"kind":"parametric","frequency":1000,"gain":2,"bandwidth":1}]}"#
        .utf8
    )

    let profile = try JSONDecoder().decode(EQProfile.self, from: data)

    XCTAssertEqual(profile.name, "HD 25")
    XCTAssertNil(profile.source)
  }
}
