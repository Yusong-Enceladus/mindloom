import CryptoKit
import Foundation
import MindloomLink
import XCTest

@testable import MindloomPhoneKit

/// Regressions for the fix-ios review (withdraw against delivery, re-pairing, lost parts, the
/// screenshot records that must never outlive their run).
final class V11ReviewRegressionTests: XCTestCase {
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
    collector = PhoneItemCollector(items: items, outbox: outbox, pairing: pairing, signaling: nil)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: base)
  }

  private func pair(macKey: Curve25519.KeyAgreement.PrivateKey = testMacKey) throws {
    let hostLine = PairingPayload.openSSHPublicKey(Curve25519.Signing.PrivateKey().publicKey)
    let payload = try PairingPayload(
      label: "合成的 MacBook",
      spark: PairingEndpoint(
        host: "spark.example", port: 22, user: "mindloom",
        hostKey: XCTUnwrap(SSHHostKey(openSSH: hostLine))),
      relay: nil, phoneKey: Curve25519.Signing.PrivateKey().rawRepresentation,
      phoneKeyID: "phone-1234", macSealPublicKey: macKey.publicKey.rawRepresentation)
    try pairing.write(payload.record)
  }

  private func keepText(_ text: String = "合成：周三交报告。") throws -> PhoneItem {
    let item = PhoneItem(createdAt: baseDate, kind: .text, source: .voice, text: text)
    let payload = try InboxItemPayload.text(text, source: .voice, createdAt: baseDate)
    return try collector.collect(item, payloads: [payload], now: baseDate)
  }

  func testAnEntryBeingSentCannotBeWithdrawn() throws {
    try pair()
    let saved = try keepText()
    let id = saved.entryIDs[0]
    XCTAssertNotNil(try outbox.beginSending(id: id))
    XCTAssertEqual(try outbox.withdraw(id: id), .inFlight)
    XCTAssertFalse(try collector.withdraw(id: saved.id), "in flight: the item stays")
    XCTAssertEqual(items.all().count, 1)
    try outbox.markSent(id: id, at: baseDate)
    XCTAssertEqual(try outbox.withdraw(id: id), .alreadySent)
  }

  func testAWithdrawnEntryIsNeverClaimedForSending() throws {
    try pair()
    let saved = try keepText()
    XCTAssertTrue(try collector.withdraw(id: saved.id))
    XCTAssertNil(try outbox.beginSending(id: saved.entryIDs[0]))
  }

  func testWithdrawDuringARunIsNotSent() async throws {
    let first = try makeEntry("合成：第一条", at: 1)
    let second = try makeEntry("合成：第二条", at: 2)
    try outbox.add(first)
    try outbox.add(second)
    let inbox = FakeInbox()
    let store = outbox!
    inbox.onAdd = { id in
      if id == first.entryID { _ = try? store.withdraw(id: second.entryID) }
    }
    let deliverer = OutboxDeliverer(store: outbox, opener: inbox, clock: { baseDate })
    _ = await deliverer.deliverQueued()
    XCTAssertEqual(inbox.order, [first.entryID], "the withdrawn entry never left")
  }

  func testEntriesSealedToAnEarlierMacStayAndReadAsNotSent() async throws {
    let oldMac = Curve25519.KeyAgreement.PrivateKey()
    try pair(macKey: oldMac)
    let old = try keepText("合成：旧 Mac 的一条")
    try pair()
    let current = try keepText("合成：新 Mac 的一条")
    let currentKey = try XCTUnwrap(pairing.read()?.sealKeyID)
    let inbox = FakeInbox()
    let deliverer = OutboxDeliverer(
      store: outbox, opener: inbox, sealKeyID: currentKey, clock: { baseDate.addingTimeInterval(60) })
    _ = await deliverer.deliverQueued()
    XCTAssertEqual(inbox.order, current.entryIDs)
    XCTAssertEqual(try outbox.entry(id: old.entryIDs[0])?.state, .queued, "never marked sent")
    XCTAssertEqual(collector.delivery(of: old), .notSent)
    XCTAssertEqual(collector.delivery(of: try XCTUnwrap(items.item(id: current.id))).isOnPhone, false)
  }

  func testAMissingPartIsNotSent() throws {
    try pair()
    let saved = try keepText()
    let file = base.appendingPathComponent("outbox/queued/\(saved.entryIDs[0]).json")
    try FileManager.default.removeItem(at: file)
    XCTAssertEqual(collector.delivery(of: saved), .notSent)
  }

  func testScreenshotRecordsExpire() throws {
    let channel = try VoiceChannel(directory: base.appendingPathComponent("voice"))
    let now = Date()
    channel.writeDebugKeyboardScreen("kb-listen", now: now)
    XCTAssertEqual(channel.readDebugKeyboardScreen(now: now.addingTimeInterval(60)), "kb-listen")
    XCTAssertNil(
      channel.readDebugKeyboardScreen(
        now: now.addingTimeInterval(VoiceChannel.debugRecordLifetime + 1)))
    try channel.records.write(Data("kb-listen".utf8), as: "debug-keyboard")
    XCTAssertNil(channel.readDebugKeyboardScreen(now: now), "a record without its time is ignored")
  }
}
