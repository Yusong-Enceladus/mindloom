import BestASRDictation
import BestASRDomain
import BestASRMacAudio
import Foundation

private actor CaptureAggregate {
  private var chunkCount = 0
  private var frameCount: UInt64 = 0

  func receive(_ chunk: CapturedPCMChunk) {
    chunkCount += 1
    frameCount += chunk.frameCount
  }

  func snapshot() -> (chunks: Int, frames: UInt64) {
    (chunkCount, frameCount)
  }
}

@main
struct MicrophoneCaptureSmokeCLI {
  static func main() async throws {
    guard ProcessInfo.processInfo.environment["BESTASR_RUN_MICROPHONE_SMOKE"] == "1"
    else {
      print("{\"status\":\"skipped\",\"reason\":\"set-BESTASR_RUN_MICROPHONE_SMOKE-1\"}")
      return
    }
    let capture = AVAudioEngineMicrophoneCapture()
    let sessionID = SessionID()
    let descriptor = try await capture.prepare(sessionID: sessionID)
    let stream = await capture.chunks()
    let aggregate = CaptureAggregate()
    let consumer = Task {
      for await chunk in stream {
        await aggregate.receive(chunk)
      }
    }
    try await capture.start()
    try await Task.sleep(for: .milliseconds(650))
    let beforePause = await aggregate.snapshot()
    try await capture.pause()
    try await Task.sleep(for: .milliseconds(250))
    let duringPause = await aggregate.snapshot()
    try await capture.resume()
    try await Task.sleep(for: .milliseconds(650))
    try await capture.stop()
    await consumer.value
    let completed = await aggregate.snapshot()

    let cancelledCapture = AVAudioEngineMicrophoneCapture()
    _ = try await cancelledCapture.prepare(sessionID: SessionID())
    let cancelledStream = await cancelledCapture.chunks()
    let cancelledAggregate = CaptureAggregate()
    let cancelledConsumer = Task {
      for await chunk in cancelledStream {
        await cancelledAggregate.receive(chunk)
      }
    }
    try await cancelledCapture.start()
    try await Task.sleep(for: .milliseconds(650))
    await cancelledCapture.cancel()
    await cancelledConsumer.value
    let cancelled = await cancelledAggregate.snapshot()

    let builtIn = try await capture.currentDeviceInfo().isBuiltIn
    let pauseBufferedChunkDelta = duringPause.chunks - beforePause.chunks
    let pauseResumeSucceeded =
      beforePause.chunks > 0 && pauseBufferedChunkDelta <= 1
      && completed.chunks > duringPause.chunks
    let cancelSucceeded = cancelled.chunks > 0
    let payload: [String: Any] = [
      "status":
        builtIn && pauseResumeSucceeded && cancelSucceeded ? "pass" : "fail",
      "builtIn": builtIn,
      "sampleRateHertz": descriptor.sampleRateHertz,
      "channelCount": descriptor.channelCount,
      "chunkCount": completed.chunks,
      "frameCount": completed.frames,
      "pauseResumeSucceeded": pauseResumeSucceeded,
      "pauseBufferedChunkDelta": pauseBufferedChunkDelta,
      "cancelSucceeded": cancelSucceeded,
      "cancelChunkCount": cancelled.chunks,
      "cancelFrameCount": cancelled.frames,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  }
}
