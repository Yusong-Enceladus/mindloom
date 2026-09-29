import BestASRDictation
import Foundation

public enum PCMConversionError: Error, Equatable, Sendable {
  case bufferCapacityExceeded(limit: Int, proposed: Int)
  case formatChanged
  case frameCountMismatch(expectedSamples: UInt64, actualSamples: UInt64)
  case invalidBytes
  case invalidFormat
  case nonFiniteSample
  case unsupportedNonInterleaved
}

public struct InferencePCMChunk: Codable, Equatable, Sendable {
  public let sequence: UInt64
  public let monotonicStartNanoseconds: UInt64
  public let frameCount: UInt64
  public let sampleRateHertz: UInt32
  public let channelCount: UInt16
  public let encoding: PCMEncoding
  public let interleaved: Bool
  public let bytes: Data

  public init(
    sequence: UInt64,
    monotonicStartNanoseconds: UInt64,
    frameCount: UInt64,
    sampleRateHertz: UInt32 = 16_000,
    channelCount: UInt16 = 1,
    encoding: PCMEncoding = .float32LittleEndian,
    interleaved: Bool = true,
    bytes: Data
  ) {
    self.sequence = sequence
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.frameCount = frameCount
    self.sampleRateHertz = sampleRateHertz
    self.channelCount = channelCount
    self.encoding = encoding
    self.interleaved = interleaved
    self.bytes = bytes
  }
}

public actor BoundedPCMConverter {
  public static let targetSampleRateHertz: UInt32 = 16_000

  private struct SourceFormat: Equatable {
    let sampleRateHertz: UInt32
    let channelCount: UInt16
    let encoding: PCMEncoding
    let interleaved: Bool
  }

  private let maximumBufferedSourceFrames: Int
  private var sourceFormat: SourceFormat?
  private var pendingMonoSamples: [Float] = []
  private var sourcePhase: Double = 0
  private var outputSequence: UInt64 = 0

  public init(maximumBufferedSourceFrames: Int = 192_000) throws {
    guard maximumBufferedSourceFrames >= 2 else {
      throw PCMConversionError.invalidFormat
    }
    self.maximumBufferedSourceFrames = maximumBufferedSourceFrames
  }

  public func convert(_ chunk: CapturedPCMChunk) throws -> InferencePCMChunk {
    guard chunk.sampleRateHertz > 0, chunk.channelCount > 0, chunk.frameCount > 0
    else {
      throw PCMConversionError.invalidFormat
    }
    guard chunk.interleaved else {
      throw PCMConversionError.unsupportedNonInterleaved
    }
    let format = SourceFormat(
      sampleRateHertz: chunk.sampleRateHertz,
      channelCount: chunk.channelCount,
      encoding: chunk.encoding,
      interleaved: chunk.interleaved
    )
    if let sourceFormat, sourceFormat != format {
      throw PCMConversionError.formatChanged
    }
    sourceFormat = format

    let decoded = try Self.decode(chunk.bytes, encoding: chunk.encoding)
    let expectedSamples = chunk.frameCount.multipliedReportingOverflow(
      by: UInt64(chunk.channelCount)
    )
    guard !expectedSamples.overflow else {
      throw PCMConversionError.invalidFormat
    }
    guard UInt64(decoded.count) == expectedSamples.partialValue else {
      throw PCMConversionError.frameCountMismatch(
        expectedSamples: expectedSamples.partialValue,
        actualSamples: UInt64(decoded.count)
      )
    }
    guard decoded.allSatisfy(\.isFinite) else {
      throw PCMConversionError.nonFiniteSample
    }
    let proposed = pendingMonoSamples.count + Int(chunk.frameCount)
    guard proposed <= maximumBufferedSourceFrames else {
      throw PCMConversionError.bufferCapacityExceeded(
        limit: maximumBufferedSourceFrames,
        proposed: proposed
      )
    }

    let channels = Int(chunk.channelCount)
    pendingMonoSamples.reserveCapacity(proposed)
    for frame in 0..<Int(chunk.frameCount) {
      let base = frame * channels
      var sum: Float = 0
      for channel in 0..<channels {
        sum += decoded[base + channel]
      }
      // CoreAudio Float32 capture is not guaranteed to remain inside the
      // nominal PCM full-scale range. Preserve the original journal bytes,
      // but bound the inference copy so an otherwise valid clipped peak does
      // not make the complete recording unrecoverable.
      pendingMonoSamples.append(min(1, max(-1, sum / Float(channels))))
    }

    let ratio =
      Double(chunk.sampleRateHertz)
      / Double(Self.targetSampleRateHertz)
    var output: [Float] = []
    output.reserveCapacity(
      Int((Double(chunk.frameCount) / ratio).rounded(.up)) + 1
    )
    while sourcePhase + 1 < Double(pendingMonoSamples.count) {
      let leftIndex = Int(sourcePhase)
      let fraction = Float(sourcePhase - Double(leftIndex))
      let left = pendingMonoSamples[leftIndex]
      let right = pendingMonoSamples[leftIndex + 1]
      output.append(left + ((right - left) * fraction))
      sourcePhase += ratio
    }
    let removable = min(
      Int(sourcePhase),
      max(0, pendingMonoSamples.count - 1)
    )
    if removable > 0 {
      pendingMonoSamples.removeFirst(removable)
      sourcePhase -= Double(removable)
    }

    let result = InferencePCMChunk(
      sequence: outputSequence,
      monotonicStartNanoseconds: chunk.monotonicStartNanoseconds,
      frameCount: UInt64(output.count),
      bytes: Self.encodeFloat32LittleEndian(output)
    )
    outputSequence += 1
    return result
  }

  public func resetForFormatChange() {
    sourceFormat = nil
    pendingMonoSamples.removeAll(keepingCapacity: false)
    sourcePhase = 0
  }

  public func bufferedSourceFrameCount() -> Int {
    pendingMonoSamples.count
  }

  private static func decode(
    _ data: Data,
    encoding: PCMEncoding
  ) throws -> [Float] {
    switch encoding {
    case .float32LittleEndian:
      guard data.count.isMultiple(of: 4) else {
        throw PCMConversionError.invalidBytes
      }
      return data.withUnsafeBytes { rawBuffer in
        stride(from: 0, to: rawBuffer.count, by: 4).map { offset in
          let bits =
            UInt32(rawBuffer[offset])
            | (UInt32(rawBuffer[offset + 1]) << 8)
            | (UInt32(rawBuffer[offset + 2]) << 16)
            | (UInt32(rawBuffer[offset + 3]) << 24)
          return Float(bitPattern: bits)
        }
      }

    case .int16LittleEndian:
      guard data.count.isMultiple(of: 2) else {
        throw PCMConversionError.invalidBytes
      }
      return data.withUnsafeBytes { rawBuffer in
        stride(from: 0, to: rawBuffer.count, by: 2).map { offset in
          let bits =
            UInt16(rawBuffer[offset])
            | (UInt16(rawBuffer[offset + 1]) << 8)
          return Float(Int16(bitPattern: bits)) / Float(Int16.max)
        }
      }
    }
  }

  private static func encodeFloat32LittleEndian(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 4)
    for sample in samples {
      let bits = sample.bitPattern.littleEndian
      withUnsafeBytes(of: bits) { data.append(contentsOf: $0) }
    }
    return data
  }
}
