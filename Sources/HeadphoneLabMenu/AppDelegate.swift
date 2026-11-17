import AVFoundation
import AppKit
import OSLog
import ServiceManagement
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "nl.mingo.HeadphoneLabMenu",
    category: "audio"
  )
  private let pipeline = AudioPipeline()
  private let autoEqClient = AutoEqCatalogClient()
  private var updaterController: SPUStandardUpdaterController!
  private var statusItem: NSStatusItem!
  private let headphoneMenu = HeadphoneMenu()
  private let outputMonitor = AudioOutputMonitor()
  private lazy var routing = HeadphoneRoutingController(
    enabled: equalizerEnabled,
    headphoneOutputKeys: Set(UserDefaults.standard.stringArray(forKey: "HeadphoneOutputSources") ?? []),
    start: { [unowned self] output in
      try self.pipeline.start(
        output: output,
        profile: self.previewProfile ?? self.profile,
        userGain: self.userGain,
        peakLimiterEnabled: self.peakLimiterEnabled,
        spatialSettings: self.spatialSettings
      )
      self.logger.info("Equalizer started on \(output.name, privacy: .public)")
    },
    stop: { [unowned self] in self.pipeline.stop() }
  )
  private var profile: EQProfile?
  private var previewProfile: EQProfile?
  private var userGain: Float = 0
  private var equalizerEnabled = true
  private var peakLimiterEnabled = false
  private var autoEqBrowser: AutoEqBrowserController?
  private var spatialWindow: SpatialAudioController?
  private var spatialSettings = SpatialAudioSettings()
  private var spatialUpdateTask: Task<Void, Never>?
  private var spatialRevision = 0
  private let spatialDefaultsKey = "SpatialAudioSettings"
  private let profileDefaultsKey = "EqualizerAPOProfile"
  private let gainDefaultsKey = "UserGainDecibels"
  private let enabledDefaultsKey = "EqualizerEnabled"
  private let peakLimiterDefaultsKey = "PeakLimiterEnabled"
  private let legacyAutoTrimDefaultsKey = "AutoTrimEnabled"

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.image = NSImage(
      systemSymbolName: "headphones",
      accessibilityDescription: "Headphone EQ"
    )
    statusItem.button?.imagePosition = .imageOnly

    let bindings: [(NSMenuItem, Selector)] = [
      (headphoneMenu.processingItem, #selector(toggleProcessing)),
      (headphoneMenu.profileItem, #selector(showConfiguration)),
      (headphoneMenu.soundstageItem, #selector(showSoundstage)),
      (headphoneMenu.limiterItem, #selector(toggleLimiter)),
      (headphoneMenu.trimItem, #selector(showConfiguration)),
      (headphoneMenu.outputItem, #selector(showAudioOutput)),
      (headphoneMenu.identifyItem, #selector(toggleHeadphoneOutput)),
      (headphoneMenu.loginItem, #selector(toggleRunAtStartup)),
      (headphoneMenu.quitItem, #selector(quit)),
    ]
    for (item, action) in bindings {
      item.target = self
      item.action = action
    }
    headphoneMenu.updatesItem.target = updaterController
    headphoneMenu.updatesItem.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
    headphoneMenu.menu.delegate = self
    statusItem.menu = headphoneMenu.menu

    if let data = UserDefaults.standard.data(forKey: spatialDefaultsKey),
      let saved = try? JSONDecoder().decode(SpatialAudioSettings.self, from: data) {
      spatialSettings = saved.normalized
    }
    if let data = UserDefaults.standard.data(forKey: profileDefaultsKey) {
      profile = try? JSONDecoder().decode(EQProfile.self, from: data)
    }
    if UserDefaults.standard.object(forKey: gainDefaultsKey) != nil {
      userGain = min(0, max(-24, UserDefaults.standard.float(forKey: gainDefaultsKey)))
    }
    if UserDefaults.standard.object(forKey: enabledDefaultsKey) != nil {
      equalizerEnabled = UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }
    if UserDefaults.standard.object(forKey: peakLimiterDefaultsKey) != nil {
      peakLimiterEnabled = UserDefaults.standard.bool(forKey: peakLimiterDefaultsKey)
    } else if UserDefaults.standard.object(forKey: legacyAutoTrimDefaultsKey) != nil {
      peakLimiterEnabled = UserDefaults.standard.bool(forKey: legacyAutoTrimDefaultsKey)
      UserDefaults.standard.set(peakLimiterEnabled, forKey: peakLimiterDefaultsKey)
      UserDefaults.standard.removeObject(forKey: legacyAutoTrimDefaultsKey)
    }
    if peakLimiterEnabled {
      userGain = 0
      UserDefaults.standard.set(userGain, forKey: gainDefaultsKey)
    }

    refreshRunAtStartupItem()

    if CommandLine.arguments.contains("--browse-soundstage") {
      showSoundstage()
      refreshMenu()
      return
    }

    if CommandLine.arguments.contains("--browse-autoeq")
      || CommandLine.arguments.contains("--browse-autoeq-live")
    {
      showConfiguration()
      if !CommandLine.arguments.contains("--browse-autoeq-live") {
        refreshMenu()
        return
      }
    }

    routing.onChange = { [weak self] in self?.refreshMenu() }
    routing.onError = { [weak self] error in
      self?.logger.error("Equalizer startup failed: \(error.localizedDescription, privacy: .public)")
      if case AudioRouteError.outputChanged = error {
        self?.outputMonitor.refresh(force: true)
      } else {
        self?.showError(error)
      }
    }
    outputMonitor.onChange = { [weak self] output in self?.routing.updateOutput(output) }
    do {
      try outputMonitor.start()
    } catch {
      showError(error)
      refreshMenu()
    }
  }

  @objc private func toggleProcessing() {
    setEqualizerEnabled(!equalizerEnabled)
  }

  @objc private func toggleLimiter() {
    setPeakLimiter(!peakLimiterEnabled)
  }

  @objc private func showAudioOutput() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Sound.prefPane"))
  }

  @objc private func toggleHeadphoneOutput() {
    routing.setHeadphoneOverride(!routing.usesHeadphoneOverride)
    UserDefaults.standard.set(routing.headphoneOutputKeys.sorted(), forKey: "HeadphoneOutputSources")
  }

  private func setEqualizerEnabled(_ enabled: Bool) {
    equalizerEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: enabledDefaultsKey)
    routing.setEnabled(enabled)
  }

  @objc private func showSoundstage() {
    if let spatialWindow { spatialWindow.showWindow(nil); return }
    let controller = SpatialAudioController(settings: spatialSettings,
      liveProvider: { [weak self] in self?.pipeline.liveSoundstageSnapshot() },
      onMonitoringChange: { [weak self] enabled in self?.pipeline.setLiveMonitoring(enabled) },
      onChange: { [weak self] settings in self?.setSpatialSettings(settings) },
      onClose: { [weak self] in self?.spatialWindow = nil })
    spatialWindow = controller
    controller.setProcessingActive(pipeline.isRunning)
    controller.showWindow(nil)
  }

  private func setSpatialSettings(_ settings: SpatialAudioSettings) {
    let enableRequested = !spatialSettings.enabled && settings.enabled
    spatialSettings = settings.normalized
    if let data = try? JSONEncoder().encode(spatialSettings) {
      UserDefaults.standard.set(data, forKey: spatialDefaultsKey)
    }
    spatialRevision += 1
    let revision = spatialRevision
    spatialUpdateTask?.cancel()
    if enableRequested && !pipeline.isRunning {
      setEqualizerEnabled(true)
      refreshMenu()
      return
    }
    refreshMenu()
    guard pipeline.isRunning else { return }
    spatialWindow?.setStatus("Applying soundstage…")
    spatialUpdateTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(120)) }
      catch { return }
      guard let self, !Task.isCancelled else { return }
      self.pipeline.applySpatial(self.spatialSettings) { [weak self] error in
        guard let self, self.spatialRevision == revision else { return }
        if let error {
          self.spatialSettings.enabled = false
          if let data = try? JSONEncoder().encode(self.spatialSettings) {
            UserDefaults.standard.set(data, forKey: self.spatialDefaultsKey)
          }
          self.pipeline.applySpatial(self.spatialSettings) { _ in }
          self.spatialWindow?.setSettings(self.spatialSettings)
          self.refreshMenu()
          self.showErrorMessage(error)
        } else {
          self.spatialWindow?.setSettings(self.spatialSettings)
        }
      }
    }
  }

  @objc private func showConfiguration() {
    if let autoEqBrowser {
      autoEqBrowser.showWindow(nil)
      return
    }

    let originalProfile = profile
    let browser = AutoEqBrowserController(
      client: autoEqClient,
      initialProfile: originalProfile,
      initialGain: userGain,
      initialEnabled: equalizerEnabled,
      initialPeakLimiter: peakLimiterEnabled,
      onSoundstage: { [weak self] in self?.showSoundstage() },
      spectrumProvider: { [weak self] in
        self?.pipeline.spectrumSnapshot()
      },
      onGainChange: { [weak self] gain in
        self?.setUserGain(gain)
      },
      onEnabledChange: { [weak self] enabled in
        self?.setEqualizerEnabled(enabled)
      },
      onPeakLimiterChange: { [weak self] enabled in
        self?.setPeakLimiter(enabled)
      },
      onPreview: { [weak self] profile in
        self?.preview(profile)
      },
      onCommit: { [weak self] profile in
        self?.setProfile(profile)
      },
      onCancel: { [weak self] in
        self?.restorePreview(originalProfile)
      },
      onClose: { [weak self] in
        self?.autoEqBrowser = nil
      }
    )
    autoEqBrowser = browser
    refreshMenu()
    browser.showWindow(nil)
  }

  private func setProfile(_ newProfile: EQProfile?) {
    profile = newProfile
    previewProfile = nil
    if let newProfile, let data = try? JSONEncoder().encode(newProfile) {
      UserDefaults.standard.set(data, forKey: profileDefaultsKey)
    } else {
      UserDefaults.standard.removeObject(forKey: profileDefaultsKey)
    }
    pipeline.apply(profile: newProfile, userGain: userGain)
    refreshMenu()
  }

  private func preview(_ newProfile: EQProfile) {
    previewProfile = newProfile
    pipeline.apply(profile: newProfile, userGain: userGain)
    refreshMenu()
  }

  private func restorePreview(_ originalProfile: EQProfile?) {
    previewProfile = nil
    pipeline.apply(profile: originalProfile, userGain: userGain)
    refreshMenu()
  }

  private func setUserGain(_ gain: Float) {
    userGain = peakLimiterEnabled ? 0 : min(0, max(-24, gain))
    UserDefaults.standard.set(userGain, forKey: gainDefaultsKey)
    pipeline.apply(profile: previewProfile ?? profile, userGain: userGain)
    refreshMenu()
  }

  private func setPeakLimiter(_ enabled: Bool) {
    peakLimiterEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: peakLimiterDefaultsKey)
    pipeline.setPeakLimiter(enabled)
    if enabled { setUserGain(0) }
    autoEqBrowser?.setPeakLimiter(enabled)
    refreshMenu()
  }

  @objc private func quit() {
    outputMonitor.stop()
    pipeline.stop()
    NSApp.terminate(nil)
  }

  @objc private func toggleRunAtStartup() {
    let service = SMAppService.mainApp

    do {
      switch service.status {
      case .enabled:
        try service.unregister()
      case .notRegistered:
        try service.register()
      case .requiresApproval:
        SMAppService.openSystemSettingsLoginItems()
      case .notFound:
        showErrorMessage("Headphone EQ must be run from its app bundle to start automatically.")
      @unknown default:
        showErrorMessage("The current startup setting could not be determined.")
      }
    } catch {
      logger.error("Updating startup setting failed: \(error.localizedDescription, privacy: .public)")
      showError(error)
    }

    refreshRunAtStartupItem()
  }

  func menuWillOpen(_ menu: NSMenu) {
    outputMonitor.refresh()
    refreshRunAtStartupItem()
  }

  func applicationWillTerminate(_ notification: Notification) {
    outputMonitor.stop()
    pipeline.stop()
  }

  private func refreshMenu() {
    let displayedProfile = previewProfile ?? profile
    headphoneMenu.update(enabled: equalizerEnabled, processing: pipeline.isRunning,
      failed: routing.error != nil, outputName: routing.output?.name,
      headphonesSelected: routing.headphonesSelected,
      allowsIdentification: routing.output?.allowsHeadphoneIdentification == true,
      headphoneOverride: routing.usesHeadphoneOverride,
      profileName: displayedProfile?.name, previewing: previewProfile != nil,
      soundstageEnabled: spatialSettings.enabled, limiterEnabled: peakLimiterEnabled, gain: userGain)
    let waiting = equalizerEnabled && !routing.headphonesSelected
    autoEqBrowser?.setEqualizerEnabled(equalizerEnabled, waitingForHeadphones: waiting)
    spatialWindow?.setProcessingActive(pipeline.isRunning)
    statusItem.button?.appearsDisabled = false
    statusItem.button?.toolTip =
      pipeline.isRunning
      ? "Headphone EQ is processing \(pipeline.outputName)"
      : waiting ? "Headphone EQ is waiting for headphones" : "Headphone EQ is off"
  }

  private func refreshRunAtStartupItem() {
    let status = SMAppService.mainApp.status
    headphoneMenu.loginItem.state = status == .enabled ? .on : .off
    headphoneMenu.loginItem.title =
      status == .requiresApproval ? "Launch at Login…" : "Launch at Login"
    headphoneMenu.loginItem.toolTip =
      status == .requiresApproval
      ? "Enable Headphone EQ in System Settings > General > Login Items"
      : nil
  }

  private func showError(_ error: Error) {
    showErrorMessage((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
  }

  private func showErrorMessage(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "Headphone EQ"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}
