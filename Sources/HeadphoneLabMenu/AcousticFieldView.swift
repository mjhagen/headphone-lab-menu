import AppKit

@MainActor
final class AcousticFieldView: NSView {
  var settings = SpatialAudioSettings() {
    didSet {
      guard settings != oldValue else { return }
      rebuildGeometry()
      live.resetWaves()
      needsDisplay = true
    }
  }
  var liveProvider: (() -> LiveAudioSnapshot?)?
  var onMonitoringChange: ((Bool) -> Void)?
  var onFrame: ((LiveAudioVisualState, Double) -> Void)?
  private var source: AcousticProbeSource = .stereo
  private var band: LiveAudioBand = .full
  private var paths = SpatialImpulseBuilder.paths(settings: SpatialAudioSettings())
  private var surface: [Float] = [0.8,0.6,0.4]
  private var live = LiveAudioVisualState()
  private var decayProfile = RoomDecayProfile(settings: SpatialAudioSettings())
  private var timer: Timer?
  private var frozen = false
  private var isOpen = false
  private var frozenTime: Double = 0
  private var lastAccessibilityUpdate: Double = 0
  private let motionAllowed = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  private let pause = NSButton()
  private let slowMotion = 40.0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Live audio energy flow and processed stereo waveforms")
    setAccessibilityHelp("Real left and right audio levels drive this first-order room illustration. Full view separates faint thin bass wrap from brighter forward midrange and treble arcs. Energy packets travel at 40 times slow motion. The lower traces show the actual recent soundstage output before headphone EQ. Reflections fade using the renderer’s low, mid and high RT60 model. Direct fronts retire after reaching the listener. The virtual speakers use a generic enclosed-cabinet model aimed at the listener. Bass radiates broadly; higher frequencies favor the front.")
    toolTip = "Music-driven energy flow through the current room model. Source levels and spectrum come from live stereo input. Ear waveforms show actual soundstage output before EQ. Reflected fronts use RT60-guided decay; direct fronts retire after passing the listener. Cabinet symbols show orientation, with their fronts aimed at the listener. Frequency-dependent radiation matches the source filter used for the audio reflections. Full view draws bass as faint thin wrap and mids/treble as brighter forward arcs. Angular visibility uses energy with a soft -13 dB display floor; it does not change wave speed or filter the audio. Cabinet glyphs are enlarged for legibility. This approximates baffle shadowing rather than solving edge diffraction. Source and band controls change only the display."
    pause.isBordered = false
    pause.contentTintColor = StudioHardware.phosphor
    pause.target = self
    pause.action = #selector(toggleAnimation)
    pause.toolTip = "Freeze or resume the live display; audio keeps playing"
    addSubview(pause)
    rebuildGeometry()
    updatePauseButton()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layout() {
    super.layout()
    pause.frame = NSRect(x: bounds.width-32,y: bounds.height-31,width: 18,height: 18)
  }

  func setDisplay(source: AcousticProbeSource, band: LiveAudioBand) {
    guard source != self.source || band != self.band else { return }
    self.source = source; self.band = band
    live.resetWaves()
    needsDisplay = true
  }

  func startAnimation() {
    isOpen = true
    guard !frozen, timer == nil else { return }
    onMonitoringChange?(true)
    let newTimer = Timer(timeInterval: 1.0/30,repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self,self.window?.isVisible == true else { return }
        self.tick()
      }
    }
    timer = newTimer
    RunLoop.main.add(newTimer,forMode: .common)
    tick()
  }

  func stopAnimation() {
    isOpen = false
    timer?.invalidate(); timer = nil
    onMonitoringChange?(false)
  }

  @objc private func toggleAnimation() {
    if frozen {
      frozen = false
      live = LiveAudioVisualState()
      if isOpen { startAnimation() }
    } else {
      frozenTime = ProcessInfo.processInfo.systemUptime
      frozen = true
      timer?.invalidate(); timer = nil
      onMonitoringChange?(false)
    }
    updatePauseButton()
    needsDisplay = true
  }

  private func updatePauseButton() {
    pause.image = NSImage(systemSymbolName: frozen ? "play.fill" : "pause.fill",accessibilityDescription: nil)
    pause.setAccessibilityLabel(frozen ? "Resume live audio display" : "Freeze live audio display")
  }

  private func rebuildGeometry() {
    paths = SpatialImpulseBuilder.paths(settings: settings)
    decayProfile = settings.decayTimes
    surface = [Float(125),1000,4000].map {
      SpatialImpulseBuilder.reflectionMagnitude(treatment: settings.treatment,frequency: $0)
    }
  }

  private var period: Double {
    let s = settings.normalized
    var farthest: Float = 0
    for path in paths where source.includes(path.input) && path.gain > 0.00001 {
      let image = SpatialVector(x: path.direction.x*path.distance,
        y: path.direction.y*path.distance,z: path.direction.z*path.distance)
      for x in [-0.38*s.depth,0.62*s.depth] {
        for y in [-s.width/2,s.width/2] {
          farthest = max(farthest,SpatialVector(x: image.x-x,y: image.y-y,z: image.z).length)
        }
      }
    }
    return max(0.025,Double(farthest/343)+0.004)
  }

  private func tick() {
    let now = ProcessInfo.processInfo.systemUptime
    live.advance(liveProvider?(),now: now,band: band,
      emitWaves: motionAllowed && settings.enabled,lifetime: period*slowMotion)
    onFrame?(live,now)
    if now-lastAccessibilityUpdate > 0.5 {
      lastAccessibilityUpdate = now
      setAccessibilityLabel(String(format:
        "Live %@ display. Input left %.0f, right %.0f dBFS. Soundstage output left %.0f, right %.0f dBFS. Propagation illustrated at 40 times slow motion.",
        band.title,decibels(live.inputLevel[0]),decibels(live.inputLevel[1]),
        decibels(live.outputLevel[0]),decibels(live.outputLevel[1])))
    }
    needsDisplay = true
  }


  override func draw(_ dirtyRect: NSRect) {
    StudioHardware.screen(bounds)
    let s = settings.normalized
    let ink = s.enabled ? StudioHardware.phosphor : StudioHardware.muted
    let now = frozen ? frozenTime : ProcessInfo.processInfo.systemUptime
    let caption = frozen ? "LIVE DISPLAY · FROZEN" : !live.hasStream ? "AUDIO PROCESSING OFF"
      : !s.enabled ? "LIVE STEREO · ROOM BYPASSED"
      : !motionAllowed ? "LIVE AUDIO · REDUCED MOTION" : "LIVE AUDIO · 40× ARRIVALS + DECAY"
    text(caption,at: NSPoint(x: 16,y: bounds.height-25),size: 8,color: ink)
    let inputPeak = max(live.inputLevel[0],live.inputLevel[1])
    text(inputPeak > 1e-6 ? String(format: "IN %.0f dBFS",decibels(inputPeak)) : "SILENCE",
      at: NSPoint(x: bounds.width-110,y: bounds.height-25),size: 8,color: ink)
    let area = NSRect(x: 13,y: 98,width: bounds.width-26,height: bounds.height-136)
    ink.withAlphaComponent(0.06).setStroke()
    for x in stride(from: area.minX,to: area.maxX,by: 16) {
      let line = NSBezierPath(); line.move(to: NSPoint(x:x,y:area.minY)); line.line(to: NSPoint(x:x,y:area.maxY)); line.stroke()
    }
    for y in stride(from: area.minY,to: area.maxY,by: 16) {
      let line = NSBezierPath(); line.move(to: NSPoint(x:area.minX,y:y)); line.line(to: NSPoint(x:area.maxX,y:y)); line.stroke()
    }
    let viewport = area.insetBy(dx: 26,dy: 12)
    let scale = min(viewport.width/CGFloat(s.width),viewport.height/CGFloat(s.depth))
    let room = NSRect(x: viewport.midX-CGFloat(s.width)*scale/2,
      y: viewport.midY-CGFloat(s.depth)*scale/2,width: CGFloat(s.width)*scale,height: CGFloat(s.depth)*scale)
    let listener = NSPoint(x:room.midX,y:room.minY+room.height*0.38)
    func position(_ image: SpatialVector) -> NSPoint {
      NSPoint(x: listener.x-CGFloat(image.y)*scale,y:listener.y+CGFloat(image.x)*scale)
    }
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: room).addClip()
    ink.withAlphaComponent(0.035).setFill(); room.fill()
    if s.enabled && motionAllowed {
      for event in live.waves where source.includes(event.source) {
        let layers = CabinetWavefront.layers(band:band,energy:event.spectralEnergy)
        let time = max(0,now-event.born)/slowMotion
        let travelled = max(0.6,Float(time)*343)
        guard let direct = paths.first(where: { $0.input == event.source && !$0.reflected }) else { continue }
        for path in paths where path.input == event.source && path.gain > 0.00001 {
          let image = SpatialVector(x:path.direction.x*path.distance,y:path.direction.y*path.distance,z:path.direction.z*path.distance)
          let wave = AcousticWavefront(source:path.input,image:image,reflected:path.reflected,
            listenerDistance:path.distance,listenerGain:path.gain)
          guard let radius = wave.radius(at: time) else { continue }
          let point = position(image)
          let r = CGFloat(radius)*scale
          let farX = max(abs(point.x-room.minX),abs(point.x-room.maxX))
          let farY = max(abs(point.y-room.minY),abs(point.y-room.maxY))
          let nearX = max(0,room.minX-point.x,point.x-room.maxX)
          let nearY = max(0,room.minY-point.y,point.y-room.maxY)
          guard r <= hypot(farX,farY)+3, r+3 >= hypot(nearX,nearY) else { continue }
          let gain = path.gain*path.distance/travelled*event.strength
          let amplitude = min(0.85,sqrt(max(0,gain))*1.1)*(path.reflected ? 0.50 : 1)
          // Keep each spectral layer's own decay, so a long bass tail cannot
          // prolong the forward treble arcs in Full view. Apply it after contrast.
          let waveLayers = layers.map { layer in
            let layerBand: LiveAudioBand = layer.meterIndex == 0 ? .low : layer.meterIndex == 1 ? .mid : .high
            let envelope = path.reflected
              ? RoomVisualDecay.reflectedEnvelope(age:time,path:path,source:direct,
                  profile:decayProfile,band:layerBand,energy:[])
              : RoomVisualDecay.directEnvelope(age:time,distance:direct.distance)
            return (layer:layer,base:amplitude*envelope)
          }
          guard waveLayers.contains(where: { $0.base*$0.layer.weight > 0.008 }) else { continue }
          let color = path.input == 0 ? StudioHardware.phosphor : StudioHardware.amber
          // A mirror source also has a mirrored emission axis. Evaluate each
          // outgoing direction along the front, not the HRTF arrival angle.
          let count = 48
          for sector in 0..<count {
            let a = CGFloat(sector)*2*CGFloat.pi/CGFloat(count)
            let b = CGFloat(sector+1)*2*CGFloat.pi/CGFloat(count), m = (a+b)/2
            let p = NSPoint(x:point.x+r*cos(m),y:point.y+r*sin(m))
            // Skip pieces entirely outside the room before constructing paths.
            let margin = r*sin((b-a)/2)+3
            guard room.insetBy(dx:-margin,dy:-margin).contains(p) else { continue }
            let outgoing = SpatialVector(x:radius*Float(sin(m)),y:-radius*Float(cos(m)),z:-image.z).unit
            let cosine = outgoing.x*path.emissionAxis.x+outgoing.y*path.emissionAxis.y+outgoing.z*path.emissionAxis.z
            let response = SpeakerCabinet.bandMagnitudes(cosine:cosine)
            let magnitudes = [response.low,response.mid,response.high]
            let pulse = NSBezierPath()
            pulse.appendArc(withCenter:point,radius:r,startAngle:a*180 / .pi,endAngle:b*180 / .pi)
            if path.reflected {
              let floorOrCeiling = abs(image.z)>0.01
              pulse.setLineDash(floorOrCeiling ? [1,3] : [5,3],count:2,
                phase:(a*r).truncatingRemainder(dividingBy:floorOrCeiling ? 4 : 8))
            }
            for item in waveLayers {
              let layer = item.layer, index = layer.meterIndex
              let opacity = layer.opacity(base:item.base,magnitude:magnitudes[index],
                surfaceMagnitude:path.reflected ? surface[index] : 1)
              guard opacity > (path.reflected ? 0.008 : 0.012) else { continue }
              color.withAlphaComponent(CGFloat(opacity)).setStroke()
              pulse.lineWidth = CGFloat(path.reflected ? min(1,layer.lineWidth) : layer.lineWidth)
              pulse.stroke()
            }
          }
        }
      }
    }
    NSGraphicsContext.restoreGraphicsState()
    ink.withAlphaComponent(0.7).setStroke()
    let wall = NSBezierPath(rect:room); wall.lineWidth = 1.2+CGFloat(s.treatment)*2; wall.stroke()
    let angle = s.speakerAngle*Float.pi/180
    for input in 0..<2 {
      let image = SpatialVector(x:s.speakerDistance*cos(angle),y:s.speakerDistance*sin(angle)*(input==0 ? 1 : -1),z:0)
      let speaker = position(image)
      let color = input == 0 ? StudioHardware.phosphor : StudioHardware.amber
      let strength = LiveAudioVisualState.displayStrength(live.inputLevel[input])
      let alpha: CGFloat = source.includes(input) ? CGFloat(0.3+strength*0.7) : 0.15
      // Front baffle is centered on the emitter; the cabinet extends behind it.
      // Minimum glyph size is symbolic, preserving orientation in large rooms.
      let forward = NSPoint(x:CGFloat(image.unit.y),y:-CGFloat(image.unit.x))
      let side = NSPoint(x:-forward.y,y:forward.x)
      let width = max(9,CGFloat(SpeakerCabinet.width)*scale)
      let depth = max(12,CGFloat(SpeakerCabinet.depth)*scale)
      func corner(_ lateral:CGFloat,_ back:CGFloat) -> NSPoint {
        NSPoint(x:speaker.x+side.x*lateral-forward.x*back,
          y:speaker.y+side.y*lateral-forward.y*back)
      }
      let cabinet = NSBezierPath()
      cabinet.move(to:corner(-width/2,0)); cabinet.line(to:corner(width/2,0))
      cabinet.line(to:corner(width/2,depth)); cabinet.line(to:corner(-width/2,depth)); cabinet.close()
      NSColor(calibratedWhite:0.06,alpha:1).setFill(); cabinet.fill()
      color.withAlphaComponent(alpha*0.6).setStroke(); cabinet.lineWidth=1; cabinet.stroke()
      let baffle = NSBezierPath(); baffle.move(to:corner(-width/2,0)); baffle.line(to:corner(width/2,0))
      color.withAlphaComponent(alpha).setStroke(); baffle.lineWidth=2; baffle.stroke()
      color.withAlphaComponent(alpha).setFill()
      NSBezierPath(ovalIn:NSRect(x:speaker.x-2,y:speaker.y-2,width:4,height:4)).fill()
      let label = corner(0,depth+6)
      text(input==0 ? "L" : "R",at:NSPoint(x:label.x-3,y:label.y),size:8,color:color)
    }
    let outputStrength = LiveAudioVisualState.displayStrength(max(live.outputLevel[0],live.outputLevel[1]))
    ink.withAlphaComponent(CGFloat(0.15+outputStrength*0.85)).setFill()
    NSBezierPath(ovalIn:NSRect(x:listener.x-4,y:listener.y-5,width:8,height:10)).fill()
    text(String(format:"%.1f × %.1f × %.1f m",s.width,s.depth,s.height),
      at:NSPoint(x:area.minX+5,y:area.minY+3),size:8,color:ink.withAlphaComponent(0.65))
    let radiationLegend = band == .full ? "FAINT: BASS WRAP · BRIGHT: FORWARD MID/TREBLE"
      : band == .low ? "125 Hz · BROAD BASS WRAP AROUND CABINETS"
      : "\(band.title) · FORWARD RADIATION / REAR SHADOW"
    text(radiationLegend+" · DASH/DOT: REFLECTIONS",
      at:NSPoint(x:16,y:83),size:7,color:StudioHardware.muted)
    drawEarOutput(now:now)
  }

  private func drawEarOutput(now: Double) {
    text("LIVE EAR OUTPUT · BEFORE EQ",at:NSPoint(x:16,y:65),size:8,color:StudioHardware.muted)
    let width = bounds.width-57, origin: CGFloat = 37
    let measuredPeak = live.scope.reduce(Float(0)) { value,point in
      max(value,abs(point.minimum[0]),abs(point.minimum[1]),abs(point.maximum[0]),abs(point.maximum[1]))
    }
    let scale = max(0.02,measuredPeak)
    text(String(format:"RANGE %.0f dBFS",decibels(scale)),at:NSPoint(x:bounds.width-113,y:65),size:7,color:StudioHardware.muted)
    for ear in 0..<2 {
      let y: CGFloat = ear==0 ? 48 : 28
      let color = ear==0 ? StudioHardware.phosphor : StudioHardware.amber
      text(ear==0 ? "L" : "R",at:NSPoint(x:17,y:y-4),size:8,color:color)
      color.withAlphaComponent(0.13).setStroke()
      let baseline=NSBezierPath(); baseline.move(to:NSPoint(x:origin,y:y)); baseline.line(to:NSPoint(x:origin+width,y:y)); baseline.stroke()
      color.withAlphaComponent(0.85).setStroke()
      let plot=NSBezierPath()
      for point in live.scope {
        let fraction = 1-(now-point.time)/0.080
        guard fraction>=0 && fraction<=1 else { continue }
        let x=origin+CGFloat(fraction)*width
        plot.move(to:NSPoint(x:x,y:y+CGFloat(point.minimum[ear]/scale)*8))
        plot.line(to:NSPoint(x:x,y:y+CGFloat(point.maximum[ear]/scale)*8))
      }
      plot.lineWidth=1; plot.stroke()
    }
    for ms in [-80,-60,-40,-20,0] {
      let x=origin+CGFloat(ms+80)/80*width
      text("\(ms)",at:NSPoint(x:x-5,y:8),size:7,color:StudioHardware.muted)
    }
  }

  private func decibels(_ level: Float) -> Float { 20*log10(max(1e-6,level)) }
  private func text(_ string: String,at point: NSPoint,size: CGFloat,color: NSColor) {
    string.draw(at:point,withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:size,weight:.medium),.foregroundColor:color])
  }
}

@MainActor
final class LiveAudioHistoryView: NSView {
  var state = LiveAudioVisualState()
  var time: Double = 0
  override init(frame frameRect: NSRect) {
    super.init(frame:frameRect)
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    setAccessibilityLabel("Live soundstage output levels over the last three seconds")
    toolTip="Actual left and right RMS levels of soundstage output before headphone EQ, in dBFS. This is live program level history; RT60 above is the room model estimate."
  }
  @available(*,unavailable)
  required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func draw(_ dirtyRect:NSRect) {
    StudioHardware.screen(bounds,radius:4)
    let graph=bounds.insetBy(dx:25,dy:13)
    StudioHardware.phosphor.withAlphaComponent(0.12).setStroke()
    for db in [0,36,72] {
      let y=graph.maxY-CGFloat(db)/72*graph.height
      let line=NSBezierPath(); line.move(to:NSPoint(x:graph.minX,y:y)); line.line(to:NSPoint(x:graph.maxX,y:y)); line.stroke()
    }
    for channel in 0..<2 {
      let curve=NSBezierPath()
      var started=false
      for point in state.history {
        let fraction=1-(time-point.time)/3
        guard fraction>=0 && fraction<=1 else { continue }
        let db=max(-72,min(0,20*log10(max(1e-6,point.rms[channel]))))
        let p=NSPoint(x:graph.minX+CGFloat(fraction)*graph.width,y:graph.maxY+CGFloat(db)/72*graph.height)
        if started { curve.line(to:p) } else { curve.move(to:p); started=true }
      }
      (channel==0 ? StudioHardware.phosphor : StudioHardware.amber).setStroke()
      curve.lineWidth=1.2; curve.stroke()
    }
    let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedSystemFont(ofSize:7,weight:.regular),.foregroundColor:StudioHardware.muted]
    "0".draw(at:NSPoint(x:9,y:graph.maxY-3),withAttributes:attributes)
    "−72".draw(at:NSPoint(x:4,y:graph.minY-3),withAttributes:attributes)
    "LIVE EAR LEVEL · LAST 3 s".draw(at:NSPoint(x:graph.minX,y:2),withAttributes:attributes)
  }
}
