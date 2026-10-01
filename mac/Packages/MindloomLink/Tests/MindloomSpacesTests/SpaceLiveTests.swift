import Foundation
import MindloomLink
import MindloomSpacesTestSupport
import XCTest

@testable import MindloomSpaces

/// Opt-in: the member flows against a real Spark instance through the
/// user's own SSH (a forward to the organizer's socket; the link token read
/// over SSH into this process's memory only). Two simulated Macs, synthetic
/// content only. Skipped unless `MINDLOOM_SPACES_LIVE_HOST` (an ssh alias),
/// `MINDLOOM_SPACES_LIVE_SOCKET` and `MINDLOOM_SPACES_LIVE_TOKEN_PATH` are set.
final class SpaceLiveTests: XCTestCase {
  struct Live {
    let host: String
    let socket: String
    let tokenPath: String
    let dataDir: String?
  }

  private var forward: Process?

  override func tearDown() {
    forward?.terminate()
    forward?.waitUntilExit()
    forward = nil
  }

  private func live() throws -> Live {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["MINDLOOM_SPACES_LIVE_HOST"],
      let socket = env["MINDLOOM_SPACES_LIVE_SOCKET"],
      let token = env["MINDLOOM_SPACES_LIVE_TOKEN_PATH"]
    else { throw XCTSkip("set MINDLOOM_SPACES_LIVE_HOST / _SOCKET / _TOKEN_PATH to run") }
    for value in [host, socket, token] {
      guard value.range(of: "^[A-Za-z0-9_./~-]+$", options: .regularExpression) != nil else {
        throw XCTSkip("unexpected characters in the live configuration")
      }
    }
    return Live(
      host: host, socket: socket, tokenPath: token, dataDir: env["MINDLOOM_SPACES_LIVE_DATA_DIR"])
  }

  private func run(_ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15"] + arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return data
  }

  /// The forward and the token (in memory only).
  private func connect(_ live: Live) async throws -> LoopbackSpaceTransport {
    let token = String(decoding: try run([live.host, "cat", live.tokenPath]), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertFalse(token.isEmpty, "no link token")
    let port = Int.random(in: 41_000...48_999)
    let socket = live.socket.hasPrefix("~/") ? live.socket : live.socket
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = [
      "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-L",
      "127.0.0.1:\(port):\(socket)", live.host,
    ]
    process.standardError = FileHandle.nullDevice
    try process.run()
    forward = process
    let transport = LoopbackSpaceTransport { (port, token) }
    let probe = SpaceClient(transport: transport, device: .generate())
    for _ in 0..<60 {
      if (try? await probe.hostKeys()) != nil { return transport }
      try await Task.sleep(for: .milliseconds(500))
    }
    throw XCTSkip("the forward did not come up")
  }

  func testTwoMacsOnARealSpark() async throws {
    let live = try live()
    let transport = try await connect(live)
    let marker = "LIVE-\(UUID().uuidString.prefix(8))"
    let spaceName = "咖啡馆筹备-\(marker)"
    func mac() -> (SpaceEngine, MemorySpaceKeyStore) {
      let keys = MemorySpaceKeyStore()
      let engine = SpaceEngine(
        client: SpaceClient(transport: transport, device: .generate()),
        states: MemorySpaceStateStore(), keys: keys)
      return (engine, keys)
    }
    let (a, aKeys) = mac()
    let (b, bKeys) = mac()
    var checks: [String: Bool] = [:]

    // 1. A creates an org space and invites B; the invite pins the Spark's host key.
    let hostKeys = try await a.client.hostKeys()
    let hostKey = try XCTUnwrap(hostKeys.first { $0.hasPrefix("ssh-ed25519 ") })
    let endpoint = SpaceInviteCode.Endpoint(host: live.host, port: 22, user: nil, hostKey: hostKey)
    let org = try await a.createOrg()
    let created = try await a.createSpace(
      name: spaceName, owner: .org, orgID: org.orgID, orgMemberID: org.memberID,
      displayName: "林知远\(marker)", spark: endpoint)
    let spaceID = created.spaceID
    let code = try await a.invite(spaceID, role: .write, hostKey: hostKey, spark: endpoint)
    let decoded = try SpaceInviteCode.decode(try code.encoded())
    _ = try await b.join(
      code: decoded, displayName: "韩策\(marker)", localHostKey: hostKey)
    let requests = try await a.joinRequests(spaceID)
    let request = try XCTUnwrap(requests.first)
    checks["sealed name opens on A"] = request.displayName == "韩策\(marker)"
    checks["fingerprints match"] = request.fingerprint == (await b.device).fingerprint
    try await a.approve(spaceID, request: request)
    let bJoined = try await b.refreshJoin(spaceID)
    checks["B joined"] = bJoined.membership == .active && bJoined.role == .write

    // 2. Both share their version of the same matter.
    let a1 = SpaceID.new()
    let a2 = SpaceID.new()
    let b1 = SpaceID.new()
    let b2 = SpaceID.new()
    func fields(_ title: String, _ text: String, _ matter: String, minutes: Int) -> SpaceItemFields
    {
      let started = Date(timeIntervalSince1970: 1_790_000_000 + Double(minutes * 60))
      return SpaceItemFields(
        kind: "text", title: title, text: text, sourceName: "备忘录",
        startedAt: SpaceTime.string(started), originMatterID: matter)
    }
    let original = Data("%PDF-1.4 synthetic lease \(marker)".utf8)
    let aShare = try await a.share(
      spaceID,
      items: [
        SpaceOutgoingItem(
          itemID: a1, kind: "text",
          fields: fields(
            "租约", "拾光咖啡馆开业筹备：店面租约 9 月 26 日签，房东电话 13812345678（\(marker)）", "matter-a",
            minutes: 0), originals: [("original", original)]),
        SpaceOutgoingItem(
          itemID: a2, kind: "text",
          fields: fields("开业日期", "拾光咖啡馆开业筹备：开业定在 10 月 8 日，先试营业三天。", "matter-a", minutes: 30)),
      ], package: SpacePackageRequest(auto: .ask, matterID: "matter-a", title: "拾光咖啡馆开业筹备"))
    let bShare = try await b.share(
      spaceID,
      items: [
        SpaceOutgoingItem(
          itemID: b1, kind: "text",
          fields: fields("装修", "拾光咖啡馆开业筹备：装修报价 3 万，9 月 30 日前完工。", "matter-b", minutes: 60)),
        SpaceOutgoingItem(
          itemID: b2, kind: "text",
          fields: fields("咖啡豆", "拾光咖啡馆开业筹备：咖啡豆供应商定了云南的那家，首批 20 公斤。", "matter-b", minutes: 90)),
      ])
    checks["all four shared"] = aShare.shared.count == 2 && bShare.shared.count == 2

    // Both read each other's items, numbers as they are, and the original.
    let bState = try await b.sync(spaceID)
    let aState = try await a.sync(spaceID)
    checks["B reads A with the number"] =
      bState.items[a1]?.fields?.text?.contains("13812345678") == true
    checks["A reads B"] = aState.items[b1]?.fields?.text?.contains("装修报价") == true
    if let blob = bState.items[a1]?.blobs.first {
      checks["B opens A's original"] =
        (try? await b.original(spaceID, itemID: a1, blob: blob)) == original
    }
    checks["names known"] =
      aState.name(of: bState.memberID) == "韩策\(marker)"
      && bState.name(of: aState.memberID) == "林知远\(marker)" && bState.name == spaceName

    // 3. The space organizer assembles one matter from both members' items.
    let builder = RecordingPayloadBuilder()
    var assembled = false
    let deadline = Date().addingTimeInterval(240)
    while Date() < deadline {
      _ = try await a.organize(spaceID, builder: builder)
      let state = try await a.state(spaceID)
      if let organizer = state?.organizer, let json = try? SpaceJSON.decode(organizer.state),
        let events = json["events"]?.array,
        events.contains(where: { event in
          let ids = Set((event["item_ids"]?.array ?? []).compactMap { $0.string?.lowercased() })
          return [a1, a2, b1, b2].allSatisfy(ids.contains)
        }), Set(organizer.sameAs.map(\.matterID)).isSuperset(of: ["matter-a", "matter-b"])
      {
        assembled = true
        checks["state has placeholders only"] = !String(decoding: organizer.state, as: UTF8.self)
          .contains("13812345678")
        break
      }
      try await Task.sleep(for: .seconds(5))
    }
    checks["one matter holds the union"] = assembled

    // 4. B withdraws one item; A removes B.
    try await b.withdraw(spaceID, itemID: b2)
    let afterWithdraw = try await a.sync(spaceID)
    checks["withdrawn on A"] = afterWithdraw.items[b2]?.status == .withdrawn
    let epoch1 = try XCTUnwrap(bKeys.keys(spaceID)[1])
    try await a.removeMember(spaceID, memberID: bState.memberID)

    // 5. Rotation: the next item is epoch 2; B can no longer read.
    let a3 = SpaceID.new()
    _ = try await a.share(
      spaceID,
      items: [
        SpaceOutgoingItem(
          itemID: a3, kind: "text",
          fields: fields("移除后", "移除之后的新条目（\(marker)）", "matter-a", minutes: 120))
      ])
    let keys = try await a.client.itemKeys(spaceID, itemIDs: [a3])
    let entry = try XCTUnwrap(keys.items.first)
    checks["new item at epoch 2"] = entry.epoch == 2
    checks["B's epoch-1 key cannot open it"] =
      (try? SpaceCrypto.unwrapItemKey(
        entry.wrappedDK, spaceKey: epoch1, spaceID: spaceID, epoch: 2, itemID: a3)) == nil
    do {
      _ = try await b.sync(spaceID)
      checks["B refused"] = false
    } catch SpaceClientError.accessEnded {
      checks["B refused"] = true
    }
    checks["B's copy deleted"] = (try await b.state(spaceID)) == nil
    let rekey = try await a.organize(spaceID, builder: builder)
    checks["store re-keyed"] = rekey.rekeyed
    let finalState = try await a.state(spaceID)
    checks["B's other item stays attributed"] =
      finalState?.items[b1]?.isActive == true
      && finalState?.items[b1]?.contributor == bState.memberID
    _ = aKeys
    await a.lockOrganizer(spaceID)

    // 6. Nothing readable on the Spark.
    if let dataDir = live.dataDir {
      let hits = String(
        decoding: try run([live.host, "grep", "-rlaF", marker, dataDir, "||", "true"]),
        as: UTF8.self
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      checks["no plaintext on the Spark"] = hits.isEmpty
      let phone = String(
        decoding: try run([
          live.host, "grep", "-rlaF", "13812345678", dataDir + "/spaces", "||", "true",
        ]),
        as: UTF8.self
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      checks["no number on the Spark"] = phone.isEmpty
    }
    let failed = checks.filter { !$0.value }.map(\.key).sorted()
    print(
      "SPACES-LIVE \(checks.count - failed.count)/\(checks.count) checks pass; space \(spaceID)")
    XCTAssertEqual(failed, [], "failed checks")
  }
}
