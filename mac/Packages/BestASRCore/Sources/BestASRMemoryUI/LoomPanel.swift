import BestASRMemory
import SwiftUI

/// Home's warm tones: the page, the 「接下来」 zone, the day grid, the
/// 今天 line, and the tinted pills and chips (light and dark).
struct HomeTones {
  struct Tint {
    let fill: Color
    let ink: Color
    /// A flag's glyph.
    let mark: Color
  }

  let page: Color
  let future: Color
  let grid: Color
  /// The 今天 line and pill, and the selected person chip.
  let ink: Color
  let onInk: Color
  /// A milestone chip.
  let chip: Color
  let chipBorder: Color
  let red: Tint
  let amber: Tint
  let blue: Tint
  let gray: Tint
  /// Going well (a matter's health).
  let green: Tint

  init(_ palette: ZhijiPalette) {
    if palette.isDark {
      page = .hex(0x1C1B19)
      future = .white.opacity(0.035)
      grid = .white.opacity(0.05)
      ink = .hex(0xEDEBE6)
      onInk = .hex(0x1C1B19)
      chip = .hex(0x2A2926)
      chipBorder = .white.opacity(0.10)
      red = Tint(fill: .hex(0x3D2522), ink: .hex(0xF2A59C), mark: .hex(0xE8695D))
      amber = Tint(fill: .hex(0x3A2D1A), ink: .hex(0xE8C07A), mark: .hex(0xD69E42))
      blue = Tint(fill: .hex(0x1F2B3D), ink: .hex(0xA3C1EE), mark: .hex(0x7FA3E0))
      gray = Tint(fill: .white.opacity(0.08), ink: .hex(0xB8B4AB), mark: .hex(0x8F8B82))
      green = Tint(fill: .hex(0x1E3326), ink: .hex(0x9FD3B2), mark: .hex(0x6FBF8E))
    } else {
      page = .hex(0xFBFAF7)
      future = .hex(0xF4F2EC)
      grid = .hex(0xEFECE6)
      ink = .hex(0x1F1E1B)
      onInk = .white
      chip = .white
      chipBorder = .hex(0xE6E3DC)
      red = Tint(fill: .hex(0xFBE9E6), ink: .hex(0x9B2C22), mark: .hex(0xD0453A))
      amber = Tint(fill: .hex(0xFAF0DC), ink: .hex(0x7A4E0E), mark: .hex(0xB7791F))
      blue = Tint(fill: .hex(0xE7EEF9), ink: .hex(0x1E4E8C), mark: .hex(0x2F5D9E))
      gray = Tint(fill: .hex(0xEFEDE8), ink: .hex(0x5F5C56), mark: .hex(0x8C887F))
      green = Tint(fill: .hex(0xE7F2EA), ink: .hex(0x2E6B47), mark: .hex(0x4E9A6E))
    }
  }

  func tint(_ urgency: MemoryLoom.Urgency) -> Tint {
    switch urgency {
    case .urgent: red
    case .soon: amber
    case .later: gray
    }
  }
}

/// 「最近在动的事」 on Home: the most important matters of the last two weeks
/// and the next one as ribbons on one time axis. Each lane has its title,
/// status and people on the left; its ribbon is as thick each day as what
/// it took in, with the organizer's dated milestones on it and flags for
/// what is due in the 「接下来」 zone. Hovering a day lists its items (and
/// joins the lanes one meeting moved); clicking one opens the matter there.
struct LoomPanel: View {
  @Environment(\.zhiji) private var palette
  let loom: MemoryLoom
  @Binding var span: MemoryLoom.Span
  let state: MemoryScreenState
  /// Upper-case person ID chosen in 「看某个人」: their lanes stay, the rest
  /// dim.
  @Binding var person: String?
  /// The people 「看某个人」 offers (named, most matters first).
  let people: [MemoryPersonEntry]
  /// People known beyond the chips ("+N" opens 人物).
  var morePeople = 0
  var showAllPeople: () -> Void = {}
  /// The shell's namespace: each lane is where its matter's map grows from.
  var morph: Namespace.ID? = nil
  /// Opens a matter with these event page rows expanded.
  let open: (String, [String]) -> Void
  /// The day under the pointer (settable for a still image).
  @State var hover: LoomHover? = nil

  static let labelWidth: CGFloat = 224
  static let peopleChips = 5

  var body: some View {
    let tones = HomeTones(palette)
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 8) {
        Text(ZhijiCopy.loomTitle)
          .font(.zhiji(18, .semibold))
          .foregroundStyle(palette.label)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 16)
        if !people.isEmpty { personChips(tones) }
        ZhijiSegmented(
          options: [
            (MemoryLoom.Span.twoWeeks, ZhijiCopy.loomTwoWeeks),
            (.fiveWeeks, ZhijiCopy.loomFiveWeeks),
          ],
          selection: $span, height: 24, fontSize: 12, horizontalPadding: 10)
      }
      GeometryReader { geometry in
        let layout = LoomLayout(
          loom: loom, width: max(geometry.size.width - Self.labelWidth, 120))
        HStack(alignment: .top, spacing: 0) {
          labels(layout, tones).frame(width: Self.labelWidth)
          LoomCanvas(
            loom: loom, layout: layout, tones: tones, person: person, hover: hover,
            calendar: state.calendar, shared: state.sharedItemIDs
          )
          .frame(width: layout.width, height: layout.height)
          .accessibilityHidden(true)
          .overlay(alignment: .topLeading) { zoomSources(layout) }
        }
        .overlay(alignment: .topLeading) { tooltip(layout, tones) }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
          switch phase {
          case .active(let point):
            hover = layout.hit(CGPoint(x: point.x - Self.labelWidth, y: point.y))
          case .ended:
            hover = nil
          }
        }
        .onTapGesture { point in
          guard let target = layout.target(CGPoint(x: point.x - Self.labelWidth, y: point.y))
          else { return }
          open(loom.lanes[target.lane].eventID, target.rows)
        }
      }
      .frame(height: LoomLayout(loom: loom, width: 1).height)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bestASR.memory.loom")
  }

  /// One clear rectangle per lane, the source of the continuous zoom into
  /// that matter's 线索 map (matched geometry; none under Reduce Motion).
  @ViewBuilder
  private func zoomSources(_ layout: LoomLayout) -> some View {
    if let morph {
      ZStack(alignment: .topLeading) {
        ForEach(Array(loom.lanes.enumerated()), id: \.element.id) { index, lane in
          Color.clear
            .frame(width: layout.width, height: layout.laneHeight(index))
            .zhijiMorph("thread-\(lane.eventID)", in: morph, isSource: true)
            .offset(y: layout.laneTop(index))
            .allowsHitTesting(false)
        }
      }
    }
  }

  // MARK: - 看某个人

  private func personChips(_ tones: HomeTones) -> some View {
    HStack(spacing: 6) {
      Text(ZhijiCopy.lookAtPerson)
        .font(.zhiji(12))
        .foregroundStyle(palette.secondary)
      chip(ZhijiCopy.everyone, selected: person == nil, tones) { person = nil }
      ForEach(people.prefix(Self.peopleChips)) { entry in
        let id = entry.personID.uppercased()
        chip(entry.name, selected: person == id, tones) {
          person = person == id ? nil : id
        }
      }
      if morePeople > 0 {
        chip("+\(morePeople)", selected: false, tones, action: showAllPeople)
      }
    }
    .padding(.trailing, 8)
  }

  private func chip(
    _ title: String, selected: Bool, _ tones: HomeTones, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(title)
        .font(.zhiji(12, selected ? .semibold : .regular))
        .foregroundStyle(selected ? tones.onInk : palette.label)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(selected ? tones.ink : tones.gray.fill, in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  // MARK: - Left column

  private func labels(_ layout: LoomLayout, _ tones: HomeTones) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Color.clear.frame(height: LoomLayout.axisHeight)
      ForEach(Array(loom.lanes.enumerated()), id: \.element.id) { index, lane in
        HStack(alignment: .center, spacing: 12) {
          Capsule()
            .fill(palette.thread(index))
            .frame(width: 4)
            .padding(.vertical, 10)
          VStack(alignment: .leading, spacing: 4) {
            Text(lane.title)
              .font(.zhiji(index == 0 ? 15 : 14, .semibold))
              .foregroundStyle(palette.label)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
            Text(lane.status)
              .font(.zhiji(12))
              .foregroundStyle(palette.secondary)
              .lineLimit(1)
            if !lane.people.isEmpty {
              HStack(spacing: 3) {
                ForEach(lane.people, id: \.personID) { person in
                  Avatar(person, size: 18, ring: tones.page)
                }
              }
              .padding(.top, 2)
            }
          }
          Spacer(minLength: 8)
        }
        .frame(height: layout.laneHeight(index))
        .opacity(dimmed(lane) ? 0.35 : 1)
        .contentShape(Rectangle())
        .onTapGesture { open(lane.eventID, []) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(lane))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(lane.eventID, []) }
        .accessibilityIdentifier("bestASR.memory.loom.lane")
      }
    }
  }

  // MARK: - Hover card

  @ViewBuilder
  private func tooltip(_ layout: LoomLayout, _ tones: HomeTones) -> some View {
    if case .day(let laneIndex, let day) = hover,
      let knot = loom.lanes[laneIndex].knots.first(where: { $0.day == day })
    {
      VStack(alignment: .leading, spacing: 5) {
        Text(Self.monthDay(knot.time, state.calendar, weekday: true))
          .font(.zhiji(13, .semibold))
          .monospacedDigit()
          .foregroundStyle(palette.label)
        ForEach(Array(knot.items.prefix(3).enumerated()), id: \.offset) { _, item in
          Text(
            [state.time(item.time), item.sourceLabel, item.snippet]
              .filter { !$0.isEmpty }.joined(separator: " · ")
          )
          .font(.zhiji(12))
          .foregroundStyle(palette.secondary)
          .lineLimit(1)
        }
        Text(ZhijiCopy.openThisDay)
          .font(.zhiji(12, .semibold))
          .foregroundStyle(palette.accent)
          .padding(.top, 2)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(width: 300, alignment: .leading)
      .background(palette.isDark ? palette.surface : .white, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tones.chipBorder))
      .shadow(color: .black.opacity(palette.isDark ? 0.4 : 0.10), radius: 8, y: 3)
      .offset(
        x: min(
          Self.labelWidth + layout.x(day) + 14,
          max(Self.labelWidth + layout.width - 300, 0)),
        y: layout.y(laneIndex) + 16
      )
      .allowsHitTesting(false)
    }
  }

  // MARK: - Text

  private func dimmed(_ lane: MemoryLoom.Lane) -> Bool {
    guard let person else { return false }
    return !lane.personIDs.contains(person)
  }

  /// "9月16日", or "9月16日 周三".
  static func monthDay(_ date: Date, _ calendar: Calendar, weekday: Bool = false) -> String {
    let parts = calendar.dateComponents([.month, .day, .weekday], from: date)
    let day = "\(parts.month ?? 0)月\(parts.day ?? 0)日"
    guard weekday else { return day }
    return day + " " + MemoryDateText.weekdays[((parts.weekday ?? 1) - 1 + 7) % 7]
  }

  /// 今天 / 明天, else "9/26".
  static func dayWord(_ daysAway: Int, _ date: Date, _ calendar: Calendar) -> String {
    switch daysAway {
    case 0: return ZhijiCopy.loomToday
    case 1: return ZhijiCopy.loomTomorrow
    default:
      let parts = calendar.dateComponents([.month, .day], from: date)
      return "\(parts.month ?? 0)/\(parts.day ?? 0)"
    }
  }

  private func accessibilityLabel(_ lane: MemoryLoom.Lane) -> String {
    var parts = [
      ZhijiCopy.loomLane(
        lane.title, lane.itemCount,
        lane.knots.last.map { state.day($0.time) } ?? ""),
      lane.status,
    ]
    parts += lane.milestones.map(\.text)
    parts += lane.flags.map {
      ZhijiCopy.loomNextStep(Self.dayWord($0.daysAway, $0.date, state.calendar)) + " " + $0.text
    }
    let names = lane.people.filter(\.isNamed).map(\.name)
    if !names.isEmpty { parts.append(names.joined(separator: "、")) }
    return parts.filter { !$0.isEmpty }.joined(separator: "，")
  }
}

/// What the pointer is over: one lane's day that took something in.
enum LoomHover: Equatable {
  case day(lane: Int, day: Int)
}

/// Where days, lanes, milestone chips and flag chips are on the axis.
struct LoomLayout {
  let loom: MemoryLoom
  let width: CGFloat

  static let axisHeight: CGFloat = 36
  static let firstLaneHeight: CGFloat = 100
  static let laneHeight: CGFloat = 86
  static let chipHeight: CGFloat = 20
  static let milestoneFont: CGFloat = 11.5
  static let flagFont: CGFloat = 12
  /// A milestone chip's centre above the line, a flag chip's below it.
  static let chipAbove: CGFloat = 28
  static let chipBelow: CGFloat = 26

  var dayWidth: CGFloat { width / CGFloat(max(loom.totalDays, 1)) }
  var todayX: CGFloat { x(loom.todayIndex) }
  var height: CGFloat { laneTop(loom.lanes.count) + 4 }

  func x(_ day: Int) -> CGFloat { (CGFloat(day) + 0.5) * dayWidth }

  func laneHeight(_ lane: Int) -> CGFloat {
    lane == 0 ? Self.firstLaneHeight : Self.laneHeight
  }

  func laneTop(_ lane: Int) -> CGFloat {
    guard lane > 0 else { return Self.axisHeight }
    return Self.axisHeight + Self.firstLaneHeight + CGFloat(lane - 1) * Self.laneHeight
  }

  /// The ribbon's centre line.
  func y(_ lane: Int) -> CGFloat { laneTop(lane) + laneHeight(lane) * 0.56 }

  func lane(atY y: CGFloat) -> Int? {
    guard y >= Self.axisHeight else { return nil }
    return loom.lanes.indices.first { y >= laneTop($0) && y < laneTop($0 + 1) }
  }

  func day(atX x: CGFloat) -> Int? {
    guard x >= 0, x < width else { return nil }
    return min(Int(floor(x / dayWidth)), loom.totalDays - 1)
  }

  /// Half the ribbon's height on a day: 3 pt plus the smoothed √items,
  /// thicker on the first lane, capped to stay inside the lane.
  func halfHeight(_ lane: Int, _ value: Double) -> CGFloat {
    guard value > 0 else { return 0 }
    let scale: CGFloat = lane == 0 ? 6.5 : 5
    return min(3 + CGFloat(value) * scale, lane == 0 ? 19 : 15)
  }

  /// Estimated width of chip text: CJK is one em, Latin a bit over half.
  static func textWidth(_ text: String, size: CGFloat) -> CGFloat {
    text.reduce(0) { width, c in
      let wide = c.unicodeScalars.first.map { $0.value >= 0x2E80 } ?? true
      return width + (wide ? size : size * 0.62)
    }
  }

  /// Milestone chips that fit, latest first; one that would touch another
  /// is left out (its circle stays).
  func milestoneChips(_ lane: Int) -> [(index: Int, rect: CGRect)] {
    let milestones = loom.lanes[lane].milestones
    var kept: [(index: Int, rect: CGRect)] = []
    for index in milestones.indices.reversed() {
      let milestone = milestones[index]
      let w = Self.textWidth(milestone.label, size: Self.milestoneFont) + 16
      let midX = min(max(x(milestone.day), w / 2 + 1), width - w / 2 - 1)
      let rect = CGRect(
        x: midX - w / 2, y: y(lane) - Self.chipAbove - Self.chipHeight / 2, width: w,
        height: Self.chipHeight)
      if kept.contains(where: { $0.rect.insetBy(dx: -4, dy: 0).intersects(rect) }) { continue }
      kept.append((index, rect))
    }
    return kept.sorted { $0.index < $1.index }
  }

  /// The words of a flag chip: 今天 / 明天 / 9/26, then the action.
  func flagWords(_ flag: MemoryLoom.Flag, calendar: Calendar) -> (day: String, text: String) {
    (LoomPanel.dayWord(flag.daysAway, flag.date, calendar), flag.text)
  }

  /// Flag chips below the line, starting at the flag; the next one close by
  /// goes above; one that fits neither place is left out (its flag stays).
  func flagChips(_ lane: Int, calendar: Calendar) -> [(index: Int, rect: CGRect)] {
    var taken = milestoneChips(lane).map(\.rect)
    var kept: [(index: Int, rect: CGRect)] = []
    for (index, flag) in loom.lanes[lane].flags.enumerated() {
      let words = flagWords(flag, calendar: calendar)
      let w = Self.textWidth(words.day + " " + words.text, size: Self.flagFont) + 18
      let minX = min(max(x(flag.day) - 8, 1), width - w - 1)
      for offset in [Self.chipBelow, -Self.chipAbove] {
        let rect = CGRect(
          x: minX, y: y(lane) + offset - Self.chipHeight / 2, width: w, height: Self.chipHeight)
        if taken.contains(where: { $0.insetBy(dx: -4, dy: 0).intersects(rect) }) { continue }
        taken.append(rect)
        kept.append((index, rect))
        break
      }
    }
    return kept
  }

  /// A lane's day that took something in, under the pointer.
  func hit(_ point: CGPoint) -> LoomHover? {
    guard let lane = lane(atY: point.y), let day = day(atX: point.x),
      loom.lanes[lane].knots.contains(where: { $0.day == day })
    else { return nil }
    return .day(lane: lane, day: day)
  }

  /// What a click opens: a milestone's rows, a day's rows, else the matter.
  func target(_ point: CGPoint) -> (lane: Int, rows: [String])? {
    guard let lane = lane(atY: point.y) else { return nil }
    let data = loom.lanes[lane]
    for (index, rect) in milestoneChips(lane) where rect.insetBy(dx: -2, dy: -2).contains(point) {
      return (lane, data.milestones[index].rowIDs)
    }
    if let milestone = data.milestones.first(where: {
      abs(x($0.day) - point.x) <= 9 && abs(y(lane) - point.y) <= 9
    }) {
      return (lane, milestone.rowIDs)
    }
    if let day = day(atX: point.x), let knot = data.knots.first(where: { $0.day == day }) {
      return (lane, knot.items.map(\.rowID))
    }
    return (lane, [])
  }
}

/// The axis, the ribbons, the milestones, the flags and (on hover) the
/// weft of a shared item, drawn in one pass.
struct LoomCanvas: View {
  @Environment(\.zhiji) private var palette
  let loom: MemoryLoom
  let layout: LoomLayout
  let tones: HomeTones
  let person: String?
  let hover: LoomHover?
  let calendar: Calendar
  /// Others' items (upper-case IDs): their days are drawn in the second tone.
  var shared: Set<String> = []

  var body: some View {
    Canvas { context, size in
      drawAxis(&context, size)
      for (index, lane) in loom.lanes.enumerated() { drawRibbon(&context, lane, index) }
      drawWefts(&context, dots: false)
      for (index, lane) in loom.lanes.enumerated() { drawMarks(&context, lane, index) }
      drawWefts(&context, dots: true)
    }
  }

  private func alpha(_ lane: MemoryLoom.Lane) -> Double {
    guard let person else { return 1 }
    return lane.personIDs.contains(person) ? 1 : 0.2
  }

  // MARK: Axis

  private func drawAxis(_ context: inout GraphicsContext, _ size: CGSize) {
    let top = LoomLayout.axisHeight - 8
    let bottom = size.height
    let todayX = layout.todayX
    // 接下来: the days after today.
    let future = CGRect(x: todayX, y: 0, width: size.width - todayX, height: bottom)
    context.fill(
      Path(roundedRect: future, cornerRadius: 10, style: .continuous), with: .color(tones.future))
    // A faint line per day.
    var grid = Path()
    for day in 0..<loom.totalDays {
      grid.move(to: CGPoint(x: layout.x(day), y: top + 4))
      grid.addLine(to: CGPoint(x: layout.x(day), y: bottom))
    }
    context.stroke(grid, with: .color(tones.grid), lineWidth: 1)

    // A label a week from the first day, and the zone's last day; none next
    // to the 今天 pill.
    let labelY: CGFloat = 13
    for day in 0..<loom.totalDays {
      guard day % 7 == 0 || day == loom.totalDays - 1,
        abs(day - loom.todayIndex) > 2 || day == loom.totalDays - 1
      else { continue }
      let date = calendar.date(byAdding: .day, value: day, to: loom.start) ?? loom.start
      let parts = calendar.dateComponents([.month, .day], from: date)
      context.draw(
        Text("\(parts.month ?? 0)/\(parts.day ?? 0)").font(.zhiji(12)).monospacedDigit()
          .foregroundColor(palette.secondary),
        at: CGPoint(x: layout.x(day), y: labelY), anchor: .center)
    }
    // 今天: a dark line and pill; 接下来一周 beside it.
    var today = Path()
    today.move(to: CGPoint(x: todayX, y: top))
    today.addLine(to: CGPoint(x: todayX, y: bottom))
    context.stroke(today, with: .color(tones.ink), lineWidth: 1.5)
    let pill = CGRect(x: todayX - 24, y: labelY - 11, width: 48, height: 22)
    context.fill(Path(roundedRect: pill, cornerRadius: 11), with: .color(tones.ink))
    context.draw(
      Text(ZhijiCopy.loomToday).font(.zhiji(12, .semibold)).foregroundColor(tones.onInk),
      at: CGPoint(x: todayX, y: labelY), anchor: .center)
    if size.width - todayX > 120 {
      context.draw(
        Text(ZhijiCopy.loomNextWeek).font(.zhiji(12)).foregroundColor(palette.secondary),
        at: CGPoint(x: todayX + 32, y: labelY), anchor: .leading)
    }
  }

  // MARK: Ribbons

  private func drawRibbon(
    _ context: inout GraphicsContext, _ lane: MemoryLoom.Lane, _ index: Int
  ) {
    guard let first = lane.knots.first?.day, let last = lane.knots.last?.day else { return }
    let color = palette.thread(index)
    let a = alpha(lane)
    let y = layout.y(index)
    // The band: the day values joined smoothly, tapering half a day out.
    var upper: [CGPoint] = [CGPoint(x: layout.x(first) - layout.dayWidth * 0.45, y: y)]
    for day in first...last {
      let value = lane.band.indices.contains(day) ? lane.band[day] : 0
      upper.append(CGPoint(x: layout.x(day), y: y - layout.halfHeight(index, value)))
    }
    upper.append(CGPoint(x: layout.x(last) + layout.dayWidth * 0.45, y: y))
    let lower = upper.reversed().map { CGPoint(x: $0.x, y: 2 * y - $0.y) }
    var band = Path()
    Self.smooth(&band, upper, start: true)
    Self.smooth(&band, Array(lower), start: false)
    band.closeSubpath()
    context.fill(band, with: .color(color.opacity((palette.isDark ? 0.24 : 0.17) * a)))
    // The thread from the first to the last day, then dotted to the last flag.
    var line = Path()
    line.move(to: CGPoint(x: layout.x(first), y: y))
    line.addLine(to: CGPoint(x: layout.x(last), y: y))
    context.stroke(
      line, with: .color(color.opacity(a)),
      style: StrokeStyle(lineWidth: index == 0 ? 2.4 : 2, lineCap: .round))
    if let flag = lane.flags.map(\.day).max(), flag > last {
      var ahead = Path()
      ahead.move(to: CGPoint(x: layout.x(last), y: y))
      ahead.addLine(to: CGPoint(x: layout.x(flag), y: y))
      context.stroke(
        ahead, with: .color(color.opacity(0.8 * a)),
        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [2.5, 3.5]))
    }
  }

  /// A curve through the points' midpoints.
  static func smooth(_ path: inout Path, _ points: [CGPoint], start: Bool) {
    guard let head = points.first else { return }
    if start { path.move(to: head) } else { path.addLine(to: head) }
    guard points.count > 2 else {
      points.dropFirst().forEach { path.addLine(to: $0) }
      return
    }
    for i in 1..<(points.count - 1) {
      let mid = CGPoint(
        x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
      path.addQuadCurve(to: mid, control: points[i])
    }
    path.addLine(to: points[points.count - 1])
  }

  // MARK: Wefts (hover only)

  /// The line under the lanes' marks, its dots over them.
  private func drawWefts(_ context: inout GraphicsContext, dots: Bool) {
    guard case .day(let lane, let day) = hover,
      let knot = loom.lanes[lane].knots.first(where: { $0.day == day })
    else { return }
    let items = Set(knot.itemIDs)
    for weft in loom.wefts where items.contains(weft.itemID) && weft.lanes.contains(lane) {
      guard let top = weft.lanes.first, let bottom = weft.lanes.last else { continue }
      let x = layout.x(weft.day)
      guard dots else {
        var line = Path()
        line.move(to: CGPoint(x: x, y: layout.y(top)))
        line.addLine(to: CGPoint(x: x, y: layout.y(bottom)))
        context.stroke(
          line, with: .color(tones.ink.opacity(0.8)),
          style: StrokeStyle(lineWidth: 1.3, dash: [2, 3]))
        continue
      }
      for crossed in weft.lanes {
        let c = CGPoint(x: x, y: layout.y(crossed))
        context.fill(
          Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)),
          with: .color(tones.ink))
      }
    }
  }

  // MARK: Days, milestones, flags

  private func drawMarks(
    _ context: inout GraphicsContext, _ lane: MemoryLoom.Lane, _ index: Int
  ) {
    let color = palette.thread(index)
    let a = alpha(lane)
    let y = layout.y(index)
    let milestoneDays = Set(lane.milestones.map(\.day))
    for knot in lane.knots where !milestoneDays.contains(knot.day) {
      let hovered = hover == .day(lane: index, day: knot.day)
      let others =
        shared.isEmpty ? 0 : knot.itemIDs.filter { shared.contains($0.uppercased()) }.count
      // Others' days are a little larger, so the second tone reads.
      let r: CGFloat = hovered ? 4.5 : (others > 0 ? 3.6 : 2.6)
      let c = CGPoint(x: layout.x(knot.day), y: y)
      if hovered {
        context.fill(
          Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)),
          with: .color(color.opacity(0.22)))
      }
      let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
      if others == 0 {
        context.fill(dot, with: .color(color.opacity(a)))
      } else {
        // A shared day: others' items in the second tone (half when mixed).
        context.fill(dot, with: .color(palette.mate.opacity(a)))
        if others < knot.itemIDs.count {
          var half = Path()
          half.addArc(
            center: c, radius: r, startAngle: .degrees(90), endAngle: .degrees(270),
            clockwise: false)
          half.closeSubpath()
          context.fill(half, with: .color(color.opacity(a)))
        }
      }
    }
    // Milestones: a hollow circle and, where there is room, a chip above.
    for milestone in lane.milestones {
      let c = CGPoint(x: layout.x(milestone.day), y: y)
      let hovered = hover == .day(lane: index, day: milestone.day)
      let r: CGFloat = hovered ? 7.5 : 6.5
      let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
      context.fill(ring, with: .color(tones.page))
      context.stroke(ring, with: .color(color.opacity(a)), lineWidth: 2.2)
    }
    for (i, rect) in layout.milestoneChips(index) {
      let path = Path(roundedRect: rect, cornerRadius: 6, style: .continuous)
      context.fill(path, with: .color(tones.chip.opacity(a)))
      context.stroke(path, with: .color(tones.chipBorder.opacity(a)), lineWidth: 1)
      context.draw(
        Text(lane.milestones[i].label).font(.zhiji(LoomLayout.milestoneFont))
          .foregroundColor(palette.label.opacity(a)),
        at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }
    // Flags: a small flag on the day and its chip.
    for flag in lane.flags {
      let tint = tones.tint(flag.urgency)
      let base = CGPoint(x: layout.x(flag.day), y: y)
      var pole = Path()
      pole.move(to: base)
      pole.addLine(to: CGPoint(x: base.x, y: base.y - 18))
      context.stroke(pole, with: .color(tint.mark.opacity(a)), lineWidth: 1.6)
      var cloth = Path()
      cloth.move(to: CGPoint(x: base.x, y: base.y - 18))
      cloth.addLine(to: CGPoint(x: base.x + 10, y: base.y - 14.5))
      cloth.addLine(to: CGPoint(x: base.x, y: base.y - 11))
      cloth.closeSubpath()
      context.fill(cloth, with: .color(tint.mark.opacity(a)))
    }
    for (i, rect) in layout.flagChips(index, calendar: calendar) {
      let flag = lane.flags[i]
      let tint = tones.tint(flag.urgency)
      let words = layout.flagWords(flag, calendar: calendar)
      context.fill(
        Path(roundedRect: rect, cornerRadius: 10, style: .continuous),
        with: .color(tint.fill.opacity(a)))
      let text =
        Text(words.day).font(.zhiji(LoomLayout.flagFont, .bold))
        + Text(" " + words.text).font(.zhiji(LoomLayout.flagFont))
      context.draw(
        text.foregroundColor(tint.ink.opacity(a)),
        at: CGPoint(x: rect.minX + 9, y: rect.midY), anchor: .leading)
    }
  }
}
