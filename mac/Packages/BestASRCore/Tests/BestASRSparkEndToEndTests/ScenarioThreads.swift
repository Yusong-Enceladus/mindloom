import BestASRDomain
import Foundation

/// Which organizer event stands for a scenario's ground-truth event: the one
/// holding the majority of its items, counting the parts of split items.
///
/// Every item the scenario lists under the truth event carries one vote:
/// - held whole by one event: the vote goes there (shared if several hold it);
/// - held in parts: the scenario's own quotes for this truth event, located in
///   the item's text as sent, give the vote to the events whose parts overlap
///   them, by characters of overlap; without a located quote the holders of
///   its parts share it equally;
/// - in Unfiled or not organized: no vote (it lowers the winner's share).
/// Ties go to the better Home rank.
enum ScenarioThreads {
  struct Member {
    let ref: String
    /// Upper-case local item ID.
    let id: String
    /// The item's text as sent (nil for a screenshot).
    let text: String?
    /// The scenario's quotes for the truth event in this item.
    let quotes: [String]
  }

  struct Choice: Equatable {
    let truthEvent: String
    let members: Int
    let eventID: String?
    /// Votes for the chosen event over all members (0…1).
    let share: Double
    /// Organizer events that received any vote.
    let holders: Int
  }

  static func choose(
    truthEvent: String, members: [Member], events: [RemoteOrganizerEvent], rank: [String: Int]
  ) -> Choice {
    let live = events.filter { !$0.deleted }
    var votes: [String: Double] = [:]
    for member in members {
      var pieces: [(eventID: String, start: Int, end: Int)] = []
      var whole: [String] = []
      for event in live {
        let parts = event.segments.filter { $0.itemID.uppercased() == member.id }
        if !parts.isEmpty {
          pieces += parts.map { (event.eventID, $0.start, $0.end) }
        } else if event.itemIDs.contains(where: { $0.uppercased() == member.id }) {
          whole.append(event.eventID)
        }
      }
      if pieces.isEmpty {
        for eventID in whole { votes[eventID, default: 0] += 1 / Double(whole.count) }
        continue
      }
      // An event holding the whole item holds every quote too.
      pieces += whole.map { ($0, 0, Int.max) }
      let ranges =
        member.text.map { text in member.quotes.compactMap { locate($0, in: text) } }
        ?? []
      var weights: [String: Double] = [:]
      for range in ranges {
        var overlaps: [String: Double] = [:]
        for piece in pieces {
          let overlap = min(range.upperBound, piece.end) - max(range.lowerBound, piece.start)
          if overlap > 0 { overlaps[piece.eventID, default: 0] += Double(overlap) }
        }
        let total = overlaps.values.reduce(0, +)
        guard total > 0 else { continue }
        for (eventID, overlap) in overlaps {
          weights[eventID, default: 0] += overlap / total / Double(ranges.count)
        }
      }
      if weights.isEmpty {
        let holders = Set(pieces.map(\.eventID))
        for eventID in holders { weights[eventID] = 1 / Double(holders.count) }
      } else {
        // Quotes that overlapped nothing leave part of the vote unassigned.
        let assigned = weights.values.reduce(0, +)
        if assigned < 1 { weights = weights.mapValues { $0 / assigned } }
      }
      for (eventID, weight) in weights { votes[eventID, default: 0] += weight }
    }
    let best = votes.max { a, b in
      if abs(a.value - b.value) > 1e-9 { return a.value < b.value }
      let (ra, rb) = (rank[a.key] ?? .max, rank[b.key] ?? .max)
      return ra != rb ? ra > rb : a.key > b.key
    }
    return Choice(
      truthEvent: truthEvent, members: members.count, eventID: best?.key,
      share: members.isEmpty ? 0 : (best?.value ?? 0) / Double(members.count),
      holders: votes.filter { $0.value > 0 }.count)
  }

  /// The quote's place in `text` as Unicode-scalar offsets (the organizer's
  /// segment unit): exact, else trimmed, else its longest line.
  static func locate(_ quote: String, in text: String) -> Range<Int>? {
    let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
    let longest =
      trimmed.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }.max { $0.count < $1.count } ?? ""
    for candidate in [quote, trimmed, longest] where candidate.count >= 4 {
      if let found = text.range(of: candidate) {
        let start = text[..<found.lowerBound].unicodeScalars.count
        return start..<(start + text[found].unicodeScalars.count)
      }
    }
    return nil
  }

  /// A truth event ID as part of a file name.
  static func fileSafe(_ value: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    let mapped = String(value.map { allowed.contains($0) ? $0 : "_" })
    return mapped.isEmpty ? "event" : mapped
  }
}
