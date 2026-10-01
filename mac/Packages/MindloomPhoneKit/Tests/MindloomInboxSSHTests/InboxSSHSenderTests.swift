import Crypto
import Foundation
import MindloomLink
import MindloomPhoneKit
import NIOCore
import NIOSSH
import XCTest

@testable import MindloomInboxSSH

/// The SSH sender against in-process NIO SSH servers: a fake Spark running
/// the inbox gate, and a fake relay that only forwards to the Spark.
final class InboxSSHSenderTests: XCTestCase {
  private let phoneKey = Curve25519.Signing.PrivateKey()
  private let sparkHostKey = Curve25519.Signing.PrivateKey()
  private let relayHostKey = Curve25519.Signing.PrivateKey()
  private let macKey = Curve25519.KeyAgreement.PrivateKey()
  private let gate = "~/hack/organizer/spark/zhiji-inbox"
  private var servers: [() async -> Void] = []

  override func tearDown() async throws {
    for stop in servers { await stop() }
    servers = []
  }

  // MARK: - Fixtures

  private func hostKey(_ key: Curve25519.Signing.PrivateKey) -> SSHHostKey {
    SSHHostKey(openSSH: PairingPayload.openSSHPublicKey(key.publicKey))!
  }

  private func startSpark(
    _ behaviour: FakeSpark.Behaviour = .normal, authorizing: Curve25519.Signing.PublicKey? = nil
  ) async throws -> FakeSpark {
    let spark = FakeSpark(
      hostKey: sparkHostKey, user: "owner", phoneKey: authorizing ?? phoneKey.publicKey,
      behaviour: behaviour)
    try await spark.start()
    servers.append { await spark.stop() }
    return spark
  }

  private func startRelay(permitPort: Int, authorizing: Curve25519.Signing.PublicKey? = nil)
    async throws
    -> FakeRelay
  {
    let relay = FakeRelay(
      hostKey: relayHostKey, user: "jump", phoneKey: authorizing ?? phoneKey.publicKey,
      permitHost: "127.0.0.1", permitPort: permitPort)
    try await relay.start()
    servers.append { await relay.stop() }
    return relay
  }

  private func configuration(
    spark: FakeSpark, relay: FakeRelay? = nil,
    sparkKey: SSHHostKey? = nil, relayKey: SSHHostKey? = nil
  ) throws -> InboxSSHConfiguration {
    var configuration = InboxSSHConfiguration(
      spark: try PairingEndpoint(
        host: "127.0.0.1", port: spark.port, user: "owner",
        hostKey: sparkKey ?? hostKey(sparkHostKey)),
      relay: try relay.map {
        try PairingEndpoint(
          host: "127.0.0.1", port: $0.port, user: "jump", hostKey: relayKey ?? hostKey(relayHostKey)
        )
      },
      gate: gate, phoneKey: phoneKey)
    configuration.connectTimeout = .seconds(5)
    configuration.handshakeTimeout = .seconds(5)
    configuration.commandTimeout = .seconds(10)
    return configuration
  }

  private func sealed(_ text: String = "合成：周四下午评审") throws -> OutboxEntry {
    try OutboxEntry.seal(InboxItemPayload.text(text, source: .keyboard), to: macKey.publicKey)
  }

  @discardableResult
  private func expectFailure(
    _ category: DeliveryErrorCategory, file: StaticString = #filePath, line: UInt = #line,
    _ body: () async throws -> Void
  ) async -> InboxDeliveryError? {
    do {
      try await body()
      XCTFail("expected \(category)", file: file, line: line)
      return nil
    } catch let error as InboxDeliveryError {
      XCTAssertEqual(error.category, category, error.detail, file: file, line: line)
      return error
    } catch {
      XCTFail("expected \(category), got \(error)", file: file, line: line)
      return nil
    }
  }

  // MARK: - Direct to the Spark

  func testExecWithStdinDeliversTheSealedWire() async throws {
    let spark = try await startSpark()
    let entry = try sealed()
    let session = try await InboxSSHSender(configuration: configuration(spark: spark)).openSession()
    let receipt = try await session.add(entryID: entry.entryID, wire: XCTUnwrap(entry.wire))
    await session.close()

    XCTAssertEqual(receipt, InboxAddReceipt(entryID: entry.entryID, duplicate: false))
    XCTAssertEqual(spark.commands, ["\(gate) add --sealed --id \(entry.entryID) --json"])
    XCTAssertEqual(
      spark.blobs, [entry.entryID: entry.wire!], "the Spark stores exactly the sealed wire")
    // Only the Mac can open what the Spark holds.
    let opened = try InboxItemPayload.decode(
      MindloomSeal.open(spark.blobs[entry.entryID]!, entryID: entry.entryID, with: macKey))
    XCTAssertEqual(opened.text, "合成：周四下午评审")
  }

  func testSeveralEntriesOverOneConnectionAndDuplicatesAreSuccess() async throws {
    let spark = try await startSpark()
    let entries = try (0..<3).map { try sealed("第\($0)条") }
    let session = try await InboxSSHSender(configuration: configuration(spark: spark)).openSession()
    for entry in entries {
      let receipt = try await session.add(entryID: entry.entryID, wire: entry.wire!)
      XCTAssertFalse(receipt.duplicate)
    }
    // A retry after a lost reply: same id again.
    let retry = try await session.add(entryID: entries[0].entryID, wire: entries[0].wire!)
    XCTAssertEqual(retry, InboxAddReceipt(entryID: entries[0].entryID, duplicate: true))
    await session.close()
    XCTAssertEqual(spark.blobs.count, 3)
    XCTAssertEqual(spark.connections, 1)
  }

  func testTheCurrentSparkReplyShapeIsAccepted() async throws {
    let spark = try await startSpark(.legacyReply)
    let entry = try sealed()
    let session = try await InboxSSHSender(configuration: configuration(spark: spark)).openSession()
    let receipt = try await session.add(entryID: entry.entryID, wire: entry.wire!)
    await session.close()
    XCTAssertEqual(receipt.entryID, entry.entryID)
  }

  /// A server with another host key is dropped during key exchange: the
  /// phone key is never offered and nothing is sent.
  func testWrongSparkHostKeyIsRefused() async throws {
    let spark = try await startSpark()
    let impostorKey = hostKey(Curve25519.Signing.PrivateKey())
    let error = await expectFailure(.hostKeyMismatch) {
      _ = try await InboxSSHSender(
        configuration: configuration(spark: spark, sparkKey: impostorKey)
      )
      .openSession()
    }
    XCTAssertTrue(error?.detail.hasPrefix("spark") == true)
    XCTAssertEqual(spark.authAttempts.read { $0 }, 0, "the phone key was never offered")
    XCTAssertEqual(spark.commands, [])
  }

  func testUnauthorizedPhoneKeyFailsAuthentication() async throws {
    let spark = try await startSpark(authorizing: Curve25519.Signing.PrivateKey().publicKey)
    await expectFailure(.authentication) {
      _ = try await InboxSSHSender(configuration: configuration(spark: spark)).openSession()
    }
    XCTAssertEqual(spark.commands, [])
  }

  func testNothingListeningIsANetworkFailure() async throws {
    let spark = try await startSpark()
    var config = try configuration(spark: spark)
    await spark.stop()
    config.connectTimeout = .seconds(3)
    let error = await expectFailure(.network) {
      _ = try await InboxSSHSender(configuration: config).openSession()
    }
    XCTAssertNotNil(error)
  }

  func testGateRejectionFailsOnlyThatEntry() async throws {
    let spark = try await startSpark(.rejectEntries)
    let session = try await InboxSSHSender(configuration: configuration(spark: spark)).openSession()
    let first = try sealed()
    await expectFailure(.rejected) {
      _ = try await session.add(entryID: first.entryID, wire: first.wire!)
    }
    // The connection is still good for the next entry.
    spark.behaviour.change { $0 = .normal }
    let second = try sealed()
    let receipt = try await session.add(entryID: second.entryID, wire: second.wire!)
    XCTAssertEqual(receipt.entryID, second.entryID)
    await session.close()
  }

  func testRefusedExecIsARejection() async throws {
    let spark = try await startSpark(.refuseExec)
    let session = try await InboxSSHSender(configuration: configuration(spark: spark)).openSession()
    let entry = try sealed()
    await expectFailure(.rejected) {
      _ = try await session.add(entryID: entry.entryID, wire: entry.wire!)
    }
    await session.close()
  }

  func testUnexpectedRepliesAreProtocolErrors() async throws {
    for behaviour in [FakeSpark.Behaviour.garbage, .wrongID] {
      let spark = try await startSpark(behaviour)
      let session = try await InboxSSHSender(configuration: configuration(spark: spark))
        .openSession()
      let entry = try sealed()
      await expectFailure(.protocolError) {
        _ = try await session.add(entryID: entry.entryID, wire: entry.wire!)
      }
      await session.close()
    }
  }

  func testASilentGateTimesOut() async throws {
    let spark = try await startSpark(.hang)
    var config = try configuration(spark: spark)
    config.commandTimeout = .milliseconds(800)
    let session = try await InboxSSHSender(configuration: config).openSession()
    let entry = try sealed()
    await expectFailure(.timeout) {
      _ = try await session.add(entryID: entry.entryID, wire: entry.wire!)
    }
    await session.close()
  }

  func testOnlySealedWiresAndValidIDsAreSent() async throws {
    let spark = try await startSpark()
    let session = try await InboxSSHSender(configuration: configuration(spark: spark)).openSession()
    await expectFailure(.rejected) {
      _ = try await session.add(entryID: EntryID.make(), wire: "plaintext")
    }
    await expectFailure(.rejected) {
      _ = try await session.add(entryID: "x; rm -rf ~", wire: "mlseal1.AAAA")
    }
    await session.close()
    XCTAssertEqual(spark.commands, [], "nothing reached the gate")
  }

  // MARK: - Through the relay

  func testRelayForwardsToTheSparkOnly() async throws {
    let spark = try await startSpark()
    let relay = try await startRelay(permitPort: spark.port)
    let entry = try sealed()
    let session = try await InboxSSHSender(configuration: configuration(spark: spark, relay: relay))
      .openSession()
    let receipt = try await session.add(entryID: entry.entryID, wire: entry.wire!)
    await session.close()

    XCTAssertEqual(receipt.entryID, entry.entryID)
    XCTAssertEqual(relay.requestedTargets.read { $0 }, ["127.0.0.1:\(spark.port)"])
    XCTAssertEqual(relay.sessionRequests.read { $0 }, 0, "no command ever runs on the relay")
    XCTAssertEqual(spark.blobs[entry.entryID], entry.wire)
  }

  func testWrongRelayHostKeyIsRefused() async throws {
    let spark = try await startSpark()
    let relay = try await startRelay(permitPort: spark.port)
    let error = await expectFailure(.hostKeyMismatch) {
      _ = try await InboxSSHSender(
        configuration: configuration(
          spark: spark, relay: relay, relayKey: hostKey(Curve25519.Signing.PrivateKey()))
      ).openSession()
    }
    XCTAssertTrue(error?.detail.hasPrefix("relay") == true)
    XCTAssertEqual(relay.authAttempts.read { $0 }, 0)
    XCTAssertEqual(spark.connections, 0, "never got as far as the Spark")
  }

  /// The relay is honest but the thing behind it is not the paired Spark.
  func testWrongSparkHostKeyBehindTheRelayIsRefused() async throws {
    let spark = try await startSpark()
    let relay = try await startRelay(permitPort: spark.port)
    let error = await expectFailure(.hostKeyMismatch) {
      _ = try await InboxSSHSender(
        configuration: configuration(
          spark: spark, relay: relay, sparkKey: hostKey(Curve25519.Signing.PrivateKey()))
      ).openSession()
    }
    XCTAssertTrue(error?.detail.hasPrefix("spark") == true)
    XCTAssertEqual(spark.authAttempts.read { $0 }, 0)
    XCTAssertEqual(spark.commands, [])
  }

  func testRelayRefusingTheTargetIsReported() async throws {
    let spark = try await startSpark()
    let relay = try await startRelay(permitPort: spark.port + 1)
    await expectFailure(.relayRefused) {
      _ = try await InboxSSHSender(configuration: configuration(spark: spark, relay: relay))
        .openSession()
    }
    XCTAssertEqual(spark.connections, 0)
  }

  func testRelayRefusingThePhoneKeyIsAnAuthenticationFailure() async throws {
    let spark = try await startSpark()
    let relay = try await startRelay(
      permitPort: spark.port, authorizing: Curve25519.Signing.PrivateKey().publicKey)
    let error = await expectFailure(.authentication) {
      _ = try await InboxSSHSender(configuration: configuration(spark: spark, relay: relay))
        .openSession()
    }
    XCTAssertTrue(error?.detail.hasPrefix("relay") == true)
  }

  /// The largest entry the phone makes (a 25 MiB document, about 46.6 MB of
  /// wire) goes through both SSH layers intact.
  func testLargestEntryThroughTheRelay() async throws {
    let spark = try await startSpark()
    let relay = try await startRelay(permitPort: spark.port)
    var bytes = Data(count: InboxLimits.maximumFileBytes)
    bytes.replaceSubrange(0..<5, with: Data("%PDF-".utf8))
    bytes[bytes.count - 1] = 0x42
    let entry = try OutboxEntry.seal(
      InboxItemPayload.file(bytes, filename: "合成大文件.pdf", mime: "application/pdf", source: .share),
      to: macKey.publicKey)
    let session = try await InboxSSHSender(configuration: configuration(spark: spark, relay: relay))
      .openSession()
    _ = try await session.add(entryID: entry.entryID, wire: entry.wire!)
    await session.close()
    XCTAssertEqual(spark.blobs[entry.entryID]?.utf8.count, entry.wire!.utf8.count)
    XCTAssertEqual(spark.blobs[entry.entryID], entry.wire)
  }

  // MARK: - Whole path: outbox → SSH → Spark

  func testOutboxDeliveryThroughTheRelayLeavesOnlySealedBlobsOnTheSpark() async throws {
    let spark = try await startSpark()
    let relay = try await startRelay(permitPort: spark.port)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mindloom-ssh-e2e-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try OutboxStore(root: root)

    let sentinel = "SENTINEL-18612345678"
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(sentinel.utf8))
    let payloads = try [
      InboxItemPayload.text("口述：\(sentinel)", source: .keyboard),
      InboxItemPayload.link(
        URL(string: "https://example.com/\(sentinel)")!, title: sentinel, source: .share),
      InboxItemPayload.image(png, mime: "image/png", source: .share),
    ]
    for payload in payloads { try store.add(OutboxEntry.seal(payload, to: macKey.publicKey)) }

    let deliverer = OutboxDeliverer(
      store: store,
      opener: InboxSSHSender(configuration: try configuration(spark: spark, relay: relay)))
    let report = await deliverer.deliverQueued()
    XCTAssertEqual(report.sent.count, 3)
    XCTAssertNil(report.stoppedBy)
    XCTAssertEqual(try store.queued(), [])
    XCTAssertEqual(try store.sent().count, 3)

    let blobs = spark.blobs
    XCTAssertEqual(blobs.count, 3)
    for (id, blob) in blobs {
      XCTAssertTrue(blob.hasPrefix("mlseal1."))
      XCTAssertFalse(blob.contains(sentinel), "the Spark never sees plaintext")
      XCTAssertFalse(blob.contains(Data(sentinel.utf8).base64EncodedString()))
      let item = try InboxItemPayload.decode(MindloomSeal.open(blob, entryID: id, with: macKey))
      XCTAssertTrue([.text, .link, .image].contains(item.kind))
    }
    // After sending, the phone keeps no sealed payload and no image at all.
    for entry in try store.sent() {
      XCTAssertNil(entry.wire)
      if entry.kind == .image { XCTAssertNil(entry.preview) }
    }
  }

  func testDelivererStopsOnAWrongHostKeyAndKeepsTheQueue() async throws {
    let spark = try await startSpark()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mindloom-ssh-mismatch-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try OutboxStore(root: root)
    try store.add(sealed())
    let deliverer = OutboxDeliverer(
      store: store,
      opener: InboxSSHSender(
        configuration: try configuration(
          spark: spark, sparkKey: hostKey(Curve25519.Signing.PrivateKey()))))
    let report = await deliverer.deliverQueued()
    XCTAssertEqual(report.stoppedBy, .hostKeyMismatch)
    XCTAssertEqual(try store.queued().count, 1)
    XCTAssertEqual(spark.blobs, [:])
  }

  // MARK: - Command and reply parsing

  func testAddCommandIsBuiltFromValidatedWordsOnly() throws {
    var config = InboxSSHConfiguration(
      spark: try PairingEndpoint(
        host: "spark-demo", port: 22, user: "owner", hostKey: hostKey(sparkHostKey)),
      relay: nil, gate: gate, phoneKey: phoneKey)
    let id = EntryID.make()
    XCTAssertEqual(try config.addCommand(entryID: id), "\(gate) add --sealed --id \(id) --json")
    XCTAssertThrowsError(try config.addCommand(entryID: "\(id); id"))
    XCTAssertThrowsError(try config.addCommand(entryID: id.uppercased()))
    config.gate = "zhiji-inbox; cat ~/.ssh/id_ed25519"
    XCTAssertThrowsError(try config.addCommand(entryID: id))
  }

  func testGateReplyParsing() throws {
    let id = EntryID.make()
    func outcome(_ stdout: String, exit: Int? = 0, stderr: String = "") -> ExecOutcome {
      ExecOutcome(
        exitStatus: exit, stdout: ByteBuffer(string: stdout), stderr: ByteBuffer(string: stderr),
        stdoutTruncated: false)
    }
    XCTAssertEqual(
      try InboxGateReply.receipt(from: outcome(#"{"ok":true,"id":"\#(id)"}"#), entryID: id),
      InboxAddReceipt(entryID: id, duplicate: false))
    XCTAssertEqual(
      try InboxGateReply.receipt(
        from: outcome(
          "warning: something\n" + #"{"ok":true,"inbox_id":"\#(id)","duplicate":true}"# + "\n"),
        entryID: id),
      InboxAddReceipt(entryID: id, duplicate: true))
    XCTAssertEqual(
      try InboxGateReply.receipt(
        from: outcome(#"{"ok":false,"error":"duplicate"}"#, exit: 1), entryID: id),
      InboxAddReceipt(entryID: id, duplicate: true))
    XCTAssertEqual(
      try InboxGateReply.receipt(from: outcome(#"{"ok":true}"#), entryID: id),
      InboxAddReceipt(entryID: id, duplicate: false))

    func category(_ outcome: ExecOutcome) -> DeliveryErrorCategory? {
      do {
        _ = try InboxGateReply.receipt(from: outcome, entryID: id)
        return nil
      } catch {
        return (error as? InboxDeliveryError)?.category
      }
    }
    XCTAssertEqual(category(outcome(#"{"ok":false,"error":"locked"}"#, exit: 1)), .rejected)
    // The organizer is down (the Spark gate's exit 2): transient, retried.
    let unavailable = category(outcome(#"{"ok":false,"error":"unavailable"}"#, exit: 2))
    XCTAssertEqual(unavailable, .network)
    XCTAssertEqual(unavailable?.isTransient, true)
    XCTAssertEqual(
      category(outcome("", exit: 1, stderr: "zhiji-inbox: this key may only run")), .rejected)
    XCTAssertEqual(category(outcome("", exit: 0)), .protocolError)
    XCTAssertEqual(category(outcome("", exit: nil)), .protocolError)
    XCTAssertEqual(category(outcome(#"{"ok":true,"id":"\#(EntryID.make())"}"#)), .protocolError)
    XCTAssertEqual(category(outcome(#"{"ok":true,"id":"\#(id)"}"#, exit: 3)), .protocolError)
  }
}
