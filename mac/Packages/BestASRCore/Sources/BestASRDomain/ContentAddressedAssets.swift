import Darwin
import Foundation

/// Identical file bytes taken in twice are stored once (privacy contract
/// §7). Every item keeps its own path (`sessions/<id>/source/…`), but when
/// the bytes are already in the library that path is a hard link to the
/// same file, found through a content index `content/<aa>/<sha256>` that is
/// itself a link. The file system counts the references: deleting an item
/// removes one link, and the bytes go when the last item holding them is
/// deleted and `prune` drops the index entry nobody else links to.
public enum ContentAddressedAssets {
  public static let directoryName = "content"

  public static func anchor(assetRoot: URL, digest: String) -> URL? {
    let lowered = digest.lowercased()
    guard lowered.count == 64, lowered.allSatisfy({ $0.isHexDigit }) else { return nil }
    return assetRoot.appendingPathComponent(directoryName, isDirectory: true)
      .appendingPathComponent(String(lowered.prefix(2)), isDirectory: true)
      .appendingPathComponent(lowered)
  }

  /// Links `destination` (which must not exist) to the library's copy of
  /// `data` when there is one with exactly these bytes. Returns false when
  /// there is none; the caller then writes the bytes and calls `register`.
  public static func linkExisting(
    assetRoot: URL, digest: String, data: Data, to destination: URL
  ) -> Bool {
    guard let anchor = anchor(assetRoot: assetRoot, digest: digest) else { return false }
    var entry = stat()
    guard lstat(anchor.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG,
      Int(entry.st_size) == data.count
    else { return false }
    // Byte for byte, not only by name: a damaged copy is never shared.
    let descriptor = open(anchor.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    guard let stored = try? handle.read(upToCount: data.count + 1), stored == data else {
      return false
    }
    return link(anchor.path, destination.path) == 0
  }

  /// Makes `file` (just written, with these bytes) findable for the next
  /// identical intake. Best effort: without it the next copy is simply
  /// written again.
  public static func register(assetRoot: URL, digest: String, file: URL) {
    guard let anchor = anchor(assetRoot: assetRoot, digest: digest) else { return }
    let folder = anchor.deletingLastPathComponent()
    try? FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    _ = link(file.path, anchor.path)
  }

  /// Drops index entries no item links to any more (link count 1), so the
  /// bytes of deleted items do not stay behind. Returns how many were
  /// removed. Call after every deletion and at startup.
  @discardableResult
  public static func prune(assetRoot: URL) -> Int {
    let root = assetRoot.appendingPathComponent(directoryName, isDirectory: true)
    let manager = FileManager.default
    guard let folders = try? manager.contentsOfDirectory(atPath: root.path) else { return 0 }
    var removed = 0
    for folder in folders where folder.count == 2 {
      let folderPath = root.appendingPathComponent(folder).path
      for name in (try? manager.contentsOfDirectory(atPath: folderPath)) ?? [] {
        let path = folderPath + "/" + name
        var entry = stat()
        guard lstat(path, &entry) == 0 else { continue }
        // Anything but a regular file with other links is not an index entry.
        if entry.st_mode & S_IFMT != S_IFREG || entry.st_nlink <= 1 {
          if unlink(path) == 0 { removed += 1 }
        }
      }
      _ = rmdir(folderPath)
    }
    return removed
  }

  /// Total bytes of the files under `directory`, each file (inode) once.
  public static func uniqueBytes(under directory: URL) -> (files: Int, bytes: Int64) {
    var seen = Set<[UInt64]>()
    var bytes: Int64 = 0
    var files = 0
    guard
      let walker = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: nil, options: [])
    else { return (0, 0) }
    for case let url as URL in walker {
      var entry = stat()
      guard lstat(url.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG else { continue }
      files += 1
      if seen.insert([UInt64(entry.st_dev), UInt64(entry.st_ino)]).inserted {
        bytes += Int64(entry.st_size)
      }
    }
    return (files, bytes)
  }
}
