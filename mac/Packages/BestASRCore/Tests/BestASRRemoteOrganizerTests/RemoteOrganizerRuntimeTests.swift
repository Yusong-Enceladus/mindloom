import BestASRDomain
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import XCTest

/// Deterministic runtime tests: fake ssh launcher, fake Spark, real SQLite
/// store on a temporary synthetic library. No network, no ssh.
@MainActor
final class RemoteOrganizerRuntimeTests: XCTestCase {
  private let enabledAt = Date(timeIntervalSince1970: 500)

  private func makeRuntime(
    _ repository: any RemoteOrganizerRepository, launcher: FakeTunnelLauncher, spark: FakeSpark,
    updates: @escaping (RemoteOrganizerRuntime.LinkState, RemoteOrganizerProjection?) -> Void
  ) -> RemoteOrganizerRuntime {
    RemoteOrganizerRuntime(
      repository: repository, launcher: launcher, http: spark, timing: fastTiming,
      onUpdate: updates
    )
  }

  private func itemJobState(_ library: SyntheticOrganizerLibrary, _ id: UUID) async throws
    -> String?
  {
    try await library.scalar(
      "SELECT state FROM remote_organizer_item_jobs WHERE item_id = ?", [id.uuidString]
    )
  }

  func testNothingIsSentWhenTheForwardPortIsNotHeldByOurSSH() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let sessionID = UUID()
    try await library.seedCompletedSession(sessionID, createdAt: 1000, text: "虚构口述")
    _ = try await library.store.enqueueRemoteSession(sessionID: SessionID(sessionID))
    let launcher = FakeTunnelLauncher()
    launcher.ownsListener = false
    let spark = FakeSpark()
    var states: [RemoteOrganizerRuntime.LinkState] = []
    let runtime = makeRuntime(library.store, launcher: launcher, spark: spark) { state, _ in
      states.append(state)
    }
    runtime.start()
    try await waitUntil { launcher.launched.count >= 3 }
    runtime.stop()
    XCTAssertTrue(spark.requests.isEmpty, "a request left before the owner check passed")
    XCTAssertEqual(launcher.tokenFetches, 0)
    XCTAssertFalse(states.contains(.connected))
    XCTAssertTrue(states.contains(.unavailable))
    XCTAssertTrue(launcher.launched.allSatisfy(\.terminated))
    let pending = try await itemJobState(library, sessionID)
    XCTAssertEqual(pending, "queued")
    await library.close()
  }

  func testOwnerCheckRunsBeforeEveryRequestNotOnlyAtConnect() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let launcher = FakeTunnelLauncher()
    let spark = FakeSpark()
    var states: [RemoteOrganizerRuntime.LinkState] = []
    let runtime = makeRuntime(library.store, launcher: launcher, spark: spark) { state, _ in
      states.append(state)
    }
    runtime.start()
    try await waitUntil { spark.paths.contains { $0.hasPrefix("/v1/state") } }
    XCTAssertTrue(states.contains(.connected))
    // Another process now holds the port (our ssh lost it): the next request
    // must not leave, although the tunnel was verified when it connected.
    launcher.ownsListener = false
    let countAtLoss = spark.requests.count
    let sessionID = UUID()
    try await library.seedCompletedSession(sessionID, createdAt: 1000, text: "虚构口述")
    _ = try await library.store.enqueueRemoteSession(sessionID: SessionID(sessionID))
    try await waitUntil { states.last == .unavailable }
    try await Task.sleep(for: .milliseconds(150))
    runtime.stop()
    let after = spark.requests.dropFirst(countAtLoss)
    XCTAssertLessThanOrEqual(after.count, 1, "at most a request already in flight")
    XCTAssertFalse(after.contains { $0.path == "/v1/items" })
    XCTAssertTrue(spark.items.isEmpty)
    await library.close()
  }

  func testRequestsCarryTokenToOwnedPortAndSendCurrentRevision() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let sessionID = UUID()
    try await library.seedCompletedSession(sessionID, createdAt: 1000, text: "第一版虚构口述")
    // Not enqueued explicitly: the reconciliation sweep must find it.
    let launcher = FakeTunnelLauncher()
    let spark = FakeSpark()
    var states: [RemoteOrganizerRuntime.LinkState] = []
    let runtime = makeRuntime(library.store, launcher: launcher, spark: spark) { state, _ in
      states.append(state)
    }
    runtime.start()
    try await waitUntil { spark.items.count == 1 }
    XCTAssertEqual(spark.items.first?["text"] as? String, "第一版虚构口述")
    XCTAssertEqual(spark.items.first?["item_id"] as? String, sessionID.uuidString)
    XCTAssertEqual(spark.paths.first, "/v1/health")
    let port = try XCTUnwrap(launcher.launched.last?.localPort)
    XCTAssertTrue(spark.requests.allSatisfy { $0.token == launcher.token && $0.port == port })
    XCTAssertEqual(launcher.tokenFetches, 1)
    XCTAssertGreaterThanOrEqual(launcher.cleanUps, 1)
    XCTAssertTrue(states.contains(.connected))

    // An edit after delivery goes out as a higher revision with the new text.
    try await library.addRevision(
      sessionID, revision: 2, kind: "userEdit", text: "修改后的虚构口述", createdAt: 1003
    )
    try await waitUntil { spark.items.count == 2 }
    let firstRevision = try XCTUnwrap(spark.items[0]["revision"] as? Int)
    let secondRevision = try XCTUnwrap(spark.items[1]["revision"] as? Int)
    XCTAssertGreaterThan(secondRevision, firstRevision)
    XCTAssertEqual(spark.items[1]["text"] as? String, "修改后的虚构口述")
    runtime.stop()
    await library.close()
  }

  func testHealthClockIsExposedSoATestConfigurationCanBeShown() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let launcher = FakeTunnelLauncher()
    let spark = FakeSpark()
    spark.setClock("fixed")
    let runtime = makeRuntime(library.store, launcher: launcher, spark: spark) { _, _ in }
    XCTAssertNil(runtime.serviceClock)
    runtime.start()
    try await waitUntil { runtime.serviceClock != nil }
    XCTAssertEqual(runtime.serviceClock, "fixed")
    runtime.stop()
    await library.close()
  }

  func testUnauthorizedDropsTheTokenAndFetchesItAgainOnReconnect() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let sessionID = UUID()
    try await library.seedCompletedSession(sessionID, createdAt: 1000, text: "虚构口述")
    let rotated = String(repeating: "cd", count: 32)
    let spark = FakeSpark(token: rotated)  // the Spark's token was rotated
    let launcher = FakeTunnelLauncher()
    launcher.onTokenFetch = { [unowned launcher] in
      if launcher.tokenFetches >= 2 { launcher.token = rotated }
    }
    var states: [RemoteOrganizerRuntime.LinkState] = []
    let runtime = makeRuntime(library.store, launcher: launcher, spark: spark) { state, _ in
      states.append(state)
    }
    runtime.start()
    try await waitUntil { spark.items.count == 1 }
    runtime.stop()
    XCTAssertEqual(launcher.tokenFetches, 2, "one refetch after the 401")
    XCTAssertTrue(states.contains(.unavailable))
    XCTAssertEqual(spark.requests.first?.token, String(repeating: "ab", count: 32))
    XCTAssertEqual(spark.requests.last?.token, rotated)
    // The item was never lost; it is delivered under the new token.
    try await waitUntil { try await self.itemJobState(library, sessionID) == "delivered" }
    await library.close()
  }

  func testDuplicateOrStaleReceiptMarksTheJobDeliveredWithoutResending() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let sessionID = UUID()
    try await library.seedCompletedSession(sessionID, createdAt: 1000, text: "虚构口述")
    let spark = FakeSpark()
    spark.seedItem(sessionID.uuidString, revision: 9)  // the Spark holds a newer one
    let launcher = FakeTunnelLauncher()
    let runtime = makeRuntime(library.store, launcher: launcher, spark: spark) { _, _ in }
    runtime.start()
    try await waitUntil { spark.duplicates == 1 }
    try await waitUntil { try await self.itemJobState(library, sessionID) == "delivered" }
    try await Task.sleep(for: .milliseconds(120))
    runtime.stop()
    XCTAssertEqual(spark.duplicates, 1, "a duplicate receipt is final; nothing is resent")
    XCTAssertTrue(spark.items.isEmpty)
    await library.close()
  }

  func testStopIsSynchronousAndNoLateStatusOrProjectionArrives() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let launcher = FakeTunnelLauncher()
    let spark = FakeSpark()
    spark.holdStatePulls()
    var updates: [RemoteOrganizerRuntime.LinkState] = []
    let runtime = makeRuntime(library.store, launcher: launcher, spark: spark) { state, _ in
      updates.append(state)
    }
    runtime.start()
    try await waitUntil { spark.isHoldingState }
    let countAtStop = updates.count
    runtime.stop()
    // Revocation has finished when stop() returns.
    XCTAssertEqual(runtime.state, .off)
    XCTAssertFalse(runtime.isRunning)
    XCTAssertTrue(spark.cancelled)
    XCTAssertTrue(launcher.launched.allSatisfy(\.terminated))
    // The in-flight pull now completes; nothing may reach the app.
    spark.releaseHeldState()
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(updates.count, countAtStop)
    XCTAssertEqual(runtime.state, .off)
    let requestsAfter = spark.requests.count
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(spark.requests.count, requestsAfter)
    await library.close()
  }

  func testStoreIdentityChangeResendsDeliveredItems() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let sessionID = UUID()
    try await library.seedCompletedSession(sessionID, createdAt: 1000, text: "虚构记录")
    let launcher = FakeTunnelLauncher()
    let spark = FakeSpark()
    let runtime = makeRuntime(library.store, launcher: launcher, spark: spark) { _, _ in }
    runtime.start()
    try await waitUntil { spark.items.count == 1 }
    // Wait until the mirror has a cursor above 0, so a later since=0 pull can
    // only come from the reset.
    try await waitUntil {
      spark.paths.contains { $0.hasPrefix("/v1/state?since=") && $0 != "/v1/state?since=0" }
    }
    let requestsBeforeReset = spark.requests.count
    spark.setStoreID("store-b")
    try await waitUntil { spark.items.count == 2 }
    XCTAssertEqual(spark.items[1]["item_id"] as? String, sessionID.uuidString)
    XCTAssertEqual(spark.items[1]["revision"] as? Int, spark.items[0]["revision"] as? Int)
    // After the reset is seen, the state is pulled again from cursor 0.
    try await waitUntil {
      spark.paths.dropFirst(requestsBeforeReset).contains("/v1/state?since=0")
    }
    runtime.stop()
    let storeID = try await library.store.remoteLinkRecord().storeID
    XCTAssertEqual(storeID, "store-b")
    await library.close()
  }

  func testDecisionsInOrderRejectedStaysVisibleAndExpiredAnswerFallsBack() async throws {
    let library = try SyntheticOrganizerLibrary()
    let store = library.store
    try await store.enableRemoteLink(at: enabledAt)
    let pin = RemoteOrganizerDecision(kind: "pin_event", eventID: "event-1", pinned: true)
    let rename = RemoteOrganizerDecision(kind: "rename_event", eventID: "event-1", title: "新标题")
    let answer = RemoteOrganizerDecision(
      kind: "same_event", questionID: "question-1", a: "item-1", b: "event-1", answer: true
    )
    for decision in [pin, rename, answer] { try await store.enqueueRemoteDecision(decision) }
    let launcher = FakeTunnelLauncher()
    let spark = FakeSpark()
    spark.reject(kind: "rename_event", reason: "unknown or deleted event")
    spark.setQuestionStatus(409)
    var projections: [RemoteOrganizerProjection] = []
    let runtime = makeRuntime(store, launcher: launcher, spark: spark) { _, projection in
      if let projection { projections.append(projection) }
    }
    runtime.start()
    try await waitUntil { spark.decisions.count == 3 }
    XCTAssertEqual(
      spark.decisions.map { $0["kind"] as? String }, ["pin_event", "rename_event", "same_event"])
    let decisionPaths = spark.paths.filter { $0 != "/v1/health" && !$0.hasPrefix("/v1/state") }
    XCTAssertEqual(
      decisionPaths,
      ["/v1/decisions", "/v1/decisions", "/v1/questions/question-1/answer", "/v1/decisions"]
    )
    try await waitUntil {
      projections.last?.unacceptedDecisions.map(\.decisionID) == [rename.decisionID]
    }
    let issue = try XCTUnwrap(projections.last?.unacceptedDecisions.first)
    XCTAssertEqual(issue.state, .rejected)
    XCTAssertEqual(issue.reason, "unknown or deleted event")
    XCTAssertEqual(issue.errorCategory, "rejected")
    runtime.stop()
    await library.close()
  }

  func testAlreadyAnsweredWithoutAppliedIsConfirmedThroughThePlainDecision() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let answer = RemoteOrganizerDecision(
      kind: "same_event", questionID: "question-9", a: "item-1", b: "event-1", answer: true
    )
    try await library.store.enqueueRemoteDecision(answer)
    let spark = FakeSpark()
    // An older service replies this way to a replay even if nothing applied.
    spark.setQuestionBody(["ok": true, "note": "already answered"])
    let runtime = makeRuntime(library.store, launcher: FakeTunnelLauncher(), spark: spark) {
      _, _ in
    }
    runtime.start()
    try await waitUntil { spark.decisions.count == 1 }
    runtime.stop()
    let paths = spark.paths.filter { $0 != "/v1/health" && !$0.hasPrefix("/v1/state") }
    XCTAssertEqual(paths, ["/v1/questions/question-9/answer", "/v1/decisions"])
    XCTAssertEqual(spark.decisions.first?["decision_id"] as? String, answer.decisionID.uuidString)
    await library.close()
  }

  func testTransientRecoveryErrorDoesNotStopTheWorker() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let sessionID = UUID()
    try await library.seedCompletedSession(sessionID, createdAt: 1000, text: "虚构口述")
    let repository = FlakyRecoveryRepository(base: library.store, failures: 1)
    let spark = FakeSpark()
    var states: [RemoteOrganizerRuntime.LinkState] = []
    let runtime = makeRuntime(repository, launcher: FakeTunnelLauncher(), spark: spark) {
      state, _ in states.append(state)
    }
    runtime.start()
    try await waitUntil { spark.items.count == 1 }
    runtime.stop()
    XCTAssertEqual(states.first, .connecting)
    XCTAssertTrue(states.contains(.unavailable), "the failure is shown, then retried")
    XCTAssertGreaterThanOrEqual(repository.recoveryCalls, 2)
    await library.close()
  }

  func testDecisionRowWithoutAJobIsPickedUpOnTheNextPoll() async throws {
    let library = try SyntheticOrganizerLibrary()
    try await library.store.enableRemoteLink(at: enabledAt)
    let spark = FakeSpark()
    let runtime = makeRuntime(library.store, launcher: FakeTunnelLauncher(), spark: spark) {
      _, _ in
    }
    runtime.start()
    try await waitUntil { spark.paths.contains { $0.hasPrefix("/v1/state") } }
    // A stored decision without a job (for example left by an older build)
    // is queued by the running worker, without a restart.
    let orphan = RemoteOrganizerDecision(kind: "feature_less", eventID: "event-7")
    let payload = try JSONEncoder().encode(orphan)
    try await library.write { db in
      try db.execute(
        sql:
          "INSERT INTO remote_organizer_decisions (id, payload_json, created_at) VALUES (?, ?, 1)",
        arguments: [orphan.decisionID.uuidString, payload]
      )
    }
    try await waitUntil { spark.decisions.count == 1 }
    runtime.stop()
    XCTAssertEqual(spark.decisions.first?["decision_id"] as? String, orphan.decisionID.uuidString)
    await library.close()
  }
}

@MainActor
final class RemoteOrganizerLinkControllerTests: XCTestCase {
  private func syntheticRoot() throws -> URL {
    let root = try makeTemporaryDirectory()
    FileManager.default.createFile(
      atPath: root.appendingPathComponent(RemoteOrganizerDataProvenance.syntheticMarkerFileName)
        .path,
      contents: Data()
    )
    return root
  }

  private func makeController(
    _ repository: any RemoteOrganizerRepository, root: URL, realLibrary: URL,
    intent: RemoteOrganizerMemoryLinkIntent = RemoteOrganizerMemoryLinkIntent(),
    launcher: FakeTunnelLauncher = FakeTunnelLauncher(), spark: FakeSpark = FakeSpark(),
    cleanUps: @escaping @MainActor () -> Void = {},
    runtimesMade: @escaping @MainActor () -> Void = {}
  ) -> RemoteOrganizerLinkController {
    RemoteOrganizerLinkController(
      repository: repository, dataRoot: root, realLibraryRoot: realLibrary,
      intent: intent, cleanUpStaleTunnels: cleanUps,
      makeRuntime: { repository, onUpdate in
        runtimesMade()
        return RemoteOrganizerRuntime(
          repository: repository, launcher: launcher, http: spark, timing: fastTiming,
          onUpdate: onUpdate
        )
      }
    )
  }

  func testRealLibraryAndUnmarkedRootsNeverStartTheLink() async throws {
    let library = try SyntheticOrganizerLibrary()
    let realLibrary = try makeTemporaryDirectory("real-library")
    // Even a marker placed inside the real library does not make it sendable.
    FileManager.default.createFile(
      atPath: realLibrary.appendingPathComponent(
        RemoteOrganizerDataProvenance.syntheticMarkerFileName
      ).path,
      contents: Data()
    )
    let unmarked = try makeTemporaryDirectory("unmarked")
    var runtimesMade = 0
    var cleanUps = 0
    for (root, expected) in [
      (realLibrary, RemoteOrganizerDataProvenance.Verdict.refusedRealLibrary),
      (realLibrary.appendingPathComponent("nested"), .refusedRealLibrary),
      (unmarked, .refusedNotSynthetic),
    ] {
      let controller = makeController(
        library.store, root: root, realLibrary: realLibrary,
        cleanUps: { cleanUps += 1 }, runtimesMade: { runtimesMade += 1 }
      )
      await controller.setEnabled(true)
      XCTAssertEqual(controller.status, .refused(expected))
      XCTAssertFalse(controller.isEnabled)
      XCTAssertFalse(controller.isRuntimeRunning)
      let record = try await library.store.remoteLinkRecord()
      XCTAssertNil(record.enabledAt)
    }
    XCTAssertEqual(runtimesMade, 0)
    XCTAssertEqual(cleanUps, 3, "orphaned forwards are ended even when the root is refused")
    XCTAssertFalse(RemoteOrganizerDataProvenance.productReleaseAllowsOwnLibrary)
    await library.close()
  }

  func testRevocationStopsSendingAndClearsTheOutbox() async throws {
    let library = try SyntheticOrganizerLibrary()
    let root = try syntheticRoot()
    let launcher = FakeTunnelLauncher()
    let spark = FakeSpark()
    var cleanUps = 0
    var statuses: [RemoteOrganizerLinkController.Status] = []
    let intent = RemoteOrganizerMemoryLinkIntent()
    let controller = makeController(
      library.store, root: root, realLibrary: try makeTemporaryDirectory("real"),
      intent: intent, launcher: launcher, spark: spark, cleanUps: { cleanUps += 1 }
    )
    controller.onChange = { status, _ in statuses.append(status) }
    await controller.restoreOnLaunch()
    XCTAssertEqual(controller.status, .off)
    XCTAssertEqual(cleanUps, 1, "a stale forward from a previous run is cleaned at launch")
    await controller.setEnabled(true)
    XCTAssertTrue(controller.isEnabled)
    XCTAssertTrue(controller.isRuntimeRunning)
    XCTAssertEqual(cleanUps, 2, "and again when the link is enabled")
    try await waitUntil { controller.status == .connected }

    // One item is on its way to the Spark (the response is held) and one
    // decision waits behind it.
    spark.holdItemPosts()
    let sessionID = UUID()
    try await library.seedCompletedSession(
      sessionID, createdAt: Date().timeIntervalSince1970, text: "开启期间的虚构口述"
    )
    try await controller.enqueueCompletedSession(SessionID(sessionID))
    try await controller.record(.init(kind: "feature_less", eventID: "event-1"))
    try await waitUntil { spark.isHoldingItem }
    let requestsAtRevoke = spark.requests.count
    let statusesAtRevoke = statuses.count

    // Revocation: the synchronous part alone already stops everything.
    controller.revokeNow()
    XCTAssertFalse(intent.onRecorded, "the on marker is gone before anything else")
    XCTAssertFalse(controller.isRuntimeRunning)
    XCTAssertFalse(controller.isEnabled)
    XCTAssertEqual(controller.status, .off)
    XCTAssertNil(controller.projection)
    XCTAssertTrue(launcher.launched.allSatisfy(\.terminated))
    XCTAssertTrue(spark.cancelled)
    spark.releaseHeldItem()
    await controller.revokeStorage()
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(spark.requests.count, requestsAtRevoke, "nothing is sent after revocation")
    XCTAssertEqual(Array(statuses.dropFirst(statusesAtRevoke)), [.off], "no late status")
    let cleared = try await library.scalar(
      "SELECT state FROM remote_organizer_item_jobs WHERE item_id = ?", [sessionID.uuidString]
    )
    XCTAssertNil(cleared, "the in-flight item is not recorded as delivered; its job is cleared")
    let record = try await library.store.remoteLinkRecord()
    XCTAssertNil(record.enabledAt)
    let decisionState = try await library.scalar(
      "SELECT state || '/' || error_category FROM remote_organizer_decision_jobs"
    )
    XCTAssertEqual(decisionState, "cancelled/revoked")
    // Captured while off: nothing is queued.
    let offSession = UUID()
    try await library.seedCompletedSession(
      offSession, createdAt: Date().timeIntervalSince1970 + 2, text: "关闭期间的虚构口述"
    )
    try await controller.enqueueCompletedSession(SessionID(offSession))
    let direct = try await library.store.enqueueRemoteSession(sessionID: SessionID(offSession))
    XCTAssertFalse(direct)
    await library.close()
  }

  func testWorkerCannotTurnTheLinkBackOnBetweenTheToggleAndTheStorageWrite() async throws {
    let library = try SyntheticOrganizerLibrary()
    let spark = FakeSpark()
    var statuses: [RemoteOrganizerLinkController.Status] = []
    let controller = makeController(
      library.store, root: try syntheticRoot(), realLibrary: try makeTemporaryDirectory("real"),
      spark: spark
    )
    controller.onChange = { status, _ in statuses.append(status) }
    await controller.setEnabled(true)
    // The worker publishes on every 20 ms poll while connected.
    try await waitUntil { statuses.filter { $0 == .connected }.count >= 3 }
    let requestsAtToggle = spark.requests.count
    let statusesAtToggle = statuses.count
    controller.revokeNow()
    // Main-actor work queued behind the toggle (worker resumptions, publishes)
    // runs now, before the library write.
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(Array(statuses.dropFirst(statusesAtToggle)), [.off])
    XCTAssertFalse(controller.isEnabled)
    XCTAssertEqual(spark.requests.count, requestsAtToggle)
    await controller.revokeStorage()
    XCTAssertEqual(controller.status, .off)
    await library.close()
  }

  func testLaunchFailsClosedWhenTheMarkerDisappears() async throws {
    let library = try SyntheticOrganizerLibrary()
    let root = try syntheticRoot()
    try await library.store.enableRemoteLink(at: Date(timeIntervalSince1970: 500))
    try FileManager.default.removeItem(
      at: root.appendingPathComponent(RemoteOrganizerDataProvenance.syntheticMarkerFileName)
    )
    var runtimesMade = 0
    let intent = RemoteOrganizerMemoryLinkIntent(onRecorded: true)
    let controller = makeController(
      library.store, root: root, realLibrary: try makeTemporaryDirectory("real"),
      intent: intent, runtimesMade: { runtimesMade += 1 }
    )
    await controller.restoreOnLaunch()
    XCTAssertEqual(controller.status, .refused(.refusedNotSynthetic))
    XCTAssertFalse(intent.onRecorded)
    XCTAssertFalse(controller.isEnabled)
    XCTAssertEqual(runtimesMade, 0)
    let record = try await library.store.remoteLinkRecord()
    XCTAssertNil(record.enabledAt)
    await library.close()
  }

  func testTurningOffFailsClosedWhenTheLibraryWriteFails() async throws {
    let library = try SyntheticOrganizerLibrary()
    let root = try syntheticRoot()
    let realLibrary = try makeTemporaryDirectory("real")
    let intent = RemoteOrganizerMemoryLinkIntent()
    let failing = FailingRevokeRepository(base: library.store)
    var runtimesMade = 0
    let first = makeController(
      failing, root: root, realLibrary: realLibrary, intent: intent,
      runtimesMade: { runtimesMade += 1 }
    )
    await first.setEnabled(true)
    XCTAssertTrue(first.isRuntimeRunning)
    await first.setEnabled(false)
    XCTAssertEqual(first.status, .storageUnavailable)
    XCTAssertFalse(first.isEnabled)
    let stillEnabled = try await library.store.remoteLinkRecord()
    XCTAssertNotNil(stillEnabled.enabledAt, "the revocation did not commit")

    // Next launch: a session recorded meanwhile, the write still failing.
    let sessionID = UUID()
    try await library.seedCompletedSession(
      sessionID, createdAt: Date().timeIntervalSince1970, text: "关闭后的虚构口述"
    )
    let relaunched = makeController(
      failing, root: root, realLibrary: realLibrary, intent: intent,
      runtimesMade: { runtimesMade += 1 }
    )
    await relaunched.restoreOnLaunch()
    XCTAssertEqual(relaunched.status, .storageUnavailable)
    XCTAssertFalse(relaunched.isEnabled)
    XCTAssertEqual(runtimesMade, 1, "no runtime starts while the off intent is pending")

    // Once the library can be written again, the launch finishes the
    // revocation before anything else, and nothing is left to send.
    let healed = makeController(
      library.store, root: root, realLibrary: realLibrary, intent: intent,
      runtimesMade: { runtimesMade += 1 }
    )
    await healed.restoreOnLaunch()
    XCTAssertEqual(healed.status, .off)
    XCTAssertEqual(runtimesMade, 1)
    let record = try await library.store.remoteLinkRecord()
    XCTAssertNil(record.enabledAt)
    let swept = try await library.store.reconcileRemoteItems()
    XCTAssertEqual(swept, 0)
    let claim = try await library.store.claimNextRemoteItem(now: Date())
    XCTAssertNil(claim)
    await library.close()
  }

  func testLaunchResumesOnlyWithBothTheOnMarkerAndTheWatermark() async throws {
    let library = try SyntheticOrganizerLibrary()
    let root = try syntheticRoot()
    let realLibrary = try makeTemporaryDirectory("real")
    var runtimesMade = 0
    // Watermark without the marker (an enable that never recorded it, or a
    // revocation whose library write failed): the launch revokes, sends nothing.
    try await library.store.enableRemoteLink(at: Date(timeIntervalSince1970: 500))
    let sessionID = UUID()
    try await library.seedCompletedSession(
      sessionID, createdAt: Date().timeIntervalSince1970, text: "虚构口述")
    let unmarked = makeController(
      library.store, root: root, realLibrary: realLibrary,
      runtimesMade: { runtimesMade += 1 })
    await unmarked.restoreOnLaunch()
    XCTAssertEqual(unmarked.status, .off)
    XCTAssertEqual(runtimesMade, 0)
    let revoked = try await library.store.remoteLinkRecord()
    XCTAssertNil(revoked.enabledAt)
    let swept = try await library.store.reconcileRemoteItems()
    XCTAssertEqual(swept, 0)

    // Marker without the watermark: stays off and the stale marker goes.
    let intent = RemoteOrganizerMemoryLinkIntent(onRecorded: true)
    let stale = makeController(
      library.store, root: root, realLibrary: realLibrary, intent: intent,
      runtimesMade: { runtimesMade += 1 })
    await stale.restoreOnLaunch()
    XCTAssertEqual(stale.status, .off)
    XCTAssertFalse(intent.onRecorded)
    XCTAssertEqual(runtimesMade, 0)

    // Both: resumes.
    await stale.setEnabled(true)
    XCTAssertTrue(intent.onRecorded)
    stale.shutdown()
    let resumed = makeController(
      library.store, root: root, realLibrary: realLibrary, intent: intent,
      runtimesMade: { runtimesMade += 1 })
    await resumed.restoreOnLaunch()
    XCTAssertTrue(resumed.isEnabled)
    XCTAssertTrue(resumed.isRuntimeRunning)
    await resumed.setEnabled(false)
    await library.close()
  }

  func testAFailedMarkerRemovalIsShownAndCannotResumeTheLink() async throws {
    let library = try SyntheticOrganizerLibrary()
    let root = try syntheticRoot()
    let realLibrary = try makeTemporaryDirectory("real")
    let intent = RemoteOrganizerMemoryLinkIntent()
    var runtimesMade = 0
    let controller = makeController(
      library.store, root: root, realLibrary: realLibrary, intent: intent,
      runtimesMade: { runtimesMade += 1 })
    await controller.setEnabled(true)
    XCTAssertTrue(controller.isRuntimeRunning)
    intent.failWrites = true
    controller.revokeNow()
    XCTAssertEqual(controller.status, .storageUnavailable, "not a silent 'off'")
    XCTAssertFalse(controller.isRuntimeRunning)
    await controller.revokeStorage()
    XCTAssertEqual(controller.status, .off, "the library write finished the revocation")
    XCTAssertTrue(intent.onRecorded, "the marker is still there")
    let relaunched = makeController(
      library.store, root: root, realLibrary: realLibrary, intent: intent,
      runtimesMade: { runtimesMade += 1 })
    await relaunched.restoreOnLaunch()
    XCTAssertFalse(relaunched.isEnabled, "a marker alone never resumes the link")
    XCTAssertEqual(runtimesMade, 1)
    await library.close()
  }

  func testOnMarkerIsKeyedByTheCanonicalRootNotItsSpelling() throws {
    let run = UUID().uuidString
    let state = try makeTemporaryDirectory("state-\(run)")
    let root = try makeTemporaryDirectory("root-Canonical-\(run)")
    let alias = try makeTemporaryDirectory("alias-parent-\(run)").appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    let first = RemoteOrganizerLinkIntentFile(stateDirectory: state, dataRoot: root)
    XCTAssertFalse(first.onRecorded)
    try first.recordOn()
    let spellings = [
      alias,
      URL(
        fileURLWithPath: root.path.uppercased().replacingOccurrences(
          of: "/PRIVATE/", with: "/private/")),
      URL(fileURLWithPath: root.path + "/."),
    ]
    for spelling in spellings {
      XCTAssertTrue(
        RemoteOrganizerLinkIntentFile(stateDirectory: state, dataRoot: spelling).onRecorded,
        spelling.path)
    }
    try RemoteOrganizerLinkIntentFile(stateDirectory: state, dataRoot: alias).clearOn()
    XCTAssertFalse(first.onRecorded)
    XCTAssertNoThrow(try first.clearOn(), "removing an absent marker is not an error")
  }

  func testArchiveImportTurnsTheLinkOffAndRestoredDecisionsWaitForTheUser() async throws {
    let library = try SyntheticOrganizerLibrary()
    let spark = FakeSpark()
    let controller = makeController(
      library.store, root: try syntheticRoot(), realLibrary: try makeTemporaryDirectory("real"),
      spark: spark
    )
    await controller.setEnabled(true)
    try await waitUntil { controller.status == .connected }

    // An archive from another library holding one correction.
    let otherRoot = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: otherRoot) }
    let other = try GRDBDictationStore(
      databaseURL: otherRoot.appendingPathComponent("other.sqlite"))
    let restored = RemoteOrganizerDecision(kind: "pin_event", eventID: "event-3", pinned: true)
    try await other.enqueueRemoteDecision(restored)
    let archive = try await other.exportPortablePersistenceState()
    try await other.checkpointAndClose()

    try await library.store.importPortablePersistenceState(archive)
    let turnedOff = await controller.archiveImported()
    XCTAssertTrue(turnedOff)
    XCTAssertFalse(controller.isEnabled)
    XCTAssertFalse(controller.isRuntimeRunning)
    XCTAssertEqual(controller.status, .off)
    let jobState = try await library.scalar(
      "SELECT state || '/' || error_category FROM remote_organizer_decision_jobs WHERE decision_id = ?",
      [restored.decisionID.uuidString]
    )
    XCTAssertEqual(jobState, "cancelled/imported")

    // Turned on again, the restored correction is listed right away (no
    // restart) but is not sent until the user retries it.
    await controller.setEnabled(true)
    try await waitUntil {
      controller.projection?.unacceptedDecisions.map(\.decisionID) == [restored.decisionID]
    }
    XCTAssertEqual(controller.projection?.unacceptedDecisions.first?.state, .notSent)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(spark.decisions.isEmpty)
    try await controller.retryDecision(restored.decisionID)
    try await waitUntil { spark.decisions.count == 1 }
    XCTAssertEqual(spark.decisions.first?["kind"] as? String, "pin_event")
    XCTAssertNotEqual(
      spark.decisions.first?["decision_id"] as? String, restored.decisionID.uuidString,
      "a retry is a new decision, evaluated afresh by the Spark"
    )
    await controller.setEnabled(false)
    await library.close()
  }
}
