import BestASRAudioJournal
import BestASRCandidateAdapters
import BestASRDictation
import BestASRDomain
import BestASRFluidRuntime
import BestASRInference
import BestASRDelivery
import BestASRLocalText
import BestASRMLXRuntime
import BestASRModelManager
import BestASRPersistence
import BestASRProcessing
import BestASRQwenRuntime
import BestASRRecognition
import BestASRSpeakerRouting
import CryptoKit
import Foundation
import OSLog

// History: moved out of LocalDictationRuntime.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension LocalDictationRuntime {
  /// Rewrites finished recordings at the rate everything already reads them.
  ///
  /// This waits for the same idle moment the models are released at, because
  /// by then nothing is still reading a session's audio: recognition, the
  /// speaker job and any late polish are long done, and a dictation that
  /// starts cancels the timer before this runs.
  func compactIdleRecordings() async {
    let sessions = (try? await repository.sessionsWithUncompactedSourceAudio(
      limit: Self.idleCompactionLimit)) ?? []
    guard !sessions.isEmpty else { return }
    var reclaimed: UInt64 = 0
    var rewritten = 0
    for sessionID in sessions {
      guard sessionsAwaitingInsertion.isEmpty else { break }
      do {
        // Through the journal, which owns these files and caches what it has
        // already read from them.
        let outcome = try await journal.compactSealedRecording(sessionID: sessionID)
        guard !outcome.alreadyCompact else { continue }
        try await repository.applySourceAudioCompaction(
          sessionID: sessionID,
          tracks: outcome.tracks,
          chunks: outcome.runs.map {
            CompactedAudioChunkRecord(
              trackID: $0.trackID,
              sequence: $0.sequence,
              assetReference: $0.assetReference,
              monotonicStartNanoseconds: $0.monotonicStartNanoseconds,
              monotonicEndNanoseconds: $0.monotonicEndNanoseconds,
              frameCount: $0.frameCount,
              digest: $0.contentDigest,
              sampleRateHertz: SourceAudioCompaction.sampleRateHertz,
              channelCount: SourceAudioCompaction.channelCount
            )
          }
        )
        reclaimed += outcome.originalByteCount - outcome.compactedByteCount
        rewritten += 1
      } catch {
        // A session that cannot be verified keeps its original recording.
        continue
      }
    }
    guard rewritten > 0 else { return }
    localDictationRuntimeLogger.notice(
      """
      recordings compacted count=\(rewritten, privacy: .public) \
      reclaimed_mb=\(reclaimed / 1_048_576, privacy: .public)
      """
    )
  }

  /// A fresh final transcript must sort after every persisted live draft.
  /// Lifecycle revisions count capture state transitions and can be lower
  /// than live ASR input revisions; recovery of an already-created final,
  /// however, must retain that final's original revision for idempotency.
  nonisolated static func finalProcessingInputRevision(
    snapshotRevision: UInt64,
    persistedInputRevision: UInt64?,
    persistedTranscripts: [DictationPersistedTranscriptRecord]
  ) throws -> UInt64 {
    if let persistedInputRevision {
      return max(1, persistedInputRevision)
    }
    let maximumPersisted = persistedTranscripts.map(\.inputRevision).max() ?? 0
    let (nextPersisted, overflow) = maximumPersisted.addingReportingOverflow(1)
    guard !overflow else { throw LocalDictationRuntimeError.staleInputRevision }
    return max(1, max(snapshotRevision, nextPersisted))
  }

  func configurePolish(prepare: Bool) async throws {
    let artifact = MLXLocalTextArtifact.qwen3Selected
    let runtime = try await MLXLocalTextRuntimeFactory.makeRuntime(
      modelManager: modelManager,
      artifact: artifact,
      prepare: prepare
    )
    generalTextRuntime = runtime
    let engine = VersionedLocalTextAdapter(
      artifact: artifact.descriptor, runtime: runtime)
    localTextEngine = engine
    polishAdapter = try MLXDictationPolishAdapter(
      engine: engine,
      artifactID: artifact.artifactID,
      configHash: mlxPolishConfigHash.value
    )
    _ = try await repository.requeueDefaultLocalTextJobsForConfiguration(
      modelArtifactKey: artifact.artifactID,
      configHash: mlxPolishConfigHash
    )
    beginLocalTextDrainIfReady()
  }

  func rerecognizeHistory(sessionID: SessionID) async throws -> HistorySpeakerRefreshOutcome {
    guard asrEngine != nil else { throw LocalDictationRuntimeError.modelNotReady }
    let recovery = try await journal.recover(sessionID: sessionID)
    guard recovery.state == .sealed, !recovery.ranges.isEmpty else {
      throw LocalDictationRuntimeError.modelNotReady
    }
    let existing = try await repository.loadTranscripts(sessionID: sessionID)
    let nextRevision = (existing.map(\.inputRevision).max() ?? 0) + 1
    let dictionary = try await repository.dictionaryContext(
      maximumEntries: 64,
      maximumUTF8Bytes: 16_384
    )
    let dictionaryFingerprint = dictionary.entries.map {
      "\($0.id.rawValue.uuidString):\($0.revision.value)"
    }.joined(separator: "|")
    let configHash = try BestASRDomain.SHA256Digest(
      Self.sha256(
        "\(baseASRConfigHash.value)|\(dictionaryFingerprint)"
          + "|\(finalRoutingAvailabilityFingerprint)"
      )
    )
    let adapter = try makeAutomaticFinalASR(
      configHash: configHash,
      // Manual re-recognition must independently infer the source language.
      // Reusing the previous terminal text can permanently preserve a bad
      // language route, which is exactly what re-recognition should repair.
      languageEvidenceText: "",
      languageEvidenceHints: [],
      permitsEmptyResult: false
    )
    let current = TranscriptSelection.current(in: existing)
    let transcript = try await adapter.recognize(
      VersionedDictationASRRequest(
        request: DictationASRRequest(
          sessionID: sessionID,
          inputRevision: nextRevision,
          audio: recovery.ranges,
          dictionaryTerms: dictionary.canonicalTerms,
          dictionaryHints: dictionary.asrDictionaryHints
        ),
        mode: .final,
        languageHints: ["zh-CN", "en-US"],
        supersedesRevisionID: current?.id
      )
    )
    let speakerJob = try await repository.commitRerecognizedTranscriptRevision(
      DictationTranscriptRevisionCommit(
        sessionID: sessionID,
        transcript: transcript,
        inputRevision: nextRevision,
        configHash: configHash,
        createdAt: Date()
      ),
      sourceAudio: recovery.ranges,
      speakerModelArtifactKey: FluidSpeakerPinnedArtifact.artifactID,
      embeddingSpaceID: FluidSpeakerPinnedArtifact.embeddingSpaceID,
      speakerConfigHash: speakerConfigHash
    )
    try? await repository.setAutomaticSessionTitle(
      sessionID: sessionID,
      from: transcript.text
    )
    let speakerOutcome: HistorySpeakerRefreshOutcome
    if let speakerJob {
      beginSpeakerDrainIfReady()
      // Await the actor-owned worker without blocking the main actor. Its
      // persisted job also survives relaunch or an unavailable speaker model.
      await speakerWorkerTask?.value
      let currentJob = try await repository.speakerFinalJob(id: speakerJob.id)
      switch currentJob?.state {
      case .succeeded: speakerOutcome = .completed
      case .permanentFailed, .retryableFailed, .cancelled: speakerOutcome = .failed
      default: speakerOutcome = .queued
      }
    } else {
      speakerOutcome = .preservedHumanDecisions
    }
    if let inputMode = try? await repository.sessionInputMode(
      sessionID: sessionID
    ), inputMode != .dictation {
      _ = try? await repository.scheduleDefaultLocalTextWork(
        sessionID: sessionID,
        inputRevision: nextRevision,
        modelArtifactKey: MLXLocalTextArtifact.qwen3Selected.artifactID,
        configHash: mlxPolishConfigHash
      )
      beginLocalTextDrainIfReady()
    }
    return speakerOutcome
  }

  func repolishHistory(sessionID: SessionID) async throws {
    let transcripts = try await repository.loadTranscripts(sessionID: sessionID)
    guard let source = TranscriptSelection.current(in: transcripts) else {
      throw LocalDictationRuntimeError.modelNotReady
    }
    let dictionary = try await repository.dictionaryContext(
      maximumEntries: 64,
      maximumUTF8Bytes: 16_384
    )
    let dictionaryFingerprint = dictionary.entries.map {
      "\($0.id.rawValue.uuidString):\($0.revision.value)"
    }.joined(separator: "|")
    let snapshot = try await repository.load(sessionID: sessionID)
    let targetPolicy = snapshot?.target?.bundleIdentifier.flatMap {
      appPolicies[$0]
    }
    let shouldUseModelPolish =
      targetPolicy?.polishEnabled
      ?? defaultPolishEnabled
    let basePolish: any DictationPolishPort
    if personalCleanupEnabled, let personalCleanup {
      basePolish = personalCleanup
    } else if shouldUseModelPolish, let polishAdapter {
      basePolish = polishAdapter
    } else {
      basePolish = DeterministicPunctuationPolishAdapter()
    }
    let polish = AppFormattingPolishAdapter(
      base: basePolish,
      style: targetPolicy?.formattingStyle ?? .automatic
    )
    let transcript = DictationTranscriptResult(
      revisionID: source.id,
      segmentIDs: source.segments.map(\.id),
      text: source.content,
      modelArtifactID: source.modelArtifactID ?? "bestasr-user-edit-v1"
    )
    let request = DictationPolishRequest(
      sessionID: sessionID,
      transcript: transcript,
      dictionaryTerms: dictionary.canonicalTerms,
      targetBundleIdentifier: snapshot?.target?.bundleIdentifier
    )
    let candidate: DictationPolishResult
    do {
      let proposed = try await polish.polish(request)
      let validation = DictationProtectedFactValidator.validate(
        source: source.content,
        candidate: proposed.text,
        dictionaryTerms: dictionary.canonicalTerms
      )
      candidate =
        proposed.sourceRevisionID == source.id && validation.passed
        ? proposed
        : try await DeterministicPunctuationPolishAdapter().polish(request)
    } catch {
      candidate = try await DeterministicPunctuationPolishAdapter().polish(request)
    }
    let selectedConfig: BestASRDomain.SHA256Digest =
      if personalCleanupEnabled, let personalCleanup {
        personalCleanupConfigHash(personalCleanup.revision)
      } else if shouldUseModelPolish, polishAdapter != nil {
        mlxPolishConfigHash
      } else {
        deterministicPolishConfigHash
      }
    let configHash = try BestASRDomain.SHA256Digest(
      Self.sha256(
        "\(selectedConfig.value)|\(dictionaryFingerprint)"
          + "|\(targetPolicy?.formattingStyle.rawValue ?? "automatic")"
      )
    )
    try await repository.saveRepolishedText(
      sessionID: sessionID,
      sourceTranscriptID: source.id,
      sourceRevision: source.inputRevision,
      result: candidate,
      configHash: configHash
    )
  }
}
