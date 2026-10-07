import BestASRDomain
import Foundation

/// The kind of source an item came from, for its source tile.
public enum MemorySourceKind: String, Equatable, Sendable {
  /// A recording or a meeting App's transcript.
  case meeting
  /// Pasted text or a chat.
  case chat
  /// Sent from the phone.
  case phone
  /// Dictation.
  case dictation
  /// A screenshot or picture.
  case image
  /// A document or any other file.
  case file
}

/// One source line's words (MAC-SPEC §13.3.1): one word, an optional second
/// word after 「 · 」, and the SF Symbol drawn before them. Never a file name.
public struct MemorySourceWords: Equatable, Hashable, Sendable {
  /// 口述 · 键盘 · 会议记录 · 微信 · 邮件 · 文件 · 照片 · 表格 · 网页 · 截图 · 会议 · 粘贴 …
  public let word: String
  /// 「腾讯会议」 after 会议记录, 「iPhone」 after 键盘; empty otherwise.
  public let app: String
  /// mic · keyboard · person.3 · bubble.left · envelope · doc · photo · doc.text · link
  public let symbol: String
  /// The lead of the moment line inside an opened item: 「同一场会还讲到」 ·
  /// 「同一段口述还讲到」 · 「同一封邮件还讲到」 · 「同一段聊天还讲到」 · 「同一份文件还讲到」.
  public let sameCaptureLead: String

  public init(word: String, app: String = "", symbol: String, sameCaptureLead: String) {
    self.word = word
    self.app = app
    self.symbol = symbol
    self.sameCaptureLead = sameCaptureLead
  }

  /// 「会议记录 · 腾讯会议」, 「口述」.
  public var line: String { app.isEmpty ? word : word + " · " + app }
}

/// Source words and snippets for items (shared by the digest, Home and the
/// matter page).
public enum MemoryItemSource {
  /// What a meeting recorded from the microphone alone says, on its item
  /// and in the menu bar's menu while it records.
  public static let microphoneOnlyNote = "仅录制了麦克风"
  static let meetingApps: Set<String> = ["腾讯会议", "Zoom", "飞书妙记", "钉钉会议", "Teams", "Google Meet"]
  static let chatApps: Set<String> = ["微信", "企业微信", "飞书", "短信", "信息", "钉钉", "Slack", "Telegram"]
  static let assistantApps: Set<String> = ["Claude", "Codex", "ChatGPT"]
  static let keyboardApps: Set<String> = ["织机键盘", "Mindloom 键盘", "Mindloom键盘"]

  public static func kind(_ record: MemoryItemRecord) -> MemorySourceKind {
    switch record.inputMode {
    case .dictation: return .dictation
    case .roomMicrophone, .systemAudio, .importedMedia: return .meeting
    case .userItem:
      if record.sourceBundleID == nil, isPhone(record.sourceDisplayName) { return .phone }
      switch record.itemKind {
      case .image?: return .image
      case .file?: return .file
      case .document?, .text?:
        if MemoryTranscriptText.parse(record.text ?? "") != nil { return .meeting }
        return record.itemKind == .document ? .file : .chat
      case nil: return .chat
      }
    }
  }

  static func isPhone(_ name: String?) -> Bool {
    guard let name = name?.lowercased() else { return false }
    return name.contains("iphone") || name.contains("ipad") || name.contains("手机")
  }

  /// The words of an item's source line (`src_of` in the prototype's data).
  public static func words(_ record: MemoryItemRecord) -> MemorySourceWords {
    let app = record.sourceLabel
    let image = record.itemKind == .image
    switch record.inputMode {
    case .dictation:
      return MemorySourceWords(word: "口述", symbol: "mic", sameCaptureLead: "同一段口述还讲到")
    case .roomMicrophone:
      // 开始记录会议 without 屏幕与系统录音: the other side was not
      // recorded, and the item says so (ALIGNMENT 收2-2).
      return MemorySourceWords(
        word: "会议", app: microphoneOnlyNote, symbol: "person.3", sameCaptureLead: "同一场会还讲到")
    case .systemAudio:
      return MemorySourceWords(word: "会议", symbol: "person.3", sameCaptureLead: "同一场会还讲到")
    case .importedMedia:
      let media = MemoryMediaKind.of(record)
      return MemorySourceWords(
        word: media.word, symbol: media.symbol, sameCaptureLead: "同一份文件还讲到")
    case .userItem:
      break
    }
    if app == "Fn 口述" {
      return MemorySourceWords(word: "口述", symbol: "mic", sameCaptureLead: "同一段口述还讲到")
    }
    if keyboardApps.contains(app) || (record.sourceBundleID == nil && isPhone(record.sourceDisplayName))
    {
      return MemorySourceWords(
        word: "键盘", app: "iPhone", symbol: "keyboard", sameCaptureLead: "同一段口述还讲到")
    }
    if meetingApps.contains(app) {
      return MemorySourceWords(
        word: "会议记录", app: app, symbol: "person.3", sameCaptureLead: "同一场会还讲到")
    }
    if chatApps.contains(app) {
      return MemorySourceWords(
        word: app, symbol: image ? "photo" : "bubble.left", sameCaptureLead: "同一段聊天还讲到")
    }
    if assistantApps.contains(app) {
      return MemorySourceWords(word: app, symbol: "bubble.left", sameCaptureLead: "同一段聊天还讲到")
    }
    switch app {
    case "邮件", "Mail":
      return MemorySourceWords(word: "邮件", symbol: "envelope", sameCaptureLead: "同一封邮件还讲到")
    case "Finder", "访达":
      return MemorySourceWords(
        word: image ? "截图" : "文件", symbol: image ? "photo" : "doc",
        sameCaptureLead: "同一份文件还讲到")
    case "相册", "照片", "Photos":
      return MemorySourceWords(word: "照片", symbol: "photo", sameCaptureLead: "同一份文件还讲到")
    case "共享表格":
      return MemorySourceWords(word: "表格", symbol: "doc.text", sameCaptureLead: "同一份文件还讲到")
    case "网页", "课程平台", "Safari", "Google Chrome", "Chrome":
      return MemorySourceWords(word: "网页", symbol: "link", sameCaptureLead: "同一份文件还讲到")
    default:
      break
    }
    if image {
      return MemorySourceWords(word: "截图", symbol: "photo", sameCaptureLead: "同一份文件还讲到")
    }
    if MemoryTranscriptText.parse(record.text ?? "") != nil {
      return MemorySourceWords(word: "会议记录", symbol: "person.3", sameCaptureLead: "同一场会还讲到")
    }
    if record.itemKind == .file || record.itemKind == .document {
      return MemorySourceWords(word: "文件", symbol: "doc", sameCaptureLead: "同一份文件还讲到")
    }
    let word = app.isEmpty || app == "未知来源" ? "文字" : app
    return MemorySourceWords(word: word, symbol: "doc.text", sameCaptureLead: "同一份文件还讲到")
  }

  static let snippetLength = 30

  /// The part's description when the matter holds a part, else the item's
  /// first words (its reading for a screenshot, its title for a file).
  public static func snippet(_ record: MemoryItemRecord, gist: String?) -> String {
    if let gist, !gist.trimmingCharacters(in: .whitespaces).isEmpty {
      return short(gist, snippetLength)
    }
    let candidates = [record.text, record.localReading, record.title]
    for text in candidates {
      guard let text else { continue }
      if text == UserItemLimits.noTextLayerPlaceholder { continue }
      let words = text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        .joined(separator: " ")
      if !words.isEmpty { return short(words, snippetLength) }
    }
    return ""
  }

  static func short(_ text: String, _ length: Int) -> String {
    let line =
      text.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    guard line.count > length else { return line }
    return String(line.prefix(length - 1)) + "…"
  }
}

/// What an imported recording is (ALIGNMENT 收2-6): 「录音」 when it is sound
/// only, 「视频」 when it has pictures. Read from the original's media type,
/// else its file name's extension, else the frames taken from it.
public enum MemoryMediaKind: Equatable, Sendable {
  case audio
  case video

  public static func of(filename: String?, mediaType: String?, hasFrames: Bool = false)
    -> MemoryMediaKind
  {
    let type = (mediaType ?? "").lowercased()
    if type.hasPrefix("video/") { return .video }
    if type.hasPrefix("audio/") { return .audio }
    let ext = ((filename ?? "") as NSString).pathExtension.lowercased()
    if MediaImportFormats.videoExtensions.contains(ext) { return .video }
    if MediaImportFormats.audioExtensions.contains(ext) { return .audio }
    return hasFrames ? .video : .audio
  }

  public static func of(_ record: MemoryItemRecord) -> MemoryMediaKind {
    of(
      filename: record.sourceIdentifier, mediaType: record.mediaType,
      hasFrames: !record.keyframes.isEmpty)
  }

  /// 「录音」 · 「视频」.
  public var word: String {
    switch self {
    case .audio: "录音"
    case .video: "视频"
    }
  }

  public var symbol: String {
    switch self {
    case .audio: "waveform"
    case .video: "video"
    }
  }
}
