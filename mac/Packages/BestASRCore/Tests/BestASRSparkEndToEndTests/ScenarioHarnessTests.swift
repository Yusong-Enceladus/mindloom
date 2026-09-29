import AppKit
import BestASRDomain
import BestASRIntake
import BestASRMemory
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import XCTest

/// The scenario harness's own parts, run without a Spark: a fake organizing
/// device stands in for it (invented items only).
@MainActor
final class ScenarioHarnessTests: XCTestCase {
  // MARK: - Scenario items with a `format`

  func testFormatsKeepTheirKindAndOnlyMeetingExportsAreDropped() throws {
    let work = try Self.workDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    try FileManager.default.createDirectory(
      at: work.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try Data("%PDF-1.4 invented".utf8).write(to: work.appendingPathComponent("assets/memo.pdf"))
    let scenario = #"""
      {"scenario_id": "unit-formats", "items": [
        {"ref": "a", "t": "2026-05-04T09:00:00+08:00", "kind": "text", "format": "chat_paste",
         "source_app": "微信", "text": "周末去看樱桃园"},
        {"ref": "b", "t": "2026-05-04T09:01:00+08:00", "kind": "dictation",
         "format": "phone_ime_voice", "source_app": "备忘录", "text": "记得买灯泡"},
        {"ref": "c", "t": "2026-05-04T09:02:00+08:00", "kind": "document",
         "format": "tencent_transcript", "source_app": "腾讯会议", "filename": "晨会.txt",
         "text": "甲(00:00:01):\n早\n\n乙(00:00:04):\n早上好"},
        {"ref": "d", "t": "2026-05-04T09:03:00+08:00", "kind": "document", "format": "pdf",
         "source_app": "访达", "filename": "memo.pdf", "asset": "assets/memo.pdf"},
        {"ref": "e", "t": "2026-05-04T09:04:00+08:00", "kind": "text", "format": "email",
         "source_app": "邮件", "text": "主题：灯泡"},
        {"ref": "f", "t": "2026-05-04T09:05:00+08:00", "kind": "document",
         "source_app": "访达", "filename": "清单.txt", "text": "灯泡\n门票"},
        {"ref": "g", "t": "2026-05-04T09:06:00+08:00", "kind": "document",
         "source_app": "访达", "filename": "申请表.docx", "text": "姓名\n日期"}]}
      """#
    try Data(scenario.utf8).write(to: work.appendingPathComponent("scenario.json"))
    let directory = try ScenarioDirectory(root: work)
    XCTAssertEqual(
      directory.items.map(directory.intakeKind),
      ["text", "dictation_as_text", "transcript_file", "document", "text", "document", "document"])
    let inbox = work.appendingPathComponent("inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    guard case .paste = try directory.intake(directory.items[0], inbox: inbox),
      case .paste = try directory.intake(directory.items[4], inbox: inbox)
    else { return XCTFail("text with a format is pasted") }
    guard case .drop(let transcript) = try directory.intake(directory.items[2], inbox: inbox)
    else { return XCTFail("a meeting export is dropped") }
    XCTAssertEqual(transcript.lastPathComponent, "晨会.txt")
    guard case .drop(let pdf) = try directory.intake(directory.items[3], inbox: inbox) else {
      return XCTFail("a PDF is dropped")
    }
    XCTAssertEqual(pdf.lastPathComponent, "memo.pdf")
    // A document the scenario ships no file for: a text file stays text, any
    // other becomes a PDF with a text layer (never PDF bytes under .txt/.docx).
    guard case .drop(let note) = try directory.intake(directory.items[5], inbox: inbox),
      case .drop(let form) = try directory.intake(directory.items[6], inbox: inbox)
    else { return XCTFail("documents are dropped") }
    XCTAssertEqual(note.lastPathComponent, "清单.txt")
    XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "灯泡\n门票")
    XCTAssertEqual(form.lastPathComponent, "申请表.pdf")
    XCTAssertEqual(try Data(contentsOf: form).prefix(4), Data("%PDF".utf8))
    XCTAssertTrue(ScenarioDirectory.isTranscriptFormat("zoom_vtt"))
    XCTAssertFalse(ScenarioDirectory.isTranscriptFormat("doc_text"))
  }

  /// A scenario item may ship any file; it is dropped through the real
  /// intake and becomes what that file becomes (a file item, a document,
  /// an image, or a media import).
  func testScenarioAssetsOfAnyTypeAreDroppedThroughTheRealIntake() throws {
    let work = try Self.workDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    let assets = work.appendingPathComponent("assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try (Data([0x50, 0x4B, 0x03, 0x04]) + Data("invented".utf8))
      .write(to: assets.appendingPathComponent("sheet.xlsx"))
    try Data("BEGIN:VCALENDAR\nSUMMARY:虚构评审\nEND:VCALENDAR\n".utf8)
      .write(to: assets.appendingPathComponent("meet.ics"))
    try Data("From: a@example.invalid\nSubject: 虚构\n\n正文".utf8)
      .write(to: assets.appendingPathComponent("mail.eml"))
    try Data([0, 1, 2]).write(to: assets.appendingPathComponent("clip.mov"))
    try Data("# 虚构\n".utf8).write(to: assets.appendingPathComponent("note.md"))
    let scenario = #"""
      {"scenario_id": "unit-files", "items": [
        {"ref": "sheet", "t": "2026-05-04T09:00:00+08:00", "kind": "file", "source_app": "访达"},
        {"ref": "invite", "t": "2026-05-04T09:01:00+08:00", "kind": "calendar",
         "source_app": "日历", "file": "assets/meet.ics"},
        {"ref": "mail", "t": "2026-05-04T09:02:00+08:00", "kind": "email", "source_app": "邮件"},
        {"ref": "clip", "t": "2026-05-04T09:03:00+08:00", "kind": "video", "source_app": "访达"},
        {"ref": "n", "t": "2026-05-04T09:04:00+08:00", "kind": "text", "source_app": "访达",
         "path": "assets/note.md"}]}
      """#
    try Data(scenario.utf8).write(to: work.appendingPathComponent("scenario.json"))
    let directory = try ScenarioDirectory(root: work)
    XCTAssertEqual(
      directory.items.map(directory.intakeKind), ["file", "file", "file", "media", "document"])
    let inbox = work.appendingPathComponent("inbox", isDirectory: true)
    let processor = IntakeProcessor(
      assetStore: IntakeAssetStore(assetRoot: work.appendingPathComponent("library")),
      pathPolicy: .none)
    var kinds: [String] = []
    for item in directory.items {
      guard case .drop(let url) = try directory.intake(item, inbox: inbox) else {
        return XCTFail("\(item.ref) is dropped as its file")
      }
      switch processor.prepare(.file(url), capturedAt: item.at, source: nil, origin: .finder) {
      case .item(let draft): kinds.append(draft.kind.rawValue)
      case .media: kinds.append("media")
      case .rejected(let message): kinds.append("rejected: \(message)")
      }
    }
    XCTAssertEqual(kinds, ["file", "file", "file", "media", "document"])
  }

  func testMinuteStampsParseLikeSecondStamps() {
    XCTAssertEqual(
      ScenarioDirectory.date("2026-05-04T09:00+08:00"),
      ScenarioDirectory.date("2026-05-04T09:00:00+08:00"))
    XCTAssertNotNil(ScenarioDirectory.date("2026-05-04T09:00+08:00"))
    XCTAssertNil(ScenarioDirectory.date("2026-05-04 09:00"))
  }

  // MARK: - Ground-truth threads

  func testThreadIsTheEventHoldingMostOfItsItemsCountingParts() {
    let one = "11111111-1111-1111-1111-111111111111"
    let two = "22222222-2222-2222-2222-222222222222"
    let three = "33333333-3333-3333-3333-333333333333"
    let split = "44444444-4444-4444-4444-444444444444"
    let text = "先说樱桃园的门票。\n再说灯泡换哪种。"
    let cut = "先说樱桃园的门票。\n".unicodeScalars.count
    let events = [
      RemoteOrganizerEvent(
        eventID: "A", title: "a", itemIDs: [one, split],
        segments: [.init(itemID: split, segID: "s1", start: 0, end: cut, gist: "门票")]),
      RemoteOrganizerEvent(eventID: "B", title: "b", itemIDs: [two]),
      RemoteOrganizerEvent(
        eventID: "C", title: "c", itemIDs: [three, split],
        segments: [
          .init(itemID: split, segID: "s2", start: cut, end: text.unicodeScalars.count, gist: "灯泡")
        ]),
      RemoteOrganizerEvent(eventID: "D", title: "d", itemIDs: [two], deleted: true),
    ]
    let rank = ["A": 1, "B": 2, "C": 3]
    // Truth "bulbs": item three whole in C, the split item's bulb part in C.
    let bulbs = ScenarioThreads.choose(
      truthEvent: "bulbs",
      members: [
        .init(ref: "r3", id: three, text: "灯泡", quotes: []),
        .init(ref: "r4", id: split, text: text, quotes: ["再说灯泡换哪种。"]),
        .init(ref: "r9", id: "99999999-9999-9999-9999-999999999999", text: nil, quotes: []),
      ],
      events: events, rank: rank)
    XCTAssertEqual(bulbs.eventID, "C")
    XCTAssertEqual(bulbs.share, 2.0 / 3.0, accuracy: 1e-9)
    XCTAssertEqual(bulbs.holders, 1)
    // Without a located quote the split item's parts share its vote; the
    // tie between A and B goes to the better Home rank.
    let tickets = ScenarioThreads.choose(
      truthEvent: "tickets",
      members: [
        .init(ref: "r2", id: two, text: "x", quotes: []),
        .init(ref: "r4", id: split, text: text, quotes: ["不在正文里的一句话"]),
        .init(ref: "r1", id: one, text: "y", quotes: []),
      ],
      events: events, rank: rank)
    XCTAssertEqual(tickets.eventID, "A")
    XCTAssertEqual(tickets.share, 1.5 / 3.0, accuracy: 1e-9)
    let tie = ScenarioThreads.choose(
      truthEvent: "tie",
      members: [
        .init(ref: "r3", id: three, text: nil, quotes: []),
        .init(ref: "r2", id: two, text: nil, quotes: []),
      ],
      events: events, rank: rank)
    XCTAssertEqual(tie.eventID, "B", "equal votes: the better Home rank")
    XCTAssertNil(
      ScenarioThreads.choose(truthEvent: "none", members: [], events: events, rank: rank).eventID)
    XCTAssertEqual(ScenarioThreads.locate("灯泡换哪种", in: text), (cut + 2)..<(cut + 7))
    XCTAssertEqual(ScenarioThreads.fileSafe("ev/门票 1"), "ev____1")
  }

  // MARK: - Ledger and resume

  func testLedgerKeepsWhatWasTakenInAcrossRuns() throws {
    let work = try Self.workDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    let url = work.appendingPathComponent("ledger.jsonl")
    var ledger = try ScenarioLedger(url: url, scenario: "unit-ledger")
    try ledger.recordIngested(ref: "a", id: "A-ID", at: Date(timeIntervalSince1970: 10))
    try ledger.recordIngested(ref: "b", id: "B-ID", at: Date(timeIntervalSince1970: 11))
    try ledger.recordIngested(ref: "c", id: "C-ID", at: Date(timeIntervalSince1970: 12))
    try ledger.recordOrganized([(ref: "a", at: Date(timeIntervalSince1970: 20))])
    try ledger.forget(["b"])
    // A torn last line, as a killed run could leave.
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"ref": "c", "organi"#.utf8))
    try handle.close()

    let reopened = try ScenarioLedger(url: url, scenario: "unit-ledger")
    XCTAssertEqual(reopened.entries.map(\.ref), ["a", "c"])
    XCTAssertEqual(reopened.entries[0].organizedAt, Date(timeIntervalSince1970: 20))
    XCTAssertNil(reopened.entries[1].organizedAt)
    XCTAssertThrowsError(try ScenarioLedger(url: url, scenario: "another"))

    let delivered = SparkEndToEndTests.JobRow(
      state: "delivered", errorCategory: "none", retryCount: 0, deliveredAt: 1,
      deliveredRevision: 1)
    let entries =
      reopened.entries + [
        ScenarioLedger.Entry(ref: "gone", id: "G-ID", ingestedAt: Date())
      ]
    let afterRevoke = ScenarioEndToEndTests.resumePlan(
      entries, linkStillOn: false, jobs: ["A-ID": delivered], known: ["a", "c"])
    XCTAssertEqual(afterRevoke.keep.map(\.ref), ["a"], "only delivered items are on the Spark")
    XCTAssertEqual(afterRevoke.forget, ["c", "gone"])
    let afterStop = ScenarioEndToEndTests.resumePlan(
      entries, linkStillOn: true, jobs: [:], known: ["a", "c"])
    XCTAssertEqual(
      afterStop.keep.map(\.ref), ["a", "c"], "a stopped run's outbox still holds them")
    XCTAssertEqual(ScenarioEndToEndTests.list(" ev_a, ,ev_b,ev_a "), ["ev_a", "ev_b"])
  }

  // MARK: - The probe and the wait, against a fake organizing device

  func testProbeReadsNewestJobPerItemAndNeedsAnEmptyQueue() throws {
    let health = Data(#"{"ok": true, "queue": 1, "items": 3, "events": 1, "store_id": "s"}"#.utf8)
    let jobs = Data(
      #"""
      {"jobs": [
        {"item_id": "aaaaaaaa-0000-0000-0000-000000000001", "revision": 1, "state": "superseded"},
        {"item_id": "AAAAAAAA-0000-0000-0000-000000000001", "revision": 2, "state": "done",
         "enqueued_at": 100.0, "run_ended": 104.5},
        {"item_id": "AAAAAAAA-0000-0000-0000-000000000002", "revision": 1, "state": "running"},
        {"item_id": "AAAAAAAA-0000-0000-0000-000000000003", "revision": 1, "state": "failed",
         "error_category": "internal"}]}
      """#.utf8)
    let status = try SparkProbe.status(health: health, jobs: jobs)
    let ids = (1...4).map { "AAAAAAAA-0000-0000-0000-00000000000\($0)" }
    XCTAssertEqual(status.jobs[ids[0]]?.state, "done")
    XCTAssertEqual(status.unfinished(ids), [ids[1], ids[3]], "running, and never received")
    XCTAssertFalse(status.processedAll([ids[0], ids[2]]), "a queued split part keeps it busy")
    let idle = SparkProbe.Status(
      queue: 0, items: 3, events: 1, storeID: "s", jobs: status.jobs)
    XCTAssertTrue(idle.processedAll([ids[0], ids[2]]), "failed is finished")
    XCTAssertThrowsError(try SparkProbe.status(health: Data("{}".utf8), jobs: jobs))
  }

  /// A whole run's wait against the fake device: items go out over the real
  /// runtime, are placed at once, yet the run waits while the device still
  /// reports work queued, then ends settled and the ledger holds the timings.
  func testWaitEndsOnlyWhenTheSparkReportsEverySentItemProcessed() async throws {
    let work = try Self.workDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    let root = try SparkEndToEndTests.makeSyntheticDataRoot(at: work.appendingPathComponent("root"))
    guard let realLibrary = BestASRDataRootSelection.ownerRealLibraryRoot() else {
      return XCTFail("owner library root unresolvable")
    }
    let databaseURL = root.appendingPathComponent("history.sqlite")
    let assetRoot = root.appendingPathComponent("assets", isDirectory: true)
    let store = try GRDBDictationStore(databaseURL: databaseURL, remoteItemTimeZone: .current)
    let spark = OrganizingFakeSpark(busyListings: 3)
    let runtimeLauncher = FakeForwardLauncher()
    let controller = RemoteOrganizerLinkController(
      repository: store, dataRoot: root, realLibraryRoot: realLibrary,
      intent: RemoteOrganizerLinkIntentFile(
        stateDirectory: work.appendingPathComponent("link-state"), dataRoot: root),
      cleanUpStaleTunnels: {},
      makeRuntime: { repository, onUpdate in
        RemoteOrganizerRuntime(
          repository: repository, launcher: runtimeLauncher, http: spark,
          timing: RemoteOrganizerRuntime.Timing(
            pollInterval: .milliseconds(100), reconnectDelay: .milliseconds(200)),
          onUpdate: onUpdate)
      })
    await controller.setEnabled(true)
    XCTAssertTrue(controller.isEnabled)

    var ledger: ScenarioLedger? = try ScenarioLedger(
      url: work.appendingPathComponent("ledger.jsonl"), scenario: "unit-wait")
    let processor = IntakeProcessor(
      assetStore: IntakeAssetStore(assetRoot: assetRoot), pathPolicy: .none, imageReader: nil)
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("bestASR.e2e.unit.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    var tracked: [ScenarioEndToEndTests.Tracked] = []
    for (index, text) in ["樱桃园门票两张", "灯泡换暖光的", "周六上午十点出发"].enumerated() {
      pasteboard.clearContents()
      pasteboard.setString(text, forType: .string)
      let outcome = processor.prepare(
        try SparkEndToEndTests.readSingle(pasteboard),
        capturedAt: Date(timeIntervalSinceNow: Double(index - 10)),
        source: ScenarioDirectory.source("微信"), origin: .previousFrontmost)
      guard case .item(let draft) = outcome else { return XCTFail("\(outcome)") }
      try await store.createUserItem(draft)
      processor.assetStore.commit(sessionID: draft.id)
      let entry = ScenarioEndToEndTests.Tracked(
        ref: "t\(index)", kind: "text", intakeKind: "text", sourceApp: "微信",
        expectedEvents: ["ev_trip"], id: draft.id.rawValue.uuidString.uppercased(),
        ingestedAt: Date())
      try ledger?.recordIngested(ref: entry.ref, id: entry.id, at: entry.ingestedAt)
      tracked.append(entry)
    }

    let probe = SparkProbe(launcher: FakeForwardLauncher(), http: spark)
    let settings = SparkEndToEndTests.Settings(
      link: try RemoteOrganizerLinkConfiguration(
        host: "fake-spark", remoteSocketPath: "/tmp/fake.sock", remoteTokenPath: "/tmp/fake"),
      output: work.appendingPathComponent("out"), timeout: 60, quiet: 0.3)
    var summary = ScenarioSummary(scenario: "unit-wait", host: "fake-spark", pace: 0)
    var errors: [String] = []
    let started = Date()
    let outcome = try await ScenarioEndToEndTests.waitUntilProcessed(
      store: store, controller: controller, databaseURL: databaseURL, tracked: tracked,
      settings: settings, probe: probe, probeInterval: 0.1, started: started,
      errors: &errors, summary: &summary, ledger: &ledger, pollInterval: .milliseconds(100))
    XCTAssertTrue(outcome.settled, "\(errors)")
    XCTAssertFalse(outcome.timedOut)
    XCTAssertEqual(errors, [])
    XCTAssertEqual(summary.waitMode, "spark_processed")
    XCTAssertNotNil(summary.spark.processedAtSeconds)
    XCTAssertGreaterThan(spark.jobListings, 3, "it kept asking while work was queued")
    XCTAssertEqual(Set(summary.organizedAt.keys), Set(tracked.map(\.id)))
    summary.describeSpark(try await probe.status(), tracked: tracked)
    XCTAssertTrue(summary.spark.processedAll)
    XCTAssertEqual(summary.spark.jobStates, ["done": 3])
    XCTAssertEqual(summary.spark.enqueueToDoneP50Seconds, 2)
    probe.close()

    let jobs = try SparkEndToEndTests.jobRows(databaseURL)
    XCTAssertEqual(tracked.filter { jobs[$0.id]?.deliveredRevision != nil }.count, 3)
    controller.revokeNow()
    await controller.revokeStorage()
    // A rerun after this finished run keeps all three: they were delivered.
    let reopened = try ScenarioLedger(
      url: work.appendingPathComponent("ledger.jsonl"), scenario: "unit-wait")
    XCTAssertTrue(reopened.entries.allSatisfy { $0.organizedAt != nil })
    let plan = ScenarioEndToEndTests.resumePlan(
      reopened.entries, linkStillOn: try await store.remoteLinkRecord().enabledAt != nil,
      jobs: try SparkEndToEndTests.jobRows(databaseURL), known: ["t0", "t1", "t2"])
    XCTAssertEqual(plan.keep.count, 3)
    XCTAssertEqual(plan.forget, [])
    XCTAssertEqual(spark.itemPosts, 3, "each item was sent once")

    // The summary's counts from the final projection.
    let remote = try await store.remoteProjection()
    let records = try await store.memoryItemRecords(
      ids: MemoryProjection.sessionIDs(tracked.map(\.id)))
    let model = MemoryReadModel(MemoryProjection(remote: remote, records: records, now: Date()))
    XCTAssertEqual(model.home.count, 1)
    summary.describe(
      remote: remote, home: model.home, tracked: tracked, jobs: jobs, model: model,
      texts: Dictionary(uniqueKeysWithValues: tracked.map { ($0.id, "四个汉字" as String?) }))
    XCTAssertEqual(summary.totalCharacters, 12)
    XCTAssertEqual(summary.eventCount, 1)
    XCTAssertEqual(summary.itemsWithMultipleSegments, 1)
    XCTAssertEqual(summary.byKind, ["text": 3])
    XCTAssertEqual(summary.itemsSent, 3)
    XCTAssertNotNil(summary.pasteToFiledP90Seconds)
    XCTAssertEqual(summary.firstPasteToLastFiledSeconds, summary.organizeSeconds)
    XCTAssertEqual(summary.grouping.first?.events, [1])
    try? await store.checkpointAndClose()
  }

  static func workDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-harness-unit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

// MARK: - Fakes

@MainActor
final class FakeForward: RemoteOrganizerTunnelProcess {
  let processIdentifier: Int32
  let localPort: Int
  private(set) var isRunning = true

  init(processIdentifier: Int32, localPort: Int) {
    self.processIdentifier = processIdentifier
    self.localPort = localPort
  }

  func terminateAndWait() { isRunning = false }
}

@MainActor
final class FakeForwardLauncher: RemoteOrganizerTunnelLauncher {
  private var launched: [FakeForward] = []
  private var nextPort = 43_000

  func freeLoopbackPort() throws -> Int {
    nextPort += 3
    return nextPort
  }

  func launchForward(localPort: Int) async throws -> any RemoteOrganizerTunnelProcess {
    let forward = FakeForward(
      processIdentifier: Int32(8_000 + launched.count), localPort: localPort)
    launched.append(forward)
    return forward
  }

  func listenerIsOwned(by pid: Int32, port: Int) -> Bool {
    launched.contains { $0.processIdentifier == pid && $0.localPort == port && $0.isRunning }
  }

  func fetchLinkToken() async throws -> String { OrganizingFakeSpark.token }

  func cleanUpStaleTunnels() {}
}

/// A stand-in organizing device: takes items, files each at once into one
/// event (the first item split into two parts), and reports its job queue
/// busy for the first `busyListings` job listings (a split part or a brief
/// still running) before every job is done.
final class OrganizingFakeSpark: RemoteOrganizerHTTPTransport, @unchecked Sendable {
  static let token = String(repeating: "cd", count: 32)
  private let lock = NSLock()
  private let busyListings: Int
  private var items: [String] = []
  private var _itemPosts = 0
  private var _jobListings = 0

  init(busyListings: Int) { self.busyListings = busyListings }

  var jobListings: Int { lock.withLock { _jobListings } }
  var itemPosts: Int { lock.withLock { _itemPosts } }

  func send(_ request: RemoteOrganizerHTTPRequest) async throws -> RemoteOrganizerHTTPResponse {
    func json(_ object: Any, status: Int = 200) throws -> RemoteOrganizerHTTPResponse {
      RemoteOrganizerHTTPResponse(
        status: status, body: try JSONSerialization.data(withJSONObject: object))
    }
    guard request.token == Self.token else { return try json(["detail": "token"], status: 401) }
    let path = request.path
    if path == "/v1/items" {
      let body = request.body.flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
      }
      let received = (body?["items"] as? [[String: Any]] ?? []).compactMap {
        $0["item_id"] as? String
      }
      let accepted = lock.withLock { () -> Int in
        _itemPosts += 1
        let new = received.filter { !items.contains($0) }
        items += new
        return new.count
      }
      return try json(["accepted": accepted, "duplicates": received.count - accepted])
    }
    let (held, busy) = lock.withLock { () -> ([String], Bool) in
      if path == "/v1/debug/jobs" { _jobListings += 1 }
      return (items, _jobListings <= busyListings)
    }
    switch path {
    case "/v1/health":
      return try json([
        "ok": true, "store_id": "fake-store", "clock": "wall", "queue": busy ? 1 : 0,
        "items": held.count, "events": held.isEmpty ? 0 : 1,
      ])
    case "/v1/debug/jobs":
      var rows: [[String: Any]] = held.map {
        [
          "item_id": $0, "revision": 1, "state": busy ? "running" : "done",
          "enqueued_at": 100.0, "run_ended": busy ? NSNull() : 102.0,
        ]
      }
      if busy { rows.append(["item_id": UUID().uuidString, "revision": 1, "state": "queued"]) }
      return try json(["jobs": rows])
    default:
      break
    }
    if path.hasPrefix("/v1/state") {
      var event: [String: Any] = [
        "event_id": "ev-fake", "title": "出游", "title_user_edited": false,
        "status_line": "", "status_facts": [] as [Any], "importance": 0.5,
        "item_ids": held, "person_ids": [] as [Any], "pinned": false, "deleted": false,
        "provenance": [:] as [String: Any],
      ]
      if let first = held.first {
        event["segments"] = [
          ["item_id": first, "seg_id": "s1", "start": 0, "end": 2, "gist": "门票"],
          ["item_id": first, "seg_id": "s2", "start": 2, "end": 5, "gist": "张数"],
        ]
      }
      return try json([
        "cursor": held.count, "store_id": "fake-store",
        "events": held.isEmpty ? [] as [Any] : [event], "questions": [] as [Any],
        "persons": [] as [Any], "unfiled": [] as [Any],
      ])
    }
    return try json(["detail": "not found"], status: 404)
  }

  func cancelAll() {}
}

/// Home time-lapse (`BESTASR_E2E_HOME_CUTOFFS`): what a day's cut keeps.
@MainActor
final class ScenarioHomeCutOffTests: XCTestCase {
  func testHomeCutOffKeepsOnlyItemsCapturedByThen() throws {
    let calendar = ScenarioEndToEndTests.calendar(TimeZone(identifier: "Asia/Shanghai")!)
    let end = try XCTUnwrap(ScenarioEndToEndTests.endOfDay("2026-08-23", calendar: calendar))
    XCTAssertNil(ScenarioEndToEndTests.endOfDay("08/23", calendar: calendar))
    let early = end.addingTimeInterval(-3_600)
    let late = end.addingTimeInterval(3_600)
    let remote = RemoteOrganizerProjection(
      cursor: 7,
      events: [
        RemoteOrganizerEvent(
          eventID: "e1", title: "早", statusLine: "后来的进展",
          statusFacts: [
            .init(text: "后来的下一步", itemIDs: ["b"], state: "planned", date: "2026-08-30")
          ],
          itemIDs: ["a", "b"]),
        RemoteOrganizerEvent(eventID: "e2", title: "晚", itemIDs: ["c"]),
      ],
      questions: [], persons: [],
      unfiled: [
        RemoteOrganizerUnfiledItem(itemID: "d", reason: "noise"),
        RemoteOrganizerUnfiledItem(itemID: "e", reason: "noise"),
      ])
    let cut = ScenarioEndToEndTests.projection(
      remote, capturedBy: end, capturedAt: ["A": early, "B": late, "C": late, "D": early])
    XCTAssertEqual(cut.events[0].itemIDs, ["a"])
    XCTAssertEqual(cut.events[0].statusLine, "")
    XCTAssertEqual(cut.events[0].statusFacts, [])
    XCTAssertFalse(cut.events[0].deleted)
    XCTAssertTrue(cut.events[1].deleted)
    XCTAssertEqual(cut.unfiled.map(\.itemID), ["d"])
  }
}
