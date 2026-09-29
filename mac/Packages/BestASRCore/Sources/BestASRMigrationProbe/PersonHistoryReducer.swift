import BestASRDomain
import Foundation

public enum PersonHistoryReducerError: Error, Equatable, Sendable {
  case conflictingDuplicateChange(ChangeID)
  case conflictingDuplicateCorrection(PersonCorrectionID)
  case conflictingDuplicateTombstone(TombstoneID)
  case malformedPersonCorrectionChange(ChangeID)
  case personCorrectionRevisionMismatch(ChangeID)
  case personMergeCycle(PersonCorrectionID)
}

public enum PersonHistoryDecisionKind: String, Codable, Sendable {
  case change
  case tombstone
}

public struct PersonHistoryDecisionReference: Codable, Equatable, Sendable {
  public let revision: Revision
  public let occurredAt: Date
  public let kind: PersonHistoryDecisionKind
  public let stableID: UUID
}

public struct PersonAssignmentDecision: Equatable, Sendable {
  public let occurrenceID: SpeakerOccurrenceID
  public let personID: PersonID
  public let actor: PersonCorrectionActor
  public let operationID: PersonCorrectionID
  public let revision: Revision
}

public struct PersonNameDecision: Equatable, Sendable {
  public let personID: PersonID
  public let displayName: String
  public let actor: PersonCorrectionActor
  public let operationID: PersonCorrectionID
  public let revision: Revision
}

public struct PersonMergeDecision: Equatable, Sendable {
  public let mergedID: PersonID
  public let primaryID: PersonID
  public let actor: PersonCorrectionActor
  public let operationID: PersonCorrectionID
  public let revision: Revision
}

public struct OccurrenceCandidateKey: Equatable, Hashable, Sendable {
  public let occurrenceID: SpeakerOccurrenceID
  public let candidatePersonID: PersonID

  public init(
    occurrenceID: SpeakerOccurrenceID,
    candidatePersonID: PersonID
  ) {
    self.occurrenceID = occurrenceID
    self.candidatePersonID = candidatePersonID
  }
}

public struct PersonRejectionDecision: Equatable, Sendable {
  public let key: OccurrenceCandidateKey
  public let actor: PersonCorrectionActor
  public let operationID: PersonCorrectionID
  public let revision: Revision
}

public struct PersonHistoryState: Equatable, Sendable {
  public let occurrenceAssignments: [SpeakerOccurrenceID: PersonAssignmentDecision]
  public let personNames: [PersonID: PersonNameDecision]
  public let personMerges: [PersonID: PersonMergeDecision]
  public let rejectedCandidates: [OccurrenceCandidateKey: PersonRejectionDecision]
  public let latestTombstones: [DomainEntityReference: Tombstone]
  public let sourceAssetDeletionAuthorizations: Set<DomainEntityReference>
  public let appliedCorrectionIDs: Set<PersonCorrectionID>
  public let ignoredAutomaticCorrectionIDs: Set<PersonCorrectionID>
  public let decisionOrder: [PersonHistoryDecisionReference]

  public func canonicalPersonID(for personID: PersonID) -> PersonID {
    var current = personID
    var visited = Set<PersonID>()
    while visited.insert(current).inserted,
      let decision = personMerges[current]
    {
      current = decision.primaryID
    }
    return current
  }
}

public enum PersonHistoryReducer {
  public static func reduce(
    changeLog: [ChangeLogEntry],
    tombstones: [Tombstone]
  ) throws -> PersonHistoryState {
    let changes = try uniqueChanges(changeLog)
    let uniqueTombstones = try uniqueTombstones(tombstones)
    let events = orderedEvents(changes: changes, tombstones: uniqueTombstones)

    var working = WorkingState()
    var correctionByID: [PersonCorrectionID: PersonCorrectionOperation] = [:]

    for event in events {
      working.decisionOrder.append(event.reference)
      switch event.payload {
      case .change(let change):
        guard let correction = try correction(from: change) else {
          continue
        }
        if let existing = correctionByID[correction.id] {
          guard existing == correction else {
            throw PersonHistoryReducerError.conflictingDuplicateCorrection(
              correction.id
            )
          }
          continue
        }
        correctionByID[correction.id] = correction
        let applied = try apply(correction, to: &working)
        if applied {
          working.appliedCorrectionIDs.insert(correction.id)
        } else if correction.actor == .automatic {
          working.ignoredAutomaticCorrectionIDs.insert(correction.id)
        }
      case .tombstone(let tombstone):
        working.latestTombstones[tombstone.entity] = tombstone
        if tombstone.deletionScope == .explicitSourceAssetDeletion {
          working.sourceAssetDeletionAuthorizations.insert(tombstone.entity)
        }
      }
    }

    return PersonHistoryState(
      occurrenceAssignments: working.occurrenceAssignments,
      personNames: working.personNames,
      personMerges: working.personMerges,
      rejectedCandidates: working.rejectedCandidates,
      latestTombstones: working.latestTombstones,
      sourceAssetDeletionAuthorizations:
        working.sourceAssetDeletionAuthorizations,
      appliedCorrectionIDs: working.appliedCorrectionIDs,
      ignoredAutomaticCorrectionIDs:
        working.ignoredAutomaticCorrectionIDs,
      decisionOrder: working.decisionOrder
    )
  }

  private static func uniqueChanges(_ changes: [ChangeLogEntry]) throws
    -> [ChangeLogEntry]
  {
    var changesByID: [ChangeID: ChangeLogEntry] = [:]
    for change in changes {
      if let existing = changesByID[change.id] {
        guard existing == change else {
          throw PersonHistoryReducerError.conflictingDuplicateChange(change.id)
        }
      } else {
        changesByID[change.id] = change
      }
    }
    return Array(changesByID.values)
  }

  private static func uniqueTombstones(_ tombstones: [Tombstone]) throws
    -> [Tombstone]
  {
    var tombstonesByID: [TombstoneID: Tombstone] = [:]
    for tombstone in tombstones {
      if let existing = tombstonesByID[tombstone.id] {
        guard existing == tombstone else {
          throw PersonHistoryReducerError.conflictingDuplicateTombstone(
            tombstone.id
          )
        }
      } else {
        tombstonesByID[tombstone.id] = tombstone
      }
    }
    return Array(tombstonesByID.values)
  }

  private static func correction(from change: ChangeLogEntry) throws
    -> PersonCorrectionOperation?
  {
    if change.operation == .personCorrection {
      guard let correction = change.personCorrection else {
        throw PersonHistoryReducerError.malformedPersonCorrectionChange(
          change.id
        )
      }
      guard correction.revision == change.revision,
        correction.occurredAt == change.occurredAt
      else {
        throw PersonHistoryReducerError.personCorrectionRevisionMismatch(
          change.id
        )
      }
      return correction
    }
    guard change.personCorrection == nil else {
      throw PersonHistoryReducerError.malformedPersonCorrectionChange(
        change.id
      )
    }
    return nil
  }

  private static func apply(
    _ operation: PersonCorrectionOperation,
    to state: inout WorkingState
  ) throws -> Bool {
    switch operation.payload {
    case .confirm(let occurrenceID, let personID):
      let rejectionKey = OccurrenceCandidateKey(
        occurrenceID: occurrenceID,
        candidatePersonID: personID
      )
      if operation.actor == .automatic,
        state.rejectedCandidates[rejectionKey]?.actor == .user
      {
        return false
      }
      if operation.actor == .automatic,
        state.occurrenceAssignments[occurrenceID]?.actor == .user
      {
        return false
      }
      state.rejectedCandidates.removeValue(forKey: rejectionKey)
      state.occurrenceAssignments[occurrenceID] = PersonAssignmentDecision(
        occurrenceID: occurrenceID,
        personID: personID,
        actor: operation.actor,
        operationID: operation.id,
        revision: operation.revision
      )
      return true

    case .merge(let primaryID, let mergedID):
      if operation.actor == .automatic {
        if state.personMerges[mergedID]?.actor == .user {
          return false
        }
        let hasUserAssignment = state.occurrenceAssignments.values.contains {
          $0.actor == .user && $0.personID == mergedID
        }
        if hasUserAssignment {
          return false
        }
      }

      let resolvedPrimaryID = canonicalPersonID(
        for: primaryID,
        merges: state.personMerges
      )
      let resolvedMergedID = canonicalPersonID(
        for: mergedID,
        merges: state.personMerges
      )
      if resolvedPrimaryID == resolvedMergedID {
        return true
      }
      if canonicalPersonID(
        for: resolvedPrimaryID,
        merges: state.personMerges
      ) == mergedID {
        throw PersonHistoryReducerError.personMergeCycle(operation.id)
      }

      state.personMerges[mergedID] = PersonMergeDecision(
        mergedID: mergedID,
        primaryID: resolvedPrimaryID,
        actor: operation.actor,
        operationID: operation.id,
        revision: operation.revision
      )
      for occurrenceID in Array(state.occurrenceAssignments.keys) {
        guard let existing = state.occurrenceAssignments[occurrenceID],
          existing.personID == mergedID,
          operation.actor == .user || existing.actor != .user
        else {
          continue
        }
        state.occurrenceAssignments[occurrenceID] = PersonAssignmentDecision(
          occurrenceID: occurrenceID,
          personID: resolvedPrimaryID,
          actor: operation.actor,
          operationID: operation.id,
          revision: operation.revision
        )
      }
      return true

    case .reject(let occurrenceID, let candidatePersonID):
      let key = OccurrenceCandidateKey(
        occurrenceID: occurrenceID,
        candidatePersonID: candidatePersonID
      )
      if operation.actor == .automatic,
        state.occurrenceAssignments[occurrenceID]?.actor == .user
      {
        return false
      }
      if operation.actor == .automatic,
        state.rejectedCandidates[key]?.actor == .user
      {
        return false
      }
      state.rejectedCandidates[key] = PersonRejectionDecision(
        key: key,
        actor: operation.actor,
        operationID: operation.id,
        revision: operation.revision
      )
      if let assignment = state.occurrenceAssignments[occurrenceID],
        assignment.personID == candidatePersonID,
        operation.actor == .user || assignment.actor != .user
      {
        state.occurrenceAssignments.removeValue(forKey: occurrenceID)
      }
      return true

    case .rename(let personID, let displayName):
      if operation.actor == .automatic,
        state.personNames[personID]?.actor == .user
      {
        return false
      }
      state.personNames[personID] = PersonNameDecision(
        personID: personID,
        displayName: displayName,
        actor: operation.actor,
        operationID: operation.id,
        revision: operation.revision
      )
      return true

    case .split(_, let newPersonID, let occurrenceIDs):
      if operation.actor == .user
        || state.personMerges[newPersonID]?.actor != .user
      {
        state.personMerges.removeValue(forKey: newPersonID)
      }
      var applied = false
      for occurrenceID in Set(occurrenceIDs) {
        if operation.actor == .automatic,
          state.occurrenceAssignments[occurrenceID]?.actor == .user
        {
          continue
        }
        state.occurrenceAssignments[occurrenceID] = PersonAssignmentDecision(
          occurrenceID: occurrenceID,
          personID: newPersonID,
          actor: operation.actor,
          operationID: operation.id,
          revision: operation.revision
        )
        applied = true
      }
      return applied || occurrenceIDs.isEmpty
    }
  }

  private static func canonicalPersonID(
    for personID: PersonID,
    merges: [PersonID: PersonMergeDecision]
  ) -> PersonID {
    var current = personID
    var visited = Set<PersonID>()
    while visited.insert(current).inserted,
      let decision = merges[current]
    {
      current = decision.primaryID
    }
    return current
  }

  private static func orderedEvents(
    changes: [ChangeLogEntry],
    tombstones: [Tombstone]
  ) -> [OrderedEvent] {
    let changeEvents = changes.map {
      OrderedEvent(
        reference: PersonHistoryDecisionReference(
          revision: $0.revision,
          occurredAt: $0.occurredAt,
          kind: .change,
          stableID: $0.id.rawValue
        ),
        payload: .change($0)
      )
    }
    let tombstoneEvents = tombstones.map {
      OrderedEvent(
        reference: PersonHistoryDecisionReference(
          revision: $0.revision,
          occurredAt: $0.deletedAt,
          kind: .tombstone,
          stableID: $0.id.rawValue
        ),
        payload: .tombstone($0)
      )
    }
    return (changeEvents + tombstoneEvents).sorted(by: orderedBefore)
  }

  private static func orderedBefore(_ lhs: OrderedEvent, _ rhs: OrderedEvent)
    -> Bool
  {
    if lhs.reference.revision != rhs.reference.revision {
      return lhs.reference.revision < rhs.reference.revision
    }
    if lhs.reference.occurredAt != rhs.reference.occurredAt {
      return lhs.reference.occurredAt < rhs.reference.occurredAt
    }
    if lhs.reference.kind != rhs.reference.kind {
      return lhs.reference.kind == .change
    }
    return lhs.reference.stableID.uuidString
      < rhs.reference.stableID.uuidString
  }

  private struct WorkingState {
    var occurrenceAssignments: [SpeakerOccurrenceID: PersonAssignmentDecision] = [:]
    var personNames: [PersonID: PersonNameDecision] = [:]
    var personMerges: [PersonID: PersonMergeDecision] = [:]
    var rejectedCandidates: [OccurrenceCandidateKey: PersonRejectionDecision] = [:]
    var latestTombstones: [DomainEntityReference: Tombstone] = [:]
    var sourceAssetDeletionAuthorizations = Set<DomainEntityReference>()
    var appliedCorrectionIDs = Set<PersonCorrectionID>()
    var ignoredAutomaticCorrectionIDs = Set<PersonCorrectionID>()
    var decisionOrder: [PersonHistoryDecisionReference] = []
  }

  private struct OrderedEvent {
    let reference: PersonHistoryDecisionReference
    let payload: Payload

    enum Payload {
      case change(ChangeLogEntry)
      case tombstone(Tombstone)
    }
  }
}
