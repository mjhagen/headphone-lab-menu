import AudioBridge
import Foundation

struct RoomDecayProfile: Sendable {
  let low: Float
  let mid: Float
  let high: Float

  init(settings: SpatialAudioSettings) {
    let s = settings.normalized
    let decay = HLMSpatialRoomDecayTimes(s.width,s.depth,s.height,s.treatment)
    low = decay.low; mid = decay.mid; high = decay.high
  }

  func time(for band: LiveAudioBand) -> Float {
    switch band {
    case .low: low
    case .full, .mid: mid
    case .high: high
    }
  }

  // At RT60 the amplitude is 0.001 (energy 0.000001). Full-band decay is
  // energy-weighted so bass-rich activity persists longer than treble.
  func amplitude(after seconds: Double, band: LiveAudioBand, energy: [Float]) -> Float {
    let elapsed = Float(max(0,seconds))
    func decay(_ rt60: Float) -> Float { pow(0.001,elapsed/rt60) }
    guard band == .full, energy.count == 3 else { return decay(time(for: band)) }
    let weights = energy.map { $0.isFinite ? max(0,$0) : 0 }
    let total = weights.reduce(0,+)
    guard total > 1e-20 else { return decay(mid) }
    let values = [decay(low),decay(mid),decay(high)]
    return sqrt((0..<3).reduce(Float(0)) { $0+weights[$1]*values[$1]*values[$1] }/total)
  }
}

enum RoomVisualDecay {
  // Direct fronts are highlighted until arrival at the listener, then retired
  // over 5 ms of acoustic time. This is display focus, not extra audio damping.
  static func directEnvelope(age: Double, distance: Float) -> Float {
    let progress = min(1,max(0,(age-Double(distance/343))/0.005))
    return Float(1-progress*progress*(3-2*progress))
  }

  static func reflectedEnvelope(age: Double, path: SpatialPath, source: SpatialPath,
                                profile: RoomDecayProfile, band: LiveAudioBand,
                                energy: [Float]) -> Float {
    // Half the separation between a source and its mirror is the normal
    // source-to-wall distance, including floor/ceiling mirrors in 3D.
    let dx = path.direction.x*path.distance-source.direction.x*source.distance
    let dy = path.direction.y*path.distance-source.direction.y*source.distance
    let dz = path.direction.z*path.distance-source.direction.z*source.distance
    let firstBounce = Double(sqrt(dx*dx+dy*dy+dz*dz)/2/343)
    return profile.amplitude(after: max(0,age-firstBounce),band: band,energy: energy)
  }
}
