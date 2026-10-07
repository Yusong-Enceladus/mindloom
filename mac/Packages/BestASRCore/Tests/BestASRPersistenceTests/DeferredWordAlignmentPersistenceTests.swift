import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRPersistence
import Foundation
import GRDB
import XCTest

/// Dictation's sentences timed later (DICTATION_ARCHITECTURE §15.7): a
/// finished dictation's pending window segment is found, and replaced in
/// place by its timed sentences; what cited the window cites them.
final class DeferredWordAlignmentPersistenceTests: XCTestCase {
  private let model = "fixture-qwen-asr"

  func testAFinishedDictationsPendingWindowIsReplacedByItsSentences() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = try GRDBDictationStore(databaseURL: fixture.url)

    let work = try await store.deferredWordAlignmentWork(modelArtifactID: model, limit: 10)
    XCTAssertEqual(work.map(\.transcript.id), [fixture.transcriptID])
    XCTAssertEqual(work.first?.pendingSegments, [fixture.pending])

    let sentences = timedSentences
    let replaced = try await store.replaceDeferredWordAlignmentSegment(
      transcriptID: fixture.transcriptID, pending: fixture.pending, with: sentences)
    XCTAssertTrue(replaced)

    let transcript = try await store.loadTranscripts(sessionID: fixture.sessionID)
      .first { $0.id == fixture.transcriptID }
    XCTAssertEqual(transcript?.segments, sentences + [fixture.later])
    XCTAssertEqual(transcript?.content, fixture.content, "the text itself never changes")
    let remaining = try await store.deferredWordAlignmentWork(modelArtifactID: model, limit: 10)
    XCTAssertEqual(remaining, [])
    // Done once: the same replacement again changes nothing.
    let again = try await store.replaceDeferredWordAlignmentSegment(
      transcriptID: fixture.transcriptID, pending: fixture.pending, with: sentences)
    XCTAssertFalse(again)

    // The event document that cited the window cites its sentences.
    try await store.checkpointAndClose()
    let queue = try DatabaseQueue(path: fixture.url.path)
    let stored: [String] = try await queue.read { db in
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT source_references_json, result_json FROM event_text_documents")
      else { return [] }
      return ["source_references_json", "result_json"].map {
        String(decoding: row[$0] as Data, as: UTF8.self)
      }
    }
    try queue.close()
    XCTAssertEqual(stored.count, 2)
    let references = stored.first ?? ""
    let result = stored.last ?? ""
    for text in [references, result] {
      XCTAssertFalse(text.contains(fixture.pending.id.uuidString))
      XCTAssertTrue(text.contains(sentences[0].id.uuidString))
      XCTAssertTrue(text.contains(sentences[1].id.uuidString))
      XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(text.utf8)))
    }
    XCTAssertTrue(references.contains(fixture.later.id.uuidString))
  }

  func testSentencesThatDoNotHoldTheWindowsTextAreRefused() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = try GRDBDictationStore(databaseURL: fixture.url)
    let missingWords = [sentence(1, 1_000_000_000, 9_000_000_000, "今天开会。")]
    let outsideTheWindow = [
      sentence(1, 1_000_000_000, 4_000_000_000, "今天开会。"),
      sentence(2, 4_300_000_000, 9_500_000_000, "Then ship it."),
    ]
    // The window's time span must stay: a shared space's times count from
    // it (review 2026-10-07).
    let shorterThanTheWindow = [
      sentence(1, 1_200_000_000, 4_000_000_000, "今天开会。"),
      sentence(2, 4_300_000_000, 8_600_000_000, "Then ship it."),
    ]
    for sentences in [missingWords, outsideTheWindow, shorterThanTheWindow] {
      do {
        try await store.replaceDeferredWordAlignmentSegment(
          transcriptID: fixture.transcriptID, pending: fixture.pending, with: sentences)
        XCTFail("Sentences must hold exactly the window's text and span its time")
      } catch BestASRPersistenceError.invalidSnapshot {}
    }
    let transcript = try await store.loadTranscripts(sessionID: fixture.sessionID)
      .first { $0.id == fixture.transcriptID }
    XCTAssertEqual(transcript?.segments, [fixture.pending, fixture.later])
    try await store.checkpointAndClose()
  }

  /// A dictation still being processed (or failed and open to a retry) is
  /// left alone: its processing commit may be replayed.
  func testADictationThatHasNotFinishedIsLeftAlone() async throws {
    let fixture = try await makeFixture(phase: "recognizing")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = try GRDBDictationStore(databaseURL: fixture.url)
    let work = try await store.deferredWordAlignmentWork(modelArtifactID: model, limit: 10)
    XCTAssertEqual(work, [])
    try await store.checkpointAndClose()
  }

  /// The user's edit copies the window, ID and all, and History shows the
  /// newest revision: the copy is timed too, an unchanged one with the
  /// same sentences (review 2026-10-07). Each revision's event documents
  /// change only when that revision is timed.
  func testAUsersEditOfAPendingDictationIsTimedAndCitationsFollowTheirRevision() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = try GRDBDictationStore(databaseURL: fixture.url)
    let edit = try await store.saveUserTranscriptSegmentEdit(
      sessionID: fixture.sessionID, sourceTranscriptID: fixture.transcriptID,
      segmentID: fixture.later.id, replacement: "好的，就这样。",
      createdAt: Date(timeIntervalSince1970: 1_788_000_100))
    XCTAssertEqual(edit.segments.first, fixture.pending, "the edit copies the window as is")
    try await store.checkpointAndClose()
    let editDocument = try insertDocument(
      fixture, transcriptID: edit.id, segments: [fixture.pending.id, fixture.later.id])

    let reopened = try GRDBDictationStore(databaseURL: fixture.url)
    let work = try await reopened.deferredWordAlignmentWork(modelArtifactID: model, limit: 10)
    XCTAssertEqual(work.map(\.transcript.id), [edit.id, fixture.transcriptID], "newest first")
    XCTAssertEqual(work.map(\.pendingSegments), [[fixture.pending], [fixture.pending]])

    // The final transcript first: only the document citing it changes.
    let timedFinal = try await reopened.replaceDeferredWordAlignmentSegment(
      transcriptID: fixture.transcriptID, pending: fixture.pending, with: timedSentences)
    XCTAssertTrue(timedFinal)
    try await reopened.checkpointAndClose()
    var documents = try storedDocuments(fixture)
    let window = fixture.pending.id.uuidString
    XCTAssertFalse(documents[fixture.documentID]?.references.contains(window) ?? true)
    XCTAssertTrue(documents[editDocument]?.references.contains(window) ?? false)
    XCTAssertTrue(documents[editDocument]?.result.contains(window) ?? false)

    // Then the edit, with the same sentences.
    let again = try GRDBDictationStore(databaseURL: fixture.url)
    let pendingEdit = try await again.deferredWordAlignmentWork(modelArtifactID: model, limit: 10)
    XCTAssertEqual(pendingEdit.map(\.transcript.id), [edit.id])
    let timedEdit = try await again.replaceDeferredWordAlignmentSegment(
      transcriptID: edit.id, pending: fixture.pending, with: timedSentences)
    XCTAssertTrue(timedEdit)
    let transcripts = try await again.loadTranscripts(sessionID: fixture.sessionID)
    let editedNow = try XCTUnwrap(transcripts.first { $0.id == edit.id })
    XCTAssertEqual(editedNow.segments.map(\.text), ["今天开会。", "Then ship it.", "好的，就这样。"])
    XCTAssertEqual(editedNow.content, edit.content)
    let none = try await again.deferredWordAlignmentWork(modelArtifactID: model, limit: 10)
    XCTAssertEqual(none, [])
    try await again.checkpointAndClose()
    documents = try storedDocuments(fixture)
    for document in documents.values {
      XCTAssertFalse(document.references.contains(fixture.pending.id.uuidString))
      XCTAssertFalse(document.result.contains(fixture.pending.id.uuidString))
      XCTAssertTrue(document.references.contains(timedSentences[0].id.uuidString))
    }
  }

  /// An edit of the window's own text is found with that text: it is timed
  /// against what the user wrote, not the recognizer's words.
  func testAnEditedWindowIsTimedAgainstItsOwnText() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let store = try GRDBDictationStore(databaseURL: fixture.url)
    let edit = try await store.saveUserTranscriptSegmentEdit(
      sessionID: fixture.sessionID, sourceTranscriptID: fixture.transcriptID,
      segmentID: fixture.pending.id, replacement: "今天开会。 Then ship it today.",
      createdAt: Date(timeIntervalSince1970: 1_788_000_100))
    let work = try await store.deferredWordAlignmentWork(modelArtifactID: model, limit: 10)
    XCTAssertEqual(
      work.first { $0.transcript.id == edit.id }?.pendingSegments.map(\.text),
      ["今天开会。 Then ship it today."])
    let original = work.first { $0.transcript.id == fixture.transcriptID }?.pendingSegments.first
    // The recognizer's sentences do not hold the edited text.
    let editedPending = try XCTUnwrap(edit.segments.first)
    do {
      try await store.replaceDeferredWordAlignmentSegment(
        transcriptID: edit.id, pending: editedPending, with: timedSentences)
      XCTFail("An edited window takes sentences of its own text only")
    } catch BestASRPersistenceError.invalidSnapshot {}
    let editedSentences = [
      sentence(1, 1_000_000_000, 4_000_000_000, "今天开会。"),
      sentence(3, 4_300_000_000, 9_000_000_000, "Then ship it today."),
    ]
    let timed = try await store.replaceDeferredWordAlignmentSegment(
      transcriptID: edit.id, pending: editedPending, with: editedSentences)
    XCTAssertTrue(timed)
    XCTAssertEqual(original, fixture.pending, "the final transcript keeps its own window")
    try await store.checkpointAndClose()
  }

  /// Timing changes the rows of a revision the organizer may already have
  /// delivered: its job is marked changed, as a new revision marks it.
  func testTimingMarksTheOrganizerJobChanged() async throws {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let session = fixture.sessionID.rawValue.uuidString
    let queue = try DatabaseQueue(path: fixture.url.path)
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO remote_organizer_meta (key, value) VALUES ('link_enabled_at', '1')")
      try db.execute(
        sql: """
          INSERT INTO remote_organizer_item_jobs (
            item_id, target_revision, state, change_seq, created_at, updated_at, delivered_at
          ) VALUES (?, 1, 'delivered', 4, 0, 0, 0)
          """,
        arguments: [session])
    }
    try queue.close()
    let store = try GRDBDictationStore(databaseURL: fixture.url)
    let replaced = try await store.replaceDeferredWordAlignmentSegment(
      transcriptID: fixture.transcriptID, pending: fixture.pending, with: timedSentences)
    XCTAssertTrue(replaced)
    try await store.checkpointAndClose()
    let reader = try DatabaseQueue(path: fixture.url.path)
    let job = try await reader.read { db -> (state: String?, changeSeq: Int64?) in
      let row = try Row.fetchOne(
        db, sql: "SELECT state, change_seq FROM remote_organizer_item_jobs WHERE item_id = ?",
        arguments: [session])
      return (row?["state"], row?["change_seq"])
    }
    try reader.close()
    XCTAssertEqual(job.state, "queued")
    XCTAssertEqual(job.changeSeq, 5)
  }

  func testOnlyVersionEightIDsArePending() {
    XCTAssertTrue(
      DeferredWordAlignment.isPending(DeferredWordAlignment.pendingSegmentID(seed: "a")))
    let sentence = DeferredWordAlignment.sentenceID(
      replacing: DeferredWordAlignment.pendingSegmentID(seed: "a"), ordinal: 0,
      startNanoseconds: 1, endNanoseconds: 2, text: "好")
    XCTAssertFalse(DeferredWordAlignment.isPending(sentence))
    XCTAssertFalse(DeferredWordAlignment.isPending(UUID()))
    XCTAssertEqual(
      DeferredWordAlignment.pendingSegmentID(seed: "a"),
      DeferredWordAlignment.pendingSegmentID(seed: "a"))
  }

  private struct Fixture {
    let root: URL
    let url: URL
    let sessionID: SessionID
    let transcriptID: TranscriptRevisionID
    let pending: DictationTranscriptSegment
    let later: DictationTranscriptSegment
    let content: String
    let eventID: String
    let documentID: String
  }

  /// The fixture window's text, timed: the first sentence starts where the
  /// window starts and the last ends where it ends.
  private var timedSentences: [DictationTranscriptSegment] {
    [
      sentence(1, 1_000_000_000, 4_000_000_000, "今天开会。"),
      sentence(2, 4_300_000_000, 9_000_000_000, "Then ship it."),
    ]
  }

  /// Adds an event document citing `segments` of `transcriptID` in both
  /// columns; its ID.
  private func insertDocument(
    _ fixture: Fixture, transcriptID: TranscriptRevisionID, segments: [UUID]
  ) throws -> String {
    let id = UUID().uuidString
    let queue = try DatabaseQueue(path: fixture.url.path)
    let references =
      "[{\"segmentIDs\":[" + segments.map { "\"\($0.uuidString)\"" }.joined(separator: ",")
      + "],\"transcriptRevisionID\":\"\(transcriptID.rawValue.uuidString)\"}]"
    let result =
      "{\"claims\":[{\"sourceSegmentIDs\":[\"\(segments[0].uuidString)\"],\"text\":\"x\"}]}"
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO event_text_documents (
            id, event_id, event_revision, task_id, model_artifact_id, config_hash,
            source_references_json, result_json, state, created_at
          ) VALUES (?, ?, 1, 'summary', 'fixture-text', ?, ?, ?, 'current', 0)
          """,
        arguments: [
          id, fixture.eventID, String(repeating: "b", count: 64), Data(references.utf8),
          Data(result.utf8),
        ])
    }
    try queue.close()
    return id
  }

  /// Every event document's two columns as stored, by ID.
  private func storedDocuments(
    _ fixture: Fixture
  ) throws -> [String: (references: String, result: String)] {
    let queue = try DatabaseQueue(path: fixture.url.path)
    let rows = try queue.read { db in
      try Row.fetchAll(
        db, sql: "SELECT id, source_references_json, result_json FROM event_text_documents")
    }
    try queue.close()
    var documents: [String: (references: String, result: String)] = [:]
    for row in rows {
      let id: String = row["id"]
      documents[id] = (
        String(decoding: row["source_references_json"] as Data, as: UTF8.self),
        String(decoding: row["result_json"] as Data, as: UTF8.self)
      )
    }
    return documents
  }

  private func sentence(_ ordinal: Int, _ start: UInt64, _ end: UInt64, _ text: String)
    -> DictationTranscriptSegment
  {
    DictationTranscriptSegment(
      id: DeferredWordAlignment.sentenceID(
        replacing: DeferredWordAlignment.pendingSegmentID(seed: "window"), ordinal: ordinal,
        startNanoseconds: start, endNanoseconds: end, text: text),
      monotonicStartNanoseconds: start, monotonicEndNanoseconds: end, text: text,
      confidence: nil)
  }

  /// A dictation with one pending window and one ordinary segment after it,
  /// finished (or in `phase`), and an event document citing both.
  private func makeFixture(phase: String = "completed") async throws -> Fixture {
    let root = try persistenceTemporaryDirectory()
    let url = root.appendingPathComponent("history.sqlite")
    let store = try GRDBDictationStore(databaseURL: url)
    let sessionID = SessionID()
    try await store.create(preparingSnapshot(sessionID: sessionID), inputMode: .dictation)
    let pending = DictationTranscriptSegment(
      id: DeferredWordAlignment.pendingSegmentID(seed: "window"),
      monotonicStartNanoseconds: 1_000_000_000, monotonicEndNanoseconds: 9_000_000_000,
      text: "今天开会。 Then ship it.", confidence: nil)
    let later = DictationTranscriptSegment(
      id: UUID(), monotonicStartNanoseconds: 9_000_000_000,
      monotonicEndNanoseconds: 12_000_000_000, text: "好的。", confidence: nil)
    let content = "今天开会。 Then ship it. 好的。"
    let transcriptID = TranscriptRevisionID()
    let audio = AudioRangeInput(
      sourceID: sessionID.rawValue, trackID: UUID(),
      assetReference: "sessions/fixture/journal/source.pcm",
      contentDigest: String(repeating: "a", count: 64),
      monotonicStartNanoseconds: 1_000_000_000, monotonicEndNanoseconds: 12_000_000_000,
      sampleRateHertz: 16_000, channelCount: 1)
    try await store.commitTranscriptRevision(
      DictationTranscriptRevisionCommit(
        sessionID: sessionID,
        transcript: DictationTranscriptResult(
          revisionID: transcriptID, segmentIDs: [pending.id, later.id], text: content,
          modelArtifactID: model,
          provenance: DictationTranscriptProvenance(
            parentRevisionID: nil, kind: .final, languageHints: ["zh-CN"], audioRanges: [audio],
            segments: [pending, later])),
        inputRevision: 1, configHash: try persistenceDigest(),
        createdAt: Date(timeIntervalSince1970: 1_788_000_000)))
    try await store.checkpointAndClose()

    let queue = try DatabaseQueue(path: url.path)
    let eventID = UUID().uuidString
    let documentID = UUID().uuidString
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO events (
            id, revision, title, notes, start_at, end_at, title_is_user_edited,
            confirmation_state, created_at, updated_at
          ) VALUES (?, 1, 'Fixture', '', 0, 0, 0, 'automatic', 0, 0)
          """,
        arguments: [eventID])
      try db.execute(
        sql: "UPDATE dictation_snapshots SET phase = ? WHERE session_id = ?",
        arguments: [phase, sessionID.rawValue.uuidString])
      let references =
        "[{\"segmentIDs\":[\"\(pending.id.uuidString)\",\"\(later.id.uuidString)\"],"
        + "\"transcriptRevisionID\":\"\(transcriptID.rawValue.uuidString)\"}]"
      let result =
        "{\"claims\":[{\"sourceSegmentIDs\":[\"\(pending.id.uuidString)\"],\"text\":\"x\"}]}"
      try db.execute(
        sql: """
          INSERT INTO event_text_documents (
            id, event_id, event_revision, task_id, model_artifact_id, config_hash,
            source_references_json, result_json, state, created_at
          ) VALUES (?, ?, 1, 'summary', 'fixture-text', ?, ?, ?, 'current', 0)
          """,
        arguments: [
          documentID, eventID, String(repeating: "b", count: 64),
          Data(references.utf8), Data(result.utf8),
        ])
    }
    try queue.close()
    return Fixture(
      root: root, url: url, sessionID: sessionID, transcriptID: transcriptID, pending: pending,
      later: later, content: content, eventID: eventID, documentID: documentID)
  }
}
