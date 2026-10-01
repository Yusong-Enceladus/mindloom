import Foundation

/// Who writes in a pasted chat or a transcript text: the names in speaker
/// lines ("名：…", "[08-17 12:29] 名：…", or a byline "名 10:05" on its own
/// line with the message under it). The same shapes the organizer reads
/// speakers from (`spark/organizer/persons.py`), so the Mac can tell a person
/// who takes part in a matter from one the text only names (the organizer's
/// `mention` links, which it does not send per item).
public enum MemorySpeakerLines {
  /// Every speaker label in `text`, normalized (`normalized(_:)`), each also
  /// without its remark ("周建国-装修" gives "周建国-装修" and "周建国").
  public static func labels(in text: String) -> Set<String> {
    var result = Set<String>()
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    for (index, raw) in lines.enumerated() {
      let line = String(raw)
      // Every shape has a colon (a byline's is in its time).
      guard line.contains(where: { $0 == "：" || $0 == ":" }) else { continue }
      var name: String?
      if let match = firstMatch(speakerLine, in: line), let rest = group(match, "rest", in: line),
        !rest.trimmingCharacters(in: .whitespaces).isEmpty
      {
        name = group(match, "name", in: line)
      } else if let match = firstMatch(byline, in: line), index + 1 < lines.count,
        !lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty
      {
        name = group(match, "name", in: line)
      }
      guard let name else { continue }
      let full = normalized(name)
      guard !full.isEmpty else { continue }
      result.insert(full)
      let base = normalized(baseName(name))
      if !base.isEmpty { result.insert(base) }
    }
    return result
  }

  /// A name as labels compare it: trimmed, inner spaces collapsed, Latin
  /// letters lower-cased.
  public static func normalized(_ name: String) -> String {
    name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
  }

  /// A contact name without its remark: "周建国-装修" → "周建国",
  /// "王老师（物业）" → "王老师".
  static func baseName(_ name: String) -> String {
    let stops: Set<Character> = ["-", "－", "—", "（", "("]
    let cut = name.firstIndex(where: { stops.contains($0) }) ?? name.endIndex
    return String(name[..<cut]).trimmingCharacters(in: .whitespaces)
  }

  private static let nameSource =
    #"[\x{4E00}-\x{9FFF}A-Za-z·•][\x{4E00}-\x{9FFF}A-Za-z·• \-_.]{0,15}"#
  private static let stampSource =
    #"(?:[\[【]\s*(?:(?:[0-9]{4}[-/.年])?[0-9]{1,2}[-/.月][0-9]{1,2}日?\s*)?[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?\s*[\]】]\s*)?"#

  // Both patterns are valid ICU; built once.
  private static let speakerLine = try! NSRegularExpression(
    pattern: #"^\s*"# + stampSource + "(?<name>" + nameSource + #")\s*[：:](?<rest>.*)$"#)
  private static let byline = try! NSRegularExpression(
    pattern: #"^\s*(?<name>"# + nameSource
      + #")\s+(?:[0-9]{4}[-/年.][0-9]{1,2}[-/月.][0-9]{1,2}日?\s*)?(?:(?:上午|下午|晚上|早上)\s*)?[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?\s*$"#
  )

  private static func firstMatch(_ regex: NSRegularExpression, in line: String)
    -> NSTextCheckingResult?
  {
    regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
  }

  private static func group(_ match: NSTextCheckingResult, _ name: String, in line: String)
    -> String?
  {
    let range = match.range(withName: name)
    guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else {
      return nil
    }
    return String(line[swiftRange])
  }
}
