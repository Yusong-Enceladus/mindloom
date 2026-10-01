import BestASRDomain
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import GRDB
import XCTest

/// The library key every test runtime unlocks with (synthetic).
let testOrganizerKeys: OrganizerKeyMaterial = {
  // swift-format-ignore: NeverUseForceTry
  try! OrganizerKeyMaterial(libraryKey: Data(repeating: 0x42, count: 32))
}()

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
  // Contract v6: a store locked with a key that lives only on the Mac.
  private var _supportsLocking = true
  private var _locked = true
  private var _storeKeyID: String?
  private var _unlockedKeyID: String?
  private var _locks = 0
  private var _wipes: [String] = []
  private var _deletedItems: [String] = []
  private var _tombstones = Set<String>()
  private var _failDeletes = 0
  private var _stateExtras: [String: Any] = [:]
  private var _holdLocks = false
  // Privacy review F1: after an unlock, data routes need the key's access proof.
  private var _accessProof: String?
  private var _failLocks = 0
  private var _lockAttempts = 0
  private var _refuseAccess = 0

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
  var isLocked: Bool { locked { _locked } }
  var storeKeyID: String? { locked { _storeKeyID } }
  var lockCount: Int { locked { _locks } }
  /// Lock requests received (answered or failed).
  var lockAttempts: Int { locked { _lockAttempts } }
  /// The next `count` lock requests fail with 500.
  func failLocks(_ count: Int) { locked { _failLocks = count } }
  /// The next `count` data requests are refused with 403 `access` (the store
  /// was locked and opened again).
  func refuseAccess(_ count: Int) { locked { _refuseAccess = count } }
  var wipes: [String] { locked { _wipes } }
  var deletedItems: [String] { locked { _deletedItems } }

  /// An older service without `/v1/unlock` (and no encryption at rest).
  func dropLockingSupport() { locked { _supportsLocking = false } }
  /// The store on disk belongs to this key ID (another library's key).
  func setStoreKeyID(_ keyID: String?) { locked { _storeKeyID = keyID } }
  /// A restart: the store is locked again, the key gone from memory.
  func restart() {
    locked {
      _locked = true
      _unlockedKeyID = nil
    }
  }
  /// Lock requests never answer (a hung organizing device).
  func holdLocks() { locked { _holdLocks = true } }
  /// What `/v1/state` returns besides its cursor and store (events, persons,
  /// questions, readings).
  func setState(_ extras: [String: Any]) { locked { _stateExtras = extras } }
  /// The next `count` deletions fail with 500.
  func failDeletes(_ count: Int) { locked { _failDeletes = count } }
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
      let (storeID, clock, supportsLocking, isLocked, keyID) = locked {
        (_storeID, _clock, _supportsLocking, _locked, _storeKeyID)
      }
      var health: [String: Any] = ["ok": true]
      if let clock { health["clock"] = clock }
      if supportsLocking {
        health["locked"] = isLocked
        health["key_id"] = keyID ?? NSNull()
        if !isLocked { health["store_id"] = storeID }
      } else {
        health["store_id"] = storeID
      }
      return try json(health)
    }
    let supportsLocking = locked { _supportsLocking }
    if supportsLocking, request.path == "/v1/unlock" {
      guard let hex = body?["key"] as? String, hex.count == 64,
        let data = Self.bytes(hex), let keys = try? OrganizerKeyMaterial(libraryKey: data)
      else { return try json(["error": "malformed key"], status: 400) }
      let outcome = locked { () -> (Int, [String: Any]) in
        if let onDisk = _storeKeyID, onDisk != keys.keyID {
          return (409, ["error": "wrong_key", "key_id": onDisk])
        }
        let created = _storeKeyID == nil
        _storeKeyID = keys.keyID
        _unlockedKeyID = keys.keyID
        _accessProof = keys.accessProof
        _locked = false
        return (200, ["locked": false, "key_id": keys.keyID, "created": created])
      }
      return try json(outcome.1, status: outcome.0)
    }
    if supportsLocking, request.path == "/v1/lock" {
      if locked({ _holdLocks }) { try? await Task.sleep(for: .seconds(30)) }
      let failed = locked { () -> Bool in
        _lockAttempts += 1
        if _failLocks > 0 {
          _failLocks -= 1
          return true
        }
        _locked = true
        _unlockedKeyID = nil
        _accessProof = nil
        _locks += 1
        return false
      }
      return failed ? try json(["detail": "busy"], status: 500) : try json(["locked": true])
    }
    if supportsLocking, request.path == "/v1/wipe" {
      let keyID = body?["key_id"] as? String ?? ""
      let outcome = locked { () -> Int in
        guard _storeKeyID == nil || _storeKeyID == keyID else { return 409 }
        _wipes.append(keyID)
        _storeKeyID = nil
        _unlockedKeyID = nil
        _locked = true
        _revisions = [:]
        _items = []
        _tombstones = []
        return 200
      }
      return outcome == 200
        ? try json(["wiped": true]) : try json(["error": "wrong_key"], status: 409)
    }
    // Every data route needs an unlocked store (the inbox excepted).
    if supportsLocking, locked({ _locked }), !request.path.hasPrefix("/v1/inbox") {
      return try json(["error": "locked"], status: 423)
    }
    // ... and, once unlocked, the key-derived access proof (review F1).
    if supportsLocking, !request.path.hasPrefix("/v1/inbox") {
      let refused = locked { () -> Bool in
        if _refuseAccess > 0 {
          _refuseAccess -= 1
          _locked = true
          _accessProof = nil
          return true
        }
        return _accessProof != nil && request.accessProof != _accessProof
      }
      if refused { return try json(["error": "access"], status: 403) }
    }
    if request.method == "DELETE", request.path.hasPrefix("/v1/items/") {
      let id =
        String(request.path.dropFirst("/v1/items/".count)).removingPercentEncoding ?? ""
      let failed = locked { () -> Bool in
        if _failDeletes > 0 {
          _failDeletes -= 1
          return true
        }
        _deletedItems.append(id)
        _tombstones.insert(id)
        _items.removeAll { ($0["item_id"] as? String) == id }
        _revisions[id] = nil
        return false
      }
      return failed ? try json(["detail": "busy"], status: 500) : try json(["deleted": true])
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
          if _tombstones.contains(id) { continue }
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
      let ids = received.map { $0["item_id"] as? String ?? "" }
      let tombstoned = locked { ids.contains { _tombstones.contains($0) } }
      if tombstoned { return try json(["error": "deleted"], status: 410) }
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
      let (cursor, storeID, extras) = locked {
        _cursor += 1
        return (_cursor, _storeID, _stateExtras)
      }
      var state: [String: Any] = [
        "cursor": cursor, "store_id": storeID, "events": [] as [Any],
        "questions": [] as [Any], "persons": [] as [Any],
      ]
      state.merge(extras) { _, new in new }
      return try json(state)
    }
    return try json(["detail": "not found"], status: 404)
  }

  func cancelAll() {
    locked { _cancelled = true }
  }

  static func bytes(_ hex: String) -> Data? {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      data.append(byte)
      index = next
    }
    return data
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
  func recordRemoteMasks(_ record: RemoteOrganizerMaskRecord) async throws {
    try await base.recordRemoteMasks(record)
  }
  func claimNextRemoteDeletion(now: Date) async throws -> String? {
    try await base.claimNextRemoteDeletion(now: now)
  }
  func markRemoteDeletionSent(itemID: String) async throws {
    try await base.markRemoteDeletionSent(itemID: itemID)
  }
  func markRemoteDeletionFailed(itemID: String, retryAt: Date) async throws {
    try await base.markRemoteDeletionFailed(itemID: itemID, retryAt: retryAt)
  }
  func forgetRemoteStore() async throws { try await base.forgetRemoteStore() }
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
  func recordRemoteMasks(_ record: RemoteOrganizerMaskRecord) async throws {
    try await base.recordRemoteMasks(record)
  }
  func claimNextRemoteDeletion(now: Date) async throws -> String? {
    try await base.claimNextRemoteDeletion(now: now)
  }
  func markRemoteDeletionSent(itemID: String) async throws {
    try await base.markRemoteDeletionSent(itemID: itemID)
  }
  func markRemoteDeletionFailed(itemID: String, retryAt: Date) async throws {
    try await base.markRemoteDeletionFailed(itemID: itemID, retryAt: retryAt)
  }
  func forgetRemoteStore() async throws { try await base.forgetRemoteStore() }
}

/// Sends a screenshot as it is (the runtime tests check byte identity; the
/// Vision redactor has its own tests in the intake suite).
struct IdentityRedactor: RemoteOrganizerImageRedacting {
  func redactedSendCopy(of data: Data, mediaType: String) throws -> Data { data }
}

/// Sends a file's bytes as they are, pictures not redacted (the file
/// sanitizer has its own tests in the intake suite).
struct IdentitySanitizer: RemoteOrganizerFileSanitizing {
  func sendCopy(of data: Data, filename: String) throws -> RemoteOrganizerFileSendCopy {
    RemoteOrganizerFileSendCopy(data: data, picturesRedacted: false)
  }
}

/// A send copy made here: the bytes replaced, pictures marked redacted.
struct MarkingSanitizer: RemoteOrganizerFileSanitizing {
  func sendCopy(of data: Data, filename: String) throws -> RemoteOrganizerFileSendCopy {
    RemoteOrganizerFileSendCopy(data: Data("sanitized:".utf8) + data, picturesRedacted: true)
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
