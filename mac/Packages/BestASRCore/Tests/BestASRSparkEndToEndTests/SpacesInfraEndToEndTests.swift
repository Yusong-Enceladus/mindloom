import BestASRDomain
import BestASRRemoteOrganizer
import Foundation
import MindloomLink
import MindloomSpaces
import XCTest

/// Opt-in end-to-end run of v8 contracts B and C on the Mac against one real
/// Spark instance and its real model: the two-member spaces run extended with
/// what a lab needs. A is the Spark owner's Mac (its own link); B is a
/// teammate whose Mac enrolls with its own key and reaches the Spark only
/// through the gate's bridge on the real sshd; B2 is B's second Mac. Three
/// synthetic data roots, file-kept secrets (synthetic roots only). Steps:
/// per-member access, a meeting part's audio shared to members (ciphertext on
/// the Spark, opened and length-checked on B's Macs), B's second Mac added and
/// retired with a new key, a share made while B's link is down sent once, a
/// handover pack written by the Spark's model and given as a snapshot with the
/// matter, the snapshot leaving with an item it cites, a backup → restore drill,
/// plaintext scans of the Spark, and every Mac unpaired with
/// `authorized_keys` byte-identical to before.
///
/// Skipped unless `BESTASR_E2E_SPACES_HOST`, `_SOCKET_PATH`, `_TOKEN_PATH`,
/// `BESTASR_E2E_INFRA_MEMBER_HOST` and `_MEMBER_USER` are set;
/// `BESTASR_E2E_INFRA_PROXY` is the ProxyCommand of the member's hop when the
/// Spark sits behind a relay; `BESTASR_E2E_SPACES_DATA_DIR` adds the scans;
/// `BESTASR_E2E_INFRA_EVIDENCE` writes a JSON summary (check names, counts).
@MainActor
final class SpacesInfraEndToEndTests: XCTestCase {
  static let sentinel = "QZXV-V8-INFRA-SENTINEL"

  /// A transport the test can cut (the link is down).
  final class SwitchableTransport: SpaceTransport, @unchecked Sendable {
    let inner: any SpaceTransport
    private let lock = NSLock()
    private var down = false
    private var log: [(target: String, body: Data)] = []

    init(_ inner: any SpaceTransport) { self.inner = inner }

    func set(down: Bool) { lock.withLock { self.down = down } }

    func send(_ request: SpaceHTTPRequest) async throws -> SpaceHTTPResponse {
      let isDown = lock.withLock {
        log.append((request.target, request.body ?? Data()))
        return down
      }
      if isDown { throw SpaceClientError.transport }
      return try await inner.send(request)
    }

    /// Every request body, and those outside the organizing payloads (the
    /// only place the Spark reads text, masked, under a member's lease).
    var sent: Data { lock.withLock { log.map(\.body).reduce(Data(), +) } }
    var sentOutsideOrganizing: Data {
      lock.withLock {
        log.filter { !$0.target.contains("/organizer/items") }.map(\.body).reduce(Data(), +)
      }
    }
  }

  struct Member {
    let root: URL
    let stores: SpaceStores
    let device: SpaceDeviceKeys
    let engine: SpaceEngine
    let access: AccessClient
    let wire: SwitchableTransport
    let bridge: SSHBridgeTransport?
  }

  private var link: SpacesEndToEndTests.SpaceLink?
  private var roots: [URL] = []
  private var bridges: [SSHBridgeTransport] = []

  override func tearDown() async throws {
    for bridge in bridges { await bridge.close() }
    bridges = []
    link?.close()
    link = nil
    for root in roots { try? FileManager.default.removeItem(at: root) }
    roots = []
  }

  private func env(_ name: String) -> String? { ProcessInfo.processInfo.environment[name] }

  private func ssh(_ host: String, _ command: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=20", host, command]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }

  private func root(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-infra-e2e-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: root.appendingPathComponent(RemoteOrganizerDataProvenance.syntheticMarkerFileName)
        .path, contents: Data())
    roots.append(root)
    return root
  }

  /// A Mac on the owner's link (A).
  private func ownerMac(_ live: RemoteOrganizerLinkConfiguration, real: URL) throws -> Member {
    let root = try root("a")
    let stores = try SpaceStores.synthetic(dataRoot: root, realLibraryRoot: real)
    let device = try stores.loadOrCreateDevice()
    let link = SpacesEndToEndTests.SpaceLink(live, state: root.appendingPathComponent("link-state"))
    self.link = link
    let wire = SwitchableTransport(LoopbackSpaceTransport { try await link.endpoint() })
    let client = SpaceClient(transport: wire, device: device)
    return Member(
      root: root, stores: stores, device: device,
      engine: SpaceEngine(
        client: client, states: stores.states, keys: stores.keys, outbox: stores.outbox),
      access: AccessClient(client: client), wire: wire, bridge: nil)
  }

  /// A member's Mac: enrolls with a team invite through the gate, then uses
  /// its own bridge for everything.
  private func memberMac(
    _ name: String, code: AccessInviteCode, real: URL, proxy: String?
  ) async throws -> (Member, MemberAccessRecord) {
    let root = try root(name)
    let stores = try SpaceStores.synthetic(dataRoot: root, realLibraryRoot: real)
    let device = try stores.loadOrCreateDevice()
    let gate = try XCTUnwrap(stores.gateDirectory)
    let route = SSHGateRoute(
      spark: code.spark, relay: code.relay, workDirectory: gate, proxyCommandOverride: proxy)
    let record = try await TeamAccess.enroll(
      code: code, device: device, memberID: SpaceID.new(), store: stores.access
    ) { key, request in
      try await SSHGateEnrollment.enroll(route: route, ticketKey: key, request: request)
    }
    let store = stores.access
    let bridge = SSHBridgeTransport(route: route) {
      guard let current = try store.load(), let key = current.key else {
        throw SpaceClientError.transport
      }
      return (current.credential, key, current.relayKey)
    }
    bridges.append(bridge)
    let wire = SwitchableTransport(bridge)
    let client = SpaceClient(transport: wire, device: device)
    let engine = SpaceEngine(
      client: client, states: stores.states, keys: stores.keys, outbox: stores.outbox)
    try await engine.setMemberIdentity(record.memberID)
    return (
      Member(
        root: root, stores: stores, device: device, engine: engine,
        access: AccessClient(client: client), wire: wire, bridge: bridge), record
    )
  }

  private static func fields(_ title: String, _ text: String, minutes: Int) -> SpaceItemFields {
    SpaceItemFields(
      kind: "text", title: title, text: text, sourceName: "备忘录",
      startedAt: SpaceTime.string(Date(timeIntervalSince1970: 1_790_000_000 + Double(minutes * 60)))
    )
  }

  /// 20 s of a tone with a 3 s pause, on a recording clock starting at `start`.
  private static func recording(start: UInt64) -> [SpaceAudioPart.Chunk] {
    func tone(_ seconds: Int, _ hz: Double) -> [Float] {
      (0..<(48_000 * seconds)).map { Float(sin(Double($0) * 2 * .pi * hz / 48_000) * 0.25) }
    }
    return [
      .init(
        startNS: start + 55_000_000_000, endNS: start + 70_000_000_000, sampleRate: 48_000,
        mono: tone(15, 330)),
      .init(
        startNS: start + 73_000_000_000, endNS: start + 90_000_000_000, sampleRate: 48_000,
        mono: tone(17, 440)),
    ]
  }

  func testATeamOnTheSparkWithItsOwnKeysAudioPartsASecondMacHandoverAndABackupDrill()
    async throws
  {
    guard let host = env("BESTASR_E2E_SPACES_HOST"),
      let socket = env("BESTASR_E2E_SPACES_SOCKET_PATH"),
      let token = env("BESTASR_E2E_SPACES_TOKEN_PATH"),
      let memberHost = env("BESTASR_E2E_INFRA_MEMBER_HOST"),
      let memberUser = env("BESTASR_E2E_INFRA_MEMBER_USER")
    else {
      throw XCTSkip(
        "Set BESTASR_E2E_SPACES_HOST/_SOCKET_PATH/_TOKEN_PATH and BESTASR_E2E_INFRA_MEMBER_HOST/_MEMBER_USER to run."
      )
    }
    let proxy = env("BESTASR_E2E_INFRA_PROXY")
    let dataDir = env("BESTASR_E2E_SPACES_DATA_DIR")
    let logDir =
      env("BESTASR_E2E_SPACES_LOG_DIR")
      ?? dataDir.map { ($0 as NSString).deletingLastPathComponent + "/logs" }
    let started = Date()
    var timings: [String: Int] = [:]
    func lap(_ name: String) { timings[name] = Int(Date().timeIntervalSince(started)) }
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ ok: Bool) {
      checks.append((name, ok))
      print((ok ? "PASS " : "FAIL ") + name)
    }
    let real = try root("real")
    let akBefore = try ssh(host, "sha256sum .ssh/authorized_keys | cut -c1-64").trimmingCharacters(
      in: .whitespacesAndNewlines)
    var accessIDs: [String] = []
    var audioBytes = Data()
    let a = try ownerMac(
      try RemoteOrganizerLinkConfiguration(
        host: host, remoteSocketPath: socket, remoteTokenPath: token),
      real: real)
    defer { _ = accessIDs }
    do {
      // ---- 1. A (the Spark owner's Mac) makes an org space; B joins with its own key ----------------
      let hostKeys = try await a.engine.client.hostKeys()
      let hostKey = try XCTUnwrap(hostKeys.first { $0.hasPrefix("ssh-ed25519 ") })
      let spark = SpaceInviteCode.Endpoint(
        host: memberHost, port: 22, user: memberUser, hostKey: hostKey)
      let org = try await a.engine.createOrg()
      let space = try await a.engine.createSpace(
        name: "合成：Twin-7 复测", owner: .org, orgID: org.orgID, orgMemberID: org.memberID,
        displayName: "林知远", spark: .init(host: memberHost, port: 22, user: nil, hostKey: hostKey))
      let id = space.spaceID
      let spaceInvite = try await a.engine.invite(
        id, role: .write, hostKey: hostKey,
        spark: .init(host: memberHost, port: 22, user: nil, hostKey: hostKey))
      let (teamCode, _) = try await TeamAccess.makeInvite(
        access: a.access, kind: .member, spark: spark, relay: nil, team: "合成实验室",
        space: try spaceInvite.encoded())
      let (b, bRecord) = try await memberMac(
        "b", code: try AccessInviteCode.decode(try teamCode.encoded()), real: real, proxy: proxy)
      accessIDs.append(bRecord.accessID)
      check("B enrolled with its own key and credential", bRecord.isUsable)
      let bMe = try await b.access.me()
      check("B's bridge: /v1/access/me is B's Mac", bMe.access?.deviceID == b.device.deviceID)
      do {
        _ = try await b.engine.client.send("GET", "/v1/state", signed: false)
        check("B's bridge refuses the owner's store", false)
      } catch let error as SpaceClientError {
        check("B's bridge refuses the owner's store", error.serverCode == "gate_refused")
      }
      let inner = try SpaceInviteCode.decode(try XCTUnwrap(teamCode.space))
      _ = try await b.engine.join(
        code: inner, displayName: "韩策", localHostKey: bRecord.spark.hostKey)
      let requests = try await a.engine.joinRequests(id)
      let request = try XCTUnwrap(requests.first)
      check(
        "A sees B's name and fingerprint",
        request.displayName == "韩策" && request.fingerprint == b.device.fingerprint)
      try await a.engine.approve(id, request: request)
      let bJoined = try await b.engine.refreshJoin(id)
      check("B joined the space through its bridge", bJoined.membership == .active)
      lap("joined")

      // ---- 2. Shares, and a meeting part's audio for members only ---------------------------------
      var aItems: [String] = []
      for (n, text) in [
        "合成：Twin-7 叠衣服真机复测定在周四下午 B203，\(Self.sentinel)",
        "合成：复测前要把机械臂夹爪换成 TG-2，林知远负责采购，供应商电话 13812345678",
        "合成：复测结果周五前写进周报，韩策汇总",
      ].enumerated() {
        let item = SpaceID.new()
        aItems.append(item)
        _ = try await a.engine.share(
          id,
          items: [
            SpaceOutgoingItem(
              itemID: item, kind: "text", fields: Self.fields("Twin-7 \(n)", text, minutes: n * 10))
          ])
      }
      var bItems: [String] = []
      for (n, text) in ["合成：TG-2 夹爪已下单，下周二到货", "合成：周四复测我来带数据线和标定板"].enumerated() {
        let item = SpaceID.new()
        bItems.append(item)
        let report = try await b.engine.share(
          id,
          items: [
            SpaceOutgoingItem(
              itemID: item, kind: "text", fields: Self.fields("B \(n)", text, minutes: 40 + n))
          ])
        check("B shares through its bridge (\(n))", report.shared == [item])
      }
      let recordingID = SpaceID.new()
      let start: UInt64 = 3_000_000_000
      let segment = SpaceSegmentRef(
        parentItemID: recordingID, startMS: 60_000, endMS: 80_000, recordingMS: 3_600_000)
      let scratch = a.root.appendingPathComponent("audio-scratch", isDirectory: true)
      let audio = try SpaceAudioPart.make(
        Self.recording(start: start), recordingStartNS: start, segment: segment, directory: scratch)
      audioBytes = audio
      let part = SpaceID.segment(parent: recordingID, startMS: 60_000, endMS: 80_000)
      var partFields = Self.fields(
        "组会（1:00–1:20）", "合成：会议里这二十秒在说 Twin-7 的复测安排 \(Self.sentinel)", minutes: 60)
      partFields.kind = "audio_segment"
      partFields.parentKind = "meeting_offline"
      let audioReport = try await a.engine.share(
        id,
        items: [
          SpaceOutgoingItem(
            itemID: part, kind: "audio_segment", fields: partFields, originals: [("audio", audio)],
            segment: segment)
        ])
      check("A shares a meeting part with its audio", audioReport.shared == [part])
      let whole = try await a.engine.share(
        id,
        items: [
          SpaceOutgoingItem(
            itemID: SpaceID.new(), kind: "audio_segment", fields: partFields,
            originals: [("audio", audio)],
            segment: .init(
              parentItemID: SpaceID.new(), startMS: 0, endMS: 20_000, recordingMS: 20_000))
        ])
      check("the whole recording is never shared", whole.refused.values.contains("whole_recording"))
      _ = try await b.engine.sync(id)
      let heard = try await b.engine.audioPart(id, itemID: part)
      let heardMS = try SpaceAudioPart.durationMS(
        of: heard.audio, directory: b.root.appendingPathComponent("audio-scratch"))
      check("B opens the audio part (bytes as sent)", heard.audio == audio)
      check(
        "B's length check passes before playing",
        SpaceAudioCheck.ok(durationMS: heardMS, segment: heard.segment))
      lap("audio")
      if let dataDir {
        let state = try await a.engine.sync(id)
        let blob = try XCTUnwrap(state.items[part]?.audioBlob)
        let path = "\(dataDir)/spaces/\(id)/blobs/\(blob.blobID)"
        check(
          "on the Spark: the audio is a sealed file", try ssh(host, "head -c 4 \(path)") == "MLB1")
        let stored =
          Data(
            base64Encoded: try ssh(host, "base64 -w0 \(path)").trimmingCharacters(
              in: .whitespacesAndNewlines)) ?? Data()
        let window = audio.subdata(in: (audio.count / 2)..<(audio.count / 2 + 48))
        check(
          "on the Spark: the stored audio holds none of the sound's bytes",
          !stored.isEmpty && stored.range(of: window) == nil)
      }

      // ---- 3. B's second Mac: device ticket, added, reads and hears; then retired --------------------
      let (deviceCode, _) = try await TeamAccess.makeInvite(
        access: b.access, kind: .device, spark: bRecord.spark, relay: nil,
        memberID: bRecord.memberID,
        team: nil, space: nil)
      let (b2, b2Record) = try await memberMac("b2", code: deviceCode, real: real, proxy: proxy)
      accessIDs.append(b2Record.accessID)
      check("B2 enrolled under B's member id", b2Record.memberID == bRecord.memberID)
      let toAdd = try await b.access.devices().devices.first { $0.deviceID == b2.device.deviceID }
      check("B's work list: B2 still to add to the space", toAdd?.toAdd?.spaces == [id])
      try await b.engine.addDevice(id, device: try XCTUnwrap(toAdd).publicRecord)
      let adopted = try await b2.engine.adoptSpaces()
      check("B2 takes the space in", adopted == [id])
      let b2State = try await b2.engine.sync(id)
      check(
        "B2 reads A's items", b2State.items[aItems[0]]?.fields?.text?.contains("Twin-7") == true)
      let b2Heard = try await b2.engine.audioPart(id, itemID: part)
      check("B2 opens the audio part too", b2Heard.audio == audio)
      let fromB2 = SpaceID.new()
      _ = try await b2.engine.share(
        id,
        items: [
          SpaceOutgoingItem(
            itemID: fromB2, kind: "text",
            fields: Self.fields("B2", "合成：第二台 Mac 记下的标定参数", minutes: 70))
        ])
      let aSeesB2 = try await a.engine.sync(id)
      check("A reads B2's item as B's", aSeesB2.items[fromB2]?.contributor == bRecord.memberID)
      let removed = try await b.access.unpair(b2Record.accessID)
      check("B unpairs B2", removed == 1)
      let toRemove = try await b.access.devices().devices.first {
        $0.deviceID == b2.device.deviceID
      }
      check("B's work list: B2 still to remove from the space", toRemove?.toRemove?.spaces == [id])
      let epochBefore = try await b.engine.sync(id).epoch
      try await b.engine.retireDevice(id, deviceID: b2.device.deviceID)
      let afterRetire = try await b.engine.sync(id)
      check("retiring B2 rotated the key", afterRetire.epoch == epochBefore + 1)
      check(
        "B2 is out of the signed roster",
        afterRetire.roster?.activeDeviceIDs.contains(b2.device.deviceID) == false)
      do {
        _ = try await b2.engine.sync(id)
        check("B2 cannot reach the Spark any more", false)
      } catch {
        check("B2 cannot reach the Spark any more", true)
      }
      lap("second-mac")

      // ---- 4. A share made while B's link is down waits on disk and goes once --------------------------
      b.wire.set(down: true)
      let offline = SpaceID.new()
      let queued = try await b.engine.share(
        id,
        items: [
          SpaceOutgoingItem(
            itemID: offline, kind: "text", fields: Self.fields("断网", "合成：断网时记下的复测时间", minutes: 80))
        ])
      check("B's share waits while the link is down", queued.queued == [offline])
      let outboxFile = b.root.appendingPathComponent("spaces").appendingPathComponent(id)
        .appendingPathComponent("outbox").appendingPathComponent("outbox.json")
      check("B's outbox is on disk", FileManager.default.fileExists(atPath: outboxFile.path))
      b.wire.set(down: false)
      let flushed = try await b.engine.flushOutbox(id)
      check(
        "B's outbox sent it after reconnecting", flushed.done.values.compactMap { $0 } == [offline])
      let page = try await a.engine.client.ops(id, since: 0, limit: 1000)
      let sharesOfIt = page.ops.filter { entry in
        entry.type == "item.share"
          && (entry.opBytes.flatMap { try? SpaceJSON.decode($0) })?["body"]?["item_id"]?.string
            == offline
      }
      check("the Spark logged it once", sharesOfIt.count == 1)
      lap("outbox")

      // ---- 5. A handover pack written by the Spark's model, given with the matter ----------------------
      var withdrawnCited: String?
      let builder = SpaceOrganizerPayloads()
      var matter: String?
      let organizeDeadline = Date().addingTimeInterval(420)
      while Date() < organizeDeadline, matter == nil {
        _ = try await a.engine.organize(id, builder: builder)
        if let raw = try await a.engine.state(id)?.organizer?.state,
          let json = try? SpaceJSON.decode(raw)
        {
          matter =
            (json["events"]?.array ?? []).first { event in
              let ids = Set((event["item_ids"]?.array ?? []).compactMap { $0.string?.lowercased() })
              return ids.intersection(aItems + bItems).count >= 2
            }?["event_id"]?.string
        }
        if matter == nil { try await Task.sleep(for: .seconds(10)) }
      }
      check("the space organizer made the matter", matter != nil)
      lap("organized")
      if let matter {
        let (packID, reason) = try await a.engine.requestHandoverPack(
          id, matterID: matter, from: "林知远", to: "韩策")
        check("handover pack queued", packID != nil && reason == nil)
        var view: SpaceHandoverView?
        let packDeadline = Date().addingTimeInterval(600)
        while let packID, Date() < packDeadline {
          _ = try? await a.engine.organize(id, builder: builder)
          let pack = try await a.engine.handoverPack(id, packID: packID)
          if pack.isReady || pack.status == "failed" {
            let state = try await a.engine.sync(id)
            view = SpaceHandoverView(pack, state: state, maskKey: try await a.engine.maskKey(id))
            break
          }
          try await Task.sleep(for: .seconds(8))
        }
        check("the Spark's model wrote the pack", view?.isReady == true)
        lap("pack")
        if let view, let markdown = view.markdown {
          check("the pack cites the space's items", !view.sources.isEmpty)
          check(
            "the pack shown on the Mac has no placeholder left",
            !markdown.contains(PrivacyMaskRules.leftBracket))
          let (snapshot, report) = try await a.engine.shareSnapshot(
            id, title: "交接包：Twin-7 复测", text: markdown, matterID: matter, packID: view.packID,
            cites: view.sources)
          check("the pack is shared as a snapshot", report.shared == [snapshot])
          try await a.engine.handover(
            id, matterID: matter, to: bRecord.memberID, packItemID: snapshot)
          let bState = try await b.engine.sync(id)
          check("B is the matter's 负责人", bState.handovers[matter] == bRecord.memberID)
          check(
            "B sees the pack given with it",
            bState.handoverPacks[matter] == snapshot
              && bState.items[snapshot]?.fields?.text == markdown)
          // The snapshot leaves with an item it cites (A withdraws its own).
          if let cited = view.sources.first(where: { aItems.contains($0) }) {
            withdrawnCited = cited
            try await a.engine.withdraw(id, itemID: cited)
            let after = try await b.engine.sync(id)
            check(
              "a withdrawn cited item takes the snapshot along",
              after.items[snapshot]?.isActive == false)
            check("B's Mac accepted the Spark's removal record", after.rejectedOps == 0)
          }
        }
      }

      // ---- 6. Backup → restore drill ---------------------------------------------------------------
      let (stream, receipt) = try await a.engine.backup(id)
      let backupFile = a.root.appendingPathComponent("backups").appendingPathComponent(
        receipt.fileName)
      try FileManager.default.createDirectory(
        at: backupFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try stream.write(to: backupFile)
      let opened = try await a.engine.openBackup(stream, keyWraps: receipt.keyWraps)
      check(
        "backup pulled and opens with its key sealed to the admins",
        opened.activeItems.count == receipt.items)
      check(
        "a plain member cannot open the backup (review V8R-13)",
        (try? await b.engine.openBackup(stream, keyWraps: receipt.keyWraps)) == nil)
      check("the backup holds no plaintext", stream.range(of: Data(Self.sentinel.utf8)) == nil)
      try await b.engine.withdraw(id, itemID: bItems[1])
      _ = try await a.engine.sync(id)
      let restored = try await a.engine.restore(
        id, stream: try Data(contentsOf: backupFile), mode: "replace", keyWraps: receipt.keyWraps)
      check(
        "restored onto the Spark's longer log: data filled in, nothing rolled back (V8R-03)",
        restored["ok"]?.bool == true && restored["applied"]?.string == "fill")
      let aAfter = try await a.engine.sync(id)
      let bAfter = try await b.engine.sync(id)
      let stillThere = aItems.first { $0 != withdrawnCited } ?? aItems[0]
      check(
        "after the restore A reads the items",
        aAfter.items[stillThere]?.fields?.text?.contains("Twin-7") == true
          || aAfter.items[stillThere]?.fields?.text?.contains("TG-2") == true)
      check(
        "after the restore B reads the items",
        bAfter.items[bItems[0]]?.fields?.text?.contains("TG-2") == true)
      check(
        "the withdrawal holds after the restore",
        aAfter.items[bItems[1]]?.isActive == false && bAfter.items[bItems[1]]?.isActive == false)
      let reheard = try await b.engine.audioPart(id, itemID: part)
      check("the audio part opens after the restore", reheard.audio == audio)
      let postRestore = SpaceID.new()
      let post = try await b.engine.share(
        id,
        items: [
          SpaceOutgoingItem(
            itemID: postRestore, kind: "text",
            fields: Self.fields("恢复后", "合成：恢复之后照常共享", minutes: 90))
        ])
      check("sharing works after the restore", post.shared == [postRestore])
      lap("backup")
      await a.engine.lockOrganizer(id)

      // ---- 7. Nothing readable on the Spark --------------------------------------------------------
      if let dataDir {
        let dirs = [dataDir] + (logDir.map { [$0] } ?? [])
        let hits = try ssh(
          host, "grep -rlaF \(Self.sentinel) \(dirs.joined(separator: " ")) 2>/dev/null | wc -l"
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        check("no sentinel anywhere on the Spark", hits == "0")
        let phone = try ssh(host, "grep -rlaF 13812345678 \(dataDir)/spaces 2>/dev/null | wc -l")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        check("no number on the Spark", phone == "0")
      }
      let outside = String(
        decoding: b.wire.sentOutsideOrganizing + a.wire.sentOutsideOrganizing, as: UTF8.self)
      check(
        "the text reaches the Spark only in organizing payloads (members get ciphertext)",
        !outside.contains(Self.sentinel))
      let all = b.wire.sent + a.wire.sent
      check(
        "no number in any request (masked for organizing)",
        all.range(of: Data("13812345678".utf8)) == nil)
      let window = audioBytes.subdata(in: (audioBytes.count / 2)..<(audioBytes.count / 2 + 48))
      check("the sound's bytes are never in any request", all.range(of: window) == nil)
    } catch {
      check("run completed (\(type(of: error)): \(error))", false)
    }
    // ---- 8. Unpair every Mac; authorized_keys as before ----------------------------------------------
    for accessID in accessIDs { _ = try? await a.access.unpair(accessID) }
    for bridge in bridges { await bridge.close() }
    let akAfter = try ssh(host, "sha256sum .ssh/authorized_keys | cut -c1-64").trimmingCharacters(
      in: .whitespacesAndNewlines)
    check("authorized_keys byte-identical", akAfter == akBefore && akBefore.count == 64)
    lap("done")
    let failed = checks.filter { !$0.1 }.map(\.0)
    print(
      "INFRA-E2E \(checks.count - failed.count)/\(checks.count) in \(Int(Date().timeIntervalSince(started))) s"
    )
    if let path = env("BESTASR_E2E_INFRA_EVIDENCE") {
      let summary: [String: Any] = [
        "checks": checks.count, "passed": checks.count - failed.count, "failed": failed,
        "names": checks.map(\.0), "seconds": timings,
        "authorized_keys_sha256_prefix": String(akBefore.prefix(16)),
      ]
      let data = try JSONSerialization.data(
        withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: URL(fileURLWithPath: path))
    }
    XCTAssertEqual(failed, [])
  }
}
