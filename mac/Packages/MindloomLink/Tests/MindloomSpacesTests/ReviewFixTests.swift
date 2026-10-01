import CryptoKit
import Foundation
import MindloomLink
import MindloomSpacesTestSupport
import XCTest

@testable import MindloomSpaces

/// A Spark that edits only what whoever runs the Spark account can edit: the
/// answers to GET /v1/spaces/{id}, …/keys and …/ops, and the 403 bodies. The
/// space routes behind it are the honest fake's. Synthetic data only.
final class LyingSpark: SpaceTransport, @unchecked Sendable {
  let honest: FakeSpaceSpark
  private let lock = NSLock()
  private var injected: (device: SpaceDevicePublic, member: String)?
  private var epochOverride: Int?
  private var forged: [SpaceJSON] = []
  private var fakeWrap: (epoch: Int, wrap: String)?
  private var dropRemovalProof = false
  private(set) var sent: [SpaceHTTPRequest] = []

  init(_ honest: FakeSpaceSpark) { self.honest = honest }

  func inject(_ device: SpaceDevicePublic, under member: String) {
    lock.withLock { injected = (device, member) }
  }
  func reportEpoch(_ epoch: Int?) { lock.withLock { epochOverride = epoch } }
  func appendToLog(_ entry: SpaceJSON) { lock.withLock { forged.append(entry) } }
  func offerWrap(epoch: Int, wrap: String) { lock.withLock { fakeWrap = (epoch, wrap) } }
  func withholdRemovalProof() { lock.withLock { dropRemovalProof = true } }

  /// The op JSONs a Mac posted through this Spark.
  var postedOps: [(op: SpaceJSON, wire: SpaceJSON)] {
    lock.withLock { sent }.filter { $0.method == "POST" && $0.target.hasSuffix("/ops") }.flatMap {
      request -> [(op: SpaceJSON, wire: SpaceJSON)] in
      guard let body = request.body, let json = try? SpaceJSON.decode(body) else { return [] }
      return (json["ops"]?.array ?? []).compactMap { wire in
        guard let b64 = wire["op"]?.string, let raw = Base64URL.decode(b64, allowPadding: true),
          let op = try? SpaceJSON.decode(raw)
        else { return nil }
        return (op, wire)
      }
    }
  }

  func send(_ request: SpaceHTTPRequest) async throws -> SpaceHTTPResponse {
    lock.withLock { sent.append(request) }
    let response = try await honest.send(request)
    let path = request.target.split(separator: "?").first.map(String.init) ?? request.target
    let parts = path.split(separator: "/").map(String.init)
    guard var json = try? SpaceJSON.decode(response.body) else { return response }
    let (device, epoch, extra, wrap, drop) = lock.withLock {
      (injected, epochOverride, forged, fakeWrap, dropRemovalProof)
    }
    if response.status == 403, json["error"]?.string == "not_member", drop {
      json = json.setting("removal", .null)
      return SpaceHTTPResponse(status: 403, body: try json.encoded())
    }
    guard request.method == "GET", response.status == 200, parts.count >= 3, parts[1] == "spaces"
    else { return response }
    if parts.count == 3 {
      if let device, case .array(var members) = json["members"] ?? .null {
        for index in members.indices where members[index]["member_id"]?.string == device.member {
          var devices = members[index]["devices"]?.array ?? []
          devices.append(device.device.json.setting("status", "active"))
          members[index] = members[index].setting("devices", .array(devices))
        }
        json = json.setting("members", .array(members))
      }
      if let epoch { json = json.setting("epoch", SpaceJSON(epoch)) }
    } else if parts.count == 4, parts[3] == "keys" {
      if let epoch { json = json.setting("epoch", SpaceJSON(epoch)) }
      if let wrap, case .array(var wraps) = json["wraps"] ?? .null {
        wraps.append(["epoch": SpaceJSON(wrap.epoch), "wrap": .string(wrap.wrap)])
        json = json.setting("wraps", .array(wraps))
      }
    } else if parts.count == 4, parts[3] == "ops", !extra.isEmpty, var ops = json["ops"]?.array {
      var head = json["head"]?.int ?? 0
      for entry in extra {
        head += 1
        ops.append(entry.setting("seq", SpaceJSON(head)))
      }
      json = json.setting("ops", .array(ops)).setting("head", SpaceJSON(head))
        .setting("cursor", SpaceJSON(head)).setting("more", false)
      lock.withLock { forged = [] }
    }
    return SpaceHTTPResponse(status: 200, body: try json.encoded())
  }
}

/// Masks every digit run of 6+ (a stand-in for the Mac's masker, which the
/// BestASRCore tests cover).
struct DigitMasker: SpaceTextMasking {
  func mask(_ text: String, maskKey: Data) throws -> String {
    text.replacingOccurrences(of: "[0-9]{6,}", with: "〔号码〕", options: .regularExpression)
  }
}

/// XCTUnwrap for a value an `await` produced (XCTUnwrap's autoclosure cannot await).
func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
  try XCTUnwrap(value, file: file, line: line)
}

/// Regression tests for the v7 review of the Mac's shared spaces (V7-S*).
final class ReviewFixTests: XCTestCase {
  static let endpoint = SpaceInviteCode.Endpoint(
    host: "spark.test", port: 22, user: "member", hostKey: FakeSpaceSpark.hostKey)
  static let sentinel = "评审哨兵-QX7-移除后共享"

  struct Member {
    let engine: SpaceEngine
    let keys: MemorySpaceKeyStore
    let states: MemorySpaceStateStore
    let device: SpaceDeviceKeys

    /// The same Mac after a restart: a new engine on the same stores.
    func restarted(_ transport: any SpaceTransport, _ spark: FakeSpaceSpark) -> Member {
      Member(
        engine: SpaceEngine(
          client: SpaceClient(transport: transport, device: device, now: { spark.now }),
          states: states, keys: keys, textMasker: DigitMasker(), now: { spark.now }),
        keys: keys, states: states, device: device)
    }
  }

  private func mac(_ transport: any SpaceTransport, _ spark: FakeSpaceSpark, masker: Bool = true)
    -> Member
  {
    let keys = MemorySpaceKeyStore()
    let states = MemorySpaceStateStore()
    let device = SpaceDeviceKeys.generate()
    let engine = SpaceEngine(
      client: SpaceClient(transport: transport, device: device, now: { spark.now }),
      states: states, keys: keys, textMasker: masker ? DigitMasker() : nil, now: { spark.now })
    return Member(engine: engine, keys: keys, states: states, device: device)
  }

  private func note(_ text: String) -> SpaceItemFields {
    SpaceItemFields(
      kind: "text", title: String(text.prefix(10)), text: text, sourceName: "备忘录",
      startedAt: "2026-09-20T09:00:00+08:00", originMatterID: nil)
  }

  /// A creates a space (group, or org) and admits the others.
  private func space(
    _ a: Member, _ others: [Member], _ spark: FakeSpaceSpark, owner: SpaceOwnerKind = .person
  ) async throws -> String {
    var orgID: String?
    var orgMember: String?
    if owner == .org {
      let org = try await a.engine.createOrg()
      orgID = org.orgID
      orgMember = org.memberID
    }
    let created = try await a.engine.createSpace(
      name: "评审空间", owner: owner, orgID: orgID, orgMemberID: orgMember, displayName: "甲",
      spark: Self.endpoint)
    for (n, other) in others.enumerated() {
      let code = try await a.engine.invite(
        created.spaceID, role: .write, hostKey: FakeSpaceSpark.hostKey, spark: Self.endpoint)
      let decoded = try SpaceInviteCode.decode(try code.encoded(), now: spark.now)
      _ = try await other.engine.join(
        code: decoded, displayName: "成员\(n)", localHostKey: FakeSpaceSpark.hostKey)
      let request = try unwrap(try await a.engine.joinRequests(created.spaceID).first)
      XCTAssertNil(request.warning)
      try await a.engine.approve(created.spaceID, request: request)
      _ = try await other.engine.refreshJoin(created.spaceID)
    }
    _ = try await a.engine.sync(created.spaceID)
    return created.spaceID
  }

  // MARK: - V7-S1: members and devices from the signed log only

  func testRotationNeverWrapsTheNewKeyToADeviceNoMemberAdmitted() async throws {
    let spark = FakeSpaceSpark()
    let liar = LyingSpark(spark)
    let a = mac(liar, spark)
    let b = mac(spark, spark)
    let spaceID = try await space(a, [b], spark)
    let bMember = try unwrap(try await b.engine.state(spaceID)).memberID
    let evil = SpaceDeviceKeys.generate()
    liar.inject(evil.publicRecord, under: bMember)
    let synced = try await a.engine.sync(spaceID)
    XCTAssertEqual(synced.integrityWarnings, ["unknown_device_listed"])
    XCTAssertFalse(synced.member(bMember)?.devices.contains { $0.deviceID == evil.deviceID } ?? true)
    try await a.engine.rotate(spaceID)
    let rotate = try XCTUnwrap(liar.postedOps.last { $0.op["type"]?.string == "epoch.rotate" })
    let wraps = try XCTUnwrap(rotate.op["body"]?["wraps"]?.array)
    XCTAssertFalse(wraps.contains { $0["device_id"]?.string == evil.deviceID })
    XCTAssertEqual(
      Set(wraps.compactMap { $0["device_id"]?.string }), [a.device.deviceID, b.device.deviceID])
    // B (an honest Mac) still reads what A shares under the new epoch.
    let item = SpaceID.new()
    _ = try await a.engine.share(
      spaceID, items: [SpaceOutgoingItem(itemID: item, kind: "text", fields: note("换钥匙之后"))])
    let bState = try await b.engine.sync(spaceID)
    XCTAssertEqual(bState.epoch, 2)
    XCTAssertEqual(bState.items[item]?.fields?.text, "换钥匙之后")
  }

  func testAnOpSignedByADeviceTheSparkListedIsNotAppliedAsAMembers() async throws {
    let spark = FakeSpaceSpark()
    let liar = LyingSpark(spark)
    let a = mac(liar, spark)
    let b = mac(spark, spark)
    let spaceID = try await space(a, [b], spark)
    let itemID = SpaceID.new()
    _ = try await b.engine.share(
      spaceID, items: [SpaceOutgoingItem(itemID: itemID, kind: "text", fields: note("乙的条目"))])
    _ = try await a.engine.sync(spaceID)
    let bMember = try unwrap(try await b.engine.state(spaceID)).memberID
    let evil = SpaceDeviceKeys.generate()
    liar.inject(evil.publicRecord, under: bMember)
    let forged = try evil.op(
      space: spaceID, member: bMember, type: "item.withdraw", body: ["item_id": .string(itemID)])
    liar.appendToLog([
      "type": "item.withdraw", "applied_at": "2026-09-30T00:00:00+00:00",
      "op": .string(Base64URL.encode(forged.opJSON)), "sig": .string(forged.signature),
      "enc": nil, "purged": false,
    ])
    let before = try unwrap(try await a.engine.state(spaceID)).rejectedOps
    let after = try await a.engine.sync(spaceID)
    XCTAssertEqual(after.items[itemID]?.isActive, true)
    XCTAssertEqual(after.rejectedOps, before + 1)
  }

  func testJoinApproveCarriesTheJoinersKeysAndTheRosterComesFromIt() async throws {
    let spark = FakeSpaceSpark()
    let a = mac(spark, spark)
    let b = mac(spark, spark)
    let spaceID = try await space(a, [b], spark)
    let state = try unwrap(try await a.engine.state(spaceID))
    let roster = try XCTUnwrap(state.roster)
    let bMember = try unwrap(try await b.engine.state(spaceID)).memberID
    XCTAssertEqual(
      roster.device(member: bMember, device: b.device.deviceID)?.signKey, b.device.signPublicKey)
    XCTAssertEqual(roster.epoch, 1)
    // B rebuilt the same roster from the same signed log.
    let bRoster = try unwrap(try await b.engine.state(spaceID)?.roster)
    XCTAssertEqual(bRoster.activeDeviceIDs, roster.activeDeviceIDs)
  }

  // MARK: - V7-S10: no going back to an older epoch, no key the Spark made up

  func testNewItemsAreNeverEncryptedUnderAnEpochOlderThanTheLogs() async throws {
    let spark = FakeSpaceSpark()
    let liar = LyingSpark(spark)
    let a = mac(liar, spark)
    let b = mac(spark, spark)
    let c = mac(spark, spark)
    let spaceID = try await space(a, [b, c], spark)
    let removedKey = try XCTUnwrap(try b.keys.keys(spaceID)[1])
    let bMember = try unwrap(try await b.engine.state(spaceID)).memberID
    try await a.engine.removeMember(spaceID, memberID: bMember)
    liar.reportEpoch(1)
    let synced = try await a.engine.sync(spaceID)
    XCTAssertEqual(synced.epoch, 2)
    XCTAssertEqual(synced.integrityWarnings, ["spark_epoch_behind"])
    let itemID = SpaceID.new()
    _ = try? await a.engine.share(
      spaceID,
      items: [SpaceOutgoingItem(itemID: itemID, kind: "text", fields: note(Self.sentinel))])
    let share = try XCTUnwrap(liar.postedOps.last { $0.op["type"]?.string == "item.share" })
    XCTAssertEqual(share.op["epoch"]?.int, 2)
    let wrapped = try XCTUnwrap(share.wire["wrapped_dk"]?.string)
    XCTAssertNil(
      try? SpaceCrypto.unwrapItemKey(
        wrapped, spaceKey: removedKey, spaceID: spaceID, epoch: 1, itemID: itemID))
  }

  func testAWrapTheSparkMadeUpIsNeverUsed() async throws {
    let spark = FakeSpaceSpark()
    let liar = LyingSpark(spark)
    let a = mac(liar, spark)
    let b = mac(spark, spark)
    let spaceID = try await space(a, [b], spark)
    // The Spark seals a key of its own to A's device and says it is epoch 2.
    let sparksKey = SpaceCrypto.randomKey()
    liar.offerWrap(
      epoch: 2,
      wrap: try SpaceCrypto.wrapSpaceKey(
        sparksKey, to: a.device.sealPublicKey, spaceID: spaceID, epoch: 2,
        deviceID: a.device.deviceID))
    liar.reportEpoch(2)
    let synced = try await a.engine.sync(spaceID)
    XCTAssertEqual(synced.epoch, 1)
    XCTAssertNil(try a.keys.keys(spaceID)[2])
    let itemID = SpaceID.new()
    _ = try? await a.engine.share(
      spaceID,
      items: [SpaceOutgoingItem(itemID: itemID, kind: "text", fields: note(Self.sentinel))])
    let share = try XCTUnwrap(liar.postedOps.last { $0.op["type"]?.string == "item.share" })
    XCTAssertEqual(share.op["epoch"]?.int, 1)
    let wrapped = try XCTUnwrap(share.wire["wrapped_dk"]?.string)
    XCTAssertNil(
      try? SpaceCrypto.unwrapItemKey(
        wrapped, spaceKey: sparksKey, spaceID: spaceID, epoch: 2, itemID: itemID))
  }

  // MARK: - V7-S9 / V7-S2: what the inviter checks before 同意

  func testTheJoinRequestCarriesNoSecretAndAForgedOneCannotBeApproved() async throws {
    let spark = FakeSpaceSpark()
    let a = mac(spark, spark)
    let created = try await a.engine.createSpace(
      name: "邀请", owner: .person, displayName: "甲", spark: Self.endpoint)
    let code = try await a.engine.invite(
      created.spaceID, role: .write, hostKey: FakeSpaceSpark.hostKey, spark: Self.endpoint)
    let secret = try XCTUnwrap(code.secretBytes)
    // What an honest joiner sends: the gate and the binding, never the secret.
    let joiner = SpaceDeviceKeys.generate()
    let wire = try joiner.joinRequest(
      space: created.spaceID, inviteID: code.inviteID, secret: secret, member: SpaceID.new(),
      profile: nil)
    let text = String(decoding: try wire.encoded(), as: UTF8.self)
    XCTAssertNil(wire["invite_secret"])
    XCTAssertFalse(text.contains(Base64URL.encode(secret)))
    XCTAssertFalse(text.contains(SpaceCrypto.hex(secret)))
    // The Spark (it saw the gate) files a request for its own device with a
    // binding it cannot make: the inviter's Mac refuses to approve it.
    let evil = SpaceDeviceKeys.generate()
    var forged = try evil.joinRequest(
      space: created.spaceID, inviteID: code.inviteID, secret: SpaceCrypto.randomKey(),
      member: SpaceID.new(), profile: nil)
    forged = forged.setting("invite_gate", wire["invite_gate"] ?? .null)
    _ = try await a.engine.client.join(created.spaceID, request: forged)
    let request = try unwrap(try await a.engine.joinRequests(created.spaceID).first)
    XCTAssertTrue(request.blocked)
    XCTAssertNotNil(request.warning)
    do {
      try await a.engine.approve(created.spaceID, request: request)
      XCTFail("a request without the invite's binding was approved")
    } catch SpaceEngine.EngineError.refused(let code) {
      XCTAssertEqual(code, "join_request_unverified")
    }
    XCTAssertFalse(
      String(decoding: spark.everythingReceived, as: UTF8.self).contains(
        Base64URL.encode(secret)))
  }

  func testAJoinRequestUnderAKnownMembersIDWithAnotherKeyIsBlocked() async throws {
    let spark = FakeSpaceSpark()
    let a = mac(spark, spark)
    let b = mac(spark, spark)
    let first = try await space(a, [b], spark)
    let bMember = try unwrap(try await b.engine.state(first)).memberID
    // A second space; someone asks to join it under B's member id from another device.
    let second = try await a.engine.createSpace(
      name: "第二个", owner: .person, displayName: "甲", spark: Self.endpoint)
    let code = try await a.engine.invite(
      second.spaceID, role: .read, hostKey: FakeSpaceSpark.hostKey, spark: Self.endpoint)
    let mallory = SpaceDeviceKeys.generate()
    let wire = try mallory.joinRequest(
      space: second.spaceID, inviteID: code.inviteID, secret: try XCTUnwrap(code.secretBytes),
      member: bMember, profile: nil)
    do {
      _ = try await a.engine.client.join(second.spaceID, request: wire)
      XCTFail("the Spark took a member id bound to another key")
    } catch SpaceClientError.server(let error) {
      XCTAssertEqual(error.code, "member_id_taken")
    }
  }

  // MARK: - V7-S14: the invite must pin this Mac's own host key

  func testJoinRefusesAnInviteThatPinsAnotherHostKey() async throws {
    let spark = FakeSpaceSpark()
    let a = mac(spark, spark)
    let b = mac(spark, spark)
    let created = try await a.engine.createSpace(
      name: "主机钥匙", owner: .person, displayName: "甲", spark: Self.endpoint)
    let code = try await a.engine.invite(
      created.spaceID, role: .write, hostKey: FakeSpaceSpark.hostKey, spark: Self.endpoint)
    for local in [nil, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherMachineEntirely000000000000000"] {
      do {
        _ = try await b.engine.join(code: code, displayName: "乙", localHostKey: local)
        XCTFail("joined through a link that reaches another machine")
      } catch SpaceEngine.EngineError.refused(let code) {
        XCTAssertEqual(code, "host_key_mismatch")
      }
    }
    _ = try await b.engine.join(
      code: code, displayName: "乙", localHostKey: FakeSpaceSpark.hostKey + " known_hosts")
  }

  // MARK: - V7-S16: only signed records delete anything

  func testAnUnsignedRemovalWithoutAnOverduePrivacyTakedownIsIgnored() async throws {
    let spark = FakeSpaceSpark()
    let liar = LyingSpark(spark)
    let a = mac(liar, spark)
    let b = mac(spark, spark)
    let spaceID = try await space(a, [b], spark)
    let itemID = SpaceID.new()
    _ = try await b.engine.share(
      spaceID, items: [SpaceOutgoingItem(itemID: itemID, kind: "text", fields: note("留着"))])
    _ = try await a.engine.sync(spaceID)
    let record: SpaceJSON = [
      "v": 1, "space_id": .string(spaceID), "op_id": .string(SpaceID.new()),
      "type": "system.remove", "member_id": nil, "device_id": nil,
      "created_at": "2026-09-30T00:00:00+00:00",
      "body": [
        "item_id": .string(itemID), "reason": "takedown_overdue",
        "takedown_id": .string(SpaceID.new()),
      ],
    ]
    liar.appendToLog([
      "type": "system.remove", "applied_at": "2026-09-30T00:00:00+00:00",
      "op": .string(Base64URL.encode(try record.encoded())), "sig": nil, "enc": nil,
      "purged": false,
    ])
    let after = try await a.engine.sync(spaceID)
    XCTAssertEqual(after.items[itemID]?.isActive, true)
  }

  func testNotAMemberWithoutASignedRemovalDeletesNothing() async throws {
    let spark = FakeSpaceSpark()
    let liar = LyingSpark(spark)
    let a = mac(spark, spark)
    let b = mac(liar, spark)
    let spaceID = try await space(a, [b], spark)
    let item = SpaceID.new()
    _ = try await a.engine.share(
      spaceID, items: [SpaceOutgoingItem(itemID: item, kind: "text", fields: note("可以存一份"))])
    _ = try await b.engine.sync(spaceID)
    try await b.engine.fork(spaceID, itemID: item)
    try await b.engine.recordForkCopy(spaceID, itemID: item, localID: "LOCAL-COPY-9")
    let bMember = try unwrap(try await b.engine.state(spaceID)).memberID
    try await a.engine.removeMember(spaceID, memberID: bMember)
    // The Spark answers "not a member" but keeps the signed removal back.
    liar.withholdRemovalProof()
    do { _ = try await b.engine.sync(spaceID) } catch SpaceClientError.accessEnded {}
    let kept = try await b.engine.state(spaceID)
    XCTAssertNotNil(kept)
    XCTAssertEqual(kept?.integrityWarnings, ["not_member_unsigned"])
    XCTAssertNotNil(try b.keys.keys(spaceID)[1])
    let none = await b.engine.forkCopiesToDelete()
    XCTAssertEqual(none, [])
    // With the signed removal, the space and the copy go.
    let honest = b.restarted(spark, spark)
    do { _ = try await honest.engine.sync(spaceID) } catch SpaceClientError.accessEnded {}
    let gone = try await honest.engine.state(spaceID)
    XCTAssertNil(gone)
    let copies = await honest.engine.forkCopiesToDelete()
    XCTAssertEqual(copies, ["LOCAL-COPY-9"])
  }

  // MARK: - V7-S15: fork copies to delete survive a restart; privacy removals take them

  func testForkCopiesToDeleteSurviveARestartAndGoWithAPrivacyRemoval() async throws {
    let spark = FakeSpaceSpark()
    let a = mac(spark, spark)
    let b = mac(spark, spark)
    let spaceID = try await space(a, [b], spark)
    let item = SpaceID.new()
    _ = try await a.engine.share(
      spaceID, items: [SpaceOutgoingItem(itemID: item, kind: "text", fields: note("有隐私"))])
    _ = try await b.engine.sync(spaceID)
    try await b.engine.fork(spaceID, itemID: item)
    try await b.engine.recordForkCopy(spaceID, itemID: item, localID: "LOCAL-COPY-PRIV")
    try await a.engine.remove(spaceID, itemID: item, reason: "privacy")
    _ = try await b.engine.sync(spaceID)
    // B's Mac quits before the App deletes the copy; after the restart it is still owed.
    let restarted = b.restarted(spark, spark)
    let owed = await restarted.engine.forkCopiesToDelete()
    XCTAssertEqual(owed, ["LOCAL-COPY-PRIV"])
    await restarted.engine.forkCopiesDeleted(owed)
    let done = await restarted.engine.forkCopiesToDelete()
    XCTAssertEqual(done, [])
  }

  // MARK: - V7-S17: another member's clear does not touch my rule

  func testAnotherMembersRuleClearDoesNotClearMine() async throws {
    let spark = FakeSpaceSpark()
    let a = mac(spark, spark)
    let b = mac(spark, spark)
    let spaceID = try await space(a, [b], spark)
    let rule = try await a.engine.setRule(
      spaceID, kind: "rope", targetID: "rope-1", title: "绳", auto: .auto)
    // B clears a rule with A's id (the fake, like an old Spark, lets it through).
    let bState = try unwrap(try await b.engine.state(spaceID))
    let op = try b.device.op(
      space: spaceID, member: bState.memberID, type: "share_rule.clear",
      body: ["rule_id": .string(rule)])
    _ = try await b.engine.client.submit(spaceID, [op])
    let aState = try await a.engine.sync(spaceID)
    XCTAssertEqual(aState.rules[rule]?.active, true)
  }

  // MARK: - V7-S12: deleting my item on the Mac takes it out of the space

  func testDeletingTheLocalSourceWithdrawsWhatThisMacSharedEvenAfterARestart() async throws {
    let spark = FakeSpaceSpark()
    let a = mac(spark, spark)
    let b = mac(spark, spark)
    let spaceID = try await space(a, [b], spark)
    let note = SpaceID.new()
    let recording = SpaceID.new()
    let part = SpaceID.segment(parent: recording, startMS: 0, endMS: 60_000)
    _ = try await a.engine.share(
      spaceID,
      items: [
        SpaceOutgoingItem(itemID: note, kind: "text", fields: self.note("要删的笔记")),
        SpaceOutgoingItem(
          itemID: part, kind: "audio_segment", fields: self.note("录音的一段"),
          segment: SpaceSegmentRef(parentItemID: recording, startMS: 0, endMS: 60_000)),
      ])
    let sources = try await a.engine.sharedSources()
    XCTAssertEqual(sources, [note, recording])
    // The user deletes both locally while the link is down: queued, not lost.
    spark.offline = true
    let queued = try await a.engine.localItemsDeleted([note.uppercased(), recording])
    XCTAssertEqual(queued, 2)
    _ = try? await a.engine.flushDeletes(spaceID)
    spark.offline = false
    let restarted = a.restarted(spark, spark)
    let queuedAfterRestart = try await restarted.engine.state(spaceID)?.pendingDeletes?.count
    XCTAssertEqual(queuedAfterRestart, 2)
    let sent = try await restarted.engine.flushDeletes(spaceID)
    XCTAssertEqual(sent, 2)
    let bState = try await b.engine.sync(spaceID)
    XCTAssertEqual(bState.items[note]?.status, .withdrawn)
    XCTAssertEqual(bState.items[part]?.status, .withdrawn)
    let emptied = try await restarted.engine.state(spaceID)?.pendingDeletes
    XCTAssertNil(emptied)
  }

  func testPastAnOrgWindowADeletedSourceBecomesATakedownRequest() async throws {
    let spark = FakeSpaceSpark()
    let a = mac(spark, spark)
    let b = mac(spark, spark)
    let spaceID = try await space(a, [b], spark, owner: .org)
    let item = SpaceID.new()
    _ = try await b.engine.share(
      spaceID, items: [SpaceOutgoingItem(itemID: item, kind: "text", fields: note("组织资产"))])
    spark.advance(hours: 25)
    _ = try await b.engine.localItemsDeleted([item])
    _ = try await b.engine.flushDeletes(spaceID)
    let aState = try await a.engine.sync(spaceID)
    XCTAssertEqual(aState.items[item]?.status, .active)
    XCTAssertTrue(aState.takedowns.values.contains { $0.itemID == item && $0.status == "open" })
  }

  // MARK: - V7-S5: one part of a recording, at most 15 minutes

  func testAWholeRecordingCannotGoAsConsecutiveParts() async throws {
    let spark = FakeSpaceSpark()
    let a = mac(spark, spark)
    let spaceID = try await space(a, [], spark)
    let recording = SpaceID.new()
    let parts = (0..<8).map { n -> SpaceOutgoingItem in
      let start = n * 900_000
      return SpaceOutgoingItem(
        itemID: SpaceID.segment(parent: recording, startMS: start, endMS: start + 900_000),
        kind: "audio_segment", fields: note("第\(n)段"),
        segment: SpaceSegmentRef(parentItemID: recording, startMS: start, endMS: start + 900_000))
    }
    let report = try await a.engine.share(spaceID, items: parts)
    XCTAssertEqual(report.shared.count, 1)
    XCTAssertEqual(
      Set(report.refused.values), ["recording_share_limit"], "\(report.refused)")
    // The review list: parts start unticked; ticking one unticks the others.
    let candidates = parts.map { part in
      SpaceShareCandidate(
        id: part.itemID, sourceItemID: recording,
        kind: .segment(
          parentItemID: recording, startMS: part.segment!.startMS, endMS: part.segment!.endMS),
        wireKind: "audio_segment", title: "段", preview: "", startedAt: nil,
        isPrivateDictation: false, numberLabels: [], hasOriginal: false)
    }
    var review = SpaceShareReview(candidates: candidates)
    XCTAssertTrue(review.selected.isEmpty)
    review.toggle(candidates[0].id)
    review.toggle(candidates[3].id)
    XCTAssertEqual(review.selected.map(\.id), [candidates[3].id])
    XCTAssertNotNil(candidates[0].untickedReason)
  }

  // MARK: - V7-S13: a maintainer's title reaches the organizer masked

  func testAMaintainersRenameIsMaskedBeforeTheOrganizer() async throws {
    let spark = FakeSpaceSpark()
    let a = mac(spark, spark)
    let spaceID = try await space(a, [], spark)
    _ = try await a.engine.editMatters(
      spaceID,
      decisions: [
        [
          "decision_id": .string(SpaceID.new()), "kind": "rename_event", "event_id": "e1",
          "title": "给 13812345678 回电话",
        ]
      ])
    let sent = String(decoding: spark.everythingReceived, as: UTF8.self)
    XCTAssertFalse(sent.contains("13812345678"))
    XCTAssertTrue(sent.contains("〔号码〕"))
    let bare = mac(spark, spark, masker: false)
    let other = try await space(bare, [], spark)
    do {
      _ = try await bare.engine.editMatters(
        other, decisions: [["kind": "rename_event", "event_id": "e1", "title": "13812345678"]])
      XCTFail("a title went out unmasked")
    } catch SpaceEngine.EngineError.refused(let code) {
      XCTAssertEqual(code, "no_masker")
    }
  }
}
