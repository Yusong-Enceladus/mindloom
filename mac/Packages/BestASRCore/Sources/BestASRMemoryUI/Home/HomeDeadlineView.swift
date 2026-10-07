import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-home. S2 · Home 按截止 (MAC-SPEC §4.2): `state.digest.deadlines`
// grouped 已过期 · 快到期 · 这周 · 下周 · 下下周 · {N}月 · 以后; a row opens the
// matter with that step's popover (`navigator.openMatter(_, step:)`).

/// 按截止's input: which matters (nil = every live matter; a group or space
/// passes its own).
public struct HomeDeadlineInput: Equatable, Sendable {
  public let eventIDs: Set<String>?

  public init(eventIDs: Set<String>?) { self.eventIDs = eventIDs }
}

public struct HomeDeadlineView: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let context: MindloomPageContext
  let input: HomeDeadlineInput
  @FocusState private var focused: String?
  @State private var keyboard = false

  public init(context: MindloomPageContext, input: HomeDeadlineInput) {
    self.context = context
    self.input = input
  }

  public var body: some View {
    let days = HomeDays(context.state)
    let groups = HomeDerivation.deadlineGroups(
      context.state.digest, eventIDs: input.eventIDs, days: days)
    let order = groups.flatMap { $0.entries.map(\.id) }
    // Rows are drawn as they scroll in (理1-6).
    LazyVStack(alignment: .leading, spacing: 0) {
      if groups.isEmpty {
        HomeEmptyMessage(title: "近期没有截止日期").padding(.top, 140)
      }
      ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
        HomeGroupHeader(title: group.title, range: group.range, first: index == 0)
        ForEach(group.entries) { entry in
          row(entry, days: days)
            .focusable(!snapshot)
            .focusEffectDisabled()
            .focused($focused, equals: entry.id)
            .onKeyPress(.return) {
              open(entry)
              return .handled
            }
        }
      }
    }
    .padding(.top, 8)
    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
      guard let current = focused, let at = order.firstIndex(of: current) else { return .ignored }
      keyboard = true
      focused = order[press.key == .downArrow ? min(at + 1, order.count - 1) : max(at - 1, 0)]
      return .handled
    }
  }

  private func open(_ entry: HomeDerivation.DeadlineEntry) {
    context.navigator.openMatter(entry.matter.eventID, step: entry.stepID)
  }

  private func row(_ entry: HomeDerivation.DeadlineEntry, days: HomeDays) -> some View {
    let word = entry.n < 0 ? "已过期" : days.dueWord(entry.n)
    let title =
      ([entry.matter] + entry.also).map { MLAutospace.apply($0.title) }.joined(separator: " · ")
    return HStack(alignment: .firstTextBaseline, spacing: 20) {
      VStack(alignment: .leading, spacing: 0) {
        if let word {
          Text(word).foregroundStyle(MLColor.alert).mlLineBox(\.sub)
          if entry.n < 0 {
            Text(days.md(entry.n)).foregroundStyle(MLColor.ink2).mlLineBox(\.sub)
          }
        } else {
          Text(days.mdw(entry.n)).foregroundStyle(MLColor.ink2).mlLineBox(\.sub)
        }
      }
      .mlFont(\.sub)
      .monospacedDigit()
      .padding(.top, 2)
      .frame(width: 112, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Text(MLAutospace.apply(entry.text))
          .mlFont(\.headline)
          .foregroundStyle(MLColor.ink)
          .fixedSize(horizontal: false, vertical: true)
          .mlLineBox(\.headline)
        Text(title)
          .mlFont(\.sub)
          .foregroundStyle(MLColor.ink2)
          .fixedSize(horizontal: false, vertical: true)
          .mlLineBox(\.sub)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .frame(minHeight: 52)
    .modifier(HomeRowChrome())
    .modifier(HomeFocusRing(on: keyboard && focused == entry.id && !snapshot))
    .padding(.horizontal, -12)
    .onTapGesture { open(entry) }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isLink)
    .accessibilityAction { open(entry) }
  }
}
