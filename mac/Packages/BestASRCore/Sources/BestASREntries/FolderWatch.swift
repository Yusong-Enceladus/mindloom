import BestASRDomain
import BestASRIntake
import Darwin
import Foundation

/// Watched folders (V8 contract A4), off by default. The owner picks folders
/// (the screenshots folder, Downloads, …); a file that appears in one after
/// it is watched, settles (same size and time on two looks) and passes the
/// rules is taken in by the drop rules, with source "文件夹 · <名字>" and its
/// own creation time. Files already there when watching starts, or while a
/// folder is paused, are never taken. Only the folder itself, not its
/// subfolders.
public enum FolderWatchRules {
  /// Names a download or an editor leaves while it is still writing.
  static let temporarySuffixes = [
    ".crdownload", ".download", ".part", ".partial", ".tmp", ".temp", ".opdownload", ".icloud",
    ".swp", ".lock",
  ]

  /// Never a candidate: hidden files, system clutter, unfinished downloads.
  public static func isIgnored(_ name: String) -> Bool {
    if name.hasPrefix(".") || name.hasPrefix("~$") || name == "Icon\r" { return true }
    let lower = name.lowercased()
    return temporarySuffixes.contains { lower.hasSuffix($0) }
  }

  /// The owner's exclusions: glob patterns on the file name, any case.
  public static func isExcluded(_ name: String, patterns: [String]) -> Bool {
    patterns.contains { pattern in
      let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return false }
      return fnmatch(trimmed.lowercased(), name.lowercased(), 0) == 0
    }
  }
}

/// What a folder listing says about one entry (no content is read).
public struct FolderListingEntry: Equatable, Sendable {
  public let name: String
  public let isRegularFile: Bool
  public let size: UInt64
  public let modified: Double
  public let inode: UInt64
  public let created: Date?

  public init(
    name: String, isRegularFile: Bool, size: UInt64, modified: Double, inode: UInt64,
    created: Date? = nil
  ) {
    self.name = name
    self.isRegularFile = isRegularFile
    self.size = size
    self.modified = modified
    self.inode = inode
    self.created = created
  }

  var mark: FolderFileMark { FolderFileMark(size: size, modified: modified, inode: inode) }

  /// The entries directly in `folder` (links and folders are reported as not
  /// regular files and never followed).
  public static func list(_ folder: URL) -> [FolderListingEntry]? {
    guard
      let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
    else { return nil }
    return names.map { name in
      var entry = stat()
      let path = folder.appendingPathComponent(name).path
      guard lstat(path, &entry) == 0 else {
        return FolderListingEntry(name: name, isRegularFile: false, size: 0, modified: 0, inode: 0)
      }
      let modified =
        Double(entry.st_mtimespec.tv_sec) + Double(entry.st_mtimespec.tv_nsec) / 1_000_000_000
      let created = Date(
        timeIntervalSince1970: Double(entry.st_birthtimespec.tv_sec)
          + Double(entry.st_birthtimespec.tv_nsec) / 1_000_000_000)
      return FolderListingEntry(
        name: name, isRegularFile: entry.st_mode & S_IFMT == S_IFREG,
        size: UInt64(max(0, entry.st_size)), modified: modified, inode: UInt64(entry.st_ino),
        created: created)
    }
  }
}

public struct FolderFileMark: Codable, Equatable, Sendable {
  public let size: UInt64
  public let modified: Double
  public let inode: UInt64
}

/// Per folder: the files already accounted for (taken, skipped, or there
/// before watching), and new files waiting to settle.
public struct FolderWatchState: Codable, Equatable, Sendable {
  public var known: [String: [String: FolderFileMark]] = [:]
  public var settling: [String: [String: FolderFileMark]] = [:]

  public init() {}
}

/// One decision of a scan.
public enum FolderWatchDecision: Equatable, Sendable {
  case take(URL, createdAt: Date)
  /// Not taken, with the reason shown in Settings (no content).
  case skip(name: String, reason: String)
}

public enum FolderWatchEngine {
  public static let tooLargeReason = "超过大小上限"
  public static let excludedReason = "符合排除规则"
  public static let protectedReason = "织机资料库里的文件"

  /// One look at one folder. The first look (or any look while paused)
  /// only records what is there. A new or changed file waits for a second
  /// look with the same size and time before it is taken.
  public static func scan(
    _ folder: WatchedFolder, listing: [FolderListingEntry], paused: Bool,
    state: inout FolderWatchState, isProtected: (URL) -> Bool = { _ in false }
  ) -> [FolderWatchDecision] {
    let key = folder.id.uuidString
    let files = listing.filter { $0.isRegularFile && !FolderWatchRules.isIgnored($0.name) }
    guard var known = state.known[key], !paused else {
      // Baseline: everything here now is accounted for, never taken.
      state.known[key] = Dictionary(
        files.map { ($0.name, $0.mark) }, uniquingKeysWith: { first, _ in first })
      state.settling[key] = [:]
      return []
    }
    var settling = state.settling[key] ?? [:]
    var decisions: [FolderWatchDecision] = []
    let present = Set(files.map(\.name))
    for file in files.sorted(by: {
      ($0.created ?? .distantPast, $0.name) < ($1.created ?? .distantPast, $1.name)
    }) {
      let mark = file.mark
      if let previous = known[file.name], previous.inode == mark.inode {
        // The same file (perhaps still growing after it was taken or
        // skipped): never taken twice.
        known[file.name] = mark
        continue
      }
      guard settling[file.name] == mark else {
        settling[file.name] = mark
        continue
      }
      settling[file.name] = nil
      known[file.name] = mark
      let url = folder.url.appendingPathComponent(file.name, isDirectory: false)
      if FolderWatchRules.isExcluded(file.name, patterns: folder.exclusions) {
        decisions.append(.skip(name: file.name, reason: excludedReason))
      } else if file.size > folder.maximumBytes {
        decisions.append(.skip(name: file.name, reason: tooLargeReason))
      } else if isProtected(url) {
        decisions.append(.skip(name: file.name, reason: protectedReason))
      } else {
        decisions.append(.take(url, createdAt: file.created ?? Date()))
      }
    }
    // Forget what is gone, so a new file under an old name counts as new.
    known = known.filter { present.contains($0.key) }
    settling = settling.filter { present.contains($0.key) }
    state.known[key] = known
    state.settling[key] = settling
    return decisions
  }

  /// Drops the state of folders no longer watched.
  public static func prune(_ state: inout FolderWatchState, keeping folders: [WatchedFolder]) {
    let keys = Set(folders.map(\.id.uuidString))
    state.known = state.known.filter { keys.contains($0.key) }
    state.settling = state.settling.filter { keys.contains($0.key) }
  }

  /// Whether a scan left files waiting to settle (look again soon).
  public static func hasSettling(_ state: FolderWatchState) -> Bool {
    state.settling.values.contains { !$0.isEmpty }
  }

  /// The intake item for a file to take.
  public static func item(_ url: URL, createdAt: Date, folder: WatchedFolder) -> EntryIntakeItem {
    EntryIntakeItem(
      candidate: .file(url), source: EntrySource.named(EntrySource.folder(folder.displayName)),
      capturedAt: createdAt)
  }
}

/// Tells the App when a watched folder's entries change (a kernel vnode
/// event on the folder), so it looks again. Holds no content.
public final class FolderChangeMonitor: @unchecked Sendable {
  private let queue = DispatchQueue(label: "mindloom.entries.folder-monitor")
  private var sources: [String: DispatchSourceFileSystemObject] = [:]
  private let changed: @Sendable () -> Void

  public init(changed: @escaping @Sendable () -> Void) {
    self.changed = changed
  }

  /// Watches exactly these folders (paths), dropping the others.
  public func watch(_ paths: [String]) {
    queue.sync {
      for (path, source) in sources where !paths.contains(path) {
        source.cancel()
        sources[path] = nil
      }
      for path in paths where sources[path] == nil {
        let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { continue }
        let source = DispatchSource.makeFileSystemObjectSource(
          fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .link], queue: queue)
        let changed = changed
        source.setEventHandler { changed() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources[path] = source
      }
    }
  }

  public func stop() { watch([]) }

  deinit {
    for source in sources.values { source.cancel() }
  }
}
