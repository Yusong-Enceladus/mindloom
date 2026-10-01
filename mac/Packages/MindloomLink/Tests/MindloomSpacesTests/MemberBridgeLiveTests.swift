import Foundation
import MindloomLink
import XCTest

@testable import MindloomSpaces

/// Opt-in: a member Mac's own way in, against a real Spark instance through
/// its real sshd (v8 B1): the owner's Mac (its own link) makes a ticket; this
/// Mac enrolls through the ticket key, then speaks HTTP over its own
/// `ssh -T … bridge` with its own credential — reads its record, makes an org
/// and a space, shares a 1 MB original, pulls a backup — and is unpaired, after
/// which the Spark's `authorized_keys` is byte-identical to before. Synthetic
/// content only. Skipped unless `MINDLOOM_BRIDGE_LIVE_HOST` (the owner's ssh
/// alias), `_SOCKET`, `_TOKEN_PATH`, `_MEMBER_HOST`, `_MEMBER_USER` are set;
/// `_PROXY` is a ProxyCommand for the member's hop to a Spark behind a relay.
final class MemberBridgeLiveTests: XCTestCase {
  private var forward: Process?

  override func tearDown() {
    forward?.terminate()
    forward?.waitUntilExit()
    forward = nil
  }

  private func env(_ name: String) -> String? {
    ProcessInfo.processInfo.environment["MINDLOOM_BRIDGE_LIVE_\(name)"]
  }

  private func ssh(_ arguments: [String], stdin: Data? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=20"] + arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    if let stdin {
      let input = Pipe()
      process.standardInput = input
      try process.run()
      input.fileHandleForWriting.write(stdin)
      try input.fileHandleForWriting.close()
    } else {
      try process.run()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return data
  }

  func testAMemberMacEnrollsUsesItsOwnBridgeAndIsUnpairedCleanly() async throws {
    guard let host = env("HOST"), let socket = env("SOCKET"), let tokenPath = env("TOKEN_PATH"),
      let memberHost = env("MEMBER_HOST"), let memberUser = env("MEMBER_USER")
    else {
      throw XCTSkip("set MINDLOOM_BRIDGE_LIVE_HOST/_SOCKET/_TOKEN_PATH/_MEMBER_HOST/_MEMBER_USER")
    }
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ ok: Bool) {
      checks.append((name, ok))
      print((ok ? "PASS " : "FAIL ") + name)
    }
    let akBefore = String(
      decoding: try ssh([host, "sha256sum", ".ssh/authorized_keys"]), as: UTF8.self
    ).prefix(64)
    // The owner's own link: a forward to the socket, the token in memory only.
    let token = String(decoding: try ssh([host, "cat", tokenPath]), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let port = Int.random(in: 41_000...48_999)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = [
      "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-L",
      "127.0.0.1:\(port):\(socket)", host,
    ]
    process.standardError = FileHandle.nullDevice
    try process.run()
    forward = process
    let ownerTransport = LoopbackSpaceTransport { (port, token) }
    let ownerClient = SpaceClient(transport: ownerTransport, device: .generate())
    var hostKeys: [String] = []
    for _ in 0..<60 {
      if let keys = try? await ownerClient.hostKeys() {
        hostKeys = keys
        break
      }
      try await Task.sleep(for: .milliseconds(500))
    }
    let hostKey = try XCTUnwrap(hostKeys.first { $0.hasPrefix("ssh-ed25519 ") })
    let owner = AccessClient(client: ownerClient)
    let spark = SpaceInviteCode.Endpoint(
      host: memberHost, port: 22, user: memberUser, hostKey: hostKey)
    let work = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mlbridge-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: work) }
    let route = SSHGateRoute(
      spark: spark, relay: nil, workDirectory: work, proxyCommandOverride: env("PROXY"))
    let started = Date()
    // 1. A ticket and its invite; enrollment through the ticket key.
    let (code, _) = try await TeamAccess.makeInvite(
      access: owner, kind: .member, spark: spark, relay: nil, team: "合成实验室", space: nil)
    let device = SpaceDeviceKeys.generate()
    let store = MemoryMemberAccessStore()
    let record = try await TeamAccess.enroll(
      code: try AccessInviteCode.decode(try code.encoded()), device: device,
      memberID: SpaceID.new(),
      store: store
    ) { key, request in
      try await SSHGateEnrollment.enroll(route: route, ticketKey: key, request: request)
    }
    check("enrolled through the ticket key", record.isUsable)
    do {
      _ = try await TeamAccess.enroll(
        code: code, device: .generate(), memberID: SpaceID.new(), store: MemoryMemberAccessStore()
      ) { key, request in
        try await SSHGateEnrollment.enroll(route: route, ticketKey: key, request: request)
      }
      check("the ticket key is dead after enrolling", false)
    } catch {
      check("the ticket key is dead after enrolling", true)
    }
    // 2. The member's own bridge: keep-alive, its own credential.
    let bridge = SSHBridgeTransport(route: route) {
      guard let current = try store.load(), let key = current.key else {
        throw SpaceClientError.transport
      }
      return (current.credential, key, current.relayKey)
    }
    let memberClient = SpaceClient(transport: bridge, device: device)
    let member = AccessClient(client: memberClient)
    let me = try await member.me()
    check("bridge: /v1/access/me is this Mac", me.access?.accessID == record.accessID)
    do {
      _ = try await memberClient.send("GET", "/v1/state", signed: false)
      check("bridge: the owner's store is refused", false)
    } catch let error as SpaceClientError {
      check("bridge: the owner's store is refused", error.serverCode == "gate_refused")
    }
    do {
      _ = try await member.health()
      check("bridge: health refused to a plain member", false)
    } catch let error as SpaceClientError {
      check("bridge: health refused to a plain member", error.serverCode == "forbidden")
    }
    // 3. As an org admin through the bridge: health, a space, a 1 MB original, a backup.
    let states = MemorySpaceStateStore()
    let keys = MemorySpaceKeyStore()
    let engine = SpaceEngine(client: memberClient, states: states, keys: keys)
    try await engine.setMemberIdentity(record.memberID)
    let org = try await engine.createOrg()
    let health = try await member.health()
    check("bridge: health for an org admin", health.models.contains { $0.role == "chat" })
    let space = try await engine.createSpace(
      name: "合成：门禁冒烟", owner: .org, orgID: org.orgID, orgMemberID: org.memberID,
      displayName: "合成成员", spark: spark)
    let item = SpaceID.new()
    let original = Data((0..<(1 << 20)).map { UInt8($0 % 251) })
    let report = try await engine.share(
      space.spaceID,
      items: [
        SpaceOutgoingItem(
          itemID: item, kind: "document",
          fields: SpaceItemFields(kind: "document", title: "合成文件", text: "合成：门禁冒烟素材"),
          originals: [("original", original)])
      ])
    check("bridge: share with a 1 MB original", report.shared == [item])
    let state = try await engine.sync(space.spaceID)
    if let blob = state.items[item]?.blobs.first {
      let back = try await engine.original(space.spaceID, itemID: item, blob: blob)
      check("bridge: the original comes back", back == original)
    }
    let (stream, receipt) = try await engine.backup(space.spaceID)
    check("bridge: a backup streamed and opens", receipt.blobs == 1 && stream.count > (1 << 20))
    let sessions = await bridge.sessionsOpened
    check("bridge: one long session for every call", sessions == 1)
    // 4. Unpaired: the next request is refused; the key file is as before.
    let removed = try await owner.unpair(record.accessID)
    check("unpaired", removed == 1)
    do {
      _ = try await member.me()
      check("the credential stops at once", false)
    } catch {
      check("the credential stops at once", true)
    }
    await bridge.close()
    let akAfter = String(
      decoding: try ssh([host, "sha256sum", ".ssh/authorized_keys"]), as: UTF8.self
    ).prefix(64)
    check("authorized_keys byte-identical", akAfter == akBefore && akBefore.count == 64)
    let failed = checks.filter { !$0.1 }.map(\.0)
    print(
      "BRIDGE-LIVE \(checks.count - failed.count)/\(checks.count) in \(Int(Date().timeIntervalSince(started))) s; ak \(akBefore.prefix(16))"
    )
    XCTAssertEqual(failed, [])
  }
}
