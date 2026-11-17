import AppKit

@MainActor
final class SpatialAudioController: NSWindowController, NSWindowDelegate {
  private var processingActive = false
  private var settings: SpatialAudioSettings
  private let onChange: (SpatialAudioSettings) -> Void
  private let onClose: () -> Void
  private let enabled = HardwareButton(title: "Active", target: nil, action: nil)
  private let profile = NSPopUpButton()
  private let optimal = HardwareButton(title: "Optimal Placement", target: nil, action: nil)
  private let plan = AcousticFieldView(frame: .zero)
  private let levelHistory = LiveAudioHistoryView(frame: .zero)
  private let displaySource = NSSegmentedControl(labels: ["L", "L+R", "R"],
    trackingMode: .selectOne, target: nil, action: nil)
  private let displayBand = NSSegmentedControl(labels: ["Full", "125 Hz", "1 kHz", "4 kHz"],
    trackingMode: .selectOne, target: nil, action: nil)
  private let status = NSTextField(labelWithString: "")
  private let decay = HardwareReadout()
  private let decayTitle = StudioHardware.label("MIDRANGE RT60 · MODEL", size: 9, color: StudioHardware.muted)
  private var knobs: [HardwareKnob] = []
  private var values: [HardwareReadout] = []

  init(settings: SpatialAudioSettings,
       liveProvider: @escaping () -> LiveAudioSnapshot?,
       onMonitoringChange: @escaping (Bool) -> Void,
       onChange: @escaping (SpatialAudioSettings) -> Void,
       onClose: @escaping () -> Void) {
    self.settings = settings.normalized
    self.onChange = onChange
    self.onClose = onClose
    super.init(window: nil)
    window = makeWindow()
    plan.liveProvider = liveProvider
    plan.onMonitoringChange = onMonitoringChange
    plan.onFrame = { [weak self] state,time in
      self?.levelHistory.state = state
      self?.levelHistory.time = time
      self?.levelHistory.needsDisplay = true
    }
    refresh()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.center()
    window?.makeKeyAndOrderFront(sender)
    NSApp.activate(ignoringOtherApps: true)
    plan.startAnimation()
  }

  func windowWillClose(_ notification: Notification) {
    plan.stopAnimation()
    onClose()
  }
  func setStatus(_ message: String) { status.stringValue = message }
  func setProcessingActive(_ active: Bool) { processingActive = active; refresh() }
  func setSettings(_ settings: SpatialAudioSettings) { self.settings = settings.normalized; refresh() }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 730),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Headphone EQ · Soundstage"
    window.appearance = NSAppearance(named: .darkAqua)
    window.titlebarAppearsTransparent = true
    window.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.delegate = self
    window.contentView = RackPanelView()
    guard let content = window.contentView else { return window }

    let title = StudioHardware.label("SOUNDSTAGE", size: 27, tracking: 4)
    let subtitle = StudioHardware.label("HEADPHONE EQ  /  BINAURAL MONITOR CONTROLLER", size: 9,
      color: StudioHardware.muted, tracking: 1.7)
    let titleStack = NSStackView(views: [title, subtitle])
    titleStack.orientation = .vertical
    titleStack.alignment = .leading
    titleStack.spacing = 5
    enabled.showsPowerLamp = true
    enabled.setButtonType(.pushOnPushOff)
    enabled.target = self
    enabled.action = #selector(changed)
    enabled.setAccessibilityLabel("Enable soundstage")
    enabled.toolTip = "Switch between virtual speakers and ordinary stereo headphones"
    enabled.widthAnchor.constraint(equalToConstant: 112).isActive = true
    enabled.heightAnchor.constraint(equalToConstant: 38).isActive = true
    let header = NSStackView(views: [titleStack, NSView(), enabled])
    header.orientation = .horizontal

    profile.addItems(withTitles: HRTFProfile.allCases.map(\.title))
    profile.font = .systemFont(ofSize: 12, weight: .medium)
    profile.target = self
    profile.action = #selector(changed)
    profile.setAccessibilityLabel("Ear profile")
    let hint = NSTextField(wrappingLabelWithString:
      "Choose the profile that places the speakers most naturally in front of you.")
    hint.font = .systemFont(ofSize: 11)
    hint.textColor = StudioHardware.muted
    displaySource.selectedSegment = AcousticProbeSource.stereo.rawValue
    displayBand.selectedSegment = LiveAudioBand.full.rawValue
    for control in [displaySource, displayBand] {
      control.controlSize = .small
      control.font = .systemFont(ofSize: 10)
      control.target = self
      control.action = #selector(changeDisplay)
    }
    displaySource.setAccessibilityLabel("Displayed audio channels")
    displaySource.toolTip = "Choose which live input channels drive the room illustration. Both processed ear waveforms remain visible; audio playback is unchanged."
    displayBand.setAccessibilityLabel("Displayed audio band")
    displayBand.toolTip = "Full shows faint bass wrap plus brighter forward mid/treble arcs. Select a band to inspect its cabinet radiation pattern: broad bass at 125 Hz, stronger forward directionality at 1 and 4 kHz. The ear waveforms and level history remain full-band; audio playback is unchanged."
    let profileStack = NSStackView(views: [
      StudioHardware.label("LISTENER / LIVE DISPLAY", size: 10), profile, hint,
      displaySource, displayBand,
      decayTitle, decay, levelHistory,
    ])
    profileStack.orientation = .vertical
    profileStack.alignment = .leading
    profileStack.spacing = 8
    let profilePanel = HardwareWellView()
    embed(profileStack, in: profilePanel, inset: 16)
    profilePanel.widthAnchor.constraint(equalToConstant: 260).isActive = true
    profile.widthAnchor.constraint(equalTo: profileStack.widthAnchor).isActive = true
    hint.widthAnchor.constraint(equalTo: profileStack.widthAnchor).isActive = true
    for control in [displaySource, displayBand] {
      control.widthAnchor.constraint(equalTo: profileStack.widthAnchor).isActive = true
      control.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    levelHistory.widthAnchor.constraint(equalTo: profileStack.widthAnchor).isActive = true
    levelHistory.heightAnchor.constraint(equalToConstant: 57).isActive = true
    decay.widthAnchor.constraint(equalTo: profileStack.widthAnchor).isActive = true
    decay.heightAnchor.constraint(equalToConstant: 27).isActive = true
    let scene = NSStackView(views: [plan, profilePanel])
    scene.orientation = .horizontal
    scene.spacing = 18
    scene.alignment = .top
    scene.heightAnchor.constraint(equalToConstant: 300).isActive = true
    plan.heightAnchor.constraint(equalTo: scene.heightAnchor).isActive = true
    profilePanel.heightAnchor.constraint(equalTo: scene.heightAnchor).isActive = true

    let defaults = SpatialAudioSettings()
    let tiles = [
      dial("ANGLE", accessible: "Speaker angle", range: 15...60, reset: Double(defaults.speakerAngle), tag: 0),
      dial("DISTANCE", accessible: "Listening distance", range: 0.6...3.5, reset: Double(defaults.speakerDistance), tag: 1),
      dial("WIDTH", accessible: "Width", range: 3...12, reset: Double(defaults.width), tag: 2),
      dial("DEPTH", accessible: "Depth", range: 3...16, reset: Double(defaults.depth), tag: 3),
      dial("HEIGHT", accessible: "Height", range: 2.2...5, reset: Double(defaults.height), tag: 4),
      dial("TREATMENT", accessible: "Treatment", range: 0...1, reset: Double(defaults.treatment), tag: 5),
      dial("PRESENCE", accessible: "Room presence", range: 0...0.6, reset: Double(defaults.roomAmount), tag: 6),
    ]
    knobs[0].toolTip = "Angle to each speaker from straight ahead"
    knobs[1].toolTip = "Listening distance; limited to fit the speakers inside the room"
    knobs[5].toolTip = "Bare surfaces to broad absorption, with more absorption at high frequencies"
    knobs[6].toolTip = "Amount of directional early reflections and late reverberation"
    optimal.target = self
    optimal.action = #selector(optimalPlacement)
    optimal.setButtonType(.pushOnPushOff)
    optimal.showsStateLamp = true
    optimal.setAccessibilityLabel("Optimal Placement")
    optimal.toolTip = "Keep a symmetric 60° stereo triangle fitted to the room as dimensions change, with at least 0.5 m cabinet clearance. Speakers face the listener. The lamp shows automatic placement is on. Adjusting angle or distance switches to manual placement."
    optimal.setAccessibilityHelp(optimal.toolTip)
    optimal.heightAnchor.constraint(equalToConstant: 24).isActive = true
    let speakers = controlGroup("VIRTUAL SPEAKERS", tiles: Array(tiles[0...1]), spacing: 10, footer: optimal)
    let room = controlGroup("ROOM ACOUSTICS", tiles: Array(tiles[2...6]), spacing: 6)
    let controls = NSStackView(views: [speakers, room])
    controls.orientation = .horizontal
    controls.spacing = 18
    speakers.widthAnchor.constraint(equalToConstant: 250).isActive = true

    status.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    status.textColor = StudioHardware.amber
    let notes = StudioHardware.label("6 dB HEADROOM  ·  DRAG TO ADJUST  ·  SHIFT: FINE  ·  DOUBLE-CLICK: RESET",
      size: 8, color: StudioHardware.muted, tracking: 0.45)
    let footerText = NSStackView(views: [status, notes])
    footerText.orientation = .vertical
    footerText.alignment = .leading
    footerText.spacing = 7
    let reset = HardwareButton(title: "Reset Room", target: self, action: #selector(resetRoom))
    let done = HardwareButton(title: "Done", target: self, action: #selector(closeRoom))
    done.keyEquivalent = "\r"
    for button in [reset, done] {
      button.widthAnchor.constraint(equalToConstant: button === done ? 74 : 102).isActive = true
      button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
    let footer = NSStackView(views: [footerText, NSView(), reset, done])
    footer.orientation = .horizontal
    footer.spacing = 10

    let stack = NSStackView(views: [header, scene, controls, footer])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 18
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    for view in [header, scene, controls, footer] {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
    ])
    return window
  }

  private func embed(_ stack: NSStackView, in view: NSView, inset: CGFloat) {
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: inset),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -inset),
    ])
  }

  private func controlGroup(_ title: String, tiles: [NSView], spacing: CGFloat, footer: NSView? = nil) -> NSView {
    let row = NSStackView(views: tiles)
    row.orientation = .horizontal
    row.distribution = .fillEqually
    row.spacing = spacing
    let stack = NSStackView(views: [StudioHardware.label(title, size: 9, color: StudioHardware.muted), row])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 9
    row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    let well = HardwareWellView()
    embed(stack, in: well, inset: 12)
    if let footer {
      stack.addArrangedSubview(footer)
      footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    well.heightAnchor.constraint(equalToConstant: 225).isActive = true
    return well
  }

  private func dial(_ title: String, accessible: String, range: ClosedRange<Double>,
                    reset: Double, tag: Int) -> NSView {
    let label = StudioHardware.label(title, size: 8, tracking: 0.8)
    let knob = HardwareKnob()
    knob.sliderType = .circular
    knob.minValue = range.lowerBound
    knob.maxValue = range.upperBound
    knob.resetValue = reset
    knob.tag = tag
    knob.isContinuous = true
    knob.focusRingType = .none
    knob.target = self
    knob.action = #selector(changed)
    knob.setAccessibilityLabel(accessible)
    knob.setAccessibilityHelp("Drag up or down, use arrow keys, or scroll. Hold Shift for fine adjustment. Double-click to reset.")
    knob.widthAnchor.constraint(equalToConstant: 100).isActive = true
    knob.heightAnchor.constraint(equalToConstant: 100).isActive = true
    let value = HardwareReadout()
    value.widthAnchor.constraint(equalToConstant: 86).isActive = true
    value.heightAnchor.constraint(equalToConstant: 26).isActive = true
    let tile = NSStackView(views: [label, knob, value])
    tile.orientation = .vertical
    tile.alignment = .centerX
    tile.spacing = 5
    knobs.append(knob)
    values.append(value)
    return tile
  }

  @objc private func changeDisplay() {
    guard let source = AcousticProbeSource(rawValue: displaySource.selectedSegment),
      let band = LiveAudioBand(rawValue: displayBand.selectedSegment) else { return }
    plan.setDisplay(source: source, band: band)
    refreshDecay()
  }

  @objc private func changed(_ sender: Any?) {
    if let knob = sender as? HardwareKnob, knob.tag == 0 || knob.tag == 1 {
      settings.automaticPlacement = false
    }
    settings.enabled = enabled.state == .on
    settings.hrtf = HRTFProfile.allCases[max(0, profile.indexOfSelectedItem)]
    settings.speakerAngle = knobs[0].floatValue
    settings.speakerDistance = knobs[1].floatValue
    settings.width = knobs[2].floatValue
    settings.depth = knobs[3].floatValue
    settings.height = knobs[4].floatValue
    settings.treatment = knobs[5].floatValue
    settings.roomAmount = knobs[6].floatValue
    settings = settings.normalized
    refresh()
    onChange(settings)
  }

  @objc private func optimalPlacement() {
    settings.automaticPlacement = optimal.state == .on
    settings = settings.normalized
    refresh()
    onChange(settings)
  }

  @objc private func resetRoom() {
    let wasEnabled = settings.enabled
    let wasAutomatic = settings.automaticPlacement
    settings = SpatialAudioSettings()
    settings.enabled = wasEnabled
    settings.automaticPlacement = wasAutomatic
    settings = settings.normalized
    refresh()
    onChange(settings)
  }

  @objc private func closeRoom() { window?.close() }

  private func refreshDecay() {
    let band = LiveAudioBand(rawValue: displayBand.selectedSegment) ?? .full
    let name = band == .low ? "BASS" : band == .high ? "TREBLE" : "MIDRANGE"
    decayTitle.stringValue = "\(name) RT60 · MODEL"
    decay.stringValue = String(format: "%.2f s", settings.decayTimes.time(for: band))
    decay.toolTip = "Time for modeled reverberation to fall by 60 dB. Full-band fronts blend bass, midrange and treble decay using the measured input spectrum; this readout shows midrange for Full."
  }

  private func refresh() {
    enabled.state = settings.enabled ? .on : .off
    enabled.processingAvailable = processingActive
    enabled.title = settings.enabled ? (processingActive ? "Active" : "Ready") : "Bypass"
    enabled.needsDisplay = true
    optimal.state = settings.automaticPlacement ? .on : .off
    optimal.needsDisplay = true
    profile.selectItem(at: HRTFProfile.allCases.firstIndex(of: settings.hrtf) ?? 0)
    let numbers = [settings.speakerAngle, settings.speakerDistance, settings.width,
      settings.depth, settings.height, settings.treatment, settings.roomAmount]
    knobs[1].maxValue = Double(settings.maximumSpeakerDistance)
    for i in numbers.indices {
      knobs[i].floatValue = numbers[i]
      knobs[i].needsDisplay = true
      let text = i == 0 ? String(format: "±%.0f°", numbers[i])
        : i >= 5 ? String(format: "%.0f%%", numbers[i]*100)
        : String(format: "%.1f m", numbers[i])
      values[i].stringValue = text
      knobs[i].setAccessibilityValueDescription(text)
    }
    plan.settings = settings
    refreshDecay()
    status.stringValue = settings.enabled
      ? (processingActive ? "●  BINAURAL MONITORING ACTIVE" : "○  AUDIO PROCESSING OFF")
      : "○  BYPASS · ORIGINAL STEREO"
  }
}

