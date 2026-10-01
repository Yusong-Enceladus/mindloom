import Foundation
import MindloomLink

/// The two sides of pairing a Mac to the team Spark's gate (v8 B1): the
/// admin's Mac makes a one-time ticket and an invite code; the invitee's Mac
/// enrolls through the ticket key, gets its own credential and keeps its own
/// key. The Spark sees the ticket's public key and the secret's hash, then
/// the invitee's public key — never a private key or the secret.
public enum TeamAccess {
  public enum TeamError: Error, Equatable, Sendable {
    case refused(String)
    case expired
  }

  /// Registers a ticket and builds the invite. `memberID` only for a device
  /// ticket (another Mac of the same member).
  public static func makeInvite(
    access: AccessClient, kind: AccessInviteCode.Kind, spark: SpaceInviteCode.Endpoint,
    relay: SpaceInviteCode.Endpoint?, memberID: String? = nil, team: String?, space: String?,
    lifetime: TimeInterval = 3 * 86_400, now: Date = Date()
  ) async throws -> (code: AccessInviteCode, ticketKey: SSHEd25519Key) {
    let key = SSHEd25519Key()
    let secret = SpaceCrypto.randomKey()
    let ticketID = SpaceID.new()
    let expires = now.addingTimeInterval(min(lifetime, MemberAccess.maximumTicketLifetime) - 60)
    try await access.createTicket(
      ticketID: ticketID, kind: kind, sshKey: key.authorizedKey,
      secretHash: MemberAccess.ticketHash(secret), expiresAt: expires,
      memberID: kind == .device ? memberID : nil)
    let code = AccessInviteCode(
      kind: kind, spark: spark, relay: relay, ticketID: ticketID, key: key, secret: secret,
      expiresAt: expires, memberID: kind == .device ? memberID : nil, team: team, space: space)
    return (code, key)
  }

  public typealias Enroller =
    @Sendable (_ ticketKey: SSHEd25519Key, _ request: SpaceJSON) async throws -> AccessEnrollAnswer

  /// Enrolls this Mac with an invite: its own new SSH key, its member id
  /// (the device ticket's, or this Mac's own), its device keys, signed. The
  /// record (credential, key seed, route) is saved before it is returned.
  public static func enroll(
    code: AccessInviteCode, device: SpaceDeviceKeys, memberID: String, store: any MemberAccessStore,
    now: Date = Date(), enroller: Enroller
  ) async throws -> MemberAccessRecord {
    guard let expiry = code.expiry, expiry > now else { throw TeamError.expired }
    guard let ticketKey = code.ticketKey, let secret = code.secretBytes else {
      throw AccessInviteCode.CodeError.malformed
    }
    let member = (code.memberID ?? memberID).lowercased()
    let key = SSHEd25519Key()
    let request = try MemberAccess.enrollRequest(
      device: device, ticketID: code.ticketID, secret: secret, sshKey: key.authorizedKey,
      memberID: member, createdAt: now)
    let answer = try await enroller(ticketKey, request)
    guard answer.ok, let accessID = answer.accessID, let credential = answer.credential,
      MemberAccess.accessID(ofCredential: credential) == accessID,
      (answer.memberID ?? member) == member, (answer.deviceID ?? device.deviceID) == device.deviceID
    else { throw TeamError.refused(answer.error ?? "refused") }
    let record = MemberAccessRecord(
      accessID: accessID, memberID: member, deviceID: device.deviceID, credential: credential,
      key: key, relayKey: code.relay == nil ? nil : ticketKey, spark: code.spark, relay: code.relay,
      fingerprint: answer.fingerprint ?? key.fingerprint, pairedAt: now, team: code.team)
    try store.save(record)
    return record
  }

  /// Plain words for the Spark's enrollment and ticket refusals.
  public static func message(_ code: String) -> String {
    switch code {
    case "bad_secret": return "邀请码不对"
    case "ticket_used": return "这个邀请码已经用过了"
    case "ticket_closed": return "这个邀请码已经过期或被收回"
    case "ticket_locked": return "这个邀请码试错太多次，已经锁住；请对方重新邀请"
    case "wrong_member": return "这个邀请只能加同一个人的另一台 Mac"
    case "member_exists": return "你已经用另一台 Mac 加入过；请让那台 Mac 邀请这台"
    case "device_exists", "device_member_conflict", "device_key_conflict":
      return "这台 Mac 已经以别人的身份登记过，不能再加入"
    case "device_revoked":
      return "这台 Mac 以前被这台整理设备断开过，不能用原来的设备钥匙再加入；请联系整理设备的主人"
    case "member_id_taken":
      return "这个身份在整理设备上已经是别人的了，不能用来加入；请让对方用他自己的 Mac 邀请这台"
    case "bad_signature": return "这台 Mac 的设备钥匙对不上，没有加入"
    case "not_allowed": return "邀请钥匙只能用来加入"
    case "unavailable": return "整理设备暂时没有响应，请稍后再试"
    case "too_many_devices": return "一个人最多 4 台 Mac"
    case "too_many_tickets": return "没用掉的邀请太多了（最多 20 个）；先收回一些"
    case "key_in_use", "ticket_exists": return "这把邀请钥匙已经登记过；请重新生成邀请"
    case "forbidden": return "只有整理设备的主人和组织管理员能邀请新队友"
    case "expired": return "邀请码已经过期"
    default: return "没有加入（\(code)）"
    }
  }
}
