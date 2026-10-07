import BestASRDictation
import BestASRDomain
import BestASRMemory
import BestASRPersistence
import Foundation
import XCTest

/// v12 find (ALIGNMENT 查-1 to 查-6): the record search index, the history
/// list and the old full-text query. Synthetic text only.
final class RecordSearchPersistenceTests: XCTestCase {
  final class StepClock: DictationClock, @unchecked Sendable {
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

  let base = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-22
  var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("record-search-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func makeStore(_ clock: StepClock) throws -> GRDBDictationStore {
    try GRDBDictationStore(
      databaseURL: directory.appendingPathComponent("history.sqlite"), clock: clock)
  }

  @discardableResult
  private func item(
    _ store: GRDBDictationStore, _ text: String, at: Date, source: String = "微信",
    kind: UserItemKind = .text
  ) async throws -> SessionID {
    let id = SessionID()
    try await store.createUserItem(
      UserItemDraft(
        id: id, kind: kind, capturedAt: at,
        source: ItemSourceApplication(bundleID: nil, name: source),
        sourceOrigin: .previousFrontmost, text: text, extractor: "pasteboard-text-v1"))
    return id
  }

  /// A dictation written the way the Typeless import writes one.
  @discardableResult
  private func typelessDictation(
    _ store: GRDBDictationStore, clock: StepClock, _ text: String, at: Date
  ) async throws -> SessionID {
    clock.set(at)
    let sessionID = SessionID()
    let revisionID = TranscriptRevisionID()
    try await store.create(
      DictationSessionSnapshot(sessionID: sessionID, revision: 1, phase: .preparing),
      inputMode: .dictation)
    try await store.save(
      transcript: TranscriptRevision(
        id: revisionID, sessionID: sessionID, revision: try Revision(1), parentID: nil,
        kind: .final, content: text, modelArtifactID: nil, configHash: nil, createdAt: at))
    try await store.save(
      DictationSessionSnapshot(
        sessionID: sessionID, revision: 2, phase: .completed,
        transcript: DictationTranscriptResult(
          revisionID: revisionID, segmentIDs: [], text: text, modelArtifactID: "typeless-import"),
        polish: DictationPolishResult(
          sourceRevisionID: revisionID, text: text, disposition: .model,
          modelArtifactID: "typeless-import"),
        insertion: DictationInsertionResult(
          idempotencyKey: try DictationIdempotencyKey("import:\(sessionID.rawValue)"),
          method: .clipboardPaste, inserted: true)))
    try await store.setSessionSourceMetadata(
      sessionID: sessionID, sourceKind: "typeless-import",
      sourceIdentifier: sessionID.rawValue.uuidString, sourceDisplayName: "Typeless",
      sourceBundleID: "now.typeless.desktop")
    return sessionID
  }

  private func query(_ text: String, people: [SearchPerson] = [], now: Date? = nil)
    -> SearchQuery
  {
    SearchQueryParser.parse(
      text, context: SearchContext(people: people, clock: SearchClock(now: now ?? base)))
  }

  // MARK: - History

  func testTypelessDictationsAppearInHistoryAndSearch() async throws {
    let clock = StepClock(base)
    let store = try makeStore(clock)
    let typeless = try await typelessDictation(
      store, clock: clock, "把 GripDiff 的消融实验结果发给导师", at: base.addingTimeInterval(-86_400 * 300))
    try await item(store, "今天的组会改到下午三点", at: base)
    _ = try await store.syncRecordSearchIndex()

    let history = try await store.searchRecords(query(""), now: base)
    XCTAssertEqual(history.total, 2)
    XCTAssertEqual(history.hits.last?.sessionID, typeless)

    for text in ["grip diff", "GripDiff", "消融实验", "Typeless 消融"] {
      let page = try await store.searchRecords(query(text), now: base)
      XCTAssertEqual(page.hits.map(\.sessionID), [typeless], text)
    }
    // 「口述」 and 「Typeless」 are sources: the imported dictation, by time.
    let spoken = try await store.searchRecords(query("口述"), now: base)
    XCTAssertEqual(spoken.hits.map(\.sessionID), [typeless])
  }

  func testHistoryPagesByTimeCursorWithoutGapsOrRepeats() async throws {
    let clock = StepClock(base)
    let store = try makeStore(clock)
    var made: [SessionID] = []
    for index in 0..<230 {
      // Two records share each second, so the cursor must break ties.
      made.append(
        try await item(store, "第 \(index) 条记录", at: base.addingTimeInterval(Double(index / 2))))
    }
    var seen: [SessionID] = []
    var cursor: RecordSearchCursor?
    var pages = 0
    repeat {
      let page = try await store.searchRecords(query(""), cursor: cursor, limit: 100, now: base)
      if pages == 0 { XCTAssertEqual(page.total, 230) }
      seen += page.hits.map(\.sessionID)
      cursor = page.next
      pages += 1
      XCTAssertTrue(
        zip(page.hits, page.hits.dropFirst()).allSatisfy { $0.createdAt >= $1.createdAt })
    } while cursor != nil && pages < 10
    XCTAssertEqual(pages, 3)
    XCTAssertEqual(seen.count, 230)
    XCTAssertEqual(Set(seen), Set(made))
  }

  // MARK: - Search

  func testRelevanceHasNoCapAndPutsAllWordsFirst() async throws {
    let clock = StepClock(base)
    let store = try makeStore(clock)
    for index in 0..<40 {
      try await item(store, "杭州的协议第 \(index) 版", at: base.addingTimeInterval(Double(index)))
    }
    let both = try await item(store, "杭州那边下周谈合作", at: base.addingTimeInterval(-86_400 * 90))
    _ = try await store.syncRecordSearchIndex()

    // The one record with both words first; then, because that is little,
    // the records with some of them (marked), all of them.
    let together = try await store.searchRecords(query("杭州 合作"), limit: 100, now: base)
    XCTAssertEqual(together.hits.first?.sessionID, both)
    XCTAssertEqual(together.hits.first?.partial, false)
    XCTAssertEqual(together.total, 41)
    XCTAssertTrue(together.hits.dropFirst().allSatisfy(\.partial))
    // Two words with nothing together: the records with either, all of them.
    let loose = try await store.searchRecords(query("杭州 投标"), limit: 30, now: base)
    XCTAssertTrue(loose.hits.allSatisfy(\.partial))
    XCTAssertEqual(loose.total, 41)
    let rest = try await store.searchRecords(
      query("杭州 投标"), cursor: loose.next, limit: 30, now: base)
    XCTAssertEqual(loose.hits.count + rest.hits.count, 41)
    XCTAssertNil(rest.next)
  }

  func testHomophoneTypoAndTraditionalFindTheRecord() async throws {
    let clock = StepClock(base)
    let store = try makeStore(clock)
    let id = try await item(store, "穹顶具身组的会议纪要", at: base)
    try await item(store, "晚饭吃什么", at: base)
    _ = try await store.syncRecordSearchIndex()
    for text in ["穹鼎", "會議紀要", "qiongding"] {
      let page = try await store.searchRecords(query(text), now: base)
      XCTAssertEqual(page.hits.first?.sessionID, id, text)
    }
  }

  func testConditionsNarrowTimeSourceAndPerson() async throws {
    let clock = StepClock(base)
    let store = try makeStore(clock)
    let day: Double = 86_400
    let wechatLastWeek = try await item(
      store, "陆老师说报价单周五前给", at: base.addingTimeInterval(-7 * day), source: "微信")
    try await item(store, "报价单我晚点看", at: base.addingTimeInterval(-7 * day), source: "邮件")
    try await item(store, "报价单的第二版", at: base.addingTimeInterval(-40 * day), source: "微信")
    try await item(store, "跟陆老师约了下周见", at: base.addingTimeInterval(-2 * day), source: "飞书")
    _ = try await store.syncRecordSearchIndex()
    let lu = SearchPerson(id: "p-lu", name: "陆思成", aliases: ["陆老师"])

    let page = try await store.searchRecords(query("上周 微信 报价单"), now: base)
    XCTAssertEqual(page.hits.map(\.sessionID), [wechatLastWeek])
    let person = try await store.searchRecords(query("陆思成", people: [lu]), now: base)
    XCTAssertEqual(person.hits.count, 2)
    XCTAssertNil(person.hits.first?.score)  // only a person: time order
    let both = try await store.searchRecords(query("陆老师 报价单", people: [lu]), now: base)
    XCTAssertEqual(both.hits.map(\.sessionID), [wechatLastWeek])
  }

  /// v12 search: older dictation stored the App's identifier as its source
  /// name; 「微信」 and 「Claude」 still find it (on a copy of a real library,
  /// queries naming such an App found nothing at all).
  func testSourceWordsFindRecordsNamedByAppIdentifier() async throws {
    let clock = StepClock(base)
    let store = try makeStore(clock)
    let wechat = try await item(
      store, "报价单周五前给", at: base.addingTimeInterval(-60), source: "com.tencent.xinWeChat")
    let claude = try await item(
      store, "报价单的表格再改一下", at: base.addingTimeInterval(-120),
      source: "com.anthropic.claudefordesktop")
    try await item(store, "报价单我晚点看", at: base.addingTimeInterval(-180), source: "邮件")
    _ = try await store.syncRecordSearchIndex()
    let inWeChat = try await store.searchRecords(query("微信 报价单 "), now: base)
    XCTAssertEqual(inWeChat.hits.map(\.sessionID), [wechat])
    let inClaude = try await store.searchRecords(query("Claude 报价单 "), now: base)
    XCTAssertEqual(inClaude.hits.map(\.sessionID), [claude])
    XCTAssertTrue(
      SearchSources.words.first { $0.filter.label == "微信" }!.filter.matches(
        sourceName: "com.tencent.xinWeChat", inputMode: "dictation", itemKind: nil,
        sourceKind: nil, sourceIdentifier: nil))
  }

  func testEditedAndDeletedRecordsFollowTheIndex() async throws {
    let clock = StepClock(base)
    let store = try makeStore(clock)
    let id = try await item(store, "旧的说法", at: base)
    let gone = try await item(store, "要删除的一条", at: base)
    var sync = try await store.syncRecordSearchIndex()
    XCTAssertEqual(sync.indexed, 2)
    sync = try await store.syncRecordSearchIndex()
    XCTAssertEqual(sync.indexed, 0)

    _ = try await store.saveUserTranscriptEdit(sessionID: id, content: "新的写法", createdAt: base)
    try await store.deleteSessionRecordsExplicitly(sessionID: gone)
    sync = try await store.syncRecordSearchIndex()
    XCTAssertEqual(sync.indexed, 1)
    XCTAssertEqual(sync.removed, 1)
    let edited = try await store.searchRecords(query("新的写法"), now: base)
    XCTAssertEqual(edited.hits.map(\.sessionID), [id])
    let old = try await store.searchRecords(query("要删除"), now: base)
    XCTAssertTrue(old.hits.isEmpty)
  }

  // MARK: - The old query (B4 §1.2)

  /// Regression: `searchHistory` matched the full-text index once per
  /// session row (1.39 s for a common word on the demo library). It is one
  /// MATCH now, with the same results.
  func testOldSearchHistoryMatchesOnceWithTheSameResults() async throws {
    let clock = StepClock(base)
    let store = try makeStore(clock)
    var expected = Set<SessionID>()
    for index in 0..<1_500 {
      let text = index % 3 == 0 ? "TouchFold 第 \(index) 次测试" : "别的事情 \(index)"
      let id = try await item(store, text, at: base.addingTimeInterval(Double(index)))
      if index % 3 == 0 { expected.insert(id) }
    }
    let started = Date()
    let found = try await store.searchHistory(
      query: "TouchFold", mode: nil, status: nil, limit: 1_000)
    let elapsed = Date().timeIntervalSince(started)
    XCTAssertEqual(Set(found.map(\.sessionID)), expected)
    XCTAssertLessThan(elapsed, 0.5, "searchHistory took \(elapsed) s")
  }
}
