import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-home. S1 · Home 按时间 (MAC-SPEC §4.1): 「刚收进来」, the sticky
// axis, groups 已过期 · 快到期 · 这周 · 上周 · 更早 with risk text, rows with
// their track (dots, hover tips), the today rule, the lit row
// (`state.highlightedEventID`), FLIP re-ordering (M7, M8). Also used by group
// and space pages with their own `HomeListInput`.

/// 按时间 for a list of matters.
public struct HomeTimeView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.zhijiSnapshot) private var snapshot
  let context: MindloomPageContext
  let input: HomeListInput
  @FocusState private var focused: String?
  @State private var keyboard = false
  /// While a row is lit after filing, the list keeps its order (M9: on Home
  /// nothing moves or scrolls); 3 s later it glides to the new order (M7).
  @State private var frozen: [FrozenLine]?

  public init(context: MindloomPageContext, input: HomeListInput) {
    self.context = context
    self.input = input
  }

  /// One line of the list: a group header or a row (flat, so every element
  /// glides to its new place in one move).
  private enum Line: Identifiable {
    case header(HomeDerivation.TimeGroupKind, first: Bool)
    case row(MatterDigest, HomeDerivation.TimeGroupKind)

    var id: String {
      switch self {
      case .header(let kind, _): "g-" + kind.rawValue
      case .row(let matter, _): matter.eventID
      }
    }
  }

  public var body: some View {
    let state = context.state
    let days = HomeDays(state)
    let groups = HomeDerivation.timeGroups(input.matters, days: days)
    let fresh = lines(groups)
    let lines = frozenLines(fresh) ?? fresh
    let captures = input.showsCaptures ? state.waitingCaptures : []
    VStack(alignment: .leading, spacing: 0) {
      if !captures.isEmpty {
        HomeGroupHeader(title: "最近添加", first: true)
          .padding(.top, 6)
        WaitingCountLine(context: context, shown: captures.count)
        ForEach(captures) { capture in
          WaitingCaptureRow(state: state, capture: capture)
            .transition(captureTransition)
        }
      }
      if !groups.isEmpty {
        HomeAxisView(days: days)
        list(lines, days: days)
      }
    }
    .animation(reduceMotion || snapshot ? nil : MLSpring.smooth.animation, value: lines.map(\.id))
    .onChange(of: state.highlightedEventID) { _, lit in
      guard lit != nil, !snapshot else { return }
      frozen = fresh.map(FrozenLine.init)
    }
    .task(id: frozen == nil) {
      guard frozen != nil else { return }
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      frozen = nil
    }
    .animation(
      reduceMotion || snapshot ? nil : MLSpring.gentle.animation, value: captures.map(\.id))
  }

  /// A line of a frozen order, by ID.
  private struct FrozenLine: Equatable {
    let id: String
    let kind: HomeDerivation.TimeGroupKind
    let first: Bool
    let isHeader: Bool

    init(_ line: Line) {
      switch line {
      case .header(let kind, let first):
        self.id = line.id
        self.kind = kind
        self.first = first
        self.isHeader = true
      case .row(_, let kind):
        self.id = line.id
        self.kind = kind
        self.first = false
        self.isHeader = false
      }
    }
  }

  /// The frozen order with today's values, when the same rows are shown.
  private func frozenLines(_ fresh: [Line]) -> [Line]? {
    guard let frozen else { return nil }
    var matters: [String: MatterDigest] = [:]
    for line in fresh {
      if case .row(let matter, _) = line { matters[matter.eventID] = matter }
    }
    let frozenRows = frozen.filter { !$0.isHeader }.map(\.id)
    guard Set(frozenRows) == Set(matters.keys) else { return nil }
    return frozen.compactMap { line in
      line.isHeader
        ? .header(line.kind, first: line.first) : matters[line.id].map { .row($0, line.kind) }
    }
  }

  private func lines(_ groups: [HomeDerivation.TimeGroup]) -> [Line] {
    var out: [Line] = []
    // The prototype's list starts with the today rule, so even its first
    // header is not `:first-child`: 24 pt above it, like every other one.
    for group in groups {
      out.append(.header(group.kind, first: false))
      if group.kind == .earlier && !context.navigation.earlierOpen { continue }
      out += group.matters.map { .row($0, group.kind) }
    }
    return out
  }

  private var captureTransition: AnyTransition {
    reduceMotion
      ? .opacity
      : .asymmetric(
        insertion: .modifier(
          active: RiseIn(offset: -8, opacity: 0), identity: RiseIn(offset: 0, opacity: 1)),
        removal: .opacity)
  }

  private var rowTransition: AnyTransition {
    .asymmetric(
      insertion: .opacity.animation(MLMotion.easeOut(MLMotion.durBase).delay(0.12)),
      removal: .opacity.animation(MLMotion.easeOut(MLMotion.durFast)))
  }

  private func list(_ lines: [Line], days: HomeDays) -> some View {
    let rows = lines.compactMap { line -> String? in
      if case .row = line { return line.id }
      return nil
    }
    // Rows are drawn as they scroll in (理1-6: a library of thousands).
    return LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(lines) { line in
        switch line {
        case .header(let kind, let first):
          if kind == .earlier {
            earlierHeader(first: first)
          } else {
            HomeGroupHeader(title: kind.rawValue, first: first)
          }
        case .row(let matter, let kind):
          let track = HomeDerivation.track(
            matter, days: days, fresh: context.state.highlightedEventID == matter.eventID)
          HomeMatterRow(
            context: context, matter: matter,
            second: HomeDerivation.secondLine(
              matter, days: days, sharedBy: input.sharedBy[matter.eventID],
              withRisk: kind.showsRisk),
            track: track, lit: context.state.highlightedEventID == matter.eventID,
            selected: input.selectedEventID == matter.eventID,
            focused: keyboard && focused == matter.eventID
          )
          .focusable(!snapshot)
          .focusEffectDisabled()
          .focused($focused, equals: matter.eventID)
          .onKeyPress(.return) {
            context.navigator.openMatter(matter.eventID)
            return .handled
          }
          .anchorPreference(key: TrackedRowsKey.self, value: .bounds) {
            track.isDrawn ? [$0] : []
          }
          .transition(rowTransition)
        }
      }
    }
    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
      guard let current = focused, let at = rows.firstIndex(of: current) else { return .ignored }
      let next = press.key == .downArrow ? min(at + 1, rows.count - 1) : max(at - 1, 0)
      keyboard = true
      focused = rows[next]
      return .handled
    }
    .backgroundPreferenceValue(TrackedRowsKey.self) { anchors in
      GeometryReader { geometry in
        let bottom = anchors.map { geometry[$0].maxY }.max() ?? 0
        Rectangle()
          .fill(MLColor.accent)
          .opacity(0.6)
          .frame(width: 1, height: max(0, bottom - 6))
          .offset(x: geometry.size.width - HomeTrackWindow.width + HomeTrackWindow.x(0) - 0.5)
      }
      .allowsHitTesting(false)
    }
  }

  private func earlierHeader(first: Bool) -> some View {
    let open = context.navigation.earlierOpen
    return Button {
      context.navigator.setEarlierOpen(!open)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .rotationEffect(.degrees(open ? 0 : -90))
          .animation(reduceMotion ? nil : MLMotion.easeOut(MLMotion.durBase), value: open)
        Text("更早").mlFont(\.section)
      }
      .foregroundStyle(MLColor.ink2)
      .padding(.vertical, 2)
      .padding(.trailing, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.top, first ? 12 : 24)
    .padding(.bottom, 6)
    .accessibilityValue(open ? "已展开" : "已折叠")
  }
}

/// Rows with a drawn track (the today rule stops at the last one).
private struct TrackedRowsKey: PreferenceKey {
  static let defaultValue: [Anchor<CGRect>] = []
  static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
    value += nextValue()
  }
}

/// M8: a new waiting capture comes in from −8 pt.
struct RiseIn: ViewModifier {
  let offset: CGFloat
  let opacity: Double

  func body(content: Content) -> some View {
    content.offset(y: offset).opacity(opacity)
  }
}

/// Under 「刚收进来」 (v12, 理1-4): how many records wait to be organized
/// (「32 条等整理」) when the DGX Spark is not organizing them — the offline
/// line already says it while the link is down — and, when more wait than
/// the few shown, 「在历史里看全部」 (every record, newest first).
struct WaitingCountLine: View {
  let context: MindloomPageContext
  let shown: Int

  var body: some View {
    let total = context.state.homeExtras.waitingTotal
    let count = !context.state.link.showsNotConnected && total > 0
    let more = total > shown
    if count || more {
      HStack(spacing: 0) {
        if count {
          Text("\(total) 条等待整理")
            .foregroundStyle(MLColor.ink2)
            .monospacedDigit()
        }
        if count && more {
          Text("·").foregroundStyle(MLColor.ink3).padding(.horizontal, 6.5)
        }
        if more {
          Button("在“历史”中查看全部") { context.navigator.openRoot(.search) }
            .buttonStyle(.plain)
            .foregroundStyle(MLColor.accent)
        }
      }
      .mlFont(\.sub, lineBox: true)
      .padding(.bottom, 4)
      .accessibilityElement(children: .combine)
    }
  }
}
