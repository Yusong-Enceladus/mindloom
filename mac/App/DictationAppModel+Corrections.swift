import BestASRDelivery
import BestASRDomain
import BestASRPersistence
import BestASRProcessing
import Foundation
import MindloomIdentity
import OSLog

private let correctionLogger = Logger(
  subsystem: MindloomIdentity.logSubsystem, category: "corrections")

// 改了就校准 (ALIGNMENT 收1-8): three ways a correction is seen, one dictionary.
//
// - A field that shows its text: the dictation just typed in is watched, and
//   the field is read every second or two while the watch lasts, so a word
//   fixed just before a chat message is sent is seen before the field is
//   emptied (`followFieldCorrections`, review 10-6 S10). What the user made
//   of it is learned when the next dictation starts or a while later
//   (`settleFieldCorrections`).
// - An App that shows no text (Claude's composer reports no value; WeChat
//   names no field): select the wrong word and say the right one with
//   fn+space (`SpokenJobComposer`'s `.correct` row).
// - History: an edit of a dictation's text.
//
// One sighting makes a replacement under 自动添加; the same correction seen
// twice also joins what the recognizer expects (`learnCorrection`).
extension DictationAppModel {
  /// How long after a dictation is typed in its field is read again.
  static let correctionWatchSeconds: TimeInterval = 90
  /// How often the watched field is read while the watch lasts.
  static let correctionReadSeconds: TimeInterval = 1.5

  /// Reads what the user made of the last dictation typed into a field that
  /// shows its text, and learns from it. Cheap when nothing is watched.
  func settleFieldCorrections() {
    guard let watched = insertionService?.settleCorrectionWatch() else {
      fieldCorrections = nil
      return
    }
    var tracker =
      fieldCorrections.flatMap { $0.key == watched.key.value ? $0 : nil }
      ?? FieldCorrectionTracker(key: watched.key.value, inserted: watched.inserted)
    fieldCorrections = nil
    tracker.observe(watched.fieldContents)
    learnCorrections(tracker.corrections, source: .field)
  }

  /// After a dictation ends: follow its field while the watch lasts, then
  /// settle the watch once the user has had time to correct it, if no other
  /// dictation has settled it first.
  func scheduleCorrectionSettle() {
    correctionSettleTask?.cancel()
    correctionSettleTask = Task { [weak self] in
      let started = Date()
      while !Task.isCancelled, Date().timeIntervalSince(started) < Self.correctionWatchSeconds + 5 {
        try? await Task.sleep(for: .seconds(Self.correctionReadSeconds))
        guard !Task.isCancelled, let self else { return }
        self.followFieldCorrections()
      }
      guard !Task.isCancelled, let self else { return }
      guard let armed = self.insertionService?.correctionWatchArmedAt,
        Date().timeIntervalSince(armed) >= Self.correctionWatchSeconds
      else { return }
      self.settleFieldCorrections()
    }
  }

  /// One reading of the watched field (nothing when no field is watched).
  func followFieldCorrections() {
    guard let watched = insertionService?.peekCorrectionWatch() else { return }
    if fieldCorrections?.key != watched.key.value {
      fieldCorrections = FieldCorrectionTracker(key: watched.key.value, inserted: watched.inserted)
    }
    fieldCorrections?.observe(watched.fieldContents)
  }

  /// A dictation's text edited in history: each word the user fixed is
  /// learned.
  func learnFromTranscriptEdit(original: String, edited: String) {
    learnCorrections(
      CorrectionLearning.fromEdit(original: original, edited: edited), source: .history)
  }

  func learnCorrections(_ candidates: [LearnedCorrectionCandidate], source: CorrectionSource) {
    guard !candidates.isEmpty, let repository else { return }
    Task { [weak self] in
      var learned = 0
      var recognized = 0
      for candidate in candidates {
        guard
          let outcome = try? await repository.learnCorrection(
            heard: candidate.heard, written: candidate.written, source: source.rawValue)
        else { continue }
        learned += 1
        if outcome.usedForRecognition { recognized += 1 }
      }
      // Counts only; never the words.
      correctionLogger.notice(
        "corrections learned source=\(source.rawValue, privacy: .public) count=\(learned, privacy: .public) recognition=\(recognized, privacy: .public)"
      )
      guard learned > 0, let self else { return }
      await self.dictionary.refreshEntries(preserveStatus: true)
      await self.refreshAutomaticDictionaryEntries()
    }
  }

  /// 自动添加 › 移除: the forms corrections added to one of the user's words
  /// leave it, and the same corrections are not learned again.
  func forgetLearnedForms(id: String) async {
    guard let repository, let uuid = UUID(uuidString: id) else { return }
    try? await repository.forgetLearnedForms(entryID: DictionaryEntryID(uuid))
    await dictionary.refreshEntries(preserveStatus: true)
    await refreshAutomaticDictionaryEntries()
  }

  /// The words under 自动添加, for Settings.
  func refreshAutomaticDictionaryEntries() async {
    guard let repository else { return }
    let automatic = (try? await repository.automaticDictionaryEntries()) ?? []
    automaticDictionaryEntries = Dictionary(
      uniqueKeysWithValues: automatic.map { ($0.entryID, $0) })
  }
}
