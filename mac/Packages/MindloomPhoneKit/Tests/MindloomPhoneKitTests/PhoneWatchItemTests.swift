import CryptoKit
import Foundation
import MindloomLink
import XCTest

@testable import MindloomPhoneKit

/// Recordings from Apple Watch on the iPhone (WATCH-004, WATCH-005): one item per recording, shown
/// while it is transcribed, then sent to the Mac as text under 「口述」 with the origin "Apple
/// Watch"; every step can run twice; the item is kept as long as its recording.
final class PhoneWatchItemTests: XCTestCase {
  private var base: URL!
  private var items: PhoneItemStore!
  private var outbox: OutboxStore!
  private var pairing: PairingRecordStore!
  private var collector: PhoneItemCollector!
  private let id = "0f8e7c1a-2b3d-4e5f-8a9b-0c1d2e3f4a5b"

  override func setUpWithError() throws {
    base = try makeTemporaryDirectory()
    items = try PhoneItemStore(root: base.appendingPathComponent("items"))
    outbox = try OutboxStore(root: base.appendingPathComponent("outbox"))
    pairing = PairingRecordStore(file: base.appendingPathComponent("pairing.json"))
    collector = PhoneItemCollector(items: items, outbox: outbox, pairing: pairing, signaling: nil)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: base)
  }

  private func pair() throws {
    let hostLine = PairingPayload.openSSHPublicKey(Curve25519.Signing.PrivateKey().publicKey)
    let payload = try PairingPayload(
      label: "合成的 MacBook",
      spark: PairingEndpoint(
        host: "spark.example", port: 22, user: "mindloom",
        hostKey: XCTUnwrap(SSHHostKey(openSSH: hostLine))),
      relay: nil, phoneKey: Curve25519.Signing.PrivateKey().rawRepresentation,
      phoneKeyID: "phone-1234", macSealPublicKey: testMacKey.publicKey.rawRepresentation)
    try pairing.write(payload.record)
  }

  func testRecordingShowsAtOnceAndOnlyOnce() throws {
    let shown = try collector.recordWatchRecording(id: id, startedAt: baseDate, seconds: 4.2)
    XCTAssertEqual(shown.id, id)
    XCTAssertEqual(shown.source, .watch)
    XCTAssertEqual(shown.createdAt, baseDate)
    XCTAssertEqual(shown.recordingID, id)
    XCTAssertEqual(shown.recordingSeconds, 4.2)
    XCTAssertEqual(shown.awaitingTranscription, true)
    XCTAssertNil(shown.text)
    XCTAssertEqual(
      collector.delivery(of: shown), .onPhone, "waiting for its text: still on the iPhone")
    try collector.recordWatchRecording(
      id: id, startedAt: baseDate.addingTimeInterval(9), seconds: 1)
    XCTAssertEqual(items.all(), [shown])
  }

  func testTextGoesToTheMacFromAppleWatchOnce() throws {
    try pair()
    try collector.recordWatchRecording(id: id, startedAt: baseDate, seconds: 4.2)
    let done = try collector.completeWatchRecording(
      id: id, startedAt: baseDate, seconds: 4.2, text: " 合成：明早九点站会。 ", now: baseDate)
    XCTAssertEqual(done.text, "合成：明早九点站会。")
    XCTAssertNil(done.awaitingTranscription)
    XCTAssertEqual(done.entryIDs.count, 1)
    let entry = try XCTUnwrap(outbox.entry(id: done.entryIDs[0]))
    XCTAssertEqual(entry.source, .voice, "a source every Mac since v11 opens")
    XCTAssertEqual(entry.kind, .text)
    XCTAssertEqual(entry.createdAt, baseDate, "the time recording started on the watch")
    let payload = try InboxItemPayload.decode(
      MindloomSeal.open(XCTUnwrap(entry.wire), entryID: entry.entryID, with: testMacKey))
    XCTAssertEqual(payload.source, .voice)
    XCTAssertEqual(payload.origin, "Apple Watch")
    XCTAssertEqual(payload.shownSource, "Apple Watch")
    XCTAssertEqual(payload.text, "合成：明早九点站会。")

    // Run again (a crash after the item was saved): no second entry, no change.
    let again = try collector.completeWatchRecording(
      id: id, startedAt: baseDate, seconds: 4.2, text: "合成：另一段", now: baseDate)
    XCTAssertEqual(again, done)
    XCTAssertEqual(try outbox.queued().count, 1)
  }

  /// 「撤回」 does not apply to the item of a kept recording (its recording would bring it back).
  func testItemOfAKeptRecordingIsNotWithdrawn() throws {
    try collector.recordWatchRecording(id: id, startedAt: baseDate, seconds: 3)
    XCTAssertFalse(try collector.withdraw(id: id))
    XCTAssertEqual(items.all().map(\.id), [id])
  }

  func testWithoutAMacTheTextWaitsForPairing() throws {
    let done = try collector.completeWatchRecording(
      id: id, startedAt: baseDate, seconds: 2, text: "合成：周五前回邮件。", now: baseDate)
    XCTAssertTrue(done.awaitingPairing)
    XCTAssertEqual(items.unsealed(id: id)?.map(\.shownSource), ["Apple Watch"])
    try pair()
    XCTAssertEqual(try collector.sealAwaitingItems(now: baseDate), 1)
    XCTAssertEqual(try outbox.queued().map(\.source), [.voice])
  }

  func testNothingSaidSendsNothingAndKeepsTheRecording() throws {
    try pair()
    try collector.recordWatchRecording(id: id, startedAt: baseDate, seconds: 3)
    let done = try collector.completeWatchRecording(
      id: id, startedAt: baseDate, seconds: 3, text: "  ", now: baseDate)
    XCTAssertNil(done.text)
    XCTAssertNil(done.awaitingTranscription)
    XCTAssertEqual(done.entryIDs, [])
    XCTAssertEqual(try outbox.queued(), [])
    XCTAssertFalse(collector.delivery(of: done).isOnPhone)
  }

  /// Regression: delivered items are pruned after 7 days, but an item of a kept recording stays
  /// as long as the recording (WATCH-004: recordings are kept until the person deletes them).
  func testPruneKeepsItemsOfKeptRecordings() throws {
    try pair()
    let watch = try collector.completeWatchRecording(
      id: id, startedAt: baseDate, seconds: 3, text: "合成：手表上的一句。", now: baseDate)
    let voice = try collector.collect(
      PhoneItem(createdAt: baseDate, kind: .text, source: .voice, text: "合成：口述的一句。"),
      payloads: [try InboxItemPayload.text("合成：口述的一句。", source: .voice, createdAt: baseDate)],
      now: baseDate)
    for entryID in watch.entryIDs + voice.entryIDs {
      try outbox.markSent(id: entryID, at: baseDate)
    }
    XCTAssertEqual(collector.prune(now: baseDate.addingTimeInterval(30 * 24 * 3600)), 1)
    XCTAssertEqual(items.all().map(\.id), [id])
  }

  /// Regression (review, 10-06): the outbox forgets a sent part 7 days after it was sent, and the
  /// item of a kept recording stays; Home then said 「未能发送」 for every watch item older than a
  /// week. The delivery is written onto the item before the outbox prunes, and a part forgotten
  /// before that (another process pruned) still counts as sent.
  func testAWatchItemStaysSentAfterTheOutboxForgetsItsPart() throws {
    try pair()
    let sentAt = baseDate.addingTimeInterval(120)
    let done = try collector.completeWatchRecording(
      id: id, startedAt: baseDate, seconds: 3, text: "合成：手表上的一句。", now: baseDate)
    try outbox.markSent(id: done.entryIDs[0], at: sentAt)
    XCTAssertEqual(collector.delivery(of: done), .sent(at: sentAt))

    let later = sentAt.addingTimeInterval(OutboxEntry.sentRetention + 24 * 3600)
    collector.prune(now: later)
    XCTAssertGreaterThan(try outbox.prune(now: later), 0, "the sent part is forgotten")
    XCTAssertNil(try outbox.entry(id: done.entryIDs[0]))
    let kept = try XCTUnwrap(items.item(id: id))
    XCTAssertEqual(kept.sentAt, sentAt)
    XCTAssertEqual(collector.delivery(of: kept, now: later), .sent(at: sentAt))

    // The same without the note on the item (the outbox was pruned first, as a delivery does).
    let other = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    let second = try collector.completeWatchRecording(
      id: other, startedAt: baseDate, seconds: 2, text: "合成：另一句。", now: baseDate)
    try outbox.markSent(id: second.entryIDs[0], at: sentAt)
    _ = try outbox.prune(now: later)
    XCTAssertEqual(
      collector.delivery(of: try XCTUnwrap(items.item(id: other)), now: later), .sent(at: nil))
    // Within its first 7 days a missing part was never sent.
    XCTAssertEqual(
      collector.delivery(
        of: try XCTUnwrap(items.item(id: other)), now: baseDate.addingTimeInterval(3600)),
      .notSent)
  }

  /// A recording that cannot be transcribed stops waiting (「无法转写音频」, nothing sent) and
  /// 「重新转写」 makes it wait again; an item with text is never retried.
  func testAFailedRecordingStopsWaitingAndCanBeTriedAgain() throws {
    try pair()
    try collector.recordWatchRecording(id: id, startedAt: baseDate, seconds: 3)
    let failed = try XCTUnwrap(collector.failWatchRecording(id: id))
    XCTAssertNil(failed.awaitingTranscription)
    XCTAssertNil(failed.text)
    XCTAssertEqual(try outbox.queued(), [])
    XCTAssertTrue(try collector.retryWatchRecording(id: id))
    XCTAssertEqual(items.item(id: id)?.awaitingTranscription, true)
    XCTAssertFalse(try collector.retryWatchRecording(id: id), "already waiting")
    let done = try collector.completeWatchRecording(
      id: id, startedAt: baseDate, seconds: 3, text: "合成：重试后的一句。", now: baseDate)
    XCTAssertEqual(done.entryIDs.count, 1)
    XCTAssertFalse(try collector.retryWatchRecording(id: id), "has its text")
  }

  /// 「删除录音…」: the item goes with its parts that have not left and the previews of those that
  /// did (no orphan row on Home); other items are not touched.
  func testDeletingAWatchItemTakesItsUnsentPartsAlong() throws {
    try pair()
    let queued = try collector.completeWatchRecording(
      id: id, startedAt: baseDate, seconds: 3, text: "合成：还没送出的一句。", now: baseDate)
    let other = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    let sent = try collector.completeWatchRecording(
      id: other, startedAt: baseDate, seconds: 3, text: "合成：已送出的一句。", now: baseDate)
    try outbox.markSent(id: sent.entryIDs[0], at: baseDate)
    let voice = try collector.collect(
      PhoneItem(createdAt: baseDate, kind: .text, source: .voice, text: "合成：口述。"),
      payloads: [try InboxItemPayload.text("合成：口述。", source: .voice, createdAt: baseDate)],
      now: baseDate)

    XCTAssertTrue(try collector.removeWatchRecordingItem(id: id))
    XCTAssertNil(items.item(id: id))
    XCTAssertNil(try outbox.entry(id: queued.entryIDs[0]), "the unsent part is withdrawn")
    XCTAssertTrue(try collector.removeWatchRecordingItem(id: other))
    XCTAssertNil(
      try outbox.entry(id: sent.entryIDs[0]),
      "the sent part's preview goes too (the Mac keeps what it received)")
    XCTAssertFalse(try collector.removeWatchRecordingItem(id: voice.id), "only watch items")
    XCTAssertEqual(items.all().map(\.id), [voice.id])
  }

  /// Regression (review, 10-06, WATCH-009): a restore from a backup brought the originals back
  /// without their items (the App Group is not in backups), and an original that was already
  /// transcribed could then not be seen, retried or deleted. Its item is made again: with its text
  /// (not sent again), or with none (「无法转写音频」, 「重新转写」), and it can be deleted.
  func testARestoredRecordingGetsItsItemBack() throws {
    try pair()
    let withText = try collector.restoreWatchRecordingItem(
      id: id, startedAt: baseDate, seconds: 4.2, text: "合成：恢复后的一句。")
    XCTAssertEqual(withText.source, .watch)
    XCTAssertEqual(withText.createdAt, baseDate)
    XCTAssertEqual(withText.recordingID, id)
    XCTAssertEqual(withText.recordingSeconds, 4.2)
    XCTAssertEqual(withText.text, "合成：恢复后的一句。")
    XCTAssertNil(withText.awaitingTranscription)
    XCTAssertEqual(withText.entryIDs, [])
    XCTAssertEqual(try outbox.queued(), [], "not sent again")
    XCTAssertEqual(
      collector.delivery(of: withText), .sent(at: nil), "left the iPhone before the backup")
    XCTAssertFalse(try collector.retryWatchRecording(id: id), "has its text")
    // Made again a second time (the next launch): nothing changes.
    XCTAssertEqual(
      try collector.restoreWatchRecordingItem(id: id, startedAt: baseDate, seconds: 1, text: nil),
      withText)

    let other = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    let noText = try collector.restoreWatchRecordingItem(
      id: other, startedAt: baseDate, seconds: 3, text: " ")
    XCTAssertNil(noText.text)
    XCTAssertNil(noText.awaitingTranscription, "「无法转写音频」, not 「正在转写…」")
    XCTAssertTrue(try collector.retryWatchRecording(id: other), "「重新转写」 works")
    XCTAssertEqual(items.item(id: other)?.awaitingTranscription, true)

    XCTAssertTrue(try collector.removeWatchRecordingItem(id: id), "「删除录音…」 works")
    XCTAssertTrue(try collector.removeWatchRecordingItem(id: other))
    XCTAssertEqual(items.all(), [])
  }
}
