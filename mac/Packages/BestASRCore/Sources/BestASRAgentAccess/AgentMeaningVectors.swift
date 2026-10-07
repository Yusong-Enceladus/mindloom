import BestASRMemory
import Foundation

/// The vectors of the pieces other Apps' search compares (v12 search, review
/// fixes). The library keeps every one (`AgentMeaning.stored`, `store`), so
/// a launch does not make them again; this keeps the recently used ones in
/// memory, at most `budget` bytes, the least recently used going first even
/// while a search runs (reading one again costs a database read, not the
/// model). A piece is made once at a time: a search that needs a piece
/// another search or the background warm-up is making waits for it.
///
/// The vectors one search compares are held only for that search, outside
/// the budget.
actor AgentMeaningVectors {
  struct Outcome {
    /// Unit vectors by piece key.
    var found: [String: [Float]]
    /// Pieces asked for that have no vector (not compared this time).
    var missing: Int
  }

  private struct Entry {
    let vector: [Float]
    var used: UInt64
  }

  let budget: Int
  private var entries: [String: Entry] = [:]
  private var size = 0
  private var tick: UInt64 = 0
  private var model: String?
  private var making: [String: Task<[String: [Float]], Never>] = [:]
  /// Pieces sent to the model (for tests and measurements).
  private(set) var embedded = 0

  /// Pieces per model call while a search runs, and in the warm-up.
  static let searchBatch = 32
  static let warmBatch = 16

  init(budget: Int) {
    self.budget = max(0, budget)
  }

  var count: Int { entries.count }
  var bytes: Int { size }

  /// The vectors of `wanted` (unique keys): from memory, then the library,
  /// then pieces being made, then at most `maximumNew` made now (while
  /// `meaning.mayEmbed` allows).
  func vectors(
    for wanted: [(key: String, text: String)], meaning: AgentMeaning, maximumNew: Int
  ) async -> Outcome {
    use(meaning.model)
    tick += 1
    var found: [String: [Float]] = [:]
    var rest: [(key: String, text: String)] = []
    for item in wanted {
      if let vector = touch(item.key) { found[item.key] = vector } else { rest.append(item) }
    }
    if !rest.isEmpty {
      for (key, vector) in await meaning.stored(rest.map(\.key)) where !vector.isEmpty {
        found[key] = vector
        keep(key, vector)
      }
    }
    var made = 0
    var awaited = Set<Task<[String: [Float]], Never>>()
    while true {
      for item in rest where found[item.key] == nil {
        if let vector = touch(item.key) { found[item.key] = vector }
      }
      rest = rest.filter { found[$0.key] == nil }
      // Pieces someone else is making: wait for those, once each.
      let theirs = Set(rest.compactMap { making[$0.key] }).subtracting(awaited)
      if !theirs.isEmpty {
        for task in theirs {
          awaited.insert(task)
          for (key, vector) in await task.value { found[key] = vector }
        }
        continue
      }
      guard !rest.isEmpty, made < maximumNew, await meaning.mayEmbed() else { break }
      // Asking may have let another search start some of them, or keep them.
      let batch = Array(
        rest.filter { making[$0.key] == nil && entries[$0.key] == nil }
          .prefix(min(Self.searchBatch, maximumNew - made)))
      if batch.isEmpty {
        let more = rest.contains {
          entries[$0.key] != nil || making[$0.key].map { !awaited.contains($0) } == true
        }
        // Otherwise only pieces another search failed to make are left.
        if more { continue } else { break }
      }
      made += batch.count
      guard let out = await make(Array(batch), meaning: meaning, fromSearch: true) else { break }
      for (key, vector) in out {
        found[key] = vector
        keep(key, vector)
      }
    }
    trim()
    return Outcome(found: found, missing: wanted.filter { found[$0.key] == nil }.count)
  }

  /// Makes and stores the vectors of `wanted` (unique keys not stored yet),
  /// awaiting `pause` before every batch. Pieces already being made are left
  /// to whoever makes them. Returns how many were made; throws when `pause`
  /// throws or the model fails.
  func warm(
    _ wanted: [(key: String, text: String)], meaning: AgentMeaning,
    pause: @Sendable () async throws -> Void
  ) async throws -> Int {
    use(meaning.model)
    var done = 0
    var index = 0
    while index < wanted.count {
      try await pause()
      try Task.checkCancellation()
      let slice = wanted[index..<min(index + Self.warmBatch, wanted.count)]
      index += slice.count
      let mine = slice.filter { making[$0.key] == nil && entries[$0.key] == nil }
      guard !mine.isEmpty else { continue }
      guard let out = await make(Array(mine), meaning: meaning, fromSearch: false) else {
        throw AgentMeaningError.modelFailed
      }
      done += out.count
    }
    return done
  }

  /// Embeds `items`, stores their vectors and returns them; nil when the
  /// model failed. Searches that need one of them meanwhile wait for it.
  private func make(
    _ items: [(key: String, text: String)], meaning: AgentMeaning, fromSearch: Bool
  ) async -> [String: [Float]]? {
    let task = Task { () -> [String: [Float]] in
      guard let vectors = try? await meaning.embed(items.map(\.text), .document),
        vectors.count == items.count
      else { return [:] }
      var out: [String: [Float]] = [:]
      for (item, vector) in zip(items, vectors) where !vector.isEmpty {
        out[item.key] = MeaningMatrix.normalized(vector)
      }
      await meaning.store(out, fromSearch)
      return out
    }
    for item in items { making[item.key] = task }
    let out = await task.value
    for item in items where making[item.key] == task { making[item.key] = nil }
    embedded += out.count
    return out.isEmpty ? nil : out
  }

  // MARK: - Memory

  /// Vectors of another model are never compared: memory starts again.
  private func use(_ model: String) {
    guard self.model != model else { return }
    entries = [:]
    size = 0
    self.model = model
  }

  private func touch(_ key: String) -> [Float]? {
    guard var entry = entries[key] else { return nil }
    entry.used = tick
    entries[key] = entry
    return entry.vector
  }

  private func keep(_ key: String, _ vector: [Float]) {
    if let old = entries[key] { size -= Self.cost(key, old.vector) }
    entries[key] = Entry(vector: vector, used: tick)
    size += Self.cost(key, vector)
  }

  /// Down to the budget, least recently used first (this search's too).
  private func trim() {
    guard size > budget else { return }
    for (key, entry) in entries.sorted(by: { $0.value.used < $1.value.used }) {
      guard size > budget else { break }
      entries[key] = nil
      size -= Self.cost(key, entry.vector)
    }
  }

  static func cost(_ key: String, _ vector: [Float]) -> Int {
    key.utf8.count + vector.count * MemoryLayout<Float>.size
  }
}

enum AgentMeaningError: Error {
  case modelFailed
}
