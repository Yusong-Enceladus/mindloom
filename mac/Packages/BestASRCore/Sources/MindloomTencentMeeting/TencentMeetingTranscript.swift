import BestASRMemory
import CryptoKit
import Foundation

/// One paragraph of a Tencent Meeting transcript
/// (`data.minutes.paragraphs[]`): its number, its time from the start of the
/// recording, who spoke (`speaker.user_id`, `speaker.user_name`) and the
/// words.
public struct TencentMeetingParagraph: Codable, Equatable, Sendable {
  public let pid: Int
  public let startMilliseconds: Int
  public let endMilliseconds: Int
  /// Tencent Meeting's user number; the same person keeps it across
  /// meetings.
  public let speakerUserID: String?
  public let speakerName: String
  public let text: String

  public init(
    pid: Int, startMilliseconds: Int, endMilliseconds: Int, speakerUserID: String?,
    speakerName: String, text: String
  ) {
    self.pid = pid
    self.startMilliseconds = startMilliseconds
    self.endMilliseconds = endMilliseconds
    self.speakerUserID = speakerUserID
    self.speakerName = speakerName
    self.text = text
  }

  enum CodingKeys: String, CodingKey {
    case pid
    case startMilliseconds = "start_ms"
    case endMilliseconds = "end_ms"
    case speakerUserID = "speaker_user_id"
    case speakerName = "speaker_name"
    case text
  }
}

/// One page of `record transcript-get`.
public struct TencentMeetingTranscriptPage: Equatable, Sendable {
  public let paragraphs: [TencentMeetingParagraph]
  /// Tencent says there are more paragraphs after these.
  public let more: Bool
}

public enum TencentMeetingTranscriptParser {
  /// The page in tmeet's `data` object; nil when it is not a transcript.
  public static func page(_ data: [String: Any]) -> TencentMeetingTranscriptPage? {
    guard let minutes = data["minutes"] as? [String: Any] else {
      // A page with no minutes object and nothing more is an empty end.
      if data["minutes"] == nil, (data["more"] as? Bool) == false {
        return TencentMeetingTranscriptPage(paragraphs: [], more: false)
      }
      return nil
    }
    var paragraphs: [TencentMeetingParagraph] = []
    for case let paragraph as [String: Any] in (minutes["paragraphs"] as? [Any]) ?? [] {
      guard let pid = TencentMeetingListingParser.integer(paragraph["pid"]), pid >= 0 else {
        continue
      }
      let speaker = paragraph["speaker"] as? [String: Any]
      var words = ""
      for case let sentence as [String: Any] in (paragraph["sentences"] as? [Any]) ?? [] {
        if let text = sentence["text"] as? String {
          words += text
          continue
        }
        for case let word as [String: Any] in (sentence["words"] as? [Any]) ?? [] {
          words += (word["text"] as? String) ?? ""
        }
      }
      let text = words.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      paragraphs.append(
        TencentMeetingParagraph(
          pid: pid,
          startMilliseconds: milliseconds(paragraph["start_time"]) ?? 0,
          endMilliseconds: milliseconds(paragraph["end_time"]) ?? 0,
          speakerUserID: TencentMeetingListingParser.number(speaker?["user_id"]),
          speakerName: (TencentMeetingListingParser.string(speaker?["user_name"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines),
          text: text))
    }
    return TencentMeetingTranscriptPage(
      paragraphs: paragraphs, more: (data["more"] as? Bool) ?? false)
  }

  /// tmeet turns Tencent's milliseconds into "MM:SS" / "HH:MM:SS"; a bare
  /// number is read as milliseconds.
  static func milliseconds(_ value: Any?) -> Int? {
    guard let text = TencentMeetingListingParser.string(value), !text.isEmpty else { return nil }
    if text.contains(":") {
      return TencentMeetingListingParser.seconds(text).map { Int($0) * 1_000 }
    }
    return Int(text)
  }

  /// The pages' paragraphs in order, each number once (a page may repeat
  /// the last paragraph of the one before).
  public static func merged(_ pages: [TencentMeetingTranscriptPage]) -> [TencentMeetingParagraph] {
    var byPID: [Int: TencentMeetingParagraph] = [:]
    for page in pages {
      for paragraph in page.paragraphs where byPID[paragraph.pid] == nil {
        byPID[paragraph.pid] = paragraph
      }
    }
    return byPID.keys.sorted().compactMap { byPID[$0] }
  }

  /// What changes when the transcript changes: every paragraph's number,
  /// times, speaker and words (not tmeet's trace number).
  public static func digest(_ paragraphs: [TencentMeetingParagraph]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(paragraphs)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// The speakers met in fetched transcripts, by Tencent Meeting user number
/// (`TencentMeetingState.people`), and the one name each number is written
/// under in every transcript this Mac adds. The person pipeline reads the
/// transcripts' speaker names, so one number stays one person across
/// meetings, even after a display name changes, and two people with the
/// same display name stay two.
public enum TencentMeetingSpeakers {
  /// Records one transcript's speakers seen at `date` (the recording's
  /// start): each number's names (newest first), first and last time,
  /// recordings; then gives every number without a name to be written under
  /// one — this transcript's in the order they first speak, then any older
  /// ones by when they were first seen.
  public static func learn(
    _ paragraphs: [TencentMeetingParagraph], at date: Date,
    people: inout [String: TencentMeetingSpeaker]
  ) {
    var names: [String: String] = [:]
    var order: [String] = []
    for paragraph in paragraphs {
      guard let id = paragraph.speakerUserID, !paragraph.speakerName.isEmpty else { continue }
      if names[id] == nil {
        names[id] = paragraph.speakerName
        order.append(id)
      }
    }
    for (id, name) in names {
      var speaker =
        people[id]
        ?? TencentMeetingSpeaker(names: [], firstSeen: date, lastSeen: date, recordings: 0)
      if date >= speaker.lastSeen {
        speaker.names.removeAll { $0 == name }
        speaker.names.insert(name, at: 0)
        speaker.lastSeen = date
      } else if !speaker.names.contains(name) {
        speaker.names.append(name)
      }
      speaker.firstSeen = min(speaker.firstSeen, date)
      speaker.recordings += 1
      people[id] = speaker
    }
    let earlier = people.filter { $0.value.label == nil && names[$0.key] == nil }
      .sorted { ($0.value.firstSeen, $0.key) < ($1.value.firstSeen, $1.key) }.map(\.key)
    var taken = Set(people.values.compactMap(\.label))
    for id in order + earlier {
      guard let speaker = people[id], speaker.label == nil else { continue }
      // The earliest name it used (a new number has only this one).
      let name = speaker.names.last ?? names[id] ?? ""
      guard let label = TencentMeetingTranscriptText.label(for: name, taken: taken) else {
        continue
      }
      people[id]?.label = label
      taken.insert(label)
    }
  }

  /// User number → the name it is written under.
  public static func labels(_ people: [String: TencentMeetingSpeaker]) -> [String: String] {
    people.compactMapValues(\.label)
  }
}

/// The item's text: the meeting's title, then each turn as Tencent
/// Meeting's own export writes it, `名字(时:分:秒):` with the words on the
/// following lines — the format `MemoryTranscriptText` reads on this Mac and
/// on the organizing device. Consecutive paragraphs of one speaker are one
/// turn (one paragraph per line). The account's own paragraphs are written
/// as 「我」, the owner's name everywhere in Mindloom; every other user
/// number under its label (`TencentMeetingSpeakers`), the same in every
/// meeting.
public enum TencentMeetingTranscriptText {
  public static let ownerName = "我"

  public static func readable(
    title: String, paragraphs: [TencentMeetingParagraph], ownerUserIDs: Set<String>,
    labels: [String: String] = [:]
  ) -> String {
    let names = speakerNames(paragraphs, ownerUserIDs: ownerUserIDs, labels: labels)
    var lines: [String] = [titleLine(title)]
    var current: String?
    for paragraph in paragraphs where !paragraph.text.isEmpty {
      let name = names[key(paragraph)] ?? "发言人"
      if name != current {
        lines.append("")
        lines.append("\(name)(\(clock(paragraph.startMilliseconds))):")
        current = name
      }
      lines.append(contentsOf: paragraph.text.split(whereSeparator: \.isNewline).map(String.init))
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// A speaker key: the user number, or the name when Tencent gave none.
  static func key(_ paragraph: TencentMeetingParagraph) -> String {
    paragraph.speakerUserID.map { "id:" + $0 } ?? "name:" + paragraph.speakerName
  }

  /// One name per speaker in this meeting: the owner is 「我」, a labelled
  /// user number its label; the others in the order they first speak, a
  /// name another speaker here already has getting “ 2”, “ 3”. Every name is
  /// one the transcript reader takes as a name.
  public static func speakerNames(
    _ paragraphs: [TencentMeetingParagraph], ownerUserIDs: Set<String>,
    labels: [String: String] = [:]
  ) -> [String: String] {
    var names: [String: String] = [:]
    var taken: Set<String> = []
    for paragraph in paragraphs where !paragraph.text.isEmpty {
      guard let id = paragraph.speakerUserID else { continue }
      if ownerUserIDs.contains(id) {
        names[key(paragraph)] = ownerName
        taken.insert(ownerName)
      } else if let label = labels[id], !label.isEmpty, label != ownerName {
        names[key(paragraph)] = label
        taken.insert(label)
      }
    }
    var unnamed = 0
    for paragraph in paragraphs where !paragraph.text.isEmpty {
      let key = key(paragraph)
      guard names[key] == nil else { continue }
      var base = cleanName(paragraph.speakerName)
      if base.isEmpty || base == ownerName {
        unnamed += 1
        base = "发言人 \(unnamed)"
      }
      var name = base
      var suffix = 2
      while taken.contains(name) {
        name = "\(base) \(suffix)"
        suffix += 1
      }
      names[key] = name
      taken.insert(name)
    }
    return names
  }

  /// A Tencent display name as a turn name: no sentence punctuation or
  /// brackets (they end a name in the export format), not starting with a
  /// digit, at most eight CJK ideographs and 32 characters.
  static func cleanName(_ name: String) -> String {
    let notInName = CharacterSet(charactersIn: "。，,、！!？?；;：:“”\"「」【】[]()（）<>《》")
    var scalars = String.UnicodeScalarView()
    for scalar in name.unicodeScalars {
      if notInName.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
        || CharacterSet.newlines.contains(scalar)
      {
        scalars.append(" ")
      } else {
        scalars.append(scalar)
      }
    }
    var cleaned = String(scalars).split(whereSeparator: { $0 == " " || $0 == "\t" })
      .joined(separator: " ")
    var ideographs = 0
    var kept = String.UnicodeScalarView()
    for scalar in cleaned.unicodeScalars {
      if (0x4E00...0x9FFF).contains(scalar.value) {
        ideographs += 1
        if ideographs > 8 { break }
      }
      if kept.count >= 32 { break }
      kept.append(scalar)
    }
    cleaned = String(kept).trimmingCharacters(in: .whitespaces)
    if let first = cleaned.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) {
      cleaned = "用户 " + cleaned
    }
    return cleaned
  }

  /// A user number's label from its display name: the name as a turn name,
  /// “ 2”, “ 3” when another number has it already. Nil when the name is no
  /// name (empty, or 「我」).
  static func label(for name: String, taken: Set<String>) -> String? {
    let base = cleanName(name)
    guard !base.isEmpty, base != ownerName else { return nil }
    var label = base
    var suffix = 2
    while taken.contains(label) {
      label = "\(base) \(suffix)"
      suffix += 1
    }
    return label
  }

  /// The title on its own line; a title that would read as a turn header
  /// (「周会(14:00)」) is written 「会议：周会(14:00)」, which does not.
  static func titleLine(_ title: String) -> String {
    let line = title.split(whereSeparator: \.isNewline).map(String.init).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    let text = line.isEmpty ? "腾讯会议" : line
    guard MemoryTranscriptText.startsTurn(text) else { return text }
    let prefixed = "会议：" + text
    return MemoryTranscriptText.startsTurn(prefixed) ? "腾讯会议" : prefixed
  }

  static func clock(_ milliseconds: Int) -> String {
    let seconds = max(0, milliseconds / 1_000)
    return String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
  }
}

/// The item's source file: the recording's listing objects and every
/// transcript page exactly as tmeet printed it (each page's bytes appear
/// unchanged in the file). Format `mindloom-tencent-meeting-source/1`:
///
/// ```json
/// {"format": "mindloom-tencent-meeting-source/1", "fetched_at": "…",
///  "tmeet_version": "…", "record_file_id": "…", "meeting_id": "…",
///  "listing": {"record_list": {…}, "meeting_list_ended": {…}},
///  "pages": [<page 1 as printed>, <page 2 as printed>, …]}
/// ```
///
/// It stays on this Mac (the item is a document: only its text is sent for
/// organizing). The organizing core reads people from it by
/// `speaker.user_id` (`TencentMeetingSourceDocument.parse`).
public struct TencentMeetingSourceDocument: Equatable, Sendable {
  public static let format = "mindloom-tencent-meeting-source/1"

  public let recordFileID: String
  public let meetingID: String
  public let fetchedAt: Date?
  public let paragraphs: [TencentMeetingParagraph]
  /// The listing objects, as stored.
  public let listings: [TencentMeetingListingSource: Data]

  /// The file's bytes. Nil when a page is not JSON.
  public static func encode(
    recording: TencentMeetingRecording, pages: [Data], fetchedAt: Date, tmeetVersion: String
  ) -> Data? {
    var trimmed: [Data] = []
    for page in pages {
      let text = String(decoding: page, as: UTF8.self).trimmingCharacters(
        in: .whitespacesAndNewlines)
      let bytes = Data(text.utf8)
      guard (try? JSONSerialization.jsonObject(with: bytes)) is [String: Any] else { return nil }
      trimmed.append(bytes)
    }
    var listing: [String: Any] = [:]
    for (source, data) in recording.listings {
      listing[source.rawValue] = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let head: [String: Any] = [
      "format": format, "fetched_at": formatter.string(from: fetchedAt),
      "tmeet_version": tmeetVersion, "record_file_id": recording.recordFileID,
      "meeting_id": recording.meetingID, "listing": listing,
    ]
    guard
      var document = try? JSONSerialization.data(
        withJSONObject: head, options: [.sortedKeys, .withoutEscapingSlashes]),
      document.last == UInt8(ascii: "}")
    else { return nil }
    document.removeLast()
    document.append(contentsOf: Array(",\"pages\":[".utf8))
    for (index, page) in trimmed.enumerated() {
      if index > 0 { document.append(UInt8(ascii: ",")) }
      document.append(page)
    }
    document.append(contentsOf: Array("]}".utf8))
    return document
  }

  /// Reads a source file back: the recording numbers and its paragraphs.
  public static func parse(_ data: Data) -> TencentMeetingSourceDocument? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["format"] as? String == format,
      let recordFileID = TencentMeetingListingParser.number(object["record_file_id"]),
      let meetingID = TencentMeetingListingParser.number(object["meeting_id"]),
      let pages = object["pages"] as? [Any]
    else { return nil }
    var parsed: [TencentMeetingTranscriptPage] = []
    for case let page as [String: Any] in pages {
      guard let pageData = page["data"] as? [String: Any],
        let transcript = TencentMeetingTranscriptParser.page(pageData)
      else { return nil }
      parsed.append(transcript)
    }
    var listings: [TencentMeetingListingSource: Data] = [:]
    for (key, value) in (object["listing"] as? [String: Any]) ?? [:] {
      guard let source = TencentMeetingListingSource(rawValue: key),
        let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
      else { continue }
      listings[source] = bytes
    }
    return TencentMeetingSourceDocument(
      recordFileID: recordFileID, meetingID: meetingID,
      fetchedAt: TencentMeetingListingParser.date(object["fetched_at"]),
      paragraphs: TencentMeetingTranscriptParser.merged(parsed), listings: listings)
  }
}
