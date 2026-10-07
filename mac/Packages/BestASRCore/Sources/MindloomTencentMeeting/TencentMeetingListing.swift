import Foundation

/// Tencent's two kinds of recording that carry a transcript.
public enum TencentMeetingRecordType: String, Codable, Equatable, Sendable {
  /// 云录制: the cloud recording's transcript.
  case cloudRecording = "cloud_recording"
  /// 文字转写: the meeting's own transcription.
  case textTranscription = "text_transcription"
  case other

  init(label: String?) {
    switch label?.trimmingCharacters(in: .whitespaces) {
    case "云录制": self = .cloudRecording
    case "文字转写": self = .textTranscription
    default: self = .other
    }
  }
}

/// What this account may do with a recording (`permission_status`).
public enum TencentMeetingPermission: String, Codable, Equatable, Sendable {
  case canView = "can_view"
  case canApply = "can_apply"
  case passwordRequired = "password_required"
  case closed
  case deleted
  case unknown

  init(raw: String?) {
    self = raw.flatMap(TencentMeetingPermission.init(rawValue:)) ?? .unknown
  }
}

/// Which listing a recording was seen in.
public enum TencentMeetingListingSource: String, Codable, Hashable, Sendable {
  /// `record list`: the recordings this account made or owns — nearly all
  /// of them in meetings it hosted (with the host's user number), sometimes
  /// one in a meeting someone else hosted. Recordings others share are not
  /// in it.
  case recordList = "record_list"
  /// `meeting list-ended`: the meetings this account created or joined,
  /// with up to five recordings each and their permission; how many a
  /// meeting has in all is `records_total_count`.
  case meetingListEnded = "meeting_list_ended"
  /// `meeting get`: one meeting with all its recordings (up to 200), asked
  /// for when `list-ended` listed only some of them.
  case meetingGet = "meeting_get"
}

/// One recording file as the listings describe it (no transcript text).
public struct TencentMeetingRecording: Equatable, Sendable {
  public var recordFileID: String
  public var meetingID: String
  public var subMeetingID: String?
  public var meetingCode: String?
  public var meetingRecordID: String?
  public var type: TencentMeetingRecordType
  /// Ready to read: Tencent finished it (「转码完成…」).
  public var isReady: Bool
  public var permission: TencentMeetingPermission
  public var meetingSubject: String?
  public var recordSubject: String?
  /// When the recording started and ended.
  public var start: Date?
  public var end: Date?
  public var scheduledStart: Date?
  public var scheduledEnd: Date?
  public var recurring: Bool?
  public var hostUserID: String?
  /// The recording's page on meeting.tencent.com, where the owner can ask
  /// for access.
  public var pageURL: URL?
  /// Per listing: the fields that change when Tencent changes the recording
  /// (state, length, size), never the permission.
  public var fingerprints: [TencentMeetingListingSource: String]
  /// The listing objects as tmeet printed them (sorted-key JSON), kept with
  /// the item as part of its source.
  public var listings: [TencentMeetingListingSource: Data]

  /// Viewable and finished.
  public var isFetchable: Bool { isReady && permission == .canView }

  public var duration: TimeInterval? {
    guard let start, let end, end > start else { return nil }
    return end.timeIntervalSince(start)
  }

  /// The title shown and written as the transcript's first line.
  public var title: String {
    for candidate in [meetingSubject, recordSubject] {
      if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
        return value
      }
    }
    return "腾讯会议"
  }

  /// Merges what another listing said about the same file.
  mutating func merge(_ other: TencentMeetingRecording) {
    subMeetingID = subMeetingID ?? other.subMeetingID
    meetingCode = meetingCode ?? other.meetingCode
    meetingRecordID = meetingRecordID ?? other.meetingRecordID
    if type == .other { type = other.type }
    isReady = isReady || other.isReady
    // A listing that says the account may view it wins; otherwise the
    // first permission known.
    if permission == .unknown || other.permission == .canView { permission = other.permission }
    meetingSubject = meetingSubject ?? other.meetingSubject
    recordSubject = recordSubject ?? other.recordSubject
    start = start ?? other.start
    end = end ?? other.end
    scheduledStart = scheduledStart ?? other.scheduledStart
    scheduledEnd = scheduledEnd ?? other.scheduledEnd
    recurring = recurring ?? other.recurring
    hostUserID = hostUserID ?? other.hostUserID
    pageURL = pageURL ?? other.pageURL
    fingerprints.merge(other.fingerprints) { _, new in new }
    listings.merge(other.listings) { _, new in new }
  }
}

/// How many recordings Tencent counts for one meeting and how many a
/// listing gave (meeting listings only).
public struct TencentMeetingRecordCount: Equatable, Sendable {
  public var meetingID: String
  public var subMeetingID: String?
  /// The meeting's scheduled start.
  public var start: Date?
  public var total: Int
  public var listed: Int

  /// The listing left some of the meeting's recordings out.
  public var isTruncated: Bool { total > listed }
}

/// One page of a listing.
public struct TencentMeetingListingPage: Equatable, Sendable {
  public var recordings: [TencentMeetingRecording]
  public var nextPageToken: String?
  /// Per meeting in a meeting listing: Tencent's count and what was listed.
  public var counts: [TencentMeetingRecordCount] = []

  /// Meetings whose recordings the page did not all include.
  public var truncatedMeetings: Int { counts.filter(\.isTruncated).count }
}

/// Reads `record list` and `meeting list-ended` (the `data` object tmeet
/// printed). Unknown or missing fields are skipped; a recording without a
/// file number or meeting number is dropped.
public enum TencentMeetingListingParser {
  public static func recordList(_ data: [String: Any]) -> TencentMeetingListingPage {
    var recordings: [TencentMeetingRecording] = []
    for case let meeting as [String: Any] in (data["record_meetings"] as? [Any]) ?? [] {
      guard let meetingID = number(meeting["meeting_id"]) else { continue }
      let stateText = string(meeting["state"])
      for case let file as [String: Any] in (meeting["record_files"] as? [Any]) ?? [] {
        guard let recordFileID = number(file["record_file_id"]) else { continue }
        let start = date(file["record_start_time"]) ?? date(meeting["media_start_time"])
        let end = date(file["record_end_time"])
        var listing = meeting
        listing["record_files"] = [file]
        let fingerprint = [
          stateText ?? "", string(file["record_end_time"]) ?? "",
          string(file["record_size"]) ?? "",
        ].joined(separator: "|")
        recordings.append(
          TencentMeetingRecording(
            recordFileID: recordFileID, meetingID: meetingID,
            subMeetingID: number(meeting["sub_meeting_id"]),
            meetingCode: number(meeting["meeting_code"]),
            meetingRecordID: number(meeting["meeting_record_id"]),
            type: TencentMeetingRecordType(label: string(meeting["record_type"])),
            isReady: isReady(stateText), permission: .canView, meetingSubject: nil,
            recordSubject: string(meeting["subject"]), start: start, end: end,
            scheduledStart: nil, scheduledEnd: nil, recurring: nil,
            hostUserID: number(meeting["host_user_id"]), pageURL: nil,
            fingerprints: [.recordList: fingerprint],
            listings: [.recordList: json(listing)]))
      }
    }
    return TencentMeetingListingPage(recordings: recordings, nextPageToken: nextToken(data))
  }

  public static func meetingListEnded(_ data: [String: Any]) -> TencentMeetingListingPage {
    meetings(data, source: .meetingListEnded)
  }

  /// `meeting get`: the same meeting object with every recording.
  public static func meetingGet(_ data: [String: Any]) -> TencentMeetingListingPage {
    var page = meetings(data, source: .meetingGet)
    page.nextPageToken = nil
    return page
  }

  /// A `meeting_info_list` with each meeting's `records` (both meeting
  /// listings print recordings the same way).
  static func meetings(_ data: [String: Any], source: TencentMeetingListingSource)
    -> TencentMeetingListingPage
  {
    var recordings: [TencentMeetingRecording] = []
    var counts: [TencentMeetingRecordCount] = []
    for case let meeting as [String: Any] in (data["meeting_info_list"] as? [Any]) ?? [] {
      guard let meetingID = number(meeting["meeting_id"]) else { continue }
      let records = (meeting["records"] as? [Any]) ?? []
      let subMeetingID = number(meeting["sub_meeting_id"])
      counts.append(
        TencentMeetingRecordCount(
          meetingID: meetingID, subMeetingID: subMeetingID, start: date(meeting["start_time"]),
          total: max(integer(meeting["records_total_count"]) ?? records.count, records.count),
          listed: records.count))
      var meetingOnly = meeting
      meetingOnly["records"] = nil
      meetingOnly["minutes"] = nil
      for case let record as [String: Any] in records {
        guard let recordFileID = number(record["record_file_id"]) else { continue }
        let stateText = string(record["state"])
        let start = date(record["media_start_time"])
        let end = start.flatMap { start in
          seconds(string(record["duration"])).map { start.addingTimeInterval($0) }
        }
        var listing = meetingOnly
        listing["records"] = [record]
        let fingerprint = [
          stateText ?? "", string(record["duration"]) ?? "",
          string(record["record_file_count"]) ?? "",
        ].joined(separator: "|")
        recordings.append(
          TencentMeetingRecording(
            recordFileID: recordFileID, meetingID: meetingID, subMeetingID: subMeetingID,
            meetingCode: number(meeting["meeting_code"]),
            meetingRecordID: number(record["meeting_record_id"]),
            type: TencentMeetingRecordType(label: string(record["type"])),
            isReady: isReady(stateText),
            permission: TencentMeetingPermission(raw: string(record["permission_status"])),
            meetingSubject: string(meeting["subject"]), recordSubject: string(record["subject"]),
            start: start, end: end, scheduledStart: date(meeting["start_time"]),
            scheduledEnd: date(meeting["end_time"]),
            recurring: string(meeting["meeting_type"]).map { $0 == "周期性会议" },
            hostUserID: nil, pageURL: pageURL(string(record["url"])),
            fingerprints: [source: fingerprint],
            listings: [source: json(listing)]))
      }
    }
    return TencentMeetingListingPage(
      recordings: recordings, nextPageToken: nextToken(data), counts: counts)
  }

  // MARK: Fields

  /// 「转码完成，可根据录制文件权限进行下一步」 and nothing earlier (录制中、转码中).
  static func isReady(_ state: String?) -> Bool {
    state?.hasPrefix("转码完成") ?? false
  }

  static func nextToken(_ data: [String: Any]) -> String? {
    guard (data["has_more"] as? Bool) == true, let token = string(data["next_page_token"]),
      !token.isEmpty, TencentMeetingCommand.isPageToken(token)
    else { return nil }
    return token
  }

  static func string(_ value: Any?) -> String? {
    switch value {
    case let text as String: text
    case let number as NSNumber: number.stringValue
    default: nil
    }
  }

  static func integer(_ value: Any?) -> Int? {
    switch value {
    case let number as NSNumber: number.intValue
    case let text as String: Int(text)
    default: nil
    }
  }

  /// A Tencent number (meeting, recording, user): digits only.
  static func number(_ value: Any?) -> String? {
    guard let text = string(value)?.trimmingCharacters(in: .whitespaces),
      TencentMeetingCommand.isNumber(text)
    else { return nil }
    return text
  }

  /// tmeet prints times as RFC 3339 in this Mac's time zone.
  static func date(_ value: Any?) -> Date? {
    guard let text = string(value), !text.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
  }

  /// "MM:SS" or "HH:MM:SS" (tmeet's form for lengths and offsets).
  static func seconds(_ text: String?) -> TimeInterval? {
    guard let text, !text.isEmpty else { return nil }
    let parts = text.split(separator: ":").map { Int($0) }
    guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else {
      return nil
    }
    return TimeInterval(parts.reduce(0) { $0 * 60 + $1! })
  }

  /// The recording's page, accepted only on meeting.tencent.com over https.
  static func pageURL(_ text: String?) -> URL? {
    guard let text, let components = URLComponents(string: text), components.scheme == "https",
      components.host == "meeting.tencent.com", components.user == nil, components.port == nil
    else { return nil }
    return components.url
  }

  static func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
      ?? Data("{}".utf8)
  }
}
