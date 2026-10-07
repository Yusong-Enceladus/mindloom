import AppKit
import BestASRDomain
import BestASRMemory
import BestASRMemoryUI
import BestASRPersistence
import BestASRRemoteOrganizer
import Combine
import Foundation

/// Adapts the App's models to the Mindloom pages' value state (v11). It
/// reloads the read model when events, the organizer projection, people,
/// history or the user's own organizing change, lays held corrections over
/// it (`corrections`, the undo window), and keeps the one toast.
@MainActor
final class MemoryScreenModel: ObservableObject {
  /// Derived once per load; `state(app:…)` patches the live parts in.
  @Published private(set) var base = MemoryScreenState()
  /// The one toast (MAC-SPEC §7.6).
  @Published private(set) var toast: MemoryToast?
  /// The row lit after something was filed into it.
  @Published var highlightedEventID: String?
  /// The user's pins, groups and step marks as last read from the library.
  @Published private(set) var user = UserOrganizingSnapshot.empty
  /// The sidebar's tagline (docs/TAGLINES.md), picked by `showTagline` when
  /// the window comes on screen and kept while it is shown.
  @Published private(set) var tagline: MindloomTagline?
  /// The undo window: held corrections and the one undo slot.
  private(set) var corrections: MemoryCorrectionQueue!
  private var reload: Task<Void, Never>?
  private var observers: Set<AnyCancellable> = []
  private let thumbnails = ThumbnailCache()
  private weak var app: DictationAppModel?
  /// A change arrived while no main window was on screen: rebuild once one
  /// is (ALIGNMENT 收1-3, no refresh work while the windows are hidden).
  private var refreshWhenVisible = false

  /// Whether a main window is on screen now: shown, not minimized, not
  /// fully covered, and the App not hidden.
  static var mainWindowOnScreen: Bool {
    !NSApp.isHidden
      && NSApp.windows.contains {
        $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible
          && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
      }
  }

  /// Starts following the App's models; call once.
  func attach(to app: DictationAppModel) {
    guard observers.isEmpty else { return }
    self.app = app
    // The App's own queue: it outlives this window, so ⌘W inside the undo
    // window never drops a correction (fix-mac).
    corrections = app.memoryCorrections
    // A send finished: pins, groups and marks are read again.
    corrections.$inFlight
      .removeDuplicates()
      .scan((0, 0)) { ($0.1, $1) }
      .filter { $0.1 < $0.0 }
      .sink { [weak self] _ in Task { await self?.reloadUser() } }
      .store(in: &observers)
    let changes: [AnyPublisher<Void, Never>] = [
      app.events.$summaries.map { _ in () }.eraseToAnyPublisher(),
      app.events.$candidates.map { _ in () }.eraseToAnyPublisher(),
      app.events.$remoteProjection.map { _ in () }.eraseToAnyPublisher(),
      app.people.$personSummaries.map { _ in () }.eraseToAnyPublisher(),
      app.history.$historyItems.map { _ in () }.eraseToAnyPublisher(),
      app.history.$eventAvailableHistoryItems.map { _ in () }.eraseToAnyPublisher(),
      app.$remoteOrganizerEnabled.map { _ in () }.eraseToAnyPublisher(),
      // 通用 › 时区: 今天 and 已过期 are counted again in the new zone.
      app.$productTimeZone.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      corrections.$pending.map { _ in () }.eraseToAnyPublisher(),
      $user.map { _ in () }.eraseToAnyPublisher(),
    ]
    Publishers.MergeMany(changes)
      .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
      .sink { [weak self, weak app] in
        guard let self, let app else { return }
        guard Self.mainWindowOnScreen else {
          self.refreshWhenVisible = true
          return
        }
        self.refresh(app)
      }
      .store(in: &observers)
    // Back on screen after changes arrived unseen: one rebuild.
    let visibility: [AnyPublisher<Void, Never>] = [
      NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)
        .map { _ in () }.eraseToAnyPublisher(),
      NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)
        .map { _ in () }.eraseToAnyPublisher(),
      NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)
        .map { _ in () }.eraseToAnyPublisher(),
    ]
    Publishers.MergeMany(visibility)
      .receive(on: RunLoop.main)
      .sink { [weak self, weak app] in
        guard let self, let app, self.refreshWhenVisible, Self.mainWindowOnScreen else { return }
        self.refreshWhenVisible = false
        self.refresh(app)
      }
      .store(in: &observers)
    // Intake's confirmations (「已收好」 …) become the toast.
    app.intake.$confirmation
      .removeDuplicates()
      .sink { [weak self] message in
        guard let self, let message else { return }
        self.show(MemoryToast(message))
      }
      .store(in: &observers)
    Task { await reloadUser() }
    refresh(app)
  }

  func refresh(_ app: DictationAppModel) {
    reload?.cancel()
    let held = corrections?.held ?? []
    let user = user
    reload = Task { [weak self, weak app] in
      guard let app else { return }
      // The records are read off the main thread by the store; building the
      // projection and deriving the pages from thousands of records happens
      // off it too, so the window never waits for it.
      guard let inputs = await app.memoryProjectionInputs() else {
        guard !Task.isCancelled, let self else { return }
        base = MemoryScreenState(
          mode: app.memoryUsesRemote ? .spark : .local, projection: nil, user: user)
        return
      }
      let now = Date()
      let owners = DictationAppModel.memoryOwnerNames
      // Days are the product time zone's, not the Mac's (根-13).
      let calendar = app.productCalendar
      let model = await Task.detached(priority: .userInitiated) {
        MemoryReadModel(
          inputs.projection().applying(held), user: user, now: now, calendar: calendar,
          ownerNames: owners)
      }.value
      guard !Task.isCancelled, let self else { return }
      let root = app.intake.assetRoot
      let cache = thumbnails
      base = MemoryScreenState(
        mode: app.memoryUsesRemote ? .spark : .local, readModel: model, user: user, now: now,
        calendar: calendar, thumbnail: { path in cache.image(path, root: root) })
    }
  }

  /// Reads the user's pins, groups and step marks again.
  func reloadUser() async {
    guard let repository = app?.repository,
      let snapshot = try? await repository.userOrganizing()
    else { return }
    if snapshot != user { user = snapshot }
  }

  var projection: MemoryProjection? { base.projection }

  private var pageRefresh = MemoryPageRefresh()

  /// A page visit: what to ask the models for (a reload at most once a
  /// minute; never the whole-library local organizer, v12 理1-4).
  func claimPageRefresh(now: Date = Date()) -> MemoryPageRefresh.Work? {
    pageRefresh.visit(at: now)
  }

  func state(
    app: DictationAppModel, capture: MemoryCaptureIndicator?, now: Date = Date()
  ) -> MemoryScreenState {
    var state = base
    // `base` is rebuilt after a debounce; the user's groups and pins are
    // already the latest read (a new group's page never shows it deleted).
    state.overlayUser(user)
    state.toast = toast
    state.capture = capture
    // Demo mode says so in the sidebar as long as it lasts (根-10).
    state.demo = MindloomLaunch.isDemo
    state.tagline = tagline
    state.issues = Self.issues(app.events.remoteProjection)
    state.link = Self.link(app)
    state.highlightedEventID = highlightedEventID
    state.undo = corrections?.undoState
    state.playingItemID =
      app.playback.playbackIsPlaying
      ? app.history.selectedHistorySessionID?.rawValue.uuidString : nil
    state.playbackItemID =
      app.playback.playbackTrackIDs.isEmpty
      ? nil : app.history.selectedHistorySessionID?.rawValue.uuidString
    state.homeExtras.playingVoice =
      app.playback.playbackIsPlaying ? app.playback.voicePersonID : nil
    return state
  }

  // MARK: - Corrections and toasts

  /// A correction from the pages: held or committed through the undo
  /// window, with its toast (§7.6).
  func submit(_ correction: MemoryCorrection) {
    guard let corrections else { return }
    let entry = corrections.submit(correction)
    if case .pin = correction {
      Task { await reloadUser() }
      return
    }
    let titles = Dictionary(
      (base.digest?.matters ?? []).map { ($0.eventID, $0.title) }, uniquingKeysWith: { a, _ in a })
    let groups = Dictionary(
      user.groups.map { ($0.id.uuidString.lowercased(), $0.name) },
      uniquingKeysWith: { a, _ in a })
    let names = Dictionary(
      base.people.map { ($0.personID, $0.name) }, uniquingKeysWith: { a, _ in a })
    if let toast = MemoryCorrectionToast.toast(
      for: correction, id: entry.id, titles: titles, groups: groups, names: names)
    {
      show(toast)
    }
    if !correction.isHeld { Task { await reloadUser() } }
  }

  func undo() {
    guard corrections?.undo() != nil else { return }
    dismissToast()
    Task { await reloadUser() }
  }

  func show(_ toast: MemoryToast) {
    // A held correction whose toast is replaced while the pointer is on it
    // goes on with its timer (it is no longer on screen to be left).
    if let previous = self.toast?.id, previous != toast.id { corrections?.resume(previous) }
    self.toast = toast
  }

  func dismissToast(_ id: UUID? = nil) {
    guard id == nil || toast?.id == id else { return }
    if let previous = toast?.id { corrections?.resume(previous) }
    toast = nil
  }

  /// The window is coming on screen (opened, brought back from the Dock,
  /// another Space or behind other windows): the current tagline, in the
  /// interface language's set, six-hour periods counted in the product time
  /// zone. Never called while the window is shown, so the line never changes
  /// under the reader's eyes; a new period takes effect at the next showing.
  func showTagline(app: DictationAppModel, now: Date = Date()) {
    tagline = MindloomTaglineBoard(defaults: LocalPreferenceStore.defaults).line(
      now: now, zone: app.productTimeZone, interfaceLanguage: app.spoken.interfaceLanguageID)
  }

  /// The window is going away: a toast it showed can no longer be left by
  /// the pointer, so its correction goes on.
  func windowClosed() {
    if let previous = toast?.id { corrections?.resume(previous) }
  }

  /// The pointer over the toast holds its correction too.
  func holdToast(_ id: UUID, hovering: Bool) {
    if hovering { corrections?.pause(id) } else { corrections?.resume(id) }
  }

  // MARK: - Mapping

  static func link(_ app: DictationAppModel) -> MemoryLinkState {
    let status: MemoryLinkState.Status
    if !app.remoteOrganizerEnabled {
      status = .off
    } else {
      switch app.remoteOrganizerLinkStatus {
      case .connected: status = .connected
      case .connecting: status = .connecting
      case .off: status = .off
      default: status = .notConnected
      }
    }
    return MemoryLinkState(status: status, waiting: 0, lastOrganizedAt: app.remoteOrganizerLastPull)
  }

  /// Corrections the DGX Spark did not take, worded as Settings words them;
  /// the local overlay keeps showing them applied until the user retries or
  /// drops them.
  static func issues(_ projection: RemoteOrganizerProjection?) -> [MemoryIssue] {
    (projection?.unacceptedDecisions ?? []).map { issue in
      MemoryIssue(
        id: issue.decisionID.uuidString,
        title: DictationAppModel.remoteDecisionIssueTitle(issue),
        deliveryUnknown: issue.state == .deliveryUnknown)
    }
  }
}

/// The undo window a quitting App commits (`applicationShouldTerminate`).
@MainActor
enum MemoryCorrectionQuit {
  static weak var queue: MemoryCorrectionQueue?
}

/// Normalized images read once from the asset root, by relative path. A path
/// that leaves the root is refused. NSCache is thread-safe.
private final class ThumbnailCache: @unchecked Sendable {
  private let cache = NSCache<NSString, NSImage>()

  func image(_ path: String, root: URL?) -> NSImage? {
    guard let root, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
      return nil
    }
    if let hit = cache.object(forKey: path as NSString) { return hit }
    guard let image = NSImage(contentsOf: root.appendingPathComponent(path)) else { return nil }
    cache.setObject(image, forKey: path as NSString)
    return image
  }
}

// OWNER: v12 find. The 历史 page's model (ALIGNMENT 查-1 to 查-7): keeps the
// record search index up to date, reads what is typed (people, sources,
// time words in the product time zone, the dictionary's spellings), runs
// the one MATCH (or the time-ordered page), and pages on as the list
// scrolls. Everything stays on this Mac: the query is never sent anywhere.

@MainActor
final class HistorySearchModel: ObservableObject {
  @Published private(set) var state = MemoryHistoryState()

  private weak var app: DictationAppModel?
  private var screen: @MainActor () -> MemoryScreenState = { MemoryScreenState() }
  private var observers: Set<AnyCancellable> = []
  private var query = ""
  private var parsed: SearchQuery?
  /// The meaning side of the shown search (v12 search), kept for its pages.
  private var meaning: RecordMeaningQuery?
  private var cursor: RecordSearchCursor?
  private var generation = 0
  private var searchTask: Task<Void, Never>?
  private var pageTask: Task<Void, Never>?
  private var syncTask: Task<Void, Never>?
  /// The index has been brought up to date once since launch.
  private var indexReady = false
  private var people: [SearchPerson] = []
  private var lexicon: [SearchLexiconEntry] = []
  private var sourceNames: [String] = []
  private var contextLoaded = false
  static let historyPage = 100
  static let searchPage = 50

  /// Starts following the library; call once. `screen` gives the pages'
  /// current state (matters, people, the projection) for 事 and 人.
  func attach(to app: DictationAppModel, screen: @escaping @MainActor () -> MemoryScreenState) {
    guard observers.isEmpty else { return }
    self.app = app
    self.screen = screen
    // A new or changed record: the index follows, then the open list.
    app.history.$historyItems
      .map { _ in () }
      .merge(with: app.history.$eventAvailableHistoryItems.map { _ in () })
      .debounce(for: .seconds(1), scheduler: RunLoop.main)
      .sink { [weak self] in self?.libraryChanged() }
      .store(in: &observers)
    syncIndex()
  }

  /// The dictionary or the people changed: read them again before the
  /// next query.
  func invalidateContext() {
    contextLoaded = false
  }

  /// A record the owner deleted leaves the list at once, however far it was
  /// paged (the index follows with the next library change).
  func forgetRow(_ itemID: String) {
    guard let index = state.rows.firstIndex(where: { $0.itemID == itemID }) else { return }
    state.rows.remove(at: index)
    state.total = state.total.map { max(0, $0 - 1) }
  }

  // MARK: - Index

  private func syncIndex(then: (() -> Void)? = nil) {
    guard let store = app?.repository else { return }
    syncTask?.cancel()
    syncTask = Task { [weak self] in
      let result = try? await store.syncRecordSearchIndex()
      guard let self, !Task.isCancelled else { return }
      indexReady = true
      // The meaning index follows the character index, in the background.
      self.app?.meaningSearch.scheduleIndexing()
      if let result, result.indexed + result.removed > 0 {
        contextLoaded = false
      }
      then?()
    }
  }

  private func libraryChanged() {
    syncIndex { [weak self] in
      guard let self, self.state.query == self.query else { return }
      // Show what came in, from the top of the list; a list already paged
      // further down is left where the user is reading.
      let first = self.parsed?.ordersByTime == false ? Self.searchPage : Self.historyPage
      guard self.state.rows.count <= first else { return }
      self.run(self.query, debounce: false, keepRows: true)
    }
  }

  // MARK: - Queries

  /// The page's query (the search field's text; "" is the whole history).
  func search(_ text: String) {
    let next = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let typing = !next.isEmpty && next != query
    query = next
    run(next, debounce: typing, keepRows: false)
  }

  private func run(_ text: String, debounce: Bool, keepRows: Bool) {
    guard let store = app?.repository else {
      state = MemoryHistoryState(query: text)
      return
    }
    searchTask?.cancel()
    pageTask?.cancel()
    pageTask = nil
    generation += 1
    let generation = generation
    if !keepRows {
      state.loading = true
    }
    let screen = screen()
    searchTask = Task { [weak self] in
      if debounce { try? await Task.sleep(for: .milliseconds(120)) }
      guard let self, !Task.isCancelled else { return }
      await self.loadContext(store: store, screen: screen)
      let context = self.searchContext(screen: screen)
      let parsed = SearchQueryParser.parse(text, context: context)
      // Words or a person need the index; the first build at launch is
      // waited for (later changes catch up in the background).
      if !parsed.ordersByTime || !parsed.people.isEmpty, !self.indexReady {
        if let running = self.syncTask {
          await running.value
        } else {
          _ = try? await store.syncRecordSearchIndex()
        }
        self.indexReady = true
      }
      let limit = parsed.ordersByTime ? Self.historyPage : Self.searchPage
      // By meaning too when the model is in memory and the query's vector
      // comes quickly; else characters now, and the same search again once
      // the vector has come or the model has loaded. Nothing of it while
      // something is being captured or recognized.
      let meaningSearch = self.app?.meaningSearch
      let again: @MainActor @Sendable () -> Void = { [weak self] in
        guard let self, generation == self.generation, self.query == text else { return }
        self.run(text, debounce: false, keepRows: true)
      }
      let meaning = await meaningSearch?.query(for: parsed, whenLate: again)
      if meaning == nil, MeaningQueryText.asksMeaning(parsed), meaningSearch?.isLoaded == false {
        meaningSearch?.warm(then: again)
      }
      guard !Task.isCancelled, generation == self.generation else { return }
      do {
        let page = try await store.searchRecords(
          parsed, meaning: meaning, limit: limit, now: Date())
        let records = try await store.memoryItemRecords(ids: page.hits.map(\.sessionID))
        guard !Task.isCancelled, generation == self.generation else { return }
        let digest = screen.digest
        let people = screen.people
        let built = await Task.detached(priority: .userInitiated) {
          Self.build(parsed, page: page, records: records, digest: digest, people: people)
        }.value
        guard !Task.isCancelled, generation == self.generation else { return }
        // Nothing found under conditions: what each one left out finds.
        var widen: [MemoryHistoryWiden] = []
        if page.total == 0, !parsed.chips.isEmpty {
          for chip in parsed.chips {
            let rest = SearchQueryParser.removing(chip, from: text)
            let wider = SearchQueryParser.parse(rest, context: context)
            if let n = try? await store.searchRecords(wider, limit: 1, now: Date()).total, n > 0 {
              widen.append(MemoryHistoryWiden(chip: chip, query: rest, count: n))
            }
          }
          guard !Task.isCancelled, generation == self.generation else { return }
        }
        self.parsed = parsed
        self.meaning = meaning
        self.cursor = page.next
        self.state = MemoryHistoryState(
          query: text, chips: parsed.chips, ordersByTime: parsed.ordersByTime,
          matters: built.matters, personIDs: built.people, rows: built.rows,
          total: page.total, hasMore: page.next != nil, loading: false,
          highlights: parsed.units.isEmpty ? [] : parsed.highlights)
        self.state.widen = widen
      } catch {
        guard generation == self.generation else { return }
        self.state = MemoryHistoryState(query: text, loading: false)
      }
    }
  }

  /// The next page (the list's end came into view).
  func loadMore() {
    guard let store = app?.repository, let parsed, let cursor, pageTask == nil,
      state.query == query
    else { return }
    let generation = generation
    let screen = screen()
    let limit = parsed.ordersByTime ? Self.historyPage : Self.searchPage
    let meaning = meaning
    pageTask = Task { [weak self] in
      defer { if let self, generation == self.generation { self.pageTask = nil } }
      guard
        let page = try? await store.searchRecords(
          parsed, meaning: meaning, cursor: cursor, limit: limit, now: Date()),
        let records = try? await store.memoryItemRecords(ids: page.hits.map(\.sessionID))
      else { return }
      guard let self, !Task.isCancelled, generation == self.generation else { return }
      let digest = screen.digest
      let built = await Task.detached(priority: .userInitiated) {
        Self.build(
          parsed, page: page, records: records, digest: digest, people: [],
          mattersAndPeople: false)
      }.value
      guard generation == self.generation else { return }
      let seen = Set(self.state.rows.map(\.itemID))
      self.state.rows += built.rows.filter { !seen.contains($0.itemID) }
      self.cursor = page.next
      self.state.hasMore = page.next != nil
    }
  }

  nonisolated private static func build(
    _ query: SearchQuery, page: RecordSearchPage, records: [MemoryItemRecord],
    digest: MemoryDigest?, people: [MemoryPersonEntry], mattersAndPeople: Bool = true
  ) -> (rows: [MemoryHistoryRow], matters: [MemoryHistoryMatter], people: [String]) {
    let index = MemoryHistoryBuilder.matterIndex(digest)
    let byID = Dictionary(
      records.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, _ in a })
    let rows = page.hits.compactMap { hit -> MemoryHistoryRow? in
      guard let record = byID[hit.sessionID] else { return nil }
      let id = record.sessionID.rawValue.uuidString.uppercased()
      return MemoryHistoryBuilder.row(
        record, query: query, matter: index[id], partial: hit.partial,
        near: hit.meaningOnly ? hit.meaningPiece?.text : nil)
    }
    guard mattersAndPeople else { return (rows, [], []) }
    return (
      rows, MemoryHistoryBuilder.matters(query, digest: digest),
      MemoryHistoryBuilder.people(query, people: people)
    )
  }

  // MARK: - What the query may name

  private func loadContext(store: GRDBDictationStore, screen: MemoryScreenState) async {
    guard !contextLoaded else { return }
    async let people = store.recordSearchPeople()
    async let names = store.recordSourceNames()
    async let words = store.allDictionaryEntries()
    self.people = (try? await people) ?? []
    sourceNames = (try? await names) ?? []
    lexicon = ((try? await words) ?? []).filter(\.enabled).map {
      SearchLexiconEntry(canonical: $0.canonicalForm, spoken: $0.spokenForms)
    }
    contextLoaded = true
  }

  private func searchContext(screen: MemoryScreenState) -> SearchContext {
    var owners = Set(DictationAppModel.memoryOwnerNames)
    if let projection = screen.projection {
      for person in projection.persons
      where projection.ownerPersonIDs.contains(person.personID.uppercased()) {
        if let name = person.displayName { owners.insert(name) }
        owners.formUnion(person.aliases)
      }
    }
    return SearchContext(
      people: people, ownerNames: owners, lexicon: lexicon, sourceNames: sourceNames,
      clock: SearchClock(now: Date()))
  }
}
