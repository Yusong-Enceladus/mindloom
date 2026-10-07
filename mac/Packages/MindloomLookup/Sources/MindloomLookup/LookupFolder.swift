import Darwin
import Foundation

/// The library's private `lookup` folder (0700; files 0600): the switch and
/// the owner's 「不查找的词和网站」, the network activity record, the request
/// ledger behind the limits, each search service's state, and a cache of
/// public answers. Search keys are never here; they are in the Keychain.
public struct LookupFolder: Sendable {
  public static let name = "lookup"
  public let url: URL

  /// `dataRoot`'s lookup folder (created on first use).
  public init(dataRoot: URL) {
    url = dataRoot.appendingPathComponent(Self.name, isDirectory: true)
  }

  public init(folder: URL) {
    url = folder
  }

  var settingsURL: URL { url.appendingPathComponent("settings.json") }
  var activityURL: URL { url.appendingPathComponent("activity.jsonl") }
  var ledgerURL: URL { url.appendingPathComponent("ledger.json") }
  var servicesURL: URL { url.appendingPathComponent("services.json") }
  var cacheURL: URL { url.appendingPathComponent("cache", isDirectory: true) }

  public func loadSettings() -> WebLookupSettings {
    guard let data = PrivateFiles.read(settingsURL, maximumBytes: 256 * 1024),
      let settings = try? JSONDecoder().decode(WebLookupSettings.self, from: data)
    else { return WebLookupSettings() }
    return settings
  }

  public func save(_ settings: WebLookupSettings) throws {
    try PrivateFiles.writeJSON(settings, to: settingsURL)
  }
}

/// The switch as every request sees it. `LookupEgress` reads it before each
/// request (and each redirect), so turning 「从网络补充信息」 off stops a
/// lookup already under way; with a folder it is the settings file, which
/// another device or process may change too.
final class LookupSwitch: @unchecked Sendable {
  private let folder: LookupFolder?
  private let lock = NSLock()
  private var memory = WebLookupSettings()

  init(folder: LookupFolder?) {
    self.folder = folder
  }

  func settings() -> WebLookupSettings {
    if let folder { return folder.loadSettings() }
    return lock.withLock { memory }
  }

  func save(_ settings: WebLookupSettings) throws {
    if let folder {
      try folder.save(settings)
    } else {
      lock.withLock { memory = settings }
    }
  }

  var isOn: Bool { settings().enabled }
}

/// 「从网络补充信息」 and its lists. Off by default; travels with the library.
public struct WebLookupSettings: Codable, Equatable, Sendable {
  public var enabled: Bool
  /// 「不查找的词和网站」: words that are never sent, sites never read.
  public var blockedTerms: [String]
  public var blockedSites: [String]

  public init(enabled: Bool = false, blockedTerms: [String] = [], blockedSites: [String] = []) {
    self.enabled = enabled
    self.blockedTerms = blockedTerms
    self.blockedSites = blockedSites
  }

  enum CodingKeys: String, CodingKey {
    case enabled
    case blockedTerms = "blocked_terms"
    case blockedSites = "blocked_sites"
  }

  /// Unknown or malformed fields fall back to the defaults (off).
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = ((try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? false
    blockedTerms = ((try? container.decodeIfPresent([String].self, forKey: .blockedTerms)) ?? nil) ?? []
    blockedSites = ((try? container.decodeIfPresent([String].self, forKey: .blockedSites)) ?? nil) ?? []
  }
}

public enum PrivateFileError: Error, Equatable, Sendable {
  case write
}

/// Small private files: folders 0700, files 0600, written under a temporary
/// name and renamed into place, read without following links.
enum PrivateFiles {
  static func prepare(_ folder: URL) throws {
    let path = folder.path
    var status = stat()
    if lstat(path, &status) == 0 {
      guard status.st_mode & S_IFMT == S_IFDIR else { throw PrivateFileError.write }
      if status.st_mode & 0o777 != 0o700 { chmod(path, 0o700) }
      return
    }
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  static func read(_ url: URL, maximumBytes: Int) -> Data? {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_size <= maximumBytes
    else { return nil }
    return try? handle.readToEnd()
  }

  static func write(_ data: Data, to url: URL) throws {
    try prepare(url.deletingLastPathComponent())
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw PrivateFileError.write }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      unlink(temporary.path)
      throw PrivateFileError.write
    }
    guard rename(temporary.path, url.path) == 0 else {
      unlink(temporary.path)
      throw PrivateFileError.write
    }
  }

  static func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value) else { throw PrivateFileError.write }
    try write(data, to: url)
  }

  static func readJSON<Value: Decodable>(_ type: Value.Type, from url: URL, maximumBytes: Int) -> Value? {
    guard let data = read(url, maximumBytes: maximumBytes) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(type, from: data)
  }

  /// Appends one line (a record) to a private file.
  static func append(_ line: Data, to url: URL) throws {
    try prepare(url.deletingLastPathComponent())
    let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw PrivateFileError.write }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      throw PrivateFileError.write
    }
    do {
      try handle.write(contentsOf: line)
      try handle.close()
    } catch {
      throw PrivateFileError.write
    }
  }
}
