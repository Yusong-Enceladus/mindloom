import BestASRMemory
import BestASRMemoryUI
import Foundation

/// The undo window's journal (v11: a held correction survives a crash). One
/// small JSON file in the library, `held-corrections.json` (0600), rewritten
/// atomically on every change: a held correction is written when it is
/// made, and removed when it is undone or its send is durable. What a
/// crashed run left is sent at the next launch (`replayLeftovers`). It holds
/// only the correction itself (IDs and the titles the user typed) and never
/// leaves this Mac.
@MainActor
final class HeldCorrectionsFile: MemoryCorrectionJournal {
  struct Row: Codable, Equatable {
    var id: UUID
    var correction: MemoryCorrection
    var releaseAt: Date
  }

  private let url: URL
  private var rows: [Row]
  /// The rows found at launch (a previous run's), handed out once.
  private var found: [Row]

  init(dataRoot: URL) {
    url = dataRoot.appendingPathComponent("held-corrections.json")
    let loaded = (try? Data(contentsOf: url)).flatMap {
      try? JSONDecoder().decode([Row].self, from: $0)
    } ?? []
    rows = loaded
    found = loaded
  }

  func record(_ id: UUID, _ correction: MemoryCorrection, releaseAt: Date) {
    rows.append(Row(id: id, correction: correction, releaseAt: releaseAt))
    write()
  }

  func remove(_ id: UUID) {
    let before = rows.count
    rows.removeAll { $0.id == id }
    if rows.count != before { write() }
  }

  func leftovers() -> [(id: UUID, correction: MemoryCorrection, releaseAt: Date)] {
    defer { found = [] }
    return found.sorted { $0.releaseAt < $1.releaseAt }.map { ($0.id, $0.correction, $0.releaseAt) }
  }

  private func write() {
    do {
      if rows.isEmpty {
        if FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.removeItem(at: url)
        }
        return
      }
      let data = try JSONEncoder().encode(rows)
      try data.write(to: url, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      // The correction is still held in memory and committed on quit.
    }
  }
}
