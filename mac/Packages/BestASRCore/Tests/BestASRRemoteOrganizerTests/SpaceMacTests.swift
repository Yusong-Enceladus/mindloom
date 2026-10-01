import BestASRDomain
import BestASRMemory
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import GRDB
import MindloomSpaces
import MindloomSpacesTestSupport
import XCTest

/// Shared spaces on the Mac with a real library (SPACES-CONTRACT §5, Mac
/// part): what leaves for a space is read from the library the way the
/// organizing link reads it — never a voiceprint, the dictionary or a window
/// title; members get the numbers as they are, the Spark only placeholders
/// made with the space's own mask key; recordings only as the parts filed
/// into the matter. Every value is made up.
final class SpaceMacTests: XCTestCase {
  static let dictionarySentinel = "SENTINEL-DICT-拾光专名"
  static let voiceprintSentinel = "SENTINEL-VOICEPRINT-0451"
  static let windowSentinel = "SENTINEL-WINDOW-TITLE-SPACE"
  static let identifiers = [
    "13812345678", "zhang.san@example.com", "11010519491231002X", "Tr0ub4dor-3x",
  ]
  static let identifierNote =
    "回电 13812345678，邮箱 zhang.san@example.com，身份证 11010519491231002X，密码：Tr0ub4dor-3x。"

  private func seed(_ library: SyntheticOrganizerLibrary) async throws -> (
    meeting: SessionID, dictation: SessionID
  ) {
    let meeting = SessionID(UUID())
    let dictation = SessionID(UUID())
    let lines = [
      (0, 60, "王姐：先说房租，下周一交。"),
      (600, 660, "李雷：装修报价三万，" + Self.identifierNote),
      (1_500, 1_560, "王姐：周末团建另外聊。"),
    ]
    try await library.write { db in
      for (id, mode) in [(meeting, "roomMicrophone"), (dictation, "dictation")] {
        let sid = id.rawValue.uuidString
        try db.execute(
          sql: """
            INSERT INTO sessions (id, revision, input_mode, state, source_audio_retention,
              created_at, updated_at)
            VALUES (?, 1, ?, 'completed', 'retained', 1790000000, 1790000002)
            """, arguments: [sid, mode])
        try db.execute(
          sql: """
            INSERT INTO dictation_snapshots (session_id, control_revision, phase, snapshot_json,
              is_ephemeral, updated_at) VALUES (?, 1, 'completed', ?, 0, 1790000002)
            """, arguments: [sid, Data("{}".utf8)])
        try db.execute(
          sql: """
            INSERT INTO session_metadata (session_id, revision, title, title_is_user_edited,
              source_kind, source_display_name, source_bundle_id, recording_format,
              created_at, updated_at)
            VALUES (?, 1, ?, 0, 'dictation', '备忘录', 'com.apple.Notes',
                    'float32-pcm-journal', 1790000000, 1790000002)
            """, arguments: [sid, Self.windowSentinel])
      }
      let transcript = UUID().uuidString
      try db.execute(
        sql: """
          INSERT INTO transcript_revisions (id, session_id, revision, kind, content, created_at)
          VALUES (?, ?, 1, 'final', ?, 1790000002)
          """,
        arguments: [
          transcript, meeting.rawValue.uuidString, lines.map(\.2).joined(separator: "\n"),
        ])
      for (index, line) in lines.enumerated() {
        try db.execute(
          sql: """
            INSERT INTO transcript_segments (transcript_id, segment_id, ordinal,
              monotonic_start_ns, monotonic_end_ns, text) VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            transcript, UUID().uuidString, index, Int64(line.0) * 1_000_000_000,
            Int64(line.1) * 1_000_000_000, line.2,
          ])
      }
      let dictationTranscript = UUID().uuidString
      try db.execute(
        sql: """
          INSERT INTO transcript_revisions (id, session_id, revision, kind, content, created_at)
          VALUES (?, ?, 1, 'final', ?, 1790000002)
          """,
        arguments: [
          dictationTranscript, dictation.rawValue.uuidString, "私事：" + Self.identifierNote,
        ])
      // People with voices: their names may go, their voiceprints never.
      for (name, start, end) in [("王姐", 0, 60), ("李雷", 600, 660)] {
        let person = UUID().uuidString
        let speaker = UUID().uuidString
        let occurrence = UUID().uuidString
        try db.execute(
          sql: """
            INSERT INTO persons (id, revision, display_name, aliases_json, created_at, updated_at)
            VALUES (?, 1, ?, '[]', 1000, 1000)
            """, arguments: [person, name])
        try db.execute(
          sql: """
            INSERT INTO session_speakers (id, session_id, revision, stable_ordinal)
            VALUES (?, ?, 1, (SELECT COALESCE(MAX(stable_ordinal), 0) + 1
                              FROM session_speakers WHERE session_id = ?))
            """, arguments: [speaker, meeting.rawValue.uuidString, meeting.rawValue.uuidString])
        try db.execute(
          sql: """
            INSERT INTO speaker_occurrences (id, session_id, session_speaker_id, revision,
              monotonic_start_ns, monotonic_end_ns, overlaps_another_speaker,
              association_status, person_id, confidence, evidence_revision)
            VALUES (?, ?, ?, 1, ?, ?, 0, 'userConfirmed', ?, 1, 1)
            """,
          arguments: [
            occurrence, meeting.rawValue.uuidString, speaker, Int64(start) * 1_000_000_000,
            Int64(end) * 1_000_000_000, person,
          ])
        try db.execute(
          sql: """
            INSERT INTO session_speaker_embeddings (session_speaker_id, revision,
              embedding_space_id, vector_json, speech_duration_ns, signal_quality,
              model_artifact_key, created_at)
            VALUES (?, 1, 'synthetic-space', ?, 1000000000, 0.9, 'synthetic', 1000)
            """, arguments: [speaker, Data("[\"\(Self.voiceprintSentinel)\"]".utf8)])
        try db.execute(
          sql: """
            INSERT INTO person_embeddings (id, person_id, revision, embedding_space_id,
              vector_json, speech_duration_ns, signal_quality, source_occurrence_id, created_at)
            VALUES (?, ?, 1, 'synthetic-space', ?, 1000000000, 0.9, ?, 1000)
            """,
          arguments: [
            UUID().uuidString, person, Data("[\"\(Self.voiceprintSentinel)\"]".utf8), occurrence,
          ])
      }
      // The personal dictionary.
      try db.execute(
        sql: """
          INSERT INTO dictionary_entries (id, revision, canonical_form, spoken_forms_json,
            enabled, created_at, updated_at)
          VALUES (?, 1, ?, ?, 1, 1000, 1000)
          """,
        arguments: [
          UUID().uuidString, Self.dictionarySentinel, "[\"\(Self.dictionarySentinel)\"]",
        ])
    }
    return (meeting, dictation)
  }

  private func twoMacs(_ spark: FakeSpaceSpark) async throws -> (TestMac, TestMac, String) {
    let a = TestMac("A", spark: spark)
    let b = TestMac("B", spark: spark)
    let endpoint = SpaceInviteCode.Endpoint(
      host: "spark.test", user: nil, hostKey: FakeSpaceSpark.hostKey)
    let space = try await a.engine.createSpace(
      name: "开业筹备", owner: .person, displayName: "林知远", spark: endpoint)
    let code = try await a.engine.invite(
      space.spaceID, role: .write, hostKey: FakeSpaceSpark.hostKey, spark: endpoint)
    _ = try await b.engine.join(
      code: code, displayName: "韩策", localHostKey: FakeSpaceSpark.hostKey)
    let requests = try await a.engine.joinRequests(space.spaceID)
    let request = try XCTUnwrap(requests.first)
    try await a.engine.approve(space.spaceID, request: request)
    _ = try await b.engine.refreshJoin(space.spaceID)
    return (a, b, space.spaceID)
  }

  // MARK: - The sentinel test, extended to space payloads

  func testSpacePayloadsNeverCarryAVoiceprintTheDictionaryOrAWindowTitle() async throws {
    let library = try SyntheticOrganizerLibrary()
    let (meeting, dictation) = try await seed(library)
    let meetingItemValue = try await library.store.spaceShareContent(sessionID: meeting)
    let meetingItem = try XCTUnwrap(meetingItemValue)
    let dictationItemValue = try await library.store.spaceShareContent(sessionID: dictation)
    let dictationItem = try XCTUnwrap(dictationItemValue)
    // The matter holds the middle part of the meeting only.
    let text = try XCTUnwrap(meetingItem.text)
    let middle = try XCTUnwrap(text.range(of: "李雷"))
    let start = text.unicodeScalars.distance(
      from: text.unicodeScalars.startIndex, to: middle.lowerBound)
    let parts = [SpaceShareContent.Part(start: start, end: start + 30)]
    let entries =
      SpaceShareContent.entries(
        for: meetingItem, title: "周会", matterID: "matter-1", parts: parts)
      + SpaceShareContent.entries(for: dictationItem, title: "口述", matterID: "matter-1")
    XCTAssertEqual(entries.count, 2)
    // A recording goes only as its part (10:00–11:00), never whole.
    let part = try XCTUnwrap(entries.first { $0.item.kind == "audio_segment" })
    XCTAssertEqual(part.item.segment?.startMS, 600_000)
    XCTAssertEqual(part.item.segment?.endMS, 660_000)
    XCTAssertEqual(part.item.fields.segments?.count, 1)
    XCTAssertEqual(part.item.fields.persons, ["李雷"])
    XCTAssertFalse(part.item.fields.text?.contains("房租") ?? true)
    XCTAssertFalse(entries.contains { SpaceShareContent.recordingKinds.contains($0.item.kind) })
    // Review defaults: the dictation is private; the part has numbers.
    XCTAssertFalse(entries.contains { $0.candidate.tickedByDefault })
    XCTAssertTrue(part.candidate.numberLabels.contains("手机号"))

    let spark = FakeSpaceSpark()
    let (a, b, spaceID) = try await twoMacs(spark)
    let report = try await a.engine.share(
      spaceID, items: entries.map(\.item),
      package: SpacePackageRequest(auto: .ask, matterID: "matter-1", title: "开业筹备"))
    XCTAssertEqual(report.shared.count, 2)
    let organized = try await a.engine.organize(spaceID, builder: SpaceOrganizerPayloads())
    XCTAssertEqual(organized.sent, 2)

    // Nothing that belongs to the body and habits, nor the window title,
    // anywhere in what left the Mac (ciphertext or organizing payloads).
    let wire = String(decoding: spark.everythingReceived, as: UTF8.self)
    for sentinel in [Self.dictionarySentinel, Self.voiceprintSentinel, Self.windowSentinel]
      + Self.identifiers
    {
      XCTAssertFalse(wire.contains(sentinel), "\(sentinel) left the Mac")
    }
    // The organizer got placeholders made with the space's mask key, not
    // the personal library's.
    let maskKey = try await a.engine.maskKey(spaceID)
    let spaceMasker = try PrivacyMasker(maskKey: maskKey)
    let phone = spaceMasker.placeholder(type: "phone", value: "13812345678")
    let personal = PrivacyMasker(keys: testOrganizerKeys).placeholder(
      type: "phone", value: "13812345678")
    XCTAssertNotEqual(phone, personal)
    let payloads = try XCTUnwrap(spark.space(spaceID)?.payloads)
    let payloadText = String(
      decoding: try SpaceJSON.array(Array(payloads.values)).encoded(), as: UTF8.self)
    XCTAssertTrue(payloadText.contains(phone))
    XCTAssertFalse(payloadText.contains(personal))
    XCTAssertTrue(payloadText.contains("李雷"))

    // The member reads the numbers as they are, and nothing else.
    let read = try await b.engine.sync(spaceID)
    let fields = read.activeItems.compactMap(\.fields)
    let memberText = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
    XCTAssertTrue(memberText.contains("13812345678"))
    for sentinel in [Self.dictionarySentinel, Self.voiceprintSentinel, Self.windowSentinel] {
      XCTAssertFalse(memberText.contains(sentinel), "\(sentinel) reached a member")
    }
    await library.close()
  }

  // MARK: - Masking toward the Spark, originals toward members

  func testTheSpaceViewPutsTheNumbersBackForMembersAndDropsWhatLeftOrIsHidden() throws {
    let k1 = Data(repeating: 0x21, count: 32)
    let maskKey = SpaceCrypto.maskKey(firstEpochKey: k1)
    let masker = try PrivacyMasker(maskKey: maskKey)
    let me = SpaceID.new()
    let mate = SpaceID.new()
    var state = SpaceLocalState(
      spaceID: SpaceID.new(), memberID: me, name: "实验室", ownerKind: .org, orgID: nil,
      policy: .org, role: .write, membership: .active, spark: nil)
    state.knownNames[mate] = "韩策"
    let kept = SpaceID.new()
    let hidden = SpaceID.new()
    let gone = SpaceID.new()
    func item(_ id: String, _ text: String, by: String, status: SpaceSharedItem.Status = .active)
      -> SpaceSharedItem
    {
      SpaceSharedItem(
        itemID: id, contributor: by, kind: "text", revision: 1, shareSeq: 2,
        firstSharedAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
        fields: status == .active
          ? SpaceItemFields(kind: "text", title: "回电", text: text, sourceName: "微信") : nil,
        blobs: [], segment: nil, packageID: nil, status: status, keyEpoch: 1)
    }
    state.items[kept] = item(kept, "房东电话 13812345678，周一回电", by: mate)
    state.items[hidden] = item(hidden, "不想看的", by: mate)
    state.items[gone] = item(gone, "", by: mate, status: .withdrawn)
    state.hidden = [hidden]
    let phone = masker.placeholder(type: "phone", value: "13812345678")
    let organizerState: SpaceJSON = [
      "cursor": 1, "questions": [], "persons": [], "unfiled": [], "readings": [],
      "events": [
        [
          "event_id": "ev-1", "title": .string("给 \(phone) 回电"), "title_user_edited": false,
          "status_line": .string("房东 \(phone)"), "status_facts": [], "importance": 0.9,
          "item_ids": [
            .string(kept.uppercased()), .string(hidden.uppercased()), .string(gone.uppercased()),
          ],
          "person_ids": [], "pinned": false, "deleted": false, "provenance": [:], "segments": [],
        ]
      ],
    ]
    state.organizer = SpaceOrganizerSnapshot(
      state: try organizerState.encoded(), sameAs: [], busyQueue: 0, busyBriefs: 0,
      pulledAt: Date())
    let view = SpaceProjectionBuilder.build(state, maskKey: maskKey)
    let event = try XCTUnwrap(view.projection.events.first)
    XCTAssertEqual(event.title, "给 13812345678 回电")
    XCTAssertEqual(event.statusLine, "房东 13812345678")
    XCTAssertEqual(event.itemIDs.map { $0.lowercased() }, [kept])
    XCTAssertEqual(view.records.count, 1)
    // Each item names its contributor.
    XCTAssertEqual(view.records.first?.sourceDisplayName, "微信 · 韩策")
    XCTAssertEqual(view.contributionLine(eventID: "ev-1"), "韩策 1 条")
    // Without the mask key nothing is guessed: the placeholder shows untagged.
    let blind = SpaceProjectionBuilder.build(state, maskKey: nil)
    XCTAssertEqual(blind.projection.events.first?.title, "给 〔手机号〕 回电")
  }

  // MARK: - "同一件事": the badge and the two-tone overlay

  func testTheSharedVersionsBadgeAndTheTwoToneOverlay() throws {
    let me = SpaceID.new()
    let mate = SpaceID.new()
    var state = SpaceLocalState(
      spaceID: SpaceID.new(), memberID: me, name: "实验室", ownerKind: .person, orgID: nil,
      policy: .group, role: .admin, membership: .active, spark: nil)
    state.knownNames[mate] = "韩策"
    let mine1 = UUID().uuidString
    let mine2 = UUID().uuidString
    let theirs1 = UUID().uuidString
    let theirs2 = UUID().uuidString
    let other = UUID().uuidString
    for (id, by) in [(mine1, me), (mine2, me), (theirs1, mate), (theirs2, mate), (other, mate)] {
      state.items[id.lowercased()] = SpaceSharedItem(
        itemID: id, contributor: by, kind: "text", revision: 1, shareSeq: 1,
        firstSharedAt: Date(), updatedAt: Date(),
        fields: SpaceItemFields(kind: "text", title: "t", text: "素材 \(id.prefix(4))"),
        blobs: [], segment: nil, packageID: nil, status: .active, keyEpoch: 1)
    }
    func event(_ id: String, _ items: [String], map: SpaceJSON = nil) -> SpaceJSON {
      [
        "event_id": .string(id), "title": .string(id), "title_user_edited": false,
        "status_line": "", "status_facts": [], "importance": 0.5,
        "item_ids": .array(items.map { .string($0) }), "person_ids": [], "pinned": false,
        "deleted": false, "provenance": [:], "segments": [], "map": map,
      ]
    }
    // v7: the space organizer draws maps too (MAP-CONTRACT inside SPACES-CONTRACT)
    let theirMap: SpaceJSON = [
      "strands": [
        ["id": "s1", "name": "招牌", "summary": "", "item_ids": [.string(other)], "state": "open"]
      ],
      "knots": [], "health": nil, "skill_version": "1.1.1", "stale": false,
      "facts_current": true,
    ]
    let organizerState: SpaceJSON = [
      "cursor": 1, "questions": [], "persons": [], "unfiled": [],
      "events": [
        event("space-ev", [mine1, mine2, theirs1, theirs2]),
        event("their-own", [other], map: theirMap),
      ],
    ]
    state.organizer = SpaceOrganizerSnapshot(
      state: try organizerState.encoded(),
      sameAs: [
        SpaceSameAs(eventID: "space-ev", memberID: me, matterID: "my-matter", items: 2),
        SpaceSameAs(eventID: "space-ev", memberID: mate, matterID: "his-matter", items: 2),
      ], busyQueue: 0, busyBriefs: 0, pulledAt: Date())
    let view = SpaceProjectionBuilder.build(state, maskKey: nil)
    let myMap = RemoteOrganizerMatterMap(
      strands: [.init(id: "s1", name: "菜单", itemIDs: [mine1])], knots: [])
    let personal = [
      MemoryEventSource(
        eventID: "my-matter", origin: .spark, title: "开业筹备", statusLine: "", pinned: false,
        updatedAt: nil, itemIDs: [mine1, mine2], personIDs: [], map: myMap)
    ]
    let badges = SpaceOverlay.badges(
      personal: personal.map { ($0.eventID, $0.itemIDs) }, spaces: [(state, view)])
    let badge = try XCTUnwrap(badges["my-matter"])
    XCTAssertEqual(badge.text, "共享版更完整 · +2 条，来自 韩策")
    XCTAssertEqual(badge.spaceEventID, "space-ev")

    let merged = SpaceOverlay.merged(
      personal: personal, personalRecords: [], personalPersons: [], spaces: [(state, view)])
    let mine = try XCTUnwrap(merged.events.first { $0.eventID == "my-matter" })
    XCTAssertEqual(
      Set(mine.itemIDs.map { $0.uppercased() }),
      Set([mine1, mine2, theirs1, theirs2].map { $0.uppercased() }))
    XCTAssertEqual(merged.othersItemIDs, Set([theirs1, theirs2, other].map { $0.uppercased() }))
    // My matter keeps its own map in 全部 (v7 integration).
    XCTAssertEqual(mine.map, myMap)
    // The space's matter none of mine links to is there too, read-only, with its map.
    let foreign = try XCTUnwrap(merged.events.first { $0.eventID.hasSuffix(":their-own") })
    XCTAssertEqual(merged.spaceEvents[foreign.eventID], state.spaceID)
    XCTAssertEqual(foreign.map?.strands.map(\.name), ["招牌"])
    // The space's own copy of my matter is not listed twice.
    XCTAssertFalse(merged.events.contains { $0.eventID.hasSuffix(":space-ev") })
  }

  // MARK: - 整根绳 on the map's ropes (v7 integration)

  func testARopeRuleCoversTheRopeAndTheRopesInsideItAndSendsByItselfOnlyWhenConfirmed() {
    let ropes = [
      RemoteOrganizerRope(id: "r-lab", title: "科研", children: ["E1", "E2"], proposed: false),
      RemoteOrganizerRope(id: "r-paper", title: "论文", parent: "r-lab", children: ["E3", "E1"]),
      RemoteOrganizerRope(id: "r-deep", title: "附录", parent: "r-paper", children: ["E4"]),
      RemoteOrganizerRope(id: "r-life", title: "生活", children: ["E9"]),
      // a loop in the parent links does not hang or repeat
      RemoteOrganizerRope(id: "r-a", title: "甲", parent: "r-b", children: ["E5"]),
      RemoteOrganizerRope(id: "r-b", title: "乙", parent: "r-a", children: ["E6"]),
    ]
    XCTAssertEqual(SpaceRopeRule.matters(of: "r-lab", in: ropes), ["E1", "E2", "E3", "E4"])
    XCTAssertEqual(SpaceRopeRule.matters(of: "r-paper", in: ropes), ["E3", "E1", "E4"])
    XCTAssertEqual(SpaceRopeRule.matters(of: "r-a", in: ropes), ["E5", "E6"])
    XCTAssertEqual(SpaceRopeRule.matters(of: "gone", in: ropes), [])
    XCTAssertTrue(SpaceRopeRule.sendsByItself(ropes[0]))
    XCTAssertFalse(SpaceRopeRule.sendsByItself(ropes[1]))
  }

  // MARK: - Recordings: parts only

  func testARecordingGoesAsPartsOfAtMostFifteenMinutes() {
    let id = UUID()
    let lines = (0..<40).map { minute in
      RemoteOrganizerItem.Segment(
        startMS: Int64(minute) * 60_000, endMS: Int64(minute) * 60_000 + 50_000,
        personID: nil, text: "第 \(minute) 分钟")
    }
    let recording = RemoteOrganizerItem(
      itemID: id, revision: 0, kind: "meeting_online",
      sourceApp: .init(bundleID: nil, name: "腾讯会议"), startedAt: "2026-09-20T09:00:00+08:00",
      text: lines.map(\.text).joined(separator: "\n"), segments: lines, sha256: "x")
    // Filed whole: consecutive parts, none longer than 15 minutes.
    let whole = SpaceShareContent.entries(for: recording, title: "周会", matterID: nil)
    XCTAssertEqual(whole.count, 3)
    for entry in whole {
      XCTAssertEqual(entry.item.kind, "audio_segment")
      let segment = try? XCTUnwrap(entry.item.segment)
      XCTAssertLessThanOrEqual((segment?.endMS ?? 0) - (segment?.startMS ?? 0), 15 * 60_000)
      XCTAssertNil(SpaceEngine.refusal(entry.item))
      XCTAssertEqual(entry.item.fields.parentKind, "meeting_online")
    }
    // Offered as choices only: none ticked for you, one per recording at most
    // (review V7-S5).
    XCTAssertFalse(whole.contains { $0.candidate.tickedByDefault })
    var review = SpaceShareReview(candidates: whole.map(\.candidate))
    for entry in whole { review.toggle(entry.candidate.id) }
    XCTAssertEqual(review.selected.map(\.id), [whole[2].candidate.id])
    // The same part always has the same id.
    let again = SpaceShareContent.entries(for: recording, title: "周会", matterID: nil)
    XCTAssertEqual(whole.map(\.item.itemID), again.map(\.item.itemID))
    // A filed part: only its lines.
    let text = recording.text ?? ""
    let start = text.unicodeScalars.distance(
      from: text.unicodeScalars.startIndex,
      to: text.range(of: "第 20 分钟")!.lowerBound)
    let part = SpaceShareContent.entries(
      for: recording, title: "周会", matterID: nil,
      parts: [.init(start: start, end: start + 6)])
    XCTAssertEqual(part.count, 1)
    XCTAssertEqual(part.first?.item.segment?.startMS, 20 * 60_000)
    XCTAssertEqual(part.first?.item.fields.text, "第 20 分钟")
    // The organizing payload of a part reads like its recording, masked.
    let shared = SpaceSharedItem(
      itemID: part[0].item.itemID, contributor: SpaceID.new(), kind: "audio_segment", revision: 1,
      shareSeq: 1, firstSharedAt: Date(), updatedAt: Date(), fields: part[0].item.fields,
      blobs: [], segment: part[0].item.segment, packageID: nil, status: .active, keyEpoch: 1)
    XCTAssertEqual(
      SpaceOrganizerPayloads.organizerItem(shared, part[0].item.fields).kind, "meeting_online")
  }

  /// Regression (lab end-to-end run, 2026-09-30): a part was titled with its
  /// recording's first words — a line about another matter that was never
  /// filed — and dated at the recording's start.
  func testAPartIsNamedAndTimedByItsOwnLinesOnly() {
    let lines = [
      RemoteOrganizerItem.Segment(
        startMS: 0, endMS: 20_000, personID: nil, text: "先说灰狼机械臂上的触觉夹爪"),
      RemoteOrganizerItem.Segment(
        startMS: 20_000, endMS: 50_000, personID: nil, text: "Twin-7 毛巾跑完了，41/50"),
      RemoteOrganizerItem.Segment(
        startMS: 50_000, endMS: 80_000, personID: nil, text: "基线评测下周再说"),
    ]
    let text = lines.map(\.text).joined(separator: "\n")
    let start = lines[0].text.unicodeScalars.count + 1
    let filed = SpaceShareContent.Part(
      start: start, end: start + lines[1].text.unicodeScalars.count)
    let recording = RemoteOrganizerItem(
      itemID: UUID(), revision: 0, kind: "meeting_offline",
      sourceApp: .init(bundleID: nil, name: "线下录音"),
      startedAt: "2026-09-09T14:00:00.000+08:00", text: text, segments: lines, sha256: "x")
    let part = SpaceShareContent.entries(
      for: recording, title: nil, matterID: "E5", parts: [filed])
    XCTAssertEqual(part.count, 1)
    let fields = part[0].item.fields
    let shown = (fields.texts + [part[0].candidate.title, part[0].candidate.preview])
      .joined(separator: "\n")
    XCTAssertFalse(shown.contains("触觉夹爪"))
    XCTAssertFalse(shown.contains("基线评测"))
    XCTAssertEqual(fields.parentTitle, "线下录音")
    XCTAssertEqual(fields.title, "Twin-7 毛巾跑完了，41/50（0:20–0:50）")
    XCTAssertEqual(fields.startedAt, "2026-09-09T14:00:20+08:00")
    XCTAssertEqual(fields.endedAt, "2026-09-09T14:00:50+08:00")
    // The user's own title still names the part.
    let named = SpaceShareContent.entries(
      for: recording, title: "周三组会", matterID: "E5", parts: [filed])
    XCTAssertEqual(named.first?.item.fields.title, "周三组会（0:20–0:50）")
    XCTAssertEqual(named.first?.item.fields.parentTitle, "周三组会")
    // A whole-text edit has no timed lines: only the filed characters go.
    let edited = RemoteOrganizerItem(
      itemID: UUID(), revision: 0, kind: "meeting_offline",
      sourceApp: .init(bundleID: nil, name: "线下录音"),
      startedAt: "2026-09-09T14:00:00.000+08:00", text: text, segments: nil, sha256: "x")
    let editedPart = SpaceShareContent.entries(
      for: edited, title: nil, matterID: "E5", parts: [filed])
    XCTAssertEqual(editedPart.count, 1)
    XCTAssertEqual(editedPart.first?.item.fields.text, lines[1].text)
    XCTAssertFalse(
      (editedPart.first?.item.fields.texts ?? []).joined().contains("触觉夹爪"))
  }

  // MARK: - Secrets: Keychain, or files only in a synthetic root

  // MARK: - Review fixes (V7-S11, V7-S13)

  func testOriginalsOpenedFromASpaceGoWhenTheirItemLeavesAndAtEveryLaunch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "space-originals-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let space = SpaceID.new()
    let kept = SpaceID.new()
    let gone = SpaceID.new()
    let folder = SpaceOriginalsFolder(root: root)
    let one = try folder.write(
      Data("原件一".utf8), space: space, item: kept, blob: SpaceID.new(), ext: "pdf")
    let two = try folder.write(
      Data("原件二".utf8), space: space, item: gone, blob: SpaceID.new(), ext: "png")
    let mode = try FileManager.default.attributesOfItem(atPath: one.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o600)
    let dirMode =
      try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
    XCTAssertEqual(dirMode, 0o700)
    // The second item was withdrawn: its decrypted original goes.
    folder.prune { $0 == space && $1 == kept }
    XCTAssertTrue(FileManager.default.fileExists(atPath: one.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: two.path))
    // Access to the space ended: everything of it goes.
    folder.prune { _, _ in false }
    XCTAssertEqual(folder.files(), [])
    // A file an earlier launch left is gone at the next launch.
    let earlier = try folder.write(
      Data("原件三".utf8), space: space, item: kept, blob: SpaceID.new(), ext: "")
    SpaceOriginalsFolder(root: root).purgeAll()
    XCTAssertFalse(FileManager.default.fileExists(atPath: earlier.path))
    XCTAssertThrowsError(
      try folder.write(Data(), space: "../x", item: kept, blob: SpaceID.new(), ext: "pdf"))
  }

  func testAMaintainersTitleIsMaskedWithTheSpacesMaskKey() throws {
    let maskKey = SpaceCrypto.maskKey(firstEpochKey: Data(repeating: 0x21, count: 32))
    let masked = try SpaceTitleMasker().mask("给 13812345678 回电话", maskKey: maskKey)
    XCTAssertFalse(masked.contains("13812345678"))
    let placeholder = try PrivacyMasker(maskKey: maskKey).placeholder(
      type: "phone", value: "13812345678")
    XCTAssertTrue(masked.contains(placeholder))
  }

  func testSpaceSecretsLiveInFilesOnlyInASyntheticRoot() throws {
    let real = FileManager.default.temporaryDirectory.appendingPathComponent(
      "space-real-\(UUID().uuidString)")
    let plain = FileManager.default.temporaryDirectory.appendingPathComponent(
      "space-plain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: real)
      try? FileManager.default.removeItem(at: plain)
    }
    XCTAssertThrowsError(try SpaceStores.synthetic(dataRoot: plain, realLibraryRoot: real))
    XCTAssertThrowsError(try SpaceStores.synthetic(dataRoot: real, realLibraryRoot: real))
    FileManager.default.createFile(
      atPath: plain.appendingPathComponent(RemoteOrganizerDataProvenance.syntheticMarkerFileName)
        .path, contents: Data())
    let stores = try SpaceStores.synthetic(dataRoot: plain, realLibraryRoot: real)
    let device = try stores.loadOrCreateDevice()
    XCTAssertEqual(try stores.loadOrCreateDevice().deviceID, device.deviceID)
    try stores.keys.save(Data(repeating: 7, count: 32), space: SpaceID.new(), epoch: 1)
    let files = try FileManager.default.contentsOfDirectory(
      atPath: plain.appendingPathComponent("space-keys").path)
    for file in files {
      let mode =
        try FileManager.default.attributesOfItem(
          atPath: plain.appendingPathComponent("space-keys/\(file)").path)[.posixPermissions]
        as? Int
      XCTAssertEqual(mode, 0o600, file)
    }
    // Losing the marker locks the files away.
    try FileManager.default.removeItem(
      at: plain.appendingPathComponent(RemoteOrganizerDataProvenance.syntheticMarkerFileName))
    XCTAssertThrowsError(try stores.device.load())
  }
}
