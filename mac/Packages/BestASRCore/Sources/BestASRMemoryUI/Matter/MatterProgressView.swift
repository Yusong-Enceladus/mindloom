import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-matter. S6 · 进展 time view (MAC-SPEC §4.7, §4.8): one lane per
// part (`matter.parts`), the true date axis with 今天, per lane the latest ●
// and at most two ○ (vermilion when due or overdue), far marks at the
// right, labels placed without overlap, the 经过 segment, 待定 below
// (`matter.openQuestions`). Steps: `matter.steps` (overrides applied).
// Geometry: `MatterTimeLayout`; drawing: a `Canvas` for the lines plus
// positioned buttons for names, marks, labels and segments.

public struct MatterProgressInput: Equatable, Sendable {
  public let matter: MatterDigest
  public let popover: MatterPopover?

  public init(matter: MatterDigest, popover: MatterPopover?) {
    self.matter = matter
    self.popover = popover
  }
}

extension EnvironmentValues {
  /// A part's segment was clicked `dx` points from its start (the 经过
  /// popover is anchored there).
  @Entry var matterSegmentClick: (String, CGFloat) -> Void = { _, _ in }
}

public struct MatterProgressView: View {
  let context: MindloomPageContext
  let input: MatterProgressInput

  public init(context: MindloomPageContext, input: MatterProgressInput) {
    self.context = context
    self.input = input
  }

  private var selectedStep: String? {
    if case .step(let id)? = input.popover { return id }
    return nil
  }

  public var body: some View {
    let state = context.state
    // The height depends on the lanes only, not on the width.
    let probe = MatterTimeLayout(
      matter: input.matter, width: 884, today: state.today, calendar: state.calendar,
      measure: { text, _ in CGFloat(text.count) * 13 })
    VStack(alignment: .leading, spacing: 0) {
      Color.clear
        .frame(maxWidth: .infinity)
        .frame(height: probe.height)
        .overlay(alignment: .topLeading) {
          GeometryReader { geometry in
            MatterTimeCanvas(
              context: context,
              layout: MatterTimeLayout(
                matter: input.matter, width: geometry.size.width, today: state.today,
                calendar: state.calendar),
              eventID: input.matter.eventID, selectedStep: selectedStep,
              selectedSegment: {
                if case .segment(let id)? = input.popover { return id }
                return nil
              }())
          }
        }
        .padding(.top, 30)
      if !probe.open.isEmpty {
        MatterOpenList(context: context, steps: probe.open, selected: selectedStep)
          .frame(maxWidth: 760, alignment: .leading)
          .padding(.top, 8)
      }
    }
  }
}

// MARK: - Pins

/// Where a subview of `PinLayout` goes: a point, the subview's own anchor
/// at it, and an optional proposed size.
struct Pin: Equatable {
  var point: CGPoint
  var anchor: UnitPoint = .center
  var width: CGFloat?
  var height: CGFloat?
}

struct PinKey: LayoutValueKey {
  static let defaultValue = Pin(point: .zero)
}

extension View {
  func pinned(
    _ point: CGPoint, anchor: UnitPoint = .center, width: CGFloat? = nil, height: CGFloat? = nil
  ) -> some View {
    layoutValue(
      key: PinKey.self, value: Pin(point: point, anchor: anchor, width: width, height: height))
  }
}

/// Places each subview at its pin (absolute positions inside the proposed
/// size, as the prototype's absolutely positioned time view).
struct PinLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for subview in subviews {
      let pin = subview[PinKey.self]
      subview.place(
        at: CGPoint(x: bounds.minX + pin.point.x, y: bounds.minY + pin.point.y), anchor: pin.anchor,
        proposal: ProposedViewSize(width: pin.width, height: pin.height))
    }
  }
}

// MARK: - The time view

struct MatterTimeCanvas: View {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let context: MindloomPageContext
  let layout: MatterTimeLayout
  let eventID: String
  let selectedStep: String?
  let selectedSegment: String?

  private var calendar: Calendar { context.state.calendar }

  var body: some View {
    let selectedMark = selectedStep.flatMap { layout.mark(holding: $0) }
    PinLayout {
      lines
        .pinned(.zero, anchor: .topLeading, width: layout.width, height: layout.height)
        .accessibilityHidden(true)
      // Axis.
      ForEach(layout.axis, id: \.day) { label in
        Text(MindloomDates.monthDay(day(label.day), calendar: calendar))
          .mlFont(\.foot, lineBox: true)
          .foregroundStyle(MLColor.ink2)
          .fixedSize()
          .pinned(CGPoint(x: label.x, y: MatterTimeLayout.axisY - 24), anchor: .top)
          .accessibilityHidden(true)
      }
      Text("今天")
        .mlFont(\.foot, weight: .medium, lineBox: true)
        .foregroundStyle(MLColor.accent)
        .fixedSize()
        .pinned(CGPoint(x: layout.todayX, y: MatterTimeLayout.axisY - 24), anchor: .top)
        .accessibilityHidden(true)
      // Lanes.
      ForEach(layout.lanes) { lane in
        LaneName(lane: lane, maxWidth: layout.nameColumn - 20)
          .matterAnchor("name:\(lane.id)")
          .pinned(
            CGPoint(x: 0, y: lane.closed ? lane.y - 9 : lane.y),
            anchor: lane.closed ? .topLeading : .leading, width: layout.nameColumn - 20)
      }
      ForEach(layout.segments, id: \.laneID) { segment in
        if let lane = layout.lane(segment.laneID) {
          SegmentButton(
            lane: lane, segment: segment, calendar: calendar, today: context.state.today,
            selected: selectedSegment == lane.id
          ) {
            context.navigator.openPopover(
              selectedSegment == lane.id ? nil : .segment(lane.id))
          }
          .matterAnchor("seg:\(lane.id)")
          .pinned(
            CGPoint(x: segment.x0, y: lane.y), anchor: .leading, width: segment.x1 - segment.x0,
            height: 16)
        }
      }
      ForEach(layout.marks) { mark in
        MarkButton(
          mark: mark, accessibility: markLabel(mark), selected: selectedMark?.id == mark.id
        ) { open(mark.steps[0].id, in: mark) }
        .matterAnchor(mark.steps.map { "step:\($0.id)" })
        .pinned(CGPoint(x: mark.x, y: layout.y(of: mark.laneID)), width: 21, height: 21)
        .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
      }
      ForEach(layout.marks) { mark in
        if let label = mark.label {
          LabelButton(label: label, selected: selectedMark?.id == mark.id) {
            open(mark.steps[0].id, in: mark)
          }
          .matterAnchor(["lab:\(mark.id)"] + mark.steps.map { "own:\($0.id)" })
          .pinned(
            CGPoint(
              x: label.x0,
              y: layout.y(of: mark.laneID) + (label.row < 0 ? -26 : 8)),
            anchor: .topLeading, width: max(label.width, 1), height: 18)
        }
      }
      // A folded step opened from 经过 shows its own dot on its own day.
      if let id = selectedStep, selectedMark == nil, let lane = layout.laneOf[id],
        let step = context.state.matter(eventID)?.step(id), !(step.isOpenQuestion && !step.isDone)
      {
        TempDot()
          .matterAnchor("step:\(id)")
          .pinned(
            CGPoint(x: layout.x(min(day(step.date), 0)), y: layout.y(of: lane)), width: 21,
            height: 21
          )
          .transition(.opacity)
      }
    }
    .frame(width: layout.width, height: layout.height, alignment: .topLeading)
    .animation(
      reduceMotion ? .easeOut(duration: 0.2) : MLSpring.gentle.animation,
      value: layout.marks.map(\.id))
  }

  private func day(_ n: Int) -> Date {
    calendar.date(byAdding: .day, value: n, to: context.state.today) ?? context.state.today
  }

  private func day(_ date: Date) -> Int {
    MemoryDigest.days(from: context.state.today, to: date, calendar: calendar)
  }

  private func open(_ stepID: String, in mark: MatterTimeLayout.Mark) {
    let current = selectedStep.map { mark.contains($0) } ?? false
    context.navigator.openPopover(current ? nil : .step(stepID))
  }

  /// 「{M月D日} {text}」 for ●, 「{when} {text}(，另 {n} 条)?」 otherwise.
  private func markLabel(_ mark: MatterTimeLayout.Mark) -> String {
    let first = mark.steps[0]
    let when =
      mark.kind == .done
      ? MindloomDates.monthDay(first.date, calendar: calendar) : (mark.label?.when ?? "")
    let more = mark.steps.count > 1 ? "，另 \(mark.steps.count - 1) 条" : ""
    return [when, first.text].filter { !$0.isEmpty }.joined(separator: " ") + more
  }

  /// The today rule and the dashed future (segments draw their own line).
  private var lines: some View {
    let layout = layout
    let accent = MLColor.accent.color(for: scheme)
    let ink4 = MLColor.ink4.color(for: scheme)
    return Canvas { canvas, _ in
      var rule = Path()
      rule.move(to: CGPoint(x: layout.todayX, y: MatterTimeLayout.axisY - 2))
      rule.addLine(to: CGPoint(x: layout.todayX, y: layout.height - 14))
      canvas.stroke(rule, with: .color(accent.opacity(0.6)), lineWidth: 1)
      for dash in layout.dashes {
        let y = layout.y(of: dash.laneID)
        var path = Path()
        path.move(to: CGPoint(x: dash.x0, y: y))
        path.addLine(to: CGPoint(x: dash.x1, y: y))
        canvas.stroke(path, with: .color(ink4), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
      }
    }
  }
}

/// A part's name (13 pt medium, autospaced); 「已完成」 under a closed one.
/// Hovering shows the part's summary.
private struct LaneName: View {
  let lane: MatterTimeLayout.Lane
  let maxWidth: CGFloat
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(MLAutospace.apply(lane.name))
        .mlFont(\.label, lineBox: true)
        .foregroundStyle(MLColor.ink)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      if lane.closed {
        Text("已完成").mlFont(\.foot, lineBox: true).foregroundStyle(MLColor.ink2)
      }
    }
    .frame(maxWidth: maxWidth, alignment: .leading)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .overlay(alignment: .top) {
      if hovering, !lane.summary.isEmpty {
        MatterTooltip(text: Text(MLAutospace.apply(lane.summary)))
          .alignmentGuide(.top) { $0[.bottom] + 6 }
          .alignmentGuide(HorizontalAlignment.center) { $0[.leading] + 40 }
          .transition(.opacity)
      }
    }
    .animation(MLMotion.easeOut(MLMotion.durFast), value: hovering)
    .zIndex(hovering ? 2 : 0)
    .accessibilityElement(children: .combine)
    .accessibilityHint(MLAutospace.apply(lane.summary))
  }
}

/// A part's active span: a 1 pt line in a 16 pt hit area; hover tints it
/// and says 「{part}：{M月D日}起(，另有 {n} 条经过)? · 点一下看经过」; a click
/// opens 经过 at the click point.
private struct SegmentButton: View {
  @Environment(\.matterSegmentClick) private var reportClick
  let lane: MatterTimeLayout.Lane
  let segment: MatterTimeLayout.Segment
  let calendar: Calendar
  let today: Date
  let selected: Bool
  let action: () -> Void
  @State private var hovering = false

  private var words: String {
    let date = calendar.date(byAdding: .day, value: segment.firstDay, to: today) ?? today
    let folded = segment.folded > 0 ? "，另有 \(segment.folded) 条经过" : ""
    return MLAutospace.apply(lane.name) + "：" + MindloomDates.monthDay(date, calendar: calendar)
      + "起" + folded
  }

  var body: some View {
    ZStack {
      Capsule().fill(hovering ? MLColor.fill2 : MLColor.transparent)
      Rectangle()
        .fill(hovering ? MLColor.ink3 : MLColor.ink4)
        .frame(height: 1)
    }
    .contentShape(Capsule())
    .onHover { hovering = $0 }
    .onTapGesture(coordinateSpace: .local) { location in
      reportClick(lane.id, location.x)
      action()
    }
    .overlay(alignment: .top) {
      if hovering {
        MatterTooltip(text: Text(words) + Text(" · 点按以查看经过").foregroundStyle(MLColor.ink2))
          .alignmentGuide(.top) { $0[.bottom] + 6 }
          .transition(.opacity)
      }
    }
    .animation(MLMotion.easeOut(MLMotion.durFast), value: hovering)
    .zIndex(hovering ? 2 : 0)
    .accessibilityElement()
    .accessibilityLabel(words)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: "查看经过", action)
  }
}

/// A mark: a 21 pt round hit area holding a 7 pt dot (● / ○ / vermilion ○).
private struct MarkButton: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let mark: MatterTimeLayout.Mark
  let accessibility: String
  let selected: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle().fill(
          selected ? MLColor.accentTint2 : hovering ? MLColor.fill2 : MLColor.transparent)
        MLStatusCircle(mark.kind.status)
          .scaleEffect(hovering && !reduceMotion ? 1.15 : 1)
      }
      .frame(width: 21, height: 21)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(MLMotion.easeOut(MLMotion.durFast), value: hovering)
    .accessibilityLabel(accessibility)
  }
}

/// A mark's label: the step, its day word and 「另 {n} 条」, one line.
private struct LabelButton: View {
  @Environment(\.colorScheme) private var scheme
  let label: MatterTimeLayout.Label
  let selected: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 0) {
        Text(label.text).foregroundStyle(MLColor.ink)
        if let when = label.when {
          Text(when).foregroundStyle(label.whenAlert ? MLColor.alert : MLColor.ink2)
            .padding(.leading, 6.5)
        }
        if label.more > 0 {
          Text("另 \(label.more) 条").foregroundStyle(MLColor.ink2).padding(.leading, 6.5)
        }
      }
      .mlFont(\.sub, lineBox: true)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 3)
      .frame(height: 18)
      .background(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(selected || hovering ? MLColor.accentTint : MLColor.transparent)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .accessibilityHidden(true)
  }
}

/// The temporary selected dot of a folded step while its popover is open.
private struct TempDot: View {
  var body: some View {
    ZStack {
      Circle().fill(MLColor.accentTint2)
      MLStatusCircle(.done)
    }
    .frame(width: 21, height: 21)
    .accessibilityHidden(true)
  }
}

// MARK: - 待定

/// Questions with no date (§4.8): ○ · the question · 「{date}提出 · {source}」.
struct MatterOpenList: View {
  let context: MindloomPageContext
  let steps: [MatterStep]
  let selected: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("待定").mlFont(\.section, lineBox: true).foregroundStyle(MLColor.ink2).padding(.bottom, 6)
      ForEach(steps) { step in
        OpenRow(context: context, step: step, selected: selected == step.id)
      }
    }
  }
}

private struct OpenRow: View {
  let context: MindloomPageContext
  let step: MatterStep
  let selected: Bool
  @State private var hovering = false

  private var asked: String {
    guard let evidence = step.evidence else { return "" }
    let state = context.state
    let day =
      MemoryDigest.days(from: state.today, to: evidence.time, calendar: state.calendar) == 0
      ? "今天" : MindloomDates.monthDay(evidence.time, calendar: state.calendar)
    return day + "提出 · " + evidence.source.word
  }

  var body: some View {
    Button {
      context.navigator.openPopover(selected ? nil : .step(step.id))
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        MLStatusCircle(.next).frame(width: 14).alignmentGuide(.firstTextBaseline) { $0[.bottom] }
        Text(MLAutospace.apply(step.text))
          .mlFont(\.body, lineBox: true)
          .foregroundStyle(MLColor.ink)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(asked).mlFont(\.sub, lineBox: true).foregroundStyle(MLColor.ink2).lineLimit(1).fixedSize()
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 12)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(selected || hovering ? MLColor.fill2 : MLColor.transparent)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, -12)
    .onHover { hovering = $0 }
    .matterAnchor(["step:\(step.id)", "q:\(step.id)"])
    .accessibilityLabel(MLAutospace.apply(step.text) + "，" + asked)
  }
}
