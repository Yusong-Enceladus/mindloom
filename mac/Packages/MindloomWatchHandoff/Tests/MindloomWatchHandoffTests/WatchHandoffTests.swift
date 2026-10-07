import CryptoKit
import Foundation
import XCTest

@testable import MindloomWatchHandoff

/// The watch's queue, the iPhone's inbox and the messages between them (WATCH-003, WATCH-004),
/// without WatchConnectivity: the files and decisions it carries. Synthetic bytes only.
final class WatchHandoffTests: XCTestCase {
  private var base: URL!
  private let start = Date(timeIntervalSince1970: 1_790_000_000)

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "watch-handoff-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: base)
  }

  private func syntheticAudio(_ count: Int = 4096, seed: UInt8 = 7) -> Data {
    // An ADTS sync word, then deterministic filler: shaped like the file, not real audio.
    var bytes: [UInt8] = [0xFF, 0xF1]
    var value = seed
    while bytes.count < count {
      value = value &* 31 &+ 17
      bytes.append(value)
    }
    return Data(bytes)
  }

  private func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Records one synthetic recording into `queue` and returns it.
  private func record(
    in queue: WatchRecordingQueue, bytes: Data, at: Date? = nil, duration: TimeInterval = 4.2
  ) throws -> WatchRecording {
    let id = WatchRecordingID.make()
    let url = try queue.beginRecording(id: id, startedAt: at ?? start)
    try bytes.write(to: url)
    return try XCTUnwrap(queue.finishRecording(id: id, duration: duration, interrupted: false))
  }

  // MARK: - Description and messages

  func testTransferMetadataRoundTripsAndIsValidated() throws {
    let data = syntheticAudio()
    let recording = WatchRecording(
      id: WatchRecordingID.make(), startedAt: start, duration: 12.5, bytes: data.count,
      sha256: hex(data))
    let decoded = try WatchRecording(transferMetadata: recording.transferMetadata)
    XCTAssertEqual(decoded, recording)
    // Property-list values only (WatchConnectivity refuses anything else).
    XCTAssertTrue(
      PropertyListSerialization.propertyList(recording.transferMetadata, isValidFor: .binary))

    var bad = recording.transferMetadata
    bad["id"] = "../../etc"
    XCTAssertThrowsError(try WatchRecording(transferMetadata: bad))
    bad = recording.transferMetadata
    bad["sha256"] = "XYZ"
    XCTAssertThrowsError(try WatchRecording(transferMetadata: bad))
    bad = recording.transferMetadata
    bad["bytes"] = WatchRecording.maximumBytes + 1
    XCTAssertThrowsError(try WatchRecording(transferMetadata: bad))
    bad = recording.transferMetadata
    bad["duration"] = WatchRecording.maximumDuration * 3
    XCTAssertThrowsError(try WatchRecording(transferMetadata: bad))
    bad = recording.transferMetadata
    bad[WatchRecording.marker] = 99
    XCTAssertThrowsError(try WatchRecording(transferMetadata: bad))
    XCTAssertThrowsError(try WatchRecording(transferMetadata: nil))
  }

  /// Regression (the iPhone simulator test of 10-06 failed on it): a start with a fraction of a
  /// millisecond, as `Date()` gives, came back from the inbox's JSON a little different, so the
  /// same recording no longer compared equal.
  func testAStartWithAFractionOfAMillisecondComparesEqualEverywhere() throws {
    let data = syntheticAudio()
    let started = Date(timeIntervalSince1970: 1_790_000_000.123_456_7)
    let recording = WatchRecording(
      id: WatchRecordingID.make(), startedAt: started, duration: 5.76, bytes: data.count,
      sha256: hex(data))
    XCTAssertEqual(recording.startedAt.timeIntervalSince1970, 1_790_000_000.123, accuracy: 1e-6)
    XCTAssertEqual(try WatchRecording(transferMetadata: recording.transferMetadata), recording)

    let inbox = try WatchRecordingInbox(root: WatchRecordingInbox.directory(in: base))
    let file = try received(data, in: base)
    XCTAssertEqual(
      try inbox.accept(file: file, metadata: recording.transferMetadata), .stored(recording))
    XCTAssertEqual(inbox.record(id: recording.id)?.recording, recording)
    XCTAssertEqual(
      try inbox.accept(file: file, metadata: recording.transferMetadata), .duplicate(recording))

    let queue = try WatchRecordingQueue(root: base.appendingPathComponent("watch"))
    let queued = try record(in: queue, bytes: data, at: started)
    XCTAssertEqual(queue.pending().first?.recording, queued)
    XCTAssertEqual(queued.startedAt, recording.startedAt)
  }

  func testMessagesRoundTripAndDropWhatIsNotOurs() {
    let ids = [WatchRecordingID.make(), WatchRecordingID.make()]
    XCTAssertEqual(
      WatchHandoffMessage(dictionary: WatchHandoffMessage.stored(ids).dictionary), .stored(ids))
    XCTAssertEqual(
      WatchHandoffMessage(dictionary: WatchHandoffMessage.holding(ids).dictionary), .holding(ids))
    var mixed = WatchHandoffMessage.stored(ids).dictionary
    mixed["stored"] = [ids[0], "not-an-id", ids[0], 42, ids[1].uppercased()]
    XCTAssertEqual(WatchHandoffMessage(dictionary: mixed), .stored([ids[0]]))
    XCTAssertNil(WatchHandoffMessage(dictionary: ["stored": ids]))
    XCTAssertNil(WatchHandoffMessage(dictionary: nil))
    // The answer to "holding": what is stored, and what is missing although the iPhone had
    // nothing more coming from WatchConnectivity.
    let reply = WatchHandoffMessage.reply(stored: [ids[0]], missing: [ids[1]])
    XCTAssertEqual(WatchHandoffMessage(dictionary: reply.dictionary), reply)
    XCTAssertTrue(PropertyListSerialization.propertyList(reply.dictionary, isValidFor: .binary))
    var both = reply.dictionary
    both["missing"] = [ids[0], ids[1]]
    XCTAssertEqual(
      WatchHandoffMessage(dictionary: both), .reply(stored: [ids[0]], missing: [ids[1]]),
      "never both stored and missing")
    XCTAssertNil(WatchHandoffMessage(dictionary: [WatchRecording.marker: 1]))
  }

  // MARK: - The watch's queue

  func testFinishedRecordingWaitsWithItsDigest() throws {
    let queue = try WatchRecordingQueue(root: base.appendingPathComponent("watch"))
    let data = syntheticAudio()
    let recording = try record(in: queue, bytes: data)
    XCTAssertEqual(recording.bytes, data.count)
    XCTAssertEqual(recording.sha256, hex(data))
    XCTAssertEqual(recording.startedAt, start)
    XCTAssertFalse(recording.interrupted)
    XCTAssertEqual(queue.pending().map(\.id), [recording.id])
    XCTAssertEqual(try Data(contentsOf: queue.fileURL(id: recording.id)), data)
    XCTAssertNoThrow(try recording.validate())
  }

  func testEmptyRecordingIsNotKept() throws {
    let queue = try WatchRecordingQueue(root: base.appendingPathComponent("watch"))
    let id = WatchRecordingID.make()
    let url = try queue.beginRecording(id: id, startedAt: start)
    try Data().write(to: url)
    XCTAssertNil(try queue.finishRecording(id: id, duration: 0, interrupted: false))
    XCTAssertEqual(queue.pendingCount, 0)
    XCTAssertEqual(queue.recover(duration: { _ in 0 }), [])
  }

  func testOnlyTheIPhonesStoredRemovesARecording() throws {
    let queue = try WatchRecordingQueue(root: base.appendingPathComponent("watch"))
    let first = try record(in: queue, bytes: syntheticAudio(seed: 1))
    let second = try record(
      in: queue, bytes: syntheticAudio(seed: 2), at: start.addingTimeInterval(60))
    queue.markSending(id: first.id, at: start)
    queue.markDelivered(id: first.id, at: start)
    // Delivery by WatchConnectivity alone removes nothing.
    XCTAssertEqual(queue.pending().map(\.id), [first.id, second.id])
    XCTAssertEqual(queue.removeStored([first.id, WatchRecordingID.make(), "bogus"]), [first.id])
    XCTAssertEqual(queue.pending().map(\.id), [second.id])
    XCTAssertEqual(queue.removeStored([first.id]), [], "a second stored for the same id is a no-op")
  }

  func testWhenARecordingIsSentAgain() throws {
    let queue = try WatchRecordingQueue(root: base.appendingPathComponent("watch"))
    let recording = try record(in: queue, bytes: syntheticAudio())
    let id = recording.id
    func due(_ offset: TimeInterval, outstanding: Set<String> = []) -> Bool {
      queue.due(now: start.addingTimeInterval(offset), outstanding: outstanding).map(\.id) == [id]
    }
    XCTAssertTrue(due(0), "never sent")
    XCTAssertFalse(due(0, outstanding: [id]), "never twice at once")
    queue.markSending(id: id, at: start)
    XCTAssertFalse(due(60))
    XCTAssertTrue(due(WatchRecordingQueue.resendAfterSilence), "lost without a result")
    queue.markDelivered(id: id, at: start)
    XCTAssertFalse(due(WatchRecordingQueue.resendAfterDelivery - 1))
    XCTAssertTrue(
      due(WatchRecordingQueue.resendAfterDelivery), "delivered, never confirmed: last resort")
    queue.markFailed(id: id, at: start)
    XCTAssertFalse(due(WatchRecordingQueue.firstRetryPause - 1))
    XCTAssertTrue(due(WatchRecordingQueue.firstRetryPause))
    queue.markSending(id: id, at: start)
    queue.markFailed(id: id, at: start)
    XCTAssertFalse(due(WatchRecordingQueue.firstRetryPause), "the pause doubles")
    XCTAssertTrue(due(2 * WatchRecordingQueue.firstRetryPause))
    for _ in 0..<20 { queue.markFailed(id: id, at: start) }
    XCTAssertTrue(due(WatchRecordingQueue.maximumRetryPause), "never longer than the maximum")
  }

  /// Regression (paired simulators, 10-06): WatchConnectivity reported a transfer delivered while
  /// the iPhone was shut down, and the iPhone, back and asked "holding", answered that it did not
  /// have it; the recording then sat on the watch until the 15-minute resend. The iPhone's answer
  /// now makes it due at once.
  func testWhatTheIPhoneSaysItLacksIsSentAgainAtOnce() throws {
    let queue = try WatchRecordingQueue(root: base.appendingPathComponent("watch"))
    let delivered = try record(in: queue, bytes: syntheticAudio(seed: 5))
    let failed = try record(
      in: queue, bytes: syntheticAudio(seed: 6), at: start.addingTimeInterval(10))
    let travelling = try record(
      in: queue, bytes: syntheticAudio(seed: 8), at: start.addingTimeInterval(20))
    for id in [delivered.id, failed.id, travelling.id] { queue.markSending(id: id, at: start) }
    queue.markDelivered(id: delivered.id, at: start)
    queue.markFailed(id: failed.id, at: start)
    let ids = [delivered.id, failed.id, travelling.id]
    let justAfter = start.addingTimeInterval(WatchRecordingQueue.missingGrace - 1)
    XCTAssertEqual(
      queue.noteMissing(ids, outstanding: [travelling.id], now: justAfter), [],
      "just delivered: it may still be on its way into the app")
    let later = start.addingTimeInterval(WatchRecordingQueue.missingGrace)
    XCTAssertEqual(
      queue.noteMissing(ids + ["bogus"], outstanding: [travelling.id], now: later), [delivered.id],
      "a failed copy keeps its own pause; one still travelling is never sent twice")
    XCTAssertEqual(
      queue.due(now: later, outstanding: [travelling.id]).map(\.id), [delivered.id, failed.id])
    // Nothing is removed by being missing.
    XCTAssertEqual(queue.pendingCount, 3)
    // WatchConnectivity dropped the travelling one without a result: missing makes it due too.
    XCTAssertEqual(queue.noteMissing([travelling.id], outstanding: [], now: later), [travelling.id])
  }

  /// Regression (review, 10-06): "delivered" means the file is in the iPhone's WatchConnectivity
  /// queue, waiting for Mindloom there to run. With a 15-minute resend the watch sent the same
  /// file again and again while the iPhone app did not run (8 full copies in about 2 hours of
  /// background refreshes). A delivered recording is not sent again for hours; only the iPhone,
  /// asked while it runs, makes it due sooner (`noteMissing`).
  func testADeliveredRecordingIsNotSentAgainWhileTheIPhoneAppDoesNotRun() throws {
    let queue = try WatchRecordingQueue(root: base.appendingPathComponent("watch"))
    let recording = try record(in: queue, bytes: syntheticAudio())
    queue.markSending(id: recording.id, at: start)
    queue.markDelivered(id: recording.id, at: start)
    var resent = 0
    for minute in stride(from: 0, through: 120, by: 16) {
      let now = start.addingTimeInterval(Double(minute) * 60)
      for queued in queue.due(now: now, outstanding: []) {
        resent += 1
        queue.markSending(id: queued.id, at: now)
        queue.markDelivered(id: queued.id, at: now)
      }
    }
    XCTAssertEqual(resent, 0)
    XCTAssertGreaterThanOrEqual(WatchRecordingQueue.resendAfterDelivery, 60 * 60)
    // The background refresh is asked for when the next one is due, not every 15 minutes.
    XCTAssertEqual(
      queue.nextDue(after: start),
      start.addingTimeInterval(WatchRecordingQueue.resendAfterDelivery))
    let fresh = try record(in: queue, bytes: syntheticAudio(seed: 9))
    XCTAssertEqual(queue.nextDue(after: start), start, "one never handed over is due now")
    queue.markSending(id: fresh.id, at: start)
    queue.markFailed(id: fresh.id, at: start)
    XCTAssertEqual(
      queue.nextDue(after: start), start.addingTimeInterval(WatchRecordingQueue.firstRetryPause))
    _ = queue.removeStored([recording.id, fresh.id])
    XCTAssertNil(queue.nextDue(after: start), "nothing waits")
  }

  /// Regression for the durability rule (AGENTS.md: recording durability outranks inference): a
  /// recording the app could not finish (it was ended mid-recording) is kept as interrupted, with
  /// its start time, and sent like any other.
  func testRecoveryKeepsWhatACrashLeftBehind() throws {
    let root = base.appendingPathComponent("watch")
    var queue = try WatchRecordingQueue(root: root)
    let cut = WatchRecordingID.make()
    let cutURL = try queue.beginRecording(id: cut, startedAt: start)
    try syntheticAudio(seed: 3).write(to: cutURL)
    // A start note with no audio (ended before the first frame).
    _ = try queue.beginRecording(id: WatchRecordingID.make(), startedAt: start)
    // A finished description whose move did not happen.
    let moved = try record(in: queue, bytes: syntheticAudio(seed: 4))
    let movedAudio = try Data(contentsOf: queue.fileURL(id: moved.id))
    try FileManager.default.moveItem(
      at: queue.fileURL(id: moved.id),
      to: root.appendingPathComponent("recording/\(moved.id).aac"))

    queue = try WatchRecordingQueue(root: root)
    let recovered = queue.recover(duration: { _ in 3.5 })
    XCTAssertEqual(Set(recovered.map(\.id)), [cut, moved.id])
    let cutRecording = try XCTUnwrap(recovered.first { $0.id == cut })
    XCTAssertTrue(cutRecording.interrupted)
    XCTAssertEqual(cutRecording.startedAt, start)
    XCTAssertEqual(cutRecording.duration, 3.5)
    XCTAssertEqual(Set(queue.pending().map(\.id)), [cut, moved.id])
    XCTAssertEqual(try Data(contentsOf: queue.fileURL(id: moved.id)), movedAudio)
    let leftovers = try FileManager.default.contentsOfDirectory(
      atPath: root.appendingPathComponent("recording").path)
    XCTAssertEqual(leftovers, [])
    XCTAssertEqual(queue.recover(duration: { _ in 1 }), [], "a second recovery finds nothing")
  }

  // MARK: - The iPhone's inbox

  private func received(_ data: Data, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("inbox-\(UUID().uuidString).aac")
    try data.write(to: url)
    return url
  }

  func testInboxKeepsTheOriginalByteForByteAndOnce() throws {
    let inbox = try WatchRecordingInbox(root: WatchRecordingInbox.directory(in: base))
    let data = syntheticAudio()
    let recording = WatchRecording(
      id: WatchRecordingID.make(), startedAt: start, duration: 4, bytes: data.count,
      sha256: hex(data))
    let file = try received(data, in: base)
    XCTAssertEqual(
      try inbox.accept(file: file, metadata: recording.transferMetadata), .stored(recording))
    XCTAssertEqual(try Data(contentsOf: inbox.audioURL(id: recording.id)), data)
    XCTAssertEqual(
      try inbox.accept(file: file, metadata: recording.transferMetadata), .duplicate(recording))
    XCTAssertEqual(inbox.all().count, 1)
    XCTAssertEqual(inbox.pendingTranscription().map(\.id), [recording.id])
    XCTAssertEqual(inbox.storedIDs(among: [recording.id, WatchRecordingID.make()]), [recording.id])
    XCTAssertTrue(settles(inbox.root, excluded: false), "the originals are in the iPhone's backups")
    XCTAssertTrue(settles(inbox.audioURL(id: recording.id), excluded: false))
    XCTAssertTrue(
      settles(inbox.root.appendingPathComponent("tmp", isDirectory: true), excluded: true))

    try inbox.noteFailedAttempt(id: recording.id, at: start)
    XCTAssertEqual(inbox.record(id: recording.id)?.attempts, 1)
    try inbox.setTranscription(.done, id: recording.id)
    XCTAssertEqual(inbox.pendingTranscription(), [])
    XCTAssertEqual(inbox.record(id: recording.id)?.transcription, .done)
  }

  /// Whether `url` itself carries a backup exclusion: the extended attribute Foundation writes
  /// for `isExcludedFromBackup`, read directly. On macOS the URL value also reports a parent's
  /// exclusion and can come back stale for a moment (seen on this Mac: a staging directory read as
  /// excluded after its own mark and its parent's were gone; about one full run in eight failed
  /// that way before this check).
  private func excludedFromBackup(_ url: URL) -> Bool {
    getxattr(url.path, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, 0) >= 0
  }

  /// Whether `url`'s own mark is `excluded` within 2 seconds (a directory's can take a moment to
  /// go while the Mac is busy).
  private func settles(_ url: URL, excluded: Bool) -> Bool {
    let deadline = Date().addingTimeInterval(2)
    repeat {
      if excludedFromBackup(url) == excluded { return true }
      usleep(20_000)
    } while Date() < deadline
    return false
  }

  private func setExcludedFromBackup(_ url: URL, _ excluded: Bool) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = excluded
    var url = url
    try url.setResourceValues(values)
  }

  /// WATCH-009: an inbox an earlier build excluded from backups (the directory, and a file with
  /// its own mark) is included again when the iPhone opens it; the originals and their state are
  /// kept as they were, and staging stays out.
  func testAnInboxExcludedByAnEarlierBuildGoesIntoBackups() throws {
    let root = WatchRecordingInbox.directory(in: base)
    let data = syntheticAudio()
    let recording = WatchRecording(
      id: WatchRecordingID.make(), startedAt: start, duration: 4, bytes: data.count,
      sha256: hex(data))
    do {
      let earlier = try WatchRecordingInbox(root: root)
      let file = try received(data, in: base)
      XCTAssertEqual(
        try earlier.accept(file: file, metadata: recording.transferMetadata), .stored(recording))
      try earlier.setTranscription(.done, id: recording.id)
    }
    // What a build before 2026-10-06 left behind.
    try setExcludedFromBackup(root, true)
    try setExcludedFromBackup(root.appendingPathComponent("\(recording.id).json"), true)
    try setExcludedFromBackup(root.appendingPathComponent("tmp", isDirectory: true), false)
    XCTAssertTrue(settles(root, excluded: true))
    XCTAssertTrue(settles(root.appendingPathComponent("\(recording.id).json"), excluded: true))
    XCTAssertTrue(settles(root.appendingPathComponent("tmp", isDirectory: true), excluded: false))

    let inbox = try WatchRecordingInbox(root: root)
    XCTAssertTrue(settles(root, excluded: false))
    XCTAssertTrue(settles(inbox.audioURL(id: recording.id), excluded: false))
    XCTAssertTrue(settles(root.appendingPathComponent("\(recording.id).json"), excluded: false))
    XCTAssertTrue(settles(root.appendingPathComponent("tmp", isDirectory: true), excluded: true))
    XCTAssertEqual(try Data(contentsOf: inbox.audioURL(id: recording.id)), data)
    XCTAssertEqual(inbox.record(id: recording.id)?.transcription, .done)
    XCTAssertEqual(inbox.all().map(\.id), [recording.id])

    // Opening it again changes nothing.
    _ = try WatchRecordingInbox(root: root)
    XCTAssertTrue(settles(root, excluded: false))
    XCTAssertTrue(settles(root.appendingPathComponent("tmp", isDirectory: true), excluded: true))
  }

  /// Regression (review, 10-06): the original is a copy of the received file, and a copy keeps
  /// that file's own backup exclusion, so an original could stay out of backups for good (the
  /// earlier one-time pass ran only while the directory itself was excluded). The stored original
  /// is included; an original that carries a mark anyway is included at the next open.
  func testAReceivedFileWithItsOwnExclusionIsStoredIntoBackups() throws {
    let inbox = try WatchRecordingInbox(root: WatchRecordingInbox.directory(in: base))
    let data = syntheticAudio()
    let recording = WatchRecording(
      id: WatchRecordingID.make(), startedAt: start, duration: 4, bytes: data.count,
      sha256: hex(data))
    let file = try received(data, in: base)
    try setExcludedFromBackup(file, true)
    XCTAssertTrue(settles(file, excluded: true))
    XCTAssertEqual(
      try inbox.accept(file: file, metadata: recording.transferMetadata), .stored(recording))
    let original = inbox.audioURL(id: recording.id)
    XCTAssertTrue(settles(original, excluded: false), "the original is in the iPhone's backups")
    XCTAssertEqual(try Data(contentsOf: original), data)

    try setExcludedFromBackup(original, true)
    XCTAssertTrue(settles(original, excluded: true))
    XCTAssertTrue(settles(inbox.root, excluded: false), "the directory itself is included")
    _ = try WatchRecordingInbox(root: inbox.root)
    XCTAssertTrue(settles(original, excluded: false), "cleared at the next open")
    XCTAssertTrue(
      settles(inbox.root.appendingPathComponent("tmp", isDirectory: true), excluded: true))
    XCTAssertEqual(try Data(contentsOf: original), data)
  }

  /// WATCH-009: the text an original gave is kept with it (its Home item is in the App Group,
  /// which is not in backups, so after a restore the item is made again from this). Nothing said
  /// keeps no text; the person's deletion removes it with the audio.
  func testTheTextIsKeptWithTheOriginalUntilItIsDeleted() throws {
    let root = WatchRecordingInbox.directory(in: base)
    let inbox = try WatchRecordingInbox(root: root)
    var ids: [String] = []
    for seed in [UInt8(3), 4] {
      let data = syntheticAudio(seed: seed)
      let recording = WatchRecording(
        id: WatchRecordingID.make(), startedAt: start, duration: 4, bytes: data.count,
        sha256: hex(data))
      _ = try inbox.accept(file: try received(data, in: base), metadata: recording.transferMetadata)
      ids.append(recording.id)
    }
    XCTAssertNil(inbox.record(id: ids[0])?.text, "nothing yet")
    try inbox.noteTranscribed(text: "合成：明早九点站会。", id: ids[0])
    try inbox.noteTranscribed(text: "", id: ids[1])

    let reopened = try WatchRecordingInbox(root: root)
    XCTAssertEqual(reopened.record(id: ids[0])?.transcription, .done)
    XCTAssertEqual(reopened.record(id: ids[0])?.text, "合成：明早九点站会。")
    XCTAssertEqual(reopened.record(id: ids[1])?.transcription, .noSpeech)
    XCTAssertNil(reopened.record(id: ids[1])?.text)
    XCTAssertEqual(reopened.pendingTranscription(), [])

    XCTAssertTrue(try reopened.delete(id: ids[0], at: start))
    let note = try XCTUnwrap(reopened.record(id: ids[0]))
    XCTAssertNotNil(note.deletedAt)
    XCTAssertNil(note.text, "the text goes with the recording")
    let json = try String(
      contentsOf: root.appendingPathComponent("\(ids[0]).json"), encoding: .utf8)
    XCTAssertFalse(json.contains("站会"))
  }

  func testInboxRefusesWhatDoesNotMatchItsDescription() throws {
    let inbox = try WatchRecordingInbox(root: WatchRecordingInbox.directory(in: base))
    let data = syntheticAudio()
    let id = WatchRecordingID.make()
    let truncated = try received(data.prefix(1000), in: base)
    let recording = WatchRecording(
      id: id, startedAt: start, duration: 4, bytes: data.count, sha256: hex(data))
    XCTAssertThrowsError(try inbox.accept(file: truncated, metadata: recording.transferMetadata)) {
      XCTAssertEqual($0 as? WatchRecordingInbox.AcceptError, .sizeMismatch)
    }
    var altered = data
    altered[10] ^= 0xFF
    XCTAssertThrowsError(
      try inbox.accept(file: try received(altered, in: base), metadata: recording.transferMetadata)
    ) { XCTAssertEqual($0 as? WatchRecordingInbox.AcceptError, .digestMismatch) }
    XCTAssertThrowsError(try inbox.accept(file: truncated, metadata: ["id": id])) {
      XCTAssertEqual($0 as? WatchRecordingInbox.AcceptError, .invalidDescription)
    }
    XCTAssertEqual(inbox.all(), [])

    // The same id with other bytes: the first stays, the second is refused.
    XCTAssertNoThrow(
      try inbox.accept(file: try received(data, in: base), metadata: recording.transferMetadata))
    let other = WatchRecording(
      id: id, startedAt: start, duration: 4, bytes: altered.count, sha256: hex(altered))
    XCTAssertThrowsError(
      try inbox.accept(file: try received(altered, in: base), metadata: other.transferMetadata)
    ) {
      XCTAssertEqual($0 as? WatchRecordingInbox.AcceptError, .conflict)
    }
    XCTAssertEqual(try Data(contentsOf: inbox.audioURL(id: id)), data)
  }

  /// Regression (review, 10-06): one original that could never be transcribed (cut inside its
  /// first frame, or always cut off by the time limit) stopped every later one, for good. A
  /// failed try pauses only that original (5 minutes, doubling), the next one is due at once, and
  /// after `maximumAttempts` it is marked failed and no longer waits; 「重新转写」 starts it over.
  func testAnOriginalThatKeepsFailingDoesNotHoldUpTheOthers() throws {
    let inbox = try WatchRecordingInbox(root: WatchRecordingInbox.directory(in: base))
    var ids: [String] = []
    for (index, data) in [syntheticAudio(5, seed: 1), syntheticAudio(seed: 2)].enumerated() {
      let recording = WatchRecording(
        id: WatchRecordingID.make(), startedAt: start.addingTimeInterval(Double(index) * 60),
        duration: 0, bytes: data.count, sha256: hex(data))
      _ = try inbox.accept(file: try received(data, in: base), metadata: recording.transferMetadata)
      ids.append(recording.id)
    }
    let (bad, good) = (ids[0], ids[1])
    XCTAssertEqual(inbox.dueForTranscription(now: start).map(\.id), [bad, good], "oldest first")

    var now = start
    try inbox.noteFailedAttempt(id: bad, at: now)
    XCTAssertEqual(inbox.dueForTranscription(now: now).map(\.id), [good])
    XCTAssertEqual(
      inbox.dueForTranscription(now: now.addingTimeInterval(ReceivedRecording.firstRetryPause))
        .map(\.id), [bad, good])
    now = now.addingTimeInterval(ReceivedRecording.firstRetryPause)
    try inbox.noteFailedAttempt(id: bad, at: now)
    XCTAssertEqual(
      inbox.dueForTranscription(now: now.addingTimeInterval(ReceivedRecording.firstRetryPause))
        .map(\.id), [good], "the pause doubles")
    now = now.addingTimeInterval(2 * ReceivedRecording.firstRetryPause)
    let last = try XCTUnwrap(inbox.noteFailedAttempt(id: bad, at: now))
    XCTAssertEqual(last.attempts, ReceivedRecording.maximumAttempts)
    XCTAssertEqual(last.transcription, .failed)
    XCTAssertEqual(inbox.pendingTranscription().map(\.id), [good])
    XCTAssertEqual(inbox.all().count, 2, "the original is kept")

    XCTAssertTrue(try inbox.retryTranscription(id: bad))
    XCTAssertEqual(inbox.record(id: bad)?.attempts, 0)
    XCTAssertEqual(inbox.dueForTranscription(now: now).map(\.id), [bad, good])
    XCTAssertFalse(try inbox.retryTranscription(id: good), "only failed or silent ones")
  }

  /// 「删除录音…」: the original goes; a copy the watch sends again is confirmed (so the watch
  /// removes it) and not stored again.
  func testADeletedOriginalIsConfirmedAndNotStoredAgain() throws {
    let inbox = try WatchRecordingInbox(root: WatchRecordingInbox.directory(in: base))
    let data = syntheticAudio()
    let recording = WatchRecording(
      id: WatchRecordingID.make(), startedAt: start, duration: 4, bytes: data.count,
      sha256: hex(data))
    _ = try inbox.accept(file: try received(data, in: base), metadata: recording.transferMetadata)
    XCTAssertTrue(try inbox.delete(id: recording.id, at: start))
    XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.audioURL(id: recording.id).path))
    XCTAssertEqual(inbox.all(), [])
    XCTAssertEqual(inbox.pendingTranscription(), [])
    XCTAssertEqual(
      try inbox.accept(file: try received(data, in: base), metadata: recording.transferMetadata),
      .duplicate(recording))
    XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.audioURL(id: recording.id).path))
    XCTAssertEqual(inbox.storedIDs(among: [recording.id]), [recording.id])
    XCTAssertFalse(try inbox.delete(id: recording.id), "already deleted")
  }

  // MARK: - Both sides

  /// The whole handoff with files standing in for WatchConnectivity: the watch records three, the
  /// iPhone is away for the first transfer, a duplicate arrives, and each recording leaves the
  /// watch only after the iPhone's "stored" for it.
  func testHandoffEndToEnd() throws {
    let queue = try WatchRecordingQueue(root: base.appendingPathComponent("watch"))
    let inbox = try WatchRecordingInbox(
      root: WatchRecordingInbox.directory(in: base.appendingPathComponent("phone")))
    let payloads = (0..<3).map { syntheticAudio(2048 + $0 * 512, seed: UInt8($0 + 10)) }
    var recordings: [WatchRecording] = []
    for (index, data) in payloads.enumerated() {
      recordings.append(
        try record(in: queue, bytes: data, at: start.addingTimeInterval(Double(index) * 30)))
    }

    // The iPhone is away: every transfer fails and nothing leaves the watch.
    for queued in queue.due(now: start, outstanding: []) {
      queue.markSending(id: queued.id, at: start)
      queue.markFailed(id: queued.id, at: start)
    }
    XCTAssertEqual(queue.pendingCount, 3)

    // Back in range: each file arrives (the first one twice) and the iPhone answers.
    let later = start.addingTimeInterval(WatchRecordingQueue.firstRetryPause)
    var acknowledged: [String] = []
    for queued in queue.due(now: later, outstanding: []) {
      queue.markSending(id: queued.id, at: later)
      let copy = try received(Data(contentsOf: queue.fileURL(id: queued.id)), in: base)
      let outcome = try inbox.accept(file: copy, metadata: queued.recording.transferMetadata)
      if case .stored(let stored) = outcome { acknowledged.append(stored.id) }
      queue.markDelivered(id: queued.id, at: later)
    }
    let again = try received(payloads[0], in: base)
    XCTAssertEqual(
      try inbox.accept(file: again, metadata: recordings[0].transferMetadata),
      .duplicate(recordings[0]))
    let message = try XCTUnwrap(
      WatchHandoffMessage(dictionary: WatchHandoffMessage.stored(acknowledged).dictionary))
    guard case .stored(let ids) = message else { return XCTFail("stored") }
    XCTAssertEqual(Set(queue.removeStored(ids)), Set(recordings.map(\.id)))
    XCTAssertEqual(queue.pendingCount, 0)
    for (recording, data) in zip(recordings, payloads) {
      XCTAssertEqual(try Data(contentsOf: inbox.audioURL(id: recording.id)), data)
    }
    // The watch asking about what it still holds gets the stored ones back.
    XCTAssertEqual(inbox.storedIDs(among: recordings.map(\.id)), recordings.map(\.id))
  }

  // MARK: - The backup notice (owner's decision 2026-10-06)

  func testTheBackupNoticeIsClaimedOnceEverAndSurvivesReopeningTheInbox() throws {
    let root = WatchRecordingInbox.directory(in: base)
    let inbox = try WatchRecordingInbox(root: root)
    XCTAssertTrue(inbox.claimBackupNotice(), "the first claim shows it")
    XCTAssertFalse(inbox.claimBackupNotice())
    XCTAssertFalse(inbox.claimBackupNotice())
    // A relaunch, a later recording, a restore that brings the folder back: never again.
    let reopened = try WatchRecordingInbox(root: root)
    XCTAssertFalse(reopened.claimBackupNotice())
    // The mark is not an original: nothing is listed or counted because of it.
    XCTAssertEqual(reopened.all().count, 0)
    // A different inbox (a fresh install) is a first time again.
    let other = try WatchRecordingInbox(
      root: WatchRecordingInbox.directory(in: base.appendingPathComponent("other")))
    XCTAssertTrue(other.claimBackupNotice())
  }

  func testTheBackupNoticeIsNotShownWhenItsMarkCannotBeKept() throws {
    let root = WatchRecordingInbox.directory(in: base)
    let inbox = try WatchRecordingInbox(root: root)
    // A directory where the mark file would go: it cannot be created, so it must not be shown.
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("backup-notice-shown", isDirectory: true),
      withIntermediateDirectories: false)
    XCTAssertFalse(inbox.claimBackupNotice())
  }

  func testTheBackupNoticeNamesTheBackupsAndMakesNoPromise() {
    let text = WatchRecordingInbox.BackupNotice.message
    XCTAssertTrue(text.contains("iCloud 云备份"))
    XCTAssertTrue(text.contains("加密备份"))
    XCTAssertTrue(text.contains("这台 iPhone"))
    for banned in ["不会", "放心", "安全", "只在", "只保存", "一下", "去设置", "吧"] {
      XCTAssertFalse(text.contains(banned), banned)
    }
  }
}
