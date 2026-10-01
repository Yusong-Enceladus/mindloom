import CryptoKit
import Foundation
import MindloomLink

/// One member device: its id, its Ed25519 signing key (new with spaces) and
/// its X25519 seal key (the one from the phone work). A member is identified
/// by the signatures of its devices; the Spark can verify an op but never
/// forge one.
public struct SpaceDeviceKeys: Sendable {
  public let deviceID: String
  public let signingKey: Curve25519.Signing.PrivateKey
  public let sealKey: Curve25519.KeyAgreement.PrivateKey

  public init(
    deviceID: String, signingKey: Curve25519.Signing.PrivateKey,
    sealKey: Curve25519.KeyAgreement.PrivateKey
  ) {
    self.deviceID = deviceID.lowercased()
    self.signingKey = signingKey
    self.sealKey = sealKey
  }

  /// A new device id and signing key next to an existing seal key.
  public static func generate(sealKey: Curve25519.KeyAgreement.PrivateKey = .init())
    -> SpaceDeviceKeys
  {
    SpaceDeviceKeys(deviceID: SpaceID.new(), signingKey: .init(), sealKey: sealKey)
  }

  public var signPublicKey: Data { signingKey.publicKey.rawRepresentation }
  public var sealPublicKey: Data { sealKey.publicKey.rawRepresentation }

  /// `{"device_id","sign_pub","seal_pub"}` as the Spark lists devices.
  public var publicRecord: SpaceDevicePublic {
    SpaceDevicePublic(
      deviceID: deviceID, signPub: Base64URL.encode(signPublicKey),
      sealPub: Base64URL.encode(sealPublicKey))
  }

  /// A short fingerprint of the signing key, shown on both screens when a
  /// join is approved ("A1B2-C3D4-E5F6").
  public var fingerprint: String { SpaceDevicePublic.fingerprint(of: signPublicKey) }

  public func sign(_ message: Data) throws -> String {
    Base64URL.encode(try signingKey.signature(for: message))
  }

  // MARK: - Ops

  /// A signed op on the wire. The op JSON commits to each detached field by
  /// its SHA-256, so the Spark can delete them (crypto-shredding) and the
  /// signature still verifies.
  public func op(
    space spaceID: String, member memberID: String, type: String, body: SpaceJSON,
    epoch: Int? = nil, enc: String? = nil, wrappedDK: String? = nil,
    opID: String = SpaceID.new(), createdAt: Date = Date()
  ) throws -> SpaceWireOp {
    try envelope(
      idKey: "space_id", id: spaceID, member: memberID, type: type, body: body, epoch: epoch,
      enc: enc, wrappedDK: wrappedDK, opID: opID, createdAt: createdAt)
  }

  /// An organization op: the same envelope with `org_id` in place of `space_id`.
  public func orgOp(
    org orgID: String, member memberID: String, type: String, body: SpaceJSON,
    opID: String = SpaceID.new(), createdAt: Date = Date()
  ) throws -> SpaceWireOp {
    try envelope(
      idKey: "org_id", id: orgID, member: memberID, type: type, body: body, epoch: nil, enc: nil,
      wrappedDK: nil, opID: opID, createdAt: createdAt)
  }

  private func envelope(
    idKey: String, id: String, member: String, type: String, body: SpaceJSON, epoch: Int?,
    enc: String?, wrappedDK: String?, opID: String, createdAt: Date
  ) throws -> SpaceWireOp {
    var payload: [String: SpaceJSON] = [
      "v": 1, idKey: .string(id.lowercased()), "op_id": .string(opID.lowercased()),
      "type": .string(type), "member_id": .string(member.lowercased()),
      "device_id": .string(deviceID), "created_at": .string(SpaceTime.string(createdAt)),
      "body": body,
    ]
    if let epoch { payload["epoch"] = SpaceJSON(epoch) }
    if let enc { payload["enc_sha256"] = .string(SpaceCrypto.detachedHash(enc)) }
    if let wrappedDK { payload["wrapped_dk_sha256"] = .string(SpaceCrypto.detachedHash(wrappedDK)) }
    let bytes = try SpaceJSON.object(payload).encoded()
    return SpaceWireOp(
      opID: opID.lowercased(), type: type, opJSON: bytes,
      signature: try sign(SpaceSignatures.opDomain + bytes), enc: enc, wrappedDK: wrappedDK)
  }

  // MARK: - Join

  /// A signed join request. The invite secret never leaves this Mac: beside
  /// the request go the gate token (the Spark checks it against the invite's
  /// stored hash and uses the invite up) and an HMAC of the request bytes
  /// that only an invite holder can make, which the inviting admin's Mac
  /// checks before it approves. The display name is sealed to that Mac.
  public func joinRequest(
    space spaceID: String, inviteID: String, secret: Data, member memberID: String,
    requestID: String = SpaceID.new(), profile: String?, createdAt: Date = Date()
  ) throws -> SpaceJSON {
    let payload: SpaceJSON = [
      "v": 1, "space_id": .string(spaceID.lowercased()),
      "invite_id": .string(inviteID.lowercased()), "request_id": .string(requestID.lowercased()),
      "member_id": .string(memberID.lowercased()), "device": publicRecord.json,
      "created_at": .string(SpaceTime.string(createdAt)),
    ]
    let bytes = try payload.encoded()
    var wire: [String: SpaceJSON] = [
      "request": .string(Base64URL.encode(bytes)),
      "sig": .string(try sign(SpaceSignatures.joinDomain + bytes)),
      "invite_gate": .string(Base64URL.encode(SpaceCrypto.inviteGate(secret))),
      "invite_binding": .string(SpaceCrypto.inviteBinding(secret: secret, request: bytes)),
    ]
    if let profile { wire["profile"] = .string(profile) }
    return .object(wire)
  }

  // MARK: - Requests

  /// The four `X-Mindloom-*` headers of one signed request. `target` is the
  /// raw path plus `?` and the raw query exactly as sent.
  public func requestHeaders(
    method: String, target: String, body: Data, date: Date = Date(), nonce: String? = nil
  ) throws -> [String: String] {
    let seconds = String(Int64(date.timeIntervalSince1970.rounded(.down)))
    let nonce = nonce ?? Base64URL.encode(SpaceCrypto.randomKey().prefix(18))
    let message = SpaceSignatures.requestMessage(
      method: method, target: target, date: seconds, nonce: nonce, body: body)
    return [
      "X-Mindloom-Device": deviceID, "X-Mindloom-Date": seconds, "X-Mindloom-Nonce": nonce,
      "X-Mindloom-Signature": try sign(message),
    ]
  }
}

/// A device as the Spark lists it.
public struct SpaceDevicePublic: Codable, Equatable, Hashable, Sendable {
  public let deviceID: String
  public let signPub: String
  public let sealPub: String
  public var status: String?

  public init(deviceID: String, signPub: String, sealPub: String, status: String? = nil) {
    self.deviceID = deviceID
    self.signPub = signPub
    self.sealPub = sealPub
    self.status = status
  }

  enum CodingKeys: String, CodingKey {
    case deviceID = "device_id"
    case signPub = "sign_pub"
    case sealPub = "seal_pub"
    case status
  }

  public var json: SpaceJSON {
    ["device_id": .string(deviceID), "sign_pub": .string(signPub), "seal_pub": .string(sealPub)]
  }

  public var signKey: Data? {
    Base64URL.decode(signPub, allowPadding: true).flatMap { $0.count == 32 ? $0 : nil }
  }

  public var sealKey: Data? {
    Base64URL.decode(sealPub, allowPadding: true).flatMap { $0.count == 32 ? $0 : nil }
  }

  public var isActive: Bool { status == nil || status == "active" }

  public var fingerprint: String { signKey.map(Self.fingerprint(of:)) ?? "????-????-????" }

  /// The first 6 bytes of SHA-256 of the signing key, as three groups.
  public static func fingerprint(of signKey: Data) -> String {
    let digest = SpaceCrypto.sha256Hex(Data("mindloom-space-device-fp-v1".utf8) + signKey)
      .uppercased()
    let chars = Array(digest.prefix(12))
    return [0, 4, 8].map { String(chars[$0..<($0 + 4)]) }.joined(separator: "-")
  }
}

/// One signed op ready to post: `{"op": b64u(JSON), "sig", "enc"?, "wrapped_dk"?}`.
public struct SpaceWireOp: Equatable, Sendable {
  public let opID: String
  public let type: String
  public let opJSON: Data
  public let signature: String
  public let enc: String?
  public let wrappedDK: String?

  public var json: SpaceJSON {
    var wire: [String: SpaceJSON] = [
      "op": .string(Base64URL.encode(opJSON)), "sig": .string(signature),
    ]
    if let enc { wire["enc"] = .string(enc) }
    if let wrappedDK { wire["wrapped_dk"] = .string(wrappedDK) }
    return .object(wire)
  }
}

public enum SpaceSignatures {
  public static let opDomain = Data("mindloom-space-op-v1\n".utf8)
  public static let joinDomain = Data("mindloom-space-join-v1\n".utf8)
  static let requestDomain = "mindloom-space-req-v1"

  public static func requestMessage(
    method: String, target: String, date: String, nonce: String, body: Data
  ) -> Data {
    let digest = SpaceCrypto.sha256Hex(body)
    return Data(
      [requestDomain, method.uppercased(), target, date, nonce, digest].joined(separator: "\n")
        .utf8)
  }

  /// Ed25519 verification of a base64url signature with a raw public key.
  public static func verify(signPub: Data, message: Data, signature: String) -> Bool {
    guard let raw = Base64URL.decode(signature, allowPadding: true), raw.count == 64,
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signPub)
    else { return false }
    return key.isValidSignature(raw, for: message)
  }

  public static func verifyOp(_ opJSON: Data, signature: String, signPub: Data) -> Bool {
    verify(signPub: signPub, message: opDomain + opJSON, signature: signature)
  }
}

/// Ids are lowercase UUID strings everywhere in a space's log.
public enum SpaceID {
  public static func new() -> String { UUID().uuidString.lowercased() }

  public static func isValid(_ value: String) -> Bool {
    value.count == 36 && value == value.lowercased() && UUID(uuidString: value) != nil
  }

  /// A stable id for a part of a recording: the same parent and range always
  /// give the same id (a share of the same segment again is the same item).
  public static func segment(parent: String, startMS: Int, endMS: Int) -> String {
    let digest = SpaceCrypto.sha256Hex(
      Data("mindloom-space-segment-v1|\(parent.lowercased())|\(startMS)|\(endMS)".utf8))
    var chars = Array(digest.prefix(32))
    // A version-4-shaped UUID (the variant bits set), so every UUID parser takes it.
    chars[12] = "4"
    let variant = Int(String(chars[16]), radix: 16) ?? 0
    chars[16] = Character(String((variant & 0x3) | 0x8, radix: 16))
    let s = String(chars)
    return [
      s.prefix(8), s.dropFirst(8).prefix(4), s.dropFirst(12).prefix(4), s.dropFirst(16).prefix(4),
      s.dropFirst(20),
    ].joined(separator: "-")
  }
}

/// ISO-8601 with the local offset, as every time in a space is written.
public enum SpaceTime {
  public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = timeZone
    return formatter.string(from: date)
  }

  public static func date(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}
