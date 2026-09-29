import BestASRAudio
import BestASRDictation
import Foundation

/// Converts a recording's committed chunks to 16 kHz mono as they arrive and
/// cuts them into inference windows the way `prepareInferenceAudio` later
/// cuts the same chunks, so work started during recording sees exactly the
/// windows final processing will. A gap in the audio (where materialization
/// resets and starts a new window) ends it.
public actor CommittedInferenceAudio {
  private let converter: BoundedPCMConverter
  private let windowLimit: Int
  private var completed: [[Float]] = []
  /// The window still being filled.
  public private(set) var samples: [Float] = []
  public private(set) var committedThroughNanoseconds: UInt64 = 0
  public private(set) var ended = false

  /// `windowLimit` is the journal's inference window in 16 kHz samples.
  public init(windowLimit: Int) throws {
    converter = try BoundedPCMConverter()
    self.windowLimit = windowLimit
  }

  public func append(_ chunk: CapturedPCMChunk) async {
    guard !ended else { return }
    let rate = UInt64(max(1, chunk.sampleRateHertz))
    if committedThroughNanoseconds > 0,
      chunk.monotonicStartNanoseconds > committedThroughNanoseconds + 2_000_000_000 / rate
    {
      end()
      return
    }
    guard let converted = try? await converter.convert(chunk), !ended else {
      end()
      return
    }
    samples.append(
      contentsOf: converted.bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
    committedThroughNanoseconds =
      chunk.monotonicStartNanoseconds + chunk.frameCount * 1_000_000_000 / rate
    // Same rule and timing as materialization's flushAtPauses: a window is
    // cut as soon as the buffer exceeds the limit, decided by its first
    // `windowLimit` samples only.
    while let cut = samples.withUnsafeBufferPointer({
      PauseAlignedWindowing.cut($0, limit: windowLimit)
    }) {
      let length = max(1, cut)
      completed.append(Array(samples.prefix(length)))
      samples.removeFirst(length)
    }
  }

  /// Windows that are final now and have not been handed out yet.
  public func takeCompletedWindows() -> [[Float]] {
    defer { completed = [] }
    return completed
  }

  private func end() {
    ended = true
    samples = []
    completed = []
  }
}
