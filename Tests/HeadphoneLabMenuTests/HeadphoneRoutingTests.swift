import CoreAudio
import XCTest
@testable import HeadphoneEQ

final class HeadphoneRoutingTests: XCTestCase {
  private func route(_ id: UInt32 = 10, name: String = "Headphones") -> AudioOutputRoute {
    AudioOutputRoute(deviceID: id, uid: "device-\(id)", name: name)
  }

  func testDetectsWiredHeadphonesAndAirPods() {
    XCTAssertTrue(route().detectedHeadphones)
    XCTAssertTrue(route(name: "Jane’s AirPods Pro").detectedHeadphones)
    var usb = route(name: "USB Audio")
    usb.transport = kAudioDeviceTransportTypeUSB
    usb.terminalTypes = [kAudioStreamTerminalTypeHeadphones]
    XCTAssertTrue(usb.detectedHeadphones)
    var builtIn = route(name: "Built-in Output")
    builtIn.dataSources = [fourCC("hdpn")]
    XCTAssertTrue(builtIn.detectedHeadphones)
    builtIn.dataSources = [42]
    builtIn.sourceNames = ["External Headphones"]
    XCTAssertTrue(builtIn.detectedHeadphones)
  }

  func testBluetoothSpeakersAndUnknownDACsAreNotAssumedToBeHeadphones() {
    var speaker = route(name: "Living Room")
    speaker.transport = kAudioDeviceTransportTypeBluetooth
    XCTAssertFalse(speaker.detectedHeadphones)
    speaker.transport = kAudioDeviceTransportTypeBluetoothLE
    XCTAssertFalse(speaker.detectedHeadphones)
    speaker.transport = kAudioDeviceTransportTypeUSB
    XCTAssertFalse(speaker.detectedHeadphones)
    XCTAssertFalse(route(name: "MacBook Pro Speakers").detectedHeadphones)
  }

  func testSelectedSpeakerSourceOverridesHeadphoneDeviceNameAndTerminal() {
    var combined = route()
    combined.terminalTypes = [kAudioStreamTerminalTypeHeadphones]
    combined.dataSources = [fourCC("ispk")]
    XCTAssertFalse(combined.detectedHeadphones)
    combined.dataSources = [123]
    combined.sourceNames = ["Internal Speakers"]
    XCTAssertFalse(combined.detectedHeadphones)
  }

  func testDisconnectedDeadAndNonPhysicalOutputsAreExcluded() {
    var headphones = route()
    headphones.jackConnected = false
    XCTAssertFalse(headphones.detectedHeadphones)
    headphones.jackConnected = true
    headphones.isAlive = false
    XCTAssertFalse(headphones.detectedHeadphones)
    headphones.isAlive = true
    for transport in [kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeHDMI,
      kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeVirtual,
      kAudioDeviceTransportTypeAggregate] {
      headphones.transport = transport
      XCTAssertFalse(headphones.detectedHeadphones)
    }
  }

  func testSimultaneousSpeakerAndHeadphoneTerminalsAreExcluded() {
    var output = route()
    output.terminalTypes = [kAudioStreamTerminalTypeHeadphones, kAudioStreamTerminalTypeSpeaker]
    XCTAssertFalse(output.detectedHeadphones)
  }

  @MainActor
  func testSpeakersPauseAndHeadphonesResumeWithoutChangingPreference() {
    var events: [String] = []
    let controller = HeadphoneRoutingController(enabled: true,
      start: { events.append("start:\($0.deviceID)") }, stop: { events.append("stop") })
    controller.updateOutput(route(name: "MacBook Pro Speakers"))
    XCTAssertTrue(events.isEmpty)
    controller.updateOutput(route())
    controller.updateOutput(route(20, name: "Display Speakers"))
    XCTAssertNil(controller.runningOutput)
    XCTAssertTrue(controller.enabled)
    controller.updateOutput(route())
    XCTAssertEqual(events, ["start:10", "stop", "start:10"])
  }

  @MainActor
  func testHandoverStopsOldHeadphonesBeforeStartingNewOutput() {
    var events: [String] = []
    let controller = HeadphoneRoutingController(enabled: true,
      start: { events.append("start:\($0.deviceID)") }, stop: { events.append("stop") })
    controller.updateOutput(route())
    controller.updateOutput(route(20, name: "AirPods"))
    controller.updateOutput(route(20, name: "AirPods"))
    XCTAssertEqual(events, ["start:10", "stop", "start:20"])
    XCTAssertEqual(controller.runningOutput?.deviceID, 20)
  }

  @MainActor
  func testManualDisablePersistsAcrossOutputChangesAndReconnects() {
    var starts = 0
    var stops = 0
    let controller = HeadphoneRoutingController(enabled: true,
      start: { _ in starts += 1 }, stop: { stops += 1 })
    controller.updateOutput(route())
    controller.setEnabled(false)
    controller.updateOutput(nil)
    controller.updateOutput(route(20, name: "AirPods"))
    XCTAssertEqual(starts, 1)
    XCTAssertEqual(stops, 1)
    XCTAssertFalse(controller.enabled)
    XCTAssertNil(controller.runningOutput)
    controller.setEnabled(true)
    XCTAssertEqual(starts, 2)
  }

  @MainActor
  func testDisabledLaunchDoesNotStartUntilEnabled() {
    var starts = 0
    let controller = HeadphoneRoutingController(enabled: false,
      start: { _ in starts += 1 }, stop: {})
    controller.updateOutput(route())
    XCTAssertEqual(starts, 0)
    controller.setEnabled(true)
    XCTAssertEqual(starts, 1)
  }

  @MainActor
  func testMissingOrDeadOutputStopsAndReconnectResumes() {
    var events: [String] = []
    let controller = HeadphoneRoutingController(enabled: true,
      start: { _ in events.append("start") }, stop: { events.append("stop") })
    controller.updateOutput(route())
    controller.updateOutput(nil)
    controller.updateOutput(route())
    var dead = route()
    dead.isAlive = false
    controller.updateOutput(dead)
    controller.updateOutput(route())
    XCTAssertEqual(events, ["start", "stop", "start", "stop", "start"])
  }

  @MainActor
  func testOutputSampleRateChangeRebuildsRoute() {
    var starts = 0
    var stops = 0
    let controller = HeadphoneRoutingController(enabled: true,
      start: { _ in starts += 1 }, stop: { stops += 1 })
    var headphones = route()
    headphones.sampleRate = 48_000
    controller.updateOutput(headphones)
    headphones.sampleRate = 44_100
    controller.updateOutput(headphones)
    XCTAssertEqual(starts, 2)
    XCTAssertEqual(stops, 1)
  }

  @MainActor
  func testManualDACIdentificationIsRememberedAndCanBeRemoved() {
    var starts = 0
    var stops = 0
    let dac = route(name: "USB DAC")
    let controller = HeadphoneRoutingController(enabled: true,
      start: { _ in starts += 1 }, stop: { stops += 1 })
    controller.updateOutput(dac)
    XCTAssertEqual(starts, 0)
    controller.setHeadphoneOverride(true)
    XCTAssertEqual(starts, 1)
    let remembered = controller.headphoneOutputKeys
    controller.updateOutput(nil)
    controller.updateOutput(dac)
    XCTAssertEqual(starts, 2)
    controller.setHeadphoneOverride(false)
    XCTAssertEqual(stops, 2)
    XCTAssertTrue(controller.headphoneOutputKeys.isEmpty)
    let restored = HeadphoneRoutingController(enabled: true, headphoneOutputKeys: remembered,
      start: { _ in starts += 1 }, stop: {})
    restored.updateOutput(dac)
    XCTAssertEqual(starts, 3)
  }

  @MainActor
  func testManualIdentificationDoesNotApplyToAnotherDeviceOrSpeakerSource() {
    var starts = 0
    var stops = 0
    var output = route(name: "Combined Output")
    output.dataSources = [12]
    let controller = HeadphoneRoutingController(enabled: true,
      start: { _ in starts += 1 }, stop: { stops += 1 })
    controller.updateOutput(output)
    controller.setHeadphoneOverride(true)
    output.dataSources = [fourCC("ispk")]
    controller.updateOutput(output)
    XCTAssertFalse(controller.headphonesSelected)
    controller.updateOutput(route(20, name: "USB DAC"))
    XCTAssertFalse(controller.headphonesSelected)
    XCTAssertEqual(starts, 1)
    XCTAssertEqual(stops, 1)
  }

  @MainActor
  func testJackDisconnectionStopsEvenAManuallyIdentifiedOutput() {
    var stops = 0
    var output = route(name: "USB DAC")
    let controller = HeadphoneRoutingController(enabled: true, start: { _ in }, stop: { stops += 1 })
    controller.updateOutput(output)
    controller.setHeadphoneOverride(true)
    output.jackConnected = false
    controller.updateOutput(output)
    XCTAssertFalse(controller.headphonesSelected)
    XCTAssertNil(controller.runningOutput)
    XCTAssertEqual(stops, 1)
  }

  @MainActor
  func testKnownSpeakerSourceCannotBeOverriddenEvenWithASavedIdentification() {
    var output = route(name: "Built-in Output")
    output.dataSources = [fourCC("ispk")]
    var starts = 0
    let controller = HeadphoneRoutingController(enabled: true,
      headphoneOutputKeys: [output.headphonePreferenceKey],
      start: { _ in starts += 1 }, stop: {})
    controller.updateOutput(output)
    controller.setHeadphoneOverride(true)
    XCTAssertFalse(controller.headphonesSelected)
    XCTAssertEqual(starts, 0)
    controller.setHeadphoneOverride(false)
    XCTAssertTrue(controller.headphoneOutputKeys.isEmpty)
  }

  @MainActor
  func testRealOutputMonitorPublishesInitialRouteAndCanBeStoppedAndRestarted() throws {
    let monitor = AudioOutputMonitor()
    defer { monitor.stop() }
    var snapshots: [AudioOutputRoute?] = []
    monitor.onChange = { snapshots.append($0) }
    try monitor.start()
    XCTAssertEqual(snapshots.count, 1)
    XCTAssertEqual(snapshots[0], AudioOutputRoute.current())
    monitor.refresh()
    XCTAssertEqual(snapshots.count, 1)
    monitor.stop()
    monitor.refresh(force: true)
    XCTAssertEqual(snapshots.count, 1)
    try monitor.start()
    XCTAssertEqual(snapshots.count, 2)
    XCTAssertEqual(snapshots[1], AudioOutputRoute.current())
  }

  @MainActor
  func testFailedStartDoesNotLoopOrDiscardTheUserPreference() {
    var attempts = 0
    var errors = 0
    let controller = HeadphoneRoutingController(enabled: true,
      start: { _ in attempts += 1; throw AudioRouteError.noOutputDevice }, stop: {})
    controller.onError = { _ in errors += 1 }
    controller.updateOutput(route())
    controller.updateOutput(route())
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(errors, 1)
    XCTAssertTrue(controller.enabled)
    XCTAssertNotNil(controller.error)
    XCTAssertNil(controller.runningOutput)
    controller.setEnabled(true)
    XCTAssertEqual(attempts, 2)
    controller.updateOutput(nil)
    XCTAssertNil(controller.error)
    controller.updateOutput(route())
    XCTAssertEqual(attempts, 3)
  }
}
