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
