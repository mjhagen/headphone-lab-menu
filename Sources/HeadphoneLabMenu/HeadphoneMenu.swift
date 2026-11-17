import AppKit

/// Standard AppKit menu items preserve system typography, materials, keyboard
/// navigation, checkmarks, and light/dark appearance.
@MainActor
final class HeadphoneMenu {
  let menu = NSMenu()
  let statusItem = NSMenuItem(title: "Waiting for Headphones", action: nil, keyEquivalent: "")
  let processingItem = NSMenuItem(title: "Headphone Processing", action: nil, keyEquivalent: "")
  let profileItem = NSMenuItem(title: "Headphone Profile…", action: nil, keyEquivalent: "")
  let soundstageItem = NSMenuItem(title: "Binaural Soundstage…", action: nil, keyEquivalent: "")
  let limiterItem = NSMenuItem(title: "Peak Limiter", action: nil, keyEquivalent: "")
  let trimItem = NSMenuItem(title: "Output Trim: 0.0 dB…", action: nil, keyEquivalent: "")
  let outputItem = NSMenuItem(title: "Audio Output…", action: nil, keyEquivalent: "")
  let identifyItem = NSMenuItem(title: "Use as Headphone Output", action: nil, keyEquivalent: "")
  let updatesItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
  let loginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
  let quitItem = NSMenuItem(title: "Quit Headphone EQ", action: nil, keyEquivalent: "q")

  init() {
    menu.minimumWidth = 270
    menu.addItem(.sectionHeader(title: "Headphone EQ"))
    menu.addItem(processingItem)
    menu.addItem(statusItem)
    menu.addItem(.separator())
    for (item, symbol) in [(profileItem, "headphones"),
      (soundstageItem, "speaker.wave.2"), (limiterItem, "waveform.path"),
      (trimItem, "speaker.minus")] {
      item.image = Self.symbol(symbol)
      menu.addItem(item)
    }
    menu.addItem(.separator())
    outputItem.image = Self.symbol("hifispeaker")
    identifyItem.image = Self.symbol("headphones")
    menu.addItem(outputItem)
    menu.addItem(identifyItem)
    menu.addItem(.separator())
    menu.addItem(updatesItem)
    menu.addItem(loginItem)
    menu.addItem(.separator())
    menu.addItem(quitItem)
    statusItem.isEnabled = false
    identifyItem.isHidden = true
    processingItem.toolTip = "Automatically apply your listening settings on headphones. Turn off to prevent automatic resume."
    profileItem.toolTip = "Browse headphone measurements, choose an EQ profile, or open an Equalizer APO file."
    soundstageItem.toolTip = "Configure virtual loudspeakers, your HRTF listening profile, and room acoustics."
    limiterItem.toolTip = "Prevent digital sample clipping. Enabling the limiter resets output trim to 0 dB."
    identifyItem.toolTip = "Remember this output as a headphone DAC. Clear the checkmark to return to automatic detection."
    outputItem.toolTip = "Select your playback device in macOS Sound settings."
  }

  func update(enabled: Bool, processing: Bool, failed: Bool,
    outputName: String?, headphonesSelected: Bool, allowsIdentification: Bool,
    headphoneOverride: Bool, profileName: String?, previewing: Bool,
    soundstageEnabled: Bool, limiterEnabled: Bool, gain: Float) {
    processingItem.state = enabled ? .on : .off
    statusItem.title = processing ? "Processing Headphone Audio" : !enabled ? "Processing Off"
      : failed ? "Unable to Start Processing" : "Waiting for Headphones"
    statusItem.toolTip = enabled && !headphonesSelected
      ? "Choose headphones in Audio Output. Your saved listening settings will resume automatically."
      : nil
    let profileTitle = previewing ? "Preview Headphone Profile…" : "Headphone Profile…"
    detail(profileItem, title: profileTitle, subtitle: profileName ?? "Flat Response")
    let spatialDetail = !soundstageEnabled ? "Off · Original Stereo"
      : processing ? "Enabled · Virtual Speakers" : "Enabled · Paused"
    detail(soundstageItem, title: "Binaural Soundstage…", subtitle: spatialDetail)
    limiterItem.state = limiterEnabled ? .on : .off
    let trim = String(format: "Output Trim: %.1f dB…", gain == 0 ? 0 : gain)
    trimItem.title = trim
    trimItem.toolTip = limiterEnabled
      ? "Output trim is managed by Peak Limiter. Open equalizer settings to change it."
      : "Open equalizer settings to adjust output trim from −24 to 0 dB."
    detail(outputItem, title: "Audio Output…", subtitle: outputName ?? "No Output Selected")
    outputItem.image = Self.symbol(headphonesSelected ? "headphones" : "hifispeaker")
    // Only show identification when it is useful for an ambiguous DAC or device.
    identifyItem.isHidden = !headphoneOverride && (!allowsIdentification || headphonesSelected)
    identifyItem.state = headphoneOverride ? .on : .off
  }

  private func detail(_ item: NSMenuItem, title: String, subtitle: String) {
    if #available(macOS 14.4, *) {
      item.title = title
      item.subtitle = subtitle
    } else {
      item.title = "\(title.dropLast()): \(subtitle)…"
    }
  }

  private static func symbol(_ name: String) -> NSImage? {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    image?.isTemplate = true
    return image
  }
}
