import AppKit
import BestASRDomain
import BestASRIntake
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import XCTest

/// The legacy plain phone entry: what an iOS Shortcut left in the organizing
/// device's inbox before the phone path became sealed-only (privacy review
/// F9) is still pulled, taken in through the real intake into a real store
/// as a user item from "iPhone", acknowledged only after the local commit,
/// and then sent for organizing (masked) like any item. The Mac only reads
/// and acknowledges the inbox; it never adds to it. Fake Spark, synthetic
/// data only.
@MainActor
final class RemoteOrganizerInboxTests: XCTestCase {
  private let enabledAt = Date(timeIntervalSince1970: 500)

  private func png() throws -> Data {
    let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
      NSColor.systemTeal.setFill()
      rect.fill()
      return true
    }
    let tiff = try XCTUnwrap(image.tiffRepresentation)
    return try XCTUnwrap(
      NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
  }

  func testInboxEntriesBecomeItemsFromIPhoneAckedAfterCommitAndSentOnce() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let assets = library.root.appendingPathComponent("assets", isDirectory: true)
    let processor = IntakeProcessor(
      assetStore: IntakeAssetStore(assetRoot: assets), pathPolicy: .none, imageReader: nil)
    let recorder = Recorder()
    let ingestor = IntakeInboxIngestor(
      processor: processor, store: library.store,
      committed: { id in await recorder.add(id) })

    let spark = FakeSpark()
    spark.addInbox([
      "inbox_id": "ib-1", "source": "iPhone", "kind": "text",
      "text": "虚构备忘：周六上午去取装裱好的画。", "received_at": "2026-09-26T08:15:00.123456+08:00",
    ])
    spark.addInbox([
      "inbox_id": "ib-2", "source": "iPhone", "kind": "image",
      "image_b64": try png().base64EncodedString(), "received_at": "2026-09-26T08:20:00+08:00",
    ])
    // No words: never taken in, so it stays on the organizing device.
    spark.addInbox([
      "inbox_id": "ib-3", "source": "iPhone", "kind": "text", "text": "   ",
      "received_at": "2026-09-26T08:25:00+08:00",
    ])
    // The first acknowledgement fails: the entry comes again and is not
    // taken in twice.
    spark.failInboxAcks(1)

    let runtime = RemoteOrganizerRuntime(
      repository: library.store, launcher: FakeTunnelLauncher(), http: spark,
      keys: testOrganizerKeys,
      itemAssetReader: RemoteOrganizerItemAssetReader(assetRoot: assets),
      imageRedactor: IdentityRedactor(), inbox: ingestor, timing: fastTiming, onUpdate: { _, _ in })
    runtime.start()
    try await waitUntil(timeout: 10) { spark.items.count == 2 && spark.acked.count == 2 }
    runtime.stop()

    XCTAssertEqual(Set(spark.acked), ["ib-1", "ib-2"])
    XCTAssertEqual(spark.inboxLeft, 1, "a refused entry is never acknowledged")
    // F9: the sealed phone path is the only way into the inbox; this Mac
    // reads it and acknowledges entries, and never creates one.
    let inboxCalls = spark.requests.filter { $0.path.hasPrefix("/v1/inbox") }
    XCTAssertFalse(inboxCalls.isEmpty)
    for call in inboxCalls {
      let read = call.method == "GET" && call.path.hasPrefix("/v1/inbox?since=")
      let ack =
        call.method == "POST" && call.path.hasPrefix("/v1/inbox/") && call.path.hasSuffix("/ack")
      XCTAssertTrue(read || ack, "\(call.method) \(call.path)")
    }
    let text = RemoteOrganizerInboxEntry(
      inboxID: "ib-1", source: "iPhone", kind: .text, text: nil, imageData: nil,
      receivedAt: Date()
    ).sessionID
    let image = RemoteOrganizerInboxEntry(
      inboxID: "ib-2", source: "iPhone", kind: .image, text: nil, imageData: nil,
      receivedAt: Date()
    ).sessionID
    let committedIDs = await recorder.ids
    XCTAssertEqual(committedIDs, [text, image], "each entry committed exactly once")
    let userItems = try await library.scalar(
      "SELECT COUNT(*) FROM sessions WHERE input_mode = 'userItem'")
    XCTAssertEqual(userItems, "2")

    // Sent like any item: its source App is the phone, its time when the
    // organizing device received it.
    let sent = Dictionary(
      uniqueKeysWithValues: spark.items.map { (($0["item_id"] as? String) ?? "", $0) })
    let sentText = try XCTUnwrap(sent[text.rawValue.uuidString])
    XCTAssertEqual(sentText["kind"] as? String, "text")
    XCTAssertEqual((sentText["source_app"] as? [String: Any])?["name"] as? String, "iPhone")
    XCTAssertEqual(sentText["text"] as? String, "虚构备忘：周六上午去取装裱好的画。")
    let started = try XCTUnwrap(sentText["started_at"] as? String)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    XCTAssertEqual(
      formatter.date(from: started).map { Int($0.timeIntervalSince1970) },
      Int(ISO8601DateFormatter().date(from: "2026-09-26T08:15:00+08:00")!.timeIntervalSince1970))
    let sentImage = try XCTUnwrap(sent[image.rawValue.uuidString])
    XCTAssertEqual(sentImage["kind"] as? String, "image")
    XCTAssertFalse((sentImage["image_b64"] as? String ?? "").isEmpty)
    await library.close()
  }

  func testAnOrganizerWithoutAnInboxIsAskedOnce() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    final class NoIngest: RemoteOrganizerInboxIngesting {
      func ingest(_ entry: RemoteOrganizerInboxEntry) async throws -> RemoteOrganizerInboxOutcome {
        XCTFail("nothing to ingest")
        return .refused("")
      }
    }
    // A service without the endpoint: 404 for /v1/inbox.
    let spark = OldSpark()
    let runtime = RemoteOrganizerRuntime(
      repository: library.store, launcher: FakeTunnelLauncher(), http: spark,
      keys: testOrganizerKeys, inbox: NoIngest(),
      timing: fastTiming, onUpdate: { _, _ in })
    runtime.start()
    try await waitUntil { spark.statePulls >= 3 }
    runtime.stop()
    XCTAssertEqual(spark.inboxPulls, 1)
    await library.close()
  }

  func testInboxPageDecodesLeniently() throws {
    let page = try JSONDecoder().decode(
      RemoteOrganizerInboxPage.self,
      from: Data(
        #"""
        {"cursor": 7, "items": [
          {"inbox_id": "a", "kind": "text", "text": "虚构", "received_at": "2026-09-26T08:15:00+08:00"},
          {"id": 42, "source": "iPad", "kind": "text", "text": "虚构二", "received_at": "2026-09-26T08:16:00Z"},
          {"inbox_id": "b", "kind": "video", "received_at": "2026-09-26T08:15:00+08:00"},
          {"inbox_id": "c", "kind": "image", "image_b64": "!!!", "received_at": "2026-09-26T08:15:00+08:00"},
          {"inbox_id": "d", "kind": "text", "text": "x"},
          "junk"
        ]}
        """#.utf8))
    XCTAssertEqual(page.cursor, 7)
    XCTAssertEqual(page.entries.map(\.inboxID), ["a", "42"])
    XCTAssertEqual(page.entries.map(\.source), ["iPhone", "iPad"])
    // Stable per entry, different across entries.
    XCTAssertEqual(page.entries[0].sessionID, page.entries[0].sessionID)
    XCTAssertNotEqual(page.entries[0].sessionID, page.entries[1].sessionID)
    XCTAssertEqual(page.entries[0].sessionID.rawValue.uuidString.dropFirst(14).first, "5")
  }
}

private actor Recorder {
  private(set) var ids: [SessionID] = []
  func add(_ id: SessionID) { ids.append(id) }
}

/// A Spark service from before the phone entry: no inbox endpoint.
private final class OldSpark: RemoteOrganizerHTTPTransport, @unchecked Sendable {
  private let base = FakeSpark()
  private let lock = NSLock()
  private var _inboxPulls = 0
  private var _statePulls = 0
  var inboxPulls: Int { lock.withLock { _inboxPulls } }
  var statePulls: Int { lock.withLock { _statePulls } }

  func send(_ request: RemoteOrganizerHTTPRequest) async throws -> RemoteOrganizerHTTPResponse {
    if request.path.hasPrefix("/v1/inbox") {
      lock.withLock { _inboxPulls += 1 }
      return RemoteOrganizerHTTPResponse(
        status: 404, body: Data(#"{"detail": "Not Found"}"#.utf8))
    }
    if request.path.hasPrefix("/v1/state") { lock.withLock { _statePulls += 1 } }
    return try await base.send(request)
  }

  func cancelAll() { base.cancelAll() }
}
