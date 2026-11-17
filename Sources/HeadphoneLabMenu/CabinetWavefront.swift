import Foundation

/// Frequency-resolved display layers. Radius still represents travel time;
/// cabinet directivity changes energy visibility, never propagation speed.
struct CabinetWaveLayer: Sendable {
  let meterIndex: Int
  let weight: Float
  let lineWidth: Float

  func opacity(base: Float, magnitude: Float, surfaceMagnitude: Float = 1) -> Float {
    // Display power, with a soft floor at -13 dB relative to the on-axis
    // source. Weak rearward treble disappears instead of outlining a full ring.
    let power = magnitude*magnitude
    let visible = max(0,(power-0.05)/0.95)
    return base*weight*visible*surfaceMagnitude*surfaceMagnitude
  }
}

enum CabinetWavefront {
  static func layers(band: LiveAudioBand, energy: [Float]) -> [CabinetWaveLayer] {
    if let index = band.meterIndex {
      return [CabinetWaveLayer(meterIndex:index,weight:1,lineWidth:1.5)]
    }
    guard energy.count == 3 else { return [] }
    let values = energy.map { $0.isFinite ? max(0,$0) : 0 }
    let total = values.reduce(0,+)
    guard total > 1e-20 else { return [] }
    // Faint/thin bass context; stronger mids and treble make the baffle's
    // forward radiation legible even when bass dominates the program spectrum.
    // The layer's RMS share still follows actual measured source-band energy.
    let contrast: [Float] = [0.18,0.65,1]
    let widths: [Float] = [0.65,1.1,1.6]
    return (0..<3).compactMap { i in
      guard values[i] > 0 else { return nil }
      return CabinetWaveLayer(meterIndex:i,weight:sqrt(values[i]/total)*contrast[i],lineWidth:widths[i])
    }
  }
}
