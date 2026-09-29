import BestASRDictation
import BestASRDomain
import Foundation

enum CapturedPCMChunkAccumulatorError: Error, Equatable {
  case invalidByteCount
  case unsupportedLayout
}

/// Coalesces real-time callback buffers into short durable blocks. Native
/// audio callbacks are intentionally small, but persisting each callback as a
/// separate crash-safe file creates an unbounded filesystem/manifest burden
/// during long recordings. The default 500 ms boundary keeps first-draft ASR
/// inside its latency budget while remaining well below the two-second source
/// block ceiling.
struct CapturedPCMChunkAccumulator {
  static let defaultMaximumDurationNanoseconds: UInt64 = 500_000_000

  private struct Pending {
    let trackID: TrackID?
    let monotonicStartNanoseconds: UInt64
    let sampleRateHertz: UInt32
    let channelCount: UInt16
    let encoding: PCMEncoding
    let interleaved: Bool
    var frameCount: UInt64
    var bytes: Data
  }

  private let maximumDurationNanoseconds: UInt64
  private var pending: Pending?
  private var nextSequence: UInt64 = 0

  init(
    maximumDurationNanoseconds: UInt64 = Self.defaultMaximumDurationNanoseconds
  ) {
    self.maximumDurationNanoseconds = min(
      2_000_000_000,
      max(1, maximumDurationNanoseconds)
    )
  }

  mutating func append(_ input: CapturedPCMChunk) throws
    -> [CapturedPCMChunk]
  {
    guard input.interleaved else {
      throw CapturedPCMChunkAccumulatorError.unsupportedLayout
    }
    let bytesPerFrame = try Self.bytesPerFrame(for: input)
    guard input.frameCount > 0,
      input.frameCount <= UInt64(Int.max) / UInt64(bytesPerFrame),
      input.bytes.count == Int(input.frameCount) * bytesPerFrame
    else {
      throw CapturedPCMChunkAccumulatorError.invalidByteCount
    }

    var emitted: [CapturedPCMChunk] = []
    if let pending, !Self.canAppend(input, to: pending) {
      if let boundary = flush() { emitted.append(boundary) }
    }

    var remainingFrames = input.frameCount
    var remainingBytes = input.bytes[input.bytes.startIndex..<input.bytes.endIndex]
    var remainingStart = input.monotonicStartNanoseconds
    let targetFrames = Self.targetFrames(
      sampleRateHertz: input.sampleRateHertz,
      maximumDurationNanoseconds: maximumDurationNanoseconds
    )

    while remainingFrames > 0 {
      if pending == nil {
        pending = Pending(
          trackID: input.trackID,
          monotonicStartNanoseconds: remainingStart,
          sampleRateHertz: input.sampleRateHertz,
          channelCount: input.channelCount,
          encoding: input.encoding,
          interleaved: input.interleaved,
          frameCount: 0,
          bytes: Data(
            capacity:
              targetFrames <= UInt64(Int.max / bytesPerFrame)
              ? Int(targetFrames) * bytesPerFrame
              : input.bytes.count
          )
        )
      }
      guard var current = pending else { break }
      let room = targetFrames - current.frameCount
      let acceptedFrames = min(room, remainingFrames)
      let acceptedBytes = Int(acceptedFrames) * bytesPerFrame
      current.bytes.append(contentsOf: remainingBytes.prefix(acceptedBytes))
      current.frameCount += acceptedFrames
      pending = current
      remainingBytes = remainingBytes.dropFirst(acceptedBytes)
      remainingFrames -= acceptedFrames
      remainingStart &+= Self.durationNanoseconds(
        frameCount: acceptedFrames,
        sampleRateHertz: input.sampleRateHertz
      )
      if current.frameCount == targetFrames,
        let completed = flush()
      {
        emitted.append(completed)
      }
    }
    return emitted
  }

  mutating func flush() -> CapturedPCMChunk? {
    guard let pending, pending.frameCount > 0 else { return nil }
    let chunk = CapturedPCMChunk(
      trackID: pending.trackID,
      sequence: nextSequence,
      monotonicStartNanoseconds: pending.monotonicStartNanoseconds,
      frameCount: pending.frameCount,
      sampleRateHertz: pending.sampleRateHertz,
      channelCount: pending.channelCount,
      encoding: pending.encoding,
      interleaved: pending.interleaved,
      bytes: pending.bytes
    )
    nextSequence &+= 1
    self.pending = nil
    return chunk
  }

  mutating func reset() {
    pending = nil
    nextSequence = 0
  }

  mutating func discardPending() {
    pending = nil
  }

  private static func canAppend(
    _ input: CapturedPCMChunk,
    to pending: Pending
  ) -> Bool {
    guard input.trackID == pending.trackID,
      input.sampleRateHertz == pending.sampleRateHertz,
      input.channelCount == pending.channelCount,
      input.encoding.rawValue == pending.encoding.rawValue,
      input.interleaved == pending.interleaved
    else { return false }
    let expectedStart =
      pending.monotonicStartNanoseconds
      &+ durationNanoseconds(
        frameCount: pending.frameCount,
        sampleRateHertz: pending.sampleRateHertz
      )
    let difference =
      expectedStart >= input.monotonicStartNanoseconds
      ? expectedStart - input.monotonicStartNanoseconds
      : input.monotonicStartNanoseconds - expectedStart
    let twoFrames = durationNanoseconds(
      frameCount: 2,
      sampleRateHertz: pending.sampleRateHertz
    )
    return difference <= max(1_000_000, twoFrames)
  }

  private static func targetFrames(
    sampleRateHertz: UInt32,
    maximumDurationNanoseconds: UInt64
  ) -> UInt64 {
    max(
      1,
      UInt64(
        ceil(
          Double(sampleRateHertz) * Double(maximumDurationNanoseconds)
            / 1_000_000_000
        )
      )
    )
  }

  private static func bytesPerFrame(
    for chunk: CapturedPCMChunk
  ) throws -> Int {
    let bytesPerSample =
      switch chunk.encoding {
      case .float32LittleEndian: 4
      case .int16LittleEndian: 2
      }
    let (value, overflow) = bytesPerSample.multipliedReportingOverflow(
      by: Int(chunk.channelCount)
    )
    guard !overflow, value > 0 else {
      throw CapturedPCMChunkAccumulatorError.invalidByteCount
    }
    return value
  }

  private static func durationNanoseconds(
    frameCount: UInt64,
    sampleRateHertz: UInt32
  ) -> UInt64 {
    UInt64(
      (Double(frameCount) * 1_000_000_000 / Double(sampleRateHertz)).rounded()
    )
  }
}
