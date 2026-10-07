import BestASRAudioJournal
import BestASRDictation
import BestASRDomain
import BestASRPersistence
import Foundation

/// Removes a demo-mode dictation from the demo library (ALIGNMENT 根-10):
/// its retained audio is staged first and put back if its records cannot
/// go, as 删除记录 does. A session that was never made counts as removed.
public enum DemoDictationRemoval {
  public static func remove(
    _ sessionID: SessionID, journal: ProductionAudioJournal, repository: GRDBDictationStore
  ) async -> Bool {
    var staged: [StagedSessionDeletion] = []
    do {
      do {
        if let deletion = try await journal.stageExplicitDeletion(sessionID: sessionID) {
          staged.append(deletion)
        }
        do {
          try await repository.deleteSessionRecordsExplicitly(sessionID: sessionID)
        } catch BestASRPersistenceError.missingSession {
          // Never made (the start failed first), or already gone.
        }
      } catch {
        for deletion in staged.reversed() { try? await journal.rollbackExplicitDeletion(deletion) }
        throw error
      }
      for deletion in staged { try await journal.commitExplicitDeletion(deletion) }
      return true
    } catch {
      return false
    }
  }

  /// Removes `sessionID` and, once it is gone, takes it off the ledger.
  @discardableResult
  public static func remove(
    _ sessionID: SessionID, ledger: DemoDictationLedger, journal: ProductionAudioJournal,
    repository: GRDBDictationStore
  ) async -> Bool {
    guard await remove(sessionID, journal: journal, repository: repository) else { return false }
    ledger.remove(sessionID.rawValue)
    return true
  }

  /// Every dictation still on the ledger (an earlier run stopped before it
  /// was settled). One whose words were typed in is removed; one that never
  /// got a session only leaves the ledger; any other — stopped while it
  /// listened, waited for the models or failed — stays in the demo library
  /// with its audio, like a take that failed while the App ran (review
  /// v12-B #1): a crash is never permission to delete what was said.
  /// Returns how many are left on the ledger.
  @discardableResult
  public static func removeLeftovers(
    ledger: DemoDictationLedger, journal: ProductionAudioJournal, repository: GRDBDictationStore,
    wordsReachedOwner: (@Sendable (DictationSessionSnapshot) -> Bool)? = nil
  ) async -> Int {
    let reached =
      wordsReachedOwner ?? { DemoDictationKeeping.wordsReachedOwner($0, copiedFinalWords: false) }
    for id in ledger.pending() {
      let sessionID = SessionID(id)
      let stored: DictationSessionSnapshot?
      do {
        stored = try await repository.load(sessionID: sessionID)
      } catch {
        // Unreadable now: left on the ledger, untouched, for another launch.
        continue
      }
      guard let stored else {
        ledger.remove(id)
        continue
      }
      if reached(stored) {
        await remove(sessionID, ledger: ledger, journal: journal, repository: repository)
      } else {
        ledger.remove(id)
      }
    }
    return ledger.pending().count
  }
}

/// When a demo-mode dictation leaves the demo library (ALIGNMENT 根-10;
/// review v12-B #1). Only once its words reached the owner — typed in, or
/// its final words copied whole to the clipboard — or the owner cancelled it
/// with Esc (which discards an uncommitted take in every mode). A take that
/// failed, ended before the models were ready, or was neither typed in nor
/// copied stays in the demo library with its audio, so the HUD's
/// 「录音已保存，可以在历史里重试」 and 「文字在历史里」 are true and the owner can
/// retry or delete it in 历史. It still never reaches a DGX Spark: its capture
/// was not made eligible for the organizing device.
public enum DemoDictationKeeping {
  /// True when the take's words reached the owner: it completed and was
  /// typed in, or its final words (not the live draft) were copied.
  public static func wordsReachedOwner(
    _ snapshot: DictationSessionSnapshot, copiedFinalWords: Bool
  ) -> Bool {
    guard snapshot.phase == .completed else { return false }
    return snapshot.insertion?.inserted == true || copiedFinalWords
  }
}
