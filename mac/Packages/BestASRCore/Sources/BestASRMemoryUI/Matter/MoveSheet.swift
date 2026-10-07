import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-matter. S14 · 移到哪件事？ (MAC-SPEC §7.4, §7.4.1): the text,
// the field, 「可能是」 (up to 3 likely matters) and 「其他事」; + 新建一件事 ·
// 不属于任何事 · 取消. Results via `actions.correct(.moveItem / .newMatter /
// .takeOut)` and the toasts of §7.6.

public struct MoveSheetInput: Equatable, Sendable {
  public let subject: MoveSubject
  /// A typed filter (still images; the field starts empty in the App).
  public let query: String

  public init(subject: MoveSubject, query: String = "") {
    self.subject = subject
    self.query = query
  }
}

/// What moves, resolved against the page: the item (and part), the words
/// that describe it, and the sheet's sentence.
struct MoveThing: Equatable {
  let eventID: String
  let itemID: String
  let segID: String?
  /// The words the picker guesses from and a new matter is named after.
  let words: String
  /// The first clause, for 新建一件事 (at most 18 characters).
  let newTitle: String
  let sentence: String

  @MainActor
  static func resolve(_ subject: MoveSubject, state: MemoryScreenState) -> MoveThing? {
    switch subject {
    case .step(let eventID, let stepID):
      guard let step = state.matter(eventID)?.step(stepID), let evidence = step.evidence else {
        return nil
      }
      let seg = evidence.rowID.split(separator: "#", maxSplits: 1).dropFirst().first.map(
        String.init)
      return MoveThing(
        eventID: eventID, itemID: evidence.itemID, segID: seg,
        words: step.text + evidence.lines.map(\.words).joined(),
        newTitle: firstClause(step.text),
        sentence: "“\(MLAutospace.apply(step.text))”及其原文将被移动。")
    case .item(let eventID, let itemID, let segID):
      let rowID = segID.map { "\(itemID)#\($0)" }
      let entry = state.matterTexts(eventID, keep: rowID).first {
        $0.itemID.caseInsensitiveCompare(itemID) == .orderedSame && $0.segID == segID
      }
      let first = entry?.lines.first?.words ?? ""
      return MoveThing(
        eventID: eventID, itemID: itemID.uppercased(), segID: segID,
        words: String(first.prefix(40)) + (entry?.lines.map(\.words).joined() ?? ""),
        newTitle: firstClause(first), sentence: "这条原文将被移动。")
    }
  }

  /// 「表2重跑完了，结果稳定」 → 「表2重跑完了」 (split on ，。,；; ≤ 18).
  static func firstClause(_ text: String) -> String {
    let clause =
      text.split(whereSeparator: { "，。,；".contains($0) }).first.map(String.init) ?? text
    let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "新的事" : String(trimmed.prefix(18))
  }
}

/// The picker's options (§7.4): 「可能是」 (matters sharing ≥ 3 points of
/// character bigrams with the moved words: +2 in the title, +1 in status,
/// part names or people; top 3), then 「其他事」 by urgency.
enum MovePicker {
  static func likely(_ words: String, among matters: [MatterDigest]) -> [MatterDigest] {
    let grams = MemoryDisplayText.bigrams(words)
    return matters.map { matter -> (MatterDigest, Int) in
      let title = MemoryDisplayText.bigrams(matter.title)
      let rest = MemoryDisplayText.bigrams(
        matter.status + matter.parts.map(\.name).joined() + matter.people.map(\.name).joined())
      let score = grams.reduce(0) { $0 + (title.contains($1) ? 2 : rest.contains($1) ? 1 : 0) }
      return (matter, score)
    }
    .filter { $0.1 >= 3 }
    .sorted { $0.1 > $1.1 }
    .prefix(3)
    .map(\.0)
  }

  /// Nearest undone date in the next 14 days first (none last), then the
  /// organizer's order, then the latest activity.
  static func byUrgency(_ matters: [MatterDigest], today: Date, calendar: Calendar)
    -> [MatterDigest]
  {
    matters.sorted { a, b in
      let na = a.nextDate(today: today, calendar: calendar) ?? .distantFuture
      let nb = b.nextDate(today: today, calendar: calendar) ?? .distantFuture
      if na != nb { return na < nb }
      if a.rank != b.rank { return a.rank < b.rank }
      return (a.lastDay ?? .distantPast) > (b.lastDay ?? .distantPast)
    }
  }

  /// The filter ignores spaces and case.
  static func matches(_ title: String, _ query: String) -> Bool {
    let q = query.lowercased().filter { !$0.isWhitespace && $0 != "\u{2005}" }
    guard !q.isEmpty else { return true }
    return title.lowercased().filter { !$0.isWhitespace && $0 != "\u{2005}" }.contains(q)
  }
}

public struct MoveSheet: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let context: MindloomPageContext
  let input: MoveSheetInput
  @State private var query = ""
  @State private var selection = 0
  @FocusState private var fieldFocused: Bool

  public init(context: MindloomPageContext, input: MoveSheetInput) {
    self.context = context
    self.input = input
    _query = State(initialValue: input.query)
  }

  private struct Option: Identifiable {
    let matter: MatterDigest
    let likely: Bool
    var id: String { matter.eventID + (likely ? "*" : "") }
  }

  private func options(_ thing: MoveThing) -> (likely: [MatterDigest], rest: [MatterDigest]) {
    let state = context.state
    let others = (state.digest?.matters ?? []).filter { $0.eventID != thing.eventID }
    let likely = MovePicker.likely(thing.words, among: others)
    let rest = MovePicker.byUrgency(
      others.filter { m in !likely.contains { $0.eventID == m.eventID } }, today: state.today,
      calendar: state.calendar)
    return (likely, rest)
  }

  public var body: some View {
    let thing = MoveThing.resolve(input.subject, state: context.state)
    VStack(alignment: .leading, spacing: 0) {
      Text("移到哪件事？")
        .mlFont(\.title2, lineBox: true)
        .foregroundStyle(MLColor.ink)
        .padding(.bottom, 6)
      if let thing {
        Text(thing.sentence)
          .mlFont(\.callout, lineBox: true)
          .foregroundStyle(MLColor.ink2)
          .fixedSize(horizontal: false, vertical: true)
        picker(thing)
      } else {
        Text("此条已不在这件事中。")
          .mlFont(\.callout, lineBox: true)
          .foregroundStyle(MLColor.ink2)
      }
      HStack(spacing: 8) {
        if let thing {
          Button {
            create(thing)
          } label: {
            HStack(spacing: 5) {
              Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
              Text("新建一件事")
            }
          }
          .buttonStyle(MLButtonStyle(.standard))
          Button("不属于任何事") { takeOut(thing) }
            .buttonStyle(MLButtonStyle(.standard))
        }
        Spacer(minLength: 0)
        Button("取消") { context.navigator.present(nil) }
          .buttonStyle(MLButtonStyle(.standard))
          .keyboardShortcut(.cancelAction)
      }
      .padding(.top, 20)
    }
    .padding(.top, 22)
    .padding(.horizontal, 24)
    .padding(.bottom, 18)
    .frame(width: 480, alignment: .leading)
    .background(MLColor.surface)
  }

  @ViewBuilder
  private func picker(_ thing: MoveThing) -> some View {
    let (likely, rest) = options(thing)
    let filtering = !query.trimmingCharacters(in: .whitespaces).isEmpty
    let shown: [Option] =
      (likely.map { Option(matter: $0, likely: true) }
      + rest.map { Option(matter: $0, likely: false) })
      .filter { MovePicker.matches(MLAutospace.apply($0.matter.title), query) }
    let selected = min(selection, max(0, shown.count - 1))
    field(shown: shown, selected: selected, thing: thing)
      .padding(.top, 14)
    let list = VStack(alignment: .leading, spacing: 1) {
      ForEach(Array(shown.enumerated()), id: \.element.id) { index, option in
        if !filtering, !likely.isEmpty, index == 0 {
          pickerHeader("可能是", first: true)
        }
        if !filtering, !likely.isEmpty, index == likely.count {
          pickerHeader("其他事", first: false)
        }
        PickerOption(
          title: MLAutospace.apply(option.matter.title), selected: index == selected
        ) { move(thing, to: option.matter.eventID) }
        .id(option.id)
      }
      if shown.isEmpty {
        Text("无结果")
          .mlFont(\.control)
          .foregroundStyle(MLColor.ink3)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    let height = min(300, pickerHeight(shown.count, headers: !filtering && !likely.isEmpty))
    Group {
      if snapshot {
        // AppKit scroll views do not draw into a still image.
        list.frame(height: height, alignment: .top).clipped()
      } else {
        ScrollViewReader { reader in
          ScrollView(.vertical) { list }
            .scrollIndicators(.automatic)
            .frame(height: height)
            .onChange(of: selection) { _, value in
              if shown.indices.contains(value) { reader.scrollTo(shown[value].id) }
            }
        }
      }
    }
    .padding(.top, 12)
  }

  private func pickerHeight(_ count: Int, headers: Bool) -> CGFloat {
    // Capped at 300 by the caller: a long list then ends part-way through a
    // row, so it shows there is more to scroll (the prototype's max-height).
    CGFloat(max(count, 1)) * 29 + (headers ? 44 : 0)
  }

  private func pickerHeader(_ title: String, first: Bool) -> some View {
    Text(title)
      .mlFont(\.section, lineBox: true)
      .foregroundStyle(MLColor.ink2)
      .padding(.horizontal, 10)
      .padding(.top, first ? 0 : 8)
      .padding(.bottom, 4)
  }

  @ViewBuilder
  private func field(shown: [Option], selected: Int, thing: MoveThing) -> some View {
    Group {
      if snapshot {
        Text(query.isEmpty ? "搜索" : query)
          .foregroundStyle(query.isEmpty ? MLColor.ink3 : MLColor.ink)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        TextField("搜索", text: $query)
          .textFieldStyle(.plain)
          .focused($fieldFocused)
          .onAppear { fieldFocused = true }
          .onChange(of: query) { _, _ in selection = 0 }
          .onSubmit {
            if shown.indices.contains(selected) { move(thing, to: shown[selected].matter.eventID) }
          }
          .onKeyPress(.downArrow) {
            selection = min(shown.count - 1, selected + 1)
            return .handled
          }
          .onKeyPress(.upArrow) {
            selection = max(0, selected - 1)
            return .handled
          }
          .accessibilityLabel("搜索事")
      }
    }
    .mlFont(\.control)
    .padding(.horizontal, 10)
    .frame(height: 30)
    .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(
        MLColor.rule2, lineWidth: 0.5)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .inset(by: -1.5)
        .stroke(MLColor.focus, lineWidth: 3)
        .opacity(fieldFocused ? 1 : 0)
    )
  }

  // MARK: - Results (§7.4.1)

  private func move(_ thing: MoveThing, to target: String) {
    context.navigator.present(nil)
    context.navigator.openPopover(nil)
    context.actions.correct(
      .moveItem(itemID: thing.itemID, segID: thing.segID, from: thing.eventID, to: target))
  }

  private func takeOut(_ thing: MoveThing) {
    context.navigator.present(nil)
    context.navigator.openPopover(nil)
    context.actions.correct(.takeOut(itemID: thing.itemID, segID: thing.segID, from: thing.eventID))
  }

  private func create(_ thing: MoveThing) {
    context.navigator.present(nil)
    context.navigator.openPopover(nil)
    context.actions.correct(
      .newMatter(
        itemID: thing.itemID, segID: thing.segID, from: thing.eventID, title: thing.newTitle,
        provisionalID: UUID().uuidString.lowercased()))
  }
}

/// One option: padding 6 10, radius 7; hover `--fill-2`; selected
/// `--accent-fill` with white text.
private struct PickerOption: View {
  let title: String
  let selected: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Text(title)
        .mlFont(\.control)
        .foregroundStyle(selected ? MLColor.onAccent : MLColor.ink)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 6 + 16 + 6 (`.picker button`, 13/16): 28, 29 apart with the 1 gap.
        .frame(height: 28)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? MLColor.accentFill : hovering ? MLColor.fill2 : MLColor.transparent)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
