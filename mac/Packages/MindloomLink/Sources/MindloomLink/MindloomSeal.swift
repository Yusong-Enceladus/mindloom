import CryptoKit
import Foundation

/// `mlseal1`: an inbox entry sealed on the phone to the Mac's X25519 public
/// key (PHONE-CONTRACT §3). The Spark only relays the wire string; only the
/// Mac holding the private key can open it.
///
/// ```
/// eph = X25519 ephemeral key pair
/// shared = X25519(eph_priv, mac_pub)
/// key = HKDF-SHA256(shared, salt: eph_pub ‖ mac_pub, info: "mindloom-inbox-seal-v1", 32)
/// box = ChaChaPoly(plaintext, key, nonce: random 12, aad: "mindloom-inbox-v1|" + entry_id)
/// wire = "mlseal1." + base64url_nopad(eph_pub ‖ nonce ‖ ciphertext ‖ tag)
/// ```
public enum MindloomSeal {
  public static let wirePrefix = "mlseal1."
  public static let hkdfInfo = "mindloom-inbox-seal-v1"
  public static let aadPrefix = "mindloom-inbox-v1|"

  static let publicKeyBytes = 32
  static let nonceBytes = 12
  static let tagBytes = 16
  /// eph_pub ‖ nonce ‖ tag, the fixed overhead around the ciphertext.
  public static let overheadBytes = publicKeyBytes + nonceBytes + tagBytes

  /// "36 MB sealed" (§3): the sealed binary `eph_pub ‖ nonce ‖ ciphertext ‖
  /// tag`, before base64url. This fits a 25 MiB document (base64 inside the
  /// JSON plaintext is about 34.95 MB).
  public static let maximumSealedBytes = 36_000_000
  /// The longest wire string a valid seal can produce (prefix + base64url of
  /// `maximumSealedBytes`), which is what the Spark must accept on stdin.
  public static let maximumWireBytes =
    wirePrefix.utf8.count + (maximumSealedBytes * 4 + 2) / 3

  public enum SealError: Error, Equatable, Sendable {
    /// The entry id is not a lowercase UUID string.
    case invalidEntryID
    /// The recipient public key is a low-order point (no shared secret).
    case invalidRecipientKey
    /// The sealed bytes would exceed `maximumSealedBytes`.
    case tooLarge
    /// Not an `mlseal1.` string, not canonical base64url, or too short.
    case malformedWire
    /// Authentication failed: wrong key, wrong entry id, or changed bytes.
    case openFailed
    /// Test injection only: the nonce is not 12 bytes.
    case invalidNonce
  }

  /// Seals `plaintext` for the Mac. Fresh ephemeral key and nonce every call.
  public static func seal(
    _ plaintext: Data,
    entryID: String,
    to recipient: Curve25519.KeyAgreement.PublicKey
  ) throws -> String {
    let nonce = Data(ChaChaPoly.Nonce())
    return try sealWith(
      plaintext, entryID: entryID, recipient: recipient,
      ephemeral: Curve25519.KeyAgreement.PrivateKey(), nonce: nonce)
  }

  /// Test-only injection of the ephemeral key and nonce, for the fixed
  /// vectors in `seal_vectors.json`. Never use this outside tests: reusing an
  /// ephemeral key and nonce breaks confidentiality.
  @_spi(MindloomLinkTesting)
  public static func sealForTesting(
    _ plaintext: Data,
    entryID: String,
    to recipient: Curve25519.KeyAgreement.PublicKey,
    ephemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey,
    nonce: Data
  ) throws -> String {
    try sealWith(
      plaintext, entryID: entryID, recipient: recipient,
      ephemeral: ephemeralPrivateKey, nonce: nonce)
  }

  /// Opens a wire string with the Mac's private key. `entryID` is the id the
  /// entry arrived under (the Spark's `inbox_id`); a different id fails.
  public static func open(
    _ wire: String,
    entryID: String,
    with recipient: Curve25519.KeyAgreement.PrivateKey
  ) throws -> Data {
    guard EntryID.isValid(entryID) else { throw SealError.invalidEntryID }
    guard wire.utf8.count <= maximumWireBytes else { throw SealError.tooLarge }
    guard wire.hasPrefix(wirePrefix),
      let sealed = Base64URL.decode(String(wire.dropFirst(wirePrefix.count))),
      sealed.count >= overheadBytes
    else { throw SealError.malformedWire }
    guard sealed.count <= maximumSealedBytes else { throw SealError.tooLarge }

    let ephemeralBytes = sealed.prefix(publicKeyBytes)
    guard let ephemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralBytes)
    else { throw SealError.malformedWire }
    guard
      let key = try? derivedKey(
        privateKey: recipient, peer: ephemeral,
        ephemeralPublic: Data(ephemeralBytes),
        recipientPublic: recipient.publicKey.rawRepresentation)
    else { throw SealError.openFailed }
    guard
      let box = try? ChaChaPoly.SealedBox(combined: sealed.dropFirst(publicKeyBytes)),
      let plaintext = try? ChaChaPoly.open(box, using: key, authenticating: aad(for: entryID))
    else { throw SealError.openFailed }
    return plaintext
  }

  /// A short, stable fingerprint of a Mac seal public key: the first 16 hex
  /// characters of SHA-256 over the raw key. Lets the phone tell which pairing
  /// an outbox entry was sealed for, without storing the key again.
  public static func keyID(for publicKey: Curve25519.KeyAgreement.PublicKey) -> String {
    let digest = SHA256.hash(data: publicKey.rawRepresentation)
    return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
  }

  /// False for the low-order points of Curve25519, which give an all-zero
  /// shared secret with every private key and so would seal to no one.
  public static func isUsableRecipientKey(_ raw: Data) -> Bool {
    guard raw.count == publicKeyBytes,
      let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw),
      let secret = try? Curve25519.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(with: key)
    else { return false }
    return secret.withUnsafeBytes { bytes in bytes.contains(where: { $0 != 0 }) }
  }

  // MARK: - Internals

  static func aad(for entryID: String) -> Data { Data((aadPrefix + entryID).utf8) }

  private static func sealWith(
    _ plaintext: Data,
    entryID: String,
    recipient: Curve25519.KeyAgreement.PublicKey,
    ephemeral: Curve25519.KeyAgreement.PrivateKey,
    nonce: Data
  ) throws -> String {
    guard EntryID.isValid(entryID) else { throw SealError.invalidEntryID }
    guard nonce.count == nonceBytes, let chachaNonce = try? ChaChaPoly.Nonce(data: nonce) else {
      throw SealError.invalidNonce
    }
    guard plaintext.count <= maximumSealedBytes - overheadBytes else { throw SealError.tooLarge }
    let ephemeralPublic = ephemeral.publicKey.rawRepresentation
    let key = try derivedKey(
      privateKey: ephemeral, peer: recipient,
      ephemeralPublic: ephemeralPublic,
      recipientPublic: recipient.rawRepresentation)
    let box = try ChaChaPoly.seal(
      plaintext, using: key, nonce: chachaNonce, authenticating: aad(for: entryID))
    var sealed = Data(capacity: overheadBytes + plaintext.count)
    sealed.append(ephemeralPublic)
    sealed.append(box.combined)
    return wirePrefix + Base64URL.encode(sealed)
  }

  private static func derivedKey(
    privateKey: Curve25519.KeyAgreement.PrivateKey,
    peer: Curve25519.KeyAgreement.PublicKey,
    ephemeralPublic: Data,
    recipientPublic: Data
  ) throws -> SymmetricKey {
    let shared: SharedSecret
    do {
      shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
    } catch {
      throw SealError.invalidRecipientKey
    }
    let isZero = shared.withUnsafeBytes { bytes in bytes.allSatisfy { $0 == 0 } }
    guard !isZero else { throw SealError.invalidRecipientKey }
    return shared.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: ephemeralPublic + recipientPublic,
      sharedInfo: Data(hkdfInfo.utf8),
      outputByteCount: 32)
  }
}
