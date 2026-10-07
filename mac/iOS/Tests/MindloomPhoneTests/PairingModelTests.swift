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
    keychain = PhoneKeyKeychain(service: "app.mindloom.tests.\(UUID().uuidString)")
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
      ("hello", "这不是 Mindloom 的配对码。"),
      ("mlpair1.@@@", "配对码不完整。请在 Mac 上重新拷贝。"),
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
      XCTAssertEqual(PairingModel.message(for: error), "配对码无法使用。请在 Mac 上重新拷贝。")
    }
    XCTAssertFalse(model.isPaired)
    XCTAssertNil(keychain.load())
  }
}

/// The review fixes of the App Group move (appgroup-fix): what waits for pairing is sealed once a
/// pairing exists, and the Live Activity's content goes stale when the app stops renewing it.
@MainActor
final class AppGroupFixTests: XCTestCase {
  private var root: URL!
  private var keychain: PhoneKeyKeychain!
  private var suite: String!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "appgroup-fix-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    keychain = PhoneKeyKeychain(service: "app.mindloom.tests.\(UUID().uuidString)")
    suite = "mindloom-tests-\(UUID().uuidString)"
  }

  override func tearDown() async throws {
    keychain.delete()
    UserDefaults().removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }

  /// Shared before the app had moved its pairing into the App Group: the item waits for pairing
  /// although the phone is paired. The launch (and every activation) seals it, once.
  func testSealPendingSealsWhatWaitedOnceAPairingExists() throws {
    let recordStore = PairingRecordStore(file: root.appendingPathComponent("pairing.json"))
    let collector = PhoneItemCollector(
      items: try PhoneItemStore(root: root.appendingPathComponent("items")),
      outbox: try OutboxStore(root: root.appendingPathComponent("outbox")),
      pairing: recordStore, signaling: nil)
    let waiting = try collector.collect(
      PhoneItem(createdAt: Date(), kind: .text, source: .share, text: "合成：等配对"),
      payloads: [try InboxItemPayload.text("合成：等配对", source: .share, createdAt: Date())])
    XCTAssertTrue(waiting.awaitingPairing)
    let pairing = PairingModel(recordStore: recordStore, keychain: keychain)
    let delivery = DeliveryService(
      collector: collector, pairing: pairing,
      settings: PhoneSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), isShared: false))

    delivery.sealPending()
    XCTAssertTrue(try XCTUnwrap(collector.items.item(id: waiting.id)).awaitingPairing, "unpaired: waits")

    try pairing.pair(text: SyntheticPairing.payload().encodedText())
    delivery.sealPending()
    let sealed = try XCTUnwrap(collector.items.item(id: waiting.id))
    XCTAssertFalse(sealed.awaitingPairing)
    XCTAssertEqual(sealed.entryIDs.count, 1)
    XCTAssertEqual(try collector.outbox.queued().map(\.entryID), sealed.entryIDs)
    XCTAssertEqual(try collector.outbox.queued().first?.sealKeyID, pairing.record?.sealKeyID)
    delivery.sealPending()
    XCTAssertEqual(try collector.outbox.queued().count, 1, "a second call seals nothing more")
    delivery.refresh()
    XCTAssertEqual(delivery.rows.map(\.id), [waiting.id])
    XCTAssertTrue(delivery.rows[0].onPhone)
  }

  func testLiveActivityGoesStaleWithinTwoMinutesOrAtTheEnd() {
    let now = Date(timeIntervalSince1970: 1_790_730_902)
    XCTAssertEqual(
      VoiceLiveActivity.staleDate(endsAt: nil, now: now), now.addingTimeInterval(120),
      "charging (no countdown): stale two minutes ahead, renewed while the session runs")
    XCTAssertEqual(
      VoiceLiveActivity.staleDate(endsAt: now.addingTimeInterval(600), now: now),
      now.addingTimeInterval(120))
    XCTAssertEqual(
      VoiceLiveActivity.staleDate(endsAt: now.addingTimeInterval(30), now: now),
      now.addingTimeInterval(30))
  }

  /// A build without the App Group after one with it: Home says the data is elsewhere.
  func testTheDataElsewhereNoticeIsPlainWords() {
    XCTAssertFalse(HomeList.dataElsewhereNotice.contains("App Group"))
    XCTAssertTrue(HomeList.dataElsewhereNotice.hasPrefix("之前的配对和内容"))
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
