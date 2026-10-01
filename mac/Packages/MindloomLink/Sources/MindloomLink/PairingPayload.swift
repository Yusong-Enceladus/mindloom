import CryptoKit
import Foundation

/// One SSH hop: the Spark itself, or the relay in front of it.
public struct PairingEndpoint: Codable, Equatable, Hashable, Sendable {
  public let host: String
  public let port: Int
  public let user: String
  public let hostKey: SSHHostKey

  enum CodingKeys: String, CodingKey {
    case host, port, user
    case hostKey = "host_key"
  }

  public init(host: String, port: Int = 22, user: String, hostKey: SSHHostKey) throws {
    self.host = host
    self.port = port
    self.user = user
    self.hostKey = hostKey
    try validate()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    host = try container.decode(String.self, forKey: .host)
    port = try container.decode(Int.self, forKey: .port)
    user = try container.decode(String.self, forKey: .user)
    let keyText = try container.decode(String.self, forKey: .hostKey)
    guard let key = SSHHostKey(openSSH: keyText) else {
      throw PairingPayload.PairingError.invalidHostKey
    }
    hostKey = key
    try validate()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(host, forKey: .host)
    try container.encode(port, forKey: .port)
    try container.encode(user, forKey: .user)
    try container.encode(hostKey.openSSH, forKey: .hostKey)
  }

  func validate() throws {
    guard Self.isValidHost(host) else { throw PairingPayload.PairingError.invalidHost }
    guard (1...65_535).contains(port) else { throw PairingPayload.PairingError.invalidPort }
    guard Self.isValidUser(user) else { throw PairingPayload.PairingError.invalidUser }
  }

  /// The Mac link configuration's host rule (ASCII letters, digits, `._-`, at
  /// most 253 characters, no leading `-`), plus `:` for an IPv6 literal.
  public static func isValidHost(_ host: String) -> Bool {
    !host.isEmpty && host.utf8.count <= 253 && host.first != "-"
      && host.unicodeScalars.allSatisfy {
        ($0.isASCII && CharacterSet.alphanumerics.contains($0))
          || "._-:".unicodeScalars.contains($0)
      }
  }

  /// A POSIX login name: ASCII letters, digits, `._-`, 1–32, no leading `-`.
  public static func isValidUser(_ user: String) -> Bool {
    !user.isEmpty && user.utf8.count <= 32 && user.first != "-"
      && user.unicodeScalars.allSatisfy {
        ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0)
      }
  }
}

/// `mlpair1.` + base64url(JSON): what the Mac shows as a QR code and as the
/// "复制配对码" text (PHONE-CONTRACT §4).
///
/// ```
/// {"v":1,"label":"<Mac 名称>","spark":{"host","port","user","host_key"},
///  "relay":null | {"host","port","user","host_key"},
///  "phone_key":"<ed25519 private key raw 32 bytes, base64>","phone_key_id":"<id>",
///  "mac_seal_pub":"<x25519 raw 32 bytes, base64>","gate":"zhiji-inbox"}
/// ```
///
/// It carries the phone's SSH private key, so its text form never appears in
/// `description`, `debugDescription` or `dump`. On the phone the key goes to
/// the Keychain and the rest (`record`) to the App Group.
public struct PairingPayload: Codable, Equatable, Sendable {
  public static let prefix = "mlpair1."
  public static let currentVersion = 1
  /// The pairing text is a QR code, so it stays small; this bounds decoding.
  public static let maximumTextBytes = 8 * 1024

  public let v: Int
  public let label: String
  public let spark: PairingEndpoint
  public let relay: PairingEndpoint?
  /// The raw 32-byte ed25519 private key (seed) of the phone. Secret.
  public let phoneKey: Data
  public let phoneKeyID: String
  /// The Mac's X25519 seal public key, raw 32 bytes.
  public let macSealPublicKey: Data
  public let gate: String

  public enum PairingError: Error, Equatable, Sendable {
    case notAPairingCode
    case malformed
    case unsupportedVersion(Int)
    case invalidLabel
    case invalidHost
    case invalidPort
    case invalidUser
    /// Missing, unsupported or malformed host key: pairing is refused, never
    /// completed by trusting whatever key the server shows first.
    case invalidHostKey
    case invalidPhoneKey
    case invalidPhoneKeyID
    case invalidSealKey
    case invalidGate
  }

  enum CodingKeys: String, CodingKey {
    case v, label, spark, relay, gate
    case phoneKey = "phone_key"
    case phoneKeyID = "phone_key_id"
    case macSealPublicKey = "mac_seal_pub"
  }

  public init(
    label: String,
    spark: PairingEndpoint,
    relay: PairingEndpoint?,
    phoneKey: Data,
    phoneKeyID: String,
    macSealPublicKey: Data,
    gate: String = "zhiji-inbox"
  ) throws {
    self.v = Self.currentVersion
    self.label = label
    self.spark = spark
    self.relay = relay
    self.phoneKey = phoneKey
    self.phoneKeyID = phoneKeyID
    self.macSealPublicKey = macSealPublicKey
    self.gate = gate
    try validate()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    v = try container.decode(Int.self, forKey: .v)
    guard v == Self.currentVersion else { throw PairingError.unsupportedVersion(v) }
    label = try container.decode(String.self, forKey: .label)
    spark = try container.decode(PairingEndpoint.self, forKey: .spark)
    relay = try container.decodeIfPresent(PairingEndpoint.self, forKey: .relay)
    guard let key = Base64URL.decodeStandard(try container.decode(String.self, forKey: .phoneKey))
    else { throw PairingError.invalidPhoneKey }
    phoneKey = key
    phoneKeyID = try container.decode(String.self, forKey: .phoneKeyID)
    guard
      let seal = Base64URL.decodeStandard(
        try container.decode(String.self, forKey: .macSealPublicKey))
    else { throw PairingError.invalidSealKey }
    macSealPublicKey = seal
    gate = try container.decode(String.self, forKey: .gate)
    try validate()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(v, forKey: .v)
    try container.encode(label, forKey: .label)
    try container.encode(spark, forKey: .spark)
    // `"relay": null` is written out, as in the contract.
    try container.encode(relay, forKey: .relay)
    try container.encode(phoneKey.base64EncodedString(), forKey: .phoneKey)
    try container.encode(phoneKeyID, forKey: .phoneKeyID)
    try container.encode(macSealPublicKey.base64EncodedString(), forKey: .macSealPublicKey)
    try container.encode(gate, forKey: .gate)
  }

  // MARK: - Text form

  /// `mlpair1.` + unpadded base64url of the sorted-key JSON.
  public func encodedText() throws -> String {
    try validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return Self.prefix + Base64URL.encode(try encoder.encode(self))
  }

  /// Accepts the pairing text as scanned or pasted: surrounding whitespace is
  /// ignored and base64url padding is tolerated. Everything else is strict.
  public static func decode(text: String) throws -> PairingPayload {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix(prefix) else { throw PairingError.notAPairingCode }
    guard trimmed.utf8.count <= maximumTextBytes,
      let json = Base64URL.decode(String(trimmed.dropFirst(prefix.count)), allowPadding: true)
    else { throw PairingError.malformed }
    do {
      return try JSONDecoder().decode(PairingPayload.self, from: json)
    } catch let error as PairingError {
      throw error
    } catch {
      throw PairingError.malformed
    }
  }

  // MARK: - Derived

  /// The phone's SSH signing key.
  public var phoneSigningKey: Curve25519.Signing.PrivateKey {
    // Validated in `validate()`: 32 bytes always form a valid seed.
    try! Curve25519.Signing.PrivateKey(rawRepresentation: phoneKey)
  }

  /// The phone's public key in OpenSSH form, with the `mindloom-phone:<id>`
  /// marker the Spark and relay use in `authorized_keys`.
  public var phoneAuthorizedKey: String {
    Self.openSSHPublicKey(phoneSigningKey.publicKey, comment: "mindloom-phone:\(phoneKeyID)")
  }

  public var macSealKey: Curve25519.KeyAgreement.PublicKey {
    try! Curve25519.KeyAgreement.PublicKey(rawRepresentation: macSealPublicKey)
  }

  public var sealKeyID: String { MindloomSeal.keyID(for: macSealKey) }

  /// Everything but the private key, for the App Group.
  public var record: PairingRecord {
    PairingRecord(
      label: label, spark: spark, relay: relay, phoneKeyID: phoneKeyID,
      macSealPublicKey: macSealPublicKey, gate: gate)
  }

  public static func openSSHPublicKey(
    _ key: Curve25519.Signing.PublicKey, comment: String? = nil
  ) -> String {
    var blob = Data()
    func appendString(_ bytes: Data) {
      var length = UInt32(bytes.count).bigEndian
      blob.append(Data(bytes: &length, count: 4))
      blob.append(bytes)
    }
    appendString(Data("ssh-ed25519".utf8))
    appendString(key.rawRepresentation)
    let base = "ssh-ed25519 " + blob.base64EncodedString()
    return comment.map { base + " " + $0 } ?? base
  }

  // MARK: - Validation

  public func validate() throws {
    guard v == Self.currentVersion else { throw PairingError.unsupportedVersion(v) }
    guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.count <= 64,
      !label.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    else { throw PairingError.invalidLabel }
    try spark.validate()
    try relay?.validate()
    guard phoneKey.count == 32, phoneKey.contains(where: { $0 != 0 }) else {
      throw PairingError.invalidPhoneKey
    }
    guard Self.isValidKeyID(phoneKeyID) else { throw PairingError.invalidPhoneKeyID }
    guard MindloomSeal.isUsableRecipientKey(macSealPublicKey) else {
      throw PairingError.invalidSealKey
    }
    guard Self.isValidGate(gate) else { throw PairingError.invalidGate }
  }

  /// `[A-Za-z0-9._-]`, 1–64, starting with a letter or digit: safe inside an
  /// `authorized_keys` comment and as one shell word.
  public static func isValidKeyID(_ id: String) -> Bool {
    guard let first = id.unicodeScalars.first, id.utf8.count <= 64,
      first.isASCII, CharacterSet.alphanumerics.contains(first)
    else { return false }
    return id.unicodeScalars.allSatisfy {
      ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0)
    }
  }

  /// The gate command: one safe word (`[A-Za-z0-9._/~-]`, no `..`, no leading
  /// `-`), the same rule as remote paths in the Mac link configuration.
  public static func isValidGate(_ gate: String) -> Bool {
    !gate.isEmpty && gate.utf8.count <= 512 && gate.first != "-" && !gate.contains("..")
      && gate.unicodeScalars.allSatisfy {
        ($0.isASCII && CharacterSet.alphanumerics.contains($0))
          || "._/~-".unicodeScalars.contains($0)
      }
  }
}

extension PairingPayload: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var description: String {
    "PairingPayload(label: \(label), spark: \(spark.user)@\(spark.host):\(spark.port), "
      + "relay: \(relay.map { "\($0.user)@\($0.host):\($0.port)" } ?? "none"), "
      + "phone_key_id: \(phoneKeyID), phone_key: <redacted>)"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "label": label, "spark": spark, "relay": relay as Any, "phoneKeyID": phoneKeyID,
        "phoneKey": "<redacted>", "gate": gate,
      ],
      displayStyle: .struct)
  }
}

/// The pairing without the private key: safe to keep in the App Group
/// container where the share and keyboard extensions can read it.
public struct PairingRecord: Codable, Equatable, Sendable {
  public let label: String
  public let spark: PairingEndpoint
  public let relay: PairingEndpoint?
  public let phoneKeyID: String
  public let macSealPublicKey: Data
  public let gate: String

  enum CodingKeys: String, CodingKey {
    case label, spark, relay, gate
    case phoneKeyID = "phone_key_id"
    case macSealPublicKey = "mac_seal_pub"
  }

  public var macSealKey: Curve25519.KeyAgreement.PublicKey? {
    try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: macSealPublicKey)
  }

  public var sealKeyID: String? { macSealKey.map(MindloomSeal.keyID(for:)) }
}
