import AVFoundation
import BestASRDictation
import BestASRDomain
import Foundation
import XCTest

@testable import BestASRMacAudio

final class AVAudioEngineMicrophoneCaptureTests: XCTestCase {
  func testCallbackChunksCoalesceToTheLowLatencyDurableBoundary() throws {
    var accumulator = CapturedPCMChunkAccumulator(
      maximumDurationNanoseconds: 500_000_000
    )
    let trackID = TrackID()

    XCTAssertTrue(
      try accumulator.append(
        pcmChunk(trackID: trackID, start: 0, frames: 1, sampleRate: 4)
      ).isEmpty
    )
    let committed = try accumulator.append(
      pcmChunk(
        trackID: trackID,
        start: 250_000_000,
        frames: 1,
        sampleRate: 4
      )
    )

    XCTAssertEqual(committed.count, 1)
    XCTAssertEqual(committed[0].sequence, 0)
    XCTAssertEqual(committed[0].frameCount, 2)
    XCTAssertEqual(committed[0].monotonicStartNanoseconds, 0)
    XCTAssertEqual(committed[0].bytes.count, 8)
    XCTAssertNil(accumulator.flush())
  }

  func testCallbackDiscontinuityFlushesWithoutHidingTheGap() throws {
    var accumulator = CapturedPCMChunkAccumulator(
      maximumDurationNanoseconds: 500_000_000
    )
    let trackID = TrackID()
    _ = try accumulator.append(
      pcmChunk(trackID: trackID, start: 0, frames: 1, sampleRate: 4)
    )

    let boundary = try accumulator.append(
      pcmChunk(
        trackID: trackID,
        start: 1_000_000_000,
        frames: 1,
        sampleRate: 4
      )
    )

    XCTAssertEqual(boundary.map(\.monotonicStartNanoseconds), [0])
    XCTAssertEqual(boundary.map(\.frameCount), [1])
    XCTAssertEqual(accumulator.flush()?.monotonicStartNanoseconds, 1_000_000_000)
  }

  func testDefaultDeviceSelectionDoesNotReconfigureAudioUnit() {
    XCTAssertFalse(
      MicrophoneDeviceSelectionPolicy.requiresExplicitSelection(
        selectedDeviceUID: nil,
        defaultDeviceUID: "built-in"
      )
    )
    XCTAssertFalse(
      MicrophoneDeviceSelectionPolicy.requiresExplicitSelection(
        selectedDeviceUID: "built-in",
        defaultDeviceUID: "built-in"
      )
    )
    XCTAssertTrue(
      MicrophoneDeviceSelectionPolicy.requiresExplicitSelection(
        selectedDeviceUID: "usb-microphone",
        defaultDeviceUID: "built-in"
      )
    )
  }

  func testInvalidInputFormatRetryIsBoundedAndBacksOff() {
    XCTAssertEqual(
      MicrophoneFormatSettlingPolicy.retryDelaysNanoseconds,
      [50_000_000, 100_000_000, 200_000_000, 400_000_000, 800_000_000]
    )
    XCTAssertEqual(
      MicrophoneFormatSettlingPolicy.delay(afterFailedAttempt: 0),
      50_000_000
    )
    XCTAssertEqual(
      MicrophoneFormatSettlingPolicy.delay(afterFailedAttempt: 4),
      800_000_000
    )
    XCTAssertNil(
      MicrophoneFormatSettlingPolicy.delay(afterFailedAttempt: 5)
    )
  }

  func testPermissionDenialFailsBeforeTouchingDevice() async throws {
    let provider = CountingDeviceProvider(result: .success(deviceInfo()))
    let capture = AVAudioEngineMicrophoneCapture(
      authorization: FixedAuthorization(state: .denied),
      deviceProvider: provider
    )
    await assertThrowsMacMicrophoneError(.permissionNotGranted(.denied)) {
      _ = try await capture.prepare(sessionID: SessionID())
    }
    XCTAssertEqual(provider.callCount, 0)
  }

  func testFailedPrestartLeavesANormalStartWithTheRealError() async throws {
    let provider = CountingDeviceProvider(result: .success(deviceInfo()))
    let capture = AVAudioEngineMicrophoneCapture(
      authorization: FixedAuthorization(state: .denied),
      deviceProvider: provider
    )
    let sessionID = SessionID()
    await assertThrowsMacMicrophoneError(.permissionNotGranted(.denied)) {
      try await capture.prestart(sessionID: sessionID)
    }
    await assertThrowsMacMicrophoneError(.permissionNotGranted(.denied)) {
      _ = try await capture.prepare(sessionID: sessionID)
    }
    XCTAssertEqual(provider.callCount, 0)
  }

  func testNoDefaultDeviceIsExplicit() async throws {
    let capture = AVAudioEngineMicrophoneCapture(
      authorization: FixedAuthorization(state: .granted),
      deviceProvider: CountingDeviceProvider(
        result: .failure(.noDefaultInputDevice)
      )
    )
    await assertThrowsMacMicrophoneError(.noDefaultInputDevice) {
      _ = try await capture.prepare(sessionID: SessionID())
    }
  }

  func testInactivePauseResumeAndStopFailClosed() async throws {
    let capture = AVAudioEngineMicrophoneCapture(
      authorization: FixedAuthorization(state: .granted),
      deviceProvider: CountingDeviceProvider(result: .success(deviceInfo()))
    )
    await assertThrowsMacMicrophoneError(.notActive) {
      try await capture.pause()
    }
    await assertThrowsMacMicrophoneError(.notActive) {
      try await capture.resume()
    }
    await assertThrowsMacMicrophoneError(.notActive) {
      try await capture.stop()
    }
  }

  func testPCMBufferCopyInterleavesChannelsAndPreservesFrames() throws {
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
      )
    )
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2)
    )
    buffer.frameLength = 2
    let channels = try XCTUnwrap(buffer.floatChannelData)
    channels[0][0] = 0.25
    channels[0][1] = 0.5
    channels[1][0] = -0.25
    channels[1][1] = -0.5

    let chunk = try MicrophonePCMBufferCopier.copy(
      buffer,
      time: AVAudioTime(hostTime: 1),
      sequence: 7
    )

    XCTAssertEqual(chunk.sequence, 7)
    XCTAssertEqual(chunk.frameCount, 2)
    XCTAssertEqual(chunk.sampleRateHertz, 48_000)
    XCTAssertEqual(chunk.channelCount, 2)
    XCTAssertTrue(chunk.interleaved)
    XCTAssertEqual(
      decodeFloatData(chunk.bytes),
      [0.25, -0.25, 0.5, -0.5]
    )
  }

  func testBoundedCallbackStreamTerminatesOnOverflow() throws {
    let pair = AsyncStream.makeStream(
      of: CapturedPCMChunk.self,
      bufferingPolicy: .bufferingOldest(1)
    )
    let state = MicrophoneCallbackState(
      continuation: pair.continuation,
      maximumChunkDurationNanoseconds: 1
    )
    let format = try XCTUnwrap(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      )
    )
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)
    )
    buffer.frameLength = 1
    buffer.floatChannelData?[0][0] = 0.1

    state.receive(buffer: buffer, time: AVAudioTime(hostTime: 1))
    state.receive(buffer: buffer, time: AVAudioTime(hostTime: 2))

    XCTAssertEqual(state.failure(), .bufferOverflow)
  }

  private func deviceInfo() -> MicrophoneDeviceInfo {
    MicrophoneDeviceInfo(
      deviceID: 1,
      uid: "fixture-input",
      name: "Fixture Input",
      transportType: 0,
      isBuiltIn: true
    )
  }

  private func pcmChunk(
    trackID: TrackID,
    start: UInt64,
    frames: UInt64,
    sampleRate: UInt32
  ) -> CapturedPCMChunk {
    CapturedPCMChunk(
      trackID: trackID,
      sequence: 0,
      monotonicStartNanoseconds: start,
      frameCount: frames,
      sampleRateHertz: sampleRate,
      channelCount: 1,
      encoding: .float32LittleEndian,
      interleaved: true,
      bytes: Data(repeating: 0, count: Int(frames) * 4)
    )
  }

  func testSpeechPauseDetectorReportsOnePauseAndAResume() {
    var detector = SpeechPauseDetector()
    let buffer = 0.046
    var events: [SpeechPauseDetector.Event] = []
    func feed(_ rms: Float, _ count: Int) {
      for _ in 0..<count {
        if let event = detector.consume(rms: rms, seconds: buffer) { events.append(event) }
      }
    }
    feed(0.004, 20)  // quiet before speaking is not a pause
    feed(0.08, 3)  // 138 ms of speech is too short
    feed(0.004, 10)
    XCTAssertEqual(events, [])
    feed(0.08, 10)
    feed(0.004, 2)  // 92 ms of quiet is a breath, not a pause
    XCTAssertEqual(events, [])
    feed(0.004, 2)  // 184 ms: start recognizing while the user may still hold
    XCTAssertEqual(events, [.paused])
    feed(0.004, 30)
    feed(0.08, 1)  // a click does not resume
    feed(0.004, 1)
    XCTAssertEqual(events, [.paused])
    feed(0.08, 2)
    XCTAssertEqual(events, [.paused, .resumed])
  }

  func testQuietSpeakerOnAQuietMicrophoneStillPauses() {
    // Measured on the user's microphone: room ~0.0014, speech 0.005–0.014.
    var detector = SpeechPauseDetector()
    var events: [SpeechPauseDetector.Event] = []
    for rms: Float in Array(repeating: 0.0014, count: 10) + Array(repeating: 0.008, count: 20)
      + Array(repeating: 0.0015, count: 10)
    {
      if let event = detector.consume(rms: rms, seconds: 0.046) { events.append(event) }
    }
    XCTAssertEqual(events, [.paused])
  }
}

private struct FixedAuthorization: MicrophoneAuthorizationChecking {
  let stateValue: DictationPermissionState

  init(state: DictationPermissionState) {
    stateValue = state
  }

  func state() -> DictationPermissionState { stateValue }
}

private final class CountingDeviceProvider: DefaultInputDeviceProviding,
  @unchecked Sendable
{
  private let lock = NSLock()
  private let result: Result<MicrophoneDeviceInfo, MacMicrophoneCaptureError>
  private var count = 0

  init(result: Result<MicrophoneDeviceInfo, MacMicrophoneCaptureError>) {
    self.result = result
  }

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func currentDefaultInput() throws -> MicrophoneDeviceInfo {
    lock.lock()
    count += 1
    lock.unlock()
    return try result.get()
  }
}

private func decodeFloatData(_ data: Data) -> [Float] {
  data.withUnsafeBytes { bytes in
    stride(from: 0, to: bytes.count, by: 4).map { offset in
      let bits =
        UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
      return Float(bitPattern: bits)
    }
  }
}

private func assertThrowsMacMicrophoneError(
  _ expected: MacMicrophoneCaptureError,
  operation: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await operation()
    XCTFail("Expected \(expected)", file: file, line: line)
  } catch let error as MacMicrophoneCaptureError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
  }

}
