import BestASRDomain
import BestASRPersistence
import BestASRRemoteOrganizer
import CryptoKit
import Foundation
import GRDB
import XCTest

/// Privacy contract v6 on the Mac: unlock first, masking on the wire and
/// originals back on screen, queued deletions, lock on revoke, "forget me",
/// and media that never leaves. Fake ssh, fake Spark, a real SQLite store on
/// a temporary synthetic library; every value below is made up.
@MainActor
final class RemoteOrganizerPrivacyTests: XCTestCase {
  private let enabledAt = Date(timeIntervalSince1970: 500)

  /// Seven kinds of identifier in one made-up note (the ID and card numbers
  /// pass their checksums; nobody owns them).
  static let sentinels = [
    "13812345678", "11010519491231002X", "6222 0212 3456 7894", "zhang.san@example.com",
    "Tr0ub4dor-3x", "482913", "sk-proj-Ab3dEf6hIj9kLm2nOp5q",
  ]
  static let sentinelNote =
    "请回电 13812345678，身份证 11010519491231002X，卡号 6222 0212 3456 7894，"
    + "邮箱 zhang.san@example.com，密码：Tr0ub4dor-3x，验证码 482913，"
    + "key sk-proj-Ab3dEf6hIj9kLm2nOp5q。明天下午三点在国贸见，预算 2000 元。"

  private func makeRuntime(
    _ repository: any RemoteOrganizerRepository, spark: FakeSpark,
    launcher: FakeTunnelLauncher = FakeTunnelLauncher(),
    updates: @escaping (RemoteOrganizerRuntime.LinkState, RemoteOrganizerProjection?) -> Void = {
      _, _ in
    }
  ) -> RemoteOrganizerRuntime {
    RemoteOrganizerRuntime(
      repository: repository, launcher: launcher, http: spark, keys: testOrganizerKeys,
      imageRedactor: IdentityRedactor(), timing: fastTiming, onUpdate: updates)
  }

  private func syntheticRoot() throws -> URL {
    let root = try makeTemporaryDirectory()
    FileManager.default.createFile(
      atPath: root.appendingPathComponent(RemoteOrganizerDataProvenance.syntheticMarkerFileName)
        .path,
      contents: Data())
    return root
  }

  private func makeController(
    _ library: SyntheticOrganizerLibrary, spark: FakeSpark,
    launcher: FakeTunnelLauncher = FakeTunnelLauncher(), keyStore: MemoryOrganizerKeyStore
  ) throws -> RemoteOrganizerLinkController {
    RemoteOrganizerLinkController(
      repository: library.store, dataRoot: try syntheticRoot(),
      realLibraryRoot: try makeTemporaryDirectory("real"),
      intent: RemoteOrganizerMemoryLinkIntent(), keyStore: keyStore, cleanUpStaleTunnels: {},
      makeRuntime: { repository, keys, onUpdate in
        RemoteOrganizerRuntime(
          repository: repository, launcher: launcher, http: spark, keys: keys,
          timing: fastTiming, onUpdate: onUpdate)
      })
  }

  private func dataPath(_ request: RemoteOrganizerHTTPRequest) -> Bool {
    !["/v1/health", "/v1/unlock", "/v1/lock", "/v1/wipe"].contains(request.path)
  }

  // MARK: - Unlock

  func testUnlockPrecedesEveryDataCallAndOnlyItCarriesTheKey() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let sessionID = UUID()
    try await library.seedCompletedSession(sessionID, createdAt: 1_000, text: "虚构口述")
    try await library.store.enqueueRemoteDecision(
      .init(kind: "pin_event", eventID: "e1", pinned: true))
    let spark = FakeSpark()
    let runtime = makeRuntime(library.store, spark: spark)
    runtime.start()
    try await waitUntil { spark.items.count == 1 && spark.decisions.count == 1 }
    runtime.stop()
    let requests = spark.requests
    XCTAssertEqual(requests.first?.path, "/v1/health")
    let unlockIndex = try XCTUnwrap(requests.firstIndex { $0.path == "/v1/unlock" })
    let firstData = try XCTUnwrap(requests.firstIndex(where: dataPath))
    XCTAssertLessThan(unlockIndex, firstData, "unlock is the first data call")
    XCTAssertEqual(unlockIndex, 1)
    // Contract order: decisions before items.
    let decisionIndex = try XCTUnwrap(requests.firstIndex { $0.path == "/v1/decisions" })
    let itemIndex = try XCTUnwrap(requests.firstIndex { $0.path == "/v1/items" })
    XCTAssertLessThan(decisionIndex, itemIndex)
    let unlockBody = try XCTUnwrap(requests[unlockIndex].body)
    let key = try JSONSerialization.jsonObject(with: unlockBody) as? [String: String]
    XCTAssertEqual(key?["key"], testOrganizerKeys.libraryKeyHex)
    for request in requests where request.path != "/v1/unlock" {
      let body = request.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
      XCTAssertFalse(body.contains(testOrganizerKeys.libraryKeyHex), request.path)
    }
    XCTAssertEqual(spark.storeKeyID, testOrganizerKeys.keyID)
    await library.close()
  }

  func testRestartedLockedStoreIsUnlockedAgainBeforeAnythingIsSent() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let spark = FakeSpark()
    var states: [RemoteOrganizerRuntime.LinkState] = []
    let runtime = makeRuntime(library.store, spark: spark) { state, _ in states.append(state) }
    runtime.start()
    try await waitUntil { states.last == .connected }
    // The organizing device restarts: its store is locked, the key gone.
    spark.restart()
    let sessionID = UUID()
    try await library.seedCompletedSession(sessionID, createdAt: 1_000, text: "重启后的虚构口述")
    _ = try await library.store.enqueueRemoteSession(sessionID: SessionID(sessionID))
    try await waitUntil { spark.items.count == 1 }
    runtime.stop()
    XCTAssertEqual(spark.paths.filter { $0 == "/v1/unlock" }.count, 2)
    await library.close()
  }

  func testAnOrganizerThatCannotLockItsStoreIsSentNothing() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let sessionID = UUID()
    try await library.seedCompletedSession(sessionID, createdAt: 1_000, text: "虚构口述")
    let spark = FakeSpark()
    spark.dropLockingSupport()
    var states: [RemoteOrganizerRuntime.LinkState] = []
    let runtime = makeRuntime(library.store, spark: spark) { state, _ in states.append(state) }
    runtime.start()
    try await waitUntil { states.contains(.unsupported) }
    try await Task.sleep(for: .milliseconds(100))
    runtime.stop()
    XCTAssertTrue(spark.items.isEmpty)
    XCTAssertFalse(
      spark.requests.contains { $0.path == "/v1/items" || $0.path.hasPrefix("/v1/state") })
    await library.close()
  }

  func testWrongKeyIsShownNothingIsSentAndForgettingTheOldContentRecovers() async throws {
    let library = try SyntheticOrganizerLibrary()
    let spark = FakeSpark()
    spark.setStoreKeyID("feedfacefeedface")
    let keyStore = MemoryOrganizerKeyStore()
    let controller = try makeController(library, spark: spark, keyStore: keyStore)
    await controller.setEnabled(true)
    let sessionID = UUID()
    try await library.seedCompletedSession(
      sessionID, createdAt: Date().timeIntervalSince1970, text: "开启后的虚构口述")
    try await waitUntil { controller.status == .wrongKey("feedfacefeedface") }
    XCTAssertTrue(controller.canForget)
    try await Task.sleep(for: .milliseconds(100))
    // The health check named another key: this library's key never went out.
    XCTAssertFalse(spark.paths.contains("/v1/unlock"))
    XCTAssertTrue(spark.items.isEmpty)
    let ownKey = try XCTUnwrap(controller.keyID)

    let outcome = await controller.forgetOnOrganizer(.otherKey("feedfacefeedface"))
    XCTAssertEqual(outcome, .forgotten)
    XCTAssertEqual(spark.wipes, ["feedfacefeedface"])
    XCTAssertEqual(controller.keyID, ownKey, "this library's own key is kept")
    try await waitUntil { controller.status == .connected }
    XCTAssertEqual(spark.storeKeyID, ownKey)
    await controller.setEnabled(false)
    await library.close()
  }

  // MARK: - Revocation and forgetting

  func testTurningTheLinkOffLocksTheStoreAndGivesUpAfterTwoSeconds() async throws {
    let library = try SyntheticOrganizerLibrary()
    let spark = FakeSpark()
    let launcher = FakeTunnelLauncher()
    let controller = try makeController(
      library, spark: spark, launcher: launcher, keyStore: MemoryOrganizerKeyStore())
    await controller.setEnabled(true)
    try await waitUntil { controller.status == .connected }
    await controller.setEnabled(false)
    XCTAssertEqual(spark.lockCount, 1)
    XCTAssertTrue(spark.isLocked)
    XCTAssertEqual(spark.paths.last, "/v1/lock", "the lock is the last request")
    XCTAssertTrue(launcher.launched.allSatisfy(\.terminated))

    // An organizing device that does not answer holds nothing up for long.
    spark.holdLocks()
    await controller.setEnabled(true)
    try await waitUntil { controller.status == .connected }
    let started = Date()
    controller.revokeNow()
    XCTAssertFalse(controller.isRuntimeRunning)
    await controller.waitForRevocation()
    let waited = Date().timeIntervalSince(started)
    XCTAssertLessThan(waited, RemoteOrganizerLinkController.lockTimeout + 1.5)
    XCTAssertTrue(launcher.launched.allSatisfy(\.terminated))
    await controller.revokeStorage()
    await library.close()
  }

  func testForgettingWipesTheOrganizerDestroysTheKeyAndResendsOnlyWhatChanges() async throws {
    let library = try SyntheticOrganizerLibrary()
    let spark = FakeSpark()
    let keyStore = MemoryOrganizerKeyStore()
    let controller = try makeController(library, spark: spark, keyStore: keyStore)
    let off = await controller.forgetOnOrganizer(.mine)
    XCTAssertEqual(off, .notConnected, "only while the link is on")
    await controller.setEnabled(true)
    let sessionID = UUID()
    try await library.seedCompletedSession(
      sessionID, createdAt: Date().timeIntervalSince1970, text: "送达后要被忘掉的虚构口述")
    try await controller.enqueueCompletedSession(SessionID(sessionID))
    try await waitUntil { spark.items.count == 1 }
    try await waitUntil {
      try await library.scalar(
        "SELECT delivered_revision FROM remote_organizer_item_jobs WHERE item_id = ?",
        [sessionID.uuidString]) != nil
    }
    let oldKey = try XCTUnwrap(controller.keyID)
    XCTAssertEqual(keyStore.stored?.keyID, oldKey)

    let outcome = await controller.forgetOnOrganizer(.mine)
    XCTAssertEqual(outcome, .forgotten)
    XCTAssertEqual(spark.wipes, [oldKey])
    // The old key is gone; a new one opens the new, empty store.
    XCTAssertNotEqual(keyStore.stored?.keyID, oldKey)
    XCTAssertEqual(controller.keyID, keyStore.stored?.keyID)
    try await waitUntil { controller.status == .connected }
    XCTAssertEqual(spark.storeKeyID, controller.keyID)
    let delivered = try await library.scalar(
      "SELECT delivered_revision FROM remote_organizer_item_jobs WHERE item_id = ?",
      [sessionID.uuidString])
    XCTAssertNil(delivered, "nothing counts as delivered after forgetting")
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(spark.items.isEmpty, "nothing is sent again by itself")
    // A later change sends the then-current content.
    try await library.addRevision(
      sessionID, revision: 2, kind: "userEdit", text: "修改过的虚构口述",
      createdAt: Date().timeIntervalSince1970 + 60)
    try await waitUntil { spark.items.count == 1 }
    XCTAssertEqual(spark.items.first?["text"] as? String, "修改过的虚构口述")
    await controller.setEnabled(false)
    await library.close()
  }

  // MARK: - Deletions

  func testPendingDeletionsSurviveRevocationAndArchiveImportAndGoFirst() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let delivered = UUID()
    try await library.seedCompletedSession(delivered, createdAt: 1_000, text: "已送达的虚构口述")
    let spark = FakeSpark()
    let first = makeRuntime(library.store, spark: spark)
    first.start()
    try await waitUntil { spark.items.count == 1 }
    try await waitUntil {
      try await library.scalar(
        "SELECT delivered_revision FROM remote_organizer_item_jobs WHERE item_id = ?",
        [delivered.uuidString]) != nil
    }
    first.stop()
    let neverSent = UUID()
    try await library.seedCompletedSession(neverSent, createdAt: 2_000, text: "从未送达的虚构口述")

    // Off, then deleted on the Mac: only what may be on the Spark is queued.
    try await library.store.revokeRemoteLink()
    try await library.store.deleteSessionRecordsExplicitly(
      sessionIDs: [SessionID(delivered), SessionID(neverSent)])
    var pending = try await library.store.pendingRemoteDeletions()
    XCTAssertEqual(pending, [delivered.uuidString])

    // An archive import (which turns the link off again) keeps the queue.
    let other = try SyntheticOrganizerLibrary()
    let archive = try await other.store.exportPortablePersistenceState()
    try await library.store.importPortablePersistenceState(archive)
    await other.close()
    pending = try await library.store.pendingRemoteDeletions()
    XCTAssertEqual(pending, [delivered.uuidString])

    // On again: the deletion is the first data call after unlock.
    try await library.store.enableRemoteLink(at: Date(timeIntervalSince1970: 3_000))
    let fresh = UUID()
    try await library.seedCompletedSession(fresh, createdAt: 4_000, text: "新的虚构口述")
    try await library.store.enqueueRemoteDecision(.init(kind: "feature_less", eventID: "e1"))
    let countBefore = spark.requests.count
    let second = makeRuntime(library.store, spark: spark)
    second.start()
    try await waitUntil {
      spark.items.contains { ($0["item_id"] as? String) == fresh.uuidString }
        && spark.decisions.count == 1
    }
    second.stop()
    let after = Array(spark.requests.dropFirst(countBefore))
    let unlock = try XCTUnwrap(after.firstIndex { $0.path == "/v1/unlock" })
    let firstData = try XCTUnwrap(after.firstIndex(where: dataPath))
    XCTAssertEqual(after[firstData].method, "DELETE")
    XCTAssertEqual(after[firstData].path, "/v1/items/\(delivered.uuidString)")
    XCTAssertGreaterThan(firstData, unlock)
    XCTAssertEqual(spark.deletedItems, [delivered.uuidString])
    pending = try await library.store.pendingRemoteDeletions()
    XCTAssertEqual(pending, [])
    XCTAssertFalse(spark.items.contains { ($0["item_id"] as? String) == neverSent.uuidString })
    await library.close()
  }

  // MARK: - Masking

  private func userItem(
    _ library: SyntheticOrganizerLibrary, kind: UserItemKind, text: String, at seconds: Double,
    filename: String? = nil, extractor: String = "pasteboard-text-v1"
  ) async throws -> SessionID {
    let id = SessionID()
    try await library.store.createUserItem(
      UserItemDraft(
        id: id, kind: kind, capturedAt: Date(timeIntervalSince1970: seconds),
        source: ItemSourceApplication(bundleID: "dev.synthetic.notes", name: "虚构笔记"),
        sourceOrigin: .user, text: text, extractor: extractor, originalFilename: filename))
    return id
  }

  func testEveryTextThatLeavesIsMaskedAndEveryTextThatComesBackIsRestored() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let dictation = UUID()
    try await library.seedCompletedSession(dictation, createdAt: 1_000, text: Self.sentinelNote)
    let pasted = try await userItem(library, kind: .text, text: Self.sentinelNote, at: 2_000)
    let document = try await userItem(
      library, kind: .document, text: "合同附件\n" + Self.sentinelNote, at: 3_000,
      filename: "合同-13812345678.md", extractor: "plain-text-v1")
    let rename = RemoteOrganizerDecision(
      kind: "rename_event", eventID: "event-1", title: "给 13812345678 回电")
    try await library.store.enqueueRemoteDecision(rename)

    let masker = PrivacyMasker(keys: testOrganizerKeys)
    let spark = FakeSpark()
    let phone = masker.placeholder(type: "phone", value: "13812345678")
    let email = masker.placeholder(type: "email", value: "zhang.san@example.com")
    // What the organizing device writes about the item it was sent: masked.
    let sentText = masker.mask(Self.sentinelNote)
    let sentScalars = Array(sentText.unicodeScalars)
    let tomorrow = try XCTUnwrap(sentText.components(separatedBy: "明天").first).unicodeScalars
      .count
    spark.setState([
      "events": [
        [
          "event_id": "event-1", "title": "回电 \(phone)", "title_user_edited": false,
          "status_line": "已发邮件到 \(email)",
          "status_facts": [
            ["text": "约好 \(phone) 回电", "item_ids": [dictation.uuidString], "quote": email]
          ],
          "importance": 0.9, "item_ids": [dictation.uuidString], "person_ids": ["p1"],
          "pinned": false, "deleted": false, "provenance": [:] as [String: Any],
          "segments": [
            [
              "item_id": dictation.uuidString, "seg_id": "s1", "start": tomorrow,
              "end": sentScalars.count, "gist": "见面 \(phone)",
            ]
          ],
        ]
      ],
      "persons": [
        [
          "person_id": "p1", "display_name": "张三（\(phone)）", "aliases": [email],
          "origin": "chat",
        ]
      ],
      "questions": [
        [
          "question_id": "q1", "kind": "same_event", "a": "x", "b": "y",
          "prompt_zh": "\(phone) 和 〔手机号·000000〕 是同一件事吗？", "created_at": "2026-09-30T10:00:00+08:00",
        ]
      ],
    ])
    var projections: [RemoteOrganizerProjection] = []
    let runtime = makeRuntime(library.store, spark: spark) { _, projection in
      if let projection { projections.append(projection) }
    }
    runtime.start()
    try await waitUntil { spark.items.count == 3 && spark.decisions.count == 1 }

    // On the wire: placeholders only, in every text field.
    let wire = try String(
      decoding: JSONSerialization.data(withJSONObject: spark.items + spark.decisions), as: UTF8.self
    )
    for sentinel in Self.sentinels + ["6222021234567894", "Tr0ub4dor"] {
      XCTAssertFalse(wire.contains(sentinel), "\(sentinel) left the Mac")
    }
    XCTAssertTrue(wire.contains(phone))
    let byID = Dictionary(
      uniqueKeysWithValues: spark.items.map { ($0["item_id"] as? String ?? "", $0) })
    XCTAssertEqual(byID[dictation.uuidString]?["text"] as? String, sentText)
    XCTAssertEqual(byID[pasted.rawValue.uuidString]?["text"] as? String, sentText)
    XCTAssertEqual(
      byID[document.rawValue.uuidString]?["text"] as? String, "合同附件\n" + sentText)
    // The digest names the masked text, not the original.
    let sentDigest = SHA256.hash(data: Data(sentText.utf8)).map { String(format: "%02x", $0) }
      .joined()
    XCTAssertEqual(byID[dictation.uuidString]?["sha256"] as? String, sentDigest)
    XCTAssertEqual(spark.decisions.first?["title"] as? String, "给 \(phone) 回电")
    let mapped = try await library.scalar("SELECT COUNT(*) FROM remote_mask_map")
    XCTAssertGreaterThanOrEqual(Int(mapped ?? "0") ?? 0, 7)

    // Back on screen: every string the Spark wrote shows the originals.
    try await waitUntil { projections.last?.events.first?.statusLine.hasPrefix("已发邮件") == true }
    let projection = try XCTUnwrap(projections.last)
    let event = try XCTUnwrap(projection.events.first)
    // The user's own rename wins, and it was stored as typed.
    XCTAssertEqual(event.title, "给 13812345678 回电")
    XCTAssertEqual(event.statusLine, "已发邮件到 zhang.san@example.com")
    XCTAssertEqual(event.statusFacts.first?.text, "约好 13812345678 回电")
    XCTAssertEqual(event.statusFacts.first?.quote, "zhang.san@example.com")
    XCTAssertEqual(event.segments.first?.gist, "见面 13812345678")
    XCTAssertEqual(projection.persons.first?.displayName, "张三（13812345678）")
    XCTAssertEqual(projection.persons.first?.aliases, ["zhang.san@example.com"])
    XCTAssertEqual(projection.questions.first?.promptZH, "13812345678 和 〔手机号〕 是同一件事吗？")
    // The part's offsets were counted in the masked text; they now point at
    // the same words in the original.
    let part = try XCTUnwrap(event.segments.first)
    let original = Array(Self.sentinelNote.unicodeScalars)
    XCTAssertEqual(
      String(String.UnicodeScalarView(original[part.start..<part.end])),
      "明天下午三点在国贸见，预算 2000 元。")
    runtime.stop()
    await library.close()
  }

  func testAPlaceholderStandingForTwoValuesIsShownWithoutItsTag() async throws {
    let library = try SyntheticOrganizerLibrary()
    let placeholder = "〔手机号·abcdef〕"
    try await library.store.recordRemoteMasks(
      .init(
        ownerID: UUID().uuidString,
        entries: [.init(placeholder: placeholder, original: "13900000001", type: "phone")]))
    try await library.store.recordRemoteMasks(
      .init(
        ownerID: UUID().uuidString,
        entries: [.init(placeholder: placeholder, original: "13900000002", type: "phone")]))
    let state = try JSONDecoder().decode(
      RemoteOrganizerState.self,
      from: JSONSerialization.data(withJSONObject: [
        "cursor": 1, "questions": [] as [Any], "persons": [] as [Any],
        "events": [
          [
            "event_id": "e", "title": "打给 \(placeholder)", "title_user_edited": false,
            "status_line": "", "status_facts": [] as [Any], "importance": 0.5,
            "item_ids": [] as [Any], "person_ids": [] as [Any], "pinned": false,
            "deleted": false, "provenance": [:] as [String: Any],
          ]
        ],
      ]))
    _ = try await library.store.applyRemoteState(state)
    let projection = try await library.store.remoteProjection()
    XCTAssertEqual(projection.events.first?.title, "打给 〔手机号〕")
    await library.close()
  }

  // MARK: - Media

  private func fileItem(
    _ library: SyntheticOrganizerLibrary, name: String, mime: String, uti: String?, data: Data,
    at seconds: Double, extractor: String = UserItemLimits.fileBytesExtractor
  ) async throws -> SessionID {
    let id = SessionID()
    let ext = (name as NSString).pathExtension
    let relative = "sessions/\(id.rawValue.uuidString.lowercased())/source/original.\(ext)"
    let url = library.root.appendingPathComponent("assets").appendingPathComponent(relative)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try await library.store.createUserItem(
      UserItemDraft(
        id: id, kind: .file, capturedAt: Date(timeIntervalSince1970: seconds),
        source: ItemSourceApplication(bundleID: nil, name: "Finder"), sourceOrigin: .finder,
        text: "", extractor: extractor, originalFilename: name,
        attachments: [
          UserItemAttachment(
            role: .original, relativePath: relative, originalFilename: name, mediaType: mime,
            digest: try SHA256Digest(digest), sizeBytes: UInt64(data.count))
        ],
        uniformType: uti))
    return id
  }

  func testAudioAndVideoNeverLeaveAsBytesWhateverTheyAreCalled() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    // An `ftyp` box: MP4/M4A by content.
    let mp4 = Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8) + Data(repeating: 7, count: 64)
    let avi = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("AVI LIST".utf8) + Data(count: 32)
    let m4a = try await fileItem(
      library, name: "录音.m4a", mime: "audio/mp4", uti: "com.apple.m4a-audio", data: mp4,
      at: 1_000)
    let video = try await fileItem(
      library, name: "clip.mp4", mime: "video/mp4", uti: "public.mpeg-4", data: mp4, at: 2_000)
    let aviItem = try await fileItem(
      library, name: "old.avi", mime: "video/avi", uti: "public.avi", data: avi, at: 3_000)
    // Named like a spreadsheet, typed as bytes, but a video by content.
    let disguised = try await fileItem(
      library, name: "report.xlsx", mime: "application/octet-stream", uti: nil, data: mp4,
      at: 4_000)
    // Kept on the Mac by intake: never built into a payload at all.
    let localOnly = try await fileItem(
      library, name: "backup.7z", mime: "application/x-7z-compressed", uti: nil,
      data: Data("7z-synthetic".utf8), at: 5_000, extractor: UserItemLimits.localOnlyExtractor)
    let document = try await fileItem(
      library, name: "table.csv", mime: "text/csv", uti: "public.comma-separated-values-text",
      data: Data("a,b\n1,2\n".utf8), at: 6_000)
    let spark = FakeSpark()
    let reader = RemoteOrganizerItemAssetReader(
      assetRoot: library.root.appendingPathComponent("assets"))
    let runtime = RemoteOrganizerRuntime(
      repository: library.store, launcher: FakeTunnelLauncher(), http: spark,
      keys: testOrganizerKeys, itemAssetReader: reader, imageRedactor: IdentityRedactor(),
      fileSanitizer: IdentitySanitizer(), timing: fastTiming, onUpdate: { _, _ in })
    runtime.start()
    try await waitUntil { spark.items.count == 1 }
    try await Task.sleep(for: .milliseconds(150))
    runtime.stop()
    XCTAssertEqual(spark.items.map { $0["item_id"] as? String }, [document.rawValue.uuidString])
    for id in [m4a, video, aviItem, disguised] {
      let state = try await library.scalar(
        "SELECT state || '/' || error_category FROM remote_organizer_item_jobs WHERE item_id = ?",
        [id.rawValue.uuidString])
      XCTAssertEqual(state, "failed/local-only", id.rawValue.uuidString)
    }
    let parked = try await library.scalar(
      "SELECT error_category FROM remote_organizer_item_jobs WHERE item_id = ?",
      [localOnly.rawValue.uuidString])
    XCTAssertEqual(parked, "unsendable")
    await library.close()
  }

  // MARK: - Privacy review fixes (review/FINDINGS.md)

  /// F3: a file's bytes leave only as the sanitizer's send copy, which then
  /// says whether its pictures were redacted; with no sanitizer the file
  /// stays on the Mac.
  func testFileBytesLeaveOnlyAsASendCopy() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let bytes = Data("PK-synthetic-slides".utf8)
    let deck = try await fileItem(
      library, name: "方案.pptx", mime: "application/vnd.ms-powerpoint", uti: nil, data: bytes,
      at: 1_000)
    let reader = RemoteOrganizerItemAssetReader(
      assetRoot: library.root.appendingPathComponent("assets"))
    // No sanitizer: nothing leaves.
    let bare = FakeSpark()
    let first = RemoteOrganizerRuntime(
      repository: library.store, launcher: FakeTunnelLauncher(), http: bare,
      keys: testOrganizerKeys, itemAssetReader: reader, imageRedactor: IdentityRedactor(),
      timing: fastTiming, onUpdate: { _, _ in })
    first.start()
    try await waitUntil {
      try await library.scalar(
        "SELECT state || '/' || error_category FROM remote_organizer_item_jobs WHERE item_id = ?",
        [deck.rawValue.uuidString]) == "failed/local-only"
    }
    first.stop()
    XCTAssertTrue(bare.items.isEmpty)

    // With one: the copy, its own digest and size, and the pictures mark.
    let other = try SyntheticOrganizerLibrary()
    try await other.store.enableRemoteLink(at: enabledAt)
    let copy = try await fileItem(
      other, name: "方案.pptx", mime: "application/vnd.ms-powerpoint", uti: nil, data: bytes,
      at: 1_000)
    let spark = FakeSpark()
    let second = RemoteOrganizerRuntime(
      repository: other.store, launcher: FakeTunnelLauncher(), http: spark,
      keys: testOrganizerKeys,
      itemAssetReader: RemoteOrganizerItemAssetReader(
        assetRoot: other.root.appendingPathComponent("assets")),
      imageRedactor: IdentityRedactor(), fileSanitizer: MarkingSanitizer(), timing: fastTiming,
      onUpdate: { _, _ in })
    second.start()
    try await waitUntil { spark.items.count == 1 }
    second.stop()
    let sent = try XCTUnwrap(spark.items.first)
    XCTAssertEqual(sent["item_id"] as? String, copy.rawValue.uuidString)
    let sentBytes = try XCTUnwrap(
      (sent["bytes_b64"] as? String).flatMap { Data(base64Encoded: $0) })
    XCTAssertEqual(sentBytes, Data("sanitized:".utf8) + bytes)
    XCTAssertEqual(
      sent["sha256"] as? String,
      SHA256.hash(data: sentBytes).map { String(format: "%02x", $0) }.joined())
    XCTAssertEqual(sent["size"] as? Int, sentBytes.count)
    XCTAssertEqual(sent["pictures_redacted"] as? Bool, true)
    await library.close()
    await other.close()
  }

  /// F1: every request carries the key-derived access proof, and a store
  /// that refuses it (locked and opened again) is unlocked again.
  func testEveryRequestCarriesTheAccessProofAndARefusalUnlocksAgain() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let first = UUID()
    try await library.seedCompletedSession(first, createdAt: 1_000, text: "虚构口述一")
    let spark = FakeSpark()
    let runtime = makeRuntime(library.store, spark: spark)
    runtime.start()
    try await waitUntil { spark.items.count == 1 }
    spark.refuseAccess(1)
    let second = UUID()
    try await library.seedCompletedSession(second, createdAt: 2_000, text: "虚构口述二")
    _ = try await library.store.enqueueRemoteSession(sessionID: SessionID(second))
    try await waitUntil { spark.items.count == 2 }
    runtime.stop()
    XCTAssertTrue(spark.requests.allSatisfy { $0.accessProof == testOrganizerKeys.accessProof })
    XCTAssertEqual(spark.paths.filter { $0 == "/v1/unlock" }.count, 2)
    await library.close()
  }

  /// F1: sleep and quit lock the store; waking connects (and unlocks)
  /// again; a lock that fails is sent once more.
  func testSleepAndQuitLockTheStoreAndAFailedLockIsSentAgain() async throws {
    let library = try SyntheticOrganizerLibrary()
    let spark = FakeSpark()
    let controller = try makeController(library, spark: spark, keyStore: MemoryOrganizerKeyStore())
    await controller.setEnabled(true)
    try await waitUntil { controller.status == .connected }
    await controller.suspendForSleep()
    XCTAssertEqual(spark.lockCount, 1)
    XCTAssertTrue(spark.isLocked)
    XCTAssertFalse(controller.isRuntimeRunning)
    XCTAssertTrue(controller.isEnabled, "sleep does not turn the link off")
    controller.resumeAfterSleep()
    try await waitUntil { controller.status == .connected && !spark.isLocked }
    XCTAssertEqual(spark.paths.filter { $0 == "/v1/unlock" }.count, 2)

    spark.failLocks(1)
    await controller.shutdownLocking()
    XCTAssertEqual(spark.lockAttempts, 3, "the failed lock was sent once more")
    XCTAssertEqual(spark.lockCount, 2)
    XCTAssertTrue(spark.isLocked)
    XCTAssertFalse(controller.isRuntimeRunning)
    await library.close()
  }

  /// F11: when the key store cannot destroy the forgotten key, the link
  /// stops instead of going on with it.
  func testForgettingNeverGoesOnWithAKeyItCouldNotDestroy() async throws {
    let library = try SyntheticOrganizerLibrary()
    let spark = FakeSpark()
    let keyStore = MemoryOrganizerKeyStore()
    let controller = try makeController(library, spark: spark, keyStore: keyStore)
    await controller.setEnabled(true)
    try await waitUntil { controller.status == .connected }
    let oldKey = try XCTUnwrap(controller.keyID)
    keyStore.failWrites = true
    let outcome = await controller.forgetOnOrganizer(.mine)
    XCTAssertEqual(outcome, .keyNotDestroyed)
    XCTAssertEqual(spark.wipes, [oldKey])
    XCTAssertEqual(controller.status, .keyUnavailable)
    XCTAssertFalse(controller.isRuntimeRunning)
    let unlocksAfterWipe = spark.requests.drop(while: { $0.path != "/v1/wipe" }).filter {
      $0.path == "/v1/unlock"
    }
    XCTAssertTrue(unlocksAfterWipe.isEmpty, "the forgotten key never unlocks again")
    await library.close()
  }

  /// F14: an item whose send was under way when the link went off may be on
  /// the organizing device; deleting it later still queues the deletion.
  func testAnItemInFlightAtRevocationStillGetsItsRemoteDeletion() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let inFlight = UUID()
    try await library.seedCompletedSession(inFlight, createdAt: 1_000, text: "送出途中的虚构口述")
    let spark = FakeSpark()
    spark.holdItemPosts()
    let runtime = makeRuntime(library.store, spark: spark)
    runtime.start()
    try await waitUntil { spark.isHoldingItem }
    runtime.stop()
    spark.releaseHeldItem()
    try await library.store.revokeRemoteLink()
    try await library.store.deleteSessionRecordsExplicitly(sessionIDs: [SessionID(inFlight)])
    let pending = try await library.store.pendingRemoteDeletions()
    XCTAssertEqual(pending, [inFlight.uuidString])
    await library.close()
  }
}
