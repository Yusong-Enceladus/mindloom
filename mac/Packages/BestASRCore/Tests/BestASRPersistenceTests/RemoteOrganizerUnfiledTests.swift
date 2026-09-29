import BestASRDomain
import BestASRPersistence
import Foundation
import GRDB
import XCTest

/// The organizer-quality API changes on the Mac side: local UTC offsets, the
/// Unfiled set, and the overlay of the new decision kinds. Synthetic data only.
final class RemoteOrganizerUnfiledTests: XCTestCase {
  private let enabledAt = Date(timeIntervalSince1970: 500)

  private func state(
    cursor: Int64, events: String, questions: String = "[]", unfiled: String? = nil,
    storeID: String = "store-a"
  ) throws -> RemoteOrganizerState {
    let unfiledField = unfiled.map { ", \"unfiled\": \($0)" } ?? ""
    return try JSONDecoder().decode(
      RemoteOrganizerState.self,
      from: Data(
        """
        {"cursor": \(cursor), "store_id": "\(storeID)", "persons": [],
         "questions": \(questions), "events": \(events)\(unfiledField)}
        """.utf8))
  }

  private func event(_ id: String, title: String, items: [String]) -> String {
    let list = items.map { "\"\($0)\"" }.joined(separator: ",")
    return """
      {"event_id": "\(id)", "handle": "E1", "anchor": "\(title)", "title": "\(title)",
       "title_user_edited": false, "status_line": "", "importance": 0.5,
       "status_facts": [{"text": "周五签字", "state": "planned", "date": "2026-09-26",
                         "quote": "", "item_ids": []}],
       "started_at": null, "updated_at": null, "item_ids": [\(list)], "person_ids": [],
       "pinned": false, "deleted": false, "provenance": {}}
      """
  }

  func testItemTimesCarryTheLocalOffsetNotZ() async throws {
    let library = try SyntheticRemoteLibrary(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    let sessionID = SyntheticRemoteLibrary.sessionID(71)
    try await library.store.enableRemoteLink(at: enabledAt)
    try await library.seedCompletedSession(sessionID, createdAt: 1000, text: "虚构记录")
    _ = try await library.store.enqueueRemoteSession(sessionID: sessionID)
    let claim = try await library.store.claimNextRemoteItem(now: Date())
    let payload = try payloadObject(try XCTUnwrap(claim))
    XCTAssertEqual(payload["started_at"] as? String, "1970-01-01T08:16:40.000+08:00")
    try await library.close()
  }

  func testNewFieldsDecodeAndOldServicesStillDecode() throws {
    let pulled = try state(
      cursor: 1, events: "[\(event("ev-1", title: "租房", items: []))]",
      unfiled: #"[{"item_id": "i-1", "reason": "none", "since": "2026-09-26T10:00:00+08:00"}]"#)
    let decoded = try XCTUnwrap(pulled.events.first)
    XCTAssertEqual(decoded.handle, "E1")
    XCTAssertEqual(decoded.anchor, "租房")
    XCTAssertEqual(decoded.statusFacts.first?.state, "planned")
    XCTAssertEqual(decoded.statusFacts.first?.date, "2026-09-26")
    XCTAssertEqual(pulled.unfiled?.first?.reason, "none")
    let old = try JSONDecoder().decode(
      RemoteOrganizerState.self,
      from: Data(
        """
        {"cursor": 1, "events": [{"event_id": "e", "title": "t", "title_user_edited": false,
          "status_line": "", "status_facts": [{"text": "x", "item_ids": []}],
          "importance": 0.1, "started_at": null, "updated_at": null, "item_ids": [],
          "person_ids": [], "pinned": false, "deleted": false, "provenance": {}}],
         "questions": [], "persons": []}
        """.utf8))
    XCTAssertNil(old.unfiled)
    XCTAssertNil(old.events.first?.handle)
    XCTAssertNil(old.events.first?.statusFacts.first?.state)
  }

  func testNewDecisionKindsAreWellFormedOnlyWithAnItem() {
    XCTAssertTrue(RemoteOrganizerDecision(kind: "unfile_item", itemID: "i").isWellFormed)
    XCTAssertFalse(RemoteOrganizerDecision(kind: "unfile_item").isWellFormed)
    let filed = RemoteOrganizerDecision(
      kind: "file_item_new_event", itemID: "i", newEventID: "abc")
    XCTAssertTrue(filed.isWellFormed)
    XCTAssertTrue(RemoteOrganizerDecision(kind: "file_item_new_event", itemID: "i").isWellFormed)
    XCTAssertFalse(RemoteOrganizerDecision(kind: "file_item_new_event").isWellFormed)
    XCTAssertEqual(filed.reissued().newEventID, "abc")
    let json = String(decoding: try! JSONEncoder().encode(filed), as: UTF8.self)
    XCTAssertTrue(json.contains("\"new_event_id\":\"abc\""))
    // Absent, not null, on every other kind: stored digests stay the same.
    let other = String(
      decoding: try! JSONEncoder().encode(RemoteOrganizerDecision(kind: "unfile_item", itemID: "i")),
      as: UTF8.self)
    XCTAssertFalse(other.contains("new_event_id"))
  }

  func testUnfiledIsTheCompleteSetPerPullAndClearedOnStoreReset() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: enabledAt)
    _ = try await store.applyRemoteState(
      try state(
        cursor: 2, events: "[\(event("ev-1", title: "租房", items: ["I-A"]))]",
        unfiled: #"[{"item_id": "I-N", "reason": "none", "since": null}]"#))
    var projection = try await store.remoteProjection()
    XCTAssertEqual(projection.unfiled.map(\.itemID), ["I-N"])
    // The next pull replaces the set; an older service without it empties it.
    _ = try await store.applyRemoteState(
      try state(
        cursor: 3, events: "[]",
        unfiled: #"[{"item_id": "I-M", "reason": "user", "since": null}]"#))
    projection = try await store.remoteProjection()
    XCTAssertEqual(projection.unfiled.map(\.itemID), ["I-M"])
    _ = try await store.applyRemoteState(try state(cursor: 4, events: "[]"))
    projection = try await store.remoteProjection()
    XCTAssertTrue(projection.unfiled.isEmpty)
    _ = try await store.applyRemoteState(
      try state(
        cursor: 5, events: "[]",
        unfiled: #"[{"item_id": "I-M", "reason": "user", "since": null}]"#))
    // A different store is a different Spark: nothing of the old set stays.
    let reset = try await store.observeRemoteStoreID("store-b")
    XCTAssertTrue(reset)
    projection = try await store.remoteProjection()
    XCTAssertTrue(projection.unfiled.isEmpty)
    try await library.close()
  }

  func testOverlayOfRemoveUnfileFileNewMoveAndAnswers() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: enabledAt)
    let itemE = SyntheticRemoteLibrary.sessionID(81)
    try await library.seedCompletedSession(itemE, createdAt: 2000, text: "装宽带\n第二行")
    let e = itemE.rawValue.uuidString
    let questions = """
      [{"question_id": "q-in", "kind": "same_event", "a": "I-D", "b": "ev-1",
        "prompt_zh": "这条是租房的吗？", "created_at": "2026-09-26T00:00:00Z"}]
      """
    _ = try await store.applyRemoteState(
      try state(
        cursor: 2,
        events: """
          [\(event("ev-1", title: "租房", items: ["I-A", "I-B", "I-D"])),
           \(event("ev-2", title: "露营", items: ["I-C", e]))]
          """,
        questions: questions,
        unfiled: #"[{"item_id": "I-N", "reason": "none", "since": null}]"#))

    // remove_item: out of the event, into Unfiled (not a one-item event).
    try await store.enqueueRemoteDecision(
      .init(kind: "remove_item", eventID: "ev-1", itemID: "I-A"))
    // unfile_item: out of every event, into Unfiled as the user's.
    try await store.enqueueRemoteDecision(.init(kind: "unfile_item", itemID: "I-C"))
    // move_item files an unfiled item.
    try await store.enqueueRemoteDecision(
      .init(kind: "move_item", itemID: "I-N", toEventID: "ev-2"))
    // An item already in b, answered No: it leaves b for Unfiled.
    try await store.enqueueRemoteDecision(
      .init(kind: "same_event", questionID: "q-in", a: "I-D", b: "ev-1", answer: false))
    // file_item_new_event: a provisional event under the client ID.
    let newID = "0c7d8e0a-1111-4222-8333-444455556666"
    try await store.enqueueRemoteDecision(
      .init(kind: "file_item_new_event", itemID: e, newEventID: newID.uppercased()))

    var projection = try await store.remoteProjection()
    func items(_ id: String) -> [String] {
      projection.events.first { $0.eventID == id }?.itemIDs ?? []
    }
    XCTAssertEqual(items("ev-1"), ["I-B"])
    XCTAssertEqual(items("ev-2"), ["I-N"])
    XCTAssertEqual(items(newID), [e])
    XCTAssertEqual(projection.events.first { $0.eventID == newID }?.title, "装宽带")
    let unfiled = Dictionary(uniqueKeysWithValues: projection.unfiled.map { ($0.itemID, $0.reason) })
    XCTAssertEqual(unfiled, ["I-A": "removed_by_user", "I-C": "user", "I-D": "removed_by_user"])
    XCTAssertTrue(projection.questions.isEmpty)

    // Once the Spark returns the same event, it is used as is and not doubled.
    _ = try await store.applyRemoteState(
      try state(
        cursor: 3,
        events: "[\(event(newID, title: "新家宽带", items: [e]))]",
        unfiled: "[]"))
    projection = try await store.remoteProjection()
    XCTAssertEqual(projection.events.filter { $0.eventID == newID }.count, 1)
    XCTAssertEqual(items(newID), [e])
    XCTAssertEqual(projection.events.first { $0.eventID == newID }?.title, "新家宽带")
    try await library.close()
  }

  /// Yes to "is this item part of 租房", then 这不是这件事的: the Spark requeues
  /// the item and files it elsewhere. The older Yes must not drag it back.
  func testALaterRemovalSupersedesAnEarlierPlacementOfTheSameItem() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: enabledAt)
    _ = try await store.applyRemoteState(
      try state(
        cursor: 2,
        events: """
          [\(event("ev-1", title: "租房", items: ["I-K"])),
           \(event("ev-3", title: "搬家", items: ["I-L"]))]
          """,
        unfiled: #"[{"item_id": "I-X", "reason": "none", "since": null}]"#))
    try await store.enqueueRemoteDecision(
      .init(kind: "same_event", questionID: "q-x", a: "I-X", b: "ev-1", answer: true))
    var projection = try await store.remoteProjection()
    func items(_ id: String) -> [String] {
      projection.events.first { $0.eventID == id }?.itemIDs ?? []
    }
    XCTAssertEqual(items("ev-1"), ["I-K", "I-X"])
    try await store.enqueueRemoteDecision(
      .init(kind: "remove_item", eventID: "ev-1", itemID: "I-X"))
    projection = try await store.remoteProjection()
    XCTAssertEqual(items("ev-1"), ["I-K"])
    XCTAssertEqual(projection.unfiled.map(\.itemID), ["I-X"])
    // The next pull has the organizer's new placement: ev-3.
    _ = try await store.applyRemoteState(
      try state(
        cursor: 3,
        events: """
          [\(event("ev-1", title: "租房", items: ["I-K"])),
           \(event("ev-3", title: "搬家", items: ["I-L", "i-x"]))]
          """,
        unfiled: "[]"))
    projection = try await store.remoteProjection()
    XCTAssertEqual(items("ev-1"), ["I-K"])
    XCTAssertEqual(items("ev-3"), ["I-L", "i-x"])
    XCTAssertTrue(projection.unfiled.isEmpty)
    try await library.close()
  }

  /// Taking the only item out of an event leaves no "0 条" card behind.
  func testAnEventTheUsersCorrectionsEmptiedIsNotShown() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: enabledAt)
    _ = try await store.applyRemoteState(
      try state(
        cursor: 2,
        events: """
          [\(event("ev-solo", title: "一条", items: ["I-S"])),
           \(event("ev-2", title: "露营", items: ["I-C"]))]
          """))
    try await store.enqueueRemoteDecision(
      .init(kind: "remove_item", eventID: "ev-solo", itemID: "I-S"))
    let projection = try await store.remoteProjection()
    XCTAssertEqual(projection.events.map(\.eventID), ["ev-2"])
    XCTAssertEqual(projection.unfiled.map(\.itemID), ["I-S"])
    try await library.close()
  }

  /// The additive `readings` field: an object keyed by item ID or a list;
  /// a malformed entry or field is dropped, never failing the pull.
  func testReadingsDecodeLenientlyInEitherShape() throws {
    func decode(_ readings: String) throws -> RemoteOrganizerState {
      try JSONDecoder().decode(
        RemoteOrganizerState.self,
        from: Data(
          """
          {"cursor": 1, "events": [], "questions": [], "persons": [], "readings": \(readings)}
          """.utf8))
    }
    let keyed = try decode(
      """
      {"i-1": {"revision": 2, "text": " 甲：周五见 "},
       "i-2": {"revision": 1, "derived_text": "乙：好"},
       "i-3": {"text": "no revision"}, "i-4": "just text", "i-5": {"revision": 1, "text": ""}}
      """)
    XCTAssertEqual(
      keyed.readings,
      [
        RemoteOrganizerItemReading(itemID: "i-1", revision: 2, text: "甲：周五见"),
        RemoteOrganizerItemReading(itemID: "i-2", revision: 1, text: "乙：好"),
      ])
    let listed = try decode(
      #"[{"item_id": "i-9", "revision": 3, "reading": "丙"}, {"revision": 1, "text": "x"}, 7]"#)
    XCTAssertEqual(listed.readings, [.init(itemID: "i-9", revision: 3, text: "丙")])
    XCTAssertNil(try decode(#""not readings""#).readings)
    XCTAssertNil(try state(cursor: 1, events: "[]").readings)
    // `summary` sent apart: kept on one line; present but empty or null is
    // "none" (not the first line of the text); a summary alone is a reading.
    let split = try decode(
      """
      {"i-1": {"revision": 2, "text": "甲：好\\n乙：行", "summary": "甲乙约好\\n周五"},
       "i-2": {"revision": 1, "text": "丙：嗯\\n丁：好", "summary": ""},
       "i-3": {"revision": 1, "text": "", "summary": "一张风景照"},
       "i-4": {"revision": 1, "text": "戊", "summary": null},
       "i-5": {"revision": 1, "text": "", "summary": ""}}
      """)
    XCTAssertEqual(
      split.readings,
      [
        .init(itemID: "i-1", revision: 2, text: "甲：好\n乙：行", summary: "甲乙约好 周五"),
        .init(itemID: "i-2", revision: 1, text: "丙：嗯\n丁：好", summary: ""),
        .init(itemID: "i-3", revision: 1, text: "", summary: "一张风景照"),
        .init(itemID: "i-4", revision: 1, text: "戊", summary: ""),
      ])
  }

  /// A reading shows only while its revision is the one the Mac last
  /// delivered; a newer delivery hides it until a matching one arrives, and
  /// deleting the item drops it.
  func testReadingsFollowTheDeliveredRevision() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: enabledAt)
    // The Spark's identity is known before anything is delivered to it.
    _ = try await store.observeRemoteStoreID("store-a")
    let shot = SyntheticRemoteLibrary.sessionID(91)
    let other = SyntheticRemoteLibrary.sessionID(92)
    try await library.seedCompletedSession(shot, createdAt: 1000, text: "虚构截图")
    try await library.seedCompletedSession(other, createdAt: 1001, text: "虚构文字")
    _ = try await store.enqueueRemoteSession(sessionID: shot)
    let claim = try await store.claimNextRemoteItem(now: Date())
    let first = try XCTUnwrap(claim)
    XCTAssertEqual(first.itemID, shot.rawValue)
    try await store.markRemoteItemDelivered(first)
    let id = shot.rawValue.uuidString
    func pull(_ cursor: Int64, _ readings: String) async throws {
      _ = try await store.applyRemoteState(
        try JSONDecoder().decode(
          RemoteOrganizerState.self,
          from: Data(
            """
            {"cursor": \(cursor), "store_id": "store-a", "events": [], "questions": [],
             "persons": [], "readings": \(readings)}
            """.utf8)))
    }
    // Lower-case IDs from the Spark; an item never sent is not kept.
    try await pull(
      2,
      """
      {"\(id.lowercased())": {"revision": \(first.revision), "text": "甲：周五见"},
       "\(other.rawValue.uuidString)": {"revision": 1, "text": "不该留下"}}
      """)
    var projection = try await store.remoteProjection()
    XCTAssertEqual(projection.readings, [id: "甲：周五见"])
    XCTAssertTrue(projection.readingSummaries.isEmpty)
    // The same revision re-sent with its summary apart replaces it.
    try await pull(
      2, #"{"\#(id)": {"revision": \#(first.revision), "text": "甲：周五见", "summary": "约周五"}}"#)
    projection = try await store.remoteProjection()
    XCTAssertEqual(projection.readings, [id: "甲：周五见"])
    XCTAssertEqual(projection.readingSummaries, [id: "约周五"])
    // A reading of another revision is ignored.
    try await pull(3, #"{"\#(id)": {"revision": 99, "text": "别的版本"}}"#)
    projection = try await store.remoteProjection()
    XCTAssertTrue(projection.readings.isEmpty)
    // An older one arriving later does not replace the newer.
    try await pull(4, #"{"\#(id)": {"revision": \#(first.revision), "text": "旧的"}}"#)
    projection = try await store.remoteProjection()
    XCTAssertTrue(projection.readings.isEmpty)

    let held = try await library.read { db in
      try String.fetchOne(
        db, sql: "SELECT value FROM remote_organizer_meta WHERE key = 'readings_json'")
    }
    XCTAssertTrue(held?.contains(id) == true)
    XCTAssertFalse(held?.contains("不该留下") == true)
    // Deleting the item drops what was read from it.
    try await store.deleteSessionRecordsExplicitly(sessionID: shot)
    let afterDeletion = try await library.read { db in
      try String.fetchOne(
        db, sql: "SELECT value FROM remote_organizer_meta WHERE key = 'readings_json'")
    }
    XCTAssertNil(afterDeletion)
    try await library.close()
  }

  func testItemTimesFollowTheMacsCurrentZoneByDefault() async throws {
    let root = try persistenceTemporaryDirectory()
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("synthetic.sqlite"))
    // Not the zone at launch: a long-running App follows later zone changes.
    XCTAssertEqual(store.remoteItemTimeZone, TimeZone.autoupdatingCurrent)
    try await store.checkpointAndClose()
    try? FileManager.default.removeItem(at: root)
  }
}
