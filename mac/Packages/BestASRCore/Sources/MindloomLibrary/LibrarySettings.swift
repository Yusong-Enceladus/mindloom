import Darwin
import Foundation

/// Settings that belong to one library rather than to the Mac or the App's
/// preferences (v12 phase B): they travel with the library folder, so a demo
/// root carries its own. Stored as `library-settings.json` in the root.
public struct LibrarySettings: Codable, Equatable, Sendable {
  /// The product time zone (ALIGNMENT 根-13), an IANA identifier; nil means
  /// the default (`ProductTimeZone.defaultIdentifier`).
  public var timeZoneIdentifier: String?
  /// 设置 › 其他 App › 允许其他 App 读 (v12 F1): off unless the owner turned it
  /// on for this library; while off the App does not listen for agents at
  /// all (there is no socket).
  public var otherAppsCanRead: Bool

  public init(timeZoneIdentifier: String? = nil, otherAppsCanRead: Bool = false) {
    self.timeZoneIdentifier = timeZoneIdentifier
    self.otherAppsCanRead = otherAppsCanRead
  }

  enum CodingKeys: String, CodingKey {
    case timeZoneIdentifier = "time_zone"
    case otherAppsCanRead = "other_apps_can_read"
  }

  /// Unknown or malformed fields fall back to the defaults.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    timeZoneIdentifier = try? container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
    otherAppsCanRead =
      ((try? container.decodeIfPresent(Bool.self, forKey: .otherAppsCanRead)) ?? nil) ?? false
  }
}

public struct LibrarySettingsFile: Sendable {
  public static let name = "library-settings.json"
  public let url: URL

  public init(dataRoot: URL) {
    url = dataRoot.appendingPathComponent(Self.name)
  }

  /// The stored settings; a missing or unreadable file is the defaults.
  public func load() -> LibrarySettings {
    guard let data = LibraryFiles.read(url),
      let settings = try? JSONDecoder().decode(LibrarySettings.self, from: data)
    else { return LibrarySettings() }
    return settings
  }

  public func save(_ settings: LibrarySettings) throws {
    try LibraryFiles.write(settings, to: url)
  }
}

public enum LibraryFileError: Error, Equatable, Sendable {
  case write
}

/// Small private JSON files in a library root: read without following
/// links, written 0600 under a temporary name and renamed into place.
enum LibraryFiles {
  static let maximumBytes = 256 * 1024

  static func read(_ url: URL) -> Data? {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_size <= maximumBytes
    else { return nil }
    return try? handle.readToEnd()
  }

  static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value) else { throw LibraryFileError.write }
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw LibraryFileError.write }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      unlink(temporary.path)
      throw LibraryFileError.write
    }
    guard rename(temporary.path, url.path) == 0 else {
      unlink(temporary.path)
      throw LibraryFileError.write
    }
  }
}
