import Foundation
import MindloomLink

/// The invite code an admin's Mac shows as a QR code and as text, and the
/// invitee's Mac reads (`mlinvite1.` + base64url JSON). It travels Mac to
/// Mac; the Spark never sees it. It holds the one-time secret, so the code
/// alone joins nobody: the admin still approves the request, and the space
/// key is wrapped only to the device the admin approved.
public struct SpaceInviteCode: Codable, Equatable, Sendable {
  public static let prefix = "mlinvite1."
  public static let maximumLifetime: TimeInterval = 7 * 86_400

  public struct Endpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int
    public let user: String?
    /// `ssh-ed25519 AAAA…`, pinned: the invitee refuses any other host key.
    public let hostKey: String

    public init(host: String, port: Int = 22, user: String?, hostKey: String) {
      self.host = host
      self.port = port
      self.user = user
      self.hostKey = hostKey
    }

    enum CodingKeys: String, CodingKey {
      case host, port, user
      case hostKey = "host_key"
    }
  }

  public struct Inviter: Codable, Equatable, Sendable {
    public let memberID: String
    public let deviceID: String
    /// base64url X25519: the joiner seals its display name to it.
    public let sealPub: String

    public init(memberID: String, deviceID: String, sealPub: String) {
      self.memberID = memberID
      self.deviceID = deviceID
      self.sealPub = sealPub
    }

    enum CodingKeys: String, CodingKey {
      case memberID = "member_id"
      case deviceID = "device_id"
      case sealPub = "seal_pub"
    }
  }

  public let v: Int
  public let spaceID: String
  public let inviteID: String
  /// base64url of 32 random bytes.
  public let secret: String
  public let expiresAt: String
  public let spaceName: String
  public let role: String?
  public let spark: Endpoint
  public let relay: Endpoint?
  public let inviter: Inviter

  public init(
    spaceID: String, inviteID: String, secret: Data, expiresAt: Date, spaceName: String,
    role: SpaceRole?, spark: Endpoint, relay: Endpoint?, inviter: Inviter
  ) {
    v = 1
    self.spaceID = spaceID.lowercased()
    self.inviteID = inviteID.lowercased()
    self.secret = Base64URL.encode(secret)
    self.expiresAt = SpaceTime.string(expiresAt)
    self.spaceName = spaceName
    self.role = role?.rawValue
    self.spark = spark
    self.relay = relay
    self.inviter = inviter
  }

  enum CodingKeys: String, CodingKey {
    case v
    case spaceID = "space_id"
    case inviteID = "invite_id"
    case secret
    case expiresAt = "expires_at"
    case spaceName = "space_name"
    case role, spark, relay, inviter
  }

  public enum CodeError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion
    case expired
    case missingHostKey
  }

  public var secretBytes: Data? {
    Base64URL.decode(secret, allowPadding: true).flatMap { $0.count == 32 ? $0 : nil }
  }

  public var expiry: Date? { SpaceTime.date(expiresAt) }

  public var inviterSealKey: Data? {
    Base64URL.decode(inviter.sealPub, allowPadding: true).flatMap { $0.count == 32 ? $0 : nil }
  }

  public func encoded() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return Self.prefix + Base64URL.encode(try encoder.encode(self))
  }

  /// Reads a pasted or scanned code (surrounding whitespace ignored) and
  /// checks it is usable now: ids, secret, a pinned host key, not expired.
  public static func decode(_ text: String, now: Date = Date()) throws -> SpaceInviteCode {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(prefix),
      let raw = Base64URL.decode(String(trimmed.dropFirst(prefix.count)), allowPadding: true),
      let code = try? JSONDecoder().decode(SpaceInviteCode.self, from: raw)
    else { throw CodeError.malformed }
    guard code.v == 1 else { throw CodeError.unsupportedVersion }
    guard SpaceID.isValid(code.spaceID), SpaceID.isValid(code.inviteID),
      SpaceID.isValid(code.inviter.memberID), SpaceID.isValid(code.inviter.deviceID),
      code.secretBytes != nil, code.inviterSealKey != nil,
      !code.spaceName.isEmpty, code.spaceName.count <= 80
    else { throw CodeError.malformed }
    guard code.spark.hostKey.hasPrefix("ssh-") else { throw CodeError.missingHostKey }
    guard let expiry = code.expiry else { throw CodeError.malformed }
    guard expiry > now else { throw CodeError.expired }
    return code
  }
}
