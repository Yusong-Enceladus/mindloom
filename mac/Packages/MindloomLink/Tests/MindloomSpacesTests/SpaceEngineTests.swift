import CryptoKit
import Foundation
import MindloomLink
import MindloomSpacesTestSupport
import XCTest

@testable import MindloomSpaces

/// Records the mask key it was given and masks every digit run of 6+ (a
/// stand-in for the Mac's masking rules; the real masker is tested with the
/// library in BestASRCore).
final class RecordingPayloadBuilder: SpacePayloadBuilding, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var maskKeys: [Data] = []
  private(set) var built: [String] = []

  func payload(
    item: SpaceSharedItem, fields: SpaceItemFields, maskKey: Data,
    original: @escaping @Sendable (SpaceBlobRef) async throws -> Data?
  ) async throws -> Data? {
    lock.withLock {
      maskKeys.append(maskKey)
      built.append(item.itemID)
    }
    let tag = SpaceCrypto.hex(maskKey).prefix(6)
    let masked = (fields.text ?? "").replacingOccurrences(
      of: "[0-9]{6,}", with: "〔号码·\(tag)〕", options: .regularExpression)
    let payload: SpaceJSON = [
      "item_id": .string(item.itemID), "revision": SpaceJSON(item.revision), "kind": "text",
      "source_app": ["name": "测试"], "started_at": "2026-09-20T09:00:00+08:00",
      "text": .string(masked), "sha256": .string(SpaceCrypto.sha256Hex(Data(masked.utf8))),
      "origin_matter_id": SpaceJSON(fields.originMatterID),
    ]
    return try payload.encoded()
  }
}

final class SpaceEngineTests: XCTestCase {
  static let endpoint = SpaceInviteCode.Endpoint(
    host: "spark.test", port: 22, user: "member", hostKey: FakeSpaceSpark.hostKey)
  static let sentinel = "哨兵-SPACE-7f3a"

  private func note(_ text: String, matter: String? = nil) -> SpaceItemFields {
    SpaceItemFields(
      kind: "text", title: String(text.prefix(10)), text: text, sourceName: "备忘录",
      startedAt: "2026-09-20T09:00:00+08:00", originMatterID: matter)
  }

  /// A creates a space, invites B, B joins with a name only A can read, A
  /// approves after comparing fingerprints.
  private func twoMembers(
    _ spark: FakeSpaceSpark, owner: SpaceOwnerKind = .person, policy: SpacePolicy? = nil,
    role: SpaceRole = .write
  ) async throws -> (TestMac, TestMac, String) {
    let a = TestMac("A", spark: spark)
    let b = TestMac("B", spark: spark)
    var orgID: String?
    var orgMember: String?
    if owner == .org {
      let org = try await a.engine.createOrg()
      orgID = org.orgID
      orgMember = org.memberID
    }
    let created = try await a.engine.createSpace(
      name: "拾光咖啡馆", owner: owner, orgID: orgID, orgMemberID: orgMember, policy: policy,
      displayName: "林知远", spark: Self.endpoint)
    let code = try await a.engine.invite(
      created.spaceID, role: role, hostKey: FakeSpaceSpark.hostKey, spark: Self.endpoint)
    let text = try code.encoded()
    let decoded = try SpaceInviteCode.decode(text, now: spark.now)
    let pending = try await b.engine.join(
      code: decoded, displayName: "韩策", localHostKey: FakeSpaceSpark.hostKey)
    XCTAssertEqual(pending.membership, .pending)
    let requests = try await a.engine.joinRequests(created.spaceID)
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.displayName, "韩策")
    let bDevice = await b.engine.device
    XCTAssertEqual(request.fingerprint, bDevice.fingerprint)
    try await a.engine.approve(created.spaceID, request: request)
    let joined = try await b.engine.refreshJoin(created.spaceID)
    XCTAssertEqual(joined.membership, .active)
    _ = try await a.engine.sync(created.spaceID)
    return (a, b, created.spaceID)
  }

  // MARK: - Create, invite, join, share, read

  func testTwoMembersShareAndEachReadsTheOthersItemsWhileTheSparkHoldsOnlyCiphertext() async throws
  {
    let spark = FakeSpaceSpark()
    let (a, b, spaceID) = try await twoMembers(spark)
    let aItem = SpaceID.new()
    let bItem = SpaceID.new()
    let original = Data("%PDF-1.7 \(Self.sentinel) 原件".utf8)
    let aReport = try await a.engine.share(
      spaceID,
      items: [
        SpaceOutgoingItem(
          itemID: aItem, kind: "document",
          fields: note("租约草稿 \(Self.sentinel)，房东电话 13812345678", matter: "matter-a"),
          originals: [("original", original)])
      ],
      package: SpacePackageRequest(auto: .ask, matterID: "matter-a", title: "拾光咖啡馆开业筹备"))
    XCTAssertEqual(aReport.shared, [aItem])
    XCTAssertNotNil(aReport.packageID)
    let bReport = try await b.engine.share(
      spaceID,
      items: [
        SpaceOutgoingItem(
          itemID: bItem, kind: "text", fields: note("装修报价 \(Self.sentinel) 3 万", matter: "matter-b")
        )
      ])
    XCTAssertEqual(bReport.shared, [bItem])

    let aState = try await a.engine.sync(spaceID)
    let bState = try await b.engine.sync(spaceID)
    // Each opens the other's fields, numbers as they are.
    XCTAssertEqual(
      bState.items[aItem]?.fields?.text, "租约草稿 \(Self.sentinel)，房东电话 13812345678")
    XCTAssertEqual(aState.items[bItem]?.fields?.text, "装修报价 \(Self.sentinel) 3 万")
    XCTAssertEqual(bState.items[aItem]?.contributor, aState.memberID)
    // Names travel encrypted: both know each other.
    XCTAssertEqual(aState.name(of: bState.memberID), "韩策")
    XCTAssertEqual(bState.name(of: aState.memberID), "林知远")
    XCTAssertEqual(bState.name, "拾光咖啡馆")
    // B opens A's original.
    let blob = try XCTUnwrap(bState.items[aItem]?.blobs.first)
    let opened = try await b.engine.original(spaceID, itemID: aItem, blob: blob)
    XCTAssertEqual(opened, original)
    XCTAssertEqual(bState.packages.values.first?.title, "拾光咖啡馆开业筹备")

    // The Spark never received a name, a space name, a number or the sentinel.
    let wire = String(decoding: spark.everythingReceived, as: UTF8.self)
    for plain in [Self.sentinel, "13812345678", "韩策", "林知远", "拾光咖啡馆", "租约草稿", "原件"] {
      XCTAssertFalse(wire.contains(plain), "\(plain) reached the Spark")
    }
    let stored = try XCTUnwrap(spark.space(spaceID))
    for blob in stored.blobs.values where !blob.data.isEmpty {
      XCTAssertEqual(blob.data.prefix(4), Data("MLB1".utf8))
    }
  }

  func testAnOpThatFailsVerificationIsNeverApplied() async throws {
    let spark = FakeSpaceSpark()
    let (a, b, spaceID) = try await twoMembers(spark)
    let item = SpaceID.new()
    _ = try await a.engine.share(
      spaceID, items: [SpaceOutgoingItem(itemID: item, kind: "text", fields: note("原文"))])
    let shareSeq = try XCTUnwrap(spark.space(spaceID)?.log.last?.seq)
    // The Spark rewrites the op (e.g. claims another item id).
    spark.tamper(space: spaceID, seq: shareSeq) { bytes in
      bytes = Data(
        String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: item, with: SpaceID.new())
          .utf8)
    }
    // And appends an op signed by a device the space does not know.
    let stranger = SpaceDeviceKeys.generate()
    let forged = try stranger.op(
      space: spaceID, member: SpaceID.new(), type: "item.remove",
      body: ["item_id": .string(item)])
    spark.injectForeignOp(space: spaceID, op: forged)
    let state = try await b.engine.sync(spaceID)
    XCTAssertNil(state.items[item])
    XCTAssertEqual(state.items.count, 0)
    XCTAssertEqual(state.rejectedOps, 2)
  }

  // MARK: - Rotation and access loss

  func testRemovalRotatesTheKeyAndTheRemovedMacCannotReadNewItemsAndPurgesItsCopy() async throws {
    let spark = FakeSpaceSpark()
    let (a, b, spaceID) = try await twoMembers(spark)
    let before = SpaceID.new()
    _ = try await b.engine.share(
      spaceID, items: [SpaceOutgoingItem(itemID: before, kind: "text", fields: note("B 的条目"))])
    let epoch1 = try XCTUnwrap(b.keys.keys(spaceID)[1])
    try await a.engine.removeMember(spaceID, memberID: try await b.engine.state(spaceID)!.memberID)
    let aState = try await a.engine.sync(spaceID)
    XCTAssertEqual(aState.epoch, 2)
    // B's contribution stays attributed.
    XCTAssertTrue(aState.items[before]?.isActive == true)
    let after = SpaceID.new()
    _ = try await a.engine.share(
      spaceID, items: [SpaceOutgoingItem(itemID: after, kind: "text", fields: note("新条目"))])
    // The new item's key is under epoch 2: B's epoch-1 key cannot open it.
    let wrapped = try XCTUnwrap(spark.space(spaceID)?.itemKeys[after])
    XCTAssertEqual(wrapped.epoch, 2)
    XCTAssertThrowsError(
      try SpaceCrypto.unwrapItemKey(
        wrapped.wrapped, spaceKey: epoch1, spaceID: spaceID, epoch: 2, itemID: after))
    // B's next request answers not_member: its copy of the space is deleted.
    do {
      _ = try await b.engine.sync(spaceID)
      XCTFail("the removed Mac still synced")
    } catch SpaceClientError.accessEnded {}
    let gone = try await b.engine.state(spaceID)
    XCTAssertNil(gone)
    XCTAssertTrue(try b.keys.keys(spaceID).isEmpty)
    // The remaining member reaches epoch 1 through the link and re-wraps lazily.
    XCTAssertNotNil(try a.keys.keys(spaceID)[1])
    let rewrapped = try await a.engine.rewrapStale(spaceID)
    XCTAssertEqual(rewrapped, 1)
    XCTAssertEqual(spark.space(spaceID)?.itemKeys[before]?.epoch, 2)
  }

  func testTheLeaseLendsTheEpochStoreKeyAndTheFirstEpochMaskKeyAndReKeysAfterARotation()
    async throws
  {
    let spark = FakeSpaceSpark()
    let (a, b, spaceID) = try await twoMembers(spark)
    let builder = RecordingPayloadBuilder()
    _ = try await a.engine.share(
      spaceID,
      items: [
        SpaceOutgoingItem(
          itemID: SpaceID.new(), kind: "text", fields: note("回电 13812345678", matter: "m-a"))
      ])
    _ = try await b.engine.share(
      spaceID,
      items: [
        SpaceOutgoingItem(itemID: SpaceID.new(), kind: "text", fields: note("报价单", matter: "m-b"))
      ])
    let report = try await a.engine.organize(spaceID, builder: builder)
    XCTAssertTrue(report.leased)
    XCTAssertEqual(report.sent, 2)
    let k1 = try XCTUnwrap(a.keys.keys(spaceID)[1])
    let lease = try XCTUnwrap(spark.leases.last)
    XCTAssertEqual(lease.storeKey, SpaceCrypto.hex(SpaceCrypto.storeKey(spaceKey: k1)))
    XCTAssertEqual(lease.maskKey, SpaceCrypto.hex(SpaceCrypto.maskKey(firstEpochKey: k1)))
    XCTAssertEqual(builder.maskKeys.first, SpaceCrypto.maskKey(firstEpochKey: k1))
    // The organizer got placeholders, not the number; the state links both matters.
    let state = try await a.engine.state(spaceID)
    let organizer = try XCTUnwrap(state?.organizer)
    XCTAssertFalse(String(decoding: organizer.state, as: UTF8.self).contains("13812345678"))
    XCTAssertEqual(Set(organizer.sameAs.map(\.matterID)), ["m-a", "m-b"])

    // A rotation: the store is still under epoch 1; the lease re-keys it,
    // and the mask key does not change.
    try await a.engine.removeMember(spaceID, memberID: try await b.engine.state(spaceID)!.memberID)
    let rekey = try await a.engine.organize(spaceID, builder: builder)
    XCTAssertTrue(rekey.rekeyed)
    let k2 = try XCTUnwrap(a.keys.keys(spaceID)[2])
    XCTAssertEqual(
      spark.leases.last?.storeKey, SpaceCrypto.hex(SpaceCrypto.storeKey(spaceKey: k2)))
    XCTAssertEqual(spark.leases.last?.maskKey, lease.maskKey)
  }

  // MARK: - Withdraw, delete, takedown

  func testWithdrawShredsTheDataKeyAndTheOtherMacDropsItsCopy() async throws {
    let spark = FakeSpaceSpark()
    let (a, b, spaceID) = try await twoMembers(spark)
    let item = SpaceID.new()
    _ = try await b.engine.share(
      spaceID,
      items: [
        SpaceOutgoingItem(
          itemID: item, kind: "image", fields: note("截图"),
          originals: [("image", Data("PNG-\(Self.sentinel)".utf8))])
      ])
    var aState = try await a.engine.sync(spaceID)
    let blob = try XCTUnwrap(aState.items[item]?.blobs.first)
    _ = try await a.engine.original(spaceID, itemID: item, blob: blob)
    XCTAssertEqual(a.states.originalCount, 1)
    try await b.engine.withdraw(spaceID, itemID: item)
    // On the Spark: no data key, no fields, no blob bytes.
    let stored = try XCTUnwrap(spark.space(spaceID))
    XCTAssertNil(stored.itemKeys[item])
    XCTAssertTrue(stored.log.filter { $0.subject == item }.allSatisfy { $0.enc == nil })
    XCTAssertTrue(stored.blobs.values.allSatisfy { $0.data.isEmpty })
    aState = try await a.engine.sync(spaceID)
    XCTAssertEqual(aState.items[item]?.status, .withdrawn)
    XCTAssertNil(aState.items[item]?.fields)
    XCTAssertEqual(a.states.originalCount, 0)
    // A withdrawn id cannot be shared again.
    let again = try await b.engine.share(
      spaceID, items: [SpaceOutgoingItem(itemID: item, kind: "text", fields: note("再来"))])
    XCTAssertEqual(again.refused[item], "item_gone")
  }

  func testOrgSpaceKeepsAssetsAfterTheTwentyFourHourWindowDeleteBecomesATakedown() async throws {
    let spark = FakeSpaceSpark()
    let (a, b, spaceID) = try await twoMembers(spark, owner: .org)
    let early = SpaceID.new()
    let late = SpaceID.new()
    _ = try await b.engine.share(
      spaceID,
      items: [
        SpaceOutgoingItem(itemID: early, kind: "text", fields: note("早")),
        SpaceOutgoingItem(itemID: late, kind: "text", fields: note("晚")),
      ])
    let bState = try await b.engine.sync(spaceID)
    XCTAssertEqual(bState.ownerKind, .org)
    XCTAssertEqual(bState.policy.withdrawWindowHours, 24)
    // Within 24 h: withdraw works.
    spark.advance(hours: 23)
    try await b.engine.withdraw(spaceID, itemID: early)
    // Past the window: withdraw is refused, delete becomes a takedown request.
    spark.advance(hours: 2)
    do {
      try await b.engine.withdraw(spaceID, itemID: late)
      XCTFail("withdrew past the window")
    } catch SpaceEngine.EngineError.refused(let code) {
      XCTAssertEqual(code, "window_passed")
    }
    let outcome = try await b.engine.delete(spaceID, itemID: late)
    XCTAssertEqual(outcome, .takedownRequested)
    var aState = try await a.engine.sync(spaceID)
    XCTAssertTrue(aState.items[late]?.isActive == true)
    let takedown = try XCTUnwrap(aState.takedowns.values.first { $0.itemID == late })
    XCTAssertEqual(takedown.kind, "other")
    // A maintainer accepts it: removed everywhere.
    try await a.engine.resolveTakedown(spaceID, takedownID: takedown.takedownID, accept: true)
    aState = try await a.engine.sync(spaceID)
    XCTAssertEqual(aState.items[late]?.status, .removed)
    // The Mac's own rules agree with the Spark.
    let first = Date(timeIntervalSince1970: 0)
    XCTAssertEqual(
      SpaceRules.deleteOutcome(
        policy: .org, firstShared: first, now: first.addingTimeInterval(23 * 3600)),
      .withdrawn)
    XCTAssertEqual(
      SpaceRules.deleteOutcome(
        policy: .org, firstShared: first, now: first.addingTimeInterval(25 * 3600)),
      .takedownRequested)
    XCTAssertEqual(
      SpaceRules.deleteOutcome(
        policy: .group, firstShared: first, now: first.addingTimeInterval(400 * 3600)), .withdrawn)
  }

  func testAPrivacyTakedownIsRefusedOnlyWithAReasonAndIsCarriedOutWhenItsWindowEnds() async throws {
    let spark = FakeSpaceSpark()
    let (a, b, spaceID) = try await twoMembers(spark, owner: .org)
    let item = SpaceID.new()
    _ = try await a.engine.share(
      spaceID, items: [SpaceOutgoingItem(itemID: item, kind: "text", fields: note("有 B 的私事"))])
    _ = try await b.engine.sync(spaceID)
    let takedownID = try await b.engine.requestTakedown(
      spaceID, itemID: item, privacy: true, reason: "里面有我的私事")
    var aState = try await a.engine.sync(spaceID)
    XCTAssertEqual(aState.takedowns[takedownID]?.reason, "里面有我的私事")
    XCTAssertNotNil(aState.takedowns[takedownID]?.dueAt)
    do {
      try await a.engine.resolveTakedown(spaceID, takedownID: takedownID, accept: false)
      XCTFail("a privacy takedown was rejected without a reason")
    } catch SpaceEngine.EngineError.refused(let code) {
      XCTAssertEqual(code, "bad_op")
    }
    // Nobody acts: the Spark removes it when the window ends.
    spark.advance(hours: 73)
    aState = try await a.engine.sync(spaceID)
    XCTAssertEqual(aState.items[item]?.status, .removed)
    XCTAssertFalse(String(decoding: spark.everythingReceived, as: UTF8.self).contains("私事"))
  }

  // MARK: - Forks, hide, leave

  func testForksAreRemovedFromTheMacWhenAccessEnds() async throws {
    let spark = FakeSpaceSpark()
    let (a, b, spaceID) = try await twoMembers(spark)
    let item = SpaceID.new()
    _ = try await a.engine.share(
      spaceID, items: [SpaceOutgoingItem(itemID: item, kind: "text", fields: note("可以存一份"))])
    _ = try await b.engine.sync(spaceID)
    try await b.engine.fork(spaceID, itemID: item)
    try await b.engine.recordForkCopy(spaceID, itemID: item, localID: "LOCAL-COPY-1")
    try await b.engine.hide(spaceID, itemID: item)
    let bState = try await b.engine.sync(spaceID)
    XCTAssertEqual(bState.forks[item], "LOCAL-COPY-1")
    XCTAssertTrue(bState.hidden.contains(item))
    // A's view is unaffected by B's hide (private), and A sees no hide op.
    let aState = try await a.engine.sync(spaceID)
    XCTAssertFalse(aState.hidden.contains(item))
    try await a.engine.removeMember(spaceID, memberID: bState.memberID)
    do { _ = try await b.engine.sync(spaceID) } catch SpaceClientError.accessEnded {}
    let copies = await b.engine.takeForkCopiesToDelete()
    XCTAssertEqual(copies, ["LOCAL-COPY-1"])
  }

  func testForksNeedThePolicyAndOrgSpacesDoNotAllowThemByDefault() async throws {
    let spark = FakeSpaceSpark()
    let (a, b, spaceID) = try await twoMembers(spark, owner: .org)
    let item = SpaceID.new()
    _ = try await a.engine.share(
      spaceID, items: [SpaceOutgoingItem(itemID: item, kind: "text", fields: note("组织资产"))])
    _ = try await b.engine.sync(spaceID)
    do {
      try await b.engine.fork(spaceID, itemID: item)
      XCTFail("forked in an org space")
    } catch SpaceEngine.EngineError.refused(let code) {
      XCTAssertEqual(code, "forks_not_allowed")
    }
  }

  func testLeavingAGroupSpaceCanTakeContributionsAndAnAdminRotatesAfterwards() async throws {
    let spark = FakeSpaceSpark()
    let (a, b, spaceID) = try await twoMembers(spark)
    let item = SpaceID.new()
    _ = try await b.engine.share(
      spaceID, items: [SpaceOutgoingItem(itemID: item, kind: "text", fields: note("带走"))])
    _ = try await b.engine.leave(spaceID, withdrawContributions: true)
    let gone = try await b.engine.state(spaceID)
    XCTAssertNil(gone)
    var aState = try await a.engine.sync(spaceID)
    XCTAssertTrue(aState.rotationPending)
    XCTAssertEqual(spark.space(spaceID)?.items[item]?.status, "withdrawn")
    // Shares wait until an admin rotates.
    do {
      _ = try await a.engine.share(
        spaceID, items: [SpaceOutgoingItem(itemID: SpaceID.new(), kind: "text", fields: note("x"))])
      XCTFail("shared while a rotation was pending")
    } catch SpaceEngine.EngineError.refused(let code) {
      XCTAssertEqual(code, "rotation_pending")
    }
    try await a.engine.rotate(spaceID)
    aState = try await a.engine.sync(spaceID)
    XCTAssertFalse(aState.rotationPending)
    XCTAssertEqual(aState.epoch, 2)
  }

  // MARK: - What never leaves

  func testAudioOnlyAsSegmentsAndNeverAVoiceprintDictionaryOrWholeRecording() async throws {
    let spark = FakeSpaceSpark()
    let (a, _, spaceID) = try await twoMembers(spark)
    let parent = SpaceID.new()
    let okSegment = SpaceID.segment(parent: parent, startMS: 60_000, endMS: 120_000)
    let long = SpaceID.segment(parent: parent, startMS: 0, endMS: 16 * 60_000)
    let items = [
      SpaceOutgoingItem(itemID: SpaceID.new(), kind: "voiceprint", fields: note("x")),
      SpaceOutgoingItem(itemID: SpaceID.new(), kind: "dictionary", fields: note("x")),
      SpaceOutgoingItem(itemID: SpaceID.new(), kind: "recognition_profile", fields: note("x")),
      SpaceOutgoingItem(itemID: SpaceID.new(), kind: "recording", fields: note("x")),
      // A whole meeting, and audio without a segment.
      SpaceOutgoingItem(itemID: parent, kind: "meeting_offline", fields: note("整场会")),
      SpaceOutgoingItem(
        itemID: SpaceID.new(), kind: "text", fields: note("x"),
        originals: [("audio", Data("RIFF".utf8))]),
      SpaceOutgoingItem(
        itemID: long, kind: "audio_segment", fields: note("太长"),
        segment: SpaceSegmentRef(parentItemID: parent, startMS: 0, endMS: 16 * 60_000)),
      SpaceOutgoingItem(
        itemID: okSegment, kind: "audio_segment", fields: note("这一分钟"),
        originals: [("audio", Data("RIFF-minute".utf8))],
        segment: SpaceSegmentRef(parentItemID: parent, startMS: 60_000, endMS: 120_000)),
    ]
    let report = try await a.engine.share(spaceID, items: items)
    XCTAssertEqual(report.shared, [okSegment])
    XCTAssertEqual(report.refused.count, 7)
    XCTAssertEqual(report.refused[parent], "audio_needs_segment")
    XCTAssertEqual(report.refused[long], "segment_too_long")
    // Only one item.share ever left this Mac, and one blob.
    let shares = spark.requests.filter { $0.target.hasSuffix("/ops") }.compactMap { request in
      try? SpaceJSON.decode(request.body ?? Data())["ops"]?.array
    }.flatMap { $0 }.compactMap { wire -> String? in
      guard let op = wire["op"]?.string.flatMap({ Base64URL.decode($0) }),
        let json = try? SpaceJSON.decode(op), json["type"]?.string == "item.share"
      else { return nil }
      return json["body"]?["kind"]?.string
    }
    XCTAssertEqual(shares, ["audio_segment"])
    XCTAssertEqual(spark.requests.filter { $0.method == "PUT" }.count, 1)
    // The segment id is stable for the same part of the same recording.
    XCTAssertEqual(
      okSegment, SpaceID.segment(parent: parent.uppercased(), startMS: 60_000, endMS: 120_000))
    XCTAssertTrue(SpaceID.isValid(okSegment))
  }

  func testTextOnlySpacesKeepOriginalsOnTheContributorsMac() async throws {
    let spark = FakeSpaceSpark()
    var policy = SpacePolicy.group
    policy.originals = "text_only"
    let (a, _, spaceID) = try await twoMembers(spark, policy: policy)
    let report = try await a.engine.share(
      spaceID,
      items: [
        SpaceOutgoingItem(
          itemID: SpaceID.new(), kind: "image", fields: note("只留文字"),
          originals: [("image", Data("PNG".utf8))])
      ])
    XCTAssertEqual(report.shared.count, 1)
    XCTAssertEqual(report.originalsDropped, 1)
    XCTAssertEqual(spark.requests.filter { $0.method == "PUT" }.count, 0)
  }

  // MARK: - Rights

  func testRightsPerRoleAndSpaceType() async throws {
    // The Mac lists exactly the Spark's rights.
    XCTAssertEqual(
      SpaceRules.rights(role: .read, policy: .org),
      ["read", "hide", "leave", "agent_access", "profile", "takedown_privacy"])
    XCTAssertTrue(SpaceRules.rights(role: .read, policy: .group).contains("fork"))
    XCTAssertFalse(SpaceRules.rights(role: .read, policy: .org).contains("fork"))
    XCTAssertTrue(SpaceRules.rights(role: .write, policy: .org).contains("share"))
    XCTAssertFalse(SpaceRules.rights(role: .write, policy: .org).contains("remove"))
    XCTAssertTrue(SpaceRules.rights(role: .maintain, policy: .org).contains("resolve_proposals"))
    XCTAssertFalse(SpaceRules.rights(role: .maintain, policy: .org).contains("invite"))
    XCTAssertTrue(SpaceRules.rights(role: .admin, policy: .org).contains("remove_members"))

    let t0 = Date(timeIntervalSince1970: 0)
    let day2 = t0.addingTimeInterval(30 * 3600)
    func actions(
      _ mine: Bool, _ role: SpaceRole, _ policy: SpacePolicy,
      at: Date = Date(timeIntervalSince1970: 3600)
    ) -> Set<SpaceRules.ItemAction> {
      Set(
        SpaceRules.actions(
          .init(isMine: mine, role: role, policy: policy, firstShared: t0), now: at))
    }
    // Group space: your own item can always be withdrawn; others' can be
    // hidden, reported for privacy, forked.
    XCTAssertEqual(actions(true, .write, .group, at: day2), [.withdraw, .delete])
    XCTAssertEqual(actions(false, .write, .group), [.hide, .requestPrivacyTakedown, .fork])
    // Org space: no withdraw after the window, no forks.
    XCTAssertEqual(actions(true, .write, .org), [.withdraw, .delete])
    XCTAssertEqual(actions(true, .write, .org, at: day2), [.delete])
    XCTAssertEqual(actions(false, .read, .org), [.hide, .requestPrivacyTakedown])
    // Maintainers may remove anyone's item.
    XCTAssertTrue(actions(false, .maintain, .org).contains(.remove))
    XCTAssertFalse(actions(false, .write, .org).contains(.remove))

    // And the engine refuses what the role cannot do before anything is sent.
    let spark = FakeSpaceSpark()
    let (_, b, spaceID) = try await twoMembers(spark, role: .read)
    let sentBefore = spark.requests.count
    do {
      _ = try await b.engine.invite(
        spaceID, role: .write, hostKey: FakeSpaceSpark.hostKey, spark: Self.endpoint)
      XCTFail("a read-only member invited")
    } catch SpaceEngine.EngineError.notAllowed(let right) {
      XCTAssertEqual(right, "invite")
    }
    do {
      _ = try await b.engine.share(
        spaceID, items: [SpaceOutgoingItem(itemID: SpaceID.new(), kind: "text", fields: note("x"))])
      XCTFail("a read-only member shared")
    } catch SpaceEngine.EngineError.notAllowed(let right) {
      XCTAssertEqual(right, "share")
    }
    XCTAssertEqual(spark.requests.count, sentBefore)
  }

  // MARK: - Invites

  func testInviteCodesPinTheHostKeyAndExpire() async throws {
    let spark = FakeSpaceSpark()
    let a = TestMac("A", spark: spark)
    let space = try await a.engine.createSpace(
      name: "组", owner: .person, displayName: "我", spark: Self.endpoint)
    // A host key that is not the Spark's is refused by the Spark.
    do {
      _ = try await a.engine.invite(
        space.spaceID, role: .write, hostKey: "ssh-ed25519 AAAAother", spark: Self.endpoint)
      XCTFail("an invite pinned the wrong host key")
    } catch SpaceEngine.EngineError.refused(let code) {
      XCTAssertEqual(code, "host_key_mismatch")
    }
    let code = try await a.engine.invite(
      space.spaceID, role: .maintain, hostKey: FakeSpaceSpark.hostKey, spark: Self.endpoint)
    let text = try code.encoded()
    XCTAssertTrue(text.hasPrefix("mlinvite1."))
    let decoded = try SpaceInviteCode.decode("  \(text)\n", now: spark.now)
    XCTAssertEqual(decoded, code)
    XCTAssertEqual(decoded.role, "maintain")
    XCTAssertLessThanOrEqual(
      try XCTUnwrap(decoded.expiry).timeIntervalSince(spark.now), 7 * 86_400)
    XCTAssertThrowsError(
      try SpaceInviteCode.decode(text, now: spark.now.addingTimeInterval(8 * 86_400))
    ) { error in XCTAssertEqual(error as? SpaceInviteCode.CodeError, .expired) }
    XCTAssertThrowsError(try SpaceInviteCode.decode("mlinvite1.!!", now: spark.now))
    // One use only: a second Mac with the same code is refused.
    let b = TestMac("B", spark: spark)
    let c = TestMac("C", spark: spark)
    _ = try await b.engine.join(
      code: decoded, displayName: "B", localHostKey: FakeSpaceSpark.hostKey)
    do {
      _ = try await c.engine.join(
        code: decoded, displayName: "C", localHostKey: FakeSpaceSpark.hostKey)
      XCTFail("an invite was used twice")
    } catch SpaceClientError.server(let error) {
      XCTAssertEqual(error.code, "invite_used")
    }
  }

  // MARK: - Proposals and audit

  func testMaintainersReviewProposalsAndAdminsSeeRecordsOnly() async throws {
    let spark = FakeSpaceSpark()
    let (a, b, spaceID) = try await twoMembers(spark)
    let proposal = try await b.engine.propose(
      spaceID, kind: "rename", matterIDs: ["ev-1"], details: ["title": "开业筹备（新）"])
    var aState = try await a.engine.sync(spaceID)
    XCTAssertEqual(aState.proposals[proposal]?.details?["title"]?.string, "开业筹备（新）")
    XCTAssertEqual(aState.proposals[proposal]?.status, "open")
    _ = try await a.engine.resolveProposal(spaceID, proposalID: proposal, accept: false)
    aState = try await a.engine.sync(spaceID)
    XCTAssertEqual(aState.proposals[proposal]?.status, "rejected")
    // B (a contributor) cannot resolve proposals.
    do {
      _ = try await b.engine.resolveProposal(spaceID, proposalID: proposal, accept: true)
      XCTFail("a contributor resolved a proposal")
    } catch SpaceEngine.EngineError.notAllowed {}
    let audit = try await a.engine.audit(spaceID)
    XCTAssertFalse(audit.records.isEmpty)
    let text = String(decoding: try JSONEncoder().encode(audit.records), as: UTF8.self)
    XCTAssertFalse(text.contains("开业筹备"))
    do {
      _ = try await b.engine.audit(spaceID)
      XCTFail("a contributor read the audit")
    } catch SpaceEngine.EngineError.notAllowed {}
  }

  // MARK: - Review list

  func testShareReviewListUnticksPrivateDictationsAndItemsWithNumbers() {
    let review = SpaceShareReview(candidates: [
      SpaceShareCandidate(
        id: "a", sourceItemID: "a", kind: .item, wireKind: "text", title: "会议纪要", preview: "",
        startedAt: nil, isPrivateDictation: false, numberLabels: [], hasOriginal: false),
      SpaceShareCandidate(
        id: "b", sourceItemID: "b", kind: .item, wireKind: "dictation", title: "口述", preview: "",
        startedAt: nil, isPrivateDictation: true, numberLabels: [], hasOriginal: false),
      SpaceShareCandidate(
        id: "c", sourceItemID: "c", kind: .item, wireKind: "image", title: "截图", preview: "",
        startedAt: nil, isPrivateDictation: false, numberLabels: ["手机号"], hasOriginal: true),
      SpaceShareCandidate(
        id: "d", sourceItemID: "rec",
        kind: .segment(parentItemID: "rec", startMS: 0, endMS: 60_000),
        wireKind: "audio_segment", title: "会议片段", preview: "", startedAt: nil,
        isPrivateDictation: false, numberLabels: [], hasOriginal: true),
    ])
    // A recording's part is never ticked for you: you pick it (V7-S5).
    XCTAssertEqual(review.ticked, ["a"])
    XCTAssertEqual(review.candidates[1].untickedReason, "口述内容默认不共享")
    XCTAssertEqual(review.candidates[2].untickedReason?.hasPrefix("含号码（手机号）"), true)
    XCTAssertEqual(review.candidates[3].untickedReason?.hasPrefix("录音片段要你自己选"), true)
    var edited = review
    edited.toggle("c")
    edited.toggle("d")
    XCTAssertEqual(edited.selected.map(\.id), ["a", "c", "d"])
  }
}
