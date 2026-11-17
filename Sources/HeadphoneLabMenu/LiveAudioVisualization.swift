import AudioBridge
import Foundation

enum LiveAudioBand: Int, CaseIterable, Sendable {
  case full, low, mid, high
  var title: String { ["FULL", "125 Hz", "1 kHz", "4 kHz"][rawValue] }
  var meterIndex: Int? { self == .full ? nil : rawValue-1 }
}

struct LiveAudioPacket: Sendable {
  let audioTime: Double
  let duration: Double
  let inputRMS: [Float]
  let inputBands: [[Float]]
  let outputRMS: [Float]
  let outputPeak: [Float]
  let minimum: [[Float]]
  let maximum: [[Float]]
}

struct LiveAudioSnapshot: Sendable {
  let stream: UInt64
  let generation: UInt32
  let audioTime: Double
  let packets: [LiveAudioPacket]
}

// The source node retains this object until rendering stops. Only C touches its
// producer state; one main-actor reader drains the independent display queue.
final class LiveAudioMonitor: @unchecked Sendable {
  let handle: OpaquePointer
  init(sampleRate: Double) throws {
    guard let handle = HLMLiveMonitorCreate(sampleRate) else { throw SpatialAudioError.allocation }
    self.handle = handle
  }
  deinit { HLMLiveMonitorDestroy(handle) }
}

@MainActor
final class LiveAudioReader {
  private var scratch = [HLMLiveAudioFrame](repeating: HLMLiveAudioFrame(), count: 128)

  func snapshot(monitor: LiveAudioMonitor, sampleRate: Double, stream: UInt64) -> LiveAudioSnapshot {
    let generation = HLMLiveMonitorGeneration(monitor.handle)
    let count = scratch.withUnsafeMutableBufferPointer {
      Int(HLMLiveMonitorRead(monitor.handle,$0.baseAddress!,UInt32($0.count)))
    }
    let latest = max(HLMLiveMonitorCurrentFrame(monitor.handle),
      count > 0 ? scratch[count-1].endFrame : 0)
    var packets: [LiveAudioPacket] = []
    for i in 0..<count {
      let raw = scratch[i]
      guard raw.generation == generation,
        Double(latest-raw.endFrame)/sampleRate <= 0.20 else { continue }
      let bands = withUnsafeBytes(of: raw.inputBandRMS) { Array($0.bindMemory(to: Float.self)) }
      let minimum = withUnsafeBytes(of: raw.outputMinimum) { Array($0.bindMemory(to: Float.self)) }
      let maximum = withUnsafeBytes(of: raw.outputMaximum) { Array($0.bindMemory(to: Float.self)) }
      let bins = Int(HLM_LIVE_SCOPE_BINS)
      packets.append(LiveAudioPacket(audioTime: Double(raw.endFrame)/sampleRate,
        duration: Double(raw.frameCount)/sampleRate,
        inputRMS: [raw.inputRMS.0,raw.inputRMS.1],
        inputBands: [Array(bands[0..<3]),Array(bands[3..<6])],
        outputRMS: [raw.outputRMS.0,raw.outputRMS.1],
        outputPeak: [raw.outputPeak.0,raw.outputPeak.1],
        minimum: [Array(minimum[0..<bins]),Array(minimum[bins..<bins*2])],
        maximum: [Array(maximum[0..<bins]),Array(maximum[bins..<bins*2])]))
    }
    return LiveAudioSnapshot(stream: stream,generation: generation,
      audioTime: Double(latest)/sampleRate,packets: packets)
  }
}

struct LiveAudioWave: Sendable {
  let source: Int
  let born: Double
  let strength: Float
  let spectralEnergy: [Float]
}

struct LiveAudioScopePoint: Sendable {
  let time: Double
  let minimum: [Float]
  let maximum: [Float]
}
struct LiveAudioLevelPoint: Sendable {
  let time: Double
  let rms: [Float]
}

/// Converts measured packets to bounded visual histories. Silence never creates
/// events. Levels use a fixed −72 dBFS threshold, preserving left/right and
/// polarity-independent energy rather than folding stereo to mono.
struct LiveAudioVisualState: Sendable {
  private(set) var waves: [LiveAudioWave] = []
  private(set) var scope: [LiveAudioScopePoint] = []
  private(set) var history: [LiveAudioLevelPoint] = []
  private(set) var inputLevel: [Float] = [0,0]
  private(set) var outputLevel: [Float] = [0,0]
  private(set) var hasStream = false
  private var stream: UInt64?
  private var generation: UInt32?
  private var lastPacket = -Double.infinity
  private var lastTick: Double?
  private var lastEmission: [Double] = [-.infinity,-.infinity]
  private var previousStrength: [Float] = [0,0]
  private var targetInput: [Float] = [0,0]
  private var targetOutput: [Float] = [0,0]

  static func displayStrength(_ rms: Float) -> Float {
    guard rms.isFinite, rms > 0 else { return 0 }
    return min(1,max(0,(20*log10(rms)+72)/57))
  }

  mutating func resetWaves() {
    waves.removeAll(keepingCapacity: true)
    previousStrength = [0,0]
    lastEmission = [-.infinity,-.infinity]
  }

  mutating func advance(_ snapshot: LiveAudioSnapshot?, now: Double, band: LiveAudioBand,
                       emitWaves: Bool = true, lifetime: Double = 3.5) {
    if let snapshot {
      if stream != snapshot.stream || generation != snapshot.generation {
        self = LiveAudioVisualState()
        stream = snapshot.stream; generation = snapshot.generation
      }
      hasStream = true
      for packet in snapshot.packets {
        let time = now-max(0,snapshot.audioTime-packet.audioTime)
        guard now-time <= 0.20 else { continue }
        lastPacket = time
        targetInput = band.meterIndex.map { b in packet.inputBands.map { $0[b] } } ?? packet.inputRMS
        targetOutput = packet.outputRMS
        for channel in 0..<2 {
          let rms = band.meterIndex.map { packet.inputBands[channel][$0] } ?? packet.inputRMS[channel]
          let strength = Self.displayStrength(rms)
          let elapsed = time-lastEmission[channel]
          if emitWaves, strength > 0,
            elapsed >= 0.40 || (elapsed >= 0.20 && strength > previousStrength[channel]+0.12) {
            waves.append(LiveAudioWave(source: channel,born: time,strength: strength,
              spectralEnergy: packet.inputBands[channel].map { $0*$0 }))
            lastEmission[channel] = time
          }
          previousStrength[channel] = strength
        }
        let bins = packet.minimum[0].count
        for i in 0..<bins {
          scope.append(LiveAudioScopePoint(time: time-packet.duration*Double(bins-1-i)/Double(bins),
            minimum: [packet.minimum[0][i],packet.minimum[1][i]],
            maximum: [packet.maximum[0][i],packet.maximum[1][i]]))
        }
        history.append(LiveAudioLevelPoint(time: time,rms: packet.outputRMS))
      }
    } else { hasStream = false; resetWaves() }
    if now-lastPacket > 0.20 || !hasStream {
      targetInput = [0,0]; targetOutput = [0,0]
      // A stopped route has no new packets; show a real zero-level continuation.
      history.append(LiveAudioLevelPoint(time: now,rms: [0,0]))
    }
    let elapsed = max(0, min(0.2, now-(lastTick ?? now-1.0/30)))
    lastTick = now
    for c in 0..<2 {
      let inputTime = targetInput[c] > inputLevel[c] ? 0.025 : 0.12
      let outputTime = targetOutput[c] > outputLevel[c] ? 0.025 : 0.12
      inputLevel[c] += (targetInput[c]-inputLevel[c])*Float(1-exp(-elapsed/inputTime))
      outputLevel[c] += (targetOutput[c]-outputLevel[c])*Float(1-exp(-elapsed/outputTime))
      if inputLevel[c] < 1e-7 { inputLevel[c] = 0 }
      if outputLevel[c] < 1e-7 { outputLevel[c] = 0 }
    }
    waves.removeAll { now-$0.born > lifetime }
    // Retain enough history for slower wall returns, while bounding each source
    // independently so a busy channel cannot crowd out the other speaker.
    for channel in 0..<2 {
      var excess = waves.filter { $0.source == channel }.count-12
      if excess > 0 {
        waves.removeAll { wave in
          guard excess > 0, wave.source == channel else { return false }
          excess -= 1
          return true
        }
      }
    }
    scope.removeAll { now-$0.time > 0.080 }
    history.removeAll { now-$0.time > 3 }
    if scope.count > 1024 { scope.removeFirst(scope.count-1024) }
    if history.count > 400 { history.removeFirst(history.count-400) }
  }
}
