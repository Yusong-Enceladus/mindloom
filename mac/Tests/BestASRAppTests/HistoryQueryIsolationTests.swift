import BestASRDictation
import BestASRDomain
import BestASRPersistence
import Foundation
import XCTest

@testable import bestASR

@MainActor
final class HistoryQueryIsolationTests: XCTestCase {
  func testSelectingSourceReadsOnlyItsFirstPage() async {
    let store = ControlledHistoryRepository()
    let expected = Self.items(count: 1)
    await store.setPage(source: "app.a", offset: 0, items: expected)
    let model = Self.model(store)
    model.history.sourceApplicationQuery = "app.a"

    model.applyHistoryFilters()
    model.applyHistoryFilters()
    await model.history.listTask?.value

    XCTAssertEqual(model.history.historyItems.map(\.sessionID), expected.map(\.sessionID))
    let counts = await store.counts()
    XCTAssertEqual(counts.search, 1)
    XCTAssertEqual(
      counts.overview, 0, "A filter must not request library-wide statistics or sources.")
    XCTAssertNil(model.history.maintenanceTask, "A filter must not schedule source-index repair.")
    XCTAssertFalse(model.history.listLoading)
  }

  func testOlderFirstPageCannotReplaceNewerSourceEvenIfStorageIgnoresCancellation() async {
    let store = ControlledHistoryRepository()
    let a = Self.items(count: 1)
    let b = Self.items(count: 1)
    await store.hold(source: "app.a", offset: 0)
    await store.setPage(source: "app.b", offset: 0, items: b)
    let model = Self.model(store)
    model.history.sourceApplicationQuery = "app.a"
    model.applyHistoryFilters()
    let oldTask = model.history.listTask
    await store.waitForSearch(source: "app.a", offset: 0)

    model.history.sourceApplicationQuery = "app.b"
    model.applyHistoryFilters()
    await model.history.listTask?.value
    await store.release(source: "app.a", offset: 0, items: a)
    await oldTask?.value

    XCTAssertEqual(model.history.historyItems.map(\.sessionID), b.map(\.sessionID))
    XCTAssertEqual(model.history.presentedQuery?.sourceApplication, "app.b")
    XCTAssertFalse(model.history.listLoading)
  }

  func testOldPageCannotAppendToEqualSizedNewSourceOrClearItsLoadingState() async {
    let store = ControlledHistoryRepository()
    let a = Self.items(count: DictationAppModel.historyPageSize)
    let b = Self.items(count: DictationAppModel.historyPageSize)
    let bNext = Self.items(count: 1)
    await store.setPage(source: "app.a", offset: 0, items: a)
    await store.setPage(source: "app.b", offset: 0, items: b)
    await store.hold(source: "app.a", offset: 60)
    await store.hold(source: "app.b", offset: 60)
    let model = Self.model(store)
    model.history.sourceApplicationQuery = "app.a"
    model.applyHistoryFilters()
    await model.history.listTask?.value
    model.loadMoreHistoryItems()
    let oldPage = model.history.pageTask
    await store.waitForSearch(source: "app.a", offset: 60)

    model.history.sourceApplicationQuery = "app.b"
    model.applyHistoryFilters()
    await model.history.listTask?.value
    model.loadMoreHistoryItems()
    let newPage = model.history.pageTask
    await store.waitForSearch(source: "app.b", offset: 60)
    await store.release(source: "app.a", offset: 60, items: Self.items(count: 1))
    await oldPage?.value

    XCTAssertEqual(model.history.historyItems.map(\.sessionID), b.map(\.sessionID))
    XCTAssertTrue(model.history.pageLoading, "Only the current page request may clear its spinner.")
    await store.release(source: "app.b", offset: 60, items: bNext)
    await newPage?.value
    XCTAssertEqual(model.history.historyItems.map(\.sessionID), (b + bNext).map(\.sessionID))
    XCTAssertFalse(model.history.pageLoading)
    XCTAssertTrue(model.history.pagingExhausted)
  }

  func testLibraryOverviewDoesNotDelayListAndRefreshesAfterLibraryChanges() async {
    let store = ControlledHistoryRepository()
    let first = Self.items(count: 1)
    await store.setPage(source: "", offset: 0, items: first)
    await store.setOverview(recent: first, sessionCount: 1)
    await store.holdUsage()
    let model = Self.model(store)

    await model.refreshHistoryItems()
    let overview = model.history.overviewTask
    await store.waitForUsage()
    XCTAssertEqual(model.history.historyItems.map(\.sessionID), first.map(\.sessionID))
    XCTAssertFalse(model.history.listLoading)
    XCTAssertFalse(model.usage.usageLoaded, "A slow overview must not hold the first page hostage.")

    let filtered = Self.items(count: 1)
    await store.setPage(source: "app.filtered", offset: 0, items: filtered)
    model.history.sourceApplicationQuery = "app.filtered"
    model.applyHistoryFilters()
    await model.history.listTask?.value
    XCTAssertEqual(model.history.historyItems.map(\.sessionID), filtered.map(\.sessionID))
    XCTAssertFalse(
      model.usage.usageLoaded, "Filtering must finish while the overview is still suspended.")

    await store.releaseUsage()
    await overview?.value
    let counts = await store.counts()
    XCTAssertEqual(counts.overview, 4, "The filter must not restart any overview query.")
    XCTAssertEqual(model.usage.usageStatistics.sessionCount, 1)
    XCTAssertTrue(model.usage.usageLoaded)

    let changed = Self.items(count: 2)
    model.history.sourceApplicationQuery = ""
    await store.setPage(source: "", offset: 0, items: changed)
    await store.setOverview(recent: changed, sessionCount: 2)
    await model.refreshHistoryItems()
    await model.history.overviewTask?.value

    XCTAssertEqual(model.history.historyItems.map(\.sessionID), changed.map(\.sessionID))
    XCTAssertEqual(model.history.homeRecentHistoryItems.map(\.sessionID), changed.map(\.sessionID))
    XCTAssertEqual(model.history.sourceApplications.first?.sessionCount, 2)
    XCTAssertEqual(model.usage.usageStatistics.sessionCount, 2)
    XCTAssertEqual(model.usage.usage.dictationCount, 2)
  }

  func testFirstVisibleRecoveryOrProcessingRecordBeyondFirstSixtyIsFound() async {
    for filter in ["recoverable", "processing"] {
      let store = ControlledHistoryRepository()
      let expected = Self.items(
        count: 1, status: filter == "processing" ? .processing : .failed,
        canRetry: filter == "recoverable"
      )
      await store.setPage(source: "", offset: 0, items: Self.items(count: 60))
      await store.setPage(source: "", offset: 60, items: expected)
      let model = Self.model(store)
      model.history.statusFilter = filter
      model.applyHistoryFilters()
      await model.history.listTask?.value

      XCTAssertEqual(model.history.historyItems.map(\.sessionID), expected.map(\.sessionID))
      XCTAssertEqual(model.history.nextPageOffset, 61)
      XCTAssertTrue(model.history.pagingExhausted)
      let counts = await store.counts()
      XCTAssertEqual(counts.search, 2)
      let largestRead = await store.largestRead()
      XCTAssertEqual(largestRead, 60, "Finding a later match must not require an unbounded read.")
    }
  }

  func testLaterPageSkipsNonmatchingRowsBeforePublishingMoreResults() async {
    let store = ControlledHistoryRepository()
    let first = Self.items(count: 60, status: .failed, canRetry: true)
    let last = Self.items(count: 1, status: .failed, canRetry: true)
    await store.setPage(source: "", offset: 0, items: first)
    await store.setPage(source: "", offset: 60, items: Self.items(count: 60))
    await store.setPage(source: "", offset: 120, items: last)
    let model = Self.model(store)
    model.history.statusFilter = "recoverable"
    model.applyHistoryFilters()
    await model.history.listTask?.value
    model.loadMoreHistoryItems()
    await model.history.pageTask?.value

    XCTAssertEqual(model.history.historyItems.map(\.sessionID), (first + last).map(\.sessionID))
    XCTAssertEqual(model.history.nextPageOffset, 121)
    XCTAssertTrue(model.history.pagingExhausted)
  }

  func testPageFailurePreservesCursorAndCanBeRetried() async {
    let store = ControlledHistoryRepository()
    let first = Self.items(count: 60)
    let next = Self.items(count: 1)
    await store.setPage(source: "", offset: 0, items: first)
    await store.setPage(source: "", offset: 60, items: next)
    await store.failNext(source: "", offset: 60)
    let model = Self.model(store)
    model.applyHistoryFilters()
    await model.history.listTask?.value
    model.loadMoreHistoryItems()
    await model.history.pageTask?.value

    XCTAssertNotNil(model.history.pageErrorMessage)
    XCTAssertFalse(model.history.pageLoading)
    XCTAssertEqual(model.history.nextPageOffset, 60)
    XCTAssertEqual(model.history.historyItems.count, 60)
    model.loadMoreHistoryItems()
    await model.history.pageTask?.value
    XCTAssertNil(model.history.pageErrorMessage)
    XCTAssertEqual(model.history.historyItems.map(\.sessionID), (first + next).map(\.sessionID))
  }

  func testFirstPageFailureKeepsOldResultsIdentifiableAndRetryClearsError() async {
    let store = ControlledHistoryRepository()
    let a = Self.items(count: 1)
    let b = Self.items(count: 1)
    await store.setPage(source: "app.a", offset: 0, items: a)
    await store.setPage(source: "app.b", offset: 0, items: b)
    let model = Self.model(store)
    model.history.sourceApplicationQuery = "app.a"
    model.applyHistoryFilters()
    await model.history.listTask?.value
    await store.failNext(source: "app.b", offset: 0)
    model.history.sourceApplicationQuery = "app.b"
    model.applyHistoryFilters()
    await model.history.listTask?.value

    XCTAssertNotNil(model.history.listErrorMessage)
    XCTAssertFalse(model.history.listLoading)
    XCTAssertEqual(model.history.presentedQuery?.sourceApplication, "app.a")
    XCTAssertEqual(model.history.historyItems.map(\.sessionID), a.map(\.sessionID))
    model.applyHistoryFilters()
    await model.history.listTask?.value
    XCTAssertNil(model.history.listErrorMessage)
    XCTAssertEqual(model.history.historyItems.map(\.sessionID), b.map(\.sessionID))
  }

  func testCancelledOlderFailureCannotPolluteNewResults() async {
    let store = ControlledHistoryRepository()
    let b = Self.items(count: 1)
    await store.hold(source: "app.a", offset: 0)
    await store.setPage(source: "app.b", offset: 0, items: b)
    let model = Self.model(store)
    model.history.sourceApplicationQuery = "app.a"
    model.applyHistoryFilters()
    let oldTask = model.history.listTask
    await store.waitForSearch(source: "app.a", offset: 0)
    model.history.sourceApplicationQuery = "app.b"
    model.applyHistoryFilters()
    await model.history.listTask?.value
    await store.releaseFailure(source: "app.a", offset: 0)
    await oldTask?.value

    XCTAssertNil(model.history.listErrorMessage)
    XCTAssertEqual(model.history.historyItems.map(\.sessionID), b.map(\.sessionID))
  }

  func testEnterAfterSearchFailureDoesNotOpenPreservedOldResults() async {
    let store = ControlledHistoryRepository()
    let previous = Self.items(count: 1)
    await store.setPage(source: "app.a", offset: 0, items: previous)
    let model = Self.model(store)
    model.history.sourceApplicationQuery = "app.a"
    model.applyHistoryFilters()
    await model.history.listTask?.value
    model.history.selectedHistorySessionID = nil
    model.history.detailPresented = false

    await store.failNext(source: "app.b", offset: 0)
    model.history.sourceApplicationQuery = "app.b"
    model.history.searchQuery = "new search"
    await model.openFirstHistorySearchResult().value

    XCTAssertNotNil(model.history.listErrorMessage)
    XCTAssertEqual(model.history.historyItems.map(\.sessionID), previous.map(\.sessionID))
    XCTAssertNil(model.history.selectedHistorySessionID)
    XCTAssertFalse(model.history.detailPresented)
  }

  func testSQLiteCandidateFilterRunsBeforePaginationAndRetryCannotBypassSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let candidate = try await Self.seed(store, phase: .recognizing, source: "app.a")
    for _ in 0..<60 { _ = try await Self.seed(store, phase: .completed, source: "app.a") }
    let retrying = try await Self.seed(store, phase: .completed, source: "app.b")

    let firstRaw = try await store.searchHistory(query: "", mode: nil, status: nil, limit: 1)
    XCTAssertEqual(firstRaw.first?.sessionID, retrying)
    let candidates = try await store.searchHistory(
      query: "", mode: nil, status: nil,
      candidatePhases: [.recognizing], sourceApplication: "app.a", limit: 1
    )
    XCTAssertEqual(candidates.map(\.sessionID), [candidate])
    let wrongSource = try await store.searchHistory(
      query: "", mode: nil, status: nil,
      candidatePhases: [], includingSessionID: retrying,
      sourceApplication: "app.a", limit: 1
    )
    XCTAssertTrue(wrongSource.isEmpty, "Retry inclusion widens phase only, never other filters.")
    let included = try await store.searchHistory(
      query: "", mode: nil, status: nil,
      candidatePhases: [.recognizing], includingSessionID: retrying,
      sourceApplication: "app.b", limit: 1
    )
    XCTAssertEqual(included.map(\.sessionID), [retrying])
    try await store.checkpointAndClose()
  }

  func testSQLiteCompletedUIIncludesRecoveredWithoutChangingLegacyStatusQuery() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let completed = try await Self.seed(store, phase: .completed, source: "app.a")
    let recovered = try await Self.seed(store, phase: .completed, source: "app.a")
    try await store.markRecovered(sessionID: recovered)

    let legacy = try await store.searchHistory(query: "", mode: nil, status: .completed)
    XCTAssertEqual(legacy.map(\.sessionID), [completed])
    let model = DictationAppModel(preview: true, memoryRepository: store)
    model.history.statusFilter = "completed"
    model.applyHistoryFilters()
    await model.history.listTask?.value
    XCTAssertEqual(Set(model.history.historyItems.map(\.sessionID)), [completed, recovered])
    XCTAssertNil(model.history.listErrorMessage)
    model.history.retryingHistorySessionID = recovered
    model.history.statusFilter = "processing"
    model.applyHistoryFilters()
    await model.history.listTask?.value
    XCTAssertEqual(model.history.historyItems.map(\.sessionID), [recovered])
    try await store.checkpointAndClose()
  }

  private static func seed(
    _ store: GRDBDictationStore, phase: DictationPhase, source: String
  ) async throws -> SessionID {
    let id = SessionID()
    let target = DictationTargetSnapshot(
      processIdentifier: 99, bundleIdentifier: source, isSecure: false
    )
    try await store.create(
      DictationSessionSnapshot(
        sessionID: id, revision: 1, phase: .preparing, target: target
      ))
    try await store.save(
      DictationSessionSnapshot(
        sessionID: id, revision: 2, phase: phase, target: target
      ))
    return id
  }

  private static func model(_ store: ControlledHistoryRepository) -> DictationAppModel {
    let model = DictationAppModel(preview: true)
    model.history.repository = store
    model.history.historyItems = []
    model.usage.usageLoaded = false
    return model
  }

  private static func items(
    count: Int, status: DictationHistoryStatus = .completed, canRetry: Bool = false
  ) -> [DictationHistoryItem] {
    (0..<count).map { index in
      DictationHistoryItem(
        sessionID: SessionID(), revision: 1,
        phase: status == .processing
          ? .recognizing : status == .failed ? .failedRecoverable : .completed,
        status: status,
        rawText: "Synthetic history fixture", polishedText: nil,
        failureCode: nil, canRetry: canRetry, sourceAudioRetained: true,
        createdAt: Date(timeIntervalSince1970: Double(index)),
        updatedAt: Date(timeIntervalSince1970: Double(index)), recoveredAt: nil
      )
    }
  }
}

/// A deliberately cancellation-insensitive storage double reproduces SQLite work
/// that has already started. The caller must reject its late results by identity.
private actor ControlledHistoryRepository: HistoryQueryRepository {
  struct Key: Hashable {
    let source: String
    let offset: Int
  }

  private var pages: [Key: [DictationHistoryItem]] = [:]
  private var held: Set<Key> = []
  private var pending: [Key: CheckedContinuation<[DictationHistoryItem], Error>] = [:]
  private var failures: Set<Key> = []
  private var maximumLimit = 0
  private enum TestFailure: Error { case unavailable }
  private var requested: Set<Key> = []
  private var searchWaiters: [Key: [CheckedContinuation<Void, Never>]] = [:]
  private var searchCount = 0
  private var overviewCount = 0
  private var recent: [DictationHistoryItem] = []
  private var sessionCount = 0
  private var usageHeld = false
  private var usageStarted = false
  private var usageContinuation: CheckedContinuation<Void, Never>?
  private var usageWaiters: [CheckedContinuation<Void, Never>] = []

  func setPage(source: String, offset: Int, items: [DictationHistoryItem]) {
    pages[Key(source: source, offset: offset)] = items
  }

  func hold(source: String, offset: Int) { held.insert(Key(source: source, offset: offset)) }

  func release(source: String, offset: Int, items: [DictationHistoryItem]) {
    let key = Key(source: source, offset: offset)
    held.remove(key)
    pending.removeValue(forKey: key)?.resume(returning: items)
  }

  func failNext(source: String, offset: Int) {
    failures.insert(Key(source: source, offset: offset))
  }

  func releaseFailure(source: String, offset: Int) {
    let key = Key(source: source, offset: offset)
    held.remove(key)
    pending.removeValue(forKey: key)?.resume(throwing: TestFailure.unavailable)
  }

  func largestRead() -> Int { maximumLimit }

  func waitForSearch(source: String, offset: Int) async {
    let key = Key(source: source, offset: offset)
    guard !requested.contains(key) else { return }
    await withCheckedContinuation { searchWaiters[key, default: []].append($0) }
  }

  func counts() -> (search: Int, overview: Int) { (searchCount, overviewCount) }

  func setOverview(recent: [DictationHistoryItem], sessionCount: Int) {
    self.recent = recent
    self.sessionCount = sessionCount
  }

  func holdUsage() { usageHeld = true }

  func waitForUsage() async {
    guard !usageStarted else { return }
    await withCheckedContinuation { usageWaiters.append($0) }
  }

  func releaseUsage() {
    usageHeld = false
    usageContinuation?.resume()
    usageContinuation = nil
  }

  func searchHistory(
    query: String, mode: SessionInputMode?, status: DictationHistoryStatus?,
    candidatePhases: [DictationPhase]?, includingSessionID: SessionID?,
    sourceApplication: String?, since: Date?, limit: Int, offset: Int
  ) async throws -> [DictationHistoryItem] {
    let key = Key(source: sourceApplication ?? "", offset: offset)
    searchCount += 1
    maximumLimit = max(maximumLimit, limit)
    requested.insert(key)
    searchWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
    if failures.remove(key) != nil { throw TestFailure.unavailable }
    if held.contains(key) {
      return try await withCheckedThrowingContinuation { pending[key] = $0 }
    }
    return pages[key] ?? []
  }

  func loadHistory(limit: Int) async throws -> [DictationHistoryItem] {
    overviewCount += 1
    return Array(recent.prefix(limit))
  }

  func historySourceApplications() async throws -> [DictationHistorySourceApplication] {
    overviewCount += 1
    return [
      .init(bundleIdentifier: "synthetic.app", displayName: "Synthetic", sessionCount: sessionCount)
    ]
  }

  func historyUsageStatistics() async throws -> LocalHistoryUsageStatistics {
    overviewCount += 1
    usageStarted = true
    usageWaiters.forEach { $0.resume() }
    usageWaiters.removeAll()
    if usageHeld { await withCheckedContinuation { usageContinuation = $0 } }
    return LocalHistoryUsageStatistics(sessionCount: sessionCount)
  }

  func dictationActivityRecords() async throws -> [DictationActivityRecord] {
    overviewCount += 1
    return recent.map {
      DictationActivityRecord(
        createdAt: $0.createdAt, speechNanoseconds: 1_000_000_000, text: "Synthetic text")
    }
  }
}
