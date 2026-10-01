import CryptoKit
import Foundation
@_spi(MindloomLinkTesting) import MindloomLink
import XCTest

/// `seal_vectors.json` comes from an independent Python implementation
/// (`Vectors/make_seal_vectors.py`); CryptoKit must agree byte for byte.
final class SealVectorTests: XCTestCase {
  func testVectorFileMatchesTheContractConstants() throws {
    let file = try SealVectorFile.load()
    XCTAssertEqual(file.format, "mlseal1")
    XCTAssertEqual(file.hkdfInfo, MindloomSeal.hkdfInfo)
    XCTAssertEqual(file.aadPrefix, MindloomSeal.aadPrefix)
    XCTAssertEqual(file.vectors.count, 5)
    XCTAssertGreaterThanOrEqual(file.openFailures.count, 30)
  }

  func testSealWithInjectedKeysReproducesEveryWireString() throws {
    for vector in try SealVectorFile.load().vectors {
      let mac = try Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: Data(hex: vector.macPrivHex))
      let ephemeral = try Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: Data(hex: vector.ephPrivHex))
      XCTAssertEqual(mac.publicKey.rawRepresentation.hex, vector.macPubHex, vector.name)
      XCTAssertEqual(ephemeral.publicKey.rawRepresentation.hex, vector.ephPubHex, vector.name)

      let wire = try MindloomSeal.sealForTesting(
        Data(hex: vector.plaintextHex), entryID: vector.entryId, to: mac.publicKey,
        ephemeralPrivateKey: ephemeral, nonce: Data(hex: vector.nonceHex))
      XCTAssertEqual(wire, vector.wire, vector.name)
    }
  }

  func testOpenRecoversEveryPlaintext() throws {
    for vector in try SealVectorFile.load().vectors {
      let mac = try Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: Data(hex: vector.macPrivHex))
      let plaintext = try MindloomSeal.open(vector.wire, entryID: vector.entryId, with: mac)
      XCTAssertEqual(plaintext.hex, vector.plaintextHex, vector.name)
    }
  }

  func testPayloadVectorsDecodeAsValidInboxItems() throws {
    let payloads = try SealVectorFile.load().vectors.filter {
      ["text-keyboard", "link-share", "image-share"].contains($0.name)
    }
    XCTAssertEqual(payloads.count, 3)
    for vector in payloads {
      let item = try InboxItemPayload.decode(Data(hex: vector.plaintextHex))
      XCTAssertEqual(item.v, 1)
      XCTAssertNotNil(item.createdDate, vector.name)
    }
  }

  /// Wrong key, wrong entry id, a flipped bit in every region, and structural
  /// damage: all must fail, with the expected error.
  func testEveryOpenFailureVectorFails() throws {
    for failure in try SealVectorFile.load().openFailures {
      let mac = try Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: Data(hex: failure.macPrivHex))
      let expected: MindloomSeal.SealError =
        switch failure.expect {
        case "open_failed": .openFailed
        case "malformed_wire": .malformedWire
        default: .openFailed
        }
      XCTAssertTrue(["open_failed", "malformed_wire"].contains(failure.expect), failure.name)
      XCTAssertThrowsError(
        try MindloomSeal.open(failure.wire, entryID: failure.entryId, with: mac)
      ) {
        XCTAssertEqual($0 as? MindloomSeal.SealError, expected, failure.name)
      }
    }
  }

  func testFailureVectorsCoverTheContractCases() throws {
    let names = try SealVectorFile.load().openFailures.map(\.name)
    for vector in [
      "text-keyboard", "link-share", "image-share", "long-multiblock", "empty-plaintext",
    ] {
      XCTAssertTrue(names.contains("\(vector)/wrong-key"), vector)
      XCTAssertTrue(names.contains("\(vector)/wrong-entry-id"), vector)
      XCTAssertTrue(names.contains("\(vector)/tampered-tag"), vector)
      XCTAssertTrue(names.contains("\(vector)/tampered-nonce"), vector)
      XCTAssertTrue(names.contains("\(vector)/tampered-eph-pub"), vector)
    }
  }
}
