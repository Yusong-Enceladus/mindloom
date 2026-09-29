import BestASRCandidateAdapters
import BestASRInference
import CryptoKit
import Foundation

public protocol FluidASRSampleTranscribing: Sendable {
  func transcribe(samples: [Float]) async throws -> String
}

/// Shared local runtime for the language-specialized FluidAudio models. It
/// consumes only authenticated 16 kHz Float32 derivatives beneath the journal
/// root, suppresses silence before inference, and maps every result back to
/// the original monotonic audio range.
public struct FluidMonolingualASRRuntime: CandidateASRRuntime {
  private let candidateID: String
  private let audioLoader: any SenseVoiceAudioSampleLoading
  private let backend: any FluidASRSampleTranscribing
  private let activitySegmenter: SenseVoiceActivitySegmenter
  private let dictionaryNormalizer: SenseVoiceDictionaryNormalizer

  public init(
    candidateID: String,
    audioLoader: any SenseVoiceAudioSampleLoading,
    backend: any FluidASRSampleTranscribing,
    activitySegmenter: SenseVoiceActivitySegmenter = SenseVoiceActivitySegmenter(),
    dictionaryNormalizer: SenseVoiceDictionaryNormalizer = SenseVoiceDictionaryNormalizer()
  ) {
    self.candidateID = candidateID
    self.audioLoader = audioLoader
    self.backend = backend
    self.activitySegmenter = activitySegmenter
    self.dictionaryNormalizer = dictionaryNormalizer
  }

  public func networkPolicy() async -> CandidateRuntimeNetworkPolicy {
    .modelManagerVerifiedArtifactsOnly
  }

  public func transcribe(
    _ request: ASRRequest,
    candidateID requestedCandidateID: String
  ) async throws -> CandidateRuntimeOutput {
    try InferenceCancellation.check()
    guard requestedCandidateID == candidateID else {
      throw InferenceEngineError(
        category: .incompatibleArtifact,
        code: "fluid-monolingual-candidate-id-mismatch",
        retryable: false
      )
    }
    guard
      request.audio.sampleRateHertz == 16_000,
      request.audio.channelCount == 1
    else {
      throw InferenceEngineError(
        category: .invalidRequest,
        code: "fluid-monolingual-requires-16khz-mono",
        retryable: false
      )
    }

    let samples = try await audioLoader.loadSamples(for: request.audio)
    try InferenceCancellation.check()
    guard !samples.isEmpty else {
      throw InferenceEngineError(
        category: .corruptInput,
        code: "fluid-monolingual-empty-audio",
        retryable: false
      )
    }

    let speechRanges = activitySegmenter.speechRanges(in: samples)
    var recognized: [(range: Range<Int>, text: String)] = []
    recognized.reserveCapacity(speechRanges.count)
    for range in speechRanges {
      let rawText: String
      do {
        rawText = try await backend.transcribe(samples: Array(samples[range]))
      } catch is CancellationError {
        throw InferenceEngineError.cancelled
      } catch let error as InferenceEngineError {
        throw error
      } catch {
        throw InferenceEngineError(
          category: .transientRuntime,
          code: "fluid-monolingual-runtime-failed",
          retryable: true
        )
      }
      try InferenceCancellation.check()
      let normalized = dictionaryNormalizer.normalize(
        rawText.trimmingCharacters(in: .whitespacesAndNewlines),
        dictionaryTerms: request.recognitionContext.dictionaryTerms,
        dictionaryHints: request.recognitionContext.dictionaryHints
      )
      if !normalized.isEmpty {
        recognized.append((range, normalized))
      }
    }

    let text = SenseVoiceDictionaryNormalizer.join(recognized.map(\.text))
    let revisionID = deterministicUUID(
      namespace: "revision",
      request: request,
      text: text
    )
    let inputDuration =
      request.audio.monotonicEndNanoseconds
      - request.audio.monotonicStartNanoseconds
    let segments = recognized.enumerated().map { index, item in
      let startOffset = UInt64(
        (Double(inputDuration) * Double(item.range.lowerBound)
          / Double(samples.count)).rounded(.down)
      )
      let endOffset = UInt64(
        (Double(inputDuration) * Double(item.range.upperBound)
          / Double(samples.count)).rounded(.up)
      )
      return CandidateRuntimeSegment(
        segmentID: deterministicUUID(
          namespace: "segment-\(index)-\(item.range.lowerBound)-\(item.range.upperBound)",
          request: request,
          text: item.text
        ),
        monotonicStartNanoseconds:
          request.audio.monotonicStartNanoseconds + startOffset,
        monotonicEndNanoseconds: min(
          request.audio.monotonicEndNanoseconds,
          request.audio.monotonicStartNanoseconds + max(startOffset + 1, endOffset)
        ),
        text: item.text,
        confidence: nil
      )
    }
    return CandidateRuntimeOutput(
      revisionID: revisionID,
      segments: segments,
      detectedLanguage: detectedLanguage
    )
  }

  private var detectedLanguage: String? {
    switch candidateID {
    case FluidParaformerPinnedArtifact.candidateID:
      return "zh-CN"
    case FluidParakeetUnifiedPinnedArtifact.candidateID:
      return "en-US"
    default:
      return nil
    }
  }

  private func deterministicUUID(
    namespace: String,
    request: ASRRequest,
    text: String
  ) -> UUID {
    let seed = [
      namespace,
      candidateID,
      request.metadata.jobID.uuidString.lowercased(),
      String(request.metadata.inputRevision),
      request.metadata.modelArtifactID,
      request.metadata.configHash,
      request.audio.contentDigest,
      String(request.audio.monotonicStartNanoseconds),
      String(request.audio.monotonicEndNanoseconds),
      request.mode.rawValue,
      request.supersedesRevisionID?.uuidString.lowercased() ?? "none",
      text,
    ].joined(separator: "\u{1f}")
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      )
    )
  }
}
