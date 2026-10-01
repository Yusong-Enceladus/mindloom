import CryptoKit
import Darwin
import Foundation

/// An item's member-visible fields: the `enc` of its `item.share`, under the
/// item's own data key. Numbers are as they are (members were meant to see
/// them); the Spark never sees these fields. Every field is optional on
/// decode, so a newer or older Mac's fields still open.
public struct SpaceItemFields: Codable, Equatable, Sendable {
  public struct Segment: Codable, Equatable, Sendable {
    public var startMS: Int64
    public var endMS: Int64
    public var speaker: String?
    public var text: String

    public init(startMS: Int64, endMS: Int64, speaker: String?, text: String) {
      self.startMS = startMS
      self.endMS = endMS
      self.speaker = speaker
      self.text = text
    }

    enum CodingKeys: String, CodingKey {
      case startMS = "start_ms"
      case endMS = "end_ms"
      case speaker, text
    }
  }

  public var v: Int?
  public var kind: String?
  public var title: String?
  public var text: String?
  public var sourceName: String?
  public var sourceBundleID: String?
  public var startedAt: String?
  public var endedAt: String?
  /// Display names only; never a voice cluster id.
  public var persons: [String]?
  public var segments: [Segment]?
  public var filename: String?
  public var mediaType: String?
  public var sizeBytes: Int64?
  /// What the contributor's Mac read from a screenshot or file.
  public var reading: String?
  /// A segment's recording: its kind (`meeting_offline` …) and title.
  public var parentKind: String?
  public var parentTitle: String?
  /// The contributor's personal matter this came from (for "同一件事").
  public var originMatterID: String?

  public init(
    kind: String?, title: String?, text: String? = nil, sourceName: String? = nil,
    sourceBundleID: String? = nil, startedAt: String? = nil, endedAt: String? = nil,
    persons: [String]? = nil, segments: [Segment]? = nil, filename: String? = nil,
    mediaType: String? = nil, sizeBytes: Int64? = nil, reading: String? = nil,
    parentKind: String? = nil, parentTitle: String? = nil, originMatterID: String? = nil
  ) {
    v = 1
    self.kind = kind
    self.title = title
    self.text = text
    self.sourceName = sourceName
    self.sourceBundleID = sourceBundleID
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.persons = persons
    self.segments = segments
    self.filename = filename
    self.mediaType = mediaType
    self.sizeBytes = sizeBytes
    self.reading = reading
    self.parentKind = parentKind
    self.parentTitle = parentTitle
    self.originMatterID = originMatterID
  }

  enum CodingKeys: String, CodingKey {
    case v, kind, title, text
    case sourceName = "source_name"
    case sourceBundleID = "source_bundle_id"
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case persons, segments, filename
    case mediaType = "media_type"
    case sizeBytes = "size_bytes"
    case reading
    case parentKind = "parent_kind"
    case parentTitle = "parent_title"
    case originMatterID = "origin_matter_id"
  }

  /// Every text a member reads in these fields (for search and for the
  /// placeholder map that puts numbers back into the organizer's words).
  public var texts: [String] {
    var out = [title, text, reading, filename, parentTitle, sourceName].compactMap { $0 }
    out += persons ?? []
    out += (segments ?? []).flatMap { [$0.text] + ($0.speaker.map { [$0] } ?? []) }
    return out
  }
}

public struct SpaceBlobRef: Codable, Equatable, Hashable, Sendable {
  public let blobID: String
  /// `original`, `image`, `file`, `audio` or `preview`.
  public let role: String

  public init(blobID: String, role: String) {
    self.blobID = blobID
    self.role = role
  }

  enum CodingKeys: String, CodingKey {
    case blobID = "blob_id"
    case role
  }
}

public struct SpaceSegmentRef: Codable, Equatable, Sendable {
  public let parentItemID: String
  public let startMS: Int
  public let endMS: Int

  public init(parentItemID: String, startMS: Int, endMS: Int) {
    self.parentItemID = parentItemID.lowercased()
    self.startMS = startMS
    self.endMS = endMS
  }

  enum CodingKeys: String, CodingKey {
    case parentItemID = "parent_item_id"
    case startMS = "start_ms"
    case endMS = "end_ms"
  }
}

/// One item in a space as this Mac knows it.
public struct SpaceSharedItem: Codable, Equatable, Identifiable, Sendable {
  public enum Status: String, Codable, Sendable {
    case active
    /// The contributor took it back (its data key is gone from the Spark).
    case withdrawn
    /// A maintainer removed it, or the Spark did for an overdue privacy takedown.
    case removed
  }

  public let itemID: String
  public var contributor: String
  public var kind: String
  public var revision: Int
  public var shareSeq: Int
  public var firstSharedAt: Date
  public var updatedAt: Date
  /// nil until opened (or after the item left the space).
  public var fields: SpaceItemFields?
  public var blobs: [SpaceBlobRef]
  public var segment: SpaceSegmentRef?
  public var packageID: String?
  public var status: Status
  /// The epoch its data key is wrapped under on the Spark.
  public var keyEpoch: Int?
  /// The device whose op shared it (this Mac withdraws only what it shared).
  public var deviceID: String?

  public var id: String { itemID }
  public var isActive: Bool { status == .active }

  public init(
    itemID: String, contributor: String, kind: String, revision: Int, shareSeq: Int,
    firstSharedAt: Date, updatedAt: Date, fields: SpaceItemFields?, blobs: [SpaceBlobRef],
    segment: SpaceSegmentRef?, packageID: String?, status: Status, keyEpoch: Int?
  ) {
    self.itemID = itemID.lowercased()
    self.contributor = contributor
    self.kind = kind
    self.revision = revision
    self.shareSeq = shareSeq
    self.firstSharedAt = firstSharedAt
    self.updatedAt = updatedAt
    self.fields = fields
    self.blobs = blobs
    self.segment = segment
    self.packageID = packageID
    self.status = status
    self.keyEpoch = keyEpoch
  }
}

public struct SpaceMember: Codable, Equatable, Identifiable, Sendable {
  public let memberID: String
  public var displayName: String?
  public var role: SpaceRole
  public var status: String
  public var outside: Bool
  public var owner: Bool
  public var orgAdmin: Bool
  public var joinedAt: String?
  public var endedAt: String?
  public var devices: [SpaceDevicePublic]

  public var id: String { memberID }
  public var isActive: Bool { status == "active" }

  public init(record: SpaceMemberRecord, displayName: String?) {
    memberID = record.memberID
    self.displayName = displayName
    role = record.effective
    status = record.status
    outside = record.outside
    owner = record.owner
    orgAdmin = record.orgAdmin
    joinedAt = record.joinedAt
    endedAt = record.endedAt
    devices = record.devices
  }
}

/// A matter shared as a package: its items, the sharer's hints and its rule.
public struct SpacePackage: Codable, Equatable, Sendable {
  public let packageID: String
  public var owner: String
  public var itemIDs: [String]
  public var auto: SpaceRuleMode
  /// Decrypted hints: `title`, `facts`, `matter_id`.
  public var hints: SpaceJSON?
  public var active: Bool

  public var title: String? { hints?["title"]?.string }
  public var matterID: String? { hints?["matter_id"]?.string }
}

/// A rule of this member's own Macs ("以后新归进来的也共享").
public struct SpaceShareRule: Codable, Equatable, Sendable {
  public let ruleID: String
  /// `rope` or `matter`.
  public var kind: String
  public var auto: SpaceRuleMode
  /// Decrypted: `target_id` (the rope or matter id), `title`.
  public var details: SpaceJSON?
  public var active: Bool

  public var targetID: String? { details?["target_id"]?.string }
  public var title: String? { details?["title"]?.string }
}

public struct SpaceTakedown: Codable, Equatable, Sendable {
  public let takedownID: String
  public var itemID: String
  public var kind: String
  public var requester: String?
  public var status: String
  public var reason: String?
  public var createdAt: Date?
  public var dueAt: Date?
}

public struct SpaceProposal: Codable, Equatable, Sendable {
  public let proposalID: String
  public var author: String?
  public var kind: String
  public var targets: SpaceJSON?
  /// Decrypted: the proposed title, the other matter, a note.
  public var details: SpaceJSON?
  public var status: String
  public var resolvedBy: String?
}

public struct SpaceInviteInfo: Codable, Equatable, Sendable {
  public let inviteID: String
  public var role: SpaceRole
  public var expiresAt: Date
  public var status: String
  /// The code, kept only by the admin who made it (to show it again).
  public var code: String?
}

/// The space organizer's latest state as pulled (placeholders, unmasked when shown).
public struct SpaceOrganizerSnapshot: Codable, Equatable, Sendable {
  /// The v6 `/v1/state` JSON as received.
  public var state: Data
  public var sameAs: [SpaceSameAs]
  public var busyQueue: Int
  public var busyBriefs: Int
  public var pulledAt: Date

  public init(state: Data, sameAs: [SpaceSameAs], busyQueue: Int, busyBriefs: Int, pulledAt: Date) {
    self.state = state
    self.sameAs = sameAs
    self.busyQueue = busyQueue
    self.busyBriefs = busyBriefs
    self.pulledAt = pulledAt
  }
}

/// Everything this Mac keeps about one space (in its data root; never sent).
public struct SpaceLocalState: Codable, Equatable, Identifiable, Sendable {
  public enum Membership: String, Codable, Sendable {
    /// Asked to join; waiting for an admin.
    case pending
    case active
    case rejected
  }

  public let spaceID: String
  public var memberID: String
  public var name: String
  public var ownerKind: SpaceOwnerKind
  public var orgID: String?
  public var ownerMemberID: String?
  public var policy: SpacePolicy
  public var role: SpaceRole
  public var rights: [String]
  public var epoch: Int
  public var rotationPending: Bool
  public var archived: Bool
  public var head: Int
  public var cursor: Int
  public var membership: Membership
  public var joinRequestID: String?
  public var spark: SpaceInviteCode.Endpoint?
  public var members: [SpaceMember]
  /// Names other admins approved under (opened from join profiles), until
  /// the member's own `member.profile` arrives.
  public var knownNames: [String: String]
  public var items: [String: SpaceSharedItem]
  public var hidden: Set<String>
  /// Forked items → the id of the local copy in the personal space.
  public var forks: [String: String]
  public var packages: [String: SpacePackage]
  public var rules: [String: SpaceShareRule]
  public var takedowns: [String: SpaceTakedown]
  public var proposals: [String: SpaceProposal]
  public var invites: [String: SpaceInviteInfo]
  /// Matter id → the member who is its 负责人.
  public var handovers: [String: String]
  public var organizer: SpaceOrganizerSnapshot?
  /// Ops whose signature did not verify: never applied (counted, not kept).
  public var rejectedOps: Int
  public var lastSyncedAt: Date?
  /// Members and devices as the signed log admitted them (review V7-S1); the
  /// only source of signing keys and of the devices a rotation wraps to.
  public var roster: SpaceRoster?
  /// What the Spark said that the signed log contradicts (a device no member
  /// admitted, an epoch older than the newest key held …): shown, never used.
  public var integrityWarnings: [String]?
  /// This device's space-key wraps as signed ops carried them (genesis,
  /// approval, rotation), by epoch: the only wraps this Mac unwraps.
  public var signedWraps: [Int: String]?
  /// Items this Mac shared whose local source the user deleted: each still
  /// goes out of the space as `item.delete` (review V7-S12). Kept here so a
  /// quit or a link that is down does not lose it.
  public var pendingDeletes: [String]?

  public var id: String { spaceID }

  public init(
    spaceID: String, memberID: String, name: String, ownerKind: SpaceOwnerKind, orgID: String?,
    policy: SpacePolicy, role: SpaceRole, membership: Membership, spark: SpaceInviteCode.Endpoint?
  ) {
    self.spaceID = spaceID.lowercased()
    self.memberID = memberID.lowercased()
    self.name = name
    self.ownerKind = ownerKind
    self.orgID = orgID
    ownerMemberID = ownerKind == .person ? memberID.lowercased() : nil
    self.policy = policy
    self.role = role
    rights = SpaceRules.rights(role: role, policy: policy)
    epoch = 1
    rotationPending = false
    archived = false
    head = 0
    cursor = 0
    self.membership = membership
    self.spark = spark
    members = []
    knownNames = [:]
    items = [:]
    hidden = []
    forks = [:]
    packages = [:]
    rules = [:]
    takedowns = [:]
    proposals = [:]
    invites = [:]
    handovers = [:]
    rejectedOps = 0
  }

  public func can(_ right: String) -> Bool { rights.contains(right) }

  public var activeItems: [SpaceSharedItem] {
    items.values.filter(\.isActive).sorted { $0.shareSeq < $1.shareSeq }
  }

  public func member(_ id: String?) -> SpaceMember? {
    guard let id else { return nil }
    return members.first { $0.memberID == id.lowercased() }
  }

  /// A member's name as this Mac knows it; "成员" until they named themselves.
  public func name(of memberID: String?) -> String {
    guard let memberID else { return "整理设备" }
    let id = memberID.lowercased()
    if let name = member(id)?.displayName ?? knownNames[id], !name.isEmpty { return name }
    return id == self.memberID ? "我" : "成员"
  }

  public var activeMembers: [SpaceMember] { members.filter(\.isActive) }

  /// Records a contradiction between the Spark's answer and the signed log.
  mutating func warn(_ code: String) {
    var list = integrityWarnings ?? []
    if !list.contains(code) { list.append(code) }
    integrityWarnings = list
  }
}

// MARK: - Stores

public enum SpaceStoreError: Error, Equatable, Sendable {
  case notAllowed
  case unreadable
}

/// Where this Mac keeps its spaces (inside its data root).
public protocol SpaceStateStore: Sendable {
  func states() throws -> [SpaceLocalState]
  func load(_ spaceID: String) throws -> SpaceLocalState?
  func save(_ state: SpaceLocalState) throws
  /// The space and every original kept for it.
  func delete(_ spaceID: String) throws
  func original(space: String, item: String, blob: String) throws -> Data?
  func saveOriginal(_ data: Data, space: String, item: String, blob: String) throws
  func deleteOriginals(space: String, item: String) throws
  /// Local copies ("存一份到我的空间") the App still has to delete, kept
  /// across a quit or a crash after the space's own state is gone (V7-S15).
  func forkCopiesToDelete() throws -> [String]
  func setForkCopiesToDelete(_ ids: [String]) throws
}

/// The space keys this device unwrapped, per epoch. Keychain on a real
/// library; a 0600 file only in a synthetic root.
public protocol SpaceKeyStore: Sendable {
  func keys(_ spaceID: String) throws -> [Int: Data]
  func save(_ key: Data, space spaceID: String, epoch: Int) throws
  func delete(_ spaceID: String) throws
}

/// This device's identity (the signing key is secret; the id is not).
public protocol SpaceDeviceStore: Sendable {
  func load() throws -> SpaceDeviceKeys?
  func save(_ keys: SpaceDeviceKeys) throws
}

public final class MemorySpaceStateStore: SpaceStateStore, @unchecked Sendable {
  private let lock = NSLock()
  private var spaces: [String: SpaceLocalState] = [:]
  private var originals: [String: Data] = [:]

  public init() {}

  public func states() throws -> [SpaceLocalState] {
    lock.withLock { spaces.values.sorted { $0.spaceID < $1.spaceID } }
  }

  public func load(_ spaceID: String) throws -> SpaceLocalState? {
    lock.withLock { spaces[spaceID.lowercased()] }
  }

  public func save(_ state: SpaceLocalState) throws {
    lock.withLock { spaces[state.spaceID] = state }
  }

  public func delete(_ spaceID: String) throws {
    lock.withLock {
      spaces[spaceID.lowercased()] = nil
      originals = originals.filter { !$0.key.hasPrefix(spaceID.lowercased() + "/") }
    }
  }

  public func original(space: String, item: String, blob: String) throws -> Data? {
    lock.withLock { originals["\(space)/\(item)/\(blob)"] }
  }

  public func saveOriginal(_ data: Data, space: String, item: String, blob: String) throws {
    lock.withLock { originals["\(space)/\(item)/\(blob)"] = data }
  }

  public func deleteOriginals(space: String, item: String) throws {
    lock.withLock { originals = originals.filter { !$0.key.hasPrefix("\(space)/\(item)/") } }
  }

  public var originalCount: Int { lock.withLock { originals.count } }

  private var forkDeletes: [String] = []

  public func forkCopiesToDelete() throws -> [String] { lock.withLock { forkDeletes } }

  public func setForkCopiesToDelete(_ ids: [String]) throws { lock.withLock { forkDeletes = ids } }
}

public final class MemorySpaceKeyStore: SpaceKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String: [Int: Data]] = [:]

  public init() {}

  public func keys(_ spaceID: String) throws -> [Int: Data] {
    lock.withLock { stored[spaceID.lowercased()] ?? [:] }
  }

  public func save(_ key: Data, space spaceID: String, epoch: Int) throws {
    lock.withLock { stored[spaceID.lowercased(), default: [:]][epoch] = key }
  }

  public func delete(_ spaceID: String) throws {
    lock.withLock { stored[spaceID.lowercased()] = nil }
  }
}

public final class MemorySpaceDeviceStore: SpaceDeviceStore, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: SpaceDeviceKeys?

  public init(_ keys: SpaceDeviceKeys? = nil) { self.keys = keys }

  public func load() throws -> SpaceDeviceKeys? { lock.withLock { keys } }
  public func save(_ keys: SpaceDeviceKeys) throws { lock.withLock { self.keys = keys } }
}

/// Spaces as files under `<root>/spaces/<space_id>/` (0700 directories, 0600
/// files written atomically). The state holds members' shared content, so
/// it lives in the data root next to the library, never anywhere else.
public struct FileSpaceStateStore: SpaceStateStore {
  public let directory: URL

  public init(directory: URL) {
    self.directory = directory.standardizedFileURL
  }

  private func spaceDirectory(_ spaceID: String) throws -> URL {
    let id = spaceID.lowercased()
    guard SpaceID.isValid(id) else { throw SpaceStoreError.unreadable }
    return directory.appendingPathComponent(id, isDirectory: true)
  }

  private func ensure(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  public func states() throws -> [SpaceLocalState] {
    guard
      let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
    else { return [] }
    return names.filter(SpaceID.isValid).sorted().compactMap { try? load($0) }
  }

  public func load(_ spaceID: String) throws -> SpaceLocalState? {
    let url = try spaceDirectory(spaceID).appendingPathComponent("state.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    guard let state = try? decoder.decode(SpaceLocalState.self, from: data) else {
      throw SpaceStoreError.unreadable
    }
    return state
  }

  public func save(_ state: SpaceLocalState) throws {
    let folder = try spaceDirectory(state.spaceID)
    try ensure(folder)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    try Self.write(try encoder.encode(state), to: folder.appendingPathComponent("state.json"))
  }

  public func delete(_ spaceID: String) throws {
    let folder = try spaceDirectory(spaceID)
    if FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.removeItem(at: folder)
    }
  }

  private func originalURL(space: String, item: String, blob: String) throws -> URL {
    let item = item.lowercased()
    let blob = blob.lowercased()
    guard SpaceID.isValid(item), SpaceID.isValid(blob) else { throw SpaceStoreError.unreadable }
    return try spaceDirectory(space).appendingPathComponent("originals", isDirectory: true)
      .appendingPathComponent(item, isDirectory: true).appendingPathComponent(blob)
  }

  public func original(space: String, item: String, blob: String) throws -> Data? {
    try? Data(contentsOf: originalURL(space: space, item: item, blob: blob))
  }

  public func saveOriginal(_ data: Data, space: String, item: String, blob: String) throws {
    let url = try originalURL(space: space, item: item, blob: blob)
    try ensure(url.deletingLastPathComponent())
    try Self.write(data, to: url)
  }

  public func deleteOriginals(space: String, item: String) throws {
    guard SpaceID.isValid(item.lowercased()) else { return }
    let folder = try spaceDirectory(space).appendingPathComponent("originals", isDirectory: true)
      .appendingPathComponent(item.lowercased(), isDirectory: true)
    if FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.removeItem(at: folder)
    }
  }

  public func forkCopiesToDelete() throws -> [String] {
    let url = directory.appendingPathComponent("fork-copies-to-delete.json")
    guard let data = try? Data(contentsOf: url) else { return [] }
    guard let ids = try? JSONDecoder().decode([String].self, from: data) else {
      throw SpaceStoreError.unreadable
    }
    return ids
  }

  public func setForkCopiesToDelete(_ ids: [String]) throws {
    try ensure(directory)
    try Self.write(
      try JSONEncoder().encode(ids),
      to: directory.appendingPathComponent("fork-copies-to-delete.json"))
  }

  /// Written to a 0600 temporary file in the same directory, then renamed.
  static func write(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).tmp")
    let descriptor = open(
      temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw SpaceStoreError.unreadable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw SpaceStoreError.unreadable }
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
      guard rename(temporary.path, url.path) == 0 else { throw SpaceStoreError.unreadable }
    } catch {
      unlink(temporary.path)
      throw error
    }
  }
}

/// Space keys and the device's signing key as 0600 files: only for a data
/// root the caller has checked is synthetic (tests and end-to-end runs).
/// A real library uses the Keychain stores.
public struct FileSpaceSecretStore: SpaceKeyStore, SpaceDeviceStore {
  public let directory: URL

  /// `allowed` is checked on every access (the synthetic-root rule).
  public init(directory: URL, allowed: @escaping @Sendable () -> Bool) throws {
    guard allowed() else { throw SpaceStoreError.notAllowed }
    self.directory = directory.standardizedFileURL
    self.allowed = allowed
  }

  private let allowed: @Sendable () -> Bool

  private func check() throws {
    guard allowed() else { throw SpaceStoreError.notAllowed }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  private func read(_ name: String) throws -> Data? {
    try check()
    let url = directory.appendingPathComponent(name)
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw SpaceStoreError.unreadable
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_mode & 0o077 == 0
    else { throw SpaceStoreError.unreadable }
    return try handle.readToEnd() ?? Data()
  }

  private func write(_ data: Data, _ name: String) throws {
    try check()
    try FileSpaceStateStore.write(data, to: directory.appendingPathComponent(name))
  }

  public func keys(_ spaceID: String) throws -> [Int: Data] {
    guard let data = try read("space-\(spaceID.lowercased()).keys") else { return [:] }
    guard let map = try? JSONDecoder().decode([String: String].self, from: data) else {
      throw SpaceStoreError.unreadable
    }
    var out: [Int: Data] = [:]
    for (epoch, hex) in map {
      guard let e = Int(epoch), let key = Data(spaceHex: hex), key.count == 32 else {
        throw SpaceStoreError.unreadable
      }
      out[e] = key
    }
    return out
  }

  public func save(_ key: Data, space spaceID: String, epoch: Int) throws {
    var all = try keys(spaceID)
    all[epoch] = key
    let map = Dictionary(uniqueKeysWithValues: all.map { ("\($0.key)", SpaceCrypto.hex($0.value)) })
    try write(try JSONEncoder().encode(map), "space-\(spaceID.lowercased()).keys")
  }

  public func delete(_ spaceID: String) throws {
    try check()
    let url = directory.appendingPathComponent("space-\(spaceID.lowercased()).keys")
    guard unlink(url.path) == 0 || errno == ENOENT else { throw SpaceStoreError.unreadable }
  }

  public func load() throws -> SpaceDeviceKeys? {
    guard let data = try read("space-device.json") else { return nil }
    guard let record = try? JSONDecoder().decode([String: String].self, from: data),
      let id = record["device_id"], SpaceID.isValid(id),
      let sign = record["sign_priv"].flatMap({ Data(spaceHex: $0) }),
      let seal = record["seal_priv"].flatMap({ Data(spaceHex: $0) }),
      let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: sign),
      let sealing = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seal)
    else { throw SpaceStoreError.unreadable }
    return SpaceDeviceKeys(deviceID: id, signingKey: signing, sealKey: sealing)
  }

  public func save(_ keys: SpaceDeviceKeys) throws {
    let record = [
      "device_id": keys.deviceID,
      "sign_priv": SpaceCrypto.hex(keys.signingKey.rawRepresentation),
      "seal_priv": SpaceCrypto.hex(keys.sealKey.rawRepresentation),
    ]
    try write(try JSONEncoder().encode(record), "space-device.json")
  }
}

extension Data {
  /// Lowercase or uppercase hex; nil for anything else.
  public init?(spaceHex hex: String) {
    guard hex.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    self.init(bytes)
  }
}
