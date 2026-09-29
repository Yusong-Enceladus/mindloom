import BestASRDomain
import BestASRPersistence
import Foundation
import XCTest

/// Items the organizing device split into parts (`events[].segments`) and
/// the user's corrections on one part (`seg_id`). Synthetic data only.
final class RemoteOrganizerSegmentTests: XCTestCase {
  private let enabledAt = Date(timeIntervalSince1970: 500)

  private func state(cursor: Int64, events: String) throws -> RemoteOrganizerState {
    try JSONDecoder().decode(
      RemoteOrganizerState.self,
      from: Data(
        """
        {"cursor": \(cursor), "store_id": "store-a", "persons": [], "questions": [],
         "events": \(events), "unfiled": []}
        """.utf8))
  }

  private func event(_ id: String, items: [String], segments: String = "[]") -> String {
    let list = items.map { "\"\($0)\"" }.joined(separator: ",")
    return """
      {"event_id": "\(id)", "title": "\(id)", "title_user_edited": false,
       "status_line": "", "status_facts": [], "importance": 0.5,
       "started_at": null, "updated_at": null, "item_ids": [\(list)], "person_ids": [],
       "pinned": false, "deleted": false, "provenance": {}, "segments": \(segments)}
      """
  }

  private func part(_ item: String, _ seg: String, _ start: Int, _ end: Int) -> String {
    #"{"item_id": "\#(item)", "seg_id": "\#(seg)", "start": \#(start), "end": \#(end), "gist": "虚构要点 \#(seg)"}"#
  }

  func testSegmentsDecodeLenientlyAndOnlyForHeldItems() throws {
    let pulled = try state(
      cursor: 1,
      events: """
        [\(event("ev-a", items: ["I-M"], segments: """
          [\(part("I-M", "s1", 0, 40)), \(part("I-OTHER", "s9", 0, 5)),
           {"item_id": "I-M", "seg_id": "bad", "start": 30, "end": 10, "gist": "x"},
           {"item_id": "I-M"}, 7, \(part("i-m", "s1", 0, 40))]
          """)),
         \(event("ev-b", items: ["I-M"], segments: #""not a list""#))]
        """)
    let a = try XCTUnwrap(pulled.events.first)
    // Unknown item, an empty range, a partial entry, a non-object and a
    // repeated (item, segment) are dropped; the event decodes.
    XCTAssertEqual(a.segments.map(\.segID), ["s1"])
    XCTAssertEqual(a.segments.first?.gist, "虚构要点 s1")
    XCTAssertEqual(pulled.events.last?.segments, [])
    // Older services send no field.
    let old = try JSONDecoder().decode(
      RemoteOrganizerEvent.self,
      from: Data(
        """
        {"event_id": "e", "title": "t", "title_user_edited": false, "status_line": "",
         "status_facts": [], "importance": 0.1, "item_ids": ["I"], "person_ids": [],
         "pinned": false, "deleted": false, "provenance": {}}
        """.utf8))
    XCTAssertEqual(old.segments, [])
  }

  func testSegmentDecisionsCarrySegIDOnlyForItemCorrections() throws {
    let move = RemoteOrganizerDecision(
      kind: "move_item", itemID: "I-M", toEventID: "ev-b", segID: "s2")
    XCTAssertTrue(move.isWellFormed)
    let wire = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(move)) as? [String: Any])
    XCTAssertEqual(wire["seg_id"] as? String, "s2")
    // Absent, not null, when the whole item is meant (older services).
    let whole = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: JSONEncoder().encode(RemoteOrganizerDecision(kind: "unfile_item", itemID: "I")))
        as? [String: Any])
    XCTAssertNil(whole["seg_id"])
    XCTAssertFalse(
      RemoteOrganizerDecision(kind: "rename_event", eventID: "e", title: "t", segID: "s")
        .isWellFormed)
    XCTAssertFalse(
      RemoteOrganizerDecision(kind: "remove_item", eventID: "e", itemID: "i", segID: " ")
        .isWellFormed)
    XCTAssertEqual(move.reissued().segID, "s2")
  }

  /// One meeting in three events. Removing one part keeps the item in its
  /// other events; moving a part takes only that part; the last part out
  /// takes the item out; unfiling a part that is nowhere else unfiles it.
  func testOverlayOfCorrectionsOnOnePart() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: enabledAt)
    _ = try await store.applyRemoteState(
      try state(
        cursor: 2,
        events: """
          [\(event("ev-a", items: ["I-M", "I-X"], segments: "[\(part("I-M", "s1", 0, 40))]")),
           \(event("ev-b", items: ["I-M"], segments: """
             [\(part("I-M", "s2", 40, 90)), \(part("I-M", "s3", 90, 130))]
             """)),
           \(event("ev-c", items: ["I-Y"]))]
          """))
    var projection = try await store.remoteProjection()
    func held(_ id: String) -> RemoteOrganizerEvent? {
      projection.events.first { $0.eventID == id }
    }
    XCTAssertEqual(held("ev-b")?.segments.map(\.segID), ["s2", "s3"])

    // 这不是这件事的 on part s2 of ev-b: s3 keeps the item there.
    try await store.enqueueRemoteDecision(
      .init(kind: "remove_item", eventID: "ev-b", itemID: "I-M", segID: "s2"))
    projection = try await store.remoteProjection()
    XCTAssertEqual(held("ev-b")?.itemIDs, ["I-M"])
    XCTAssertEqual(held("ev-b")?.segments.map(\.segID), ["s3"])
    XCTAssertTrue(projection.unfiled.isEmpty)

    // 移到… ev-c with part s3: ev-b gives up its last part (and the item),
    // ev-c holds only that part; ev-a is untouched.
    try await store.enqueueRemoteDecision(
      .init(kind: "move_item", itemID: "I-M", toEventID: "ev-c", segID: "s3"))
    projection = try await store.remoteProjection()
    XCTAssertNil(held("ev-b"), "an event the corrections emptied is not shown")
    XCTAssertEqual(held("ev-c")?.itemIDs, ["I-Y", "I-M"])
    XCTAssertEqual(held("ev-c")?.segments.map(\.segID), ["s3"])
    XCTAssertEqual(held("ev-c")?.segments.first?.start, 90)
    XCTAssertEqual(held("ev-a")?.segments.map(\.segID), ["s1"])

    // Unfiling part s1: the item stays in ev-c, so it is not Unfiled.
    try await store.enqueueRemoteDecision(
      .init(kind: "unfile_item", itemID: "I-M", segID: "s1"))
    projection = try await store.remoteProjection()
    XCTAssertEqual(held("ev-a")?.itemIDs, ["I-X"])
    XCTAssertEqual(held("ev-a")?.segments, [])
    XCTAssertTrue(projection.unfiled.isEmpty)

    // Removing the whole item from ev-c takes its parts too: now Unfiled.
    try await store.enqueueRemoteDecision(
      .init(kind: "remove_item", eventID: "ev-c", itemID: "I-M"))
    projection = try await store.remoteProjection()
    XCTAssertEqual(held("ev-c")?.itemIDs, ["I-Y"])
    XCTAssertEqual(held("ev-c")?.segments, [])
    XCTAssertEqual(projection.unfiled.map(\.itemID), ["I-M"])
    try await library.close()
  }

  /// A new revision re-splits: the Spark's next pull replaces the parts, and
  /// a correction about a part that no longer exists changes nothing.
  func testACorrectionOnAPartTheSparkNoLongerHasIsInert() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: enabledAt)
    _ = try await store.applyRemoteState(
      try state(
        cursor: 2,
        events: """
          [\(event("ev-a", items: ["I-M"], segments: "[\(part("I-M", "s1", 0, 40))]")),
           \(event("ev-b", items: ["I-M"], segments: "[\(part("I-M", "s2", 40, 90))]"))]
          """))
    try await store.enqueueRemoteDecision(
      .init(kind: "move_item", itemID: "I-M", toEventID: "ev-b", segID: "old-s7"))
    let projection = try await store.remoteProjection()
    XCTAssertEqual(
      projection.events.first { $0.eventID == "ev-a" }?.segments.map(\.segID), ["s1"])
    XCTAssertEqual(
      projection.events.first { $0.eventID == "ev-b" }?.segments.map(\.segID), ["s2"])
    try await library.close()
  }
}
