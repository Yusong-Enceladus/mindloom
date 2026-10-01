import CryptoKit
import Foundation
import MindloomLink

/// The member side of shared-space cryptography (SPACES-CONTRACT §3, the
/// wire formats fixed in the Spark's `space_member.py`). Every key and every
/// plaintext stays on member devices: the Spark stores only the strings and
/// bytes made here and cannot open any of them.
///
/// AEAD is ChaCha20-Poly1305 with a 12-byte random nonce; HKDF is
/// HKDF-SHA256 with an empty salt unless one is given. AADs bind every
/// ciphertext to its space, epoch, device, item, revision, op or blob, so a
/// ciphertext moved anywhere else does not open.
public enum SpaceCrypto {
  public static let wrapPrefix = "mlwrap1."
  public static let epochLinkPrefix = "mlelink1."
  public static let itemKeyPrefix = "mlikey1."
  public static let encPrefix = "mlenc1."
  public static let profilePrefix = "mlpro1."
  public static let blobMagic = Data("MLB1".utf8)

  static let wrapInfo = "mindloom-space-wrap-v1"
  static let epochLinkInfo = "mindloom-space-epoch-link-v1"
  static let itemKeyInfo = "mindloom-space-item-key-v1"
  static let itemEncInfo = "mindloom-space-item-enc-v1"
  static let opEncInfo = "mindloom-space-op-enc-v1"
  static let blobInfo = "mindloom-space-blob-v1"
  static let profileInfo = "mindloom-space-join-profile-v1"

  public static let keyBytes = 32
  static let nonceBytes = 12
  static let tagBytes = 16
  /// One original's ceiling (the Spark refuses larger blobs).
  public static let maximumBlobBytes = 36_000_000
  /// One encrypted op field's ceiling (`enc`).
  public static let maximumEncBytes = 256 * 1024

  public enum CryptoError: Error, Equatable, Sendable {
    /// Not the expected prefix, not base64url, or the wrong length.
    case malformed
    /// Authentication failed: wrong key, wrong AAD (moved ciphertext), or
    /// changed bytes.
    case openFailed
    /// A key that is not 32 bytes, or a low-order public key.
    case invalidKey
    case tooLarge
  }

  // MARK: - Derived keys

  /// 32 bytes from the system CSPRNG: a space key, an item data key, an
  /// invite secret.
  public static func randomKey() -> Data {
    SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
  }

  /// `HMAC-SHA256(K_e, "mindloom-space-store-v1")`: the space organizer
  /// store's SQLCipher key for epoch `e`, lent to the Spark in a lease.
  public static func storeKey(spaceKey: Data) -> Data {
    hmac(spaceKey, "mindloom-space-store-v1")
  }

  /// `HMAC-SHA256(K_1, "mindloom-space-mask-v1")`, always from the first
  /// epoch's key, so placeholders do not change at a rotation.
  public static func maskKey(firstEpochKey: Data) -> Data {
    hmac(firstEpochKey, "mindloom-space-mask-v1")
  }

  /// The id of a store key (the Spark's `store.keyid`).
  public static func storeKeyID(_ storeKey: Data) -> String {
    String(sha256Hex(Data("mindloom-space-store-id-v1".utf8) + storeKey).prefix(16))
  }

  /// The id of a mask key (the Spark's `store.maskid`).
  public static func maskKeyID(_ maskKey: Data) -> String {
    String(sha256Hex(Data("mindloom-space-mask-id-v1".utf8) + maskKey).prefix(16))
  }

  /// The token a joiner shows the Spark in place of the invite secret: the
  /// secret itself stays between the two Macs (review finding V7-S9).
  public static func inviteGate(_ secret: Data) -> Data {
    Data(SHA256.hash(data: Data("mindloom-space-invite-gate-v1".utf8) + secret))
  }

  /// What the Spark keeps of an invite (`invite.create`'s `secret_hash`): a
  /// hash of the gate token, so the Spark can check and use up an invite
  /// without ever holding the secret.
  public static func inviteSecretHash(_ secret: Data) -> String {
    sha256Hex(Data("mindloom-space-invite-v1".utf8) + inviteGate(secret))
  }

  /// HMAC-SHA256 of the exact signed join request bytes under a key derived
  /// from the invite secret. Only an invite holder can make it; the Spark
  /// stores it and the inviting admin's Mac checks it before 同意, so whoever
  /// runs the Spark cannot bind a device of its own to the invite.
  public static func inviteBinding(secret: Data, request: Data) -> String {
    let key = SymmetricKey(data: hmac(secret, "mindloom-space-join-bind-key-v1"))
    let mac = HMAC<SHA256>.authenticationCode(
      for: Data("mindloom-space-join-bind-v2\n".utf8) + request, using: key)
    return hex(Data(mac))
  }

  /// What a signed op commits to for a detached field (`enc`, `wrapped_dk`).
  public static func detachedHash(_ value: String) -> String {
    sha256Hex(Data(value.utf8))
  }

  // MARK: - Space-key wraps (sealed to one device)

  public static func wrapAAD(spaceID: String, epoch: Int, deviceID: String) -> Data {
    Data("\(wrapInfo)|\(spaceID)|\(epoch)|\(deviceID)".utf8)
  }

  /// `K_e` sealed to one member device's X25519 seal key.
  public static func wrapSpaceKey(
    _ spaceKey: Data, to sealPublicKey: Data, spaceID: String, epoch: Int, deviceID: String,
    ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(), nonce: Data? = nil
  ) throws -> String {
    guard spaceKey.count == keyBytes else { throw CryptoError.invalidKey }
    let raw = try sealToDevice(
      spaceKey, recipient: sealPublicKey, info: wrapInfo,
      aad: wrapAAD(spaceID: spaceID, epoch: epoch, deviceID: deviceID), ephemeral: ephemeral,
      nonce: nonce)
    return wrapPrefix + Base64URL.encode(raw)
  }

  public static func unwrapSpaceKey(
    _ wrap: String, sealKey: Curve25519.KeyAgreement.PrivateKey, spaceID: String, epoch: Int,
    deviceID: String
  ) throws -> Data {
    let raw = try payload(wrap, prefix: wrapPrefix, exact: 32 + nonceBytes + keyBytes + tagBytes)
    let key = try openFromDevice(
      raw, sealKey: sealKey, info: wrapInfo,
      aad: wrapAAD(spaceID: spaceID, epoch: epoch, deviceID: deviceID))
    guard key.count == keyBytes else { throw CryptoError.openFailed }
    return key
  }

  // MARK: - Epoch links: K_{e-1} under K_e

  public static func epochLink(
    newKey: Data, previousKey: Data, spaceID: String, epoch: Int, nonce: Data? = nil
  ) throws -> String {
    guard newKey.count == keyBytes, previousKey.count == keyBytes else {
      throw CryptoError.invalidKey
    }
    let raw = try aeadSeal(
      previousKey, key: hkdf(newKey, info: epochLinkInfo),
      aad: Data("\(epochLinkInfo)|\(spaceID)|\(epoch)".utf8), nonce: nonce)
    return epochLinkPrefix + Base64URL.encode(raw)
  }

  public static func openEpochLink(_ link: String, newKey: Data, spaceID: String, epoch: Int)
    throws -> Data
  {
    let raw = try payload(link, prefix: epochLinkPrefix, exact: nonceBytes + keyBytes + tagBytes)
    return try aeadOpen(
      raw, key: hkdf(newKey, info: epochLinkInfo),
      aad: Data("\(epochLinkInfo)|\(spaceID)|\(epoch)".utf8))
  }

  // MARK: - Item data keys

  public static func wrapItemKey(
    _ dataKey: Data, spaceKey: Data, spaceID: String, epoch: Int, itemID: String,
    nonce: Data? = nil
  ) throws -> String {
    guard dataKey.count == keyBytes, spaceKey.count == keyBytes else {
      throw CryptoError.invalidKey
    }
    let raw = try aeadSeal(
      dataKey, key: hkdf(spaceKey, info: itemKeyInfo),
      aad: Data("\(itemKeyInfo)|\(spaceID)|\(epoch)|\(itemID)".utf8), nonce: nonce)
    return itemKeyPrefix + Base64URL.encode(raw)
  }

  public static func unwrapItemKey(
    _ wrapped: String, spaceKey: Data, spaceID: String, epoch: Int, itemID: String
  ) throws -> Data {
    let raw = try payload(wrapped, prefix: itemKeyPrefix, exact: nonceBytes + keyBytes + tagBytes)
    return try aeadOpen(
      raw, key: hkdf(spaceKey, info: itemKeyInfo),
      aad: Data("\(itemKeyInfo)|\(spaceID)|\(epoch)|\(itemID)".utf8))
  }

  // MARK: - Encrypted fields

  /// An item's member-visible fields (numbers as they are), under its data key.
  public static func encryptItem(
    _ plaintext: Data, dataKey: Data, spaceID: String, itemID: String, revision: Int,
    nonce: Data? = nil
  ) throws -> String {
    try enc(
      plaintext, key: hkdf(dataKey, info: itemEncInfo),
      aad: Data("\(itemEncInfo)|\(spaceID)|\(itemID)|\(revision)".utf8), nonce: nonce)
  }

  public static func decryptItem(
    _ value: String, dataKey: Data, spaceID: String, itemID: String, revision: Int
  ) throws -> Data {
    try aeadOpen(
      payload(value, prefix: encPrefix, minimum: nonceBytes + tagBytes),
      key: hkdf(dataKey, info: itemEncInfo),
      aad: Data("\(itemEncInfo)|\(spaceID)|\(itemID)|\(revision)".utf8))
  }

  /// Any other op's content (a space name, a display name, proposal details,
  /// a takedown reason), under the space key of the op's epoch.
  public static func encryptOp(
    _ plaintext: Data, spaceKey: Data, spaceID: String, opID: String, nonce: Data? = nil
  ) throws -> String {
    try enc(
      plaintext, key: hkdf(spaceKey, info: opEncInfo),
      aad: Data("\(opEncInfo)|\(spaceID)|\(opID)".utf8), nonce: nonce)
  }

  public static func decryptOp(_ value: String, spaceKey: Data, spaceID: String, opID: String)
    throws -> Data
  {
    try aeadOpen(
      payload(value, prefix: encPrefix, minimum: nonceBytes + tagBytes),
      key: hkdf(spaceKey, info: opEncInfo), aad: Data("\(opEncInfo)|\(spaceID)|\(opID)".utf8))
  }

  // MARK: - Originals

  /// `MLB1 ‖ nonce ‖ ciphertext ‖ tag`: an original (a file, a screenshot, a
  /// segment's audio) as the Spark's blob store keeps it.
  public static func sealBlob(
    _ data: Data, dataKey: Data, spaceID: String, itemID: String, blobID: String,
    nonce: Data? = nil
  ) throws -> Data {
    let sealed =
      blobMagic
      + (try aeadSeal(
        data, key: hkdf(dataKey, info: blobInfo),
        aad: Data("\(blobInfo)|\(spaceID)|\(itemID)|\(blobID)".utf8), nonce: nonce))
    guard sealed.count <= maximumBlobBytes else { throw CryptoError.tooLarge }
    return sealed
  }

  public static func openBlob(
    _ blob: Data, dataKey: Data, spaceID: String, itemID: String, blobID: String
  ) throws -> Data {
    guard blob.count >= blobMagic.count + nonceBytes + tagBytes,
      blob.prefix(blobMagic.count) == blobMagic
    else { throw CryptoError.malformed }
    return try aeadOpen(
      Data(blob.dropFirst(blobMagic.count)), key: hkdf(dataKey, info: blobInfo),
      aad: Data("\(blobInfo)|\(spaceID)|\(itemID)|\(blobID)".utf8))
  }

  // MARK: - Join profile (the joiner's name, sealed to the inviting admin)

  public static func sealProfile(
    _ plaintext: Data, to sealPublicKey: Data, spaceID: String, requestID: String,
    ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(), nonce: Data? = nil
  ) throws -> String {
    let raw = try sealToDevice(
      plaintext, recipient: sealPublicKey, info: profileInfo,
      aad: Data("\(profileInfo)|\(spaceID)|\(requestID)".utf8), ephemeral: ephemeral,
      nonce: nonce)
    return profilePrefix + Base64URL.encode(raw)
  }

  public static func openProfile(
    _ value: String, sealKey: Curve25519.KeyAgreement.PrivateKey, spaceID: String,
    requestID: String
  ) throws -> Data {
    let raw = try payload(value, prefix: profilePrefix, minimum: 32 + nonceBytes + tagBytes)
    return try openFromDevice(
      raw, sealKey: sealKey, info: profileInfo,
      aad: Data("\(profileInfo)|\(spaceID)|\(requestID)".utf8))
  }

  // MARK: - Helpers

  public static func sha256Hex(_ data: Data) -> String {
    hex(Data(SHA256.hash(data: data)))
  }

  public static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  static func hmac(_ key: Data, _ label: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: SymmetricKey(data: key)))
  }

  static func hkdf(_ inputKey: Data, info: String, salt: Data = Data()) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: inputKey), salt: salt, info: Data(info.utf8),
      outputByteCount: keyBytes)
  }

  static func enc(_ plaintext: Data, key: SymmetricKey, aad: Data, nonce: Data?) throws -> String {
    let raw = try aeadSeal(plaintext, key: key, aad: aad, nonce: nonce)
    guard raw.count <= maximumEncBytes else { throw CryptoError.tooLarge }
    return encPrefix + Base64URL.encode(raw)
  }

  static func aeadSeal(_ plaintext: Data, key: SymmetricKey, aad: Data, nonce: Data?) throws
    -> Data
  {
    let chachaNonce: ChaChaPoly.Nonce
    if let nonce {
      guard nonce.count == nonceBytes, let value = try? ChaChaPoly.Nonce(data: nonce) else {
        throw CryptoError.malformed
      }
      chachaNonce = value
    } else {
      chachaNonce = ChaChaPoly.Nonce()
    }
    let box = try ChaChaPoly.seal(plaintext, using: key, nonce: chachaNonce, authenticating: aad)
    return Data(chachaNonce) + box.ciphertext + box.tag
  }

  static func aeadOpen(_ raw: Data, key: SymmetricKey, aad: Data) throws -> Data {
    guard raw.count >= nonceBytes + tagBytes else { throw CryptoError.malformed }
    let bytes = Data(raw)
    do {
      let box = try ChaChaPoly.SealedBox(
        nonce: ChaChaPoly.Nonce(data: bytes.prefix(nonceBytes)),
        ciphertext: bytes.dropFirst(nonceBytes).dropLast(tagBytes),
        tag: bytes.suffix(tagBytes))
      return try ChaChaPoly.open(box, using: key, authenticating: aad)
    } catch {
      throw CryptoError.openFailed
    }
  }

  static func sealToDevice(
    _ plaintext: Data, recipient: Data, info: String, aad: Data,
    ephemeral: Curve25519.KeyAgreement.PrivateKey, nonce: Data?
  ) throws -> Data {
    guard recipient.count == keyBytes,
      let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient),
      let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: publicKey)
    else { throw CryptoError.invalidKey }
    let ephemeralPublic = ephemeral.publicKey.rawRepresentation
    let key = shared.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: ephemeralPublic + recipient, sharedInfo: Data(info.utf8),
      outputByteCount: keyBytes)
    return ephemeralPublic + (try aeadSeal(plaintext, key: key, aad: aad, nonce: nonce))
  }

  static func openFromDevice(
    _ raw: Data, sealKey: Curve25519.KeyAgreement.PrivateKey, info: String, aad: Data
  ) throws -> Data {
    let bytes = Data(raw)
    guard bytes.count >= keyBytes + nonceBytes + tagBytes,
      let ephemeral = try? Curve25519.KeyAgreement.PublicKey(
        rawRepresentation: bytes.prefix(keyBytes)),
      let shared = try? sealKey.sharedSecretFromKeyAgreement(with: ephemeral)
    else { throw CryptoError.openFailed }
    let key = shared.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: bytes.prefix(keyBytes) + sealKey.publicKey.rawRepresentation,
      sharedInfo: Data(info.utf8), outputByteCount: keyBytes)
    return try aeadOpen(Data(bytes.dropFirst(keyBytes)), key: key, aad: aad)
  }

  /// The bytes after `prefix`; base64url with or without padding.
  static func payload(_ value: String, prefix: String, exact: Int? = nil, minimum: Int = 0)
    throws -> Data
  {
    guard value.hasPrefix(prefix),
      let raw = Base64URL.decode(String(value.dropFirst(prefix.count)), allowPadding: true)
    else { throw CryptoError.malformed }
    if let exact, raw.count != exact { throw CryptoError.malformed }
    guard raw.count >= minimum else { throw CryptoError.malformed }
    return raw
  }
}
