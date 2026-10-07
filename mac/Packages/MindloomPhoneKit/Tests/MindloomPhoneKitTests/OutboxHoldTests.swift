import CryptoKit
import Foundation
import MindloomLink
import XCTest

@testable import MindloomPhoneKit

/// The undo window (PHONE-SPEC §7.1, 「已收好 · 撤销」 for 3 s): an entry is held before it can be
/// sent, can be withdrawn without a trace, and is never lost if the app dies during the hold.
final class OutboxHoldTests: XCTestCase {
  private var root: URL!
  private var store: OutboxStore!

  override func setUpWithError() throws {
    root = try makeTemporaryDirectory().appendingPathComponent("outbox")
    store = try OutboxStore(root: root)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
  }

  func testHeldEntryIsNotQueuedUntilItsHoldEnds() throws {
    let entry = try makeEntry()
    let until = baseDate.addingTimeInterval(3)
    XCTAssertEqual(try store.add(entry, heldUntil: until), .added)
    XCTAssertEqual(try store.add(entry, heldUntil: until), .alreadyQueued, "idempotent by id")
    XCTAssertEqual(try store.add(entry), .alreadyQueued)

    XCTAssertEqual(try store.queued(now: baseDate.addingTimeInterval(1)), [], "never sent early")
    XCTAssertEqual(try store.held(now: baseDate.addingTimeInterval(1)), [entry])
    XCTAssertEqual(try store.nextHoldEnd(now: baseDate), until)
    XCTAssertEqual(try store.counts(now: baseDate.addingTimeInterval(1)).queued, 1, "on the phone")
    XCTAssertEqual(try store.entry(id: entry.entryID), entry)

    XCTAssertEqual(try store.queued(now: until), [entry], "after the hold it is an ordinary entry")
    XCTAssertEqual(try store.held(now: until), [])
    XCTAssertNil(try store.nextHoldEnd(now: until))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("held/\(entry.entryID).json").path))
  }

  func testWithdrawDuringTheHoldLeavesNothing() throws {
    let entry = try makeEntry()
    try store.add(entry, heldUntil: baseDate.addingTimeInterval(3))
    XCTAssertEqual(try store.withdraw(id: entry.entryID), .withdrawn)
    XCTAssertNil(try store.entry(id: entry.entryID))
    XCTAssertEqual(try store.queued(now: baseDate.addingTimeInterval(10)), [])
    XCTAssertEqual(try store.withdraw(id: entry.entryID), .unknown)
    for directory in ["held", "queued", "sent"] {
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(
          atPath: root.appendingPathComponent(directory).path), [], directory)
    }
  }

  func testWithdrawQueuedButNotSent() throws {
    let queued = try makeEntry("合成：排队的")
    let sent = try makeEntry("合成：已经到 Mac 的")
    try store.add(queued)
    try store.add(sent)
    try store.markSent(id: sent.entryID, at: baseDate)
    XCTAssertEqual(try store.withdraw(id: queued.entryID), .withdrawn)
    XCTAssertEqual(try store.withdraw(id: sent.entryID), .alreadySent)
    XCTAssertEqual(try store.entry(id: sent.entryID)?.state, .sent, "a sent entry stays")
    XCTAssertEqual(try store.withdraw(id: "../escape"), .unknown)
  }

  func testReleaseEndsTheHoldEarly() throws {
    let entry = try makeEntry()
    try store.add(entry, heldUntil: Date().addingTimeInterval(60))
    XCTAssertEqual(try store.queued(), [])
    try store.release(id: entry.entryID)
    XCTAssertEqual(try store.queued(), [entry])
    try store.release(id: entry.entryID)  // idempotent
    XCTAssertEqual(try store.queued(), [entry])
  }

  /// The app dies during the undo window: the next run sends the entry anyway.
  func testHoldSurvivesARestart() throws {
    let entry = try makeEntry()
    try store.add(entry, heldUntil: baseDate.addingTimeInterval(3))
    let reopened = try OutboxStore(root: root)
    XCTAssertEqual(try reopened.queued(now: baseDate.addingTimeInterval(4)), [entry])
  }

  func testUnreadableHeldFileIsQuarantined() throws {
    let id = EntryID.make()
    try Data("{\"until_ms\":1".utf8).write(
      to: root.appendingPathComponent("held/\(id).json"))
    XCTAssertEqual(try store.held(now: baseDate), [])
    XCTAssertEqual(store.quarantinedCount(), 1)
  }

  func testPruneRemovesHeldCopiesOfSentEntries() throws {
    let entry = try makeEntry()
    try store.add(entry)
    try store.markSent(id: entry.entryID, at: baseDate)
    let held = OutboxStore.HeldEntry(untilMillis: 0, entry: entry)
    try held.encoded().write(to: root.appendingPathComponent("held/\(entry.entryID).json"))
    try store.prune(now: baseDate)
    XCTAssertEqual(try store.queued(now: baseDate), [])
    XCTAssertEqual(try store.entry(id: entry.entryID)?.state, .sent)
  }
}
