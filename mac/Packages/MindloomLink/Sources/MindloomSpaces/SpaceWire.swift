import Foundation
import MindloomLink

// The Spark's answers on the space routes (its `spaces_api.py`). Decoding is
// tolerant where a newer service may add fields; ids are compared lowercase.

public enum SpaceRole: String, Codable, CaseIterable, Comparable, Sendable {
  case read, write, maintain, admin

  var rank: Int {
    switch self {
    case .read: 1
    case .write: 2
    case .maintain: 3
    case .admin: 4
    }
  }

  public static func < (lhs: SpaceRole, rhs: SpaceRole) -> Bool { lhs.rank < rhs.rank }

  /// 只读 / 贡献 / 维护 / 管理.
  public var title: String {
    switch self {
    case .read: "只读"
    case .write: "贡献"
    case .maintain: "维护"
    case .admin: "管理"
    }
  }
}

/// A space's policy; every field optional on the wire (`space.policy` may be partial).
public struct SpacePolicy: Codable, Equatable, Sendable {
  /// Hours after the first share during which the contributor may withdraw;
  /// nil = any time (group spaces).
  public var withdrawWindowHours: Int?
  public var takedownWindowHours: Int
  public var forksAllowed: Bool
  /// `members` (originals readable by members) or `text_only`.
  public var originals: String
  /// `keep` (org spaces) or `contributor_choice` (group spaces).
  public var onLeave: String
  /// Each member's storage in the space, in MB (0 = none; nil = the Spark's default).
  public var memberQuotaMB: Int?
  /// Members may share a meeting part's audio (v8 C1; on unless switched off).
  public var segmentAudio: Bool

  public init(
    withdrawWindowHours: Int?, takedownWindowHours: Int = 72, forksAllowed: Bool,
    originals: String = "members", onLeave: String, memberQuotaMB: Int? = nil,
    segmentAudio: Bool = true
  ) {
    self.withdrawWindowHours = withdrawWindowHours
    self.takedownWindowHours = takedownWindowHours
    self.forksAllowed = forksAllowed
    self.originals = originals
    self.onLeave = onLeave
    self.memberQuotaMB = memberQuotaMB
    self.segmentAudio = segmentAudio
  }

  /// The Spark's defaults: an org space keeps contributions (a 24 h withdraw
  /// window, no forks); a group space follows shared-album rules.
  public static let org = SpacePolicy(
    withdrawWindowHours: 24, forksAllowed: false, onLeave: "keep")
  public static let group = SpacePolicy(
    withdrawWindowHours: nil, forksAllowed: true, onLeave: "contributor_choice")

  public var originalsForMembers: Bool { originals != "text_only" }

  enum CodingKeys: String, CodingKey {
    case withdrawWindowHours = "withdraw_window_h"
    case takedownWindowHours = "takedown_window_h"
    case forksAllowed = "forks_allowed"
    case originals
    case onLeave = "on_leave"
    case memberQuotaMB = "member_quota_mb"
    case segmentAudio = "segment_audio"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    withdrawWindowHours = try c.decodeIfPresent(Int.self, forKey: .withdrawWindowHours)
    takedownWindowHours = try c.decodeIfPresent(Int.self, forKey: .takedownWindowHours) ?? 72
    forksAllowed = try c.decodeIfPresent(Bool.self, forKey: .forksAllowed) ?? false
    originals = try c.decodeIfPresent(String.self, forKey: .originals) ?? "members"
    onLeave = try c.decodeIfPresent(String.self, forKey: .onLeave) ?? "keep"
    memberQuotaMB = try c.decodeIfPresent(Int.self, forKey: .memberQuotaMB)
    segmentAudio = try c.decodeIfPresent(Bool.self, forKey: .segmentAudio) ?? true
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    // `null` is meaningful for the window (no window).
    try c.encode(withdrawWindowHours, forKey: .withdrawWindowHours)
    try c.encode(takedownWindowHours, forKey: .takedownWindowHours)
    try c.encode(forksAllowed, forKey: .forksAllowed)
    try c.encode(originals, forKey: .originals)
    try c.encode(onLeave, forKey: .onLeave)
    // Absent means the Spark's default; only an explicit quota is sent.
    try c.encodeIfPresent(memberQuotaMB, forKey: .memberQuotaMB)
    try c.encode(segmentAudio, forKey: .segmentAudio)
  }

  public var json: SpaceJSON { (try? SpaceJSON.from(self)) ?? [:] }
}

/// One op's answer in a batch.
public struct SpaceOpResult: Decodable, Equatable, Sendable {
  public let ok: Bool
  public let opID: String?
  public let duplicate: Bool?
  public let seq: Int?
  public let effects: SpaceJSON?
  public let status: Int?
  public let error: String?
  public let detail: String?
  /// What an outbox does with a refused op (v8 C3): `remake`, `later` or `never`.
  public let retry: String?
  /// A remade op the Spark took as the one it already has (`share_key`,
  /// `withdrawn`, `open_takedown`).
  public let acceptedAs: String?

  enum CodingKeys: String, CodingKey {
    case ok
    case opID = "op_id"
    case duplicate, seq, effects, status, error, detail, retry
    case acceptedAs = "accepted_as"
  }

  public init(
    ok: Bool, opID: String? = nil, duplicate: Bool? = nil, seq: Int? = nil,
    effects: SpaceJSON? = nil,
    status: Int? = nil, error: String? = nil, detail: String? = nil, retry: String? = nil,
    acceptedAs: String? = nil
  ) {
    self.ok = ok
    self.opID = opID
    self.duplicate = duplicate
    self.seq = seq
    self.effects = effects
    self.status = status
    self.error = error
    self.detail = detail
    self.retry = retry
    self.acceptedAs = acceptedAs
  }

  /// What the share outbox does with this result (`space_member.outbox_action`).
  public var outboxAction: SpaceOutboxAction {
    if ok { return .done }
    switch retry ?? "never" {
    case "remake": return .remake
    case "later": return .later
    default: return .drop
    }
  }
}

public enum SpaceOutboxAction: String, Sendable {
  /// Accepted now or before: the entry leaves the outbox.
  case done
  /// Sync the keys, make a new op for the same entry (same share key).
  case remake
  /// Send the very same op again later.
  case later
  /// Refused for good: drop it and tell the user.
  case drop
}

public struct SpaceOpsAnswer: Decodable, Sendable {
  public let results: [SpaceOpResult]
  public let head: Int?
}

public struct SpaceListEntry: Decodable, Equatable, Sendable {
  public let spaceID: String
  public let ownerKind: String
  public let orgID: String?
  public let memberID: String
  public let status: String
  public let role: String?
  public let epoch: Int
  public let archived: Bool
  public let head: Int

  enum CodingKeys: String, CodingKey {
    case spaceID = "space_id"
    case ownerKind = "owner_kind"
    case orgID = "org_id"
    case memberID = "member_id"
    case status, role, epoch, archived, head
  }
}

public struct SpaceList: Decodable, Sendable {
  public struct Org: Decodable, Equatable, Sendable {
    public let orgID: String
    public let memberID: String
    public let admin: Bool
    enum CodingKeys: String, CodingKey {
      case orgID = "org_id"
      case memberID = "member_id"
      case admin
    }
  }

  public struct PendingJoin: Decodable, Equatable, Sendable {
    public let spaceID: String
    public let requestID: String
    public let status: String
    enum CodingKeys: String, CodingKey {
      case spaceID = "space_id"
      case requestID = "request_id"
      case status
    }
  }

  public let deviceID: String
  public let spaces: [SpaceListEntry]
  public let orgs: [Org]
  public let pendingJoins: [PendingJoin]

  enum CodingKeys: String, CodingKey {
    case deviceID = "device_id"
    case spaces, orgs
    case pendingJoins = "pending_joins"
  }
}

public struct SpaceMemberRecord: Codable, Equatable, Sendable {
  public let memberID: String
  public let role: String
  public let effectiveRole: String?
  public let outside: Bool
  public let status: String
  public let owner: Bool
  public let orgAdmin: Bool
  public let joinedAt: String?
  public let endedAt: String?
  public let devices: [SpaceDevicePublic]
  /// What this member stores here (admins see it for everyone).
  public let usageBytes: Int?

  enum CodingKeys: String, CodingKey {
    case memberID = "member_id"
    case role
    case effectiveRole = "effective_role"
    case outside, status, owner
    case orgAdmin = "org_admin"
    case joinedAt = "joined_at"
    case endedAt = "ended_at"
    case devices
    case usageBytes = "usage_bytes"
  }

  public var isActive: Bool { status == "active" }
  public var effective: SpaceRole { SpaceRole(rawValue: effectiveRole ?? role) ?? .read }
}

public struct SpaceSummary: Decodable, Sendable {
  public struct Owner: Decodable, Equatable, Sendable {
    public let kind: String
    public let memberID: String?
    public let orgID: String?
    enum CodingKeys: String, CodingKey {
      case kind
      case memberID = "member_id"
      case orgID = "org_id"
    }
  }

  public struct Me: Decodable, Equatable, Sendable {
    public let memberID: String
    public let deviceID: String
    public let role: String
    public let rights: [String]
    public let hidden: [String]
    public let forks: [String]
    public let usage: SpaceUsage?
    enum CodingKeys: String, CodingKey {
      case memberID = "member_id"
      case deviceID = "device_id"
      case role, rights, hidden, forks, usage
    }
  }

  public struct Counts: Decodable, Equatable, Sendable {
    public let items: Int
    public let openTakedowns: Int
    public let openProposals: Int
    public let pendingJoins: Int
    enum CodingKeys: String, CodingKey {
      case items
      case openTakedowns = "open_takedowns"
      case openProposals = "open_proposals"
      case pendingJoins = "pending_joins"
    }
  }

  public struct Organizer: Decodable, Equatable, Sendable {
    public let locked: Bool?
    public let keyID: String?
    public let epoch: Int?
    public let leaseHolder: SpaceJSON?
    public let leaseS: Int?
    enum CodingKeys: String, CodingKey {
      case locked
      case keyID = "key_id"
      case epoch
      case leaseHolder = "lease_holder"
      case leaseS = "lease_s"
    }
  }

  public let spaceID: String
  public let owner: Owner
  public let policy: SpacePolicy
  public let epoch: Int
  public let rotationPending: Bool
  public let archived: Bool
  public let head: Int
  public let createdAt: String?
  public let members: [SpaceMemberRecord]
  public let me: Me
  public let counts: Counts?
  public let organizer: Organizer?
  /// Org spaces: who can open the current key and which admin devices lack a wrap.
  public let escrow: SpaceEscrowStatus?
  public let limits: SpaceLimits?

  enum CodingKeys: String, CodingKey {
    case spaceID = "space_id"
    case owner, policy, epoch
    case rotationPending = "rotation_pending"
    case archived, head
    case createdAt = "created_at"
    case members, me, counts, organizer, escrow, limits
  }
}

/// `me.usage`: this member's storage in the space against its quota.
public struct SpaceUsage: Codable, Equatable, Sendable {
  public let bytes: Int
  public let quotaBytes: Int?

  public init(bytes: Int, quotaBytes: Int?) {
    self.bytes = bytes
    self.quotaBytes = quotaBytes
  }

  enum CodingKeys: String, CodingKey {
    case bytes
    case quotaBytes = "quota_bytes"
  }

  /// "已用 12 MB / 2048 MB" (or without a ceiling).
  public var text: String {
    let used = SpaceUsage.megabytes(bytes)
    guard let quotaBytes else { return "已用 \(used)（不限）" }
    return "已用 \(used) / \(SpaceUsage.megabytes(quotaBytes))"
  }

  public var fraction: Double? {
    guard let quotaBytes, quotaBytes > 0 else { return nil }
    return min(1, Double(bytes) / Double(quotaBytes))
  }

  public static func megabytes(_ bytes: Int) -> String {
    let mb = Double(bytes) / 1_048_576
    if mb < 0.1, bytes > 0 { return "不到 0.1 MB" }
    return mb < 10 ? String(format: "%.1f MB", mb) : "\(Int(mb.rounded())) MB"
  }
}

/// `escrow` of an org space (v8 B5).
public struct SpaceEscrowStatus: Codable, Equatable, Sendable {
  public struct Missing: Codable, Equatable, Sendable {
    public let deviceID: String
    public let memberID: String
    public let sealPub: String
    enum CodingKeys: String, CodingKey {
      case deviceID = "device_id"
      case memberID = "member_id"
      case sealPub = "seal_pub"
    }
  }

  public let policy: Int
  public let required: Int
  public let holders: [String]
  public let missing: [Missing]
  public let ok: Bool

  public init(policy: Int, required: Int, holders: [String], missing: [Missing], ok: Bool) {
    self.policy = policy
    self.required = required
    self.holders = holders
    self.missing = missing
    self.ok = ok
  }
}

/// `limits`: the numbers the Spark enforces, checked before sending.
public struct SpaceLimits: Codable, Equatable, Sendable {
  public let segmentMS: Int
  public let audioBytesPerS: Int
  public let audioOverheadBytes: Int
  public let blobBytes: Int
  public let blobsPerItem: Int
  public let opsPerPost: Int
  public let snapshotCites: Int

  public static let standard = SpaceLimits(
    segmentMS: 15 * 60 * 1000, audioBytesPerS: 32_000, audioOverheadBytes: 65_536,
    blobBytes: 36_000_000, blobsPerItem: 20, opsPerPost: 50, snapshotCites: 500)

  public init(
    segmentMS: Int, audioBytesPerS: Int, audioOverheadBytes: Int, blobBytes: Int,
    blobsPerItem: Int, opsPerPost: Int, snapshotCites: Int
  ) {
    self.segmentMS = segmentMS
    self.audioBytesPerS = audioBytesPerS
    self.audioOverheadBytes = audioOverheadBytes
    self.blobBytes = blobBytes
    self.blobsPerItem = blobsPerItem
    self.opsPerPost = opsPerPost
    self.snapshotCites = snapshotCites
  }

  enum CodingKeys: String, CodingKey {
    case segmentMS = "segment_ms"
    case audioBytesPerS = "audio_bytes_per_s"
    case audioOverheadBytes = "audio_overhead_bytes"
    case blobBytes = "blob_bytes"
    case blobsPerItem = "blobs_per_item"
    case opsPerPost = "ops_per_post"
    case snapshotCites = "snapshot_cites"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Self.standard
    segmentMS = try c.decodeIfPresent(Int.self, forKey: .segmentMS) ?? d.segmentMS
    audioBytesPerS = try c.decodeIfPresent(Int.self, forKey: .audioBytesPerS) ?? d.audioBytesPerS
    audioOverheadBytes =
      try c.decodeIfPresent(Int.self, forKey: .audioOverheadBytes) ?? d.audioOverheadBytes
    blobBytes = try c.decodeIfPresent(Int.self, forKey: .blobBytes) ?? d.blobBytes
    blobsPerItem = try c.decodeIfPresent(Int.self, forKey: .blobsPerItem) ?? d.blobsPerItem
    opsPerPost = try c.decodeIfPresent(Int.self, forKey: .opsPerPost) ?? d.opsPerPost
    snapshotCites = try c.decodeIfPresent(Int.self, forKey: .snapshotCites) ?? d.snapshotCites
  }

  /// The largest ciphertext the Spark takes for an audio part of `ms`.
  public func audioCeiling(ms: Int) -> Int {
    audioOverheadBytes + Int((Double(ms) * Double(audioBytesPerS) / 1000).rounded(.up))
  }
}

/// One entry of `GET …/ops`.
public struct SpaceLogEntry: Decodable, Equatable, Sendable {
  public struct ItemKey: Decodable, Equatable, Sendable {
    public let epoch: Int
    public let wrappedDK: String
    enum CodingKeys: String, CodingKey {
      case epoch
      case wrappedDK = "wrapped_dk"
    }
  }

  public let seq: Int
  public let type: String
  public let appliedAt: String?
  /// base64url of the op's exact JSON bytes.
  public let op: String
  /// nil only for a Spark-written `system.remove`.
  public let sig: String?
  public let enc: String?
  public let purged: Bool
  public let itemKey: ItemKey?
  /// The Spark left `enc` out for this member (a privacy takedown's reason is
  /// for the requester and the maintainers); the op still verifies.
  public let withheld: Bool?

  enum CodingKeys: String, CodingKey {
    case seq, type
    case appliedAt = "applied_at"
    case op, sig, enc, purged
    case itemKey = "item_key"
    case withheld
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    seq = try c.decode(Int.self, forKey: .seq)
    type = try c.decode(String.self, forKey: .type)
    appliedAt = try c.decodeIfPresent(String.self, forKey: .appliedAt)
    op = try c.decode(String.self, forKey: .op)
    sig = try c.decodeIfPresent(String.self, forKey: .sig)
    enc = try c.decodeIfPresent(String.self, forKey: .enc)
    purged = try c.decodeIfPresent(Bool.self, forKey: .purged) ?? false
    itemKey = try c.decodeIfPresent(ItemKey.self, forKey: .itemKey)
    withheld = try c.decodeIfPresent(Bool.self, forKey: .withheld)
  }

  /// The op's JSON bytes and value, or nil when they do not decode.
  public var opBytes: Data? { Base64URL.decode(op, allowPadding: true) }
}

public struct SpaceOpsPage: Decodable, Sendable {
  public let ops: [SpaceLogEntry]
  public let cursor: Int
  public let more: Bool
  public let head: Int
}

public struct SpaceKeys: Decodable, Sendable {
  public struct Wrap: Decodable, Equatable, Sendable {
    public let epoch: Int
    public let wrap: String
  }

  public struct Link: Decodable, Equatable, Sendable {
    public let epoch: Int
    public let prevWrap: String
    enum CodingKeys: String, CodingKey {
      case epoch
      case prevWrap = "prev_wrap"
    }
  }

  public let epoch: Int
  public let rotationPending: Bool
  public let wraps: [Wrap]
  public let epochLinks: [Link]

  enum CodingKeys: String, CodingKey {
    case epoch
    case rotationPending = "rotation_pending"
    case wraps
    case epochLinks = "epoch_links"
  }
}

public struct SpaceItemKeys: Decodable, Sendable {
  public struct Entry: Decodable, Equatable, Sendable {
    public let itemID: String
    public let revision: Int
    public let epoch: Int
    public let wrappedDK: String
    enum CodingKeys: String, CodingKey {
      case itemID = "item_id"
      case revision, epoch
      case wrappedDK = "wrapped_dk"
    }
  }

  public let epoch: Int
  public let items: [Entry]
}

public struct SpaceJoinRequestRecord: Decodable, Equatable, Sendable {
  public let requestID: String
  public let inviteID: String?
  public let memberID: String
  public let device: SpaceDevicePublic
  public let profile: String?
  public let status: String
  public let createdAt: String?
  public let role: String?
  public let outside: Bool?
  /// The signed request bytes (base64url) and their signature, and the HMAC
  /// binding only an invite holder can make (checked by the inviter's Mac).
  public let request: String?
  public let sig: String?
  public let binding: String?

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case inviteID = "invite_id"
    case memberID = "member_id"
    case device, profile, status
    case createdAt = "created_at"
    case role, outside, request, sig, binding
  }
}

public struct SpaceJoinStatus: Decodable, Equatable, Sendable {
  public let requestID: String
  public let status: String
  public let memberID: String?
  public let role: String?
  public let epoch: Int?

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case status
    case memberID = "member_id"
    case role, epoch
  }
}

public struct SpaceInviteRecord: Decodable, Equatable, Sendable {
  public let inviteID: String
  public let role: String
  public let outside: Bool?
  public let hostKey: String?
  public let expiresAt: String?
  public let status: String
  public let requestID: String?

  enum CodingKeys: String, CodingKey {
    case inviteID = "invite_id"
    case role, outside
    case hostKey = "host_key"
    case expiresAt = "expires_at"
    case status
    case requestID = "request_id"
  }
}

public struct SpaceTakedownRecord: Decodable, Equatable, Sendable {
  public let takedownID: String
  public let itemID: String
  public let kind: String
  public let requester: String?
  public let status: String
  public let createdAt: String?
  public let dueAt: String?
  public let overdue: Bool?

  enum CodingKeys: String, CodingKey {
    case takedownID = "takedown_id"
    case itemID = "item_id"
    case kind, requester, status
    case createdAt = "created_at"
    case dueAt = "due_at"
    case overdue
  }
}

public struct SpaceProposalRecord: Decodable, Equatable, Sendable {
  public let proposalID: String
  public let author: String?
  public let kind: String
  public let targets: SpaceJSON?
  public let status: String?
  public let opSeq: Int?
  public let resolvedBy: String?
  /// The organizer's own proposals carry its v6 question.
  public let question: SpaceJSON?

  enum CodingKeys: String, CodingKey {
    case proposalID = "proposal_id"
    case author, kind, targets, status
    case opSeq = "op_seq"
    case resolvedBy = "resolved_by"
    case question
  }
}

public struct SpaceProposals: Decodable, Sendable {
  public let proposals: [SpaceProposalRecord]
  public let organizer: [SpaceProposalRecord]
}

/// One audit record: ids, counts and codes only, never content.
public struct SpaceAuditRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: Int
  public let spaceID: String?
  public let orgID: String?
  public let seq: Int?
  public let at: String
  public let actorMember: String?
  public let actorDevice: String?
  public let action: String
  public let target: SpaceJSON?

  enum CodingKeys: String, CodingKey {
    case id
    case spaceID = "space_id"
    case orgID = "org_id"
    case seq, at
    case actorMember = "actor_member"
    case actorDevice = "actor_device"
    case action, target
  }
}

public struct SpaceAuditPage: Decodable, Sendable {
  public let records: [SpaceAuditRecord]
  public let cursor: Int?
}

public struct SpaceLease: Decodable, Equatable, Sendable {
  public let locked: Bool
  public let keyID: String?
  public let created: Bool?
  public let storeID: String?
  public let epoch: Int?
  public let leaseS: Int?
  public let purged: Int?

  enum CodingKeys: String, CodingKey {
    case locked
    case keyID = "key_id"
    case created
    case storeID = "store_id"
    case epoch
    case leaseS = "lease_s"
    case purged
  }
}

public struct SpacePendingItem: Decodable, Equatable, Sendable {
  public let itemID: String
  public let revision: Int
  public let contributor: String?
  public let kind: String?

  enum CodingKeys: String, CodingKey {
    case itemID = "item_id"
    case revision, contributor, kind
  }
}

/// "同一件事": which personal matter of which member a shared matter holds items from.
public struct SpaceSameAs: Codable, Equatable, Sendable {
  public let eventID: String
  public let memberID: String
  public let matterID: String
  public let items: Int

  public init(eventID: String, memberID: String, matterID: String, items: Int) {
    self.eventID = eventID
    self.memberID = memberID
    self.matterID = matterID
    self.items = items
  }

  enum CodingKeys: String, CodingKey {
    case eventID = "event_id"
    case memberID = "member_id"
    case matterID = "matter_id"
    case items
  }
}

/// One org space's escrow wrap for the asking admin device (`GET /v1/orgs/{id}/escrow`).
public struct SpaceEscrowWrap: Decodable, Equatable, Sendable {
  public let spaceID: String
  public let epoch: Int
  public let wrap: String?
  public let rotationPending: Bool

  enum CodingKeys: String, CodingKey {
    case spaceID = "space_id"
    case epoch, wrap
    case rotationPending = "rotation_pending"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    spaceID = try c.decode(String.self, forKey: .spaceID)
    epoch = try c.decode(Int.self, forKey: .epoch)
    wrap = try c.decodeIfPresent(String.self, forKey: .wrap)
    rotationPending = try c.decodeIfPresent(Bool.self, forKey: .rotationPending) ?? false
  }
}
