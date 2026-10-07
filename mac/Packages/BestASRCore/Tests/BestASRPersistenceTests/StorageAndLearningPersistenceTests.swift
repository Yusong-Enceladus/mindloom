import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRPersistence
import Foundation
import GRDB
import XCTest

/// v12 storage (ALIGNMENT 收1-25, 收3-5, 收1-8): which recordings the idle
/// rewrite may touch, the storage report, and words learned from corrections.
/// Synthetic data only.
final class StorageAndLearningPersistenceTests: XCTestCase {
  final class FixedClock: DictationClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date
    init(_ start: Date) { now = start }
    func set(_ date: Date) {
      lock.lock()
      now = date
      lock.unlock()
    }
    func wallTime() -> Date {
      lock.lock()
      defer { lock.unlock() }
      return now
    }
    func monotonicNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
  }

  let base = Date(timeIntervalSince1970: 1_790_000_000)
  var directory: URL!

  override func setUpWithError() throws {
    directory = try persistenceTemporaryDirectory()
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: - Which recordings a rewrite may touch

  func testMeetingsAreCompactedOnceCompletedAndNothingWaitsToReadThem() async throws {
    let clock = FixedClock(base)
    let store = try GRDBDictationStore(
      databaseURL: directory.appendingPathComponent("history.sqlite"), clock: clock)
    let dictation = try await recording(store, mode: .dictation, rate: 48_000, state: .completed)
    let meeting = try await recording(store, mode: .systemAudio, rate: 48_000, state: .completed)
    let unfinished = try await recording(
      store, mode: .roomMicrophone, rate: 44_100, state: .failedRecoverable)
    let waiting = try await recording(store, mode: .roomMicrophone, rate: 44_100, state: .completed)
    try pendingSpeakerJob(for: waiting)

    let listed = try await store.sessionsWithUncompactedSourceAudio(limit: 100)

    XCTAssertTrue(listed.contains(dictation))
    XCTAssertTrue(listed.contains(meeting), "A completed meeting goes to 16 kHz (收1-25)")
    XCTAssertFalse(listed.contains(unfinished), "A meeting not recognised yet keeps its audio")
    XCTAssertFalse(listed.contains(waiting), "A speaker job still has to read it")
  }

  func testOnlyCompactedRecordingsOlderThanTheCutoffAreArchived() async throws {
    let clock = FixedClock(base)
    let store = try GRDBDictationStore(
      databaseURL: directory.appendingPathComponent("history.sqlite"), clock: clock)
    let old = try await recording(store, mode: .dictation, rate: 16_000, state: .completed)
    let wide = try await recording(store, mode: .systemAudio, rate: 48_000, state: .completed)
    let busy = try await recording(store, mode: .dictation, rate: 16_000, state: .completed)
    try pendingSpeakerJob(for: busy)
    clock.set(base.addingTimeInterval(40 * 86_400))
    let recent = try await recording(store, mode: .dictation, rate: 16_000, state: .completed)
    let cutoff = base.addingTimeInterval(10 * 86_400)

    let listed = try await store.sessionsReadyForArchival(recordedBefore: cutoff, limit: 100)

    XCTAssertEqual(listed, [old])
    XCTAssertFalse(listed.contains(wide), "Opus is made from the 16 kHz master only")
    XCTAssertFalse(listed.contains(recent), "Recordings younger than 30 days stay PCM")
    XCTAssertFalse(listed.contains(busy))
  }

  // MARK: - Storage report

  func testTheStorageReportCountsEachFileOnceByKindAndMonth() async throws {
    let clock = FixedClock(base)
    let root = directory.appendingPathComponent("library", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite"), clock: clock)
    let dictation = try await recording(store, mode: .dictation, rate: 16_000, state: .completed)
    clock.set(base.addingTimeInterval(-40 * 86_400))
    let meeting = try await recording(store, mode: .systemAudio, rate: 16_000, state: .completed)
    let sessions = root.appendingPathComponent("assets/sessions")
    func folder(_ id: SessionID) throws -> URL {
      let url = sessions.appendingPathComponent(id.rawValue.uuidString.lowercased())
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }
    try Data(count: 1_000).write(to: folder(dictation).appendingPathComponent("a.pcm"))
    try Data(count: 3_000).write(to: folder(meeting).appendingPathComponent("b.pcm"))
    // The same bytes held twice (a hard link, as the content index makes)
    // take the space once.
    try FileManager.default.linkItem(
      at: folder(meeting).appendingPathComponent("b.pcm"),
      to: folder(dictation).appendingPathComponent("b-again.pcm"))

    let personal = root.appendingPathComponent("personal-models/cleanup/current")
    try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
    try Data(count: 500).write(to: personal.appendingPathComponent("weights.bin"))

    let report = LibraryStorageReport.scan(
      dataRoot: root, classes: try await store.sessionStorageClasses(), monthCount: 3,
      calendar: Calendar(identifier: .gregorian), now: base)

    XCTAssertEqual(report.modelBytes, 500, "Personal models count as models (review 10-6 S15)")

    XCTAssertEqual(
      (report.bytesByKind[.dictation] ?? 0) + (report.bytesByKind[.meetings] ?? 0), 4_000)
    XCTAssertEqual(report.months.count, 3)
    XCTAssertEqual(report.months.reduce(0) { $0 + $1.bytes }, 4_000)
    XCTAssertGreaterThan(report.databaseBytes, 0)
    XCTAssertGreaterThan(report.capacityBytes, 0)
  }

  /// 收3-5: an imported recording or video is found by its bytes, so the
  /// same file taken in again (under any name) is not copied a second time.
  func testAnImportedFileIsFoundByItsBytes() async throws {
    let store = try GRDBDictationStore(
      databaseURL: directory.appendingPathComponent("history.sqlite"), clock: FixedClock(base))
    let sessionID = SessionID()
    try await store.create(preparingSnapshot(sessionID: sessionID), inputMode: .importedMedia)
    let digest = try persistenceDigest("c")
    try await store.saveRetainedSourceAsset(
      RetainedSourceAssetRecord(
        id: UUID(), sessionID: sessionID, revision: try Revision(1), kind: .importedOriginal,
        originalFilename: "lecture.mov", mediaType: "video/quicktime",
        assetReference: try PortableAssetReference(
          relativePath: "sessions/\(sessionID.rawValue.uuidString.lowercased())/source/original.mov"
        ),
        digest: digest, sizeBytes: 2_000, createdAt: base))

    let found = try await store.existingCapture(withOriginalDigest: digest.value)

    XCTAssertEqual(found, sessionID)
  }

  func testLowDiskMeansLessThanATenthFree() {
    XCTAssertTrue(LibraryStorageReport.isLow(available: 9, capacity: 100))
    XCTAssertFalse(LibraryStorageReport.isLow(available: 10, capacity: 100))
    XCTAssertFalse(LibraryStorageReport.isLow(available: 0, capacity: 0))
  }

  /// Regression (review 10-6 S11): 42 GB free of 494 GB is not short, and
  /// the notice is not shown again each day or after each launch.
  func testTheLowDiskNoticeIsShownOnceUntilSpaceFallsFurtherOrRecovers() {
    let gb: Int64 = 1_000_000_000
    XCTAssertFalse(LibraryStorageReport.isLow(available: 42 * gb, capacity: 494 * gb))
    XCTAssertTrue(LibraryStorageReport.isLow(available: 19 * gb, capacity: 494 * gb))
    XCTAssertTrue(LibraryStorageReport.isLow(available: 9 * gb, capacity: 128 * gb))

    let day: TimeInterval = 24 * 60 * 60
    var now = base
    var decision = LibraryStorageReport.lowDiskNotice(
      available: 19 * gb, capacity: 494 * gb, last: nil, now: now)
    XCTAssertTrue(decision.show)
    let remembered = decision.remember
    // Later that day, the next days, after a relaunch (the same remembered
    // notice): nothing new.
    for later in [day / 2, day * 2, day * 9] {
      decision = LibraryStorageReport.lowDiskNotice(
        available: 17 * gb, capacity: 494 * gb, last: remembered, now: now + later)
      XCTAssertFalse(decision.show)
      XCTAssertEqual(decision.remember, remembered)
    }
    // What is free has halved since: shown again.
    now += day * 3
    decision = LibraryStorageReport.lowDiskNotice(
      available: 9 * gb, capacity: 494 * gb, last: remembered, now: now)
    XCTAssertTrue(decision.show)
    // Space freed: forgotten, so the next shortage is told.
    decision = LibraryStorageReport.lowDiskNotice(
      available: 60 * gb, capacity: 494 * gb, last: decision.remember, now: now + day)
    XCTAssertFalse(decision.show)
    XCTAssertNil(decision.remember)
    decision = LibraryStorageReport.lowDiskNotice(
      available: 18 * gb, capacity: 494 * gb, last: nil, now: now + day * 2)
    XCTAssertTrue(decision.show)
  }

  // MARK: - Learning from corrections (收1-8)

  func testOneCorrectionIsAReplacementTwoAlsoReachTheRecognizer() async throws {
    let store = try GRDBDictationStore(
      databaseURL: directory.appendingPathComponent("history.sqlite"), clock: FixedClock(base))

    let firstSeen = try await store.learnCorrection(
      heard: "曼德鲁姆", written: "Mindloom", source: "field")
    let first = try XCTUnwrap(firstSeen)
    XCTAssertTrue(first.createdEntry)
    XCTAssertEqual(first.times, 1)
    XCTAssertFalse(first.usedForRecognition)
    var context = try await store.dictionaryContext()
    XCTAssertFalse(context.canonicalTerms.contains("Mindloom"), "Not told to the recognizer yet")
    let entry = try XCTUnwrap(context.entries.first { $0.canonicalForm == "Mindloom" })
    XCTAssertEqual(entry.spokenForms, ["曼德鲁姆"], "But the misheard form is replaced")
    XCTAssertTrue(context.replacementOnlyEntryIDs.contains(entry.id))

    let secondSeen = try await store.learnCorrection(
      heard: "曼德鲁姆", written: "Mindloom", source: "selection")
    let second = try XCTUnwrap(secondSeen)
    XCTAssertEqual(second.times, 2)
    XCTAssertTrue(second.usedForRecognition)
    context = try await store.dictionaryContext()
    XCTAssertTrue(context.canonicalTerms.contains("Mindloom"))
    // Regression (review 10-6 S7): told to the recognizer, but still a
    // whole-word replacement only, never searched for among similar text.
    XCTAssertEqual(
      context.asrDictionaryHints.filter { $0.canonicalForm == "Mindloom" }.map(\.explicitOnly),
      [true])
    let automatic = try await store.automaticDictionaryEntries()
    XCTAssertEqual(automatic.map(\.entryID), [entry.id])
    XCTAssertEqual(automatic.first?.lastSource, "selection")
  }

  func testAUserWordGainsTheHeardFormAndStaysTheirs() async throws {
    let store = try GRDBDictationStore(
      databaseURL: directory.appendingPathComponent("history.sqlite"), clock: FixedClock(base))
    let own = try await store.createDictionaryEntry(canonicalForm: "Qwen", spokenForms: [])

    let seen = try await store.learnCorrection(heard: "Queen", written: "qwen", source: "history")
    let outcome = try XCTUnwrap(seen)

    XCTAssertEqual(outcome.entryID, own.id)
    XCTAssertFalse(outcome.createdEntry)
    XCTAssertTrue(outcome.usedForRecognition, "The user's own word was already recognized")
    let context = try await store.dictionaryContext()
    XCTAssertEqual(context.entries.first { $0.id == own.id }?.spokenForms, ["Queen"])
    // The learned form travels as its own learned hint; the user's word
    // keeps its search (review 10-6 S7).
    XCTAssertEqual(
      context.asrDictionaryHints.filter { $0.canonicalForm == "Qwen" },
      [
        ASRDictionaryHint(canonicalForm: "Qwen", spokenForms: []),
        ASRDictionaryHint(canonicalForm: "Qwen", spokenForms: ["Queen"], explicitOnly: true),
      ])
    let decoded = try JSONDecoder().decode(
      DictionaryContextProjection.self, from: JSONEncoder().encode(context))
    XCTAssertEqual(decoded, context, "What learning taught survives a durable job's input")
    // Regression (review 10-6 S15): what learning added to the user's word
    // is listed under 自动添加 and can be removed; it is not learned again.
    let automatic = try await store.automaticDictionaryEntries()
    XCTAssertEqual(automatic.map(\.entryID), [own.id])
    XCTAssertEqual(automatic.first?.learnedForms, ["Queen"])
    try await store.forgetLearnedForms(entryID: own.id)
    let after = try await store.dictionaryContext()
    XCTAssertEqual(after.entries.first { $0.id == own.id }?.spokenForms, [])
    XCTAssertEqual(after.entries.first { $0.id == own.id }?.canonicalForm, "Qwen", "The word stays")
    let listed = try await store.automaticDictionaryEntries()
    XCTAssertTrue(listed.isEmpty)
    let again = try await store.learnCorrection(heard: "Queen", written: "qwen", source: "history")
    XCTAssertNil(again, "Removed: the same correction teaches nothing")
  }

  func testADeletedLearnedWordIsNotLearnedAgain() async throws {
    let store = try GRDBDictationStore(
      databaseURL: directory.appendingPathComponent("history.sqlite"), clock: FixedClock(base))
    let seen = try await store.learnCorrection(heard: "在座", written: "在坐", source: "field")
    let learned = try XCTUnwrap(seen)
    let entries = try await store.allDictionaryEntries()
    let entry = try XCTUnwrap(entries.first { $0.id == learned.entryID })

    _ = try await store.deleteDictionaryEntry(id: entry.id, expectedRevision: entry.revision)

    let automatic = try await store.automaticDictionaryEntries()
    XCTAssertTrue(automatic.isEmpty)
    let again = try await store.learnCorrection(heard: "在座", written: "在坐", source: "field")
    XCTAssertNil(again, "The user deleted it: the same correction teaches nothing")
    let live = try await store.allDictionaryEntries().filter { $0.tombstonedAt == nil }
    XCTAssertFalse(live.contains { $0.canonicalForm == "在坐" })
    // Another correction is still learned.
    let other = try await store.learnCorrection(heard: "曼德鲁姆", written: "Mindloom", source: "field")
    XCTAssertNotNil(other)
  }

  func testACorrectionThatChangesNothingIsRefused() async throws {
    let store = try GRDBDictationStore(
      databaseURL: directory.appendingPathComponent("history.sqlite"), clock: FixedClock(base))
    do {
      _ = try await store.learnCorrection(heard: "Fable", written: "fable", source: "field")
      XCTFail("A change of case is not a correction")
    } catch {}
  }

  // MARK: - Fixtures

  private func recording(
    _ store: GRDBDictationStore, mode: SessionInputMode, rate: UInt32, state: DictationPhase
  ) async throws -> SessionID {
    let sessionID = SessionID()
    try await store.create(preparingSnapshot(sessionID: sessionID), inputMode: mode)
    let track = CaptureTrackDescriptor(
      role: mode == .dictation ? .microphoneLocal : .systemRemote, deviceUID: "storage-fixture",
      sampleRateHertz: rate, channelCount: 1,
      encoding: rate == 16_000 ? .int16LittleEndian : .float32LittleEndian, interleaved: true)
    try await store.indexCommittedSourceAudio(
      sessionID: sessionID, tracks: [track],
      chunks: [
        CommittedSourceAudioChunk(
          trackID: track.id, sequence: 0, monotonicStartNanoseconds: 1_000,
          frameCount: UInt64(rate), sampleRateHertz: rate, contentDigest: try persistenceDigest(),
          assetReference: try PortableAssetReference(
            relativePath:
              "sessions/\(sessionID.rawValue.uuidString.lowercased())/journal/chunks/\(track.id.rawValue.uuidString)-0.pcm"
          ))
      ])
    let failure: DictationFailure? =
      state == .failedRecoverable
      ? try DictationFailure(
        stage: .recognition, category: .modelUnavailable, code: "fixture", retryable: true,
        recoveryPhase: .recognizing)
      : nil
    try await store.save(
      DictationSessionSnapshot(
        sessionID: sessionID, revision: 2, phase: state, failure: failure))
    return sessionID
  }

  private func pendingSpeakerJob(for sessionID: SessionID) throws {
    let queue = try DatabaseQueue(path: directory.appendingPathComponent("history.sqlite").path)
    try queue.write { db in
      let job = UUID().uuidString
      try db.execute(
        sql: """
          INSERT INTO durable_jobs (
            id, revision, kind, state, input_revision, model_artifact_id, config_hash,
            retry_count, error_category, lease_owner, lease_expires_at
          ) VALUES (?, 1, 'speakerFinal', 'queued', 1, 'fixture', ?, 0, 'none', NULL, NULL)
          """, arguments: [job, String(repeating: "b", count: 64)])
      try db.execute(
        sql: """
          INSERT INTO speaker_job_inputs (
            job_id, session_id, audio_ranges_json, model_artifact_key, embedding_space_id, created_at
          ) VALUES (?, ?, X'5B5D', 'fixture', 'fixture', 0)
          """, arguments: [job, sessionID.rawValue.uuidString])
    }
  }
}
