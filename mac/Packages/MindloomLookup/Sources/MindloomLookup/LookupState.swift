import CryptoKit
import Foundation

// MARK: - Each search service's state

/// What Settings shows for a search service, and whether the chain uses it.
public enum SearchServiceCondition: String, Codable, Sendable {
  /// No key.
  case notAdded
  /// Has a key and answered (or has not been asked yet).
  case ready
  /// The service refused the key. Skipped until the key changes.
  case badKey
  /// The key's allowance is used up. Skipped for a day.
  case quotaUsed
  /// No connection could be made. Skipped for 30 minutes.
  case unreachable
  /// Too many requests. Skipped for as long as the service asks.
  case rateLimited
  /// The service failed. Skipped for 5 minutes.
  case failing
}

public struct SearchServiceStatus: Sendable, Equatable, Identifiable {
  public var service: SearchServiceID
  public var condition: SearchServiceCondition
  /// The key is stored so that it follows the owner's iCloud Keychain to
  /// their other devices.
  public var syncsAcrossDevices: Bool
  public var id: SearchServiceID { service }
}

/// Remembers each service's last failure from real requests only (no probe,
/// no network detection; WEBSEARCH §4.3).
actor SearchServiceStates {
  struct State: Codable, Equatable {
    var condition: SearchServiceCondition
    var until: Date?
    /// The first 16 hex characters of SHA-256 of the key the condition is
    /// about: a new key clears a `badKey`.
    var keyFingerprint: String?
  }

  private let fileURL: URL?
  private let now: @Sendable () -> Date
  private var states: [SearchServiceID: State] = [:]
  private var loaded = false

  init(fileURL: URL?, now: @escaping @Sendable () -> Date) {
    self.fileURL = fileURL
    self.now = now
  }

  static func fingerprint(_ key: String) -> String {
    String(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
  }

  private func load() {
    guard !loaded else { return }
    loaded = true
    guard let fileURL,
      let stored = PrivateFiles.readJSON([String: State].self, from: fileURL, maximumBytes: 64 * 1024)
    else { return }
    for (name, state) in stored {
      if let service = SearchServiceID(rawValue: name) { states[service] = state }
    }
  }

  private func save() {
    guard let fileURL else { return }
    let stored = Dictionary(uniqueKeysWithValues: states.map { ($0.key.rawValue, $0.value) })
    try? PrivateFiles.writeJSON(stored, to: fileURL)
  }

  /// The condition for `key` now (an expired skip is `ready` again).
  func condition(_ service: SearchServiceID, key: String?) -> SearchServiceCondition {
    load()
    guard let key else { return .notAdded }
    guard let state = states[service] else { return .ready }
    if state.condition == .badKey {
      return state.keyFingerprint == Self.fingerprint(key) ? .badKey : .ready
    }
    if let until = state.until, until > now() { return state.condition }
    return .ready
  }

  func usable(_ service: SearchServiceID, key: String) -> Bool {
    condition(service, key: key) == .ready
  }

  func note(_ service: SearchServiceID, key: String, failure: SearchFailure) {
    load()
    let current = now()
    let state: State
    switch failure {
    case .badKey:
      state = State(condition: .badKey, until: nil, keyFingerprint: Self.fingerprint(key))
    case .quotaUsed:
      state = State(condition: .quotaUsed, until: current.addingTimeInterval(86_400))
    case .rateLimited(let retryAfter):
      state = State(condition: .rateLimited, until: current.addingTimeInterval(min(max(retryAfter ?? 60, 1), 3_600)))
    case .server, .malformed:
      state = State(condition: .failing, until: current.addingTimeInterval(300))
    }
    states[service] = state
    save()
  }

  func noteUnreachable(_ service: SearchServiceID) {
    load()
    states[service] = State(condition: .unreachable, until: now().addingTimeInterval(1_800))
    save()
  }

  func noteAnswered(_ service: SearchServiceID) {
    load()
    guard states[service] != nil else { return }
    states[service] = nil
    save()
  }

  func forget(_ service: SearchServiceID) {
    load()
    states[service] = nil
    save()
  }
}

// MARK: - Limits

/// The limits that keep many harmless requests from adding up to a leak
/// (MATTER-MINIMUM §7.5, §8.6; WEBSEARCH §4.6). They count requests that
/// carry words (a search, a name lookup, an identifier), answered or not;
/// downloading the whole deadline table and reading pages count for nothing.
///
/// A gap's two sends are counted over a week (the same words are not sent
/// again within a week either). A send that got no usable answer (a server
/// error, a timeout, too many requests, a refused key) counts for that gap
/// for a day only, and not at all once the owner changes that service's
/// key: a short outage or a wrong key must not close a matter's gap for
/// good. Every send counts toward the per-matter and daily limits.
actor LookupLimits {
  static let perGap = 2
  static let perMatterPerDay = 3
  static let perDay = 20
  static let gapWindow: TimeInterval = 7 * 86_400
  static let failedGapWindow: TimeInterval = 86_400

  struct Ledger: Codable {
    struct Send: Codable {
      var time: Date
      var matter: UUID
      var gap: String
      /// The service or source the words went to.
      var service: String?
      /// No usable answer came back.
      var failed: Bool?
      /// The owner changed that service's key since.
      var forgiven: Bool?
    }
    var sends: [Send] = []
  }

  private let fileURL: URL?
  private let now: @Sendable () -> Date
  private var ledger = Ledger()
  private var loaded = false

  init(fileURL: URL?, now: @escaping @Sendable () -> Date) {
    self.fileURL = fileURL
    self.now = now
  }

  static func gapKey(_ request: LookupRequest) -> String {
    "\(request.matterID.uuidString.lowercased())|\(request.gap.rawValue)"
  }

  private func load() {
    guard !loaded else { return }
    loaded = true
    if let fileURL, let stored = PrivateFiles.readJSON(Ledger.self, from: fileURL, maximumBytes: 1024 * 1024) {
      ledger = stored
    }
    let cutoff = now().addingTimeInterval(-90 * 86_400)
    ledger.sends.removeAll { $0.time < cutoff }
  }

  /// The limit this request would break, or nil.
  func limit(for request: LookupRequest) -> LookupLimit? {
    load()
    let key = Self.gapKey(request)
    let current = now()
    let dayAgo = current.addingTimeInterval(-86_400)
    let gapSends = ledger.sends.filter { send in
      guard send.gap == key, send.forgiven != true else { return false }
      let window = send.failed == true ? Self.failedGapWindow : Self.gapWindow
      return send.time > current.addingTimeInterval(-window)
    }
    if gapSends.count >= Self.perGap { return .gapLimit }
    let today = ledger.sends.filter { $0.time > dayAgo }
    if today.filter({ $0.matter == request.matterID }).count >= Self.perMatterPerDay { return .matterDailyLimit }
    if today.count >= Self.perDay { return .dailyLimit }
    return nil
  }

  func record(_ request: LookupRequest, service: String, failed: Bool) {
    load()
    ledger.sends.append(
      Ledger.Send(
        time: now(), matter: request.matterID, gap: Self.gapKey(request), service: service,
        failed: failed ? true : nil))
    save()
  }

  /// The owner changed `service`'s key: sends that failed there no longer
  /// hold any gap closed.
  func forgiveFailures(service: String) {
    load()
    var changed = false
    for index in ledger.sends.indices where ledger.sends[index].service == service && ledger.sends[index].failed == true {
      ledger.sends[index].forgiven = true
      changed = true
    }
    if changed { save() }
  }

  private func save() {
    if let fileURL { try? PrivateFiles.writeJSON(ledger, to: fileURL) }
  }
}

// MARK: - Cache of public answers

/// Public answers kept so the same words are not sent again: paper records
/// for 30 days; names, places and search results for 7 days; the deadline
/// table for a day (an older copy is used when a new one cannot be had).
actor LookupCache {
  static let paper: TimeInterval = 30 * 86_400
  static let week: TimeInterval = 7 * 86_400
  static let table: TimeInterval = 86_400

  struct Envelope: Codable {
    var expires: Date
    var body: Data
    /// When the answer was fetched (its sources say 「取到的时间」 from this,
    /// not from when the cache answered).
    var fetchedAt: Date?
  }

  private let folder: URL?
  private let now: @Sendable () -> Date
  private var memory: [String: Envelope] = [:]

  init(folder: URL?, now: @escaping @Sendable () -> Date) {
    self.folder = folder
    self.now = now
  }

  static func name(_ key: String) -> String {
    SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// The body for `key`; an expired one only when `stale` is allowed.
  func body(_ key: String, stale: Bool = false) -> Data? {
    entry(key, stale: stale)?.body
  }

  /// The body and when it was fetched.
  func entry(_ key: String, stale: Bool = false) -> (body: Data, fetchedAt: Date?)? {
    let name = Self.name(key)
    var envelope = memory[name]
    if envelope == nil, let folder {
      envelope = PrivateFiles.readJSON(
        Envelope.self, from: folder.appendingPathComponent(name + ".json"), maximumBytes: 16 * 1024 * 1024)
      if let envelope { memory[name] = envelope }
    }
    guard let envelope else { return nil }
    if !stale, envelope.expires <= now() { return nil }
    return (envelope.body, envelope.fetchedAt)
  }

  func store(_ body: Data, for key: String, keepFor seconds: TimeInterval, fetchedAt: Date? = nil) {
    pruneOnce()
    let name = Self.name(key)
    let envelope = Envelope(expires: now().addingTimeInterval(seconds), body: body, fetchedAt: fetchedAt ?? now())
    memory[name] = envelope
    if let folder { try? PrivateFiles.writeJSON(envelope, to: folder.appendingPathComponent(name + ".json")) }
  }

  /// How long an expired answer is still kept (a stale deadline table is
  /// used when a new one cannot be had).
  static let staleGrace: TimeInterval = 30 * 86_400
  private var pruned = false

  /// Once per run, before the first new answer is stored: removes answers
  /// that expired more than `staleGrace` ago and temporary files a crash
  /// left behind, so the folder does not grow without end.
  private func pruneOnce() {
    guard !pruned else { return }
    pruned = true
    prune()
  }

  func prune() {
    let current = now()
    memory = memory.filter { $0.value.expires > current.addingTimeInterval(-Self.staleGrace) }
    guard let folder,
      let names = try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [])
    else { return }
    for url in names {
      let name = url.lastPathComponent
      if name.hasPrefix("."), name.hasSuffix(".tmp") {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, current.timeIntervalSince(modified) > 86_400 { try? FileManager.default.removeItem(at: url) }
        continue
      }
      guard name.hasSuffix(".json") else { continue }
      let envelope = PrivateFiles.readJSON(Envelope.self, from: url, maximumBytes: 16 * 1024 * 1024)
      if envelope.map({ current.timeIntervalSince($0.expires) > Self.staleGrace }) ?? true {
        try? FileManager.default.removeItem(at: url)
      }
    }
  }
}
