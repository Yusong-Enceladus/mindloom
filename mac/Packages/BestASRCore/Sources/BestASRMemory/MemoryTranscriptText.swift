import Foundation

/// A meeting transcript exported by a meeting App, read as turns. The
/// organizing device reads the same text with the same rules
/// (`spark/organizer/transcripts.py`) and cuts split segments on these turns;
/// both are checked against one shared case file
/// (`Tests/Fixtures/RemoteOrganizer/transcript_formats.json`, a copy of the
/// organizer's). Keep the two in step.
///
/// The text is read line by line (split on U+000A, each line trimmed of
/// surrounding whitespace, so a CRLF export's `\r` is not content). Formats:
///
/// - Tencent Meeting (腾讯会议) export: a header line `Name(HH:MM:SS):`
///   (ASCII or full-width brackets and colon, the colon optional; `H:MM` and
///   `MM:SS` also accepted), then the utterance on the following lines until
///   the next header. The utterance may also follow the colon on the header
///   line.
/// - Feishu (飞书妙记) export: a header line `Name HH:MM:SS` (seconds
///   required, nothing after the time), then the utterance as above.
/// - Zoom: `[HH:MM:SS] Name: text` (ASCII or full-width colon); a following
///   line without a header continues the turn, a blank line ends it.
/// - WebVTT / SRT: a cue timing line `HH:MM:SS.mmm --> HH:MM:SS.mmm` (`,`
///   for SRT; a cue number on the line above belongs to the cue), then
///   `Name: text` or `<v Name>text`; the cue's text runs to the next blank
///   line. Cues without a speaker are not turns; consecutive cues of one
///   speaker are one turn.
///
/// A speaker name is at most 40 scalars, does not start with a digit, has no
/// sentence punctuation or brackets and at most eight CJK ideographs; runs
/// of spaces in it read as one. The name may be "中文名 English NAME". Lines
/// before the first header (a title block) belong to no turn. Text is a
/// transcript when a format yields at least two turns with words; the format
/// with the most turns wins, the earlier one in the order above on a tie.
/// Times read as `HH:MM:SS` (`01:05` is one minute five seconds).
///
/// A turn's `start`/`end` are offsets in Unicode scalars (what the
/// organizing device counts as characters; CRLF counts two): from the first
/// non-space character of its header line (the cue number's line for SRT)
/// to the end of its last non-empty line, trailing spaces and `\r` excluded.
/// A segment of a transcript item starts at a turn's `start` and ends at a
/// turn's `end`.
public enum MemoryTranscriptText {
  public enum Format: String, Equatable, Sendable {
    case tencent
    case feishu
    case zoom
    case subtitles
  }

  public struct Turn: Equatable, Sendable {
    public let speaker: String
    /// The time as written ("00:12:05"); empty when the format has none.
    public let time: String
    public let text: String
    public let start: Int
    public let end: Int

    public init(speaker: String, time: String, text: String, start: Int, end: Int) {
      self.speaker = speaker
      self.time = time
      self.text = text
      self.start = start
      self.end = end
    }
  }

  public struct Transcript: Equatable, Sendable {
    public let format: Format
    public let turns: [Turn]
  }

  /// Nil when the text does not read as a transcript.
  public static func parse(_ text: String) -> Transcript? {
    let lines = Self.lines(text)
    var best: Transcript?
    for format in [Format.tencent, .feishu, .zoom, .subtitles] {
      let turns: [Turn]
      switch format {
      case .tencent: turns = headed(lines, header: tencentHeader)
      case .feishu: turns = headed(lines, header: feishuHeader)
      case .zoom: turns = zoom(lines)
      case .subtitles: turns = subtitles(lines)
      }
      guard qualifies(turns, format: format) else { continue }
      if turns.count > (best?.turns.count ?? 0) {
        best = Transcript(format: format, turns: turns)
      }
    }
    return best
  }

  static func qualifies(_ turns: [Turn], format: Format) -> Bool {
    turns.count >= 2
  }

  // MARK: - Lines

  struct Line {
    /// Trimmed.
    let text: String
    /// Unicode-scalar offsets of the untrimmed line (without its newline).
    let start: Int
    let end: Int
    /// Offset of the first non-space character.
    let contentStart: Int
    /// Offset just after the last non-space character.
    let contentEnd: Int
  }

  static func lines(_ text: String) -> [Line] {
    // Split on the scalar U+000A: Swift reads "\r\n" as one Character, the
    // organizing device as two characters.
    var result: [Line] = []
    var offset = 0
    var current = String.UnicodeScalarView()
    func close() {
      let raw = String(current)
      let scalars = current.count
      // Surrounding spaces and `\r` are not content.
      var leading = 0
      for scalar in current {
        guard CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
        leading += 1
      }
      var trailing = 0
      for scalar in current.reversed() {
        guard CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
        trailing += 1
      }
      result.append(
        Line(
          text: raw.trimmingCharacters(in: .whitespacesAndNewlines), start: offset,
          end: offset + scalars, contentStart: offset + min(leading, scalars),
          contentEnd: offset + scalars - trailing))
      offset += scalars + 1
      current = String.UnicodeScalarView()
    }
    for scalar in text.unicodeScalars {
      if scalar == "\n" { close() } else { current.append(scalar) }
    }
    close()
    return result
  }

  // MARK: - Header formats (Tencent, Feishu)

  private static let clock = #"(\d{1,2}:\d{2}(?::\d{2})?)"#

  /// The utterance may follow the colon (group 3).
  static let tencentHeader = try! NSRegularExpression(
    pattern: #"^(\S(?:[^()（）]{0,38}\S)?)\s*[(（]\s*"# + clock
      + #"\s*[)）]\s*(?:[:：]\s*(.*))?$"#)

  static let feishuHeader = try! NSRegularExpression(
    pattern: #"^(\S(?:.{0,38}\S)?)\s+(\d{1,2}:\d{2}:\d{2})$"#)

  private static func match(_ regex: NSRegularExpression, _ line: String) -> [String]? {
    let range = NSRange(line.startIndex..., in: line)
    guard let found = regex.firstMatch(in: line, range: range) else { return nil }
    return (1..<found.numberOfRanges).map { index in
      Range(found.range(at: index), in: line).map { String(line[$0]) } ?? ""
    }
  }

  static func headed(_ lines: [Line], header: NSRegularExpression) -> [Turn] {
    var turns: [Turn] = []
    var current: (speaker: String, time: String, start: Int, end: Int, body: [String])?
    func flush() {
      guard let open = current else { return }
      let text = open.body.joined(separator: "\n")
      if !text.isEmpty {
        turns.append(
          Turn(
            speaker: cleanSpeaker(open.speaker), time: normalizedTime(open.time), text: text,
            start: open.start, end: open.end))
      }
      current = nil
    }
    for line in lines {
      if let parts = match(header, line.text), parts.count >= 2 {
        let speaker = parts[0].trimmingCharacters(in: .whitespaces)
        if isSpeakerName(speaker) {
          flush()
          let inline = parts.count >= 3 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
          current = (
            speaker, parts[1], line.contentStart, line.contentEnd, inline.isEmpty ? [] : [inline]
          )
          continue
        }
      }
      guard !line.text.isEmpty, current != nil else { continue }
      current?.body.append(line.text)
      current?.end = line.contentEnd
    }
    flush()
    return turns
  }

  /// A name, not a clause: at most 40 scalars, not starting with a digit,
  /// no sentence punctuation or brackets, at most eight CJK ideographs.
  static func isSpeakerName(_ name: String) -> Bool {
    let scalars = name.unicodeScalars
    guard let first = scalars.first, scalars.count <= 40,
      !CharacterSet.decimalDigits.contains(first)
    else { return false }
    let notInName = CharacterSet(charactersIn: "。，,、！!？?；;：:“”\"「」【】[]()（）<>")
    guard !scalars.contains(where: { notInName.contains($0) }) else { return false }
    return scalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count <= 8
  }

  /// Runs of spaces and tabs in a name read as one space.
  static func cleanSpeaker(_ name: String) -> String {
    name.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
  }

  /// "1:02" reads as "00:01:02", "1:02:03" as "01:02:03".
  static func normalizedTime(_ time: String) -> String {
    var parts = time.split(separator: ":").map { Int($0) ?? 0 }
    while parts.count < 3 { parts.insert(0, at: 0) }
    let hms = parts.suffix(3).map { $0 < 10 ? "0\($0)" : "\($0)" }
    return hms.joined(separator: ":")
  }

  // MARK: - Zoom

  static let zoomLine = try! NSRegularExpression(
    pattern: #"^\[\s*"# + clock + #"\s*\]\s*([^:：\[\]]{1,40}?)\s*[:：]\s*(.*)$"#)

  static func zoom(_ lines: [Line]) -> [Turn] {
    var turns: [Turn] = []
    var current: (speaker: String, time: String, start: Int, end: Int, body: [String])?
    func flush() {
      guard let open = current else { return }
      let text = open.body.joined(separator: "\n")
      if !text.isEmpty {
        turns.append(
          Turn(
            speaker: cleanSpeaker(open.speaker), time: normalizedTime(open.time), text: text,
            start: open.start, end: open.end))
      }
      current = nil
    }
    for line in lines {
      if let parts = match(zoomLine, line.text), parts.count >= 3,
        isSpeakerName(parts[1].trimmingCharacters(in: .whitespaces))
      {
        flush()
        let first = parts[2].trimmingCharacters(in: .whitespaces)
        current = (
          parts[1].trimmingCharacters(in: .whitespaces), parts[0], line.contentStart,
          line.contentEnd, first.isEmpty ? [] : [first]
        )
        continue
      }
      guard !line.text.isEmpty, current != nil else {
        // A blank line ends a turn in this format.
        if line.text.isEmpty { flush() }
        continue
      }
      current?.body.append(line.text)
      current?.end = line.contentEnd
    }
    flush()
    return turns
  }

  // MARK: - WebVTT / SRT

  static let cueTiming = try! NSRegularExpression(
    pattern: #"^(\d{1,2}:\d{2}(?::\d{2})?)[.,]\d{1,3}\s*-->\s*\d{1,2}:\d{2}(?::\d{2})?[.,]\d{1,3}"#)
  static let voiceTag = try! NSRegularExpression(
    pattern: #"^<v(?:\.[^\s>]+)?\s+([^>]{1,40})>(.*)$"#)
  static let namedCue = try! NSRegularExpression(pattern: #"^([^:：]{1,40}?)\s*[:：]\s*(\S.*)$"#)
  static let cueNumber = try! NSRegularExpression(pattern: #"^[+-]?[0-9]+$"#)

  static func subtitles(_ lines: [Line]) -> [Turn] {
    var turns: [Turn] = []
    var index = 0
    while index < lines.count {
      guard let timing = match(cueTiming, lines[index].text) else {
        index += 1
        continue
      }
      // A cue number on the line above belongs to the cue.
      var start = lines[index].contentStart
      if index > 0, match(cueNumber, lines[index - 1].text) != nil {
        start = lines[index - 1].contentStart
      }
      var body: [Line] = []
      var next = index + 1
      while next < lines.count, !lines[next].text.isEmpty,
        match(cueTiming, lines[next].text) == nil
      {
        body.append(lines[next])
        next += 1
      }
      index = next
      guard let first = body.first else { continue }
      let voice =
        match(voiceTag, first.text)
        ?? match(namedCue, first.text).flatMap { isSpeakerName($0[0]) ? $0 : nil }
      guard let voice, voice.count >= 2 else { continue }
      let rest = body.dropFirst().map(\.text)
      let opening = voice[1].replacingOccurrences(of: "</v>", with: "")
        .trimmingCharacters(in: .whitespaces)
      let text = ([opening] + rest).filter { !$0.isEmpty }.joined(separator: "\n")
      guard !text.isEmpty else { continue }
      let speaker = cleanSpeaker(voice[0].trimmingCharacters(in: .whitespaces))
      // Consecutive cues of one speaker are one turn.
      if let last = turns.last, last.speaker == speaker {
        turns[turns.count - 1] = Turn(
          speaker: speaker, time: last.time, text: last.text + "\n" + text, start: last.start,
          end: body.last?.contentEnd ?? last.end)
      } else {
        turns.append(
          Turn(
            speaker: speaker, time: normalizedTime(timing[0]), text: text, start: start,
            end: body.last?.contentEnd ?? lines[index - 1].contentEnd))
      }
    }
    return turns
  }

  // MARK: - Slicing

  /// The part of `text` between two Unicode-scalar offsets, clamped to the
  /// text; empty when the range is empty or outside it.
  public static func slice(_ text: String, start: Int, end: Int) -> String {
    let scalars = text.unicodeScalars
    let count = scalars.count
    let lower = min(max(0, start), count)
    let upper = min(max(lower, end), count)
    guard lower < upper else { return "" }
    let from = scalars.index(scalars.startIndex, offsetBy: lower)
    let to = scalars.index(from, offsetBy: upper - lower)
    return String(scalars[from..<to])
  }
}
