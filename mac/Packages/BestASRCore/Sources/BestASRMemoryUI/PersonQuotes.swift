import BestASRDomain
import BestASRMemory
import SwiftUI

/// One thing a person said, for the Person page's 说过的话: their own words
/// from a speaker turn (a recording's speakers, a meeting transcript, a
/// pasted chat or a screenshot's reading), read exactly as the event page's
/// transcript reads them.
struct PersonQuote: Equatable, Identifiable {
  let eventID: String
  let eventTitle: String
  let itemID: String
  /// The event page's row it is in (the item, or the part of it this event
  /// holds), to open the matter with that row expanded.
  let rowID: String
  let text: String
  /// When it was said: the item's time, plus the turn's start in a recording.
  let date: Date?
  /// Where it came from (腾讯会议, 企业微信, 当面 …).
  let source: String
  /// The turn's place in its item.
  let turnIndex: Int
  /// Said aloud (a recording or a meeting transcript), not written in a chat.
  var spoken = false

  var id: String { "\(eventID)|\(itemID.uppercased())|\(turnIndex)" }
}

enum PersonQuotes {
  /// Lines the section shows, each from a different matter.
  static let limit = 5
  /// Lines with fewer letters and digits ("好的。") say nothing on their own.
  static let minimumLength = 4
  /// Lines with at least this many letters and digits say something; a
  /// shorter one is shown only when a matter has nothing longer.
  static let substantiveLength = 8

  /// One line from each of the person's most important matters, in that
  /// order; empty when no turn is theirs.
  ///
  /// A matter gives its best line: a substantive one before a short one,
  /// then one said aloud (a recording, a meeting transcript) before one
  /// written in a chat, then one that names the matter (see `names`) before
  /// a meeting's small talk, then the newest. A greeting, thanks or an
  /// acknowledgement ("收到，谢谢老师") is never a line.
  ///
  /// Matters with a substantive line come before the rest, pinned ones
  /// first; then by the sum of two places among the person's matters: its
  /// place in Home (pins, the organizer's importance, recency) and its place
  /// by how many of its items hold the person's words, so the work they
  /// carry comes before a matter they only passed through. Home order breaks
  /// ties.
  @MainActor
  static func quotes(
    of person: MemoryPersonEntry, in projection: MemoryProjection, limit: Int = limit
  ) -> [PersonQuote] {
    let wanted = projection.canonicalPersonID(person.personID).uppercased()
    // `person.events` is in Home order: a matter's index is its Home place.
    var matters: [Matter] = []
    for entry in person.events {
      guard let detail = projection.event(id: entry.eventID) else { continue }
      var lines: [Line] = []
      var theirItems = Set<String>()
      let terms = titleTerms(detail.title, leaving: detail.people.map(\.name))
      let factQuotes = detail.statusFacts.compactMap(\.quote)
      for item in detail.items {
        guard let record = item.record else { continue }
        let turns = TranscriptPreview(item: item, expanded: true, people: detail.people).turns
        for (index, turn) in turns.enumerated() {
          guard let speaker = turn.personID,
            projection.canonicalPersonID(speaker).uppercased() == wanted
          else { continue }
          theirItems.insert(item.itemID.uppercased())
          let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
          let length = words(text).count
          guard length >= minimumLength, !isFiller(text) else { continue }
          let date = item.startedAt.map { start in
            turn.offsetMilliseconds.map { start.addingTimeInterval(Double($0) / 1_000) } ?? start
          }
          lines.append(
            Line(
              quote: PersonQuote(
                eventID: detail.eventID, eventTitle: detail.title, itemID: item.itemID,
                rowID: item.id, text: text, date: date, source: source(of: record),
                turnIndex: index, spoken: turn.spoken),
              substantive: length >= substantiveLength,
              names: names(text, terms: terms, factQuotes: factQuotes)))
        }
      }
      guard !lines.isEmpty else { continue }
      matters.append(
        Matter(pinned: entry.pinned, items: theirItems.count, lines: lines.sorted(by: better)))
    }
    for (place, index) in matters.indices.sorted(by: {
      matters[$0].items != matters[$1].items ? matters[$0].items > matters[$1].items : $0 < $1
    }).enumerated() {
      matters[index].itemPlace = place
    }
    let order = matters.indices.sorted { a, b in
      let left = matters[a]
      let right = matters[b]
      if left.substantive != right.substantive { return left.substantive }
      if left.pinned != right.pinned { return left.pinned }
      let leftRank = a + left.itemPlace
      let rightRank = b + right.itemPlace
      return leftRank != rightRank ? leftRank < rightRank : a < b
    }
    // A line two matters hold (one item filed in both) is shown once, for
    // the first of them.
    var shown = Set<String>()
    var picked: [PersonQuote] = []
    for index in order where picked.count < limit {
      guard let line = matters[index].lines.first(where: { !shown.contains(words($0.quote.text)) })
      else { continue }
      shown.insert(words(line.quote.text))
      picked.append(line.quote)
    }
    return picked
  }

  private struct Line {
    let quote: PersonQuote
    let substantive: Bool
    let names: Bool
  }

  private struct Matter {
    let pinned: Bool
    /// Items of the matter holding a turn of theirs.
    let items: Int
    /// Best first.
    let lines: [Line]
    /// Place by `items` among the person's matters (0 is the most).
    var itemPlace = 0

    var substantive: Bool { lines.first?.substantive ?? false }
  }

  private static func better(_ a: Line, _ b: Line) -> Bool {
    if a.substantive != b.substantive { return a.substantive }
    if a.quote.spoken != b.quote.spoken { return a.quote.spoken }
    if a.names != b.names { return a.names }
    return newerFirst(a.quote, b.quote)
  }

  /// The words of a matter's title a line can name it by: its Latin words
  /// and numbers of two or more characters ("RoboPrior", "80") and each pair
  /// of adjacent Chinese characters ("夹爪", "中期"), lower-cased, less the
  /// pairs in its people's names.
  static func titleTerms(_ title: String, leaving names: [String]) -> Set<String> {
    var terms = Set<String>()
    var latin = ""
    var han: [Character] = []
    func flush() {
      if latin.count >= 2 { terms.insert(latin) }
      for index in han.indices.dropLast() { terms.insert(String(han[index...index + 1])) }
      latin = ""
      han = []
    }
    for character in title.lowercased() {
      if character.isASCII, character.isLetter || character.isNumber {
        if !han.isEmpty { flush() }
        latin.append(character)
      } else if character.isLetter {
        if !latin.isEmpty { flush() }
        han.append(character)
      } else {
        flush()
      }
    }
    flush()
    return terms.filter { term in !names.contains { $0.lowercased().contains(term) } }
  }

  /// The line names its matter: a word of its title, or a clause the
  /// organizer quoted for one of its facts.
  static func names(_ text: String, terms: Set<String>, factQuotes: [String]) -> Bool {
    let line = text.lowercased()
    if terms.contains(where: { line.contains($0) }) { return true }
    let said = words(text)
    return factQuotes.contains { quote in
      let clause = words(quote)
      return clause.count >= minimumLength && said.contains(clause)
    }
  }

  static func newerFirst(_ a: PersonQuote, _ b: PersonQuote) -> Bool {
    let left = a.date ?? .distantPast
    let right = b.date ?? .distantPast
    if left != right { return left > right }
    if a.itemID == b.itemID, a.turnIndex != b.turnIndex { return a.turnIndex > b.turnIndex }
    return a.id < b.id
  }

  /// The letters and digits of a line, lower-cased: what its length counts.
  static func words(_ text: String) -> String {
    String(text.filter { $0.isLetter || $0.isNumber }).lowercased()
  }

  /// Greetings, thanks, acknowledgements, and the words that go with them;
  /// longest first so "好的" is taken before "好".
  static let fillers: [String] = [
    "你好", "您好", "大家好", "早上好", "上午好", "中午好", "下午好", "晚上好", "早安", "午安", "晚安",
    "在吗", "在的", "在", "早", "哈喽", "嗨", "hi", "hello", "hey",
    "谢谢", "多谢", "感谢", "谢了", "辛苦了", "辛苦啦", "辛苦", "thanks", "thankyou", "thx",
    "好的", "好滴", "好嘞", "好哒", "好吧", "好", "行", "嗯", "哦", "噢", "喔", "啊", "呀", "哈", "嘿",
    "对的", "对", "是的", "是", "收到", "明白", "了解", "知道了", "没问题", "可以", "ok", "okay",
    "拜拜", "再见", "回头见", "散会", "了", "啦", "呢", "吧", "老师", "老板", "大家", "各位",
  ].sorted { $0.count > $1.count }

  /// A line made only of `fillers` ("收到，谢谢老师", "好的好的").
  static func isFiller(_ text: String) -> Bool {
    var rest = Substring(words(text))
    while !rest.isEmpty {
      guard let filler = fillers.first(where: { rest.hasPrefix($0) }) else { return false }
      rest = rest.dropFirst(filler.count)
    }
    return true
  }

  /// The App or meeting it came from; a room recording is 当面.
  static func source(of record: MemoryItemRecord) -> String {
    record.inputMode == .roomMicrophone ? ZhijiCopy.inPerson : record.sourceLabel
  }
}

/// 说过的话: the lines in one hairline card, each with a tick in the
/// person's colour, when and where it was said, and its matter as a chip;
/// a row opens that matter with its row expanded.
struct PersonQuotesList: View {
  @Environment(\.zhiji) private var palette
  let quotes: [PersonQuote]
  let colorIndex: Int
  let state: MemoryScreenState
  let openAt: (_ eventID: String, _ rows: [String]) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(quotes.enumerated()), id: \.element.id) { index, quote in
        if index > 0 {
          Rectangle().fill(palette.hairline).frame(height: 1).padding(.leading, 31)
        }
        row(quote)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: ZhijiMetrics.cardRadius, style: .continuous)
        .strokeBorder(palette.separator.opacity(0.8))
    )
  }

  private func row(_ quote: PersonQuote) -> some View {
    HStack(alignment: .top, spacing: 14) {
      RoundedRectangle(cornerRadius: 2)
        .fill(palette.person(colorIndex))
        .frame(width: 3)
      VStack(alignment: .leading, spacing: 5) {
        Text(quote.text)
          .font(.zhiji(14))
          .foregroundStyle(palette.label)
          .lineSpacing(3)
          .lineLimit(2)
          .truncationMode(.tail)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Text(meta(quote)).metaStyle(palette).lineLimit(1).fixedSize()
          Text(quote.eventTitle)
            .font(.zhiji(11))
            .foregroundStyle(palette.label)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(palette.quietFill, in: Capsule())
        }
      }
      Spacer(minLength: 0)
    }
    // The tick is as tall as the text, not as the space offered.
    .fixedSize(horizontal: false, vertical: true)
    .padding(.vertical, 10)
    .padding(.horizontal, 14)
    .contentShape(Rectangle())
    .zhijiActivatable { openAt(quote.eventID, [quote.rowID]) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(quote.text)，\(meta(quote))，\(quote.eventTitle)")
    .accessibilityAddTraits(.isButton)
  }

  private func meta(_ quote: PersonQuote) -> String {
    var parts: [String] = []
    if let date = quote.date { parts.append("\(state.day(date)) \(state.time(date))") }
    parts.append(quote.source)
    return parts.joined(separator: " · ")
  }
}
