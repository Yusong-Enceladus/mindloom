import CryptoKit
import Foundation
import MindloomLink

/// Builds one organizing payload for the space organizer: the v6 item JSON
/// with every text masked with the space's mask key (placeholders toward the
/// Spark; members see the numbers in the item's own fields). Images are
/// redacted and shrunk by the builder; nil leaves the item out.
public protocol SpacePayloadBuilding: Sendable {
  func payload(
    item: SpaceSharedItem, fields: SpaceItemFields, maskKey: Data,
    original: @escaping @Sendable (SpaceBlobRef) async throws -> Data?
  ) async throws -> Data?
}

/// One item this Mac shares (after the review list).
public struct SpaceOutgoingItem: Sendable {
  public let itemID: String
  /// A wire kind; never a recording, voiceprint, dictionary or recognition profile.
  public let kind: String
  public let fields: SpaceItemFields
  /// Originals members may open (a file, a screenshot, a segment's audio).
  public let originals: [(role: String, data: Data)]
  public let segment: SpaceSegmentRef?
  /// A frozen summary's sources (`kind: snapshot`, v8 C2).
  public let snapshot: SpaceSnapshotRef?

  public init(
    itemID: String, kind: String, fields: SpaceItemFields,
    originals: [(role: String, data: Data)] = [], segment: SpaceSegmentRef? = nil,
    snapshot: SpaceSnapshotRef? = nil
  ) {
    self.itemID = itemID.lowercased()
    self.kind = kind
    self.fields = fields
    self.originals = originals
    self.segment = segment
    self.snapshot = snapshot
  }

  public var hasAudio: Bool { originals.contains { $0.role == "audio" } }
}

/// A matter shared as a package (its hints are member-only ciphertext).
public struct SpacePackageRequest: Sendable {
  public let packageID: String
  public let auto: SpaceRuleMode
  public let matterID: String?
  public let title: String?
  public let facts: [String]

  public init(
    packageID: String = SpaceID.new(), auto: SpaceRuleMode, matterID: String?, title: String?,
    facts: [String] = []
  ) {
    self.packageID = packageID.lowercased()
    self.auto = auto
    self.matterID = matterID
    self.title = title
    self.facts = facts
  }
}

public struct SpaceShareReport: Equatable, Sendable {
  public var shared: [String] = []
  /// Item id → the Spark's (or this Mac's) reason it was not shared.
  public var refused: [String: String] = [:]
  /// In the outbox: sent when the link is back (v8 C3).
  public var queued: [String] = []
  public var packageID: String?
  /// Originals left out because the space keeps text only.
  public var originalsDropped = 0
}

public struct SpaceOrganizeReport: Equatable, Sendable {
  public var leased = false
  public var sent = 0
  public var skipped = 0
  public var rekeyed = false
  public var pulled = false
}

public struct SpaceJoinRequestView: Equatable, Identifiable, Sendable {
  public let requestID: String
  public let memberID: String
  /// The name the joiner sealed to the inviting admin; nil for any other admin.
  public let displayName: String?
  public let fingerprint: String
  public let role: SpaceRole?
  public let outside: Bool
  public let createdAt: Date?
  public let device: SpaceDevicePublic
  /// What this Mac found wrong with the request (shown above 同意), or nil.
  public let warning: String?
  /// 同意 is refused: the request is not what an invite holder sent.
  public let blocked: Bool

  public var id: String { requestID }

  public init(
    requestID: String, memberID: String, displayName: String?, fingerprint: String,
    role: SpaceRole?, outside: Bool, createdAt: Date?, device: SpaceDevicePublic,
    warning: String? = nil, blocked: Bool = false
  ) {
    self.requestID = requestID
    self.memberID = memberID
    self.displayName = displayName
    self.fingerprint = fingerprint
    self.role = role
    self.outside = outside
    self.createdAt = createdAt
    self.device = device
    self.warning = warning
    self.blocked = blocked
  }
}

/// Masks a text with a space's mask key before it goes to the space
/// organizer (the App passes the same masker its organizing payloads use).
public protocol SpaceTextMasking: Sendable {
  func mask(_ text: String, maskKey: Data) throws -> String
}

/// What a member Mac does in its spaces (SPACES-CONTRACT §4, the Spark's
/// `docs/SPACES.md` §6): create, invite, join, approve, sync and verify the
/// op log, share with per-item data keys, withdraw / delete / remove / hide /
/// fork, takedowns, proposals, leave and remove with key rotation, the lazy
/// re-wrap, the lease that lets the space organizer run, and the audit view.
///
/// Every key stays on this Mac; the Spark receives only signed ops,
/// ciphertext, and — for organizing — masked payloads under a lease.
public actor SpaceEngine {
  public enum EngineError: Error, Equatable, Sendable {
    case unknownSpace
    case notActive
    case notAllowed(String)
    case missingKey(epoch: Int)
    case neverShared(String)
    case refused(String)
    /// The link is down: it waits in the outbox and goes when the link is back.
    case queued
  }

  public nonisolated let client: SpaceClient
  let states: any SpaceStateStore
  let keyStore: any SpaceKeyStore
  let now: @Sendable () -> Date
  /// Masks titles a maintainer writes before they reach the space organizer
  /// (review V7-S13); without one, such edits are not sent.
  var textMasker: (any SpaceTextMasking)?

  public func setTextMasker(_ masker: (any SpaceTextMasking)?) { textMasker = masker }
  /// Wire kinds that never leave the Mac, whatever asks (contract §0 rule 3).
  public static let neverShared: Set<String> = [
    "recording", "voiceprint", "speaker_embedding", "dictionary", "personal_model", "vocabulary",
    "recognition_profile",
  ]
  public static let audioKinds: Set<String> = [
    "meeting_online", "meeting_offline", "imported_media", "audio_segment",
  ]
  public static let maximumSegmentMS = 15 * 60 * 1000

  /// What this Mac still has to deliver (v8 C3); durable in the App.
  let outbox: any SpaceOutboxStore
  /// When each org's signed log was last read (org admins' Macs).
  var orgFetchedAt: [String: Date] = [:]
  /// Organizations whose log the Spark served did not continue what this Mac
  /// pinned (review V8R-02): no escrow, rotation wrap or takeover uses it.
  var orgLogRefused: Set<String> = []
  /// A space's roster as it was before this Mac re-read the log after a
  /// restore that replaced it (V8R-03): the next sync compares against it.
  var rosterBeforeReset: [String: SpaceRoster] = [:]

  public init(
    client: SpaceClient, states: any SpaceStateStore, keys: any SpaceKeyStore,
    textMasker: (any SpaceTextMasking)? = nil, outbox: (any SpaceOutboxStore)? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.client = client
    self.states = states
    keyStore = keys
    self.textMasker = textMasker
    self.outbox = outbox ?? MemorySpaceOutboxStore()
    self.now = now
  }

  public var device: SpaceDeviceKeys { client.device }

  // MARK: - Local state

  public func allStates() throws -> [SpaceLocalState] { try states.states() }

  public func state(_ spaceID: String) throws -> SpaceLocalState? {
    try states.load(spaceID.lowercased())
  }

  func required(_ spaceID: String) throws -> SpaceLocalState {
    guard let state = try states.load(spaceID.lowercased()) else { throw EngineError.unknownSpace }
    return state
  }

  func key(_ spaceID: String, epoch: Int) throws -> Data {
    guard let key = try keyStore.keys(spaceID)[epoch] else {
      throw EngineError.missingKey(epoch: epoch)
    }
    return key
  }

  func currentKey(_ state: SpaceLocalState) throws -> Data {
    try key(state.spaceID, epoch: state.epoch)
  }

  /// The space's mask key: from the first epoch (reached through the links).
  public func maskKey(_ spaceID: String) throws -> Data {
    SpaceCrypto.maskKey(firstEpochKey: try key(spaceID.lowercased(), epoch: 1))
  }

  // MARK: - Ops

  func post(
    _ state: SpaceLocalState, type: String, body: SpaceJSON, encPlain: SpaceJSON? = nil,
    opID: String = SpaceID.new()
  ) async throws -> SpaceOpResult {
    var enc: String?
    if let encPlain {
      enc = try SpaceCrypto.encryptOp(
        encPlain.encoded(), spaceKey: currentKey(state), spaceID: state.spaceID, opID: opID)
    }
    let op = try device.op(
      space: state.spaceID, member: state.memberID, type: type, body: body,
      epoch: enc == nil ? nil : state.epoch, enc: enc, opID: opID, createdAt: now())
    return try await submitOne(state.spaceID, op)
  }

  func submitOne(_ spaceID: String, _ op: SpaceWireOp) async throws -> SpaceOpResult {
    let answer = try await guarded(spaceID) { try await self.client.submit(spaceID, [op]) }
    guard let result = answer.results.first else { throw SpaceClientError.malformed }
    if !result.ok, result.status == 403, result.error == "not_member" {
      // An op result carries no proof: a signed read brings the op that ended
      // the access (checked below before anything is deleted).
      _ = try await guarded(spaceID) { try await self.client.summary(spaceID) }
      throw EngineError.refused("not_member")
    }
    return result
  }

  /// Runs a request; when it says this device's access ended, and the signed
  /// op that ended it checks out against this Mac's roster, the space's
  /// content and keys are deleted from this Mac before the error goes on. A
  /// bare "not a member" from the Spark deletes nothing (review V7-S16).
  func guarded<Value>(_ spaceID: String, _ work: () async throws -> Value) async throws
    -> Value
  {
    do { return try await work() } catch SpaceClientError.accessEnded(
      let status, let forks, let removal)
    {
      if verifiedRemoval(spaceID, removal) {
        try await accessEnded(spaceID, purgeForks: forks)
      } else if var state = try? states.load(spaceID.lowercased()) {
        state.warn("not_member_unsigned")
        try? states.save(state)
      }
      throw SpaceClientError.accessEnded(memberStatus: status, purgeForks: forks, removal: removal)
    }
  }

  /// The op that ended this device's access, signed by a device this Mac's
  /// roster admits: a `member.remove` of this member, a `device.remove` of
  /// this device, or this member's own `member.leave`.
  func verifiedRemoval(_ spaceID: String, _ entry: SpaceLogEntry?) -> Bool {
    guard let entry, let sig = entry.sig, let bytes = entry.opBytes,
      let op = try? SpaceJSON.decode(bytes), let state = try? states.load(spaceID.lowercased()),
      let roster = state.roster, op["space_id"]?.string == state.spaceID,
      let signer = roster.device(member: op["member_id"]?.string, device: op["device_id"]?.string),
      let key = signer.signKey, SpaceSignatures.verifyOp(bytes, signature: sig, signPub: key)
    else { return false }
    let body = op["body"] ?? [:]
    switch op["type"]?.string {
    case "member.remove": return body["member_id"]?.string == state.memberID
    case "device.remove": return body["device_id"]?.string == device.deviceID
    case "member.leave": return op["member_id"]?.string == state.memberID
    default: return false
    }
  }

  func ok(_ result: SpaceOpResult) throws -> SpaceOpResult {
    guard result.ok else { throw EngineError.refused(result.error ?? "refused") }
    return result
  }

  // MARK: - Access ended

  /// Fork copies the App must delete from the personal space (access to a
  /// space ended, or the item was removed for privacy). Kept in the state
  /// store, so a quit or a crash before the App deletes them loses nothing
  /// (review V7-S15; honest limit: a Mac that never syncs again keeps them).
  public func forkCopiesToDelete() -> [String] {
    (try? states.forkCopiesToDelete()) ?? []
  }

  /// The App deleted these copies.
  public func forkCopiesDeleted(_ ids: [String]) {
    let done = Set(ids)
    try? states.setForkCopiesToDelete(forkCopiesToDelete().filter { !done.contains($0) })
  }

  func queueForkCopyDeletion(_ copies: [String]) {
    let fresh = copies.filter { !$0.isEmpty }
    guard !fresh.isEmpty else { return }
    let queued = forkCopiesToDelete()
    try? states.setForkCopiesToDelete(queued + fresh.filter { !queued.contains($0) })
  }

  /// Deletes the space's content, originals and keys from this Mac; its fork
  /// copies are queued for the App first.
  public func accessEnded(_ spaceID: String, purgeForks: [String]) async throws {
    let id = spaceID.lowercased()
    if let state = try? states.load(id) {
      queueForkCopyDeletion(
        Set(purgeForks.map { $0.lowercased() }).union(state.forks.keys).compactMap {
          state.forks[$0]
        })
    }
    try states.delete(id)
    try keyStore.delete(id)
  }

  /// The fork copies to delete, handed over once (tests; the App uses
  /// `forkCopiesToDelete` and acknowledges with `forkCopiesDeleted`).
  public func takeForkCopiesToDelete() -> [String] {
    let copies = forkCopiesToDelete()
    forkCopiesDeleted(copies)
    return copies
  }

  // MARK: - Organizations

  /// `org.create` from this device; this device's member id becomes the
  /// organization's first admin.
  public func createOrg(recoveryAdmins: Int = 1) async throws -> (orgID: String, memberID: String) {
    let orgID = SpaceID.new()
    let memberID = try memberIdentity()
    let op = try device.orgOp(
      org: orgID, member: memberID, type: "org.create",
      body: [
        "device": device.publicRecord.json,
        "policy": ["recovery_admins": SpaceJSON(recoveryAdmins)],
      ], createdAt: now())
    let answer = try await client.createOrg(op)
    guard answer["ok"]?.bool == true else {
      throw EngineError.refused(answer["error"]?.string ?? "refused")
    }
    // V8R-02: this Mac knows the organization's first op; any log the Spark
    // serves later must start with it.
    var pins = (try? states.orgPins()) ?? [:]
    pins[orgID] = SpaceOrgPin.created(orgID: orgID, op: op, device: device.publicRecord)
    try states.setOrgPins(pins)
    return (orgID, memberID)
  }

  // MARK: - Create

  /// A new space with a fresh `K_1` wrapped to this device; the name is
  /// encrypted under it. An org space must be created by an org admin's
  /// device under the admin's org member id.
  public func createSpace(
    name: String, owner: SpaceOwnerKind, orgID: String? = nil, orgMemberID: String? = nil,
    policy: SpacePolicy? = nil, displayName: String, spark: SpaceInviteCode.Endpoint?
  ) async throws -> SpaceLocalState {
    let spaceID = SpaceID.new()
    let identity = try memberIdentity()
    let memberID = owner == .org ? (orgMemberID ?? identity) : identity
    let k1 = SpaceCrypto.randomKey()
    let opID = SpaceID.new()
    var ownerJSON: SpaceJSON = ["kind": .string(owner.rawValue)]
    if owner == .org {
      guard let orgID else { throw EngineError.notAllowed("org") }
      ownerJSON = ownerJSON.setting("org_id", .string(orgID))
      // V8R-02: the space's signed genesis commits to the organization's
      // first op, so every member checks the org log against it.
      if let pin = try? states.orgPins()[orgID.lowercased()] {
        ownerJSON = ownerJSON.setting("org_genesis", .string(pin.genesisHash))
      }
    }
    let wrap = try SpaceCrypto.wrapSpaceKey(
      k1, to: device.sealPublicKey, spaceID: spaceID, epoch: 1, deviceID: device.deviceID)
    var body: SpaceJSON = [
      "owner": ownerJSON, "device": device.publicRecord.json,
      "wraps": [["device_id": .string(device.deviceID), "epoch": 1, "wrap": .string(wrap)]],
    ]
    if let policy { body = body.setting("policy", policy.json) }
    if owner == .org, let orgID {
      // v8 B5: the first key is escrowed to the org's other admin devices.
      let escrow = try await escrowWraps(
        orgID: orgID, key: k1, spaceID: spaceID, epoch: 1, memberDevices: [device.deviceID])
      if !escrow.isEmpty { body = body.setting("escrow_wraps", .array(escrow)) }
    }
    let enc = try SpaceCrypto.encryptOp(
      SpaceJSON.object(["name": .string(name)]).encoded(), spaceKey: k1, spaceID: spaceID,
      opID: opID)
    let op = try device.op(
      space: spaceID, member: memberID, type: "space.create", body: body, epoch: 1, enc: enc,
      opID: opID, createdAt: now())
    try keyStore.save(k1, space: spaceID, epoch: 1)
    let result = try await client.createSpace(op)
    guard result.ok else {
      try? keyStore.delete(spaceID)
      throw EngineError.refused(result.error ?? "refused")
    }
    var state = SpaceLocalState(
      spaceID: spaceID, memberID: memberID, name: name, ownerKind: owner, orgID: orgID,
      policy: policy ?? (owner == .org ? .org : .group), role: .admin, membership: .active,
      spark: spark)
    state.knownNames[memberID] = displayName
    try states.save(state)
    _ = try? await post(
      state, type: "member.profile", body: [:], encPlain: ["display_name": .string(displayName)])
    return try await sync(spaceID)
  }

  // MARK: - Invite

  /// An invite: a one-time secret whose hash goes to the Spark, a role, a
  /// pinned host key (one of the Spark's, else 422), at most 7 days.
  public func invite(
    _ spaceID: String, role: SpaceRole, outside: Bool = false, hostKey: String,
    spark: SpaceInviteCode.Endpoint, relay: SpaceInviteCode.Endpoint? = nil,
    lifetime: TimeInterval = SpaceInviteCode.maximumLifetime
  ) async throws -> SpaceInviteCode {
    var state = try required(spaceID)
    guard state.can("invite") else { throw EngineError.notAllowed("invite") }
    let secret = SpaceCrypto.randomKey()
    let inviteID = SpaceID.new()
    let expires = now().addingTimeInterval(min(lifetime, SpaceInviteCode.maximumLifetime) - 60)
    var body: SpaceJSON = [
      "invite_id": .string(inviteID),
      "secret_hash": .string(SpaceCrypto.inviteSecretHash(secret)),
      "expires_at": .string(SpaceTime.string(expires)), "role": .string(role.rawValue),
      "host_key": .string(hostKey),
    ]
    if outside { body = body.setting("outside", true) }
    _ = try ok(try await post(state, type: "invite.create", body: body))
    let code = SpaceInviteCode(
      spaceID: state.spaceID, inviteID: inviteID, secret: secret, expiresAt: expires,
      spaceName: state.name, role: role, spark: spark, relay: relay,
      inviter: .init(
        memberID: state.memberID, deviceID: device.deviceID,
        sealPub: Base64URL.encode(device.sealPublicKey)))
    state.invites[inviteID] = SpaceInviteInfo(
      inviteID: inviteID, role: role, expiresAt: expires, status: "open",
      code: try code.encoded())
    try states.save(state)
    return code
  }

  public func revokeInvite(_ spaceID: String, inviteID: String) async throws {
    var state = try required(spaceID)
    _ = try ok(try await post(state, type: "invite.revoke", body: ["invite_id": .string(inviteID)]))
    state.invites[inviteID]?.status = "revoked"
    state.invites[inviteID]?.code = nil
    try states.save(state)
  }

  // MARK: - Join

  /// Sends a join request for an invite code: a new member id for this
  /// space, this device's public keys, the display name sealed to the
  /// inviting admin. Waits for approval (`refreshJoin`).
  ///
  /// `localHostKey` is the host key this Mac's own link pinned for the Spark
  /// (its known_hosts entry): the invite's pinned key must be that one. The
  /// Spark's own list of its keys proves nothing about which machine this
  /// Mac reached (review V7-S14).
  public func join(code: SpaceInviteCode, displayName: String, localHostKey: String?)
    async throws -> SpaceLocalState
  {
    guard let secret = code.secretBytes, let inviterSeal = code.inviterSealKey else {
      throw SpaceInviteCode.CodeError.malformed
    }
    if let existing = try states.load(code.spaceID), existing.membership == .active {
      return existing
    }
    // The invite pins the organizing device's host key: this Mac's link must
    // reach that same device.
    guard let localHostKey, Self.sameHostKey(localHostKey, code.spark.hostKey) else {
      throw EngineError.refused("host_key_mismatch")
    }
    let memberID = try memberIdentity()
    let requestID = SpaceID.new()
    let profile = try SpaceCrypto.sealProfile(
      SpaceJSON.object(["display_name": .string(displayName)]).encoded(), to: inviterSeal,
      spaceID: code.spaceID, requestID: requestID)
    let request = try device.joinRequest(
      space: code.spaceID, inviteID: code.inviteID, secret: secret, member: memberID,
      requestID: requestID, profile: profile, createdAt: now())
    _ = try await client.join(code.spaceID, request: request)
    var state = SpaceLocalState(
      spaceID: code.spaceID, memberID: memberID, name: code.spaceName, ownerKind: .person,
      orgID: nil, policy: .group, role: SpaceRole(rawValue: code.role ?? "write") ?? .write,
      membership: .pending, spark: code.spark)
    state.joinRequestID = requestID
    state.knownNames[memberID] = displayName
    try states.save(state)
    return state
  }

  /// `type base64` of two OpenSSH host keys, comments ignored.
  static func sameHostKey(_ a: String, _ b: String) -> Bool {
    let x = a.split(separator: " ").prefix(2)
    let y = b.split(separator: " ").prefix(2)
    return x.count == 2 && x == y
  }

  /// Polls a pending join; on approval syncs the space and introduces this
  /// member by name to everyone (`member.profile`).
  public func refreshJoin(_ spaceID: String) async throws -> SpaceLocalState {
    var state = try required(spaceID)
    guard state.membership == .pending, let requestID = state.joinRequestID else { return state }
    let status = try await client.joinStatus(state.spaceID, requestID: requestID)
    switch status.status {
    case "approved":
      state.membership = .active
      if let member = status.memberID { state.memberID = member }
      try states.save(state)
      var synced = try await sync(spaceID)
      if let name = state.knownNames[state.memberID] {
        _ = try? await post(
          synced, type: "member.profile", body: [:], encPlain: ["display_name": .string(name)])
        synced = try await sync(spaceID)
      }
      return synced
    case "rejected":
      state.membership = .rejected
      try states.save(state)
      return state
    default:
      return state
    }
  }

  /// Forgets a pending or rejected join on this Mac.
  public func dropJoin(_ spaceID: String) throws {
    guard let state = try states.load(spaceID), state.membership != .active else { return }
    try states.delete(state.spaceID)
    try keyStore.delete(state.spaceID)
  }

  // MARK: - Approve

  /// Pending requests with the joiner's name (opened with this device's seal
  /// key when this device sent the invite) and the fingerprint to compare.
  /// Each is checked first: signed by the device it names, and — when this
  /// Mac sent the invite — carrying the HMAC binding only an invite holder
  /// can make (V7-S9); a member id this Mac already knows from a space is
  /// flagged (V7-S2).
  public func joinRequests(_ spaceID: String) async throws -> [SpaceJoinRequestView] {
    let state = try required(spaceID)
    guard state.can("approve_joins") else { return [] }
    let records = try await guarded(state.spaceID) {
      try await self.client.joinRequests(state.spaceID)
    }
    let known = knownMemberKeys()
    return records.map { record in
      var name: String?
      if let profile = record.profile,
        let data = try? SpaceCrypto.openProfile(
          profile, sealKey: device.sealKey, spaceID: state.spaceID, requestID: record.requestID),
        let json = try? SpaceJSON.decode(data)
      {
        name = json["display_name"]?.string
      }
      let check = Self.check(record, secret: inviteSecret(state, record.inviteID))
      var warning: String?
      var blocked = false
      switch check {
      case .ok:
        break
      case .unverifiable:
        warning = "这条申请来自另一位管理员发的邀请，这台 Mac 核对不了；请当面核对指纹"
      case .bad:
        warning = "这条申请不是持邀请码的人发的（签名或邀请绑定对不上），不能同意"
        blocked = true
      }
      if let keys = known[record.memberID.lowercased()],
        !keys.contains(record.device.signKey ?? Data())
      {
        warning = "申请用的成员编号已经属于你认识的另一位成员，不能同意"
        blocked = true
      }
      return SpaceJoinRequestView(
        requestID: record.requestID, memberID: record.memberID, displayName: name,
        fingerprint: record.device.fingerprint,
        role: record.role.flatMap(SpaceRole.init(rawValue:)), outside: record.outside ?? false,
        createdAt: SpaceTime.date(record.createdAt), device: record.device, warning: warning,
        blocked: blocked)
    }
  }

  enum RequestCheck: Equatable { case ok, unverifiable, bad }

  /// The request is the signed bytes its device made (naming this record's
  /// member, request and device) and, given the invite's secret, carries the
  /// binding only an invite holder can make.
  static func check(_ record: SpaceJoinRequestRecord, secret: Data?) -> RequestCheck {
    guard let encoded = record.request, let bytes = Base64URL.decode(encoded, allowPadding: true),
      let request = try? SpaceJSON.decode(bytes), let sig = record.sig,
      let key = record.device.signKey,
      SpaceSignatures.verify(
        signPub: key, message: SpaceSignatures.joinDomain + bytes, signature: sig),
      request["member_id"]?.string == record.memberID,
      request["request_id"]?.string == record.requestID,
      let named = try? request["device"]?.decoded(as: SpaceDevicePublic.self),
      named.deviceID == record.device.deviceID, named.signKey == record.device.signKey,
      named.sealKey == record.device.sealKey
    else { return .bad }
    guard let secret else { return .unverifiable }
    guard let binding = record.binding,
      binding == SpaceCrypto.inviteBinding(secret: secret, request: bytes)
    else { return .bad }
    return .ok
  }

  /// The secret of an invite this Mac made (its code is kept in the state).
  func inviteSecret(_ state: SpaceLocalState, _ inviteID: String?) -> Data? {
    guard let inviteID, let code = state.invites[inviteID]?.code,
      let decoded = try? SpaceInviteCode.decode(code, now: .distantPast)
    else { return nil }
    return decoded.secretBytes
  }

  /// Member ids of every space this Mac is in, with the signing keys their
  /// signed logs admitted under them: an invite holder whose device is not
  /// one of those must never take one of these ids (an org admin's, say).
  func knownMemberKeys() -> [String: Set<Data>] {
    var known: [String: Set<Data>] = [:]
    for state in (try? states.states()) ?? [] {
      for (member, record) in state.roster?.members ?? [:] {
        known[member, default: []].formUnion(record.devices.values.compactMap(\.signKey))
      }
      if state.membership == .active {
        known[state.memberID, default: []].insert(device.signPublicKey)
      }
    }
    return known
  }

  /// 同意: the current space key wrapped to the joiner's device, and the
  /// joiner's member id and both public keys signed into the log (every
  /// member Mac admits devices only from such ops, V7-S1).
  public func approve(_ spaceID: String, request: SpaceJoinRequestView, role: SpaceRole? = nil)
    async throws
  {
    var state = try required(spaceID)
    guard state.can("approve_joins") else { throw EngineError.notAllowed("approve_joins") }
    guard !request.blocked else { throw EngineError.refused("join_request_unverified") }
    guard let seal = request.device.sealKey else { throw SpaceCrypto.CryptoError.invalidKey }
    let wrap = try SpaceCrypto.wrapSpaceKey(
      currentKey(state), to: seal, spaceID: state.spaceID, epoch: state.epoch,
      deviceID: request.device.deviceID)
    var body: SpaceJSON = [
      "request_id": .string(request.requestID), "member_id": .string(request.memberID),
      "device": request.device.json,
      "wraps": [
        [
          "device_id": .string(request.device.deviceID), "epoch": SpaceJSON(state.epoch),
          "wrap": .string(wrap),
        ]
      ],
    ]
    if let role { body = body.setting("role", .string(role.rawValue)) }
    _ = try ok(try await post(state, type: "join.approve", body: body))
    if let name = request.displayName { state.knownNames[request.memberID] = name }
    try states.save(state)
    _ = try await sync(spaceID)
  }

  public func reject(_ spaceID: String, requestID: String) async throws {
    let state = try required(spaceID)
    _ = try ok(
      try await post(state, type: "join.reject", body: ["request_id": .string(requestID)]))
  }

  // MARK: - Sync

  /// The summary, every new op, then the keys. Each op is verified against
  /// the key of a device the signed log itself admitted (the genesis op
  /// against the key inside it); an op that fails is never applied. The
  /// members, devices and epoch that matter for keys come from that log,
  /// never from the Spark's summary (review V7-S1, V7-S10), and this device's
  /// space keys are unwrapped only from wraps inside signed ops (genesis,
  /// approval, rotation): a wrap the Spark made up for this device is never
  /// used. Older epochs come through the epoch links, which only the holder
  /// of the newer key could have made.
  @discardableResult
  public func sync(_ spaceID: String) async throws -> SpaceLocalState {
    var state = try required(spaceID)
    guard state.membership == .active else { return state }
    let id = state.spaceID
    if state.roster == nil {
      // A state from before the roster: rebuild it from the whole log.
      state.cursor = 0
      state.roster = SpaceRoster()
    }
    let keys = try await guarded(id) { try await self.client.keys(id) }
    let summary = try await guarded(id) { try await self.client.summary(id) }
    apply(summary: summary, to: &state)
    state.integrityWarnings = nil
    var before: SpaceRoster? = rosterBeforeReset.removeValue(forKey: id)
    if summary.head < state.cursor {
      // The Spark's log went back (a restore from a backup): read it again
      // from the start and believe only what the signed ops say. Who this
      // Mac saw removed is kept (review V8R-03): a shorter log may admit them
      // again, under an older key they hold.
      before = state.roster
      state.resetForResync()
      state.warn("spark_restored")
    }
    // Pass 1: verify the new ops in order and move the roster on.
    var fresh: [SpaceLogEntry] = []
    var more = true
    var cursor = state.cursor
    while more {
      let page = try await guarded(id) { try await self.client.ops(id, since: cursor) }
      fresh += page.ops
      cursor = max(cursor, page.ops.map(\.seq).max() ?? cursor)
      state.head = page.head
      more = page.more && !page.ops.isEmpty
    }
    if state.ownerKind == .org, let orgID = state.orgID {
      // A takeover is checked against the organization's own signed log.
      await refreshOrgRoster(
        &state, orgID: orgID, force: fresh.contains { $0.type == "space.recover" })
    }
    var accepted: [(entry: SpaceLogEntry, op: SpaceJSON)] = []
    for entry in fresh {
      if let op = verify(entry, state: &state) { accepted.append((entry, op)) }
    }
    // The keys: this device's signed wraps, then the links back to epoch 1.
    var held = try keyStore.keys(id)
    for (epoch, wrap) in state.signedWraps ?? [:] where held[epoch] == nil {
      guard
        let key = try? SpaceCrypto.unwrapSpaceKey(
          wrap, sealKey: device.sealKey, spaceID: id, epoch: epoch, deviceID: device.deviceID)
      else { continue }
      try keyStore.save(key, space: id, epoch: epoch)
      held[epoch] = key
    }
    let links = Dictionary(keys.epochLinks.map { ($0.epoch, $0.prevWrap) }) { first, _ in first }
    var epoch = held.keys.max() ?? 0
    while epoch > 1, let newer = held[epoch] {
      if held[epoch - 1] == nil {
        guard let link = links[epoch],
          let previous = try? SpaceCrypto.openEpochLink(
            link, newKey: newer, spaceID: id, epoch: epoch)
        else { break }
        try keyStore.save(previous, space: id, epoch: epoch - 1)
        held[epoch - 1] = previous
      }
      epoch -= 1
    }
    // Pass 2: what the accepted ops change on this Mac.
    for item in accepted { apply(item.entry, op: item.op, to: &state, keys: held) }
    for entry in fresh { state.cursor = max(state.cursor, entry.seq) }
    let roster = state.roster ?? SpaceRoster()
    // The epoch in use is the newest one a signed rotation made; a lower one
    // from the Spark is a contradiction, never a reason to go back.
    let newest = max(roster.epoch, 1)
    if summary.epoch < newest || keys.epoch < newest { state.warn("spark_epoch_behind") }
    state.epoch = newest
    // V8R-03: members and devices that a log gone back admitted again stay
    // listed until an admin removes them again (with a new key); until then
    // nothing new is shared (it would be under a key they hold).
    var back = Set(state.readmittedAfterRollback ?? [])
    if let before {
      for (memberID, record) in before.members where record.status != "active" {
        if roster.members[memberID]?.status == "active" { back.insert(memberID) }
      }
      let activeNow = roster.activeDeviceIDs
      for record in before.members.values {
        for device in record.devices.values
        where !device.active && activeNow.contains(device.deviceID) {
          back.insert(device.deviceID)
        }
      }
    }
    back = back.filter {
      roster.members[$0]?.status == "active" || roster.activeDeviceIDs.contains($0)
    }
    state.readmittedAfterRollback = back.isEmpty ? nil : back.sorted()
    if !back.isEmpty { state.warn("removed_member_back") }
    state.rotationPending =
      roster.rotationPending || keys.rotationPending || summary.rotationPending || !back.isEmpty
    // Devices the Spark lists that no signed op admitted get nothing from
    // this Mac; say so instead of trusting them.
    let listed = Set(
      summary.members.filter(\.isActive).flatMap { $0.devices.filter(\.isActive).map(\.deviceID) })
    if !listed.subtracting(roster.activeDeviceIDs).isEmpty { state.warn("unknown_device_listed") }
    for index in state.members.indices {
      let admitted = roster.members[state.members[index].memberID]?.devices ?? [:]
      state.members[index].devices = state.members[index].devices.filter {
        admitted[$0.deviceID]?.signPub == $0.signPub
      }
    }
    for itemID in state.items.keys where state.items[itemID]?.isActive == false {
      try? states.deleteOriginals(space: id, item: itemID)
    }
    state.lastSyncedAt = now()
    try states.save(state)
    return state
  }

  func apply(summary: SpaceSummary, to state: inout SpaceLocalState) {
    state.memberID = summary.me.memberID
    state.ownerKind = SpaceOwnerKind(rawValue: summary.owner.kind) ?? state.ownerKind
    state.orgID = summary.owner.orgID
    state.ownerMemberID = summary.owner.memberID
    state.policy = summary.policy
    state.role = SpaceRole(rawValue: summary.me.role) ?? state.role
    state.rights = summary.me.rights
    state.archived = summary.archived
    state.escrow = summary.escrow
    state.limits = summary.limits
    state.usage = summary.me.usage
    state.hidden = Set(summary.me.hidden.map { $0.lowercased() })
    let forks = Set(summary.me.forks.map { $0.lowercased() })
    state.forks = state.forks.filter { forks.contains($0.key) }
    for fork in forks where state.forks[fork] == nil { state.forks[fork] = "" }
    let names = Dictionary(state.members.map { ($0.memberID, $0.displayName) }) { a, _ in a }
    state.members = summary.members.map { record in
      SpaceMember(
        record: record,
        displayName: (names[record.memberID] ?? nil) ?? state.knownNames[record.memberID])
    }
  }

  /// Pass 1 of a sync: one entry checked against the roster as of that op
  /// (a device the signed log admitted, never one the Spark merely lists);
  /// an accepted op moves the roster on and hands over any wrap it carries
  /// for this device. Returns the decoded op when it is accepted.
  func verify(_ entry: SpaceLogEntry, state: inout SpaceLocalState) -> SpaceJSON? {
    guard let bytes = entry.opBytes, let op = try? SpaceJSON.decode(bytes) else {
      state.rejectedOps += 1
      return nil
    }
    let type = op["type"]?.string ?? entry.type
    guard let sig = entry.sig else {
      // Only the Spark's own removal record is unsigned; pass 2 checks that
      // it carries out a privacy takedown whose window ended (V7-S16).
      if type == "system.remove", entry.type == type { return op }
      state.rejectedOps += 1
      return nil
    }
    let body = op["body"] ?? [:]
    let member = op["member_id"]?.string
    var roster = state.roster ?? SpaceRoster()
    guard op["space_id"]?.string == state.spaceID, type == entry.type else {
      state.rejectedOps += 1
      return nil
    }
    if type == "space.recover" {
      // v8 B5: signed by an org admin's own org device, as the organization's
      // signed log admits it (or as the member confirmed it out of band).
      guard let member, let named = SpaceRoster.device(body["device"]),
        named.deviceID == op["device_id"]?.string, let key = named.signKey,
        SpaceSignatures.verifyOp(bytes, signature: sig, signPub: key)
      else {
        state.rejectedOps += 1
        return nil
      }
      let orgDevice = state.orgRoster?.device(member: member, device: named.deviceID)
      let admitted =
        (orgDevice?.signPub == named.signPub && orgDevice?.sealPub == named.sealPub)
        || state.trustedRecoveries?[named.deviceID] == named.signPub
      guard admitted else {
        var pending = state.pendingRecoveries ?? []
        if !pending.contains(where: { $0.device.deviceID == named.deviceID }) {
          pending.append(
            SpacePendingRecovery(seq: entry.seq, memberID: member, device: named.publicRecord))
        }
        state.pendingRecoveries = pending
        state.rejectedOps += 1
        return nil
      }
      roster.admitRecovery(member: member, device: named)
      state.roster = roster
      state.pendingRecoveries = state.pendingRecoveries?.filter {
        $0.device.deviceID != named.deviceID
      }
      return op
    }
    if type == "space.create", !roster.genesis {
      let key = body["device"]?["sign_pub"]?.string.flatMap {
        Base64URL.decode($0, allowPadding: true)
      }
      guard let key, body["device"]?["device_id"]?.string == op["device_id"]?.string,
        SpaceSignatures.verifyOp(bytes, signature: sig, signPub: key), let member,
        roster.admitGenesis(member: member, device: body["device"])
      else {
        state.rejectedOps += 1
        return nil
      }
      if let committed = body["owner"]?["org_genesis"]?.string { state.orgGenesis = committed }
    } else {
      guard let signer = roster.device(member: member, device: op["device_id"]?.string),
        let key = signer.signKey, SpaceSignatures.verifyOp(bytes, signature: sig, signPub: key)
      else {
        state.rejectedOps += 1
        return nil
      }
    }
    if let enc = entry.enc, op["enc_sha256"]?.string != SpaceCrypto.detachedHash(enc) {
      state.rejectedOps += 1
      return nil
    }
    roster.apply(type: type, member: member, body: body)
    state.roster = roster
    // Member wraps, and (v8 B5) escrow wraps an admin signed into the log.
    let carried = (body["wraps"]?.array ?? []) + (body["escrow_wraps"]?.array ?? [])
    for wrap in carried where wrap["device_id"]?.string == device.deviceID {
      if let epoch = wrap["epoch"]?.int, let value = wrap["wrap"]?.string {
        var signed = state.signedWraps ?? [:]
        signed[epoch] = value
        state.signedWraps = signed
      }
    }
    return op
  }

  /// Pass 2 of a sync: what one accepted op changes on this Mac.
  func apply(
    _ entry: SpaceLogEntry, op: SpaceJSON, to state: inout SpaceLocalState, keys: [Int: Data]
  ) {
    let type = op["type"]?.string ?? entry.type
    let body = op["body"] ?? [:]
    let member = op["member_id"]?.string
    let at = SpaceTime.date(entry.appliedAt) ?? now()
    let opID = op["op_id"]?.string ?? ""
    if entry.sig == nil, !Self.acceptsSystemRemove(type: type, body: body, state: state, at: at) {
      state.rejectedOps += 1
      return
    }
    func opened() -> SpaceJSON? {
      guard let enc = entry.enc, !entry.purged, let epoch = op["epoch"]?.int,
        let key = keys[epoch],
        let data = try? SpaceCrypto.decryptOp(
          enc, spaceKey: key, spaceID: state.spaceID, opID: opID)
      else { return nil }
      return try? SpaceJSON.decode(data)
    }
    let itemID = body["item_id"]?.string?.lowercased()
    switch type {
    case "space.create", "space.meta":
      if let name = opened()?["name"]?.string, !name.isEmpty { state.name = name }
    case "space.policy":
      if let policy = body["policy"],
        let merged = try? state.policy.json.merging(policy)
          .decoded(as: SpacePolicy.self)
      {
        state.policy = merged
      }
    case "space.archive":
      state.archived = body["archived"]?.bool ?? state.archived
    case "member.profile":
      if let member, let name = opened()?["display_name"]?.string, !name.isEmpty {
        state.knownNames[member] = name
        if let index = state.members.firstIndex(where: { $0.memberID == member }) {
          state.members[index].displayName = name
        }
      }
    case "invite.create":
      if member == state.memberID, let inviteID = body["invite_id"]?.string,
        state.invites[inviteID] == nil
      {
        state.invites[inviteID] = SpaceInviteInfo(
          inviteID: inviteID, role: SpaceRole(rawValue: body["role"]?.string ?? "") ?? .write,
          expiresAt: SpaceTime.date(body["expires_at"]?.string) ?? at, status: "open", code: nil)
      }
    case "invite.revoke":
      if let inviteID = body["invite_id"]?.string { state.invites[inviteID]?.status = "revoked" }
    case "item.share":
      guard let itemID, let member else { return }
      let revision = body["revision"]?.int ?? 0
      var fields: SpaceItemFields?
      if let itemKey = entry.itemKey, let key = keys[itemKey.epoch], let enc = entry.enc,
        !entry.purged,
        let dataKey = try? SpaceCrypto.unwrapItemKey(
          itemKey.wrappedDK, spaceKey: key, spaceID: state.spaceID, epoch: itemKey.epoch,
          itemID: itemID),
        let plain = try? SpaceCrypto.decryptItem(
          enc, dataKey: dataKey, spaceID: state.spaceID, itemID: itemID, revision: revision)
      {
        fields = try? JSONDecoder().decode(SpaceItemFields.self, from: plain)
      }
      let previous = state.items[itemID]
      if let previous, previous.revision > revision { return }
      let blobs =
        body["blobs"]?.array?.compactMap { blob -> SpaceBlobRef? in
          guard let id = blob["blob_id"]?.string else { return nil }
          return SpaceBlobRef(blobID: id, role: blob["role"]?.string ?? "original")
        } ?? []
      let segment = body["segment"].flatMap { s -> SpaceSegmentRef? in
        guard let parent = s["parent_item_id"]?.string, let start = s["start_ms"]?.int,
          let end = s["end_ms"]?.int
        else { return nil }
        return SpaceSegmentRef(
          parentItemID: parent, startMS: start, endMS: end, recordingMS: s["recording_ms"]?.int)
      }
      if previous != nil, previous?.revision ?? 0 < revision {
        try? states.deleteOriginals(space: state.spaceID, item: itemID)
      }
      var shared = SpaceSharedItem(
        itemID: itemID, contributor: member, kind: body["kind"]?.string ?? "text",
        revision: revision, shareSeq: entry.seq, firstSharedAt: previous?.firstSharedAt ?? at,
        updatedAt: at, fields: fields ?? (previous?.revision == revision ? previous?.fields : nil),
        blobs: blobs, segment: segment, packageID: body["package_id"]?.string,
        // A purged share is an older revision or an item that left; the op
        // that took it out (withdraw, remove) follows in the log.
        status: .active, keyEpoch: entry.itemKey?.epoch)
      shared.deviceID = op["device_id"]?.string
      shared.snapshot = try? body["snapshot"]?.decoded(as: SpaceSnapshotRef.self)
      state.items[itemID] = shared
    case "item.withdraw":
      if let itemID { state.items[itemID].map { _ in markGone(itemID, .withdrawn, &state) } }
    case "item.delete":
      // A withdraw, or past an org space's window a takedown request: the
      // share op of a withdrawn item comes back purged on the next sync.
      if let itemID, let item = state.items[itemID],
        SpaceRules.withdrawWindowOpen(
          policy: state.policy, firstShared: item.firstSharedAt, now: at)
      {
        markGone(itemID, .withdrawn, &state)
      } else if let itemID {
        let takedownID = Self.takedownID(deleteOpID: opID)
        state.takedowns[takedownID] = SpaceTakedown(
          takedownID: takedownID, itemID: itemID, kind: "other", requester: member,
          status: "open", reason: nil, createdAt: at, dueAt: nil)
      }
    case "item.remove", "system.remove":
      // A removal for privacy takes this Mac's fork copy with it (V7-S15).
      let privacy = type == "system.remove" || body["reason"]?.string == "privacy"
      if let itemID { markGone(itemID, .removed, &state, privacy: privacy) }
      if let takedownID = body["takedown_id"]?.string {
        state.takedowns[takedownID]?.status = "done"
      }
    case "item.hide":
      if let itemID {
        if body["hidden"]?.bool == false {
          state.hidden.remove(itemID)
        } else {
          state.hidden.insert(itemID)
        }
      }
    case "item.fork":
      if let itemID, member == state.memberID, state.forks[itemID] == nil {
        state.forks[itemID] = ""
      }
    case "item.unfork":
      if let itemID, member == state.memberID { state.forks[itemID] = nil }
    case "takedown.request":
      if let takedownID = body["takedown_id"]?.string, let itemID {
        let kind = body["kind"]?.string ?? "other"
        state.takedowns[takedownID] = SpaceTakedown(
          takedownID: takedownID, itemID: itemID, kind: kind, requester: member, status: "open",
          reason: opened()?["reason"]?.string, createdAt: at,
          dueAt: kind == "privacy"
            ? at.addingTimeInterval(TimeInterval(state.policy.takedownWindowHours) * 3_600) : nil)
      }
    case "takedown.resolve":
      if let takedownID = body["takedown_id"]?.string {
        let accepted = body["decision"]?.string == "accept"
        state.takedowns[takedownID]?.status = accepted ? "done" : "rejected"
        if accepted, let itemID = state.takedowns[takedownID]?.itemID {
          markGone(
            itemID, .removed, &state, privacy: state.takedowns[takedownID]?.kind == "privacy")
        }
      }
    case "takedown.withdraw":
      if let takedownID = body["takedown_id"]?.string {
        state.takedowns[takedownID]?.status = "withdrawn"
      }
    case "matter.share":
      if let packageID = body["package_id"]?.string, let member {
        state.packages[packageID] = SpacePackage(
          packageID: packageID, owner: member,
          itemIDs: body["item_ids"]?.array?.compactMap { $0.string?.lowercased() } ?? [],
          auto: SpaceRuleMode(rawValue: body["auto"]?.string ?? "") ?? .off, hints: opened(),
          active: true)
      }
    case "matter.unshare":
      if let packageID = body["package_id"]?.string { state.packages[packageID]?.active = false }
    case "share_rule.set":
      if let ruleID = body["rule_id"]?.string, member == state.memberID {
        state.rules[ruleID] = SpaceShareRule(
          ruleID: ruleID, kind: body["kind"]?.string ?? "matter",
          auto: SpaceRuleMode(rawValue: body["auto"]?.string ?? "") ?? .ask, details: opened(),
          active: true)
      }
    case "share_rule.clear":
      // A rule is its member's own: another member's clear changes nothing here (V7-S17).
      if let ruleID = body["rule_id"]?.string, member == state.memberID {
        state.rules[ruleID]?.active = false
      }
    case "proposal.create":
      if let proposalID = body["proposal_id"]?.string {
        state.proposals[proposalID] = SpaceProposal(
          proposalID: proposalID, author: member, kind: body["kind"]?.string ?? "other",
          targets: body["targets"], details: opened(), status: "open", resolvedBy: nil)
      }
    case "proposal.resolve":
      if let proposalID = body["proposal_id"]?.string {
        state.proposals[proposalID]?.status =
          body["decision"]?.string == "accept" ? "accepted" : "rejected"
        state.proposals[proposalID]?.resolvedBy = member
      }
    case "proposal.withdraw":
      if let proposalID = body["proposal_id"]?.string {
        state.proposals[proposalID]?.status = "withdrawn"
      }
    case "matter.handover":
      if let matter = body["matter_id"]?.string, let to = body["to_member_id"]?.string {
        state.handovers[matter] = to
        if let pack = body["pack_item_id"]?.string {
          state.handoverPacks[matter] = pack.lowercased()
        }
      }
    default:
      break
    }
  }

  /// The Spark's own unsigned record is accepted only when it removes what
  /// this Mac can see should go: a privacy takedown it saw filed whose window
  /// ended, a snapshot whose cited item left (v8 C2), or an item a restoring
  /// admin's Mac listed as gone (v8 B4; it only removes).
  static func acceptsSystemRemove(type: String, body: SpaceJSON, state: SpaceLocalState, at: Date)
    -> Bool
  {
    guard type == "system.remove", let item = body["item_id"]?.string?.lowercased() else {
      return false
    }
    switch body["reason"]?.string {
    case "cited_item_gone":
      guard let cited = body["cited_item_id"]?.string?.lowercased(),
        let snapshot = state.items[item]?.snapshot, snapshot.cites.contains(cited)
      else { return false }
      return state.items[cited]?.isActive != true
    case "restore":
      return true
    default:
      guard let takedownID = body["takedown_id"]?.string,
        let takedown = state.takedowns[takedownID],
        takedown.kind == "privacy", takedown.status == "open", takedown.itemID == item,
        let due = takedown.dueAt
      else { return false }
      return at >= due
    }
  }

  func markGone(
    _ itemID: String, _ status: SpaceSharedItem.Status, _ state: inout SpaceLocalState,
    privacy: Bool = false
  ) {
    guard var item = state.items[itemID] else { return }
    item.status = status
    item.fields = nil
    item.blobs = []
    state.items[itemID] = item
    try? states.deleteOriginals(space: state.spaceID, item: itemID)
    if privacy, let copy = state.forks[itemID], !copy.isEmpty {
      queueForkCopyDeletion([copy])
      state.forks[itemID] = ""
    }
  }

  /// The id the Spark gives the takedown a late `item.delete` becomes
  /// (`uuid5(op_id, "takedown")`).
  public static func takedownID(deleteOpID: String) -> String {
    guard let ns = UUID(uuidString: deleteOpID) else { return SpaceID.new() }
    var bytes = withUnsafeBytes(of: ns.uuid) { Data($0) }
    bytes.append(Data("takedown".utf8))
    var digest = Array(Insecure.SHA1.hash(data: bytes))
    digest[6] = (digest[6] & 0x0F) | 0x50
    digest[8] = (digest[8] & 0x3F) | 0x80
    let u = UUID(
      uuid: (
        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
        digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14],
        digest[15]
      ))
    return u.uuidString.lowercased()
  }

  // MARK: - Share

  /// Why an item may not go at all (checked on this Mac before anything is sent).
  public static func refusal(_ item: SpaceOutgoingItem) -> String? {
    if neverShared.contains(item.kind) { return "never_shared" }
    let audio = item.hasAudio
    if audio || item.kind == "audio_segment" {
      guard let segment = item.segment else { return "audio_needs_segment" }
      guard segment.endMS > segment.startMS else { return "bad_segment" }
      if segment.endMS - segment.startMS > maximumSegmentMS { return "segment_too_long" }
    }
    if audio {
      // v8 C1: one audio part, of a meeting, a part and never the whole recording.
      guard audioKinds.contains(item.kind), item.originals.filter({ $0.role == "audio" }).count == 1
      else { return "bad_field" }
      guard let segment = item.segment, let whole = segment.recordingMS else {
        return "audio_needs_recording_length"
      }
      guard segment.endMS <= whole else { return "bad_segment" }
      guard SpaceAudioCheck.isPart(lengthMS: segment.lengthMS, recordingMS: whole) else {
        return "whole_recording"
      }
    }
    if item.kind == "snapshot" {
      guard item.originals.isEmpty, item.segment == nil else { return "bad_field" }
    }
    if audioKinds.contains(item.kind), item.kind != "audio_segment", item.segment == nil {
      // A whole recording is never shared, only the parts filed into the matter.
      return "audio_needs_segment"
    }
    return nil
  }

  /// Milliseconds a set of spans covers, overlaps counted once.
  public static func covered(_ spans: [(Int, Int)]) -> Int {
    var total = 0
    var end = Int.min
    for (start, stop) in spans.sorted(by: { $0.0 < $1.0 }) where stop > end {
      total += stop - max(start, end)
      end = stop
    }
    return total
  }

  static func unique(_ ids: [String]) -> [String] {
    var seen = Set<String>()
    return ids.filter { seen.insert($0).inserted }
  }

  /// Stops a package's rule; its items stay.
  public func unsharePackage(_ spaceID: String, packageID: String) async throws {
    let state = try required(spaceID)
    _ = try ok(
      try await post(state, type: "matter.unshare", body: ["package_id": .string(packageID)]))
    _ = try await sync(spaceID)
  }

  /// A rule for this member's own Macs: everything on a rope (or filed into a
  /// matter) goes to this space, asking first or automatically.
  public func setRule(
    _ spaceID: String, kind: String, targetID: String, title: String, auto: SpaceRuleMode,
    ruleID: String = SpaceID.new()
  ) async throws -> String {
    let state = try required(spaceID)
    _ = try ok(
      try await post(
        state, type: "share_rule.set",
        body: [
          "rule_id": .string(ruleID), "kind": .string(kind),
          "auto": .string(auto == .off ? "ask" : auto.rawValue),
        ], encPlain: ["target_id": .string(targetID), "title": .string(title)]))
    _ = try await sync(spaceID)
    return ruleID
  }

  public func clearRule(_ spaceID: String, ruleID: String) async throws {
    let state = try required(spaceID)
    _ = try ok(try await post(state, type: "share_rule.clear", body: ["rule_id": .string(ruleID)]))
    _ = try await sync(spaceID)
  }

  // MARK: - Items deleted on this Mac

  /// The local items (by their library id, lowercase) behind what this
  /// device has out in its spaces: a shared item's own id, or the recording
  /// a shared part came from.
  public func sharedSources() throws -> Set<String> {
    var out = Set<String>()
    for state in try states.states() where state.membership == .active {
      for item in state.activeItems where Self.sharedHere(item, state, device.deviceID) {
        out.insert(item.segment?.parentItemID ?? item.itemID)
      }
    }
    return out
  }

  static func sharedHere(_ item: SpaceSharedItem, _ state: SpaceLocalState, _ deviceID: String)
    -> Bool
  {
    item.contributor == state.memberID && (item.deviceID == nil || item.deviceID == deviceID)
  }

  /// The user deleted these local items: whatever this device shared from
  /// them (the item, or every part of a recording) goes out of every space
  /// too — a withdraw, or past an org space's window a takedown request
  /// (SPACES-CONTRACT §4 "删除"; review V7-S12). Queued in each space's state
  /// first, then sent (`flushDeletes`), so a quit or a link that is down
  /// loses nothing. Returns how many space items were queued.
  @discardableResult
  public func localItemsDeleted(_ sourceIDs: Set<String>) throws -> Int {
    let sources = Set(sourceIDs.map { $0.lowercased() })
    var queued = 0
    for var state in try states.states() where state.membership == .active {
      // Shares of these items still waiting in the outbox never go (review
      // V8R-04); one that may have reached the Spark is deleted there too.
      let maybeSent = try dropQueuedShares(state.spaceID, items: sources)
      let doomed =
        state.activeItems.filter {
          Self.sharedHere($0, state, device.deviceID)
            && sources.contains($0.segment?.parentItemID ?? $0.itemID)
        }.map(\.itemID) + maybeSent.sorted()
      let pending = state.pendingDeletes ?? []
      let fresh = Self.unique(doomed.filter { !pending.contains($0) })
      guard !fresh.isEmpty else { continue }
      state.pendingDeletes = pending + fresh
      try states.save(state)
      queued += fresh.count
    }
    return queued
  }

  /// Sends the queued deletes of one space; each leaves the queue once the
  /// Spark has it (or the item is already gone). Returns how many went.
  @discardableResult
  public func flushDeletes(_ spaceID: String) async throws -> Int {
    var state = try required(spaceID)
    guard state.membership == .active, let pending = state.pendingDeletes, !pending.isEmpty else {
      return 0
    }
    var left: [String] = []
    var sent = 0
    for itemID in pending {
      do {
        let result = try await post(state, type: "item.delete", body: ["item_id": .string(itemID)])
        if result.ok || ["item_gone", "unknown_item", "forbidden"].contains(result.error ?? "") {
          sent += 1
        } else {
          left.append(itemID)
        }
      } catch SpaceClientError.transport {
        left.append(itemID)
      }
    }
    state = try required(spaceID)
    state.pendingDeletes = left.isEmpty ? nil : left
    try states.save(state)
    _ = try? await sync(spaceID)
    return sent
  }

  // MARK: - Withdraw, delete, remove, hide, fork

  public func withdraw(_ spaceID: String, itemID: String) async throws {
    try await itemOp(spaceID, "item.withdraw", ["item_id": .string(itemID.lowercased())])
  }

  /// 删除 your own item: a withdraw, or past an org space's window a
  /// takedown request (the result says which).
  @discardableResult
  public func delete(_ spaceID: String, itemID: String) async throws
    -> SpaceRules.DeleteOutcome
  {
    let state = try required(spaceID)
    let maybeSent = try dropQueuedShares(spaceID, items: [itemID.lowercased()])
    if state.items[itemID.lowercased()] == nil, maybeSent.isEmpty { return .withdrawn }
    let result: SpaceOpResult
    do {
      result = try ok(
        try await post(state, type: "item.delete", body: ["item_id": .string(itemID.lowercased())]))
    } catch SpaceClientError.transport {
      // v8 C3: waits in the outbox; a remade delete is taken as the first.
      try enqueueOp(
        spaceID, type: "item.delete", body: ["item_id": .string(itemID.lowercased())], label: "删除")
      throw EngineError.queued
    }
    _ = try await sync(spaceID)
    return result.effects?["status"]?.string == "takedown_requested"
      ? .takedownRequested : .withdrawn
  }

  public func remove(_ spaceID: String, itemID: String, reason: String = "other") async throws {
    try await itemOp(
      spaceID, "item.remove",
      ["item_id": .string(itemID.lowercased()), "reason": .string(reason)])
  }

  public func hide(_ spaceID: String, itemID: String, hidden: Bool = true) async throws {
    try await itemOp(
      spaceID, "item.hide", ["item_id": .string(itemID.lowercased()), "hidden": .bool(hidden)])
  }

  /// "存一份到我的空间": recorded on the Spark (so access loss can remove it);
  /// the App makes the local copy and reports its id.
  public func fork(_ spaceID: String, itemID: String) async throws {
    try await itemOp(spaceID, "item.fork", ["item_id": .string(itemID.lowercased())])
  }

  public func recordForkCopy(_ spaceID: String, itemID: String, localID: String) throws {
    var state = try required(spaceID)
    state.forks[itemID.lowercased()] = localID
    try states.save(state)
  }

  public func unfork(_ spaceID: String, itemID: String) async throws -> String? {
    let copy = try required(spaceID).forks[itemID.lowercased()]
    try await itemOp(spaceID, "item.unfork", ["item_id": .string(itemID.lowercased())])
    return copy.flatMap { $0.isEmpty ? nil : $0 }
  }

  func itemOp(_ spaceID: String, _ type: String, _ body: SpaceJSON) async throws {
    let state = try required(spaceID)
    if type == "item.withdraw", let item = body["item_id"]?.string {
      // A share of it still waiting here never goes (review V8R-04); when it
      // never reached the Spark there is nothing to withdraw there.
      let maybeSent = try dropQueuedShares(spaceID, items: [item])
      if state.items[item] == nil, maybeSent.isEmpty { return }
    }
    do {
      _ = try ok(try await post(state, type: type, body: body))
    } catch SpaceClientError.transport where type == "item.withdraw" {
      // v8 C3: a withdraw waits in the outbox while the link is down.
      try enqueueOp(spaceID, type: type, body: body, label: "撤回")
      throw EngineError.queued
    }
    _ = try await sync(spaceID)
  }

  /// Opens an original another member shared (cached on this Mac until the
  /// item leaves the space).
  public func original(_ spaceID: String, itemID: String, blob: SpaceBlobRef) async throws
    -> Data
  {
    let state = try required(spaceID)
    let itemID = itemID.lowercased()
    if let cached = try states.original(space: state.spaceID, item: itemID, blob: blob.blobID) {
      return cached
    }
    let dataKey = try await self.dataKey(state, itemID: itemID)
    let sealed = try await guarded(state.spaceID) {
      try await self.client.blob(state.spaceID, blobID: blob.blobID)
    }
    let data = try SpaceCrypto.openBlob(
      sealed, dataKey: dataKey, spaceID: state.spaceID, itemID: itemID, blobID: blob.blobID)
    try states.saveOriginal(data, space: state.spaceID, item: itemID, blob: blob.blobID)
    return data
  }

  func dataKey(_ state: SpaceLocalState, itemID: String) async throws -> Data {
    let answer = try await guarded(state.spaceID) {
      try await self.client.itemKeys(state.spaceID, itemIDs: [itemID])
    }
    guard let entry = answer.items.first(where: { $0.itemID.lowercased() == itemID }) else {
      throw SpaceClientError.server(SpaceServerError(status: 410, code: "item_gone"))
    }
    return try SpaceCrypto.unwrapItemKey(
      entry.wrappedDK, spaceKey: key(state.spaceID, epoch: entry.epoch), spaceID: state.spaceID,
      epoch: entry.epoch, itemID: itemID)
  }

  // MARK: - Takedowns

  @discardableResult
  public func requestTakedown(
    _ spaceID: String, itemID: String, privacy: Bool, reason: String? = nil
  ) async throws -> String {
    let state = try required(spaceID)
    let takedownID = SpaceID.new()
    _ = try ok(
      try await post(
        state, type: "takedown.request",
        body: [
          "takedown_id": .string(takedownID), "item_id": .string(itemID.lowercased()),
          "kind": .string(privacy ? "privacy" : "other"),
        ], encPlain: reason.map { ["reason": .string($0)] }))
    _ = try await sync(spaceID)
    return takedownID
  }

  /// 同意 or 不同意 a takedown request. Someone else's privacy takedown can
  /// only be refused with a reason (only the requester and the maintainers
  /// read it); the contributor's own is always honoured.
  public func resolveTakedown(
    _ spaceID: String, takedownID: String, accept: Bool, reason: String? = nil
  ) async throws {
    let state = try required(spaceID)
    _ = try ok(
      try await post(
        state, type: "takedown.resolve",
        body: [
          "takedown_id": .string(takedownID), "decision": .string(accept ? "accept" : "reject"),
        ], encPlain: accept ? nil : reason.map { ["reason": .string($0)] }))
    _ = try await sync(spaceID)
  }

  public func withdrawTakedown(_ spaceID: String, takedownID: String) async throws {
    let state = try required(spaceID)
    _ = try ok(
      try await post(state, type: "takedown.withdraw", body: ["takedown_id": .string(takedownID)]))
    _ = try await sync(spaceID)
  }

  /// Open takedowns as the Spark sees them (with `overdue`).
  public func openTakedowns(_ spaceID: String) async throws -> [SpaceTakedownRecord] {
    let state = try required(spaceID)
    return try await guarded(state.spaceID) {
      try await self.client.takedowns(state.spaceID, status: "open")
    }
  }

  // MARK: - Proposals

  @discardableResult
  public func propose(
    _ spaceID: String, kind: String, matterIDs: [String] = [], itemIDs: [String] = [],
    ropeIDs: [String] = [], details: SpaceJSON? = nil
  ) async throws -> String {
    let state = try required(spaceID)
    let proposalID = SpaceID.new()
    var targets: SpaceJSON = [:]
    if !matterIDs.isEmpty { targets = targets.setting("matter_ids", SpaceJSON(matterIDs)) }
    if !itemIDs.isEmpty { targets = targets.setting("item_ids", SpaceJSON(itemIDs)) }
    if !ropeIDs.isEmpty { targets = targets.setting("rope_ids", SpaceJSON(ropeIDs)) }
    _ = try ok(
      try await post(
        state, type: "proposal.create",
        body: [
          "proposal_id": .string(proposalID), "kind": .string(kind), "targets": targets,
        ], encPlain: details))
    _ = try await sync(spaceID)
    return proposalID
  }

  /// A maintainer accepts or rejects a proposal; on accept the change is
  /// applied to the shared matters through the space organizer
  /// (`organizer/decisions`), where it maps to one.
  @discardableResult
  public func resolveProposal(_ spaceID: String, proposalID: String, accept: Bool) async throws
    -> Bool
  {
    let state = try required(spaceID)
    guard state.can("resolve_proposals") else { throw EngineError.notAllowed("resolve_proposals") }
    _ = try ok(
      try await post(
        state, type: "proposal.resolve",
        body: [
          "proposal_id": .string(proposalID), "decision": .string(accept ? "accept" : "reject"),
        ]))
    var applied = false
    if accept, let proposal = state.proposals[proposalID],
      let decision = Self.decision(for: proposal)
    {
      applied = (try? await editMatters(state.spaceID, decisions: [decision])) ?? false
    }
    _ = try await sync(spaceID)
    return applied
  }

  /// A maintainer's direct edit of the space's matters (`organizer/decisions`).
  /// A title is masked with the space's mask key first, as every organizing
  /// payload is: the Spark sees placeholders, never the numbers a maintainer
  /// typed (review V7-S13). Without a masker nothing with a title is sent.
  @discardableResult
  public func editMatters(_ spaceID: String, decisions: [SpaceJSON]) async throws -> Bool {
    let state = try required(spaceID)
    guard state.can("edit_matters") || state.can("resolve_proposals") else {
      throw EngineError.notAllowed("edit_matters")
    }
    let mask = try maskKey(state.spaceID)
    var masked: [SpaceJSON] = []
    for decision in decisions {
      if let title = decision["title"]?.string {
        guard let textMasker else { throw EngineError.refused("no_masker") }
        masked.append(
          decision.setting("title", .string(try textMasker.mask(title, maskKey: mask))))
      } else {
        masked.append(decision)
      }
    }
    let body = try SpaceJSON.object(["decisions": .array(masked)]).encoded()
    let answer = try await guarded(state.spaceID) {
      try await self.client.organizerDecisions(state.spaceID, body: body)
    }
    return (answer["applied"]?.int ?? 0) > 0
  }

  /// The organizer decision an accepted proposal stands for, when it maps to one.
  static func decision(for proposal: SpaceProposal) -> SpaceJSON? {
    let matters = proposal.targets?["matter_ids"]?.array?.compactMap(\.string) ?? []
    let id = SpaceID.new()
    switch proposal.kind {
    case "rename":
      guard let event = matters.first, let title = proposal.details?["title"]?.string else {
        return nil
      }
      return [
        "decision_id": .string(id), "kind": "rename_event", "event_id": .string(event),
        "title": .string(title),
      ]
    case "merge":
      guard matters.count == 2 else { return nil }
      return [
        "decision_id": .string(id), "kind": "same_event", "a": .string(matters[0]),
        "b": .string(matters[1]), "answer": true,
      ]
    default:
      return nil
    }
  }

  public func withdrawProposal(_ spaceID: String, proposalID: String) async throws {
    let state = try required(spaceID)
    _ = try ok(
      try await post(state, type: "proposal.withdraw", body: ["proposal_id": .string(proposalID)]))
    _ = try await sync(spaceID)
  }

  public func openProposals(_ spaceID: String) async throws -> SpaceProposals {
    let state = try required(spaceID)
    return try await guarded(state.spaceID) { try await self.client.proposals(state.spaceID) }
  }

  /// A maintainer answers one of the organizer's own proposals (an
  /// uncertain merge or same-person question).
  public func answerOrganizerProposal(_ spaceID: String, questionID: String, yes: Bool)
    async throws
  {
    let state = try required(spaceID)
    let qid = questionID.hasPrefix("q:") ? String(questionID.dropFirst(2)) : questionID
    _ = try await guarded(state.spaceID) {
      try await self.client.answerOrganizerQuestion(
        state.spaceID, questionID: qid, answer: yes ? "yes" : "no")
    }
  }

  // MARK: - Members, rotation

  public func setRole(_ spaceID: String, memberID: String, role: SpaceRole) async throws {
    let state = try required(spaceID)
    _ = try ok(
      try await post(
        state, type: "member.role",
        body: ["member_id": .string(memberID), "role": .string(role.rawValue)]))
    _ = try await sync(spaceID)
  }

  /// 移除: a new space key wrapped to every remaining active device, the old
  /// key linked under it, one `member.remove` op; then the organizer store is
  /// re-keyed at the next lease. The removed member's Macs cannot open
  /// anything shared afterwards.
  public func removeMember(_ spaceID: String, memberID: String) async throws {
    var state = try await sync(spaceID)
    guard state.can("remove_members") else { throw EngineError.notAllowed("remove_members") }
    let (body, newKey) = try await rotation(state, excluding: memberID)
    let result = try ok(
      try await post(
        state, type: "member.remove", body: body.setting("member_id", .string(memberID))))
    try keyStore.save(newKey, space: state.spaceID, epoch: state.epoch + 1)
    state.epoch = result.effects?["epoch"]?.int ?? state.epoch + 1
    try states.save(state)
    _ = try await sync(spaceID)
  }

  /// After a member left (`rotation_pending`), an admin's Mac rotates.
  public func rotate(_ spaceID: String) async throws {
    var state = try await sync(spaceID)
    guard state.can("rotate") else { throw EngineError.notAllowed("rotate") }
    if let back = state.readmittedAfterRollback, !back.isEmpty {
      // V8R-03: a new key never goes to whoever a log gone back let in again;
      // they are removed again instead (each removal makes the new key).
      if try await repairRollback(spaceID) > 0 { return }
      throw EngineError.refused("removed_member_back")
    }
    let (body, newKey) = try await rotation(state, excluding: nil)
    _ = try ok(try await post(state, type: "epoch.rotate", body: body))
    try keyStore.save(newKey, space: state.spaceID, epoch: state.epoch + 1)
    state.epoch += 1
    try states.save(state)
    _ = try await sync(spaceID)
  }

  func rotation(
    _ state: SpaceLocalState, excluding memberID: String?, excludingDevice: String? = nil
  ) async throws -> (SpaceJSON, Data) {
    let next = state.epoch + 1
    let newKey = SpaceCrypto.randomKey()
    var wraps: [SpaceJSON] = []
    // Only devices the signed log admitted get the new key (V7-S1); a device
    // the Spark lists beyond those makes the Spark refuse the rotation.
    let devices = (state.roster ?? SpaceRoster()).activeDevices(excluding: memberID).filter {
      $0.deviceID != excludingDevice
    }
    for device in devices {
      guard let seal = device.sealKey else { continue }
      wraps.append([
        "device_id": .string(device.deviceID), "epoch": SpaceJSON(next),
        "wrap": .string(
          try SpaceCrypto.wrapSpaceKey(
            newKey, to: seal, spaceID: state.spaceID, epoch: next, deviceID: device.deviceID)),
      ])
    }
    let link = try SpaceCrypto.epochLink(
      newKey: newKey, previousKey: currentKey(state), spaceID: state.spaceID, epoch: next)
    var body: SpaceJSON = [
      "epoch": SpaceJSON(next), "wraps": .array(wraps), "epoch_link": .string(link),
    ]
    if state.ownerKind == .org, let orgID = state.orgID {
      // v8 B5: the new key is also escrowed to the org's admin devices that
      // get no member wrap, as the org's own signed log names them.
      // Never to a device being retired, even while it is still an org device.
      let escrow = try await escrowWraps(
        orgID: orgID, key: newKey, spaceID: state.spaceID, epoch: next,
        memberDevices: Set(devices.map(\.deviceID) + [excludingDevice].compactMap { $0 }))
      if !escrow.isEmpty { body = body.setting("escrow_wraps", .array(escrow)) }
    }
    return (body, newKey)
  }

  /// 离开: contributions stay (org spaces) or go (group spaces, if chosen);
  /// this Mac's keys and copies of the space's content are deleted.
  public func leave(_ spaceID: String, withdrawContributions: Bool) async throws -> [String] {
    let state = try required(spaceID)
    let contributions =
      withdrawContributions && state.policy.onLeave == "contributor_choice" ? "withdraw" : "keep"
    _ = try ok(
      try await post(
        state, type: "member.leave", body: ["contributions": .string(contributions)]))
    try await accessEnded(spaceID, purgeForks: Array(state.forks.keys))
    return takeForkCopiesToDelete()
  }

  /// Lazy re-wrap after a rotation: every item key still under an older
  /// epoch, re-wrapped under the current one (any contributor's Mac).
  @discardableResult
  public func rewrapStale(_ spaceID: String) async throws -> Int {
    let state = try required(spaceID)
    guard state.can("rewrap") else { return 0 }
    let stale = try await guarded(state.spaceID) {
      try await self.client.staleItemKeys(state.spaceID)
    }
    guard !stale.items.isEmpty, stale.epoch == state.epoch else { return 0 }
    let current = try currentKey(state)
    var rewraps: [SpaceJSON] = []
    for entry in stale.items {
      guard let old = try? key(state.spaceID, epoch: entry.epoch),
        let dataKey = try? SpaceCrypto.unwrapItemKey(
          entry.wrappedDK, spaceKey: old, spaceID: state.spaceID, epoch: entry.epoch,
          itemID: entry.itemID)
      else { continue }
      rewraps.append([
        "item_id": .string(entry.itemID), "epoch": SpaceJSON(state.epoch),
        "wrapped_dk": .string(
          try SpaceCrypto.wrapItemKey(
            dataKey, spaceKey: current, spaceID: state.spaceID, epoch: state.epoch,
            itemID: entry.itemID)),
      ])
    }
    guard !rewraps.isEmpty else { return 0 }
    return try await guarded(state.spaceID) {
      try await self.client.rewrap(state.spaceID, rewraps)
    }
  }

  // MARK: - Space settings

  public func setPolicy(_ spaceID: String, _ changes: SpaceJSON) async throws {
    let state = try required(spaceID)
    _ = try ok(try await post(state, type: "space.policy", body: ["policy": changes]))
    _ = try await sync(spaceID)
  }

  public func rename(_ spaceID: String, name: String) async throws {
    let state = try required(spaceID)
    _ = try ok(
      try await post(state, type: "space.meta", body: [:], encPlain: ["name": .string(name)]))
    _ = try await sync(spaceID)
  }

  public func archive(_ spaceID: String, archived: Bool) async throws {
    let state = try required(spaceID)
    _ = try ok(try await post(state, type: "space.archive", body: ["archived": .bool(archived)]))
    _ = try await sync(spaceID)
  }

  public func handover(_ spaceID: String, matterID: String, to memberID: String) async throws {
    let state = try required(spaceID)
    _ = try ok(
      try await post(
        state, type: "matter.handover",
        body: ["matter_id": .string(matterID), "to_member_id": .string(memberID)]))
    _ = try await sync(spaceID)
  }

  /// An agent read this space (AGENT-CONTRACT): counts only, never content.
  public func recordAgentAccess(
    _ spaceID: String, client agent: String, tool: String, matters: Int, items: Int, bytes: Int,
    allowed: Bool
  ) async throws {
    let state = try required(spaceID)
    _ = try await post(
      state, type: "agent.access",
      body: [
        "client": .string(agent), "tool": .string(tool), "matters": SpaceJSON(matters),
        "items": SpaceJSON(items), "bytes": SpaceJSON(bytes), "allowed": .bool(allowed),
      ])
  }

  /// The audit view (admins): records only — ids, counts and codes.
  public func audit(_ spaceID: String, since: Int = 0) async throws -> SpaceAuditPage {
    let state = try required(spaceID)
    guard state.role == .admin else { throw EngineError.notAllowed("audit") }
    return try await guarded(state.spaceID) {
      try await self.client.audit(state.spaceID, since: since, limit: 500)
    }
  }

  // MARK: - The space organizer

  /// Takes the lease (the store key of the current epoch and the space's
  /// mask key, into the Spark's memory only), sends the payloads the store
  /// lacks — masked with the space's mask key — and pulls the derived state.
  @discardableResult
  public func organize(_ spaceID: String, builder: (any SpacePayloadBuilding)?) async throws
    -> SpaceOrganizeReport
  {
    var state = try await sync(spaceID)
    var report = SpaceOrganizeReport()
    let id = state.spaceID
    let mask = try maskKey(id)
    do {
      let body = try leaseBody(state, mask: mask, previous: nil)
      _ = try await guarded(id) { try await self.client.lease(id, body: body) }
    } catch SpaceClientError.server(let error) where error.code == "wrong_key" {
      // The store is still under an older epoch's key: open it with that key
      // and re-key it under the current one.
      guard let previous = error.extra["epoch"]?.int, previous < state.epoch else { throw error }
      let body = try leaseBody(state, mask: mask, previous: previous)
      _ = try await guarded(id) { try await self.client.lease(id, body: body) }
      report.rekeyed = true
    } catch SpaceClientError.server(let error) where error.code == "stale_epoch" {
      state = try await sync(id)
      let body = try leaseBody(state, mask: mask, previous: nil)
      _ = try await guarded(id) { try await self.client.lease(id, body: body) }
    }
    report.leased = true
    if state.can("lease_write"), let builder {
      let pending = try await guarded(id) { try await self.client.pending(id) }
      var payloads: [Data] = []
      var bytes = 0
      for entry in pending {
        guard let item = state.items[entry.itemID.lowercased()], item.isActive,
          item.revision == entry.revision, let fields = item.fields
        else {
          report.skipped += 1
          continue
        }
        let engine = self
        guard
          let payload = try await builder.payload(
            item: item, fields: fields, maskKey: mask,
            original: { blob in try await engine.original(id, itemID: item.itemID, blob: blob) })
        else {
          report.skipped += 1
          continue
        }
        if !payloads.isEmpty, payloads.count >= 50 || bytes + payload.count > 24_000_000 {
          _ = try await guarded(id) { try await self.client.organizerItems(id, items: payloads) }
          report.sent += payloads.count
          payloads = []
          bytes = 0
        }
        payloads.append(payload)
        bytes += payload.count
      }
      if !payloads.isEmpty {
        _ = try await guarded(id) { try await self.client.organizerItems(id, items: payloads) }
        report.sent += payloads.count
      }
    }
    let raw = try await guarded(id) { try await self.client.organizerState(id) }
    let json = (try? SpaceJSON.decode(raw)) ?? [:]
    let sameAs = (try? json["same_as"]?.decoded(as: [SpaceSameAs].self)) ?? []
    state.organizer = SpaceOrganizerSnapshot(
      state: raw, sameAs: sameAs, busyQueue: json["busy"]?["queue"]?.int ?? 0,
      busyBriefs: json["busy"]?["briefs"]?.int ?? 0, pulledAt: now())
    try states.save(state)
    report.pulled = true
    return report
  }

  /// The lease: the current epoch's store key and the space's mask key (and,
  /// to re-key a store an older epoch's key still locks, that key too).
  func leaseBody(_ state: SpaceLocalState, mask: Data, previous: Int?) throws -> SpaceJSON {
    var body: SpaceJSON = [
      "epoch": SpaceJSON(state.epoch),
      "store_key": .string(SpaceCrypto.hex(SpaceCrypto.storeKey(spaceKey: try currentKey(state)))),
      "mask_key": .string(SpaceCrypto.hex(mask)),
    ]
    if let previous {
      body = body.setting(
        "previous",
        [
          "epoch": SpaceJSON(previous),
          "store_key": .string(
            SpaceCrypto.hex(
              SpaceCrypto.storeKey(spaceKey: try key(state.spaceID, epoch: previous)))),
        ])
    }
    return body
  }

  /// Ends the lease now (the Spark also locks the store after 600 s idle).
  public func lockOrganizer(_ spaceID: String) async {
    try? await client.lockOrganizer(spaceID.lowercased())
  }
}

extension SpaceJSON {
  /// Object fields of `other` over this object's.
  public func merging(_ other: SpaceJSON) -> SpaceJSON {
    guard case .object(var mine) = self, case .object(let theirs) = other else { return self }
    for (key, value) in theirs { mine[key] = value }
    return .object(mine)
  }
}
