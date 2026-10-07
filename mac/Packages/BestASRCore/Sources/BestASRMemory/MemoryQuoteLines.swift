import Foundation

/// One line of an item as a quote shows it: who said it (「我」 for the
/// owner, empty for none) and the words. Never autospaced.
public struct MemoryQuoteLine: Equatable, Hashable, Sendable {
  public let speaker: String
  public let words: String
  /// The sentence in a recording on this Mac, when the line is one: its
  /// speaker's name plays it (v12, 理3-5).
  public let voice: MemoryQuoteVoice?

  public init(speaker: String, words: String, voice: MemoryQuoteVoice? = nil) {
    self.speaker = speaker
    self.words = words
    self.voice = voice
  }
}

/// Where a recorded sentence is: the item, who said it (canonical person
/// ID), and its stretch on the recording's monotonic clock.
public struct MemoryQuoteVoice: Equatable, Hashable, Sendable {
  /// Upper-case item ID.
  public let itemID: String
  public let personID: String
  public let start: UInt64
  public let end: UInt64

  public init(itemID: String, personID: String, start: UInt64, end: UInt64) {
    self.itemID = itemID.uppercased()
    self.personID = personID
    self.start = start
    self.end = max(start, end)
  }
}

/// An item's text as speaker lines, and the two lines around a quote
/// (MAC-SPEC §13.3.1 `lines`): chat lines `[MM-DD HH:MM] 名字：…`, meeting
/// lines `名字 Pinyin NAME (hh:mm:ss)` with the words on the next line, or
/// plain prose lines.
public enum MemoryQuoteLines {
  static let chatLine = #"^\[[0-9\- :]+\]\s*([^：:\[\]]{1,14})[：:]\s*(.*)$"#
  static let meetingLine =
    #"^([\x{4E00}-\x{9FA5}A-Za-z]{2,4})(?:\s+[A-Za-z]+ [A-Z]+)?\s*[（(]\d\d:\d\d:\d\d[)）][：:]?\s*(.*)$"#
  /// A plain `名字：…` line (a pasted chat without time stamps).
  static let namedLine = #"^([\x{4E00}-\x{9FA5}A-Za-z·]{1,8})[：:]\s*(.+)$"#
  /// The synthetic scenario's watermark, never shown.
  static let watermark = "合成数据 ▲ 虚构内容"
  static let emoji: [(String, String)] = [
    ("[OK]", "👌"), ("[捂脸]", "🤦"), ("[抱拳]", "🙏"), ("[笑哭]", "😂"), ("[微笑]", "🙂"), ("[强]", "👍"),
    ("[哭]", "😢"), ("[叹气]", "😮‍💨"), ("[呲牙]", "😁"), ("[握手]", "🤝"),
  ]

  /// Every non-empty line, with its speaker when the line names one.
  public static func lines(_ text: String) -> [(speaker: String?, words: String)] {
    var out: [(String?, String)] = []
    var pending: String?
    for raw in text.replacingOccurrences(of: watermark, with: "").split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }
      if let groups = MemoryDisplayText.allGroups(chatLine, in: line).first {
        out.append((groups[1].trimmingCharacters(in: .whitespaces), groups[2].trimmingCharacters(in: .whitespaces)))
      } else if let groups = MemoryDisplayText.allGroups(meetingLine, in: line).first {
        if groups[2].isEmpty { pending = groups[1] } else { out.append((groups[1], groups[2])) }
      } else if let speaker = pending {
        out.append((speaker, line))
        pending = nil
      } else if let groups = MemoryDisplayText.allGroups(namedLine, in: line).first {
        out.append((groups[1], groups[2].trimmingCharacters(in: .whitespaces)))
      } else {
        out.append((nil, line))
      }
    }
    return out
  }

  /// The line holding the quote (by its first eight characters) and the one
  /// after it; a line over 150 characters is cut to the sentence around the
  /// quote. Dictations get punctuation (a space between two CJK characters
  /// is a pause: 「，」). Chat codes become the emoji the chat showed.
  public static func around(
    _ quote: String, in text: String, dictation: Bool, ownerNames: Set<String>
  ) -> [MemoryQuoteLine] {
    var all = lines(text)
    if dictation { all = all.map { ($0.speaker, punctuated($0.words)) } }
    let head = String(quote.prefix(8))
    let index = head.isEmpty ? 0 : (all.firstIndex { $0.words.contains(head) } ?? 0)
    return all.dropFirst(index).prefix(2).map { line in
      var words = line.words
      if words.count > 150 { words = cut(words, around: head) }
      let speaker = line.speaker.map { ownerNames.contains($0) ? "我" : $0 } ?? ""
      return MemoryQuoteLine(speaker: speaker, words: withEmoji(words))
    }
  }

  static func cut(_ words: String, around head: String) -> String {
    var text = words
    if !head.isEmpty, let hit = text.range(of: head) {
      let offset = text.distance(from: text.startIndex, to: hit.lowerBound)
      if offset > 60 {
        let before = text[..<hit.lowerBound]
        if let stop = before.lastIndex(where: { $0 == "。" || $0 == "，" }) {
          text = String(text[text.index(after: stop)...])
        } else {
          text = String(text.dropFirst(offset - 40))
        }
      }
    }
    text = String(text.prefix(150))
    if let end = text.lastIndex(where: { $0 == "。" || $0 == "，" }),
      text.distance(from: text.startIndex, to: end) > 60
    {
      text = String(text[...end])
    }
    return text
  }

  /// A dictation's pauses as commas (the recognizer's own punctuation is kept).
  public static func punctuated(_ text: String) -> String {
    var s = MemoryDisplayText.replace(
      #"(?<=[\x{4E00}-\x{9FA5}])\s+(?=[\x{4E00}-\x{9FA5}])"#,
      in: text.trimmingCharacters(in: .whitespaces)
    ) { _ in "，" }
    s = MemoryDisplayText.replace(
      #"(?<=[\x{4E00}-\x{9FA5}])\s+(?=[A-Za-z0-9])|(?<=[A-Za-z0-9])\s+(?=[\x{4E00}-\x{9FA5}])"#, in: s
    ) { _ in " " }
    return s
  }

  static func withEmoji(_ text: String) -> String {
    emoji.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
  }
}
