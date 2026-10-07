import BestASRAgentAccess
import BestASRMLXRuntime
import BestASRMemory
import BestASRPersistence
import Foundation
import MindloomIdentity
import OSLog

// OWNER: v12 search (ALIGNMENT 查-3, 查-6). The meaning half of the search,
// shared by 历史 and by other Apps' `search`: the installed meaning model,
// the meaning index kept up to date in the background, the agents' vectors
// made in the same steps, and a query's vector. Everything runs on this Mac;
// the query never leaves it.
//
// Nothing of it runs while something is being captured or recognized
// (`isBusy`: dictation, a room or system-audio recording, an import, a
// record recognized again, speaker matching, 整理, a recognition model's
// load): indexing waits between steps of a few pieces and drops the model
// while it waits, 历史 and agents search by characters only. The model loads
// when indexing or searching needs it and is released after two idle
// minutes, with the vectors held in memory. Without the model (not
// downloaded, or failing its check) search is by characters only, as
// before, and vectors of deleted records still go.

private let meaningLogger = Logger(
  subsystem: MindloomIdentity.logSubsystem, category: "meaning-search")

@MainActor
final class MeaningSearch {
  private weak var app: DictationAppModel?
  private(set) var embedder: MLXMeaningEmbedder?
  private var queryVectors: MeaningQueryVectors?
  private var indexTask: Task<Void, Never>?
  private var indexAgain = false
  private var releaseTask: Task<Void, Never>?
  private var loadTask: Task<Void, Never>?
  /// The model failed to load once; searches stay by characters until the
  /// next discovery.
  private var loadFailed = false
  /// Called once the model is loaded after a search had to go without it.
  private var whenLoaded: [@MainActor () -> Void] = []
  let artifact = MLXMeaningArtifact.selected
  static let idleRelease: Duration = .seconds(120)
  /// How long indexing waits between checks while dictation runs.
  static let busyPoll: Duration = .seconds(2)
  /// New pieces one agent search embeds, at most (the background warm-up
  /// makes the rest).
  static let agentNewPieces = 600
  /// How long 历史's character results wait for the query's vector; a later
  /// vector shows the search again.
  static let queryDeadline: Duration = .milliseconds(80)
  /// Pieces an agent search made for a grant's masked words are kept this
  /// long once no matter holds them as they are.
  static let agentSearchPiecesKept: TimeInterval = 7 * 86_400

  /// The model key of the model this App installs (vectors of any other are
  /// dropped).
  var selectedModelKey: String {
    GRDBDictationStore.meaningModelKey(
      artifact.recipe.modelVersion, dimension: artifact.recipe.dimension)
  }

  func attach(to app: DictationAppModel) {
    self.app = app
  }

  /// Something is being captured or recognized: nothing of the meaning
  /// search runs.
  var isBusy: Bool { app?.isCapturingOrRecognizing ?? false }

  // MARK: - Model

  /// Looks for the installed, verified model; indexing starts when found.
  func discover() async {
    guard let runtime = app?.localRuntime else { return }
    if let made = await runtime.makeMeaningEmbedder() {
      adopt(made)
    } else {
      embedder = nil
      queryVectors = nil
      // Vectors of deleted records still go.
      scheduleIndexing()
    }
  }

  func adopt(_ made: MLXMeaningEmbedder) {
    embedder = made
    queryVectors = MeaningQueryVectors { text in
      try? await made.embed([text], role: .query).first
    }
    loadFailed = false
    scheduleIndexing()
  }

  /// The model is in memory (read without waiting for the model's queue).
  var isLoaded: Bool { embedder?.isLoaded ?? false }

  /// Loads the model in the background; `then` runs once it is ready. Not
  /// while something is being captured or recognized.
  func warm(then: @escaping @MainActor () -> Void) {
    guard let embedder, !loadFailed, !isBusy else { return }
    whenLoaded.append(then)
    guard loadTask == nil else { return }
    loadTask = Task(priority: .userInitiated) { [weak self] in
      let loaded: Bool
      do {
        try await embedder.prepare()
        loaded = true
      } catch {
        loaded = false
      }
      guard let self else { return }
      self.loadTask = nil
      let waiting = self.whenLoaded
      self.whenLoaded = []
      guard loaded else {
        self.loadFailed = true
        meaningLogger.error("meaning model did not load; search by characters only")
        return
      }
      for then in waiting { then() }
      self.scheduleRelease()
    }
  }

  private func scheduleRelease() {
    releaseTask?.cancel()
    releaseTask = Task { [weak self] in
      try? await Task.sleep(for: Self.idleRelease)
      guard let self, !Task.isCancelled, self.indexTask == nil else { return }
      await self.embedder?.release()
      // The vectors held for searching go too; the next search reads them.
      self.app?.repository?.forgetRecordMeaningMatrix()
      await self.queryVectors?.forget()
      meaningLogger.notice("meaning model released after idle")
    }
  }

  // MARK: - Index

  /// The library changed (run after the character index caught up).
  func scheduleIndexing() {
    guard app?.repository != nil else { return }
    guard indexTask == nil else {
      indexAgain = true
      return
    }
    indexTask = Task(priority: .utility) { [weak self] in
      await self?.runIndexing()
    }
  }

  private func runIndexing() async {
    defer {
      indexTask = nil
      if indexAgain {
        indexAgain = false
        scheduleIndexing()
      } else if embedder != nil {
        scheduleRelease()
      }
    }
    guard let app, let store = app.repository else { return }
    let started = Date()
    do {
      _ = try await store.syncRecordSearchIndex()
      guard let embedder else {
        // No model: what left the library leaves the meaning index too, and
        // vectors of a model this App no longer installs go whole.
        let removed = try await store.pruneRecordMeaningIndex(keepingModel: selectedModelKey)
        try await upkeepAgentVectors(store: store, embedder: nil)
        if removed > 0 {
          meaningLogger.notice(
            "meaning index without model: \(removed, privacy: .public) records removed")
        }
        return
      }
      let result = try await store.syncRecordMeaningIndex(embedder: embedder) { [weak self] in
        try await self?.waitWhileBusy()
      }
      if result.records + result.removed > 0 {
        meaningLogger.notice(
          "meaning index: \(result.records, privacy: .public) records, \(result.embedded, privacy: .public) pieces, \(result.removed, privacy: .public) removed in \(Date().timeIntervalSince(started), privacy: .public) s"
        )
      }
      try await upkeepAgentVectors(store: store, embedder: embedder)
    } catch is CancellationError {
    } catch {
      meaningLogger.error(
        "meaning index stopped: \(String(describing: type(of: error)), privacy: .public)")
    }
  }

  /// The agents' vectors, in the same steps as the index: made in the
  /// background while other Apps may read (so a search does not make them),
  /// kept only for words some matter still holds; all dropped while other
  /// Apps may not read.
  private func upkeepAgentVectors(store: GRDBDictationStore, embedder: MLXMeaningEmbedder?)
    async throws
  {
    // Not set up yet (the library is still opening): nothing to do.
    guard let app, let service = app.agentAccess.service, let search = app.agentAccess.search
    else { return }
    guard app.agentAccess.otherAppsCanRead else {
      try await store.clearAgentMeaningVectors()
      return
    }
    let documents = await service.meaningDocuments()
    let cutoff = Date().addingTimeInterval(-Self.agentSearchPiecesKept)
    guard let embedder, let meaning = agentMeaning(embedder: embedder, store: store) else {
      // Without the model nothing is made; words no matter holds still go.
      try await Self.pruneAgentVectors(store: store, documents: documents, before: cutoff)
      return
    }
    let started = Date()
    let warmup = try await search.warmMeaning(
      documents, meaning: meaning, stored: try await store.agentMeaningKeys(model: meaning.model)
    ) { [weak self] in
      try await self?.waitWhileBusy()
    }
    let pruned = try await store.pruneAgentMeaningVectors(
      keeping: warmup.keys, searchPiecesBefore: cutoff)
    if warmup.embedded + pruned > 0 {
      meaningLogger.notice(
        "agent meaning vectors: \(warmup.embedded, privacy: .public) made, \(pruned, privacy: .public) removed in \(Date().timeIntervalSince(started), privacy: .public) s"
      )
    }
  }

  /// Off the main thread: cutting every matter's words into pieces takes a
  /// while on a large library.
  private nonisolated static func pruneAgentVectors(
    store: GRDBDictationStore, documents: [AgentSearchDocument], before cutoff: Date
  ) async throws {
    try await store.pruneAgentMeaningVectors(
      keeping: AgentRecordSearch.meaningKeys(of: documents), searchPiecesBefore: cutoff)
  }

  /// Waits while something is being captured or recognized (the dictation
  /// critical path never shares the Mac with indexing); the model leaves
  /// memory when a wait begins.
  func waitWhileBusy() async throws {
    try await MeaningPause.wait(
      poll: Self.busyPoll,
      isBusy: { [weak self] in await MainActor.run { self?.isBusy ?? false } },
      whenBusy: { [weak self] in await self?.releaseWhileBusy() })
  }

  private func releaseWhileBusy() async {
    guard let embedder, embedder.isLoaded else { return }
    await embedder.release()
    meaningLogger.notice("meaning model released while capturing or recognizing")
  }

  // MARK: - Queries

  /// The meaning side of a 历史 search, when the model is loaded and nothing
  /// is being captured or recognized (nil: search by characters only). The
  /// query's vector is waited for at most `queryDeadline`; when it comes
  /// later, `whenLate` runs (show the search again). `warm` loads the model
  /// for the next search.
  func query(for parsed: SearchQuery, whenLate: @escaping @MainActor @Sendable () -> Void) async
    -> RecordMeaningQuery?
  {
    guard let embedder, let queryVectors, MeaningQueryText.asksMeaning(parsed),
      embedder.isLoaded, !isBusy
    else { return nil }
    scheduleRelease()
    guard
      let vector = await queryVectors.vector(
        for: MeaningQueryText.text(parsed), within: Self.queryDeadline,
        whenLate: { Task { @MainActor in whenLate() } })
    else { return nil }
    return RecordMeaningQuery(
      vector: vector, modelVersion: embedder.modelVersion, floor: artifact.floor)
  }

  /// The same model and combining rule for other Apps' `search` (用-8).
  /// While something is being captured or recognized an agent's search is
  /// by characters only: neither loading the model nor embedding competes
  /// with dictation (a search under way stops embedding when dictation
  /// starts). The vectors come from the library (made in the background);
  /// one search makes at most `agentNewPieces` the warm-up has not reached.
  func agentMeaning() -> AgentMeaning? {
    guard let embedder, !loadFailed, !isBusy, let store = app?.repository else { return nil }
    return agentMeaning(embedder: embedder, store: store)
  }

  private func agentMeaning(embedder: MLXMeaningEmbedder, store: GRDBDictationStore)
    -> AgentMeaning?
  {
    guard !loadFailed else { return nil }
    let model = GRDBDictationStore.meaningModelKey(
      embedder.modelVersion, dimension: embedder.dimension)
    return AgentMeaning(
      floor: artifact.floor, maximumNewPieces: Self.agentNewPieces, model: model,
      stored: { keys in (try? await store.agentMeaningVectors(keys, model: model)) ?? [:] },
      store: { vectors, fromSearch in
        try? await store.saveAgentMeaningVectors(vectors, model: model, fromSearch: fromSearch)
      },
      mayEmbed: { [weak self] in
        await MainActor.run { !(self?.isBusy ?? false) }
      },
      embed: { [weak self] texts, role in
        let vectors = try await embedder.embed(texts, role: role)
        await self?.scheduleRelease()
        return vectors
      })
  }
}

extension DictationAppModel {
  /// Something is being captured, or recognized, matched to speakers,
  /// polished, organized or inserted; or a recognition model is loading.
  var isCapturingOrRecognizing: Bool {
    snapshot.phase.isActive || capture.roomSnapshot.phase.isActive
      || capture.systemAudioSnapshot.phase.isActive || capture.importInProgress
      || history.retryingHistorySessionID != nil || localRuntime?.heavyWork.isBusy == true
  }
}
