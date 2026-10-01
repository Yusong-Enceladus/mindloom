import Darwin
import Foundation
import MindloomLink

/// One thing this Mac still has to deliver to a space (v8 C3): a share (the
/// item, its originals and the signed op as last made) or another signed op
/// (a withdraw, a delete, a matter package). Written before anything is sent,
/// so a quit, a crash or a link that is down loses nothing; sent again after
/// reconnecting, driven by the Spark's `retry` and `accepted_as`.
///
/// Rule (the Spark's): a retry of the same entry keeps its revision and
/// `share_key`; changed content is a new entry with a new revision and key.
public struct SpaceOutboxEntry: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case share
    case op
  }

  public struct Original: Codable, Equatable, Sendable {
    public let role: String
    /// File name in the outbox folder (the plain original, this Mac only).
    public let file: String
  }

  public struct Upload: Codable, Equatable, Sendable {
    public let blobID: String
    public let role: String
    /// File name of the sealed bytes (`MLB1…`) in the outbox folder.
    public let file: String
    public var uploaded: Bool
  }

  public struct Wire: Codable, Equatable, Sendable {
    public let opID: String
    public let type: String
    public let opJSON: String
    public let signature: String
    public let enc: String?
    public let wrappedDK: String?

    public init(_ op: SpaceWireOp) {
      opID = op.opID
      type = op.type
      opJSON = Base64URL.encode(op.opJSON)
      signature = op.signature
      enc = op.enc
      wrappedDK = op.wrappedDK
    }

    public var op: SpaceWireOp? {
      Base64URL.decode(opJSON).map {
        SpaceWireOp(
          opID: opID, type: type, opJSON: $0, signature: signature, enc: enc, wrappedDK: wrappedDK)
      }
    }
  }

  /// The share key (for a share) or a fresh id (another op).
  public let entryID: String
  public let kind: Kind
  /// What the user sees in the queue ("周四复测机械臂", "撤回 1 条").
  public var label: String
  public var itemID: String?
  public var revision: Int?
  public var itemKind: String?
  public var fields: SpaceItemFields?
  public var segment: SpaceSegmentRef?
  public var snapshot: SpaceSnapshotRef?
  public var packageID: String?
  public var originals: [Original]
  public var uploads: [Upload]
  /// For `.op`: the op's type, plain body and the plaintext of its `enc`.
  public var opType: String?
  public var body: SpaceJSON?
  public var encPlain: SpaceJSON?
  public var wire: Wire?
  public var needsRemake: Bool
  public var attempts: Int
  public var lastError: String?
  public var createdAt: Date

  public var id: String { entryID }

  public init(
    entryID: String, kind: Kind, label: String, createdAt: Date, itemID: String? = nil,
    revision: Int? = nil, itemKind: String? = nil, fields: SpaceItemFields? = nil,
    segment: SpaceSegmentRef? = nil, snapshot: SpaceSnapshotRef? = nil, packageID: String? = nil,
    opType: String? = nil, body: SpaceJSON? = nil, encPlain: SpaceJSON? = nil
  ) {
    self.entryID = entryID.lowercased()
    self.kind = kind
    self.label = label
    self.itemID = itemID?.lowercased()
    self.revision = revision
    self.itemKind = itemKind
    self.fields = fields
    self.segment = segment
    self.snapshot = snapshot
    self.packageID = packageID
    originals = []
    uploads = []
    self.opType = opType
    self.body = body
    self.encPlain = encPlain
    wire = nil
    needsRemake = true
    attempts = 0
    lastError = nil
    self.createdAt = createdAt
  }
}

/// An entry the Spark refused for good (shown once, then dismissed).
public struct SpaceOutboxFailure: Codable, Equatable, Identifiable, Sendable {
  public let entryID: String
  public let label: String
  public let code: String
  public let at: Date

  public var id: String { entryID }

  public init(entryID: String, label: String, code: String, at: Date) {
    self.entryID = entryID
    self.label = label
    self.code = code
    self.at = at
  }
}

public struct SpaceOutboxContents: Codable, Equatable, Sendable {
  public var entries: [SpaceOutboxEntry]
  public var failures: [SpaceOutboxFailure]

  public init(entries: [SpaceOutboxEntry] = [], failures: [SpaceOutboxFailure] = []) {
    self.entries = entries
    self.failures = failures
  }
}

public protocol SpaceOutboxStore: Sendable {
  func contents(_ spaceID: String) throws -> SpaceOutboxContents
  func save(_ contents: SpaceOutboxContents, space spaceID: String) throws
  func file(_ name: String, space spaceID: String) throws -> Data?
  func saveFile(_ data: Data, name: String, space spaceID: String) throws
  func deleteFile(_ name: String, space spaceID: String) throws
}

public final class MemorySpaceOutboxStore: SpaceOutboxStore, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String: SpaceOutboxContents] = [:]
  private var files: [String: Data] = [:]

  public init() {}

  public func contents(_ spaceID: String) throws -> SpaceOutboxContents {
    lock.withLock { stored[spaceID.lowercased()] ?? SpaceOutboxContents() }
  }

  public func save(_ contents: SpaceOutboxContents, space spaceID: String) throws {
    lock.withLock { stored[spaceID.lowercased()] = contents }
  }

  public func file(_ name: String, space spaceID: String) throws -> Data? {
    lock.withLock { files["\(spaceID.lowercased())/\(name)"] }
  }

  public func saveFile(_ data: Data, name: String, space spaceID: String) throws {
    lock.withLock { files["\(spaceID.lowercased())/\(name)"] = data }
  }

  public func deleteFile(_ name: String, space spaceID: String) throws {
    lock.withLock { files["\(spaceID.lowercased())/\(name)"] = nil }
  }

  public var fileCount: Int { lock.withLock { files.count } }
}

/// The outbox as files inside the space's own folder
/// (`<spaces>/<space_id>/outbox/`, 0700 / 0600, written atomically): it goes
/// with the space when access ends.
public struct FileSpaceOutboxStore: SpaceOutboxStore {
  public let directory: URL

  public init(directory: URL) { self.directory = directory.standardizedFileURL }

  private func folder(_ spaceID: String) throws -> URL {
    let id = spaceID.lowercased()
    guard SpaceID.isValid(id) else { throw SpaceStoreError.unreadable }
    return directory.appendingPathComponent(id, isDirectory: true)
      .appendingPathComponent("outbox", isDirectory: true)
  }

  private func ensure(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  public func contents(_ spaceID: String) throws -> SpaceOutboxContents {
    let url = try folder(spaceID).appendingPathComponent("outbox.json")
    guard let data = try? Data(contentsOf: url) else { return SpaceOutboxContents() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    guard let contents = try? decoder.decode(SpaceOutboxContents.self, from: data) else {
      throw SpaceStoreError.unreadable
    }
    return contents
  }

  public func save(_ contents: SpaceOutboxContents, space spaceID: String) throws {
    let dir = try folder(spaceID)
    if contents.entries.isEmpty, contents.failures.isEmpty {
      let url = dir.appendingPathComponent("outbox.json")
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
      return
    }
    try ensure(dir)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    try FileSpaceStateStore.write(
      try encoder.encode(contents), to: dir.appendingPathComponent("outbox.json"))
  }

  private func fileURL(_ name: String, _ spaceID: String) throws -> URL {
    guard !name.isEmpty, name.count <= 80, !name.hasPrefix("."),
      name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
    else { throw SpaceStoreError.unreadable }
    return try folder(spaceID).appendingPathComponent("files", isDirectory: true)
      .appendingPathComponent(name)
  }

  public func file(_ name: String, space spaceID: String) throws -> Data? {
    try? Data(contentsOf: fileURL(name, spaceID))
  }

  public func saveFile(_ data: Data, name: String, space spaceID: String) throws {
    let url = try fileURL(name, spaceID)
    try ensure(url.deletingLastPathComponent())
    try FileSpaceStateStore.write(data, to: url)
  }

  public func deleteFile(_ name: String, space spaceID: String) throws {
    let url = try fileURL(name, spaceID)
    guard unlink(url.path) == 0 || errno == ENOENT else { throw SpaceStoreError.unreadable }
  }
}
