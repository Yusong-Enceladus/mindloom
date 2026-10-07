import BestASRDomain
import BestASRMemoryUI
import Foundation

// OWNER: mac-capture. Settings › 设备与隐私 › 详细说明 › 「删除原始录音…」, only
// after the user confirmed it there: every kept original recording on this
// Mac is deleted the same way one record's 仅删除保留原音 does (journal staged,
// the library marked, then committed). Transcripts, organized progress and
// people stay. Never automatic.
extension DictationAppModel {
  func deleteAllOriginalRecordings() {
    guard let journal, let repository else { return }
    // What is being recorded, imported or recognized right now keeps its
    // audio; so does anything not yet transcribed (the query leaves those
    // out), since its transcript could not be made or retried without it.
    let busy = Set(
      [
        snapshot.sessionID, capture.roomSnapshot.sessionID, capture.systemAudioSnapshot.sessionID,
        importSessionID,
      ]
      .compactMap { $0 })
    stopHistoryPlayback()
    Task { [weak self] in
      let found = try? await repository.sessionsRetainingSourceAudio()
      let sessions = found?.finished ?? []
      let kept = (found?.unfinished ?? 0) + sessions.filter { busy.contains($0) }.count
      var deleted = 0
      for sessionID in sessions where !busy.contains(sessionID) {
        do {
          let staged = try await journal.stageExplicitDeletion(sessionID: sessionID)
          do {
            try await repository.markSessionSourceAudioExplicitlyDeleted(sessionID: sessionID)
          } catch {
            if let staged { try? await journal.rollbackExplicitDeletion(staged) }
            continue
          }
          if let staged { try await journal.commitExplicitDeletion(staged) }
          deleted += 1
        } catch {
          continue
        }
      }
      guard let self else { return }
      let words =
        kept > 0
        ? (deleted > 0 ? "原始录音已删除 · \(kept) 条尚未转写完成，暂时保留" : "\(kept) 条尚未转写完成，暂时保留")
        : (deleted > 0 ? "原始录音已删除" : "没有可以删除的原始录音")
      CaptureFeedback.shared.show(MemoryToast(words, icon: .symbol("trash")))
      await refreshHistoryItems(preserveStatus: true)
    }
  }
}
