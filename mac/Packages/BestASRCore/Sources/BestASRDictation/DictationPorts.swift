import BestASRDomain
import BestASRInference
import Dispatch
import Foundation

public enum DictationPermissionKind: String, Codable, Hashable, Sendable {
  case microphone
  case accessibility
  case systemAudioCapture
}

public enum DictationPermissionState: String, Codable, Sendable {
  case notDetermined
  case denied
  case granted
  case restricted
  case revoked
  case restartRequired
}

public enum GlobalHotkeyAction: UInt32, Codable, CaseIterable, Hashable, Sendable {
  case startOrEnd = 1
  case pauseOrResume = 2
  case cancel = 3
}

public struct GlobalHotkeyModifiers: OptionSet, Codable, Hashable, Sendable {
  public let rawValue: UInt32

  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let command = Self(rawValue: 1 << 0)
  public static let option = Self(rawValue: 1 << 1)
  public static let control = Self(rawValue: 1 << 2)
  public static let shift = Self(rawValue: 1 << 3)
  /// The hardware Globe/Fn modifier. Carbon does not expose this modifier, so
  /// the macOS backend registers it through the trusted global event tap.
  public static let function = Self(rawValue: 1 << 4)
}

public struct GlobalHotkeyBinding: Codable, Hashable, Sendable {
  public let keyCode: UInt32
  public let modifiers: GlobalHotkeyModifiers

  public init(keyCode: UInt32, modifiers: GlobalHotkeyModifiers) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }
}

public enum GlobalHotkeyRegistrationResult: Equatable, Sendable {
  case registered
  case conflict
  case unavailable(code: String)
}

public protocol GlobalHotkeyPort: Sendable {
  func register(
    action: GlobalHotkeyAction,
    binding: GlobalHotkeyBinding
  ) async -> GlobalHotkeyRegistrationResult
  func unregister(action: GlobalHotkeyAction) async
  func actions() async -> AsyncStream<GlobalHotkeyAction>
  func setCancellationEnabled(_ enabled: Bool) async
}

public enum PCMEncoding: String, Codable, Sendable {
  case float32LittleEndian
  case int16LittleEndian
}

public struct CaptureTrackDescriptor: Codable, Equatable, Sendable {
  public let id: TrackID
  public let role: SourceTrackRole
  public let deviceUID: String
  public let sampleRateHertz: UInt32
  public let channelCount: UInt16
  public let encoding: PCMEncoding
  public let interleaved: Bool

  public init(
    id: TrackID = TrackID(),
    role: SourceTrackRole,
    deviceUID: String,
    sampleRateHertz: UInt32,
    channelCount: UInt16,
    encoding: PCMEncoding,
    interleaved: Bool
  ) {
    self.id = id
    self.role = role
    self.deviceUID = deviceUID
    self.sampleRateHertz = sampleRateHertz
    self.channelCount = channelCount
    self.encoding = encoding
    self.interleaved = interleaved
  }
}

public struct MicrophoneCaptureDescriptor: Codable, Equatable, Sendable {
  public let sessionID: SessionID
  public let deviceUID: String
  public let sampleRateHertz: UInt32
  public let channelCount: UInt16
  public let encoding: PCMEncoding
  public let interleaved: Bool
  /// Nil is the backward-compatible single microphone track. Multi-source
  /// capture supplies every independent durable track explicitly.
  public let tracks: [CaptureTrackDescriptor]?

  public init(
    sessionID: SessionID,
    deviceUID: String,
    sampleRateHertz: UInt32,
    channelCount: UInt16,
    encoding: PCMEncoding,
    interleaved: Bool,
    tracks: [CaptureTrackDescriptor]? = nil
  ) {
    self.sessionID = sessionID
    self.deviceUID = deviceUID
    self.sampleRateHertz = sampleRateHertz
    self.channelCount = channelCount
    self.encoding = encoding
    self.interleaved = interleaved
    self.tracks = tracks
  }
}

public struct CapturedPCMChunk: Codable, Equatable, Sendable {
  public let trackID: TrackID?
  public let sequence: UInt64
  public let monotonicStartNanoseconds: UInt64
  public let frameCount: UInt64
  public let sampleRateHertz: UInt32
  public let channelCount: UInt16
  public let encoding: PCMEncoding
  public let interleaved: Bool
  public let bytes: Data

  public init(
    trackID: TrackID? = nil,
    sequence: UInt64,
    monotonicStartNanoseconds: UInt64,
    frameCount: UInt64,
    sampleRateHertz: UInt32,
    channelCount: UInt16,
    encoding: PCMEncoding,
    interleaved: Bool,
    bytes: Data
  ) {
    self.trackID = trackID
    self.sequence = sequence
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.frameCount = frameCount
    self.sampleRateHertz = sampleRateHertz
    self.channelCount = channelCount
    self.encoding = encoding
    self.interleaved = interleaved
    self.bytes = bytes
  }
}

public protocol MicrophoneCapturePort: Sendable {
  func prepare(sessionID: SessionID) async throws -> MicrophoneCaptureDescriptor
  func start() async throws
  func chunks() async -> AsyncStream<CapturedPCMChunk>
  func pause() async throws
  func resume() async throws
  func stop() async throws
  func cancel() async
  func terminalFailure() async -> DictationFailure?
}

public protocol DictationJournalPort: Sendable {
  func create(sessionID: SessionID, descriptor: MicrophoneCaptureDescriptor) async throws
  func append(sessionID: SessionID, chunk: CapturedPCMChunk) async throws
  func append(sessionID: SessionID, marker: DictationTimelineMarker) async throws
  func seal(sessionID: SessionID) async throws -> [AudioRangeInput]
  /// Reopens an intact journal that deliberately stopped before a recoverable
  /// resource-pressure write. Journals that do not need this may no-op.
  func resumeAfterRecoverableStop(sessionID: SessionID) async throws
  func cancelEphemeral(sessionID: SessionID) async throws
  func recoveryStatus(sessionID: SessionID) async throws
    -> DictationJournalRecoveryStatus
}

public protocol DictationMutableTrackJournalPort: DictationJournalPort {
  func addCaptureTracks(
    sessionID: SessionID,
    tracks: [CaptureTrackDescriptor]
  ) async throws
  func removeCaptureTracksIfEmpty(
    sessionID: SessionID,
    trackIDs: Set<TrackID>
  ) async throws
}

public protocol DictationTimelineEventRepositoryPort: Sendable {
  func save(timelineEvent: TimelineEvent) async throws
}

extension DictationJournalPort {
  public func resumeAfterRecoverableStop(sessionID: SessionID) async throws {}
}

/// Read-only access to source chunks that have already crossed the journal's
/// durable commit boundary. Implementations must never expose a block still
/// being written.
public protocol DictationCommittedAudioPort: Sendable {
  func committedAudioSnapshot(
    sessionID: SessionID
  ) async throws -> [AudioRangeInput]
}

/// Called only after a captured chunk has been durably appended. The observer
/// must return promptly and keep inference work outside capture ownership.
public protocol DictationCommittedChunkObserver: Sendable {
  func didCommit(
    sessionID: SessionID,
    chunk: CapturedPCMChunk
  ) async
  func didReachBoundary(
    sessionID: SessionID,
    kind: TranscriptRevisionKind
  ) async
  func didResume(sessionID: SessionID) async
}

extension DictationCommittedChunkObserver {
  public func didResume(sessionID: SessionID) async {}
}

public struct DictationJournalRecoveryStatus: Codable, Equatable, Sendable {
  public let committedChunkCount: Int
  public let issueCount: Int
  public let sealed: Bool

  public init(committedChunkCount: Int, issueCount: Int, sealed: Bool) {
    self.committedChunkCount = committedChunkCount
    self.issueCount = issueCount
    self.sealed = sealed
  }
}

public enum InsertionReservation: String, Codable, Sendable {
  case acquired
  case alreadyCompleted
  case alreadyReserved
}

public protocol DictationRepositoryPort: Sendable {
  func create(_ snapshot: DictationSessionSnapshot) async throws
  func save(_ snapshot: DictationSessionSnapshot) async throws
  func load(sessionID: SessionID) async throws -> DictationSessionSnapshot?
  func loadRecoverable() async throws -> [DictationSessionSnapshot]
  func reserveInsertion(
    sessionID: SessionID,
    key: DictationIdempotencyKey
  ) async throws -> InsertionReservation
  func completeInsertion(
    sessionID: SessionID,
    result: DictationInsertionResult
  ) async throws
  func insertionResult(sessionID: SessionID) async throws
    -> DictationInsertionResult?
  func cancelEphemeral(sessionID: SessionID) async throws
}

public protocol SessionModeDictationRepositoryPort: DictationRepositoryPort {
  func create(
    _ snapshot: DictationSessionSnapshot,
    inputMode: SessionInputMode
  ) async throws
  /// Records that a dictation was delivered as 翻译 or 指令. Known only at
  /// delivery, because the chord that sets the mode follows the key press
  /// that created the session.
  func recordSpokenMode(sessionID: SessionID, mode: String) async throws
}

/// The live capture path's explicit grant: a session the user just started
/// (a dictation, a recording, or an in-app media import) may be sent to the
/// own-device organizer if the link is enabled right now. Creating a session
/// never grants it by itself, so bulk writers such as a history importer can
/// never make rows sendable.
public protocol LiveCaptureRemoteEligibilityPort: Sendable {
  func markLiveCaptureRemoteEligible(sessionID: SessionID) async throws
}

public protocol DictationCaptureTrackRepositoryPort: Sendable {
  func saveCaptureTracks(
    sessionID: SessionID,
    tracks: [CaptureTrackDescriptor]
  ) async throws
  func removeCaptureTracksIfUnused(
    sessionID: SessionID,
    trackIDs: Set<TrackID>
  ) async throws
}

extension DictationCaptureTrackRepositoryPort {
  public func removeCaptureTracksIfUnused(
    sessionID: SessionID,
    trackIDs: Set<TrackID>
  ) async throws {}
}

public struct DictationRecognitionCommit: Codable, Equatable, Sendable {
  public let snapshot: DictationSessionSnapshot
  public let transcript: DictationTranscriptResult
  public let inputRevision: UInt64
  public let configHash: SHA256Digest
  public let createdAt: Date

  public init(
    snapshot: DictationSessionSnapshot,
    transcript: DictationTranscriptResult,
    inputRevision: UInt64,
    configHash: SHA256Digest,
    createdAt: Date
  ) {
    self.snapshot = snapshot
    self.transcript = transcript
    self.inputRevision = inputRevision
    self.configHash = configHash
    self.createdAt = createdAt
  }
}

public struct DictationTranscriptRevisionCommit: Codable, Equatable, Sendable {
  public let sessionID: SessionID
  public let transcript: DictationTranscriptResult
  public let inputRevision: UInt64
  public let configHash: SHA256Digest
  public let createdAt: Date

  public init(
    sessionID: SessionID,
    transcript: DictationTranscriptResult,
    inputRevision: UInt64,
    configHash: SHA256Digest,
    createdAt: Date
  ) {
    self.sessionID = sessionID
    self.transcript = transcript
    self.inputRevision = inputRevision
    self.configHash = configHash
    self.createdAt = createdAt
  }
}

public protocol DictationTranscriptRevisionRepositoryPort: Sendable {
  func commitTranscriptRevision(
    _ commit: DictationTranscriptRevisionCommit
  ) async throws
}

public struct DictationPolishCommit: Codable, Equatable, Sendable {
  public let derivationID: UUID
  public let snapshot: DictationSessionSnapshot
  public let polish: DictationPolishResult
  public let sourceRevision: UInt64
  public let configHash: SHA256Digest
  public let createdAt: Date

  public init(
    derivationID: UUID,
    snapshot: DictationSessionSnapshot,
    polish: DictationPolishResult,
    sourceRevision: UInt64,
    configHash: SHA256Digest,
    createdAt: Date
  ) {
    self.derivationID = derivationID
    self.snapshot = snapshot
    self.polish = polish
    self.sourceRevision = sourceRevision
    self.configHash = configHash
    self.createdAt = createdAt
  }
}

public struct DictationInsertionCommit: Codable, Equatable, Sendable {
  public let snapshot: DictationSessionSnapshot
  public let result: DictationInsertionResult

  public init(
    snapshot: DictationSessionSnapshot,
    result: DictationInsertionResult
  ) {
    self.snapshot = snapshot
    self.result = result
  }
}

/// Atomic processing commits keep immutable evidence and lifecycle state in
/// lockstep. Implementations must treat an identical replay as a no-op and
/// reject a conflicting replay.
public protocol DictationProcessingRepositoryPort: DictationRepositoryPort {
  func commitRecognition(_ commit: DictationRecognitionCommit) async throws
  func commitPolish(_ commit: DictationPolishCommit) async throws
  func commitInsertion(_ commit: DictationInsertionCommit) async throws
}

public struct DictationASRRequest: Codable, Equatable, Sendable {
  public let sessionID: SessionID
  public let inputRevision: UInt64
  public let audio: [AudioRangeInput]
  public let dictionaryTerms: [String]
  public let dictionaryHints: [ASRDictionaryHint]

  public init(
    sessionID: SessionID,
    inputRevision: UInt64,
    audio: [AudioRangeInput],
    dictionaryTerms: [String]
  ) {
    self.init(
      sessionID: sessionID,
      inputRevision: inputRevision,
      audio: audio,
      dictionaryTerms: dictionaryTerms,
      dictionaryHints: []
    )
  }

  public init(
    sessionID: SessionID,
    inputRevision: UInt64,
    audio: [AudioRangeInput],
    dictionaryTerms: [String],
    dictionaryHints: [ASRDictionaryHint]
  ) {
    self.sessionID = sessionID
    self.inputRevision = inputRevision
    self.audio = audio
    self.dictionaryTerms = dictionaryTerms
    self.dictionaryHints = dictionaryHints
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID
    case inputRevision
    case audio
    case dictionaryTerms
    case dictionaryHints
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
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionID, forKey: .sessionID)
    try container.encode(inputRevision, forKey: .inputRevision)
    try container.encode(audio, forKey: .audio)
    try container.encode(dictionaryTerms, forKey: .dictionaryTerms)
    try container.encode(dictionaryHints, forKey: .dictionaryHints)
  }
}

extension DictionaryContextProjection {
  /// Preserve the canonical-to-spoken mapping across the dictation/inference
  /// protocol boundary instead of flattening it into canonical strings.
  public var asrDictionaryHints: [ASRDictionaryHint] {
    entries.map {
      ASRDictionaryHint(
        canonicalForm: $0.canonicalForm,
        spokenForms: $0.spokenForms
      )
    }
  }
}

public protocol DictationASRPort: Sendable {
  func recognize(_ request: DictationASRRequest) async throws
    -> DictationTranscriptResult
}

public struct VersionedDictationASRRequest: Codable, Equatable, Sendable {
  public let request: DictationASRRequest
  public let mode: ASRMode
  public let languageHints: [String]
  public let supersedesRevisionID: TranscriptRevisionID?

  public init(
    request: DictationASRRequest,
    mode: ASRMode,
    languageHints: [String],
    supersedesRevisionID: TranscriptRevisionID?
  ) {
    self.request = request
    self.mode = mode
    self.languageHints = languageHints
    self.supersedesRevisionID = supersedesRevisionID
  }
}

public protocol VersionedDictationASRPort: DictationASRPort {
  func recognize(_ request: VersionedDictationASRRequest) async throws
    -> DictationTranscriptResult
}

/// Produces bounded, content-addressed inference derivatives while retaining
/// the immutable source ranges. Implementations must be idempotent.
public protocol DictationInferenceAudioPort: Sendable {
  func prepareInferenceAudio(
    sessionID: SessionID,
    sourceAudio: [AudioRangeInput]
  ) async throws -> [AudioRangeInput]

  /// Releases a previously prepared derivative once the inference consumer
  /// has finished reading it. Source audio is never affected. Implementations
  /// that materialize disposable files should make this idempotent.
  func discardInferenceAudio(
    sessionID: SessionID,
    preparedAudio: [AudioRangeInput]
  ) async
}

extension DictationInferenceAudioPort {
  public func discardInferenceAudio(
    sessionID _: SessionID,
    preparedAudio _: [AudioRangeInput]
  ) async {}
}

public struct DictationPolishRequest: Codable, Equatable, Sendable {
  public let sessionID: SessionID
  public let transcript: DictationTranscriptResult
  public let dictionaryTerms: [String]
  public let targetBundleIdentifier: String?

  public init(
    sessionID: SessionID,
    transcript: DictationTranscriptResult,
    dictionaryTerms: [String],
    targetBundleIdentifier: String?
  ) {
    self.sessionID = sessionID
    self.transcript = transcript
    self.dictionaryTerms = dictionaryTerms
    self.targetBundleIdentifier = targetBundleIdentifier
  }
}

public protocol DictationPolishPort: Sendable {
  func polish(_ request: DictationPolishRequest) async throws
    -> DictationPolishResult
}

public struct DictationInsertionRequest: Codable, Equatable, Sendable {
  public let sessionID: SessionID
  /// Where the caret was when the dictation started. Only a hint: the text is
  /// delivered wherever the caret is when it finishes, because a dictation may
  /// begin anywhere and be aimed at its field on the way. Nil when nothing
  /// focusable was in front at the start, which is itself an ordinary case.
  public let target: DictationTargetSnapshot?
  public let text: String
  public let idempotencyKey: DictationIdempotencyKey

  public init(
    sessionID: SessionID,
    target: DictationTargetSnapshot?,
    text: String,
    idempotencyKey: DictationIdempotencyKey
  ) {
    self.sessionID = sessionID
    self.target = target
    self.text = text
    self.idempotencyKey = idempotencyKey
  }
}

public protocol DictationInsertionPort: Sendable {
  func captureTarget() async throws -> DictationTargetSnapshot
  func insert(_ request: DictationInsertionRequest) async throws
    -> DictationInsertionResult
}

public protocol DictationPermissionPort: Sendable {
  func state(for permission: DictationPermissionKind) async -> DictationPermissionState
  func request(_ permission: DictationPermissionKind) async
    -> DictationPermissionState
  func openRecoverySettings(for permission: DictationPermissionKind) async
}

public protocol DictationSpeakerSchedulingPort: Sendable {
  func scheduleFinalSpeakerWork(
    sessionID: SessionID,
    audio: [AudioRangeInput],
    inputRevision: UInt64
  ) async throws
}

public protocol DictationClock: Sendable {
  func wallTime() -> Date
  func monotonicNanoseconds() -> UInt64
}

public struct SystemDictationClock: DictationClock {
  public init() {}

  public func wallTime() -> Date { Date() }

  public func monotonicNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }
}

public protocol DictationDiagnosticSink: Sendable {
  func record(_ event: DictationDiagnosticEvent) async
}

public struct NoopDictationDiagnosticSink: DictationDiagnosticSink {
  public init() {}
  public func record(_ event: DictationDiagnosticEvent) async {}
}
