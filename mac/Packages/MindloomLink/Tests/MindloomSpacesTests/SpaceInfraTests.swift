import CryptoKit
import Foundation
import MindloomLink
import MindloomSpacesTestSupport
import XCTest

@testable import MindloomSpaces

/// v8 contracts B and C on the member Mac against the in-memory Spark: key
/// escrow and the takeover, backups and restore, the durable outbox, audio
/// parts, snapshots, a member's second Mac, handover packs.
final class SpaceInfraTests: XCTestCase {
  static let endpoint = SpaceInviteCode.Endpoint(
    host: "spark.test", port: 22, user: "member", hostKey: FakeSpaceSpark.hostKey)
  static let sentinel = "哨兵-V8-INFRA-91c2"

  private func note(_ text: String, matter: String? = nil) -> SpaceItemFields {
    SpaceItemFields(
      kind: "text", title: String(text.prefix(10)), text: text, sourceName: "备忘录",
      startedAt: "2026-09-20T09:00:00+08:00", originMatterID: matter)
  }

  /// `joiner` joins `spaceID` by an invite from `admin`, approved.
  private func join(_ joiner: TestMac, _ spaceID: String, admin: TestMac, role: SpaceRole = .write)
    async throws
  {
    let code = try await admin.engine.invite(
      spaceID, role: role, hostKey: FakeSpaceSpark.hostKey, spark: Self.endpoint)
    _ = try await joiner.engine.join(
      code: code, displayName: joiner.name, localHostKey: FakeSpaceSpark.hostKey)
    let requests = try await admin.engine.joinRequests(spaceID)
    let request = try XCTUnwrap(requests.first)
    try await admin.engine.approve(spaceID, request: request)
    let joined = try await joiner.engine.refreshJoin(spaceID)
    XCTAssertEqual(joined.membership, .active)
  }

  private func share(_ mac: TestMac, _ spaceID: String, _ text: String) async throws -> String {
    let id = SpaceID.new()
    let report = try await mac.engine.share(
      spaceID, items: [SpaceOutgoingItem(itemID: id, kind: "text", fields: note(text))])
    XCTAssertEqual(report.shared, [id], "\(report)")
    return id
  }

  // MARK: - One member id per Mac

  func testOneMacKeepsOneMemberIDAcrossItsSpacesAndOrgs() async throws {
    let spark = FakeSpaceSpark()
    let a = TestMac("A", spark: spark)
    let first = try await a.engine.createSpace(
      name: "一", owner: .person, displayName: "A", spark: Self.endpoint)
    let org = try await a.engine.createOrg()
    let second = try await a.engine.createSpace(
      name: "二", owner: .org, orgID: org.orgID, orgMemberID: org.memberID, displayName: "A",
      spark: Self.endpoint)
    XCTAssertEqual(first.memberID, second.memberID)
    XCTAssertEqual(org.memberID, first.memberID)
    let identity = try await a.engine.memberIdentity()
    XCTAssertEqual(identity, first.memberID)
  }

  // MARK: - Escrow and the takeover (B5)

  func testOrgSpaceKeysAreEscrowedAndAnotherAdminTakesTheSpaceOverAfterLosingTheOnlyAdmin()
    async throws
  {
    let spark = FakeSpaceSpark()
    let a = TestMac("林知远", spark: spark)
    let b = TestMac("许嘉禾", spark: spark)
    let c = TestMac("韩策", spark: spark)
    let org = try await a.engine.createOrg(recoveryAdmins: 2)
    let bMember = try await b.engine.memberIdentity()
    try await a.engine.addOrgAdmin(org.orgID, memberID: bMember, device: b.device.publicRecord)
    // The space key is escrowed to B's device (an org admin, never a member).
    let space = try await a.engine.createSpace(
      name: "Twin-7", owner: .org, orgID: org.orgID, orgMemberID: org.memberID,
      displayName: "林知远", spark: Self.endpoint)
    let id = space.spaceID
    XCTAssertNotNil(spark.space(id)?.escrow["1|\(b.device.deviceID)"])
    var aState = try await a.engine.sync(id)
    XCTAssertEqual(aState.escrow?.ok, true)
    XCTAssertEqual(aState.escrow?.required, 2)
    try await join(c, id, admin: a)
    let cItem = try await share(c, id, "合成：周四 B203 复测机械臂 \(Self.sentinel)")
    // A rotation keeps the escrow: removing someone still works.
    let d = TestMac("D", spark: spark)
    try await join(d, id, admin: a)
    try await a.engine.removeMember(id, memberID: try await d.engine.memberIdentity())
    aState = try await a.engine.sync(id)
    XCTAssertEqual(aState.epoch, 2)
    XCTAssertNotNil(spark.space(id)?.escrow["2|\(b.device.deviceID)"])

    // A's Mac is lost; B takes the space over with its escrow wrap.
    let recovered = try await b.engine.recover(orgID: org.orgID, spaceID: id, displayName: "许嘉禾")
    XCTAssertEqual(recovered.role, .admin)
    XCTAssertEqual(recovered.epoch, 2)
    XCTAssertEqual(recovered.items[cItem]?.fields?.text, "合成：周四 B203 复测机械臂 \(Self.sentinel)")
    XCTAssertNil(recovered.pendingRecoveries?.first)
    let bItem = try await share(b, id, "合成：接手后的第一条")

    // C, a plain member, cannot read the org's log: it is asked to confirm.
    var cState = try await c.engine.sync(id)
    let pending = try XCTUnwrap(cState.pendingRecoveries?.first)
    XCTAssertEqual(pending.fingerprint, b.device.fingerprint)
    XCTAssertNil(cState.items[bItem]?.fields)
    try await c.engine.confirmRecovery(id, deviceID: pending.device.deviceID)
    cState = try await c.engine.sync(id)
    XCTAssertEqual(cState.items[bItem]?.fields?.text, "合成：接手后的第一条")
    XCTAssertEqual(cState.items[cItem]?.fields?.text, "合成：周四 B203 复测机械臂 \(Self.sentinel)")
    XCTAssertNil(cState.pendingRecoveries?.first)
    // Without an escrow wrap there is no takeover.
    let e = TestMac("E", spark: spark)
    do {
      _ = try await e.engine.recover(orgID: org.orgID, spaceID: id, displayName: "E")
      XCTFail("recovered without escrow")
    } catch {}
    XCTAssertFalse(
      String(decoding: spark.everythingReceived, as: UTF8.self).contains(Self.sentinel))
  }

  func testAddingAnOrgAdminLaterFillsTheEscrowFromTheOrgsSignedLog() async throws {
    let spark = FakeSpaceSpark()
    let a = TestMac("A", spark: spark)
    let b = TestMac("B", spark: spark)
    let org = try await a.engine.createOrg(recoveryAdmins: 2)
    let space = try await a.engine.createSpace(
      name: "组", owner: .org, orgID: org.orgID, orgMemberID: org.memberID, displayName: "A",
      spark: Self.endpoint)
    // One admin only: the policy asks for min(2, 1).
    var state = try await a.engine.sync(space.spaceID)
    XCTAssertEqual(state.escrow?.required, 1)
    try await a.engine.addOrgAdmin(
      org.orgID, memberID: try await b.engine.memberIdentity(), device: b.device.publicRecord)
    state = try await a.engine.sync(space.spaceID)
    XCTAssertEqual(state.escrow?.ok, true)
    XCTAssertEqual(state.escrow?.missing, [])
    XCTAssertNotNil(spark.space(space.spaceID)?.escrow["1|\(b.device.deviceID)"])
    // The org roster is built from the signed log only.
    let fetched = await a.engine.orgRoster(org.orgID)
    let roster = try XCTUnwrap(fetched)
    let bMember = try await b.engine.memberIdentity()
    XCTAssertEqual(Set(roster.activeAdmins), Set([org.memberID, bMember]))
    XCTAssertEqual(roster.policy, 2)
    XCTAssertEqual(roster.rejected, 0)
  }

  // MARK: - Backups (B4)

  func testABackupOpensOnlyWithTheSpacesKeyAndARestoreDrillGivesTheSameSpaceBack() async throws {
    let spark = FakeSpaceSpark()
    let a = TestMac("A", spark: spark)
    let b = TestMac("B", spark: spark)
    let space = try await a.engine.createSpace(
      name: "备份", owner: .person, displayName: "A", spark: Self.endpoint)
    let id = space.spaceID
    try await join(b, id, admin: a)
    let kept = try await share(a, id, "合成：留着的 \(Self.sentinel)")
    let gone = try await share(b, id, "合成：之后撤回的")
    let original = Data("PNG-\(Self.sentinel)".utf8)
    let withFile = SpaceID.new()
    _ = try await a.engine.share(
      id,
      items: [
        SpaceOutgoingItem(
          itemID: withFile, kind: "image", fields: note("截图"), originals: [("image", original)])
      ])
    let (stream, receipt) = try await a.engine.backup(id)
    XCTAssertEqual(receipt.items, 3)
    XCTAssertEqual(receipt.blobs, 1)
    XCTAssertTrue(stream.starts(with: Data("MLBK1\n".utf8)))
    XCTAssertFalse(String(decoding: stream, as: UTF8.self).contains(Self.sentinel))
    let contents = try await a.engine.openBackup(stream, keyWraps: receipt.keyWraps)
    XCTAssertEqual(contents.activeItems.count, 3)
    // Another key, a changed byte, a cut-off stream: refused.
    let key = try await a.engine.backupKey(stream, keyWraps: receipt.keyWraps)
    XCTAssertThrowsError(try SpaceBackup.open(stream, key: SpaceCrypto.randomKey()))
    var changed = stream
    changed[changed.count - 20] ^= 0x01
    XCTAssertThrowsError(try SpaceBackup.open(changed, key: key))
    XCTAssertThrowsError(try SpaceBackup.open(stream.dropLast(5), key: key))
    // B withdraws after the backup. The Spark's log holds the backup's and
    // more (review V8R-03): the restore fills in data only and the withdrawal
    // stays as the log has it.
    try await b.engine.withdraw(id, itemID: gone)
    _ = try await a.engine.sync(id)
    let answer = try await a.engine.restore(
      id, stream: stream, mode: "replace", keyWraps: receipt.keyWraps)
    XCTAssertEqual(answer["applied"]?.string, "fill")
    XCTAssertEqual(answer["purged"]?.int, 0)
    let aState = try await a.engine.sync(id)
    XCTAssertEqual(aState.items[kept]?.fields?.text, "合成：留着的 \(Self.sentinel)")
    XCTAssertFalse(aState.items[gone]?.isActive ?? true)
    let blob = try XCTUnwrap(aState.items[withFile]?.blobs.first)
    let opened = try await a.engine.original(id, itemID: withFile, blob: blob)
    XCTAssertEqual(opened, original)
    // B's Mac reads on; the withdrawal holds.
    let bState = try await b.engine.sync(id)
    XCTAssertEqual(bState.items[kept]?.fields?.text, "合成：留着的 \(Self.sentinel)")
    XCTAssertFalse(bState.items[gone]?.isActive ?? true)
    _ = try await share(b, id, "合成：恢复之后照常共享")
  }

  func testBackupScheduleIsDueByIntervalAndWaitsAfterAFailure() {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    var schedule = SpaceBackupSchedule(interval: .daily, folder: "/Volumes/外置盘/织机备份")
    XCTAssertTrue(schedule.isDue(now: now))
    schedule.lastSuccess = now.addingTimeInterval(-3_600)
    XCTAssertFalse(schedule.isDue(now: now))
    schedule.lastSuccess = now.addingTimeInterval(-90_000)
    XCTAssertTrue(schedule.isDue(now: now))
    schedule.lastAttempt = now.addingTimeInterval(-600)
    schedule.lastError = "disk_missing"
    XCTAssertFalse(schedule.isDue(now: now))
    schedule.folder = nil
    XCTAssertFalse(schedule.isDue(now: now.addingTimeInterval(86_400)))
    XCTAssertFalse(SpaceBackupSchedule(interval: .off, folder: "/x").isDue(now: now))
    XCTAssertTrue(
      SpaceBackupFiles.fileName(spaceName: "B203 实验室", backupID: SpaceID.new(), at: now)
        .hasSuffix(".mlbk"))
  }

  // MARK: - The outbox (C3)

  func testSharesMadeWhileTheLinkIsDownWaitOnDiskAndGoAfterReconnecting() async throws {
    let spark = FakeSpaceSpark()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mloutbox-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let states = MemorySpaceStateStore()
    let keys = MemorySpaceKeyStore()
    let device = SpaceDeviceKeys.generate()
    let a = TestMac(
      "A", spark: spark, transport: spark, device: device, states: states, keys: keys,
      outbox: FileSpaceOutboxStore(directory: root))
    let b = TestMac("B", spark: spark)
    let space = try await a.engine.createSpace(
      name: "断网", owner: .person, displayName: "A", spark: Self.endpoint)
    let id = space.spaceID
    try await join(b, id, admin: a)
    spark.offline = true
    let item = SpaceID.new()
    let original = Data("FILE-\(Self.sentinel)".utf8)
    let report = try await a.engine.share(
      id,
      items: [
        SpaceOutgoingItem(
          itemID: item, kind: "document", fields: note("断网时记下的"),
          originals: [("original", original)])
      ])
    XCTAssertEqual(report.queued, [item])
    // On disk, in the space's own folder, 0600.
    let folder = root.appendingPathComponent(id).appendingPathComponent("outbox")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: folder.appendingPathComponent("outbox.json").path))
    var info = stat()
    XCTAssertEqual(stat(folder.appendingPathComponent("outbox.json").path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o600)
    // The App quits; a new engine on the same stores sends it once the link is back.
    spark.offline = false
    let again = TestMac(
      "A", spark: spark, transport: spark, device: device, states: states, keys: keys,
      outbox: FileSpaceOutboxStore(directory: root))
    let flush = try await again.engine.flushOutbox(id)
    XCTAssertEqual(flush.done.values.compactMap { $0 }, [item])
    let left = try await again.engine.outboxContents(id)
    XCTAssertEqual(left.entries.count, 0)
    let files =
      (try? FileManager.default.contentsOfDirectory(
        atPath: folder.appendingPathComponent("files").path)) ?? []
    XCTAssertEqual(files, [])
    let bState = try await b.engine.sync(id)
    let blob = try XCTUnwrap(bState.items[item]?.blobs.first)
    let opened = try await b.engine.original(id, itemID: item, blob: blob)
    XCTAssertEqual(opened, original)
  }

  func testALostAnswerAndARemadeShareAreAcceptedOnceAndRefusalsAreReported() async throws {
    let spark = FakeSpaceSpark()
    let a = TestMac("A", spark: spark)
    let space = try await a.engine.createSpace(
      name: "重试", owner: .person, displayName: "A", spark: Self.endpoint)
    let id = space.spaceID
    // The share lands but its answer is lost.
    spark.loseNextAnswer("item.share")
    let item = SpaceID.new()
    let first = try await a.engine.share(
      id, items: [SpaceOutgoingItem(itemID: item, kind: "text", fields: note("只算一次"))])
    XCTAssertEqual(first.queued, [item])
    XCTAssertEqual(spark.space(id)?.items[item]?.revision, 1)
    // Then the key moves on: the entry is remade (new op, new data key) with
    // the same share key, and the Spark takes it as the one it has.
    spark.failNext("item.share", code: "rotation_pending")
    let flush = try await a.engine.flushOutbox(id)
    XCTAssertEqual(flush.done.values.compactMap { $0 }, [item])
    let shares = spark.space(id)?.log.filter { $0.type == "item.share" } ?? []
    XCTAssertEqual(shares.count, 1)
    // A quota refusal waits ("later"); a refusal for good is dropped and reported.
    spark.failNext("item.share", code: "quota_exceeded", status: 413)
    let later = SpaceID.new()
    let waiting = try await a.engine.share(
      id, items: [SpaceOutgoingItem(itemID: later, kind: "text", fields: note("稍后"))])
    XCTAssertEqual(waiting.queued, [later])
    let sent = try await a.engine.flushOutbox(id)
    XCTAssertEqual(sent.done.values.compactMap { $0 }, [later])
    spark.failNext("item.share", code: "never_shared", status: 422)
    let refused = SpaceID.new()
    let report = try await a.engine.share(
      id, items: [SpaceOutgoingItem(itemID: refused, kind: "text", fields: note("不收"))])
    XCTAssertEqual(report.refused[refused], "never_shared")
    let failed = try await a.engine.outboxContents(id)
    XCTAssertEqual(failed.failures.map(\.code), ["never_shared"])
    try await a.engine.dismissOutboxFailures(id)
    let cleared = try await a.engine.outboxContents(id)
    XCTAssertEqual(cleared.failures, [])
  }

  func testAWithdrawWhileOfflineWaitsAndARemadeWithdrawIsTakenAsTheFirst() async throws {
    let spark = FakeSpaceSpark()
    let a = TestMac("A", spark: spark)
    let space = try await a.engine.createSpace(
      name: "撤回", owner: .person, displayName: "A", spark: Self.endpoint)
    let id = space.spaceID
    let item = try await share(a, id, "合成：要撤回的")
    spark.offline = true
    do {
      try await a.engine.withdraw(id, itemID: item)
      XCTFail("withdrew while offline")
    } catch SpaceEngine.EngineError.queued {}
    spark.offline = false
    // The first attempt's answer is lost; the remade one is taken as it.
    spark.loseNextAnswer("item.withdraw")
    var flush = try await a.engine.flushOutbox(id)
    XCTAssertTrue(flush.linkDown)
    XCTAssertEqual(spark.space(id)?.items[item]?.status, "withdrawn")
    flush = try await a.engine.flushOutbox(id)
    XCTAssertEqual(flush.done.count, 1)
    let empty = try await a.engine.outboxContents(id)
    XCTAssertEqual(empty.entries.count, 0)
  }

  // MARK: - Meeting parts with their audio (C1)

  func testAMeetingPartsAudioGoesToMembersAsCiphertextAndIsCheckedBeforePlaying() async throws {
    let spark = FakeSpaceSpark()
    let a = TestMac("A", spark: spark)
    let b = TestMac("B", spark: spark)
    let space = try await a.engine.createSpace(
      name: "会议", owner: .person, displayName: "A", spark: Self.endpoint)
    let id = space.spaceID
    try await join(b, id, admin: a)
    let recording = SpaceID.new()
    let audio = Data(repeating: 0x5A, count: 20 * 4_000) + Data(Self.sentinel.utf8)
    let part = SpaceID.segment(parent: recording, startMS: 60_000, endMS: 80_000)
    let segment = SpaceSegmentRef(
      parentItemID: recording, startMS: 60_000, endMS: 80_000, recordingMS: 3_600_000)
    let report = try await b.engine.share(
      id,
      items: [
        SpaceOutgoingItem(
          itemID: part, kind: "audio_segment", fields: note("这二十秒"),
          originals: [("audio", audio)], segment: segment)
      ])
    XCTAssertEqual(report.shared, [part])
    // A opens it; the decoded length matches the signed part.
    _ = try await a.engine.sync(id)
    let opened = try await a.engine.audioPart(id, itemID: part)
    XCTAssertEqual(opened.audio, audio)
    XCTAssertEqual(opened.segment, segment)
    XCTAssertTrue(SpaceAudioCheck.ok(durationMS: 20_400, segment: opened.segment))
    XCTAssertFalse(SpaceAudioCheck.ok(durationMS: 60_000, segment: opened.segment))
    XCTAssertFalse(
      SpaceAudioCheck.ok(
        durationMS: 20_000,
        segment: .init(parentItemID: recording, startMS: 0, endMS: 20_000, recordingMS: 20_000)))
    // The Spark holds ciphertext only.
    let stored = spark.space(id)?.blobs.values.map(\.data) ?? []
    XCTAssertTrue(stored.allSatisfy { $0.starts(with: Data("MLB1".utf8)) })
    XCTAssertFalse(
      String(decoding: spark.everythingReceived, as: UTF8.self).contains(Self.sentinel))
    // One audio part per recording; never the whole recording.
    let other = SpaceID.segment(parent: recording, startMS: 0, endMS: 2_000)
    let whole = SpaceID.segment(parent: recording, startMS: 0, endMS: 3_600_000)
    let second = try await b.engine.share(
      id,
      items: [
        SpaceOutgoingItem(
          itemID: other, kind: "audio_segment", fields: note("另一段"),
          originals: [("audio", Data(count: 100))],
          segment: .init(parentItemID: recording, startMS: 0, endMS: 2_000, recordingMS: 3_600_000)),
        SpaceOutgoingItem(
          itemID: whole, kind: "audio_segment", fields: note("整场"),
          originals: [("audio", Data(count: 100))],
          segment: .init(
            parentItemID: SpaceID.new(), startMS: 0, endMS: 600_000, recordingMS: 600_000)),
      ])
    XCTAssertEqual(second.refused[other], "one_part_per_recording")
    XCTAssertEqual(second.refused[whole], "whole_recording")
    // Withdrawn: the members' Macs drop it and the Spark's file is gone.
    try await b.engine.withdraw(id, itemID: part)
    let aState = try await a.engine.sync(id)
    XCTAssertFalse(aState.items[part]?.isActive ?? true)
    do {
      _ = try await a.engine.audioPart(id, itemID: part)
      XCTFail("opened a withdrawn part")
    } catch {}
  }

  // MARK: - Snapshots (C2)

  func testASnapshotIsANewFrozenItemAndGoesWithTheItemsItCites() async throws {
    let spark = FakeSpaceSpark()
    let a = TestMac("A", spark: spark)
    let b = TestMac("B", spark: spark)
    let space = try await a.engine.createSpace(
      name: "快照", owner: .person, displayName: "A", spark: Self.endpoint)
    let id = space.spaceID
    try await join(b, id, admin: a)
    let cited = try await share(a, id, "合成：周四复测")
    let (snapshot, report) = try await b.engine.shareSnapshot(
      id, title: "小结", text: "合成：B 的小结，引用了周四复测", matterID: "E1", cites: [cited, SpaceID.new()])
    XCTAssertEqual(report.shared, [snapshot])
    var aState = try await a.engine.sync(id)
    XCTAssertEqual(aState.items[snapshot]?.kind, "snapshot")
    XCTAssertEqual(aState.items[snapshot]?.snapshot?.cites, [cited])
    let bIdentity = try await b.engine.memberIdentity()
    XCTAssertEqual(aState.items[snapshot]?.contributor, bIdentity)
    XCTAssertEqual(aState.items[snapshot]?.fields?.text, "合成：B 的小结，引用了周四复测")
    // Frozen: sharing again on its id is refused.
    let again = try await b.engine.share(
      id, items: [SpaceOutgoingItem(itemID: snapshot, kind: "snapshot", fields: note("改"))])
    XCTAssertEqual(again.refused[snapshot], "snapshot_frozen")
    // The cited item leaves: the Spark's system record removes the snapshot, and both Macs accept it.
    try await a.engine.withdraw(id, itemID: cited)
    aState = try await a.engine.sync(id)
    let bState = try await b.engine.sync(id)
    XCTAssertFalse(aState.items[snapshot]?.isActive ?? true)
    XCTAssertFalse(bState.items[snapshot]?.isActive ?? true)
    XCTAssertEqual(aState.rejectedOps, 0)
    XCTAssertEqual(bState.rejectedOps, 0)
  }

  // MARK: - A member's second Mac (C4)

  func testASecondMacIsAddedByTheFirstReadsTheSpaceAndIsRetiredWithANewKey() async throws {
    let spark = FakeSpaceSpark()
    let owner = AccessClient(
      client: SpaceClient(transport: spark, device: .generate(), now: { spark.now }))
    // A joins the team with its own credential, then makes an org and a space.
    let aDevice = SpaceDeviceKeys.generate()
    let (code, _) = try await TeamAccess.makeInvite(
      access: owner, kind: .member, spark: Self.endpoint, relay: nil, team: nil, space: nil,
      now: spark.now)
    let aRecord = try await TeamAccess.enroll(
      code: code, device: aDevice, memberID: SpaceID.new(), store: MemoryMemberAccessStore(),
      now: spark.now
    ) { key, request in spark.enroll(ticketKey: key.authorizedKey, request: request) }
    let a = TestMac(
      "A", spark: spark, transport: spark.credentialTransport(aRecord.credential), device: aDevice)
    try await a.engine.setMemberIdentity(aRecord.memberID)
    let org = try await a.engine.createOrg()
    let space = try await a.engine.createSpace(
      name: "两台", owner: .org, orgID: org.orgID, orgMemberID: org.memberID, displayName: "A",
      spark: Self.endpoint)
    let id = space.spaceID
    let item = try await share(a, id, "合成：第一台 Mac 记的")
    // A makes a device ticket; A2 enrolls under the same member id.
    let aAccess = a.accessClient(spark.credentialTransport(aRecord.credential), spark: spark)
    let (deviceCode, _) = try await TeamAccess.makeInvite(
      access: aAccess, kind: .device, spark: Self.endpoint, relay: nil, memberID: aRecord.memberID,
      team: nil, space: nil, now: spark.now)
    let a2Device = SpaceDeviceKeys.generate()
    let a2Record = try await TeamAccess.enroll(
      code: deviceCode, device: a2Device, memberID: SpaceID.new(), store: MemoryMemberAccessStore(),
      now: spark.now
    ) { key, request in spark.enroll(ticketKey: key.authorizedKey, request: request) }
    XCTAssertEqual(a2Record.memberID, aRecord.memberID)
    let a2 = TestMac(
      "A2", spark: spark, transport: spark.credentialTransport(a2Record.credential),
      device: a2Device)
    try await a2.engine.setMemberIdentity(a2Record.memberID)
    // The work list says where A2 is still to be added; A signs it.
    let view = try await aAccess.devices()
    let entry = try XCTUnwrap(view.devices.first { $0.deviceID == a2Device.deviceID })
    XCTAssertEqual(entry.toAdd, .init(spaces: [id], orgs: [org.orgID]))
    try await a.engine.addDevice(id, device: entry.publicRecord)
    try await a.engine.addOrgDevice(org.orgID, device: entry.publicRecord)
    let adopted = try await a2.engine.adoptSpaces()
    XCTAssertEqual(adopted, [id])
    let a2State = try await a2.engine.sync(id)
    XCTAssertEqual(a2State.items[item]?.fields?.text, "合成：第一台 Mac 记的")
    XCTAssertEqual(a2State.role, .admin)
    let fromA2 = try await share(a2, id, "合成：第二台 Mac 记的")
    var aState = try await a.engine.sync(id)
    XCTAssertEqual(aState.items[fromA2]?.fields?.text, "合成：第二台 Mac 记的")
    XCTAssertEqual(aState.items[fromA2]?.contributor, aRecord.memberID)
    // A2 is lost: unpaired, retired in the space (new key) and the org.
    let removed = try await aAccess.unpair(a2Record.accessID)
    XCTAssertEqual(removed, 1)
    let after = try await aAccess.devices()
    XCTAssertEqual(
      after.devices.first { $0.deviceID == a2Device.deviceID }?.toRemove,
      .init(spaces: [id], orgs: [org.orgID]))
    try await a.engine.retireDevice(id, deviceID: a2Device.deviceID)
    try await a.engine.retireOrgDevice(org.orgID, deviceID: a2Device.deviceID)
    aState = try await a.engine.sync(id)
    XCTAssertEqual(aState.epoch, 2)
    XCTAssertFalse(aState.roster?.activeDeviceIDs.contains(a2Device.deviceID) ?? true)
    XCTAssertNil(spark.space(id)?.wraps["2|\(a2Device.deviceID)"])
  }

  // MARK: - Handover (B3)

  func testAHandoverPackBecomesASnapshotAndTheMatterGoesToAnotherMember() async throws {
    let spark = FakeSpaceSpark()
    let a = TestMac("A", spark: spark)
    let b = TestMac("B", spark: spark)
    let space = try await a.engine.createSpace(
      name: "交接", owner: .person, displayName: "A", spark: Self.endpoint)
    let id = space.spaceID
    try await join(b, id, admin: a, role: .maintain)
    let item = try await share(a, id, "合成：采购单周五前寄出")
    _ = try await a.engine.organize(id, builder: RecordingPayloadBuilder())
    let (packID, reason) = try await a.engine.requestHandoverPack(
      id, matterID: "ev-1", from: "A", to: "B")
    XCTAssertNil(reason)
    let pack = try await a.engine.handoverPack(id, packID: try XCTUnwrap(packID))
    XCTAssertTrue(pack.isReady)
    XCTAssertEqual(pack.sources, [item])
    let (snapshot, report) = try await a.engine.shareSnapshot(
      id, title: "交接包", text: pack.markdown ?? "", matterID: "ev-1", packID: packID,
      cites: pack.sources)
    XCTAssertEqual(report.shared, [snapshot])
    try await a.engine.handover(
      id, matterID: "ev-1", to: try await b.engine.memberIdentity(), packItemID: snapshot)
    let bState = try await b.engine.sync(id)
    let bMember = try await b.engine.memberIdentity()
    XCTAssertEqual(bState.handovers["ev-1"], bMember)
    XCTAssertEqual(bState.handoverPacks["ev-1"], snapshot)
    XCTAssertEqual(bState.items[snapshot]?.snapshot?.packID, packID)
  }
}
