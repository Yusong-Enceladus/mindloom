import Foundation
import MindloomPhoneKit
import MindloomWatchHandoff
import UIKit
import os

/// Recordings from Apple Watch on this iPhone (WATCH-004, WATCH-005): each stored original appears
/// on Home at once (「正在转写…」), is transcribed on this iPhone, and its text goes to the Mac with
/// the origin "Apple Watch". The original stays here until the person deletes it. Runs again, one
/// recording at a time, whenever a recording arrives, the app becomes active or a background
/// refresh runs, until every original has its text or is marked failed.
@MainActor
final class WatchRecordings {
  let inbox: WatchRecordingInbox
  private let delivery: DeliveryService
  private var running: Task<Void, Never>?
  private var again = false
  /// Items made again after a restore this launch (`restoreMissingItems`).
  private var itemsChecked = false
  private let log = Logger(subsystem: PhoneNames.appLog, category: "watch")

  init(inbox: WatchRecordingInbox, delivery: DeliveryService) {
    self.inbox = inbox
    self.delivery = delivery
  }

  /// The originals live in the app's own Application Support (only the app reads them), included in
  /// the iPhone's backups (WATCH-009).
  static func makeInbox() -> WatchRecordingInbox? {
    guard let base = PhoneAppGroup.privateApplicationSupport() else { return nil }
    return try? WatchRecordingInbox(root: WatchRecordingInbox.directory(in: base))
  }

  /// A newly stored original (called from WatchConnectivity's queue).
  nonisolated func stored(_ recording: WatchRecording) {
    Task { @MainActor in
      self.show(recording)
      self.process()
    }
  }

  private func show(_ recording: WatchRecording) {
    do {
      try delivery.collector.recordWatchRecording(
        id: recording.id, startedAt: recording.startedAt, seconds: recording.duration)
    } catch {
      log.error("watch item not shown: \(String(describing: error), privacy: .public)")
    }
    delivery.refresh()
  }

  /// Transcribes every original that is due, oldest first.
  func process() {
    guard running == nil else {
      again = true
      return
    }
    running = Task { @MainActor [weak self] in
      guard let self else { return }
      let background = UIApplication.shared.beginBackgroundTask(withName: "watch-transcription") {
        [weak self] in self?.running?.cancel()
      }
      restoreMissingItems()
      repeat {
        again = false
        await processPending()
      } while again && !Task.isCancelled
      running = nil
      UIApplication.shared.endBackgroundTask(background)
    }
  }

  /// Waits for the run in progress (background refresh). Cancelling the caller cancels the run.
  func finish() async {
    process()
    guard let running else { return }
    await withTaskCancellationHandler {
      await running.value
    } onCancel: {
      running.cancel()
    }
  }

  /// 「重新转写」: a recording that gave no text is tried again from a fresh count.
  func retry(id: String) {
    do {
      guard try inbox.retryTranscription(id: id) else { return }
      try delivery.collector.retryWatchRecording(id: id)
    } catch {
      log.error("watch retry: \(String(describing: error), privacy: .public)")
    }
    delivery.refresh()
    process()
  }

  /// 「删除录音…」: the original, its item and the item's parts that have not left this iPhone.
  /// What the Mac received stays there. Returns false when nothing was deleted.
  @discardableResult
  func delete(id: String) -> Bool {
    do {
      // The original first: if that fails, the item stays with it.
      let hadOriginal = try inbox.delete(id: id)
      let hadItem = try delivery.collector.removeWatchRecordingItem(id: id)
      delivery.refresh()
      return hadOriginal || hadItem
    } catch {
      log.error("watch delete: \(String(describing: error), privacy: .public)")
      delivery.refresh()
      return false
    }
  }

  /// After a restore from a backup (WATCH-009) the originals are back and their Home items are
  /// not (the App Group is not in backups). Every kept original without an item gets it again, so
  /// it can be seen, retried and deleted: still waiting for its text (「正在转写…」, then
  /// transcribed and sent as usual), its text (not sent again), or no text (「无法转写音频」).
  /// Once per launch, when protected data can be read; until then, at the next run.
  private func restoreMissingItems() {
    guard !itemsChecked, UIApplication.shared.isProtectedDataAvailable else { return }
    let collector = delivery.collector
    var restored = 0
    for received in inbox.all() where collector.items.item(id: received.id) == nil {
      let recording = received.recording
      do {
        switch received.transcription {
        case .pending:
          try collector.recordWatchRecording(
            id: recording.id, startedAt: recording.startedAt, seconds: recording.duration)
        case .done where received.text == nil:
          // Transcribed by a build that did not keep the text with the original: transcribed
          // again, and its text sent as usual.
          try inbox.setTranscription(.pending, id: recording.id)
          try collector.recordWatchRecording(
            id: recording.id, startedAt: recording.startedAt, seconds: recording.duration)
        case .done, .noSpeech, .failed:
          try collector.restoreWatchRecordingItem(
            id: recording.id, startedAt: recording.startedAt, seconds: recording.duration,
            text: received.text)
        }
        restored += 1
      } catch {
        log.error("watch item not restored: \(String(describing: error), privacy: .public)")
        return
      }
    }
    itemsChecked = true
    if restored > 0 {
      log.notice("watch items made again after a restore (\(restored, privacy: .public))")
      delivery.refresh()
    }
  }

  private func processPending() async {
    for received in inbox.dueForTranscription() {
      guard !Task.isCancelled else { return }
      let recording = received.recording
      let url = inbox.audioURL(id: recording.id)
      // In the background only what fits in the time left (assumed: a recording takes no longer
      // to transcribe than to play; not measured on a device). The rest waits for the app.
      let remaining = UIApplication.shared.backgroundTimeRemaining
      if remaining.isFinite, remaining < 600,
        (WatchTranscriber.length(of: url) ?? recording.duration) > remaining - 10
      {
        log.notice("watch recording left for the foreground")
        continue
      }
      show(recording)
      let outcome = await WatchTranscriber.transcribe(url, seconds: recording.duration)
      // Deleted while it was being transcribed: nothing comes back.
      guard inbox.record(id: recording.id)?.deletedAt == nil else { continue }
      switch outcome {
      case .text(let text):
        do {
          let item = try delivery.collector.completeWatchRecording(
            id: recording.id, startedAt: recording.startedAt, seconds: recording.duration,
            text: text)
          // The text is kept with the original too (WATCH-009: a restore brings the item back).
          try inbox.noteTranscribed(text: item.text, id: recording.id)
          log.notice("watch recording transcribed (\(text.count, privacy: .public) characters)")
        } catch {
          log.error("watch item not kept: \(String(describing: error), privacy: .public)")
        }
        delivery.refresh()
        Task { await delivery.deliver() }
      case .failed:
        // This recording only: tried again after a pause, marked failed after a few tries.
        let updated = try? inbox.noteFailedAttempt(id: recording.id)
        log.notice(
          "watch recording not transcribed (try \(updated?.attempts ?? 0, privacy: .public))")
        if updated?.transcription == .failed { markFailed(recording.id) }
      case .unreadable:
        try? inbox.setTranscription(.failed, id: recording.id)
        log.notice("watch recording does not read as audio")
        markFailed(recording.id)
      case .notNow:
        log.notice("watch recordings wait for the recognizer")
        // The next run comes with the next arrival, activation or background refresh.
        return
      case .cancelled:
        return
      }
    }
  }

  private func markFailed(_ id: String) {
    _ = try? delivery.collector.failWatchRecording(id: id)
    delivery.refresh()
  }
}

extension PhoneFormat {
  /// 「0:12」, 「12:05」, 「1:02:03」: a recording's length.
  static func duration(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let (hours, minutes, rest) = (total / 3600, (total % 3600) / 60, total % 60)
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, rest)
      : String(format: "%d:%02d", minutes, rest)
  }
}
