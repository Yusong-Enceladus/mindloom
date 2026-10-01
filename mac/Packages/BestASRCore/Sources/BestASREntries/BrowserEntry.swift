import Darwin
import Foundation
import MindloomAgentProtocol

/// The Chrome extension's connection (V8 contract A6): the native messaging
/// host manifest that tells Chrome which program to start for the extension
/// 「收进织机」 — the helper bundled in the App — and that only that
/// extension may start it (`allowed_origins`). It is written only when the
/// owner switches the entry on in Settings → 入口 and removed when they switch
/// it off; nothing else ever writes or deletes it. It holds a path and the
/// extension's ID, no library data.
public struct BrowserHostManifest: Sendable {
  public static let fileName = BrowserExtension.hostName + ".json"
  public static let description = "织机「收进织机」的本机连接（不联网）"

  /// Chrome's `NativeMessagingHosts` folder for this user.
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory
  }

  /// Google Chrome's per-user folder, from the account database (not `HOME`).
  public static func chrome() -> BrowserHostManifest? {
    guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
    let path = String(cString: home)
    guard path.hasPrefix("/") else { return nil }
    return BrowserHostManifest(
      directory: URL(fileURLWithPath: path, isDirectory: true)
        .appendingPathComponent(
          "Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true))
  }

  public var fileURL: URL { directory.appendingPathComponent(Self.fileName, isDirectory: false) }

  /// The browser's own support folder; missing means the browser was never
  /// installed or run for this user.
  public var browserFolder: URL { directory.deletingLastPathComponent() }

  /// The manifest for a helper at `helperPath`.
  public static func content(helperPath: String) -> JSONValue {
    [
      "name": .string(BrowserExtension.hostName),
      "description": .string(description),
      "path": .string(helperPath),
      "type": "stdio",
      "allowed_origins": .strings([BrowserExtension.origin]),
    ]
  }

  public static func data(helperPath: String) -> Data {
    Data((content(helperPath: helperPath).serialized + "\n").utf8)
  }

  // MARK: Status

  public enum Status: Equatable, Sendable {
    case absent
    /// Ours, pointing at this helper.
    case installed
    /// Ours, but for a helper somewhere else (the App moved, or another copy).
    case otherHelper(String)
    /// A file by our name we cannot read as our manifest.
    case unreadable
  }

  public func status(helperPath: String) -> Status {
    var entry = stat()
    guard lstat(fileURL.path, &entry) == 0 else { return .absent }
    guard entry.st_mode & S_IFMT == S_IFREG,
      let data = EntryFolder.read(fileURL), let value = try? JSONValue.parse(data),
      value["name"]?.stringValue == BrowserExtension.hostName,
      let path = value["path"]?.stringValue
    else { return .unreadable }
    let origins = value["allowed_origins"]?.arrayValue?.compactMap(\.stringValue) ?? []
    guard path == helperPath, origins == [BrowserExtension.origin],
      value["type"]?.stringValue == "stdio"
    else { return .otherHelper(path) }
    return .installed
  }

  // MARK: Install / remove

  public enum InstallResult: Equatable, Sendable {
    case installed
    /// Already there, byte for byte: nothing written.
    case unchanged
  }

  public enum ManifestError: Error, Equatable, Sendable {
    /// Chrome's folder for this user does not exist (Chrome not installed).
    case browserMissing
    /// The helper is not an executable file at an absolute path.
    case helperMissing
    /// Something that is not a file has the manifest's name.
    case notAFile
    case write
    case remove
  }

  /// Writes the manifest for `helperPath` (idempotent: the same manifest is
  /// left untouched). Creates `NativeMessagingHosts` when Chrome's own folder
  /// exists; never creates Chrome's folder.
  @discardableResult
  public func install(helperPath: String) throws -> InstallResult {
    guard helperPath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: helperPath)
    else { throw ManifestError.helperMissing }
    var folder = stat()
    guard stat(browserFolder.path, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR else {
      throw ManifestError.browserMissing
    }
    if mkdir(directory.path, 0o755) != 0, errno != EEXIST { throw ManifestError.write }
    let wanted = Self.data(helperPath: helperPath)
    var entry = stat()
    if lstat(fileURL.path, &entry) == 0 {
      switch entry.st_mode & S_IFMT {
      case S_IFREG:
        if EntryFolder.read(fileURL) == wanted { return .unchanged }
      case S_IFLNK:
        break  // replaced by the rename below, never followed
      default:
        throw ManifestError.notAFile
      }
    }
    let temporary = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString).tmp")
    let descriptor = Darwin.open(
      temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else { throw ManifestError.write }
    // The umask must not make it unreadable for Chrome.
    fchmod(descriptor, 0o644)
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: wanted)
      try handle.synchronize()
    } catch {
      unlink(temporary.path)
      throw ManifestError.write
    }
    guard rename(temporary.path, fileURL.path) == 0 else {
      unlink(temporary.path)
      throw ManifestError.write
    }
    return .installed
  }

  public enum RemoveResult: Equatable, Sendable {
    case removed
    /// There was nothing to remove.
    case absent
  }

  /// Removes only our manifest (idempotent); the folder and other programs'
  /// manifests stay as they were.
  @discardableResult
  public func remove() throws -> RemoveResult {
    var entry = stat()
    guard lstat(fileURL.path, &entry) == 0 else { return .absent }
    let type = entry.st_mode & S_IFMT
    guard type == S_IFREG || type == S_IFLNK else { throw ManifestError.notAFile }
    guard unlink(fileURL.path) == 0 else {
      if errno == ENOENT { return .absent }
      throw ManifestError.remove
    }
    return .removed
  }
}
