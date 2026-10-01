import CryptoKit
import Foundation
import MindloomLink
import MindloomPhoneKit
import XCTest

@testable import MindloomPhone

/// Pairing on the phone: the private key only in the Keychain, the rest in
/// the App Group, and plain words for every refused code.
@MainActor
final class PairingModelTests: XCTestCase {
  private var root: URL!
  private var keychain: PhoneKeyKeychain!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pairing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    keychain = PhoneKeyKeychain(service: "com.bestasr.phone.tests.\(UUID().uuidString)")
  }

  override func tearDown() async throws {
    keychain.delete()
    try? FileManager.default.removeItem(at: root)
  }

  private func makeModel() -> PairingModel {
    PairingModel(
      recordStore: PairingRecordStore(file: root.appendingPathComponent("pairing.json")),
      keychain: keychain)
  }

  func testPairingKeepsTheKeyOnlyInTheKeychain() throws {
    let model = makeModel()
    XCTAssertFalse(model.isPaired)
    let payload = try SyntheticPairing.payload()
    let record = try model.pair(text: payload.encodedText())
    XCTAssertTrue(model.isPaired)
    XCTAssertEqual(record.label, "合成的 MacBook")
    XCTAssertEqual(keychain.load(), payload.phoneKey)
    XCTAssertEqual(
      model.signingKey()?.publicKey.rawRepresentation,
      payload.phoneSigningKey.publicKey.rawRepresentation)

    let stored = try Data(contentsOf: root.appendingPathComponent("pairing.json"))
    let json = String(decoding: stored, as: UTF8.self)
    XCTAssertFalse(
      json.contains(payload.phoneKey.base64EncodedString()), "no private key in the App Group")
    XCTAssertFalse(json.contains("phone_key\""), "no private key field at all")
    XCTAssertTrue(json.contains("mac_seal_pub"))

    // A new model (the next launch, or an extension) sees the same pairing.
    XCTAssertEqual(makeModel().record, record)
  }

  func testPairingAgainReplacesTheOldPairing() throws {
    let model = makeModel()
    try model.pair(text: SyntheticPairing.payload(label: "旧的 Mac").encodedText())
    let second = try SyntheticPairing.payload(label: "新的 Mac")
    try model.pair(text: second.encodedText())
    XCTAssertEqual(model.record?.label, "新的 Mac")
    XCTAssertEqual(keychain.load(), second.phoneKey)
  }

  func testUnpairForgetsBoth() throws {
    let model = makeModel()
    try model.pair(text: SyntheticPairing.payload().encodedText())
    model.unpair()
    XCTAssertFalse(model.isPaired)
    XCTAssertNil(keychain.load())
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("pairing.json").path))
  }

  func testRecordWithoutItsKeyIsNotAPairing() throws {
    let model = makeModel()
    try model.pair(text: SyntheticPairing.payload().encodedText())
    keychain.delete()
    XCTAssertFalse(makeModel().isPaired, "for example after a restore to another phone")
  }

  func testRefusedCodesAreExplained() throws {
    let model = makeModel()
    for (text, expected) in [
      ("hello", "这不是织机的配对码"),
      ("mlpair1.@@@", "配对码不完整，请在 Mac 上重新复制"),
    ] {
      XCTAssertThrowsError(try model.pair(text: text)) { error in
        XCTAssertEqual(PairingModel.message(for: error), expected)
      }
    }
    // A pairing whose Spark host key is missing is refused: no trust on
    // first use.
    var json =
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(SyntheticPairing.payload())) as! [String: Any]
    var spark = json["spark"] as! [String: Any]
    spark["host_key"] = ""
    json["spark"] = spark
    let data = try JSONSerialization.data(withJSONObject: json)
    let text =
      PairingPayload.prefix
      + data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    XCTAssertThrowsError(try model.pair(text: text)) { error in
      XCTAssertEqual(error as? PairingPayload.PairingError, .invalidHostKey)
      XCTAssertTrue(PairingModel.message(for: error).contains("Spark 的身份"))
    }
    XCTAssertFalse(model.isPaired)
    XCTAssertNil(keychain.load())
  }
}

enum SyntheticPairing {
  static let macKey = Curve25519.KeyAgreement.PrivateKey()

  static func payload(label: String = "合成的 MacBook") throws -> PairingPayload {
    let hostLine = PairingPayload.openSSHPublicKey(Curve25519.Signing.PrivateKey().publicKey)
    return try PairingPayload(
      label: label,
      spark: PairingEndpoint(
        host: "spark.example", port: 22, user: "mindloom",
        hostKey: XCTUnwrap(SSHHostKey(openSSH: hostLine))),
      relay: nil,
      phoneKey: Curve25519.Signing.PrivateKey().rawRepresentation,
      phoneKeyID: "phone-\(Int.random(in: 1000...9999))",
      macSealPublicKey: macKey.publicKey.rawRepresentation)
  }
}
