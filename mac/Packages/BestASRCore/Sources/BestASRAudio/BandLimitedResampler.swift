import Accelerate
import Foundation

/// Converts mono samples at the capture rate to 16 kHz through a low-pass
/// filter, so nothing above 8 kHz folds back into the band that is kept.
///
/// The retained copy of a recording is rewritten at 16 kHz once its jobs are
/// done (PRD STORE-001) and the capture-rate original is removed, so this
/// conversion decides what the recording is from then on. Plain linear
/// interpolation (what `BoundedPCMConverter` feeds the recognizer) keeps
/// every tone above 8 kHz at full strength as a lower one: a 12 kHz tone at
/// 48 kHz comes out as a 4 kHz tone (review 10-6 S4). This is a
/// windowed-sinc filter (Kaiser window): the band up to 7 kHz passes
/// unchanged, and from 8 kHz up the signal is attenuated by at least
/// `stopbandAttenuationDecibels`.
///
/// Output sample `n` lies exactly at source time `n / 16 000 s` (the filter
/// is centred, not delayed), so the recorded timeline does not move. Nothing
/// before the first sample or after the last one is invented: the filter
/// sees silence there. Deterministic: the same input gives the same output
/// bit for bit, on any Mac.
public struct BandLimitedResampler: Sendable {
  public static let targetSampleRateHertz = 16_000
  /// Up to here the gain is 1 (within 0.01 dB).
  public static let passbandEdgeHertz = 7_000.0
  /// From here up the signal is attenuated by at least
  /// `stopbandAttenuationDecibels`.
  public static let stopbandEdgeHertz = 8_000.0
  public static let stopbandAttenuationDecibels = 80.0
  /// More distinct fractional positions than this are rounded to the nearest
  /// of this many (only for capture rates that share no large factor with
  /// 16 kHz; 44.1, 48 and 96 kHz need 160, 1 and 1).
  static let maximumPhases = 4_096

  public let sourceRateHertz: Int
  /// Source samples per output sample, as a fraction: `step / outputsPerStep`.
  private let step: Int
  private let outputsPerStep: Int
  private let halfWidth: Int
  private let phases: Int
  /// `phases` kernels of `2 * halfWidth` taps each, one after another.
  private let kernels: [Float]
  private var buffer: [Float] = []
  /// Source index of `buffer[0]`.
  private var bufferStart = 0
  private var received = 0
  private var produced = 0

  public init(sourceRateHertz: Int) throws {
    guard sourceRateHertz > 0, sourceRateHertz <= 1_536_000 else {
      throw PCMConversionError.invalidFormat
    }
    self.sourceRateHertz = sourceRateHertz
    let divisor = Self.greatestCommonDivisor(sourceRateHertz, Self.targetSampleRateHertz)
    step = sourceRateHertz / divisor
    outputsPerStep = Self.targetSampleRateHertz / divisor
    guard sourceRateHertz != Self.targetSampleRateHertz else {
      halfWidth = 0
      phases = 1
      kernels = []
      return
    }
    // Downsampling keeps 0–7 kHz and removes 8 kHz up; a source slower than
    // 16 kHz has nothing above its own half rate, which is where the band
    // then ends.
    let rate = Double(sourceRateHertz)
    let downsampling = sourceRateHertz > Self.targetSampleRateHertz
    let stop = downsampling ? Self.stopbandEdgeHertz : rate / 2
    let pass = downsampling ? Self.passbandEdgeHertz : rate * 0.45
    let cutoff = (pass + stop) / 2 / rate
    let transition = (stop - pass) / rate
    let attenuation = Self.stopbandAttenuationDecibels
    let beta = 0.1102 * (attenuation - 8.7)
    let taps = (attenuation - 7.95) / (2.285 * 2 * Double.pi * transition) + 1
    halfWidth = max(2, Int((taps / 2).rounded(.up)))
    phases = min(outputsPerStep, Self.maximumPhases)
    var kernels = [Float](repeating: 0, count: phases * 2 * halfWidth)
    let window = Double(halfWidth)
    let normalizer = Self.besselI0(beta)
    for phase in 0..<phases {
      let fraction = Double(phase) / Double(phases)
      var values = [Double](repeating: 0, count: 2 * halfWidth)
      var sum = 0.0
      for tap in 0..<(2 * halfWidth) {
        // Tap `tap` multiplies the source sample `base + tap - halfWidth + 1`.
        let offset = Double(tap - halfWidth + 1) - fraction
        let ratio = offset / window
        guard abs(ratio) < 1 else { continue }
        let x = 2 * cutoff * offset
        let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
        let value =
          2 * cutoff * sinc * Self.besselI0(beta * (1 - ratio * ratio).squareRoot()) / normalizer
        values[tap] = value
        sum += value
      }
      // Unity gain at 0 Hz for every position, so a constant stays constant.
      for tap in 0..<(2 * halfWidth) {
        kernels[phase * 2 * halfWidth + tap] = Float(values[tap] / sum)
      }
    }
    self.kernels = kernels
  }

  /// Takes the next source samples and returns every 16 kHz sample they
  /// complete.
  public mutating func append(_ samples: [Float]) -> [Float] {
    guard !samples.isEmpty else { return [] }
    received += samples.count
    guard halfWidth > 0 else {
      produced += samples.count
      return samples
    }
    buffer.append(contentsOf: samples)
    return drain(final: false)
  }

  /// The samples still owed at the end of the run: the last ones, whose
  /// filter reaches past the final source sample, see silence there.
  public mutating func finish() -> [Float] {
    guard halfWidth > 0 else { return [] }
    let output = drain(final: true)
    buffer.removeAll(keepingCapacity: false)
    return output
  }

  /// How many 16 kHz samples `sourceFrames` source samples make: every
  /// output position from the first sample to the last.
  public static func outputCount(sourceFrames: Int, sourceRateHertz: Int) -> Int {
    guard sourceFrames > 0, sourceRateHertz > 0 else { return 0 }
    return (sourceFrames - 1) * targetSampleRateHertz / sourceRateHertz + 1
  }

  private mutating func drain(final: Bool) -> [Float] {
    var output: [Float] = []
    let total = Self.outputCount(sourceFrames: received, sourceRateHertz: sourceRateHertz)
    while produced < total {
      let position = produced * step
      var base = position / outputsPerStep
      var phase = position % outputsPerStep
      if phases != outputsPerStep {
        phase = Int((Double(phase) * Double(phases) / Double(outputsPerStep)).rounded())
        if phase == phases {
          phase = 0
          base += 1
        }
      }
      // Every tap to the right must have arrived unless the run has ended.
      guard final || base + halfWidth < received else { break }
      output.append(value(at: base, phase: phase))
      produced += 1
    }
    // Keep what the next output's leftmost tap still needs.
    let nextBase = produced * step / outputsPerStep
    let keepFrom = max(bufferStart, nextBase - halfWidth)
    let removable = min(buffer.count, keepFrom - bufferStart)
    if removable > 0 {
      buffer.removeFirst(removable)
      bufferStart += removable
    }
    return output
  }

  /// One output sample: the kernel for `phase` over the source samples
  /// around `base`, silence beyond what was recorded.
  private func value(at base: Int, phase: Int) -> Float {
    let first = base - halfWidth + 1
    let lower = max(first, bufferStart)
    let upper = min(base + halfWidth + 1, bufferStart + buffer.count)
    guard lower < upper else { return 0 }
    var result: Float = 0
    buffer.withUnsafeBufferPointer { samples in
      kernels.withUnsafeBufferPointer { taps in
        vDSP_dotpr(
          samples.baseAddress! + (lower - bufferStart), 1,
          taps.baseAddress! + phase * 2 * halfWidth + (lower - first), 1,
          &result, vDSP_Length(upper - lower))
      }
    }
    return result
  }

  static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
    var (x, y) = (a, b)
    while y != 0 { (x, y) = (y, x % y) }
    return x
  }

  /// The modified Bessel function of the first kind, order zero (series).
  static func besselI0(_ x: Double) -> Double {
    var sum = 1.0
    var term = 1.0
    let half = x / 2
    for k in 1..<64 {
      term *= (half / Double(k)) * (half / Double(k))
      sum += term
      if term < sum * 1e-17 { break }
    }
    return sum
  }
}
