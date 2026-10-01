import Foundation
import MindloomLink

/// A space's members and devices as the signed op log admitted them, rebuilt
/// on this Mac op by op (review finding V7-S1). The Spark's member list
/// (`GET /v1/spaces/{id}`) is never used for keys or devices: anyone who can
/// write the Spark's plain `spaces.db` could add a device row there, and it
/// would then receive the next space key and sign ops in a member's name.
///
/// What admits a device: the genesis op's own device, a `join.approve`
/// (signed by an admin's device, naming the joiner's member id and both
/// public keys), a `device.add` signed by one of the member's own devices.
/// What ends one: `device.remove`, `member.remove`, `member.leave`. The epoch
/// in use is the newest one a signed rotation made (V7-S10). The reference
/// is the Spark repository's `space_member.replay`.
///
/// Honest limit: roles are not recomputed here (the Spark checks them), so a
/// member who colludes with whoever runs the Spark could sign a membership op
/// an honest Spark would refuse; an outsider with only the Spark cannot.
public struct SpaceRoster: Codable, Equatable, Sendable {
  public struct Device: Codable, Equatable, Sendable {
    public let deviceID: String
    public let signPub: String
    public let sealPub: String
    public var active: Bool

    public var signKey: Data? {
      Base64URL.decode(signPub, allowPadding: true).flatMap { $0.count == 32 ? $0 : nil }
    }

    public var sealKey: Data? {
      Base64URL.decode(sealPub, allowPadding: true).flatMap { $0.count == 32 ? $0 : nil }
    }

    public var publicRecord: SpaceDevicePublic {
      SpaceDevicePublic(deviceID: deviceID, signPub: signPub, sealPub: sealPub, status: "active")
    }
  }

  public struct Member: Codable, Equatable, Sendable {
    /// `active`, `removed` or `left`.
    public var status: String
    public var devices: [String: Device]
  }

  public var members: [String: Member] = [:]
  /// The newest epoch a signed op created (1 after the genesis op).
  public var epoch = 0
  /// A member left since the last rotation: nothing new may be encrypted
  /// under the key they still hold.
  public var rotationPending = false
  public var genesis = false

  public init() {}

  /// The device a member's op must be signed by: admitted by the log and
  /// still active, of a member who is still active.
  public func device(member: String?, device: String?) -> Device? {
    guard let member, let device, let m = members[member], m.status == "active",
      let d = m.devices[device], d.active
    else { return nil }
    return d
  }

  /// Every active device of every active member (a rotation wraps to these).
  public func activeDevices(excluding memberID: String? = nil) -> [Device] {
    members.filter { $0.key != memberID && $0.value.status == "active" }
      .sorted { $0.key < $1.key }
      .flatMap { $0.value.devices.values.filter(\.active).sorted { $0.deviceID < $1.deviceID } }
  }

  public var activeDeviceIDs: Set<String> { Set(activeDevices().map(\.deviceID)) }

  /// The member and device a genesis op names, if it is signed by that device.
  mutating func admitGenesis(member: String, device record: SpaceJSON?) -> Bool {
    guard !genesis, let device = Self.device(record) else { return false }
    genesis = true
    epoch = max(epoch, 1)
    members[member] = Member(status: "active", devices: [device.deviceID: device])
    return true
  }

  /// What one verified op changes in the roster.
  mutating func apply(type: String, member: String?, body: SpaceJSON) {
    switch type {
    case "join.approve":
      // An approval that does not name the joiner's keys admits nobody here.
      guard let joiner = body["member_id"]?.string, SpaceID.isValid(joiner),
        let device = Self.device(body["device"])
      else { return }
      var record = members[joiner] ?? Member(status: "active", devices: [:])
      guard record.status != "removed" else { return }
      record.status = "active"
      record.devices[device.deviceID] = device
      members[joiner] = record
    case "device.add":
      guard let member, members[member] != nil, let device = Self.device(body["device"]) else {
        return
      }
      members[member]?.devices[device.deviceID] = device
    case "device.remove":
      if let id = body["device_id"]?.string {
        for key in members.keys where members[key]?.devices[id] != nil {
          members[key]?.devices[id]?.active = false
        }
      }
      rotated(body)
    case "member.remove":
      if let id = body["member_id"]?.string { end(id, status: "removed") }
      rotated(body)
    case "member.leave":
      if let member { end(member, status: "left") }
      rotationPending = true
    case "epoch.rotate":
      rotated(body)
    default:
      break
    }
  }

  private mutating func end(_ memberID: String, status: String) {
    guard var record = members[memberID] else { return }
    record.status = status
    for key in record.devices.keys { record.devices[key]?.active = false }
    members[memberID] = record
  }

  private mutating func rotated(_ body: SpaceJSON) {
    guard let next = body["epoch"]?.int, next > epoch else { return }
    epoch = next
    rotationPending = false
  }

  static func device(_ record: SpaceJSON?) -> Device? {
    guard let id = record?["device_id"]?.string, SpaceID.isValid(id),
      let sign = record?["sign_pub"]?.string, let seal = record?["seal_pub"]?.string
    else { return nil }
    let device = Device(deviceID: id, signPub: sign, sealPub: seal, active: true)
    guard device.signKey != nil, device.sealKey != nil else { return nil }
    return device
  }
}

/// An organization's admins and their devices, from its own signed log
/// alone (`GET /v1/orgs/{id}` "ops", only an org admin's device may read it;
/// reference `space_member.org_roster`): `org.create` signed by the device it
/// names, then `org.admin_add` / `org.admin_remove` / `org.device_add` /
/// `org.device_remove` signed by an active admin's device. What a takeover
/// (`space.recover`) and the escrow wraps of a new space key are checked
/// against (v8 B5). The Spark's own lists are never used for keys.
public struct SpaceOrgRoster: Codable, Equatable, Sendable {
  public struct Admin: Codable, Equatable, Sendable {
    public var status: String
    public var devices: [String: SpaceRoster.Device]
  }

  public let orgID: String
  public var admins: [String: Admin] = [:]
  public var policy: Int = 1
  /// Ops that did not verify (counted, never applied).
  public var rejected = 0

  public init(orgID: String) { self.orgID = orgID.lowercased() }

  /// Rebuilds the roster from the org's ops in seq order.
  public init(orgID: String, entries: [SpaceLogEntry]) {
    self.init(orgID: orgID)
    for entry in entries.sorted(by: { $0.seq < $1.seq }) { admit(entry) }
  }

  mutating func admit(_ entry: SpaceLogEntry) {
    guard let bytes = entry.opBytes, let op = try? SpaceJSON.decode(bytes),
      op["org_id"]?.string == orgID, op["type"]?.string == entry.type, let sig = entry.sig
    else {
      rejected += 1
      return
    }
    let body = op["body"] ?? [:]
    let member = op["member_id"]?.string ?? ""
    if entry.type == "org.create" {
      guard admins.isEmpty, let device = SpaceRoster.device(body["device"]),
        device.deviceID == op["device_id"]?.string, let key = device.signKey,
        SpaceSignatures.verifyOp(bytes, signature: sig, signPub: key)
      else {
        rejected += 1
        return
      }
      admins[member] = Admin(status: "active", devices: [device.deviceID: device])
      if let n = body["policy"]?["recovery_admins"]?.int { policy = n }
      return
    }
    guard let signer = self.device(member: member, device: op["device_id"]?.string),
      let key = signer.signKey, SpaceSignatures.verifyOp(bytes, signature: sig, signPub: key)
    else {
      rejected += 1
      return
    }
    switch entry.type {
    case "org.admin_add":
      guard let id = body["member_id"]?.string, SpaceID.isValid(id),
        let device = SpaceRoster.device(body["device"])
      else { return }
      var admin = admins[id] ?? Admin(status: "active", devices: [:])
      admin.status = "active"
      admin.devices[device.deviceID] = device
      admins[id] = admin
    case "org.device_add":
      if let device = SpaceRoster.device(body["device"]) {
        admins[member]?.devices[device.deviceID] = device
      }
    case "org.device_remove":
      guard let target = body["device_id"]?.string, target != op["device_id"]?.string else {
        return
      }
      for id in admins.keys where admins[id]?.devices[target] != nil {
        admins[id]?.devices[target]?.active = false
      }
    case "org.admin_remove":
      if let id = body["member_id"]?.string, var admin = admins[id] {
        admin.status = "removed"
        for d in admin.devices.keys { admin.devices[d]?.active = false }
        admins[id] = admin
      }
    case "org.policy":
      if let n = body["recovery_admins"]?.int { policy = n }
    default:
      break
    }
  }

  /// An active device of an active admin.
  public func device(member: String?, device: String?) -> SpaceRoster.Device? {
    guard let member, let device, let admin = admins[member], admin.status == "active",
      let d = admin.devices[device], d.active
    else { return nil }
    return d
  }

  /// Every active device of every active admin: where an org space's key is
  /// escrowed (`space_member.escrow_devices`).
  public var escrowDevices: [(memberID: String, device: SpaceRoster.Device)] {
    admins.filter { $0.value.status == "active" }.sorted { $0.key < $1.key }.flatMap { id, admin in
      admin.devices.values.filter(\.active).sorted { $0.deviceID < $1.deviceID }.map { (id, $0) }
    }
  }

  public var activeAdmins: [String] {
    admins.filter { $0.value.status == "active" }.keys.sorted()
  }

  public func isAdmin(_ memberID: String) -> Bool { admins[memberID]?.status == "active" }
}

/// What this Mac pinned of an organization's signed log (review finding
/// V8R-02): the hash of its first op (`org.create`) and its creator device,
/// and a hash chain over every op it has accepted so far. A later fetch of
/// the log is believed only when it starts with that very `org.create` and
/// continues the chain: whoever runs the Spark (or can write its plain
/// `spaces.db`) cannot serve a new log for the same org id with an
/// `org.create` of its own device, nor rewrite the history, and so never
/// becomes an "admin device" that space keys are escrowed or rotated to.
///
/// Pinned when this Mac creates the organization, else the first time it
/// reads the log, checked against the commitment an org space's own signed
/// genesis op carries (`owner.org_genesis`) when it has one.
public struct SpaceOrgPin: Codable, Equatable, Sendable {
  public let orgID: String
  /// SHA-256 (hex) of the exact bytes of the organization's `org.create` op.
  public let genesisHash: String
  public let creatorDevice: String
  public let creatorSignPub: String
  /// The ops accepted so far (seq 1…headSeq) and their chain hash.
  public var headSeq: Int
  public var headHash: String

  public init(
    orgID: String, genesisHash: String, creatorDevice: String, creatorSignPub: String,
    headSeq: Int, headHash: String
  ) {
    self.orgID = orgID.lowercased()
    self.genesisHash = genesisHash
    self.creatorDevice = creatorDevice
    self.creatorSignPub = creatorSignPub
    self.headSeq = headSeq
    self.headHash = headHash
  }

  static let chainStart = SpaceCrypto.sha256Hex(Data("mindloom-org-log-v1".utf8))

  static func step(_ hash: String, seq: Int, bytes: Data, sig: String?) -> String {
    SpaceCrypto.sha256Hex(Data("\(hash)|\(seq)|\(SpaceCrypto.sha256Hex(bytes))|\(sig ?? "")".utf8))
  }

  /// The chain over the first `count` entries (seq 1…count, in order).
  public static func chain(_ entries: [SpaceLogEntry], count: Int) -> String? {
    var hash = chainStart
    for (index, entry) in entries.prefix(count).enumerated() {
      guard entry.seq == index + 1, let bytes = entry.opBytes else { return nil }
      hash = step(hash, seq: entry.seq, bytes: bytes, sig: entry.sig)
    }
    return hash
  }

  /// The pin of an organization this Mac has just created with `op`.
  public static func created(orgID: String, op: SpaceWireOp, device: SpaceDevicePublic)
    -> SpaceOrgPin
  {
    SpaceOrgPin(
      orgID: orgID, genesisHash: SpaceCrypto.sha256Hex(op.opJSON), creatorDevice: device.deviceID,
      creatorSignPub: device.signPub, headSeq: 1,
      headHash: step(chainStart, seq: 1, bytes: op.opJSON, sig: op.signature))
  }

  /// A log's first op as a pin (seq 1, an `org.create` signed by the device it
  /// names), or nil.
  public static func genesis(orgID: String, entries: [SpaceLogEntry]) -> SpaceOrgPin? {
    guard let first = entries.first, first.seq == 1, first.type == "org.create",
      let bytes = first.opBytes, let sig = first.sig, let op = try? SpaceJSON.decode(bytes),
      op["org_id"]?.string == orgID.lowercased(), op["type"]?.string == "org.create",
      let device = SpaceRoster.device(op["body"]?["device"]),
      device.deviceID == op["device_id"]?.string, let key = device.signKey,
      SpaceSignatures.verifyOp(bytes, signature: sig, signPub: key),
      let chain = chain(entries, count: 1)
    else { return nil }
    return SpaceOrgPin(
      orgID: orgID, genesisHash: SpaceCrypto.sha256Hex(bytes), creatorDevice: device.deviceID,
      creatorSignPub: device.signPub, headSeq: 1, headHash: chain)
  }

  /// Whether `entries` (seq 1… in order, no gaps) start with the pinned
  /// genesis and continue the pinned chain; the pin moved to their head.
  public func advanced(by entries: [SpaceLogEntry]) -> SpaceOrgPin? {
    let sorted = entries.sorted { $0.seq < $1.seq }
    guard sorted.enumerated().allSatisfy({ $0.offset + 1 == $0.element.seq }),
      let first = sorted.first?.opBytes, SpaceCrypto.sha256Hex(first) == genesisHash,
      sorted.count >= headSeq, Self.chain(sorted, count: headSeq) == headHash,
      let head = Self.chain(sorted, count: sorted.count)
    else { return nil }
    var next = self
    next.headSeq = sorted.count
    next.headHash = head
    return next
  }
}

/// A takeover this Mac could not check against the organization's log (a
/// plain member cannot read it): shown with the new admin's fingerprint
/// until the member confirms it out of band.
public struct SpacePendingRecovery: Codable, Equatable, Identifiable, Sendable {
  public let seq: Int
  public let memberID: String
  public let device: SpaceDevicePublic

  public var id: String { device.deviceID }
  public var fingerprint: String { device.fingerprint }

  public init(seq: Int, memberID: String, device: SpaceDevicePublic) {
    self.seq = seq
    self.memberID = memberID
    self.device = device
  }
}

extension SpaceRoster {
  /// `space.recover` (v8 B5): an org admin's device takes the space over; the
  /// caller checked its signature against the org roster (or the member's
  /// confirmation).
  mutating func admitRecovery(member: String, device: Device) {
    var record = members[member] ?? Member(status: "active", devices: [:])
    record.status = "active"
    record.devices[device.deviceID] = device
    members[member] = record
  }
}
