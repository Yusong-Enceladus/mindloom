import BestASRDomain
import BestASRInference
import Foundation

public enum DictationValidationError: Error, Equatable, Sendable {
  case emptyIdentifier
  case invalidIdentifier
  case invalidRange
  case invalidTransition(from: DictationPhase, action: String)
}

public enum DictationPhase: String, Codable, CaseIterable, Sendable {
  case idle
  case preparing
  case recording
  case paused
  case finalizing
  case recognizing
  case polishing
  case inserting
  case completed
  case cancelling
  case cancelled
  case failedRecoverable

  public var isActive: Bool {
    switch self {
    case .preparing, .recording, .paused, .finalizing, .recognizing,
      .polishing, .inserting, .cancelling:
      return true
    case .idle, .completed, .cancelled, .failedRecoverable:
      return false
    }
  }
}

public enum DictationProcessingStage: String, Codable, Sendable {
  case capture
  case journal
  case recognition
  case polish
  case insertion
  case speaker
  case persistence
}

public struct DictationIdempotencyKey: Codable, Hashable, Sendable {
  public let value: String

  public init(_ value: String) throws {
    guard !value.isEmpty else { throw DictationValidationError.emptyIdentifier }
    guard value.count <= 512,
      value.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil
    else {
      throw DictationValidationError.invalidIdentifier
    }
    self.value = value
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

/// The application a dictation is aimed at: the one in front when the key
/// went down. Delivery is a keystroke to that process, so nothing about the
/// focused element is recorded — the process knows where its focus is
/// better than any snapshot of it. `isSecure` is secure keyboard entry at
/// that moment: a password field, into which nothing is ever sent.
public struct DictationTargetSnapshot: Codable, Equatable, Sendable {
  public let processIdentifier: Int32
  public let bundleIdentifier: String?
  public let isSecure: Bool

  public init(processIdentifier: Int32, bundleIdentifier: String?, isSecure: Bool) {
    self.processIdentifier = processIdentifier
    self.bundleIdentifier = bundleIdentifier
    self.isSecure = isSecure
  }

  private enum CodingKeys: String, CodingKey {
    case processIdentifier, bundleIdentifier, isSecure
  }
}

public enum DictationTimelineMarkerKind: String, Codable, Sendable {
  case started
  case paused
  case resumed
  case endRequested
  case cancelRequested
}

public struct DictationTimelineMarker: Codable, Equatable, Sendable {
  public let kind: DictationTimelineMarkerKind
  public let monotonicNanoseconds: UInt64

  public init(kind: DictationTimelineMarkerKind, monotonicNanoseconds: UInt64) {
    self.kind = kind
    self.monotonicNanoseconds = monotonicNanoseconds
  }
}

public enum DictationFailureCategory: String, Codable, Sendable {
  case cancelled
  case conflict
  case corruptInput
  case diskPressure
  case invalidState
  case modelUnavailable
  case permissionDenied
  case resourcePressure
  case targetUnavailable
  case transientRuntime
  case unknown
}

public struct DictationFailure: Codable, Equatable, Sendable {
  public let stage: DictationProcessingStage
  public let category: DictationFailureCategory
  public let code: String
  public let retryable: Bool
  public let recoveryPhase: DictationPhase

  /// Audio that held no speech — the commonest way a dictation ends with
  /// nothing to show, from a key tapped without speaking. It is a finished
  /// take, not a breakage, and every surface that names it says so rather
  /// than reporting a failure the user cannot act on.
  public static func isSilentTake(code: String?) -> Bool {
    code?.hasSuffix("no-speech-detected") == true
  }

  public var isSilentTake: Bool { Self.isSilentTake(code: code) }

  public init(
    stage: DictationProcessingStage,
    category: DictationFailureCategory,
    code: String,
    retryable: Bool,
    recoveryPhase: DictationPhase
  ) throws {
    guard !code.isEmpty, code.count <= 128,
      code.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil
    else {
      throw DictationValidationError.invalidIdentifier
    }
    guard recoveryPhase.isActive, recoveryPhase != .cancelling else {
      throw DictationValidationError.invalidTransition(
        from: .failedRecoverable,
        action: "recover-to-\(recoveryPhase.rawValue)"
      )
    }
    self.stage = stage
    self.category = category
    self.code = code
    self.retryable = retryable
    self.recoveryPhase = recoveryPhase
  }
}

public struct DictationTranscriptSegment: Codable, Equatable, Sendable {
  public let id: UUID
  public let monotonicStartNanoseconds: UInt64
  public let monotonicEndNanoseconds: UInt64
  public let text: String
  public let confidence: Double?

  public init(
    id: UUID,
    monotonicStartNanoseconds: UInt64,
    monotonicEndNanoseconds: UInt64,
    text: String,
    confidence: Double?
  ) {
    self.id = id
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.monotonicEndNanoseconds = monotonicEndNanoseconds
    self.text = text
    self.confidence = confidence
  }
}

public struct DictationTranscriptProvenance: Codable, Equatable, Sendable {
  public let parentRevisionID: TranscriptRevisionID?
  public let kind: TranscriptRevisionKind
  public let languageHints: [String]
  public let audioRanges: [AudioRangeInput]
  public let segments: [DictationTranscriptSegment]

  public init(
    parentRevisionID: TranscriptRevisionID?,
    kind: TranscriptRevisionKind,
    languageHints: [String],
    audioRanges: [AudioRangeInput],
    segments: [DictationTranscriptSegment]
  ) {
    self.parentRevisionID = parentRevisionID
    self.kind = kind
    self.languageHints = languageHints
    self.audioRanges = audioRanges
    self.segments = segments
  }
}

public struct DictationTranscriptResult: Codable, Equatable, Sendable {
  public let revisionID: TranscriptRevisionID
  public let segmentIDs: [UUID]
  public let text: String
  public let modelArtifactID: String
  public let provenance: DictationTranscriptProvenance?

  public init(
    revisionID: TranscriptRevisionID,
    segmentIDs: [UUID],
    text: String,
    modelArtifactID: String,
    provenance: DictationTranscriptProvenance? = nil
  ) {
    self.revisionID = revisionID
    self.segmentIDs = segmentIDs
    self.text = text
    self.modelArtifactID = modelArtifactID
    self.provenance = provenance
  }
}

public enum DictationPolishDisposition: String, Codable, Sendable {
  case model
  case punctuationOnlyFallback
  case rawTranscriptFallback
}

public struct DictationPolishResult: Codable, Equatable, Sendable {
  public let sourceRevisionID: TranscriptRevisionID
  public let text: String
  public let disposition: DictationPolishDisposition
  public let modelArtifactID: String?

  public init(
    sourceRevisionID: TranscriptRevisionID,
    text: String,
    disposition: DictationPolishDisposition,
    modelArtifactID: String?
  ) {
    self.sourceRevisionID = sourceRevisionID
    self.text = text
    self.disposition = disposition
    self.modelArtifactID = modelArtifactID
  }
}

public enum DictationInsertionMethod: String, Codable, Sendable {
  /// Historical: written by builds that wrote through accessibility. Kept
  /// so those rows still decode; nothing produces it now.
  case accessibilityReplacement
  case clipboardPaste
  case retainedForCopy
}

/// Why text was kept for copying instead of delivered. Every case is an
/// observation, not an inference.
public enum DictationInsertionFailureReason: String, Codable, Sendable {
  /// ⌘V was sent and the application never asked for the text: no field
  /// had the keyboard.
  case nowhere
  /// A password field had the keyboard. Nothing was sent.
  case secureInput
  /// A different application was in front by the time the words were ready.
  case applicationChanged
  /// The system does not let this app post keystrokes.
  case permissionDenied
  /// The dictation produced nothing to insert: what it produced was shown
  /// instead (an instruction whose answer is read, not written).
  case nothingToInsert
  /// The engine that was to produce the text could not.
  case unavailable
  /// Two insertions of the same dictation raced; the second stood down.
  case ambiguousReservation
}

extension DictationInsertionFailureReason {
  /// Whether keeping the text was the designed answer rather than a failure.
  /// A dictation aimed at nowhere, or interrupted by switching apps, is the
  /// system doing its job; an engine that could not produce text is not.
  public var declinedByDesign: Bool {
    switch self {
    case .nowhere, .secureInput, .applicationChanged, .permissionDenied, .nothingToInsert:
      true
    case .unavailable, .ambiguousReservation:
      false
    }
  }
}

public struct DictationInsertionResult: Codable, Equatable, Sendable {
  public let idempotencyKey: DictationIdempotencyKey
  public let method: DictationInsertionMethod
  public let inserted: Bool
  public let failureReason: DictationInsertionFailureReason?
  /// What showed an inserted result landed: "pasteboard" or "field". Nil on
  /// rows written before delivery was observed rather than inferred.
  public let evidence: String?

  public init(
    idempotencyKey: DictationIdempotencyKey,
    method: DictationInsertionMethod,
    inserted: Bool,
    failureReason: DictationInsertionFailureReason? = nil,
    evidence: String? = nil
  ) {
    self.idempotencyKey = idempotencyKey
    self.method = method
    self.inserted = inserted
    self.failureReason = failureReason
    self.evidence = evidence
  }

  private enum CodingKeys: String, CodingKey {
    case idempotencyKey, method, inserted, failureReason, evidence
  }

  /// Rows written before this vocabulary carry reasons it no longer has;
  /// they decode with no reason rather than failing the whole history.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    idempotencyKey = try container.decode(DictationIdempotencyKey.self, forKey: .idempotencyKey)
    method = try container.decode(DictationInsertionMethod.self, forKey: .method)
    inserted = try container.decode(Bool.self, forKey: .inserted)
    failureReason = (try? container.decodeIfPresent(String.self, forKey: .failureReason))
      .flatMap { $0 }
      .flatMap(DictationInsertionFailureReason.init(rawValue:))
    evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
  }
}

public enum DictationCommand: Codable, Equatable, Sendable {
  case start(sessionID: SessionID, target: DictationTargetSnapshot?)
  case pause
  case resume
  case end
  case cancel
  case retry
}

public enum DictationLifecycleEvent: Codable, Equatable, Sendable {
  case preparationSucceeded
  case journalSealed
  case recognitionSucceeded(DictationTranscriptResult)
  case polishSucceeded(DictationPolishResult)
  case polishFellBack(DictationPolishResult)
  case insertionCompleted(DictationInsertionResult)
  case cancellationCompleted
  case ambientSilence
  case failed(DictationFailure)
}

public struct DictationSessionSnapshot: Codable, Equatable, Sendable {
  public let sessionID: SessionID?
  public let revision: UInt64
  public let phase: DictationPhase
  public let target: DictationTargetSnapshot?
  public let timeline: [DictationTimelineMarker]
  public let transcript: DictationTranscriptResult?
  public let polish: DictationPolishResult?
  public let insertion: DictationInsertionResult?
  public let failure: DictationFailure?

  public init(
    sessionID: SessionID? = nil,
    revision: UInt64 = 0,
    phase: DictationPhase = .idle,
    target: DictationTargetSnapshot? = nil,
    timeline: [DictationTimelineMarker] = [],
    transcript: DictationTranscriptResult? = nil,
    polish: DictationPolishResult? = nil,
    insertion: DictationInsertionResult? = nil,
    failure: DictationFailure? = nil
  ) {
    self.sessionID = sessionID
    self.revision = revision
    self.phase = phase
    self.target = target
    self.timeline = timeline
    self.transcript = transcript
    self.polish = polish
    self.insertion = insertion
    self.failure = failure
  }

  public func validate() throws {
    if phase == .idle {
      guard sessionID == nil, revision == 0, target == nil,
        transcript == nil, polish == nil, insertion == nil, failure == nil
      else {
        throw DictationValidationError.invalidTransition(
          from: phase,
          action: "invalid-idle-snapshot"
        )
      }
      return
    }

    guard sessionID != nil, revision > 0 else {
      throw DictationValidationError.invalidTransition(
        from: phase,
        action: "missing-session-context"
      )
    }
    guard (phase == .failedRecoverable) == (failure != nil) else {
      throw DictationValidationError.invalidTransition(
        from: phase,
        action: "failure-state-mismatch"
      )
    }
    if let polish {
      guard polish.sourceRevisionID == transcript?.revisionID else {
        throw DictationValidationError.invalidTransition(
          from: phase,
          action: "polish-source-mismatch"
        )
      }
    }
    if insertion != nil {
      guard phase == .completed, polish != nil else {
        throw DictationValidationError.invalidTransition(
          from: phase,
          action: "insertion-state-mismatch"
        )
      }
    }
  }
}
