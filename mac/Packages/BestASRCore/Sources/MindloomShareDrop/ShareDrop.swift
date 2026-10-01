import Darwin
import Foundation

/// The hand-over between the macOS share extension 「收进织机」 and the App
/// (V8 contract A1). The extension is sandboxed and cannot reach the App's
/// socket, so it leaves one entry per share in a private drop folder inside
/// the library (`<library>/entries/share-inbox`, 0700) and pokes the App; the
/// App takes every entry in through the same intake rules as a paste or a
/// drop and removes it. Foundation only: the extension links nothing else.
///
/// An entry is `<id>.json` plus, for bytes that are not a file on disk (an
/// image from Safari, a clipping), a folder `<id>/` with those bytes. The
/// JSON is written last (temporary name, then rename), so a half-written
/// share is never read. Links are kept as text and never fetched; a shared
/// file is recorded by its path and read by the App under the drop rules.
public struct ShareDropEntry: Codable, Equatable, Sendable {
  public static let currentVersion = 1
  /// At most this many parts per share.
  public static let maximumParts = 50

  public var version: Int
  /// Lowercase UUID; also the file and folder name.
  public var id: String
  /// ISO 8601 with the local offset, when the owner shared it.
  public var createdAt: String
  /// The App the share came from (the frontmost App when the sheet opened).
  public var sourceBundleID: String?
  public var sourceName: String?
  public var parts: [Part]

  public struct Part: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
      case text
      /// A web link: kept as its title and URL, never fetched.
      case link
      /// A file on this Mac, by its absolute path.
      case file
      /// Bytes saved next to the entry (`name` inside `<id>/`).
      case data
    }

    public var kind: Kind
    public var text: String?
    public var url: String?
    public var title: String?
    public var path: String?
    public var name: String?
    /// The data's Uniform Type Identifier.
    public var type: String?

    public init(
      kind: Kind, text: String? = nil, url: String? = nil, title: String? = nil,
      path: String? = nil, name: String? = nil, type: String? = nil
    ) {
      self.kind = kind
      self.text = text
      self.url = url
      self.title = title
      self.path = path
      self.name = name
      self.type = type
    }

    public static func text(_ text: String) -> Part { Part(kind: .text, text: text) }
    public static func link(_ url: String, title: String? = nil) -> Part {
      Part(kind: .link, url: url, title: title)
    }
    public static func file(_ path: String) -> Part { Part(kind: .file, path: path) }
    public static func data(name: String, type: String?) -> Part {
      Part(kind: .data, name: name, type: type)
    }
  }

  enum CodingKeys: String, CodingKey {
    case version = "v"
    case id
    case createdAt = "created_at"
    case sourceBundleID = "source_bundle_id"
    case sourceName = "source_name"
    case parts
  }

  public init(
    id: String = UUID().uuidString.lowercased(), createdAt: Date = Date(),
    sourceBundleID: String? = nil, sourceName: String? = nil, parts: [Part]
  ) {
    version = Self.currentVersion
    self.id = id
    self.createdAt = Self.timestamp(createdAt)
    self.sourceBundleID = sourceBundleID
    self.sourceName = sourceName
    self.parts = parts
  }

  public var createdDate: Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: createdAt) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: createdAt)
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = .current
    return formatter.string(from: date)
  }

  /// Whether the entry is one the App may take in: a known version, an ID
  /// that is a lowercase UUID, a bounded number of parts, each part with what
  /// its kind needs, file paths absolute, data names plain file names.
  public var isWellFormed: Bool {
    guard version == Self.currentVersion, Self.isEntryID(id), createdDate != nil,
      !parts.isEmpty, parts.count <= Self.maximumParts
    else { return false }
    return parts.allSatisfy { part in
      switch part.kind {
      case .text: return !(part.text ?? "").isEmpty
      case .link: return !(part.url ?? "").isEmpty
      case .file: return (part.path ?? "").hasPrefix("/") && !(part.path ?? "").contains("\0")
      case .data: return part.name.map(Self.isPlainFileName) ?? false
      }
    }
  }

  public static func isEntryID(_ id: String) -> Bool {
    guard let uuid = UUID(uuidString: id) else { return false }
    return uuid.uuidString.lowercased() == id
  }

  /// A name with no folder in it and nothing hidden or relative.
  public static func isPlainFileName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= 200 && !name.contains("/") && !name.contains("\0")
      && !name.hasPrefix(".") && name != ".." && name != "."
  }
}

/// The drop folder itself: the extension writes, the App reads and removes.
public struct ShareDropbox: Sendable {
  public static let folderName = "share-inbox"
  /// The library-relative location (`<library>/entries/share-inbox`).
  public static let relativePath = "entries/share-inbox"
  /// Bytes of one data part, and of one share in all.
  public static let maximumDataBytes = 25 * 1_024 * 1_024
  public static let maximumShareBytes = 100 * 1_024 * 1_024

  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  /// The drop folder of the owner's library (from the account database, not
  /// `HOME`, which is the container inside the sandbox).
  public static func ownerLibraryDropbox() -> ShareDropbox? {
    guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
    let path = String(cString: home)
    guard path.hasPrefix("/") else { return nil }
    return ShareDropbox(
      directory: URL(fileURLWithPath: path, isDirectory: true)
        .appendingPathComponent("Library/Application Support/bestASR", isDirectory: true)
        .appendingPathComponent(relativePath, isDirectory: true))
  }

  public static func inLibrary(_ root: URL) -> ShareDropbox {
    ShareDropbox(directory: root.appendingPathComponent(relativePath, isDirectory: true))
  }

  /// The App creates the folder while sharing is on and removes it when the
  /// owner switches sharing off, so the extension can tell.
  public var isOpen: Bool {
    var entry = stat()
    return lstat(directory.path, &entry) == 0 && entry.st_mode & S_IFMT == S_IFDIR
  }

  public enum DropError: Error, Equatable, Sendable {
    case closed
    case malformed
    case tooLarge
    case writeFailed
  }

  // MARK: Writing (the extension)

  /// Writes one share: its bytes first, then its JSON under a temporary name,
  /// renamed into place last.
  public func write(_ entry: ShareDropEntry, data: [String: Data] = [:]) throws {
    guard isOpen else { throw DropError.closed }
    guard entry.isWellFormed else { throw DropError.malformed }
    let dataParts = entry.parts.filter { $0.kind == .data }.compactMap(\.name)
    guard Set(dataParts) == Set(data.keys), dataParts.count == data.count else {
      throw DropError.malformed
    }
    guard data.values.allSatisfy({ $0.count <= Self.maximumDataBytes }),
      data.values.reduce(0, { $0 + $1.count }) <= Self.maximumShareBytes
    else { throw DropError.tooLarge }
    let folder = directory.appendingPathComponent(entry.id, isDirectory: true)
    if !data.isEmpty {
      guard mkdir(folder.path, S_IRWXU) == 0 else { throw DropError.writeFailed }
      for (name, bytes) in data {
        guard Self.writePrivate(bytes, to: folder.appendingPathComponent(name)) else {
          removeEntryFiles(id: entry.id)
          throw DropError.writeFailed
        }
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let json = try? encoder.encode(entry) else { throw DropError.malformed }
    let temporary = directory.appendingPathComponent(".\(entry.id).json.tmp")
    let final = directory.appendingPathComponent("\(entry.id).json")
    guard Self.writePrivate(json, to: temporary), rename(temporary.path, final.path) == 0 else {
      unlink(temporary.path)
      removeEntryFiles(id: entry.id)
      throw DropError.writeFailed
    }
  }

  static func writePrivate(_ bytes: Data, to url: URL) -> Bool {
    let descriptor = Darwin.open(
      url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return false }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: bytes)
      return true
    } catch {
      unlink(url.path)
      return false
    }
  }

  // MARK: Reading (the App)

  public struct Pending: Equatable, Sendable {
    public let entry: ShareDropEntry
    /// `<id>/`, holding the data parts.
    public let dataFolder: URL

    public func dataURL(_ part: ShareDropEntry.Part) -> URL? {
      guard part.kind == .data, let name = part.name, ShareDropEntry.isPlainFileName(name) else {
        return nil
      }
      return dataFolder.appendingPathComponent(name, isDirectory: false)
    }
  }

  /// Every complete entry, oldest first, and how many unreadable ones were
  /// removed on the way (a broken entry can never be taken in).
  public func pending() -> (entries: [Pending], removedMalformed: Int) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    var entries: [Pending] = []
    var removed = 0
    for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
      let id = String(name.dropLast(".json".count))
      let url = directory.appendingPathComponent(name)
      guard ShareDropEntry.isEntryID(id),
        let data = Self.readSmall(url, limit: 8 * 1_024 * 1_024),
        let entry = try? JSONDecoder().decode(ShareDropEntry.self, from: data),
        entry.id == id, entry.isWellFormed
      else {
        removeEntryFiles(id: id, jsonName: name)
        removed += 1
        continue
      }
      entries.append(
        Pending(entry: entry, dataFolder: directory.appendingPathComponent(id, isDirectory: true)))
    }
    entries.sort {
      ($0.entry.createdDate ?? .distantPast, $0.entry.id)
        < ($1.entry.createdDate ?? .distantPast, $1.entry.id)
    }
    return (entries, removed)
  }

  /// Removes a taken (or refused) entry: its JSON and its data folder.
  public func remove(_ pending: Pending) {
    removeEntryFiles(id: pending.entry.id)
  }

  func removeEntryFiles(id: String, jsonName: String? = nil) {
    let manager = FileManager.default
    if ShareDropEntry.isEntryID(id) {
      try? manager.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
    }
    unlink(directory.appendingPathComponent(jsonName ?? "\(id).json").path)
  }

  static func readSmall(_ url: URL, limit: Int) -> Data? {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else {
      return nil
    }
    return data
  }

  /// Creates the folder (0700) for a library whose sharing is on; an
  /// existing one must be this user's folder (not a link).
  public func prepareFolder() -> Bool {
    var entry = stat()
    if lstat(directory.path, &entry) != 0 {
      let parent = directory.deletingLastPathComponent()
      if lstat(parent.path, &entry) != 0 {
        guard mkdir(parent.path, S_IRWXU) == 0 || errno == EEXIST else { return false }
      }
      guard mkdir(directory.path, S_IRWXU) == 0 || errno == EEXIST else { return false }
      guard lstat(directory.path, &entry) == 0 else { return false }
    }
    guard entry.st_mode & S_IFMT == S_IFDIR, entry.st_uid == getuid() else { return false }
    if entry.st_mode & 0o077 != 0 { chmod(directory.path, S_IRWXU) }
    return true
  }

  /// Sharing switched off: the folder goes (after the App has taken what was
  /// waiting), so the extension says sharing is off.
  public func removeFolder() {
    try? FileManager.default.removeItem(at: directory)
  }
}
