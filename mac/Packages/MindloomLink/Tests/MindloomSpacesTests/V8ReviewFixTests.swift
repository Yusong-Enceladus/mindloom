import CryptoKit
import Foundation
import MindloomLink
import XCTest

@testable import MindloomSpaces
@testable import MindloomSpacesTestSupport

/// Regression tests for the adversarial review of claude/v8 on the member Mac
/// (V8R-02, -03, -04, -11, -12, -13, -15). The first two are the review's own
/// proof tests (they failed before the fixes). Synthetic data only.
final class V8ReviewFixTests: XCTestCase {
  static let endpoint = SpaceInviteCode.Endpoint(
    host: "spark.test", port: 22, user: "member", hostKey: FakeSpaceSpark.hostKey)
  static let sentinel = "哨兵-REVIEW-V8-删掉了还发出去"

  private func note(_ text: String) -> SpaceItemFields {
    SpaceItemFields(
      kind: "text", title: String(text.prefix(10)), text: text, sourceName: "备忘录",
      startedAt: "2026-09-20T09:00:00+08:00")
  }

  private func join(_ joiner: TestMac, _ spaceID: String, admin: TestMac) async throws {
    let code = try await admin.engine.invite(
      spaceID, role: .write, hostKey: FakeSpaceSpark.hostKey, spark: Self.endpoint)
    _ = try await joiner.engine.join(
      code: code, displayName: joiner.name, localHostKey: FakeSpaceSpark.hostKey)
    let requests = try await admin.engine.joinRequests(spaceID)
    let request = try XCTUnwrap(requests.first)
    try await admin.engine.approve(spaceID, request: request)
    _ = try await joiner.engine.refreshJoin(spaceID)
  }

  /// A new org log for the same org id, as whoever runs the Spark could
  /// serve it: `org.create` by its own device X, then `org.admin_add` of the
  /// real admin's device.
  private func forgeOrgLog(_ spark: FakeSpaceSpark, orgID: String, admin: TestMac, memberID: String)
    throws -> SpaceDeviceKeys
  {
    let x = SpaceDeviceKeys.generate()
    let xMember = SpaceID.new()
    let create = try x.orgOp(
      org: orgID, member: xMember, type: "org.create",
      body: ["device": x.publicRecord.json, "policy": ["recovery_admins": SpaceJSON(1)]])
    let addA = try x.orgOp(
      org: orgID, member: xMember, type: "org.admin_add",
      body: ["member_id": .string(memberID), "device": admin.device.publicRecord.json])
    var forged = try XCTUnwrap(spark.org(orgID))
    forged.admins[xMember] = "active"
    forged.devices[x.deviceID] = FakeOrg.Device(
      member: xMember, signPub: x.signPublicKey, signPubB64: Base64URL.encode(x.signPublicKey),
      sealPub: Base64URL.encode(x.sealPublicKey))
    forged.log = [
      FakeSpaceSpark.LoggedOp(
        seq: 1, type: "org.create", op: create.opJSON, sig: create.signature, enc: nil,
        at: spark.now),
      FakeSpaceSpark.LoggedOp(
        seq: 2, type: "org.admin_add", op: addA.opJSON, sig: addA.signature, enc: nil,
        at: spark.now),
    ]
    spark.lock.withLock { spark.orgs[orgID] = forged }
    return x
  }

  // MARK: - V8R-02: the organization's log is pinned

  /// The review's M1: the escrow loop of the real admin's Mac never wraps the
  /// space key to a device of a forged org log.
  func testM1ForgedOrgLogMustNotReceiveTheSpaceKey() async throws {
    let spark = FakeSpaceSpark()
    let a = TestMac("A", spark: spark)
    let org = try await a.engine.createOrg(recoveryAdmins: 1)
    let space = try await a.engine.createSpace(
      name: "组织空间", owner: .org, orgID: org.orgID, orgMemberID: org.memberID, displayName: "A",
      spark: Self.endpoint)
    _ = try await a.engine.sync(space.spaceID)
    let x = try forgeOrgLog(spark, orgID: org.orgID, admin: a, memberID: org.memberID)

    // What the spaces loop does every 10 minutes for an org admin.
    _ = try? await a.engine.fillEscrow(space.spaceID)
    let wrap = spark.space(space.spaceID)?.escrow["1|\(x.deviceID)"]
    var opened: Data?
    if let wrap {
      opened = try? SpaceCrypto.unwrapSpaceKey(
        wrap, sealKey: x.sealKey, spaceID: space.spaceID, epoch: 1, deviceID: x.deviceID)
    }
    let real = try a.keys.keys(space.spaceID)[1]
    XCTAssertNil(wrap, "the space key was escrowed to the Spark's own device")
    XCTAssertFalse(opened != nil && opened == real, "the Spark opened the space key")
    let forked = await a.engine.orgLogForked(org.orgID)
    XCTAssertTrue(forked)
    // A rotation (a member removal) does not escrow to X either.
    let roster = await a.engine.orgRoster(org.orgID)
    XCTAssertNil(roster)
  }

  /// The space's signed genesis commits to the org's first op, so a Mac that
  /// never read the org log before still refuses a forged one; a log whose
  /// pinned history was cut is refused too.
  func testTheSpaceGenesisCommitsToTheOrgAndAPinnedHistoryCannotBeCut() async throws {
    let spark = FakeSpaceSpark()
    let a = TestMac("A", spark: spark)
    let org = try await a.engine.createOrg(recoveryAdmins: 1)
    let space = try await a.engine.createSpace(
      name: "组织空间", owner: .org, orgID: org.orgID, orgMemberID: org.memberID, displayName: "A",
      spark: Self.endpoint)
    let pin = try XCTUnwrap(try a.states.orgPins()[org.orgID])
    let genesis = try XCTUnwrap(spark.space(space.spaceID)?.log.first)
    let op = try SpaceJSON.decode(genesis.op)
    XCTAssertEqual(op["body"]?["owner"]?["org_genesis"]?.string, pin.genesisHash)

    // B joins the space and learns the commitment from the signed genesis.
    let b = TestMac("B", spark: spark)
    try await join(b, space.spaceID, admin: a)
    let bState = try await b.engine.sync(space.spaceID)
    XCTAssertEqual(bState.orgGenesis, pin.genesisHash)
    // Before B ever read the org log, the Spark forges one: refused.
    _ = try forgeOrgLog(spark, orgID: org.orgID, admin: b, memberID: bState.memberID)
    let forgedForB = await b.engine.orgRoster(org.orgID)
    XCTAssertNil(forgedForB)

    // A pinned a longer history; the Spark serving it cut short is refused.
    let spark2 = FakeSpaceSpark()
    let c = TestMac("C", spark: spark2)
    let org2 = try await c.engine.createOrg(recoveryAdmins: 1)
    let d = SpaceDeviceKeys.generate()
    try await c.engine.addOrgDevice(org2.orgID, device: d.publicRecord)
    let full = await c.engine.orgRoster(org2.orgID)
    XCTAssertNotNil(full)
    XCTAssertEqual(try c.states.orgPins()[org2.orgID]?.headSeq, 2)
    spark2.lock.withLock { spark2.orgs[org2.orgID]?.log.removeLast() }
    let cut = await c.engine.orgRoster(org2.orgID)
    XCTAssertNil(cut)
  }

  // MARK: - V8R-04: the outbox follows deletes, withdrawals and cancels

  /// The review's M2.
  func testM2ItemDeletedLocallyWhileQueuedIsNeverShared() async throws {
    let spark = FakeSpaceSpark()
    let a = TestMac("A", spark: spark)
    let b = TestMac("B", spark: spark)
    let space = try await a.engine.createSpace(
      name: "断网", owner: .person, displayName: "A", spark: Self.endpoint)
    let id = space.spaceID
    try await join(b, id, admin: a)
    spark.offline = true
    let item = SpaceID.new()
    let report = try await a.engine.share(
      id, items: [SpaceOutgoingItem(itemID: item, kind: "text", fields: note(Self.sentinel))])
    XCTAssertEqual(report.queued, [item])
    // The owner deletes the item on this Mac (the App calls this for every local delete).
    _ = try await a.engine.localItemsDeleted([item])
    let left = try await a.engine.outboxContents(id)
    let stillQueued = left.entries.contains { $0.itemID == item }
    spark.offline = false
    _ = try await a.engine.flushDeletes(id)
    _ = try await a.engine.flushOutbox(id)
    let bState = try await b.engine.sync(id)
    XCTAssertFalse(stillQueued, "the deleted item's plain copy stayed in the outbox")
    XCTAssertNil(bState.items[item], "the item deleted on the Mac was shared to the members")
    XCTAssertFalse(spark.everythingReceived.range(of: Data(Self.sentinel.utf8)) != nil)
  }

  /// A withdraw while the link is down takes the waiting share out instead of
  /// sending both; a waiting entry can be cancelled; a recording deleted on
  /// this Mac takes its waiting parts with it.
  func testWithdrawAndCancelTakeWaitingSharesOut() async throws {
    let spark = FakeSpaceSpark()
    let a = TestMac("A", spark: spark)
    let b = TestMac("B", spark: spark)
    let space = try await a.engine.createSpace(
      name: "断网", owner: .person, displayName: "A", spark: Self.endpoint)
    let id = space.spaceID
    try await join(b, id, admin: a)
    spark.offline = true
    let first = SpaceID.new()
    let second = SpaceID.new()
    let third = SpaceID.new()
    let part = SpaceID.new()
    let recording = SpaceID.new()
    _ = try await a.engine.share(
      id,
      items: [
        SpaceOutgoingItem(itemID: first, kind: "text", fields: note("合成：一 \(Self.sentinel)")),
        SpaceOutgoingItem(itemID: second, kind: "text", fields: note("合成：二 \(Self.sentinel)")),
        SpaceOutgoingItem(itemID: third, kind: "text", fields: note("合成：三 \(Self.sentinel)")),
        SpaceOutgoingItem(
          itemID: part, kind: "audio_segment", fields: note("合成：片段 \(Self.sentinel)"),
          segment: SpaceSegmentRef(
            parentItemID: recording, startMS: 0, endMS: 60_000, recordingMS: 3_600_000)),
      ])
    let queuedAtFirst = try await a.engine.outboxContents(id).entries
    XCTAssertEqual(queuedAtFirst.count, 4)
    // The first entry was sent once (its answer lost to the link): a withdraw
    // takes the share out and keeps the withdraw, in case the Spark has it.
    XCTAssertEqual(queuedAtFirst.first { $0.itemID == first }?.attempts, 1)
    do {
      try await a.engine.withdraw(id, itemID: first)
    } catch SpaceEngine.EngineError.queued {}
    var waiting = try await a.engine.outboxContents(id).entries
    XCTAssertFalse(waiting.contains { $0.kind == .share && $0.itemID == first })
    XCTAssertTrue(waiting.contains { $0.opType == "item.withdraw" && $0.itemID == first })
    // One never sent: taken out, nothing to withdraw on the Spark.
    try await a.engine.withdraw(id, itemID: third)
    waiting = try await a.engine.outboxContents(id).entries
    XCTAssertFalse(waiting.contains { $0.itemID == third })
    // Cancel from the outbox list.
    let entry = try XCTUnwrap(waiting.first { $0.itemID == second })
    try await a.engine.cancelOutboxEntry(id, entryID: entry.entryID)
    // The recording deleted on this Mac: its waiting part goes too.
    _ = try await a.engine.localItemsDeleted([recording])
    waiting = try await a.engine.outboxContents(id).entries
    XCTAssertTrue(waiting.filter { $0.kind == .share }.isEmpty, "\(waiting.map(\.label))")
    spark.offline = false
    _ = try await a.engine.flushDeletes(id)
    _ = try await a.engine.flushOutbox(id)
    let bState = try await b.engine.sync(id)
    XCTAssertNil(bState.items[first])
    XCTAssertNil(bState.items[second])
    XCTAssertNil(bState.items[third])
    XCTAssertNil(bState.items[part])
    XCTAssertNil(spark.everythingReceived.range(of: Data(Self.sentinel.utf8)))
    let after = try await a.engine.outboxContents(id)
    XCTAssertTrue(after.entries.isEmpty)
    XCTAssertTrue(after.failures.isEmpty, "\(after.failures)")
  }

  // MARK: - V8R-03: a log gone back never lets a removed member read new things

  func testALogGoneBackIsRepairedBeforeAnythingNewIsShared() async throws {
    let spark = FakeSpaceSpark()
    let a = TestMac("A", spark: spark)
    let b = TestMac("B", spark: spark)
    let m = TestMac("M", spark: spark)
    let space = try await a.engine.createSpace(
      name: "回滚", owner: .person, displayName: "A", spark: Self.endpoint)
    let id = space.spaceID
    try await join(b, id, admin: a)
    try await join(m, id, admin: a)
    let mLocal = try await m.engine.state(id)
    let mID = try XCTUnwrap(mLocal?.memberID)
    let before = try XCTUnwrap(spark.space(id))  // the Spark's state while M is a member
    try await a.engine.removeMember(id, memberID: mID)
    _ = try await b.engine.sync(id)
    // The Spark's log goes back (a forced restore, or whoever runs the Spark).
    spark.lock.withLock { spark.spaces[id] = before }
    let bState = try await b.engine.sync(id)
    XCTAssertEqual(bState.readmittedAfterRollback?.contains(mID), true)
    XCTAssertTrue(bState.rotationPending)
    // B shares now: it waits instead of going out under a key M holds.
    let item = SpaceID.new()
    let report = try await b.engine.share(
      id, items: [SpaceOutgoingItem(itemID: item, kind: "text", fields: note(Self.sentinel))])
    XCTAssertEqual(report.queued, [item])
    XCTAssertNil(spark.space(id)?.items[item])
    // A plain rotation would wrap the new key to M again: the admin's Mac
    // removes M again instead (with a new key).
    try await a.engine.rotate(id)
    let aState = try await a.engine.sync(id)
    XCTAssertNil(aState.readmittedAfterRollback)
    XCTAssertEqual(aState.roster?.members[mID]?.status, "removed")
    // Now B's share goes, and M cannot open it.
    _ = try await b.engine.sync(id)
    _ = try await b.engine.flushOutbox(id)
    XCTAssertNotNil(spark.space(id)?.items[item])
    let mState = try? await m.engine.sync(id)
    XCTAssertNil(mState?.items[item]?.fields)
  }

  // MARK: - V8R-13: a backup opens for the space's admins only

  func testABackupIsSealedToAdminsAndItsReceiptNamesNoSpace() async throws {
    let spark = FakeSpaceSpark()
    let a = TestMac("A", spark: spark)
    let b = TestMac("B", spark: spark)
    let space = try await a.engine.createSpace(
      name: "B203 实验室", owner: .person, displayName: "A", spark: Self.endpoint)
    let id = space.spaceID
    try await join(b, id, admin: a)
    _ = try await a.engine.share(
      id, items: [SpaceOutgoingItem(itemID: SpaceID.new(), kind: "text", fields: note("合成：一条"))])
    let (stream, receipt) = try await a.engine.backup(id)
    XCTAssertEqual(Set(receipt.keyWraps?.keys ?? [:].keys), [a.device.deviceID])
    let key = try await a.engine.backupKey(stream, keyWraps: receipt.keyWraps)
    XCTAssertNoThrow(try SpaceBackup.open(stream, key: key))
    // B holds the space key but no wrap: it cannot open the backup, nor with
    // the key the space key used to derive.
    do {
      _ = try await b.engine.openBackup(stream, keyWraps: receipt.keyWraps)
      XCTFail("a plain member opened the backup")
    } catch {}
    let spaceKey = try XCTUnwrap(try b.keys.keys(id)[receipt.epoch])
    XCTAssertThrowsError(
      try SpaceBackup.open(
        stream, key: SpaceBackup.key(spaceKey: spaceKey, backupID: receipt.backupID)))
    // The receipt beside it names no space; the file name neither.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let json = String(decoding: try encoder.encode(receipt), as: UTF8.self)
    XCTAssertFalse(json.contains("B203"))
    XCTAssertFalse(json.contains("space_name"))
    XCTAssertTrue(receipt.fileName.hasPrefix("mindloom-"))
    XCTAssertFalse(receipt.fileName.contains("B203"))
  }

  // MARK: - V8R-15: a part is never (nearly) the whole recording

  func testAnAudioPartIsAtMostFourFifthsOfItsRecording() {
    XCTAssertTrue(SpaceAudioCheck.isPart(lengthMS: 80_000, recordingMS: 100_000))
    XCTAssertFalse(SpaceAudioCheck.isPart(lengthMS: 99_999, recordingMS: 100_000))
    XCTAssertFalse(SpaceAudioCheck.isPart(lengthMS: 0, recordingMS: 100_000))
    let nearlyAll = SpaceSegmentRef(
      parentItemID: SpaceID.new(), startMS: 0, endMS: 95_000, recordingMS: 100_000)
    XCTAssertFalse(SpaceAudioCheck.ok(durationMS: 95_000, segment: nearlyAll))
    let item = SpaceOutgoingItem(
      itemID: SpaceID.new(), kind: "audio_segment", fields: note("合成：片段"),
      originals: [("audio", Data(repeating: 1, count: 100))], segment: nearlyAll)
    XCTAssertEqual(SpaceEngine.refusal(item), "whole_recording")
  }

  // MARK: - V8R-11: the snapshot is what the member saw, of ticked items only

  func testTheSnapshotTextUsesOnlyFactsOfTickedItems() {
    let note = SpaceShareCandidate(
      id: "n1", sourceItemID: "n1", kind: .item, wireKind: "text", title: "便签", preview: "",
      startedAt: nil, isPrivateDictation: false, numberLabels: [], hasOriginal: false,
      audioPossible: false)
    let dictation = SpaceShareCandidate(
      id: "d1", sourceItemID: "d1", kind: .item, wireKind: "dictation", title: "口述",
      preview: "", startedAt: nil, isPrivateDictation: true, numberLabels: ["手机号"],
      hasOriginal: false, audioPossible: false)
    var review = SpaceShareReview(candidates: [note, dictation])
    XCTAssertEqual(review.ticked, ["n1"])
    let facts = [
      SpaceSnapshotText.Fact(text: "周四复测", sourceIDs: ["N1"]),
      SpaceSnapshotText.Fact(text: "联系 138 0013 8000", sourceIDs: ["d1"]),
      SpaceSnapshotText.Fact(text: "没有来源的要点", sourceIDs: []),
    ]
    var text = SpaceSnapshotText.make(
      title: "Twin-7", statusLine: "进展：私人口述里说的", facts: facts, review: review)
    XCTAssertEqual(text, "# Twin-7\n- 周四复测")
    XCTAssertFalse(SpaceSnapshotText.hasNumbers(text))
    review.toggle("d1")
    text = SpaceSnapshotText.make(
      title: "Twin-7", statusLine: "进展：私人口述里说的", facts: facts, review: review)
    XCTAssertTrue(text.contains("进展：") && text.contains("138 0013 8000"))
    XCTAssertTrue(SpaceSnapshotText.hasNumbers(text))
  }

  // MARK: - V8R-12: the relay's team lines follow the Spark's records

  func testRelayLinesAreWantedOnlyForOpenTicketsAndPairedMacs() throws {
    func record(_ json: String) throws -> AccessRecord {
      try JSONDecoder().decode(AccessRecord.self, from: Data(json.utf8))
    }
    func ticket(_ json: String) throws -> AccessTicketRecord {
      try JSONDecoder().decode(AccessTicketRecord.self, from: Data(json.utf8))
    }
    let openKey = SSHEd25519Key()
    let usedKey = SSHEd25519Key()
    let pairedKey = SSHEd25519Key()
    let unpairedKey = SSHEd25519Key()
    let tickets = [
      try ticket(
        #"{"ticket_id":"t1","kind":"member","status":"open","ssh_key":"\#(openKey.authorizedKey)"}"#
      ),
      try ticket(
        #"{"ticket_id":"t2","kind":"member","status":"used","ssh_key":"\#(usedKey.authorizedKey)"}"#
      ),
    ]
    let members = [
      try record(
        #"{"access_id":"a1","member_id":"m","device_id":"d","status":"active","ssh_key":"\#(pairedKey.authorizedKey)"}"#
      ),
      try record(
        #"{"access_id":"a2","member_id":"m","device_id":"e","status":"revoked","ssh_key":"\#(unpairedKey.authorizedKey)"}"#
      ),
    ]
    let wanted = TeamRelayLines.wanted(tickets: tickets, members: members)
    XCTAssertEqual(
      Set(wanted.keys),
      [
        TeamRelayLines.keyID(rawPublicKey: openKey.publicKeyRaw),
        TeamRelayLines.keyID(rawPublicKey: pairedKey.publicKeyRaw),
      ])
    XCTAssertEqual(
      wanted[TeamRelayLines.keyID(rawPublicKey: pairedKey.publicKeyRaw)], pairedKey.publicKeyBase64)
  }

  func testTheRelayHopOffersTheMembersOwnKeyBeforeTheTicketKey() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mlrelay-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let route = SSHGateRoute(
      spark: .init(host: "spark.test", port: 22, user: "nvidia", hostKey: FakeSpaceSpark.hostKey),
      relay: .init(host: "relay.test", port: 2200, user: "relay", hostKey: FakeSpaceSpark.hostKey),
      workDirectory: folder)
    let own = folder.appendingPathComponent(".k-own")
    let ticket = folder.appendingPathComponent(".k-ticket")
    let args = try route.arguments(command: "bridge", keyFile: own, relayKeyFiles: [own, ticket])
    let proxy = try XCTUnwrap(args.first { $0.hasPrefix("ProxyCommand=") })
    let ownAt = try XCTUnwrap(proxy.range(of: own.path))
    let ticketAt = try XCTUnwrap(proxy.range(of: ticket.path))
    XCTAssertLessThan(ownAt.lowerBound, ticketAt.lowerBound)
  }
}
