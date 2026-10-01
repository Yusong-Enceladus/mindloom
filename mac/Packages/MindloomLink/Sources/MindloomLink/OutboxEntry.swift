import CryptoKit
import Foundation

/// Why a delivery attempt failed, recorded on the entry for the outbox UI and
/// for retry policy. Never contains content.
public enum DeliveryErrorCategory: String, Codable, Sendable, CaseIterable {
  /// No route, connection refused or dropped: retry later.
  case network
  /// The attempt took too long: retry later.
  case timeout
  /// A server presented a host key other than the pinned one. Nothing was
  /// sent; pairing again on the Mac is the fix.
  case hostKeyMismatch
  /// The Spark or relay refused the phone's key (for example after unpairing).
  case authentication
  /// The relay refused to forward to the Spark.
  case relayRefused
  /// The gate refused the command or the entry.
  case rejected
  /// The reply was not the expected `{"ok":true,…}`.
  case protocolError
  /// There is no pairing on this phone yet.
  case notPaired

  /// Whether sending again later can succeed without the user doing anything.
  public var isTransient: Bool {
    switch self {
    case .network, .timeout, .protocolError: true
    case .hostKeyMismatch, .authentication, .relayRefused, .rejected, .notPaired: false
    }
  }
}

/// One item in the phone's durable outbox (PHONE-CONTRACT §5).
///
/// `queued` holds only the sealed wire string, never the plaintext, plus a
/// short text preview (none for images). Once the Spark confirms, the entry
/// becomes `sent`: the wire string is dropped and only the preview stays, for
/// seven days.
public struct OutboxEntry: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable {
    case queued
    case sent
  }

  public static let currentVersion = 1
  /// How long a "已送出" preview is kept after the Spark confirmed it.
  public static let sentRetention: TimeInterval = 7 * 24 * 60 * 60

  public let v: Int
  public let entryID: String
  public let kind: InboxItemKind
  public let source: InboxItemSource
  /// When the item was collected, milliseconds since 1970 (exact in JSON).
  public let createdAtMillis: Int64
  /// Which Mac seal key it was sealed to (`MindloomSeal.keyID`).
  public let sealKeyID: String
  public private(set) var state: State
  public private(set) var wire: String?
  public private(set) var preview: String?
  public private(set) var sentAtMillis: Int64?
  /// The Spark already had this id (a retry after a lost reply).
  public private(set) var duplicate: Bool
  public private(set) var attempts: Int
  public private(set) var lastAttemptAtMillis: Int64?
  public private(set) var lastError: DeliveryErrorCategory?

  enum CodingKeys: String, CodingKey {
    case v, kind, source, state, wire, preview, duplicate, attempts
    case entryID = "entry_id"
    case createdAtMillis = "created_at_ms"
    case sealKeyID = "seal_key_id"
    case sentAtMillis = "sent_at_ms"
    case lastAttemptAtMillis = "last_attempt_at_ms"
    case lastError = "last_error"
  }

  public enum EntryError: Error, Equatable, Sendable {
    case invalidEntryID
    case invalidState
    case unsupportedVersion(Int)
  }

  /// Seals a validated payload into a new queued entry.
  public static func seal(
    _ payload: InboxItemPayload,
    to macSealKey: Curve25519.KeyAgreement.PublicKey,
    entryID: String = EntryID.make(),
    now: Date = Date()
  ) throws -> OutboxEntry {
    let wire = try MindloomSeal.seal(payload.encoded(), entryID: entryID, to: macSealKey)
    return try OutboxEntry(
      entryID: entryID, kind: payload.kind, source: payload.source,
      createdAt: payload.createdDate ?? now, sealKeyID: MindloomSeal.keyID(for: macSealKey),
      wire: wire, preview: payload.preview)
  }

  /// A queued entry around an already sealed wire string.
  public init(
    entryID: String, kind: InboxItemKind, source: InboxItemSource, createdAt: Date,
    sealKeyID: String, wire: String, preview: String?
  ) throws {
    self.v = Self.currentVersion
    self.entryID = entryID
    self.kind = kind
    self.source = source
    self.createdAtMillis = Self.millis(createdAt)
    self.sealKeyID = sealKeyID
    self.state = .queued
    self.wire = wire
    self.preview = kind == .image ? nil : preview
    self.sentAtMillis = nil
    self.duplicate = false
    self.attempts = 0
    self.lastAttemptAtMillis = nil
    self.lastError = nil
    try validate()
  }

  public var createdAt: Date { Self.date(createdAtMillis) }
  public var sentAt: Date? { sentAtMillis.map(Self.date) }
  public var lastAttemptAt: Date? { lastAttemptAtMillis.map(Self.date) }

  // MARK: - Transitions

  /// Records a failed attempt; the entry stays queued.
  public func recordingFailure(_ category: DeliveryErrorCategory, at now: Date) -> OutboxEntry {
    guard state == .queued else { return self }
    var next = self
    next.attempts += 1
    next.lastAttemptAtMillis = Self.millis(now)
    next.lastError = category
    return next
  }

  /// queued → sent: drops the sealed payload, keeps the text preview only.
  /// Idempotent: a sent entry is returned unchanged.
  public func markingSent(at now: Date, duplicate: Bool = false) -> OutboxEntry {
    guard state == .queued else { return self }
    var next = self
    next.state = .sent
    next.wire = nil
    if kind == .image { next.preview = nil }
    next.sentAtMillis = Self.millis(now)
    next.duplicate = duplicate
    next.attempts += 1
    next.lastAttemptAtMillis = Self.millis(now)
    next.lastError = nil
    return next
  }

  /// A sent entry older than `sentRetention` is removed entirely.
  public func isExpired(now: Date) -> Bool {
    guard state == .sent, let sentAt else { return false }
    return now.timeIntervalSince(sentAt) >= Self.sentRetention
  }

  // MARK: - JSON

  public func encoded() throws -> Data {
    try validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  public static func decode(_ data: Data) throws -> OutboxEntry {
    let entry = try JSONDecoder().decode(OutboxEntry.self, from: data)
    try entry.validate()
    return entry
  }

  public func validate() throws {
    guard v == Self.currentVersion else { throw EntryError.unsupportedVersion(v) }
    guard EntryID.isValid(entryID) else { throw EntryError.invalidEntryID }
    switch state {
    case .queued:
      guard let wire, wire.hasPrefix(MindloomSeal.wirePrefix),
        wire.utf8.count <= MindloomSeal.maximumWireBytes, sentAtMillis == nil
      else { throw EntryError.invalidState }
    case .sent:
      guard wire == nil, sentAtMillis != nil else { throw EntryError.invalidState }
    }
    if kind == .image, preview != nil { throw EntryError.invalidState }
  }

  static func millis(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }

  static func date(_ millis: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
  }
}
