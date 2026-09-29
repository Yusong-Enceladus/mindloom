import BestASRDomain
import BestASRInference
import Dispatch
import Foundation

public enum DictationCaptureCoordinatorError: Error, Equatable, Sendable {
  case captureTerminated(DictationFailure)
  case noActiveDrain
  case operationFailed(stage: DictationProcessingStage, code: String)
}

public struct DictationCaptureFinalization: Codable, Equatable, Sendable {
  public let snapshot: DictationSessionSnapshot
  public let audio: [AudioRangeInput]

  public init(
    snapshot: DictationSessionSnapshot,
    audio: [AudioRangeInput]
  ) {
    self.snapshot = snapshot
    self.audio = audio
  }
}

public actor DictationCaptureCoordinator {
  private let sessionActor: DictationSessionActor
  private var capture: any MicrophoneCapturePort
  private let journal: any DictationJournalPort
  private let repository: any DictationRepositoryPort
  private let inputMode: SessionInputMode
  private let committedChunkObserver: (any DictationCommittedChunkObserver)?
  private var drainTask: Task<Void, Error>?
  private var captureStream: AsyncStream<CapturedPCMChunk>?
  private var activeSessionID: SessionID?
  private var terminalDrainFailure: DictationFailure?
  private var pendingChunk: CapturedPCMChunk?
  private var captureUnavailableForEnd = false

  public init(
    sessionActor: DictationSessionActor,
    capture: any MicrophoneCapturePort,
    journal: any DictationJournalPort,
    repository: any DictationRepositoryPort,
    inputMode: SessionInputMode = .dictation,
    committedChunkObserver: (any DictationCommittedChunkObserver)? = nil
  ) {
    self.sessionActor = sessionActor
    self.capture = capture
    self.journal = journal
    self.repository = repository
    self.inputMode = inputMode
    self.committedChunkObserver = committedChunkObserver
  }

  public func start(
    sessionID: SessionID,
    target: DictationTargetSnapshot?
  ) async throws -> DictationSessionSnapshot {
    let preparing = try await sessionActor.handle(
      .start(sessionID: sessionID, target: target)
    )
    guard
      inputMode == .dictation
        || repository is any SessionModeDictationRepositoryPort
    else {
      throw DictationCaptureCoordinatorError.operationFailed(
        stage: .persistence,
        code: "repository-does-not-support-session-mode"
      )
    }
    // Start the microphone before any persistence so the first syllable is
    // not lost to database and journal setup. Chunks queue in the capture
    // stream until the journal exists and the drain begins.
    let descriptor: MicrophoneCaptureDescriptor
    do {
      descriptor = try await capture.prepare(sessionID: sessionID)
      try await capture.start()
    } catch {
      await capture.cancel()
      throw error
    }
    do {
      if let modeRepository = repository as? any SessionModeDictationRepositoryPort {
        try await modeRepository.create(preparing, inputMode: inputMode)
      } else {
        try await repository.create(preparing)
      }
    } catch {
      await capture.cancel()
      throw error
    }
    // Only this live path grants organizer eligibility. A failure leaves the
    // session local-only (fail closed) and never stops the recording.
    if let eligibility = repository as? any LiveCaptureRemoteEligibilityPort {
      try? await eligibility.markLiveCaptureRemoteEligible(sessionID: sessionID)
    }
    do {
      try await journal.create(sessionID: sessionID, descriptor: descriptor)
      if let tracks = descriptor.tracks,
        let trackRepository = repository as? any DictationCaptureTrackRepositoryPort
      {
        try await trackRepository.saveCaptureTracks(
          sessionID: sessionID,
          tracks: tracks
        )
      }
      if let marker = preparing.timeline.last {
        try await journal.append(sessionID: sessionID, marker: marker)
      }
      let stream = await capture.chunks()
      captureStream = stream
      activeSessionID = sessionID
      terminalDrainFailure = nil
      pendingChunk = nil
      captureUnavailableForEnd = false
      beginDrain(sessionID: sessionID, stream: stream)
      let recording = try await sessionActor.handle(.preparationSucceeded)
      try await repository.save(recording)
      return recording
    } catch {
      await capture.cancel()
      drainTask?.cancel()
      _ = try? await drainTask?.value
      drainTask = nil
      captureStream = nil
      activeSessionID = nil
      try await persistFailure(
        stage: .capture,
        code: "capture-start-failed",
        recoveryPhase: .preparing
      )
      throw error
    }
  }

  public func synchronizeProcessingSnapshot(
    _ snapshot: DictationSessionSnapshot
  ) async throws {
    try await sessionActor.synchronizeProcessingSnapshot(snapshot)
  }

  public func captureTerminalFailure() async -> DictationFailure? {
    if let terminalDrainFailure { return terminalDrainFailure }
    return await capture.terminalFailure()
  }

  public func pause() async throws -> DictationSessionSnapshot {
    try await capture.pause()
    let paused = try await sessionActor.handle(.pause)
    if let marker = paused.timeline.last {
      try await journal.append(sessionID: try sessionID(from: paused), marker: marker)
    }
    try await repository.save(paused)
    await committedChunkObserver?.didReachBoundary(
      sessionID: try sessionID(from: paused),
      kind: .sentence
    )
    return paused
  }

  public func resume() async throws -> DictationSessionSnapshot {
    let current = await sessionActor.currentSnapshot()
    let sessionID = try sessionID(from: current)
    try await journal.resumeAfterRecoverableStop(sessionID: sessionID)
    if let pendingChunk {
      try await journal.append(sessionID: sessionID, chunk: pendingChunk)
      await committedChunkObserver?.didCommit(
        sessionID: sessionID,
        chunk: pendingChunk
      )
      self.pendingChunk = nil
    }
    try await capture.resume()
    let needsDrainRestart = terminalDrainFailure != nil
    if needsDrainRestart, let drainTask {
      _ = await drainTask.result
      self.drainTask = nil
    }
    terminalDrainFailure = nil
    if needsDrainRestart, let captureStream {
      beginDrain(sessionID: sessionID, stream: captureStream)
    }
    let recording = try await sessionActor.handle(.resume)
    if let marker = recording.timeline.last {
      try await journal.append(
        sessionID: sessionID,
        marker: marker
      )
    }
    try await repository.save(recording)
    await committedChunkObserver?.didResume(
      sessionID: sessionID
    )
    return recording
  }

  /// Replaces a failed or disconnected capture endpoint while preserving the
  /// same durable session. New track identifiers retain device and format
  /// provenance without rewriting audio that was already committed.
  public func replacePausedCapture(
    with replacement: any MicrophoneCapturePort
  ) async throws -> DictationSessionSnapshot {
    let current = await sessionActor.currentSnapshot()
    guard current.phase == .paused else {
      throw DictationCaptureCoordinatorError.operationFailed(
        stage: .capture,
        code: "capture-replacement-requires-pause"
      )
    }
    let sessionID = try sessionID(from: current)
    let pausedAt = current.timeline.last(where: { $0.kind == .paused })?
      .monotonicNanoseconds
    let descriptor = try await replacement.prepare(sessionID: sessionID)
    let tracks = descriptor.tracks ?? []
    guard !tracks.isEmpty,
      let mutableJournal = journal as? any DictationMutableTrackJournalPort,
      let trackRepository = repository as? any DictationCaptureTrackRepositoryPort
    else {
      await replacement.cancel()
      throw DictationCaptureCoordinatorError.operationFailed(
        stage: .journal,
        code: "capture-replacement-tracks-unavailable"
      )
    }

    await capture.cancel()
    drainTask?.cancel()
    _ = await drainTask?.result
    drainTask = nil
    captureStream = nil
    terminalDrainFailure = nil
    pendingChunk = nil
    capture = replacement
    captureUnavailableForEnd = true

    do {
      try await mutableJournal.addCaptureTracks(
        sessionID: sessionID,
        tracks: tracks
      )
      try await trackRepository.saveCaptureTracks(
        sessionID: sessionID,
        tracks: tracks
      )
      let stream = await replacement.chunks()
      captureStream = stream
      beginDrain(sessionID: sessionID, stream: stream)
      try await replacement.start()
      captureUnavailableForEnd = false
      let recording = try await sessionActor.handle(.resume)
      if let marker = recording.timeline.last {
        try await journal.append(sessionID: sessionID, marker: marker)
      }
      try await repository.save(recording)
      if let timelineRepository = repository
        as? any DictationTimelineEventRepositoryPort
      {
        let replacementTime = DispatchTime.now().uptimeNanoseconds
        try await timelineRepository.save(
          timelineEvent: TimelineEvent(
            id: TimelineEventID(),
            sessionID: sessionID,
            revision: try Revision(max(1, recording.revision)),
            kind: .deviceChanged,
            monotonicNanoseconds: replacementTime,
            durationNanoseconds: nil
          )
        )
        if let pausedAt, replacementTime > pausedAt {
          try await timelineRepository.save(
            timelineEvent: TimelineEvent(
              id: TimelineEventID(),
              sessionID: sessionID,
              revision: try Revision(max(1, recording.revision)),
              kind: .gap,
              monotonicNanoseconds: pausedAt,
              durationNanoseconds: replacementTime - pausedAt
            )
          )
        }
      }
      await committedChunkObserver?.didResume(sessionID: sessionID)
      return recording
    } catch {
      await replacement.cancel()
      drainTask?.cancel()
      _ = await drainTask?.result
      drainTask = nil
      captureStream = nil
      let trackIDs = Set(tracks.map(\.id))
      try? await mutableJournal.removeCaptureTracksIfEmpty(
        sessionID: sessionID,
        trackIDs: trackIDs
      )
      try? await trackRepository.removeCaptureTracksIfUnused(
        sessionID: sessionID,
        trackIDs: trackIDs
      )
      throw error
    }
  }

  public func end() async throws -> DictationCaptureFinalization {
    let finalizing = try await sessionActor.handle(.end)
    let sessionID = try sessionID(from: finalizing)
    if let marker = finalizing.timeline.last {
      try await journal.append(sessionID: sessionID, marker: marker)
    }
    try await repository.save(finalizing)
    await committedChunkObserver?.didReachBoundary(
      sessionID: sessionID,
      kind: .final
    )

    do {
      let drainResult: Result<Void, Error>
      if captureUnavailableForEnd {
        drainResult = .success(())
      } else {
        try await capture.stop()
        guard let drainTask else {
          throw DictationCaptureCoordinatorError.noActiveDrain
        }
        drainResult = await drainTask.result
        self.drainTask = nil
      }
      if terminalDrainFailure?.category == .resourcePressure {
        // A low-disk hard stop intentionally excludes the one bounded chunk
        // that did not cross the durable commit boundary. Ending still seals
        // and processes every previously authenticated chunk.
        pendingChunk = nil
        terminalDrainFailure = nil
      } else {
        try drainResult.get()
      }
      if let failure = await capture.terminalFailure(),
        failure.category != .targetUnavailable
      {
        let failed = try await sessionActor.handle(.failed(failure))
        try await repository.save(failed)
        throw DictationCaptureCoordinatorError.captureTerminated(failure)
      }
      let audio = try await journal.seal(sessionID: sessionID)
      let recognizing = try await sessionActor.handle(.journalSealed)
      try await repository.save(recognizing)
      captureStream = nil
      activeSessionID = nil
      return DictationCaptureFinalization(snapshot: recognizing, audio: audio)
    } catch {
      self.drainTask = nil
      if let coordinatorError = error as? DictationCaptureCoordinatorError,
        case .captureTerminated = coordinatorError
      {
        throw coordinatorError
      }
      try await persistFailure(
        stage: .journal,
        code: "capture-finalize-failed",
        recoveryPhase: .finalizing
      )
      throw error
    }
  }

  public func cancel() async throws -> DictationSessionSnapshot {
    let cancelling = try await sessionActor.handle(.cancel)
    let sessionID = try sessionID(from: cancelling)
    if let marker = cancelling.timeline.last {
      try await journal.append(sessionID: sessionID, marker: marker)
    }
    try await repository.save(cancelling)
    await capture.cancel()
    drainTask?.cancel()
    _ = try? await drainTask?.value
    drainTask = nil
    captureStream = nil
    activeSessionID = nil
    terminalDrainFailure = nil
    pendingChunk = nil
    try await journal.cancelEphemeral(sessionID: sessionID)
    try await repository.cancelEphemeral(sessionID: sessionID)
    return try await sessionActor.handle(.cancellationCompleted)
  }

  private func persistFailure(
    stage: DictationProcessingStage,
    code: String,
    recoveryPhase: DictationPhase
  ) async throws {
    let failure = try DictationFailure(
      stage: stage,
      category: .transientRuntime,
      code: code,
      retryable: true,
      recoveryPhase: recoveryPhase
    )
    let current = await sessionActor.currentSnapshot()
    guard current.phase.isActive, current.phase != .cancelling else { return }
    let failed = try await sessionActor.handle(.failed(failure))
    try await repository.save(failed)
  }

  private func beginDrain(
    sessionID: SessionID,
    stream: AsyncStream<CapturedPCMChunk>
  ) {
    let journal = self.journal
    let observer = committedChunkObserver
    drainTask = Task { [weak self] in
      for await chunk in stream {
        try Task.checkCancellation()
        do {
          try await journal.append(sessionID: sessionID, chunk: chunk)
          await observer?.didCommit(sessionID: sessionID, chunk: chunk)
        } catch {
          await self?.recordDrainFailure(error, pendingChunk: chunk)
          throw error
        }
      }
    }
  }

  private func recordDrainFailure(
    _ error: Error,
    pendingChunk: CapturedPCMChunk
  ) {
    self.pendingChunk = pendingChunk
    let description = String(describing: error)
    let isDiskPressure = description.contains("disk-hard-stop")
    terminalDrainFailure = try? DictationFailure(
      stage: .journal,
      category: isDiskPressure ? .resourcePressure : .transientRuntime,
      code: isDiskPressure ? "disk-hard-stop" : "journal-append-failed",
      retryable: true,
      recoveryPhase: .recording
    )
  }

  private func sessionID(
    from snapshot: DictationSessionSnapshot
  ) throws -> SessionID {
    guard let sessionID = snapshot.sessionID else {
      throw DictationCaptureCoordinatorError.operationFailed(
        stage: .persistence,
        code: "missing-session-id"
      )
    }
    return sessionID
  }
}
