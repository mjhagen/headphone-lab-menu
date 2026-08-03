import AppKit
import QuartzCore

@MainActor
final class SpectrumView: NSView {
  var profile: EQProfile? {
    didSet { updateResponsePath() }
  }
  var userGain: Float = 0 {
    didSet { updateResponsePath() }
  }

  private let backgroundLayer = CALayer()
  private let gridLayer = CAShapeLayer()
  private let fillLayer = CAShapeLayer()
  private let spectrumLayer = CAShapeLayer()
  private let warningLayer = CAShapeLayer()
  private let responseLayer = CAShapeLayer()
  private let peakLabel = NSTextField(labelWithString: "PEAK  — dBFS")
  private var axisLabels: [NSTextField] = []
  private var frameProvider: (() -> SpectrumSnapshot?)?
  private var updateTimer: Timer?
  private var latestSampleRate = 48_000.0
  private var lastPeakText = ""
  private let updateInterval = 1.0 / 15.0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer = CALayer()
    guard let layer else { return }

    backgroundLayer.backgroundColor =
      NSColor(
        calibratedRed: 0.035,
        green: 0.045,
        blue: 0.06,
        alpha: 1
      ).cgColor
    backgroundLayer.cornerRadius = 8
    layer.addSublayer(backgroundLayer)

    configureShapeLayer(gridLayer, color: NSColor.white.withAlphaComponent(0.16), width: 0.5)
    fillLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.18).cgColor
    fillLayer.strokeColor = nil
    configureShapeLayer(spectrumLayer, color: NSColor.systemBlue.withAlphaComponent(0.92), width: 1)
    configureShapeLayer(warningLayer, color: .systemRed, width: 2)
    configureShapeLayer(responseLayer, color: .systemGreen, width: 2)
    for shape in [gridLayer, fillLayer, spectrumLayer, warningLayer, responseLayer] {
      layer.addSublayer(shape)
    }
    configureLabels()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateContentsScale()
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    backgroundLayer.frame = bounds
    for shape in [gridLayer, fillLayer, spectrumLayer, warningLayer, responseLayer] {
      shape.frame = bounds
    }
    gridLayer.path = makeGridPath()
    CATransaction.commit()
    layoutLabels()
    updateResponsePath()
  }

  func start(frameProvider: @escaping () -> SpectrumSnapshot?) {
    self.frameProvider = frameProvider
    guard updateTimer == nil else { return }
    let timer = Timer(timeInterval: updateInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.updateSpectrum()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    updateTimer = timer
    updateSpectrum()
  }

  func stop() {
    updateTimer?.invalidate()
    updateTimer = nil
    frameProvider = nil
    for shape in [fillLayer, spectrumLayer, warningLayer] {
      shape.removeAllAnimations()
    }
  }

  private var plotRect: CGRect {
    CGRect(x: 34, y: 26, width: max(1, bounds.width - 44), height: max(1, bounds.height - 42))
  }

  private func configureShapeLayer(_ shape: CAShapeLayer, color: NSColor, width: CGFloat) {
    shape.fillColor = nil
    shape.strokeColor = color.cgColor
    shape.lineWidth = width
    shape.lineJoin = .round
    shape.lineCap = .round
  }

  private func configureLabels() {
    peakLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    peakLabel.textColor = .secondaryLabelColor
    peakLabel.alignment = .right
    addSubview(peakLabel)

    for text in ["-60", "-40", "-20", "0", "20", "100", "1k", "10k", "20k"] {
      let label = NSTextField(labelWithString: text)
      label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
      label.textColor = NSColor.white.withAlphaComponent(0.52)
      label.alignment = .center
      axisLabels.append(label)
      addSubview(label)
    }
    let audio = makeLegendLabel("●  AUDIO", color: .systemBlue)
    audio.frame = NSRect(x: 44, y: bounds.height - 24, width: 64, height: 16)
    audio.autoresizingMask = [.minYMargin]
    addSubview(audio)
    let eq = makeLegendLabel("●  EQ", color: .systemGreen)
    eq.frame = NSRect(x: 108, y: bounds.height - 24, width: 44, height: 16)
    eq.autoresizingMask = [.minYMargin]
    addSubview(eq)
  }

  private func makeLegendLabel(_ text: String, color: NSColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 9, weight: .medium)
    label.textColor = color
    return label
  }

  private func layoutLabels() {
    guard axisLabels.count == 9 else { return }
    let plot = plotRect
    for (index, decibels) in [-60.0, -40.0, -20.0, 0.0].enumerated() {
      axisLabels[index].frame = NSRect(
        x: 0,
        y: yPosition(Float(decibels)) - 7,
        width: 32,
        height: 14
      )
    }
    let frequencies = [20.0, 100.0, 1_000.0, 10_000.0, 20_000.0]
    for (offset, frequency) in frequencies.enumerated() {
      axisLabels[offset + 4].frame = NSRect(
        x: xPosition(frequency) - 20,
        y: plot.minY - 18,
        width: 40,
        height: 14
      )
    }
    peakLabel.frame = NSRect(
      x: max(150, bounds.width - 180),
      y: bounds.height - 25,
      width: 164,
      height: 16
    )
  }

  private func updateContentsScale() {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    for shape in [gridLayer, fillLayer, spectrumLayer, warningLayer, responseLayer] {
      shape.contentsScale = scale
    }
  }

  private func updateSpectrum() {
    guard window?.isVisible == true, let snapshot = frameProvider?() else { return }
    if latestSampleRate != snapshot.sampleRate {
      latestSampleRate = snapshot.sampleRate
      updateResponsePath()
    }

    let paths = makeSpectrumPaths(snapshot)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fillLayer.path = paths.fill
    warningLayer.path = paths.warning
    CATransaction.commit()
    animate(spectrumLayer, to: paths.line)
    showPeak(snapshot)
  }

  private func animate(_ shape: CAShapeLayer, to path: CGPath) {
    let previous = shape.presentation()?.path ?? shape.path
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shape.path = path
    CATransaction.commit()
    guard let previous else { return }
    let animation = CABasicAnimation(keyPath: "path")
    animation.fromValue = previous
    animation.toValue = path
    animation.duration = updateInterval
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    shape.add(animation, forKey: "spectrumMorph")
  }

  private func makeSpectrumPaths(_ snapshot: SpectrumSnapshot) -> (
    line: CGPath, fill: CGPath, warning: CGPath
  ) {
    // One point per logical display point is already two pixels apart on a
    // Retina panel; Core Animation anti-aliases and interpolates between them.
    let pointCount = min(768, max(384, Int(plotRect.width)))
    var points = [CGPoint]()
    points.reserveCapacity(pointCount + 1)
    var levels = [Float]()
    levels.reserveCapacity(pointCount + 1)

    for pixel in 0...pointCount {
      let lowerFraction = Double(max(0, pixel - 1)) / Double(pointCount)
      let upperFraction = Double(min(pointCount, pixel + 1)) / Double(pointCount)
      let lowerFrequency = 20 * pow(1_000, lowerFraction)
      let upperFrequency = 20 * pow(1_000, upperFraction)
      let firstBin = max(
        1,
        Int(lowerFrequency * Double(AudioSpectrumAnalyzer.fftSize) / snapshot.sampleRate)
      )
      let lastBin = min(
        snapshot.magnitudes.count - 1,
        max(
          firstBin,
          Int(upperFrequency * Double(AudioSpectrumAnalyzer.fftSize) / snapshot.sampleRate))
      )
      var level: Float = -120
      if firstBin <= lastBin {
        for bin in firstBin...lastBin {
          level = max(level, snapshot.magnitudes[bin])
        }
      }
      let x = plotRect.minX + CGFloat(pixel) / CGFloat(pointCount) * plotRect.width
      points.append(CGPoint(x: x, y: yPosition(level)))
      levels.append(level)
    }

    let line = CGMutablePath()
    if let first = points.first {
      line.move(to: first)
      for point in points.dropFirst() { line.addLine(to: point) }
    }
    let fill = CGMutablePath()
    fill.move(to: CGPoint(x: plotRect.minX, y: plotRect.minY))
    for point in points { fill.addLine(to: point) }
    fill.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.minY))
    fill.closeSubpath()

    let warning = CGMutablePath()
    var continuing = false
    for (point, level) in zip(points, levels) {
      if level >= -1 {
        continuing ? warning.addLine(to: point) : warning.move(to: point)
        continuing = true
      } else {
        continuing = false
      }
    }
    return (line, fill, warning)
  }

  private func updateResponsePath() {
    guard bounds.width > 1 else { return }
    let path = CGMutablePath()
    let count = 2_048
    for index in 0..<count {
      let fraction = Double(index) / Double(count - 1)
      let frequency = 20 * pow(1_000, fraction)
      let decibels = EQResponse.decibels(
        profile: profile,
        frequency: frequency,
        sampleRate: latestSampleRate,
        userGain: userGain
      )
      let point = CGPoint(x: xPosition(frequency), y: yPosition(decibels))
      index == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    responseLayer.path = path
    CATransaction.commit()
  }

  private func makeGridPath() -> CGPath {
    let path = CGMutablePath()
    for decibels in stride(from: -60, through: 0, by: 20) {
      let y = yPosition(Float(decibels))
      path.move(to: CGPoint(x: plotRect.minX, y: y))
      path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
    }
    for frequency in [20.0, 100.0, 1_000.0, 10_000.0, 20_000.0] {
      let x = xPosition(frequency)
      path.move(to: CGPoint(x: x, y: plotRect.minY))
      path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
    }
    return path
  }

  private func showPeak(_ snapshot: SpectrumSnapshot) {
    let decibels = snapshot.peakDecibels
    let text: String
    let color: NSColor
    if snapshot.peak >= 1 {
      text = String(format: "CLIPPING  %+.1f dBFS", decibels)
      color = .systemRed
    } else if decibels >= -1 {
      text = String(format: "NEAR CLIPPING  %.1f dBFS", decibels)
      color = .systemOrange
    } else {
      text = String(format: "PEAK  %.1f dBFS", decibels)
      color = NSColor.white.withAlphaComponent(0.58)
    }
    guard text != lastPeakText else { return }
    lastPeakText = text
    peakLabel.stringValue = text
    peakLabel.textColor = color
  }

  private func xPosition(_ frequency: Double) -> CGFloat {
    let fraction = log10(frequency / 20) / log10(1_000)
    return plotRect.minX + CGFloat(fraction) * plotRect.width
  }

  private func yPosition(_ decibels: Float) -> CGFloat {
    let clamped = min(12, max(-72, decibels))
    return plotRect.minY + CGFloat((clamped + 72) / 84) * plotRect.height
  }
}
