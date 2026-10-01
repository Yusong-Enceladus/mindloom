import CryptoKit
import Foundation
import MindloomLink
import XCTest

final class PairingPayloadTests: XCTestCase {
  private typealias Failure = PairingPayload.PairingError

  static func hostKey(_ seed: UInt8 = 1) -> SSHHostKey {
    let key = try! Curve25519.Signing.PrivateKey(
      rawRepresentation: Data(repeating: seed, count: 32))
    return SSHHostKey(openSSH: PairingPayload.openSSHPublicKey(key.publicKey))!
  }

  private let phoneKey = Data((1...32).map { UInt8($0) })
  private let sealKey = Curve25519.KeyAgreement.PrivateKey()

  private func makePayload(relay: Bool = false) throws -> PairingPayload {
    try PairingPayload(
      label: "小林的 MacBook Pro",
      spark: PairingEndpoint(
        host: "spark-demo", port: 22, user: "owner", hostKey: Self.hostKey(1)),
      relay: relay
        ? PairingEndpoint(
          host: "relay.example.org", port: 2222, user: "jump", hostKey: Self.hostKey(2))
        : nil,
      phoneKey: phoneKey, phoneKeyID: "phone-7f3a",
      macSealPublicKey: sealKey.publicKey.rawRepresentation)
  }

  private func object(of text: String) throws -> [String: Any] {
    let json = try XCTUnwrap(Base64URL.decode(String(text.dropFirst(PairingPayload.prefix.count))))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
  }

  private func text(of object: [String: Any]) throws -> String {
    PairingPayload.prefix
      + Base64URL.encode(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
  }

  func testRoundTripWithoutRelayWritesNull() throws {
    let payload = try makePayload()
    let text = try payload.encodedText()
    XCTAssertTrue(text.hasPrefix("mlpair1."))
    XCTAssertFalse(text.contains("="), "unpadded base64url")
    XCTAssertEqual(try PairingPayload.decode(text: text), payload)

    let object = try object(of: text)
    XCTAssertEqual(
      Set(object.keys),
      ["v", "label", "spark", "relay", "phone_key", "phone_key_id", "mac_seal_pub", "gate"])
    XCTAssertTrue(object["relay"] is NSNull, "relay is written as null")
    XCTAssertEqual(object["gate"] as? String, "zhiji-inbox")
    XCTAssertEqual(object["phone_key"] as? String, phoneKey.base64EncodedString())
    XCTAssertEqual(
      object["mac_seal_pub"] as? String, sealKey.publicKey.rawRepresentation.base64EncodedString())
    let spark = try XCTUnwrap(object["spark"] as? [String: Any])
    XCTAssertEqual(Set(spark.keys), ["host", "port", "user", "host_key"])
    XCTAssertTrue(
      (spark["host_key"] as? String)?.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI") == true)
  }

  func testRoundTripWithRelay() throws {
    let payload = try makePayload(relay: true)
    let decoded = try PairingPayload.decode(text: payload.encodedText())
    XCTAssertEqual(decoded, payload)
    XCTAssertEqual(decoded.relay?.port, 2222)
    XCTAssertEqual(decoded.relay?.hostKey, Self.hostKey(2))
  }

  func testPastedTextIsTrimmedAndPaddingTolerated() throws {
    let payload = try makePayload()
    var text = try payload.encodedText()
    let bodyCount = text.count - PairingPayload.prefix.count
    if bodyCount % 4 != 0 { text += String(repeating: "=", count: 4 - bodyCount % 4) }
    XCTAssertEqual(try PairingPayload.decode(text: "  \n" + text + "\n"), payload)
  }

  func testMissingRelayKeyMeansNoRelay() throws {
    var object = try object(of: makePayload().encodedText())
    object.removeValue(forKey: "relay")
    XCTAssertNil(try PairingPayload.decode(text: text(of: object)).relay)
  }

  func testRejectsWhatIsNotAPairingCode() {
    assertThrows(Failure.notAPairingCode) { try PairingPayload.decode(text: "hello") }
    assertThrows(Failure.notAPairingCode) { try PairingPayload.decode(text: "mlseal1.AAAA") }
    assertThrows(Failure.malformed) { try PairingPayload.decode(text: "mlpair1.!!!!") }
    assertThrows(Failure.malformed) {
      try PairingPayload.decode(text: "mlpair1." + Base64URL.encode(Data("{}".utf8)))
    }
    assertThrows(Failure.malformed) {
      try PairingPayload.decode(text: "mlpair1." + String(repeating: "A", count: 9000))
    }
  }

  /// No host key, no pairing: there is no trust-on-first-use fallback.
  func testHostKeyIsRequiredAndStrict() throws {
    let good = try object(of: makePayload().encodedText())
    func withSparkKey(_ key: Any?) throws -> String {
      var object = good
      var spark = object["spark"] as! [String: Any]
      spark["host_key"] = key
      object["spark"] = spark
      return try text(of: object)
    }
    assertThrows(Failure.malformed) { try PairingPayload.decode(text: withSparkKey(nil)) }
    let ed25519Blob = Data(base64Encoded: String(Self.hostKey(1).openSSH.split(separator: " ")[1]))!
    for bad in [
      "", "ssh-ed25519", "ssh-ed25519 !!!!",
      "ssh-rsa " + Data(repeating: 1, count: 64).base64EncodedString(),
      "ssh-dss " + ed25519Blob.base64EncodedString(),
      // The type in the text must match the type inside the blob.
      "ecdsa-sha2-nistp256 " + ed25519Blob.base64EncodedString(),
      // Truncated key material.
      "ssh-ed25519 " + ed25519Blob.dropLast().base64EncodedString(),
      "ssh-ed25519 " + (ed25519Blob + Data([0])).base64EncodedString(),
    ] {
      assertThrows(Failure.invalidHostKey) { try PairingPayload.decode(text: withSparkKey(bad)) }
    }
    // A trailing comment is allowed and dropped.
    let commented = try PairingPayload.decode(
      text: withSparkKey(Self.hostKey(1).openSSH + " root@spark"))
    XCTAssertEqual(commented.spark.hostKey.openSSH, Self.hostKey(1).openSSH)
  }

  func testEndpointFieldsCannotInjectOptionsOrShellSyntax() throws {
    let good = try object(of: makePayload().encodedText())
    func withSpark(_ field: String, _ value: Any) throws -> String {
      var object = good
      var spark = object["spark"] as! [String: Any]
      spark[field] = value
      object["spark"] = spark
      return try text(of: object)
    }
    for host in [
      "", "-oProxyCommand=sh", "spark;rm -rf ~", "spark host", "spark\n", "$(id)", "a/b",
    ] {
      assertThrows(Failure.invalidHost) { try PairingPayload.decode(text: withSpark("host", host)) }
    }
    XCTAssertNoThrow(try PairingPayload.decode(text: withSpark("host", "100.64.0.7")))
    XCTAssertNoThrow(try PairingPayload.decode(text: withSpark("host", "fd7a:115c:a1e0::1")))
    for port in [0, 65_536, -22] {
      assertThrows(Failure.invalidPort) { try PairingPayload.decode(text: withSpark("port", port)) }
    }
    for user in ["", "-l", "root;id", "a b", String(repeating: "u", count: 33)] {
      assertThrows(Failure.invalidUser) { try PairingPayload.decode(text: withSpark("user", user)) }
    }
  }

  func testKeyFields() throws {
    let good = try object(of: makePayload().encodedText())
    func with(_ field: String, _ value: Any) throws -> String {
      var object = good
      object[field] = value
      return try text(of: object)
    }
    assertThrows(Failure.invalidPhoneKey) {
      try PairingPayload.decode(text: with("phone_key", Data(count: 31).base64EncodedString()))
    }
    assertThrows(Failure.invalidPhoneKey) {
      try PairingPayload.decode(text: with("phone_key", Data(count: 32).base64EncodedString()))
    }
    assertThrows(Failure.invalidPhoneKey) {
      try PairingPayload.decode(text: with("phone_key", "not base64!"))
    }
    assertThrows(Failure.invalidSealKey) {
      try PairingPayload.decode(text: with("mac_seal_pub", Data(count: 32).base64EncodedString()))
    }
    assertThrows(Failure.invalidSealKey) {
      try PairingPayload.decode(text: with("mac_seal_pub", Data(count: 16).base64EncodedString()))
    }
    for id in ["", "-x", "a b", "a;b", "a:b", String(repeating: "k", count: 65)] {
      assertThrows(Failure.invalidPhoneKeyID) {
        try PairingPayload.decode(text: with("phone_key_id", id))
      }
    }
    for gate in ["", "zhiji-inbox;id", "zhiji inbox", "-c", "../zhiji-inbox", "$(x)"] {
      assertThrows(Failure.invalidGate) { try PairingPayload.decode(text: with("gate", gate)) }
    }
    XCTAssertNoThrow(
      try PairingPayload.decode(text: with("gate", "~/hack/organizer/spark/zhiji-inbox")))
    assertThrows(Failure.unsupportedVersion(2)) { try PairingPayload.decode(text: with("v", 2)) }
    assertThrows(Failure.invalidLabel) { try PairingPayload.decode(text: with("label", " ")) }
    assertThrows(Failure.invalidLabel) { try PairingPayload.decode(text: with("label", "a\u{7}b")) }
  }

  func testThePrivateKeyNeverAppearsInDescriptions() throws {
    let payload = try makePayload(relay: true)
    let secret = phoneKey.base64EncodedString()
    var dumped = ""
    dump(payload, to: &dumped)
    for rendered in [
      payload.description, payload.debugDescription, String(describing: payload),
      String(reflecting: payload), "\(payload)", dumped,
    ] {
      XCTAssertFalse(rendered.contains(secret), rendered)
      XCTAssertFalse(rendered.contains("[1, 2, 3"), rendered)
      XCTAssertTrue(rendered.contains("redacted"), rendered)
    }
  }

  func testRecordHasEverythingButThePrivateKey() throws {
    let payload = try makePayload(relay: true)
    let record = payload.record
    let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    XCTAssertFalse(json.contains("phone_key\""))
    XCTAssertFalse(json.contains(phoneKey.base64EncodedString()))
    XCTAssertEqual(try JSONDecoder().decode(PairingRecord.self, from: Data(json.utf8)), record)
    XCTAssertEqual(record.sealKeyID, payload.sealKeyID)
    XCTAssertEqual(record.relay, payload.relay)
  }

  func testPhoneAuthorizedKeyCarriesTheMarker() throws {
    let payload = try makePayload()
    let line = payload.phoneAuthorizedKey
    XCTAssertTrue(line.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"))
    XCTAssertTrue(line.hasSuffix(" mindloom-phone:phone-7f3a"))
    let parsed = try XCTUnwrap(SSHHostKey(openSSH: line))
    XCTAssertEqual(parsed.type, "ssh-ed25519")
    XCTAssertEqual(parsed.blob.suffix(32), payload.phoneSigningKey.publicKey.rawRepresentation)
  }
}
