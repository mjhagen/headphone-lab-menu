import AudioBridge
import Foundation

enum AcousticProbeSource: Int, CaseIterable, Sendable {
  case left, stereo, right
  var title: String { ["L", "L+R", "R"][rawValue] }
  func includes(_ input: Int) -> Bool { self == .stereo || (self == .left ? input == 0 : input == 1) }
}

enum AcousticProbeBand: Int, CaseIterable, Sendable {
  case low, mid, high
  var frequency: Float { [125,1000,4000][rawValue] }
  var title: String { ["125 Hz", "1 kHz", "4 kHz"][rawValue] }
}

struct AcousticWavefront: Sendable {
  let source: Int
  let image: SpatialVector
  let reflected: Bool
  let listenerDistance: Float
  let listenerGain: Float

  // The intersection of a spherical wave with the horizontal ear-height plane.
  // Floor/ceiling images therefore appear later than the direct wave.
  func radius(at seconds: Double) -> Float? {
    let travelled = Float(seconds)*343
    guard travelled >= abs(image.z) else { return nil }
    return sqrt(max(0, travelled*travelled-image.z*image.z))
  }
}

struct AcousticPreviewSnapshot: Sendable {
  struct Envelope: Sendable { let minimum: Float; let maximum: Float }
  let source: AcousticProbeSource
  let band: AcousticProbeBand
  let wavefronts: [AcousticWavefront]
  let surfaceMagnitude: Float
  let early: [[Envelope]]
  let earlyDuration: Double
  let peakDecibels: Float
  let earPeakTimes: [Double]
  let decay: [Float]
  let decayDuration: Double
  let lateEnergy: Float
}

/// The preview runs the SAME C renderer with a synthetic impulse, on this actor,
/// away from the UI and audio callbacks. Only compact plot data reaches the UI.
/// It never plays a test sound or reads the user's music.
actor AcousticPreviewEngine {
  private var databases: [HRTFProfile: HRTFDatabase] = [:]

  func snapshot(settings: SpatialAudioSettings, source: AcousticProbeSource,
                band: AcousticProbeBand) throws -> AcousticPreviewSnapshot {
    try Task.checkCancellation()
    let s = settings.normalized
    let database: HRTFDatabase
    if let cached = databases[s.hrtf] { database = cached }
    else {
      database = try HRTFDatabase(profile: s.hrtf)
      databases[s.hrtf] = database
    }
    let impulse = SpatialImpulseBuilder.build(settings: s, database: database, sampleRate: 48_000)
    try Task.checkCancellation()
    let paths = SpatialImpulseBuilder.paths(settings: s).filter { source.includes($0.input) }
    let waves = paths.map { path in
      AcousticWavefront(source: path.input,
        image: SpatialVector(x: path.direction.x*path.distance,
          y: path.direction.y*path.distance, z: path.direction.z*path.distance),
        reflected: path.reflected, listenerDistance: path.distance, listenerGain: path.gain)
    }
    let lowDecay = s.decayTimes.low
    let duration = Double(min(2.5, max(0.35, lowDecay*1.5)))
    let renderer = try makeRenderer(s, impulse: impulse)
    defer { HLMSpatialDestroy(renderer) }
    // Complete publication/crossfade before the probe, exactly as in DSP tests.
    var silenceL = [Float](repeating: 0, count: 4096), silenceR = silenceL
    process(renderer, &silenceL, &silenceR)
    try Task.checkCancellation()
    let delay = Int(HLMSpatialLatencyFrames())
    let count = Int(duration*48_000)+delay
    var left = [Float](repeating: 0, count: count), right = left
    if source.includes(0) { left[0] = 1 }
    if source.includes(1) { right[0] = 1 }
    process(renderer, &left, &right)
    // Remove fixed buffering, retaining geometric travel and measured HRIR delay.
    left.removeFirst(delay); right.removeFirst(delay)
    let rawPeakTimes = [left,right].map { channel in
      Double(channel.indices.max(by: { abs(channel[$0]) < abs(channel[$1]) }) ?? 0)/48_000
    }
    let rawChannels = [left,right]
    let peak = max(rawChannels.flatMap { $0 }.map(abs).max() ?? 0, 1e-12)
    let earlyDuration = 0.080
    let earlyCount = Int(earlyDuration*48_000)
    let bins = 420
    let early = rawChannels.map { channel in
      (0..<bins).map { bin in
        let a = bin*earlyCount/bins, b = max(a+1, (bin+1)*earlyCount/bins)
        let samples = channel[a..<min(b,channel.count)]
        return AcousticPreviewSnapshot.Envelope(minimum: samples.min() ?? 0,
          maximum: samples.max() ?? 0)
      }
    }
    left = Self.bandpass(left, frequency: band.frequency)
    right = Self.bandpass(right, frequency: band.frequency)
    let channels = [left,right]
    // Schroeder reverse integration of the rendered, band-limited ear energy.
    // This includes the actual FDN tail rather than a decorative exponential.
    var integrated = [Float](repeating: 0, count: left.count)
    var energy: Double = 0
    for i in stride(from: left.count-1, through: 0, by: -1) {
      energy += Double(left[i])*Double(left[i])+Double(right[i])*Double(right[i])
      integrated[i] = Float(energy)
    }
    let reference = max(integrated[0], 1e-20)
    let decay = (0..<160).map { bin -> Float in
      let index = min(integrated.count-1, bin*(integrated.count-1)/159)
      return max(-60, 10*log10(max(1e-20, integrated[index]/reference)))
    }
    let lateStart = Int(0.06*48_000)
    let tailEnergy = channels.reduce(Float(0)) { sum, channel in
      sum + channel.dropFirst(lateStart).reduce(0) { $0+$1*$1 }
    }
    try Task.checkCancellation()
    return AcousticPreviewSnapshot(source: source, band: band, wavefronts: waves,
      surfaceMagnitude: SpatialImpulseBuilder.reflectionMagnitude(treatment: s.treatment, frequency: band.frequency),
      early: early, earlyDuration: earlyDuration, peakDecibels: 20*log10(peak),
      earPeakTimes: rawPeakTimes, decay: decay, decayDuration: duration, lateEnergy: tailEnergy)
  }

  private func makeRenderer(_ s: SpatialAudioSettings, impulse: SpatialImpulseResponse) throws -> OpaquePointer {
    guard let renderer = HLMSpatialCreate(48_000) else { throw SpatialAudioError.allocation }
    let state = impulse.samples.withUnsafeBufferPointer {
      HLMSpatialStateCreate(48_000, $0.baseAddress!, UInt32(impulse.frames), s.enabled,
        s.width,s.depth,s.height,s.treatment,s.roomAmount)
    }
    guard let state else { HLMSpatialDestroy(renderer); throw SpatialAudioError.allocation }
    if s.enabled { SpeakerCabinet.configureLateField(state) }
    HLMSpatialPublish(renderer,state)
    return renderer
  }

  private func process(_ renderer: OpaquePointer, _ left: inout [Float], _ right: inout [Float]) {
    left.withUnsafeMutableBufferPointer { l in
      right.withUnsafeMutableBufferPointer { r in
        HLMSpatialProcessPlanar(renderer,l.baseAddress!,r.baseAddress!,UInt32(l.count))
      }
    }
  }

  private static func bandpass(_ input: [Float], frequency: Float) -> [Float] {
    let omega = 2*Float.pi*frequency/48_000
    let alpha = sin(omega)/(2*0.70710678)
    let b0 = alpha/(1+alpha), b2 = -b0
    let a1 = -2*cos(omega)/(1+alpha), a2 = (1-alpha)/(1+alpha)
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    return input.map { x in
      let y = b0*x+b2*x2-a1*y1-a2*y2
      x2 = x1; x1 = x; y2 = y1; y1 = y
      return y
    }
  }
}
