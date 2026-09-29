import BestASRDictation
import BestASRDomain
import BestASRInference
import CryptoKit
import Foundation

public struct BoundedDictationASRPolicy: Codable, Equatable, Sendable {
  public let maximumPreparedRanges: Int
  public let maximumRangeNanoseconds: UInt64
  public let maximumDictionaryTerms: Int
  public let maximumPriorSegments: Int
  public let maximumLanguageHints: Int
  public let maximumTranscriptCharacters: Int
  public let timeoutNanoseconds: UInt64
  public let permitsEmptyFinalResultForReconciliation: Bool

  public init(
    maximumPreparedRanges: Int = 512,
    maximumRangeNanoseconds: UInt64 = 60_000_000_000,
    maximumDictionaryTerms: Int = 64,
    maximumPriorSegments: Int = 8,
    maximumLanguageHints: Int = 8,
    maximumTranscriptCharacters: Int = 1_000_000,
    timeoutNanoseconds: UInt64 = 30_000_000_000,
    permitsEmptyFinalResultForReconciliation: Bool = false
  ) throws {
    guard
      maximumPreparedRanges > 0,
      maximumRangeNanoseconds > 0,
      maximumDictionaryTerms >= 0,
      maximumPriorSegments >= 0,
      maximumLanguageHints > 0,
      maximumTranscriptCharacters > 0,
      timeoutNanoseconds > 0
    else {
      throw InferenceEngineError(
        category: .invalidRequest,
        code: "dictation-asr-policy-invalid",
        retryable: false
      )
    }
    self.maximumPreparedRanges = maximumPreparedRanges
    self.maximumRangeNanoseconds = maximumRangeNanoseconds
    self.maximumDictionaryTerms = maximumDictionaryTerms
    self.maximumPriorSegments = maximumPriorSegments
    self.maximumLanguageHints = maximumLanguageHints
    self.maximumTranscriptCharacters = maximumTranscriptCharacters
    self.timeoutNanoseconds = timeoutNanoseconds
    self.permitsEmptyFinalResultForReconciliation =
      permitsEmptyFinalResultForReconciliation
  }
}

public actor BoundedDictationASRAdapter: VersionedDictationASRPort {
  private let engine: any ASREngine
  private let audio: any DictationInferenceAudioPort
  private let configHash: BestASRDomain.SHA256Digest
  private let defaultLanguageHints: [String]
  private let policy: BoundedDictationASRPolicy

  public init(
    engine: any ASREngine,
    audio: any DictationInferenceAudioPort,
    configHash: BestASRDomain.SHA256Digest,
    defaultLanguageHints: [String] = ["zh-CN", "en-US"],
    policy: BoundedDictationASRPolicy
  ) {
    self.engine = engine
    self.audio = audio
    self.configHash = configHash
    self.defaultLanguageHints = defaultLanguageHints
    self.policy = policy
  }

  public func recognize(
    _ request: DictationASRRequest
  ) async throws -> DictationTranscriptResult {
    try await recognize(
      VersionedDictationASRRequest(
        request: request,
        mode: .final,
        languageHints: defaultLanguageHints,
        supersedesRevisionID: nil
      )
    )
  }

  public func recognize(
    _ versioned: VersionedDictationASRRequest
  ) async throws -> DictationTranscriptResult {
    let request = versioned.request
    try InferenceCancellation.check()
    guard request.inputRevision > 0, !request.audio.isEmpty else {
      throw failure(.invalidRequest, "dictation-asr-request-invalid", false)
    }
    let languageHints = Array(
      versioned.languageHints
        .filter { !$0.isEmpty && $0.count <= 32 }
        .prefix(policy.maximumLanguageHints)
    )
    guard !languageHints.isEmpty else {
      throw failure(.invalidRequest, "dictation-asr-language-hints-invalid", false)
    }

    let descriptor = await engine.descriptor().artifact
    guard !descriptor.networkRequired else {
      throw failure(.modelUnavailable, "dictation-asr-offline-artifact-required", false)
    }
    let requiredCapability: InferenceCapability =
      versioned.mode == .streaming
      ? .asrStreaming
      : .asrBatch
    guard descriptor.capabilities.contains(requiredCapability) else {
      throw failure(.incompatibleArtifact, "dictation-asr-mode-unsupported", false)
    }

    let prepared = try await audio.prepareInferenceAudio(
      sessionID: request.sessionID,
      sourceAudio: request.audio
    )
    do {
      let result = try await recognizePrepared(
        versioned,
        request: request,
        prepared: prepared,
        descriptor: descriptor,
        languageHints: languageHints
      )
      await audio.discardInferenceAudio(
        sessionID: request.sessionID,
        preparedAudio: prepared
      )
      return result
    } catch {
      await audio.discardInferenceAudio(
        sessionID: request.sessionID,
        preparedAudio: prepared
      )
      throw error
    }
  }

  private func recognizePrepared(
    _ versioned: VersionedDictationASRRequest,
    request: DictationASRRequest,
    prepared: [AudioRangeInput],
    descriptor: ModelArtifactDescriptor,
    languageHints: [String]
  ) async throws -> DictationTranscriptResult {
    try validatePreparedRanges(prepared)

    let dictionaryTerms = Array(
      request.dictionaryTerms
        .filter { !$0.isEmpty && $0.count <= 128 }
        .prefix(policy.maximumDictionaryTerms)
    )
    let dictionaryHints = Array(
      request.dictionaryHints.compactMap { hint -> ASRDictionaryHint? in
        let canonical = hint.canonicalForm.trimmingCharacters(
          in: .whitespacesAndNewlines
        )
        guard
          !canonical.isEmpty,
          canonical.count <= 128,
          canonical == hint.canonicalForm
        else { return nil }
        let spoken = Array(
          hint.spokenForms.lazy
            .filter {
              !$0.isEmpty
                && $0.count <= 128
                && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .prefix(32)
        )
        return ASRDictionaryHint(
          canonicalForm: canonical,
          spokenForms: spoken
        )
      }.prefix(policy.maximumDictionaryTerms)
    )
    var allSegments: [ASRSegment] = []
    var runtimeRevisionIDs: [UUID] = []
    var segmentIDs = Set<UUID>()
    var transcriptCharacterCount = 0
    var contextSegmentsByTrack: [UUID: [ASRSegment]] = [:]
    var detectedLanguages = Set<String>()

    for (index, range) in prepared.enumerated() {
      try InferenceCancellation.check()
      guard
        let sourceBounds = sourceBounds(
          for: range,
          sourceAudio: request.audio
        )
      else {
        throw failure(
          .invalidRequest,
          "dictation-asr-source-range-mapping-invalid",
          false
        )
      }
      let priorSegments = Array(
        contextSegmentsByTrack[range.trackID, default: []]
          .suffix(policy.maximumPriorSegments)
      ).map {
        ASRContextSegment(
          text: $0.text,
          monotonicEndNanoseconds: $0.monotonicEndNanoseconds
        )
      }
      let engineRequest = ASRRequest(
        metadata: InferenceRequestMetadata(
          jobID: deterministicUUID(
            [
              "job",
              request.sessionID.rawValue.uuidString,
              String(request.inputRevision),
              String(index),
              versioned.mode.rawValue,
              descriptor.artifactID,
              configHash.value,
            ]
          ),
          inputRevision: request.inputRevision,
          modelArtifactID: descriptor.artifactID,
          configHash: configHash.value
        ),
        audio: range,
        mode: versioned.mode,
        languageHints: languageHints,
        recognitionContext: ASRRecognitionContext(
          dictionaryTerms: dictionaryTerms,
          dictionaryHints: dictionaryHints,
          priorStableSegments: priorSegments
        ),
        supersedesRevisionID: versioned.supersedesRevisionID?.rawValue
      )
      let result = try await transcribeWithTimeout(engineRequest)
      guard
        result.contractVersion == InferenceContract.currentVersion,
        result.modelArtifactID == descriptor.artifactID,
        let revision = result.revision,
        revision.mode == versioned.mode,
        revision.operation == ASRRevisionOperation.replaceAudioRange,
        revision.monotonicStartNanoseconds == range.monotonicStartNanoseconds,
        revision.monotonicEndNanoseconds == range.monotonicEndNanoseconds,
        revision.supersedesRevisionID
          == versioned.supersedesRevisionID?.rawValue
      else {
        throw failure(.corruptInput, "dictation-asr-revision-malformed", true)
      }
      if let detectedLanguage = normalizedDetectedLanguage(
        result.detectedLanguage
      ) {
        detectedLanguages.insert(detectedLanguage)
      }
      runtimeRevisionIDs.append(revision.revisionID)
      for segment in result.segments {
        let mappedStart = max(
          sourceBounds.start,
          segment.monotonicStartNanoseconds
        )
        let mappedEnd = min(
          sourceBounds.end,
          segment.monotonicEndNanoseconds
        )
        guard
          segmentIDs.insert(segment.segmentID).inserted,
          segment.monotonicStartNanoseconds >= range.monotonicStartNanoseconds,
          segment.monotonicStartNanoseconds < segment.monotonicEndNanoseconds,
          segment.monotonicEndNanoseconds <= range.monotonicEndNanoseconds,
          mappedStart < mappedEnd
        else {
          throw failure(.corruptInput, "dictation-asr-segment-malformed", true)
        }
        transcriptCharacterCount += segment.text.count
        guard transcriptCharacterCount <= policy.maximumTranscriptCharacters else {
          throw failure(.resourcePressure, "dictation-asr-output-too-large", false)
        }
        let normalized = ASRSegment(
          segmentID: segment.segmentID,
          monotonicStartNanoseconds: mappedStart,
          monotonicEndNanoseconds: mappedEnd,
          text: segment.text,
          confidence: segment.confidence
        )
        allSegments.append(normalized)
        contextSegmentsByTrack[range.trackID, default: []].append(normalized)
      }
    }

    if versioned.mode == .final, allSegments.isEmpty,
      !policy.permitsEmptyFinalResultForReconciliation
    {
      throw failure(
        .invalidRequest,
        "dictation-asr-no-speech-detected",
        true
      )
    }

    let revisionID = TranscriptRevisionID(
      deterministicUUID(
        [
          "transcript",
          request.sessionID.rawValue.uuidString,
          String(request.inputRevision),
          versioned.mode.rawValue,
          versioned.supersedesRevisionID?.rawValue.uuidString ?? "none",
          descriptor.artifactID,
          configHash.value,
        ] + runtimeRevisionIDs.map(\.uuidString)
      )
    )
    // Independent system-output and microphone tracks can overlap. Present
    // their recognized segments on the shared monotonic timeline while using
    // original recognition order as the deterministic tie-breaker.
    let orderedSegments = allSegments.enumerated().sorted { lhs, rhs in
      if lhs.element.monotonicStartNanoseconds
        != rhs.element.monotonicStartNanoseconds
      {
        return lhs.element.monotonicStartNanoseconds
          < rhs.element.monotonicStartNanoseconds
      }
      if lhs.element.monotonicEndNanoseconds
        != rhs.element.monotonicEndNanoseconds
      {
        return lhs.element.monotonicEndNanoseconds
          < rhs.element.monotonicEndNanoseconds
      }
      return lhs.offset < rhs.offset
    }.map(\.element)
    let segments = orderedSegments.map {
      DictationTranscriptSegment(
        id: $0.segmentID,
        monotonicStartNanoseconds: $0.monotonicStartNanoseconds,
        monotonicEndNanoseconds: $0.monotonicEndNanoseconds,
        text: $0.text,
        confidence: $0.confidence
      )
    }
    let provenanceLanguageHints =
      detectedLanguages.count == 1
      ? Array(detectedLanguages)
      : languageHints
    return DictationTranscriptResult(
      revisionID: revisionID,
      segmentIDs: segments.map(\.id),
      text: TranscriptTextJoiner.join(segments.map(\.text)),
      modelArtifactID: descriptor.artifactID,
      provenance: DictationTranscriptProvenance(
        parentRevisionID: versioned.supersedesRevisionID,
        kind: versioned.mode == .streaming ? .streaming : .final,
        languageHints: provenanceLanguageHints,
        audioRanges: request.audio,
        segments: segments
      )
    )
  }

  private func normalizedDetectedLanguage(_ value: String?) -> String? {
    guard let value else { return nil }
    switch value.replacingOccurrences(of: "_", with: "-").lowercased() {
    case "zh", "zh-cn", "cmn", "cmn-hans-cn":
      return "zh-CN"
    case "en", "en-us", "en-gb":
      return "en-US"
    case "yue", "yue-hk":
      return "yue-HK"
    case "ja", "ja-jp":
      return "ja-JP"
    case "ko", "ko-kr":
      return "ko-KR"
    default:
      return nil
    }
  }

  private func validatePreparedRanges(_ ranges: [AudioRangeInput]) throws {
    guard !ranges.isEmpty, ranges.count <= policy.maximumPreparedRanges else {
      throw failure(.resourcePressure, "dictation-asr-range-count-exceeded", false)
    }
    var previousEndByTrack: [UUID: UInt64] = [:]
    var references = Set<String>()
    for range in ranges {
      let duration = range.monotonicEndNanoseconds
        .subtractingReportingOverflow(range.monotonicStartNanoseconds)
      guard
        !duration.overflow,
        duration.partialValue > 0,
        duration.partialValue <= policy.maximumRangeNanoseconds,
        range.sampleRateHertz == 16_000,
        range.channelCount == 1,
        !range.assetReference.isEmpty,
        references.insert(range.assetReference).inserted,
        previousEndByTrack[range.trackID].map({
          range.monotonicStartNanoseconds >= $0
        }) ?? true
      else {
        throw failure(.invalidRequest, "dictation-asr-prepared-range-invalid", false)
      }
      previousEndByTrack[range.trackID] = range.monotonicEndNanoseconds
    }
  }

  private func sourceBounds(
    for prepared: AudioRangeInput,
    sourceAudio: [AudioRangeInput]
  ) -> (start: UInt64, end: UInt64)? {
    let matchingSource = sourceAudio.filter {
      $0.sourceID == prepared.sourceID && $0.trackID == prepared.trackID
    }.sorted {
      if $0.monotonicStartNanoseconds != $1.monotonicStartNanoseconds {
        return $0.monotonicStartNanoseconds < $1.monotonicStartNanoseconds
      }
      return $0.assetReference < $1.assetReference
    }
    guard
      let firstIndex = matchingSource.firstIndex(where: { range in
        let tolerance = timestampTolerance(sampleRateHertz: range.sampleRateHertz)
        let lowerBound =
          range.monotonicStartNanoseconds > tolerance
          ? range.monotonicStartNanoseconds - tolerance
          : 0
        let upperBound = addingWithoutOverflow(
          range.monotonicEndNanoseconds,
          tolerance
        )
        return prepared.monotonicStartNanoseconds >= lowerBound
          && prepared.monotonicStartNanoseconds <= upperBound
      })
    else { return nil }

    let first = matchingSource[firstIndex]
    var coveredEnd = first.monotonicEndNanoseconds
    var lastSampleRateHertz = first.sampleRateHertz
    for range in matchingSource.dropFirst(firstIndex + 1) {
      let tolerance = timestampTolerance(sampleRateHertz: range.sampleRateHertz)
      guard
        range.monotonicStartNanoseconds
          <= addingWithoutOverflow(coveredEnd, tolerance)
      else { break }
      coveredEnd = max(coveredEnd, range.monotonicEndNanoseconds)
      lastSampleRateHertz = range.sampleRateHertz
      if prepared.monotonicEndNanoseconds <= coveredEnd { break }
    }
    let finalTolerance = timestampTolerance(
      sampleRateHertz: lastSampleRateHertz
    )
    guard
      prepared.monotonicEndNanoseconds
        <= addingWithoutOverflow(coveredEnd, finalTolerance)
    else { return nil }
    return (first.monotonicStartNanoseconds, coveredEnd)
  }

  private func timestampTolerance(sampleRateHertz: UInt32) -> UInt64 {
    max(UInt64(1), 2_000_000_000 / UInt64(max(1, sampleRateHertz)))
  }

  private func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    lhs > UInt64.max - rhs ? UInt64.max : lhs + rhs
  }

  private func transcribeWithTimeout(_ request: ASRRequest) async throws -> ASRResult {
    let engine = self.engine
    let timeout = policy.timeoutNanoseconds
    return try await withThrowingTaskGroup(of: ASRResult.self) { group in
      group.addTask { try await engine.transcribe(request) }
      group.addTask {
        try await Task.sleep(nanoseconds: timeout)
        throw InferenceEngineError(
          category: .transientRuntime,
          code: "dictation-asr-timeout",
          retryable: true
        )
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else {
        throw InferenceEngineError(
          category: .transientRuntime,
          code: "dictation-asr-runtime-empty",
          retryable: true
        )
      }
      return first
    }
  }

  private func deterministicUUID(_ components: [String]) -> UUID {
    var bytes = Array(
      SHA256.hash(data: Data(components.joined(separator: "\u{1f}").utf8))
        .prefix(16)
    )
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

  private func failure(
    _ category: InferenceFailureCategory,
    _ code: String,
    _ retryable: Bool
  ) -> InferenceEngineError {
    InferenceEngineError(category: category, code: code, retryable: retryable)
  }
}
