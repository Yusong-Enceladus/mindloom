import BestASRDomain
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import XCTest

/// v7 (MAP-CONTRACT §1–§3): `/v1/state` maps, facets, ropes and relations
/// are decoded (tolerant to absence and to malformed entries), stored,
/// unmasked and projected; rope and relation decisions are stored, applied
/// at once by the local overlay and sent; a matter with no map can ask for
/// one. Synthetic data only.
@MainActor
final class RemoteOrganizerMapTests: XCTestCase {
  private let enabledAt = Date(timeIntervalSince1970: 500)
  static let twin = "c3e46259-fdef-46ef-a695-b61f9b95fe36"
  static let wrist = "669f7a76-9abc-4460-ad9e-7c3d106a944b"
  static let cluster = "16b60ea1-0649-4043-b4ec-3dd1bd8964f4"
  static let item1 = "5BBE8F41-3639-4630-A291-A2063B8E4623"
  static let item2 = "D92AC58D-83DA-427C-A7CB-63989B2E1D57"

  static func event(_ id: String, title: String, extra: [String: Any] = [:]) -> [String: Any] {
    var event: [String: Any] = [
      "event_id": id, "title": title, "title_user_edited": false, "status_line": "",
      "status_facts": [] as [Any], "importance": 0.5, "item_ids": [item1, item2],
      "person_ids": [] as [Any], "pinned": false, "deleted": false,
      "provenance": [:] as [String: Any],
    ]
    event.merge(extra) { _, new in new }
    return event
  }

  /// A state in the shape of the organizer's (`state-sample.json`), trimmed.
  static func state(
    cursor: Int = 7, mapText: String = "9/19跑A800 baseline",
    extraKnots: [[String: Any]] = [], ropes: [[String: Any]]? = nil,
    relations: [[String: Any]]? = nil
  ) -> [String: Any] {
    let map: [String: Any] = [
      "strands": [
        [
          "id": "s1", "name": "Twin-7 真机实验与调试", "summary": "电机修好，三组数据齐。",
          "item_ids": [item1], "segment_refs": [["item_id": item1, "seg_id": "s1"]],
          "fact_ids": ["f1"], "state": "open",
        ],
        [
          "id": "s2", "name": "9/12 学院开放日演示", "summary": "", "item_ids": [item2],
          "segment_refs": [] as [Any], "fact_ids": [] as [Any], "state": "closed",
        ],
      ],
      "knots": [
        [
          "id": "k7", "strand": "s1", "kind": "commitment", "text": mapText,
          "date": "2026-09-19", "state": "planned", "who": ["林知远"], "evidence": [item2],
          "segment_refs": [["item_id": item2, "seg_id": "s2"]], "quote": "明天还要跑A800的baseline",
          "quote_item_id": item2, "quote_seg_id": "s2",
        ],
        [
          "id": "k3", "strand": nil as Any? as Any, "kind": "question", "text": "袋子成功率偏低的原因",
          "date": nil as Any? as Any, "state": "planned", "who": [] as [Any], "evidence": [item1],
          "segment_refs": [] as [Any], "quote": "", "quote_item_id": item1,
          "quote_seg_id": nil as Any? as Any,
        ],
      ] + extraKnots,
      "health": [
        "level": "ok", "reason": "实验数据已齐", "evidence": [item1],
        "segment_refs": [] as [Any],
      ],
      "skill_version": "1.1.0", "updated_at": "2026-09-20T23:49:00+08:00", "stale": false,
      "facts_current": true,
    ]
    var state: [String: Any] = [
      "cursor": cursor, "store_id": "store-a", "questions": [] as [Any], "persons": [] as [Any],
      "events": [
        event(
          twin, title: "Twin-7叠衣服真机实验",
          extra: [
            "map": map,
            "facets": [
              "type": "实验", "rope": "rope-1", "deadline": "2026-09-19",
              "deadline_overdue": true, "health": "ok",
            ],
          ]),
        event(wrist, title: "Twin-7腕电机过热维修"),
        event(cluster, title: "A800集群维护"),
      ],
    ]
    state["ropes"] =
      ropes ?? [
        [
          "id": "rope-1", "handle": "R3", "title": "Twin-7真机实验", "kind": "project",
          "parent": nil as Any? as Any, "children": [twin, wrist], "proposed": true,
          "title_user_edited": false, "reason": "电机维修、基线跑测", "evidence": [item1],
        ],
        [
          "id": "rope-2", "handle": "R4", "title": "集群", "kind": "area",
          "parent": nil as Any? as Any, "children": [cluster], "proposed": false,
          "title_user_edited": false, "reason": "", "evidence": [] as [Any],
        ],
      ]
    state["relations"] =
      relations ?? [
        [
          "kind": "cross", "a": twin, "b": wrist, "count": 37, "item_ids": [item1],
          "proposed": false,
        ],
        [
          "kind": "blocks", "a": cluster, "b": twin, "quote": "等集群维护完再跑",
          "item_id": item2, "proposed": true, "source_event": twin,
        ],
      ]
    return state
  }

  static func decode(_ object: [String: Any]) throws -> RemoteOrganizerState {
    try JSONDecoder().decode(
      RemoteOrganizerState.self, from: JSONSerialization.data(withJSONObject: object))
  }

  // MARK: - Decoding

  func testStateDecodesMapsFacetsRopesAndRelations() throws {
    let state = try Self.decode(Self.state())
    let event = try XCTUnwrap(state.events.first { $0.eventID == Self.twin })
    let map = try XCTUnwrap(event.map)
    XCTAssertEqual(map.strands.map(\.id), ["s1", "s2"])
    XCTAssertEqual(map.strands.map(\.isClosed), [false, true])
    XCTAssertEqual(map.strands[0].segmentRefs, [.init(itemID: Self.item1, segID: "s1")])
    XCTAssertEqual(map.strands[0].factIDs, ["f1"])
    XCTAssertEqual(map.knots.map(\.id), ["k7", "k3"])
    XCTAssertEqual(map.knots[0].who, ["林知远"])
    XCTAssertEqual(map.knots[0].quoteSegID, "s2")
    // A question is open whatever the wire says; no strand is the main thread.
    XCTAssertEqual(map.knots[1].state, "open")
    XCTAssertNil(map.knots[1].strand)
    XCTAssertNil(map.knots[1].date)
    XCTAssertEqual(map.health?.level, "ok")
    XCTAssertEqual(map.skillVersion, "1.1.0")
    XCTAssertTrue(map.factsCurrent)
    let facets = try XCTUnwrap(event.facets)
    XCTAssertEqual(facets.type, "实验")
    XCTAssertEqual(facets.rope, "rope-1")
    XCTAssertTrue(facets.deadlineOverdue)
    XCTAssertEqual(state.ropes?.map(\.title), ["Twin-7真机实验", "集群"])
    XCTAssertEqual(state.ropes?.first?.children, [Self.twin, Self.wrist])
    XCTAssertEqual(state.ropes?.last?.isArea, true)
    XCTAssertEqual(state.relations?.count, 2)
    let blocks = try XCTUnwrap(state.relations?.first(where: \.isBlocks))
    XCTAssertEqual(blocks.a, Self.cluster)
    XCTAssertEqual(blocks.b, Self.twin)
    XCTAssertEqual(blocks.quote, "等集群维护完再跑")
    XCTAssertTrue(blocks.proposed)
    XCTAssertEqual(state.relations?.first(where: \.isCross)?.count, 37)
    // Round trip through the Mac's own storage format.
    let reencoded = try JSONDecoder().decode(
      RemoteOrganizerEvent.self, from: JSONEncoder().encode(event))
    XCTAssertEqual(reencoded, event)
  }

  func testAStateWithoutTheV7FieldsStillDecodes() throws {
    var object = Self.state()
    object.removeValue(forKey: "ropes")
    object.removeValue(forKey: "relations")
    var events = object["events"] as! [[String: Any]]
    events[0].removeValue(forKey: "map")
    events[0].removeValue(forKey: "facets")
    object["events"] = events
    let state = try Self.decode(object)
    XCTAssertNil(state.ropes)
    XCTAssertNil(state.relations)
    XCTAssertTrue(state.events.allSatisfy { $0.map == nil && $0.facets == nil })
    // `map: null` (not drawn yet) is no map.
    events[0]["map"] = NSNull()
    object["events"] = events
    XCTAssertNil(try Self.decode(object).events[0].map)
  }

  func testMalformedEntriesAreDroppedNotThePull() throws {
    let state = try Self.decode(
      Self.state(
        extraKnots: [
          ["id": "k9", "kind": "progress"],  // no text
          ["id": "k7", "kind": "progress", "text": "重复的 ID", "state": "done"],
          [
            "id": "k10", "strand": "s9", "kind": "made-up", "text": "未知的线索",
            "date": "2026-13-40", "state": "weird", "who": ["", "韩策"],
            "evidence": ["a", "A", 3],
          ],
        ],
        ropes: [
          ["id": "rope-1", "title": ""],
          ["title": "没有 ID"],
          ["id": "rope-3", "title": "好的绳", "parent": "rope-3", "children": [Self.twin]],
        ],
        relations: [
          ["kind": "cross", "a": Self.twin, "b": Self.twin, "count": 3],
          ["kind": "similar", "a": Self.twin, "b": Self.wrist],
          ["kind": "cross", "a": Self.twin, "b": Self.wrist, "count": -4],
        ]))
    let map = try XCTUnwrap(state.events[0].map)
    XCTAssertEqual(map.knots.map(\.id), ["k7", "k3", "k10"])
    let odd = map.knots[2]
    XCTAssertNil(odd.strand, "an unknown strand is the main thread")
    XCTAssertEqual(odd.kind, "progress")
    XCTAssertEqual(odd.state, "doing")
    XCTAssertNil(odd.date)
    XCTAssertEqual(odd.who, ["韩策"])
    XCTAssertEqual(odd.evidence, ["a"])
    XCTAssertEqual(state.ropes?.map(\.id), ["rope-3"])
    XCTAssertNil(state.ropes?.first?.parent, "a rope is not its own parent")
    XCTAssertEqual(state.relations?.count, 1)
    XCTAssertEqual(state.relations?.first?.count, 0)
    // A map that is not an object is dropped, and the event stays.
    var object = Self.state()
    var events = object["events"] as! [[String: Any]]
    events[0]["map"] = ["strands": "nope", "knots": 3]
    events[0]["facets"] = ["deadline": "soon", "health": "fine", "type": 7]
    object["events"] = events
    let second = try Self.decode(object)
    XCTAssertEqual(second.events.count, 3)
    XCTAssertNil(second.events[0].map)
    XCTAssertNil(second.events[0].facets?.deadline)
    XCTAssertNil(second.events[0].facets?.health)
  }

  // MARK: - Stored and projected

  func testTheProjectionKeepsMapsRopesAndRelationsWithOriginalsBack() async throws {
    let library = try SyntheticOrganizerLibrary()
    let placeholder = "〔手机号·abc123〕"
    try await library.store.recordRemoteMasks(
      .init(
        ownerID: UUID().uuidString,
        entries: [.init(placeholder: placeholder, original: "13900000001", type: "phone")]))
    let object = Self.state(
      mapText: "打给 \(placeholder) 约时间",
      ropes: [
        [
          "id": "rope-1", "title": "联系 \(placeholder)", "children": [Self.twin, Self.wrist],
          "reason": "都要打 \(placeholder)",
        ]
      ])
    _ = try await library.store.applyRemoteState(Self.decode(object))
    let projection = try await library.store.remoteProjection()
    let event = try XCTUnwrap(projection.events.first { $0.eventID == Self.twin })
    XCTAssertEqual(event.map?.knots.first?.text, "打给 13900000001 约时间")
    XCTAssertEqual(event.facets?.rope, "rope-1")
    XCTAssertEqual(projection.ropes.map(\.title), ["联系 13900000001"])
    XCTAssertEqual(projection.ropes.first?.reason, "都要打 13900000001")
    XCTAssertEqual(projection.relations.count, 2)
    // A later pull without the v7 fields (an older service) clears them.
    var old = Self.state(cursor: 8)
    old.removeValue(forKey: "ropes")
    old.removeValue(forKey: "relations")
    _ = try await library.store.applyRemoteState(Self.decode(old))
    let after = try await library.store.remoteProjection()
    XCTAssertEqual(after.ropes, [])
    XCTAssertEqual(after.relations, [])
    // Forgetting the organizing device clears them too.
    _ = try await library.store.applyRemoteState(Self.decode(Self.state(cursor: 9)))
    try await library.store.forgetRemoteStore()
    let forgotten = try await library.store.remoteProjection()
    XCTAssertEqual(forgotten.ropes, [])
    XCTAssertEqual(forgotten.relations, [])
    await library.close()
  }

  // MARK: - Decisions

  func testRopeAndRelationDecisionsAreStoredAndAppliedAtOnce() async throws {
    let library = try SyntheticOrganizerLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: enabledAt)
    _ = try await store.applyRemoteState(Self.decode(Self.state()))
    let decisions = [
      RemoteOrganizerDecision(kind: "confirm_rope", ropeID: "rope-2"),
      RemoteOrganizerDecision(kind: "rename_rope", title: "Twin-7 实验", ropeID: "rope-1"),
      RemoteOrganizerDecision(kind: "move_to_rope", eventID: Self.wrist, ropeID: "rope-2"),
      RemoteOrganizerDecision(kind: "move_to_rope", eventID: Self.cluster, ropeID: nil),
      RemoteOrganizerDecision(
        kind: "reject_relation", a: Self.cluster, b: Self.twin, relation: "blocks"),
      RemoteOrganizerDecision(kind: "hide_crossing", a: Self.wrist, b: Self.twin),
    ]
    for decision in decisions {
      XCTAssertTrue(decision.isWellFormed, decision.kind)
      try await store.enqueueRemoteDecision(decision)
    }
    var projection = try await store.remoteProjection()
    let renamed = try XCTUnwrap(projection.ropes.first { $0.id == "rope-1" })
    XCTAssertEqual(renamed.title, "Twin-7 实验")
    XCTAssertFalse(renamed.proposed, "renaming confirms")
    XCTAssertTrue(renamed.titleUserEdited)
    XCTAssertEqual(renamed.children, [Self.twin])
    let area = try XCTUnwrap(projection.ropes.first { $0.id == "rope-2" })
    XCTAssertFalse(area.proposed)
    XCTAssertEqual(area.children, [Self.wrist])
    XCTAssertEqual(
      projection.events.first { $0.eventID == Self.wrist }?.facets?.rope, "rope-2")
    XCTAssertNil(projection.events.first { $0.eventID == Self.cluster }?.facets?.rope)
    XCTAssertEqual(projection.relations, [], "the blocks edge and the crossing are gone")

    // Rejecting a rope releases its matters; ropes inside it move up.
    let nested = Self.state(
      cursor: 8,
      ropes: [
        ["id": "outer", "title": "科研", "children": [Self.cluster]],
        ["id": "inner", "title": "论文", "parent": "outer", "children": [Self.twin]],
      ])
    _ = try await store.applyRemoteState(Self.decode(nested))
    try await store.enqueueRemoteDecision(
      RemoteOrganizerDecision(kind: "reject_rope", ropeID: "outer"))
    projection = try await store.remoteProjection()
    XCTAssertEqual(projection.ropes.map(\.id), ["inner"])
    XCTAssertNil(projection.ropes.first?.parent)
    // The earlier move of the cluster matter still holds (on no rope).
    XCTAssertNil(projection.events.first { $0.eventID == Self.cluster }?.facets?.rope)
    await library.close()
  }

  func testDecisionShapesAndLimits() throws {
    func json(_ decision: RemoteOrganizerDecision) throws -> [String: Any] {
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(decision)) as! [String: Any]
    }
    let move = try json(RemoteOrganizerDecision(kind: "move_to_rope", eventID: "e", ropeID: "r"))
    XCTAssertEqual(move["rope_id"] as? String, "r")
    XCTAssertEqual(move["event_id"] as? String, "e")
    let off = try json(RemoteOrganizerDecision(kind: "move_to_rope", eventID: "e"))
    XCTAssertNil(off["rope_id"], "on no rope: the key is left out (the service reads null)")
    let reject = try json(
      RemoteOrganizerDecision(kind: "reject_relation", a: "x", b: "y", relation: "blocks"))
    XCTAssertEqual(reject["relation"] as? String, "blocks")
    // Limits the service enforces.
    let long = String(repeating: "绳", count: 41)
    XCTAssertFalse(
      RemoteOrganizerDecision(kind: "rename_rope", title: long, ropeID: "r").isWellFormed)
    XCTAssertTrue(
      RemoteOrganizerDecision(kind: "rename_rope", title: String(long.dropFirst()), ropeID: "r")
        .isWellFormed)
    XCTAssertFalse(
      RemoteOrganizerDecision(kind: "rename_rope", title: " ", ropeID: "r").isWellFormed)
    XCTAssertFalse(RemoteOrganizerDecision(kind: "confirm_rope").isWellFormed)
    XCTAssertFalse(RemoteOrganizerDecision(kind: "move_to_rope", ropeID: "r").isWellFormed)
    XCTAssertFalse(RemoteOrganizerDecision(kind: "reject_relation", a: "x", b: "y").isWellFormed)
    XCTAssertFalse(RemoteOrganizerDecision(kind: "hide_crossing", a: "x", b: "x").isWellFormed)
    // A retry keeps the rope and relation fields.
    let original = RemoteOrganizerDecision(kind: "move_to_rope", eventID: "e", ropeID: "r")
    XCTAssertEqual(original.reissued().ropeID, "r")
    XCTAssertEqual(
      RemoteOrganizerDecision(kind: "reject_relation", a: "x", b: "y", relation: "blocks")
        .withWireText(title: nil, displayName: nil).relation, "blocks")
  }

  func testTheLinkSendsRelationDecisionsAndAsksForMaps() async throws {
    let library = try SyntheticOrganizerLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: enabledAt)
    let placeholderTitle = "联系 13900000001 的事"
    try await store.enqueueRemoteDecision(
      RemoteOrganizerDecision(kind: "rename_rope", title: placeholderTitle, ropeID: "rope-1"))
    try await store.enqueueRemoteDecision(
      RemoteOrganizerDecision(kind: "hide_crossing", a: Self.twin, b: Self.wrist))
    let spark = FakeSpark()
    spark.setState(Self.state())
    let runtime = RemoteOrganizerRuntime(
      repository: store, launcher: FakeTunnelLauncher(), http: spark, keys: testOrganizerKeys,
      timing: fastTiming, onUpdate: { _, _ in })
    runtime.requestMap(eventID: Self.wrist)
    runtime.requestMap(eventID: Self.wrist)  // asked once per runtime
    runtime.start()
    try await waitUntil { spark.decisions.count == 2 }
    try await waitUntil { spark.paths.contains("/v1/events/\(Self.wrist)/map") }
    XCTAssertEqual(spark.decisions.map { $0["kind"] as? String }, ["rename_rope", "hide_crossing"])
    // The title the user typed is masked on the wire like any text.
    let title = try XCTUnwrap(spark.decisions.first?["title"] as? String)
    XCTAssertFalse(title.contains("13900000001"), title)
    XCTAssertEqual(spark.decisions.first?["rope_id"] as? String, "rope-1")
    XCTAssertEqual(spark.decisions.last?["a"] as? String, Self.twin)
    XCTAssertEqual(spark.paths.filter { $0.hasSuffix("/map") }.count, 1)
    // After the map request, the link keeps pulling (an unknown route is
    // not a link failure).
    let pulls = spark.paths.filter { $0.hasPrefix("/v1/state") }.count
    try await waitUntil { spark.paths.filter { $0.hasPrefix("/v1/state") }.count > pulls }
    runtime.stop()
    await library.close()
  }
}
