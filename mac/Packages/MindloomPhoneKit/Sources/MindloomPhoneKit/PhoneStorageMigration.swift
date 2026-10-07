import Darwin
import Foundation

/// Moves what a build without the App Group kept in private storage into the App Group container,
/// once, the first time a build with the group starts (IOS-CODE-MAP §3b).
///
/// A free team's device build had no App Group, so:
/// - the app kept `pairing.json`, `keyboard.json`, `outbox/` and `items/` (previews and unsealed
///   payloads included) in its own `Library/Application Support` (`PhoneAppGroup.storageRoot`);
/// - the share extension kept its items and outbox in its own `Library/Application Support/share`
///   (`ShareStore`), and handed summaries of them to the app through the shared keychain
///   (`ShareHandoff`), which the app saved into its own list as mirrors (`sharedOnPhone` set);
/// - the switches lived in the app's standard defaults (`PhoneSettings`).
///
/// The rules:
/// - **Never in neither place.** A file is renamed into the group (`renamex_np` with
///   `RENAME_EXCL`, atomic on one volume). Across volumes it is copied to
///   `<group>/migration-staging-<app|share>/`, renamed into place, and only then removed from the old place.
///   A crash leaves the file in the old place, in both, or (staging only) as a stray copy that the
///   next run discards: the source still exists then.
/// - **Never deleted.** When both places hold a different file at the same path, one copy is the
///   current one and the other is moved to `<group>/migration-conflicts/<app|share>-<time>/<path>`
///   (counted in the report, never removed). Only a byte-for-byte identical old copy is let go (the
///   trace of a crash between rename and removal).
/// - **Which copy is current.** For the single-state files (`pairing.json`, `keyboard.json`) the
///   one modified last: after a round trip group → build without the group → group, a pairing made
///   in between is newer than the group's. For everything else (items, outbox entries) the group's,
///   except that a share mirror in the group (`sharedOnPhone` set) is replaced by the share
///   extension's real item, which carries the outbox entries.
/// - **Once.** A marker `<old place>/app-group-migration.json` is written after a run in which
///   every file was handled; until then each launch retries, and the moves already made are
///   no-ops. The marker sits with the old data, not in the group: a later build without the group
///   (a renewal while Xcode had no Apple ID) writes to the old place again and removes the marker
///   (`forget`), so the next build with the group moves the new files too.
/// - The voice records (`voice/`) are not moved: they are transient (a session never survives an
///   update), and an old final moved into the group could be inserted again by the keyboard.
/// - Nothing is ever read for its content except a share mirror's `shared_on_phone` flag and the
///   equality check, and nothing leaves the phone.
public enum PhoneStorageMigration {
  /// The app's private storage: these entries of its Application Support.
  public static let appEntries = ["pairing.json", "keyboard.json", "outbox", "items"]
  /// The share extension's private storage: these entries of its `Application Support/share`.
  /// Its `pairing.json` is the app's handed-over copy and stays behind.
  public static let shareEntries = ["outbox", "items"]
  /// Files that hold one state each: the copy modified last is the current one.
  static let singleStateEntries: Set<String> = ["pairing.json", "keyboard.json"]
  /// Directories that are never moved: staging for atomic writes and stale send claims.
  static let skippedDirectories: Set<String> = ["tmp", "sending"]

  /// The marker's file name, in the old place.
  public static let markerName = "app-group-migration.json"
  /// Where the copies that lost a conflict are kept, in the group.
  public static let conflictsName = "migration-conflicts"
  /// In the old (standard) defaults, removed again by `forget`.
  public static let settingsMarkerKey = "migration.app_group_settings_v1"
  /// In the old defaults, never removed: the switches went into the group at least once, so a
  /// value found in the old defaults later was written by a build without the group in between
  /// (newer than the group's).
  public static let settingsEverKey = "migration.app_group_settings_ever"

  public struct Report: Codable, Equatable, Sendable {
    /// Files now in the group that were only in the old place.
    public var moved = 0
    /// Share mirrors in the group replaced by the share extension's real item.
    public var replaced = 0
    /// The group's copy stayed current; the different old copy is under `migration-conflicts`.
    public var kept = 0
    /// The old copy of a single-state file was newer and is now current; the group's former copy
    /// is under `migration-conflicts`.
    public var superseded = 0
    /// Old copies removed because the group already had the same bytes.
    public var deduplicated = 0
    /// Files that could not be handled this time (retried next launch; no marker).
    public var failed = 0
    /// The marker was already there: nothing was looked at.
    public var alreadyDone = false

    public init() {}

    /// Copies now kept under `migration-conflicts`.
    public var conflicts: Int { kept + superseded }
  }

  /// The marker of the migration out of `legacy`.
  public static func markerFile(in legacy: URL) -> URL {
    legacy.appendingPathComponent(markerName, isDirectory: false)
  }

  public static func isDone(from legacy: URL, fileManager: FileManager = .default) -> Bool {
    fileManager.fileExists(atPath: markerFile(in: legacy).path)
  }

  /// A run without the App Group is about to write to `legacy` (and `defaults`) again: the next
  /// run with the group must look at it once more.
  public static func forget(
    legacy: URL?, defaults: UserDefaults?, fileManager: FileManager = .default
  ) {
    if let legacy { try? fileManager.removeItem(at: markerFile(in: legacy)) }
    defaults?.removeObject(forKey: settingsMarkerKey)
  }

  /// Whether files of the default protection class can be written and read in `directory` now.
  /// Before the first unlock after a restart they cannot (and the defaults read as empty): the
  /// migration then waits for a launch that can see the data, instead of writing its marker
  /// over what it could not read.
  public static func canUseProtectedData(in directory: URL, fileManager: FileManager = .default)
    -> Bool
  {
    let probe = directory.appendingPathComponent(".protected-data-probe", isDirectory: false)
    defer { try? fileManager.removeItem(at: probe) }
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      var options: Data.WritingOptions = []
      #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
      #endif
      try Data([1]).write(to: probe, options: options)
      return try Data(contentsOf: probe) == Data([1])
    } catch {
      return false
    }
  }

  /// The app's Application Support (its private layout) → the group.
  @discardableResult
  public static func migrateApp(
    from legacy: URL, to group: URL, fileManager: FileManager = .default,
    forceCopy: Bool = false
  ) throws -> Report {
    try migrate(
      tag: "app", from: legacy, entries: appEntries, to: group, fileManager: fileManager,
      forceCopy: forceCopy, replaces: { _ in false })
  }

  /// The share extension's `Application Support/share` → the group. A mirror the app saved from
  /// the keychain handoff is replaced by the real item.
  @discardableResult
  public static func migrateShare(
    from legacy: URL, to group: URL, fileManager: FileManager = .default,
    forceCopy: Bool = false
  ) throws -> Report {
    try migrate(
      tag: "share", from: legacy, entries: shareEntries, to: group, fileManager: fileManager,
      forceCopy: forceCopy, replaces: isShareMirror(_:))
  }

  /// The switches in the app's standard defaults → the group's defaults, and out of the old
  /// defaults (so what is found there later was written by a build without the group). The first
  /// time only where the group has no value of its own; after a round trip (`settingsEverKey`) the
  /// old value wins, being the newer. Returns how many were copied (0 when already done).
  ///
  /// `legacyDomain` (the app's bundle identifier for `.standard`) guards against defaults that
  /// could not be read (protected data unavailable): with no switch found and no such domain, no
  /// marker is written and the next launch looks again.
  @discardableResult
  public static func migrateSettings(
    from legacy: UserDefaults, to group: UserDefaults, legacyDomain: String? = nil
  ) -> Int {
    guard !legacy.bool(forKey: settingsMarkerKey) else { return 0 }
    let present = PhoneSettings.Key.migrated.filter { legacy.object(forKey: $0) != nil }
    if present.isEmpty, let legacyDomain, legacy.persistentDomain(forName: legacyDomain) == nil {
      return 0
    }
    let roundTrip = legacy.bool(forKey: settingsEverKey)
    var copied = 0
    for key in present {
      guard let value = legacy.object(forKey: key) else { continue }
      if roundTrip || group.object(forKey: key) == nil {
        group.set(value, forKey: key)
        copied += 1
      }
      legacy.removeObject(forKey: key)
    }
    legacy.set(true, forKey: settingsEverKey)
    legacy.set(true, forKey: settingsMarkerKey)
    return copied
  }

  // MARK: - Files

  static func migrate(
    tag: String, from legacy: URL, entries: [String], to group: URL, fileManager: FileManager,
    forceCopy: Bool, replaces: @escaping (URL) -> Bool, beforeExclusivePlace: ((URL) -> Void)? = nil
  ) throws -> Report {
    var report = Report()
    let marker = markerFile(in: legacy)
    if fileManager.fileExists(atPath: marker.path) {
      report.alreadyDone = true
      return report
    }
    // One per source: the app and the share extension may migrate at the same time.
    let staging = group.appendingPathComponent("migration-staging-" + tag, isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    // A copy left by a run that died before its rename: the source still exists.
    for stray in (try? fileManager.contentsOfDirectory(atPath: staging.path)) ?? [] {
      try? fileManager.removeItem(at: staging.appendingPathComponent(stray))
    }
    let run = Run(
      staging: staging,
      conflicts: group.appendingPathComponent(conflictsName, isDirectory: true)
        .appendingPathComponent(
          "\(tag)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))",
          isDirectory: true),
      fileManager: fileManager, forceCopy: forceCopy, replaces: replaces,
      beforeExclusivePlace: beforeExclusivePlace)

    for entry in entries {
      let source = legacy.appendingPathComponent(entry)
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { continue }
      let files = isDirectory.boolValue ? regularFiles(under: source, fileManager: fileManager) : [""]
      for relative in files {
        let path = relative.isEmpty ? entry : entry + "/" + relative
        do {
          try run.moveFile(
            path: path, from: legacy.appendingPathComponent(path),
            to: group.appendingPathComponent(path),
            singleState: relative.isEmpty && singleStateEntries.contains(entry), report: &report)
        } catch {
          report.failed += 1
        }
      }
    }

    if report.failed == 0 {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      var done = report
      done.alreadyDone = true
      let body = try encoder.encode(
        Marker(at: Date().timeIntervalSince1970, report: done))
      try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
      try body.write(to: marker, options: .atomic)
    }
    return report
  }

  struct Marker: Codable {
    var at: TimeInterval
    var report: Report
  }

  /// Every regular file under `root`, as paths relative to it, outside `skippedDirectories`.
  static func regularFiles(under root: URL, fileManager: FileManager) -> [String] {
    var found: [String] = []
    func walk(_ directory: URL, _ prefix: String) {
      for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
        let url = directory.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
        let relative = prefix.isEmpty ? name : prefix + "/" + name
        if isDirectory.boolValue {
          if !skippedDirectories.contains(name) { walk(url, relative) }
        } else {
          found.append(relative)
        }
      }
    }
    walk(root, "")
    return found.sorted()
  }

  /// One run's places and rules.
  private struct Run {
    let staging: URL
    let conflicts: URL
    let fileManager: FileManager
    let forceCopy: Bool
    let replaces: (URL) -> Bool
    let beforeExclusivePlace: ((URL) -> Void)?

    func moveFile(path: String, from: URL, to: URL, singleState: Bool, report: inout Report) throws {
      try fileManager.createDirectory(
        at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
      if fileManager.fileExists(atPath: to.path) {
        try resolve(path: path, from: from, to: to, singleState: singleState, report: &report)
        return
      }
      beforeExclusivePlace?(to)
      do {
        try place(from: from, to: to, exclusive: true)
        report.moved += 1
      } catch let error as POSIXError where error.code == .EEXIST {
        // Written by the other process (the app or the share extension) between the check and
        // the rename: the same decision as when it was there from the start.
        try resolve(path: path, from: from, to: to, singleState: singleState, report: &report)
      }
    }

    /// Both places hold `path`.
    private func resolve(
      path: String, from: URL, to: URL, singleState: Bool, report: inout Report
    ) throws {
      if replaces(to) {
        try place(from: from, to: to, exclusive: false)
        report.replaced += 1
      } else if try sameBytes(from, to) {
        try fileManager.removeItem(at: from)
        report.deduplicated += 1
      } else if singleState, try modified(from) > modified(to) {
        // The old place's copy is newer: the group's goes aside first (still in the group), then
        // the newer one takes its place.
        try place(from: to, to: aside(path), exclusive: true)
        try place(from: from, to: to, exclusive: true)
        report.superseded += 1
      } else {
        try place(from: from, to: aside(path), exclusive: true)
        report.kept += 1
      }
    }

    private func aside(_ path: String) throws -> URL {
      let url = conflicts.appendingPathComponent(path)
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      return url
    }

    /// Byte-for-byte equality; a file that cannot be read is an error (retried), never "different".
    private func sameBytes(_ a: URL, _ b: URL) throws -> Bool {
      let first = try Data(contentsOf: a, options: .mappedIfSafe)
      let second = try Data(contentsOf: b, options: .mappedIfSafe)
      return first == second
    }

    private func modified(_ url: URL) throws -> Date {
      guard let date = try url.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      else { throw POSIXError(.EIO) }
      return date
    }

    /// Puts `from` at `to`: one rename on the same volume, else copy → staging → rename → remove.
    /// `exclusive` refuses an existing `to`.
    private func place(from: URL, to: URL, exclusive: Bool) throws {
      let flags = exclusive ? UInt32(RENAME_EXCL) : 0
      if !forceCopy {
        if renamex_np(from.path, to.path, flags) == 0 { return }
        guard errno == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      }
      let copy = staging.appendingPathComponent(UUID().uuidString)
      try fileManager.copyItem(at: from, to: copy)
      let handle = open(copy.path, O_RDONLY)
      if handle >= 0 {
        _ = fsync(handle)
        close(handle)
      }
      guard renamex_np(copy.path, to.path, flags) == 0 else {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        try? fileManager.removeItem(at: copy)
        throw POSIXError(code)
      }
      try fileManager.removeItem(at: from)
    }
  }

  /// A share mirror the app saved from the keychain handoff (`items/<id>.json` with
  /// `shared_on_phone`), which the share extension's own record supersedes.
  static func isShareMirror(_ url: URL) -> Bool {
    let path = url.pathComponents
    guard path.count >= 2, path[path.count - 2] == "items", url.pathExtension == "json",
      let data = try? Data(contentsOf: url)
    else { return false }
    struct Flag: Decodable {
      var sharedOnPhone: Bool?
      enum CodingKeys: String, CodingKey { case sharedOnPhone = "shared_on_phone" }
    }
    return (try? JSONDecoder().decode(Flag.self, from: data))?.sharedOnPhone != nil
  }
}

extension PhoneAppGroup {
  /// Where a build without the App Group kept the app's files: its own Application Support
  /// (`storageRoot` without a shared container). Nil when it cannot be named.
  public static func privateApplicationSupport(fileManager: FileManager = .default) -> URL? {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
  }

  /// The share extension's own store without the App Group: `<Application Support>/share`.
  public static func privateShareDirectory(in applicationSupport: URL) -> URL {
    applicationSupport.appendingPathComponent("share", isDirectory: true)
  }
}
