import BestASRDomain
import BestASRMemory
import SwiftUI

/// 按时间 / 按绳 / 按截止 / 按人.
struct HomeLensBar: View {
  @Environment(\.zhiji) private var palette
  @Binding var lens: MemoryHomeLens

  var body: some View {
    HStack(spacing: 12) {
      ZhijiSegmented(
        options: [
          (MemoryHomeLens.time, ZhijiCopy.byTime), (.ropes, ZhijiCopy.byRope),
          (.deadlines, ZhijiCopy.byDeadline), (.people, ZhijiCopy.byPerson),
        ],
        selection: $lens, height: 28, fontSize: 13, horizontalPadding: 14
      )
      .accessibilityIdentifier("bestASR.memory.homeLens")
      if lens == .ropes {
        Text(ZhijiCopy.ropesCaption).font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
      Spacer(minLength: 0)
    }
  }
}

/// A matter's activity in the lenses' window: a thin line from its first to
/// its last day, a dot a day as big as what it took in, flags for planned
/// days, and "now" as a dashed tick.
struct MiniThread: View {
  @Environment(\.zhiji) private var palette
  let strip: MemoryActivityStrip?
  let lenses: MemoryHomeLenses
  let color: Color
  var width: CGFloat = 280
  var height: CGFloat = 22

  var body: some View {
    let tones = HomeTones(palette)
    Canvas { context, size in
      let days = CGFloat(max(lenses.windowDays - 1, 1))
      func x(_ day: Int) -> CGFloat { 4 + CGFloat(day) / days * (size.width - 8) }
      let mid = size.height / 2
      var now = Path()
      now.move(to: CGPoint(x: x(lenses.todayIndex), y: 2))
      now.addLine(to: CGPoint(x: x(lenses.todayIndex), y: size.height - 2))
      context.stroke(
        now, with: .color(palette.tertiary), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
      guard let strip else { return }
      if let first = strip.firstDay, let last = strip.lastDay {
        var line = Path()
        line.move(to: CGPoint(x: x(first), y: mid))
        line.addLine(to: CGPoint(x: max(x(last), x(first) + 2), y: mid))
        context.stroke(
          line, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
      }
      for (day, count) in strip.days {
        let r = 1.4 + CGFloat(min(count, 6)) * 0.3
        context.fill(
          Path(ellipseIn: CGRect(x: x(day) - r, y: mid - r, width: r * 2, height: r * 2)),
          with: .color(color))
      }
      for day in strip.flags {
        let tint = tones.tint(countdown: day - lenses.todayIndex)
        var flag = Path()
        flag.move(to: CGPoint(x: x(day), y: mid + 4))
        flag.addLine(to: CGPoint(x: x(day), y: mid - 8))
        flag.addLine(to: CGPoint(x: x(day) + 7, y: mid - 5))
        flag.addLine(to: CGPoint(x: x(day), y: mid - 2))
        context.stroke(flag, with: .color(tint.mark), lineWidth: 1.4)
        context.fill(flag, with: .color(tint.mark))
      }
    }
    .frame(width: width, height: height)
    .accessibilityHidden(true)
  }
}

/// The window's dates above a column of strips.
struct MiniAxis: View {
  @Environment(\.zhiji) private var palette
  let lenses: MemoryHomeLenses
  let calendar: Calendar
  var width: CGFloat = 280

  var body: some View {
    Canvas { context, size in
      let days = CGFloat(max(lenses.windowDays - 1, 1))
      func x(_ day: Int) -> CGFloat { 4 + CGFloat(day) / days * (size.width - 8) }
      for day in stride(from: 0, to: lenses.windowDays, by: 14)
      where abs(day - lenses.todayIndex) > 4 {
        let date =
          calendar.date(byAdding: .day, value: day, to: lenses.windowStart) ?? lenses.windowStart
        let parts = calendar.dateComponents([.month, .day], from: date)
        context.draw(
          Text("\(parts.month ?? 0)/\(parts.day ?? 0)").font(.zhiji(11)).monospacedDigit()
            .foregroundColor(palette.tertiary),
          at: CGPoint(x: x(day), y: size.height / 2), anchor: .center)
      }
      context.draw(
        Text(ZhijiCopy.loomToday).font(.zhiji(11, .semibold)).foregroundColor(palette.label),
        at: CGPoint(x: x(lenses.todayIndex), y: size.height / 2), anchor: .center)
    }
    .frame(width: width, height: 16)
    .accessibilityHidden(true)
  }
}

// MARK: - 按绳

/// Rope bands: each rope with its matters, the ropes inside it indented
/// under it (two levels at a time), then the matters on no rope. A proposed
/// rope has 确认 / 不对; a rope can be renamed; a matter can be moved to
/// another rope from its row.
struct RopeBandsView: View {
  @Environment(\.zhiji) private var palette
  @Environment(\.zhijiSnapshot) private var snapshot
  let lenses: MemoryHomeLenses
  let state: MemoryScreenState
  let actions: MemoryActions
  let open: (String) -> Void
  @State private var collapsed = Set<String>()
  @State private var expanded = Set<String>()
  @State private var renaming: String?

  static let rowsShown = 6
  static let stripWidth: CGFloat = 300

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      if lenses.bands.isEmpty {
        Text(ZhijiCopy.noRopesYet).font(.zhiji(13)).foregroundStyle(palette.secondary)
      }
      ForEach(lenses.bands) { band in
        bandView(band)
      }
      if !lenses.unroped.isEmpty {
        unropedView
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bestASR.memory.ropeBands")
  }

  private func bandView(_ band: MemoryHomeLenses.RopeBand) -> AnyView {
    let isCollapsed = collapsed.contains(band.id)
    return AnyView(
      VStack(alignment: .leading, spacing: 0) {
        header(band, collapsed: isCollapsed)
        if !isCollapsed {
          let shown =
            expanded.contains(band.id) ? band.entries : Array(band.entries.prefix(Self.rowsShown))
          ForEach(shown) { entry in
            row(entry, depth: band.depth, rope: band.rope.id)
          }
          if band.entries.count > shown.count {
            moreButton(band.entries.count - shown.count) { expanded.insert(band.id) }
              .padding(.leading, CGFloat(band.depth) * 24 + 18)
          }
          // Two levels at a time: a rope inside a rope inside this one is a
          // collapsed band of its own until opened.
          ForEach(band.children) { child in
            bandView(child)
              .padding(.leading, 24)
              .padding(.top, 8)
          }
        }
      }
      .padding(.bottom, 4)
      .overlay(alignment: .bottom) {
        if band.depth == 0 {
          Rectangle().fill(palette.separator.opacity(0.7)).frame(height: 1)
        }
      }
      .onAppear {
        if band.depth >= 2 { collapsed.insert(band.id) }
      })
  }

  private func header(_ band: MemoryHomeLenses.RopeBand, collapsed isCollapsed: Bool) -> some View {
    let rope = band.rope
    let tones = HomeTones(palette)
    return HStack(alignment: .center, spacing: 8) {
      Button {
        if isCollapsed { collapsed.remove(band.id) } else { collapsed.insert(band.id) }
      } label: {
        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(palette.secondary)
          .frame(width: 18, height: 18)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isCollapsed ? ZhijiCopy.show : ZhijiCopy.collapse)
      Text(rope.title)
        .font(.zhiji(band.depth == 0 ? 16 : 14, .semibold))
        .foregroundStyle(palette.label)
        .lineLimit(1)
        .contextMenu { Button(ZhijiCopy.renameRope) { renaming = rope.id } }
        .popover(
          isPresented: Binding(
            get: { renaming == rope.id }, set: { if !$0 { renaming = nil } }), arrowEdge: .bottom
        ) {
          NamePopover(
            prompt: ZhijiCopy.renameRope, initial: rope.title,
            save: { title in
              renaming = nil
              actions.relation(.renameRope(rope.id, title: title))
            }, cancel: { renaming = nil })
        }
      if let kind = rope.kind {
        Text(kind == "area" ? ZhijiCopy.ropeArea : ZhijiCopy.ropeProject)
          .font(.zhiji(11)).foregroundStyle(palette.secondary)
          .padding(.horizontal, 6).frame(height: 18)
          .background(palette.quietFill, in: Capsule())
      }
      Text(ZhijiCopy.mattersCount(band.total)).font(.zhiji(12)).monospacedDigit()
        .foregroundStyle(palette.secondary)
      if rope.proposed {
        Text(ZhijiCopy.proposedRope).font(.zhiji(11, .semibold))
          .foregroundStyle(tones.amber.ink)
          .padding(.horizontal, 6).frame(height: 18)
          .background(tones.amber.fill, in: Capsule())
        CapsuleButton(title: ZhijiCopy.confirmRope, height: 22, fontSize: 12) {
          actions.relation(.confirmRope(rope.id))
        }
        .accessibilityIdentifier("bestASR.memory.confirmRope")
        CapsuleButton(title: ZhijiCopy.rejectRope, height: 22, fontSize: 12) {
          actions.relation(.rejectRope(rope.id))
        }
        .accessibilityIdentifier("bestASR.memory.rejectRope")
      }
      Spacer(minLength: 8)
      if band.depth == 0 {
        MiniAxis(lenses: lenses, calendar: state.calendar, width: Self.stripWidth)
      }
    }
    .padding(.vertical, 8)
    .help(rope.reason)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      [rope.title, ZhijiCopy.mattersCount(band.total), rope.proposed ? ZhijiCopy.proposedRope : ""]
        .filter { !$0.isEmpty }.joined(separator: "，")
    )
    .accessibilityAction(named: ZhijiCopy.renameRope) { renaming = rope.id }
  }

  private var unropedView: some View {
    let id = "__unroped"
    let isCollapsed = collapsed.contains(id)
    let shown =
      expanded.contains(id) ? lenses.unroped : Array(lenses.unroped.prefix(Self.rowsShown + 2))
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Button {
          if isCollapsed { collapsed.remove(id) } else { collapsed.insert(id) }
        } label: {
          Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.secondary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Text(ZhijiCopy.unroped).font(.zhiji(16, .semibold)).foregroundStyle(palette.label)
        Text(ZhijiCopy.mattersCount(lenses.unroped.count)).font(.zhiji(12))
          .foregroundStyle(palette.secondary)
        Spacer()
      }
      .padding(.vertical, 8)
      if !isCollapsed {
        ForEach(shown) { entry in row(entry, depth: 0, rope: nil) }
        if lenses.unroped.count > shown.count {
          moreButton(lenses.unroped.count - shown.count) { expanded.insert(id) }
            .padding(.leading, 18)
        }
      }
    }
  }

  private func row(_ entry: MemoryHomeEntry, depth: Int, rope: String?) -> some View {
    let color = palette.thread(MatterColors.index(of: entry.eventID, state: state))
    let status =
      entry.statusLine.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return HStack(spacing: 10) {
      Circle().fill(color).frame(width: 8, height: 8)
      Text(entry.title).font(.zhiji(13, .semibold)).foregroundStyle(palette.label).lineLimit(1)
        .frame(maxWidth: 260, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
      Text(status).font(.zhiji(12))
        .foregroundStyle(entry.statusIsFallback ? palette.tertiary : palette.secondary)
        .lineLimit(1)
      Spacer(minLength: 8)
      MiniThread(
        strip: lenses.activity[entry.eventID], lenses: lenses, color: color,
        width: Self.stripWidth)
    }
    .padding(.vertical, 7)
    .padding(.leading, 18)
    .contentShape(Rectangle())
    .zhijiActivatable { open(entry.eventID) }
    .contextMenu { moveMenu(entry.eventID, current: rope) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(entry.title)，\(status)")
    .accessibilityIdentifier("bestASR.memory.ropeRow")
  }

  @ViewBuilder
  private func moveMenu(_ eventID: String, current: String?) -> some View {
    Menu(ZhijiCopy.moveToRope) {
      ForEach(allRopes.filter { $0.id != current }, id: \.id) { rope in
        Button(ZhijiCopy.ropeLabel(rope.title, proposed: rope.proposed)) {
          actions.relation(.moveToRope(eventID: eventID, ropeID: rope.id))
        }
      }
    }
    if current != nil {
      Button(ZhijiCopy.offRope) { actions.relation(.moveToRope(eventID: eventID, ropeID: nil)) }
    }
  }

  private var allRopes: [RemoteOrganizerRope] { state.projection?.ropes ?? [] }

  private func moreButton(_ count: Int, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(ZhijiCopy.moreMatters(count)).font(.zhiji(12)).foregroundStyle(palette.accent)
        .padding(.vertical, 6)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - 按截止

/// The ladder: 刚过去 (still not marked done), 今天, 明天, 这周, 以后.
struct DeadlineLadderView: View {
  @Environment(\.zhiji) private var palette
  let lenses: MemoryHomeLenses
  let state: MemoryScreenState
  let open: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      ForEach(lenses.rungs) { rung in
        rungView(rung)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bestASR.memory.ladder")
  }

  private func rungView(_ rung: MemoryHomeLenses.Rung) -> some View {
    let tones = HomeTones(palette)
    let tint = tint(rung.kind, tones)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        RoundedRectangle(cornerRadius: 2).fill(tint.mark).frame(width: 4, height: 16)
          .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
        Text(name(rung.kind)).font(.zhiji(16, .semibold)).foregroundStyle(palette.label)
          .accessibilityAddTraits(.isHeader)
        Text(subtitle(rung)).font(.zhiji(12)).monospacedDigit().foregroundStyle(palette.secondary)
      }
      if rung.deadlines.isEmpty {
        Text(ZhijiCopy.nothing).font(.zhiji(12)).foregroundStyle(palette.tertiary)
          .padding(.leading, 12)
      }
      ForEach(rung.deadlines) { deadline in
        row(deadline, tones)
      }
    }
  }

  private func row(_ deadline: MemoryHomeLenses.Deadline, _ tones: HomeTones) -> some View {
    let tint = tones.tint(countdown: deadline.daysAway)
    let color = palette.thread(MatterColors.index(of: deadline.eventID, state: state))
    return HStack(spacing: 10) {
      Text(dayChip(deadline))
        .font(.zhiji(11, .semibold)).monospacedDigit()
        .foregroundStyle(tint.ink)
        .padding(.horizontal, 8).frame(minWidth: 64).frame(height: 22)
        .background(tint.fill, in: Capsule())
      Text(deadline.text).font(.zhiji(13)).foregroundStyle(palette.label).lineLimit(1)
      Spacer(minLength: 8)
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 7, height: 7)
        Text(deadline.title).font(.zhiji(12)).foregroundStyle(palette.secondary).lineLimit(1)
      }
      .frame(maxWidth: 300, alignment: .trailing)
    }
    .padding(.vertical, 6)
    .padding(.leading, 12)
    .contentShape(Rectangle())
    .zhijiActivatable { open(deadline.eventID) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(dayChip(deadline))，\(deadline.text)，\(deadline.title)")
    .accessibilityIdentifier("bestASR.memory.deadline")
  }

  private func dayChip(_ deadline: MemoryHomeLenses.Deadline) -> String {
    switch deadline.daysAway {
    case 0: return ZhijiCopy.loomToday
    case 1: return ZhijiCopy.loomTomorrow
    case 2: return ZhijiCopy.loomDayAfter
    default:
      let parts = state.calendar.dateComponents([.month, .day, .weekday], from: deadline.date)
      let weekday = MemoryDateText.weekdays[((parts.weekday ?? 1) - 1 + 7) % 7]
      return "\(parts.month ?? 0)/\(parts.day ?? 0) \(weekday)"
    }
  }

  private func name(_ kind: MemoryHomeLenses.Rung.Kind) -> String {
    switch kind {
    case .justPassed: ZhijiCopy.rungJustPassed
    case .today: ZhijiCopy.rungToday
    case .tomorrow: ZhijiCopy.rungTomorrow
    case .thisWeek: ZhijiCopy.rungThisWeek
    case .later: ZhijiCopy.rungLater
    }
  }

  private func subtitle(_ rung: MemoryHomeLenses.Rung) -> String {
    func md(_ date: Date?) -> String {
      guard let date else { return "" }
      let parts = state.calendar.dateComponents([.month, .day], from: date)
      return "\(parts.month ?? 0)/\(parts.day ?? 0)"
    }
    let span: String
    switch rung.kind {
    case .justPassed: span = "\(md(rung.from))–\(md(rung.to))，\(ZhijiCopy.notMarkedDone)"
    case .today, .tomorrow:
      span = rung.from.map { LoomPanel.monthDay($0, state.calendar, weekday: true) } ?? ""
    case .thisWeek: span = "\(md(rung.from))–\(md(rung.to))"
    case .later: span = ZhijiCopy.afterAWeek
    }
    return "\(span) · \(ZhijiCopy.stepsCount(rung.deadlines.count))"
  }

  private func tint(_ kind: MemoryHomeLenses.Rung.Kind, _ tones: HomeTones) -> HomeTones.Tint {
    switch kind {
    case .justPassed, .thisWeek: tones.amber
    case .today, .tomorrow: tones.red
    case .later: tones.gray
    }
  }
}

// MARK: - 按人

/// The people who matter, each with their matters (at most five) and their
/// activity.
struct PeopleLensView: View {
  @Environment(\.zhiji) private var palette
  let lenses: MemoryHomeLenses
  let state: MemoryScreenState
  let open: (MemoryRoute) -> Void

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)],
      alignment: .leading, spacing: 16
    ) {
      ForEach(lenses.people) { lane in
        card(lane)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bestASR.memory.peopleLens")
  }

  private func card(_ lane: MemoryHomeLenses.PersonLane) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Avatar(lane.person, size: 34)
        VStack(alignment: .leading, spacing: 2) {
          Text(lane.person.name).font(.zhiji(15, .semibold)).foregroundStyle(palette.label)
          Text(ZhijiCopy.personMatters(lane.total)).font(.zhiji(12)).monospacedDigit()
            .foregroundStyle(palette.secondary)
        }
        Spacer()
      }
      .contentShape(Rectangle())
      .zhijiActivatable { open(.person(lane.person.personID)) }
      .accessibilityElement(children: .combine)
      VStack(alignment: .leading, spacing: 2) {
        ForEach(lane.entries) { entry in
          let color = palette.thread(MatterColors.index(of: entry.eventID, state: state))
          HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(entry.title).font(.zhiji(13)).foregroundStyle(palette.label).lineLimit(1)
            Spacer(minLength: 6)
            MiniThread(
              strip: lenses.activity[entry.eventID], lenses: lenses, color: color, width: 96)
          }
          .padding(.vertical, 4)
          .contentShape(Rectangle())
          .zhijiActivatable { open(.event(entry.eventID)) }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(entry.title)
        }
        if lane.total > lane.entries.count {
          Text(ZhijiCopy.moreMatters(lane.total - lane.entries.count)).font(.zhiji(12))
            .foregroundStyle(palette.secondary).padding(.leading, 15)
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      palette.isDark ? palette.surface : .white,
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.separator))
  }
}
