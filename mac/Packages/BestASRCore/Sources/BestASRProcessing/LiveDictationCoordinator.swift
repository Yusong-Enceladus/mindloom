import BestASRDictation
import BestASRDomain
import BestASRInference
import Foundation

public struct LiveDictationContext: Equatable, Sendable {
  public let dictionaryTerms: [String]
  public let dictionaryHints: [ASRDictionaryHint]
  public let configHash: SHA256Digest
  public let languageHints: [String]

  public init(
    dictionaryTerms: [String],
    configHash: SHA256Digest,
    languageHints: [String] = ["zh-CN", "en-US"]
  ) {
    self.init(
      dictionaryTerms: dictionaryTerms,
      dictionaryHints: [],
      configHash: configHash,
      languageHints: languageHints
    )
  }

  public init(
    dictionaryTerms: [String],
    dictionaryHints: [ASRDictionaryHint],
    configHash: SHA256Digest,
    languageHints: [String] = ["zh-CN", "en-US"]
  ) {
    self.dictionaryTerms = dictionaryTerms
    self.dictionaryHints = dictionaryHints
    self.configHash = configHash
    self.languageHints = languageHints
  }
}

public struct LiveDictationPolicy: Equatable, Sendable {
  public let minimumCadenceNanoseconds: UInt64
  public let maximumContextNanoseconds: UInt64

  public init(
    minimumCadenceNanoseconds: UInt64 = 600_000_000,
    maximumContextNanoseconds: UInt64 = 30_000_000_000
  ) throws {
    guard minimumCadenceNanoseconds > 0, maximumContextNanoseconds > 0 else {
      throw LiveDictationCoordinatorError.invalidPolicy
    }
    self.minimumCadenceNanoseconds = minimumCadenceNanoseconds
    self.maximumContextNanoseconds = maximumContextNanoseconds
  }
}

public enum LiveDictationCoordinatorError: Error, Equatable, Sendable {
  case invalidPolicy
}

public struct LiveDictationEvent: Equatable, Sendable {
  public enum State: Equatable, Sendable {
    case text(kind: TranscriptRevisionKind)
    case unavailable
  }

  public let sessionID: SessionID
  public let text: String
  /// Text produced for the current unstable sentence. `text` also contains
  /// every sentence that has already been committed for the session.
  public let latestText: String
  /// Source ranges and ASR segments for `latestText`. These let a room or
  /// system-audio presentation attach live speaker labels without changing
  /// the transcript revision that remains the source of truth.
  public let audioRanges: [AudioRangeInput]
  public let segments: [DictationTranscriptSegment]
  public let inputRevision: UInt64
  public let state: State

  public init(
    sessionID: SessionID,
    text: String,
    latestText: String = "",
    audioRanges: [AudioRangeInput] = [],
    segments: [DictationTranscriptSegment] = [],
    inputRevision: UInt64 = 0,
    state: State
  ) {
    self.sessionID = sessionID
    self.text = text
    self.latestText = latestText
    self.audioRanges = audioRanges
    self.segments = segments
    self.inputRevision = inputRevision
    self.state = state
  }
}

public struct LiveDictationSchedulingSnapshot: Equatable, Sendable {
  public let inFlight: Bool
  public let pendingRequestCount: Int
  public let generation: UInt64
  public let requestRevision: UInt64
  public let finalized: Bool
}

public actor LiveDictationCoordinator: DictationCommittedChunkObserver {
  public typealias ContextProvider = @Sendable () async throws -> LiveDictationContext
  public typealias EventHandler = @Sendable (LiveDictationEvent) -> Void

  private struct SessionState {
    var generation: UInt64 = 0
    var requestRevision: UInt64 = 0
    var inFlight = false
    var pendingKind: TranscriptRevisionKind?
    var parentRevisionID: TranscriptRevisionID?
    var stableText = ""
    var stableTrackEnds: [UUID: UInt64] = [:]
    var firstCommittedStart: UInt64?
    var lastScheduledEnd: UInt64 = 0
    var paused = false
    var finalized = false
    var task: Task<Void, Never>?
  }

  private let audio: any DictationCommittedAudioPort
  private let asr: any VersionedDictationASRPort
  private let repository: any DictationTranscriptRevisionRepositoryPort
  private let contextProvider: ContextProvider
  private let eventHandler: EventHandler
  private let policy: LiveDictationPolicy
  private let silenceConfiguration: DictationSilenceConfiguration
  private var sessions: [SessionID: SessionState] = [:]
  private var silenceDetectors: [SessionID: DictationSilenceDetector] = [:]

  public init(
    audio: any DictationCommittedAudioPort,
    asr: any VersionedDictationASRPort,
    repository: any DictationTranscriptRevisionRepositoryPort,
    contextProvider: @escaping ContextProvider,
    policy: LiveDictationPolicy,
    silenceConfiguration: DictationSilenceConfiguration,
    eventHandler: @escaping EventHandler = { _ in }
  ) {
    self.audio = audio
    self.asr = asr
    self.repository = repository
    self.contextProvider = contextProvider
    self.policy = policy
    self.silenceConfiguration = silenceConfiguration
    self.eventHandler = eventHandler
  }

  public func didCommit(sessionID: SessionID, chunk: CapturedPCMChunk) async {
    var state = sessions[sessionID] ?? SessionState()
    guard !state.finalized, !state.paused else { return }
    if state.firstCommittedStart == nil {
      state.firstCommittedStart = chunk.monotonicStartNanoseconds
    }
    sessions[sessionID] = state

    var detector =
      silenceDetectors[sessionID]
      ?? DictationSilenceDetector(configuration: silenceConfiguration)
    let sentenceBoundary = (try? detector.consume(chunk)) ?? false
    silenceDetectors[sessionID] = detector

    let duration = UInt64(
      (Double(chunk.frameCount) * 1_000_000_000
        / Double(max(1, chunk.sampleRateHertz))).rounded()
    )
    let committedEnd = chunk.monotonicStartNanoseconds + duration
    let cadenceBase =
      state.lastScheduledEnd == 0
      ? state.firstCommittedStart ?? chunk.monotonicStartNanoseconds
      : state.lastScheduledEnd
    let cadenceReached = committedEnd >= cadenceBase + policy.minimumCadenceNanoseconds
    if sentenceBoundary {
      enqueue(sessionID: sessionID, kind: .sentence, committedEnd: committedEnd)
    } else if cadenceReached {
      enqueue(sessionID: sessionID, kind: .streaming, committedEnd: committedEnd)
    }
  }

  public func didReachBoundary(
    sessionID: SessionID,
    kind: TranscriptRevisionKind
  ) async {
    guard var state = sessions[sessionID] else { return }
    if kind == .final {
      state.finalized = true
      state.generation &+= 1
      state.pendingKind = nil
      state.task?.cancel()
      sessions[sessionID] = state
      return
    }
    state.paused = true
    sessions[sessionID] = state
    enqueue(
      sessionID: sessionID,
      kind: .sentence,
      committedEnd: state.lastScheduledEnd
    )
  }

  public func didResume(sessionID: SessionID) async {
    guard var state = sessions[sessionID], !state.finalized else { return }
    state.paused = false
    sessions[sessionID] = state
  }

  public func parentRevisionID(sessionID: SessionID) -> TranscriptRevisionID? {
    sessions[sessionID]?.parentRevisionID
  }

  public func awaitFinalizationBarrier(sessionID: SessionID) async {
    guard let state = sessions[sessionID], state.finalized else { return }
    state.task?.cancel()
    await state.task?.value
  }

  public func schedulingSnapshot(
    sessionID: SessionID
  ) -> LiveDictationSchedulingSnapshot? {
    guard let state = sessions[sessionID] else { return nil }
    return LiveDictationSchedulingSnapshot(
      inFlight: state.inFlight,
      pendingRequestCount: state.pendingKind == nil ? 0 : 1,
      generation: state.generation,
      requestRevision: state.requestRevision,
      finalized: state.finalized
    )
  }

  public func clear(sessionID: SessionID) {
    sessions[sessionID]?.task?.cancel()
    sessions[sessionID] = nil
    silenceDetectors[sessionID] = nil
  }

  private func enqueue(
    sessionID: SessionID,
    kind: TranscriptRevisionKind,
    committedEnd: UInt64
  ) {
    var state = sessions[sessionID] ?? SessionState()
    guard !state.finalized else { return }
    state.lastScheduledEnd = max(state.lastScheduledEnd, committedEnd)
    if state.inFlight {
      if kind == .sentence {
        state.generation &+= 1
        state.pendingKind = .sentence
        state.task?.cancel()
      } else if state.pendingKind != .sentence {
        state.pendingKind = kind
      }
      sessions[sessionID] = state
      return
    }
    state.inFlight = true
    state.requestRevision &+= 1
    let generation = state.generation
    let revision = state.requestRevision
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performRecognition(
        sessionID: sessionID,
        kind: kind,
        generation: generation,
        inputRevision: revision
      )
    }
    state.task = task
    sessions[sessionID] = state
  }

  private func performRecognition(
    sessionID: SessionID,
    kind: TranscriptRevisionKind,
    generation: UInt64,
    inputRevision: UInt64
  ) async {
    defer { finishRequest(sessionID: sessionID) }
    do {
      let snapshot = try await audio.committedAudioSnapshot(sessionID: sessionID)
      let state = sessions[sessionID] ?? SessionState()
      guard state.generation == generation, !state.finalized else { return }
      let available = snapshot.filter { range in
        guard let stableEnd = state.stableTrackEnds[range.trackID] else { return true }
        return range.monotonicEndNanoseconds > stableEnd
      }.sorted {
        if $0.monotonicStartNanoseconds != $1.monotonicStartNanoseconds {
          return $0.monotonicStartNanoseconds < $1.monotonicStartNanoseconds
        }
        if $0.monotonicEndNanoseconds != $1.monotonicEndNanoseconds {
          return $0.monotonicEndNanoseconds < $1.monotonicEndNanoseconds
        }
        return $0.trackID.uuidString < $1.trackID.uuidString
      }
      guard let first = available.first else { return }
      let (limit, overflow) = first.monotonicStartNanoseconds.addingReportingOverflow(
        policy.maximumContextNanoseconds)
      let windowEnd = overflow ? UInt64.max : limit
      // Consume the earliest complete journal blocks, never just the newest
      // 30 seconds. A sliding tail silently erased continuous speech whenever
      // no silence boundary had yet made the preceding text stable.
      var source = available.filter { $0.monotonicEndNanoseconds <= windowEnd }
      if source.isEmpty {
        // An unusually large committed block is still owned by the bounded
        // audio adapter, which splits it; skipping it would lose evidence.
        source = [first]
      }
      let hasRemainder = source.count < available.count
      let closesWindow =
        kind == .sentence || hasRemainder
        || source.contains { $0.monotonicEndNanoseconds >= windowEnd }
      let revisionKind: TranscriptRevisionKind = closesWindow ? .sentence : .streaming
      let context = try await contextProvider()
      let parent = state.parentRevisionID
      let raw = try await asr.recognize(
        VersionedDictationASRRequest(
          request: DictationASRRequest(
            sessionID: sessionID,
            inputRevision: inputRevision,
            audio: source,
            dictionaryTerms: context.dictionaryTerms,
            dictionaryHints: context.dictionaryHints
          ),
          // A silence/pause boundary is not merely a differently labelled
          // streaming result.  It must use the precise batch capability over
          // the complete unstable sentence so the result can replace the
          // draft before it becomes stable.
          mode: closesWindow ? .final : .streaming,
          languageHints: context.languageHints,
          supersedesRevisionID: parent
        )
      )
      guard
        let current = sessions[sessionID],
        current.generation == generation,
        !current.finalized
      else { return }
      // Silence is a valid consumed window, not a transcript revision. Advance
      // its audio cursor so a long quiet prefix cannot starve later speech.
      guard !raw.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        if closesWindow {
          advanceStableWindow(
            sessionID: sessionID, ranges: source, text: current.stableText,
            hasRemainder: hasRemainder, requestedKind: kind)
        }
        return
      }
      let visibleText = [current.stableText, raw.text]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
      let provenance = raw.provenance.map {
        DictationTranscriptProvenance(
          parentRevisionID: parent,
          kind: revisionKind,
          languageHints: $0.languageHints,
          audioRanges: $0.audioRanges,
          segments: $0.segments
        )
      }
      let transcript = DictationTranscriptResult(
        revisionID: raw.revisionID,
        segmentIDs: raw.segmentIDs,
        text: visibleText,
        modelArtifactID: raw.modelArtifactID,
        provenance: provenance
      )
      try await repository.commitTranscriptRevision(
        DictationTranscriptRevisionCommit(
          sessionID: sessionID,
          transcript: transcript,
          inputRevision: inputRevision,
          configHash: context.configHash,
          createdAt: Date()
        )
      )
      guard
        var committed = sessions[sessionID],
        committed.generation == generation,
        !committed.finalized
      else { return }
      committed.parentRevisionID = transcript.revisionID
      sessions[sessionID] = committed
      if closesWindow {
        advanceStableWindow(
          sessionID: sessionID, ranges: source, text: visibleText,
          hasRemainder: hasRemainder, requestedKind: kind)
      }
      eventHandler(
        LiveDictationEvent(
          sessionID: sessionID,
          text: visibleText,
          latestText: raw.text,
          audioRanges: raw.provenance?.audioRanges ?? source,
          segments: raw.provenance?.segments ?? [],
          inputRevision: inputRevision,
          state: .text(kind: revisionKind)
        )
      )
    } catch is CancellationError {
      return
    } catch {
      guard let state = sessions[sessionID], state.generation == generation,
        !state.finalized
      else { return }
      eventHandler(
        LiveDictationEvent(
          sessionID: sessionID,
          text: "",
          state: .unavailable
        )
      )
    }
  }

  private func advanceStableWindow(
    sessionID: SessionID,
    ranges: [AudioRangeInput],
    text: String,
    hasRemainder: Bool,
    requestedKind: TranscriptRevisionKind
  ) {
    guard var state = sessions[sessionID], !state.finalized else { return }
    state.stableText = text
    for range in ranges {
      state.stableTrackEnds[range.trackID] = max(
        state.stableTrackEnds[range.trackID] ?? 0, range.monotonicEndNanoseconds)
    }
    if hasRemainder {
      // Drain a paused boundary precisely, including its final short window.
      // Continuing capture still coalesces to just one pending request.
      if requestedKind == .sentence || state.paused || state.pendingKind == .sentence {
        state.pendingKind = .sentence
      } else {
        state.pendingKind = .streaming
      }
    }
    sessions[sessionID] = state
  }

  private func finishRequest(sessionID: SessionID) {
    guard var state = sessions[sessionID] else { return }
    state.inFlight = false
    state.task = nil
    let pending = state.pendingKind
    state.pendingKind = nil
    sessions[sessionID] = state
    if let pending, !state.finalized {
      enqueue(
        sessionID: sessionID,
        kind: pending,
        committedEnd: state.lastScheduledEnd
      )
    }
  }
}
