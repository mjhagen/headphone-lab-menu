import AudioBridge
import Foundation

/// Generic enclosed monitor, aimed at the listener. This smooth source model
/// approximates baffle shadowing / driver beaming, not cabinet edge diffraction.
enum SpeakerCabinet {
  static let width: Float = 0.22
  static let depth: Float = 0.28
  static let baffleFrequency: Float = 343 / (.pi * width)
  static let beamFrequency: Float = 2500
  static let tailFrames = 256

  static func gains(cosine: Float) -> (mid: Float, high: Float) {
    let u = (1 + min(1,max(-1,cosine))) / 2
    return (0.15 + 0.85*u, 0.03 + 0.97*u*u)
  }

  // Unity on-axis and at DC; no artificial cutoff behind the enclosure.
  static func filter(_ input: [Float], cosine: Float) -> [Float] {
    guard cosine < 0.999999 else { return input }
    let g = gains(cosine:cosine)
    let a = 1-exp(-2*Float.pi*baffleFrequency/48_000)
    let b = 1-exp(-2*Float.pi*beamFrequency/48_000)
    var low: Float = 0, broad: Float = 0
    return (input + [Float](repeating:0,count:tailFrames)).map { x in
      low += a*(x-low); broad += b*(x-broad)
      return low + g.mid*(broad-low) + g.high*(x-broad)
    }
  }

  // Analytic response of precisely the same causal filter used in the FIRs.
  static func magnitude(cosine: Float, frequency: Float) -> Float {
    response(gains(cosine:cosine),coefficients:coefficients(frequency:frequency))
  }

  private struct Coefficients {
    let lr: Float, li: Float, br: Float, bi: Float
  }
  private static func coefficients(frequency: Float) -> Coefficients {
    let omega = 2*Float.pi*frequency/48_000
    func lowpass(_ cutoff:Float) -> (real:Float,imag:Float) {
      let p = exp(-2*Float.pi*cutoff/48_000), a = 1-p
      let re = 1-p*cos(omega), im = p*sin(omega), den = re*re+im*im
      return (a*re/den,-a*im/den)
    }
    let l = lowpass(baffleFrequency), b = lowpass(beamFrequency)
    return Coefficients(lr:l.real,li:l.imag,br:b.real,bi:b.imag)
  }
  private static func response(_ g: (mid:Float,high:Float), coefficients c:Coefficients) -> Float {
    let re = g.high+(g.mid-g.high)*c.br+(1-g.mid)*c.lr
    let im = (g.mid-g.high)*c.bi+(1-g.mid)*c.li
    return sqrt(re*re+im*im)
  }
  private static let displayCoefficients = [Float(125),1000,4000].map { coefficients(frequency:$0) }
  static func bandMagnitudes(cosine: Float) -> (low:Float,mid:Float,high:Float) {
    let g = gains(cosine:cosine)
    return (response(g,coefficients:displayCoefficients[0]),
            response(g,coefficients:displayCoefficients[1]),
            response(g,coefficients:displayCoefficients[2]))
  }

  // Sphere-averaged squared asymptotic polar gains: u=(1+cos(theta))/2
  // is uniform on [0,1]. The late field remains a diffuse approximation.
  static let diffuseMid: Float = sqrt(0.15*0.15 + 0.15*0.85 + 0.85*0.85/3)
  static let diffuseHigh: Float = sqrt(0.03*0.03 + 2*0.03*0.97/3 + 0.97*0.97/5)

  static func configureLateField(_ state: OpaquePointer) {
    HLMSpatialStateSetLateSourceFilter(state,baffleFrequency,beamFrequency,1,diffuseMid,diffuseHigh)
  }
}
