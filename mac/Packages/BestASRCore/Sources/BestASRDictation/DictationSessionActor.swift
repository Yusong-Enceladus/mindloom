import BestASRDomain
import Foundation

public actor DictationSessionActor {
  private var snapshot: DictationSessionSnapshot
  private let clock: any DictationClock
  private let diagnostics: any DictationDiagnosticSink

  public init(
    initialSnapshot: DictationSessionSnapshot = DictationSessionSnapshot(),
    clock: any DictationClock = SystemDictationClock(),
    diagnostics: any DictationDiagnosticSink = NoopDictationDiagnosticSink()
  ) {
    snapshot = initialSnapshot
    self.clock = clock
    self.diagnostics = diagnostics
  }

  public func currentSnapshot() -> DictationSessionSnapshot { snapshot }

  public func synchronizeProcessingSnapshot(
    _ durableSnapshot: DictationSessionSnapshot
  ) async throws {
    try durableSnapshot.validate()
    guard
      snapshot.sessionID == durableSnapshot.sessionID,
      [.recognizing, .polishing, .inserting, .failedRecoverable]
        .contains(snapshot.phase),
      [.completed, .failedRecoverable].contains(durableSnapshot.phase)
    else {
      _ = try await reject("synchronize-processing-snapshot")
      return
    }
    snapshot = durableSnapshot
    await emit(reason: .recovered)
  }

  @discardableResult
  public func handle(_ command: DictationCommand) async throws
    -> DictationSessionSnapshot
  {
    switch command {
    case .start(let sessionID, let target):
      guard
        [.idle, .completed, .cancelled, .failedRecoverable]
          .contains(snapshot.phase)
      else {
        return try await reject("start")
      }
      return await transition(
        phase: .preparing,
        sessionID: sessionID,
        target: target,
        reset: true,
        marker: .started
      )

    case .pause:
      guard snapshot.phase == .recording else {
        return try await reject("pause")
      }
      return await transition(phase: .paused, marker: .paused)

    case .resume:
      guard snapshot.phase == .paused else {
        return try await reject("resume")
      }
      return await transition(phase: .recording, marker: .resumed)

    case .end:
      if [.finalizing, .recognizing, .polishing, .inserting, .completed]
        .contains(snapshot.phase)
      {
        return snapshot
      }
      guard [.recording, .paused].contains(snapshot.phase) else {
        return try await reject("end")
      }
      return await transition(phase: .finalizing, marker: .endRequested)

    case .cancel:
      if [.cancelling, .cancelled].contains(snapshot.phase) { return snapshot }
      guard [.preparing, .recording, .paused].contains(snapshot.phase) else {
        return try await reject("cancel")
      }
      return await transition(phase: .cancelling, marker: .cancelRequested)

    case .retry:
      guard snapshot.phase == .failedRecoverable,
        let failure = snapshot.failure,
        failure.retryable
      else {
        return try await reject("retry")
      }
      return await transition(
        phase: failure.recoveryPhase,
        failure: .some(nil),
        reason: .recovered
      )
    }
  }

  @discardableResult
  public func handle(_ event: DictationLifecycleEvent) async throws
    -> DictationSessionSnapshot
  {
    switch event {
    case .preparationSucceeded:
      guard snapshot.phase == .preparing else {
        return try await reject("preparation-succeeded")
      }
      return await transition(phase: .recording)

    case .journalSealed:
      guard snapshot.phase == .finalizing else {
        return try await reject("journal-sealed")
      }
      return await transition(phase: .recognizing)

    case .recognitionSucceeded(let transcript):
      guard snapshot.phase == .recognizing else {
        return try await reject("recognition-succeeded")
      }
      return await transition(phase: .polishing, transcript: transcript)

    case .polishSucceeded(let polish), .polishFellBack(let polish):
      guard snapshot.phase == .polishing else {
        return try await reject("polish-completed")
      }
      guard polish.sourceRevisionID == snapshot.transcript?.revisionID else {
        return try await reject("polish-source-mismatch")
      }
      return await transition(phase: .inserting, polish: polish)

    case .insertionCompleted(let insertion):
      guard snapshot.phase == .inserting else {
        return try await reject("insertion-completed")
      }
      return await transition(phase: .completed, insertion: insertion)

    case .cancellationCompleted:
      guard snapshot.phase == .cancelling else {
        return try await reject("cancellation-completed")
      }
      return await transition(phase: .cancelled)

    case .ambientSilence:
      guard snapshot.phase == .recording else {
        return try await reject("ambient-silence")
      }
      await emit(reason: .ambientSilence)
      return snapshot

    case .failed(let failure):
      guard snapshot.phase.isActive, snapshot.phase != .cancelling else {
        return try await reject("failed")
      }
      return await transition(
        phase: .failedRecoverable,
        failure: .some(failure),
        reason: .failure,
        reasonCode: failure.code
      )
    }
  }

  private func reject(_ action: String) async throws -> DictationSessionSnapshot {
    await emit(reason: .commandRejected, reasonCode: "invalid-transition")
    throw DictationValidationError.invalidTransition(
      from: snapshot.phase,
      action: action
    )
  }

  private func transition(
    phase: DictationPhase,
    sessionID: SessionID? = nil,
    target: DictationTargetSnapshot? = nil,
    reset: Bool = false,
    marker: DictationTimelineMarkerKind? = nil,
    transcript: DictationTranscriptResult? = nil,
    polish: DictationPolishResult? = nil,
    insertion: DictationInsertionResult? = nil,
    failure: DictationFailure?? = nil,
    reason: DictationDiagnosticReason = .stateTransition,
    reasonCode: String? = nil
  ) async -> DictationSessionSnapshot {
    var timeline = reset ? [] : snapshot.timeline
    if let marker {
      timeline.append(
        DictationTimelineMarker(
          kind: marker,
          monotonicNanoseconds: clock.monotonicNanoseconds()
        )
      )
    }
    snapshot = DictationSessionSnapshot(
      sessionID: sessionID ?? snapshot.sessionID,
      revision: reset ? 1 : snapshot.revision + 1,
      phase: phase,
      target: reset ? target : (target ?? snapshot.target),
      timeline: timeline,
      transcript: reset ? nil : (transcript ?? snapshot.transcript),
      polish: reset ? nil : (polish ?? snapshot.polish),
      insertion: reset ? nil : (insertion ?? snapshot.insertion),
      failure: failure ?? (reset ? nil : snapshot.failure)
    )
    await emit(reason: reason, reasonCode: reasonCode)
    return snapshot
  }

  private func emit(
    reason: DictationDiagnosticReason,
    reasonCode: String? = nil
  ) async {
    guard
      let event = try? DictationDiagnosticEvent(
        sessionID: snapshot.sessionID,
        phase: snapshot.phase,
        reason: reason,
        monotonicNanoseconds: clock.monotonicNanoseconds(),
        reasonCode: reasonCode
      )
    else { return }
    await diagnostics.record(event)
  }
}
