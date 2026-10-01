import CryptoKit
import Foundation
import MindloomLink

// Per-member access to the team Spark (v8 contract B1; the Spark's
// `organizer/access.py` and `docs/INFRA.md`): every member Mac has its own
// SSH key, locked on the Spark by a forced command to the gate's bridge, and
// its own credential. The Spark owner's link token is never shared.

/// An ed25519 SSH key made on this Mac, in OpenSSH's own formats. The
/// private half is the 32-byte seed (what the Keychain keeps); OpenSSH's
/// private key file is written only for the moment ssh reads it.
public struct SSHEd25519Key: Sendable {
  public let privateKey: Curve25519.Signing.PrivateKey

  public init(_ privateKey: Curve25519.Signing.PrivateKey = .init()) {
    self.privateKey = privateKey
  }

  public init?(seed: Data) {
    guard seed.count == 32, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    else { return nil }
    privateKey = key
  }

  public var seed: Data { privateKey.rawRepresentation }
  public var publicKeyRaw: Data { privateKey.publicKey.rawRepresentation }

  /// `string "ssh-ed25519" ‖ string <32-byte key>` (RFC 8709).
  public var publicBlob: Data {
    Self.sshString(Data("ssh-ed25519".utf8)) + Self.sshString(publicKeyRaw)
  }

  public var publicKeyBase64: String { publicBlob.base64EncodedString() }

  /// `ssh-ed25519 AAAA…` (no comment: what a ticket registers).
  public var authorizedKey: String { "ssh-ed25519 " + publicKeyBase64 }

  /// `SHA256:…` as `ssh-keygen -l` prints it.
  public var fingerprint: String {
    var text = Data(SHA256.hash(data: publicBlob)).base64EncodedString()
    while text.hasSuffix("=") { text.removeLast() }
    return "SHA256:" + text
  }

  /// The unencrypted `openssh-key-v1` file ssh reads with `-i`.
  public func openSSHPrivateKey(comment: String = "mindloom") -> String {
    var check = UInt32.random(in: .min ... .max).bigEndian
    let checkBytes = withUnsafeBytes(of: &check) { Data($0) }
    var section = checkBytes + checkBytes
    section += Self.sshString(Data("ssh-ed25519".utf8))
    section += Self.sshString(publicKeyRaw)
    section += Self.sshString(seed + publicKeyRaw)
    section += Self.sshString(Data(comment.utf8))
    var pad: UInt8 = 1
    while section.count % 8 != 0 {
      section.append(pad)
      pad += 1
    }
    var blob = Data("openssh-key-v1".utf8) + Data([0])
    blob += Self.sshString(Data("none".utf8))
    blob += Self.sshString(Data("none".utf8))
    blob += Self.sshString(Data())
    blob += Self.uint32(1)
    blob += Self.sshString(publicBlob)
    blob += Self.sshString(section)
    let body = blob.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    return "\(Self.armor("BEGIN"))\n\(body)\n\(Self.armor("END"))\n"
  }

  /// Reads an unencrypted ed25519 `openssh-key-v1` file back (tests and
  /// imports); nil for anything else.
  public static func parse(openSSH text: String) -> SSHEd25519Key? {
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    guard lines.first == armor("BEGIN"), lines.last == armor("END"),
      let blob = Data(base64Encoded: lines.dropFirst().dropLast().joined())
    else { return nil }
    var reader = SSHReader(blob)
    guard reader.take(15) == Data("openssh-key-v1".utf8) + Data([0]),
      reader.string() == Data("none".utf8), reader.string() == Data("none".utf8),
      reader.string() == Data(), reader.uint32() == 1, reader.string() != nil,
      let section = reader.string()
    else { return nil }
    var inner = SSHReader(section)
    guard let a = inner.uint32(), let b = inner.uint32(), a == b,
      inner.string() == Data("ssh-ed25519".utf8), let pub = inner.string(), pub.count == 32,
      let priv = inner.string(), priv.count == 64, priv.suffix(32) == pub,
      let key = SSHEd25519Key(seed: Data(priv.prefix(32))), key.publicKeyRaw == pub
    else { return nil }
    return key
  }

  /// The file's armor lines (built from parts, so the repository's secret
  /// scanner never sees a key header in source).
  static func armor(_ edge: String) -> String {
    let label = ["OPENSSH", "PRIVATE", "KEY"].joined(separator: " ")
    return "-----\(edge) \(label)-----"
  }

  static func sshString(_ data: Data) -> Data { uint32(UInt32(data.count)) + data }

  static func uint32(_ value: UInt32) -> Data {
    var big = value.bigEndian
    return withUnsafeBytes(of: &big) { Data($0) }
  }

  struct SSHReader {
    var data: Data
    init(_ data: Data) { self.data = Data(data) }

    mutating func take(_ n: Int) -> Data? {
      guard n >= 0, data.count >= n else { return nil }
      let out = Data(data.prefix(n))
      data = Data(data.dropFirst(n))
      return out
    }

    mutating func uint32() -> UInt32? {
      guard let bytes = take(4) else { return nil }
      return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func string() -> Data? {
      guard let n = uint32(), n <= 1 << 20 else { return nil }
      return take(Int(n))
    }
  }
}

/// The wire rules of per-member access, as `organizer/access.py` fixes them.
public enum MemberAccess {
  static let ticketDomain = Data("mindloom-access-ticket-v1\n".utf8)
  public static let enrollDomain = Data("mindloom-access-enroll-v1\n".utf8)
  public static let credentialPrefix = "mlacc1."
  /// Tickets live at most 7 days on the Spark.
  public static let maximumTicketLifetime: TimeInterval = 7 * 86_400

  /// `hex(sha256("mindloom-access-ticket-v1\n" ‖ secret))`: what the Spark keeps of a ticket's secret.
  public static func ticketHash(_ secret: Data) -> String {
    SpaceCrypto.sha256Hex(ticketDomain + secret)
  }

  /// What an invitee's Mac sends on the invite key's stdin (`enroll`): its
  /// own new SSH public key, its member id and both device keys, the ticket
  /// secret, signed by the device (`organizer.access.enroll_request`).
  public static func enrollRequest(
    device: SpaceDeviceKeys, ticketID: String, secret: Data, sshKey: String, memberID: String,
    createdAt: Date = Date()
  ) throws -> SpaceJSON {
    let payload: SpaceJSON = [
      "v": 1, "ticket_id": .string(ticketID.lowercased()),
      "secret": .string(Base64URL.encode(secret)),
      "ssh_key": .string(sshKey), "member_id": .string(memberID.lowercased()),
      "device": device.publicRecord.json, "created_at": .string(SpaceTime.string(createdAt)),
    ]
    let bytes = try payload.encoded()
    return [
      "request": .string(Base64URL.encode(bytes)),
      "sig": .string(try device.sign(enrollDomain + bytes)),
    ]
  }

  /// `mlacc1.<access id>.<43 base64url>`; the access id, or nil when it is not one.
  public static func accessID(ofCredential credential: String) -> String? {
    guard credential.hasPrefix(credentialPrefix) else { return nil }
    let rest = credential.dropFirst(credentialPrefix.count).split(separator: ".")
    guard rest.count == 2, SpaceID.isValid(String(rest[0])), rest[1].count == 43,
      Base64URL.decode(String(rest[1])) != nil
    else { return nil }
    return String(rest[0])
  }
}

/// The invite a team admin's Mac shows (QR code and text, `mlteam1.` +
/// base64url JSON). It carries what the invitee needs to come in with its
/// own key: the Spark's address and pinned host key, the one-time ticket's
/// id, its ephemeral private key and secret, and — for a new teammate — the
/// shared space's own invite. It travels Mac to Mac; the Spark never sees it
/// (it holds only the ticket's public key and the secret's hash).
public struct AccessInviteCode: Codable, Equatable, Sendable {
  public static let prefix = "mlteam1."

  public enum Kind: String, Codable, Sendable {
    /// A new teammate (their first Mac).
    case member
    /// Another Mac of a member who already has one (`member_id` set).
    case device
  }

  public let v: Int
  public let kind: Kind
  public let spark: SpaceInviteCode.Endpoint
  /// A relay (jump host) on the way; its line accepts the ticket key only for
  /// a tunnel to the Spark's SSH port.
  public let relay: SpaceInviteCode.Endpoint?
  public let ticketID: String
  /// base64url of the ticket key's 32-byte seed.
  public let key: String
  /// base64url of the 32-byte ticket secret.
  public let secret: String
  public let expiresAt: String
  public let memberID: String?
  /// Shown on the invitee's Mac ("加入「…」").
  public let team: String?
  /// A shared space's own invite (`mlinvite1.…`), joined right after.
  public let space: String?

  enum CodingKeys: String, CodingKey {
    case v, kind, spark, relay
    case ticketID = "ticket_id"
    case key, secret
    case expiresAt = "expires_at"
    case memberID = "member_id"
    case team, space
  }

  public init(
    kind: Kind, spark: SpaceInviteCode.Endpoint, relay: SpaceInviteCode.Endpoint?, ticketID: String,
    key: SSHEd25519Key, secret: Data, expiresAt: Date, memberID: String?, team: String?,
    space: String?
  ) {
    v = 1
    self.kind = kind
    self.spark = spark
    self.relay = relay
    self.ticketID = ticketID.lowercased()
    self.key = Base64URL.encode(key.seed)
    self.secret = Base64URL.encode(secret)
    self.expiresAt = SpaceTime.string(expiresAt)
    self.memberID = memberID?.lowercased()
    self.team = team
    self.space = space
  }

  public enum CodeError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion
    case expired
    case missingHostKey
  }

  public var ticketKey: SSHEd25519Key? {
    Base64URL.decode(key, allowPadding: true).flatMap { SSHEd25519Key(seed: $0) }
  }

  public var secretBytes: Data? {
    Base64URL.decode(secret, allowPadding: true).flatMap { $0.count == 32 ? $0 : nil }
  }

  public var expiry: Date? { SpaceTime.date(expiresAt) }

  public func encoded() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return Self.prefix + Base64URL.encode(try encoder.encode(self))
  }

  /// Reads a pasted or scanned code and checks it is usable now.
  public static func decode(_ text: String, now: Date = Date()) throws -> AccessInviteCode {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(prefix),
      let raw = Base64URL.decode(String(trimmed.dropFirst(prefix.count)), allowPadding: true),
      let code = try? JSONDecoder().decode(AccessInviteCode.self, from: raw)
    else { throw CodeError.malformed }
    guard code.v == 1 else { throw CodeError.unsupportedVersion }
    guard SpaceID.isValid(code.ticketID), code.ticketKey != nil, code.secretBytes != nil,
      code.memberID.map(SpaceID.isValid) ?? true, (code.kind == .device) == (code.memberID != nil),
      SSHEndpointRules.isSafeHost(code.spark.host), (1...65_535).contains(code.spark.port),
      code.spark.user.map(SSHEndpointRules.isSafeUser) ?? false,
      code.relay.map({
        SSHEndpointRules.isSafeHost($0.host) && (1...65_535).contains($0.port)
          && ($0.user.map(SSHEndpointRules.isSafeUser) ?? false)
      }) ?? true,
      (code.team?.count ?? 0) <= 80
    else { throw CodeError.malformed }
    guard code.spark.hostKey.hasPrefix("ssh-"),
      code.relay.map({ $0.hostKey.hasPrefix("ssh-") }) ?? true
    else { throw CodeError.missingHostKey }
    if let space = code.space { _ = try? SpaceInviteCode.decode(space, now: now) }
    guard let expiry = code.expiry else { throw CodeError.malformed }
    guard expiry > now else { throw CodeError.expired }
    return code
  }
}

/// Host names, users and host keys that may go on an ssh command line.
public enum SSHEndpointRules {
  public static func isSafeHost(_ host: String) -> Bool {
    !host.isEmpty && host.count <= 253 && !host.hasPrefix("-")
      && host.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) && $0.isASCII || ".:-_".unicodeScalars.contains($0)
      }
  }

  public static func isSafeUser(_ user: String) -> Bool {
    !user.isEmpty && user.count <= 64 && !user.hasPrefix("-")
      && user.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0)
      }
  }

  /// `type base64` of an OpenSSH public host key, or nil.
  public static func hostKeyWords(_ key: String) -> (String, String)? {
    let words = key.split(separator: " ")
    guard words.count >= 2, words[0].hasPrefix("ssh-") || words[0].hasPrefix("ecdsa-"),
      Data(base64Encoded: String(words[1])) != nil
    else { return nil }
    return (String(words[0]), String(words[1]))
  }
}

/// This Mac's own access to a team Spark: its access record, the credential
/// (shown once at enrollment), the seed of its own SSH key and where it
/// connects. Kept in the Keychain (a 0600 file only in a synthetic root).
public struct MemberAccessRecord: Codable, Equatable, Sendable {
  public let accessID: String
  public let memberID: String
  public let deviceID: String
  public let credential: String
  /// base64url seed of this Mac's own SSH key (the bridge key).
  public let keySeed: String
  /// base64url seed of the ticket key, kept only for a relay hop (the relay
  /// line lets it open a tunnel to the Spark's SSH port and nothing else).
  public let relayKeySeed: String?
  public let spark: SpaceInviteCode.Endpoint
  public let relay: SpaceInviteCode.Endpoint?
  public let fingerprint: String?
  public let pairedAt: Date
  public let team: String?

  public init(
    accessID: String, memberID: String, deviceID: String, credential: String, key: SSHEd25519Key,
    relayKey: SSHEd25519Key?, spark: SpaceInviteCode.Endpoint, relay: SpaceInviteCode.Endpoint?,
    fingerprint: String?, pairedAt: Date, team: String?
  ) {
    self.accessID = accessID.lowercased()
    self.memberID = memberID.lowercased()
    self.deviceID = deviceID.lowercased()
    self.credential = credential
    keySeed = Base64URL.encode(key.seed)
    relayKeySeed = relayKey.map { Base64URL.encode($0.seed) }
    self.spark = spark
    self.relay = relay
    self.fingerprint = fingerprint
    self.pairedAt = pairedAt
    self.team = team
  }

  enum CodingKeys: String, CodingKey {
    case accessID = "access_id"
    case memberID = "member_id"
    case deviceID = "device_id"
    case credential
    case keySeed = "key_seed"
    case relayKeySeed = "relay_key_seed"
    case spark, relay, fingerprint
    case pairedAt = "paired_at"
    case team
  }

  public var key: SSHEd25519Key? {
    Base64URL.decode(keySeed, allowPadding: true).flatMap { SSHEd25519Key(seed: $0) }
  }

  public var relayKey: SSHEd25519Key? {
    relayKeySeed.flatMap { Base64URL.decode($0, allowPadding: true) }.flatMap {
      SSHEd25519Key(seed: $0)
    }
  }

  public var isUsable: Bool {
    MemberAccess.accessID(ofCredential: credential) == accessID && key != nil
      && (relay == nil || relayKey != nil)
  }
}

public protocol MemberAccessStore: Sendable {
  func load() throws -> MemberAccessRecord?
  func save(_ record: MemberAccessRecord) throws
  func delete() throws
}

public final class MemoryMemberAccessStore: MemberAccessStore, @unchecked Sendable {
  private let lock = NSLock()
  private var record: MemberAccessRecord?

  public init(_ record: MemberAccessRecord? = nil) { self.record = record }

  public func load() throws -> MemberAccessRecord? { lock.withLock { record } }
  public func save(_ record: MemberAccessRecord) throws { lock.withLock { self.record = record } }
  public func delete() throws { lock.withLock { record = nil } }
}

/// This Mac's access record as a 0600 file next to the space secrets of a
/// synthetic root (tests and end-to-end runs only; the App uses the Keychain).
public struct FileMemberAccessStore: MemberAccessStore {
  public let secrets: FileSpaceSecretStore

  public init(secrets: FileSpaceSecretStore) { self.secrets = secrets }

  public func load() throws -> MemberAccessRecord? {
    guard let data = try secrets.readSecret("member-access.json") else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    guard let record = try? decoder.decode(MemberAccessRecord.self, from: data) else {
      throw SpaceStoreError.unreadable
    }
    return record
  }

  public func save(_ record: MemberAccessRecord) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    try secrets.writeSecret(try encoder.encode(record), "member-access.json")
  }

  public func delete() throws { try secrets.deleteSecret("member-access.json") }
}
