import AVFoundation
import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "nl.mingo.HeadphoneLabMenu",
    category: "audio"
  )
  private let pipeline = AudioPipeline()
  private var statusItem: NSStatusItem!
  private var toggleItem: NSMenuItem!
  private var editorItem: NSMenuItem!
  private var outputItem: NSMenuItem!
  private var editorWindow: NSWindow?
  private var busy = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.image = NSImage(
      systemSymbolName: "headphones",
      accessibilityDescription: "Headphone Lab"
    )
    statusItem.button?.imagePosition = .imageOnly

    let menu = NSMenu()
    toggleItem = menu.addItem(
      withTitle: "Enable Headphone Lab",
      action: #selector(toggle),
      keyEquivalent: ""
    )
    toggleItem.target = self

    editorItem = menu.addItem(
      withTitle: "Open Headphone Lab…",
      action: #selector(openEditor),
      keyEquivalent: ","
    )
    editorItem.target = self
    editorItem.isEnabled = false

    outputItem = menu.addItem(withTitle: "Output: —", action: nil, keyEquivalent: "")
    outputItem.isEnabled = false

    menu.addItem(.separator())
    let quitItem = menu.addItem(
      withTitle: "Quit",
      action: #selector(quit),
      keyEquivalent: "q"
    )
    quitItem.target = self
    statusItem.menu = menu

    setBusy(true, title: "Starting…")
    Task {
      do {
        try await pipeline.start()
        logger.info("Processing started on \(self.pipeline.outputName, privacy: .public)")
        refreshMenu()
      } catch {
        logger.error("Startup failed: \(error.localizedDescription, privacy: .public)")
        NSLog("Headphone Lab startup failed: %@", error.localizedDescription)
        setBusy(false)
        showError(error)
        refreshMenu()
      }
    }
  }

  @objc private func toggle() {
    guard !busy else { return }
    if pipeline.isRunning {
      discardEditor()
      pipeline.stop()
      refreshMenu()
    } else {
      setBusy(true, title: "Starting…")
      Task {
        do {
          try await pipeline.start()
          logger.info("Processing started on \(self.pipeline.outputName, privacy: .public)")
        } catch {
          logger.error("Startup failed: \(error.localizedDescription, privacy: .public)")
          NSLog("Headphone Lab startup failed: %@", error.localizedDescription)
          showError(error)
        }
        setBusy(false)
        refreshMenu()
      }
    }
  }

  @objc private func openEditor() {
    guard let effect = pipeline.effect else { return }
    pipeline.saveState()

    if let editorWindow {
      editorWindow.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    do {
      let view = try AudioUnitEditor.makeView(for: effect)
      let contentSize =
        view.frame.size.width > 0
        ? view.frame.size
        : NSSize(width: 900, height: 620)
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: contentSize),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
      )
      window.title = "Headphone Lab"
      window.contentView = view
      window.delegate = self
      window.isReleasedWhenClosed = false
      window.center()
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      editorWindow = window
    } catch {
      showError(error)
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    pipeline.saveState()
    sender.orderOut(nil)
    return false
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  @objc private func quit() {
    discardEditor()
    pipeline.stop()
    NSApp.terminate(nil)
  }

  func applicationWillTerminate(_ notification: Notification) {
    discardEditor()
    pipeline.stop()
  }

  private func discardEditor() {
    guard let editorWindow else { return }
    editorWindow.delegate = nil
    editorWindow.orderOut(nil)
    editorWindow.contentView = nil
    self.editorWindow = nil
  }

  private func setBusy(_ value: Bool, title: String? = nil) {
    busy = value
    toggleItem?.isEnabled = !value
    if let title { toggleItem?.title = title }
  }

  private func refreshMenu() {
    busy = false
    toggleItem.isEnabled = true
    toggleItem.title = pipeline.isRunning ? "Disable Headphone Lab" : "Enable Headphone Lab"
    toggleItem.state = pipeline.isRunning ? .on : .off
    editorItem.isEnabled = pipeline.isRunning
    outputItem.title = pipeline.isRunning ? "Output: \(pipeline.outputName)" : "Output: —"
    statusItem.button?.appearsDisabled = !pipeline.isRunning
    statusItem.button?.toolTip =
      pipeline.isRunning
      ? "Headphone Lab is processing \(pipeline.outputName)"
      : "Headphone Lab is off"
  }

  private func showError(_ error: Error) {
    showErrorMessage((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
  }

  private func showErrorMessage(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "Headphone Lab couldn’t start"
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}
