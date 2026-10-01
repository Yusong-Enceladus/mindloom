import AppKit
import BestASRDomain
import BestASRIntake
import BestASRPersistence
import BestASRRemoteOrganizer
import CryptoKit
import Foundation
import MindloomLink
import XCTest

/// PHONE-CONTRACT §5 (Mac ingest) and §6 (Mac tests): what the iPhone app
/// sealed to this Mac's seal key waits in the organizing device's inbox as
/// an opaque `mlseal1.` blob; the Mac opens it, takes it in through the real
/// intake into a real store as a user item whose source and time come from
/// the payload, commits, then acknowledges. An entry that does not open is
/// acknowledged, dropped and counted once. Fake organizing device, synthetic
/// data only.
@MainActor
final class PhoneLinkInboxTests: XCTestCase {
  private let enabledAt = Date(timeIntervalSince1970: 500)

  private func png() throws -> Data {
    let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
      NSColor.systemIndigo.setFill()
      rect.fill()
      return true
    }
    let tiff = try XCTUnwrap(image.tiffRepresentation)
    return try XCTUnwrap(
      NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
  }

  private struct Harness {
    let library: SyntheticOrganizerLibrary
    let assets: URL
    let spark: FakeSpark
    let ingestor: IntakeInboxIngestor
  }

  private func harness(sealKey: @escaping IntakeInboxIngestor.SealKeyProvider) throws -> Harness {
    let library = try SyntheticOrganizerLibrary()
    let assets = library.root.appendingPathComponent("assets", isDirectory: true)
    let processor = IntakeProcessor(
      assetStore: IntakeAssetStore(assetRoot: assets), pathPolicy: .none, imageReader: nil)
    return Harness(
      library: library, assets: assets, spark: FakeSpark(),
      ingestor: IntakeInboxIngestor(processor: processor, store: library.store, sealKey: sealKey))
  }

  private func runtime(
    _ harness: Harness, discarded: @escaping (RemoteOrganizerInboxDiscard) -> Void
  )
    -> RemoteOrganizerRuntime
  {
    RemoteOrganizerRuntime(
      repository: harness.library.store, launcher: FakeTunnelLauncher(), http: harness.spark,
      keys: testOrganizerKeys,
      itemAssetReader: RemoteOrganizerItemAssetReader(assetRoot: harness.assets),
      imageRedactor: IdentityRedactor(), inbox: harness.ingestor, timing: fastTiming,
      onUpdate: { _, _ in }
    ).withInboxDiscardHandler(discarded)
  }

  /// What the phone puts in the inbox: `{inbox_id, kind: sealed, blob,
  /// received_at}`, sealed with the real `MindloomSeal`.
  private func sealedEntry(
    _ payload: InboxItemPayload, to key: Curve25519.KeyAgreement.PublicKey,
    id: String = EntryID.make(), deliveredAs: String? = nil
  ) throws -> (id: String, entry: [String: Any]) {
    let wire = try MindloomSeal.seal(try payload.encoded(), entryID: id, to: key)
    return (
      deliveredAs ?? id,
      [
        "inbox_id": deliveredAs ?? id, "kind": "sealed", "blob": wire,
        "received_at": "2026-09-30T08:00:00.000000+08:00",
      ]
    )
  }

  private func sessionID(_ inboxID: String) -> String {
    RemoteOrganizerInboxEntry(
      inboxID: inboxID, source: "", kind: .sealed, text: nil, imageData: nil, receivedAt: Date()
    ).sessionID.rawValue.uuidString
  }

  func testSealedEntriesBecomeUserItemsWithThePayloadsSourceAndTime() async throws {
    let macKey = Curve25519.KeyAgreement.PrivateKey()
    let keys = MemoryPhoneSealKeyStore(key: macKey)
    let harness = try harness(sealKey: { try keys.load() })
    try await harness.library.store.enableRemoteLink(at: enabledAt)
    let beijing = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
    let spoken = Date(timeIntervalSince1970: 1_790_000_000.345)
    let shared = Date(timeIntervalSince1970: 1_790_000_600)

    let text = try sealedEntry(
      .text(
        "虚构口述：周五下午把展板送到二楼会议室。", source: .keyboard, createdAt: spoken,
        timeZone: beijing),
      to: macKey.publicKey)
    let link = try sealedEntry(
      .link(
        try XCTUnwrap(URL(string: "https://unreachable.invalid/exhibit?id=7")),
        title: "虚构展览安排", text: "周末看看", source: .share, createdAt: shared,
        timeZone: beijing),
      to: macKey.publicKey)
    let image = try sealedEntry(
      .image(try png(), mime: "image/png", source: .share, createdAt: shared, timeZone: beijing),
      to: macKey.publicKey)
    let file = try sealedEntry(
      .file(
        Data("虚构清单：画框两个，挂钩四个。\n".utf8), filename: "清单.txt", mime: "text/plain",
        source: .share, createdAt: shared, timeZone: beijing),
      to: macKey.publicKey)
    for entry in [text, link, image, file] { harness.spark.addInbox(entry.entry) }
    // The first acknowledgement fails: the entry comes again and is found,
    // not taken in twice.
    harness.spark.failInboxAcks(1)

    var dropped: [RemoteOrganizerInboxDiscard] = []
    let runtime = runtime(harness) { dropped.append($0) }
    runtime.start()
    try await waitUntil(timeout: 15) {
      harness.spark.items.count == 4 && harness.spark.acked.count == 4
    }
    runtime.stop()

    XCTAssertEqual(Set(harness.spark.acked), Set([text.id, link.id, image.id, file.id]))
    XCTAssertEqual(harness.spark.inboxLeft, 0, "every opened entry is deleted there")
    XCTAssertEqual(dropped, [])
    let userItems = try await harness.library.scalar(
      "SELECT COUNT(*) FROM sessions WHERE input_mode = 'userItem'")
    XCTAssertEqual(userItems, "4", "each entry committed exactly once")

    let sent = Dictionary(
      uniqueKeysWithValues: harness.spark.items.map { (($0["item_id"] as? String) ?? "", $0) })
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func started(_ body: [String: Any]) -> Date? {
      (body["started_at"] as? String).flatMap(formatter.date(from:))
    }
    func source(_ body: [String: Any]) -> String? {
      (body["source_app"] as? [String: Any])?["name"] as? String
    }

    let sentText = try XCTUnwrap(sent[sessionID(text.id)])
    XCTAssertEqual(sentText["kind"] as? String, "text")
    XCTAssertEqual(sentText["text"] as? String, "虚构口述：周五下午把展板送到二楼会议室。")
    XCTAssertEqual(source(sentText), "iPhone 键盘")
    XCTAssertEqual(
      try XCTUnwrap(started(sentText)).timeIntervalSince1970, spoken.timeIntervalSince1970,
      accuracy: 0.002, "the time it was said on the phone, not when it reached the inbox")

    let sentLink = try XCTUnwrap(sent[sessionID(link.id)])
    XCTAssertEqual(source(sentLink), "iPhone 分享")
    XCTAssertEqual(
      sentLink["text"] as? String,
      "虚构展览安排\n周末看看\nhttps://unreachable.invalid/exhibit?id=7")
    XCTAssertEqual(
      try XCTUnwrap(started(sentLink)).timeIntervalSince1970, shared.timeIntervalSince1970,
      accuracy: 0.002)

    let sentImage = try XCTUnwrap(sent[sessionID(image.id)])
    XCTAssertEqual(sentImage["kind"] as? String, "image")
    XCTAssertEqual(source(sentImage), "iPhone 分享")
    XCTAssertFalse((sentImage["image_b64"] as? String ?? "").isEmpty)

    let sentFile = try XCTUnwrap(sent[sessionID(file.id)])
    XCTAssertEqual(source(sentFile), "iPhone 分享")
    XCTAssertEqual(sentFile["text"] as? String, "虚构清单：画框两个，挂钩四个。\n", "read on this Mac")

    // The file went through the file rules and its scratch copy is gone.
    let leftovers = try FileManager.default.contentsOfDirectory(
      atPath: FileManager.default.temporaryDirectory.path
    ).filter { $0.hasPrefix("bestasr-inbox-") }
    XCTAssertEqual(leftovers, [])
    // Nothing on the wire is the sealed blob.
    for body in harness.spark.items {
      XCTAssertFalse(String(describing: body).contains(MindloomSeal.wirePrefix))
    }
    await harness.library.close()
  }

  func testEntriesThatDoNotOpenAreAcknowledgedDroppedAndCountedOnce() async throws {
    let macKey = Curve25519.KeyAgreement.PrivateKey()
    let oldKey = Curve25519.KeyAgreement.PrivateKey()
    let keys = MemoryPhoneSealKeyStore(key: macKey)
    let harness = try harness(sealKey: { try keys.load() })
    try await harness.library.store.enableRemoteLink(at: enabledAt)
    let payload = try InboxItemPayload.text("虚构：给旧配对的一句话。", source: .keyboard)

    // Sealed to the key of an earlier pairing.
    let stale = try sealedEntry(payload, to: oldKey.publicKey)
    // Changed on the way: one character of the ciphertext flipped.
    var tampered = try sealedEntry(payload, to: macKey.publicKey)
    var blob = Array(try XCTUnwrap(tampered.entry["blob"] as? String))
    let index = blob.count - 30
    blob[index] = blob[index] == "A" ? "B" : "A"
    tampered.entry["blob"] = String(blob)
    // Moved to another inbox ID (the ID is the seal's associated data).
    let moved = try sealedEntry(payload, to: macKey.publicKey, deliveredAs: EntryID.make())
    // Opens, but is not an item (a hand-made plaintext that fails validation).
    let junkID = EntryID.make()
    let junk = try MindloomSeal.seal(
      Data(#"{"v":1,"kind":"text","source":"iPhone 键盘","created_at":"yesterday","text":"x"}"#.utf8),
      entryID: junkID, to: macKey.publicKey)
    let unusable: (id: String, entry: [String: Any]) = (
      junkID,
      [
        "inbox_id": junkID, "kind": "sealed", "blob": junk,
        "received_at": "2026-09-30T08:00:00+08:00",
      ]
    )
    for entry in [stale, tampered, moved, unusable] { harness.spark.addInbox(entry.entry) }
    // The first acknowledgement fails: the entry is dropped when it comes
    // again, and counted only then.
    harness.spark.failInboxAcks(1)

    var dropped: [RemoteOrganizerInboxDiscard] = []
    let runtime = runtime(harness) { dropped.append($0) }
    runtime.start()
    try await waitUntil(timeout: 10) { harness.spark.acked.count == 4 }
    try await Task.sleep(for: .milliseconds(200))
    runtime.stop()

    XCTAssertEqual(harness.spark.inboxLeft, 0, "nothing that can never open stays there")
    XCTAssertEqual(dropped.filter { $0 == .cannotOpen }.count, 3)
    XCTAssertEqual(dropped.filter { $0 == .unusable }.count, 1)
    let userItems = try await harness.library.scalar(
      "SELECT COUNT(*) FROM sessions WHERE input_mode = 'userItem'")
    XCTAssertEqual(userItems, "0")
    XCTAssertEqual(harness.spark.items.count, 0)

    // The visible status (PHONE-CONTRACT §5.4), kept across launches.
    let state = try makeTemporaryDirectory()
    let file = PhonePairingStateFile(stateDirectory: state, dataRoot: harness.library.root)
    for reason in dropped { file.recordDropped(reason) }
    let reread = PhonePairingStateFile(stateDirectory: state, dataRoot: harness.library.root)
    XCTAssertEqual(reread.droppedCounts(), [.cannotOpen: 3, .unusable: 1])
    XCTAssertEqual(
      PhoneInboxDropNotice.text(.cannotOpen, count: 3), "3 条手机内容无法打开（配对已更换）")
    reread.clearDropped()
    XCTAssertEqual(file.droppedCounts(), [:])
    await harness.library.close()
  }

  func testWithoutASealKeyEntriesAreDroppedAndAnUnreadableKeychainLeavesThem() async throws {
    // Never paired on this library: nothing can open, the entry is dropped.
    let payload = try InboxItemPayload.text("虚构：没有配对。", source: .share)
    let other = Curve25519.KeyAgreement.PrivateKey()
    let entry = try sealedEntry(payload, to: other.publicKey)
    let page = try JSONDecoder().decode(
      RemoteOrganizerInboxPage.self,
      from: try JSONSerialization.data(withJSONObject: ["cursor": 1, "items": [entry.entry]]))
    let parsed = try XCTUnwrap(page.entries.first)
    let none = try harness(sealKey: { nil })
    let outcome = try await none.ingestor.ingest(parsed)
    XCTAssertEqual(outcome, .discarded(.cannotOpen))
    XCTAssertTrue(outcome.acknowledges)
    await none.library.close()

    // The Keychain cannot be read right now: not the entry's fault, so it is
    // neither acknowledged nor counted; the pull tries again later.
    let broken = MemoryPhoneSealKeyStore(key: other)
    broken.failLoads = true
    let failing = try harness(sealKey: { try broken.load() })
    do {
      _ = try await failing.ingestor.ingest(parsed)
      XCTFail("an unreadable key store must not drop the entry")
    } catch {}
    broken.failLoads = false
    let retried = try await failing.ingestor.ingest(parsed)
    guard case .committed = retried else { return XCTFail("\(retried)") }
    await failing.library.close()
  }

  func testSealedInboxEntriesParseStrictly() throws {
    XCTAssertEqual(
      RemoteOrganizerInboxEntry.maximumSealedBlobBytes, MindloomSeal.maximumWireBytes,
      "the Mac accepts exactly the longest wire string a phone can send")
    let id = EntryID.make()
    let page = try JSONDecoder().decode(
      RemoteOrganizerInboxPage.self,
      from: Data(
        """
        {"cursor": 3, "items": [
          {"inbox_id": "\(id)", "kind": "sealed", "blob": "mlseal1.AAAA", "received_at": "2026-09-30T08:00:00+08:00", "seq": 3},
          {"inbox_id": "b", "kind": "sealed", "received_at": "2026-09-30T08:00:00+08:00"},
          {"inbox_id": "c", "kind": "sealed", "blob": "plain text", "received_at": "2026-09-30T08:00:00+08:00"},
          {"inbox_id": "d", "kind": "sealed", "blob": "mlseal1.\(String(repeating: "A", count: MindloomSeal.maximumWireBytes))", "received_at": "2026-09-30T08:00:00+08:00"}
        ]}
        """.utf8))
    XCTAssertEqual(
      page.entries.map(\.inboxID), [id], "no blob, no prefix or too long: not an entry")
    let entry = try XCTUnwrap(page.entries.first)
    XCTAssertEqual(entry.kind, .sealed)
    XCTAssertEqual(entry.sealedBlob, "mlseal1.AAAA")
    XCTAssertNil(entry.text)
    XCTAssertNil(entry.imageData)
    // Opening needs the exact lowercase ID it was sealed under.
    let key = Curve25519.KeyAgreement.PrivateKey()
    let wire = try MindloomSeal.seal(
      try InboxItemPayload.text("虚构", source: .keyboard).encoded(), entryID: id, to: key.publicKey)
    let upper = RemoteOrganizerInboxEntry(
      inboxID: id.uppercased(), source: "", kind: .sealed, text: nil, imageData: nil,
      sealedBlob: wire, receivedAt: Date())
    XCTAssertEqual(IntakeInboxIngestor.open(upper, with: key), .failure(.cannotOpen))
    let exact = RemoteOrganizerInboxEntry(
      inboxID: id, source: "", kind: .sealed, text: nil, imageData: nil, sealedBlob: wire,
      receivedAt: Date())
    guard case .success(let payload) = IntakeInboxIngestor.open(exact, with: key) else {
      return XCTFail("the exact ID opens")
    }
    XCTAssertEqual(payload.text, "虚构")
  }
}
