import CryptoKit
import Foundation

public struct HostTimeConverter: Equatable, Sendable {
  public let numerator: UInt64
  public let denominator: UInt64

  public init(numerator: UInt64, denominator: UInt64) throws {
    guard numerator > 0, denominator > 0 else {
      throw AudioTimelineProbeError.invalidTimebase
    }
    self.numerator = numerator
    self.denominator = denominator
  }

  public func monotonicNanoseconds(for hostTime: UInt64) throws -> UInt64 {
    let quotient = hostTime / denominator
    let remainder = hostTime % denominator
    let (whole, wholeOverflow) = quotient.multipliedReportingOverflow(
      by: numerator
    )
    let (fractionProduct, fractionOverflow) =
      remainder
      .multipliedReportingOverflow(by: numerator)
    guard !wholeOverflow, !fractionOverflow else {
      throw AudioTimelineProbeError.timebaseOverflow
    }
    let fraction = fractionProduct / denominator
    let (result, additionOverflow) = whole.addingReportingOverflow(fraction)
    guard !additionOverflow else {
      throw AudioTimelineProbeError.timebaseOverflow
    }
    return result
  }
}

public enum AudioTimelineProbeError: Error, Equatable {
  case duplicateOrMissingSequence(trackID: String, expected: UInt64, actual: UInt64)
  case invalidDigest(trackID: String, sequence: UInt64)
  case invalidTimebase
  case missingBoundary(trackID: String, segment: UInt32)
  case nonMonotonicHostTime(trackID: String, sequence: UInt64)
  case sampleRateChangedWithoutBoundary(trackID: String, sequence: UInt64)
  case timebaseOverflow
}

public enum AudioTimelineValidator {
  public static func validate(
    tracks: [ProbeTrack],
    chunks: [ProbeAudioChunk],
    boundaries: [ProbeTimelineBoundary]
  ) throws {
    let trackIDs = Set(tracks.map(\.trackID))
    guard trackIDs.count == tracks.count else {
      throw AudioTimelineProbeError.duplicateOrMissingSequence(
        trackID: "duplicate-track",
        expected: 0,
        actual: 0
      )
    }

    for trackID in trackIDs {
      let ordered = chunks.filter { $0.trackID == trackID }
        .sorted { $0.sequence < $1.sequence }
      var expectedSequence: UInt64 = 0
      var prior: ProbeAudioChunk?
      for chunk in ordered {
        guard chunk.sequence == expectedSequence else {
          throw AudioTimelineProbeError.duplicateOrMissingSequence(
            trackID: trackID,
            expected: expectedSequence,
            actual: chunk.sequence
          )
        }
        guard Self.isSHA256(chunk.contentDigest) else {
          throw AudioTimelineProbeError.invalidDigest(
            trackID: trackID,
            sequence: chunk.sequence
          )
        }
        if let prior {
          guard chunk.hostTime > prior.hostTime,
            chunk.monotonicStartNanoseconds > prior.monotonicStartNanoseconds
          else {
            throw AudioTimelineProbeError.nonMonotonicHostTime(
              trackID: trackID,
              sequence: chunk.sequence
            )
          }
          if chunk.segment == prior.segment {
            guard chunk.sampleRateHertz == prior.sampleRateHertz else {
              throw AudioTimelineProbeError.sampleRateChangedWithoutBoundary(
                trackID: trackID,
                sequence: chunk.sequence
              )
            }
          } else {
            let matchingBoundary = boundaries.contains {
              $0.trackID == trackID
                && $0.fromSegment == prior.segment
                && $0.toSegment == chunk.segment
                && $0.monotonicNanoseconds <= chunk.monotonicStartNanoseconds
            }
            guard matchingBoundary, chunk.discontinuity != nil else {
              throw AudioTimelineProbeError.missingBoundary(
                trackID: trackID,
                segment: chunk.segment
              )
            }
          }
        }
        prior = chunk
        expectedSequence += 1
      }
    }
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.unicodeScalars.allSatisfy {
        (48...57).contains($0.value) || (97...102).contains($0.value)
      }
  }
}

public enum AudioProbeSignal {
  public static func pulseChunk(
    frameCount: UInt32,
    sampleRateHertz: UInt32,
    chunkStartNanoseconds: UInt64,
    pulseNanoseconds: UInt64?
  ) -> (samples: [Float], observedPulseNanoseconds: UInt64?) {
    var samples = [Float](repeating: 0, count: Int(frameCount))
    guard let pulseNanoseconds,
      pulseNanoseconds >= chunkStartNanoseconds
    else {
      return (samples, nil)
    }
    let offset = pulseNanoseconds - chunkStartNanoseconds
    let frame = Int(
      (Double(offset) * Double(sampleRateHertz) / 1_000_000_000).rounded()
    )
    guard samples.indices.contains(frame) else {
      return (samples, nil)
    }
    samples[frame] = 1
    let observedOffset = UInt64(
      (Double(frame) * 1_000_000_000 / Double(sampleRateHertz)).rounded()
    )
    return (samples, chunkStartNanoseconds + observedOffset)
  }

  public static func digest(samples: [Float]) -> String {
    var data = Data(capacity: samples.count * MemoryLayout<UInt32>.size)
    for sample in samples {
      var bits = sample.bitPattern.littleEndian
      withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }
      .joined()
  }
}

public enum ClockDriftEstimator {
  public static func observation(
    nominalSampleRateHertz: Double,
    startFrame: UInt64,
    endFrame: UInt64,
    startMonotonicNanoseconds: UInt64,
    endMonotonicNanoseconds: UInt64,
    expectedPartsPerMillion: Double
  ) throws -> ProbeDriftObservation {
    guard endFrame > startFrame,
      endMonotonicNanoseconds > startMonotonicNanoseconds
    else {
      throw AudioTimelineProbeError.nonMonotonicHostTime(
        trackID: "drift-anchor",
        sequence: 1
      )
    }
    let frames = Double(endFrame - startFrame)
    let seconds =
      Double(
        endMonotonicNanoseconds - startMonotonicNanoseconds
      ) / 1_000_000_000
    let observed = frames / seconds
    let measured = (observed / nominalSampleRateHertz - 1) * 1_000_000
    return ProbeDriftObservation(
      nominalSampleRateHertz: nominalSampleRateHertz,
      observedSampleRateHertz: observed,
      expectedPartsPerMillion: expectedPartsPerMillion,
      measuredPartsPerMillion: measured
    )
  }
}
