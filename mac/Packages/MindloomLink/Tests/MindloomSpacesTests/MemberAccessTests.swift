import CryptoKit
import Foundation
import MindloomLink
import MindloomSpacesTestSupport
import XCTest

@testable import MindloomSpaces

/// v8 B1 on the Mac: this Mac's own SSH key in OpenSSH's formats, the gate's
/// HTTP framing, the invite code, enrollment and unpairing.
final class MemberAccessTests: XCTestCase {
  static let spark = SpaceInviteCode.Endpoint(
    host: "spark.test", port: 22, user: "nvidia", hostKey: FakeSpaceSpark.hostKey)

  // MARK: - SSH keys

  func testOpenSSHPrivateKeyRoundTripsAndSSHKeygenReadsIt() throws {
    let key = SSHEd25519Key()
    let pem = key.openSSHPrivateKey(comment: "mindloom-test")
    let parsed = try XCTUnwrap(SSHEd25519Key.parse(openSSH: pem))
    XCTAssertEqual(parsed.seed, key.seed)
    XCTAssertTrue(key.authorizedKey.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"))
    XCTAssertEqual(key.publicKeyBase64.count, 68)
    // OpenSSH itself reads the file and derives the same public key and fingerprint.
    let keygen = "/usr/bin/ssh-keygen"
    guard FileManager.default.isExecutableFile(atPath: keygen) else {
      throw XCTSkip("ssh-keygen not installed")
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mlkey-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("id")
    try SSHGateRoute.writePrivate(Data(pem.utf8), to: file, exclusive: true)
    func run(_ args: [String]) throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: keygen)
      process.arguments = args
      let out = Pipe()
      process.standardOutput = out
      process.standardError = FileHandle.nullDevice
      try process.run()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0)
      return String(decoding: data, as: UTF8.self)
    }
    let derived = try run(["-y", "-f", file.path]).split(separator: " ").prefix(2).joined(
      separator: " ")
    XCTAssertEqual(derived, key.authorizedKey)
    let fingerprint = try run(["-l", "-f", file.path]).split(separator: " ")[1]
    XCTAssertEqual(String(fingerprint), key.fingerprint)
    var info = stat()
    XCTAssertEqual(stat(file.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o600)
  }

  func testParsingRefusesOtherKeysAndDamage() {
    let pem = SSHEd25519Key().openSSHPrivateKey()
    XCTAssertNil(SSHEd25519Key.parse(openSSH: pem.replacingOccurrences(of: "BEGIN", with: "START")))
    var lines = pem.split(separator: "\n").map(String.init)
    lines[1] = String(lines[1].reversed())
    XCTAssertNil(SSHEd25519Key.parse(openSSH: lines.joined(separator: "\n")))
  }

  // MARK: - The gate's HTTP framing

  func testRequestsCarryContentLengthAndNoInjectedHeaders() {
    let bytes = HTTPBridgeCodec.encode(
      method: "POST", target: "/v1/spaces/x/ops",
      headers: [("Authorization", "Bearer mlacc1.a.b"), ("X-Evil", "a\r\nX-Injected: 1")],
      body: Data("{}".utf8))
    let text = String(decoding: bytes, as: UTF8.self)
    XCTAssertTrue(text.hasPrefix("POST /v1/spaces/x/ops HTTP/1.1\r\nHost: organizer\r\n"))
    XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
    XCTAssertFalse(text.contains("\r\nX-Injected"))
    XCTAssertFalse(text.lowercased().contains("transfer-encoding"))
    XCTAssertTrue(text.hasSuffix("\r\n\r\n{}"))
  }

  func testResponsesWithLengthChunkedAndKeepAliveParseAtAnySplit() throws {
    let first =
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}"
    let second =
      "HTTP/1.1 403 Forbidden\r\nTransfer-Encoding: chunked\r\n\r\n6\r\n{\"erro\r\n12\r\nr\":\"gate_refused\"}\r\n0\r\n\r\n"
    let stream = Data((first + second).utf8)
    for split in 1..<stream.count {
      var parser = HTTPBridgeCodec.ResponseParser()
      parser.feed(stream.prefix(split))
      var got: [HTTPBridgeCodec.Response] = []
      while let response = try parser.next() { got.append(response) }
      parser.feed(stream.dropFirst(split))
      while let response = try parser.next() { got.append(response) }
      XCTAssertEqual(got.count, 2, "split at \(split)")
      XCTAssertEqual(got.first?.status, 200)
      XCTAssertEqual(got.first.map { String(decoding: $0.body, as: UTF8.self) }, "{\"ok\":true}")
      XCTAssertEqual(got.last?.status, 403)
      XCTAssertEqual(
        got.last.map { String(decoding: $0.body, as: UTF8.self) }, "{\"error\":\"gate_refused\"}")
      XCTAssertEqual(got.map(\.closes), [false, false])
    }
  }

  func testCloseDelimitedAndMalformedResponses() throws {
    var parser = HTTPBridgeCodec.ResponseParser()
    parser.feed(
      Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n{\"error\":\"bad\"}".utf8))
    XCTAssertNil(try parser.next())
    parser.finish()
    let last = try XCTUnwrap(parser.next())
    XCTAssertEqual(last.status, 400)
    XCTAssertTrue(last.closes)
    var broken = HTTPBridgeCodec.ResponseParser()
    broken.feed(Data("SSH-2.0-OpenSSH\r\n\r\n".utf8))
    XCTAssertThrowsError(try broken.next())
    var truncated = HTTPBridgeCodec.ResponseParser()
    truncated.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8))
    truncated.finish()
    XCTAssertThrowsError(try truncated.next())
  }

  func testRouteArgumentsPinTheHostKeyAndUseOnlyTheGivenKey() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mlroute-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let relay = SpaceInviteCode.Endpoint(
      host: "relay.test", port: 2222, user: "jump", hostKey: FakeSpaceSpark.hostKey)
    let route = SSHGateRoute(spark: Self.spark, relay: relay, workDirectory: dir)
    let key = try route.materialize(SSHEd25519Key())
    let relayKey = try route.materialize(SSHEd25519Key())
    let args = try route.arguments(command: "bridge", keyFile: key, relayKeyFile: relayKey)
    XCTAssertEqual(Array(args.suffix(4)), ["-p", "22", "nvidia@spark.test", "bridge"])
    for option in [
      "BatchMode=yes", "IdentitiesOnly=yes", "IdentityAgent=none", "StrictHostKeyChecking=yes",
      "HostKeyAlias=mindloom-spark", "ClearAllForwardings=yes", "ForwardAgent=no",
    ] {
      XCTAssertTrue(args.contains(option), option)
    }
    XCTAssertEqual(args.first, "-F")
    XCTAssertEqual(args[1], "/dev/null")
    let proxy = try XCTUnwrap(args.first { $0.hasPrefix("ProxyCommand=") })
    XCTAssertTrue(proxy.contains("-W %h:%p jump@relay.test"))
    XCTAssertTrue(proxy.contains("HostKeyAlias=mindloom-relay"))
    let knownHosts = try String(contentsOf: route.knownHosts, encoding: .utf8)
    XCTAssertTrue(knownHosts.contains("mindloom-spark ssh-ed25519 "))
    XCTAssertTrue(knownHosts.contains("mindloom-relay ssh-ed25519 "))
    var info = stat()
    XCTAssertEqual(stat(dir.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o700)
    // An endpoint that could become an ssh option is refused.
    let bad = SSHGateRoute(
      spark: .init(
        host: "-oProxyCommand=x", port: 22, user: "nvidia", hostKey: FakeSpaceSpark.hostKey),
      relay: nil, workDirectory: dir)
    XCTAssertThrowsError(try bad.arguments(command: "bridge", keyFile: key, relayKeyFile: nil))
  }

  // MARK: - Invite codes

  func testInviteCodeRoundTripsAndRefusesExpiredOrDamagedCodes() throws {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let key = SSHEd25519Key()
    let code = AccessInviteCode(
      kind: .member, spark: Self.spark, relay: nil, ticketID: SpaceID.new(), key: key,
      secret: SpaceCrypto.randomKey(), expiresAt: now.addingTimeInterval(3_600), memberID: nil,
      team: "B203 实验室", space: nil)
    let text = try code.encoded()
    XCTAssertTrue(text.hasPrefix("mlteam1."))
    let decoded = try AccessInviteCode.decode(text, now: now)
    XCTAssertEqual(decoded, code)
    XCTAssertEqual(decoded.ticketKey?.seed, key.seed)
    XCTAssertThrowsError(try AccessInviteCode.decode(text, now: now.addingTimeInterval(7_200)))
    XCTAssertThrowsError(try AccessInviteCode.decode(text.dropLast(3) + "AAA", now: now))
    // A device ticket must name the member; a member ticket must not.
    let device = AccessInviteCode(
      kind: .device, spark: Self.spark, relay: nil, ticketID: SpaceID.new(), key: key,
      secret: SpaceCrypto.randomKey(), expiresAt: now.addingTimeInterval(3_600), memberID: nil,
      team: nil, space: nil)
    XCTAssertThrowsError(try AccessInviteCode.decode(try device.encoded(), now: now))
  }

  // MARK: - Enrollment, member calls, unpairing

  func testEnrollmentGivesThisMacItsOwnCredentialAndUnpairingEndsItAtOnce() async throws {
    let spark = FakeSpaceSpark()
    let owner = AccessClient(
      client: SpaceClient(transport: spark, device: .generate(), now: { spark.now }))
    let (code, ticketKey) = try await TeamAccess.makeInvite(
      access: owner, kind: .member, spark: Self.spark, relay: nil, team: "B203", space: nil,
      now: spark.now)
    // The Spark holds the ticket's public key and the secret's hash only.
    XCTAssertEqual(spark.ticketKeys(), [ticketKey.publicKeyBase64])
    let wire = String(decoding: spark.everythingReceived, as: UTF8.self)
    XCTAssertFalse(wire.contains(code.secret))
    XCTAssertFalse(wire.contains(code.key))
    let device = SpaceDeviceKeys.generate()
    let store = MemoryMemberAccessStore()
    let member = SpaceID.new()
    let record = try await TeamAccess.enroll(
      code: try AccessInviteCode.decode(try code.encoded(), now: spark.now), device: device,
      memberID: member, store: store, now: spark.now
    ) { key, request in spark.enroll(ticketKey: key.authorizedKey, request: request) }
    XCTAssertEqual(record.memberID, member)
    XCTAssertEqual(record.deviceID, device.deviceID)
    XCTAssertTrue(record.isUsable)
    XCTAssertEqual(try store.load(), record)
  }

  func testEnrollmentRefusalsAndMemberCalls() async throws {
    let spark = FakeSpaceSpark()
    let owner = AccessClient(
      client: SpaceClient(transport: spark, device: .generate(), now: { spark.now }))
    let (code, _) = try await TeamAccess.makeInvite(
      access: owner, kind: .member, spark: Self.spark, relay: nil, team: nil, space: nil,
      now: spark.now)
    let device = SpaceDeviceKeys.generate()
    let record = try await TeamAccess.enroll(
      code: code, device: device, memberID: SpaceID.new(), store: MemoryMemberAccessStore(),
      now: spark.now
    ) { key, request in spark.enroll(ticketKey: key.authorizedKey, request: request) }
    do {
      _ = try await TeamAccess.enroll(
        code: code, device: .generate(), memberID: SpaceID.new(), store: MemoryMemberAccessStore(),
        now: spark.now
      ) { key, request in spark.enroll(ticketKey: key.authorizedKey, request: request) }
      XCTFail("a used ticket enrolled again")
    } catch TeamAccess.TeamError.refused(let code) {
      XCTAssertEqual(code, "ticket_closed")
    }
    // A wrong secret is refused.
    let (fresh, _) = try await TeamAccess.makeInvite(
      access: owner, kind: .member, spark: Self.spark, relay: nil, team: nil, space: nil,
      now: spark.now)
    let wire = try SpaceJSON.decode(try JSONEncoder().encode(fresh)).setting(
      "secret", .string(Base64URL.encode(SpaceCrypto.randomKey())))
    let tampered = try JSONDecoder().decode(AccessInviteCode.self, from: try wire.encoded())
    do {
      _ = try await TeamAccess.enroll(
        code: tampered, device: .generate(), memberID: SpaceID.new(),
        store: MemoryMemberAccessStore(), now: spark.now
      ) { key, request in spark.enroll(ticketKey: key.authorizedKey, request: request) }
      XCTFail("a wrong secret enrolled")
    } catch TeamAccess.TeamError.refused(let code) {
      XCTAssertEqual(code, "bad_secret")
    }
    // The member reaches the access routes with its own credential.
    let member = AccessClient(
      client: SpaceClient(
        transport: spark.credentialTransport(record.credential), device: device,
        now: { spark.now }))
    let me = try await member.me()
    XCTAssertEqual(me.caller, "member")
    XCTAssertEqual(me.access?.memberID, record.memberID)
    XCTAssertFalse(me.mayInvite)
    do {
      _ = try await member.health()
      XCTFail("a plain member read the Spark's health")
    } catch let error as SpaceClientError {
      XCTAssertEqual(error.serverCode, "forbidden")
    }
    let health = try await owner.health()
    XCTAssertEqual(health.warnings, ["memory_low"])
    XCTAssertEqual(health.gpu?.unifiedMemory?.totalMiB, 124_610)
    // The owner unpairs it; the credential stops at once.
    let removed = try await owner.unpair(record.accessID)
    XCTAssertEqual(removed, 1)
    do {
      _ = try await member.me()
      XCTFail("an unpaired credential still worked")
    } catch let error as SpaceClientError {
      XCTAssertEqual(error.serverCode, "bad_credential")
    }
    let audit = try await owner.audit()
    XCTAssertEqual(
      audit.entries.map(\.action),
      ["access.ticket", "access.enroll", "access.ticket", "access.revoke"])
    XCTAssertEqual(TeamAccess.message("bad_secret"), "邀请码不对")
  }

  func testMemberAccessRecordSurvivesTheFileStoreAndIsSecret() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mlacc-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let secrets = try FileSpaceSecretStore(directory: dir, allowed: { true })
    let store = FileMemberAccessStore(secrets: secrets)
    let accessID = SpaceID.new()
    let record = MemberAccessRecord(
      accessID: accessID, memberID: SpaceID.new(), deviceID: SpaceID.new(),
      credential: "mlacc1.\(accessID).\(Base64URL.encode(SpaceCrypto.randomKey()))",
      key: SSHEd25519Key(), relayKey: nil, spark: Self.spark, relay: nil, fingerprint: nil,
      pairedAt: Date(timeIntervalSince1970: 1_790_000_000), team: "B203")
    try store.save(record)
    XCTAssertEqual(try store.load(), record)
    var info = stat()
    XCTAssertEqual(stat(dir.appendingPathComponent("member-access.json").path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o600)
    try store.delete()
    XCTAssertNil(try store.load())
  }
}
