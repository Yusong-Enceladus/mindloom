import BestASRModelManagerProbe
import CryptoKit
import Foundation

public struct SignedModelUpdateEnvelope: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let descriptor: ModelArtifactDescriptor
  public let signingKeyID: String
  public let signatureBase64: String

  public init(
    schemaVersion: Int = 1,
    descriptor: ModelArtifactDescriptor,
    signingKeyID: String,
    signatureBase64: String
  ) {
    self.schemaVersion = schemaVersion
    self.descriptor = descriptor
    self.signingKeyID = signingKeyID
    self.signatureBase64 = signatureBase64
  }

  public var signingPayload: Data {
    let files = descriptor.files
      .sorted { $0.relativePath < $1.relativePath }
      .map {
        "\($0.relativePath):\($0.sizeBytes):\($0.sha256)"
      }
      .joined(separator: "\n")
    return Data(
      [
        "bestasr-model-update-v1",
        String(schemaVersion),
        descriptor.artifactID,
        descriptor.version,
        signingKeyID,
        files,
      ].joined(separator: "\n").utf8
    )
  }

  public func replacingSignature(_ signatureBase64: String) -> Self {
    Self(
      schemaVersion: schemaVersion,
      descriptor: descriptor,
      signingKeyID: signingKeyID,
      signatureBase64: signatureBase64
    )
  }
}

public enum ModelUpdateEnvelopeError: String, Codable, Error, Sendable {
  case invalidEnvelope
  case signatureMismatch
  case unknownSigningKey
}

public struct ModelUpdateSignatureVerifier {
  private let trustedSigningKeys: [String: Data]

  public init(trustedSigningKeys: [String: Data]) {
    self.trustedSigningKeys = trustedSigningKeys
  }

  public func verify(_ envelope: SignedModelUpdateEnvelope) throws {
    guard envelope.schemaVersion == 1,
      !envelope.signingKeyID.isEmpty,
      let signature = Data(base64Encoded: envelope.signatureBase64)
    else {
      throw ModelUpdateEnvelopeError.invalidEnvelope
    }
    guard let publicKeyBytes = trustedSigningKeys[envelope.signingKeyID] else {
      throw ModelUpdateEnvelopeError.unknownSigningKey
    }
    let publicKey = try Curve25519.Signing.PublicKey(
      rawRepresentation: publicKeyBytes
    )
    guard publicKey.isValidSignature(signature, for: envelope.signingPayload) else {
      throw ModelUpdateEnvelopeError.signatureMismatch
    }
  }
}
