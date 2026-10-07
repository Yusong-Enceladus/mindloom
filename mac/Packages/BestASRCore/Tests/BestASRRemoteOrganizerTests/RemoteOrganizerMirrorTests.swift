import BestASRDomain
import BestASRMemory
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import XCTest

/// v11 live-mac regression: a library that holds a pulled organizer state
/// shows its matters on Home with the link off (offline mirror), with no DGX
/// Spark named at all, and while a link is still connecting. Before the fix
/// the App read the mirror only while the link was on, so a real-shaped root
/// (243 events, 187 people, cursor 25584) showed 「还没有东西」. The tests go
/// through `RemoteOrganizerMirror`, the functions the App's
/// `memoryProjectionInputs` and `reloadRemoteMirror` use. Synthetic data only.
@MainActor
final class RemoteOrganizerMirrorTests: XCTestCase {
  private static let twin = "c3e46259-fdef-46ef-a695-b61f9b95fe36"
  private static let wrist = "669f7a76-9abc-4460-ad9e-7c3d106a944b"
  private static let item1 = UUID(uuidString: "5BBE8F41-3639-4630-A291-A2063B8E4623")!
  private static let item2 = UUID(uuidString: "D92AC58D-83DA-427C-A7CB-63989B2E1D57")!
  private static let loose = UUID(uuidString: "0A3E7C55-1D2B-4C6A-9F00-6B2A1C3D4E5F")!

  /// The pages' read model from a library, the App's way: mirror → the
  /// records it references → memory projection → read model.
  private static func readModel(
    _ store: GRDBDictationStore, live: RemoteOrganizerProjection? = nil, now: Date
  ) async throws -> MemoryReadModel? {
    let stored = await RemoteOrganizerMirror.stored(in: store)
    guard let shown = RemoteOrganizerMirror.shown(live: live, stored: stored) else { return nil }
    let records = try await store.memoryItemRecords(ids: RemoteOrganizerMirror.recordIDs(shown))
    let projection = RemoteOrganizerMirror.memoryProjection(
      shown, records: records, now: now, ownerPersonIDs: [])
    return MemoryReadModel(projection, now: now)
  }

  private static func state(cursor: Int) throws -> RemoteOrganizerState {
    func event(_ id: String, _ title: String, items: [UUID], due: String) -> [String: Any] {
      [
        "event_id": id, "title": title, "title_user_edited": false,
        "status_line": "电机修好了，下周跑三组", "importance": 0.8,
        "status_facts": [
          ["text": "交实验报告", "date": due, "state": "planned", "item_ids": [items[0].uuidString]]
        ],
        "item_ids": items.map(\.uuidString), "person_ids": ["p-zhou"], "pinned": false,
        "deleted": false, "provenance": [:] as [String: Any],
        "updated_at": "2026-09-27T21:00:00+08:00",
      ]
    }
    let object: [String: Any] = [
      "cursor": cursor, "store_id": "store-live-mac", "questions": [] as [Any],
      "persons": [
        ["person_id": "p-zhou", "display_name": "周明澜", "aliases": [] as [Any]]
      ],
      "events": [
        event(twin, "Twin-7 叠衣服真机实验", items: [item1, item2], due: "2026-09-30"),
        event(wrist, "Twin-7 腕电机过热维修", items: [item2], due: "2026-10-09"),
      ],
      "unfiled": [["item_id": loose.uuidString, "reason": "none"]],
    ]
    return try JSONDecoder().decode(
      RemoteOrganizerState.self, from: JSONSerialization.data(withJSONObject: object))
  }

  private static let now = ISO8601DateFormatter().date(from: "2026-10-02T10:00:00+08:00")!

  func testMirrorShowsMattersWithTheLinkOffAndAfterRevokeUntilForgotten() async throws {
    let library = try SyntheticOrganizerLibrary()
    let store = library.store
    for (id, text) in [(Self.item1, "周三把三组数据跑完"), (Self.item2, "腕电机换了"), (Self.loose, "随手记")] {
      try await library.seedCompletedSession(id, createdAt: 1_790_000_000, text: text)
    }
    // Pulled while the link was on, then the link went off (the preview
    // root's shape: a mirror and no link_enabled_at).
    try await store.enableRemoteLink(at: Date(timeIntervalSince1970: 1_789_000_000))
    _ = try await store.applyRemoteState(Self.state(cursor: 41))
    try await store.revokeRemoteLink()
    let record = try await store.remoteLinkRecord()
    XCTAssertNil(record.enabledAt)

    let loaded = try await Self.readModel(store, now: Self.now)
    let model = try XCTUnwrap(loaded)
    XCTAssertEqual(model.home.count, 2, "Home has the mirror's matters with the link off")
    XCTAssertEqual(Set(model.digest.matters.map(\.eventID)), [Self.twin, Self.wrist])
    XCTAssertFalse(model.people.isEmpty)
    XCTAssertEqual(model.unfiled.map(\.id).map { $0.uppercased() }, [Self.loose.uuidString])

    // A correction while offline is kept and shown applied at once.
    try await store.enqueueRemoteDecision(
      RemoteOrganizerDecision(kind: "rename_event", eventID: Self.wrist, title: "腕电机维修"))
    let reloaded = try await Self.readModel(store, now: Self.now)
    let renamed = try XCTUnwrap(reloaded)
    XCTAssertEqual(renamed.digest.matter(Self.wrist)?.title, "腕电机维修")

    // A live projection, once the link has one, wins over the mirror.
    let live = RemoteOrganizerProjection(cursor: 50, events: [], questions: [], persons: [])
    XCTAssertEqual(RemoteOrganizerMirror.shown(live: live, stored: nil), live)

    // Only forgetting the DGX Spark's store empties it: Home is the Mac's own again.
    try await store.forgetRemoteStore()
    let forgotten = try await Self.readModel(store, now: Self.now)
    XCTAssertNil(forgotten)
    await library.close()
  }

  func testAnEmptyLibraryHasNoMirror() async throws {
    let library = try SyntheticOrganizerLibrary()
    let stored = await RemoteOrganizerMirror.stored(in: library.store)
    XCTAssertNil(stored)
    await library.close()
  }

  /// The real-shaped root: a temporary copy of the synthetic preview root
  /// (1514 items, 243 events, 187 people, cursor 25584), opened and migrated
  /// the way the App opens it. Skipped where the preview root is absent.
  func testPreviewRootCloneShowsMattersOffline() async throws {
    let source = URL(fileURLWithPath: "/Users/Shared/mindloom-demo/v11/env/preview-root")
    let marker = source.appendingPathComponent("SYNTHETIC_DATA_ROOT")
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: marker.path), "no synthetic preview root here")
    let copy = FileManager.default.temporaryDirectory
      .appendingPathComponent("mindloom-mirror-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: copy) }
    for name in ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm"] {
      let from = source.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: from.path) else { continue }
      try FileManager.default.copyItem(at: from, to: copy.appendingPathComponent(name))
    }
    let store = try GRDBDictationStore(databaseURL: copy.appendingPathComponent("history.sqlite"))
    let started = Date()
    let loaded = try await Self.readModel(store, now: Self.now)
    let model = try XCTUnwrap(loaded)
    let elapsed = Date().timeIntervalSince(started)
    XCTAssertGreaterThan(model.home.count, 20, "Home lists the preview root's matters")
    XCTAssertGreaterThan(model.digest.matters.count, 20)
    XCTAssertGreaterThan(model.people.count, 10)
    XCTAssertFalse(model.digest.deadlines.isEmpty, "按截止 has rows")
    // live-mac: a matter without a map listed its overdue 截止 twice.
    let rows = model.digest.deadlines.map { "\($0.eventID)|\($0.date)|\($0.text)" }
    XCTAssertEqual(rows.count, Set(rows).count, "no 按截止 row twice")
    // live-mac: TES showed 「9月28日 已过期 交回复信」 twice on its page.
    for matter in model.digest.matters {
      let steps = matter.steps.map { "\($0.date)|\($0.text)" }
      XCTAssertEqual(steps.count, Set(steps).count, "a step twice in \(matter.title)")
    }
    let matters = model.digest.matters
    print(
      "preview-root mirror → read model: \(model.home.count) matters in \(elapsed) s;",
      "with parts \(matters.filter { !$0.parts.isEmpty }.count),",
      "with steps \(matters.filter { !$0.steps.isEmpty }.count),",
      "steps \(matters.map(\.steps.count).reduce(0, +)),",
      "facts \(matters.map(\.facts.count).reduce(0, +)),",
      "deadlines \(model.digest.deadlines.count)")
    try? await store.checkpointAndClose()
  }
}
