import BestASRDomain
import BestASRPersistence
import BestASRSpeakerRouting
import Foundation
import GRDB

/// Re-links the people the speaker model already found, under the thresholds
/// that were measured rather than guessed.
///
/// The App matched every session against stored people at cosine 0.93, which
/// this model's embeddings never reach, so one voice recorded over months
/// became dozens of anonymous strangers. `SpeakerRoutingPolicy.local()` now
/// carries the measured numbers; this applies the same rule to the history
/// that was recorded under the old one, by merging the groups that are the
/// same voice through the store's own merge. Nothing is deleted: a merged
/// person keeps its row, marked as merged into the one that remains.
///
/// Usage: SpeakerRelinkCLI --store history.sqlite [--threshold 0.70] [--dry-run]
@main
enum SpeakerRelinkCLI {
  static func main() async {
    do { try await run(Arguments(CommandLine.arguments.dropFirst())) } catch {
      FileHandle.standardError.write(Data("error: \(error)\n".utf8))
      exit(1)
    }
  }

  struct Arguments {
    var store: URL
    var threshold: Double
    var dryRun = false

    init(_ arguments: some Sequence<String>) {
      var store: URL?
      var threshold: Double?
      var dryRun = false
      var iterator = arguments.makeIterator()
      while let argument = iterator.next() {
        switch argument {
        case "--store": store = iterator.next().map { URL(fileURLWithPath: $0) }
        case "--threshold": threshold = iterator.next().flatMap(Double.init)
        case "--dry-run": dryRun = true
        default: continue
        }
      }
      guard let store else {
        FileHandle.standardError.write(Data("usage: --store history.sqlite\n".utf8))
        exit(64)
      }
      self.store = store
      self.threshold =
        threshold ?? ((try? SpeakerRoutingPolicy.local().automaticMatchThreshold.value) ?? 0.70)
      self.dryRun = dryRun
    }
  }

  struct Speaker {
    let personID: PersonID
    let vector: [Double]
    let createdAt: Double
  }

  static func run(_ arguments: Arguments) async throws {
    let speakers = try read(arguments.store)
    guard !speakers.isEmpty else {
      print("speaker relink: nothing recorded yet")
      return
    }
    let clusters = cluster(speakers, threshold: arguments.threshold)
    let before = Set(speakers.map(\.personID)).count
    let after = clusters.count
    print(
      "speaker relink: \(speakers.count) session speakers, \(before) people -> "
        + "\(after) at threshold \(String(format: "%.2f", arguments.threshold))"
    )
    for (index, cluster) in clusters.sorted(by: { $0.count > $1.count }).prefix(5).enumerated() {
      print("  group \(index + 1): \(cluster.count) session speakers, \(Set(cluster.map(\.personID)).count) people")
    }
    guard !arguments.dryRun else { return }

    let store = try GRDBDictationStore(databaseURL: arguments.store)
    let device = UUID()
    var merged = 0
    var failed = 0
    // One person can have sessions in more than one group, so decide where
    // each belongs before merging any of them: a person merged twice is a
    // person merged into someone already retired.
    var homeByPerson: [PersonID: (cluster: Int, count: Int)] = [:]
    var countsByCluster: [Int: [PersonID: Int]] = [:]
    for (index, cluster) in clusters.enumerated() {
      var counts: [PersonID: Int] = [:]
      for speaker in cluster { counts[speaker.personID, default: 0] += 1 }
      countsByCluster[index] = counts
      for (personID, count) in counts
      where count > (homeByPerson[personID]?.count ?? 0) {
        homeByPerson[personID] = (index, count)
      }
    }
    for (index, counts) in countsByCluster.sorted(by: { $0.key < $1.key }) {
      let members = counts.keys.filter { homeByPerson[$0]?.cluster == index }
      guard members.count > 1,
        let primary = members.max(by: {
          (counts[$0] ?? 0, $0.rawValue.uuidString) < (counts[$1] ?? 0, $1.rawValue.uuidString)
        })
      else { continue }
      for personID in members where personID != primary {
        do {
          try await store.mergePersons(
            primaryID: primary, mergedID: personID, originDeviceID: device)
          merged += 1
        } catch {
          failed += 1
          if failed <= 3 {
            FileHandle.standardError.write(Data("  merge failed: \(error)\n".utf8))
          }
        }
      }
    }
    print("speaker relink: merged \(merged) people away, \(failed) failed")
  }

  /// Every session speaker that carries an embedding, oldest first, because
  /// matching is incremental: a session is compared against what was known
  /// when it was recorded.
  static func read(_ url: URL) throws -> [Speaker] {
    var configuration = Configuration()
    configuration.readonly = true
    let queue = try DatabaseQueue(path: url.path, configuration: configuration)
    return try queue.read { database in
      try Row.fetchAll(
        database,
        sql: """
          SELECT e.vector_json AS vector_json, o.person_id AS person_id,
                 s.created_at AS created_at
          FROM session_speaker_embeddings e
          JOIN speaker_occurrences o ON o.session_speaker_id = e.session_speaker_id
          JOIN sessions s ON s.id = o.session_id
          JOIN persons p ON p.id = o.person_id AND p.retired_at IS NULL
          GROUP BY e.session_speaker_id
          ORDER BY s.created_at
          """
      ).compactMap { row in
        guard let data: Data = row["vector_json"],
          let raw = try? JSONDecoder().decode([Double].self, from: data),
          let value: String = row["person_id"], let uuid = UUID(uuidString: value)
        else { return nil }
        let norm = raw.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return nil }
        return Speaker(
          personID: PersonID(uuid),
          vector: raw.map { $0 / norm },
          createdAt: row["created_at"] ?? 0
        )
      }
    }
  }

  /// The same incremental rule the App applies while recording: compare with
  /// everything already known, join the closest above the threshold, otherwise
  /// start a new person.
  static func cluster(_ speakers: [Speaker], threshold: Double) -> [[Speaker]] {
    var clusters: [[Speaker]] = []
    for speaker in speakers {
      var best = -1.0
      var bestIndex: Int?
      for (index, cluster) in clusters.enumerated() {
        let similarity = cluster.map { dot($0.vector, speaker.vector) }.max() ?? -1
        if similarity > best {
          best = similarity
          bestIndex = index
        }
      }
      if let bestIndex, best >= threshold {
        clusters[bestIndex].append(speaker)
      } else {
        clusters.append([speaker])
      }
    }
    return clusters
  }

  static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
    guard lhs.count == rhs.count else { return 0 }
    return zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
  }
}
