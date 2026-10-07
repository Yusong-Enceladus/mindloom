import BestASRDomain
import BestASRMemory
import Foundation
import MindloomDesign

// OWNER: mac-home. The pure part of Home and its relatives (MAC-SPEC §4.1–§4.5,
// §4.11, §4.12): the track window, each row's marks, 按时间's groups, the
// second line, 按截止's week groups, 按人's rows, the person page's lists and
// search. Deterministic functions of `MemoryScreenState`; the views only draw
// what these return (tests: HomeDerivationTests).

/// Day arithmetic relative to "today" (today = 0, yesterday = −1).
struct HomeDays {
  let today: Date
  let calendar: Calendar

  init(today: Date, calendar: Calendar) {
    self.today = calendar.startOfDay(for: today)
    self.calendar = calendar
  }

  init(_ state: MemoryScreenState) {
    self.init(today: state.today, calendar: state.calendar)
  }

  func n(_ date: Date) -> Int { MemoryDigest.days(from: today, to: date, calendar: calendar) }

  func date(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: today) ?? today }

  /// 「9月20日」.
  func md(_ n: Int) -> String { MindloomDates.monthDay(date(n), calendar: calendar) }

  /// 「9月20日 周日」.
  func mdw(_ n: Int) -> String { MindloomDates.dayTitle(date(n), calendar: calendar) }

  /// 「今天」 / 「明天」, else nil.
  func dueWord(_ n: Int) -> String? {
    switch n {
    case 0: "今天"
    case 1: "明天"
    default: nil
    }
  }

  /// This week's Monday, as a day number (≤ 0).
  var monday: Int {
    let weekday = calendar.component(.weekday, from: today)  // 1 = Sunday
    return -((weekday + 5) % 7)
  }

  func month(_ n: Int) -> Int { calendar.component(.month, from: date(n)) }
  func dayOfMonth(_ n: Int) -> Int { calendar.component(.day, from: date(n)) }
}

// MARK: - Track window (§4.1)

/// The 300 pt track: 19 days back, 9 forward, linear.
enum HomeTrackWindow {
  static let width: CGFloat = 300
  static let back = 19
  static let forward = 9

  /// x of a day number inside the 300 pt strip (today ≈ 202.1).
  static func x(_ n: Int) -> CGFloat {
    4 + CGFloat(n + back) / CGFloat(back + forward) * (width - 8)
  }

  static var t0: Int { -back }
  static var t1: Int { forward }

  /// Axis labels: every Monday in the window except within 46 pt of today,
  /// x clamped to [24, 276]; plus 「今天」. A label the clamp pushed within
  /// 56 pt of another one is left out (live-mac: on a Saturday 「9月14日」
  /// was clamped against 「9月21日」 and the two touched).
  static func axis(_ days: HomeDays) -> [(x: CGFloat, text: String, today: Bool)] {
    var out: [(x: CGFloat, text: String, today: Bool, clamped: Bool)] = []
    for n in t0...t1 {
      let weekday = days.calendar.component(.weekday, from: days.date(n))
      guard weekday == 2, abs(x(n) - x(0)) >= 46 else { continue }
      let clamped = min(width - 24, max(24, x(n)))
      out.append((clamped, days.md(n), false, clamped != x(n)))
    }
    out.append((x(0), "今天", true, false))
    let kept = out.filter { label in
      !label.clamped || !out.contains { $0.text != label.text && abs($0.x - label.x) < 56 }
    }
    return kept.map { ($0.x, $0.text, $0.today) }
  }
}

/// One mark on a row's track.
struct HomeTrackDot: Equatable, Identifiable {
  enum Style: Equatable {
    /// ● r 3.5 (the latest finished step) or r 3 (the last day something came in).
    case done
    /// ○ `ink2`.
    case next
    /// ○ `alert` (overdue, or the matter's due step).
    case due
  }

  let n: Int
  let style: Style
  let radius: CGFloat
  let tip: String
  /// Pops in (M10): the latest finished step of a row lit today.
  var fresh = false

  var x: CGFloat { HomeTrackWindow.x(n) }
  var id: String { "\(n)-\(style)-\(tip)" }
}

/// What a Home row draws on its 300 pt strip (`trackSVG`).
struct HomeTrack: Equatable {
  /// Nothing in the window: the grey date of the last activity instead.
  var oldDate: Int?
  /// 「8月29日」 for `oldDate`.
  var oldLabel: String?
  /// Solid line from `solid.lowerBound` to `solid.upperBound` (x); fades in
  /// over 36 pt when it starts before the window.
  var solid: ClosedRange<CGFloat>?
  var fadesIn = false
  /// Dashed future line (x).
  var dashed: ClosedRange<CGFloat>?
  var dots: [HomeTrackDot] = []
  var accessibilityLabel = ""

  var isDrawn: Bool { oldDate == nil }
}

// MARK: - Matter helpers

extension MatterDigest {
  /// The overdue step (`overOf`).
  var overdueStep: MatterStep? { overdue }

  func dueStep(_ days: HomeDays) -> MatterStep? { due(today: days.today, calendar: days.calendar) }

  /// Last capture day as a day number (nil: nothing on this Mac).
  func lastN(_ days: HomeDays) -> Int? { lastDay.map(days.n) }
}

enum HomeDerivation {
  // MARK: Urgency

  /// nearest undone dated step within 14 days ascending (none last), then
  /// importance (the organizer's rank), then last activity descending.
  static func urgency(_ a: MatterDigest, _ b: MatterDigest, _ days: HomeDays) -> Bool {
    let na = a.nextDate(today: days.today, calendar: days.calendar).map(days.n) ?? Int.max
    let nb = b.nextDate(today: days.today, calendar: days.calendar).map(days.n) ?? Int.max
    if na != nb { return na < nb }
    if a.rank != b.rank { return a.rank < b.rank }
    let la = a.lastN(days) ?? Int.min
    let lb = b.lastN(days) ?? Int.min
    if la != lb { return la > lb }
    return a.eventID < b.eventID
  }

  static func byUrgency(_ matters: [MatterDigest], _ days: HomeDays) -> [MatterDigest] {
    matters.sorted { urgency($0, $1, days) }
  }

  // MARK: Track

  static func track(_ m: MatterDigest, days: HomeDays, fresh: Bool = false) -> HomeTrack {
    let steps = m.steps.map { ($0, days.n($0.date)) }
    let done = steps.filter { $0.0.isDone && $0.1 <= 0 }.sorted { $0.1 > $1.1 }
    let future = steps.filter {
      !$0.0.isDone && $0.0.glyph != .open && $0.0.glyph != .minor && !$0.0.over && $0.1 >= 0
    }.sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
    let over = steps.filter { $0.0.over && !$0.0.isDone }.sorted { $0.1 < $1.1 }
    var active = m.days.map(days.n) + done.map(\.1)
    active = active.filter { $0 <= 0 }
    if fresh { active.append(0) }
    let last = m.lastN(days)
    guard let a = (active + [last].compactMap { $0 }).min(),
      let b = (active + [last.map { min($0, 0) }].compactMap { $0 }).max()
    else {
      return HomeTrack(oldDate: nil, accessibilityLabel: "")
    }
    let x = HomeTrackWindow.x
    let t0 = HomeTrackWindow.t0
    let futureIn = future.filter { $0.1 <= HomeTrackWindow.t1 }
    var track = HomeTrack()
    if b < t0 && futureIn.isEmpty && over.isEmpty {
      track.oldDate = b
      track.oldLabel = days.md(b)
      track.accessibilityLabel = "最近一次在 " + days.md(b)
      return track
    }
    let x0 = a < t0 ? 0 : x(a)
    let x1 = x(min(b, 0))
    if x1 > x0 + 1 {
      track.solid = x0...x1
      track.fadesIn = a < t0
    }
    func tip(_ n: Int, _ text: String, more: Int = 0) -> String {
      days.md(n) + (days.dueWord(n).map { "（\($0)）" } ?? "") + " · " + MLAutospace.apply(text)
        + (more > 0 ? " · 另 \(more) 条" : "")
    }
    if let latest = done.first, latest.1 >= t0 {
      let same = done.filter { $0.1 == latest.1 }.count - 1
      track.dots.append(
        HomeTrackDot(
          n: latest.1, style: .done, radius: 3.5, tip: tip(latest.1, latest.0.text, more: same),
          fresh: fresh && latest.1 == 0))
    } else if b >= t0 {
      let at = min(b, 0)
      let crowded = (over + future).contains { abs(x($0.1) - x(at)) < 12 }
      if !crowded {
        track.dots.append(
          HomeTrackDot(
            n: at, style: .done, radius: 3, tip: days.md(at) + " · 最近一次收到相关内容",
            fresh: fresh && at == 0))
      }
    }
    for (step, n) in over where n >= t0 {
      track.dots.append(HomeTrackDot(n: n, style: .due, radius: 3.25, tip: tip(n, step.text) + " · 已过期"))
    }
    var shown: [(MatterStep, Int)] = []
    for item in futureIn {
      if shown.count >= 2 || shown.contains(where: { abs(x($0.1) - x(item.1)) < 15 }) { continue }
      shown.append(item)
    }
    if let far = shown.last?.1 {
      let from = max(t0, min(b, 0))
      if far > from { track.dashed = x(from)...x(far) }
      let dueID = m.dueStep(days)?.id
      for (step, n) in shown {
        track.dots.append(
          HomeTrackDot(n: n, style: step.id == dueID ? .due : .next, radius: 3.25, tip: tip(n, step.text)))
      }
    }
    var label = [days.md(a) + "起"]
    if let latest = done.first { label.append(days.md(latest.1) + " " + latest.0.text) }
    if let next = future.first { label.append("接下来 " + days.md(next.1) + " " + next.0.text) }
    track.accessibilityLabel = label.joined(separator: "，")
    return track
  }

  // MARK: Second line

  /// The parts of a row's second line (`secondLine`).
  struct SecondLine: Equatable {
    /// 「宋雨桐共享 · 」 (ink2).
    var sharedBy: String?
    /// 「已过期」 / 「今天」 / 「明天」 (alert).
    var alertWord: String?
    /// The words after it (or the status line).
    var words: String
    /// 「 · {risk}」 (ink), only in 已过期 / 快到期.
    var risk: String?

    /// The whole line as plain text (accessibility, search).
    var plain: String {
      (sharedBy ?? "") + (alertWord.map { $0 + " " } ?? "") + words + (risk.map { " · " + $0 } ?? "")
    }
  }

  static func secondLine(
    _ m: MatterDigest, days: HomeDays, sharedBy: String? = nil, withRisk: Bool = false
  ) -> SecondLine {
    let by = sharedBy.flatMap { $0 == "你" || $0.isEmpty ? nil : $0 + "共享 · " }
    let risk = withRisk ? m.risk.flatMap { $0.isEmpty ? nil : MLAutospace.apply($0) } : nil
    if let over = m.overdueStep {
      return SecondLine(
        sharedBy: by, alertWord: "已过期",
        words: days.md(days.n(over.date)) + MLAutospace.apply(over.text), risk: risk)
    }
    if let due = m.dueStep(days), let word = days.dueWord(days.n(due.date)) {
      return SecondLine(sharedBy: by, alertWord: word, words: MLAutospace.apply(due.text), risk: risk)
    }
    return SecondLine(sharedBy: by, alertWord: nil, words: MLAutospace.apply(m.status), risk: nil)
  }

  // MARK: 按时间 groups

  enum TimeGroupKind: String, CaseIterable {
    case overdue = "已过期"
    case due = "即将到期"
    case thisWeek = "本周"
    case lastWeek = "上周"
    case earlier = "更早"

    var showsRisk: Bool { self == .overdue || self == .due }
  }

  struct TimeGroup: Equatable, Identifiable {
    let kind: TimeGroupKind
    let matters: [MatterDigest]
    var id: String { kind.rawValue }
  }

  static func timeGroups(_ matters: [MatterDigest], days: HomeDays) -> [TimeGroup] {
    let mon = days.monday
    let over = matters.filter { $0.overdueStep != nil }.sorted {
      ($0.overdueStep!.date, $0.rank) < ($1.overdueStep!.date, $1.rank)
    }
    let due = matters.filter { $0.overdueStep == nil && $0.dueStep(days) != nil }.sorted { a, b in
      let da = days.n(a.dueStep(days)!.date)
      let db = days.n(b.dueStep(days)!.date)
      return da != db ? da < db : urgency(a, b, days)
    }
    let rest = matters.filter { $0.overdueStep == nil && $0.dueStep(days) == nil }
    let week = rest.filter { ($0.lastN(days) ?? Int.min) >= mon }
    let lastWeek = rest.filter {
      let n = $0.lastN(days) ?? Int.min
      return n >= mon - 7 && n < mon
    }
    let old = rest.filter { ($0.lastN(days) ?? Int.min) < mon - 7 }.sorted {
      let a = $0.lastN(days) ?? Int.min
      let b = $1.lastN(days) ?? Int.min
      return a != b ? a > b : $0.rank < $1.rank
    }
    return [
      TimeGroup(kind: .overdue, matters: over),
      TimeGroup(kind: .due, matters: due),
      TimeGroup(kind: .thisWeek, matters: byUrgency(week, days)),
      TimeGroup(kind: .lastWeek, matters: byUrgency(lastWeek, days)),
      TimeGroup(kind: .earlier, matters: old),
    ].filter { !$0.matters.isEmpty }
  }

  // MARK: 按截止

  struct DeadlineEntry: Equatable, Identifiable {
    let n: Int
    let text: String
    let matter: MatterDigest
    let stepID: String?
    let also: [MatterDigest]
    var id: String { "\(matter.eventID)|\(stepID ?? text)|\(n)" }
  }

  struct DeadlineGroup: Equatable, Identifiable {
    let title: String
    let range: String?
    let entries: [DeadlineEntry]
    var id: String { title }
  }

  static func deadlineGroups(
    _ digest: MemoryDigest?, eventIDs: Set<String>?, days: HomeDays
  ) -> [DeadlineGroup] {
    guard let digest else { return [] }
    let live = digest.matters.filter { eventIDs?.contains($0.eventID) ?? true }
    let ids = Set(live.map(\.eventID))
    var entries: [DeadlineEntry] = []
    for row in digest.deadlines where ids.contains(row.eventID) {
      guard let matter = digest.matter(row.eventID) else { continue }
      let step =
        row.stepID.flatMap(matter.step)
        ?? matter.steps.first {
          $0.fromStatus && days.n($0.date) == days.n(row.date)
        }
      if step?.isDone ?? false { continue }
      entries.append(
        DeadlineEntry(
          n: days.n(row.date), text: row.text, matter: matter, stepID: step?.id ?? row.stepID,
          also: row.alsoEventIDs.filter { ids.contains($0) || eventIDs == nil }.compactMap(
            digest.matter)))
    }
    for matter in live {
      guard let over = matter.overdueStep else { continue }
      if entries.contains(where: { $0.matter.eventID == matter.eventID && $0.stepID == over.id }) {
        continue
      }
      entries.append(
        DeadlineEntry(
          n: days.n(over.date), text: over.text, matter: matter, stepID: over.id, also: []))
    }
    entries.sort { ($0.n, $0.matter.rank, $0.id) < ($1.n, $1.matter.rank, $1.id) }
    let nextMonday = days.monday + 7
    let thisMonth = days.month(0)
    let nextMonth = thisMonth % 12 + 1
    func range(_ from: Int) -> String {
      let to = from + 6
      return days.md(from) + "–"
        + (days.month(from) == days.month(to) ? "\(days.dayOfMonth(to))日" : days.md(to))
    }
    func key(_ n: Int) -> (String, String?) {
      if n < 0 { return ("已过期", nil) }
      if n <= 1 { return ("即将到期", nil) }
      if n < nextMonday { return ("本周", nil) }
      if n < nextMonday + 7 { return ("下周", range(nextMonday)) }
      if n < nextMonday + 14 { return ("下下周", range(nextMonday + 7)) }
      if days.month(n) == nextMonth && n < 62 { return ("\(nextMonth)月", nil) }
      return ("以后", nil)
    }
    var groups: [DeadlineGroup] = []
    for entry in entries {
      let (title, range) = key(entry.n)
      if let last = groups.last, last.title == title {
        groups[groups.count - 1] = DeadlineGroup(
          title: title, range: range, entries: last.entries + [entry])
      } else {
        groups.append(DeadlineGroup(title: title, range: range, entries: [entry]))
      }
    }
    return groups
  }

  // MARK: 按人

  /// One person in 按人 (v12, B7 U13): their name (or 「没起名 N」), their
  /// most urgent live matter and how many they are in, the last day they
  /// appeared; a row opens their page, where all of it is.
  struct PersonRow: Equatable, Identifiable {
    let person: MemoryPersonEntry
    /// Their most urgent live matter (nil: no matter holds them yet).
    let matter: MatterDigest?
    /// Live matters they are in.
    let matterCount: Int
    /// 「今天」 or 「9月19日」; "" when not known.
    let last: String
    var id: String { person.personID }
  }

  /// A run of 按人 rows under an optional header.
  struct PeopleGroup: Equatable, Identifiable {
    /// nil for the first run (no header).
    let title: String?
    let rows: [PersonRow]
    var id: String { title ?? "" }
  }

  static func personLast(_ person: MemoryPersonEntry, days: HomeDays) -> Int? {
    person.lastSeen.map { days.n(days.calendar.startOfDay(for: $0)) }
  }

  /// 按人: everyone once (v12, 理3-1): people in several matters or heard on
  /// this Mac first (last seen first), then 「只在一件事里」, then the voices
  /// nobody named, 「没起名」, by their number. Labels read as speakers
  /// (「全文」, 「Archive」) and people named only in texts no matter holds are
  /// left out.
  static func peopleGroups(_ state: MemoryScreenState) -> [PeopleGroup] {
    let days = HomeDays(state)
    let digest = state.digest
    var regulars: [PersonRow] = []
    var once: [PersonRow] = []
    var unnamed: [PersonRow] = []
    for person in state.people {
      let mine = person.events.map(\.eventID).compactMap { digest?.matter($0) }
      let n = personLast(person, days: days) ?? byUrgency(mine, days).first?.lastN(days)
      let row = PersonRow(
        person: person, matter: byUrgency(mine, days).first, matterCount: mine.count,
        last: n.map { $0 == 0 ? "今天" : days.md($0) } ?? "")
      if !person.isNamed {
        if person.hasVoice || !mine.isEmpty { unnamed.append(row) }
        continue
      }
      let shown = state.projection?.isShownPerson(person) ?? true
      if person.hasVoice || (shown && mine.count >= 2) {
        regulars.append(row)
      } else if !mine.isEmpty, MemoryProjection.looksLikePersonName(person.name) {
        once.append(row)
      }
    }
    func recent(_ a: PersonRow, _ b: PersonRow) -> Bool {
      let left = a.person.lastSeen ?? .distantPast
      let right = b.person.lastSeen ?? .distantPast
      if left != right { return left > right }
      if a.matterCount != b.matterCount { return a.matterCount > b.matterCount }
      return a.person.name < b.person.name
    }
    var groups: [PeopleGroup] = []
    if !regulars.isEmpty { groups.append(PeopleGroup(title: nil, rows: regulars.sorted(by: recent))) }
    if !once.isEmpty {
      groups.append(
        PeopleGroup(title: regulars.isEmpty ? nil : "仅出现在一件事中", rows: once.sorted(by: recent)))
    }
    if !unnamed.isEmpty {
      groups.append(
        PeopleGroup(
          title: "未命名",
          rows: unnamed.sorted {
            ($0.person.unnamedNumber ?? .max, $0.person.personID)
              < ($1.person.unnamedNumber ?? .max, $1.person.personID)
          }))
    }
    return groups
  }

  /// A row's second line: the most urgent matter (「… 等 3 件事」), else
  /// how often they were heard here.
  static func personSecondLine(_ row: PersonRow) -> String {
    if let matter = row.matter {
      let title = MLAutospace.apply(matter.title)
      return row.matterCount > 1 ? "\(title) 等 \(row.matterCount) 件事" : title
    }
    if row.person.voiceRecords > 0 { return "\(row.person.voiceRecords) 段录音中有此声音" }
    return row.person.hasVoice ? "录音中有此声音" : ""
  }

  /// People as the merge sheet offers them: named first (as 按人 orders
  /// them), then the unnamed by number; never `excluding`.
  static func mergeTargets(_ state: MemoryScreenState, excluding personID: String)
    -> [MemoryPersonEntry]
  {
    peopleGroups(state).flatMap(\.rows).map(\.person).filter {
      $0.personID.caseInsensitiveCompare(personID) != .orderedSame
    }
  }

  /// 「最近一次在今天」 / 「最近一次在 9月18日」.
  static func personSubtitle(_ person: MemoryPersonEntry, state: MemoryScreenState) -> String {
    let days = HomeDays(state)
    guard let n = personLast(person, days: days) else { return "" }
    return n == 0 ? "最近一次在今天" : "最近一次在 " + days.md(n)
  }

  /// 「一起在做」: up to six live matters with this person, by urgency.
  static func together(_ person: MemoryPersonEntry, state: MemoryScreenState) -> [MatterDigest] {
    guard let digest = state.digest else { return [] }
    let mine = person.events.map(\.eventID).compactMap(digest.matter)
    return Array(byUrgency(mine, HomeDays(state)).prefix(6))
  }

  /// 「一起定下的」: up to six decisions and promises naming this person,
  /// newest first, grouped while the matter stays the same.
  static func decided(_ person: MemoryPersonEntry, state: MemoryScreenState)
    -> [(matter: MatterRef, steps: [MatterStep])]
  {
    guard let digest = state.digest else { return [] }
    var out: [(MatterRef, [MatterStep])] = []
    for (matter, step) in digest.decided(withPersonNamed: person.name).prefix(6) {
      if let last = out.last, last.0.eventID == matter.eventID {
        out[out.count - 1].1.append(step)
      } else {
        out.append((matter, [step]))
      }
    }
    return out
  }
}
