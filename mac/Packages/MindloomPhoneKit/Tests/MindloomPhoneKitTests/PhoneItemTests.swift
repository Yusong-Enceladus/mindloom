import CryptoKit
import Foundation
import MindloomLink
import XCTest

@testable import MindloomPhoneKit

/// What the user sent, as the phone keeps it (PHONE-SPEC §8): sealed and queued with a Mac, kept
/// unsealed until pairing without one, withdrawn without a trace, delivered state from the outbox.
final class PhoneItemTests: XCTestCase {
  private var base: URL!
  private var items: PhoneItemStore!
  private var outbox: OutboxStore!
  private var pairing: PairingRecordStore!
  private var collector: PhoneItemCollector!

  override func setUpWithError() throws {
    base = try makeTemporaryDirectory()
    items = try PhoneItemStore(root: base.appendingPathComponent("items"))
    outbox = try OutboxStore(root: base.appendingPathComponent("outbox"))
    pairing = PairingRecordStore(file: base.appendingPathComponent("pairing.json"))
    collector = PhoneItemCollector(
      items: items, outbox: outbox, pairing: pairing, signaling: nil)
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

  private func voiceItem(_ text: String = "合成：组会改到周三下午。", at offset: TimeInterval = 0)
    throws -> (PhoneItem, [InboxItemPayload])
  {
    let at = baseDate.addingTimeInterval(offset)
    return (
      PhoneItem(createdAt: at, kind: .text, source: .voice, text: text),
      [try InboxItemPayload.text(text, source: .voice, createdAt: at)]
    )
  }

  func testPairedItemIsSealedAndHeld() throws {
    try pair()
    let (item, payloads) = try voiceItem()
    let saved = try collector.collect(
      item, payloads: payloads, heldUntil: baseDate.addingTimeInterval(3.6), now: baseDate)
    XCTAssertFalse(saved.awaitingPairing)
    XCTAssertEqual(saved.entryIDs.count, 1)
    XCTAssertEqual(items.all(), [saved])
    XCTAssertEqual(try outbox.held(now: baseDate).map(\.entryID), saved.entryIDs)
    XCTAssertEqual(try outbox.queued(now: baseDate), [])
    XCTAssertEqual(try outbox.entry(id: saved.entryIDs[0])?.source, .voice)
    XCTAssertEqual(collector.delivery(of: saved), .onPhone)

    let sentAt = baseDate.addingTimeInterval(9)
    XCTAssertEqual(try outbox.queued(now: baseDate.addingTimeInterval(4)).count, 1)
    try outbox.markSent(id: saved.entryIDs[0], at: sentAt)
    XCTAssertEqual(collector.delivery(of: saved), .sent(at: sentAt))
  }

  func testUndoWithdrawsItemAndEntries() throws {
    try pair()
    let (item, payloads) = try voiceItem()
    let saved = try collector.collect(
      item, payloads: payloads, heldUntil: baseDate.addingTimeInterval(3.6), now: baseDate)
    XCTAssertTrue(try collector.withdraw(id: saved.id))
    XCTAssertEqual(items.all(), [])
    XCTAssertEqual(try outbox.counts(now: baseDate.addingTimeInterval(10)).queued, 0)
    XCTAssertFalse(try collector.withdraw(id: saved.id), "nothing left to withdraw")
  }

  func testSentItemCannotBeWithdrawn() throws {
    try pair()
    let (item, payloads) = try voiceItem()
    let saved = try collector.collect(item, payloads: payloads, now: baseDate)
    try outbox.markSent(id: saved.entryIDs[0], at: baseDate)
    XCTAssertFalse(try collector.withdraw(id: saved.id))
    XCTAssertEqual(items.all().count, 1)
  }

  func testUnpairedItemWaitsUnsealedThenIsSealedAfterPairing() throws {
    let (item, payloads) = try voiceItem()
    let saved = try collector.collect(item, payloads: payloads, now: baseDate)
    XCTAssertTrue(saved.awaitingPairing)
    XCTAssertEqual(saved.entryIDs, [])
    XCTAssertEqual(collector.delivery(of: saved), .onPhone)
    XCTAssertEqual(items.unsealed(id: saved.id), payloads)
    XCTAssertEqual(try outbox.counts(now: baseDate).queued, 0)

    try pair()
    XCTAssertEqual(try collector.sealAwaitingItems(now: baseDate), 1)
    let sealed = try XCTUnwrap(items.item(id: saved.id))
    XCTAssertFalse(sealed.awaitingPairing)
    XCTAssertEqual(sealed.entryIDs.count, 1)
    XCTAssertNil(items.unsealed(id: saved.id), "no plaintext left once sealed")
    XCTAssertEqual(try outbox.queued(now: baseDate).map(\.entryID), sealed.entryIDs)
    XCTAssertEqual(try collector.sealAwaitingItems(now: baseDate), 0, "idempotent")
  }

  func testPhotosKeepPreviewsAndRemoveThemWithTheItem() throws {
    try pair()
    let png = Data(base64Encoded: tinyPNG)!
    let payloads = try (0..<2).map { _ in
      try InboxItemPayload.image(png, mime: "image/png", source: .share, createdAt: baseDate)
    }
    let item = PhoneItem(createdAt: baseDate, kind: .photos, source: .share, photoCount: 2)
    try items.writePreview(Data([0xFF, 0xD8, 0xFF]), id: item.id, index: 0)
    try items.writePreview(Data([0xFF, 0xD8, 0xFF]), id: item.id, index: 1)
    let saved = try collector.collect(item, payloads: payloads, now: baseDate)
    XCTAssertEqual(saved.entryIDs.count, 2)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: items.previewURL(id: saved.id, index: 1).path))
    XCTAssertTrue(try collector.withdraw(id: saved.id))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: items.previewURL(id: saved.id, index: 0).path))
  }

  func testPruneKeepsPendingAndRecentItems() throws {
    try pair()
    let (oldSent, p1) = try voiceItem("合成：旧的", at: 0)
    let (oldPending, p2) = try voiceItem("合成：旧的还没送出", at: 1)
    let (recent, p3) = try voiceItem("合成：新的", at: 6 * 24 * 3600)
    let a = try collector.collect(oldSent, payloads: p1, now: baseDate)
    try collector.collect(oldPending, payloads: p2, now: baseDate)
    try collector.collect(recent, payloads: p3, now: baseDate)
    try outbox.markSent(id: a.entryIDs[0], at: baseDate)
    let now = baseDate.addingTimeInterval(8 * 24 * 3600)
    XCTAssertEqual(collector.prune(now: now), 1)
    XCTAssertEqual(Set(items.all().map(\.id)), [oldPending.id, recent.id])
  }

  func testItemsAreNewestFirstAndSurviveReopen() throws {
    let (first, p1) = try voiceItem("合成：先", at: 0)
    let (second, p2) = try voiceItem("合成：后", at: 5)
    try collector.collect(first, payloads: p1)
    try collector.collect(second, payloads: p2)
    let reopened = try PhoneItemStore(root: base.appendingPathComponent("items"))
    XCTAssertEqual(reopened.all().map(\.id), [second.id, first.id])
    XCTAssertEqual(reopened.item(id: first.id)?.text, "合成：先")
  }

  func testLinkDomain() {
    XCTAssertEqual(
      PhoneItem.Link(url: "https://www.mp.weixin.qq.com/s/abc").domain, "mp.weixin.qq.com")
    XCTAssertEqual(PhoneItem.Link(url: "https://example.org/x").domain, "example.org")
  }

  func testShareNoteKeepsTheItemBackThenTravelsWithIt() throws {
    try pair()
    let at = baseDate
    let url = try XCTUnwrap(URL(string: "https://example.com/a"))
    let item = PhoneItem(
      createdAt: at, kind: .link, source: .share, link: .init(url: url.absoluteString))
    let payload = try InboxItemPayload.link(url, source: .share, createdAt: at)
    let saved = try collector.collect(
      item, payloads: [payload], heldUntil: at.addingTimeInterval(3), now: at)
    // 加一句: the hold is extended while the note is typed.
    XCTAssertTrue(try collector.extendHold(id: saved.id, until: at.addingTimeInterval(600)))
    XCTAssertEqual(try outbox.queued(now: at.addingTimeInterval(30)), [])
    XCTAssertEqual(try outbox.held(now: at.addingTimeInterval(30)).count, 1)
    // 完成: the note is one more part of the same item, and the item shows it.
    let note = try InboxItemPayload.text("合成：明天会上要问。", source: .share, createdAt: at)
    let noted = try XCTUnwrap(
      collector.attachNote(id: saved.id, note: "  合成：明天会上要问。 ", payload: note, now: at))
    XCTAssertEqual(noted.note, "合成：明天会上要问。")
    XCTAssertEqual(noted.entryIDs.count, 2)
    try collector.release(id: saved.id)
    XCTAssertEqual(try outbox.queued(now: at.addingTimeInterval(31)).count, 2)
  }

  func testEmptyNoteChangesNothingAndASentItemCannotBeHeld() throws {
    try pair()
    let (item, payloads) = try voiceItem()
    let saved = try collector.collect(item, payloads: payloads, now: baseDate)
    XCTAssertFalse(try collector.extendHold(id: saved.id, until: baseDate.addingTimeInterval(60)))
    let note = try InboxItemPayload.text("x", source: .share, createdAt: baseDate)
    let same = try collector.attachNote(id: saved.id, note: "   ", payload: note, now: baseDate)
    XCTAssertEqual(same, saved)
  }

  func testNoteBeforePairingWaitsWithTheItem() throws {
    let (item, payloads) = try voiceItem()
    let saved = try collector.collect(item, payloads: payloads, now: baseDate)
    let note = try InboxItemPayload.text("合成：备注", source: .share, createdAt: baseDate)
    _ = try collector.attachNote(id: saved.id, note: "合成：备注", payload: note, now: baseDate)
    XCTAssertEqual(items.unsealed(id: saved.id)?.count, 2)
    try pair()
    XCTAssertEqual(try collector.sealAwaitingItems(now: baseDate), 1)
    XCTAssertEqual(try outbox.queued(now: baseDate).count, 2)
  }
}

/// A 1 × 1 PNG (synthetic).
let tinyPNG =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
