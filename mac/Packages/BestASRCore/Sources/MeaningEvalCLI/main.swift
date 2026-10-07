import BestASRDomain
import BestASRMLXRuntime
import BestASRMemory
import BestASRPersistence
import Darwin
import Foundation
import MLX

/// Chooses the meaning model and the way the character and meaning searches
/// combine (v12 search; ALIGNMENT 查-3, 查-6). The same store code the App
/// runs: `syncRecordMeaningIndex`, `searchRecordMeaning`, `MeaningFusion`.
///
///     MeaningEvalCLI index --root <library> --recipe <name> --model <dir>
///         [--cache-limit-mb N] [--private]
///     MeaningEvalCLI eval  --root <library> --recipe <name> --model <dir>
///         --set <queries.json> [--out <rankings.json>] [--floor F] [--private]
///     MeaningEvalCLI meetings --root <library> --file <tmeet-transcripts.json> --private
///     MeaningEvalCLI pool  --root <library> --set <queries.json> --runs a.json,b.json
///         --out <file> --private
///     MeaningEvalCLI report --set <queries.json> --rankings <rankings.json> [--floor F]
///
/// `report` prints the table of IMPLEMENTATION_STATUS.md from a saved run
/// (no model needed): averages over the queries that have an answer; MRR is
/// the reciprocal rank of the first record of the query's highest grade
/// (the first relevant record of any grade in brackets); queries without an
/// answer report only how many records the first screen shows.
/// `Tools/SearchEval/analyze_meaning.py` adds intervals and the breakdowns.
///
/// A root is a synthetic one (marked SYNTHETIC_DATA_ROOT, never the canonical
/// demo root) or, with `--private`, a copy of a library inside
/// ~/.mindloom-private-eval. A real library folder is always refused. Standard
/// output carries numbers and query IDs only, never record text or queries
/// of a private set; `pool` writes record text only into a private file.
@main
struct MeaningEvalCLI {
  static func main() async {
    do {
      try await run(Array(CommandLine.arguments.dropFirst()))
    } catch {
      FileHandle.standardError.write(Data("meaning eval: \(error)\n".utf8))
      exit(1)
    }
  }

  // MARK: - Arguments

  struct Arguments {
    var command = ""
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
      var iterator = raw.makeIterator()
      command = iterator.next() ?? ""
      while let key = iterator.next() {
        if ["--private", "--misses", "--quiet"].contains(key) {
          flags.insert(key)
        } else if let value = iterator.next() {
          values[key] = value
        }
      }
    }

    func value(_ name: String) throws -> String {
      guard let value = values[name] else { throw CLIError("missing \(name)") }
      return value
    }
  }

  static let canonicalDemoRoot = "/Users/Shared/mindloom-demo/v11/env/preview-root"
  static var privateBase: String {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mindloom-private-eval")
      .resolvingSymlinksInPath().path
  }

  /// Refuses anything but a synthetic root or (with --private) a copy in the
  /// private evaluation folder.
  static func checkedRoot(_ arguments: Arguments) throws -> URL {
    let root = URL(fileURLWithPath: try arguments.value("--root")).standardizedFileURL
      .resolvingSymlinksInPath()
    // Mindloom's library and bestASR's (the folder the switch moves from).
    for name in ["Mindloom", "bestASR"] {
      let library = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/\(name)")
        .resolvingSymlinksInPath().path
      guard !root.path.hasPrefix(library) else { throw CLIError("refusing a real library") }
    }
    guard root.path != URL(fileURLWithPath: canonicalDemoRoot).resolvingSymlinksInPath().path
    else { throw CLIError("refusing the canonical demo root; clone it first") }
    let synthetic = FileManager.default.fileExists(
      atPath: root.appendingPathComponent("SYNTHETIC_DATA_ROOT").path)
    if arguments.flags.contains("--private") {
      guard root.path.hasPrefix(privateBase + "/") else {
        throw CLIError("--private roots live in ~/.mindloom-private-eval")
      }
    } else if !synthetic {
      throw CLIError("refusing a root without SYNTHETIC_DATA_ROOT (use --private for a copy)")
    }
    return root
  }

  static func checkedOutput(_ path: String, _ arguments: Arguments) throws -> URL {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    if arguments.flags.contains("--private") {
      let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
      guard (parent + "/").hasPrefix(privateBase + "/") else {
        throw CLIError("a private run writes only inside ~/.mindloom-private-eval")
      }
    }
    return url
  }

  static func openStore(_ root: URL) throws -> GRDBDictationStore {
    try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("history.sqlite"), migrationBackup: .disabled)
  }

  // MARK: - Recipes

  /// The candidates (pinned revisions; local evaluation picks one).
  static func recipe(_ name: String) throws -> MLXMeaningRecipe {
    switch name {
    case "qwen3-0.6b-4bit":
      return .qwen3Embedding(
        name: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
        revision: "6c3ae70858513f1a78e9cdca3cae330d9075cd2a")
    case "qwen3-0.6b-4bit-512":
      return .qwen3Embedding(
        name: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
        revision: "6c3ae70858513f1a78e9cdca3cae330d9075cd2a", dimension: 512)
    case "qwen3-0.6b-8bit":
      return .qwen3Embedding(
        name: "mlx-community/Qwen3-Embedding-0.6B-8bit",
        revision: "407ad2329cd30702720aafe83f74a1ba30fdfbca")
    case "qwen3-0.6b-bf16":
      return .qwen3Embedding(
        name: "Qwen/Qwen3-Embedding-0.6B", revision: "97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3")
    case "qwen3-0.6b-bf16-web":
      // The model card's own example instruction, for comparison.
      return .qwen3Embedding(
        name: "Qwen/Qwen3-Embedding-0.6B", revision: "97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3",
        instruction:
          "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:"
      )
    case "e5-small":
      return .multilingualE5(
        name: "intfloat/multilingual-e5-small",
        revision: "614241f622f53c4eeff9890bdc4f31cfecc418b3", dimension: 384)
    case "bge-small-zh":
      return .bgeChinese(
        name: "BAAI/bge-small-zh-v1.5", revision: "7999e1d3359715c523056ef9478215996d62a620",
        dimension: 512)
    default:
      throw CLIError("unknown recipe \(name)")
    }
  }

  static func embedder(_ arguments: Arguments) throws -> any MeaningEmbedding {
    let name = try arguments.value("--recipe")
    if name == "apple-contextual" { return try AppleMeaningEmbedder(.contextual) }
    if name == "apple-sentence" { return try AppleMeaningEmbedder(.sentence) }
    let recipe = try recipe(name)
    let directory = URL(fileURLWithPath: try arguments.value("--model"))
    if let megabytes = arguments.values["--cache-limit-mb"].flatMap(Int.init) {
      Memory.cacheLimit = megabytes * 1_048_576
    }
    let budget = arguments.values["--token-budget"].flatMap(Int.init) ?? 4_096
    return MLXMeaningEmbedder(
      verifiedModelDirectory: directory, recipe: recipe, tokenBudget: budget)
  }

  // MARK: - Commands

  static func run(_ raw: [String]) async throws {
    let arguments = Arguments(raw)
    switch arguments.command {
    case "index": try await index(arguments)
    case "eval": try await evaluate(arguments)
    case "meetings": try await meetings(arguments)
    case "pool": try await pool(arguments)
    case "probe": try await probe(arguments)
    case "report": try reportSaved(arguments)
    default:
      print("usage: MeaningEvalCLI index|eval|meetings|pool|probe|report … (see the source)")
      exit(64)
    }
  }

  /// Builds (or brings up to date) the meaning index; prints throughput,
  /// memory and size.
  static func index(_ arguments: Arguments) async throws {
    let root = try checkedRoot(arguments)
    let store = try openStore(root)
    let embedder = try embedder(arguments)
    let lexicalStart = Date()
    let sync = try await store.syncRecordSearchIndex()
    print(
      "character index: \(sync.indexed) indexed, \(sync.unchanged) unchanged, "
        + String(format: "%.2f s", Date().timeIntervalSince(lexicalStart)))
    let loadStart = Date()
    _ = try await embedder.embed(["预热"], role: .document)
    let load = Date().timeIntervalSince(loadStart)
    Memory.peakMemory = 0
    let started = Date()
    let result = try await store.syncRecordMeaningIndex(
      embedder: embedder,
      maximumRecords: arguments.values["--max-records"].flatMap(Int.init))
    let seconds = Date().timeIntervalSince(started)
    let status = try await store.recordMeaningStatus()
    let mlx = Memory.peakMemory
    print(
      String(
        format:
          "meaning index: model load %.2f s; %ld records, %ld pieces embedded, %ld kept, %ld removed in %.1f s (%.1f pieces/s); pending %ld",
        load, result.records, result.embedded, result.reused, result.removed, seconds,
        Double(result.embedded) / max(seconds, 0.001), status.pending))
    print(
      String(
        format: "size: %ld pieces, vectors %.1f MB; MLX peak %.0f MB; process peak %.0f MB",
        status.pieces, Double(status.vectorBytes) / 1_048_576, Double(mlx) / 1_048_576,
        Double(processPeakBytes()) / 1_048_576))
  }

  // MARK: - Evaluation

  struct QuerySet: Decodable {
    struct Query: Decodable {
      let id: String
      let category: String
      let query: String
      /// Binary relevance.
      let relevant: [String]?
      /// Graded relevance (1 related, 2 what was looked for).
      let graded: [String: Int]?

      var gains: [String: Int] {
        if let graded { return graded.reduce(into: [:]) { $0[$1.key.uppercased()] = $1.value } }
        return (relevant ?? []).reduce(into: [:]) { $0[$1.uppercased()] = 1 }
      }
    }

    struct Lexicon: Decodable {
      let canonical: String
      let spoken: [String]
    }

    let now: String
    let ownerNames: [String]?
    let lexicon: [Lexicon]?
    let queries: [Query]

    enum CodingKeys: String, CodingKey {
      case now, lexicon, queries
      case ownerNames = "owner_names"
    }
  }

  struct Ranking: Codable {
    let id: String
    let lexical: [String]
    let lexicalPartial: [Bool]
    let meaning: [String]
    let similarity: [Float]
    let embedMilliseconds: Double
    let hybridMilliseconds: Double
    let lexicalMilliseconds: Double?
  }

  static func context(store: GRDBDictationStore, set: QuerySet, now: Date) async throws
    -> SearchContext
  {
    var lexicon =
      (set.lexicon ?? []).map { SearchLexiconEntry(canonical: $0.canonical, spoken: $0.spoken) }
    if set.lexicon == nil {
      lexicon = try await store.allDictionaryEntries().filter(\.enabled).map {
        SearchLexiconEntry(canonical: $0.canonicalForm, spoken: $0.spokenForms)
      }
    }
    return SearchContext(
      people: try await store.recordSearchPeople(), ownerNames: Set(set.ownerNames ?? []),
      lexicon: lexicon, sourceNames: try await store.recordSourceNames(),
      clock: SearchClock(now: now))
  }

  static func evaluate(_ arguments: Arguments) async throws {
    let root = try checkedRoot(arguments)
    let set = try JSONDecoder().decode(
      QuerySet.self, from: Data(contentsOf: URL(fileURLWithPath: try arguments.value("--set"))))
    guard let now = ISO8601DateFormatter().date(from: set.now) else { throw CLIError("bad now") }
    let store = try openStore(root)
    _ = try await store.syncRecordSearchIndex()
    let embedder = try embedder(arguments)
    let status = try await store.recordMeaningStatus()
    let key = embedder.modelVersion + "|" + String(embedder.dimension)
    guard status.modelVersion == key, status.pending == 0 else {
      throw CLIError(
        "run index first (model \(status.modelVersion ?? "none"), pending \(status.pending))")
    }
    let context = try await context(store: store, set: set, now: now)
    let floor = arguments.values["--floor"].flatMap(Float.init) ?? -1
    // Warm the vectors and the model once.
    _ = try await embedder.embed(["预热"], role: .query)

    var rankings: [Ranking] = []
    for query in set.queries {
      // As typed into 历史 (the last word may still be typing).
      let parsed = SearchQueryParser.parse(query.query, context: context)
      let lexicalStart = Date()
      let lexicalPage = try await store.searchRecords(parsed, limit: 100, now: now)
      let lexicalMS = Date().timeIntervalSince(lexicalStart) * 1000
      let lexical = lexicalPage.hits.map { $0.sessionID.rawValue.uuidString.uppercased() }
      var meaning: [String] = []
      var similarity: [Float] = []
      var embedMS = 0.0
      var hybridMS = 0.0
      if MeaningQueryText.asksMeaning(parsed) {
        let start = Date()
        let vector = try await embedder.embed([MeaningQueryText.text(parsed)], role: .query)[0]
        embedMS = Date().timeIntervalSince(start) * 1000
        let found = try await store.searchRecordMeaning(
          parsed,
          meaning: RecordMeaningQuery(
            vector: vector, modelVersion: embedder.modelVersion, floor: -1),
          limit: 100)
        meaning = found.map { $0.sessionID.rawValue.uuidString.uppercased() }
        similarity = found.map(\.similarity)
        // The App's path end to end: embed, both searches, fuse, one page.
        let hybridStart = Date()
        let again = try await embedder.embed([MeaningQueryText.text(parsed)], role: .query)[0]
        _ = try await store.searchRecords(
          parsed,
          meaning: RecordMeaningQuery(
            vector: again, modelVersion: embedder.modelVersion, floor: floor),
          limit: 50, now: now)
        hybridMS = Date().timeIntervalSince(hybridStart) * 1000
      }
      rankings.append(
        Ranking(
          id: query.id, lexical: lexical, lexicalPartial: lexicalPage.hits.map(\.partial),
          meaning: meaning, similarity: similarity, embedMilliseconds: embedMS,
          hybridMilliseconds: hybridMS, lexicalMilliseconds: lexicalMS))
    }
    if let out = arguments.values["--out"] {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let url = try checkedOutput(out, arguments)
      try encoder.encode(rankings).write(to: url)
      if arguments.flags.contains("--private") {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      }
    }
    report(set: set, rankings: rankings, floor: floor, arguments: arguments)
    let embeds = rankings.map(\.embedMilliseconds).filter { $0 > 0 }.sorted()
    let hybrids = rankings.map(\.hybridMilliseconds).filter { $0 > 0 }.sorted()
    let chars = rankings.compactMap(\.lexicalMilliseconds).sorted()
    print(
      String(
        format:
          "latency: characters p50 %.1f ms p95 %.1f ms; query vector p50 %.1f ms p95 %.1f ms; whole search (vector + both + combine, first page) p50 %.1f ms p95 %.1f ms; process peak %.0f MB",
        percentile(chars, 0.5), percentile(chars, 0.95),
        percentile(embeds, 0.5), percentile(embeds, 0.95), percentile(hybrids, 0.5),
        percentile(hybrids, 0.95), Double(processPeakBytes()) / 1_048_576))
  }

  /// The ways of combining compared (the App ships `.standard`).
  static let variants: [(String, MeaningFusion.Policy?)] = [
    ("chars", nil),
    ("meaning", MeaningFusion.Policy(lexicalWeight: 0, meaningWeight: 1, wholeMatchesFirst: false)),
    ("rrf", MeaningFusion.Policy(wholeMatchesFirst: false)),
    ("rrf-whole", .standard),
    ("rrf-c2", MeaningFusion.Policy(lexicalWeight: 2, wholeMatchesFirst: false)),
    ("rrf-m2", MeaningFusion.Policy(meaningWeight: 2, wholeMatchesFirst: false)),
    ("rrf-m2-whole", MeaningFusion.Policy(meaningWeight: 2)),
  ]

  static func fused(_ ranking: Ranking, policy: MeaningFusion.Policy?, floor: Float) -> [String] {
    guard let policy else { return ranking.lexical }
    let meaning = zip(ranking.meaning, ranking.similarity).filter { $0.1 >= floor }
      .map { MeaningFusion.Meaning(id: $0.0, similarity: $0.1) }
    let lexical =
      policy.lexicalWeight == 0
      ? []
      : zip(ranking.lexical, ranking.lexicalPartial).map {
        MeaningFusion.Lexical(id: $0.0, partial: $0.1)
      }
    if ranking.meaning.isEmpty, ranking.similarity.isEmpty, policy.lexicalWeight > 0 {
      return ranking.lexical
    }
    return MeaningFusion.fuse(lexical: lexical, meaning: meaning, policy: policy).map(\.id)
  }

  /// Scores over the queries that have an answer; queries without one only
  /// count what the first screen shows.
  struct Metrics {
    var recall10 = 0.0
    var ndcg10 = 0.0
    /// The first record of the query's highest grade.
    var mrr = 0.0
    /// The first relevant record of any grade.
    var mrrAny = 0.0
    var precision10 = 0.0
    var empty = 0
    var n = 0
    var unanswerable = 0
    var unanswerableShown = 0

    mutating func add(_ ranked: [String], gains: [String: Int]) {
      let top = Array(ranked.prefix(10))
      let relevant = gains.filter { $0.value > 0 }
      guard let best = relevant.values.max() else {
        unanswerable += 1
        unanswerableShown += top.count
        return
      }
      n += 1
      if ranked.isEmpty { empty += 1 }
      let hits = top.filter { (gains[$0] ?? 0) > 0 }.count
      recall10 += Double(hits) / Double(min(10, relevant.count))
      precision10 += Double(hits) / 10
      var dcg = 0.0
      for (index, id) in top.enumerated() {
        let gain = Double((1 << (gains[id] ?? 0)) - 1)
        dcg += gain / log2(Double(index + 2))
      }
      let ideal = relevant.values.sorted(by: >).prefix(10).enumerated().reduce(0.0) {
        $0 + Double((1 << $1.element) - 1) / log2(Double($1.offset + 2))
      }
      ndcg10 += ideal > 0 ? dcg / ideal : 0
      if let rank = ranked.prefix(100).firstIndex(where: { (gains[$0] ?? 0) >= best }) {
        mrr += 1 / Double(rank + 1)
      }
      if let rank = ranked.prefix(100).firstIndex(where: { (gains[$0] ?? 0) > 0 }) {
        mrrAny += 1 / Double(rank + 1)
      }
    }

    func line(_ name: String) -> String {
      let d = Double(max(1, n))
      var out = String(
        format: "%-14@ %3ld  R@10 %.3f  nDCG@10 %.3f  MRR %.3f (any %.3f)  P@10 %.3f  empty %ld",
        name as NSString, n, recall10 / d, ndcg10 / d, mrr / d, mrrAny / d, precision10 / d,
        empty)
      if unanswerable > 0 {
        out += String(
          format: "  | no answer %ld, shown %.1f", unanswerable,
          Double(unanswerableShown) / Double(unanswerable))
      }
      return out
    }
  }

  /// The table of a saved run (`eval --out`), without a model.
  static func reportSaved(_ arguments: Arguments) throws {
    let set = try JSONDecoder().decode(
      QuerySet.self, from: Data(contentsOf: URL(fileURLWithPath: try arguments.value("--set"))))
    let rankings = try JSONDecoder().decode(
      [Ranking].self,
      from: Data(contentsOf: URL(fileURLWithPath: try arguments.value("--rankings"))))
    let floor = arguments.values["--floor"].flatMap(Float.init) ?? -1
    report(set: set, rankings: rankings, floor: floor, arguments: arguments)
  }

  static func report(set: QuerySet, rankings: [Ranking], floor: Float, arguments: Arguments) {
    let byID = Dictionary(uniqueKeysWithValues: set.queries.map { ($0.id, $0) })
    let categories = set.queries.map(\.category).reduce(into: [String]()) {
      if !$0.contains($1) { $0.append($1) }
    }
    print(
      String(
        format:
          "floor %.2f; averages over queries with an answer; MRR: first record of the query's highest grade (any grade in brackets)",
        floor))
    for (name, policy) in variants {
      var all = Metrics()
      var lines: [String] = []
      for category in categories {
        var metrics = Metrics()
        for ranking in rankings where byID[ranking.id]?.category == category {
          let ranked = fused(ranking, policy: policy, floor: floor)
          metrics.add(ranked, gains: byID[ranking.id]!.gains)
          all.add(ranked, gains: byID[ranking.id]!.gains)
        }
        lines.append("  " + metrics.line(category))
      }
      print("== \(name)")
      if categories.count > 1 {
        for line in lines { print(line) }
      }
      print("  " + all.line("all"))
    }
    // How similar the meaning side's results are, related or not (to set
    // the floor).
    var related: [Float] = []
    var unrelated: [Float] = []
    for ranking in rankings {
      guard let gains = byID[ranking.id]?.gains else { continue }
      for (id, value) in zip(ranking.meaning.prefix(10), ranking.similarity.prefix(10)) {
        if (gains[id] ?? 0) > 0 { related.append(value) } else { unrelated.append(value) }
      }
    }
    related.sort()
    unrelated.sort()
    print(
      String(
        format:
          "similarity of meaning top 10: related p10 %.3f p50 %.3f (n %ld); unrelated p50 %.3f p90 %.3f (n %ld)",
        percentile(related, 0.1), percentile(related, 0.5), related.count,
        percentile(unrelated, 0.5), percentile(unrelated, 0.9), unrelated.count))
  }

  static func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
  }

  static func percentile(_ sorted: [Float], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))])
  }

  // MARK: - Private preparation

  /// Takes meeting transcripts into a private copy as text items from
  /// 腾讯会议, one per meeting, 「名字：话」 per paragraph (once).
  static func meetings(_ arguments: Arguments) async throws {
    guard arguments.flags.contains("--private") else { throw CLIError("meetings needs --private") }
    let root = try checkedRoot(arguments)
    let file = URL(fileURLWithPath: try arguments.value("--file")).resolvingSymlinksInPath()
    guard file.path.hasPrefix(privateBase + "/") else { throw CLIError("file must be private") }
    let marker = root.appendingPathComponent("MEETINGS_ADDED")
    guard !FileManager.default.fileExists(atPath: marker.path) else {
      print("meetings: already added")
      return
    }
    struct Meeting: Decodable {
      struct Paragraph: Decodable {
        let speakerName: String
        let text: String

        enum CodingKeys: String, CodingKey {
          case text
          case speakerName = "speaker_name"
        }
      }
      let meetingStart: String
      let duplicateOf: String?
      let paragraphs: [Paragraph]

      enum CodingKeys: String, CodingKey {
        case paragraphs
        case meetingStart = "meeting_start"
        case duplicateOf = "duplicate_of"
      }
    }
    let all = try JSONDecoder().decode([Meeting].self, from: Data(contentsOf: file))
    let store = try openStore(root)
    let formatter = ISO8601DateFormatter()
    var added = 0
    var characters = 0
    for meeting in all where meeting.duplicateOf == nil {
      guard let start = formatter.date(from: meeting.meetingStart) else { continue }
      let text = meeting.paragraphs.map { "\($0.speakerName)：\($0.text)" }
        .joined(separator: "\n")
      try await store.createUserItem(
        UserItemDraft(
          kind: .text, capturedAt: start,
          source: ItemSourceApplication(bundleID: nil, name: "腾讯会议"), sourceOrigin: .user,
          text: text, extractor: "meeting-eval-v1"))
      added += 1
      characters += text.count
    }
    try Data().write(to: marker)
    print("meetings: \(added) added, \(characters) characters")
  }

  /// Writes, into a private file, every record the runs put in a query's
  /// top `--depth` (default 10) with its text, for judging.
  static func pool(_ arguments: Arguments) async throws {
    guard arguments.flags.contains("--private") else { throw CLIError("pool needs --private") }
    let root = try checkedRoot(arguments)
    let out = try checkedOutput(try arguments.value("--out"), arguments)
    let depth = arguments.values["--depth"].flatMap(Int.init) ?? 10
    let set = try JSONDecoder().decode(
      QuerySet.self, from: Data(contentsOf: URL(fileURLWithPath: try arguments.value("--set"))))
    var pooled: [String: [String]] = [:]
    for path in try arguments.value("--runs").split(separator: ",") {
      let rankings = try JSONDecoder().decode(
        [Ranking].self, from: Data(contentsOf: URL(fileURLWithPath: String(path))))
      for ranking in rankings {
        var list = pooled[ranking.id, default: []]
        for variant in variants {
          for id in fused(ranking, policy: variant.1, floor: -1).prefix(depth)
          where !list.contains(id) {
            list.append(id)
          }
        }
        pooled[ranking.id] = list
      }
    }
    let store = try openStore(root)
    let ids = Set(pooled.values.flatMap { $0 })
    let records = try await store.memoryItemRecords(
      ids: ids.compactMap { UUID(uuidString: $0).map(SessionID.init) })
    var texts: [String: (String, Date, String)] = [:]
    for record in records {
      texts[record.sessionID.rawValue.uuidString.uppercased()] = (
        MemoryHistoryBuilder.shownText(record), record.startedAt,
        MemoryItemSource.words(record).word
      )
    }
    var lines: [[String: Any]] = []
    for query in set.queries {
      let judged = query.gains
      for id in pooled[query.id] ?? [] {
        let entry = texts[id]
        lines.append([
          "query": query.id, "id": id, "judged": judged[id] ?? -1,
          "date": entry.map { ISO8601DateFormatter().string(from: $0.1) } ?? "",
          "source": entry?.2 ?? "", "text": entry?.0 ?? "",
        ])
      }
    }
    let data = try JSONSerialization.data(withJSONObject: lines, options: [.sortedKeys])
    try data.write(to: out)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out.path)
    print("pool: \(lines.count) query-record pairs, \(ids.count) records")
  }

  /// Checks a model loads and orders an obvious case right (synthetic text).
  static func probe(_ arguments: Arguments) async throws {
    let start = Date()
    let embedder = try embedder(arguments)
    _ = try await embedder.embed(["预热"], role: .document)
    print(String(format: "load %.2f s", Date().timeIntervalSince(start)))
    let documents = [
      "明天下午三点在实验室开组会，讨论机械臂抓取实验。", "我想买一台新的笔记本电脑，预算一万左右。",
      "The robot arm failed to pick up the cup during the grasping test.", "周末去海边玩，记得带防晒霜。",
    ]
    let queries = ["机器人抓取杯子的实验", "买电脑", "beach trip sunscreen", "grasp experiment meeting"]
    let d = try await embedder.embed(documents, role: .document)
    let q = try await embedder.embed(queries, role: .query)
    for (index, vector) in q.enumerated() {
      let scores = d.map { doc in zip(doc, vector).map { $0 * $1 }.reduce(0, +) }
      print(
        "q\(index): " + scores.map { String(format: "%.3f", $0) }.joined(separator: " ")
          + "  best d\(scores.firstIndex(of: scores.max()!)!)")
    }
    let timed = Date()
    for _ in 0..<20 { _ = try await embedder.embed(["上周跟老师聊的实习"], role: .query) }
    print(String(format: "query p-avg %.1f ms", Date().timeIntervalSince(timed) * 50))
  }

  // MARK: - Memory

  /// The process's peak physical footprint.
  static func processPeakBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return UInt64(max(0, info.ledger_phys_footprint_peak))
  }

  struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }
}
