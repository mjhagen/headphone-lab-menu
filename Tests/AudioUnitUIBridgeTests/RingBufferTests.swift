import AVFoundation
import AudioBridge
import XCTest

final class RingBufferTests: XCTestCase {
  private let format = AVAudioFormat(
    standardFormatWithSampleRate: 48_000,
    channels: 2
  )!

  func testStereoRoundTrip() throws {
    let ring = try XCTUnwrap(HLMRingCreate(16))
    defer { HLMRingDestroy(ring) }

    let input = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
    )
    input.frameLength = 4
    let inputChannels = try XCTUnwrap(input.floatChannelData)
    inputChannels[0][0] = 0.1
    inputChannels[0][1] = 0.2
    inputChannels[0][2] = 0.3
    inputChannels[0][3] = 0.4
    inputChannels[1][0] = -0.1
    inputChannels[1][1] = -0.2
    inputChannels[1][2] = -0.3
    inputChannels[1][3] = -0.4

    HLMRingWrite(ring, input.mutableAudioBufferList, input.frameLength)

    let output = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
    )
    output.frameLength = 4
    HLMRingRead(ring, output.mutableAudioBufferList, output.frameLength)

    let outputChannels = try XCTUnwrap(output.floatChannelData)
    for frame in 0..<4 {
      XCTAssertEqual(
        outputChannels[0][frame],
        inputChannels[0][frame],
        accuracy: 0.000_001
      )
      XCTAssertEqual(
        outputChannels[1][frame],
        inputChannels[1][frame],
        accuracy: 0.000_001
      )
    }
  }

  func testUnderflowProducesSilence() throws {
    let ring = try XCTUnwrap(HLMRingCreate(8))
    defer { HLMRingDestroy(ring) }

    let output = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
    )
    output.frameLength = 4
    let channels = try XCTUnwrap(output.floatChannelData)
    for frame in 0..<4 {
      channels[0][frame] = 1
      channels[1][frame] = 1
    }

    HLMRingRead(ring, output.mutableAudioBufferList, output.frameLength)

    for frame in 0..<4 {
      XCTAssertEqual(channels[0][frame], 0)
      XCTAssertEqual(channels[1][frame], 0)
    }
  }

  func testInterleavedStereoRoundTrip() throws {
    let interleavedFormat = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true
      )
    )
    let ring = try XCTUnwrap(HLMRingCreate(16))
    defer { HLMRingDestroy(ring) }

    let input = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: interleavedFormat, frameCapacity: 3)
    )
    input.frameLength = 3
    let inputSamples = try XCTUnwrap(
      input.mutableAudioBufferList.pointee.mBuffers.mData?
        .assumingMemoryBound(to: Float.self)
    )
    let expected: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3]
    for (index, sample) in expected.enumerated() {
      inputSamples[index] = sample
    }
    HLMRingWrite(ring, input.mutableAudioBufferList, input.frameLength)

    let output = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: interleavedFormat, frameCapacity: 3)
    )
    output.frameLength = 3
    HLMRingRead(ring, output.mutableAudioBufferList, output.frameLength)
    let outputSamples = try XCTUnwrap(
      output.mutableAudioBufferList.pointee.mBuffers.mData?
        .assumingMemoryBound(to: Float.self)
    )

    for (index, sample) in expected.enumerated() {
      XCTAssertEqual(outputSamples[index], sample, accuracy: 0.000_001)
    }
  }

  func testZeroCapacityIsRejected() {
    XCTAssertNil(HLMRingCreate(0))
  }

  func testOverflowDropsNewFramesWithoutOverwritingUnreadAudio() throws {
    let ring = try XCTUnwrap(HLMRingCreate(4))
    defer { HLMRingDestroy(ring) }

    let original = try buffer(left: [1, 2, 3, 4], right: [-1, -2, -3, -4])
    HLMRingWrite(ring, original.mutableAudioBufferList, original.frameLength)

    let overflow = try buffer(left: [5, 6], right: [-5, -6])
    HLMRingWrite(ring, overflow.mutableAudioBufferList, overflow.frameLength)

    let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
    output.frameLength = 4
    HLMRingRead(ring, output.mutableAudioBufferList, output.frameLength)
    let channels = try XCTUnwrap(output.floatChannelData)
    XCTAssertEqual(Array(UnsafeBufferPointer(start: channels[0], count: 4)), [1, 2, 3, 4])
    XCTAssertEqual(Array(UnsafeBufferPointer(start: channels[1], count: 4)), [-1, -2, -3, -4])
  }

  func testAnalyzerReadsMonoSamplesAndTracksPeak() throws {
    let ring = try XCTUnwrap(HLMRingCreate(8))
    defer { HLMRingDestroy(ring) }
    let input = try buffer(left: [0.2, -1.1, 0.4], right: [0.4, -0.9, 0.2])

    HLMRingWriteAnalyzed(ring, input.mutableAudioBufferList, input.frameLength)

    XCTAssertEqual(HLMRingAvailable(ring), 3)
    var mono = [Float](repeating: 0, count: 3)
    let read = mono.withUnsafeMutableBufferPointer {
      HLMRingReadMono(ring, $0.baseAddress!, UInt32($0.count))
    }
    XCTAssertEqual(read, 3)
    XCTAssertEqual(mono[0], 0.3, accuracy: 0.000_001)
    XCTAssertEqual(mono[1], -1, accuracy: 0.000_001)
    XCTAssertEqual(mono[2], 0.3, accuracy: 0.000_001)
    XCTAssertEqual(HLMRingAvailable(ring), 0)
    XCTAssertEqual(HLMRingTakePeak(ring), 1.1, accuracy: 0.000_001)
    XCTAssertEqual(HLMRingTakePeak(ring), 0)
  }

  private func buffer(left: [Float], right: [Float]) throws -> AVAudioPCMBuffer {
    XCTAssertEqual(left.count, right.count)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))
    )
    buffer.frameLength = AVAudioFrameCount(left.count)
    let channels = try XCTUnwrap(buffer.floatChannelData)
    for index in left.indices {
      channels[0][index] = left[index]
      channels[1][index] = right[index]
    }
    return buffer
  }
}
