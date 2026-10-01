import BestASRDomain
import Darwin
import Foundation
import MindloomSpaces

/// Masks a maintainer's title with a space's mask key before it reaches the
/// space organizer: the same masking every organizing payload of a space
/// gets, so the Spark sees placeholders, never the numbers (review V7-S13).
public struct SpaceTitleMasker: SpaceTextMasking {
  public init() {}

  public func mask(_ text: String, maskKey: Data) throws -> String {
    let (masked, _) = try PrivacyMasker(maskKey: maskKey).maskWithSpans(text)
    return masked
  }
}

/// Where an original opened from a space is written for the app that shows
/// it: `<tmp>/mindloom-space-originals/<launch>/<space>/<item>/<blob>.<ext>`
/// (folders 0700, files 0600). Everything an earlier launch left is deleted
/// at launch and at quit, and an item's files go as soon as the item leaves
/// the space or this Mac's access ends (review V7-S11). Honest limit: a copy
/// the viewer app saved elsewhere is out of reach.
public struct SpaceOriginalsFolder: Sendable {
  public let root: URL
  public let launch: String

  public init(
    root: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mindloom-space-originals", isDirectory: true),
    launch: String = UUID().uuidString.lowercased()
  ) {
    self.root = root.standardizedFileURL
    self.launch = launch
  }

  private var session: URL { root.appendingPathComponent(launch, isDirectory: true) }

  /// Removes every original any launch wrote.
  public func purgeAll() {
    try? FileManager.default.removeItem(at: root)
  }

  /// Writes one decrypted original and returns its file.
  public func write(_ data: Data, space: String, item: String, blob: String, ext: String) throws
    -> URL
  {
    let parts = [space, item, blob].map { $0.lowercased() }
    guard parts.allSatisfy(SpaceID.isValid) else { throw CocoaError(.fileWriteInvalidFileName) }
    let safeExt = String(ext.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
    let folder = session.appendingPathComponent(parts[0], isDirectory: true)
      .appendingPathComponent(parts[1], isDirectory: true)
    for url in [root, session, session.appendingPathComponent(parts[0], isDirectory: true), folder]
    {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      chmod(url.path, 0o700)
    }
    let url = folder.appendingPathComponent(parts[2] + (safeExt.isEmpty ? "" : ".\(safeExt)"))
    try data.write(to: url, options: [.atomic, .completeFileProtection])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
  }

  /// Deletes the originals of every (space, item) `keep` turns down: the item
  /// was withdrawn, removed or taken down, or access to the space ended.
  public func prune(keep: (_ space: String, _ item: String) -> Bool) {
    let manager = FileManager.default
    guard let spaces = try? manager.contentsOfDirectory(atPath: session.path) else { return }
    for space in spaces {
      let spaceURL = session.appendingPathComponent(space, isDirectory: true)
      let items = (try? manager.contentsOfDirectory(atPath: spaceURL.path)) ?? []
      for item in items where !keep(space, item) {
        try? manager.removeItem(at: spaceURL.appendingPathComponent(item, isDirectory: true))
      }
      if (try? manager.contentsOfDirectory(atPath: spaceURL.path))?.isEmpty ?? true {
        try? manager.removeItem(at: spaceURL)
      }
    }
  }

  /// Every original file currently written (tests).
  public func files() -> [URL] {
    guard
      let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [] }
    return walker.compactMap { $0 as? URL }.filter {
      (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
  }
}
