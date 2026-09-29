import Foundation

public struct DictationSilenceConfiguration: Codable, Equatable, Sendable {
  public let rmsThreshold: Double
  public let minimumSpeechNanoseconds: UInt64
  public let sentenceSilenceNanoseconds: UInt64

  public init(
    rmsThreshold: Double = 0.012,
    minimumSpeechNanoseconds: UInt64 = 250_000_000,
    sentenceSilenceNanoseconds: UInt64 = 650_000_000
  ) throws {
    guard
      rmsThreshold > 0,
      rmsThreshold < 1,
      minimumSpeechNanoseconds > 0,
      sentenceSilenceNanoseconds >= 250_000_000
    else {
      throw DictationSilenceDetectorError.invalidConfiguration
    }
    self.rmsThreshold = rmsThreshold
    self.minimumSpeechNanoseconds = minimumSpeechNanoseconds
    self.sentenceSilenceNanoseconds = sentenceSilenceNanoseconds
  }

  /// Stable, locale-independent input for transcript configuration hashes.
  public var provenanceIdentifier: String {
    "rms=\(rmsThreshold);minimumSpeechNs=\(minimumSpeechNanoseconds);sentenceSilenceNs=\(sentenceSilenceNanoseconds)"
  }
}

public enum DictationSilenceDetectorError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidPCM
}

public struct DictationSilenceDetector: Sendable {
  private let configuration: DictationSilenceConfiguration
  private var accumulatedSpeechNanoseconds: UInt64 = 0
  private var accumulatedSilenceNanoseconds: UInt64 = 0
  private var emittedForCurrentSilence = false

  public init(configuration: DictationSilenceConfiguration) {
    self.configuration = configuration
  }

  public mutating func consume(_ chunk: CapturedPCMChunk) throws -> Bool {
    let duration = UInt64(
      (Double(chunk.frameCount) * 1_000_000_000
        / Double(max(1, chunk.sampleRateHertz))).rounded()
    )
    let rms = try Self.rms(chunk)
    if rms >= configuration.rmsThreshold {
      accumulatedSpeechNanoseconds =
        min(
          UInt64.max - duration,
          accumulatedSpeechNanoseconds
        ) + duration
      accumulatedSilenceNanoseconds = 0
      emittedForCurrentSilence = false
      return false
    }
    accumulatedSilenceNanoseconds =
      min(
        UInt64.max - duration,
        accumulatedSilenceNanoseconds
      ) + duration
    guard
      accumulatedSpeechNanoseconds >= configuration.minimumSpeechNanoseconds,
      accumulatedSilenceNanoseconds >= configuration.sentenceSilenceNanoseconds,
      !emittedForCurrentSilence
    else { return false }
    emittedForCurrentSilence = true
    accumulatedSpeechNanoseconds = 0
    return true
  }

  public mutating func reset() {
    accumulatedSpeechNanoseconds = 0
    accumulatedSilenceNanoseconds = 0
    emittedForCurrentSilence = false
  }

  private static func rms(_ chunk: CapturedPCMChunk) throws -> Double {
    guard !chunk.bytes.isEmpty else {
      throw DictationSilenceDetectorError.invalidPCM
    }
    var sum = 0.0
    var count = 0
    switch chunk.encoding {
    case .float32LittleEndian:
      guard chunk.bytes.count.isMultiple(of: MemoryLayout<Float>.size) else {
        throw DictationSilenceDetectorError.invalidPCM
      }
      chunk.bytes.withUnsafeBytes { raw in
        for offset in stride(from: 0, to: raw.count, by: 4) {
          let bits =
            UInt32(raw[offset])
            | UInt32(raw[offset + 1]) << 8
            | UInt32(raw[offset + 2]) << 16
            | UInt32(raw[offset + 3]) << 24
          let value = Double(Float(bitPattern: bits))
          if value.isFinite {
            sum += value * value
            count += 1
          }
        }
      }
    case .int16LittleEndian:
      guard chunk.bytes.count.isMultiple(of: MemoryLayout<Int16>.size) else {
        throw DictationSilenceDetectorError.invalidPCM
      }
      chunk.bytes.withUnsafeBytes { raw in
        for offset in stride(from: 0, to: raw.count, by: 2) {
          let bits = UInt16(raw[offset]) | UInt16(raw[offset + 1]) << 8
          let value = Double(Int16(bitPattern: bits)) / Double(Int16.max)
          sum += value * value
          count += 1
        }
      }
    }
    guard count > 0 else { throw DictationSilenceDetectorError.invalidPCM }
    return sqrt(sum / Double(count))
  }
}
