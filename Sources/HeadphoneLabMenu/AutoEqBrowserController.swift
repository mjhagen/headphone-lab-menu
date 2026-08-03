import AppKit
import UniformTypeIdentifiers

@MainActor
private final class ResettableCircularSlider: NSSlider {
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      doubleValue = 0
      sendAction(action, to: target)
      return
    }
    super.mouseDown(with: event)
  }
}

@MainActor
final class AutoEqBrowserController: NSWindowController, NSWindowDelegate,
  NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate
{
  private let client: AutoEqCatalogClient
  private let initialProfile: EQProfile?
  private let spectrumProvider: () -> SpectrumSnapshot?
  private let onGainChange: (Float) -> Void
  private let onEnabledChange: (Bool) -> Void
  private let onPeakLimiterChange: (Bool) -> Void
  private let onPreview: (EQProfile) -> Void
  private let onCommit: (EQProfile?) -> Void
  private let onCancel: () -> Void
  private let onClose: () -> Void

  private let searchField = NSSearchField()
  private let currentProfileLabel = NSTextField(labelWithString: "")
  private let tableView = NSTableView()
  private let statusLabel = NSTextField(labelWithString: "Loading AutoEq catalog…")
  private let progressIndicator = NSProgressIndicator()
  private let useButton = NSButton(title: "Use Profile", target: nil, action: nil)
  private let spectrumView = SpectrumView()
  private let gainSlider = ResettableCircularSlider()
  private let gainValueLabel = NSTextField(labelWithString: "0.0 dB")
  private let enabledLabel = NSTextField(labelWithString: "ENABLED")
  private let enabledSwitch = NSSwitch()
  private let peakLimiterLabel = NSTextField(labelWithString: "PEAK LIMITER")
  private let peakLimiterSwitch = NSSwitch()
  private var entries: [AutoEqEntry] = []
  private var filteredEntries: [AutoEqEntry] = []
  private var profileCache: [AutoEqEntry: EQProfile] = [:]
  private var previewedEntry: AutoEqEntry?
  private var loadedProfile: EQProfile?
  private var committed = false
  private var isUpdatingTable = false
  private var catalogTask: Task<Void, Never>?
  private var profileTask: Task<Void, Never>?
  private var profileTaskID: UUID?

  init(
    client: AutoEqCatalogClient,
    initialProfile: EQProfile?,
    initialGain: Float,
    initialEnabled: Bool,
    initialPeakLimiter: Bool,
    spectrumProvider: @escaping () -> SpectrumSnapshot?,
    onGainChange: @escaping (Float) -> Void,
    onEnabledChange: @escaping (Bool) -> Void,
    onPeakLimiterChange: @escaping (Bool) -> Void,
    onPreview: @escaping (EQProfile) -> Void,
    onCommit: @escaping (EQProfile?) -> Void,
    onCancel: @escaping () -> Void,
    onClose: @escaping () -> Void
  ) {
    self.client = client
    self.initialProfile = initialProfile
    self.spectrumProvider = spectrumProvider
    self.onGainChange = onGainChange
    self.onEnabledChange = onEnabledChange
    self.onPeakLimiterChange = onPeakLimiterChange
    self.onPreview = onPreview
    self.onCommit = onCommit
    self.onCancel = onCancel
    self.onClose = onClose
    super.init(window: nil)
    spectrumView.profile = initialProfile
    spectrumView.userGain = initialGain
    setEqualizerEnabled(initialEnabled)
    setPeakLimiter(initialPeakLimiter)
    showInitialProfile()
    window = makeWindow()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func showWindow(_ sender: Any?) {
    let shouldResetSearch = window?.isVisible != true
    super.showWindow(sender)
    if shouldResetSearch {
      searchField.stringValue = ""
      filterEntries()
    }
    window?.center()
    window?.makeKeyAndOrderFront(sender)
    NSApp.activate(ignoringOtherApps: true)
    searchField.becomeFirstResponder()
    loadCatalogIfNeeded()
    spectrumView.start(frameProvider: spectrumProvider)
  }

  func windowWillClose(_ notification: Notification) {
    catalogTask?.cancel()
    profileTask?.cancel()
    spectrumView.stop()
    if !committed { onCancel() }
    onClose()
  }

  func setPeakLimiter(_ enabled: Bool) {
    peakLimiterSwitch.state = enabled ? .on : .off
    gainSlider.isEnabled = !enabled
    if enabled {
      gainSlider.doubleValue = 0
      spectrumView.userGain = 0
      gainValueLabel.stringValue = "+0.0 dB"
    }
  }

  func setEqualizerEnabled(_ enabled: Bool) {
    enabledSwitch.state = enabled ? .on : .off
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    filteredEntries.count
  }

  func tableView(
    _ tableView: NSTableView,
    viewFor tableColumn: NSTableColumn?,
    row: Int
  ) -> NSView? {
    guard row < filteredEntries.count, let tableColumn else { return nil }
    let entry = filteredEntries[row]
    let identifier = tableColumn.identifier
    let text = identifier.rawValue == "headphone" ? entry.name : entry.detail

    if let view = tableView.makeView(withIdentifier: identifier, owner: self)
      as? NSTableCellView
    {
      view.textField?.stringValue = text
      return view
    }

    let view = NSTableCellView()
    view.identifier = identifier
    let label = NSTextField(labelWithString: text)
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    view.textField = label
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
      label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    return view
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !isUpdatingTable else { return }
    previewSelection()
  }

  func controlTextDidChange(_ notification: Notification) {
    filterEntries()
  }

  @objc private func useSelection() {
    guard let entry = selectedEntry,
      entry == previewedEntry,
      let loadedProfile
    else { return }
    committed = true
    onCommit(loadedProfile)
    window?.close()
  }

  @objc private func cancel() {
    window?.close()
  }

  @objc private func changeGain() {
    let gain = Float(gainSlider.doubleValue)
    spectrumView.userGain = gain
    gainValueLabel.stringValue = String(format: "%+.1f dB", gain)
    onGainChange(gain)
  }

  @objc private func changePeakLimiter() {
    onPeakLimiterChange(peakLimiterSwitch.state == .on)
  }

  @objc private func changeEnabled() {
    onEnabledChange(enabledSwitch.state == .on)
  }

  @objc private func openLocalProfile() {
    let panel = NSOpenPanel()
    panel.title = "Open Equalizer APO Profile"
    panel.prompt = "Open Profile"
    panel.allowedContentTypes = [.plainText]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      let text = try String(contentsOf: url, encoding: .utf8)
      let profile = try EqualizerAPOParser.parse(
        text,
        name: url.deletingPathExtension().lastPathComponent
      )
      committed = true
      onCommit(profile)
      window?.close()
    } catch {
      showError(error)
    }
  }

  @objc private func clearProfile() {
    committed = true
    onCommit(nil)
    window?.close()
  }

  private var selectedEntry: AutoEqEntry? {
    let row = tableView.selectedRow
    guard row >= 0, row < filteredEntries.count else { return nil }
    return filteredEntries[row]
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 840, height: 760),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Headphone EQ Settings"
    window.minSize = NSSize(width: 700, height: 620)
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.delegate = self

    guard let contentView = window.contentView else { return window }

    searchField.placeholderString = "Search headphones"
    searchField.delegate = self
    searchField.sendsSearchStringImmediately = true

    currentProfileLabel.font = .systemFont(ofSize: 11, weight: .medium)
    currentProfileLabel.textColor = .secondaryLabelColor
    currentProfileLabel.lineBreakMode = .byTruncatingMiddle

    let headphoneColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("headphone"))
    headphoneColumn.title = "Headphone"
    headphoneColumn.width = 420
    headphoneColumn.minWidth = 220
    headphoneColumn.resizingMask = .autoresizingMask
    let sourceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
    sourceColumn.title = "Measurement"
    sourceColumn.width = 250
    sourceColumn.minWidth = 160
    sourceColumn.resizingMask = .userResizingMask
    tableView.addTableColumn(headphoneColumn)
    tableView.addTableColumn(sourceColumn)
    tableView.delegate = self
    tableView.dataSource = self
    tableView.allowsEmptySelection = true
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.target = self
    tableView.doubleAction = #selector(useSelection)

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder

    progressIndicator.style = .spinning
    progressIndicator.controlSize = .small
    progressIndicator.startAnimation(nil)

    let spectrumLabel = NSTextField(labelWithString: "LIVE SPECTRUM + EQ RESPONSE")
    spectrumLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    spectrumLabel.textColor = .secondaryLabelColor

    gainSlider.sliderType = .circular
    gainSlider.minValue = -24
    gainSlider.maxValue = 0
    gainSlider.doubleValue = Double(spectrumView.userGain)
    gainSlider.numberOfTickMarks = 7
    gainSlider.allowsTickMarkValuesOnly = false
    gainSlider.target = self
    gainSlider.action = #selector(changeGain)
    gainSlider.toolTip = "Output attenuation — double-click to reset"
    gainValueLabel.stringValue = String(format: "%+.1f dB", spectrumView.userGain)
    gainValueLabel.alignment = .center
    gainValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    let gainLabel = NSTextField(labelWithString: "OUTPUT TRIM")
    gainLabel.alignment = .center
    gainLabel.font = .systemFont(ofSize: 10, weight: .semibold)
    gainLabel.textColor = .secondaryLabelColor

    enabledLabel.alignment = .center
    enabledLabel.font = .systemFont(ofSize: 10, weight: .semibold)
    enabledLabel.textColor = .secondaryLabelColor
    enabledSwitch.target = self
    enabledSwitch.action = #selector(changeEnabled)
    enabledSwitch.toolTip = "Enable or disable system-wide equalization"
    enabledSwitch.setAccessibilityLabel("Enabled")

    peakLimiterLabel.alignment = .center
    peakLimiterLabel.font = .systemFont(ofSize: 10, weight: .semibold)
    peakLimiterLabel.textColor = .secondaryLabelColor
    peakLimiterSwitch.target = self
    peakLimiterSwitch.action = #selector(changePeakLimiter)
    peakLimiterSwitch.toolTip = "Prevent sample peaks from exceeding the digital ceiling"
    peakLimiterSwitch.setAccessibilityLabel("Peak Limiter")

    let openButton = NSButton(
      title: "Open EQ File…", target: self, action: #selector(openLocalProfile))
    let clearButton = NSButton(
      title: "Clear Profile", target: self, action: #selector(clearProfile))
    clearButton.isEnabled = initialProfile != nil
    let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
    cancelButton.keyEquivalent = "\u{1b}"
    useButton.target = self
    useButton.action = #selector(useSelection)
    useButton.keyEquivalent = "\r"
    useButton.isEnabled = false

    for view in [
      searchField, currentProfileLabel, scrollView, spectrumLabel, spectrumView,
      enabledLabel, enabledSwitch, gainSlider, gainValueLabel, gainLabel,
      peakLimiterLabel, peakLimiterSwitch, progressIndicator, statusLabel,
      openButton, clearButton, cancelButton, useButton,
    ] {
      view.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(view)
    }

    NSLayoutConstraint.activate([
      searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
      searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

      currentProfileLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
      currentProfileLabel.leadingAnchor.constraint(
        equalTo: contentView.leadingAnchor, constant: 18),
      currentProfileLabel.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor, constant: -18),

      scrollView.topAnchor.constraint(equalTo: currentProfileLabel.bottomAnchor, constant: 8),
      scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      scrollView.bottomAnchor.constraint(equalTo: spectrumLabel.topAnchor, constant: -16),
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),

      spectrumLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      spectrumLabel.bottomAnchor.constraint(equalTo: spectrumView.topAnchor, constant: -7),

      spectrumView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      spectrumView.trailingAnchor.constraint(equalTo: gainSlider.leadingAnchor, constant: -14),
      spectrumView.heightAnchor.constraint(greaterThanOrEqualToConstant: 245),
      spectrumView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -14),

      enabledLabel.centerXAnchor.constraint(equalTo: gainSlider.centerXAnchor),
      enabledLabel.topAnchor.constraint(equalTo: spectrumView.topAnchor, constant: 14),
      enabledSwitch.centerXAnchor.constraint(equalTo: gainSlider.centerXAnchor),
      enabledSwitch.topAnchor.constraint(equalTo: enabledLabel.bottomAnchor, constant: 7),

      gainSlider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
      gainSlider.topAnchor.constraint(equalTo: gainLabel.bottomAnchor, constant: 6),
      gainSlider.widthAnchor.constraint(equalToConstant: 70),
      gainSlider.heightAnchor.constraint(equalToConstant: 70),
      gainValueLabel.centerXAnchor.constraint(equalTo: gainSlider.centerXAnchor),
      gainValueLabel.topAnchor.constraint(equalTo: gainSlider.bottomAnchor, constant: 5),
      gainValueLabel.widthAnchor.constraint(equalToConstant: 82),
      gainLabel.centerXAnchor.constraint(equalTo: gainSlider.centerXAnchor),
      gainLabel.topAnchor.constraint(equalTo: enabledSwitch.bottomAnchor, constant: 14),
      peakLimiterLabel.centerXAnchor.constraint(equalTo: gainSlider.centerXAnchor),
      peakLimiterLabel.topAnchor.constraint(equalTo: gainValueLabel.bottomAnchor, constant: 18),
      peakLimiterSwitch.centerXAnchor.constraint(equalTo: gainSlider.centerXAnchor),
      peakLimiterSwitch.topAnchor.constraint(equalTo: peakLimiterLabel.bottomAnchor, constant: 8),
      peakLimiterSwitch.bottomAnchor.constraint(
        lessThanOrEqualTo: spectrumView.bottomAnchor, constant: -14),

      progressIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
      progressIndicator.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
      statusLabel.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 8),
      statusLabel.centerYAnchor.constraint(equalTo: useButton.centerYAnchor),
      statusLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: openButton.leadingAnchor, constant: -16),

      openButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -8),
      openButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
      clearButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
      clearButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
      cancelButton.trailingAnchor.constraint(equalTo: useButton.leadingAnchor, constant: -8),
      cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
      useButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      useButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
    ])

    return window
  }

  private func loadCatalogIfNeeded() {
    guard entries.isEmpty, catalogTask == nil else { return }
    catalogTask = Task {
      do {
        let loadedEntries = try await client.catalog()
        guard !Task.isCancelled else { return }
        entries = loadedEntries
        filterEntries()
        selectInitialProfile()
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        statusLabel.stringValue = "Couldn’t load AutoEq"
        showError(error)
      }
      catalogTask = nil
    }
  }

  private func filterEntries() {
    profileTask?.cancel()
    profileTask = nil
    profileTaskID = nil
    loadedProfile = nil
    useButton.isEnabled = false
    if previewedEntry != nil {
      previewedEntry = nil
      onCancel()
      spectrumView.profile = initialProfile
    }
    showInitialProfile()

    let terms = searchField.stringValue
      .split(whereSeparator: \Character.isWhitespace)
      .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }

    if terms.isEmpty {
      filteredEntries = entries
    } else {
      filteredEntries = entries.filter { entry in
        let searchable = "\(entry.name) \(entry.source)"
          .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return terms.allSatisfy(searchable.contains)
      }
    }

    isUpdatingTable = true
    tableView.reloadData()
    tableView.selectRowIndexes([], byExtendingSelection: false)
    isUpdatingTable = false
    updateMatchStatus()
  }

  private func previewSelection() {
    let hadPreview = previewedEntry != nil
    profileTask?.cancel()
    profileTask = nil
    profileTaskID = nil
    loadedProfile = nil
    previewedEntry = nil
    useButton.isEnabled = false

    guard let entry = selectedEntry else {
      if hadPreview {
        onCancel()
        spectrumView.profile = initialProfile
      }
      updateMatchStatus()
      return
    }

    if let cachedProfile = profileCache[entry] {
      activatePreview(cachedProfile, for: entry)
      return
    }

    let taskID = UUID()
    profileTaskID = taskID
    setLoadingProfile(name: entry.name)
    profileTask = Task {
      do {
        try await Task.sleep(for: .milliseconds(150))
        let profile = try await client.profile(for: entry)
        guard !Task.isCancelled, profileTaskID == taskID, selectedEntry == entry else {
          return
        }
        profileCache[entry] = profile
        activatePreview(profile, for: entry)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, profileTaskID == taskID else { return }
        finishLoadingProfile()
        showError(error)
      }
      if profileTaskID == taskID {
        profileTask = nil
        profileTaskID = nil
      }
    }
  }

  private func activatePreview(_ profile: EQProfile, for entry: AutoEqEntry) {
    previewedEntry = entry
    loadedProfile = profile
    finishLoadingProfile()
    useButton.isEnabled = true
    statusLabel.stringValue = "Previewing \(entry.name) — Use Profile to keep"
    spectrumView.profile = profile
    currentProfileLabel.stringValue = "Previewing: \(entry.name) — by \(entry.source)"
    onPreview(profile)
  }

  private func selectInitialProfile() {
    guard let initialProfile else { return }
    let row = filteredEntries.firstIndex { entry in
      entry.name.caseInsensitiveCompare(initialProfile.name) == .orderedSame
        && (initialProfile.source == nil || entry.source == initialProfile.source)
    }
    guard let row else { return }
    isUpdatingTable = true
    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
    isUpdatingTable = false
    let entry = filteredEntries[row]
    previewedEntry = entry
    loadedProfile = initialProfile
  }

  private func showInitialProfile() {
    guard let initialProfile else {
      currentProfileLabel.stringValue = "Current profile: Flat"
      return
    }
    let source = initialProfile.source.map { " — by \($0)" } ?? ""
    currentProfileLabel.stringValue = "Current profile: \(initialProfile.name)\(source)"
  }

  private func updateMatchStatus() {
    let hasTerms = !searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    statusLabel.stringValue =
      !hasTerms
      ? "\(entries.count.formatted()) profiles from AutoEq"
      : "\(filteredEntries.count.formatted()) matches"
  }

  private func setLoadingProfile(name: String) {
    progressIndicator.isHidden = false
    progressIndicator.startAnimation(nil)
    statusLabel.stringValue = "Loading preview for \(name)…"
  }

  private func finishLoadingProfile() {
    progressIndicator.stopAnimation(nil)
    progressIndicator.isHidden = true
  }

  private func showError(_ error: Error) {
    let alert = NSAlert(error: error)
    if let window {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }
}
