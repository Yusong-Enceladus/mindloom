import BestASRDomain
import CryptoKit
import Darwin
import Foundation

/// Copies an item's files into the library before its rows are committed.
///
/// Order: (1) create `sessions/<id>/` (it must not exist) and write the
/// `.intake-staging` marker; (2) copy each file into `source/`, fsync it, and
/// hash it; (3) the caller commits the rows; (4) `commit` removes the marker.
/// If the rows never commit, `discard` removes the directory, and the startup
/// sweep removes any marked directory that has no session row. The user's
/// own file is only read, never moved or deleted.
public struct IntakeAssetStore: Sendable {
  public static let stagingMarkerName = ".intake-staging"

  public enum StoreError: Error, Equatable, Sendable {
    case notARegularFile
    case tooLarge
    case alreadyExists
    case writeFailed
  }

  /// One file to keep with an item.
  public enum Source: Sendable {
    case file(URL)
    case data(Data)
  }

  public struct Request: Sendable {
    public let role: UserItemAttachmentRole
    public let source: Source
    public let originalFilename: String
    public let mediaType: String
    public let fileExtension: String

    public init(
      role: UserItemAttachmentRole, source: Source, originalFilename: String,
      mediaType: String, fileExtension: String
    ) {
      self.role = role
      self.source = source
      self.originalFilename = originalFilename
      self.mediaType = mediaType
      self.fileExtension = fileExtension
    }
  }

  public let assetRoot: URL
  public let maximumBytes: UInt64

  public init(assetRoot: URL, maximumBytes: UInt64 = UserItemLimits.maximumOriginalBytes) {
    self.assetRoot = assetRoot
    self.maximumBytes = maximumBytes
  }

  public func sessionDirectory(_ id: SessionID) -> URL {
    assetRoot.appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent(id.rawValue.uuidString.lowercased(), isDirectory: true)
  }

  /// Copies every requested file; on any failure removes what it created.
  public func stage(sessionID: SessionID, requests: [Request]) throws -> [UserItemAttachment] {
    guard !requests.isEmpty else { return [] }
    let fileManager = FileManager.default
    let directory = sessionDirectory(sessionID)
    guard !fileManager.fileExists(atPath: directory.path) else {
      throw StoreError.alreadyExists
    }
    try fileManager.createDirectory(
      at: directory.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
    do {
      try Self.writeSynchronized(
        Data(), to: directory.appendingPathComponent(Self.stagingMarkerName))
      let sourceDirectory = directory.appendingPathComponent("source", isDirectory: true)
      try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
      var result: [UserItemAttachment] = []
      for request in requests {
        let base: String =
          switch request.role {
          case .original: "original"
          case .normalizedImage: "normalized"
          default: request.role.rawValue
          }
        let ext = Self.safeExtension(request.fileExtension)
        let name = ext.isEmpty ? base : "\(base).\(ext)"
        let destination = sourceDirectory.appendingPathComponent(name)
        let data: Data
        switch request.source {
        case .data(let bytes):
          data = bytes
        case .file(let url):
          data = try readRegularFile(url)
        }
        guard !data.isEmpty else { throw StoreError.notARegularFile }
        guard UInt64(data.count) <= maximumBytes else { throw StoreError.tooLarge }
        try Self.writeSynchronized(data, to: destination)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        result.append(
          UserItemAttachment(
            role: request.role,
            relativePath:
              "sessions/\(sessionID.rawValue.uuidString.lowercased())/source/\(name)",
            originalFilename: request.originalFilename, mediaType: request.mediaType,
            digest: try SHA256Digest(digest), sizeBytes: UInt64(data.count)
          )
        )
      }
      return result
    } catch {
      try? fileManager.removeItem(at: directory)
      throw error
    }
  }

  /// The rows are committed; the directory is now the item's own.
  public func commit(sessionID: SessionID) {
    try? FileManager.default.removeItem(
      at: sessionDirectory(sessionID).appendingPathComponent(Self.stagingMarkerName)
    )
  }

  /// The rows did not commit. Removes the directory only while it is still
  /// marked as staging, so a committed item's files are never touched.
  public func discard(sessionID: SessionID) {
    let directory = sessionDirectory(sessionID)
    guard
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(Self.stagingMarkerName).path
      )
    else { return }
    try? FileManager.default.removeItem(at: directory)
  }

  /// Session IDs whose directory still carries the staging marker.
  public func markedSessionIDs() -> [SessionID] {
    let sessions = assetRoot.appendingPathComponent("sessions", isDirectory: true)
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
    return names.compactMap { name in
      guard let uuid = UUID(uuidString: name),
        FileManager.default.fileExists(
          atPath: sessions.appendingPathComponent(name)
            .appendingPathComponent(Self.stagingMarkerName).path
        )
      else { return nil }
      return SessionID(uuid)
    }
  }

  /// Startup recovery: a marked directory with a committed row loses its
  /// marker; one without a row was never committed and is removed.
  @discardableResult
  public func sweep(existing: Set<SessionID>, marked: [SessionID]) -> Int {
    var removed = 0
    for id in marked {
      if existing.contains(id) {
        commit(sessionID: id)
      } else {
        discard(sessionID: id)
        removed += 1
      }
    }
    return removed
  }

  private func readRegularFile(_ url: URL) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw StoreError.notARegularFile }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var status = stat()
    guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      throw StoreError.notARegularFile
    }
    guard status.st_size > 0 else { throw StoreError.notARegularFile }
    guard UInt64(status.st_size) <= maximumBytes else { throw StoreError.tooLarge }
    return try handle.readToEnd() ?? Data()
  }

  private static func safeExtension(_ value: String) -> String {
    let lowered = value.lowercased()
    guard lowered.count <= 12, lowered.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
    else { return "" }
    return lowered
  }

  private static func writeSynchronized(_ data: Data, to url: URL) throws {
    let descriptor = open(
      url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else { throw StoreError.writeFailed }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try handle.write(contentsOf: data)
    try handle.synchronize()
  }
}
