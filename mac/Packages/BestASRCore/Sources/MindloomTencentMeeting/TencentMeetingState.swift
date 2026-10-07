import Foundation

/// Everything the Tencent Meeting entry remembers, in the library's private
/// `entries` folder (0600, never sent, not in a full backup): the login's
/// times, each recording's fetch job, the speakers it has met and the day's
/// request count. Recording and user numbers and meeting titles only; never
/// a transcript.
///
/// Read leniently: a field, a job or a speaker this version cannot read
/// falls back to its default or is kept as unrecognized, so one entry
/// written by another version never loses the others (and with them what
/// the owner deleted).
public struct TencentMeetingState: Codable, Equatable, Sendable {
  // MARK: Login

  /// When this Mac connected through Mindloom.
  public var connectedAt: Date?
  /// The account's display name (`auth status`), to tell which speaker is
  /// the owner. On this Mac only.
  public var accountName: String?
  public var accessTokenExpires: Date?
  public var refreshTokenExpires: Date?
  public var lastStatusCheck: Date?
  /// Observed after a refresh: whether it moved the login's end (nil until
  /// seen).
  public var refreshExtendsLogin: Bool?

  // MARK: The first question

  public enum Backfill: Codable, Equatable, Sendable {
    /// Not answered yet: recordings from before `connectedAt` wait.
    case notAsked
    /// Add the earlier recordings too.
    case add
    /// Leave out recordings that ended before this time.
    case skip(before: Date)
  }

  public var backfill: Backfill = .notAsked

  // MARK: Passes

  /// The last full pass whose listings all succeeded.
  public var lastFullPass: Date?
  public var lastPass: Date?
  public var lastSuccess: Date?
  /// The last pass's failure, cleared by the next success.
  public var lastFailure: TencentMeetingFailure?
  /// Tencent's call limit was reached; nothing runs before this time.
  public var pausedUntil: Date?

  // MARK: Budget

  /// The local day (`yyyy-MM-dd`) `requestsToday` and `addedToday` count.
  public var day: String?
  /// Requests to Tencent today (`TencentMeetingCommand.requests`).
  public var requestsToday = 0
  public var addedToday = 0

  // MARK: Recordings and people

  /// Every recording seen, by record file number.
  public var recordings: [String: TencentMeetingRecordingJob] = [:]
  /// Meetings whose recordings `list-ended` did not all list, by meeting
  /// number: Tencent's count, how many were listed, and when `meeting get`
  /// last listed them in full.
  public var recordCounts: [String: TencentMeetingMeetingRecords] = [:]
  /// Every speaker seen, by Tencent Meeting user number.
  public var people: [String: TencentMeetingSpeaker] = [:]
  /// The account's own user numbers (its paragraphs are the owner's).
  public var ownerUserIDs: [String] = []
  /// What `ownerUserIDs` was taken from.
  public var ownerEvidence: OwnerEvidence?

  public enum OwnerEvidence: String, Codable, Equatable, Sendable {
    /// Host of the account's own recordings and speaking under its name.
    case hostAndName = "host_and_name"
    /// Host of most of the account's own recordings, not heard yet.
    case host
    /// The only number speaking under the account's name.
    case name
  }

  public init() {}

  public static let empty = TencentMeetingState()

  /// Starts a new day's counts.
  mutating func roll(to day: String) {
    guard self.day != day else { return }
    self.day = day
    requestsToday = 0
    addedToday = 0
  }

  // Unknown or missing fields fall back to their defaults.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    connectedAt = try? container.decodeIfPresent(Date.self, forKey: .connectedAt)
    accountName = try? container.decodeIfPresent(String.self, forKey: .accountName)
    accessTokenExpires = try? container.decodeIfPresent(Date.self, forKey: .accessTokenExpires)
    refreshTokenExpires = try? container.decodeIfPresent(Date.self, forKey: .refreshTokenExpires)
    lastStatusCheck = try? container.decodeIfPresent(Date.self, forKey: .lastStatusCheck)
    refreshExtendsLogin = try? container.decodeIfPresent(Bool.self, forKey: .refreshExtendsLogin)
    backfill = (try? container.decodeIfPresent(Backfill.self, forKey: .backfill)) ?? .notAsked
    lastFullPass = try? container.decodeIfPresent(Date.self, forKey: .lastFullPass)
    lastPass = try? container.decodeIfPresent(Date.self, forKey: .lastPass)
    lastSuccess = try? container.decodeIfPresent(Date.self, forKey: .lastSuccess)
    lastFailure = (try? container.decodeIfPresent(String.self, forKey: .lastFailure))
      .flatMap(TencentMeetingFailure.init(rawValue:))
    pausedUntil = try? container.decodeIfPresent(Date.self, forKey: .pausedUntil)
    day = try? container.decodeIfPresent(String.self, forKey: .day)
    requestsToday = (try? container.decodeIfPresent(Int.self, forKey: .requestsToday)) ?? 0
    addedToday = (try? container.decodeIfPresent(Int.self, forKey: .addedToday)) ?? 0
    recordings = Self.lenient(container, .recordings)
    recordCounts = Self.lenient(container, .recordCounts)
    people = Self.lenient(container, .people)
    ownerUserIDs = (try? container.decodeIfPresent([String].self, forKey: .ownerUserIDs)) ?? []
    ownerEvidence = (try? container.decodeIfPresent(String.self, forKey: .ownerEvidence))
      .flatMap(OwnerEvidence.init(rawValue:))
  }

  /// A dictionary read entry by entry: one that cannot be read is left out
  /// alone.
  private static func lenient<Value: Decodable>(
    _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
  ) -> [String: Value] {
    let entries =
      (try? container.decodeIfPresent([String: LenientEntry<Value>].self, forKey: key)) ?? nil
    return (entries ?? [:]).compactMapValues(\.value)
  }

  enum CodingKeys: String, CodingKey {
    case connectedAt = "connected_at"
    case accountName = "account_name"
    case accessTokenExpires = "access_token_expires"
    case refreshTokenExpires = "refresh_token_expires"
    case lastStatusCheck = "last_status_check"
    case refreshExtendsLogin = "refresh_extends_login"
    case backfill
    case lastFullPass = "last_full_pass"
    case lastPass = "last_pass"
    case lastSuccess = "last_success"
    case lastFailure = "last_failure"
    case pausedUntil = "paused_until"
    case day
    case requestsToday = "requests_today"
    case addedToday = "added_today"
    case recordings
    case recordCounts = "record_counts"
    case people
    case ownerUserIDs = "owner_user_ids"
    case ownerEvidence = "owner_evidence"
  }
}

/// One value of a dictionary, nil when it cannot be read.
private struct LenientEntry<Value: Decodable>: Decodable {
  let value: Value?

  init(from decoder: Decoder) throws {
    value = try? Value(from: decoder)
  }
}

/// A meeting `list-ended` listed only some recordings of (ARCH v3 §6): what
/// Tencent counts, what was listed, and when `meeting get` listed it in
/// full (nil until it has).
public struct TencentMeetingMeetingRecords: Codable, Equatable, Sendable {
  public var start: Date?
  public var total: Int
  public var listed: Int
  public var fullyListedAt: Date?

  /// Tencent counts more recordings than any listing gave (after `meeting
  /// get`, those Tencent keeps back).
  public var isIncomplete: Bool { total > listed }
}

/// One recording's durable fetch job: input (meeting and record file
/// numbers, the listing fingerprints), state, retries, error category and
/// the tmeet version that fetched it. Idempotent: the item number comes
/// from the record file number, so a run cut short is finished by the next.
public struct TencentMeetingRecordingJob: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Equatable, Sendable {
    /// Recording or transcoding at Tencent.
    case waiting
    /// To fetch (new, changed, or retrying after `nextAttempt`).
    case pending
    /// Added to the library (`itemIDs`).
    case imported
    /// Viewable, but the recording has no transcript text (30002).
    case noContent = "no_content"
    /// Another transcript of the same meeting already covers it.
    case covered
    /// The account must ask the owner (`can_apply`) or needs a password.
    case needsPermission = "needs_permission"
    /// Closed or deleted at Tencent.
    case unavailable
    /// Left out by the owner's answer to the first question.
    case skipped
    /// Tried `maximumAttempts` times without success; tried again once a
    /// day while it is in the window, and at once when it changes.
    case failed
    /// Written by another version of Mindloom with a status this one does
    /// not know: left as it is (never fetched, never listed).
    case unrecognized
  }

  public static let maximumAttempts = 6

  public var meetingID: String
  public var subMeetingID: String?
  public var type: TencentMeetingRecordType
  public var title: String
  public var start: Date?
  public var end: Date?
  public var permission: TencentMeetingPermission
  public var pageURL: String?
  /// The meeting's host (user number), from `record list` only.
  public var hostUserID: String?
  public var fingerprints: [String: String] = [:]
  public var status: Status
  /// The status as written, when this version does not know it.
  public var unrecognizedStatus: String?
  /// Items made from this recording, oldest first (a new one only when
  /// Tencent's transcript changed and the earlier item still exists).
  public var itemIDs: [String] = []
  public var contentDigest: String?
  public var paragraphs: Int?
  public var coveredBy: String?
  public var attempts = 0
  /// Network failures and server errors in a row while fetching it; they
  /// count as one attempt every `transientFailuresPerAttempt`.
  public var transientFailures = 0
  public var nextAttempt: Date?
  public var lastError: TencentMeetingFailure?
  public var lastErrorCode: Int?
  public var fetchedAt: Date?
  public var tmeetVersion: String?

  public init(
    meetingID: String, subMeetingID: String? = nil, type: TencentMeetingRecordType, title: String,
    start: Date? = nil, end: Date? = nil, permission: TencentMeetingPermission,
    pageURL: String? = nil, status: Status
  ) {
    self.meetingID = meetingID
    self.subMeetingID = subMeetingID
    self.type = type
    self.title = title
    self.start = start
    self.end = end
    self.permission = permission
    self.pageURL = pageURL
    self.status = status
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
      (try? container.decodeIfPresent(type, forKey: key)) ?? nil
    }
    meetingID = value(String.self, .meetingID) ?? ""
    subMeetingID = value(String.self, .subMeetingID)
    type = value(String.self, .type).flatMap(TencentMeetingRecordType.init(rawValue:)) ?? .other
    title = value(String.self, .title) ?? "腾讯会议"
    start = value(Date.self, .start)
    end = value(Date.self, .end)
    permission =
      value(String.self, .permission).flatMap(TencentMeetingPermission.init(rawValue:)) ?? .unknown
    pageURL = value(String.self, .pageURL)
    hostUserID = value(String.self, .hostUserID)
    fingerprints = value([String: String].self, .fingerprints) ?? [:]
    let rawStatus = value(String.self, .status)
    if let rawStatus, let known = Status(rawValue: rawStatus), known != .unrecognized {
      status = known
    } else {
      status = .unrecognized
      unrecognizedStatus = rawStatus ?? value(String.self, .unrecognizedStatus)
    }
    itemIDs = value([String].self, .itemIDs) ?? []
    contentDigest = value(String.self, .contentDigest)
    paragraphs = value(Int.self, .paragraphs)
    coveredBy = value(String.self, .coveredBy)
    attempts = value(Int.self, .attempts) ?? 0
    transientFailures = value(Int.self, .transientFailures) ?? 0
    nextAttempt = value(Date.self, .nextAttempt)
    lastError = value(String.self, .lastError).flatMap(TencentMeetingFailure.init(rawValue:))
    lastErrorCode = value(Int.self, .lastErrorCode)
    fetchedAt = value(Date.self, .fetchedAt)
    tmeetVersion = value(String.self, .tmeetVersion)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(meetingID, forKey: .meetingID)
    try container.encodeIfPresent(subMeetingID, forKey: .subMeetingID)
    try container.encode(type, forKey: .type)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(start, forKey: .start)
    try container.encodeIfPresent(end, forKey: .end)
    try container.encode(permission, forKey: .permission)
    try container.encodeIfPresent(pageURL, forKey: .pageURL)
    try container.encodeIfPresent(hostUserID, forKey: .hostUserID)
    try container.encode(fingerprints, forKey: .fingerprints)
    // An unrecognized status is written back as it was read.
    try container.encode(
      status == .unrecognized ? (unrecognizedStatus ?? status.rawValue) : status.rawValue,
      forKey: .status)
    try container.encode(itemIDs, forKey: .itemIDs)
    try container.encodeIfPresent(contentDigest, forKey: .contentDigest)
    try container.encodeIfPresent(paragraphs, forKey: .paragraphs)
    try container.encodeIfPresent(coveredBy, forKey: .coveredBy)
    try container.encode(attempts, forKey: .attempts)
    try container.encode(transientFailures, forKey: .transientFailures)
    try container.encodeIfPresent(nextAttempt, forKey: .nextAttempt)
    try container.encodeIfPresent(lastError, forKey: .lastError)
    try container.encodeIfPresent(lastErrorCode, forKey: .lastErrorCode)
    try container.encodeIfPresent(fetchedAt, forKey: .fetchedAt)
    try container.encodeIfPresent(tmeetVersion, forKey: .tmeetVersion)
  }

  enum CodingKeys: String, CodingKey {
    case meetingID = "meeting_id"
    case subMeetingID = "sub_meeting_id"
    case type, title, start, end, permission
    case pageURL = "page_url"
    case hostUserID = "host_user_id"
    case fingerprints, status
    case unrecognizedStatus = "unrecognized_status"
    case itemIDs = "item_ids"
    case contentDigest = "content_digest"
    case paragraphs
    case coveredBy = "covered_by"
    case attempts
    case transientFailures = "transient_failures"
    case nextAttempt = "next_attempt"
    case lastError = "last_error"
    case lastErrorCode = "last_error_code"
    case fetchedAt = "fetched_at"
    case tmeetVersion = "tmeet_version"
  }
}

/// A speaker met in fetched transcripts, by Tencent Meeting user number:
/// every name it used (newest first), how many recordings it spoke in, and
/// the one name it is written under in every transcript this Mac adds
/// (`label`). The person pipeline reads the transcripts' speaker names, so
/// one user number is one person across meetings; the account's own number
/// is written 「我」, the owner.
public struct TencentMeetingSpeaker: Codable, Equatable, Sendable {
  public var names: [String]
  public var firstSeen: Date
  public var lastSeen: Date
  public var recordings: Int
  /// Chosen the first time the number speaks and kept when the person later
  /// changes their display name; no two numbers share one. Nil for a number
  /// with no usable name (its turns are 「发言人 N」 in each transcript).
  public var label: String?

  public var name: String? { names.first }

  public init(
    names: [String], firstSeen: Date, lastSeen: Date, recordings: Int, label: String? = nil
  ) {
    self.names = names
    self.firstSeen = firstSeen
    self.lastSeen = lastSeen
    self.recordings = recordings
    self.label = label
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    names = ((try? container.decodeIfPresent([String].self, forKey: .names)) ?? nil) ?? []
    firstSeen =
      ((try? container.decodeIfPresent(Date.self, forKey: .firstSeen)) ?? nil) ?? .distantPast
    lastSeen = ((try? container.decodeIfPresent(Date.self, forKey: .lastSeen)) ?? nil) ?? firstSeen
    recordings = ((try? container.decodeIfPresent(Int.self, forKey: .recordings)) ?? nil) ?? 0
    label = (try? container.decodeIfPresent(String.self, forKey: .label)) ?? nil
  }

  enum CodingKeys: String, CodingKey {
    case names
    case firstSeen = "first_seen"
    case lastSeen = "last_seen"
    case recordings
    case label
  }
}
