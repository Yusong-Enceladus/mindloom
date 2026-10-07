import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-matter. S7 · The small page (MAC-SPEC §4.9) for a matter with no
// parts: 「接下来」 · 「经过」 · 「原文」 rows (dot, date column, text).

public struct MatterSmallPageInput: Equatable, Sendable {
  public let matter: MatterDigest
  public let memberView: Bool

  public init(matter: MatterDigest, memberView: Bool = false) {
    self.matter = matter
    self.memberView = memberView
  }
}

/// One row of the small page.
struct SmallPageRow: Equatable, Identifiable {
  enum Glyph: Equatable {
    case done
    case minor
    case next
    case due
    case over
  }

  /// Days from today; nil for undated (「待定」).
  let day: Int?
  let text: String
  let glyph: Glyph
  /// The step it opens, if a step backs it.
  let stepID: String?

  var id: String { stepID ?? "\(day ?? 99_999)|\(text)" }

  /// 接下来 and 经过, as the prototype's `smallDoc()`.
  static func rows(_ matter: MatterDigest, today: Date, calendar: Calendar) -> (
    next: [SmallPageRow], past: [SmallPageRow]
  ) {
    func day(_ date: Date) -> Int { MemoryDigest.days(from: today, to: date, calendar: calendar) }
    var next: [SmallPageRow] = []
    var past: [SmallPageRow] = []
    for step in matter.steps where !(step.isOpenQuestion && !step.isDone) {
      let n = day(step.date)
      if step.over && !step.isDone {
        next.append(SmallPageRow(day: n, text: step.text, glyph: .over, stepID: step.id))
      } else if step.isDone || n < 0 {
        past.append(SmallPageRow(day: n, text: step.text, glyph: .done, stepID: step.id))
      } else {
        next.append(
          SmallPageRow(day: n, text: step.text, glyph: step.due ? .due : .next, stepID: step.id))
      }
    }
    // Open questions are undated: 「待定」 under 接下来.
    for step in matter.steps where step.isOpenQuestion && !step.isDone {
      next.append(SmallPageRow(day: nil, text: step.text, glyph: .next, stepID: step.id))
    }
    // A fact that says what a step on the same day says (「报告提交」 beside
    // 「交报告」, both 10月7日) is that step (live-mac).
    func same(_ rows: [SmallPageRow], _ n: Int?, _ text: String) -> Bool {
      let words = MemoryDisplayText.bigrams(text)
      return rows.contains {
        $0.text == text || ($0.day == n && n != nil && !MemoryDisplayText.bigrams($0.text).isDisjoint(with: words))
      }
    }
    for fact in matter.facts {
      let n = fact.date.map(day)
      let planned = fact.state == .planned || fact.state == .inProgress
      if planned, let n, n < 0 {
        if !same(past, n, fact.text) {
          past.append(SmallPageRow(day: n, text: fact.text, glyph: .minor, stepID: nil))
        }
      } else if planned {
        if !same(next, n, fact.text) {
          next.append(
            SmallPageRow(
              day: n, text: fact.text, glyph: n.map { $0 <= 1 } ?? false ? .due : .next, stepID: nil
            ))
        }
      } else if let n, fact.state != .cancelled, !same(past, n, fact.text) {
        past.append(SmallPageRow(day: n, text: fact.text, glyph: .done, stepID: nil))
      }
    }
    next.sort { ($0.day ?? Int.max, $0.text) < ($1.day ?? Int.max, $1.text) }
    past.sort { ($0.day ?? 0) > ($1.day ?? 0) }
    return (next, past)
  }
}

public struct MatterSmallPage: View {
  let context: MindloomPageContext
  let input: MatterSmallPageInput

  public init(context: MindloomPageContext, input: MatterSmallPageInput) {
    self.context = context
    self.input = input
  }

  public var body: some View {
    let state = context.state
    let rows = SmallPageRow.rows(input.matter, today: state.today, calendar: state.calendar)
    // Up to three items (one entry per item, even when it holds several parts).
    var seen = Set<String>()
    let texts = Array(
      state.matterTexts(input.matter.eventID, memberView: input.memberView)
        .filter { seen.insert($0.itemID).inserted }.prefix(3))
    let selected: String? = {
      if case .step(let id)? = context.navigation.popover { return id }
      return nil
    }()
    VStack(alignment: .leading, spacing: 0) {
      if !rows.next.isEmpty {
        header("接下来", first: true)
        ForEach(rows.next) { SmallRow(context: context, row: $0, selected: selected == $0.stepID) }
      }
      if !rows.past.isEmpty {
        header("经过", first: rows.next.isEmpty)
        ForEach(rows.past) { SmallRow(context: context, row: $0, selected: selected == $0.stepID) }
      }
      if !texts.isEmpty {
        header("原文", first: rows.next.isEmpty && rows.past.isEmpty)
        ForEach(texts) { entry in
          MatterTextItem(
            context: context, eventID: input.matter.eventID, entry: entry, withDay: true,
            highlighted: false, actions: !input.memberView)
        }
      }
      if rows.next.isEmpty && rows.past.isEmpty && texts.isEmpty {
        Text("这件事尚无原文。")
          .mlFont(\.sub, lineBox: true)
          .foregroundStyle(MLColor.ink2)
          .frame(maxWidth: .infinity)
          .padding(.top, 60)
      }
    }
    .frame(maxWidth: 680, alignment: .leading)
    .padding(.top, 26)
  }

  private func header(_ title: String, first: Bool) -> some View {
    Text(title)
      .mlFont(\.section, lineBox: true)
      .foregroundStyle(MLColor.ink2)
      .padding(.top, first ? 0 : 20)
      .padding(.bottom, 6)
      .accessibilityAddTraits(.isHeader)
  }
}

private struct SmallRow: View {
  let context: MindloomPageContext
  let row: SmallPageRow
  let selected: Bool
  @State private var hovering = false

  private var dateWords: (String, Bool) {
    let state = context.state
    guard let n = row.day,
      let date = state.calendar.date(byAdding: .day, value: n, to: state.today)
    else { return ("待定", false) }
    let md = MindloomDates.monthDay(date, calendar: state.calendar)
    switch row.glyph {
    case .over: return (md + " 已过期", true)
    case .done, .minor: return (md, false)
    case .next, .due:
      if let word = MindloomDates.dueWord(date, today: state.today, calendar: state.calendar) {
        return (word, row.glyph == .due)
      }
      return (md, false)
    }
  }

  var body: some View {
    let (date, alert) = dateWords
    let content = HStack(alignment: .firstTextBaseline, spacing: 8) {
      MLStatusCircle(
        row.glyph == .done || row.glyph == .minor
          ? .done : row.glyph == .next ? .next : .due
      )
      .frame(width: 14, alignment: .leading)
      .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
      Text(date)
        .mlFont(\.sub, lineBox: true)
        .monospacedDigit()
        .foregroundStyle(alert ? MLColor.alert : MLColor.ink2)
        .frame(width: 96, alignment: .leading)
      Text(MLAutospace.apply(row.text))
        .mlFont(\.body, lineBox: true)
        .foregroundStyle(MLColor.ink)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 5)
    .padding(.horizontal, 12)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill((hovering || selected) && row.stepID != nil ? MLColor.fill2 : MLColor.transparent)
    )
    .contentShape(Rectangle())
    .padding(.horizontal, -12)
    if let stepID = row.stepID {
      Button {
        context.navigator.openPopover(selected ? nil : .step(stepID))
      } label: {
        content
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .matterAnchor(["step:\(stepID)", "q:\(stepID)"])
      .accessibilityLabel(date + " " + MLAutospace.apply(row.text))
    } else {
      content.accessibilityElement(children: .combine)
    }
  }
}
