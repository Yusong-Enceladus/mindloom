import AppKit
import BestASRDomain
import BestASRPersistence
import Combine
import SwiftUI
import XCTest

@testable import bestASR

@MainActor
final class DictionaryInteractionTests: XCTestCase {
  func testSelectionToolbarPreservesHeightForFirstSelectionMultipleSelectionAndDeselection()
    throws
  {
    let entries = try [entry("bestASR"), entry("Apple"), entry("Swift", enabled: false)]
    for width: CGFloat in [440, 640, 900] {
      let selections: [Set<DictionaryEntryID>] = [
        [],
        [entries[0].id],
        [entries[0].id, entries[2].id],
        Set(entries.map(\.id)),
        [],
      ]
      let heights = selections.map { selection in
        measuredSize(
          DictionarySelectionToolbar(entries: entries, selection: .constant(selection))
            .frame(width: width)
        ).height
      }
      let original = try XCTUnwrap(heights.first)
      XCTAssertGreaterThan(original, 0)
      for height in heights {
        XCTAssertEqual(
          height, original, accuracy: 0.5,
          "Selecting a word must not move the word grid at width \(width)."
        )
      }
    }
  }

  func testToolbarActionsOnlyTargetEntriesStillVisible() throws {
    let visible = try entry("bestASR")
    let hidden = try entry("Hidden")
    let toolbar = DictionarySelectionToolbar(
      entries: [visible], selection: .constant([visible.id, hidden.id])
    )
    XCTAssertEqual(toolbar.chosen.map(\.id), [visible.id])
    XCTAssertTrue(
      DictionarySelectionToolbar(
        entries: [], selection: .constant([hidden.id])
      ).chosen.isEmpty
    )
  }

  func testSelectionDoesNotResizeWordsOrAlternateFormBadges() throws {
    for entry in [
      try entry("bestASR"),
      try entry("Apple", spokenForms: ["苹果", "艾普尔"]),
      try entry("已停用的词", enabled: false),
    ] {
      let unselected = measuredSize(
        DictionaryWordButton(entry: entry, selected: false, onSelect: {}, onEdit: {})
      )
      let selected = measuredSize(
        DictionaryWordButton(entry: entry, selected: true, onSelect: {}, onEdit: {})
      )
      XCTAssertGreaterThan(unselected.height, 0)
      XCTAssertEqual(selected.width, unselected.width, accuracy: 0.5)
      XCTAssertEqual(selected.height, unselected.height, accuracy: 0.5)
    }
  }

  private func measuredSize(_ view: some View) -> CGSize {
    let host = NSHostingView(rootView: view)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }

  private func entry(
    _ canonicalForm: String, spokenForms: [String] = [], enabled: Bool = true
  ) throws -> DictionaryEntry {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return try DictionaryEntry(
      revision: Revision(1), canonicalForm: canonicalForm,
      spokenForms: spokenForms, enabled: enabled,
      createdAt: date, updatedAt: date
    )
  }
}

@MainActor
final class DictionaryQueryInteractionTests: XCTestCase {
  func testPagingReachesEveryWordBeyondTheOldTwoHundredEntryCutoff() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("dictionary.sqlite"))
    let source = try (0..<205).map {
      try DictionaryTransferEntry(
        canonicalForm: String(format: "Term %03d", $0), spokenForms: [], enabled: true
      )
    }
    _ = try await store.importDictionaryEntries(source)
    let model = DictionaryModel()
    model.repository = store
    await model.refreshEntries()
    XCTAssertEqual(model.entries.count, 100)
    XCTAssertTrue(model.hasNextPage)
    var seen = model.entries.map(\.canonicalForm)

    model.loadNextPage()
    await model.queryTask?.value
    XCTAssertEqual(model.pageIndex, 1)
    XCTAssertEqual(model.entries.count, 100)
    seen += model.entries.map(\.canonicalForm)

    model.loadNextPage()
    await model.queryTask?.value
    XCTAssertEqual(model.pageIndex, 2)
    XCTAssertEqual(model.entries.count, 5)
    XCTAssertFalse(model.hasNextPage)
    seen += model.entries.map(\.canonicalForm)
    XCTAssertEqual(seen, source.map(\.canonicalForm))
    XCTAssertEqual(Set(seen).count, 205)

    model.searchQuery = "Term 204"
    model.search()
    await model.queryTask?.value
    XCTAssertEqual(model.pageIndex, 0)
    XCTAssertEqual(model.entries.map(\.canonicalForm), ["Term 204"])
    XCTAssertFalse(model.hasNextPage)
    try await store.checkpointAndClose()
  }

  func testOlderQueryFinishingLastCannotReplaceNewerResultsOrStatus() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("dictionary.sqlite"))
    let old = try await store.createDictionaryEntry(canonicalForm: "Old", spokenForms: [])
    let new = try await store.createDictionaryEntry(canonicalForm: "New", spokenForms: [])
    let delayed = HeldDictionaryQueryStore(base: store, heldResult: old)
    let model = DictionaryModel()
    model.repository = delayed
    model.searchQuery = "Old"
    let earlier = Task { await model.refreshEntries() }
    await delayed.waitUntilHeld()

    model.searchQuery = "New"
    await model.refreshEntries()
    XCTAssertEqual(model.entries.map(\.id), [new.id])
    let status = model.dictionaryStatusMessage
    await delayed.releaseHeldRead()
    await earlier.value

    XCTAssertEqual(model.entries.map(\.id), [new.id])
    XCTAssertEqual(model.dictionaryStatusMessage, status)
    XCTAssertFalse(model.isLoadingEntries)
    try await store.checkpointAndClose()
  }

  func testBulkEnablePublishesOnceAndDoesNotOverwriteAnExternalEdit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("dictionary.sqlite"))
    for name in ["One", "Two", "Three"] {
      _ = try await store.createDictionaryEntry(canonicalForm: name, spokenForms: [])
    }
    let model = DictionaryModel()
    model.repository = store
    await model.refreshEntries()
    let selected = model.entries
    let stale = try XCTUnwrap(selected.first)
    _ = try await store.updateDictionaryEntry(
      id: stale.id, expectedRevision: stale.revision,
      canonicalForm: "Edited elsewhere", spokenForms: []
    )
    var publications = 0
    let subscription = model.$entries.dropFirst().sink { _ in publications += 1 }
    let operation = try XCTUnwrap(model.setEntriesEnabled(selected, enabled: false))
    XCTAssertTrue(model.mutationInProgress)
    XCTAssertNil(model.setEntriesEnabled(selected, enabled: false))
    await operation.value
    withExtendedLifetime(subscription) {}

    XCTAssertEqual(
      publications, 1, "A batch must publish one final list, not N intermediate reads.")
    XCTAssertFalse(model.mutationInProgress)
    let persisted = try await store.allDictionaryEntries()
    XCTAssertEqual(persisted.filter(\.enabled).map(\.canonicalForm), ["Edited elsewhere"])
    XCTAssertEqual(persisted.filter { !$0.enabled }.count, 2)
    XCTAssertTrue(model.dictionaryStatusMessage.contains("1 个未更新"))
    try await store.checkpointAndClose()
  }
}

/// Holds the older query after it has entered the repository, without timing
/// assumptions or a sleeps-based race. Other operations use the actual SQLite store.
private actor HeldDictionaryQueryStore: DictionaryManagementRepository {
  let base: GRDBDictationStore
  let heldResult: DictionaryEntry
  private var heldRead: CheckedContinuation<[DictionaryEntry], any Error>?
  private var started: CheckedContinuation<Void, Never>?

  init(base: GRDBDictationStore, heldResult: DictionaryEntry) {
    self.base = base
    self.heldResult = heldResult
  }

  func waitUntilHeld() async {
    if heldRead != nil { return }
    await withCheckedContinuation { started = $0 }
  }

  func releaseHeldRead() {
    heldRead?.resume(returning: [heldResult])
    heldRead = nil
  }

  func searchDictionaryEntries(
    query: String, includeDisabled: Bool, limit: Int, offset: Int
  ) async throws -> [DictionaryEntry] {
    if query == "Old" {
      return try await withCheckedThrowingContinuation {
        heldRead = $0
        started?.resume()
        started = nil
      }
    }
    return try await base.searchDictionaryEntries(
      query: query, includeDisabled: includeDisabled, limit: limit, offset: offset
    )
  }

  func searchDictionaryEntries(
    query: String, includeDisabled: Bool, limit: Int
  ) async throws -> [DictionaryEntry] {
    try await searchDictionaryEntries(
      query: query, includeDisabled: includeDisabled, limit: limit, offset: 0
    )
  }

  func createDictionaryEntry(
    canonicalForm: String, spokenForms: [String]
  ) async throws -> DictionaryEntry {
    try await base.createDictionaryEntry(canonicalForm: canonicalForm, spokenForms: spokenForms)
  }

  func dictionaryEntry(id: DictionaryEntryID) async throws -> DictionaryEntry? {
    try await base.dictionaryEntry(id: id)
  }

  func updateDictionaryEntry(
    id: DictionaryEntryID, expectedRevision: Revision, canonicalForm: String, spokenForms: [String]
  ) async throws -> DictionaryEntry {
    try await base.updateDictionaryEntry(
      id: id, expectedRevision: expectedRevision,
      canonicalForm: canonicalForm, spokenForms: spokenForms
    )
  }

  func setDictionaryEntryEnabled(
    id: DictionaryEntryID, expectedRevision: Revision, enabled: Bool
  ) async throws -> DictionaryEntry {
    try await base.setDictionaryEntryEnabled(
      id: id, expectedRevision: expectedRevision, enabled: enabled
    )
  }

  func deleteDictionaryEntry(
    id: DictionaryEntryID, expectedRevision: Revision
  ) async throws -> DictionaryEntry {
    try await base.deleteDictionaryEntry(id: id, expectedRevision: expectedRevision)
  }

  func dictionaryContext(
    maximumEntries: Int, maximumUTF8Bytes: Int
  ) async throws -> DictionaryContextProjection {
    try await base.dictionaryContext(
      maximumEntries: maximumEntries, maximumUTF8Bytes: maximumUTF8Bytes
    )
  }

  func allDictionaryEntries() async throws -> [DictionaryEntry] {
    try await base.allDictionaryEntries()
  }

  func importDictionaryEntries(
    _ entries: [DictionaryTransferEntry]
  ) async throws -> [DictionaryEntry] {
    try await base.importDictionaryEntries(entries)
  }
}
