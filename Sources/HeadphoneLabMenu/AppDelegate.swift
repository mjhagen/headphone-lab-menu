import AVFoundation
import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "nl.mingo.HeadphoneLabMenu",
    category: "audio"
  )
  private let pipeline = AudioPipeline()
  private let autoEqClient = AutoEqCatalogClient()
  private var statusItem: NSStatusItem!
  private var enabledItem: NSMenuItem!
  private var profileItem: NSMenuItem!
  private var peakLimiterItem: NSMenuItem!
  private var gainItem: NSMenuItem!
  private var outputItem: NSMenuItem!
  private var settingsItem: NSMenuItem!
  private var profile: EQProfile?
  private var previewProfile: EQProfile?
  private var userGain: Float = 0
  private var equalizerEnabled = true
  private var peakLimiterEnabled = false
  private var autoEqBrowser: AutoEqBrowserController?
  private var busy = false
  private let profileDefaultsKey = "EqualizerAPOProfile"
  private let gainDefaultsKey = "UserGainDecibels"
  private let enabledDefaultsKey = "EqualizerEnabled"
  private let peakLimiterDefaultsKey = "PeakLimiterEnabled"
  private let legacyAutoTrimDefaultsKey = "AutoTrimEnabled"

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.image = NSImage(
      systemSymbolName: "headphones",
      accessibilityDescription: "Headphone EQ"
    )
    statusItem.button?.imagePosition = .imageOnly

    let menu = NSMenu()
    enabledItem = menu.addItem(withTitle: "Enabled: Starting…", action: nil, keyEquivalent: "")
    enabledItem.isEnabled = false

    profileItem = menu.addItem(withTitle: "Profile: Flat", action: nil, keyEquivalent: "")
    profileItem.isEnabled = false

    peakLimiterItem = menu.addItem(withTitle: "Peak Limiter: Off", action: nil, keyEquivalent: "")
    peakLimiterItem.isEnabled = false

    gainItem = menu.addItem(withTitle: "Output Trim: 0.0 dB", action: nil, keyEquivalent: "")
    gainItem.isEnabled = false

    outputItem = menu.addItem(withTitle: "Output: —", action: nil, keyEquivalent: "")
    outputItem.isEnabled = false

    menu.addItem(.separator())
    settingsItem = menu.addItem(
      withTitle: "Settings…",
      action: #selector(showSettings),
      keyEquivalent: ","
    )
    settingsItem.target = self

    let quitItem = menu.addItem(
      withTitle: "Quit",
      action: #selector(quit),
      keyEquivalent: "q"
    )
    quitItem.target = self
    statusItem.menu = menu

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

    if CommandLine.arguments.contains("--browse-autoeq")
      || CommandLine.arguments.contains("--browse-autoeq-live")
    {
      showSettings()
      if !CommandLine.arguments.contains("--browse-autoeq-live") {
        refreshMenu()
        return
      }
    }

    if !equalizerEnabled {
      refreshMenu()
      return
    }

    setBusy(true, title: "Starting…")
    Task {
      do {
        try await pipeline.start(
          profile: profile,
          userGain: userGain,
          peakLimiterEnabled: peakLimiterEnabled
        )
        logger.info("Equalizer started on \(self.pipeline.outputName, privacy: .public)")
        autoEqBrowser?.setEqualizerEnabled(true)
        refreshMenu()
      } catch {
        logger.error("Equalizer startup failed: \(error.localizedDescription, privacy: .public)")
        setBusy(false)
        showError(error)
        refreshMenu()
      }
    }
  }

  private func setEqualizerEnabled(_ enabled: Bool) {
    guard !busy else {
      autoEqBrowser?.setEqualizerEnabled(pipeline.isRunning)
      return
    }
    guard enabled != pipeline.isRunning else { return }
    equalizerEnabled = enabled
    UserDefaults.standard.set(enabled, forKey: enabledDefaultsKey)

    if !enabled {
      pipeline.stop()
      autoEqBrowser?.setEqualizerEnabled(false)
      refreshMenu()
    } else {
      setBusy(true)
      Task {
        do {
          try await pipeline.start(
            profile: previewProfile ?? profile,
            userGain: userGain,
            peakLimiterEnabled: peakLimiterEnabled
          )
          logger.info("Equalizer started on \(self.pipeline.outputName, privacy: .public)")
          autoEqBrowser?.setEqualizerEnabled(true)
        } catch {
          self.equalizerEnabled = false
          UserDefaults.standard.set(false, forKey: self.enabledDefaultsKey)
          logger.error("Startup failed: \(error.localizedDescription, privacy: .public)")
          NSLog("Headphone EQ startup failed: %@", error.localizedDescription)
          autoEqBrowser?.setEqualizerEnabled(false)
          showError(error)
        }
        setBusy(false)
        refreshMenu()
      }
    }
  }

  @objc private func showSettings() {
    if let autoEqBrowser {
      autoEqBrowser.showWindow(nil)
      return
    }

    let originalProfile = profile
    let browser = AutoEqBrowserController(
      client: autoEqClient,
      initialProfile: originalProfile,
      initialGain: userGain,
      initialEnabled: pipeline.isRunning,
      initialPeakLimiter: peakLimiterEnabled,
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
    pipeline.stop()
    NSApp.terminate(nil)
  }

  func applicationWillTerminate(_ notification: Notification) {
    pipeline.stop()
  }

  private func setBusy(_ value: Bool, title: String? = nil) {
    busy = value
    enabledItem?.title =
      value
      ? title.map { "Enabled: \($0)" } ?? "Enabled: Starting…"
      : "Enabled: Off"
  }

  private func refreshMenu() {
    busy = false
    enabledItem.title = pipeline.isRunning ? "Enabled: On" : "Enabled: Off"
    let displayedProfile = previewProfile ?? profile
    profileItem.title =
      displayedProfile.map {
        let prefix = previewProfile == nil ? "Profile" : "Preview"
        return "\(prefix): \($0.name) (\($0.filters.count) filters)"
      } ?? "Profile: Flat"
    peakLimiterItem.title = "Peak Limiter: \(peakLimiterEnabled ? "On" : "Off")"
    gainItem.title = String(format: "Output Trim: %+.1f dB", userGain)
    outputItem.title = pipeline.isRunning ? "Output: \(pipeline.outputName)" : "Output: —"
    autoEqBrowser?.setEqualizerEnabled(pipeline.isRunning)
    statusItem.button?.appearsDisabled = !pipeline.isRunning
    statusItem.button?.toolTip =
      pipeline.isRunning
      ? "Headphone EQ is processing \(pipeline.outputName)"
      : "Headphone EQ is off"
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
