import BestASRRecognition
import Foundation

/// Final decodes started while the user is still holding the dictation key.
///
/// Two kinds are kept:
/// - Completed windows. A long dictation is cut into inference windows exactly
///   as final processing will cut it; each finished window is decoded at once
///   and reused only for a final request carrying the identical samples.
/// - A pause decode of the window still being filled. When the speaker
///   pauses, the audio so far is decoded; if the key is released without more
///   speech, the final window is that audio followed only by quiet samples.
///
/// Any other request — more speech, other dictionary terms, a different
/// recording — misses and decodes normally, so a reused result always
/// describes the same speech the final request carries.
public actor QwenSpeculativeDecodeCache {
  struct Decoded: Sendable {
    let samples: [Float]
    let dictionaryTerms: [String]
    let recognized: QwenRecognizedText
    let words: [TranscriptAlignmentWord]
  }

  private struct Pending {
    let samples: [Float]
    let task: Task<Decoded?, Never>
  }

  static let minimumSamples = 4_800

  private var windows: [Pending] = []
  private var pause: Pending?
  private var generation = 0
  /// Whether the last `take` found a finished pause decode it could not use.
  public private(set) var hadCandidate = false

  public init() {}

  /// Drops everything, e.g. when a new dictation starts.
  public func clear() {
    generation += 1
    windows.forEach { $0.task.cancel() }
    windows = []
    clearPause()
  }

  /// Drops only the pause decode, e.g. when speech resumes.
  public func clearPause() {
    pause?.task.cancel()
    pause = nil
  }

  /// Replaces any earlier pause decode with `work` on `samples`.
  func startPause(samples: [Float], _ work: @escaping @Sendable () async -> Decoded?) {
    clearPause()
    pause = Pending(samples: samples, task: Task { await work() })
  }

  /// Adds the decode of a completed window.
  func startWindow(samples: [Float], _ work: @escaping @Sendable () async -> Decoded?) {
    windows.append(Pending(samples: samples, task: Task { await work() }))
  }

  /// Hands out, once, a decode whose audio is exactly `samples` (a completed
  /// window) or `samples` minus a quiet ending (a pause decode). Waits for a
  /// matching decode that is still running.
  func take(matching samples: [Float], dictionaryTerms: [String]) async -> Decoded? {
    hadCandidate = false
    let token = generation
    if let index = windows.firstIndex(where: { $0.samples == samples }) {
      let pending = windows.remove(at: index)
      if let decoded = await pending.task.value, token == generation,
        decoded.dictionaryTerms == dictionaryTerms
      {
        return decoded
      }
    }
    guard let pending = pause,
      pending.samples.count <= samples.count,
      pending.samples.first == samples.first
    else { return nil }
    guard let decoded = await pending.task.value, token == generation else { return nil }
    guard decoded.dictionaryTerms == dictionaryTerms,
      Self.extendsOnlyWithQuiet(prefix: decoded.samples, full: samples)
    else {
      hadCandidate = true
      return nil
    }
    pause = nil
    return decoded
  }

  /// A pause decode starts after at least 350 ms of quiet, so the quietest
  /// 50 ms of the prefix's last 500 ms measures the room at rest. Everything
  /// appended must stay below 3× that level (at least RMS 0.002) in every
  /// 50 ms frame; a word said softly after the pause is louder than that and
  /// forces a new decode. (Resumed speech also cancels the pause decode.)
  static func extendsOnlyWithQuiet(prefix: [Float], full: [Float]) -> Bool {
    guard prefix.count >= minimumSamples, prefix.count <= full.count else { return false }
    // Both sides come from the same journal chunks through the same
    // deterministic resampler, so the shared part is bit-identical.
    for index in prefix.indices where prefix[index] != full[index] { return false }
    let frame = 800
    var roomLevel = Float.greatestFiniteMagnitude
    var frameStart = max(0, prefix.count - 8_000)
    while frameStart + frame <= prefix.count {
      roomLevel = min(roomLevel, rms(prefix, frameStart..<frameStart + frame))
      frameStart += frame
    }
    let limit = max(3 * roomLevel, 0.002)
    var start = prefix.count
    while start < full.count {
      let end = min(full.count, start + frame)
      guard rms(full, start..<end) < limit else { return false }
      start = end
    }
    return true
  }

  private static func rms(_ samples: [Float], _ range: Range<Int>) -> Float {
    var sum: Float = 0
    for index in range { sum += samples[index] * samples[index] }
    return (sum / Float(max(1, range.count))).squareRoot()
  }
}
