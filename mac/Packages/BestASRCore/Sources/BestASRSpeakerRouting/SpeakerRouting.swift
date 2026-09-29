import BestASRDomain
import Foundation

public struct SpeakerRoutingPolicy: Codable, Equatable, Sendable {
  public let minimumSpeechNanoseconds: UInt64
  public let minimumSignalQuality: Confidence
  public let candidateThreshold: Confidence
  public let automaticMatchThreshold: Confidence

  public init(
    minimumSpeechNanoseconds: UInt64,
    minimumSignalQuality: Confidence,
    candidateThreshold: Confidence,
    automaticMatchThreshold: Confidence
  ) {
    self.minimumSpeechNanoseconds = minimumSpeechNanoseconds
    self.minimumSignalQuality = minimumSignalQuality
    self.candidateThreshold = candidateThreshold
    self.automaticMatchThreshold = automaticMatchThreshold
  }

  public static func contractProbe() throws -> Self {
    Self(
      minimumSpeechNanoseconds: 500_000_000,
      minimumSignalQuality: try Confidence(0.70),
      candidateThreshold: try Confidence(0.75),
      automaticMatchThreshold: try Confidence(0.93)
    )
  }

  /// The thresholds the App runs on, measured against the speaker model's own
  /// embeddings on this user's recordings (200 sessions, 2026-09-21).
  ///
  /// Two voices in that library sit at cosine 0.11–0.17 from each other, while
  /// one voice recorded across seven months, several rooms and two microphones
  /// stays at 0.79–0.83 with itself. Matching incrementally the way the App
  /// does, the outcome by threshold was:
  ///
  ///     0.93 -> 176 people, and the second voice still landed in the largest
  ///             group, because at that threshold every group is a fragment
  ///     0.80 ->  50 people
  ///     0.70 ->  15 people, second voice separate
  ///     0.65 ->  10 people, second voice separate
  ///     0.60 ->   6 people, second voice absorbed
  ///
  /// 0.93 was never reachable by this model, so almost nothing matched
  /// automatically and every session became a candidate waiting for a
  /// confirmation that never came. 0.70 is the band's safe end: it holds a
  /// 0.10 margin above where the two voices start merging, and splitting one
  /// person in two is the cheaper mistake — attributing someone else's words
  /// to you is not something the user would think to check.
  public static func local() throws -> Self {
    Self(
      minimumSpeechNanoseconds: 500_000_000,
      minimumSignalQuality: try Confidence(0.70),
      candidateThreshold: try Confidence(0.55),
      automaticMatchThreshold: try Confidence(0.70)
    )
  }
}

public struct PersonMatchEvidence: Codable, Equatable, Sendable {
  public let personID: PersonID
  public let confidence: Confidence

  public init(personID: PersonID, confidence: Confidence) {
    self.personID = personID
    self.confidence = confidence
  }
}

public struct SpeakerTurnEvidence: Codable, Equatable, Sendable {
  public let occurrenceID: SpeakerOccurrenceID
  public let trackIDs: [TrackID]
  public let monotonicStartNanoseconds: UInt64
  public let monotonicEndNanoseconds: UInt64
  public let overlapsAnotherSpeaker: Bool
  public let isBackgroundSpeech: Bool
  public let signalQuality: Confidence
  public let personMatch: PersonMatchEvidence?

  public init(
    occurrenceID: SpeakerOccurrenceID,
    trackIDs: [TrackID],
    monotonicStartNanoseconds: UInt64,
    monotonicEndNanoseconds: UInt64,
    overlapsAnotherSpeaker: Bool,
    isBackgroundSpeech: Bool,
    signalQuality: Confidence,
    personMatch: PersonMatchEvidence?
  ) {
    self.occurrenceID = occurrenceID
    self.trackIDs = trackIDs
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.monotonicEndNanoseconds = monotonicEndNanoseconds
    self.overlapsAnotherSpeaker = overlapsAnotherSpeaker
    self.isBackgroundSpeech = isBackgroundSpeech
    self.signalQuality = signalQuality
    self.personMatch = personMatch
  }
}

public struct SpeakerClusterEvidence: Codable, Equatable, Sendable {
  public let sessionSpeakerID: SessionSpeakerID
  public let stableOrdinal: UInt32
  public let turns: [SpeakerTurnEvidence]

  public init(
    sessionSpeakerID: SessionSpeakerID,
    stableOrdinal: UInt32,
    turns: [SpeakerTurnEvidence]
  ) {
    self.sessionSpeakerID = sessionSpeakerID
    self.stableOrdinal = stableOrdinal
    self.turns = turns
  }
}

public struct SpeakerRoutingRequest: Codable, Equatable, Sendable {
  public let session: Session
  public let tracks: [SourceTrack]
  public let evidenceRevision: Revision
  public let clusters: [SpeakerClusterEvidence]

  public init(
    session: Session,
    tracks: [SourceTrack],
    evidenceRevision: Revision,
    clusters: [SpeakerClusterEvidence]
  ) {
    self.session = session
    self.tracks = tracks
    self.evidenceRevision = evidenceRevision
    self.clusters = clusters
  }
}

public enum SpeakerRoutingError: Error, Equatable, Sendable {
  case duplicateOccurrenceID(SpeakerOccurrenceID)
  case duplicateSessionSpeakerID(SessionSpeakerID)
  case duplicateStableOrdinal(UInt32)
  case duplicateTrackID(TrackID)
  case emptyCluster(SessionSpeakerID)
  case invalidTurnRange(SpeakerOccurrenceID)
  case sourceRoleNotAllowed(SessionInputMode, SourceTrackRole)
  case trackBelongsToDifferentSession(TrackID)
  case turnHasNoTrack(SpeakerOccurrenceID)
  case unknownTrack(TrackID)
}

public struct SpeakerHistorySnapshot: Codable, Equatable, Sendable {
  public let sessionID: SessionID
  public let inputMode: SessionInputMode
  public let sessionSpeakers: [SessionSpeaker]
  public let occurrences: [SpeakerOccurrence]
  public let referencedPersonIDs: [PersonID]

  public init(
    sessionID: SessionID,
    inputMode: SessionInputMode,
    sessionSpeakers: [SessionSpeaker],
    occurrences: [SpeakerOccurrence],
    referencedPersonIDs: [PersonID]
  ) {
    self.sessionID = sessionID
    self.inputMode = inputMode
    self.sessionSpeakers = sessionSpeakers
    self.occurrences = occurrences
    self.referencedPersonIDs = referencedPersonIDs
  }
}

public struct SpeakerRoutingResult: Codable, Equatable, Sendable {
  public let sessionID: SessionID
  public let inputMode: SessionInputMode
  public let sessionSpeakers: [SessionSpeaker]
  public let occurrences: [SpeakerOccurrence]

  public init(
    sessionID: SessionID,
    inputMode: SessionInputMode,
    sessionSpeakers: [SessionSpeaker],
    occurrences: [SpeakerOccurrence]
  ) {
    self.sessionID = sessionID
    self.inputMode = inputMode
    self.sessionSpeakers = sessionSpeakers
    self.occurrences = occurrences
  }

  public var history: SpeakerHistorySnapshot {
    let personIDs = Set(occurrences.compactMap(\.association.personID))
      .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    return SpeakerHistorySnapshot(
      sessionID: sessionID,
      inputMode: inputMode,
      sessionSpeakers: sessionSpeakers,
      occurrences: occurrences,
      referencedPersonIDs: personIDs
    )
  }
}

public enum UnifiedSpeakerRouter {
  public static func route(
    _ request: SpeakerRoutingRequest,
    policy: SpeakerRoutingPolicy
  ) throws -> SpeakerRoutingResult {
    try validate(request)

    let sortedClusters = request.clusters.sorted {
      if $0.stableOrdinal == $1.stableOrdinal {
        return $0.sessionSpeakerID.rawValue.uuidString
          < $1.sessionSpeakerID.rawValue.uuidString
      }
      return $0.stableOrdinal < $1.stableOrdinal
    }
    let sessionSpeakers = sortedClusters.map {
      SessionSpeaker(
        id: $0.sessionSpeakerID,
        sessionID: request.session.id,
        revision: request.evidenceRevision,
        stableOrdinal: $0.stableOrdinal
      )
    }
    let occurrences = try sortedClusters.flatMap { cluster in
      try cluster.turns.map { turn in
        SpeakerOccurrence(
          id: turn.occurrenceID,
          sessionID: request.session.id,
          sessionSpeakerID: cluster.sessionSpeakerID,
          revision: request.evidenceRevision,
          trackIDs: turn.trackIDs,
          monotonicStartNanoseconds: turn.monotonicStartNanoseconds,
          monotonicEndNanoseconds: turn.monotonicEndNanoseconds,
          overlapsAnotherSpeaker: turn.overlapsAnotherSpeaker,
          association: try association(
            for: turn,
            revision: request.evidenceRevision,
            policy: policy
          )
        )
      }
    }.sorted {
      if $0.monotonicStartNanoseconds == $1.monotonicStartNanoseconds {
        return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
      }
      return $0.monotonicStartNanoseconds < $1.monotonicStartNanoseconds
    }

    return SpeakerRoutingResult(
      sessionID: request.session.id,
      inputMode: request.session.inputMode,
      sessionSpeakers: sessionSpeakers,
      occurrences: occurrences
    )
  }

  private static func association(
    for turn: SpeakerTurnEvidence,
    revision: Revision,
    policy: SpeakerRoutingPolicy
  ) throws -> PersonAssociation {
    let duration = turn.monotonicEndNanoseconds - turn.monotonicStartNanoseconds
    let evidenceIsSufficient =
      duration >= policy.minimumSpeechNanoseconds
      && !turn.overlapsAnotherSpeaker
      && !turn.isBackgroundSpeech
      && turn.signalQuality >= policy.minimumSignalQuality
    guard evidenceIsSufficient, let match = turn.personMatch else {
      return try PersonAssociation(
        status: .unknown,
        personID: nil,
        confidence: nil,
        evidenceRevision: revision
      )
    }
    if match.confidence >= policy.automaticMatchThreshold {
      return try PersonAssociation(
        status: .automaticMatch,
        personID: match.personID,
        confidence: match.confidence,
        evidenceRevision: revision
      )
    }
    if match.confidence >= policy.candidateThreshold {
      return try PersonAssociation(
        status: .candidate,
        personID: match.personID,
        confidence: match.confidence,
        evidenceRevision: revision
      )
    }
    return try PersonAssociation(
      status: .unknown,
      personID: nil,
      confidence: nil,
      evidenceRevision: revision
    )
  }

  private static func validate(_ request: SpeakerRoutingRequest) throws {
    var trackIDs = Set<TrackID>()
    let allowedRoles = allowedTrackRoles(for: request.session.inputMode)
    for track in request.tracks {
      guard track.sessionID == request.session.id else {
        throw SpeakerRoutingError.trackBelongsToDifferentSession(track.id)
      }
      guard trackIDs.insert(track.id).inserted else {
        throw SpeakerRoutingError.duplicateTrackID(track.id)
      }
      guard allowedRoles.contains(track.role) else {
        throw SpeakerRoutingError.sourceRoleNotAllowed(
          request.session.inputMode,
          track.role
        )
      }
    }

    var sessionSpeakerIDs = Set<SessionSpeakerID>()
    var stableOrdinals = Set<UInt32>()
    var occurrenceIDs = Set<SpeakerOccurrenceID>()
    for cluster in request.clusters {
      guard sessionSpeakerIDs.insert(cluster.sessionSpeakerID).inserted else {
        throw SpeakerRoutingError.duplicateSessionSpeakerID(cluster.sessionSpeakerID)
      }
      guard stableOrdinals.insert(cluster.stableOrdinal).inserted else {
        throw SpeakerRoutingError.duplicateStableOrdinal(cluster.stableOrdinal)
      }
      guard !cluster.turns.isEmpty else {
        throw SpeakerRoutingError.emptyCluster(cluster.sessionSpeakerID)
      }
      for turn in cluster.turns {
        guard occurrenceIDs.insert(turn.occurrenceID).inserted else {
          throw SpeakerRoutingError.duplicateOccurrenceID(turn.occurrenceID)
        }
        guard turn.monotonicStartNanoseconds < turn.monotonicEndNanoseconds else {
          throw SpeakerRoutingError.invalidTurnRange(turn.occurrenceID)
        }
        guard !turn.trackIDs.isEmpty else {
          throw SpeakerRoutingError.turnHasNoTrack(turn.occurrenceID)
        }
        for trackID in turn.trackIDs where !trackIDs.contains(trackID) {
          throw SpeakerRoutingError.unknownTrack(trackID)
        }
      }
    }
  }

  private static func allowedTrackRoles(
    for mode: SessionInputMode
  ) -> Set<SourceTrackRole> {
    switch mode {
    case .dictation:
      return [.microphoneLocal]
    case .importedMedia:
      return [.importedSource]
    case .roomMicrophone:
      return [.roomMicrophone]
    case .systemAudio:
      return [.microphoneLocal, .systemRemote]
    case .userItem:
      // A pasted or dragged item has no audio track to route.
      return []
    }
  }
}
