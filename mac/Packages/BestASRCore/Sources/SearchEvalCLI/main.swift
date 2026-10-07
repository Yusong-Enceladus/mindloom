import BestASRDomain
import BestASRMemory
import BestASRPersistence
import Foundation

/// Scores search on a synthetic library against a versioned query set
/// (B4 §4.1; set: `Corpus/product-synthetic/search-demo-v1.json`, made by
/// `Tools/SearchEval/make_demo_set.py`).
///
///     SearchEvalCLI --root <a clone of the demo root> \
///       --set Corpus/product-synthetic/search-demo-v1.json [--engine before|after|both] \
///       [--out results.json] [--misses]
///
/// `before` is the full-text query the history used until v12 (the whole
/// query as one phrase, two characters or fewer by LIKE, newest first);
/// `after` is the record search (one MATCH by relevance, query reading).
/// Metrics: recall@10 = relevant records in the top 10 / min(10, relevant);
/// MRR = 1 / rank of the first relevant record (0 past 100). Prints numbers
/// and query words only, never record text.
///
/// Opens only a root marked SYNTHETIC_DATA_ROOT, never the canonical demo
/// root itself and never a real library; the clone gets the derived search
/// index written into it.
@main
struct SearchEvalCLI {
  struct QuerySet: Decodable {
    struct Query: Decodable {
      let id: String
      let category: String
      let query: String
      let relevant: [String]
    }

    struct Lexicon: Decodable {
      let canonical: String
      let spoken: [String]
    }

    let now: String
    let ownerNames: [String]
    let lexicon: [Lexicon]
    let queries: [Query]

    enum CodingKeys: String, CodingKey {
      case now, lexicon, queries
      case ownerNames = "owner_names"
    }
  }

  struct Score: Encodable {
    let id: String
    let category: String
    let recall10: Double
    let reciprocalRank: Double
    let returned: Int
    let milliseconds: Double
  }

  static let canonicalDemoRoot = "/Users/Shared/mindloom-demo/v11/env/preview-root"

  static func main() async {
    do {
      try await run()
    } catch {
      FileHandle.standardError.write(Data("search eval: \(error)\n".utf8))
      exit(1)
    }
  }

  static func value(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
  }

  static func run() async throws {
    guard let rootPath = value("--root"), let setPath = value("--set") else {
      print(
        "usage: SearchEvalCLI --root <synthetic clone> --set <query set> [--engine before|after|both] [--out file] [--misses]"
      )
      exit(64)
    }
    let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
    let library = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Mindloom").path
    guard !root.path.hasPrefix(library) else {
      throw CLIError("refusing a real library: \(root.path)")
    }
    guard root.path != URL(fileURLWithPath: canonicalDemoRoot).resolvingSymlinksInPath().path else {
      throw CLIError("refusing the canonical demo root; clone it with cp -c -R first")
    }
    guard
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("SYNTHETIC_DATA_ROOT").path)
    else { throw CLIError("refusing a root without SYNTHETIC_DATA_ROOT") }
    let set = try JSONDecoder().decode(
      QuerySet.self, from: Data(contentsOf: URL(fileURLWithPath: setPath)))
    guard let now = ISO8601DateFormatter().date(from: set.now) else { throw CLIError("bad now") }
    let engines: [String] =
      switch value("--engine") ?? "both" {
      case "before": ["before"]
      case "after": ["after"]
      default: ["before", "after"]
      }

    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    let started = Date()
    let sync = try await store.syncRecordSearchIndex()
    print(
      "index: \(sync.indexed) indexed, \(sync.unchanged) unchanged in "
        + String(format: "%.2f s", Date().timeIntervalSince(started)))
    let context = SearchContext(
      people: try await store.recordSearchPeople(), ownerNames: Set(set.ownerNames),
      lexicon: set.lexicon.map { SearchLexiconEntry(canonical: $0.canonical, spoken: $0.spoken) },
      sourceNames: try await store.recordSourceNames(), clock: SearchClock(now: now))

    var report: [String: [Score]] = [:]
    for engine in engines {
      var scores: [Score] = []
      for query in set.queries {
        let start = Date()
        let ranked: [String]
        if engine == "before" {
          ranked = try await store.searchHistory(
            query: query.query, mode: nil, status: nil, limit: 100
          ).map { $0.sessionID.rawValue.uuidString.uppercased() }
        } else {
          let parsed = SearchQueryParser.parse(query.query, context: context)
          ranked = try await store.searchRecords(parsed, limit: 100, now: now).hits
            .map { $0.sessionID.rawValue.uuidString.uppercased() }
        }
        let elapsed = Date().timeIntervalSince(start) * 1000
        let relevant = Set(query.relevant.map { $0.uppercased() })
        let top = ranked.prefix(10).filter(relevant.contains).count
        let recall = Double(top) / Double(min(10, relevant.count))
        let rank = ranked.prefix(100).firstIndex(where: relevant.contains).map { $0 + 1 }
        scores.append(
          Score(
            id: query.id, category: query.category, recall10: recall,
            reciprocalRank: rank.map { 1 / Double($0) } ?? 0, returned: ranked.count,
            milliseconds: elapsed))
      }
      report[engine] = scores
    }

    let categories = set.queries.map(\.category).reduce(into: [String]()) {
      if !$0.contains($1) { $0.append($1) }
    }
    func line(_ name: String, _ scores: [Score]) -> String {
      let n = Double(max(1, scores.count))
      let recall = scores.map(\.recall10).reduce(0, +) / n
      let mrr = scores.map(\.reciprocalRank).reduce(0, +) / n
      let empty = scores.filter { $0.returned == 0 }.count
      return String(
        format: "%-10@ %3d   R@10 %.3f   MRR %.3f   empty %3d", name as NSString, scores.count,
        recall,
        mrr, empty)
    }
    for engine in engines {
      guard let scores = report[engine] else { continue }
      let times = scores.map(\.milliseconds).sorted()
      print(
        "\n== \(engine): p50 \(String(format: "%.1f", times[times.count / 2])) ms, p95 "
          + "\(String(format: "%.1f", times[min(times.count - 1, times.count * 95 / 100)])) ms")
      for category in categories {
        print(line(category, scores.filter { $0.category == category }))
      }
      print(line("all", scores))
    }
    if CommandLine.arguments.contains("--misses"), let after = report["after"] {
      print("\nafter, below 1.0 recall@10:")
      for score in after where score.recall10 < 1 {
        let query = set.queries.first { $0.id == score.id }!
        print(
          "  \(score.id) 「\(query.query)」 R@10 \(String(format: "%.2f", score.recall10)) RR "
            + "\(String(format: "%.2f", score.reciprocalRank)) returned \(score.returned)")
      }
    }
    if let out = value("--out") {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(report).write(to: URL(fileURLWithPath: out))
    }
  }

  struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }
}
