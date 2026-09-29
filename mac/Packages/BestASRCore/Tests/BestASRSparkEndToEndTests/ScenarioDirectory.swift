import AppKit
import BestASRDomain
import BestASRIntake
import Foundation

/// A synthetic scenario directory (`scenario.json` + `assets/`), as the
/// organizer's evaluation scenarios are written, read leniently so a larger
/// generated scenario with new item shapes still runs:
///
///     {"scenario_id", "people": [{"person_id", "display_name", "is_owner"}],
///      "items": [{"ref", "t", "kind", "source_app", "text"?, "segments"?,
///                 "image"?, "filename"?, "file"?, "format"?, "events"?}]}
///
/// How each item is taken in (through the real intake, as a user would):
/// - `text`, `dictation`, `note` and anything else with text: pasted text
///   from its source App. (Dictation has no audio here; it is pasted.)
/// - a transcript (`kind` `transcript`, a meeting export `format` such as
///   `tencent_transcript`/`zoom_vtt`, a `.vtt`/`.srt` file, or a `.md`/`.txt`
///   `filename`/`file` on a non-document item): dropped as that file from
///   its source App. Other formats (`chat_paste`, `email`, …) keep their kind.
/// - `meeting_online` / `meeting_offline` with `segments`: written as a
///   腾讯会议-style export (`名字(HH:MM:SS):` then the words) and dropped.
/// - `image`: `assets/<ref>.png|jpg` (or `file`), else drawn from its
///   `image.messages`, pasted as PNG.
/// - `document`: its file under `assets/` (or `file`) dropped; else its text
///   as the named `.txt`/`.md` file, or a PDF with a text layer made from it
///   (named after `filename`, with `.pdf`).
/// - any item that ships a file (`file`/`asset`/`path`, or `assets/<ref>.*`
///   of any type: a spreadsheet, slides, mail, a calendar, a scan, an
///   archive, a video, …): dropped as that file through the real intake, as
///   Finder would (a screenshot's PNG/JPEG is still pasted). Audio and video
///   become media imports, which the harness reports without running ASR.
/// Items are taken in in time order (`t`), captured at `t`.
struct ScenarioDirectory {
  struct Person {
    let id: String
    let name: String
    let isOwner: Bool
  }

  struct Item {
    let ref: String
    let at: Date
    let kind: String
    let sourceApp: String
    let expectedEvents: [String]
    let raw: [String: Any]

    var text: String? { raw["text"] as? String }
  }

  enum Intake {
    case paste(String)
    case pasteImage(Data)
    case drop(URL)
  }

  let root: URL
  let id: String
  let people: [String: Person]
  let items: [Item]

  init(root: URL) throws {
    self.root = root
    let data = try Data(contentsOf: root.appendingPathComponent("scenario.json"))
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SparkEndToEndTests.EndToEndError("scenario.json is not an object")
    }
    id = json["scenario_id"] as? String ?? root.lastPathComponent
    var people: [String: Person] = [:]
    for entry in json["people"] as? [[String: Any]] ?? [] {
      guard let id = entry["person_id"] as? String else { continue }
      people[id] = Person(
        id: id, name: entry["display_name"] as? String ?? id,
        isOwner: entry["is_owner"] as? Bool ?? false)
    }
    self.people = people
    var items: [Item] = []
    for (index, entry) in (json["items"] as? [[String: Any]] ?? []).enumerated() {
      guard let stamp = (entry["t"] ?? entry["captured_at"]) as? String,
        let at = Self.date(stamp)
      else { continue }
      items.append(
        Item(
          ref: entry["ref"] as? String ?? entry["item_id"] as? String ?? "item-\(index + 1)",
          at: at, kind: (entry["kind"] as? String ?? "text").lowercased(),
          sourceApp: Self.appName(entry["source_app"]),
          expectedEvents: entry["events"] as? [String] ?? [], raw: entry))
    }
    // Time order; the file order breaks ties.
    self.items = items.enumerated().sorted {
      $0.element.at != $1.element.at ? $0.element.at < $1.element.at : $0.offset < $1.offset
    }.map(\.element)
  }

  static func appName(_ value: Any?) -> String {
    if let name = value as? String { return name }
    if let object = value as? [String: Any], let name = object["name"] as? String { return name }
    return "未知来源"
  }

  static func date(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: value) { return date }
    // Larger scenarios stamp items to the minute (`2026-08-10T08:21+08:00`).
    let minutes = DateFormatter()
    minutes.locale = Locale(identifier: "en_US_POSIX")
    minutes.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX"
    return minutes.date(from: value)
  }

  /// Bundle IDs of the Apps scenarios name, so the source reads as a paste
  /// from that App would.
  static let bundles: [String: String] = [
    "微信": "com.tencent.xinWeChat", "企业微信": "com.tencent.WeWorkMac",
    "腾讯会议": "com.tencent.meeting", "飞书": "com.electron.lark", "钉钉": "com.alibaba.DingTalkMac",
    "Zoom": "us.zoom.xos", "Claude": "com.anthropic.claudefordesktop", "Codex": "com.openai.codex",
    "ChatGPT": "com.openai.chat", "备忘录": "com.apple.Notes", "Safari": "com.apple.Safari",
    "Finder": "com.apple.finder", "访达": "com.apple.finder", "QQ": "com.tencent.qq",
    "Slack": "com.tinyspeck.slackmacgap", "邮件": "com.apple.mail", "Mail": "com.apple.mail",
  ]

  static func source(_ name: String) -> ItemSourceApplication? {
    ItemSourceApplication(bundleID: bundles[name], name: name)
  }

  /// A kind the summary reports (what the item became on the Mac).
  func intakeKind(_ item: Item) -> String {
    if isTranscript(item) || isMeeting(item) { return "transcript_file" }
    if let file = droppedAsset(item) {
      switch IntakeFileClass.classify(file) {
      case .audio, .video: return "media"
      case .image, .svg: return "image_file"
      case .plainText, .rtf, .html, .webArchive, .webLocation: return "document"
      case .pdf where ["document", "pdf"].contains(item.kind): return "document"
      default: return "file"
      }
    }
    switch item.kind {
    case "image", "screenshot": return "screenshot"
    case "document", "pdf": return "document"
    case "dictation": return "dictation_as_text"
    default: return "text"
    }
  }

  func isTranscript(_ item: Item) -> Bool {
    if item.kind == "transcript" { return true }
    // Larger scenarios give every item a `format` (`chat_paste`, `email`,
    // `pdf`, …); only a meeting App's export format makes it a transcript.
    if let format = item.raw["format"] as? String {
      if Self.isTranscriptFormat(format) { return true }
      if !format.isEmpty, item.raw["filename"] == nil, item.raw["file"] == nil { return false }
    }
    let name = (item.raw["filename"] ?? item.raw["file"]) as? String ?? ""
    let ext = (name as NSString).pathExtension.lowercased()
    if ["vtt", "srt"].contains(ext) { return true }
    return ["md", "txt"].contains(ext)
      && !["image", "screenshot", "document", "pdf"].contains(item.kind)
  }

  /// `tencent_transcript`, `feishu_transcript`, `zoom_vtt`, `zoom_txt`, a
  /// bare `vtt`/`srt`, …
  static func isTranscriptFormat(_ format: String) -> Bool {
    let value = format.lowercased()
    return value.contains("transcript") || value.contains("vtt") || value.contains("srt")
      || value.hasPrefix("zoom")
      || ["tencent", "tencent_meeting", "feishu", "lark"].contains(value)
  }

  /// The scenario's truth for an item that covers several matters: which
  /// expected event each quoted part belongs to (`event_segments`, or
  /// `segments` entries with an `event_id` and a `quote`).
  func truthParts(_ item: Item) -> [(event: String, quote: String)] {
    let lists = [item.raw["event_segments"], item.raw["segments"]]
      .compactMap { $0 as? [[String: Any]] }
    return lists.flatMap { list in
      list.compactMap { entry -> (event: String, quote: String)? in
        guard let event = entry["event_id"] as? String, let quote = entry["quote"] as? String,
          !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return (event, quote)
      }
    }
  }

  func isMeeting(_ item: Item) -> Bool {
    item.kind.hasPrefix("meeting") && item.raw["segments"] is [[String: Any]]
  }

  /// A file the scenario ships for the item: its `file`/`asset`/`image_path`
  /// field, else `assets/<ref>.<ext>` for one of `extensions`.
  func asset(_ item: Item, extensions: [String]) -> URL? {
    for key in ["file", "asset", "image_path", "path"] {
      if let relative = item.raw[key] as? String {
        let url = root.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: url.path) { return url }
      }
    }
    for ext in extensions {
      let url = root.appendingPathComponent("assets/\(item.ref).\(ext)")
      if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    return nil
  }

  /// Any file the scenario ships for the item, whatever its type: the
  /// named `file`/`asset`/`image_path`/`path`, else `assets/<ref>.<ext>`.
  func anyAsset(_ item: Item) -> URL? {
    if let named = asset(item, extensions: []) { return named }
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? []
    return names.sorted().first { ($0 as NSString).deletingPathExtension == item.ref }
      .map { assets.appendingPathComponent($0) }
  }

  /// The asset this item is dropped as, when it is dropped as its own file
  /// (not a meeting export, a transcript, or a screenshot to paste).
  func droppedAsset(_ item: Item) -> URL? {
    guard !isMeeting(item), !isTranscript(item), let file = anyAsset(item) else { return nil }
    let pasted =
      ["image", "screenshot"].contains(item.kind)
      && ["png", "jpg", "jpeg"].contains(file.pathExtension.lowercased())
    return pasted ? nil : file
  }

  /// Turns a scenario item into what the user would paste or drop; files
  /// are written into `inbox` (the Mac's temporary work directory).
  @MainActor
  func intake(_ item: Item, inbox: URL) throws -> Intake {
    if isMeeting(item) {
      return .drop(try write(meetingExport(item), named: filename(item, "txt"), in: inbox))
    }
    if isTranscript(item) {
      if let file = asset(item, extensions: ["txt", "md", "vtt", "srt"]) { return .drop(file) }
      return .drop(try write(item.text ?? "", named: filename(item, "txt"), in: inbox))
    }
    if let file = droppedAsset(item) { return .drop(file) }
    switch item.kind {
    case "image", "screenshot":
      if let file = asset(item, extensions: ["png", "jpg", "jpeg"]) {
        return .pasteImage(try Data(contentsOf: file))
      }
      return .pasteImage(try drawnScreenshot(item))
    case "document", "pdf":
      if let file = asset(item, extensions: ["pdf", "docx", "md", "txt"]) { return .drop(file) }
      let given = filename(item, "pdf")
      // A text document is dropped as that text file; any other (a PDF, a
      // .docx the scenario ships no file for) as a PDF with a text layer.
      if ["txt", "text", "md", "markdown"].contains((given as NSString).pathExtension.lowercased())
      {
        return .drop(try write(item.text ?? "", named: given, in: inbox))
      }
      let name = (given as NSString).deletingPathExtension + ".pdf"
      let lines = (item.text ?? "").split(whereSeparator: \.isNewline).map(String.init)
      let pdf = try SyntheticRendering.textPDF(title: lines.first ?? name, lines: lines)
      let url = inbox.appendingPathComponent(name)
      try pdf.write(to: url, options: .atomic)
      return .drop(url)
    default:
      guard let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw SparkEndToEndTests.EndToEndError("\(item.ref) has no text to paste") }
      return .paste(text)
    }
  }

  private func filename(_ item: Item, _ ext: String) -> String {
    let given = (item.raw["filename"] ?? item.raw["file"]) as? String
    let base = given.map { ($0 as NSString).lastPathComponent } ?? "\(item.ref).\(ext)"
    return base.replacingOccurrences(of: "/", with: "-")
  }

  private func write(_ text: String, named name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(text.utf8).write(to: url, options: .atomic)
    return url
  }

  /// `名字(HH:MM:SS):` then the words, a blank line between turns — how
  /// 腾讯会议 exports a meeting.
  func meetingExport(_ item: Item) -> String {
    let segments = item.raw["segments"] as? [[String: Any]] ?? []
    var lines: [String] = []
    if let title = item.raw["title"] as? String { lines += [title, ""] }
    for segment in segments {
      let ms = (segment["start_ms"] as? Int) ?? 0
      let seconds = ms / 1_000
      let stamp = String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
      let personID = segment["person_id"] as? String ?? ""
      let name = people[personID]?.name ?? (personID.isEmpty ? "发言人" : personID)
      let said = (segment["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !said.isEmpty else { continue }
      lines += ["\(name)(\(stamp)):", said, ""]
    }
    return lines.joined(separator: "\n")
  }

  @MainActor
  private func drawnScreenshot(_ item: Item) throws -> Data {
    let spec = item.raw["image"] as? [String: Any] ?? [:]
    let me = spec["self_sender"] as? String ?? "我"
    let messages = spec["messages"] as? [[String: Any]] ?? []
    let bubbles = messages.map { message -> SyntheticWeek.Bubble in
      let sender = message["sender"] as? String ?? ""
      return SyntheticWeek.Bubble(
        fromMe: sender == me, sender: sender, text: message["text"] as? String ?? "")
    }
    guard !bubbles.isEmpty else {
      throw SparkEndToEndTests.EndToEndError("\(item.ref) has no image and no messages")
    }
    let clock = messages.first?["time"] as? String ?? ""
    return try SyntheticRendering.chatScreenshotPNG(
      title: spec["chat_title"] as? String ?? item.sourceApp, clock: clock, bubbles: bubbles)
  }
}
