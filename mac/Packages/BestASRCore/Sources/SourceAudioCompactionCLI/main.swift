import BestASRAudioJournal
import BestASRAudioJournalProbe
import BestASRDictation
import BestASRDomain
import BestASRPersistence
import Foundation

/// Rewrites finished recordings in the format everything already reads them
/// in — 16 kHz mono 16-bit — and points the index and transcript provenance at
/// the result. See `SourceAudioCompaction` for why, and for what it refuses to
/// touch. Only aggregates are printed; no transcript or audio leaves the Mac.
///
/// Usage: SourceAudioCompactionCLI --assets dir --store history.sqlite
///   [--session uuid] [--limit n] [--dry-run]
@main
enum SourceAudioCompactionCLI {
  static func main() async {
    do { try await run(Arguments(CommandLine.arguments.dropFirst())) } catch {
      FileHandle.standardError.write(Data("error: \(error)\n".utf8))
      exit(1)
    }
  }

  struct Arguments {
    var assets: URL
    var store: URL
    var session: SessionID?
    var limit: Int?
    var dryRun = false
    /// An assets directory holding the recordings as they were before
    /// compaction; with it, this puts them back instead of rewriting them.
    var restoreFrom: URL?

    init(_ arguments: some Sequence<String>) {
      var assets: URL?
      var store: URL?
      var iterator = arguments.makeIterator()
      while let argument = iterator.next() {
        switch argument {
        case "--assets": assets = iterator.next().map { URL(fileURLWithPath: $0) }
        case "--store": store = iterator.next().map { URL(fileURLWithPath: $0) }
        case "--session": session = iterator.next().flatMap(UUID.init(uuidString:)).map(SessionID.init)
        case "--limit": limit = iterator.next().flatMap(Int.init)
        case "--dry-run": dryRun = true
        case "--restore-from": restoreFrom = iterator.next().map { URL(fileURLWithPath: $0) }
        default: continue
        }
      }
      guard let assets, let store else {
        FileHandle.standardError.write(Data("usage: --assets dir --store db\n".utf8))
        exit(64)
      }
      self.assets = assets
      self.store = store
    }
  }

  static func run(_ arguments: Arguments) async throws {
    let store = try GRDBDictationStore(databaseURL: arguments.store)
    if let backup = arguments.restoreFrom {
      try await restore(arguments, from: backup, store: store)
      return
    }
    let sessions = try arguments.session.map { [$0] } ?? recorded(under: arguments.assets)
    var before: UInt64 = 0
    var after: UInt64 = 0
    var compacted = 0
    var skipped = 0
    var failed = 0
    for sessionID in arguments.limit.map { Array(sessions.prefix($0)) } ?? sessions {
      do {
        let outcome = try await SourceAudioCompaction.compact(
          sessionID: sessionID,
          assetRoot: arguments.assets,
          dryRun: arguments.dryRun
        )
        before += outcome.originalByteCount
        after += outcome.compactedByteCount
        guard !outcome.alreadyCompact else {
          skipped += 1
          continue
        }
        if !arguments.dryRun {
          try await store.applySourceAudioCompaction(
            sessionID: sessionID,
            tracks: outcome.tracks,
            chunks: outcome.runs.map(record(_:))
          )
        }
        compacted += 1
        if compacted % 25 == 0 { print("  \(compacted) rewritten") }
      } catch SourceAudioCompactionError.sessionNotSealed {
        skipped += 1
      } catch {
        failed += 1
        if failed <= 5 {
          FileHandle.standardError.write(
            Data("  \(sessionID.rawValue.uuidString.prefix(8)): \(error)\n".utf8))
        }
      }
    }
    let saved = before > after ? before - after : 0
    print(
      """
      compaction\(arguments.dryRun ? " (dry run)" : ""): \
      \(compacted) rewritten, \(skipped) already compact or unsealed, \(failed) failed
      audio \(megabytes(before)) MB -> \(megabytes(after)) MB, \(megabytes(saved)) MB reclaimed
      """
    )
  }

  /// Puts a session's recording back the way it was and points the index at it
  /// again.
  ///
  /// Compaction cannot be undone from what it leaves behind, so the only way
  /// back is the copy taken before it ran. Re-indexing is the same operation
  /// as compaction — replace this session's chunks and move the transcript
  /// provenance onto them — so it runs through the same store call.
  static func restore(
    _ arguments: Arguments, from backup: URL, store: GRDBDictationStore
  ) async throws {
    let sessions = try arguments.session.map { [$0] } ?? recorded(under: backup)
    var restored = 0
    var skipped = 0
    for sessionID in sessions {
      let value = sessionID.rawValue.uuidString.lowercased()
      let source = backup.appendingPathComponent("sessions/\(value)/journal", isDirectory: true)
      let destination = arguments.assets.appendingPathComponent(
        "sessions/\(value)/journal", isDirectory: true)
      guard FileManager.default.fileExists(
        atPath: source.appendingPathComponent("manifest.json").path)
      else {
        skipped += 1
        continue
      }
      let metadata = try JSONDecoder().decode(
        ProductionAudioJournalMetadata.self,
        from: Data(contentsOf: source.appendingPathComponent("production-metadata.json")))
      let manifest = try JSONDecoder().decode(
        AudioJournalManifest.self,
        from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
      let tracks = metadata.trackDescriptors ?? []
      guard !tracks.isEmpty, !manifest.committedChunks.isEmpty else {
        skipped += 1
        continue
      }
      guard !arguments.dryRun else {
        print("  would restore \(value.prefix(8)): \(manifest.committedChunks.count) chunks")
        restored += 1
        continue
      }
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: source, to: destination)
      let prefix = "sessions/\(value)/journal/"
      try await store.applySourceAudioCompaction(
        sessionID: sessionID,
        tracks: tracks,
        chunks: manifest.committedChunks.map { entry in
          let duration = UInt64(
            (Double(entry.frameCount) * 1_000_000_000 / Double(entry.sampleRateHertz)).rounded())
          return CompactedAudioChunkRecord(
            trackID: TrackID(UUID(uuidString: entry.trackID) ?? UUID()),
            sequence: entry.sequence,
            assetReference: prefix + entry.relativePath,
            monotonicStartNanoseconds: entry.monotonicStartNanoseconds,
            monotonicEndNanoseconds: entry.monotonicStartNanoseconds + max(1, duration),
            frameCount: entry.frameCount,
            digest: entry.contentDigest,
            sampleRateHertz: entry.sampleRateHertz,
            channelCount: tracks.first(where: { $0.id.rawValue.uuidString == entry.trackID })?
              .channelCount ?? 1
          )
        }
      )
      restored += 1
    }
    print("restore\(arguments.dryRun ? " (dry run)" : ""): \(restored) restored, \(skipped) skipped")
  }

  /// Every session that has a journal on disk, oldest first so a partial run
  /// makes progress from the end that has been sitting there longest.
  static func recorded(under assetRoot: URL) throws -> [SessionID] {
    let sessions = assetRoot.appendingPathComponent("sessions", isDirectory: true)
    let contents = try FileManager.default.contentsOfDirectory(
      at: sessions, includingPropertiesForKeys: [.contentModificationDateKey])
    return
      contents
      .filter {
        FileManager.default.fileExists(
          atPath: $0.appendingPathComponent("journal/manifest.json").path)
      }
      .sorted {
        let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        return left < right
      }
      .compactMap { UUID(uuidString: $0.lastPathComponent).map(SessionID.init) }
  }

  static func record(_ run: CompactedSourceAudioRun) -> CompactedAudioChunkRecord {
    CompactedAudioChunkRecord(
      trackID: run.trackID,
      sequence: run.sequence,
      assetReference: run.assetReference,
      monotonicStartNanoseconds: run.monotonicStartNanoseconds,
      monotonicEndNanoseconds: run.monotonicEndNanoseconds,
      frameCount: run.frameCount,
      digest: run.contentDigest,
      sampleRateHertz: SourceAudioCompaction.sampleRateHertz,
      channelCount: SourceAudioCompaction.channelCount
    )
  }

  static func megabytes(_ bytes: UInt64) -> String {
    String(format: "%.1f", Double(bytes) / 1_048_576)
  }
}
