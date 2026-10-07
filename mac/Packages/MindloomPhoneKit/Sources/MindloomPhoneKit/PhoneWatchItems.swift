import Foundation
import MindloomLink

/// Recordings from Apple Watch on Home (WATCH-005): one item per recording, under the recording's
/// own id, shown as soon as the original is stored (「正在转写…」), then given its text and sent
/// to the Mac like anything said into the speak bar. Every step can run again after a crash
/// without making a second item or a second entry.
extension PhoneItemCollector {
  /// The original is stored: shows the item at once. Nothing changes when the item exists.
  @discardableResult
  public func recordWatchRecording(id: String, startedAt: Date, seconds: Double) throws -> PhoneItem
  {
    if let existing = items.item(id: id) { return existing }
    var item = PhoneItem(id: id, createdAt: startedAt, kind: .text, source: .watch)
    item.recordingID = id
    item.recordingSeconds = seconds
    item.awaitingTranscription = true
    try items.save(item)
    return item
  }

  /// The recording's text is ready: the item gets it and it leaves for the Mac (sealed and queued,
  /// or kept for pairing). An empty text means nothing was said: the item keeps only its
  /// recording and nothing is sent. Nothing changes when the item already has its text.
  ///
  /// The payload's `source` is 「口述」 ("iPhone 口述", a name every Mac since v11 knows) with
  /// `origin` "Apple Watch": a Mac before v12 deleted an entry whose source it did not know.
  @discardableResult
  public func completeWatchRecording(
    id: String, startedAt: Date, seconds: Double, text: String, now: Date = Date()
  ) throws -> PhoneItem {
    var item: PhoneItem
    if let existing = items.item(id: id) {
      item = existing
    } else {
      item = try recordWatchRecording(id: id, startedAt: startedAt, seconds: seconds)
    }
    guard item.awaitingTranscription == true else { return item }
    item.awaitingTranscription = nil
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      item.text = nil
      try items.save(item)
      return item
    }
    item.text = trimmed
    let payload = try InboxItemPayload.text(
      trimmed, source: item.source.payloadSource, origin: item.source.payloadOrigin,
      createdAt: item.createdAt)
    return try collect(item, payloads: [payload], now: now)
  }

  /// After a restore from a backup (WATCH-009) the originals come back and their items do not
  /// (the App Group is not in backups). Makes the item of a kept original that was transcribed
  /// again, so the recording can be seen, retried and deleted: with its text, or with none
  /// (nothing was said or it could not be transcribed: 「无法转写音频」, 「重新转写」). A text is
  /// not sent again: it was handed to the outbox for the Mac before the backup, and the outbox,
  /// which knew whether it arrived, did not come back; sending it again could put a second copy
  /// on the Mac. (One still waiting for its text is `recordWatchRecording`.) Nothing changes when
  /// the item exists.
  @discardableResult
  public func restoreWatchRecordingItem(
    id: String, startedAt: Date, seconds: Double, text: String?
  ) throws -> PhoneItem {
    if let existing = items.item(id: id) { return existing }
    var item = PhoneItem(id: id, createdAt: startedAt, kind: .text, source: .watch)
    item.recordingID = id
    item.recordingSeconds = seconds
    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
    item.text = trimmed?.isEmpty == false ? trimmed : nil
    try items.save(item)
    return item
  }

  /// The recording could not be transcribed (the file does not read, or every try failed): the
  /// item stops waiting and shows 「无法转写音频」; nothing is sent. 「重新转写」 brings it back.
  @discardableResult
  public func failWatchRecording(id: String) throws -> PhoneItem? {
    guard var item = items.item(id: id), item.recordingID != nil,
      item.awaitingTranscription == true
    else { return items.item(id: id) }
    item.awaitingTranscription = nil
    item.text = nil
    try items.save(item)
    return item
  }

  /// 「重新转写」: an item whose recording gave no text waits for its text again. False (nothing
  /// changes) when the item already has text or is still waiting.
  @discardableResult
  public func retryWatchRecording(id: String) throws -> Bool {
    guard var item = items.item(id: id), item.recordingID != nil, item.text == nil,
      item.awaitingTranscription != true, item.entryIDs.isEmpty, !item.awaitingPairing
    else { return false }
    item.awaitingTranscription = true
    try items.save(item)
    return true
  }

  /// 「删除录音…」 (the person's own deletion, WATCH-004): removes the item of a recording from
  /// Apple Watch, with its parts that have not left this iPhone and the previews of those that
  /// did. A part already sent, or being sent right now, stays with the Mac. The recording itself
  /// is removed by the caller (`WatchRecordingInbox.delete`). False when `id` is not such an item.
  @discardableResult
  public func removeWatchRecordingItem(id: String) throws -> Bool {
    guard let item = items.item(id: id), item.recordingID != nil else { return false }
    for entryID in item.entryIDs where try outbox.withdraw(id: entryID) == .alreadySent {
      // Otherwise Home would show the sent part's preview as an item of its own.
      try outbox.removeSent(id: entryID)
    }
    items.remove(id: id)
    signaling?.post(PhoneSignal.outboxChanged)
    return true
  }

  /// Writes onto each item of a kept recording when the Mac had every part (`PhoneItem.sentAt`):
  /// the outbox forgets a sent part after 7 days, the item stays as long as its recording.
  /// Run before anything prunes the outbox. Returns how many items were updated.
  @discardableResult
  public func noteKeptItemsSent(now: Date = Date()) -> Int {
    var noted = 0
    for var item in items.all()
    where item.recordingID != nil && item.sentAt == nil && !item.entryIDs.isEmpty {
      // An unknown time (parts already forgotten) is left to `delivery(of:)`.
      guard case .sent(let at?) = delivery(of: item, now: now) else { continue }
      item.sentAt = at
      if (try? items.save(item)) != nil { noted += 1 }
    }
    return noted
  }
}
