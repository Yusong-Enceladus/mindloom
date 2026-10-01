import Darwin
import Foundation
import MindloomLink

/// The phone's durable outbox (PHONE-CONTRACT §5), one JSON file per entry in
/// the App Group container, so the app, the keyboard and the share extension
/// can all add to it without a shared database:
///
/// ```
/// outbox/
///   queued/<entry_id>.json   sealed wire + short preview, waiting for the Spark
///   sent/<entry_id>.json     preview only, kept 7 days ("已送出")
///   tmp/                     staging for atomic writes
///   quarantine/              unreadable files, moved aside, never deleted
/// ```
///
/// - **Crash-safe:** every write goes to `tmp/`, is synced, and is renamed
///   into place, so a reader sees the old file or the new one, never half of
///   one. queued → sent writes `sent/` first and then removes `queued/`; a
///   crash in between leaves both, and the `sent/` copy wins on every read.
/// - **Idempotent by entry id:** adding an id that is already queued or sent
///   changes nothing; marking an already sent entry sent changes nothing.
///   Sending the same id twice is also harmless on the Spark (a duplicate id
///   counts as success), so an interrupted send is simply sent again.
/// - **Private:** the directory is excluded from backups (the previews are
///   plaintext) and, on iOS, files are protected until first unlock so a
///   background refresh can still send.
///
/// Within one process a lock serializes changes. Across processes the
/// extensions only add entries; only the app changes or removes them.
public final class OutboxStore: @unchecked Sendable {
  public enum AddResult: Equatable, Sendable {
    case added
    case alreadyQueued
    case alreadySent
  }

  public struct Counts: Equatable, Sendable {
    public let queued: Int
    public let sent: Int

    public init(queued: Int, sent: Int) {
      self.queued = queued
      self.sent = sent
    }
  }

  public let root: URL
  private let lock = NSLock()
  private let fileManager: FileManager

  private var queuedDirectory: URL { root.appendingPathComponent("queued", isDirectory: true) }
  private var sentDirectory: URL { root.appendingPathComponent("sent", isDirectory: true) }
  private var tmpDirectory: URL { root.appendingPathComponent("tmp", isDirectory: true) }
  private var quarantineDirectory: URL {
    root.appendingPathComponent("quarantine", isDirectory: true)
  }

  /// Opens (and creates) an outbox at `root`.
  public init(root: URL, fileManager: FileManager = .default) throws {
    self.root = root
    self.fileManager = fileManager
    for directory in [root, queuedDirectory, sentDirectory, tmpDirectory, quarantineDirectory] {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    var mutableRoot = root
    try mutableRoot.setResourceValues(excluded)
  }

  /// The outbox in the App Group container.
  public static func appGroup(fileManager: FileManager = .default) throws -> OutboxStore {
    guard let container = PhoneAppGroup.containerURL(fileManager: fileManager) else {
      throw PhoneAppGroup.AppGroupError.containerUnavailable
    }
    return try OutboxStore(
      root: PhoneAppGroup.outboxDirectory(in: container), fileManager: fileManager)
  }

  // MARK: - Adding

  /// Adds a queued entry. Idempotent by entry id.
  @discardableResult
  public func add(_ entry: OutboxEntry) throws -> AddResult {
    guard entry.state == .queued else { throw OutboxEntry.EntryError.invalidState }
    return try locked {
      if fileManager.fileExists(atPath: file(in: sentDirectory, id: entry.entryID).path) {
        return .alreadySent
      }
      if fileManager.fileExists(atPath: file(in: queuedDirectory, id: entry.entryID).path) {
        return .alreadyQueued
      }
      try write(entry, to: queuedDirectory)
      return .added
    }
  }

  // MARK: - Reading

  /// Queued entries, oldest first (then by id, so the order is stable).
  public func queued() throws -> [OutboxEntry] {
    try locked {
      let sentIDs = Set(entryIDs(in: sentDirectory))
      return try entryIDs(in: queuedDirectory)
        .filter { !sentIDs.contains($0) }
        .compactMap { try read(id: $0, from: queuedDirectory) }
        .filter { $0.state == .queued }
        .sorted { ($0.createdAtMillis, $0.entryID) < ($1.createdAtMillis, $1.entryID) }
    }
  }

  /// "已送出" entries still inside the 7-day window, newest first.
  public func sent(now: Date = Date()) throws -> [OutboxEntry] {
    try locked {
      try entryIDs(in: sentDirectory)
        .compactMap { try read(id: $0, from: sentDirectory) }
        .filter { $0.state == .sent && !$0.isExpired(now: now) }
        .sorted { ($0.sentAtMillis ?? 0, $0.entryID) > ($1.sentAtMillis ?? 0, $1.entryID) }
    }
  }

  public func entry(id: String) throws -> OutboxEntry? {
    guard EntryID.isValid(id) else { return nil }
    return try locked {
      try read(id: id, from: sentDirectory) ?? read(id: id, from: queuedDirectory)
    }
  }

  public func counts(now: Date = Date()) throws -> Counts {
    Counts(queued: try queued().count, sent: try sent(now: now).count)
  }

  /// How many unreadable files were moved aside.
  public func quarantinedCount() -> Int {
    (try? fileManager.contentsOfDirectory(atPath: quarantineDirectory.path).count) ?? 0
  }

  // MARK: - Transitions (app only)

  /// queued → sent: keeps only the preview. Idempotent; nil for an unknown id.
  @discardableResult
  public func markSent(id: String, at now: Date = Date(), duplicate: Bool = false) throws
    -> OutboxEntry?
  {
    guard EntryID.isValid(id) else { return nil }
    return try locked {
      if let sent = try read(id: id, from: sentDirectory) {
        try removeIfPresent(file(in: queuedDirectory, id: id))
        return sent
      }
      guard let queued = try read(id: id, from: queuedDirectory) else { return nil }
      let sent = queued.markingSent(at: now, duplicate: duplicate)
      try write(sent, to: sentDirectory)
      try removeIfPresent(file(in: queuedDirectory, id: id))
      return sent
    }
  }

  /// Records a failed attempt on a queued entry.
  @discardableResult
  public func recordFailure(
    id: String, category: DeliveryErrorCategory, at now: Date = Date()
  ) throws -> OutboxEntry? {
    guard EntryID.isValid(id) else { return nil }
    return try locked {
      guard !fileManager.fileExists(atPath: file(in: sentDirectory, id: id).path),
        let queued = try read(id: id, from: queuedDirectory)
      else { return nil }
      let failed = queued.recordingFailure(category, at: now)
      try write(failed, to: queuedDirectory)
      return failed
    }
  }

  /// Removes expired "已送出" previews, queued copies left behind by a crash
  /// after `sent/` was written, and stale staging files. Returns how many
  /// entries were removed.
  @discardableResult
  public func prune(now: Date = Date()) throws -> Int {
    try locked {
      var removed = 0
      let sentIDs = entryIDs(in: sentDirectory)
      for id in sentIDs {
        if let entry = try read(id: id, from: sentDirectory), entry.isExpired(now: now) {
          try removeIfPresent(file(in: sentDirectory, id: id))
          removed += 1
        }
      }
      for id in Set(entryIDs(in: queuedDirectory)).intersection(sentIDs) {
        try removeIfPresent(file(in: queuedDirectory, id: id))
      }
      let staleBefore = now.addingTimeInterval(-60 * 60)
      for name in (try? fileManager.contentsOfDirectory(atPath: tmpDirectory.path)) ?? [] {
        let url = tmpDirectory.appendingPathComponent(name)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate
        if (modified ?? .distantPast) < staleBefore { try removeIfPresent(url) }
      }
      return removed
    }
  }

  // MARK: - Files

  private func locked<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private func file(in directory: URL, id: String) -> URL {
    directory.appendingPathComponent(id + ".json", isDirectory: false)
  }

  private func entryIDs(in directory: URL) -> [String] {
    ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
      .filter { $0.hasSuffix(".json") }
      .map { String($0.dropLast(5)) }
      .filter(EntryID.isValid)
  }

  /// Reads one entry. A file that cannot be decoded, or whose id does not
  /// match its name, is moved to `quarantine/` and skipped: the outbox keeps
  /// working and nothing is silently deleted.
  private func read(id: String, from directory: URL) throws -> OutboxEntry? {
    let url = file(in: directory, id: id)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch let error as NSError
      where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    {
      return nil
    }
    guard let entry = try? OutboxEntry.decode(data), entry.entryID == id else {
      let target = quarantineDirectory.appendingPathComponent(
        "\(directory.lastPathComponent)-\(id)-\(UUID().uuidString.prefix(8)).json")
      try? fileManager.moveItem(at: url, to: target)
      return nil
    }
    return entry
  }

  private func write(_ entry: OutboxEntry, to directory: URL) throws {
    let data = try entry.encoded()
    let staging = tmpDirectory.appendingPathComponent("\(entry.entryID).\(UUID().uuidString).tmp")
    var options: Data.WritingOptions = [.withoutOverwriting]
    #if os(iOS)
      options.insert(.completeFileProtectionUntilFirstUserAuthentication)
    #endif
    try data.write(to: staging, options: options)
    do {
      try Self.synchronize(staging)
      guard rename(staging.path, file(in: directory, id: entry.entryID).path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      Self.synchronizeDirectory(directory)
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }
  }

  private func removeIfPresent(_ url: URL) throws {
    do {
      try fileManager.removeItem(at: url)
    } catch CocoaError.fileNoSuchFile {
    } catch let error as NSError
      where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    {
    }
  }

  private static func synchronize(_ url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
  }

  /// Best effort: makes the rename itself durable.
  private static func synchronizeDirectory(_ url: URL) {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { return }
    _ = fsync(descriptor)
    close(descriptor)
  }
}
