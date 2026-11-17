import AppKit

@MainActor
enum StudioHardware {
  static let ivory = NSColor(calibratedRed: 0.88, green: 0.86, blue: 0.81, alpha: 1)
  static let muted = NSColor(calibratedRed: 0.56, green: 0.57, blue: 0.55, alpha: 1)
  static let amber = NSColor(calibratedRed: 1, green: 0.70, blue: 0.31, alpha: 1)
  static let phosphor = NSColor(calibratedRed: 0.57, green: 0.85, blue: 0.72, alpha: 1)
  static let panelImage = image("rack-panel-v1")
  static let knobImage = image("machined-knob-v1")

  private static func image(_ name: String) -> NSImage? {
    if let url = Bundle.main.resourceURL?.appendingPathComponent("StudioSkin/\(name).png"),
      let image = NSImage(contentsOf: url) { return image }
    guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "StudioSkin")
    else { return nil }
    return NSImage(contentsOf: url)
  }

  static func label(_ text: String, size: CGFloat = 10,
                    color: NSColor = ivory, tracking: CGFloat = 1.2) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.attributedStringValue = NSAttributedString(string: text, attributes: [
      .font: NSFont.systemFont(ofSize: size, weight: .semibold),
      .foregroundColor: color, .kern: tracking,
    ])
    return label
  }

  static func screen(_ rect: NSRect, radius: CGFloat = 8) {
    NSColor(calibratedWhite: 0.035, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    NSColor(calibratedWhite: 0.32, alpha: 0.75).setStroke()
    let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
    rim.lineWidth = 1
    rim.stroke()
    let inner = rect.insetBy(dx: 3, dy: 3)
    NSGradient(starting: NSColor(calibratedRed: 0.035, green: 0.057, blue: 0.049, alpha: 1),
      ending: NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.061, alpha: 1))?
      .draw(in: NSBezierPath(roundedRect: inner, xRadius: radius-2, yRadius: radius-2), angle: -90)
    NSColor.black.withAlphaComponent(0.8).setStroke()
    let inset = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: radius-1, yRadius: radius-1)
    inset.lineWidth = 2
    inset.stroke()
  }
}

@MainActor
final class RackPanelView: NSView {
  override var isOpaque: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSGradient(starting: NSColor(calibratedWhite: 0.15, alpha: 1),
      ending: NSColor(calibratedWhite: 0.075, alpha: 1))?.draw(in: bounds, angle: -90)
    StudioHardware.panelImage?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 0.68)
    NSColor.black.withAlphaComponent(0.25).setFill()
    NSRect(x: 0, y: 0, width: 12, height: bounds.height).fill()
    NSRect(x: bounds.width-12, y: 0, width: 12, height: bounds.height).fill()
    NSColor.white.withAlphaComponent(0.10).setStroke()
    let top = NSBezierPath()
    top.move(to: NSPoint(x: 13, y: bounds.height-0.5))
    top.line(to: NSPoint(x: bounds.width-13, y: bounds.height-0.5))
    top.stroke()
    for x in [CGFloat(6), bounds.width-6] {
      for y in [CGFloat(15), bounds.height-15] {
        let screw = NSBezierPath(ovalIn: NSRect(x: x-3.5, y: y-3.5, width: 7, height: 7))
        NSGradient(starting: .darkGray, ending: .black)?.draw(in: screw, angle: -90)
        NSColor(calibratedWhite: 0.30, alpha: 1).setStroke()
        screw.stroke()
        NSColor.black.setStroke()
        let slot = NSBezierPath()
        slot.move(to: NSPoint(x: x-2, y: y-1))
        slot.line(to: NSPoint(x: x+2, y: y+1))
        slot.lineWidth = 1.5
        slot.stroke()
      }
    }
  }
}

@MainActor
final class HardwareWellView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
    NSColor.black.withAlphaComponent(0.16).setFill()
    shape.fill()
    NSColor.white.withAlphaComponent(0.08).setStroke()
    shape.stroke()
  }
}

/// A native slider supplies accessibility semantics and value binding; the face
/// is generated artwork. Only the pointer and scale move, keeping light fixed.
@MainActor
final class HardwareKnob: NSSlider {
  override var isFlipped: Bool { false }
  override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
  var resetValue: Double = 0

  override var doubleValue: Double {
    get { super.doubleValue }
    set { super.doubleValue = newValue; needsDisplay = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    let side = min(bounds.width, bounds.height)
    let center = NSPoint(x: bounds.midX, y: bounds.midY)
    let normalized = maxValue > minValue ? (doubleValue-minValue)/(maxValue-minValue) : 0
    let fraction = min(1, max(0, normalized))
    let opacity: CGFloat = isEnabled ? 1 : 0.38
    for tick in 0...10 {
      let angle = (225-270*Double(tick)/10)*Double.pi/180
      let r = side*0.46
      let mark = NSBezierPath()
      mark.move(to: NSPoint(x: center.x+cos(angle)*r, y: center.y+sin(angle)*r))
      mark.line(to: NSPoint(x: center.x+cos(angle)*(r+3), y: center.y+sin(angle)*(r+3)))
      let lit = Double(tick)/10 <= fraction && isEnabled
      (lit ? StudioHardware.amber.withAlphaComponent(0.8) : StudioHardware.muted.withAlphaComponent(0.45*opacity)).setStroke()
      mark.lineWidth = tick%5 == 0 ? 1.5 : 1
      mark.stroke()
    }
    let face = NSRect(x: center.x-side*0.46, y: center.y-side*0.46, width: side*0.92, height: side*0.92)
    if let image = StudioHardware.knobImage {
      image.draw(in: face, from: .zero, operation: .sourceOver, fraction: opacity)
    } else {
      NSColor.darkGray.setFill()
      NSBezierPath(ovalIn: face.insetBy(dx: side*0.06, dy: side*0.06)).fill()
    }
    let angle = (225-270*fraction)*Double.pi/180
    let pointer = NSBezierPath()
    pointer.move(to: NSPoint(x: center.x+cos(angle)*side*0.20, y: center.y+sin(angle)*side*0.20))
    pointer.line(to: NSPoint(x: center.x+cos(angle)*side*0.31, y: center.y+sin(angle)*side*0.31))
    pointer.lineWidth = max(2, side*0.025)
    pointer.lineCapStyle = .round
    StudioHardware.amber.withAlphaComponent(opacity).setStroke()
    pointer.stroke()
    if window?.firstResponder === self {
      StudioHardware.amber.withAlphaComponent(0.65).setStroke()
      NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).stroke()
    }
  }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled, let window else { return }
    window.makeFirstResponder(self)
    if event.clickCount == 2 { commit(resetValue); return }
    var previous = event.locationInWindow
    while let drag = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      if drag.type == .leftMouseUp { break }
      let precision = drag.modifierFlags.contains(.shift) ? 0.15 : 1.0
      let distance = Double(drag.locationInWindow.y-previous.y)
        + Double(drag.locationInWindow.x-previous.x)*0.35
      previous = drag.locationInWindow
      commit(doubleValue + distance*(maxValue-minValue)/150*precision)
    }
  }

  override func keyDown(with event: NSEvent) {
    guard isEnabled else { return }
    let step = (maxValue-minValue)/(event.modifierFlags.contains(.shift) ? 1000 : 100)
    switch event.keyCode {
    case 123,125: commit(doubleValue-step)
    case 124,126: commit(doubleValue+step)
    case 115: commit(minValue)
    case 119: commit(maxValue)
    default: super.keyDown(with: event)
    }
  }

  override func scrollWheel(with event: NSEvent) {
    guard isEnabled else { return }
    let precision = event.modifierFlags.contains(.shift) ? 0.1 : 1.0
    commit(doubleValue + Double(event.scrollingDeltaY)*(maxValue-minValue)/300*precision)
  }

  private func commit(_ value: Double) {
    doubleValue = min(maxValue, max(minValue, value))
    sendAction(action, to: target)
  }
}

@MainActor
final class HardwareButton: NSButton {
  override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
  var showsPowerLamp = false
  var showsStateLamp = false
  var processingAvailable = true { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    let pressed = cell?.isHighlighted == true
    let rect = bounds.insetBy(dx: 1, dy: 1)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
    NSGradient(starting: NSColor(calibratedWhite: pressed ? 0.10 : 0.25, alpha: 1),
      ending: NSColor(calibratedWhite: 0.105, alpha: 1))?.draw(in: shape, angle: -90)
    NSColor.black.setStroke()
    shape.lineWidth = 1.5
    shape.stroke()
    NSColor.white.withAlphaComponent(0.15).setStroke()
    NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4).stroke()
    let text = showsPowerLamp ? (state == .on ? (processingAvailable ? "ACTIVE" : "READY") : "BYPASS") : title.uppercased()
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
      .foregroundColor: StudioHardware.ivory, .kern: 1.0,
    ]
    let size = text.size(withAttributes: attributes)
    let offset: CGFloat = showsPowerLamp || showsStateLamp ? 8 : 0
    text.draw(at: NSPoint(x: bounds.midX-size.width/2+offset,
      y: bounds.midY-size.height/2-(pressed ? 1 : 0)), withAttributes: attributes)
    if showsPowerLamp || showsStateLamp {
      let lamp = NSRect(x: 15, y: bounds.midY-3, width: 6, height: 6)
      let lampColor = processingAvailable ? StudioHardware.phosphor : StudioHardware.amber
      (state == .on ? lampColor : StudioHardware.muted.withAlphaComponent(0.45)).setFill()
      if state == .on {
        let glow = NSShadow()
        glow.shadowColor = lampColor.withAlphaComponent(0.65)
        glow.shadowBlurRadius = 7
        NSGraphicsContext.saveGraphicsState()
        glow.set()
        NSBezierPath(ovalIn: lamp).fill()
        NSGraphicsContext.restoreGraphicsState()
      } else { NSBezierPath(ovalIn: lamp).fill() }
    }
    if window?.firstResponder === self {
      StudioHardware.amber.setStroke()
      shape.stroke()
    }
  }
}

@MainActor
final class HardwareReadout: NSTextField {
  init() {
    super.init(frame: .zero)
    isEditable = false
    isSelectable = false
    isBordered = false
    drawsBackground = false
    alignment = .center
    font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
    textColor = StudioHardware.amber
    focusRingType = .none
  }
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect: NSRect) {
    StudioHardware.screen(bounds, radius: 4)
    super.draw(dirtyRect)
  }
}
