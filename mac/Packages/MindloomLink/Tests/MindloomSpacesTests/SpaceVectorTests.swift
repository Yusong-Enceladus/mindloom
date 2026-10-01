import CryptoKit
import Foundation
import MindloomLink
import XCTest

@testable import MindloomSpaces

/// The shared vectors (`privacy/space_vectors.json` in the organizer repo,
/// byte-identical here): every wire format this Mac makes must match the
/// Spark's reference member byte for byte, and open what it made.
final class SpaceVectorTests: XCTestCase {
  /// The Spark suite asserts the same constant, so the copies cannot drift.
  static let vectorsSHA256 = "4c1c1a181d2521250ddbc264faeb2591e8d02cff48b2e3848100d7fe4d067d1a"

  private func vectors() throws -> SpaceJSON {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "space_vectors", withExtension: "json"))
    let data = try Data(contentsOf: url)
    XCTAssertEqual(SpaceCrypto.sha256Hex(data), Self.vectorsSHA256)
    return try SpaceJSON.decode(data)
  }

  private func hex(_ value: SpaceJSON?) throws -> Data {
    try XCTUnwrap(value?.string.flatMap { Data(spaceHex: $0) })
  }

  private func b64u(_ value: SpaceJSON?) throws -> Data {
    try XCTUnwrap(value?.string.flatMap { Base64URL.decode($0, allowPadding: true) })
  }

  private func string(_ value: SpaceJSON?) throws -> String { try XCTUnwrap(value?.string) }
  private func int(_ value: SpaceJSON?) throws -> Int { try XCTUnwrap(value?.int) }

  func testTheVectorFileIsTheSharedOne() throws {
    _ = try vectors()
  }

  func testDeviceKeysDeriveTheSamePublicKeys() throws {
    for device in try XCTUnwrap(vectors()["devices"]?.array) {
      let signing = try Curve25519.Signing.PrivateKey(
        rawRepresentation: hex(device["sign_priv_hex"]))
      let seal = try Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: hex(device["seal_priv_hex"]))
      let keys = SpaceDeviceKeys(
        deviceID: try string(device["device_id"]), signingKey: signing, sealKey: seal)
      XCTAssertEqual(
        Base64URL.encode(keys.signPublicKey), try string(device["expected_sign_pub_b64u"]))
      XCTAssertEqual(
        Base64URL.encode(keys.sealPublicKey), try string(device["expected_seal_pub_b64u"]))
    }
  }

  private func device(_ id: String) throws -> SpaceDeviceKeys {
    let record = try XCTUnwrap(
      vectors()["devices"]?.array?.first { $0["device_id"]?.string == id })
    return SpaceDeviceKeys(
      deviceID: id,
      signingKey: try Curve25519.Signing.PrivateKey(
        rawRepresentation: hex(record["sign_priv_hex"])),
      sealKey: try Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: hex(record["seal_priv_hex"])))
  }

  func testSignaturesVerifyAndOursVerifyToo() throws {
    let v = try vectors()
    // Op signature: the reference signature verifies; one made here does too
    // (CryptoKit's Ed25519 is randomized, so the bytes may differ).
    let op = try XCTUnwrap(v["op_signature"])
    let opDevice = try device(try string(op["device_id"]))
    let opBytes = try b64u(op["op_b64u"])
    let opSig = try string(op["expected_sig_b64u"])
    XCTAssertTrue(
      SpaceSignatures.verifyOp(opBytes, signature: opSig, signPub: opDevice.signPublicKey))
    let mine = try opDevice.sign(SpaceSignatures.opDomain + opBytes)
    XCTAssertTrue(
      SpaceSignatures.verifyOp(opBytes, signature: mine, signPub: opDevice.signPublicKey))
    // A changed byte, another key, or the wrong domain fails.
    var tampered = opBytes
    tampered[tampered.count - 3] ^= 0x01
    XCTAssertFalse(
      SpaceSignatures.verifyOp(tampered, signature: opSig, signPub: opDevice.signPublicKey))
    let other = try device("b2b2b2b2-0000-4000-8000-00000000000b")
    XCTAssertFalse(
      SpaceSignatures.verifyOp(opBytes, signature: opSig, signPub: other.signPublicKey))
    XCTAssertFalse(
      SpaceSignatures.verify(
        signPub: opDevice.signPublicKey, message: SpaceSignatures.joinDomain + opBytes,
        signature: opSig))

    // Request signature: the exact message, and its signature.
    let request = try XCTUnwrap(v["request_signature"])
    let message = SpaceSignatures.requestMessage(
      method: try string(request["method"]), target: try string(request["target"]),
      date: try string(request["date"]), nonce: try string(request["nonce"]),
      body: try b64u(request["body_b64u"]))
    XCTAssertEqual(Base64URL.encode(message), try string(request["expected_message_b64u"]))
    XCTAssertTrue(
      SpaceSignatures.verify(
        signPub: opDevice.signPublicKey, message: message,
        signature: try string(request["expected_sig_b64u"])))
    let headers = try opDevice.requestHeaders(
      method: "GET", target: try string(request["target"]), body: Data(),
      date: Date(timeIntervalSince1970: TimeInterval(try string(request["date"]))!),
      nonce: try string(request["nonce"]))
    XCTAssertEqual(headers["X-Mindloom-Device"], opDevice.deviceID)
    XCTAssertEqual(headers["X-Mindloom-Date"], try string(request["date"]))
    XCTAssertTrue(
      SpaceSignatures.verify(
        signPub: opDevice.signPublicKey, message: message,
        signature: try XCTUnwrap(headers["X-Mindloom-Signature"])))

    // Join signature.
    let join = try XCTUnwrap(v["join_signature"])
    let joiner = try device(try string(join["device_id"]))
    XCTAssertTrue(
      SpaceSignatures.verify(
        signPub: joiner.signPublicKey,
        message: SpaceSignatures.joinDomain + (try b64u(join["request_b64u"])),
        signature: try string(join["expected_sig_b64u"])))
  }

  func testSpaceKeyWrapMatchesAndOpensOnlyWithTheRightKeyAndAAD() throws {
    let w = try XCTUnwrap(vectors()["space_key_wrap"])
    let spaceID = try string(w["space_id"])
    let deviceID = try string(w["device_id"])
    let epoch = try int(w["epoch"])
    let recipient = try Curve25519.KeyAgreement.PrivateKey(
      rawRepresentation: hex(w["recipient_seal_priv_hex"]))
    let wrap = try SpaceCrypto.wrapSpaceKey(
      hex(w["space_key_hex"]), to: recipient.publicKey.rawRepresentation, spaceID: spaceID,
      epoch: epoch, deviceID: deviceID,
      ephemeral: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(w["eph_priv_hex"])),
      nonce: try hex(w["nonce_hex"]))
    XCTAssertEqual(wrap, try string(w["expected"]))
    XCTAssertEqual(
      try SpaceCrypto.unwrapSpaceKey(
        wrap, sealKey: recipient, spaceID: spaceID, epoch: epoch, deviceID: deviceID),
      try hex(w["space_key_hex"]))
    // Another device's key, another epoch or another device id in the AAD: refused.
    XCTAssertThrowsError(
      try SpaceCrypto.unwrapSpaceKey(
        wrap, sealKey: .init(), spaceID: spaceID, epoch: epoch, deviceID: deviceID))
    XCTAssertThrowsError(
      try SpaceCrypto.unwrapSpaceKey(
        wrap, sealKey: recipient, spaceID: spaceID, epoch: epoch + 1, deviceID: deviceID))
    XCTAssertThrowsError(
      try SpaceCrypto.unwrapSpaceKey(
        wrap, sealKey: recipient, spaceID: spaceID, epoch: epoch, deviceID: SpaceID.new()))
    // A changed character fails, whatever it is.
    var chars = Array(wrap)
    chars[chars.count - 5] = chars[chars.count - 5] == "A" ? "B" : "A"
    XCTAssertThrowsError(
      try SpaceCrypto.unwrapSpaceKey(
        String(chars), sealKey: recipient, spaceID: spaceID, epoch: epoch, deviceID: deviceID))
  }

  func testEpochLinkItemKeyItemFieldsOpFieldsBlobAndProfileMatch() throws {
    let v = try vectors()
    let link = try XCTUnwrap(v["epoch_link"])
    let made = try SpaceCrypto.epochLink(
      newKey: hex(link["new_key_hex"]), previousKey: hex(link["prev_key_hex"]),
      spaceID: try string(link["space_id"]), epoch: try int(link["epoch"]),
      nonce: try hex(link["nonce_hex"]))
    XCTAssertEqual(made, try string(link["expected"]))
    XCTAssertEqual(
      try SpaceCrypto.openEpochLink(
        made, newKey: hex(link["new_key_hex"]), spaceID: try string(link["space_id"]),
        epoch: try int(link["epoch"])), try hex(link["prev_key_hex"]))
    XCTAssertThrowsError(
      try SpaceCrypto.openEpochLink(
        made, newKey: hex(link["prev_key_hex"]), spaceID: try string(link["space_id"]),
        epoch: try int(link["epoch"])))

    let ikey = try XCTUnwrap(v["item_key_wrap"])
    let wrapped = try SpaceCrypto.wrapItemKey(
      hex(ikey["data_key_hex"]), spaceKey: hex(ikey["space_key_hex"]),
      spaceID: try string(ikey["space_id"]), epoch: try int(ikey["epoch"]),
      itemID: try string(ikey["item_id"]), nonce: try hex(ikey["nonce_hex"]))
    XCTAssertEqual(wrapped, try string(ikey["expected"]))
    XCTAssertEqual(
      try SpaceCrypto.unwrapItemKey(
        wrapped, spaceKey: hex(ikey["space_key_hex"]), spaceID: try string(ikey["space_id"]),
        epoch: try int(ikey["epoch"]), itemID: try string(ikey["item_id"])),
      try hex(ikey["data_key_hex"]))
    XCTAssertThrowsError(
      try SpaceCrypto.unwrapItemKey(
        wrapped, spaceKey: hex(ikey["space_key_hex"]), spaceID: try string(ikey["space_id"]),
        epoch: try int(ikey["epoch"]), itemID: SpaceID.new()))

    let item = try XCTUnwrap(v["item_enc"])
    let enc = try SpaceCrypto.encryptItem(
      b64u(item["plaintext_b64u"]), dataKey: hex(item["data_key_hex"]),
      spaceID: try string(item["space_id"]), itemID: try string(item["item_id"]),
      revision: try int(item["revision"]), nonce: try hex(item["nonce_hex"]))
    XCTAssertEqual(enc, try string(item["expected"]))
    let plain = try SpaceCrypto.decryptItem(
      enc, dataKey: hex(item["data_key_hex"]), spaceID: try string(item["space_id"]),
      itemID: try string(item["item_id"]), revision: try int(item["revision"]))
    XCTAssertEqual(plain, try b64u(item["plaintext_b64u"]))
    // The reference plaintext opens as item fields (tolerant decode).
    let fields = try JSONDecoder().decode(SpaceItemFields.self, from: plain)
    XCTAssertEqual(fields.title, "周会纪要")
    // Another revision in the AAD: refused.
    XCTAssertThrowsError(
      try SpaceCrypto.decryptItem(
        enc, dataKey: hex(item["data_key_hex"]), spaceID: try string(item["space_id"]),
        itemID: try string(item["item_id"]), revision: try int(item["revision"]) + 1))

    let op = try XCTUnwrap(v["op_enc"])
    let opEnc = try SpaceCrypto.encryptOp(
      b64u(op["plaintext_b64u"]), spaceKey: hex(op["space_key_hex"]),
      spaceID: try string(op["space_id"]), opID: try string(op["op_id"]),
      nonce: try hex(op["nonce_hex"]))
    XCTAssertEqual(opEnc, try string(op["expected"]))

    let blob = try XCTUnwrap(v["blob"])
    let sealed = try SpaceCrypto.sealBlob(
      b64u(blob["plaintext_b64u"]), dataKey: hex(blob["data_key_hex"]),
      spaceID: try string(blob["space_id"]), itemID: try string(blob["item_id"]),
      blobID: try string(blob["blob_id"]), nonce: try hex(blob["nonce_hex"]))
    XCTAssertEqual(Base64URL.encode(sealed), try string(blob["expected_b64u"]))
    XCTAssertEqual(
      try SpaceCrypto.openBlob(
        sealed, dataKey: hex(blob["data_key_hex"]), spaceID: try string(blob["space_id"]),
        itemID: try string(blob["item_id"]), blobID: try string(blob["blob_id"])),
      try b64u(blob["plaintext_b64u"]))
    XCTAssertThrowsError(
      try SpaceCrypto.openBlob(
        sealed, dataKey: hex(blob["data_key_hex"]), spaceID: try string(blob["space_id"]),
        itemID: try string(blob["item_id"]), blobID: SpaceID.new()))

    let profile = try XCTUnwrap(v["join_profile"])
    let recipient = try Curve25519.KeyAgreement.PrivateKey(
      rawRepresentation: hex(profile["recipient_seal_priv_hex"]))
    let sealedProfile = try SpaceCrypto.sealProfile(
      b64u(profile["plaintext_b64u"]), to: recipient.publicKey.rawRepresentation,
      spaceID: try string(profile["space_id"]), requestID: try string(profile["request_id"]),
      ephemeral: try Curve25519.KeyAgreement.PrivateKey(
        rawRepresentation: hex(profile["eph_priv_hex"])),
      nonce: try hex(profile["nonce_hex"]))
    XCTAssertEqual(sealedProfile, try string(profile["expected"]))
    XCTAssertEqual(
      try SpaceCrypto.openProfile(
        sealedProfile, sealKey: recipient, spaceID: try string(profile["space_id"]),
        requestID: try string(profile["request_id"])), try b64u(profile["plaintext_b64u"]))
  }

  func testDerivedKeysIDsInviteHashesAndDetachedHash() throws {
    let d = try XCTUnwrap(vectors()["derived"])
    let k1 = try hex(d["first_epoch_key_hex"])
    let k2 = try hex(d["epoch2_key_hex"])
    let store1 = SpaceCrypto.storeKey(spaceKey: k1)
    XCTAssertEqual(SpaceCrypto.hex(store1), try string(d["expected_store_key_epoch1_hex"]))
    XCTAssertEqual(
      SpaceCrypto.hex(SpaceCrypto.storeKey(spaceKey: k2)),
      try string(d["expected_store_key_epoch2_hex"]))
    let mask = SpaceCrypto.maskKey(firstEpochKey: k1)
    XCTAssertEqual(SpaceCrypto.hex(mask), try string(d["expected_mask_key_hex"]))
    XCTAssertEqual(SpaceCrypto.storeKeyID(store1), try string(d["expected_store_key_id_epoch1"]))
    XCTAssertEqual(SpaceCrypto.maskKeyID(mask), try string(d["expected_mask_key_id"]))
    let secret = try hex(d["invite_secret_hex"])
    XCTAssertEqual(
      SpaceCrypto.hex(SpaceCrypto.inviteGate(secret)), try string(d["expected_invite_gate_hex"]))
    XCTAssertEqual(
      SpaceCrypto.inviteSecretHash(secret), try string(d["expected_invite_secret_hash"]))
    let join = try XCTUnwrap(vectors()["join_signature"])
    XCTAssertEqual(
      SpaceCrypto.inviteBinding(secret: secret, request: try b64u(join["request_b64u"])),
      try string(d["expected_invite_binding"]))
    XCTAssertEqual(
      SpaceCrypto.detachedHash(try string(d["detached_value"])),
      try string(d["expected_detached_sha256"]))
  }
}
