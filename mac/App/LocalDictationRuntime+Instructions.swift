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

// Instructions: moved out of LocalDictationRuntime.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension LocalDictationRuntime {
  func receiveLatePolish(_ late: LateDictationPolish) async {
    let sessionID = late.request.sessionID
    guard !sessionsAwaitingInsertion.contains(sessionID) else {
      deferredLatePolish[sessionID] = late
      return
    }
    await persistLatePolish(late)
  }

  /// Keeps a model polish that finished after the insertion deadline as the
  /// record's current polished text. It passes the same factual gate as an
  /// on-time result and never touches the already inserted target text.
  func persistLatePolish(_ late: LateDictationPolish) async {
    let source = late.request.transcript
    // History follows the same cleanup rules as the inserted text.
    let result = DictationPolishResult(
      sourceRevisionID: late.result.sourceRevisionID,
      text: DictationTextCleanup.apply(late.result.text),
      disposition: late.result.disposition,
      modelArtifactID: late.result.modelArtifactID
    )
    guard result.sourceRevisionID == source.revisionID,
      DictationProtectedFactValidator.validate(
        source: source.text,
        candidate: result.text,
        dictionaryTerms: late.request.dictionaryTerms
      ).passed
    else { return }
    do {
      try await repository.saveRepolishedText(
        sessionID: late.request.sessionID,
        sourceTranscriptID: source.revisionID,
        sourceRevision: late.inputRevision,
        result: result,
        configHash: late.configHash
      )
      localDictationRuntimeLogger.notice("late model polish kept in history")
    } catch {
      localDictationRuntimeLogger.notice("late model polish not kept")
    }
  }

  /// Carries out a spoken instruction, optionally about text the user had
  /// highlighted. The selection is passed through and never stored or logged.
  func follow(instruction: String, on selection: String?) async -> String? {
    guard let generalTextRuntime else { return nil }
    let started = ContinuousClock.now
    defer { logDictationStage("command", since: started) }
    warmFinalASRIfIdle()
    textModelReleaseTask?.cancel()
    defer { scheduleTextModelRelease() }
    return try? await generalTextRuntime.follow(instruction: instruction, on: selection)
  }
}
