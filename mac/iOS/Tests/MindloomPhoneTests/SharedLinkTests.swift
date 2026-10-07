import CryptoKit
import Foundation
import MindloomLink
import MindloomPhoneKit
import XCTest

/// The link between the app and its extensions on a build without the App Group (IOS-CODE-MAP §3b):
/// keychain records for the voice channel, the notify-state level, and the share handoff. Runs in
/// the app's test host, where the data-protection keychain is available. Synthetic data only.
@MainActor
final class SharedLinkTests: XCTestCase {
  private var service: String!

  override func setUp() async throws {
    service = "app.mindloom.test.\(UUID().uuidString)"
  }

  private func records() -> KeychainRecords {
    KeychainRecords(accessGroup: nil, service: service)
  }

  func testKeychainRecordsRoundTripAndRemove() throws {
    let store = records()
    XCTAssertTrue(store.isUsable())
    XCTAssertNil(store.read("state"))
    try store.write(Data("一".utf8), as: "state")
    try store.write(Data("二".utf8), as: "state")
    XCTAssertEqual(store.read("state"), Data("二".utf8))
    store.remove("state")
    XCTAssertNil(store.read("state"))
  }

  /// After the move into the App Group the voice records left in the shared keychain group go,
  /// and only this service's.
  func testRemoveAllClearsOnlyThisService() throws {
    let store = records()
    try store.write(Data("合成".utf8), as: "state")
    try store.write(Data("合成".utf8), as: "final")
    let other = KeychainRecords(accessGroup: nil, service: service + ".other")
    try other.write(Data("留下".utf8), as: "items")
    defer { other.remove("items") }
    store.removeAll()
    XCTAssertNil(store.read("state"))
    XCTAssertNil(store.read("final"))
    XCTAssertEqual(other.read("items"), Data("留下".utf8))
  }

  func testVoiceChannelOverTheKeychainCarriesStatePartialsFinalsAndAcks() throws {
    let store = records()
    let channel = VoiceChannel(
      records: store, level: NotifyLevelLine(name: "app.mindloom.test.level.\(service!)"))
    XCTAssertFalse(channel.isAppGroup)
    try channel.writeState(VoiceState(sessionAliveUntil: 10, recording: true, seq: 3))
    XCTAssertEqual(channel.readState()?.seq, 3)
    try channel.writePartial(VoiceText(seq: 3, text: "合成：明天"))
    XCTAssertEqual(channel.readPartial()?.text, "合成：明天")
    var finals = VoiceFinals()
    finals.append(VoiceText(seq: 3, text: "合成：明天开会", outcome: .text))
    try channel.writeFinals(finals)
    XCTAssertEqual(channel.readFinals()?.entries.map(\.text), ["合成：明天开会"])
    var ack = VoiceAck()
    ack.insert(3, at: 1)
    try channel.writeAck(ack)
    XCTAssertEqual(channel.readAck()?.inserted, [3])
    channel.writeLevel(0.5)
    XCTAssertEqual(channel.readLevel(), 0.5, accuracy: 0.0001)
    for name in ["state", "partial", "final", "ack"] { store.remove(name) }
  }

  func testShareHandoffGivesThePairingAndListsTheExtensionItems() throws {
    let handoff = ShareHandoff(records: records())
    XCTAssertNil(handoff.readPairing())
    let macKey = Curve25519.KeyAgreement.PrivateKey()
    let hostLine = PairingPayload.openSSHPublicKey(Curve25519.Signing.PrivateKey().publicKey)
    let payload = try PairingPayload(
      label: "合成的 Mac",
      spark: PairingEndpoint(
        host: "spark.example", port: 22, user: "mindloom",
        hostKey: XCTUnwrap(SSHHostKey(openSSH: hostLine))),
      relay: nil, phoneKey: Curve25519.Signing.PrivateKey().rawRepresentation,
      phoneKeyID: "phone-test", macSealPublicKey: macKey.publicKey.rawRepresentation)
    try handoff.writePairing(payload.record, phoneKey: payload.phoneKey)
    XCTAssertEqual(handoff.readPairing()?.record, payload.record)
    XCTAssertEqual(handoff.readPairing()?.phoneKey, payload.phoneKey)

    // The extension lists one item still on the phone; the app imports it with a hollow circle,
    // then sees it delivered.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PhoneItemStore(root: root.appendingPathComponent("items"))
    let collector = PhoneItemCollector(
      items: store, outbox: try OutboxStore(root: root.appendingPathComponent("outbox")),
      pairing: PairingRecordStore(file: root.appendingPathComponent("pairing.json")),
      signaling: nil)
    let item = PhoneItem(createdAt: Date(), kind: .text, source: .share, text: "合成：读书会改期")
    try handoff.writeItems([ShareHandoff.Entry(item: item, onPhone: true)])
    XCTAssertEqual(handoff.importItems(into: store), 1)
    XCTAssertEqual(collector.delivery(of: try XCTUnwrap(store.item(id: item.id))), .onPhone)
    XCTAssertFalse(try collector.withdraw(id: item.id), "the extension's item is not the app's to take back")
    try handoff.writeItems([ShareHandoff.Entry(item: item, onPhone: false)])
    XCTAssertEqual(handoff.importItems(into: store), 1)
    XCTAssertEqual(handoff.importItems(into: store), 0, "nothing changed")
    XCTAssertFalse(collector.delivery(of: try XCTUnwrap(store.item(id: item.id))).isOnPhone)

    handoff.clearPairing()
    XCTAssertNil(handoff.readPairing())
    handoff.records.remove("items")
  }
}
