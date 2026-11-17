import AudioBridge
import AVFoundation
import XCTest
@testable import HeadphoneEQ

final class LiveAudioVisualizationTests: XCTestCase {
  func testMonitorLeavesRenderedAudioUnchangedForBothBufferLayouts() throws {
    for interleaved in [false,true] {
      let monitored = try XCTUnwrap(HLMSpatialCreate(48_000))
      let reference = try XCTUnwrap(HLMSpatialCreate(48_000))
      let meter = try XCTUnwrap(HLMLiveMonitorCreate(48_000))
      defer { HLMSpatialDestroy(monitored); HLMSpatialDestroy(reference); HLMLiveMonitorDestroy(meter) }
      var matrix = [Float](repeating:0,count:4*256)
      matrix[0]=0.6; matrix[19]=0.2; matrix[256+31]=0.1
      matrix[512+53] = -0.15; matrix[768+5]=0.6
      for renderer in [monitored,reference] {
        let state = matrix.withUnsafeBufferPointer {
          HLMSpatialStateCreate(48_000,$0.baseAddress!,256,true,5,6,2.7,0.6,0.4)
        }
        HLMSpatialPublish(renderer,try XCTUnwrap(state))
        _ = try Self.render(renderer,meter:nil,left:.init(repeating:0,count:4096),
          right:.init(repeating:0,count:4096),interleaved:interleaved)
      }
      HLMLiveMonitorSetEnabled(meter,true)
      let l = (0..<4099).map { Float(sin(Double($0)*0.11))*0.3 }
      let r = (0..<4099).map { Float(cos(Double($0)*0.19))*0.2 }
      let actual = try Self.render(monitored,meter:meter,left:l,right:r,interleaved:interleaved)
      let expected = try Self.render(reference,meter:nil,left:l,right:r,interleaved:interleaved)
      for ear in 0..<2 {
        for i in l.indices { XCTAssertEqual(actual[ear][i],expected[ear][i],accuracy:0.000001) }
      }
    }
  }

  func testStereoEnergyAndAnalysisBandsPreserveOppositePolarity() throws {
    let renderer = try XCTUnwrap(HLMSpatialCreate(48_000))
    let meter = try XCTUnwrap(HLMLiveMonitorCreate(48_000))
    defer { HLMSpatialDestroy(renderer); HLMLiveMonitorDestroy(meter) }
    HLMLiveMonitorSetEnabled(meter,true)
    let l = (0..<9600).map { Float(sin(2*Double.pi*1000*Double($0)/48_000))*0.5 }
    _ = try Self.render(renderer,meter:meter,left:l,right:l.map { -$0 })
    let packets = Self.read(meter)
    let packet = try XCTUnwrap(packets.last)
    XCTAssertEqual(packets.count,20)
    XCTAssertEqual(packet.inputRMS.0,0.353553,accuracy:0.001)
    XCTAssertEqual(packet.inputRMS.1,0.353553,accuracy:0.001)
    let bands = withUnsafeBytes(of:packet.inputBandRMS) { Array($0.bindMemory(to:Float.self)) }
    XCTAssertGreaterThan(bands[1],bands[0]*3)
    XCTAssertGreaterThan(bands[1],bands[2]*2)
    XCTAssertEqual(bands[1],bands[4],accuracy:0.000001)
    XCTAssertGreaterThan(packet.outputPeak.0,0.49)
    XCTAssertGreaterThan(packet.outputPeak.1,0.49)
    let low = withUnsafeBytes(of:packet.outputMinimum) { Array($0.bindMemory(to:Float.self)) }
    let high = withUnsafeBytes(of:packet.outputMaximum) { Array($0.bindMemory(to:Float.self)) }
    XCTAssertTrue(zip(low,high).allSatisfy { $0 <= $1 })
    XCTAssertLessThan(low.min()!, -0.49)
    XCTAssertGreaterThan(high.max()!,0.49)
  }

  func testMonitoringIsOptInAndResumeDoesNotReplayOldAudio() throws {
    let renderer = try XCTUnwrap(HLMSpatialCreate(48_000))
    let meter = try XCTUnwrap(HLMLiveMonitorCreate(48_000))
    defer { HLMSpatialDestroy(renderer); HLMLiveMonitorDestroy(meter) }
    _ = try Self.render(renderer,meter:meter,left:.init(repeating:0.5,count:4800),right:.init(repeating:0,count:4800))
    XCTAssertTrue(Self.read(meter).isEmpty)
    XCTAssertEqual(HLMLiveMonitorCurrentFrame(meter),4800)
    HLMLiveMonitorSetEnabled(meter,true)
    _ = try Self.render(renderer,meter:meter,left:.init(repeating:0.5,count:480),right:.init(repeating:0,count:480))
    // Leave the previous packet unread, as if the user froze the display.
    HLMLiveMonitorSetEnabled(meter,false)
    _ = try Self.render(renderer,meter:meter,left:.init(repeating:0,count:4800),right:.init(repeating:0,count:4800))
    HLMLiveMonitorSetEnabled(meter,true)
    _ = try Self.render(renderer,meter:meter,left:.init(repeating:0,count:480),right:.init(repeating:0,count:480))
    let packets = Self.read(meter)
    XCTAssertEqual(packets.count,1)
    XCTAssertEqual(packets[0].generation,HLMLiveMonitorGeneration(meter))
    XCTAssertEqual(packets[0].inputRMS.0,0)
    XCTAssertEqual(packets[0].inputRMS.1,0)
    let bands = withUnsafeBytes(of:packets[0].inputBandRMS) { Array($0.bindMemory(to:Float.self)) }
    XCTAssertTrue(bands.allSatisfy { $0 == 0 })
  }

  func testReaderRejectsAnOverflowedStaleBacklog() async throws {
    try await MainActor.run {
      let renderer = try XCTUnwrap(HLMSpatialCreate(48_000))
      let monitor = try LiveAudioMonitor(sampleRate:48_000)
      defer { HLMSpatialDestroy(renderer) }
      HLMLiveMonitorSetEnabled(monitor.handle,true)
      _ = try Self.render(renderer,meter:monitor.handle,left:.init(repeating:0.2,count:96_000),
        right:.init(repeating:-0.2,count:96_000))
      let reader = LiveAudioReader()
      let stale = reader.snapshot(monitor:monitor,sampleRate:48_000,stream:1)
      XCTAssertTrue(stale.packets.isEmpty)
      _ = try Self.render(renderer,meter:monitor.handle,left:.init(repeating:0.1,count:480),
        right:.init(repeating:-0.1,count:480))
      let fresh = reader.snapshot(monitor:monitor,sampleRate:48_000,stream:1)
      XCTAssertEqual(fresh.packets.count,1)
      XCTAssertEqual(fresh.packets[0].minimum[0].count,32)
      XCTAssertEqual(fresh.packets[0].inputRMS[0],0.1,accuracy:0.00001)
    }
  }

  func testBandSelectionAndPanningDriveMeasuredSourcesOnly() {
    let p = Self.packet(time:0.01,input:[0.2,0.2],bands:[[0.2,0,0],[0,0,0]])
    let snapshot = LiveAudioSnapshot(stream:1,generation:1,audioTime:0.01,packets:[p])
    var low = LiveAudioVisualState()
    low.advance(snapshot,now:1,band:.low)
    XCTAssertEqual(low.waves.map(\.source),[0])
    var high = LiveAudioVisualState()
    high.advance(snapshot,now:1,band:.high)
    XCTAssertTrue(high.waves.isEmpty)
    var full = LiveAudioVisualState()
    full.advance(snapshot,now:1,band:.full)
    XCTAssertEqual(full.waves.map(\.source),[0,1])
    XCTAssertEqual(full.scope.count,32)
    XCTAssertGreaterThan(full.outputLevel[0],0)
  }

  func testSilenceAndStoppedRouteSettleWithoutInventingWaves() {
    var state = LiveAudioVisualState()
    let loud = Self.packet(time:0.01,input:[0.2,0],bands:[[0.1,0.2,0.1],[0,0,0]])
    state.advance(LiveAudioSnapshot(stream:1,generation:1,audioTime:0.01,packets:[loud]),now:1,band:.full)
    XCTAssertEqual(state.waves.count,1)
    for i in 1...120 { state.advance(nil,now:1+Double(i)/30,band:.full,lifetime:1) }
    XCTAssertTrue(state.waves.isEmpty)
    XCTAssertTrue(state.scope.isEmpty)
    XCTAssertEqual(state.inputLevel,[0,0])
    XCTAssertEqual(state.outputLevel,[0,0])
    XCTAssertFalse(state.hasStream)
    XCTAssertEqual(LiveAudioVisualState.displayStrength(0),0)
    XCTAssertEqual(LiveAudioVisualState.displayStrength(.nan),0)
    XCTAssertEqual(LiveAudioVisualState.displayStrength(0.000001),0)
  }

  func testVisualHistoriesAreBoundedAndNewRoutesClearOldData() {
    var state = LiveAudioVisualState()
    for i in 1...1000 {
      let t = Double(i)/100
      let packet = Self.packet(time:t,input:[0.2,0.2],bands:[[0.1,0.2,0.1],[0.1,0.2,0.1]])
      state.advance(LiveAudioSnapshot(stream:1,generation:1,audioTime:t,packets:[packet]),
        now:t,band:.full,lifetime:10)
      XCTAssertLessThanOrEqual(state.waves.count,24)
      for channel in 0..<2 {
        XCTAssertLessThanOrEqual(state.waves.filter { $0.source == channel }.count,12)
      }
      XCTAssertLessThanOrEqual(state.scope.count,1024)
      XCTAssertLessThanOrEqual(state.history.count,400)
    }
    state.advance(LiveAudioSnapshot(stream:2,generation:1,audioTime:0,packets:[]),now:11,band:.full)
    XCTAssertTrue(state.waves.isEmpty)
    XCTAssertTrue(state.scope.isEmpty)
    XCTAssertEqual(state.inputLevel,[0,0])
  }

  func testConcurrentPublishingReadingAndPause() throws {
    final class Context: @unchecked Sendable {
      let monitor: OpaquePointer
      let renderer: OpaquePointer
      let buffer: AVAudioPCMBuffer
      init() throws {
        monitor = try XCTUnwrap(HLMLiveMonitorCreate(48_000))
        renderer = try XCTUnwrap(HLMSpatialCreate(48_000))
        let format = AVAudioFormat(standardFormatWithSampleRate:48_000,channels:2)!
        buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:512)!
        buffer.frameLength = 512
        for i in 0..<512 {
          buffer.floatChannelData![0][i] = Float(sin(Double(i)*0.13))*0.2
          buffer.floatChannelData![1][i] = -buffer.floatChannelData![0][i]
        }
      }
      deinit { HLMSpatialDestroy(renderer); HLMLiveMonitorDestroy(monitor) }
    }
    let context = try Context()
    let finished = expectation(description:"Audio producer completed")
    HLMLiveMonitorSetEnabled(context.monitor,true)
    DispatchQueue.global(qos:.userInitiated).async {
      for _ in 0..<2000 {
        HLMLiveMonitorProcess(context.monitor,context.renderer,
          context.buffer.mutableAudioBufferList,context.buffer.frameLength)
      }
      finished.fulfill()
    }
    for i in 0..<1000 {
      if i%10 == 0 { HLMLiveMonitorSetEnabled(context.monitor,false) }
      if i%10 == 1 { HLMLiveMonitorSetEnabled(context.monitor,true) }
      for packet in Self.read(context.monitor) {
        XCTAssertTrue(packet.inputRMS.0.isFinite && packet.inputRMS.1.isFinite)
        XCTAssertTrue(packet.outputRMS.0.isFinite && packet.outputRMS.1.isFinite)
        XCTAssertEqual(packet.frameCount,480)
      }
    }
    wait(for:[finished],timeout:10)
  }

  private static func packet(time:Double,input:[Float],bands:[[Float]]) -> LiveAudioPacket {
    LiveAudioPacket(audioTime:time,duration:0.01,inputRMS:input,inputBands:bands,
      outputRMS:[0.1,0.1],outputPeak:[0.2,0.2],
      minimum:Array(repeating:Array(repeating:-0.2,count:32),count:2),
      maximum:Array(repeating:Array(repeating:0.2,count:32),count:2))
  }

  private static func read(_ monitor:OpaquePointer) -> [HLMLiveAudioFrame] {
    var frames = [HLMLiveAudioFrame](repeating:HLMLiveAudioFrame(),count:128)
    let count = frames.withUnsafeMutableBufferPointer {
      Int(HLMLiveMonitorRead(monitor,$0.baseAddress!,UInt32($0.count)))
    }
    return Array(frames.prefix(count))
  }

  private static func render(_ renderer:OpaquePointer,meter:OpaquePointer?,left:[Float],right:[Float],
                             interleaved:Bool=false) throws -> [[Float]] {
    let format = try XCTUnwrap(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48_000,
      channels:2,interleaved:interleaved))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:UInt32(left.count)))
    buffer.frameLength = UInt32(left.count)
    let list = buffer.mutableAudioBufferList
    let l = try XCTUnwrap(list.pointee.mBuffers.mData?.assumingMemoryBound(to:Float.self))
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    let r = interleaved ? l : buffers[1].mData!.assumingMemoryBound(to:Float.self)
    for i in left.indices { l[interleaved ? i*2 : i]=left[i]; r[interleaved ? i*2+1 : i]=right[i] }
    if let meter { HLMLiveMonitorProcess(meter,renderer,list,buffer.frameLength) }
    else { HLMSpatialProcess(renderer,list,buffer.frameLength) }
    return [(0..<left.count).map { l[interleaved ? $0*2 : $0] },
      (0..<left.count).map { r[interleaved ? $0*2+1 : $0] }]
  }
}
