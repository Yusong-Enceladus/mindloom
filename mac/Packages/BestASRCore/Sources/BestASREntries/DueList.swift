import BestASRMemory
import Foundation

/// 织机：今天到期 (Shortcuts, V8 contract A2) and `mindloom due` (A3): the
/// planned steps dated today (or within the next `days`), plus the ones a
/// week overdue, read from the memory pages' own projection on this Mac.
/// Read-only; nothing leaves the Mac and nothing is changed.
public struct DueEntry: Equatable, Sendable {
  public let day: DateComponents
  public let text: String
  public let matterID: String
  public let matterTitle: String
  public let overdue: Bool

  public init(
    day: DateComponents, text: String, matterID: String, matterTitle: String, overdue: Bool
  ) {
    self.day = day
    self.text = text
    self.matterID = matterID
    self.matterTitle = matterTitle
    self.overdue = overdue
  }
}

public enum DueList {
  public static let overdueDays = 7

  public static func entries(
    _ projection: MemoryProjection, now: Date, days: Int = 0, timeZone: TimeZone = .current
  ) -> [DueEntry] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    func number(_ components: DateComponents) -> Int? {
      guard let year = components.year, let month = components.month, let day = components.day
      else { return nil }
      return year * 10_000 + month * 100 + day
    }
    func number(daysFromToday offset: Int) -> Int {
      let date = calendar.date(byAdding: .day, value: offset, to: now) ?? now
      return number(calendar.dateComponents([.year, .month, .day], from: date)) ?? 0
    }
    let today = number(daysFromToday: 0)
    let first = number(daysFromToday: -overdueDays)
    let last = number(daysFromToday: max(0, min(days, 30)))
    var result: [(Int, Int, DueEntry)] = []
    var order = 0
    for matter in projection.home() {
      let facts =
        projection.events.first {
          $0.eventID.caseInsensitiveCompare(matter.eventID) == .orderedSame
        }?.statusFacts ?? []
      for fact in facts where fact.state == .planned {
        guard let day = fact.day, let value = number(day), value >= first, value <= last else {
          continue
        }
        order += 1
        result.append(
          (
            value, order,
            DueEntry(
              day: day, text: fact.text, matterID: matter.eventID, matterTitle: matter.title,
              overdue: value < today)
          ))
      }
    }
    return result.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
  }

  /// The plain-Chinese answer: a heading, then one line per step.
  public static func render(_ entries: [DueEntry], days: Int) -> (heading: String, lines: [String])
  {
    let span = days <= 0 ? "今天" : "接下来 \(days) 天"
    guard !entries.isEmpty else { return ("\(span)没有到期的事。", []) }
    let lines = entries.map { entry in
      let day = String(
        format: "%d月%d日", entry.day.month ?? 0, entry.day.day ?? 0)
      return
        "· \(day)\(entry.overdue ? "（已过期）" : "") \(oneLine(entry.text)) — \(oneLine(entry.matterTitle))"
    }
    let overdue = entries.filter(\.overdue).count
    let heading =
      overdue > 0
      ? "\(span)到期 \(entries.count - overdue) 件，另有 \(overdue) 件已过期："
      : "\(span)到期 \(entries.count) 件："
    return (heading, lines)
  }

  static func oneLine(_ text: String) -> String {
    text.components(separatedBy: .newlines).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
