import AppKit
import BestASRMemory
import Foundation
import MindloomDesign

/// The 进展 time view's geometry (MAC-SPEC §4.7, the prototype's `tvModel()`
/// + `layoutTimeView()`), as a pure value: lanes, the true date axis, marks,
/// labels placed without overlap, segments, the dashed future and what each
/// segment folds. Time is true: every mark sits on its own day and a deadline
/// never moves; only a finished ● gives way (12 pt) to a coming mark.
///
/// Days are whole days from today (0 = today). `measure` gives a label's
/// width in points (13 pt; medium for part names).
struct MatterTimeLayout: Equatable {
  enum Kind: Equatable {
    case done
    case next
    case due
    case over

    var status: MLStatus {
      switch self {
      case .done: .done
      case .next: .next
      case .due, .over: .due
      }
    }
  }

  struct Lane: Equatable, Identifiable {
    let id: String
    let name: String
    let summary: String
    let closed: Bool
    /// Days with items (relative to today).
    let days: [Int]
    let isOther: Bool
    var y: CGFloat = 0
  }

  struct Label: Equatable {
    /// -1 above the line, 1 below.
    let row: Int
    let x0: CGFloat
    let width: CGFloat
    /// The first step's text (autospaced).
    let text: String
    let when: String?
    let whenAlert: Bool
    let more: Int
    let squeezed: Bool
  }

  struct Mark: Equatable, Identifiable {
    let laneID: String
    var x: CGFloat
    let day: Int
    var kind: Kind
    let far: Bool
    var steps: [MatterStep]
    var label: Label?
    var id: String { steps.first?.id ?? "\(laneID)-\(day)" }

    func contains(_ stepID: String) -> Bool { steps.contains { $0.id == stepID } }
  }

  struct Segment: Equatable {
    let laneID: String
    let x0: CGFloat
    let x1: CGFloat
    /// The first active day, for 「{M月D日}起」.
    let firstDay: Int
    /// Steps folded into it (shown in 经过).
    let folded: Int
  }

  struct DashedLine: Equatable {
    let laneID: String
    let x0: CGFloat
    let x1: CGFloat
  }

  struct AxisLabel: Equatable {
    let x: CGFloat
    let day: Int
  }

  static let axisY: CGFloat = 30
  static let pitch: CGFloat = 68
  static let firstLaneY: CGFloat = 70

  let width: CGFloat
  let nameColumn: CGFloat
  let start: Int
  let near: Int
  let l0: CGFloat
  let l1: CGFloat
  let farX: CGFloat
  let todayX: CGFloat
  var lanes: [Lane]
  var marks: [Mark] = []
  var segments: [Segment] = []
  var dashes: [DashedLine] = []
  var axis: [AxisLabel] = []
  /// Lane ID → finished steps folded into its segment, newest first.
  var folded: [String: [MatterStep]] = [:]
  /// Lane ID → coming steps beyond the two marks a lane shows.
  var later: [String: [MatterStep]] = [:]
  /// 待定: open questions, by when they were asked.
  let open: [MatterStep]
  /// Step ID → its lane, for steps on the axis.
  let laneOf: [String: String]

  var height: CGFloat { Self.firstLaneY + Self.pitch * CGFloat(max(0, lanes.count - 1)) + 34 }

  func x(_ day: Int) -> CGFloat {
    l0 + CGFloat(day - start) / CGFloat(max(1, near - start)) * (l1 - l0)
  }

  func lane(_ id: String) -> Lane? { lanes.first { $0.id == id } }

  /// The mark holding a step, if it is drawn.
  func mark(holding stepID: String) -> Mark? { marks.first { $0.contains(stepID) } }

  /// Everything folded in a lane's segment (finished and later), newest first.
  func foldedSteps(_ laneID: String) -> [MatterStep] {
    ((folded[laneID] ?? []) + (later[laneID] ?? [])).sorted { $0.date > $1.date }
  }

  /// The lane's y (the centre of its line).
  func y(of laneID: String) -> CGFloat { lane(laneID)?.y ?? 0 }

  // MARK: - Build

  /// - Parameters:
  ///   - width: the page content width (884 at the default window size).
  ///   - measure: a label's width at 13 pt (`medium` for part names).
  init(
    matter: MatterDigest, width: CGFloat, today: Date, calendar: Calendar,
    measure: (String, _ medium: Bool) -> CGFloat = MatterTimeLayout.measure
  ) {
    func day(_ date: Date) -> Int { MemoryDigest.days(from: today, to: date, calendar: calendar) }
    self.width = width
    let isOpen: (MatterStep) -> Bool = { $0.isOpenQuestion && !$0.isDone }
    var lanes = matter.parts.map {
      Lane(
        id: $0.id, name: $0.name, summary: $0.summary, closed: $0.closed, days: $0.days.map(day),
        isOther: false)
    }
    var laneOf: [String: String] = [:]
    let onAxis = matter.steps.filter { !isOpen($0) }
    let known = Set(lanes.map(\.id))
    let orphans = onAxis.filter { $0.partID.map { !known.contains($0) } ?? true }
    if !orphans.isEmpty {
      if lanes.count == 1 {
        for step in orphans { laneOf[step.id] = lanes[0].id }
      } else {
        lanes.append(
          Lane(id: "_m", name: "其他", summary: "", closed: false, days: [], isOther: true))
        for step in orphans { laneOf[step.id] = "_m" }
      }
    }
    for step in onAxis where laneOf[step.id] == nil { laneOf[step.id] = step.partID }
    self.laneOf = laneOf
    open = matter.steps.filter(isOpen).sorted {
      ($0.evidence?.time ?? $0.date, $0.id) < ($1.evidence?.time ?? $1.date, $1.id)
    }

    let nameWidth = lanes.map { measure(MLAutospace.apply($0.name), true) }.max() ?? 0
    let g = (max(120, min(200, nameWidth + 32))).rounded()
    nameColumn = g
    let near = 14
    self.near = near
    let farSteps = onAxis.filter { day($0.date) > near }
    let allDays =
      lanes.flatMap(\.days) + onAxis.map { day($0.date) }.filter { $0 <= near }
      + [matter.firstDay.map(day) ?? 0]
    let start = (allDays.min() ?? 0) - 1
    self.start = start
    l0 = g + 12
    l1 = width - (farSteps.isEmpty ? 12 : 56)
    farX = width - 8
    let l0 = self.l0
    let l1 = self.l1
    func xOf(_ n: Int) -> CGFloat {
      l0 + CGFloat(n - start) / CGFloat(max(1, near - start)) * (l1 - l0)
    }
    let todayX = xOf(0)
    self.todayX = todayX
    for index in lanes.indices {
      lanes[index].y = Self.firstLaneY + Self.pitch * CGFloat(index)
    }
    self.lanes = lanes

    let dueID = matter.due(today: today, calendar: calendar)?.id
    var marks: [Mark] = []
    for lane in lanes {
      let steps = onAxis.filter { laneOf[$0.id] == lane.id }
      let past = steps.filter { $0.isDone || $0.glyph == .minor || (day($0.date) < 0 && !$0.over) }
        .sorted {
          let a = day($0.date)
          let b = day($1.date)
          if a != b { return a > b }
          return ($0.kind == "decision" ? 1 : 0) > ($1.kind == "decision" ? 1 : 0)
        }
      let pastIDs = Set(past.map(\.id))
      let future = steps.filter { !pastIDs.contains($0.id) }.sorted {
        (day($0.date), $0.id) < (day($1.date), $1.id)
      }
      var laneMarks: [Mark] = []
      if let newest = past.first {
        let d = day(newest.date)
        laneMarks.append(
          Mark(
            laneID: lane.id, x: xOf(d), day: d, kind: .done, far: false,
            steps: past.filter { day($0.date) == d }))
        folded[lane.id] = past.filter { day($0.date) != d }
      } else {
        folded[lane.id] = []
      }
      for step in future where day(step.date) <= near {
        let n = day(step.date)
        let kind: Kind =
          step.over ? .over : ((step.due || step.id == dueID) && n <= 1) ? .due : .next
        if let index = laneMarks.lastIndex(where: { $0.kind != .done }),
          abs(xOf(n) - laneMarks[index].x) < 14
        {
          laneMarks[index].steps.append(step)
          if kind != .next { laneMarks[index].kind = kind }
          continue
        }
        if laneMarks.filter({ $0.kind != .done }).count >= 2 {
          later[lane.id, default: []].append(step)
          continue
        }
        laneMarks.append(
          Mark(laneID: lane.id, x: xOf(n), day: n, kind: kind, far: false, steps: [step]))
      }
      let farHere = future.filter { day($0.date) > near }
      if let first = farHere.first {
        laneMarks.append(
          Mark(
            laneID: lane.id, x: farX, day: day(first.date), kind: .next, far: true, steps: farHere))
      }
      // A finished step on the day of a coming one gives way: a deadline never moves.
      if let doneIndex = laneMarks.firstIndex(where: { $0.kind == .done }) {
        for other in laneMarks
        where other.kind != .done && abs(other.x - laneMarks[doneIndex].x) < 12 {
          laneMarks[doneIndex].x = other.x - 12
        }
      }
      marks += laneMarks
    }

    // Labels: coming marks first, left to right; finished ones last.
    let order = marks.indices.sorted { a, b in
      let ka = marks[a].kind == .done ? 1 : 0
      let kb = marks[b].kind == .done ? 1 : 0
      return ka != kb ? ka < kb : marks[a].x < marks[b].x
    }
    struct Placed {
      let laneID: String
      let row: Int
      let x0: CGFloat
      let x1: CGFloat
    }
    var placed: [Placed] = []
    for index in order {
      let mark = marks[index]
      guard let first = mark.steps.first else { continue }
      let more = mark.steps.count - 1
      var when: String?
      var alert = false
      switch mark.kind {
      case .done:
        break
      case .over:
        when = MindloomDates.monthDay(first.date, calendar: calendar) + " 已过期"
        alert = true
      case .due, .next:
        if let word = MindloomDates.dueWord(first.date, today: today, calendar: calendar) {
          when = word
          alert = mark.kind == .due
        } else {
          when = MindloomDates.monthDay(first.date, calendar: calendar)
        }
      }
      let text = MLAutospace.apply(first.text)
      var w = measure(text, false) + 6
      if let when { w += 8 + measure(when, false) }
      if more > 0 { w += 8 + measure("另 \(more) 条", false) }
      var candidates: [(row: Int, x0: CGFloat)] = []
      for row in [-1, 1] {
        if mark.kind == .done {
          candidates += [(row, mark.x + 4 - w), (row, g + 4)]
        } else if mark.far {
          candidates += [(row, width - w)]
        } else {
          candidates += [(row, mark.x - 4), (row, width - w)]
        }
      }
      var chosen: (row: Int, x0: CGFloat)?
      for candidate in candidates {
        let x0 = candidate.x0
        let x1 = x0 + w
        if x0 < g + 2 || x1 > width + 0.5 { continue }
        if x0 > mark.x + 6 || x1 < mark.x - 6 { continue }
        if mark.kind == .done, x1 > todayX + 6, mark.x < todayX - 1 { continue }
        if placed.contains(where: {
          $0.laneID == mark.laneID && $0.row == candidate.row && x0 < $0.x1 + 12 && x1 > $0.x0 - 12
        }) {
          continue
        }
        chosen = candidate
        break
      }
      let squeezed = chosen == nil
      let row = chosen?.row ?? 1
      let x0 =
        chosen?.x0
        ?? max(g + 4, min(width - w, mark.kind == .done ? mark.x + 4 - w : mark.x - 4))
      placed.append(Placed(laneID: mark.laneID, row: row, x0: x0, x1: x0 + w))
      marks[index].label = Label(
        row: row, x0: x0, width: w, text: text, when: when, whenAlert: alert, more: more,
        squeezed: squeezed)
    }
    self.marks = marks

    // Segments and the dashed future.
    for lane in lanes {
      let laneSteps = onAxis.filter { laneOf[$0.id] == lane.id }.map { day($0.date) }.filter {
        $0 <= 0
      }
      let days = (lane.days + laneSteps).filter { $0 <= 0 }
      let done = marks.first { $0.laneID == lane.id && $0.kind == .done }
      if let lo = days.min(), let hi = days.max() {
        let a = xOf(lo)
        let reach = xOf(min(0, hi))
        let b = max(a + 2, done.map { max($0.x, reach) } ?? reach)
        segments.append(
          Segment(
            laneID: lane.id, x0: a, x1: b, firstDay: lo,
            folded: (folded[lane.id]?.count ?? 0) + (later[lane.id]?.count ?? 0)))
      }
      let coming = marks.filter { $0.laneID == lane.id && $0.kind != .done }
      guard !coming.isEmpty else { continue }
      let from = done.map { $0.x > todayX ? $0.x : todayX } ?? todayX
      let nearMax = max(coming.filter { !$0.far }.map(\.x).max() ?? from, from)
      if nearMax > from { dashes.append(DashedLine(laneID: lane.id, x0: from, x1: nearMax)) }
      if coming.contains(where: \.far) {
        dashes.append(DashedLine(laneID: lane.id, x0: max(from, nearMax), x1: l1))
      }
    }

    // Axis: Mondays between start + 1 and near, clear of 今天 and the names.
    if start + 1 <= near {
      for n in (start + 1)...near {
        guard let date = calendar.date(byAdding: .day, value: n, to: today),
          calendar.component(.weekday, from: date) == 2
        else { continue }
        let x = xOf(n)
        if abs(x - todayX) < 52 || x < l0 + 20 { continue }
        axis.append(AxisLabel(x: x, day: n))
      }
    }
  }

  /// A label's width with the system font (SF and the PingFang cascade).
  static func measure(_ text: String, medium: Bool) -> CGFloat {
    let font = MLTextStyle.cascadeNSFont(size: 13, weight: medium ? .medium : .regular)
    return ceil(
      (text as NSString).size(withAttributes: [.font: font, .kern: MLTextStyle.noAutospaceKern])
        .width)
  }
}
