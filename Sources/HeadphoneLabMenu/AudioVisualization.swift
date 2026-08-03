import Accelerate
import AppKit
import AudioBridge

struct SpectrumSnapshot: Sendable {
  let magnitudes: [Float]
  let sampleRate: Double
  let peak: Float

  var peakDecibels: Float {
    20 * log10(max(peak, 0.000_001))
  }
}

@MainActor
final class AudioSpectrumAnalyzer {
  static let fftSize = 16_384

  private let log2Size = vDSP_Length(log2(Float(fftSize)))
  nonisolated(unsafe) private let fftSetup: FFTSetup
  private var scratch = [Float](repeating: 0, count: fftSize)
  private var history = [Float](repeating: 0, count: fftSize)
  private var window = [Float](repeating: 0, count: fftSize)
  private var windowed = [Float](repeating: 0, count: fftSize)
  private var real = [Float](repeating: 0, count: fftSize / 2)
  private var imaginary = [Float](repeating: 0, count: fftSize / 2)
  private var magnitudes = [Float](repeating: -96, count: fftSize / 2)
  private var smoothedMagnitudes = [Float](repeating: -96, count: fftSize / 2)
  private var historyCursor = 0
  private var hasSamples = false
  private var heldPeak: Float = 0
  private var windowScale: Float = 1
  private var lastSnapshotTime = ProcessInfo.processInfo.systemUptime

  init() {
    guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else {
      fatalError("Unable to create spectrum FFT")
    }
    fftSetup = setup
    vDSP_hann_window(&window, vDSP_Length(Self.fftSize), 0)
    windowScale = 2 / window.reduce(0, +)
  }

  deinit {
    vDSP_destroy_fftsetup(fftSetup)
  }

  func snapshot(from ring: OpaquePointer, sampleRate: Double) -> SpectrumSnapshot? {
    var remaining = min(Int(HLMRingAvailable(ring)), Self.fftSize * 2)
    while remaining > 0 {
      let requested = min(remaining, scratch.count)
      let count = scratch.withUnsafeMutableBufferPointer { samples in
        Int(HLMRingReadMono(ring, samples.baseAddress!, UInt32(requested)))
      }
      guard count > 0 else { break }
      append(scratch, count: count)
      remaining -= count
    }

    let measuredPeak = HLMRingTakePeak(ring)
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = max(0, now - lastSnapshotTime)
    lastSnapshotTime = now
    let peakDecay = Float(pow(10, -8 * elapsed / 20))
    heldPeak = max(measuredPeak, heldPeak * peakDecay)
    guard hasSamples else { return nil }
    calculateSpectrum()
    return SpectrumSnapshot(
      magnitudes: smoothedMagnitudes,
      sampleRate: sampleRate,
      peak: heldPeak
    )
  }

  private func append(_ samples: [Float], count: Int) {
    guard count > 0 else { return }
    hasSamples = true
    for index in 0..<count {
      history[historyCursor] = samples[index]
      historyCursor = (historyCursor + 1) % Self.fftSize
    }
  }

  private func calculateSpectrum() {
    for index in 0..<Self.fftSize {
      let historyIndex = (historyCursor + index) % Self.fftSize
      windowed[index] = history[historyIndex] * window[index]
    }

    real.withUnsafeMutableBufferPointer { realBuffer in
      imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
        var split = DSPSplitComplex(
          realp: realBuffer.baseAddress!,
          imagp: imaginaryBuffer.baseAddress!
        )
        windowed.withUnsafeBufferPointer { input in
          input.baseAddress!.withMemoryRebound(
            to: DSPComplex.self,
            capacity: Self.fftSize / 2
          ) { complexInput in
            vDSP_ctoz(
              complexInput,
              2,
              &split,
              1,
              vDSP_Length(Self.fftSize / 2)
            )
          }
        }
        vDSP_fft_zrip(fftSetup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
        magnitudes.withUnsafeMutableBufferPointer { output in
          vDSP_zvabs(
            &split,
            1,
            output.baseAddress!,
            1,
            vDSP_Length(Self.fftSize / 2)
          )
        }
      }
    }

    var scaleValue = windowScale
    vDSP_vsmul(
      magnitudes,
      1,
      &scaleValue,
      &magnitudes,
      1,
      vDSP_Length(magnitudes.count)
    )
    var floor: Float = 0.000_001
    vDSP_vthr(
      magnitudes,
      1,
      &floor,
      &magnitudes,
      1,
      vDSP_Length(magnitudes.count)
    )
    var count = Int32(magnitudes.count)
    vvlog10f(&magnitudes, magnitudes, &count)
    var decibelScale: Float = 20
    vDSP_vsmul(
      magnitudes,
      1,
      &decibelScale,
      &magnitudes,
      1,
      vDSP_Length(magnitudes.count)
    )
    for index in magnitudes.indices {
      let coefficient: Float = magnitudes[index] > smoothedMagnitudes[index] ? 0.62 : 0.08
      smoothedMagnitudes[index] +=
        (magnitudes[index] - smoothedMagnitudes[index]) * coefficient
    }
  }
}

enum EQResponse {
  static func decibels(
    profile: EQProfile?,
    frequency: Double,
    sampleRate: Double,
    userGain: Float
  ) -> Float {
    guard let profile else { return userGain }
    var result = Double(profile.preamp + userGain)
    for filter in profile.filters {
      result += filterDecibels(filter, frequency: frequency, sampleRate: sampleRate)
    }
    return Float(result)
  }

  private static func filterDecibels(
    _ filter: EQProfile.Filter,
    frequency: Double,
    sampleRate: Double
  ) -> Double {
    let center = min(Double(filter.frequency), sampleRate * 0.49)
    let omega = 2 * Double.pi * center / sampleRate
    let cosine = cos(omega)
    let sine = sin(omega)
    let q =
      pow(2, Double(filter.bandwidth) / 2)
      / max(0.000_001, pow(2, Double(filter.bandwidth)) - 1)
    let alpha = sine / (2 * q)
    let amplitude = pow(10, Double(filter.gain) / 40)
    let coefficients: (Double, Double, Double, Double, Double, Double)

    switch filter.kind {
    case .parametric:
      coefficients = (
        1 + alpha * amplitude, -2 * cosine, 1 - alpha * amplitude,
        1 + alpha / amplitude, -2 * cosine, 1 - alpha / amplitude
      )
    case .lowPass:
      coefficients = (
        (1 - cosine) / 2, 1 - cosine, (1 - cosine) / 2,
        1 + alpha, -2 * cosine, 1 - alpha
      )
    case .highPass:
      coefficients = (
        (1 + cosine) / 2, -(1 + cosine), (1 + cosine) / 2,
        1 + alpha, -2 * cosine, 1 - alpha
      )
    case .bandPass:
      coefficients = (alpha, 0, -alpha, 1 + alpha, -2 * cosine, 1 - alpha)
    case .notch:
      coefficients = (1, -2 * cosine, 1, 1 + alpha, -2 * cosine, 1 - alpha)
    case .lowShelf:
      let root = 2 * sqrt(amplitude) * alpha
      coefficients = (
        amplitude * ((amplitude + 1) - (amplitude - 1) * cosine + root),
        2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosine),
        amplitude * ((amplitude + 1) - (amplitude - 1) * cosine - root),
        (amplitude + 1) + (amplitude - 1) * cosine + root,
        -2 * ((amplitude - 1) + (amplitude + 1) * cosine),
        (amplitude + 1) + (amplitude - 1) * cosine - root
      )
    case .highShelf:
      let root = 2 * sqrt(amplitude) * alpha
      coefficients = (
        amplitude * ((amplitude + 1) + (amplitude - 1) * cosine + root),
        -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosine),
        amplitude * ((amplitude + 1) + (amplitude - 1) * cosine - root),
        (amplitude + 1) - (amplitude - 1) * cosine + root,
        2 * ((amplitude - 1) - (amplitude + 1) * cosine),
        (amplitude + 1) - (amplitude - 1) * cosine - root
      )
    }

    let evaluationOmega = 2 * Double.pi * frequency / sampleRate
    let z1Real = cos(evaluationOmega)
    let z1Imaginary = -sin(evaluationOmega)
    let z2Real = cos(2 * evaluationOmega)
    let z2Imaginary = -sin(2 * evaluationOmega)
    let (b0, b1, b2, a0, a1, a2) = coefficients
    let numeratorReal = b0 + b1 * z1Real + b2 * z2Real
    let numeratorImaginary = b1 * z1Imaginary + b2 * z2Imaginary
    let denominatorReal = a0 + a1 * z1Real + a2 * z2Real
    let denominatorImaginary = a1 * z1Imaginary + a2 * z2Imaginary
    let numerator = hypot(numeratorReal, numeratorImaginary)
    let denominator = max(0.000_000_001, hypot(denominatorReal, denominatorImaginary))
    return 20 * log10(max(0.000_000_001, numerator / denominator))
  }
}
