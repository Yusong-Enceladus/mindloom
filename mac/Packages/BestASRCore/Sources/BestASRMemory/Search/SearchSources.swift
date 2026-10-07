import Foundation

/// Where records came from, as a search condition: a word the user types
/// (「微信」「腾讯会议」「口述」「iPhone」…) names one of these. A record matches
/// when any of its sets matches (B4 §3.2c).
public struct SearchSourceFilter: Equatable, Hashable, Sendable {
  /// What the chip says.
  public let label: String
  /// `session_metadata.source_display_name`, exactly.
  public var names: Set<String> = []
  /// `session_metadata.source_display_name` prefixes (「iPhone」 for 「iPhone 键盘」).
  public var namePrefixes: Set<String> = []
  /// `sessions.input_mode`.
  public var inputModes: Set<String> = []
  /// `user_item_details.item_kind`.
  public var itemKinds: Set<String> = []
  /// `session_metadata.source_kind` (「typeless-import」).
  public var sourceKinds: Set<String> = []
  /// File name suffixes (lower case), for 「PDF」.
  public var fileSuffixes: Set<String> = []

  public init(
    label: String, names: Set<String> = [], namePrefixes: Set<String> = [],
    inputModes: Set<String> = [], itemKinds: Set<String> = [], sourceKinds: Set<String> = [],
    fileSuffixes: Set<String> = []
  ) {
    self.label = label
    self.names = names
    self.namePrefixes = namePrefixes
    self.inputModes = inputModes
    self.itemKinds = itemKinds
    self.sourceKinds = sourceKinds
    self.fileSuffixes = fileSuffixes
  }

  /// Whether a record with these facts matches (the same rule the store's
  /// SQL applies; used by tests and in-memory callers).
  public func matches(
    sourceName: String?, inputMode: String, itemKind: String?, sourceKind: String?,
    sourceIdentifier: String?
  ) -> Bool {
    if let sourceName {
      if names.contains(sourceName) { return true }
      if namePrefixes.contains(where: { sourceName.hasPrefix($0) }) { return true }
    }
    if inputModes.contains(inputMode) { return true }
    if let sourceKind, sourceKinds.contains(sourceKind) { return true }
    if let itemKind, itemKinds.contains(itemKind) {
      guard !fileSuffixes.isEmpty else { return true }
      let name = (sourceIdentifier ?? "").lowercased()
      return fileSuffixes.contains { name.hasSuffix($0) }
    }
    return false
  }
}

/// The words that name a source. Brand and App names are recognized
/// anywhere; generic words (口述, 会议, 邮件…) only as a word of their own (a
/// space or the edge of the query around them, or a following 里/上/中/的),
/// so 「会议纪要」 stays a content word.
public enum SearchSources {
  public struct Word: Sendable {
    public let spellings: [String]
    public let generic: Bool
    public let filter: SearchSourceFilter
  }

  /// Names include the App identifiers (`com.tencent.xinWeChat`):
  /// dictation stores its target App's identifier as the source name (v12
  /// search: on a copy of a real library 「微信」 found none of this App's
  /// own dictation).
  public static let words: [Word] = [
    Word(
      spellings: ["企业微信"], generic: false,
      filter: .init(label: "企业微信", names: ["企业微信", "com.tencent.WeWorkMac"])),
    Word(
      spellings: ["微信", "wechat"], generic: false,
      filter: .init(label: "微信", names: ["微信", "WeChat", "com.tencent.xinWeChat"])),
    Word(
      spellings: ["腾讯会议", "tencent meeting"], generic: false,
      filter: .init(label: "腾讯会议", names: ["腾讯会议", "com.tencent.meeting"])),
    Word(spellings: ["飞书妙记"], generic: false, filter: .init(label: "飞书妙记", names: ["飞书妙记"])),
    Word(
      spellings: ["飞书", "lark"], generic: false, filter: .init(label: "飞书", names: ["飞书", "飞书妙记"])),
    Word(
      spellings: ["钉钉"], generic: false,
      filter: .init(label: "钉钉", names: ["钉钉", "com.alibaba.DingTalkMac"])),
    Word(
      spellings: ["zoom"], generic: false,
      filter: .init(label: "Zoom", names: ["Zoom", "zoom.us", "us.zoom.xos"])),
    Word(
      spellings: ["slack"], generic: false,
      filter: .init(label: "Slack", names: ["Slack", "com.tinyspeck.slackmacgap"])),
    Word(
      spellings: ["claude"], generic: false,
      filter: .init(label: "Claude", names: ["Claude", "com.anthropic.claudefordesktop"])),
    Word(
      spellings: ["codex"], generic: false,
      filter: .init(label: "Codex", names: ["Codex", "com.openai.codex"])),
    Word(
      spellings: ["chatgpt"], generic: false,
      filter: .init(label: "ChatGPT", names: ["ChatGPT", "com.openai.chat"])),
    Word(
      spellings: ["overleaf"], generic: false, filter: .init(label: "Overleaf", names: ["Overleaf"])
    ),
    Word(
      spellings: ["typeless"], generic: false,
      filter: .init(label: "Typeless", names: ["Typeless"], sourceKinds: ["typeless-import"])),
    Word(
      spellings: ["apple watch", "手表"], generic: false,
      filter: .init(label: "Apple Watch", namePrefixes: ["Apple Watch"])),
    Word(
      spellings: ["iphone", "手机"], generic: false,
      filter: .init(label: "iPhone", namePrefixes: ["iPhone"])),
    Word(
      spellings: ["口述", "语音输入", "说的话"], generic: true,
      filter: .init(
        label: "口述", names: ["Fn 口述", "Typeless"], inputModes: ["dictation"],
        sourceKinds: ["typeless-import"])),
    Word(
      spellings: ["会议", "开会", "会上"], generic: true,
      filter: .init(
        label: "会议", names: ["腾讯会议", "飞书妙记", "Zoom", "会议录音"],
        inputModes: ["roomMicrophone", "systemAudio"])),
    Word(
      spellings: ["录音"], generic: true,
      filter: .init(
        label: "录音", inputModes: ["roomMicrophone", "systemAudio", "importedMedia"])),
    Word(
      spellings: ["邮件", "邮箱", "email", "mail"], generic: true,
      filter: .init(
        label: "邮件", names: ["邮件", "Mail", "Outlook", "com.apple.mail", "com.microsoft.Outlook"])),
    Word(
      spellings: ["短信", "imessage"], generic: true,
      filter: .init(label: "短信", names: ["短信", "信息", "Messages", "com.apple.MobileSMS"])),
    Word(
      spellings: ["截图", "图片", "照片"], generic: true,
      filter: .init(label: "截图", itemKinds: ["image"])),
    Word(
      spellings: ["pdf"], generic: true,
      filter: .init(label: "PDF", itemKinds: ["document", "file"], fileSuffixes: [".pdf"])),
    Word(
      spellings: ["文件", "文档"], generic: true,
      filter: .init(label: "文件", itemKinds: ["document", "file"])),
    Word(
      spellings: ["网页", "浏览器"], generic: true,
      filter: .init(
        label: "网页",
        names: [
          "网页", "Safari", "Google Chrome", "Chrome", "com.apple.Safari", "com.google.Chrome",
        ])),
    Word(
      spellings: ["终端"], generic: true,
      filter: .init(label: "终端", names: ["终端", "Terminal", "com.apple.Terminal"])),
  ]
}
