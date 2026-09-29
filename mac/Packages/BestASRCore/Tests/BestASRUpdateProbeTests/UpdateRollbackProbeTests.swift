import BestASRModelManagerProbe
import CryptoKit
import Foundation
import XCTest

@testable import BestASRUpdateProbe

final class UpdateRollbackProbeTests: XCTestCase {
  func testAppManifestSignatureBindsVersionAndPackageMetadata() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let unsigned = AppUpdateManifest(
      version: "1.2.3",
      minimumOS: "14.2.0",
      packageSizeBytes: 42,
      packageSHA256: String(repeating: "a", count: 64),
      signingKeyID: "fixture-key",
      signatureBase64: Data().base64EncodedString()
    )
    let signature = try privateKey.signature(for: unsigned.signingPayload)
    let signed = unsigned.replacingSignature(signature.base64EncodedString())
    let verifier = try Curve25519.Signing.PublicKey(
      rawRepresentation: privateKey.publicKey.rawRepresentation
    )

    XCTAssertTrue(
      verifier.isValidSignature(signature, for: signed.signingPayload)
    )
    let changed = AppUpdateManifest(
      version: "1.2.4",
      minimumOS: signed.minimumOS,
      packageSizeBytes: signed.packageSizeBytes,
      packageSHA256: signed.packageSHA256,
      signingKeyID: signed.signingKeyID,
      signatureBase64: signed.signatureBase64
    )
    XCTAssertFalse(
      verifier.isValidSignature(signature, for: changed.signingPayload)
    )
  }

  func testModelEnvelopeCanonicalizesFileOrder() throws {
    let descriptorA = descriptor(
      version: "2.0.0",
      files: [
        file("z.bin", digest: "a"),
        file("a.bin", digest: "b"),
      ]
    )
    let descriptorB = descriptor(
      version: "2.0.0",
      files: [
        file("a.bin", digest: "b"),
        file("z.bin", digest: "a"),
      ]
    )

    XCTAssertEqual(
      SignedModelUpdateEnvelope(
        descriptor: descriptorA,
        signingKeyID: "model-key",
        signatureBase64: ""
      ).signingPayload,
      SignedModelUpdateEnvelope(
        descriptor: descriptorB,
        signingKeyID: "model-key",
        signatureBase64: ""
      ).signingPayload
    )
  }

  func testModelSignatureRejectsTamperedDescriptor() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let unsigned = SignedModelUpdateEnvelope(
      descriptor: descriptor(
        version: "2.0.0",
        files: [file("weights.bin", digest: "a")]
      ),
      signingKeyID: "model-key",
      signatureBase64: Data().base64EncodedString()
    )
    let signed = unsigned.replacingSignature(
      try privateKey.signature(for: unsigned.signingPayload)
        .base64EncodedString()
    )
    let verifier = ModelUpdateSignatureVerifier(
      trustedSigningKeys: [
        "model-key": privateKey.publicKey.rawRepresentation
      ]
    )
    try verifier.verify(signed)

    let tampered = SignedModelUpdateEnvelope(
      descriptor: descriptor(
        version: "2.0.1",
        files: signed.descriptor.files
      ),
      signingKeyID: signed.signingKeyID,
      signatureBase64: signed.signatureBase64
    )
    XCTAssertThrowsError(try verifier.verify(tampered)) { error in
      XCTAssertEqual(error as? ModelUpdateEnvelopeError, .signatureMismatch)
    }
  }

  func testFullUpdateRollbackMatrixPassesAndPreservesUserData() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-update-test-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let summaryURL = root.appendingPathComponent("summary.json")

    let report = try UpdateRollbackProbeRunner.run(summaryURL: summaryURL)

    XCTAssertEqual(report.conclusion, "pass")
    XCTAssertEqual(report.signingAlgorithm, "Ed25519")
    XCTAssertEqual(report.scenarios.count, 10)
    XCTAssertEqual(report.finalAppVersion, "1.1.0")
    XCTAssertEqual(report.finalModelVersion, "2.0.0")
    XCTAssertTrue(report.userDataUnchanged)
    XCTAssertTrue(report.sourceAudioPreserved)
    XCTAssertNotEqual(report.appPublicKeySHA256, report.modelPublicKeySHA256)
    XCTAssertTrue(report.scenarios.allSatisfy { $0.status == "pass" })
    XCTAssertTrue(
      report.scenarios.allSatisfy {
        $0.userDataUnchanged
          && $0.sourceAudioPreserved
          && $0.stagingRemoved
          && $0.appAndModelNamespacesSeparated
      }
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path))
  }

  func testAppPointerWriteFailureRemovesMovedVersionDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-app-pointer-test-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = root.appendingPathComponent("store", isDirectory: true)
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    try Data("blocks active directory".utf8).write(
      to: store.appendingPathComponent("active")
    )
    let package = root.appendingPathComponent("app.pkg")
    let packageData = Data("fixture package".utf8)
    try packageData.write(to: package)
    let privateKey = Curve25519.Signing.PrivateKey()
    let unsigned = AppUpdateManifest(
      version: "1.0.0",
      minimumOS: "14.2.0",
      packageSizeBytes: packageData.count,
      packageSHA256: AppUpdateManager.sha256(packageData),
      signingKeyID: "fixture-key",
      signatureBase64: Data().base64EncodedString()
    )
    let manifest = unsigned.replacingSignature(
      try privateKey.signature(for: unsigned.signingPayload).base64EncodedString()
    )
    let manager = AppUpdateManager(
      root: store,
      trustedSigningKeys: [
        "fixture-key": privateKey.publicKey.rawRepresentation
      ]
    )

    let attempt = manager.stageVerifyAndActivate(
      manifest: manifest,
      packageURL: package
    )

    XCTAssertEqual(attempt.status, .fail)
    XCTAssertEqual(attempt.failureCategory, .fileSystem)
    XCTAssertTrue(attempt.stagingRemoved)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: store.appendingPathComponent("versions/1.0.0").path
      )
    )
  }

  private func descriptor(
    version: String,
    files: [BestASRModelManagerProbe.ModelFileDescriptor]
  ) -> BestASRModelManagerProbe.ModelArtifactDescriptor {
    BestASRModelManagerProbe.ModelArtifactDescriptor(
      artifactID: "fixture-model",
      version: version,
      files: files
    )
  }

  private func file(
    _ path: String,
    digest: Character
  ) -> BestASRModelManagerProbe.ModelFileDescriptor {
    BestASRModelManagerProbe.ModelFileDescriptor(
      relativePath: path,
      sizeBytes: 1,
      sha256: String(repeating: digest, count: 64)
    )
  }
}
