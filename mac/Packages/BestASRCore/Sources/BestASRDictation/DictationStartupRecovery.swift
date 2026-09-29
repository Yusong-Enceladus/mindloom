import BestASRDomain
import Foundation

public enum DictationRecoveryDisposition: String, Codable, Sendable {
  case cleanupCompleted
  case readyToFinalize
  case requiresRepair
}

public struct DictationRecoveryCandidate: Codable, Equatable, Sendable {
  public let snapshot: DictationSessionSnapshot
  public let journal: DictationJournalRecoveryStatus?
  public let disposition: DictationRecoveryDisposition

  public init(
    snapshot: DictationSessionSnapshot,
    journal: DictationJournalRecoveryStatus?,
    disposition: DictationRecoveryDisposition
  ) {
    self.snapshot = snapshot
    self.journal = journal
    self.disposition = disposition
  }
}

public actor DictationStartupRecovery {
  private let repository: any DictationRepositoryPort
  private let journal: any DictationJournalPort

  public init(
    repository: any DictationRepositoryPort,
    journal: any DictationJournalPort
  ) {
    self.repository = repository
    self.journal = journal
  }

  public func scan() async throws -> [DictationRecoveryCandidate] {
    let snapshots = try await repository.loadRecoverable()
    var candidates: [DictationRecoveryCandidate] = []
    for snapshot in snapshots {
      guard let sessionID = snapshot.sessionID else { continue }
      if snapshot.phase == .cancelling {
        try? await journal.cancelEphemeral(sessionID: sessionID)
        try await repository.cancelEphemeral(sessionID: sessionID)
        candidates.append(
          DictationRecoveryCandidate(
            snapshot: snapshot,
            journal: nil,
            disposition: .cleanupCompleted
          )
        )
        continue
      }
      do {
        let status = try await journal.recoveryStatus(sessionID: sessionID)
        candidates.append(
          DictationRecoveryCandidate(
            snapshot: snapshot,
            journal: status,
            disposition: status.issueCount == 0 && status.committedChunkCount > 0
              ? .readyToFinalize : .requiresRepair
          )
        )
      } catch {
        candidates.append(
          DictationRecoveryCandidate(
            snapshot: snapshot,
            journal: nil,
            disposition: .requiresRepair
          )
        )
      }
    }
    return candidates
  }
}
