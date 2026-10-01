import CryptoKit
import Foundation
@_spi(MindloomLinkTesting) import MindloomLink
import XCTest

final class SealTests: XCTestCase {
  private let mac = Curve25519.KeyAgreement.PrivateKey()
  private let entryID = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

  func testRoundTripWithFreshEphemeralKeyAndNonceEachTime() throws {
    let plaintext = Data("合成测试：周五交周报".utf8)
    let first = try MindloomSeal.seal(plaintext, entryID: entryID, to: mac.publicKey)
    let second = try MindloomSeal.seal(plaintext, entryID: entryID, to: mac.publicKey)
    XCTAssertTrue(first.hasPrefix("mlseal1."))
    XCTAssertNotEqual(first, second, "every seal uses a new ephemeral key and nonce")
    let firstBytes = try XCTUnwrap(Base64URL.decode(String(first.dropFirst(8))))
    let secondBytes = try XCTUnwrap(Base64URL.decode(String(second.dropFirst(8))))
    XCTAssertNotEqual(firstBytes.prefix(32), secondBytes.prefix(32))
    XCTAssertNotEqual(firstBytes[32..<44], secondBytes[32..<44])
    XCTAssertEqual(firstBytes.count, plaintext.count + MindloomSeal.overheadBytes)
    XCTAssertEqual(try MindloomSeal.open(first, entryID: entryID, with: mac), plaintext)
    XCTAssertEqual(try MindloomSeal.open(second, entryID: entryID, with: mac), plaintext)
  }

  func testTheWireCarriesNoPlaintext() throws {
    let sentinel = "SENTINEL-13800138000"
    let wire = try MindloomSeal.seal(Data(sentinel.utf8), entryID: entryID, to: mac.publicKey)
    XCTAssertFalse(wire.contains(sentinel))
    XCTAssertFalse(wire.contains(Data(sentinel.utf8).base64EncodedString()))
  }

  func testWrongKeyFails() throws {
    let wire = try MindloomSeal.seal(Data("x".utf8), entryID: entryID, to: mac.publicKey)
    assertThrows(MindloomSeal.SealError.openFailed) {
      try MindloomSeal.open(wire, entryID: entryID, with: Curve25519.KeyAgreement.PrivateKey())
    }
  }

  func testWrongEntryIDFails() throws {
    let wire = try MindloomSeal.seal(Data("x".utf8), entryID: entryID, to: mac.publicKey)
    assertThrows(MindloomSeal.SealError.openFailed) {
      try MindloomSeal.open(wire, entryID: EntryID.make(), with: self.mac)
    }
    assertThrows(MindloomSeal.SealError.invalidEntryID) {
      try MindloomSeal.open(wire, entryID: self.entryID.uppercased(), with: self.mac)
    }
  }

  /// Canonical base64url means any single changed character is either
  /// malformed or changes an authenticated byte: every position must fail.
  func testChangingAnyCharacterOfTheWireFails() throws {
    let wire = try MindloomSeal.seal(
      Data("合成：带一个字节的篡改检查".utf8), entryID: entryID, to: mac.publicKey)
    let characters = Array(wire)
    for index in MindloomSeal.wirePrefix.count..<characters.count {
      var changed = characters
      changed[index] = characters[index] == "A" ? "B" : "A"
      XCTAssertThrowsError(try MindloomSeal.open(String(changed), entryID: entryID, with: mac)) {
        let error = $0 as? MindloomSeal.SealError
        XCTAssertTrue(error == .openFailed || error == .malformedWire, "index \(index): \($0)")
      }
    }
  }

  func testFlippingAnyBitOfTheSealedBytesFails() throws {
    let wire = try MindloomSeal.seal(Data("0123456789".utf8), entryID: entryID, to: mac.publicKey)
    let sealed = try XCTUnwrap(Base64URL.decode(String(wire.dropFirst(8))))
    for index in sealed.indices {
      // Bit 7 of the last ephemeral-key byte is ignored by X25519 itself, so
      // flip bit 0 there and everywhere.
      var tampered = sealed
      tampered[index] ^= 0x01
      XCTAssertThrowsError(
        try MindloomSeal.open("mlseal1." + Base64URL.encode(tampered), entryID: entryID, with: mac),
        "byte \(index)")
    }
  }

  func testMalformedWireStrings() throws {
    let wire = try MindloomSeal.seal(Data("x".utf8), entryID: entryID, to: mac.publicKey)
    for bad in [
      "", "mlseal1.", "mlseal1", "MLSEAL1." + wire.dropFirst(8), "mlseal1. " + wire.dropFirst(8),
      wire + "=", wire + "\n", "mlseal1." + Base64URL.encode(Data(count: 59)),
    ] {
      assertThrows(MindloomSeal.SealError.malformedWire) {
        try MindloomSeal.open(String(bad), entryID: self.entryID, with: self.mac)
      }
    }
  }

  func testSealRejectsBadEntryIDsAndNonces() throws {
    for bad in ["", "not-a-uuid", entryID.uppercased(), entryID + "0", "{\(entryID)}"] {
      assertThrows(MindloomSeal.SealError.invalidEntryID) {
        try MindloomSeal.seal(Data("x".utf8), entryID: bad, to: self.mac.publicKey)
      }
    }
    assertThrows(MindloomSeal.SealError.invalidNonce) {
      try MindloomSeal.sealForTesting(
        Data("x".utf8), entryID: self.entryID, to: self.mac.publicKey,
        ephemeralPrivateKey: .init(), nonce: Data(count: 8))
    }
  }

  func testLowOrderRecipientKeysAreRefused() throws {
    let lowOrder: [Data] = [
      Data(count: 32),
      Data([1] + [UInt8](repeating: 0, count: 31)),
      Data(hex: "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800"),
      Data(hex: "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157"),
    ]
    for raw in lowOrder {
      XCTAssertFalse(MindloomSeal.isUsableRecipientKey(raw), raw.hex)
      let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
      assertThrows(MindloomSeal.SealError.invalidRecipientKey) {
        try MindloomSeal.seal(Data("x".utf8), entryID: self.entryID, to: key)
      }
    }
    XCTAssertTrue(MindloomSeal.isUsableRecipientKey(mac.publicKey.rawRepresentation))
    XCTAssertFalse(MindloomSeal.isUsableRecipientKey(Data(count: 31)))
  }

  func testSizeLimitIsOnTheSealedBytes() throws {
    let limit = MindloomSeal.maximumSealedBytes - MindloomSeal.overheadBytes
    assertThrows(MindloomSeal.SealError.tooLarge) {
      try MindloomSeal.seal(Data(count: limit + 1), entryID: self.entryID, to: self.mac.publicKey)
    }
    let wire = try MindloomSeal.seal(Data(count: limit), entryID: entryID, to: mac.publicKey)
    XCTAssertEqual(wire.utf8.count, MindloomSeal.maximumWireBytes)
    XCTAssertEqual(try MindloomSeal.open(wire, entryID: entryID, with: mac).count, limit)
  }

  /// A 25 MiB document (the largest file the phone shares) fits in one seal.
  func testLargestAllowedFileFitsInOneSeal() throws {
    var bytes = Data(count: InboxLimits.maximumFileBytes)
    bytes.replaceSubrange(0..<4, with: Data("%PDF".utf8))
    let payload = try InboxItemPayload.file(
      bytes, filename: "合成报告.pdf", mime: "application/pdf", source: .share,
      createdAt: fixedDate, timeZone: shanghai)
    let entry = try OutboxEntry.seal(payload, to: mac.publicKey)
    let wire = try XCTUnwrap(entry.wire)
    XCTAssertLessThanOrEqual(wire.utf8.count, MindloomSeal.maximumWireBytes)
    let opened = try InboxItemPayload.decode(
      MindloomSeal.open(wire, entryID: entry.entryID, with: mac))
    XCTAssertEqual(opened.bytes?.count, InboxLimits.maximumFileBytes)
  }

  func testKeyIDIsSixteenLowercaseHexCharacters() {
    let id = MindloomSeal.keyID(for: mac.publicKey)
    XCTAssertEqual(id.count, 16)
    XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) })
    XCTAssertEqual(id, MindloomSeal.keyID(for: mac.publicKey))
    XCTAssertNotEqual(id, MindloomSeal.keyID(for: Curve25519.KeyAgreement.PrivateKey().publicKey))
  }

  func testEntryIDs() {
    let id = EntryID.make()
    XCTAssertTrue(EntryID.isValid(id))
    XCTAssertEqual(id, id.lowercased())
    XCTAssertFalse(EntryID.isValid(id.uppercased()))
    XCTAssertFalse(EntryID.isValid("3f2504e0-4f89-41d3-9a0c-0305e82c330g"))
    XCTAssertFalse(EntryID.isValid("3f2504e0x4f89-41d3-9a0c-0305e82c3301"))
    XCTAssertFalse(EntryID.isValid("../../etc/passwd"))
  }

  func testBase64URLIsCanonical() {
    XCTAssertEqual(Base64URL.encode(Data([0xFB, 0xFF])), "-_8")
    XCTAssertEqual(Base64URL.decode("-_8"), Data([0xFB, 0xFF]))
    XCTAssertNil(Base64URL.decode("-_9"), "non-zero unused bits")
    XCTAssertNil(Base64URL.decode("+/8"), "standard alphabet")
    XCTAssertNil(Base64URL.decode("-_8="), "padding not allowed by default")
    XCTAssertEqual(Base64URL.decode("-_8=", allowPadding: true), Data([0xFB, 0xFF]))
    XCTAssertNil(Base64URL.decode("-_8==", allowPadding: true), "wrong padding length")
    XCTAssertNil(Base64URL.decode("A"), "impossible length")
    XCTAssertEqual(Base64URL.decode(""), Data())
  }
}
