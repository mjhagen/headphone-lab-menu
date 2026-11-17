import AudioBridge
import Foundation

// SOFA coordinates: x forward, y left, z up. All distances are metres.
struct SpatialVector: Sendable {
  var x: Float
  var y: Float
  var z: Float
  var length: Float { sqrt(x*x + y*y + z*z) }
  var unit: SpatialVector {
    let d = max(length, 0.0001)
    return SpatialVector(x: x/d, y: y/d, z: z/d)
  }
  func squaredDistance(to other: SpatialVector) -> Float {
    let dx = x-other.x, dy = y-other.y, dz = z-other.z
    return dx*dx + dy*dy + dz*dz
  }
}

enum HRTFProfile: String, Codable, CaseIterable, Sendable {
  case ku100 = "D1"
  case kemar = "D2"
  case listenerH10 = "H10"

  var title: String {
    switch self {
    case .ku100: "SADIE II · KU100"
    case .kemar: "SADIE II · KEMAR"
    case .listenerH10: "SADIE II · Listener H10"
    }
  }
}

struct SpatialAudioSettings: Codable, Equatable, Sendable {
  var enabled = false
  var hrtf: HRTFProfile = .ku100
  var speakerAngle: Float = 30 // angle per speaker, not total stereo span
  var speakerDistance: Float = 1.5
  var width: Float = 5
  var depth: Float = 6
  var height: Float = 2.7
  var treatment: Float = 0.65
  var roomAmount: Float = 0.25
  var automaticPlacement = false

  init() {}

  private enum CodingKeys: String, CodingKey {
    case enabled, hrtf, speakerAngle, speakerDistance, width, depth, height, treatment, roomAmount, automaticPlacement
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try values.decode(Bool.self,forKey:.enabled)
    hrtf = try values.decode(HRTFProfile.self,forKey:.hrtf)
    speakerAngle = try values.decode(Float.self,forKey:.speakerAngle)
    speakerDistance = try values.decode(Float.self,forKey:.speakerDistance)
    width = try values.decode(Float.self,forKey:.width)
    depth = try values.decode(Float.self,forKey:.depth)
    height = try values.decode(Float.self,forKey:.height)
    treatment = try values.decode(Float.self,forKey:.treatment)
    roomAmount = try values.decode(Float.self,forKey:.roomAmount)
    // Older saved rooms had a one-shot placement button, with no mode flag.
    automaticPlacement = try values.decodeIfPresent(Bool.self,forKey:.automaticPlacement) ?? false
  }

  var normalized: Self {
    var s = self
    func bounded(_ value: Float, _ lower: Float, _ upper: Float, _ fallback: Float) -> Float {
      value.isFinite ? min(upper, max(lower, value)) : fallback
    }
    s.width = bounded(width, 3, 12, 5)
    s.depth = bounded(depth, 3, 16, 6)
    s.height = bounded(height, 2.2, 5, 2.7)
    s.speakerAngle = bounded(speakerAngle, 15, 60, 30)
    s.speakerDistance = bounded(speakerDistance, 0.6, s.maximumSpeakerDistance, 1.5)
    s.treatment = bounded(treatment, 0, 1, 0.65)
    s.roomAmount = bounded(roomAmount, 0, 0.6, 0.25)
    if s.automaticPlacement { s.applyOptimalPlacement() }
    return s
  }

  var maximumSpeakerDistance: Float {
    let angle = speakerAngle * .pi / 180
    return min(3.5, width * 0.44 / sin(angle), depth * 0.52 / cos(angle))
  }

  /// A geometric starting point, not a measured room-mode optimization.
  /// The fixed listener stays centered at 38% depth; cabinets face that listener.
  func placingSpeakersOptimally() -> Self {
    var s = normalized
    s.applyOptimalPlacement()
    return s
  }

  private mutating func applyOptimalPlacement() {
    speakerAngle = 30 // equal speaker spacing and listener distance
    let angle = speakerAngle * .pi / 180
    let wallClearance: Float = 0.5
    // Account for the entire rotated cabinet, not just the acoustic center.
    let sideExtent = SpeakerCabinet.depth*sin(angle) + SpeakerCabinet.width/2*cos(angle)
    let frontExtent = SpeakerCabinet.depth*cos(angle) + SpeakerCabinet.width/2*sin(angle)
    let sideLimit = (width/2-wallClearance-sideExtent)/sin(angle)
    let frontLimit = (0.62*depth-wallClearance-frontExtent)/cos(angle)
    // Target an equilateral triangle spanning 55% of room width, capped at
    // 40% of room depth and the renderer's supported listening distance.
    speakerDistance = max(0.6,min(0.55*width,0.40*depth,
      sideLimit,frontLimit,maximumSpeakerDistance))
  }

  var decayTimes: RoomDecayProfile { RoomDecayProfile(settings: self) }
  var estimatedMidDecay: Float { decayTimes.mid }

}

struct SpatialPath: Sendable {
  let input: Int
  let direction: SpatialVector
  let distance: Float
  let gain: Float
  let reflected: Bool
  // Speaker axis mirrored along with its image source. Reception direction
  // stays separate: source directivity is evaluated along the outgoing ray.
  let emissionAxis: SpatialVector
  var emissionCosine: Float {
    -(direction.x*emissionAxis.x + direction.y*emissionAxis.y + direction.z*emissionAxis.z)
  }
}

struct SpatialImpulseResponse: Sendable {
  let samples: [Float] // contiguous [input * 2 + ear][frames]
  let frames: Int
  let paths: [SpatialPath]
}

enum SpatialAudioError: LocalizedError {
  case invalidAsset(String)
  case allocation

  var errorDescription: String? {
    switch self {
    case .invalidAsset(let name): "The bundled \(name) HRTF could not be read. Reinstall Headphone EQ."
    case .allocation: "The soundstage renderer could not allocate its audio buffers."
    }
  }
}

struct HRTFDatabase: Sendable {
  struct Measurement: Sendable {
    let direction: SpatialVector
    let peaks: [Float]
    let ears: [[Float]]
  }
  let measurements: [Measurement]
  let sampleRate: Double = 48_000

  init(profile: HRTFProfile) throws {
    // The app bundle uses its normal Resources directory; SwiftPM tests and
    // command-line builds use the generated package resource bundle.
    let installed = Bundle.main.resourceURL?
      .appendingPathComponent("HRTF/\(profile.rawValue).hlhrtf")
    let url: URL?
    if let installed, FileManager.default.fileExists(atPath: installed.path) {
      url = installed
    } else {
      url = Bundle.module.url(forResource: profile.rawValue, withExtension: "hlhrtf", subdirectory: "HRTF")
    }
    guard let url, let data = try? Data(contentsOf: url), data.count >= 16 else {
      throw SpatialAudioError.invalidAsset(profile.title)
    }
    var decoded: [Measurement] = []
    try data.withUnsafeBytes { bytes in
      func word(_ offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
      }
      func float(_ offset: Int) -> Float { Float(bitPattern: word(offset)) }
      let count = Int(word(8)), taps = Int(word(12))
      guard word(0) == 0x31484c48, word(4) == 48_000,
        (1...1000).contains(count), taps == 512,
        data.count == 16 + count * (5 + 2*taps) * 4
      else { throw SpatialAudioError.invalidAsset(profile.title) }
      var offset = 16
      for _ in 0..<count {
        let direction = SpatialVector(x: float(offset), y: float(offset+4), z: float(offset+8))
        let peaks = [float(offset+12), float(offset+16)]
        offset += 20
        var ears: [[Float]] = []
        for _ in 0..<2 {
          let values = (0..<taps).map { float(offset + $0*4) }
          guard values.allSatisfy({ $0.isFinite && abs($0) < 32 }) else {
            throw SpatialAudioError.invalidAsset(profile.title)
          }
          ears.append(values)
          offset += taps*4
        }
        guard direction.length.isFinite, abs(direction.length - 1) < 0.01,
          peaks.allSatisfy({ $0.isFinite && (0...160).contains($0) })
        else { throw SpatialAudioError.invalidAsset(profile.title) }
        decoded.append(Measurement(direction: direction, peaks: peaks, ears: ears))
      }
    }
    measurements = decoded
  }

  func interpolate(direction: SpatialVector) -> (ears: [[Float]], peaks: [Float]) {
    let target = direction.unit
    let nearest = measurements.enumerated().map {
      (index: $0.offset, distance: $0.element.direction.squaredDistance(to: target))
    }.sorted { $0.distance < $1.distance }.prefix(4)
    if let first = nearest.first, first.distance < 1e-8 {
      let m = measurements[first.index]
      return (m.ears, m.peaks)
    }
    let total = nearest.reduce(Float(0)) { $0 + 1 / max($1.distance, 1e-8) }
    var ears = Array(repeating: [Float](repeating: 0, count: 512), count: 2)
    var peaks = [Float](repeating: 0, count: 2)
    for item in nearest {
      let weight = 1 / max(item.distance, 1e-8) / total
      let m = measurements[item.index]
      for ear in 0..<2 {
        peaks[ear] += weight * m.peaks[ear]
        for tap in 0..<512 { ears[ear][tap] += weight * m.ears[ear][tap] }
      }
    }
    return (ears, peaks)
  }
}

enum SpatialImpulseBuilder {
  static func paths(settings: SpatialAudioSettings) -> [SpatialPath] {
    let s = settings.normalized
    let angle = s.speakerAngle * .pi / 180
    var result: [SpatialPath] = []
    for input in 0..<2 {
      let left = s.speakerDistance * sin(angle) * (input == 0 ? Float(1) : -1)
      let forward = s.speakerDistance * cos(angle)
      let direct = SpatialVector(x: forward, y: left, z: 0)
      let axis = SpatialVector(x:-direct.unit.x,y:-direct.unit.y,z:0)
      result.append(SpatialPath(input: input, direction: direct.unit,
        distance: direct.length, gain: 0.5, reflected: false, emissionAxis:axis))
      let images = [
        SpatialVector(x: forward, y: s.width-left, z: 0),
        SpatialVector(x: forward, y: -s.width-left, z: 0),
        SpatialVector(x: 1.24*s.depth-forward, y: left, z: 0),
        SpatialVector(x: -0.76*s.depth-forward, y: left, z: 0),
        SpatialVector(x: forward, y: left, z: -2.4),
        SpatialVector(x: forward, y: left, z: 2*(s.height-1.2)),
      ]
      for (index,image) in images.enumerated() {
        // Side-wall mirrors flip y; front/rear mirrors flip x; floor/ceiling
        // flip z (the current horizontal speaker axis has z=0).
        let imageAxis = SpatialVector(x:index == 2 || index == 3 ? -axis.x : axis.x,
          y:index < 2 ? -axis.y : axis.y,z:0)
        result.append(SpatialPath(input: input, direction: image.unit,
          distance: image.length,
          gain: 0.5 * 0.65 * s.roomAmount * s.speakerDistance/image.length,
          reflected: true, emissionAxis:imageAxis))
      }
    }
    return result
  }

  static func build(settings: SpatialAudioSettings, database: HRTFDatabase,
                    sampleRate: Double) -> SpatialImpulseResponse {
    let s = settings.normalized
    guard s.enabled else {
      return SpatialImpulseResponse(samples: [1,0,0,1], frames: 1, paths: [])
    }
    let paths = paths(settings: s)
    let ratio = Float(sampleRate/database.sampleRate)
    let longest = paths.map(\.distance).max() ?? 0
    let frames = Int(ceil(longest/343 * Float(sampleRate))) + Int(ceil(Float(768+SpeakerCabinet.tailFrames)*ratio)) + 2
    var matrix = [Float](repeating: 0, count: frames*4)
    for path in paths {
      let hrtf = database.interpolate(direction: path.direction)
      for ear in 0..<2 {
        var filter = hrtf.ears[ear]
        if path.reflected { filter = absorb(filter, treatment: s.treatment) }
        filter = SpeakerCabinet.filter(filter,cosine:path.emissionCosine)
        let resampled = resample(filter, ratio: Double(ratio))
        let delay = path.distance/343 * Float(sampleRate) + (hrtf.peaks[ear]-160)*ratio
        for (tap, value) in resampled.enumerated() {
          let position = Float(tap) + delay
          let index = Int(floor(position))
          let fraction = position-Float(index)
          let offset = (path.input*2+ear)*frames
          if index >= 0, index < frames { matrix[offset+index] += value*path.gain*(1-fraction) }
          if index+1 >= 0, index+1 < frames { matrix[offset+index+1] += value*path.gain*fraction }
        }
      }
    }
    return SpatialImpulseResponse(samples: matrix, frames: frames, paths: paths)
  }

  private static func absorb(_ input: [Float], treatment: Float) -> [Float] {
    let lowGain = sqrt(1 - (0.10 + 0.30*treatment))
    let midGain = sqrt(1 - (0.15 + 0.65*treatment))
    let highGain = sqrt(1 - (0.22 + 0.65*treatment))
    let lowPole = 1 - exp(-2 * Float.pi * 350/48_000)
    let broadPole = 1 - exp(-2 * Float.pi * 4000/48_000)
    var low: Float = 0, broad: Float = 0
    return (input + [Float](repeating: 0, count: 256)).map { x in
      low += lowPole*(x-low)
      broad += broadPole*(x-broad)
      return low*lowGain + (broad-low)*midGain + (x-broad)*highGain
    }
  }

  // Evaluate the actual reflection filter used above for the visual probe.
  static func reflectionMagnitude(treatment: Float, frequency: Float) -> Float {
    let impulse = absorb([1] + [Float](repeating: 0, count: 511), treatment: treatment)
    let omega = 2 * Float.pi * frequency/48_000
    var real: Float = 0, imaginary: Float = 0
    for (i, sample) in impulse.enumerated() {
      real += sample*cos(omega*Float(i))
      imaginary -= sample*sin(omega*Float(i))
    }
    return sqrt(real*real+imaginary*imaginary)
  }

  // Offline windowed-sinc resampling: includes anti-alias filtering for rates
  // below 48 kHz. Never executes in the render callback.
  static func resample(_ input: [Float], ratio: Double) -> [Float] {
    if abs(ratio-1) < 1e-8 { return input }
    let count = Int(ceil(Double(input.count)*ratio))
    let cutoff = min(1, ratio)*0.94
    let radius = Int(ceil(16/min(1, ratio)))
    return (0..<count).map { index in
      let position = Double(index)/ratio
      let center = Int(floor(position))
      var sum = 0.0
      for tap in (center-radius)...(center+radius) where tap >= 0 && tap < input.count {
        let distance = position-Double(tap)
        let phase = Double.pi*distance*cutoff
        let sinc = abs(phase) < 1e-10 ? 1 : sin(phase)/phase
        let window = 0.5 + 0.5*cos(Double.pi*distance/Double(radius+1))
        sum += Double(input[tap])*cutoff*sinc*window
      }
      return Float(sum/ratio)
    }
  }
}

// One serial control queue owns asset loading, FFT preparation, and publication.
// The audio thread only calls the C renderer. Capturing this object in the source
// node keeps its buffers alive until rendering has stopped; queued work also
// retains it, so stopping during a rebuild cannot free an in-flight renderer.
final class SpatialAudioRenderer: @unchecked Sendable {
  let handle: OpaquePointer
  let sampleRate: Double
  private let queue = DispatchQueue(label: "nl.mingo.HeadphoneEQ.spatial", qos: .userInitiated)
  private var databases: [HRTFProfile: HRTFDatabase] = [:] // control queue only

  init(sampleRate: Double, settings: SpatialAudioSettings) throws {
    guard let handle = HLMSpatialCreate(sampleRate) else { throw SpatialAudioError.allocation }
    self.handle = handle
    self.sampleRate = sampleRate
    // Initial setup happens before the audio engine starts.
    try prepare(settings)
  }

  deinit { HLMSpatialDestroy(handle) }

  func update(_ settings: SpatialAudioSettings,
              completion: @escaping @Sendable (String?) -> Void) {
    queue.async { [self] in
      do { try prepare(settings); completion(nil) }
      catch { completion(error.localizedDescription) }
    }
  }

  private func prepare(_ settings: SpatialAudioSettings) throws {
    let s = settings.normalized
    let impulse: SpatialImpulseResponse
    if s.enabled {
      let database: HRTFDatabase
      if let cached = databases[s.hrtf] { database = cached }
      else {
        database = try HRTFDatabase(profile: s.hrtf)
        databases[s.hrtf] = database
      }
      impulse = SpatialImpulseBuilder.build(settings: s, database: database, sampleRate: sampleRate)
    } else {
      impulse = SpatialImpulseResponse(samples: [1,0,0,1], frames: 1, paths: [])
    }
    let state = impulse.samples.withUnsafeBufferPointer {
      HLMSpatialStateCreate(sampleRate, $0.baseAddress!, UInt32(impulse.frames), s.enabled,
        s.width, s.depth, s.height, s.treatment, s.roomAmount)
    }
    guard let state else { throw SpatialAudioError.allocation }
    if s.enabled { SpeakerCabinet.configureLateField(state) }
    HLMSpatialPublish(handle, state)
  }
}
