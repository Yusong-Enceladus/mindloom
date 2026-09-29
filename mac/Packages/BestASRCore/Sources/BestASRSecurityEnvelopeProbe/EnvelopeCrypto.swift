import CryptoKit
import Foundation

public enum EnvelopePurpose: String, Codable, CaseIterable, Sendable {
  case asset
  case databaseBackup
}

public enum EnvelopeCryptoError: Error, Equatable, Sendable {
  case authenticationFailed
  case invalidContainer
  case unsupportedVersion
}

public struct EncryptedEnvelope: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let keyIdentifier: UUID
  public let purpose: EnvelopePurpose
  public let wrappedDataKey: Data
  public let sealedPayload: Data

  public init(
    schemaVersion: Int = 1,
    kind: String = "bestasr-encrypted-envelope",
    keyIdentifier: UUID,
    purpose: EnvelopePurpose,
    wrappedDataKey: Data,
    sealedPayload: Data
  ) {
    self.schemaVersion = schemaVersion
    self.kind = kind
    self.keyIdentifier = keyIdentifier
    self.purpose = purpose
    self.wrappedDataKey = wrappedDataKey
    self.sealedPayload = sealedPayload
  }
}

public enum EnvelopeCrypto {
  public static func makeMasterKey() -> SymmetricKey {
    SymmetricKey(size: .bits256)
  }

  public static func keyData(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
  }

  public static func key(from data: Data) throws -> SymmetricKey {
    guard data.count == 32 else {
      throw EnvelopeCryptoError.invalidContainer
    }
    return SymmetricKey(data: data)
  }

  public static func encrypt(
    _ plaintext: Data,
    masterKey: SymmetricKey,
    purpose: EnvelopePurpose,
    keyIdentifier: UUID = UUID()
  ) throws -> EncryptedEnvelope {
    let dataKey = SymmetricKey(size: .bits256)
    let payloadBox = try AES.GCM.seal(
      plaintext,
      using: dataKey,
      authenticating: payloadAAD(
        purpose: purpose,
        keyIdentifier: keyIdentifier
      )
    )
    let wrappedKeyBox = try AES.GCM.seal(
      keyData(dataKey),
      using: masterKey,
      authenticating: keyWrapAAD(
        purpose: purpose,
        keyIdentifier: keyIdentifier
      )
    )
    guard let sealedPayload = payloadBox.combined,
      let wrappedDataKey = wrappedKeyBox.combined
    else {
      throw EnvelopeCryptoError.invalidContainer
    }
    return EncryptedEnvelope(
      keyIdentifier: keyIdentifier,
      purpose: purpose,
      wrappedDataKey: wrappedDataKey,
      sealedPayload: sealedPayload
    )
  }

  public static func decrypt(
    _ envelope: EncryptedEnvelope,
    masterKey: SymmetricKey
  ) throws -> Data {
    guard envelope.schemaVersion == 1 else {
      throw EnvelopeCryptoError.unsupportedVersion
    }
    guard envelope.kind == "bestasr-encrypted-envelope" else {
      throw EnvelopeCryptoError.invalidContainer
    }
    do {
      let wrappedKeyBox = try AES.GCM.SealedBox(
        combined: envelope.wrappedDataKey
      )
      let dataKeyBytes = try AES.GCM.open(
        wrappedKeyBox,
        using: masterKey,
        authenticating: keyWrapAAD(
          purpose: envelope.purpose,
          keyIdentifier: envelope.keyIdentifier
        )
      )
      let dataKey = try key(from: dataKeyBytes)
      let payloadBox = try AES.GCM.SealedBox(combined: envelope.sealedPayload)
      return try AES.GCM.open(
        payloadBox,
        using: dataKey,
        authenticating: payloadAAD(
          purpose: envelope.purpose,
          keyIdentifier: envelope.keyIdentifier
        )
      )
    } catch let error as EnvelopeCryptoError {
      throw error
    } catch {
      throw EnvelopeCryptoError.authenticationFailed
    }
  }

  private static func keyWrapAAD(
    purpose: EnvelopePurpose,
    keyIdentifier: UUID
  ) -> Data {
    Data(
      "bestasr-keywrap-v1|\(purpose.rawValue)|\(keyIdentifier.uuidString)".utf8
    )
  }

  private static func payloadAAD(
    purpose: EnvelopePurpose,
    keyIdentifier: UUID
  ) -> Data {
    Data(
      "bestasr-payload-v1|\(purpose.rawValue)|\(keyIdentifier.uuidString)".utf8
    )
  }
}
