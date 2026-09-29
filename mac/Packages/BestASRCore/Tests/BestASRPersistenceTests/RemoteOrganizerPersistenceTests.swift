import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRPersistence
import Foundation
import GRDB
import XCTest

/// Synthetic library for organizer-link persistence tests. Every value is
/// fabricated; nothing here reads the owner's library.
final class SyntheticRemoteLibrary {
  let root: URL
  let url: URL
  let store: GRDBDictationStore
  /// The store's own writer may be mid-transaction (the organizer worker
  /// polls), so the fixture connection waits instead of failing.
  static let busyTolerant: Configuration = {
    var configuration = Configuration()
    configuration.busyMode = .timeout(10)
    return configuration
  }()

  init(timeZone: TimeZone = .current) throws {
    root = try persistenceTemporaryDirectory()
    url = root.appendingPathComponent("synthetic.sqlite")
    store = try GRDBDictationStore(databaseURL: url, remoteItemTimeZone: timeZone)
  }

  func close() async throws {
    try await store.checkpointAndClose()
    try? FileManager.default.removeItem(at: root)
  }

  func write(_ body: @escaping @Sendable (Database) throws -> Void) async throws {
    let writer = try DatabaseQueue(path: url.path, configuration: Self.busyTolerant)
    try await writer.write(body)
    try await writer.close()
  }

  func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
    let reader = try DatabaseQueue(path: url.path, configuration: Self.busyTolerant)
    let value = try await reader.read(body)
    try await reader.close()
    return value
  }

  static func sessionID(_ value: UInt64) -> SessionID {
    SessionID(persistenceUUID(value))
  }

  func seedCompletedSession(
    _ sessionID: SessionID, createdAt: Double, text: String,
    transcriptRevision: Int64 = 2, inputMode: String = "dictation"
  ) async throws {
    let id = sessionID.rawValue.uuidString
    try await write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions (
            id, revision, input_mode, state, source_audio_retention,
            created_at, updated_at
          ) VALUES (?, 1, ?, 'completed', 'retained', ?, ?)
          """, arguments: [id, inputMode, createdAt, createdAt + 2]
      )
      // As the live capture path does: eligible only while the link is on.
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO remote_organizer_eligible (session_id, eligible_at)
          SELECT ?, ? WHERE EXISTS (
            SELECT 1 FROM remote_organizer_meta WHERE key = 'link_enabled_at')
          """, arguments: [id, createdAt]
      )
      try db.execute(
        sql: """
          INSERT INTO dictation_snapshots (
            session_id, control_revision, phase, snapshot_json,
            is_ephemeral, updated_at
          ) VALUES (?, 1, 'completed', ?, 0, ?)
          """, arguments: [id, Data("{}".utf8), createdAt + 2]
      )
      try db.execute(
        sql: """
          INSERT INTO session_metadata (
            session_id, revision, title, title_is_user_edited,
            source_kind, source_display_name, source_bundle_id,
            recording_format, created_at, updated_at
          ) VALUES (?, 1, 'SENTINEL-WINDOW-TITLE', 0, 'dictation',
                    'Synthetic Editor', 'dev.synthetic.editor',
                    'float32-pcm-journal', ?, ?)
          """, arguments: [id, createdAt, createdAt + 2]
      )
    }
    try await addRevision(
      sessionID, revision: transcriptRevision, kind: "final", text: text,
      createdAt: createdAt + 2
    )
  }

  func addRevision(
    _ sessionID: SessionID, revision: Int64, kind: String, text: String,
    createdAt: Double
  ) async throws {
    let id = sessionID.rawValue.uuidString
    try await write { db in
      let transcriptID = UUID().uuidString
      try db.execute(
        sql: """
          INSERT INTO transcript_revisions (
            id, session_id, revision, kind, content, created_at
          ) VALUES (?, ?, ?, ?, ?, ?)
          """, arguments: [transcriptID, id, revision, kind, text, createdAt]
      )
      try db.execute(
        sql: """
          INSERT INTO transcript_segments (
            transcript_id, segment_id, ordinal,
            monotonic_start_ns, monotonic_end_ns, text
          ) VALUES (?, ?, 0, 8000000000, 9000000000, ?)
          """, arguments: [transcriptID, UUID().uuidString, text]
      )
    }
  }

  /// Assigns the whole synthetic segment to a person, as the speaker worker
  /// or a user speaker correction would.
  func assignPerson(
    _ sessionID: SessionID, personID: String, displayName: String?
  ) async throws {
    let id = sessionID.rawValue.uuidString
    try await write { db in
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO persons (id, revision, display_name, aliases_json,
                                         created_at, updated_at)
          VALUES (?, 1, ?, '[]', 1000, 1000)
          """, arguments: [personID, displayName]
      )
      let speakerID = UUID().uuidString
      try db.execute(
        sql: """
          INSERT INTO session_speakers (id, session_id, revision, stable_ordinal)
          VALUES (?, ?, 1, (SELECT COALESCE(MAX(stable_ordinal), 0) + 1
                            FROM session_speakers WHERE session_id = ?))
          """, arguments: [speakerID, id, id]
      )
      try db.execute(
        sql: """
          INSERT INTO speaker_occurrences (
            id, session_id, session_speaker_id, revision, monotonic_start_ns,
            monotonic_end_ns, overlaps_another_speaker, association_status,
            person_id, confidence, evidence_revision
          ) VALUES (?, ?, ?, 1, 8000000000, 9000000000, 0, 'userConfirmed', ?, 1, 1)
          """, arguments: [UUID().uuidString, id, speakerID, personID]
      )
    }
  }

  func renamePerson(_ personID: String, to name: String) async throws {
    try await write { db in
      try db.execute(
        sql: "UPDATE persons SET display_name = ?, revision = revision + 1 WHERE id = ?",
        arguments: [name, personID]
      )
    }
  }

  func itemState(_ sessionID: SessionID) async throws -> String? {
    try await itemJob(sessionID)
  }

  /// The item job's state, or nil when the session is not tracked.
  func itemJob(_ sessionID: SessionID) async throws -> String? {
    let id = sessionID.rawValue.uuidString
    return try await read { db in
      try String.fetchOne(
        db, sql: "SELECT state FROM remote_organizer_item_jobs WHERE item_id = ?",
        arguments: [id]
      )
    }
  }
}

func payloadObject(_ delivery: RemoteOrganizerItemDelivery) throws -> [String: Any] {
  try XCTUnwrap(JSONSerialization.jsonObject(with: delivery.payload) as? [String: Any])
}

private let linkEnabledAt = Date(timeIntervalSince1970: 500)

final class RemoteOrganizerPersistenceTests: XCTestCase {
  func testPayloadCarriesOnlyAllowedFieldsAndNoPrivateSentinels() async throws {
    let library = try SyntheticRemoteLibrary()
    let sessionID = SyntheticRemoteLibrary.sessionID(11)
    try await library.store.enableRemoteLink(at: linkEnabledAt)
    try await library.seedCompletedSession(
      sessionID, createdAt: 1000, text: "虚构的咖啡馆本周五确认菜单。"
    )
    try await library.assignPerson(sessionID, personID: "person-synthetic", displayName: "虚构甲")
    let id = sessionID.rawValue.uuidString
    // Private material that must never leave the Mac, each with a unique
    // sentinel that would show up verbatim if a query ever joined it in.
    try await library.write { db in
      try db.execute(
        sql: """
          INSERT INTO tracks (id, session_id, revision, role, asset_reference,
                              sample_rate_hz, channel_count)
          VALUES ('track-1', ?, 1, 'microphone', 'assets/SENTINEL-AUDIO-TRACK', 16000, 1)
          """, arguments: [id]
      )
      try db.execute(
        sql: """
          INSERT INTO audio_chunks (id, session_id, track_id, revision, sequence,
                                    monotonic_start_ns, frame_count, digest,
                                    asset_reference)
          VALUES ('chunk-1', ?, 'track-1', 1, 0, 0, 160, ?, 'assets/SENTINEL-AUDIO-CHUNK')
          """, arguments: [id, String(repeating: "e", count: 64)]
      )
      try db.execute(
        sql: """
          INSERT INTO person_embeddings (id, person_id, revision, embedding_space_id,
                                         vector_json, speech_duration_ns,
                                         signal_quality, created_at)
          VALUES ('embedding-1', 'person-synthetic', 1, 'SENTINEL-EMBEDDING-SPACE',
                  '[0.918273645546372]', 1000000000, 0.9, 1000)
          """
      )
      try db.execute(
        sql: """
          INSERT INTO session_speaker_embeddings (
            session_speaker_id, revision, embedding_space_id, vector_json,
            speech_duration_ns, signal_quality, model_artifact_key, created_at
          )
          SELECT id, 1, 'SENTINEL-SESSION-EMBEDDING', '[0.556677889900112]',
                 1000000000, 0.9, 'SENTINEL-MODEL-KEY', 1000
          FROM session_speakers WHERE session_id = ?
          """, arguments: [id]
      )
      try db.execute(
        sql: """
          INSERT INTO dictionary_entries (id, revision, canonical_form,
                                          spoken_forms_json, enabled,
                                          created_at, updated_at)
          VALUES ('dict-1', 1, 'SENTINEL-DICTIONARY-TERM',
                  '["SENTINEL-SPOKEN-FORM"]', 1, 1000, 1000)
          """
      )
      try db.execute(
        sql: """
          INSERT INTO source_context_events (
            id, session_id, revision, adapter_id, source_bundle_id,
            meeting_title, window_title, participant_names_json,
            active_speaker_name, monotonic_ns, reliability
          ) VALUES ('context-1', ?, 1, 'synthetic', 'dev.synthetic.editor',
                    'SENTINEL-MEETING-TITLE', 'SENTINEL-CONTEXT-WINDOW',
                    '["SENTINEL-PARTICIPANT"]', 'SENTINEL-ACTIVE-SPEAKER', 0,
                    'advisory')
          """, arguments: [id]
      )
    }

    let queued = try await library.store.enqueueRemoteSession(sessionID: sessionID)
    XCTAssertTrue(queued)
    let claimed = try await library.store.claimNextRemoteItem(now: Date())
    let delivery = try XCTUnwrap(claimed)
    let body = try XCTUnwrap(String(data: delivery.payload, encoding: .utf8))
    for sentinel in [
      "SENTINEL-WINDOW-TITLE", "SENTINEL-AUDIO-TRACK", "SENTINEL-AUDIO-CHUNK",
      "SENTINEL-EMBEDDING-SPACE", "918273645546372", "SENTINEL-SESSION-EMBEDDING",
      "556677889900112", "SENTINEL-MODEL-KEY", "SENTINEL-DICTIONARY-TERM",
      "SENTINEL-SPOKEN-FORM", "SENTINEL-MEETING-TITLE", "SENTINEL-CONTEXT-WINDOW",
      "SENTINEL-PARTICIPANT", "SENTINEL-ACTIVE-SPEAKER",
    ] {
      XCTAssertFalse(body.contains(sentinel), sentinel)
    }
    // Exact field allowlist, top level and nested.
    let object = try payloadObject(delivery)
    XCTAssertEqual(
      Set(object.keys),
      [
        "item_id", "revision", "kind", "source_app", "started_at", "text",
        "segments", "persons", "sha256",
      ]
    )
    let source = try XCTUnwrap(object["source_app"] as? [String: Any])
    XCTAssertEqual(Set(source.keys), ["bundle_id", "name"])
    XCTAssertEqual(source["bundle_id"] as? String, "dev.synthetic.editor")
    let segments = try XCTUnwrap(object["segments"] as? [[String: Any]])
    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(Set(segments[0].keys), ["start_ms", "end_ms", "person_id", "text"])
    XCTAssertEqual(segments[0]["person_id"] as? String, "person-synthetic")
    let persons = try XCTUnwrap(object["persons"] as? [[String: Any]])
    XCTAssertEqual(persons.count, 1)
    XCTAssertEqual(Set(persons[0].keys), ["person_id", "display_name"])
    XCTAssertEqual(persons[0]["display_name"] as? String, "虚构甲")
    XCTAssertEqual(object["text"] as? String, "虚构的咖啡馆本周五确认菜单。")
    try await library.close()
  }

  func testOutboxBuildsPayloadAtSendTimeAndCoalescesRevisions() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    let sessionID = SyntheticRemoteLibrary.sessionID(21)
    try await store.enableRemoteLink(at: linkEnabledAt)
    try await library.seedCompletedSession(sessionID, createdAt: 1000, text: "原始的虚构口述")
    let enqueued = try await store.enqueueRemoteSession(sessionID: sessionID)
    XCTAssertTrue(enqueued)
    // Two edits before the first send coalesce into one send of the latest.
    try await library.addRevision(
      sessionID, revision: 3, kind: "userEdit", text: "第一次修改", createdAt: 1003
    )
    try await library.addRevision(
      sessionID, revision: 4, kind: "userEdit", text: "去掉秘密后的虚构口述", createdAt: 1004
    )
    let firstClaim = try await store.claimNextRemoteItem(now: Date())
    let first = try XCTUnwrap(firstClaim)
    XCTAssertEqual(first.revision, 2)
    XCTAssertEqual(try payloadObject(first)["text"] as? String, "去掉秘密后的虚构口述")
    XCTAssertEqual(try payloadObject(first)["revision"] as? Int, 2)
    let nothingElse = try await store.claimNextRemoteItem(now: Date())
    XCTAssertNil(nothingElse)
    try await store.markRemoteItemDelivered(first)
    let observed1 = try await library.itemState(sessionID)
    XCTAssertEqual(observed1, "delivered")

    // A later edit is a new, higher revision built from the current text.
    try await library.addRevision(
      sessionID, revision: 5, kind: "userEdit", text: "再次修改的虚构口述", createdAt: 1005
    )
    let observed2 = try await library.itemState(sessionID)
    XCTAssertEqual(observed2, "queued")
    let secondClaim = try await store.claimNextRemoteItem(now: Date())
    let second = try XCTUnwrap(secondClaim)
    XCTAssertEqual(second.revision, 3)
    XCTAssertEqual(try payloadObject(second)["text"] as? String, "再次修改的虚构口述")
    XCTAssertNil(try payloadObject(second)["persons"])

    // A speaker correction while the send is in flight keeps the item queued
    // after the acknowledgement, and the next revision carries the person.
    try await library.assignPerson(sessionID, personID: "person-a", displayName: "虚构乙")
    try await store.markRemoteItemDelivered(second)
    let observed3 = try await library.itemState(sessionID)
    XCTAssertEqual(observed3, "queued")
    let thirdClaim = try await store.claimNextRemoteItem(now: Date())
    let third = try XCTUnwrap(thirdClaim)
    XCTAssertEqual(third.revision, 4)
    let thirdPersons = try XCTUnwrap(try payloadObject(third)["persons"] as? [[String: Any]])
    XCTAssertEqual(thirdPersons.first?["display_name"] as? String, "虚构乙")
    try await store.markRemoteItemDelivered(third)

    // A person rename re-sends with the new display name.
    try await library.renamePerson("person-a", to: "虚构丙")
    let fourthClaim = try await store.claimNextRemoteItem(now: Date())
    let fourth = try XCTUnwrap(fourthClaim)
    XCTAssertEqual(fourth.revision, 5)
    let fourthPersons = try XCTUnwrap(try payloadObject(fourth)["persons"] as? [[String: Any]])
    XCTAssertEqual(fourthPersons.first?["display_name"] as? String, "虚构丙")
    // A retryable failure resends the same revision with the same content.
    try await store.markRemoteItemFailed(
      fourth, category: "transport", retryAt: Date().addingTimeInterval(-1)
    )
    let retryClaim = try await store.claimNextRemoteItem(now: Date())
    let retry = try XCTUnwrap(retryClaim)
    XCTAssertEqual(retry.revision, 5)
    XCTAssertEqual(retry.retryCount, 1)
    XCTAssertEqual(retry.contentSHA256, fourth.contentSHA256)
    try await store.markRemoteItemDelivered(retry)

    // Re-enqueueing an unchanged item sends nothing.
    _ = try await store.enqueueRemoteSession(sessionID: sessionID)
    let unchanged = try await store.claimNextRemoteItem(now: Date())
    XCTAssertNil(unchanged)
    let observed4 = try await library.itemState(sessionID)
    XCTAssertEqual(observed4, "delivered")

    // Explicit deletion removes the job so the source can never leave later.
    try await library.addRevision(
      sessionID, revision: 6, kind: "userEdit", text: "删除前的修改", createdAt: 1006
    )
    try await store.deleteSessionRecordsExplicitly(sessionID: sessionID)
    let afterDeletion = try await store.claimNextRemoteItem(now: Date())
    XCTAssertNil(afterDeletion)
    let observed5 = try await library.itemJob(sessionID)
    XCTAssertNil(observed5)
    try await library.close()
  }

  func testWatermarkReconciliationAndRevocation() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    let before = SyntheticRemoteLibrary.sessionID(31)
    let recovered = SyntheticRemoteLibrary.sessionID(32)
    let delivered = SyntheticRemoteLibrary.sessionID(33)
    // Captured while the link was off: never sent automatically.
    try await library.seedCompletedSession(before, createdAt: 400, text: "开启前的虚构记录")
    let offEnqueue = try await store.enqueueRemoteSession(sessionID: delivered)
    XCTAssertFalse(offEnqueue)
    try await store.enableRemoteLink(at: linkEnabledAt)
    let beforeEnqueue = try await store.enqueueRemoteSession(sessionID: before)
    XCTAssertFalse(beforeEnqueue)
    // Completed while the link was on but never enqueued (crash recovery,
    // quit during bookkeeping): the sweep adds exactly these.
    try await library.seedCompletedSession(recovered, createdAt: 1000, text: "恢复的虚构记录")
    try await library.seedCompletedSession(delivered, createdAt: 1001, text: "已送达的虚构记录")
    let swept = try await store.reconcileRemoteItems()
    XCTAssertEqual(swept, 2)
    let sweptAgain = try await store.reconcileRemoteItems()
    XCTAssertEqual(sweptAgain, 0)
    let observed6 = try await library.itemJob(before)
    XCTAssertNil(observed6)
    let firstClaim = try await store.claimNextRemoteItem(now: Date())
    let first = try XCTUnwrap(firstClaim)
    XCTAssertEqual(first.itemID, recovered.rawValue)
    try await store.markRemoteItemFailed(
      first, category: "server", retryAt: Date().addingTimeInterval(60)
    )
    let secondClaim = try await store.claimNextRemoteItem(now: Date())
    let second = try XCTUnwrap(secondClaim)
    XCTAssertEqual(second.itemID, delivered.rawValue)
    try await store.markRemoteItemDelivered(second)
    try await store.enqueueRemoteDecision(
      .init(kind: "pin_event", eventID: "event-1", pinned: true)
    )

    // Revocation: nothing pending remains, the watermark is gone, and edits
    // made while off do not queue anything.
    try await store.revokeRemoteLink()
    let record = try await store.remoteLinkRecord()
    XCTAssertNil(record.enabledAt)
    let observed7 = try await library.itemJob(recovered)
    XCTAssertNil(observed7)
    let observed8 = try await library.itemState(delivered)
    XCTAssertEqual(observed8, "delivered")
    try await library.addRevision(
      delivered, revision: 3, kind: "userEdit", text: "关闭期间的修改", createdAt: 1010
    )
    let observed9 = try await library.itemState(delivered)
    XCTAssertEqual(observed9, "delivered")
    let whileOff = try await store.claimNextRemoteItem(now: Date())
    XCTAssertNil(whileOff)
    let offDecision = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertNil(offDecision)
    let projection = try await store.remoteProjection()
    XCTAssertEqual(projection.unacceptedDecisions.map(\.state), [.notSent])
    XCTAssertEqual(projection.unacceptedDecisions.first?.errorCategory, "revoked")
    let sweptWhileOff = try await store.reconcileRemoteItems()
    XCTAssertEqual(sweptWhileOff, 0)

    // Re-enabling sends nothing by itself: the never-sent session stays local
    // (its eligibility was cleared), and the edit made while off is not sent
    // automatically. Neither is the recovered session's pending update.
    try await store.enableRemoteLink(at: Date(timeIntervalSince1970: 2000))
    let sweptAfter = try await store.reconcileRemoteItems()
    XCTAssertEqual(sweptAfter, 0)
    let nothingOnEnable = try await store.claimNextRemoteItem(now: Date())
    XCTAssertNil(nothingOnEnable)
    // A change after re-enabling sends the record's then-current content.
    try await library.addRevision(
      delivered, revision: 4, kind: "userEdit", text: "重新开启后的修改", createdAt: 2010
    )
    let correctionClaim = try await store.claimNextRemoteItem(now: Date())
    let correction = try XCTUnwrap(correctionClaim)
    XCTAssertEqual(correction.itemID, delivered.rawValue)
    XCTAssertGreaterThan(correction.revision, second.revision)
    XCTAssertEqual(try payloadObject(correction)["text"] as? String, "重新开启后的修改")
    let nothing = try await store.claimNextRemoteItem(now: Date())
    XCTAssertNil(nothing)
    // A cancelled decision is not sent unless the user retries it; a retry is
    // re-issued as a new decision.
    let cancelled = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertNil(cancelled)
    let issueID = try XCTUnwrap(projection.unacceptedDecisions.first?.decisionID)
    try await store.retryRemoteDecision(id: issueID)
    let retried = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertNotNil(retried)
    XCTAssertNotEqual(retried?.decision.decisionID, issueID)
    XCTAssertEqual(retried?.decision.kind, "pin_event")
    XCTAssertEqual(retried?.kind, .decision)
    try await library.close()
  }

  func testDecisionsDeliverInCommitOrderAndRejectedOnesStayVisible() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: linkEnabledAt)
    let state = try JSONDecoder().decode(
      RemoteOrganizerState.self,
      from: Data(
        """
        {
          "cursor": 7,
          "events": [{
            "event_id": "event-1", "title": "模型标题", "title_user_edited": false,
            "status_line": "进度", "status_facts": [], "importance": 0.5,
            "started_at": "2026-09-26T00:00:00Z", "updated_at": "2026-09-26T00:00:00Z",
            "item_ids": [], "person_ids": [], "pinned": false,
            "deleted": false, "provenance": {}
          }],
          "questions": [{
            "question_id": "question-1", "kind": "same_event", "a": "item-1",
            "b": "event-1", "prompt_zh": "是同一件事吗？",
            "created_at": "2026-09-26T00:00:00Z"
          }],
          "persons": []
        }
        """.utf8))
    let reset = try await store.applyRemoteState(state)
    XCTAssertFalse(reset)
    let pin = RemoteOrganizerDecision(kind: "pin_event", eventID: "event-1", pinned: true)
    let unpin = RemoteOrganizerDecision(kind: "pin_event", eventID: "event-1", pinned: false)
    let rename = RemoteOrganizerDecision(
      kind: "rename_event", eventID: "event-1", title: "我的标题"
    )
    let answer = RemoteOrganizerDecision(
      kind: "same_event", questionID: "question-1", a: "item-1", b: "event-1", answer: true
    )
    for decision in [pin, unpin, rename, answer] {
      try await store.enqueueRemoteDecision(decision)
    }
    // Over-long titles are refused before they are stored.
    do {
      try await store.enqueueRemoteDecision(
        .init(
          kind: "rename_event", eventID: "event-1",
          title: String(repeating: "长", count: RemoteOrganizerDecision.maximumTitleScalars + 1)
        )
      )
      XCTFail("an 81-character title must be refused locally")
    } catch {}

    let firstClaim = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertEqual(firstClaim?.decision, pin)
    // While the first is in flight, nothing later may overtake it.
    let blockedInFlight = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertNil(blockedInFlight)
    try await store.markRemoteDecisionFailed(
      id: pin.decisionID, category: "server", reason: nil,
      retryAt: Date().addingTimeInterval(60)
    )
    let blockedBackoff = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertNil(blockedBackoff)
    // An orphaned lease (crash) is reclaimed in order after resetting leases.
    let afterBackoff = try await store.claimNextRemoteDecision(now: Date().addingTimeInterval(61))
    XCTAssertEqual(afterBackoff?.decision, pin)
    try await store.resetRemoteLeases()
    let reclaimed = try await store.claimNextRemoteDecision(now: Date().addingTimeInterval(61))
    XCTAssertEqual(reclaimed?.decision, pin)
    try await store.markRemoteDecisionDelivered(id: pin.decisionID)
    let secondClaim = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertEqual(secondClaim?.decision, unpin)
    try await store.markRemoteDecisionDelivered(id: unpin.decisionID)

    // A permanent rejection is kept, stays applied locally, and is listed.
    let thirdClaim = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertEqual(thirdClaim?.decision, rename)
    try await store.markRemoteDecisionFailed(
      id: rename.decisionID, category: "rejected", reason: "unknown or deleted event",
      retryAt: nil
    )
    let fourthClaim = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertEqual(fourthClaim?.kind, .question)
    XCTAssertEqual(fourthClaim?.decision, answer)
    try await store.markRemoteDecisionDelivered(id: answer.decisionID)

    let projection = try await store.remoteProjection()
    XCTAssertEqual(projection.cursor, 7)
    XCTAssertEqual(projection.events.first?.title, "我的标题")
    XCTAssertEqual(projection.events.first?.pinned, false)
    XCTAssertEqual(projection.events.first?.itemIDs, ["item-1"])
    XCTAssertTrue(projection.questions.isEmpty)
    XCTAssertEqual(projection.unacceptedDecisions.count, 1)
    let issue = try XCTUnwrap(projection.unacceptedDecisions.first)
    XCTAssertEqual(issue.decisionID, rename.decisionID)
    XCTAssertEqual(issue.state, .rejected)
    XCTAssertEqual(issue.kind, "rename_event")
    XCTAssertEqual(issue.reason, "unknown or deleted event")

    // Discarding is the explicit way to drop it; the model title returns.
    try await store.discardRemoteDecision(id: rename.decisionID)
    let afterDiscard = try await store.remoteProjection()
    XCTAssertEqual(afterDiscard.events.first?.title, "模型标题")
    XCTAssertTrue(afterDiscard.unacceptedDecisions.isEmpty)
    // A delivered decision cannot be discarded.
    try await store.discardRemoteDecision(id: pin.decisionID)
    let stillPinned = try await store.remoteProjection()
    XCTAssertEqual(stillPinned.events.first?.pinned, false)

    // Portable import restores the decisions as visible, never-sent ones and
    // turns the link off; nothing is queued until the user retries one.
    let archiveState = try await store.exportPortablePersistenceState()
    let imported = try GRDBDictationStore(
      databaseURL: library.root.appendingPathComponent("imported.sqlite")
    )
    try await imported.enableRemoteLink(at: linkEnabledAt)
    try await imported.importPortablePersistenceState(archiveState)
    let importedRecord = try await imported.remoteLinkRecord()
    XCTAssertNil(importedRecord.enabledAt)
    try await imported.enableRemoteLink(at: linkEnabledAt)
    let recoveredCount = try await imported.recoverRemoteDecisionsToOutbox()
    XCTAssertEqual(recoveredCount, 0, "the import already gave them jobs")
    let importedClaim = try await imported.claimNextRemoteDecision(now: Date())
    XCTAssertNil(importedClaim)
    let importedProjection = try await imported.remoteProjection()
    XCTAssertEqual(
      importedProjection.unacceptedDecisions.map(\.decisionID),
      [pin.decisionID, unpin.decisionID, answer.decisionID])
    XCTAssertTrue(
      importedProjection.unacceptedDecisions.allSatisfy {
        $0.state == .notSent && $0.errorCategory == "imported"
      })
    try await imported.checkpointAndClose()
    try await library.close()
  }

  func testUndecodableDecisionIsQuarantinedInsteadOfStoppingRecovery() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: linkEnabledAt)
    let good = RemoteOrganizerDecision(kind: "feature_less", eventID: "event-9")
    let goodPayload = try JSONEncoder().encode(good)
    try await library.write { db in
      try db.execute(
        sql: """
          INSERT INTO remote_organizer_decisions (id, payload_json, created_at)
          VALUES (?, ?, 1), (?, ?, 2)
          """,
        arguments: [
          UUID().uuidString, Data("not json".utf8),
          good.decisionID.uuidString, goodPayload,
        ]
      )
    }
    let recovered = try await store.recoverRemoteDecisionsToOutbox()
    XCTAssertEqual(recovered, 2)
    let claim = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertEqual(claim?.decision.decisionID, good.decisionID)
    let projection = try await store.remoteProjection()
    XCTAssertEqual(projection.unacceptedDecisions.map(\.errorCategory), ["corrupt"])
    try await library.close()
  }

  func testSamePersonOverlayKeepsVoicePersonCanonicalWithoutCycles() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: linkEnabledAt)
    func state(cursor: Int64, chatMergedIntoVoice: Bool) throws -> RemoteOrganizerState {
      try JSONDecoder().decode(
        RemoteOrganizerState.self,
        from: Data(
          """
          {"cursor": \(cursor), "events": [], "questions": [], "persons": [
            {"person_id": "chat-x", "display_name": "X", "aliases": [],
             "origin": "chat", "merged_into": \(chatMergedIntoVoice ? "\"voice-x\"" : "null")},
            {"person_id": "voice-x", "display_name": "X", "aliases": [],
             "origin": "voice", "merged_into": null}
          ]}
          """.utf8))
    }
    _ = try await store.applyRemoteState(try state(cursor: 3, chatMergedIntoVoice: false))
    // The service asks with a = chat person, b = voice person.
    try await store.enqueueRemoteDecision(
      .init(
        kind: "same_person", questionID: "q-person", a: "chat-x", b: "voice-x",
        answer: true
      )
    )
    let local = try await store.remoteProjection()
    XCTAssertEqual(local.persons.first { $0.personID == "chat-x" }?.mergedInto, "voice-x")
    XCTAssertNil(local.persons.first { $0.personID == "voice-x" }?.mergedInto)
    // After the Spark applies the same merge, the overlay adds nothing.
    _ = try await store.applyRemoteState(try state(cursor: 4, chatMergedIntoVoice: true))
    let pulled = try await store.remoteProjection()
    XCTAssertEqual(pulled.persons.first { $0.personID == "chat-x" }?.mergedInto, "voice-x")
    XCTAssertNil(pulled.persons.first { $0.personID == "voice-x" }?.mergedInto)
    try await library.close()
  }

  func testStoreIdentityChangeResetsMirrorAndRequeuesDeliveredItems() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    let sessionID = SyntheticRemoteLibrary.sessionID(41)
    try await store.enableRemoteLink(at: linkEnabledAt)
    let firstSighting = try await store.observeRemoteStoreID("store-a")
    XCTAssertFalse(firstSighting, "nothing mirrored yet, so nothing to reset")
    try await library.seedCompletedSession(sessionID, createdAt: 1000, text: "虚构记录")
    _ = try await store.enqueueRemoteSession(sessionID: sessionID)
    let claim = try await store.claimNextRemoteItem(now: Date())
    let delivery = try XCTUnwrap(claim)
    try await store.markRemoteItemDelivered(delivery)
    let pulled = try JSONDecoder().decode(
      RemoteOrganizerState.self,
      from: Data(
        """
        {"cursor": 40, "store_id": "store-a", "questions": [], "persons": [],
         "events": [{
          "event_id": "event-a", "title": "旧库事件", "title_user_edited": false,
          "status_line": "", "status_facts": [], "importance": 0.5,
          "started_at": null, "updated_at": null, "item_ids": [], "person_ids": [],
          "pinned": false, "deleted": false, "provenance": {}}]}
        """.utf8))
    let appliedReset = try await store.applyRemoteState(pulled)
    XCTAssertFalse(appliedReset)
    let same = try await store.observeRemoteStoreID("store-a")
    XCTAssertFalse(same)

    let changed = try await store.observeRemoteStoreID("store-b")
    XCTAssertTrue(changed)
    let cursor = try await store.remoteCursor()
    XCTAssertEqual(cursor, 0)
    let cleared = try await store.remoteProjection()
    XCTAssertTrue(cleared.events.isEmpty)
    let observed10 = try await library.itemState(sessionID)
    XCTAssertEqual(observed10, "queued")
    let resendClaim = try await store.claimNextRemoteItem(now: Date())
    let resend = try XCTUnwrap(resendClaim)
    XCTAssertEqual(resend.itemID, sessionID.rawValue)
    XCTAssertEqual(resend.revision, delivery.revision, "the new store has nothing yet")
    try await store.markRemoteItemDelivered(resend)

    // An older service without a store ID: a cursor that moves backwards is
    // also treated as a reset.
    _ = try await store.applyRemoteState(
      RemoteOrganizerState(cursor: 50, events: [], questions: [], persons: [])
    )
    let regressed = try await store.applyRemoteState(
      RemoteOrganizerState(cursor: 2, events: [], questions: [], persons: [])
    )
    XCTAssertTrue(regressed)
    let regressedCursor = try await store.remoteCursor()
    XCTAssertEqual(regressedCursor, 0)
    let observed11 = try await library.itemState(sessionID)
    XCTAssertEqual(observed11, "queued")
    try await library.close()
  }
}

/// Review follow-ups: eligibility, parked jobs, real store edit paths, name
/// limits, decision re-issue order, delivery-unknown, store reset, migration.
final class RemoteOrganizerLinkRuleTests: XCTestCase {
  private func decisionJob(_ library: SyntheticRemoteLibrary, _ id: UUID) async throws -> String? {
    try await library.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT state || '/' || error_category FROM remote_organizer_decision_jobs
          WHERE decision_id = ?
          """,
        arguments: [id.uuidString]
      )
    }
  }

  func testArchiveImportIntoAnEnabledLibraryQueuesNothing() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: linkEnabledAt)
    // Another library (for example an archive of the owner's real one) with a
    // completed session recorded long after this library's watermark.
    let source = try SyntheticRemoteLibrary()
    let imported = SyntheticRemoteLibrary.sessionID(71)
    try await source.seedCompletedSession(imported, createdAt: 9_000, text: "归档里的虚构记录")
    try await source.store.enqueueRemoteDecision(
      .init(kind: "rename_event", eventID: "event-x", title: "归档里的标题")
    )
    let archive = try await source.store.exportPortablePersistenceState()
    try await source.close()

    try await store.importPortablePersistenceState(archive)
    let record = try await store.remoteLinkRecord()
    XCTAssertNil(record.enabledAt, "an import turns the link off")
    // Even after turning it on again, nothing imported is sent automatically.
    try await store.enableRemoteLink(at: linkEnabledAt)
    let swept = try await store.reconcileRemoteItems()
    XCTAssertEqual(swept, 0)
    let direct = try await store.enqueueRemoteSession(sessionID: imported)
    XCTAssertFalse(direct)
    let item = try await store.claimNextRemoteItem(now: Date())
    XCTAssertNil(item)
    let decision = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertNil(decision)
    let projection = try await store.remoteProjection()
    XCTAssertEqual(projection.unacceptedDecisions.map(\.errorCategory), ["imported"])
    try await library.close()
  }

  func testUnsendableSessionIsParkedAndKeepsItsBurnedRevisions() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    let sessionID = SyntheticRemoteLibrary.sessionID(72)
    try await store.enableRemoteLink(at: linkEnabledAt)
    try await library.seedCompletedSession(sessionID, createdAt: 1000, text: "虚构记录")
    _ = try await store.enqueueRemoteSession(sessionID: sessionID)
    var claim = try await store.claimNextRemoteItem(now: Date())
    try await store.markRemoteItemDelivered(try XCTUnwrap(claim))
    // Speaker and name changes burn item revisions above the transcript's.
    try await library.assignPerson(sessionID, personID: "person-p", displayName: "虚构丁")
    claim = try await store.claimNextRemoteItem(now: Date())
    try await store.markRemoteItemDelivered(try XCTUnwrap(claim))
    try await library.renamePerson("person-p", to: "虚构戊")
    claim = try await store.claimNextRemoteItem(now: Date())
    let burned = try XCTUnwrap(claim)
    try await store.markRemoteItemDelivered(burned)
    XCTAssertEqual(burned.revision, 4)

    // An edit that empties the text cannot be sent: the job is parked, not
    // deleted, so its revision history survives.
    try await library.addRevision(
      sessionID, revision: 3, kind: "userEdit", text: "   ", createdAt: 1003)
    let parked = try await store.claimNextRemoteItem(now: Date())
    XCTAssertNil(parked)
    let parkedState = try await library.read { db in
      try String.fetchOne(
        db, sql: "SELECT state || '/' || error_category FROM remote_organizer_item_jobs")
    }
    XCTAssertEqual(parkedState, "failed/unsendable")
    let sweptParked = try await store.reconcileRemoteItems()
    XCTAssertEqual(sweptParked, 0, "a parked job is not rebuilt by the sweep")

    // Sendable again: the next revision is above everything already used, so
    // the Spark cannot drop it as stale.
    try await library.addRevision(
      sessionID, revision: 4, kind: "userEdit", text: "恢复的虚构记录", createdAt: 1004)
    let resumedClaim = try await store.claimNextRemoteItem(now: Date())
    let resumed = try XCTUnwrap(resumedClaim)
    XCTAssertGreaterThan(resumed.revision, burned.revision)
    XCTAssertEqual(try payloadObject(resumed)["text"] as? String, "恢复的虚构记录")
    try await library.close()
  }

  func testSilentTakeIsTrackedOnceInsteadOfRebuiltEveryPoll() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: linkEnabledAt)
    let silent = SyntheticRemoteLibrary.sessionID(73)
    try await library.seedCompletedSession(silent, createdAt: 1000, text: " ")
    let first = try await store.reconcileRemoteItems()
    XCTAssertEqual(first, 1)
    let again = try await store.reconcileRemoteItems()
    XCTAssertEqual(again, 0)
    let claim = try await store.claimNextRemoteItem(now: Date())
    XCTAssertNil(claim)
    try await library.close()
  }

  func testPayloadNamesFitTheServiceLimitsInUnicodeScalars() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: linkEnabledAt)
    let sessionID = SyntheticRemoteLibrary.sessionID(74)
    try await library.seedCompletedSession(sessionID, createdAt: 1000, text: "虚构记录")
    try await library.assignPerson(
      sessionID, personID: "person-long", displayName: String(repeating: "A", count: 200))
    let longApp = String(repeating: "👩‍💻", count: 100)  // 300 scalars, 100 characters
    let id = sessionID.rawValue.uuidString
    try await library.write { db in
      try db.execute(
        sql: """
          UPDATE session_metadata SET source_display_name = ?, source_bundle_id = ?
          WHERE session_id = ?
          """,
        arguments: [longApp, String(repeating: "b", count: 300), id]
      )
    }
    _ = try await store.enqueueRemoteSession(sessionID: sessionID)
    let claim = try await store.claimNextRemoteItem(now: Date())
    let object = try payloadObject(try XCTUnwrap(claim))
    let persons = try XCTUnwrap(object["persons"] as? [[String: Any]])
    let name = try XCTUnwrap(persons.first?["display_name"] as? String)
    XCTAssertEqual(name.unicodeScalars.count, RemoteOrganizerDecision.maximumDisplayNameScalars)
    let source = try XCTUnwrap(object["source_app"] as? [String: Any])
    let sourceName = try XCTUnwrap(source["name"] as? String)
    XCTAssertEqual(sourceName.unicodeScalars.count, 256)
    XCTAssertNil(source["bundle_id"], "an over-long bundle ID is left out, not truncated")
    try await library.close()
  }

  func testRetryIsReissuedAtTheEndSoOverlayAndSendOrderAgree() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    let state = RemoteOrganizerState(
      cursor: 3,
      events: [
        try JSONDecoder().decode(
          RemoteOrganizerEvent.self,
          from: Data(
            """
            {"event_id": "event-p", "title": "虚构事件", "title_user_edited": false,
             "status_line": "", "status_facts": [], "importance": 0.5,
             "started_at": null, "updated_at": null, "item_ids": [], "person_ids": [],
             "pinned": false, "deleted": false, "provenance": {}}
            """.utf8))
      ],
      questions: [], persons: []
    )
    _ = try await store.applyRemoteState(state)
    // Pinned while the link was off: kept, not sent.
    let pin = RemoteOrganizerDecision(kind: "pin_event", eventID: "event-p", pinned: true)
    try await store.enqueueRemoteDecision(pin)
    try await store.enableRemoteLink(at: linkEnabledAt)
    let unpin = RemoteOrganizerDecision(kind: "pin_event", eventID: "event-p", pinned: false)
    try await store.enqueueRemoteDecision(unpin)
    let unpinClaim = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertEqual(unpinClaim?.decision, unpin)
    try await store.markRemoteDecisionDelivered(id: unpin.decisionID)
    try await store.retryRemoteDecision(id: pin.decisionID)
    let retriedClaim = try await store.claimNextRemoteDecision(now: Date())
    let retried = try XCTUnwrap(retriedClaim)
    XCTAssertEqual(retried.decision.pinned, true)
    XCTAssertNotEqual(retried.decision.decisionID, pin.decisionID)
    try await store.markRemoteDecisionDelivered(id: retried.decision.decisionID)
    // Sent order: unpin, then pin. The overlay applies them in that order too.
    let projection = try await store.remoteProjection()
    XCTAssertEqual(projection.events.first?.pinned, true)
    XCTAssertTrue(projection.unacceptedDecisions.isEmpty)
    try await library.close()
  }

  func testDecisionInFlightAtRevocationIsDeliveryUnknownNotDiscardable() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: linkEnabledAt)
    let rename = RemoteOrganizerDecision(kind: "rename_event", eventID: "event-r", title: "虚构")
    let later = RemoteOrganizerDecision(kind: "feature_less", eventID: "event-r")
    try await store.enqueueRemoteDecision(rename)
    try await store.enqueueRemoteDecision(later)
    let inFlight = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertEqual(inFlight?.decision, rename)
    try await store.revokeRemoteLink()
    let renameJob = try await decisionJob(library, rename.decisionID)
    XCTAssertEqual(renameJob, "cancelled/in_flight")
    let laterJob = try await decisionJob(library, later.decisionID)
    XCTAssertEqual(laterJob, "cancelled/revoked")
    let projection = try await store.remoteProjection()
    XCTAssertEqual(projection.unacceptedDecisions.map(\.state), [.deliveryUnknown, .notSent])
    // The Spark may have applied it, so it cannot be discarded...
    try await store.discardRemoteDecision(id: rename.decisionID)
    let stillThere = try await decisionJob(library, rename.decisionID)
    XCTAssertEqual(stillThere, "cancelled/in_flight")
    // ...and 确认送达 re-issues it at the end of the commit order.
    try await store.enableRemoteLink(at: linkEnabledAt)
    try await store.retryRemoteDecision(id: rename.decisionID)
    let resent = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertEqual(resent?.decision.title, "虚构")
    XCTAssertNotEqual(resent?.decision.decisionID, rename.decisionID)
    XCTAssertEqual(resent?.kind, .decision)
    try await library.close()
  }

  /// Regression: a delivery-unknown pin confirmed after a later unpin was
  /// delivered must end the same on the Spark and in the local overlay.
  func testConfirmingAnInFlightDecisionAfterALaterOneKeepsOverlayAndSparkInAgreement()
    async throws
  {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    _ = try await store.applyRemoteState(
      try JSONDecoder().decode(
        RemoteOrganizerState.self,
        from: Data(
          """
          {"cursor": 1, "questions": [], "persons": [], "events": [{
            "event_id": "event-e", "title": "虚构事件", "title_user_edited": false,
            "status_line": "", "status_facts": [], "importance": 0.5,
            "started_at": null, "updated_at": null, "item_ids": [], "person_ids": [],
            "pinned": false, "deleted": false, "provenance": {}}]}
          """.utf8)))
    try await store.enableRemoteLink(at: linkEnabledAt)
    let pin = RemoteOrganizerDecision(kind: "pin_event", eventID: "event-e", pinned: true)
    try await store.enqueueRemoteDecision(pin)
    let inFlight = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertEqual(inFlight?.decision, pin)
    // Revoked while the pin was in flight; it never reached the Spark.
    try await store.revokeRemoteLink()
    try await store.enableRemoteLink(at: linkEnabledAt)
    let unpin = RemoteOrganizerDecision(kind: "pin_event", eventID: "event-e", pinned: false)
    try await store.enqueueRemoteDecision(unpin)
    let unpinClaim = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertEqual(unpinClaim?.decision, unpin)
    try await store.markRemoteDecisionDelivered(id: unpin.decisionID)
    var sparkPinned = false  // The Spark applied: unpin.

    // The user taps 确认送达 on the pin.
    try await store.retryRemoteDecision(id: pin.decisionID)
    let confirmedClaim = try await store.claimNextRemoteDecision(now: Date())
    let confirmed = try XCTUnwrap(confirmedClaim)
    XCTAssertEqual(confirmed.decision.pinned, true)
    sparkPinned = confirmed.decision.pinned ?? sparkPinned  // The Spark applies it last.
    try await store.markRemoteDecisionDelivered(id: confirmed.decision.decisionID)
    let projection = try await store.remoteProjection()
    XCTAssertEqual(projection.events.first?.pinned, sparkPinned)
    XCTAssertTrue(projection.unacceptedDecisions.isEmpty)
    let oldJob = try await decisionJob(library, pin.decisionID)
    XCTAssertNil(oldJob, "the delivery-unknown copy is replaced, not replayed at its old position")
    try await library.close()
  }

  func testStoreResetReseedsPeopleDecisionsAndRetiresEventDecisions() async throws {
    let library = try SyntheticRemoteLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: linkEnabledAt)
    _ = try await store.observeRemoteStoreID("store-a")
    let name = RemoteOrganizerDecision(kind: "name_person", personID: "voice-1", displayName: "虚构己")
    let same = RemoteOrganizerDecision(
      kind: "same_person", questionID: "q-old", a: "chat-1", b: "voice-1", answer: true)
    let rename = RemoteOrganizerDecision(kind: "rename_event", eventID: "event-old", title: "旧库标题")
    let pending = RemoteOrganizerDecision(kind: "pin_event", eventID: "event-old", pinned: true)
    for decision in [name, same, rename] {
      try await store.enqueueRemoteDecision(decision)
      let claim = try await store.claimNextRemoteDecision(now: Date())
      XCTAssertEqual(claim?.decision, decision)
      try await store.markRemoteDecisionDelivered(id: decision.decisionID)
    }
    try await store.enqueueRemoteDecision(pending)
    let reset = try await store.observeRemoteStoreID("store-b")
    XCTAssertTrue(reset)

    // People corrections go to the new store again, in their original order,
    // as plain decisions (the new store has no such question).
    let first = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertEqual(first?.decision, name)
    try await store.markRemoteDecisionDelivered(id: name.decisionID)
    let second = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertEqual(second?.decision, same)
    XCTAssertEqual(second?.kind, .decision)
    try await store.markRemoteDecisionDelivered(id: same.decisionID)
    let none = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertNil(none, "decisions about the old store's events are not sent to the new one")
    let pendingJob = try await decisionJob(library, pending.decisionID)
    XCTAssertEqual(pendingJob, "cancelled/store_reset")
    let renameJob = try await decisionJob(library, rename.decisionID)
    XCTAssertEqual(renameJob, "delivered/store_reset")

    // The new store's event with the same ID is not overridden by the old
    // store's corrections, and the pending one is listed once as reset.
    _ = try await store.applyRemoteState(
      try JSONDecoder().decode(
        RemoteOrganizerState.self,
        from: Data(
          """
          {"cursor": 5, "store_id": "store-b", "questions": [], "events": [{
            "event_id": "event-old", "title": "新库标题", "title_user_edited": false,
            "status_line": "", "status_facts": [], "importance": 0.5,
            "started_at": null, "updated_at": null, "item_ids": [], "person_ids": [],
            "pinned": false, "deleted": false, "provenance": {}}],
           "persons": [{"person_id": "voice-1", "display_name": "模型名", "aliases": [],
                        "origin": "voice", "merged_into": null}]}
          """.utf8)))
    let projection = try await store.remoteProjection()
    XCTAssertEqual(projection.events.first?.title, "新库标题")
    XCTAssertEqual(projection.events.first?.pinned, false)
    XCTAssertEqual(projection.persons.first?.displayName, "虚构己")
    XCTAssertEqual(projection.unacceptedDecisions.map(\.decisionID), [pending.decisionID])
    XCTAssertEqual(projection.unacceptedDecisions.first?.errorCategory, "store_reset")
    try await library.close()
  }

  func testV19OutboxMigratedWithTheLinkOffSendsNothingOnFirstEnable() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("v19.sqlite")
    let queued = persistenceUUID(81).uuidString
    let delivered = persistenceUUID(82).uuidString
    let decision = RemoteOrganizerDecision(kind: "feature_less", eventID: "event-v19")
    do {
      let old = try DatabaseQueue(path: url.path)
      try BestASRPersistenceSchema.migrator().migrate(
        old, upTo: BestASRPersistenceSchema.remoteOrganizerMigrationID)
      let payload = try JSONEncoder().encode(decision)
      try await old.write { db in
        for (id, state) in [(queued, "queued"), (delivered, "delivered")] {
          try db.execute(
            sql: """
              INSERT INTO sessions (
                id, revision, input_mode, state, source_audio_retention,
                created_at, updated_at
              ) VALUES (?, 1, 'dictation', 'completed', 'retained', 1000, 1001)
              """, arguments: [id])
          try db.execute(
            sql: """
              INSERT INTO dictation_snapshots (
                session_id, control_revision, phase, snapshot_json, is_ephemeral, updated_at
              ) VALUES (?, 1, 'completed', ?, 0, 1001)
              """, arguments: [id, Data("{}".utf8)])
          try db.execute(
            sql: """
              INSERT INTO transcript_revisions (id, session_id, revision, kind, content, created_at)
              VALUES (?, ?, 1, 'final', '虚构的旧记录', 1001)
              """, arguments: [UUID().uuidString, id])
          try db.execute(
            sql: """
              INSERT INTO remote_organizer_outbox (
                id, kind, item_id, item_revision, payload_json, payload_sha256, state,
                created_at, delivered_at
              ) VALUES (?, 'item', ?, 1, X'7B7D', ?, ?, 1002, ?)
              """,
            arguments: [
              UUID().uuidString, id, String(repeating: "a", count: 64), state,
              state == "delivered" ? 1003 : nil,
            ])
        }
        try db.execute(
          sql:
            "INSERT INTO remote_organizer_decisions (id, payload_json, created_at) VALUES (?, ?, 1004)",
          arguments: [decision.decisionID.uuidString, payload])
        try db.execute(
          sql: """
            INSERT INTO remote_organizer_outbox (
              id, kind, payload_json, payload_sha256, state, created_at
            ) VALUES (?, 'decision', ?, ?, 'queued', 1004)
            """,
          arguments: [decision.decisionID.uuidString, payload, String(repeating: "b", count: 64)])
      }
      try old.close()
    }
    // v19 kept the switch in an app preference, so the migrated library
    // starts with the link off and keeps no pending work.
    let store = try GRDBDictationStore(databaseURL: url)
    let jobs = try await store.remoteLinkRecord()
    XCTAssertNil(jobs.enabledAt)
    try await store.enableRemoteLink(at: Date())
    let item = try await store.claimNextRemoteItem(now: Date())
    XCTAssertNil(item, "an item queued under the old link is not sent")
    let swept = try await store.reconcileRemoteItems()
    XCTAssertEqual(swept, 0)
    let claimedDecision = try await store.claimNextRemoteDecision(now: Date())
    XCTAssertNil(claimedDecision)
    let projection = try await store.remoteProjection()
    XCTAssertEqual(projection.unacceptedDecisions.map(\.state), [.notSent])
    // The delivered item stays tracked: a later change sends a new revision.
    let deliveredQueued = try await store.enqueueRemoteSession(
      sessionID: SessionID(UUID(uuidString: delivered)!))
    XCTAssertTrue(deliveredQueued)
    let update = try await store.claimNextRemoteItem(now: Date())
    XCTAssertEqual(update?.itemID.uuidString, delivered)
    XCTAssertEqual(update?.revision, 2, "above the revision delivered under v19")
    try await store.checkpointAndClose()
  }
}

/// The real store edit paths (not raw SQL) must each queue a new revision that
/// carries the current text, people, names, and source.
final class RemoteOrganizerStoreEditPathTests: XCTestCase {
  func testEveryUserCorrectionPathSendsTheCurrentContent() async throws {
    let root = try persistenceTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("store.sqlite"))
    try await store.enableRemoteLink(at: linkEnabledAt)
    let sessionID = SessionID()
    let trackID = UUID()
    // Creating a session alone never grants eligibility (bulk writers such
    // as the Typeless history import create sessions the same way).
    try await store.create(preparingSnapshot(sessionID: sessionID), inputMode: .systemAudio)
    let bulk = SessionID()
    try await store.create(preparingSnapshot(sessionID: bulk), inputMode: .dictation)
    try await store.commitTranscriptRevision(try transcript(bulk, revision: 1, text: "导入的虚构旧口述"))
    try await markCompleted(root, bulk)
    let bulkQueued = try await store.enqueueRemoteSession(sessionID: bulk)
    XCTAssertFalse(bulkQueued)
    let reconciled = try await store.reconcileRemoteItems()
    XCTAssertEqual(reconciled, 0, "the running App's poll finds nothing to send")
    // The live capture path grants it explicitly while the link is on.
    try await store.markLiveCaptureRemoteEligible(sessionID: sessionID)
    let original = try transcript(sessionID, revision: 1, text: "虚构会议第一版")
    try await store.commitTranscriptRevision(original)
    try await markCompleted(root, sessionID)
    let tracked = try await store.enqueueRemoteSession(sessionID: sessionID)
    XCTAssertTrue(tracked)
    var last = try await deliver(store)
    XCTAssertEqual(last.text, "虚构会议第一版")
    XCTAssertNil(last.persons)

    // Speaker work without an identity changes nothing the Spark sees.
    let speaker = try await seedSpeaker(store, sessionID: sessionID, trackID: trackID)
    let unchanged = try await store.claimNextRemoteItem(now: Date())
    XCTAssertNil(unchanged)

    // UPDATE path: the user confirms the speaker as a new person.
    let person = try await store.confirmSessionSpeaker(
      sessionSpeakerID: speaker, personID: nil, newDisplayName: "虚构庚", originDeviceID: UUID())
    last = try await deliver(store, after: last)
    XCTAssertEqual(last.persons, [person.id.rawValue.uuidString: "虚构庚"])

    // Person rename.
    _ = try await store.renamePerson(
      personID: person.id, displayName: "虚构辛", aliases: [], originDeviceID: UUID())
    last = try await deliver(store, after: last)
    XCTAssertEqual(last.persons, [person.id.rawValue.uuidString: "虚构辛"])

    // Re-recognition.
    _ = try await store.commitRerecognizedTranscriptRevision(
      try transcript(sessionID, revision: 2, text: "重新识别的虚构会议"),
      sourceAudio: audio(sessionID, trackID), speakerModelArtifactKey: "speaker-repair-v2",
      embeddingSpaceID: "space-v1", speakerConfigHash: try persistenceDigest("f"))
    last = try await deliver(store, after: last)
    XCTAssertEqual(last.text, "重新识别的虚构会议")

    // Whole-text edit: no segments, but the people stay.
    let edited = try await store.saveUserTranscriptEdit(sessionID: sessionID, content: "整段修改的虚构会议")
    last = try await deliver(store, after: last)
    XCTAssertEqual(last.text, "整段修改的虚构会议")
    XCTAssertEqual(last.persons, [person.id.rawValue.uuidString: "虚构辛"])

    // Revision restore.
    _ = try await store.restoreTranscriptRevision(
      sessionID: sessionID, sourceTranscriptID: original.transcript.revisionID,
      expectedCurrentTranscriptID: edited.id)
    last = try await deliver(store, after: last)
    XCTAssertEqual(last.text, "虚构会议第一版")

    // Source metadata.
    try await store.setSessionSourceMetadata(
      sessionID: sessionID, sourceKind: "systemAudio", sourceIdentifier: nil,
      sourceDisplayName: "虚构会议 App", sourceBundleID: "dev.synthetic.meeting")
    last = try await deliver(store, after: last)
    XCTAssertEqual(last.sourceName, "虚构会议 App")

    // Retiring the person removes it from the item.
    try await store.retirePersonAndClearAssociations(personID: person.id, originDeviceID: UUID())
    last = try await deliver(store, after: last)
    XCTAssertNil(last.persons)
    try await store.checkpointAndClose()
  }

  private struct Sent {
    let revision: Int64
    let text: String?
    let persons: [String: String]?
    let sourceName: String?
  }

  private func deliver(_ store: GRDBDictationStore, after previous: Sent? = nil) async throws
    -> Sent
  {
    let claimed = try await store.claimNextRemoteItem(now: Date())
    let delivery = try XCTUnwrap(claimed, "a change must queue a new revision")
    try await store.markRemoteItemDelivered(delivery)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: delivery.payload) as? [String: Any])
    if let previous { XCTAssertGreaterThan(delivery.revision, previous.revision) }
    let persons = (object["persons"] as? [[String: Any]]).map {
      Dictionary(
        uniqueKeysWithValues: $0.map {
          ($0["person_id"] as? String ?? "", $0["display_name"] as? String ?? "")
        })
    }
    return Sent(
      revision: delivery.revision, text: object["text"] as? String, persons: persons,
      sourceName: (object["source_app"] as? [String: Any])?["name"] as? String)
  }

  private func markCompleted(_ root: URL, _ sessionID: SessionID) async throws {
    // The capture pipeline's final step, reduced to its two rows.
    var configuration = Configuration()
    configuration.busyMode = .timeout(10)
    let writer = try DatabaseQueue(
      path: root.appendingPathComponent("store.sqlite").path, configuration: configuration)
    try await writer.write { db in
      try db.execute(
        sql: "UPDATE sessions SET state = 'completed' WHERE id = ?",
        arguments: [sessionID.rawValue.uuidString])
      try db.execute(
        sql: "UPDATE dictation_snapshots SET phase = 'completed' WHERE session_id = ?",
        arguments: [sessionID.rawValue.uuidString])
    }
    try writer.close()
  }

  private func transcript(_ sessionID: SessionID, revision: UInt64, text: String) throws
    -> DictationTranscriptRevisionCommit
  {
    DictationTranscriptRevisionCommit(
      sessionID: sessionID,
      transcript: DictationTranscriptResult(
        revisionID: TranscriptRevisionID(), segmentIDs: [], text: text,
        modelArtifactID: "fixture-asr"),
      inputRevision: revision, configHash: try persistenceDigest(),
      createdAt: Date(timeIntervalSince1970: Double(revision))
    )
  }

  private func audio(_ sessionID: SessionID, _ trackID: UUID) -> [AudioRangeInput] {
    [
      AudioRangeInput(
        sourceID: sessionID.rawValue, trackID: trackID,
        assetReference: "sessions/fixture/journal/source.pcm",
        contentDigest: String(repeating: "a", count: 64),
        monotonicStartNanoseconds: 1_000_000_000,
        monotonicEndNanoseconds: 4_000_000_000, sampleRateHertz: 48_000, channelCount: 1)
    ]
  }

  private func seedSpeaker(
    _ store: GRDBDictationStore, sessionID: SessionID, trackID: UUID
  ) async throws -> SessionSpeakerID {
    let workerID = UUID()
    _ = try await store.scheduleSpeakerFinalWork(
      sessionID: sessionID, audio: audio(sessionID, trackID), inputRevision: 1,
      modelArtifactKey: "speaker-repair-v1", embeddingSpaceID: "space-v1",
      configHash: try persistenceDigest("e"))
    let claimedValue = try await store.claimNextSpeakerFinalJob(workerID: workerID)
    let claimed = try XCTUnwrap(claimedValue)
    let speakerID = SessionSpeakerID()
    let revision = try Revision(1)
    try await store.completeSpeakerFinalJob(
      jobID: claimed.job.id, workerID: workerID,
      commit: SpeakerFinalPersistenceCommit(
        sessionID: sessionID,
        sessionSpeakers: [
          SessionSpeaker(id: speakerID, sessionID: sessionID, revision: revision, stableOrdinal: 1)
        ],
        occurrences: [
          SpeakerOccurrence(
            id: SpeakerOccurrenceID(), sessionID: sessionID, sessionSpeakerID: speakerID,
            revision: revision, trackIDs: [TrackID(trackID)],
            monotonicStartNanoseconds: 1_000_000_000, monotonicEndNanoseconds: 4_000_000_000,
            overlapsAnotherSpeaker: false,
            association: try PersonAssociation(
              status: .unknown, personID: nil, confidence: nil, evidenceRevision: revision))
        ],
        embeddings: []
      ))
    return speakerID
  }
}
