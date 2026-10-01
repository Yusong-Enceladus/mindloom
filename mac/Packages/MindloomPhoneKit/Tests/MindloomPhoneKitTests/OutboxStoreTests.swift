import CryptoKit
import Foundation
import MindloomLink
import XCTest

@testable import MindloomPhoneKit

func makeTemporaryDirectory(_ name: String = #function) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("mindloom-phone-tests", isDirectory: true)
    .appendingPathComponent("\(name.filter(\.isLetter))-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

let testMacKey = Curve25519.KeyAgreement.PrivateKey()
let baseDate = Date(timeIntervalSince1970: 1_790_730_902)

func makeEntry(
  _ text: String = "合成：明早九点站会", at offset: TimeInterval = 0, id: String = EntryID.make()
)
  throws -> OutboxEntry
{
  try OutboxEntry.seal(
    InboxItemPayload.text(text, source: .keyboard, createdAt: baseDate.addingTimeInterval(offset)),
    to: testMacKey.publicKey, entryID: id)
}

final class OutboxStoreTests: XCTestCase {
  private var root: URL!
  private var store: OutboxStore!

  override func setUpWithError() throws {
    root = try makeTemporaryDirectory().appendingPathComponent("outbox")
    store = try OutboxStore(root: root)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
  }

  func testAddIsIdempotentByEntryID() throws {
    let entry = try makeEntry()
    XCTAssertEqual(try store.add(entry), .added)
    XCTAssertEqual(try store.add(entry), .alreadyQueued)
    let resealed = try makeEntry("另一段话", id: entry.entryID)
    XCTAssertEqual(try store.add(resealed), .alreadyQueued, "the first entry with an id wins")
    XCTAssertEqual(try store.queued(), [entry])
    try store.markSent(id: entry.entryID, at: baseDate)
    XCTAssertEqual(try store.add(entry), .alreadySent)
    XCTAssertEqual(try store.queued(), [])
  }

  func testQueuedIsOldestFirst() throws {
    let late = try makeEntry("晚", at: 30)
    let early = try makeEntry("早", at: 10)
    let middle = try makeEntry("中", at: 20)
    for entry in [late, early, middle] { try store.add(entry) }
    XCTAssertEqual(try store.queued().map(\.entryID), [early, middle, late].map(\.entryID))
  }

  func testStateMachineQueuedToSent() throws {
    let entry = try makeEntry()
    try store.add(entry)
    let failed = try XCTUnwrap(
      try store.recordFailure(id: entry.entryID, category: .network, at: baseDate))
    XCTAssertEqual(failed.attempts, 1)
    XCTAssertEqual(try store.entry(id: entry.entryID)?.lastError, .network)

    let sentAt = baseDate.addingTimeInterval(5)
    let sent = try XCTUnwrap(try store.markSent(id: entry.entryID, at: sentAt, duplicate: true))
    XCTAssertEqual(sent.state, .sent)
    XCTAssertNil(sent.wire)
    XCTAssertTrue(sent.duplicate)
    XCTAssertEqual(try store.queued(), [])
    XCTAssertEqual(try store.sent(now: sentAt), [sent])
    XCTAssertEqual(try store.entry(id: entry.entryID), sent)

    // Idempotent, and a sent entry never takes failures again.
    XCTAssertEqual(try store.markSent(id: entry.entryID, at: sentAt.addingTimeInterval(60)), sent)
    XCTAssertNil(try store.recordFailure(id: entry.entryID, category: .timeout))
    XCTAssertNil(try store.markSent(id: EntryID.make()))
    XCTAssertNil(try store.markSent(id: "../../escape"))
  }

  func testSentFilesKeepNoSealedPayload() throws {
    let entry = try makeEntry()
    try store.add(entry)
    let queuedFile = root.appendingPathComponent("queued/\(entry.entryID).json")
    XCTAssertTrue(try String(contentsOf: queuedFile, encoding: .utf8).contains("mlseal1."))
    try store.markSent(id: entry.entryID, at: baseDate)
    XCTAssertFalse(FileManager.default.fileExists(atPath: queuedFile.path))
    let sentFile = root.appendingPathComponent("sent/\(entry.entryID).json")
    let sentText = try String(contentsOf: sentFile, encoding: .utf8)
    XCTAssertFalse(sentText.contains("mlseal1."))
    XCTAssertTrue(sentText.contains(try XCTUnwrap(entry.preview)))
  }

  func testSentPreviewsLastSevenDays() throws {
    let old = try makeEntry("旧")
    let recent = try makeEntry("新")
    try store.add(old)
    try store.add(recent)
    try store.markSent(id: old.entryID, at: baseDate)
    try store.markSent(id: recent.entryID, at: baseDate.addingTimeInterval(3 * 24 * 3600))
    let now = baseDate.addingTimeInterval(7 * 24 * 3600 + 1)
    XCTAssertEqual(
      try store.sent(now: now).map(\.entryID), [recent.entryID], "expired ones are hidden")
    XCTAssertEqual(try store.prune(now: now), 1)
    XCTAssertNil(try store.entry(id: old.entryID), "and removed on prune")
    XCTAssertNotNil(try store.entry(id: recent.entryID))
    XCTAssertEqual(try store.counts(now: now), .init(queued: 0, sent: 1))
  }

  /// A crash after `sent/` is written but before `queued/` is removed must
  /// not send the entry again.
  func testCrashBetweenSentAndQueuedRemoval() throws {
    let entry = try makeEntry()
    try store.add(entry)
    let queuedFile = root.appendingPathComponent("queued/\(entry.entryID).json")
    let backup = try Data(contentsOf: queuedFile)
    try store.markSent(id: entry.entryID, at: baseDate)
    try backup.write(to: queuedFile)  // simulate the crash window

    XCTAssertEqual(try store.queued(), [], "the sent copy wins")
    XCTAssertEqual(try store.entry(id: entry.entryID)?.state, .sent)
    try store.prune(now: baseDate)
    XCTAssertFalse(FileManager.default.fileExists(atPath: queuedFile.path))
  }

  /// A leftover staging file (crash before rename) is ignored and cleaned up.
  func testCrashBeforeRenameLeavesOnlyStaging() throws {
    let staging = root.appendingPathComponent("tmp/\(EntryID.make()).abc.tmp")
    try Data("{\"half\":".utf8).write(to: staging)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-2 * 3600)], ofItemAtPath: staging.path)
    XCTAssertEqual(try store.queued(), [])
    try store.prune()
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
  }

  func testUnreadableFilesAreQuarantinedNotDeleted() throws {
    let good = try makeEntry()
    try store.add(good)
    let badID = EntryID.make()
    try Data("garbage".utf8).write(to: root.appendingPathComponent("queued/\(badID).json"))
    let other = try makeEntry()
    // A valid entry stored under the wrong name is also refused.
    try other.encoded().write(to: root.appendingPathComponent("queued/\(EntryID.make()).json"))
    try Data("x".utf8).write(to: root.appendingPathComponent("queued/not-an-id.json"))

    XCTAssertEqual(try store.queued(), [good])
    XCTAssertEqual(store.quarantinedCount(), 2)
    XCTAssertEqual(try store.queued(), [good], "stable after quarantine")
  }

  func testReopeningSeesTheSameEntries() throws {
    let entries = try (0..<5).map { try makeEntry("第\($0)条", at: TimeInterval($0)) }
    for entry in entries { try store.add(entry) }
    try store.markSent(id: entries[1].entryID, at: baseDate)
    let reopened = try OutboxStore(root: root)
    XCTAssertEqual(try reopened.queued().map(\.entryID), [0, 2, 3, 4].map { entries[$0].entryID })
    XCTAssertEqual(try reopened.sent(now: baseDate).map(\.entryID), [entries[1].entryID])
  }

  func testOutboxIsExcludedFromBackup() throws {
    let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
  }

  func testOnlyQueuedEntriesCanBeAdded() throws {
    let sent = try makeEntry().markingSent(at: baseDate)
    XCTAssertThrowsError(try store.add(sent))
  }

  /// Concurrent adds from many tasks (as from the app and extensions) all land.
  func testConcurrentAddsAllLand() async throws {
    let entries = try (0..<40).map { try makeEntry("并发\($0)", at: TimeInterval($0)) }
    let store = self.store!
    await withTaskGroup(of: Void.self) { group in
      for entry in entries {
        group.addTask { _ = try? store.add(entry) }
        group.addTask { _ = try? store.add(entry) }
      }
    }
    XCTAssertEqual(try store.queued().map(\.entryID), entries.map(\.entryID))
    let tmp = try FileManager.default.contentsOfDirectory(
      atPath: root.appendingPathComponent("tmp").path)
    XCTAssertEqual(tmp, [], "no staging files left behind")
  }

  /// Two store instances on one directory behave like two processes.
  func testTwoInstancesShareTheOutbox() throws {
    let extensionSide = try OutboxStore(root: root)
    let entry = try makeEntry()
    XCTAssertEqual(try extensionSide.add(entry), .added)
    XCTAssertEqual(try store.queued(), [entry])
    try store.markSent(id: entry.entryID, at: baseDate)
    XCTAssertEqual(try extensionSide.add(entry), .alreadySent)
  }

  func testAppGroupIdentifiers() {
    XCTAssertEqual(PhoneAppGroup.identifier, "group.com.bestasr.phone")
    XCTAssertEqual(PhoneAppGroup.keyboardBundleID, "com.bestasr.phone.keyboard")
    XCTAssertEqual(PhoneAppGroup.shareBundleID, "com.bestasr.phone.share")
    let container = URL(fileURLWithPath: "/tmp/container")
    XCTAssertEqual(PhoneAppGroup.outboxDirectory(in: container).path, "/tmp/container/outbox")
  }
}
