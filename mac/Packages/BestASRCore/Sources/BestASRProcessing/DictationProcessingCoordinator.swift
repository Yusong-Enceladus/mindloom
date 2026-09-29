import BestASRDictation
import BestASRDomain
import BestASRInference
import CryptoKit
import Foundation
import OSLog

/// Times one step of dictation processing. Only the step name and
/// milliseconds are logged, never the text.
func logProcessingStage(_ stage: String, since start: ContinuousClock.Instant) {
  let elapsed = ContinuousClock.now - start
  let milliseconds =
    elapsed.components.seconds * 1_000
    + elapsed.components.attoseconds / 1_000_000_000_000_000
  Logger(subsystem: "com.bestasr.app", category: "dictation-processing").notice(
    "processing timing stage=\(stage, privacy: .public) ms=\(milliseconds, privacy: .public)"
  )
}

public struct DictationAdapterFailure: Error, Codable, Equatable, Sendable {
  public let category: DictationFailureCategory
  public let code: String
  public let retryable: Bool

  public init(
    category: DictationFailureCategory,
    code: String,
    retryable: Bool
  ) throws {
    _ = try DictationFailure(
      stage: .persistence,
      category: category,
      code: code,
      retryable: retryable,
      recoveryPhase: .recognizing
    )
    self.category = category
    self.code = code
    self.retryable = retryable
  }
}

public struct DictationProcessingRequest: Codable, Equatable, Sendable {
  public let sessionID: SessionID
  public let inputRevision: UInt64
  public let audio: [AudioRangeInput]
  public let dictionaryTerms: [String]
  public let dictionaryHints: [ASRDictionaryHint]
  public let asrConfigHash: BestASRDomain.SHA256Digest
  public let polishConfigHash: BestASRDomain.SHA256Digest
  public let insertionKey: DictationIdempotencyKey

  public init(
    sessionID: SessionID,
    inputRevision: UInt64,
    audio: [AudioRangeInput],
    dictionaryTerms: [String],
    asrConfigHash: BestASRDomain.SHA256Digest,
    polishConfigHash: BestASRDomain.SHA256Digest,
    insertionKey: DictationIdempotencyKey
  ) {
    self.init(
      sessionID: sessionID,
      inputRevision: inputRevision,
      audio: audio,
      dictionaryTerms: dictionaryTerms,
      dictionaryHints: [],
      asrConfigHash: asrConfigHash,
      polishConfigHash: polishConfigHash,
      insertionKey: insertionKey
    )
  }

  public init(
    sessionID: SessionID,
    inputRevision: UInt64,
    audio: [AudioRangeInput],
    dictionaryTerms: [String],
    dictionaryHints: [ASRDictionaryHint],
    asrConfigHash: BestASRDomain.SHA256Digest,
    polishConfigHash: BestASRDomain.SHA256Digest,
    insertionKey: DictationIdempotencyKey
  ) {
    self.sessionID = sessionID
    self.inputRevision = inputRevision
    self.audio = audio
    self.dictionaryTerms = dictionaryTerms
    self.dictionaryHints = dictionaryHints
    self.asrConfigHash = asrConfigHash
    self.polishConfigHash = polishConfigHash
    self.insertionKey = insertionKey
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID
    case inputRevision
    case audio
    case dictionaryTerms
    case dictionaryHints
    case asrConfigHash
    case polishConfigHash
    case insertionKey
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try container.decode(SessionID.self, forKey: .sessionID)
    inputRevision = try container.decode(UInt64.self, forKey: .inputRevision)
    audio = try container.decode([AudioRangeInput].self, forKey: .audio)
    dictionaryTerms =
      try container.decodeIfPresent(
        [String].self,
        forKey: .dictionaryTerms
      ) ?? []
    dictionaryHints =
      try container.decodeIfPresent(
        [ASRDictionaryHint].self,
        forKey: .dictionaryHints
      ) ?? []
    asrConfigHash = try container.decode(
      BestASRDomain.SHA256Digest.self,
      forKey: .asrConfigHash
    )
    polishConfigHash = try container.decode(
      BestASRDomain.SHA256Digest.self,
      forKey: .polishConfigHash
    )
    insertionKey = try container.decode(
      DictationIdempotencyKey.self,
      forKey: .insertionKey
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(inputRevision, forKey: .inputRevision)
    try container.encode(audio, forKey: .audio)
    try container.encode(dictionaryTerms, forKey: .dictionaryTerms)
    try container.encode(dictionaryHints, forKey: .dictionaryHints)
    try container.encode(asrConfigHash, forKey: .asrConfigHash)
    try container.encode(polishConfigHash, forKey: .polishConfigHash)
    try container.encode(insertionKey, forKey: .insertionKey)
  }
}

public enum DictationSpeakerSchedulingState: Codable, Equatable, Sendable {
  case scheduled
  case deferred(code: String)
}

public struct DictationProcessingOutcome: Codable, Equatable, Sendable {
  public let snapshot: DictationSessionSnapshot
  public let speakerScheduling: DictationSpeakerSchedulingState

  public init(
    snapshot: DictationSessionSnapshot,
    speakerScheduling: DictationSpeakerSchedulingState
  ) {
    self.snapshot = snapshot
    self.speakerScheduling = speakerScheduling
  }
}

public enum DictationProcessingError: Error, Equatable, Sendable {
  case invalidRequest(code: String)
  case persistenceUnavailable(code: String)
  case stageFailed(DictationFailure)
}

/// Resumable finalization from a sealed journal. Each immutable processing
/// artifact is committed atomically with the state transition that exposes it.
public actor DictationProcessingCoordinator {
  private var sessionActor: DictationSessionActor
  private let repository: any DictationProcessingRepositoryPort
  private let asr: any DictationASRPort
  private let polish: any DictationPolishPort
  private let insertion: any DictationInsertionPort
  private let speaker: any DictationSpeakerSchedulingPort
  private let clock: any DictationClock
  private let diagnostics: any DictationDiagnosticSink

  public init(
    initialSnapshot: DictationSessionSnapshot,
    repository: any DictationProcessingRepositoryPort,
    asr: any DictationASRPort,
    polish: any DictationPolishPort,
    insertion: any DictationInsertionPort,
    speaker: any DictationSpeakerSchedulingPort,
    clock: any DictationClock = SystemDictationClock(),
    diagnostics: any DictationDiagnosticSink = NoopDictationDiagnosticSink()
  ) {
    sessionActor = DictationSessionActor(
      initialSnapshot: initialSnapshot,
      clock: clock,
      diagnostics: diagnostics
    )
    self.repository = repository
    self.asr = asr
    self.polish = polish
    self.insertion = insertion
    self.speaker = speaker
    self.clock = clock
    self.diagnostics = diagnostics
  }

  public func process(
    _ request: DictationProcessingRequest
  ) async throws -> DictationProcessingOutcome {
    guard request.inputRevision > 0, !request.audio.isEmpty else {
      throw DictationProcessingError.invalidRequest(code: "invalid-audio-input")
    }
    for _ in 0..<8 {
      var snapshot = await sessionActor.currentSnapshot()
      guard snapshot.sessionID == request.sessionID else {
        throw DictationProcessingError.invalidRequest(code: "session-id-mismatch")
      }

      if snapshot.phase == .failedRecoverable {
        guard snapshot.failure?.retryable == true else {
          if let failure = snapshot.failure {
            throw DictationProcessingError.stageFailed(failure)
          }
          throw DictationProcessingError.invalidRequest(code: "missing-failure")
        }
        snapshot = try await sessionActor.handle(.retry)
        do {
          try await repository.save(snapshot)
        } catch {
          await restoreActor(sessionID: request.sessionID)
          throw DictationProcessingError.persistenceUnavailable(
            code: "retry-state-commit-failed"
          )
        }
      }

      switch snapshot.phase {
      case .finalizing:
        let recognizing = try await sessionActor.handle(.journalSealed)
        do {
          try await repository.save(recognizing)
        } catch {
          await restoreActor(sessionID: request.sessionID)
          throw DictationProcessingError.persistenceUnavailable(
            code: "sealed-state-commit-failed"
          )
        }

      case .recognizing:
        try await recognize(request)

      case .polishing:
        try await derivePolish(request, snapshot: snapshot)

      case .inserting:
        try await insert(request, snapshot: snapshot)

      case .completed:
        let scheduling: DictationSpeakerSchedulingState
        do {
          try await speaker.scheduleFinalSpeakerWork(
            sessionID: request.sessionID,
            audio: request.audio,
            inputRevision: request.inputRevision
          )
          scheduling = .scheduled
        } catch {
          scheduling = .deferred(code: "speaker-schedule-deferred")
        }
        return DictationProcessingOutcome(
          snapshot: snapshot,
          speakerScheduling: scheduling
        )

      default:
        throw DictationProcessingError.invalidRequest(
          code: "phase-not-processable"
        )
      }
    }
    throw DictationProcessingError.invalidRequest(code: "transition-limit")
  }

  private func recognize(_ request: DictationProcessingRequest) async throws {
    let result: DictationTranscriptResult
    do {
      result = try await asr.recognize(
        DictationASRRequest(
          sessionID: request.sessionID,
          inputRevision: request.inputRevision,
          audio: request.audio,
          dictionaryTerms: request.dictionaryTerms,
          dictionaryHints: request.dictionaryHints
        )
      )
      guard !result.modelArtifactID.isEmpty else {
        throw try DictationAdapterFailure(
          category: .corruptInput,
          code: "asr-result-malformed",
          retryable: true
        )
      }
      guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw try DictationAdapterFailure(
          category: .corruptInput,
          code: "asr-no-speech-detected",
          retryable: true
        )
      }
    } catch {
      let failure = try mappedFailure(
        error,
        stage: .recognition,
        recoveryPhase: .recognizing
      )
      try await persist(failure: failure, sessionID: request.sessionID)
      throw DictationProcessingError.stageFailed(failure)
    }

    let commitStarted = ContinuousClock.now
    defer { logProcessingStage("commit-recognition", since: commitStarted) }
    let next = try await sessionActor.handle(.recognitionSucceeded(result))
    do {
      try await repository.commitRecognition(
        DictationRecognitionCommit(
          snapshot: next,
          transcript: result,
          inputRevision: request.inputRevision,
          configHash: request.asrConfigHash,
          createdAt: clock.wallTime()
        )
      )
    } catch {
      await restoreActor(sessionID: request.sessionID)
      throw DictationProcessingError.persistenceUnavailable(
        code: "recognition-commit-failed"
      )
    }
  }

  private func derivePolish(
    _ request: DictationProcessingRequest,
    snapshot: DictationSessionSnapshot
  ) async throws {
    guard let transcript = snapshot.transcript else {
      throw DictationProcessingError.invalidRequest(code: "missing-transcript")
    }
    let polishRequest = DictationPolishRequest(
      sessionID: request.sessionID,
      transcript: transcript,
      dictionaryTerms: request.dictionaryTerms,
      targetBundleIdentifier: snapshot.target?.bundleIdentifier
    )
    let selected: DictationPolishResult
    do {
      let polishStarted = ContinuousClock.now
      defer { logProcessingStage("polish-step", since: polishStarted) }
      let candidate = try await polish.polish(polishRequest)
      let factual = DictationProtectedFactValidator.validate(
        source: transcript.text,
        candidate: candidate.text,
        dictionaryTerms: request.dictionaryTerms
      )
      if candidate.sourceRevisionID == transcript.revisionID, factual.passed {
        selected = candidate
      } else {
        selected = await deterministicFallback(
          polishRequest,
          transcript: transcript
        )
      }
    } catch {
      selected = await deterministicFallback(
        polishRequest,
        transcript: transcript
      )
    }

    let event: DictationLifecycleEvent =
      selected.disposition == .model
      ? .polishSucceeded(selected)
      : .polishFellBack(selected)
    let next = try await sessionActor.handle(event)
    let derivationID = Self.stableDerivationID(
      sessionID: request.sessionID,
      sourceID: transcript.revisionID,
      configHash: request.polishConfigHash
    )
    do {
      try await repository.commitPolish(
        DictationPolishCommit(
          derivationID: derivationID,
          snapshot: next,
          polish: selected,
          sourceRevision: request.inputRevision,
          configHash: request.polishConfigHash,
          createdAt: clock.wallTime()
        )
      )
    } catch {
      await restoreActor(sessionID: request.sessionID)
      throw DictationProcessingError.persistenceUnavailable(
        code: "polish-commit-failed"
      )
    }
  }

  private func insert(
    _ request: DictationProcessingRequest,
    snapshot: DictationSessionSnapshot
  ) async throws {
    guard let polish = snapshot.polish else {
      throw DictationProcessingError.invalidRequest(code: "missing-insertion-input")
    }
    let reservation: InsertionReservation
    do {
      reservation = try await repository.reserveInsertion(
        sessionID: request.sessionID,
        key: request.insertionKey
      )
    } catch {
      throw DictationProcessingError.persistenceUnavailable(
        code: "insertion-reservation-failed"
      )
    }

    let result: DictationInsertionResult
    switch reservation {
    case .acquired:
      // Always ask, even when nothing was focused at the start. Where the
      // caret is now is what decides; the start target is only a hint, and a
      // dictation begun with no field in front is usually one the user aimed
      // by clicking into a field before they stopped talking.
      do {
        result = try await insertion.insert(
          DictationInsertionRequest(
            sessionID: request.sessionID,
            target: snapshot.target,
            text: polish.text,
            idempotencyKey: request.insertionKey
          )
        )
        guard result.idempotencyKey == request.insertionKey else {
          throw try DictationAdapterFailure(
            category: .conflict,
            code: "insertion-key-mismatch",
            retryable: true
          )
        }
      } catch {
        let failure = try mappedFailure(
          error,
          stage: .insertion,
          recoveryPhase: .inserting
        )
        try await persist(failure: failure, sessionID: request.sessionID)
        throw DictationProcessingError.stageFailed(failure)
      }

    case .alreadyCompleted:
      guard
        let completed = try await repository.insertionResult(
          sessionID: request.sessionID
        )
      else {
        throw DictationProcessingError.persistenceUnavailable(
          code: "completed-insertion-result-missing"
        )
      }
      result = completed

    case .alreadyReserved:
      // A previous process may have mutated another app and died before its
      // durable result. Never replay that side effect; retain the text locally.
      result = DictationInsertionResult(
        idempotencyKey: request.insertionKey,
        method: .retainedForCopy,
        inserted: false,
        failureReason: .ambiguousReservation
      )
    }

    let completed = try await sessionActor.handle(.insertionCompleted(result))
    do {
      try await repository.commitInsertion(
        DictationInsertionCommit(snapshot: completed, result: result)
      )
    } catch {
      await restoreActor(sessionID: request.sessionID)
      throw DictationProcessingError.persistenceUnavailable(
        code: "insertion-history-commit-failed"
      )
    }
  }

  private func persist(
    failure: DictationFailure,
    sessionID: SessionID
  ) async throws {
    let failed = try await sessionActor.handle(.failed(failure))
    do {
      try await repository.save(failed)
    } catch {
      await restoreActor(sessionID: sessionID)
      throw DictationProcessingError.persistenceUnavailable(
        code: "failure-state-commit-failed"
      )
    }
  }

  private func mappedFailure(
    _ error: Error,
    stage: DictationProcessingStage,
    recoveryPhase: DictationPhase
  ) throws -> DictationFailure {
    if let typed = error as? DictationAdapterFailure {
      return try DictationFailure(
        stage: stage,
        category: typed.category,
        code: typed.code,
        retryable: typed.retryable,
        recoveryPhase: recoveryPhase
      )
    }
    if let inference = error as? InferenceEngineError {
      return try DictationFailure(
        stage: stage,
        category: Self.dictationCategory(inference.category),
        code: Self.safeCode(inference.code, fallback: "inference-runtime-failed"),
        retryable: inference.retryable,
        recoveryPhase: recoveryPhase
      )
    }
    if error is CancellationError {
      return try DictationFailure(
        stage: stage,
        category: .cancelled,
        code: "operation-cancelled",
        retryable: true,
        recoveryPhase: recoveryPhase
      )
    }
    return try DictationFailure(
      stage: stage,
      category: .transientRuntime,
      code: "adapter-runtime-failed",
      retryable: true,
      recoveryPhase: recoveryPhase
    )
  }

  private func rawFallback(
    _ transcript: DictationTranscriptResult
  ) -> DictationPolishResult {
    DictationPolishResult(
      sourceRevisionID: transcript.revisionID,
      text: transcript.text,
      disposition: .rawTranscriptFallback,
      modelArtifactID: nil
    )
  }

  private func deterministicFallback(
    _ request: DictationPolishRequest,
    transcript: DictationTranscriptResult
  ) async -> DictationPolishResult {
    guard
      let punctuation = try? await DeterministicPunctuationPolishAdapter()
        .polish(request),
      punctuation.sourceRevisionID == transcript.revisionID,
      DictationProtectedFactValidator.validate(
        source: transcript.text,
        candidate: punctuation.text,
        dictionaryTerms: request.dictionaryTerms
      ).passed
    else {
      return rawFallback(transcript)
    }
    return punctuation
  }

  private func restoreActor(sessionID: SessionID) async {
    guard let durable = try? await repository.load(sessionID: sessionID) else {
      return
    }
    sessionActor = DictationSessionActor(
      initialSnapshot: durable,
      clock: clock,
      diagnostics: diagnostics
    )
  }

  private nonisolated static func dictationCategory(
    _ category: InferenceFailureCategory
  ) -> DictationFailureCategory {
    switch category {
    case .cancelled:
      return .cancelled
    case .corruptInput, .invalidRequest, .unsupportedContractVersion:
      return .corruptInput
    case .incompatibleArtifact, .modelUnavailable:
      return .modelUnavailable
    case .resourcePressure:
      return .resourcePressure
    case .transientRuntime:
      return .transientRuntime
    }
  }

  private nonisolated static func safeCode(
    _ code: String,
    fallback: String
  ) -> String {
    guard !code.isEmpty, code.count <= 128,
      code.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil
    else { return fallback }
    return code
  }

  private nonisolated static func stableDerivationID(
    sessionID: SessionID,
    sourceID: TranscriptRevisionID,
    configHash: BestASRDomain.SHA256Digest
  ) -> UUID {
    let input = Data(
      "dictation-polish:\(sessionID.rawValue.uuidString):\(sourceID.rawValue.uuidString):\(configHash.value)"
        .utf8
    )
    var bytes = Array(SHA256.hash(data: input).prefix(16))
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
