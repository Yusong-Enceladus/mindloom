import BestASRAudioJournalProbe
import Darwin
import Foundation

/// Replaces a sealed session's journal as one step.
///
/// Compaction (16 kHz) and archival (Opus) both rewrite every chunk of a
/// recording, its manifest, its commit log and its capture metadata. Doing
/// that file by file inside the live journal leaves windows where the
/// manifest and the commit log disagree; the log is replayed into the
/// manifest on every open, so a crash in such a window would publish the old
/// and the new chunks together (the recording would play twice). So the new
/// journal is built complete in `journal.rewrite` next to the live one,
/// opened and checked there, and the two directories are exchanged with
/// `renamex_np(RENAME_SWAP)`, which the file system does atomically. The old
/// journal then sits in `journal.rewrite` and is removed.
///
/// Every crash leaves either the old journal or the new one live, never a
/// mixture, and `journal.rewrite` is at all times disposable: before the
/// exchange it holds an unfinished copy, after it the recording that was
/// replaced by a verified one. `discardLeftover` removes it.
/// A rewrite built and checked beside a live journal (`finishStaging`), not
/// yet exchanged with it. The owner of the journal decides when: the swap
/// and forgetting what it cached about the session happen together, with no
/// read of the session in between (`ProductionAudioJournal`).
public struct StagedJournalRewrite: Equatable, Sendable {
  public let staging: URL
  public let journalRoot: URL

  /// Exchanges the staged journal with the live one; on failure the staged
  /// copy is discarded and the live journal stays as it was.
  public func commit(fileManager: FileManager = .default) throws {
    do {
      try JournalRewrite.commit(
        staging: staging, journalRoot: journalRoot, fileManager: fileManager)
    } catch {
      discard(fileManager: fileManager)
      throw error
    }
  }

  /// Leaves the live journal as it is and removes the staged copy.
  public func discard(fileManager: FileManager = .default) {
    JournalRewrite.discardLeftover(journalRoot: journalRoot, fileManager: fileManager)
  }
}

public enum JournalRewrite {
  public static let stagingName = "journal.rewrite"

  public enum Failure: Error, Equatable, Sendable {
    case cannotSwap(Int32)
    case stagedJournalInvalid
  }

  public static func stagingURL(for journalRoot: URL) -> URL {
    journalRoot.deletingLastPathComponent().appendingPathComponent(
      stagingName, isDirectory: true)
  }

  /// Removes what an interrupted rewrite left beside `journalRoot`.
  public static func discardLeftover(journalRoot: URL, fileManager: FileManager = .default) {
    let staging = stagingURL(for: journalRoot)
    if fileManager.fileExists(atPath: staging.path) {
      try? fileManager.removeItem(at: staging)
    }
  }

  /// A fresh, empty journal directory to build the replacement in.
  static func prepareStaging(journalRoot: URL, fileManager: FileManager) throws -> URL {
    discardLeftover(journalRoot: journalRoot, fileManager: fileManager)
    let staging = stagingURL(for: journalRoot)
    for name in ["chunks", "staging", "quarantine"] {
      try fileManager.createDirectory(
        at: staging.appendingPathComponent(name, isDirectory: true),
        withIntermediateDirectories: true)
    }
    return staging
  }

  /// Writes the manifest, commit log and capture metadata of the staged
  /// journal, carries over what the live one keeps besides its chunks
  /// (anything quarantined by an earlier recovery stays with the session),
  /// and checks that the staged journal opens with exactly `entries`, every
  /// file present and matching its digest.
  static func finishStaging(
    _ staging: URL,
    liveJournal: URL,
    manifest: AudioJournalManifest,
    metadata: ProductionAudioJournalMetadata,
    fileManager: FileManager
  ) throws {
    let pretty = JSONEncoder()
    pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try ProductionDurableFileIO.atomicWrite(
      pretty.encode(manifest), to: staging.appendingPathComponent("manifest.json"))
    let compact = JSONEncoder()
    compact.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var log = Data()
    for entry in manifest.committedChunks {
      log.append(try compact.encode(entry))
      log.append(0x0A)
    }
    try ProductionDurableFileIO.atomicWrite(
      log, to: staging.appendingPathComponent("commits.jsonl"))
    try ProductionDurableFileIO.atomicWrite(
      pretty.encode(metadata), to: staging.appendingPathComponent("production-metadata.json"))
    let quarantine = liveJournal.appendingPathComponent("quarantine", isDirectory: true)
    for name in (try? fileManager.contentsOfDirectory(atPath: quarantine.path)) ?? [] {
      try fileManager.linkItem(
        at: quarantine.appendingPathComponent(name),
        to: staging.appendingPathComponent("quarantine/\(name)"))
    }
    let reopened = try AudioJournal.open(at: staging)
    guard reopened.manifest.committedChunks == manifest.committedChunks else {
      throw Failure.stagedJournalInvalid
    }
    for entry in manifest.committedChunks {
      let url = staging.appendingPathComponent(entry.relativePath)
      guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
        UInt64(data.count) == entry.byteCount,
        RetainedAudioCodec.digest(data) == entry.contentDigest
      else { throw Failure.stagedJournalInvalid }
    }
  }

  /// Exchanges the staged journal with the live one and removes the old one.
  static func commit(staging: URL, journalRoot: URL, fileManager: FileManager) throws {
    let result = staging.path.withCString { source in
      journalRoot.path.withCString { target in
        renamex_np(source, target, UInt32(RENAME_SWAP))
      }
    }
    guard result == 0 else { throw Failure.cannotSwap(errno) }
    let parent = journalRoot.deletingLastPathComponent()
    let descriptor = parent.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
    if descriptor >= 0 {
      _ = Darwin.fsync(descriptor)
      Darwin.close(descriptor)
    }
    // `staging` now holds the journal that was replaced.
    try? fileManager.removeItem(at: staging)
  }
}
