import CryptoKit
import Foundation
import MindloomLink
import XCTest

final class OutboxEntryTests: XCTestCase {
  private let mac = Curve25519.KeyAgreement.PrivateKey()

  private func queuedText(_ text: String = "合成：下周一交实验报告") throws -> OutboxEntry {
    try OutboxEntry.seal(
      InboxItemPayload.text(text, source: .keyboard, createdAt: fixedDate, timeZone: shanghai),
      to: mac.publicKey, now: fixedDate)
  }

  func testQueuedEntryHoldsOnlyTheSealAndAPreview() throws {
    let sentinel = "TAIL-SENTINEL-4242"
    let text = String(repeating: "前面的话。", count: 30) + sentinel
    let entry = try queuedText(text)
    XCTAssertEqual(entry.state, .queued)
    XCTAssertTrue(EntryID.isValid(entry.entryID))
    XCTAssertEqual(entry.kind, .text)
    XCTAssertEqual(entry.source, .keyboard)
    XCTAssertEqual(entry.createdAt, fixedDate)
    XCTAssertEqual(entry.sealKeyID, MindloomSeal.keyID(for: mac.publicKey))
    XCTAssertEqual(entry.attempts, 0)

    let json = String(decoding: try entry.encoded(), as: UTF8.self)
    XCTAssertFalse(json.contains(sentinel), "only the short preview is stored in clear")
    XCTAssertTrue(json.contains("\"state\":\"queued\""))
    XCTAssertTrue(json.contains("\"entry_id\":\"\(entry.entryID)\""))
    XCTAssertTrue(json.contains("\"created_at_ms\":1790730902500"))

    // The Mac opens the stored wire under the entry id and gets the item back.
    let opened = try InboxItemPayload.decode(
      MindloomSeal.open(XCTUnwrap(entry.wire), entryID: entry.entryID, with: mac))
    XCTAssertEqual(opened.text, text)
    XCTAssertEqual(opened.createdAt, "2026-09-30T09:15:02.500+08:00")
  }

  func testEncodingRoundTripsExactly() throws {
    let queued = try queuedText()
    XCTAssertEqual(try OutboxEntry.decode(queued.encoded()), queued)
    let failed = queued.recordingFailure(.network, at: fixedDate.addingTimeInterval(1.234))
    XCTAssertEqual(try OutboxEntry.decode(failed.encoded()), failed)
    let sent = failed.markingSent(at: fixedDate.addingTimeInterval(60.5), duplicate: true)
    XCTAssertEqual(try OutboxEntry.decode(sent.encoded()), sent)
    let json = String(decoding: try sent.encoded(), as: UTF8.self)
    XCTAssertTrue(json.contains("\"state\":\"sent\""))
    XCTAssertFalse(json.contains("\"wire\""))
    XCTAssertTrue(json.contains("\"duplicate\":true"))
  }

  func testQueuedToSentDropsTheSealAndIsIdempotent() throws {
    let queued = try queuedText()
    let failed = queued.recordingFailure(.timeout, at: fixedDate)
    XCTAssertEqual(failed.state, .queued)
    XCTAssertEqual(failed.attempts, 1)
    XCTAssertEqual(failed.lastError, .timeout)
    XCTAssertNotNil(failed.wire)

    let sentAt = fixedDate.addingTimeInterval(30)
    let sent = failed.markingSent(at: sentAt)
    XCTAssertEqual(sent.state, .sent)
    XCTAssertNil(sent.wire)
    XCTAssertEqual(sent.preview, queued.preview)
    XCTAssertEqual(sent.sentAt, sentAt)
    XCTAssertNil(sent.lastError)
    XCTAssertEqual(sent.attempts, 2)
    XCTAssertEqual(sent.markingSent(at: sentAt.addingTimeInterval(99)), sent)
    XCTAssertEqual(
      sent.recordingFailure(.network, at: sentAt), sent, "a sent entry never goes back")
  }

  func testImagesKeepNoPreview() throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    let entry = try OutboxEntry.seal(
      InboxItemPayload.image(png, mime: "image/png", filename: "截图.png", source: .share),
      to: mac.publicKey)
    XCTAssertNil(entry.preview)
    XCTAssertNil(entry.markingSent(at: Date()).preview)
    let sneaky = try OutboxEntry(
      entryID: EntryID.make(), kind: .image, source: .share, createdAt: Date(),
      sealKeyID: "0123456789abcdef", wire: "mlseal1.AAAA", preview: "should be dropped")
    XCTAssertNil(sneaky.preview)
  }

  func testSentPreviewsExpireAfterSevenDays() throws {
    let sentAt = fixedDate
    let sent = try queuedText().markingSent(at: sentAt)
    XCTAssertFalse(sent.isExpired(now: sentAt.addingTimeInterval(OutboxEntry.sentRetention - 1)))
    XCTAssertTrue(sent.isExpired(now: sentAt.addingTimeInterval(OutboxEntry.sentRetention)))
    XCTAssertFalse(try queuedText().isExpired(now: .distantFuture), "queued entries never expire")
  }

  func testInvalidStoredEntriesAreRejected() throws {
    let queued = try JSONSerialization.jsonObject(with: queuedText().encoded()) as! [String: Any]
    func decode(_ change: (inout [String: Any]) -> Void) throws -> OutboxEntry {
      var object = queued
      change(&object)
      return try OutboxEntry.decode(JSONSerialization.data(withJSONObject: object))
    }
    assertThrows(OutboxEntry.EntryError.invalidState) { try decode { $0["wire"] = nil } }
    assertThrows(OutboxEntry.EntryError.invalidState) { try decode { $0["wire"] = "plaintext!" } }
    assertThrows(OutboxEntry.EntryError.invalidState) { try decode { $0["state"] = "sent" } }
    assertThrows(OutboxEntry.EntryError.invalidEntryID) { try decode { $0["entry_id"] = "../x" } }
    assertThrows(OutboxEntry.EntryError.unsupportedVersion(9)) { try decode { $0["v"] = 9 } }
    XCTAssertThrowsError(try decode { $0["state"] = "sending" })
  }

  func testErrorCategoriesSayWhetherRetryingHelps() {
    XCTAssertTrue(DeliveryErrorCategory.network.isTransient)
    XCTAssertTrue(DeliveryErrorCategory.timeout.isTransient)
    XCTAssertFalse(DeliveryErrorCategory.hostKeyMismatch.isTransient)
    XCTAssertFalse(DeliveryErrorCategory.authentication.isTransient)
    XCTAssertFalse(DeliveryErrorCategory.rejected.isTransient)
  }
}
