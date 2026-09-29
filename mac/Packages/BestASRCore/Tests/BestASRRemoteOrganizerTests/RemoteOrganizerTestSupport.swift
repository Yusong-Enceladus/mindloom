import BestASRDomain
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import GRDB
import XCTest

/// Fabricated library on a temporary SQLite file; never the owner's library.
final class SyntheticOrganizerLibrary: @unchecked Sendable {
  let root: URL
  let url: URL
  let store: GRDBDictationStore
  /// The store's own writer may be mid-transaction (the organizer worker
  /// polls), so the fixture connection waits instead of failing.
  static let busyTolerant: Configuration = {
    var configuration = Configuration()
    configuration.busyMode = .timeout(10)
    return configuration
  }()

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-organizer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    url = root.appendingPathComponent("synthetic.sqlite")
    store = try GRDBDictationStore(databaseURL: url)
  }

  func close() async {
    try? await store.checkpointAndClose()
    try? FileManager.default.removeItem(at: root)
  }

  func write(_ body: @escaping @Sendable (Database) throws -> Void) async throws {
    let writer = try DatabaseQueue(path: url.path, configuration: Self.busyTolerant)
    try await writer.write(body)
    try await writer.close()
  }

  func scalar(_ sql: String, _ arguments: StatementArguments = []) async throws -> String? {
    let reader = try DatabaseQueue(path: url.path, configuration: Self.busyTolerant)
    let value = try await reader.read { db in
      try String.fetchOne(db, sql: sql, arguments: arguments)
    }
    try await reader.close()
    return value
  }

  func seedCompletedSession(_ id: UUID, createdAt: Double, text: String) async throws {
    let sessionID = id.uuidString
    try await write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions (
            id, revision, input_mode, state, source_audio_retention,
            created_at, updated_at
          ) VALUES (?, 1, 'dictation', 'completed', 'retained', ?, ?)
          """, arguments: [sessionID, createdAt, createdAt + 1]
      )
      // As the live capture path does: eligible only while the link is on.
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO remote_organizer_eligible (session_id, eligible_at)
          SELECT ?, ? WHERE EXISTS (
            SELECT 1 FROM remote_organizer_meta WHERE key = 'link_enabled_at')
          """, arguments: [sessionID, createdAt]
      )
      try db.execute(
        sql: """
          INSERT INTO dictation_snapshots (
            session_id, control_revision, phase, snapshot_json,
            is_ephemeral, updated_at
          ) VALUES (?, 1, 'completed', ?, 0, ?)
          """, arguments: [sessionID, Data("{}".utf8), createdAt + 1]
      )
    }
    try await addRevision(id, revision: 1, kind: "final", text: text, createdAt: createdAt + 1)
  }

  func addRevision(
    _ id: UUID, revision: Int64, kind: String, text: String, createdAt: Double
  ) async throws {
    let sessionID = id.uuidString
    try await write { db in
      try db.execute(
        sql: """
          INSERT INTO transcript_revisions (
            id, session_id, revision, kind, content, created_at
          ) VALUES (?, ?, ?, ?, ?, ?)
          """, arguments: [UUID().uuidString, sessionID, revision, kind, text, createdAt]
      )
    }
  }
}

@MainActor
final class FakeTunnelProcess: RemoteOrganizerTunnelProcess {
  let processIdentifier: Int32
  let localPort: Int
  private(set) var isRunning = true
  private(set) var terminated = false

  init(processIdentifier: Int32, localPort: Int) {
    self.processIdentifier = processIdentifier
    self.localPort = localPort
  }

  func terminateAndWait() {
    isRunning = false
    terminated = true
  }
}

@MainActor
final class FakeTunnelLauncher: RemoteOrganizerTunnelLauncher {
  var ownsListener = true
  var token = String(repeating: "ab", count: 32)
  private(set) var launched: [FakeTunnelProcess] = []
  private(set) var tokenFetches = 0
  private(set) var cleanUps = 0
  private var nextPort = 41_000

  func freeLoopbackPort() throws -> Int {
    nextPort += 7
    return nextPort
  }

  func launchForward(localPort: Int) async throws -> any RemoteOrganizerTunnelProcess {
    let process = FakeTunnelProcess(
      processIdentifier: Int32(9_000 + launched.count), localPort: localPort
    )
    launched.append(process)
    return process
  }

  func listenerIsOwned(by pid: Int32, port: Int) -> Bool {
    ownsListener
      && launched.contains {
        $0.processIdentifier == pid && $0.localPort == port && $0.isRunning
      }
  }

  /// Called on every token fetch (for example to rotate the token).
  var onTokenFetch: (() -> Void)?

  func fetchLinkToken() async throws -> String {
    tokenFetches += 1
    onTokenFetch?()
    return token
  }

  func cleanUpStaleTunnels() {
    cleanUps += 1
  }
}

/// In-memory stand-in for the Spark organizer API. Like the real service it
/// requires the link token (401 with WWW-Authenticate otherwise) and applies
/// the item revision rule: same or lower revision is a duplicate, a higher one
/// replaces the content.
final class FakeSpark: RemoteOrganizerHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var _requests: [RemoteOrganizerHTTPRequest] = []
  private var _items: [[String: Any]] = []
  private var _revisions: [String: Int] = [:]
  private var _duplicates = 0
  private var _decisions: [[String: Any]] = []
  private var _decisionReceipts: [String: (Bool, String)] = [:]
  private var _cancelled = false
  private var _storeID = "store-a"
  private var _clock: String? = "wall"
  private var _cursor = 1
  private var _token: String?
  private var _holdState = false
  private var _held: CheckedContinuation<Void, Never>?
  private var _holdItems = false
  private var _heldItem: CheckedContinuation<Void, Never>?
  private var _rejectKinds: [String: String] = [:]
  private var _questionStatus = 200
  private var _questionBody: [String: Any] = ["ok": true, "applied": true]
  private var _inbox: [[String: Any]] = []
  private var _inboxAckFailures = 0
  private var _acked: [String] = []
  private var _inboxCursor = 0

  /// `token` is the link token the service requires (nil: not checked).
  init(token: String? = String(repeating: "ab", count: 32)) {
    _token = token
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  var requests: [RemoteOrganizerHTTPRequest] { locked { _requests } }
  var paths: [String] { locked { _requests.map(\.path) } }
  /// Items the service accepted (duplicates and stale revisions excluded).
  var items: [[String: Any]] { locked { _items } }
  var duplicates: Int { locked { _duplicates } }
  var decisions: [[String: Any]] { locked { _decisions } }
  var cancelled: Bool { locked { _cancelled } }
  var isHoldingState: Bool { locked { _held != nil } }
  var isHoldingItem: Bool { locked { _heldItem != nil } }

  /// A new store identity is a new, empty store.
  func setStoreID(_ value: String) {
    locked {
      _storeID = value
      _revisions = [:]
    }
  }
  func rotateToken(_ value: String) { locked { _token = value } }
  func setClock(_ value: String?) { locked { _clock = value } }
  func holdStatePulls() { locked { _holdState = true } }
  func holdItemPosts() { locked { _holdItems = true } }
  func reject(kind: String, reason: String) { locked { _rejectKinds[kind] = reason } }
  func setQuestionStatus(_ status: Int) { locked { _questionStatus = status } }
  func setQuestionBody(_ body: [String: Any]) { locked { _questionBody = body } }
  /// Entries the phone left in the inbox (`inbox_id`, `kind`, ...).
  func addInbox(_ entry: [String: Any]) { locked { _inbox.append(entry) } }
  /// The next `count` acknowledgements fail with 500.
  func failInboxAcks(_ count: Int) { locked { _inboxAckFailures = count } }
  var acked: [String] { locked { _acked } }
  var inboxLeft: Int { locked { _inbox.count } }

  /// The service already holds `itemID` at `revision`.
  func seedItem(_ itemID: String, revision: Int) { locked { _revisions[itemID] = revision } }

  func releaseHeldState() {
    let continuation: CheckedContinuation<Void, Never>? = locked {
      _holdState = false
      defer { _held = nil }
      return _held
    }
    continuation?.resume()
  }

  func releaseHeldItem() {
    let continuation: CheckedContinuation<Void, Never>? = locked {
      _holdItems = false
      defer { _heldItem = nil }
      return _heldItem
    }
    continuation?.resume()
  }

  func send(_ request: RemoteOrganizerHTTPRequest) async throws -> RemoteOrganizerHTTPResponse {
    locked { _requests.append(request) }
    func json(_ object: Any, status: Int = 200) throws -> RemoteOrganizerHTTPResponse {
      RemoteOrganizerHTTPResponse(
        status: status, body: try JSONSerialization.data(withJSONObject: object)
      )
    }
    if let required = locked({ _token }), request.token != required {
      return try json(["detail": "missing or invalid link token"], status: 401)
    }
    let body = request.body.flatMap {
      try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    if request.path == "/v1/health" {
      let (storeID, clock) = locked { (_storeID, _clock) }
      var health: [String: Any] = ["ok": true, "store_id": storeID]
      if let clock { health["clock"] = clock }
      return try json(health)
    }
    if request.path == "/v1/items" {
      if locked({ _holdItems }) {
        await withCheckedContinuation { continuation in
          locked { _heldItem = continuation }
        }
      }
      let received = body?["items"] as? [[String: Any]] ?? []
      let (accepted, duplicates) = locked { () -> (Int, Int) in
        var accepted = 0
        var duplicates = 0
        for item in received {
          let id = item["item_id"] as? String ?? ""
          let revision = item["revision"] as? Int ?? 0
          if let known = _revisions[id], revision <= known {
            duplicates += 1
            _duplicates += 1
          } else {
            _revisions[id] = revision
            _items.append(item)
            accepted += 1
          }
        }
        return (accepted, duplicates)
      }
      return try json(["accepted": accepted, "duplicates": duplicates])
    }
    if request.path == "/v1/decisions" {
      let received = body?["decisions"] as? [[String: Any]] ?? []
      let rejectKinds = locked {
        _decisions += received
        return _rejectKinds
      }
      if let kind = received.first?["kind"] as? String, let reason = rejectKinds[kind] {
        return try json(["applied": 0, "rejected": [["index": 0, "reason": reason]]])
      }
      return try json(["applied": received.count, "rejected": [] as [Any]])
    }
    if request.path.hasPrefix("/v1/questions/") {
      let (status, answer) = locked { (_questionStatus, _questionBody) }
      return status == 200
        ? try json(answer) : try json(["detail": "question expired"], status: status)
    }
    if request.path.hasPrefix("/v1/inbox?since=") {
      // Every entry not yet acknowledged, like the real service after a relaunch.
      let (entries, cursor) = locked { () -> ([[String: Any]], Int) in
        _inboxCursor += 1
        return (_inbox, _inboxCursor)
      }
      return try json(["cursor": cursor, "items": entries])
    }
    if request.method == "POST", request.path.hasPrefix("/v1/inbox/"),
      request.path.hasSuffix("/ack")
    {
      let id =
        String(request.path.dropFirst("/v1/inbox/".count).dropLast("/ack".count))
        .removingPercentEncoding ?? ""
      let failed = locked { () -> Bool in
        if _inboxAckFailures > 0 {
          _inboxAckFailures -= 1
          return true
        }
        _inbox.removeAll { ($0["inbox_id"] as? String) == id }
        _acked.append(id)
        return false
      }
      return failed ? try json(["detail": "busy"], status: 500) : try json(["ok": true])
    }
    if request.path.hasPrefix("/v1/state") {
      if locked({ _holdState }) {
        await withCheckedContinuation { continuation in
          locked { _held = continuation }
        }
      }
      let (cursor, storeID) = locked {
        _cursor += 1
        return (_cursor, _storeID)
      }
      return try json([
        "cursor": cursor, "store_id": storeID, "events": [] as [Any],
        "questions": [] as [Any], "persons": [] as [Any],
      ])
    }
    return try json(["detail": "not found"], status: 404)
  }

  func cancelAll() {
    locked { _cancelled = true }
  }
}

/// Passes everything to the real store, but the first `failures` calls of
/// `recoverRemoteDecisionsToOutbox` throw (for example a transient busy error).
final class FlakyRecoveryRepository: RemoteOrganizerRepository, @unchecked Sendable {
  private let base: GRDBDictationStore
  private let lock = NSLock()
  private var remainingFailures: Int
  private(set) var recoveryCalls = 0

  init(base: GRDBDictationStore, failures: Int) {
    self.base = base
    remainingFailures = failures
  }

  struct TransientFailure: Error {}

  func remoteLinkRecord() async throws -> RemoteOrganizerLinkRecord {
    try await base.remoteLinkRecord()
  }
  func enableRemoteLink(at date: Date) async throws { try await base.enableRemoteLink(at: date) }
  func revokeRemoteLink() async throws { try await base.revokeRemoteLink() }
  func enqueueRemoteSession(sessionID: SessionID) async throws -> Bool {
    try await base.enqueueRemoteSession(sessionID: sessionID)
  }
  func reconcileRemoteItems() async throws -> Int { try await base.reconcileRemoteItems() }
  func claimNextRemoteItem(now: Date) async throws -> RemoteOrganizerItemDelivery? {
    try await base.claimNextRemoteItem(now: now)
  }
  func markRemoteItemDelivered(_ delivery: RemoteOrganizerItemDelivery) async throws {
    try await base.markRemoteItemDelivered(delivery)
  }
  func markRemoteItemFailed(
    _ delivery: RemoteOrganizerItemDelivery, category: String, retryAt: Date?
  ) async throws {
    try await base.markRemoteItemFailed(delivery, category: category, retryAt: retryAt)
  }
  func enqueueRemoteDecision(_ decision: RemoteOrganizerDecision) async throws {
    try await base.enqueueRemoteDecision(decision)
  }
  func recoverRemoteDecisionsToOutbox() async throws -> Int {
    let fail = lock.withLock {
      recoveryCalls += 1
      guard remainingFailures > 0 else { return false }
      remainingFailures -= 1
      return true
    }
    if fail { throw TransientFailure() }
    return try await base.recoverRemoteDecisionsToOutbox()
  }
  func resetRemoteLeases() async throws { try await base.resetRemoteLeases() }
  func claimNextRemoteDecision(now: Date) async throws -> RemoteOrganizerDecisionDelivery? {
    try await base.claimNextRemoteDecision(now: now)
  }
  func markRemoteDecisionDelivered(id: UUID) async throws {
    try await base.markRemoteDecisionDelivered(id: id)
  }
  func markRemoteDecisionFailed(
    id: UUID, category: String, reason: String?, retryAt: Date?
  ) async throws {
    try await base.markRemoteDecisionFailed(
      id: id, category: category, reason: reason, retryAt: retryAt)
  }
  func retryRemoteDecision(id: UUID) async throws { try await base.retryRemoteDecision(id: id) }
  func discardRemoteDecision(id: UUID) async throws { try await base.discardRemoteDecision(id: id) }
  func remoteCursor() async throws -> Int64 { try await base.remoteCursor() }
  func observeRemoteStoreID(_ storeID: String) async throws -> Bool {
    try await base.observeRemoteStoreID(storeID)
  }
  func applyRemoteState(_ state: RemoteOrganizerState) async throws -> Bool {
    try await base.applyRemoteState(state)
  }
  func remoteProjection() async throws -> RemoteOrganizerProjection {
    try await base.remoteProjection()
  }
}

/// A repository whose revocation write always fails (for example the disk is
/// full), everything else from the real store.
final class FailingRevokeRepository: RemoteOrganizerRepository, @unchecked Sendable {
  private let base: FlakyRecoveryRepository
  struct RevokeFailure: Error {}

  init(base: GRDBDictationStore) {
    self.base = FlakyRecoveryRepository(base: base, failures: 0)
  }

  func revokeRemoteLink() async throws { throw RevokeFailure() }
  func remoteLinkRecord() async throws -> RemoteOrganizerLinkRecord {
    try await base.remoteLinkRecord()
  }
  func enableRemoteLink(at date: Date) async throws { try await base.enableRemoteLink(at: date) }
  func enqueueRemoteSession(sessionID: SessionID) async throws -> Bool {
    try await base.enqueueRemoteSession(sessionID: sessionID)
  }
  func reconcileRemoteItems() async throws -> Int { try await base.reconcileRemoteItems() }
  func claimNextRemoteItem(now: Date) async throws -> RemoteOrganizerItemDelivery? {
    try await base.claimNextRemoteItem(now: now)
  }
  func markRemoteItemDelivered(_ delivery: RemoteOrganizerItemDelivery) async throws {
    try await base.markRemoteItemDelivered(delivery)
  }
  func markRemoteItemFailed(
    _ delivery: RemoteOrganizerItemDelivery, category: String, retryAt: Date?
  ) async throws {
    try await base.markRemoteItemFailed(delivery, category: category, retryAt: retryAt)
  }
  func enqueueRemoteDecision(_ decision: RemoteOrganizerDecision) async throws {
    try await base.enqueueRemoteDecision(decision)
  }
  func recoverRemoteDecisionsToOutbox() async throws -> Int {
    try await base.recoverRemoteDecisionsToOutbox()
  }
  func resetRemoteLeases() async throws { try await base.resetRemoteLeases() }
  func claimNextRemoteDecision(now: Date) async throws -> RemoteOrganizerDecisionDelivery? {
    try await base.claimNextRemoteDecision(now: now)
  }
  func markRemoteDecisionDelivered(id: UUID) async throws {
    try await base.markRemoteDecisionDelivered(id: id)
  }
  func markRemoteDecisionFailed(
    id: UUID, category: String, reason: String?, retryAt: Date?
  ) async throws {
    try await base.markRemoteDecisionFailed(
      id: id, category: category, reason: reason, retryAt: retryAt)
  }
  func retryRemoteDecision(id: UUID) async throws { try await base.retryRemoteDecision(id: id) }
  func discardRemoteDecision(id: UUID) async throws { try await base.discardRemoteDecision(id: id) }
  func remoteCursor() async throws -> Int64 { try await base.remoteCursor() }
  func observeRemoteStoreID(_ storeID: String) async throws -> Bool {
    try await base.observeRemoteStoreID(storeID)
  }
  func applyRemoteState(_ state: RemoteOrganizerState) async throws -> Bool {
    try await base.applyRemoteState(state)
  }
  func remoteProjection() async throws -> RemoteOrganizerProjection {
    try await base.remoteProjection()
  }
}

let fastTiming = RemoteOrganizerRuntime.Timing(
  pollInterval: .milliseconds(20),
  reconnectDelay: .milliseconds(20),
  tunnelReadyTimeout: .milliseconds(100),
  tunnelPollInterval: .milliseconds(5),
  requestTimeout: 5
)

@MainActor
func waitUntil(
  timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
  _ condition: @MainActor () async throws -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while try await !condition() {
    guard Date() < deadline else {
      XCTFail("condition not met in time", file: file, line: line)
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

func makeTemporaryDirectory(_ name: String = UUID().uuidString) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("bestasr-organizer-\(name)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
