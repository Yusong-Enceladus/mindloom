import Darwin
import Foundation
import GRDB

/// What opening a library does before it migrates an existing database from
/// an older schema (v12 phase B, ROOT R3-1): clone the database with its
/// `-wal` and `-shm` into a dated folder inside the library, check the clone
/// with `PRAGMA quick_check`, and refuse to migrate when that fails. Only the
/// newest backups are kept once a migration has finished, except the copy
/// made before the first v12 schema (the one the daily app before Mindloom
/// can open), which stays for `protectedDays` whatever migrations follow
/// (review v12-B #8).
///
/// What it covers: the database only. Audio and the other files of the
/// library are not part of it, and it lives inside the library. The full
/// copy of the whole library before the switch is phase C's own step
/// (`cp -c -R` of the data root, plus the encrypted copy on the external
/// disk), made with the owner, not by the App: a copy the App keeps for
/// itself would also keep audio the owner later deletes.
public enum LibraryMigrationBackupPolicy: Equatable, Sendable {
  /// No backup (callers that only ever open databases they created).
  case disabled
  /// Backups go into this folder; the newest `keep` survive a migration.
  case cloneInto(URL, keep: Int)

  public static let defaultKeep = 2
  public static let folderName = "backups"

  /// `<library>/backups`, keeping the last two: the default for every store.
  public static func besideDatabase(_ databaseURL: URL) -> Self {
    .cloneInto(
      databaseURL.deletingLastPathComponent()
        .appendingPathComponent(folderName, isDirectory: true),
      keep: defaultKeep)
  }
}

public enum LibraryMigrationBackupError: Error, Equatable, Sendable {
  /// The backup folder could not be made.
  case folderUnavailable
  /// A database file could not be cloned (or copied).
  case cloneFailed(file: String, code: Int32)
  /// The clone did not pass `PRAGMA quick_check`.
  case verificationFailed
}

/// One backup made before a migration.
public struct LibraryMigrationBackupRecord: Equatable, Sendable {
  public let folder: URL
  public let fromUserVersion: Int
  public let appliedMigrationCount: Int
}

public enum LibraryMigrationBackup {
  public static let folderPrefix = "pre-migration-"
  public static let manifestName = "backup.json"
  /// The first schema of Mindloom (v12): a backup made from below it is the
  /// one the daily app before Mindloom can open.
  public static let firstMindloomUserVersion = 27
  /// How long that backup outlives later migrations.
  public static let protectedDays = 90

  /// True when the database already has migrations applied but not all of
  /// the registered ones: a library from an older version. A new, empty
  /// database and an up-to-date (or newer) one need no backup.
  public static func needsBackup(_ db: Database, migrator: DatabaseMigrator) throws -> Bool {
    let applied = try migrator.appliedIdentifiers(db)
    guard !applied.isEmpty else { return false }
    return try !migrator.hasCompletedMigrations(db)
  }

  /// Clones `databaseURL` and its `-wal`/`-shm` into a new dated folder in
  /// `folder` while holding the database's write lock (no other process can
  /// commit meanwhile), then checks the clone. Throws, and removes the
  /// partial folder, when anything fails.
  public static func backUp(
    pool: DatabasePool, databaseURL: URL, migrator: DatabaseMigrator, into folder: URL,
    now: Date = Date()
  ) throws -> LibraryMigrationBackupRecord {
    guard prepareFolder(folder) else { throw LibraryMigrationBackupError.folderUnavailable }
    let stamp = folderStamp(now)
    var target = folder.appendingPathComponent(folderPrefix + stamp, isDirectory: true)
    var suffix = 1
    while FileManager.default.fileExists(atPath: target.path) {
      suffix += 1
      target = folder.appendingPathComponent(
        folderPrefix + stamp + "-\(suffix)", isDirectory: true)
    }
    guard mkdir(target.path, S_IRWXU) == 0 else {
      throw LibraryMigrationBackupError.folderUnavailable
    }
    do {
      let (userVersion, appliedCount) = try pool.writeWithoutTransaction { db in
        var userVersion = 0
        var appliedCount = 0
        // BEGIN IMMEDIATE takes the write lock: no commit (and so no
        // checkpoint) by any other connection while the files are cloned.
        // Nothing is written; the transaction only holds the lock.
        try db.inTransaction(.immediate) {
          userVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
          appliedCount = try migrator.appliedIdentifiers(db).count
          for name in databaseFileNames(databaseURL) {
            let source = databaseURL.deletingLastPathComponent().appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try cloneFile(source, to: target.appendingPathComponent(name))
          }
          return .rollback
        }
        return (userVersion, appliedCount)
      }
      let clone = target.appendingPathComponent(databaseURL.lastPathComponent)
      guard verify(clone) else { throw LibraryMigrationBackupError.verificationFailed }
      writeManifest(
        in: target, now: now, userVersion: userVersion, appliedCount: appliedCount,
        databaseName: databaseURL.lastPathComponent)
      return LibraryMigrationBackupRecord(
        folder: target, fromUserVersion: userVersion, appliedMigrationCount: appliedCount)
    } catch {
      try? FileManager.default.removeItem(at: target)
      if let error = error as? LibraryMigrationBackupError { throw error }
      // Another program holding the database (BEGIN IMMEDIATE could not
      // take the write lock in time) is a wait, not a failed backup: thrown
      // as it is, so that `LibraryOpenRetry` tries the open again (review
      // 10-5d R5). The first open after the switch migrates, so it backs up.
      if LibraryOpenRetry.isBusy(error) { throw error }
      throw LibraryMigrationBackupError.cloneFailed(file: databaseURL.lastPathComponent, code: -1)
    }
  }

  /// `PRAGMA quick_check` on a read-only connection to the clone: "ok".
  public static func verify(_ databaseURL: URL) -> Bool {
    var configuration = Configuration()
    configuration.readonly = true
    guard let queue = try? DatabaseQueue(path: databaseURL.path, configuration: configuration)
    else { return false }
    defer { try? queue.close() }
    let result = try? queue.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check") }
    return result == ["ok"]
  }

  /// The backups in `folder`, newest first (by their dated names).
  public static func backups(in folder: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return
      names
      .filter { $0.hasPrefix(folderPrefix) }
      .sorted(by: >)
      .map { folder.appendingPathComponent($0, isDirectory: true) }
      .filter { url in
        var entry = stat()
        return lstat(url.path, &entry) == 0 && entry.st_mode & S_IFMT == S_IFDIR
      }
  }

  /// Removes all but the newest `keep` backups this code made. The oldest
  /// backup made from a schema before Mindloom's first stays for
  /// `protectedDays` after it was made, however many migrations follow
  /// (review v12-B #8): a few schema bumps right after the switch must not
  /// take the only copy the daily app can open.
  public static func prune(_ folder: URL, keep: Int, now: Date = Date()) {
    let all = backups(in: folder)
    let protected = protectedBackup(all, now: now)
    for old in all.dropFirst(max(keep, 1)) where old != protected {
      try? FileManager.default.removeItem(at: old)
    }
  }

  /// The oldest backup made before Mindloom's first schema, while it is
  /// younger than `protectedDays`; nil when there is none.
  static func protectedBackup(_ backups: [URL], now: Date) -> URL? {
    let early = backups.compactMap { url -> (URL, Date)? in
      guard let manifest = manifest(url), manifest.fromUserVersion < firstMindloomUserVersion
      else { return nil }
      return (url, manifest.createdAt)
    }
    guard let oldest = early.min(by: { $0.1 < $1.1 }) else { return nil }
    let age = now.timeIntervalSince(oldest.1)
    return age < Double(protectedDays) * 86_400 ? oldest.0 : nil
  }

  /// What a backup's `backup.json` says (nil when it cannot be read).
  static func manifest(_ folder: URL) -> (fromUserVersion: Int, createdAt: Date)? {
    guard
      let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = object["from_user_version"] as? Int,
      let created = (object["created_at"] as? String).flatMap({
        ISO8601DateFormatter().date(from: $0)
      })
    else { return nil }
    return (version, created)
  }

  static func databaseFileNames(_ databaseURL: URL) -> [String] {
    let name = databaseURL.lastPathComponent
    return [name, name + "-wal", name + "-shm"]
  }

  /// `cp -c`: an APFS clone (no extra space until either copy changes). On a
  /// volume without clones, a full copy.
  static func cloneFile(_ source: URL, to destination: URL) throws {
    if clonefile(source.path, destination.path, 0) == 0 { return }
    let code = errno
    guard code == ENOTSUP || code == EXDEV else {
      throw LibraryMigrationBackupError.cloneFailed(file: source.lastPathComponent, code: code)
    }
    guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
      throw LibraryMigrationBackupError.cloneFailed(
        file: source.lastPathComponent, code: errno)
    }
  }

  /// The library's `backups` folder, 0700, made if missing; it must be a
  /// directory of this user.
  static func prepareFolder(_ folder: URL) -> Bool {
    var entry = stat()
    if lstat(folder.path, &entry) != 0 {
      guard mkdir(folder.path, S_IRWXU) == 0 || errno == EEXIST else { return false }
      guard lstat(folder.path, &entry) == 0 else { return false }
    }
    return entry.st_mode & S_IFMT == S_IFDIR && entry.st_uid == getuid()
  }

  static func folderStamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: date)
  }

  private static func writeManifest(
    in folder: URL, now: Date, userVersion: Int, appliedCount: Int, databaseName: String
  ) {
    let manifest: [String: Any] = [
      "created_at": ISO8601DateFormatter().string(from: now),
      "database": databaseName,
      "from_user_version": userVersion,
      "applied_migrations": appliedCount,
      "quick_check": "ok",
    ]
    if let data = try? JSONSerialization.data(
      withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: folder.appendingPathComponent(manifestName), options: .atomic)
    }
  }
}
