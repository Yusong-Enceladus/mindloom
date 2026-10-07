import BestASRDictation
import BestASRDomain
import Foundation
import MindloomLibrary

/// Demo mode's dictation (ALIGNMENT 根-10): what is said is typed into other
/// Apps as always, and it never reaches a DGX Spark. Each dictation is
/// written to the demo root's ledger before its session exists and its
/// capture is not granted organizer eligibility. Once its words reached the
/// owner (typed in, or copied) or the owner cancelled it, its records and
/// audio leave the demo library. A take whose words did not reach the owner
/// (it failed, ended before the models were ready, or was neither typed in
/// nor copied) stays in the demo library with its audio, so what the HUD
/// says about it is true and it can be retried or deleted in 历史 (review
/// v12-B #1). After a crash the same rule runs at the next launch.
extension DictationAppModel {
  /// The ledger, in demo mode only.
  var demoDictationLedger: DemoDictationLedger? {
    guard let launch = MindloomLaunch.launch, launch.isDemo else { return nil }
    return DemoDictationLedger(dataRoot: launch.root)
  }

  /// True when a dictation started now is kept in the library.
  var keepsDictations: Bool { !MindloomLaunch.isDemo }

  /// Before a demo dictation's session is made.
  func noteDemoDictation(_ sessionID: SessionID) {
    guard let ledger = demoDictationLedger else { return }
    do {
      try ledger.add(sessionID.rawValue)
    } catch {
      // It is still removed when it ends; only a crash before then would
      // leave it until it is found by hand.
      dictationAppLogger.error("demo dictation ledger not written")
    }
  }

  /// A demo dictation that ended: it leaves the demo library only when its
  /// words reached the owner (`DemoDictationKeeping`); otherwise it stays,
  /// off the ledger, and the ordinary bookkeeping of a kept take follows.
  /// True when it left.
  func settleDemoDictation(_ ended: DictationSessionSnapshot, sessionID: SessionID?) async -> Bool {
    guard let sessionID else { return true }
    let copiedFinal = copiedRetainedSessionID == sessionID && !copiedRetainedTextWasDraft
    guard DemoDictationKeeping.wordsReachedOwner(ended, copiedFinalWords: copiedFinal) else {
      keepDemoDictation(sessionID)
      return false
    }
    await forgetDemoDictation(sessionID)
    return true
  }

  /// A demo dictation the owner did not get the words of: it stays in the
  /// demo library like any take (never eligible for the DGX Spark).
  func keepDemoDictation(_ sessionID: SessionID) {
    demoDictationLedger?.remove(sessionID.rawValue)
    dictationAppLogger.notice("demo dictation kept: its words did not reach the owner")
  }

  /// After a demo dictation's words reached the owner, or it was cancelled:
  /// its records and retained audio leave the demo library. A failure leaves
  /// it on the ledger for the next launch.
  func forgetDemoDictation(_ sessionID: SessionID?) async {
    guard let sessionID, let ledger = demoDictationLedger, let journal, let repository else {
      return
    }
    let removed = await DemoDictationRemoval.remove(
      sessionID, ledger: ledger, journal: journal, repository: repository)
    guard removed else {
      dictationAppLogger.error("demo dictation not removed yet; tried again at the next launch")
      return
    }
    if history.historyItems.contains(where: { $0.sessionID == sessionID }) {
      await refreshHistoryItems(preserveStatus: true)
    }
  }

  /// At launch, before history is read: demo dictations a crash left (the
  /// same rule: removed only when their words were typed in).
  func forgetLeftoverDemoDictations() async {
    guard let ledger = demoDictationLedger, let journal, let repository else { return }
    let left = await DemoDictationRemoval.removeLeftovers(
      ledger: ledger, journal: journal, repository: repository)
    if left > 0 { dictationAppLogger.error("demo dictations left for the next launch") }
  }
}
