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

  var id: String { "\(eventID)|\(itemID.uppercased())|\(turnIndex)" }
}

enum PersonQuotes {
  /// Lines the section shows.
  static let limit = 5
  /// Lines one matter gives while other matters still have some.
  static let perEvent = 2
  /// Shorter lines ("好的。") say nothing on their own.
  static let minimumLength = 4

  /// The person's newest lines across their events, newest first; empty
  /// when no turn is theirs.
  @MainActor
  static func quotes(
    of person: MemoryPersonEntry, in projection: MemoryProjection, limit: Int = limit
  ) -> [PersonQuote] {
    let wanted = projection.canonicalPersonID(person.personID).uppercased()
    var seen = Set<String>()
    var all: [PersonQuote] = []
    for entry in person.events {
      guard let detail = projection.event(id: entry.eventID) else { continue }
      for item in detail.items {
        guard let record = item.record else { continue }
        let turns = TranscriptPreview(item: item, expanded: true, people: detail.people).turns
        for (index, turn) in turns.enumerated() {
          guard let speaker = turn.personID,
            projection.canonicalPersonID(speaker).uppercased() == wanted
          else { continue }
          let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
          // An item two events hold gives its lines once.
          guard text.count >= minimumLength,
            seen.insert("\(item.itemID.uppercased())|\(text)").inserted
          else { continue }
          let date = item.startedAt.map { start in
            turn.offsetMilliseconds.map { start.addingTimeInterval(Double($0) / 1_000) } ?? start
          }
          all.append(
            PersonQuote(
              eventID: detail.eventID, eventTitle: detail.title, itemID: item.itemID, rowID: item.id,
              text: text,
              date: date, source: source(of: record), turnIndex: index))
        }
      }
    }
    // At most `perEvent` from one matter, then the rest fill what is left.
    var picked: [PersonQuote] = []
    var rest: [PersonQuote] = []
    var fromEvent: [String: Int] = [:]
    for quote in all.sorted(by: newerFirst) {
      if picked.count < limit, fromEvent[quote.eventID, default: 0] < perEvent {
        picked.append(quote)
        fromEvent[quote.eventID, default: 0] += 1
      } else {
        rest.append(quote)
      }
    }
    picked += rest.prefix(max(0, limit - picked.count))
    return picked.sorted(by: newerFirst)
  }

  static func newerFirst(_ a: PersonQuote, _ b: PersonQuote) -> Bool {
    let left = a.date ?? .distantPast
    let right = b.date ?? .distantPast
    if left != right { return left > right }
    if a.itemID == b.itemID, a.turnIndex != b.turnIndex { return a.turnIndex > b.turnIndex }
    return a.id < b.id
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
