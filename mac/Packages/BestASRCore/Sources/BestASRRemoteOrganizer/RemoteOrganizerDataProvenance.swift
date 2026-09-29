import Darwin
import Foundation

/// Development-period data-provenance guard for the own-device organizer link
/// (PRD §0.3.8, AGENTS.md). It applies in every build configuration.
public enum RemoteOrganizerDataProvenance {
  /// The one switch a product release flips once the Spark link has passed
  /// product acceptance. While it is `false`, the link may run only from a
  /// data root that fixture or demo setup marked as synthetic, and the owner's
  /// real library (`~/Library/Application Support/bestASR`) is never sent.
  /// Do not flip it during development.
  public static let productReleaseAllowsOwnLibrary = false

  /// Created only by fixture/demo setup (`script/make_synthetic_data_root.sh`
  /// or tests). The real library never has it.
  public static let syntheticMarkerFileName = "SYNTHETIC_DATA_ROOT"

  /// What the app opens inside a data root. They must be this root's own
  /// files: a symlink or hard link could make a marked root read another
  /// library's database.
  public static let storeEntryNames = [
    "history.sqlite", "history.sqlite-wal", "history.sqlite-shm", "assets",
  ]

  public enum Verdict: Equatable, Sendable {
    case allowed
    /// The active data root is the real library or inside it.
    case refusedRealLibrary
    /// The active data root is not marked as synthetic.
    case refusedNotSynthetic
    /// The marked root's database or assets are links to other files.
    case refusedLinkedStore
  }

  public static func verdict(
    dataRoot: URL,
    realLibraryRoot: URL,
    allowsOwnLibrary: Bool = productReleaseAllowsOwnLibrary
  ) -> Verdict {
    if allowsOwnLibrary { return .allowed }
    // By file identity, so no spelling (symlink, case, /.nofollow, /.resolve,
    // /.vol, firmlink) of the real library passes.
    if BestASRDataRootSelection.path(dataRoot, isWithinOrEqualTo: realLibraryRoot) {
      return .refusedRealLibrary
    }
    let marker = dataRoot.appendingPathComponent(syntheticMarkerFileName)
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path),
      attributes[.type] as? FileAttributeType == .typeRegular
    else { return .refusedNotSynthetic }
    guard storeIsOwnedByRoot(dataRoot, realLibraryRoot: realLibraryRoot) else {
      return .refusedLinkedStore
    }
    return .allowed
  }

  /// Each store entry that exists is a real file or directory of this root:
  /// not a symlink, a regular database file with a single link, and not the
  /// same file as the real library's entry.
  static func storeIsOwnedByRoot(_ root: URL, realLibraryRoot: URL) -> Bool {
    for name in storeEntryNames {
      let path = root.appendingPathComponent(name).path
      var entry = stat()
      guard lstat(path, &entry) == 0 else {
        if errno == ENOENT { continue }
        return false
      }
      let type = entry.st_mode & S_IFMT
      switch name {
      case "assets":
        guard type == S_IFDIR else { return false }
      default:
        guard type == S_IFREG, entry.st_nlink == 1 else { return false }
      }
      let real = realLibraryRoot.appendingPathComponent(name).path
      var realEntry = stat()
      if stat(real, &realEntry) == 0, realEntry.st_dev == entry.st_dev,
        realEntry.st_ino == entry.st_ino
      {
        return false
      }
    }
    return true
  }
}

/// Explicit per-launch choice of a separate data root, for demo and synthetic
/// data: `bestASR -BestASRDataRoot /path/to/demo-root`. It is read only from
/// the launch arguments, never from persistent preferences, and it can never
/// point at, into, or above the real library. Any mention of the option that
/// is not exactly `-BestASRDataRoot <absolute path>` fails the launch instead
/// of falling back to the real library.
public enum BestASRDataRootSelection {
  public static let launchArgumentKey = "BestASRDataRoot"

  public enum SelectionError: Error, Equatable, Sendable {
    /// The option is misspelled, repeated, or has no usable value.
    case malformedArgument
    case notAbsolute
    /// A magic path prefix such as `/.nofollow`, `/.resolve`, or `/.vol`.
    case unsupportedPathSpelling
    case insideRealLibrary
    case containsRealLibrary
  }

  /// The owner's real library, from the account database rather than the
  /// process environment (`HOME`/`CFFIXED_USER_HOME` can be overridden).
  public static func ownerRealLibraryRoot() -> URL? {
    guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
      return nil
    }
    let home = String(cString: directory)
    guard home.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("bestASR", isDirectory: true)
  }

  /// The separate root requested by these launch arguments, or `nil` when the
  /// option is not mentioned at all.
  public static func separateDataRoot(
    arguments: [String], realLibraryRoot: URL
  ) throws -> URL? {
    let key = launchArgumentKey.lowercased()
    let mentions = arguments.indices.dropFirst().filter {
      arguments[$0].lowercased().contains(key)
    }
    guard let first = mentions.first else { return nil }
    guard arguments[first] == "-" + launchArgumentKey,
      mentions.allSatisfy({ $0 == first || $0 == first + 1 }),
      first + 1 < arguments.count
    else { throw SelectionError.malformedArgument }
    return try separateDataRoot(requested: arguments[first + 1], realLibraryRoot: realLibraryRoot)
  }

  /// Validates one requested root. Throws rather than falling back.
  public static func separateDataRoot(
    requested: String, realLibraryRoot: URL
  ) throws -> URL {
    guard !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !requested.hasPrefix("-")
    else { throw SelectionError.malformedArgument }
    guard requested.hasPrefix("/") else { throw SelectionError.notAbsolute }
    let url = URL(fileURLWithPath: requested, isDirectory: true).standardizedFileURL
    if let firstComponent = url.pathComponents.dropFirst().first,
      firstComponent.hasPrefix(".")
    {
      throw SelectionError.unsupportedPathSpelling
    }
    if path(url, isWithinOrEqualTo: realLibraryRoot) {
      throw SelectionError.insideRealLibrary
    }
    if path(realLibraryRoot, isWithinOrEqualTo: url) {
      throw SelectionError.containsRealLibrary
    }
    return url
  }

  /// True when `candidate` is `root` or inside it, compared by file identity
  /// (device and inode of every existing ancestor) and, for paths that do not
  /// exist yet, by the kernel's canonical spelling (`F_GETPATH`), case-
  /// insensitively. Symlinks, `/.nofollow`, `/.resolve/N`, `/.vol/...`, and
  /// case variants all resolve to the same answer.
  public static func path(_ candidate: URL, isWithinOrEqualTo root: URL) -> Bool {
    if let rootIdentity = identity(root.standardizedFileURL.path) {
      var current = candidate.standardizedFileURL.path
      while true {
        if identity(current) == rootIdentity { return true }
        let parent = (current as NSString).deletingLastPathComponent
        if parent == current || parent.isEmpty { break }
        current = parent
      }
    }
    let candidateComponents = canonicalComponents(candidate)
    let rootComponents = canonicalComponents(root)
    guard candidateComponents.count >= rootComponents.count else { return false }
    return zip(candidateComponents, rootComponents).allSatisfy {
      $0.compare($1, options: [.caseInsensitive]) == .orderedSame
    }
  }

  private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
  }

  private static func identity(_ path: String) -> FileIdentity? {
    var entry = stat()
    guard stat(path, &entry) == 0 else { return nil }
    return FileIdentity(device: entry.st_dev, inode: entry.st_ino)
  }

  /// The kernel's path for an existing file (resolves symlinks, firmlinks and
  /// magic prefixes), or nil.
  static func kernelPath(ofExisting path: String) -> String? {
    let descriptor = open(path, O_EVTONLY | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
    let result = buffer.withUnsafeMutableBytes {
      fcntl(descriptor, F_GETPATH, $0.baseAddress!)
    }
    guard result != -1 else { return nil }
    return String(
      decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  private static func canonicalComponents(_ url: URL) -> [String] {
    var existing = url.standardizedFileURL.path
    var trailing: [String] = []
    var canonical: String?
    while true {
      if let resolved = kernelPath(ofExisting: existing) {
        canonical = resolved
        break
      }
      let parent = (existing as NSString).deletingLastPathComponent
      if parent == existing || parent.isEmpty { break }
      trailing.insert((existing as NSString).lastPathComponent, at: 0)
      existing = parent
    }
    var components = URL(fileURLWithPath: canonical ?? existing).pathComponents
    // Normalize /private/{tmp,var,etc} spellings for paths the kernel could
    // not resolve.
    if components.count > 1, components[1] == "private" {
      components.remove(at: 1)
    }
    return components + trailing
  }
}
