import CryptoKit
import Foundation
import XCTest

@testable import BestASRSecurityEnvelopeProbe

final class EnvelopeCryptoTests: XCTestCase {
  func testEnvelopeRoundTripDoesNotExposePlaintext() throws {
    let plaintext = Data("synthetic restricted payload marker".utf8)
    let masterKey = EnvelopeCrypto.makeMasterKey()

    let envelope = try EnvelopeCrypto.encrypt(
      plaintext,
      masterKey: masterKey,
      purpose: .asset,
      keyIdentifier: fixedKeyID
    )
    let encoded = try JSONEncoder().encode(envelope)

    XCTAssertFalse(encoded.range(of: plaintext) != nil)
    XCTAssertEqual(
      try EnvelopeCrypto.decrypt(envelope, masterKey: masterKey),
      plaintext
    )
  }

  func testWrongMasterKeyAndTamperingAreRejected() throws {
    let envelope = try EnvelopeCrypto.encrypt(
      Data("synthetic payload".utf8),
      masterKey: EnvelopeCrypto.key(from: Data(repeating: 1, count: 32)),
      purpose: .databaseBackup,
      keyIdentifier: fixedKeyID
    )

    XCTAssertThrowsError(
      try EnvelopeCrypto.decrypt(
        envelope,
        masterKey: EnvelopeCrypto.key(from: Data(repeating: 2, count: 32))
      )
    ) { error in
      XCTAssertEqual(error as? EnvelopeCryptoError, .authenticationFailed)
    }

    var tamperedPayload = envelope.sealedPayload
    tamperedPayload[tamperedPayload.startIndex] ^= 0x01
    let tampered = EncryptedEnvelope(
      keyIdentifier: envelope.keyIdentifier,
      purpose: envelope.purpose,
      wrappedDataKey: envelope.wrappedDataKey,
      sealedPayload: tamperedPayload
    )
    XCTAssertThrowsError(
      try EnvelopeCrypto.decrypt(
        tampered,
        masterKey: EnvelopeCrypto.key(from: Data(repeating: 1, count: 32))
      )
    ) { error in
      XCTAssertEqual(error as? EnvelopeCryptoError, .authenticationFailed)
    }
  }

  func testAtomicFaultPreservesPreviousEnvelopeAndCleansStaging() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-envelope-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("store.envelope")
    let masterKey = EnvelopeCrypto.makeMasterKey()
    let original = try EnvelopeCrypto.encrypt(
      Data("original".utf8),
      masterKey: masterKey,
      purpose: .databaseBackup,
      keyIdentifier: fixedKeyID
    )
    let replacement = try EnvelopeCrypto.encrypt(
      Data("replacement".utf8),
      masterKey: masterKey,
      purpose: .databaseBackup,
      keyIdentifier: fixedKeyID
    )
    try AtomicEnvelopeFile.commit(original, to: destination)

    XCTAssertThrowsError(
      try AtomicEnvelopeFile.commit(
        replacement,
        to: destination,
        fault: .beforeCommit
      )
    ) { error in
      XCTAssertEqual(
        error as? AtomicEnvelopeFileError,
        .injectedBeforeCommit
      )
    }

    XCTAssertEqual(try AtomicEnvelopeFile.read(from: destination), original)
    let children = try FileManager.default.contentsOfDirectory(
      atPath: root.path
    )
    XCTAssertFalse(children.contains { $0.hasSuffix(".envelope-staging") })

    try AtomicEnvelopeFile.commit(replacement, to: destination)
    XCTAssertEqual(try AtomicEnvelopeFile.read(from: destination), replacement)
  }

  func testEnvelopeCodableRejectsUnknownVersion() throws {
    let envelope = EncryptedEnvelope(
      schemaVersion: 2,
      keyIdentifier: fixedKeyID,
      purpose: .asset,
      wrappedDataKey: Data(repeating: 0, count: 60),
      sealedPayload: Data(repeating: 0, count: 60)
    )
    XCTAssertThrowsError(
      try EnvelopeCrypto.decrypt(
        envelope,
        masterKey: EnvelopeCrypto.makeMasterKey()
      )
    ) { error in
      XCTAssertEqual(error as? EnvelopeCryptoError, .unsupportedVersion)
    }
  }

  private var fixedKeyID: UUID {
    UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
  }
}
