import BestASRDictation
import BestASRDomain
import BestASRMemory
import Foundation
import XCTest

@testable import BestASRPersistence

/// v12 search (ALIGNMENT 查-3, 查-6): the record meaning index — built
/// incrementally, resumable, rebuilt for another model, searched with the
/// query's conditions, and combined with the character search. A
/// deterministic stand-in model: words of one concept share a direction.
/// Synthetic text only.
final class RecordMeaningPersistenceTests: XCTestCase {
  /// Words of one concept point the same way; anything else adds a small
  /// direction of its own per character.
  final class ConceptEmbedder: MeaningEmbedding, @unchecked Sendable {
    static let concepts: [[String]] = [
      ["房东", "续租", "房租", "租约", "房子到期"],
      ["实习", "入职", "offer", "报到"],
      ["腰疼", "理疗", "医院", "拍片"],
    ]
    let modelVersion: String
    let dimension = 16
    private let lock = NSLock()
    private(set) var embeddedTexts: [String] = []
    private(set) var queryCount = 0

    init(modelVersion: String = "concept-v1") {
      self.modelVersion = modelVersion
    }

    func embed(_ texts: [String], role: MeaningTextRole) async throws -> [[Float]] {
      lock.withLock {
        if role == .document { embeddedTexts += texts } else { queryCount += 1 }
      }
      return texts.map { text in
        var vector = [Float](repeating: 0, count: dimension)
        for (index, words) in Self.concepts.enumerated() where words.contains(where: text.contains)
        {
          vector[index] += 1
        }
        for scalar in text.unicodeScalars where scalar.value > 0x4E00 {
          vector[3 + Int(scalar.value % 13)] += 0.05
        }
        return MeaningMatrix.normalized(vector)
      }
    }

    func release() async {}

    var documentCount: Int { lock.withLock { embeddedTexts.count } }
  }

  final class StepClock: DictationClock, @unchecked Sendable {
    let now: Date
    init(_ now: Date) { self.now = now }
    func wallTime() -> Date { now }
    func monotonicNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
  }

  let base = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-22
  var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("record-meaning-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func makeStore() throws -> GRDBDictationStore {
    try GRDBDictationStore(
      databaseURL: directory.appendingPathComponent("history.sqlite"), clock: StepClock(base))
  }

  @discardableResult
  private func item(
    _ store: GRDBDictationStore, _ text: String, at: Date? = nil, source: String = "微信"
  ) async throws -> SessionID {
    let id = SessionID()
    try await store.createUserItem(
      UserItemDraft(
        id: id, kind: .text, capturedAt: at ?? base,
        source: ItemSourceApplication(bundleID: nil, name: source),
        sourceOrigin: .previousFrontmost, text: text, extractor: "pasteboard-text-v1"))
    return id
  }

  private func query(_ text: String) -> SearchQuery {
    SearchQueryParser.parse(text + " ", context: SearchContext(clock: SearchClock(now: base)))
  }

  private func meaning(_ embedder: ConceptEmbedder, _ text: String, floor: Float = 0.5)
    async throws -> RecordMeaningQuery
  {
    let vector = try await embedder.embed([text], role: .query)[0]
    return RecordMeaningQuery(vector: vector, modelVersion: embedder.modelVersion, floor: floor)
  }

  private func sync(_ store: GRDBDictationStore, _ embedder: ConceptEmbedder) async throws
    -> RecordMeaningSyncResult
  {
    _ = try await store.syncRecordSearchIndex()
    return try await store.syncRecordMeaningIndex(embedder: embedder)
  }

  // MARK: - Upkeep

  func testIndexIsIncrementalAndKeepsUnchangedPieces() async throws {
    let store = try makeStore()
    let embedder = ConceptEmbedder()
    let edited = try await item(store, "房东说下个月房租要涨")
    let gone = try await item(store, "周三下午去医院拍片")
    try await item(store, "实习的 offer 要在周五前回复")
    var result = try await sync(store, embedder)
    XCTAssertEqual(result.records, 3)
    XCTAssertEqual(result.embedded, 3)
    XCTAssertFalse(result.rebuilt)

    // Nothing changed: nothing is read or embedded again.
    result = try await sync(store, embedder)
    XCTAssertEqual(result.records, 0)
    XCTAssertEqual(embedder.documentCount, 3)

    // One new, one edited, one deleted: only the new words are embedded.
    try await item(store, "续租的合同下周签")
    _ = try await store.saveUserTranscriptEdit(
      sessionID: edited, content: "房东说下个月房租要涨\n另外记得交水电费", createdAt: base)
    try await store.deleteSessionRecordsExplicitly(sessionID: gone)
    result = try await sync(store, embedder)
    XCTAssertEqual(result.records, 2)
    XCTAssertEqual(result.removed, 1)
    XCTAssertEqual(
      embedder.embeddedTexts.suffix(2).sorted(), ["房东说下个月房租要涨\n另外记得交水电费", "续租的合同下周签"].sorted())
    let status = try await store.recordMeaningStatus()
    XCTAssertEqual(status.records, 3)
    XCTAssertEqual(status.pending, 0)
    XCTAssertEqual(status.vectorBytes, status.pieces * 16 * 2)
  }

  func testLongRecordKeepsVectorsOfPiecesThatDidNotChange() async throws {
    let store = try makeStore()
    let embedder = ConceptEmbedder()
    let sentences = (0..<30).map { "第\($0)段讨论了机械臂抓取实验的安排和问题。" }
    let id = try await item(store, sentences.joined())
    let first = try await sync(store, embedder)
    XCTAssertGreaterThan(first.embedded, 1)
    // A sentence added at the end: the earlier pieces keep their vectors.
    _ = try await store.saveUserTranscriptEdit(
      sessionID: id, content: sentences.joined() + "最后补一句房东的事。", createdAt: base)
    let second = try await sync(store, embedder)
    XCTAssertEqual(second.records, 1)
    XCTAssertGreaterThan(second.reused, 0)
    XCTAssertLessThan(second.embedded, first.embedded)
  }

  func testInterruptedRunContinuesWithoutRepeatingWork() async throws {
    let store = try makeStore()
    let embedder = ConceptEmbedder()
    for index in 0..<10 { try await item(store, "第\(index)条：房东和续租的事") }
    _ = try await store.syncRecordSearchIndex()

    // A capped run leaves the rest for later.
    var result = try await store.syncRecordMeaningIndex(embedder: embedder, maximumRecords: 4)
    XCTAssertEqual(result.records, 4)
    XCTAssertEqual(result.remaining, 6)

    // A run stopped by its pause gate (dictation started) keeps what it stored.
    let calls = Counter()
    do {
      _ = try await store.syncRecordMeaningIndex(embedder: embedder, recordsPerStep: 2) {
        if calls.next() >= 2 { throw CancellationError() }
      }
      XCTFail("expected the pause gate to stop the run")
    } catch is CancellationError {}
    var status = try await store.recordMeaningStatus()
    XCTAssertEqual(status.records, 6)
    XCTAssertEqual(status.pending, 4)

    result = try await store.syncRecordMeaningIndex(embedder: embedder)
    XCTAssertEqual(result.records, 4)
    status = try await store.recordMeaningStatus()
    XCTAssertEqual(status.pending, 0)
    // Every record was embedded exactly once.
    XCTAssertEqual(embedder.documentCount, 10)
  }

  func testAnotherModelRebuildsAndOldVectorsAreNeverCompared() async throws {
    let store = try makeStore()
    let old = ConceptEmbedder(modelVersion: "concept-v1")
    try await item(store, "房东说下个月房租要涨")
    _ = try await sync(store, old)
    let new = ConceptEmbedder(modelVersion: "concept-v2")
    // Searching with a model the index was not built with finds nothing.
    let mismatch = try await store.searchRecordMeaning(
      query("房东"), meaning: try await meaning(new, "房东"))
    XCTAssertTrue(mismatch.isEmpty)
    let result = try await sync(store, new)
    XCTAssertTrue(result.rebuilt)
    XCTAssertEqual(result.embedded, 1)
    let found = try await store.searchRecordMeaning(
      query("房东"), meaning: try await meaning(new, "房东"))
    XCTAssertEqual(found.count, 1)
    let stale = try await store.searchRecordMeaning(
      query("房东"), meaning: try await meaning(old, "房东"))
    XCTAssertTrue(stale.isEmpty)
  }

  // MARK: - Search

  func testMeaningFindsRecordsWithoutTheWordsAfterRecordsWithThem() async throws {
    let store = try makeStore()
    let embedder = ConceptEmbedder()
    let worded = try await item(store, "房东说下个月房租要涨", at: base.addingTimeInterval(-3_600))
    let meant = try await item(store, "续租的合同下周签", at: base.addingTimeInterval(-7_200))
    try await item(store, "实习的 offer 要在周五前回复")
    _ = try await sync(store, embedder)

    let page = try await store.searchRecords(
      query("房东"), meaning: try await meaning(embedder, "房东"), now: base)
    XCTAssertEqual(page.hits.map(\.sessionID), [worded, meant])
    XCTAssertEqual(page.hits.map(\.meaningOnly), [false, true])
    XCTAssertEqual(page.hits[1].meaningPiece?.start, 0)
    XCTAssertEqual(page.total, 2)

    // The character search alone still finds only the worded one.
    let plain = try await store.searchRecords(query("房东"), now: base)
    XCTAssertEqual(plain.hits.map(\.sessionID), [worded])

    // Words nothing holds: found by meaning alone.
    let vague = try await store.searchRecords(
      query("房子到期"), meaning: try await meaning(embedder, "房子到期"), now: base)
    XCTAssertEqual(Set(vague.hits.prefix(2).map(\.sessionID)), [worded, meant])
  }

  func testUnrelatedQueryShowsNothingByMeaning() async throws {
    let store = try makeStore()
    let embedder = ConceptEmbedder()
    try await item(store, "房东说下个月房租要涨")
    _ = try await sync(store, embedder)
    let page = try await store.searchRecords(
      query("滑雪装备"), meaning: try await meaning(embedder, "滑雪装备"), now: base)
    XCTAssertTrue(page.hits.isEmpty)
    XCTAssertEqual(page.total, 0)
  }

  func testConditionsLimitTheMeaningSide() async throws {
    let store = try makeStore()
    let embedder = ConceptEmbedder()
    let recent = try await item(store, "续租的合同下周签", at: base.addingTimeInterval(-86_400))
    try await item(store, "续租的事去年就谈过", at: base.addingTimeInterval(-86_400 * 200))
    try await item(store, "房租的发票", at: base.addingTimeInterval(-86_400), source: "邮件")
    _ = try await sync(store, embedder)
    let context = SearchContext(sourceNames: ["微信", "邮件"], clock: SearchClock(now: base))
    let parsed = SearchQueryParser.parse("最近一周 微信 房东 ", context: context)
    XCTAssertNotNil(parsed.interval)
    XCTAssertFalse(parsed.sources.isEmpty)
    let found = try await store.searchRecordMeaning(
      parsed, meaning: try await meaning(embedder, "房东"))
    XCTAssertEqual(found.map(\.sessionID), [recent])
  }

  func testPagesContinueThroughTheCombinedList() async throws {
    let store = try makeStore()
    let embedder = ConceptEmbedder()
    var ids: Set<SessionID> = []
    var worded: Set<SessionID> = []
    for index in 0..<7 {
      worded.insert(
        try await item(store, "房东第\(index)次来电话", at: base.addingTimeInterval(Double(-index))))
    }
    ids.formUnion(worded)
    for index in 0..<5 {
      ids.insert(
        try await item(store, "续租第\(index)稿", at: base.addingTimeInterval(Double(-100 - index))))
    }
    _ = try await sync(store, embedder)
    let meaning = try await meaning(embedder, "房东")
    let first = try await store.searchRecords(query("房东"), meaning: meaning, limit: 5, now: base)
    XCTAssertEqual(first.total, 12)
    var seen = first.hits.map(\.sessionID)
    var cursor = first.next
    while let next = cursor {
      let page = try await store.searchRecords(
        query("房东"), meaning: meaning, cursor: next, limit: 5, now: base)
      seen += page.hits.map(\.sessionID)
      cursor = page.next
    }
    XCTAssertEqual(seen.count, 12)
    XCTAssertEqual(Set(seen), ids)
    // The seven holding the word come first.
    XCTAssertEqual(Set(seen.prefix(7)), worded)
  }

  func testDeletedRecordsAreNotEmbedded() async throws {
    let store = try makeStore()
    let embedder = ConceptEmbedder()
    try await item(store, "房东说下个月房租要涨")
    let gone = try await item(store, "续租的合同下周签")
    try await store.deleteSessionRecordsExplicitly(sessionID: gone)
    _ = try await sync(store, embedder)
    XCTAssertEqual(embedder.embeddedTexts, ["房东说下个月房租要涨"])
  }

  /// A record deleted after its vectors were stored, before the meaning
  /// index caught up: not shown, not counted, no empty slot in the page.
  func testRecordDeletedSinceTheLastUpkeepIsNeitherShownNorCounted() async throws {
    let store = try makeStore()
    let embedder = ConceptEmbedder()
    let worded = try await item(store, "房东说下个月房租要涨", at: base.addingTimeInterval(-60))
    let gone = try await item(store, "续租的合同下周签", at: base.addingTimeInterval(-120))
    let kept = try await item(store, "租约到期前要搬家", at: base.addingTimeInterval(-180))
    _ = try await sync(store, embedder)
    try await store.deleteSessionRecordsExplicitly(sessionID: gone)
    // Only the character index has caught up.
    _ = try await store.syncRecordSearchIndex()
    let meaning = try await meaning(embedder, "房东")
    let page = try await store.searchRecords(query("房东"), meaning: meaning, limit: 2, now: base)
    XCTAssertEqual(page.hits.map(\.sessionID), [worded, kept])
    XCTAssertEqual(page.total, 2)
    XCTAssertNil(page.next)
  }

  // MARK: - Review fixes

  /// An import or a record recognized again holds the index (HIST-009): the
  /// App's runtime counts that work in its busy gauge, and the index's pause
  /// waits on it. Nothing is embedded until the work is done.
  func testRecognitionInProgressHoldsTheIndex() async throws {
    let store = try makeStore()
    let embedder = ConceptEmbedder()
    for index in 0..<5 { try await item(store, "第\(index)条：房东和续租的事") }
    _ = try await store.syncRecordSearchIndex()
    let recognizing = BusyGauge()
    recognizing.begin()  // an import's recognition started
    let released = Counter()
    let waiting = Counter()
    let run = Task {
      try await store.syncRecordMeaningIndex(embedder: embedder, recordsPerStep: 2) {
        try await MeaningPause.wait(
          poll: .milliseconds(5), isBusy: { recognizing.isBusy },
          whenBusy: {
            _ = released.next()
            _ = waiting.next()
          })
      }
    }
    // Until the run reaches its first pause, then a little longer.
    while waiting.peek == 0 { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(embedder.documentCount, 0, "nothing embedded while recognizing")
    let pending = try await store.recordMeaningStatus().pending
    XCTAssertEqual(pending, 5)
    recognizing.end()
    let result = try await run.value
    XCTAssertEqual(result.records, 5)
    XCTAssertEqual(embedder.documentCount, 5)
    XCTAssertEqual(released.next(), 2, "the model was released once, when the wait began")
  }

  /// No model (not downloaded, failing its check): a deleted record's
  /// vectors still go once the character index has followed.
  func testDeletedRecordsLoseTheirVectorsWithoutTheModel() async throws {
    let store = try makeStore()
    let embedder = ConceptEmbedder()
    try await item(store, "房东说下个月房租要涨")
    let gone = try await item(store, "续租的合同下周签")
    _ = try await sync(store, embedder)
    let key = GRDBDictationStore.meaningModelKey(embedder.modelVersion, dimension: 16)
    try await store.deleteSessionRecordsExplicitly(sessionID: gone)
    _ = try await store.syncRecordSearchIndex()
    let removed = try await store.pruneRecordMeaningIndex(keepingModel: key)
    XCTAssertEqual(removed, 1)
    let status = try await store.recordMeaningStatus()
    XCTAssertEqual(status.records, 1)
    XCTAssertEqual(status.pieces, 1)
    XCTAssertEqual(status.modelVersion, key, "the model's vectors of live records stay")
    // Nothing left to remove: nothing changes.
    let again = try await store.pruneRecordMeaningIndex(keepingModel: key)
    XCTAssertEqual(again, 0)
  }

  /// An App update installs another model: until it is downloaded, the old
  /// model's vectors (records' and agents') go whole.
  func testVectorsOfAModelThisAppNoLongerInstallsGo() async throws {
    let store = try makeStore()
    let embedder = ConceptEmbedder(modelVersion: "concept-v1")
    try await item(store, "房东说下个月房租要涨")
    _ = try await sync(store, embedder)
    let old = GRDBDictationStore.meaningModelKey("concept-v1", dimension: 16)
    try await store.saveAgentMeaningVectors(["k1": [1, 0, 0]], model: old, fromSearch: false)
    let removed = try await store.pruneRecordMeaningIndex(
      keepingModel: GRDBDictationStore.meaningModelKey("concept-v2", dimension: 16))
    XCTAssertEqual(removed, 1)
    let status = try await store.recordMeaningStatus()
    XCTAssertEqual(status.records, 0)
    XCTAssertEqual(status.pieces, 0)
    XCTAssertNil(status.modelVersion)
    let agents = try await store.agentMeaningVectors(["k1"], model: old)
    XCTAssertTrue(agents.isEmpty)
  }

  /// The vectors held in memory for searching are dropped when the model is
  /// released after idle, and never kept for another model.
  func testVectorsHeldInMemoryAreReleased() async throws {
    let store = try makeStore()
    let embedder = ConceptEmbedder()
    try await item(store, "房东说下个月房租要涨")
    _ = try await sync(store, embedder)
    let path = await store.databaseURL.path
    _ = try await store.searchRecordMeaning(query("房东"), meaning: try await meaning(embedder, "房东"))
    XCTAssertTrue(RecordMeaningCache.shared.paths.contains(path))
    store.forgetRecordMeaningMatrix()
    XCTAssertFalse(RecordMeaningCache.shared.paths.contains(path))
    _ = try await store.searchRecordMeaning(query("房东"), meaning: try await meaning(embedder, "房东"))
    XCTAssertTrue(RecordMeaningCache.shared.paths.contains(path))
    let other = ConceptEmbedder(modelVersion: "concept-v2")
    let none = try await store.searchRecordMeaning(
      query("房东"), meaning: try await meaning(other, "房东"))
    XCTAssertTrue(none.isEmpty)
    XCTAssertFalse(RecordMeaningCache.shared.paths.contains(path))
    _ = await store.closeForQuit()
  }

  /// Agents' vectors: kept per model, read back, and pruned — pieces no
  /// matter holds go at once, pieces a search made (masked words) once old.
  func testAgentVectorsAreKeptAndPruned() async throws {
    let store = try makeStore()
    let model = "concept-v1|3"
    try await store.saveAgentMeaningVectors(
      ["warm-kept": [1, 0, 0], "warm-gone": [0, 1, 0]], model: model, fromSearch: false,
      at: base)
    try await store.saveAgentMeaningVectors(
      ["search-new": [0, 0, 1]], model: model, fromSearch: true, at: base)
    try await store.saveAgentMeaningVectors(
      ["search-old": [0, 0, 1]], model: model, fromSearch: true,
      at: base.addingTimeInterval(-30 * 86_400))
    var keys = try await store.agentMeaningKeys(model: model)
    XCTAssertEqual(keys, ["warm-kept", "warm-gone", "search-new", "search-old"])
    let read = try await store.agentMeaningVectors(["warm-kept", "missing"], model: model)
    XCTAssertEqual(read.keys.sorted(), ["warm-kept"])
    XCTAssertEqual(read["warm-kept"], [1, 0, 0])
    let none = try await store.agentMeaningVectors(["warm-kept"], model: "other|3")
    XCTAssertTrue(none.isEmpty, "vectors of another model are never read")
    let pruned = try await store.pruneAgentMeaningVectors(
      keeping: ["warm-kept"], searchPiecesBefore: base.addingTimeInterval(-7 * 86_400))
    XCTAssertEqual(pruned, 2)
    keys = try await store.agentMeaningKeys(model: model)
    XCTAssertEqual(keys, ["warm-kept", "search-new"])
    // Another model's vectors replace them whole.
    try await store.saveAgentMeaningVectors(
      ["x": [1, 0, 0]], model: "concept-v2|3", fromSearch: false)
    keys = try await store.agentMeaningKeys(model: model)
    XCTAssertTrue(keys.isEmpty)
    try await store.clearAgentMeaningVectors()
    keys = try await store.agentMeaningKeys(model: "concept-v2|3")
    XCTAssertTrue(keys.isEmpty)
  }

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
      lock.withLock {
        value += 1
        return value
      }
    }
    var peek: Int { lock.withLock { value } }
  }
}
