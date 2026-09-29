import Foundation

/// What a kept scenario work directory (`BESTASR_E2E_WORK_DIR`) has taken in,
/// so a rerun against the same organizing device continues with the same
/// items instead of sending new copies of them.
///
/// JSON Lines, appended as the run goes (a killed run loses at most the line
/// being written): a header naming the scenario, then one line per item
/// taken in (`ref`, local item ID, when), one per item first seen organized,
/// and one per item forgotten (to be taken in again). Only fixture labels,
/// IDs and times; never item contents.
struct ScenarioLedger {
  struct Entry: Equatable {
    let ref: String
    let id: String
    let ingestedAt: Date
    var organizedAt: Date?
  }

  let url: URL
  let scenario: String
  /// In the order the items were taken in.
  private(set) var entries: [Entry] = []

  /// Opens (or starts) the ledger at `url`. Throws when it belongs to a
  /// different scenario, so two scenarios never share one work directory.
  init(url: URL, scenario: String) throws {
    self.url = url
    self.scenario = scenario
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else {
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Self.line(["scenario": scenario]).write(to: url, options: .atomic)
      return
    }
    let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    var index: [String: Int] = [:]
    for (number, line) in text.split(whereSeparator: \.isNewline).enumerated() {
      // A torn last line (killed mid-write) is ignored.
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      else { continue }
      if number == 0 || object["scenario"] != nil {
        if let named = object["scenario"] as? String, named != scenario {
          throw SparkEndToEndTests.EndToEndError(
            "the work directory holds scenario \(named), not \(scenario); use a new one")
        }
        continue
      }
      guard let ref = object["ref"] as? String else { continue }
      if object["forget"] as? Bool == true {
        if let position = index.removeValue(forKey: ref) {
          entries.remove(at: position)
          index = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.ref, $0) })
        }
      } else if let id = object["id"] as? String, let at = object["ingested_at"] as? Double {
        let entry = Entry(ref: ref, id: id, ingestedAt: Date(timeIntervalSince1970: at))
        if let position = index[ref] {
          entries[position] = entry
        } else {
          index[ref] = entries.count
          entries.append(entry)
        }
      } else if let at = object["organized_at"] as? Double, let position = index[ref],
        entries[position].organizedAt == nil
      {
        entries[position].organizedAt = Date(timeIntervalSince1970: at)
      }
    }
  }

  mutating func recordIngested(ref: String, id: String, at date: Date) throws {
    try append([["ref": ref, "id": id, "ingested_at": date.timeIntervalSince1970]])
    entries.removeAll { $0.ref == ref }
    entries.append(Entry(ref: ref, id: id, ingestedAt: date))
  }

  mutating func recordOrganized(_ organized: [(ref: String, at: Date)]) throws {
    guard !organized.isEmpty else { return }
    try append(organized.map { ["ref": $0.ref, "organized_at": $0.at.timeIntervalSince1970] })
    for (ref, at) in organized {
      if let position = entries.firstIndex(where: { $0.ref == ref }),
        entries[position].organizedAt == nil
      {
        entries[position].organizedAt = at
      }
    }
  }

  /// Items the Mac will never send again (their link rows were revoked
  /// before delivery): the next run takes them in anew.
  mutating func forget(_ refs: [String]) throws {
    guard !refs.isEmpty else { return }
    try append(refs.map { ["ref": $0, "forget": true] })
    let forgotten = Set(refs)
    entries.removeAll { forgotten.contains($0.ref) }
  }

  private func append(_ objects: [[String: Any]]) throws {
    var data = Data()
    for object in objects { data.append(try Self.line(object)) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  private static func line(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    data.append(0x0A)
    return data
  }
}
