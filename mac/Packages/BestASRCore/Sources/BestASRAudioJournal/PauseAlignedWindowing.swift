/// Chooses where to end a 16 kHz inference window so long speech splits at a
/// pause instead of mid-word.
///
/// Audio that still fits in one window is never cut: splitting early only
/// removes context from the recognizer. Once the limit is exceeded, the window
/// ends in the middle of the longest pause (at least 250 ms below about
/// -42 dBFS) in the last third of the limit, or else at the quietest 50 ms
/// there.
public enum PauseAlignedWindowing {
  static let frameSamples = 800
  static let pauseFrames = 5
  static let quietRMS: Float = 0.008

  /// Returns the sample count to emit as the next window, or nil to keep
  /// accumulating.
  public static func cut(_ samples: UnsafeBufferPointer<Float>, limit: Int) -> Int? {
    guard samples.count > limit, limit >= frameSamples * 3 else { return nil }
    let firstFrame = limit * 2 / 3 / frameSamples
    let endFrame = limit / frameSamples
    var run = 0
    var longest: (endFrame: Int, length: Int)?
    var quietest: (frame: Int, rms: Float)?
    for frame in firstFrame..<max(firstFrame, endFrame) {
      let level = rms(samples, frame: frame)
      if quietest.map({ level < $0.rms }) ?? true { quietest = (frame, level) }
      run = level < quietRMS ? run + 1 : 0
      if run >= pauseFrames, run >= (longest?.length ?? 0) {
        longest = (frame, run)
      }
    }
    if let longest {
      let middleFrame = longest.endFrame - longest.length / 2
      return middleFrame * frameSamples + frameSamples / 2
    }
    let frame = quietest?.frame ?? max(firstFrame, endFrame - 1)
    return min(limit, frame * frameSamples + frameSamples / 2)
  }

  /// Splits a whole recording the same way, for offline evaluation.
  public static func windows(_ samples: [Float], limit: Int) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    var start = 0
    samples.withUnsafeBufferPointer { all in
      while start < all.count {
        let remaining = UnsafeBufferPointer(rebasing: all[start...])
        guard let length = cut(remaining, limit: limit) else {
          if remaining.count <= limit {
            ranges.append(start..<all.count)
            start = all.count
          } else {
            ranges.append(start..<start + limit)
            start += limit
          }
          continue
        }
        ranges.append(start..<start + length)
        start += length
      }
    }
    return ranges
  }

  private static func rms(_ samples: UnsafeBufferPointer<Float>, frame: Int) -> Float {
    let start = frame * frameSamples
    var sum: Float = 0
    for index in start..<min(samples.count, start + frameSamples) {
      let value = samples[index]
      if value.isFinite { sum += value * value }
    }
    return (sum / Float(frameSamples)).squareRoot()
  }
}
