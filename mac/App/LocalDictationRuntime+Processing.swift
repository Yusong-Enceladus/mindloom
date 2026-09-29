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

// Processing: moved out of LocalDictationRuntime.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension LocalDictationRuntime {
  func process(
    _ finalization: DictationCaptureFinalization
  ) async throws -> DictationProcessingOutcome {
    guard let sessionID = finalization.snapshot.sessionID else {
      throw LocalDictationRuntimeError.modelNotReady
    }
    do {
      guard asrEngine != nil else { throw LocalDictationRuntimeError.modelNotReady }
      defer { clearLivePresentationState(sessionID: sessionID) }
      liveSpeakerTasks[sessionID]?.cancel()
      liveSpeakerTasks[sessionID] = nil
      let barrierStarted = ContinuousClock.now
      await liveCoordinator?.awaitFinalizationBarrier(sessionID: sessionID)
      logDictationStage("live-barrier", since: barrierStarted)
      // Resuming polish/insertion must keep the source transcript's original
      // input revision.  The snapshot revision also advances for lifecycle and
      // recovery transitions, so using it here would manufacture a different
      // derivation identity after relaunch.
      let persistedTranscripts = try? await repository.loadTranscripts(
        sessionID: sessionID
      )
      let persistedInputRevision = finalization.snapshot.transcript.flatMap {
        transcript in
        persistedTranscripts?.first(where: { $0.id == transcript.revisionID })?
          .inputRevision
      }
      let inputRevision = try Self.finalProcessingInputRevision(
        snapshotRevision: finalization.snapshot.revision,
        persistedInputRevision: persistedInputRevision,
        persistedTranscripts: persistedTranscripts ?? []
      )
      let dictionary = try await repository.dictionaryContext(
        maximumEntries: 64,
        maximumUTF8Bytes: 16_384
      )
      let dictionaryFingerprint = dictionary.entries.map {
        "\($0.id.rawValue.uuidString):\($0.revision.value)"
      }.joined(separator: "|")
      let asrConfigHash = try BestASRDomain.SHA256Digest(
        Self.sha256(
          "\(baseASRConfigHash.value)|\(dictionaryFingerprint)"
            + "|\(finalRoutingAvailabilityFingerprint)"
        )
      )
      let targetPolicy = finalization.snapshot.target?.bundleIdentifier
        .flatMap { appPolicies[$0] }
      let shouldUseModelPolish =
        targetPolicy?.polishEnabled
        ?? defaultPolishEnabled
      // The personal cleanup model is this user's own; when it is installed it
      // replaces both the generic polish and the plain rule cleanup, and its
      // own guard falls back to the rules whenever it strays from the speech.
      let basePolish: any DictationPolishPort
      let selectedPolishConfigHash: BestASRDomain.SHA256Digest
      if personalCleanupEnabled, let personalCleanup {
        basePolish = personalCleanup
        selectedPolishConfigHash = personalCleanupConfigHash(personalCleanup.revision)
      } else if shouldUseModelPolish, let polishAdapter {
        basePolish = polishAdapter
        selectedPolishConfigHash = mlxPolishConfigHash
      } else {
        basePolish = DeterministicPunctuationPolishAdapter()
        selectedPolishConfigHash = deterministicPolishConfigHash
      }
      let selectedPolish: any DictationPolishPort = AppFormattingPolishAdapter(
        base: basePolish,
        style: targetPolicy?.formattingStyle ?? .automatic
      )
      let polishConfigHash = try BestASRDomain.SHA256Digest(
        Self.sha256(
          "\(selectedPolishConfigHash.value)|\(dictionaryFingerprint)"
            + "|\(targetPolicy?.formattingStyle.rawValue ?? "automatic")"
        )
      )
      let liveParent: TranscriptRevisionID? =
        if let liveCoordinator {
          await liveCoordinator.parentRevisionID(sessionID: sessionID)
        } else {
          nil
        }
      let liveLanguageEvidence = TranscriptSelection.mostRecent(
        in: persistedTranscripts ?? [],
        where: { $0.kind == .streaming || $0.kind == .sentence }
      )
      let asr = try makeAutomaticFinalASR(
        configHash: asrConfigHash,
        languageEvidenceText: liveLanguageEvidence?.content ?? "",
        languageEvidenceHints: liveLanguageEvidence?.languageHints ?? [],
        permitsEmptyResult: liveParent != nil
      )
      let finalASR: any DictationASRPort
      if let parent = liveParent {
        finalASR = FinalParentingASRAdapter(
          base: asr,
          parentRevisionID: parent,
          liveCandidates: (persistedTranscripts ?? []).compactMap(
            finalTranscriptCandidate
          ),
          dictionaryTerms: dictionary.canonicalTerms
        )
      } else {
        finalASR = asr
      }
      // Neither model may delay insertion past its budget: the rule-cleaned
      // transcript is inserted and the model result is kept in history once
      // this session's insertion has committed. The personal cleanup model
      // gets a real budget because pause decodes usually have its answer
      // waiting; the generic polish gets none.
      let insertionBudget: Duration? =
        personalCleanupEnabled && personalCleanup != nil
        ? Self.personalCleanupInsertionBudget
        : (shouldUseModelPolish && polishAdapter != nil ? Self.polishInsertionBudget : nil)
      let insertionPolish: any DictationPolishPort =
        insertionBudget.map { budget -> any DictationPolishPort in
          TimeBoxedDictationPolishAdapter(
            base: TimedDictationPolish(base: selectedPolish),
            budget: budget,
            onLateResult: { [weak self] request, result in
              await self?.receiveLatePolish(
                LateDictationPolish(
                  request: request,
                  result: result,
                  inputRevision: inputRevision,
                  configHash: polishConfigHash
                )
              )
            }
          )
        } ?? selectedPolish
      let coordinator = DictationProcessingCoordinator(
        initialSnapshot: finalization.snapshot,
        repository: repository,
        asr: TimedDictationASR(base: finalASR),
        polish: insertionPolish,
        insertion: TimedDictationInsertion(
          base: insertion, deliver: deliveryTransform),
        speaker: GRDBSpeakerJobScheduler(
          store: repository,
          modelArtifactKey: FluidSpeakerPinnedArtifact.artifactID,
          embeddingSpaceID: FluidSpeakerPinnedArtifact.embeddingSpaceID,
          configHash: speakerConfigHash
        )
      )
      sessionsAwaitingInsertion.insert(sessionID)
      let processingStarted = ContinuousClock.now
      let outcome: DictationProcessingOutcome
      do {
        outcome = try await coordinator.process(
          DictationProcessingRequest(
            sessionID: sessionID,
            inputRevision: inputRevision,
            audio: finalization.audio,
            dictionaryTerms: dictionary.canonicalTerms,
            dictionaryHints: dictionary.asrDictionaryHints,
            asrConfigHash: asrConfigHash,
            polishConfigHash: polishConfigHash,
            insertionKey: try DictationIdempotencyKey(
              "insert:\(sessionID.rawValue.uuidString):\(inputRevision)"
            )
          )
        )
      } catch {
        sessionsAwaitingInsertion.remove(sessionID)
        deferredLatePolish[sessionID] = nil
        throw error
      }
      logDictationStage("recognize-polish-insert", since: processingStarted)
      endDictationBookkeeping(sessionID: sessionID)
      sessionsAwaitingInsertion.remove(sessionID)
      if let late = deferredLatePolish.removeValue(forKey: sessionID) {
        await persistLatePolish(late)
      }
      if let titleText = outcome.snapshot.polish?.text
        ?? outcome.snapshot.transcript?.text
      {
        try? await repository.setAutomaticSessionTitle(
          sessionID: sessionID,
          from: titleText
        )
      }
      if let inputMode = try? await repository.sessionInputMode(
        sessionID: sessionID
      ), inputMode != .dictation {
        _ = try? await repository.scheduleDefaultLocalTextWork(
          sessionID: sessionID,
          inputRevision: inputRevision,
          modelArtifactKey: MLXLocalTextArtifact.qwen3Selected.artifactID,
          configHash: mlxPolishConfigHash
        )
        beginLocalTextDrainIfReady()
      }
      await liveCoordinator?.clear(sessionID: sessionID)
      beginSpeakerDrainIfReady()
      return outcome
    } catch {
      // A dictation that failed is still a dictation that ended: pressing the
      // shortcut without speaking must not leave the models resident.
      endDictationBookkeeping(sessionID: sessionID)
      let diagnosticCode = await persistOuterProcessingFailure(
        error,
        sessionID: sessionID
      )
      localDictationRuntimeLogger.error(
        "final processing failed code=\(diagnosticCode, privacy: .public)"
      )
      throw error
    }
  }

  /// What every way of ending a dictation owes the App: the speculation slot
  /// back, with the audio it holds, and the idle release re-armed. Leaving
  /// either one out keeps about 4 GB resident for as long as the App runs.
  func endDictationBookkeeping(sessionID: SessionID) {
    if finalSpeculation?.sessionID == sessionID { finalSpeculation = nil }
    lastFinalASRActivity = ContinuousClock.now
    scheduleIdleModelRelease()
  }

  func persistOuterProcessingFailure(
    _ error: Error,
    sessionID: SessionID
  ) async -> String {
    if let processing = error as? DictationProcessingError,
      case .stageFailed(let failure) = processing
    {
      return failure.code
    }
    let diagnosticCode = Self.processingDiagnosticCode(for: error)
    guard
      let current = try? await repository.load(sessionID: sessionID),
      current.phase.isActive,
      current.phase != .cancelling,
      let failure = try? Self.outerProcessingFailure(
        for: error,
        code: diagnosticCode,
        recoveryPhase: current.phase
      )
    else { return diagnosticCode }
    let actor = DictationSessionActor(initialSnapshot: current)
    guard let failed = try? await actor.handle(.failed(failure)) else {
      return diagnosticCode
    }
    try? await repository.save(failed)
    return diagnosticCode
  }

  nonisolated static func outerProcessingFailure(
    for error: Error,
    code: String,
    recoveryPhase: DictationPhase
  ) throws -> DictationFailure {
    let stage: DictationProcessingStage
    let category: DictationFailureCategory
    let retryable: Bool
    if let processing = error as? DictationProcessingError {
      switch processing {
      case .stageFailed(let failure):
        return failure
      case .persistenceUnavailable:
        stage = .persistence
        category = .transientRuntime
        retryable = true
      case .invalidRequest:
        stage = .recognition
        category = .corruptInput
        retryable = false
      }
    } else if let inference = error as? InferenceEngineError {
      stage = .recognition
      category =
        switch inference.category {
        case .cancelled: .cancelled
        case .corruptInput, .invalidRequest, .unsupportedContractVersion:
          .corruptInput
        case .incompatibleArtifact, .modelUnavailable: .modelUnavailable
        case .resourcePressure: .resourcePressure
        case .transientRuntime: .transientRuntime
        }
      retryable = inference.retryable
    } else if error is CancellationError {
      stage = .recognition
      category = .cancelled
      retryable = true
    } else if error is LocalDictationRuntimeError {
      stage = .recognition
      category = .modelUnavailable
      retryable = true
    } else {
      stage = .recognition
      category = .transientRuntime
      retryable = true
    }
    return try DictationFailure(
      stage: stage,
      category: category,
      code: code,
      retryable: retryable,
      recoveryPhase: recoveryPhase
    )
  }

  nonisolated static func processingDiagnosticCode(
    for error: Error
  ) -> String {
    if let processing = error as? DictationProcessingError {
      switch processing {
      case .stageFailed(let failure): return failure.code
      case .invalidRequest(let code), .persistenceUnavailable(let code):
        return safeDiagnosticCode(code, fallback: "processing-state-invalid")
      }
    }
    if let inference = error as? InferenceEngineError {
      return safeDiagnosticCode(
        inference.code,
        fallback: "inference-runtime-failed"
      )
    }
    if error is CancellationError { return "operation-cancelled" }
    if let local = error as? LocalDictationRuntimeError {
      return switch local {
      case .alphaCandidateMissing: "asr-candidate-missing"
      case .bundledRegistryMissing: "model-registry-missing"
      case .modelNotReady: "model-not-ready"
      case .speakerEvidenceUnavailable: "speaker-evidence-unavailable"
      case .staleInputRevision: "processing-input-revision-stale"
      }
    }
    let bridged = error as NSError
    let domain = bridged.domain.unicodeScalars.map { scalar in
      CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-"
        ? String(scalar) : "-"
    }.joined().lowercased()
    return safeDiagnosticCode(
      "ns-\(String(domain.prefix(80)))-\(bridged.code)",
      fallback: "processing-runtime-failed"
    )
  }

  /// Installs the substitution the mode dictations need. The app owns the
  /// mode and the selected text; this side only asks, once, what to deliver.
  func setDeliveryTransform(_ transform: DictationDeliveryTransform?) {
    deliveryTransform = transform
  }
}
