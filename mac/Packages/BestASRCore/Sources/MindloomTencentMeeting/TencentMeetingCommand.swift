import Foundation

/// The only tmeet commands Mindloom runs (PRD ENTRY-013). Everything here
/// reads; `authLogin` makes this Mac's own login. (Switching the entry off
/// removes tmeet's folder and the key; tmeet's `auth logout` would only
/// delete the same local files, so it is not run.)
/// tmeet can also create, change and cancel meetings, remove participants
/// and upload logs; none of those can be expressed by this type, and a test
/// checks every case's arguments against the list below.
///
/// Arguments take only identifiers in their own formats (digits for meeting,
/// recording and paragraph numbers; a page token of URL-safe characters);
/// anything else makes `arguments` nil and the command is not run.
public enum TencentMeetingCommand: Equatable, Sendable {
  /// `auth login --no-browser`: prints the authorization address, then waits
  /// (up to tmeet's own five minutes) for the owner to allow it.
  case authLogin
  /// `auth status`: whether the login holds and how long (one request).
  case authStatus
  /// `record list`: recordings this account may view in a time window.
  case recordList(start: Date, end: Date, pageToken: String?)
  /// `meeting list-ended`: meetings this account created or joined, with
  /// up to five recordings each and their permission (`can_view`,
  /// `can_apply`, …).
  case meetingListEnded(start: Date, end: Date, pageToken: String?)
  /// `meeting get`: one meeting with all its recordings (up to 200), for a
  /// meeting `list-ended` listed only some of.
  case meetingGet(meetingID: String)
  /// `record transcript-get`: one page of a recording's transcript.
  case transcriptGet(recordFileID: String, meetingID: String?, pid: String?, limit: Int)

  /// The subcommand paths Mindloom may run; nothing else.
  public static let allowedPaths: Set<[String]> = [
    ["auth", "login"], ["auth", "status"], ["record", "list"],
    ["meeting", "list-ended"], ["meeting", "get"], ["record", "transcript-get"],
  ]

  /// Paragraphs per transcript page (tmeet passes it to Tencent as is).
  public static let transcriptPageSize = 100
  /// Meetings or recordings per listing page (tmeet's maximum).
  public static let listPageSize = 30

  public var path: [String] {
    switch self {
    case .authLogin: ["auth", "login"]
    case .authStatus: ["auth", "status"]
    case .recordList: ["record", "list"]
    case .meetingListEnded: ["meeting", "list-ended"]
    case .meetingGet: ["meeting", "get"]
    case .transcriptGet: ["record", "transcript-get"]
    }
  }

  /// Whether the command is a listing (the login check included), which may
  /// not use the share of the day's budget kept for transcripts.
  public var isListing: Bool {
    switch self {
    case .authStatus, .recordList, .meetingListEnded, .meetingGet: true
    default: false
    }
  }

  /// The requests to Tencent one run makes with the owner's login, counted
  /// against the daily budget (tmeet's source, v1.0.18): `list-ended` asks
  /// for the meetings, their recordings and their summaries; `meeting get`
  /// for the meeting, up to two pages of recordings and its summaries.
  /// `auth login` makes none with the login.
  public var requests: Int {
    switch self {
    case .authLogin: 0
    case .authStatus, .recordList, .transcriptGet: 1
    case .meetingListEnded: 3
    case .meetingGet: 4
    }
  }

  /// The argument vector after the program name, or nil when a value is not
  /// in its format.
  public var arguments: [String]? {
    switch self {
    case .authLogin:
      return ["auth", "login", "--no-browser"]
    case .authStatus:
      return ["auth", "status"]
    case .recordList(let start, let end, let token):
      guard start < end, Self.isPageToken(token) else { return nil }
      var arguments = [
        "record", "list", "--start", Self.time(start), "--end", Self.time(end),
        "--page-size", String(Self.listPageSize), "--format", "json",
      ]
      if let token { arguments += ["--page-token", token] }
      return arguments
    case .meetingListEnded(let start, let end, let token):
      guard start < end, Self.isPageToken(token) else { return nil }
      var arguments = [
        "meeting", "list-ended", "--start", Self.time(start), "--end", Self.time(end),
        "--page-size", String(Self.listPageSize), "--format", "json",
      ]
      if let token { arguments += ["--page-token", token] }
      return arguments
    case .meetingGet(let meetingID):
      guard Self.isNumber(meetingID) else { return nil }
      return ["meeting", "get", "--meeting-id", meetingID, "--format", "json"]
    case .transcriptGet(let recordFileID, let meetingID, let pid, let limit):
      guard Self.isNumber(recordFileID), meetingID.map(Self.isNumber) ?? true,
        pid.map(Self.isNumber) ?? true, (1...500).contains(limit)
      else { return nil }
      var arguments = ["record", "transcript-get", "--record-file-id", recordFileID]
      if let meetingID { arguments += ["--meeting-id", meetingID] }
      if let pid { arguments += ["--pid", pid] }
      arguments += ["--limit", String(limit), "--format", "json"]
      return arguments
    }
  }

  /// Meeting, recording and paragraph numbers: 1–32 ASCII digits.
  public static func isNumber(_ value: String) -> Bool {
    (1...32).contains(value.utf8.count) && value.utf8.allSatisfy { (0x30...0x39).contains($0) }
  }

  /// A listing's `next_page_token`: 1–512 characters of `A–Z a–z 0–9 - _ = + / .`.
  static func isPageToken(_ token: String?) -> Bool {
    guard let token else { return true }
    return (1...512).contains(token.utf8.count)
      && token.utf8.allSatisfy { byte in
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
          || (0x61...0x7A).contains(byte) || [0x2D, 0x5F, 0x3D, 0x2B, 0x2F, 0x2E].contains(byte)
      }
  }

  /// `2026-10-05T14:00:00+08:00` in this Mac's time zone, as tmeet expects.
  static func time(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }
}
