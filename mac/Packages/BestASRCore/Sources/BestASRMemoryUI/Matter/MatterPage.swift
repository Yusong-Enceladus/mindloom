import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-matter. S6–S8 · The matter page (MAC-SPEC §4.6): header (title
// with in-place rename, status line, risk, meta line 「在「论文」里 · 8月18日起 ·
// 高原、宋雨桐… · 已共享到「实验室」」), then 进展 (`MatterProgressView`, or
// `MatterSmallPage` when the matter has no parts) or 原文 (`MatterTextTab`);
// the step and 经过 popovers; member view.

public struct MatterPageInput: Equatable, Sendable {
  public let eventID: String
  public let tab: MatterTab
  /// The popover open (a step or a part's 经过).
  public let popover: MatterPopover?
  /// The 原文 row to highlight and scroll to once.
  public let revealRow: String?
  /// The title is being renamed in place.
  public let renaming: Bool
  /// Shared to you by someone else: read-only (§4.6).
  public let memberView: Bool

  public init(
    eventID: String, tab: MatterTab, popover: MatterPopover?, revealRow: String?, renaming: Bool,
    memberView: Bool
  ) {
    self.eventID = eventID
    self.tab = tab
    self.popover = popover
    self.revealRow = revealRow
    self.renaming = renaming
    self.memberView = memberView
  }
}

public struct MatterPage: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let context: MindloomPageContext
  let input: MatterPageInput
  /// Where on a segment it was clicked (the 经过 popover points there).
  @State private var segmentClick: [String: CGFloat] = [:]

  public init(context: MindloomPageContext, input: MatterPageInput) {
    self.context = context
    self.input = input
  }

  public var body: some View {
    let matter = context.state.matter(input.eventID)
    MindloomPageScroll(key: context.navigation.scrollKey) {
      if let matter {
        VStack(alignment: .leading, spacing: 0) {
          MatterHeader(context: context, matter: matter, input: input)
            .frame(maxWidth: 760, alignment: .leading)
          switch input.tab {
          case .progress:
            if matter.parts.isEmpty {
              MatterSmallPage(
                context: context,
                input: MatterSmallPageInput(matter: matter, memberView: input.memberView))
            } else {
              MatterProgressView(
                context: context, input: MatterProgressInput(matter: matter, popover: input.popover)
              )
            }
          case .text:
            MatterTextTab(
              context: context,
              input: MatterTextTabInput(
                eventID: input.eventID, revealRow: input.revealRow, memberView: input.memberView))
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
          // A click on empty space closes the popover (§5.2).
          if input.popover != nil {
            Color.clear.contentShape(Rectangle()).onTapGesture {
              context.navigator.openPopover(nil)
            }
          }
        }
      } else {
        MatterGone(context: context)
      }
    }
    .environment(\.matterSegmentClick) { id, dx in segmentClick[id] = dx }
    .overlayPreferenceValue(MatterAnchorKey.self) { anchors in
      GeometryReader { proxy in
        if let matter, let popover = input.popover {
          popoverLayer(matter, popover, anchors: anchors, proxy: proxy)
            .id(popover)
            .transition(
              reduceMotion
                ? .opacity
                : .scale(scale: 0.97).combined(with: .opacity).combined(
                  with: .offset(y: -4)))
        }
      }
      .animation(reduceMotion ? .easeOut(duration: 0.2) : MLMotion.easeOut(), value: input.popover)
    }
    .onAppear { context.actions.refresh() }
  }

  // MARK: - Popovers

  @ViewBuilder
  private func popoverLayer(
    _ matter: MatterDigest, _ popover: MatterPopover, anchors: [String: Anchor<CGRect>],
    proxy: GeometryProxy
  ) -> some View {
    let state = context.state
    let layout = MatterTimeLayout(
      matter: matter, width: max(320, proxy.size.width - 64), today: state.today,
      calendar: state.calendar)
    let labelKeys = anchors.keys.filter {
      $0.hasPrefix("lab:") || $0.hasPrefix("name:") || $0.hasPrefix("q:") || $0 == "meta"
    }.sorted()
    switch popover {
    case .step(let id):
      if let rect = anchors["step:\(id)"].map({ proxy[$0] }) {
        let mark = layout.mark(holding: id)
        let own = anchors["own:\(id)"].map { proxy[$0] }
        let ownKey = mark.map { "lab:\($0.id)" }
        let keys = labelKeys.filter { $0 != ownKey && $0 != "q:\(id)" }
        placed(anchor: rect, own: own, labels: keys.compactMap { anchors[$0].map { proxy[$0] } }) {
          StepPopover(
            context: context,
            input: StepPopoverInput(
              matter: matter, stepID: id, memberView: input.memberView,
              others: mark?.steps.filter { $0.id != id } ?? [],
              othersFinished: mark?.kind == .done))
        }
      }
    case .segment(let partID):
      if let rect = anchors["seg:\(partID)"].map({ proxy[$0] }) {
        let x = segmentClick[partID].map { rect.minX + $0 } ?? rect.midX
        placed(
          anchor: CGRect(x: x, y: rect.minY, width: 0, height: rect.height), own: nil,
          labels: labelKeys.compactMap { anchors[$0].map { proxy[$0] } }
        ) {
          SegmentPopover(
            context: context,
            input: SegmentPopoverInput(
              matter: matter, partID: partID, folded: layout.foldedSteps(partID)))
        }
      }
    }
  }

  private func placed<Content: View>(
    anchor: CGRect, own: CGRect?, labels: [CGRect], @ViewBuilder content: () -> Content
  ) -> some View {
    MatterPopoverLayout(anchor: anchor, ownLabel: own, labels: labels) {
      ForEach(labels.indices, id: \.self) { _ in
        Rectangle().fill(MLColor.paper).opacity(0.75).allowsHitTesting(false)
      }
      PopoverArrowView(up: true)
      PopoverArrowView(up: false)
      content()
      // Esc closes it.
      Button("") { context.navigator.openPopover(nil) }
        .keyboardShortcut(.cancelAction)
        .opacity(0)
    }
  }
}

// MARK: - Header

/// Title (rename in place), status line, risk sentence, meta line (§4.6).
struct MatterHeader: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let context: MindloomPageContext
  let matter: MatterDigest
  let input: MatterPageInput
  @State private var draft = ""
  /// This rename was saved or cancelled (Return then blur must not save twice).
  @State private var finished = false
  @FocusState private var editing: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      title
      if !matter.status.isEmpty {
        Text(MLAutospace.apply(matter.status))
          .mlFont(\.lead, lineBox: true)
          .foregroundStyle(MLColor.ink)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 6)
      }
      if let risk = matter.risk, !risk.isEmpty {
        Text(MLAutospace.apply(risk))
          .mlFont(\.sub, lineBox: true)
          .foregroundStyle(MLColor.ink)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 2)
      }
      MatterMetaLine(context: context, matter: matter)
        .padding(.top, 10)
        .matterAnchor("meta")
    }
    .padding(.top, 10)
  }

  @ViewBuilder
  private var title: some View {
    let shown = MLAutospace.apply(matter.title)
    if input.renaming && !input.memberView {
      Group {
        if snapshot {
          Text(matter.title)
            .background(MLColor.selection)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          TextField("", text: $draft)
            .textFieldStyle(.plain)
            .focused($editing)
            .onSubmit(save)
            .onExitCommand {
              finished = true
              context.navigator.rename(nil)
            }
            .onChange(of: editing) { _, focused in if !focused { save() } }
            .onAppear {
              draft = matter.title
              finished = false
              editing = true
            }
        }
      }
      .mlFont(\.title, lineBox: true)
      .foregroundStyle(MLColor.ink)
      .padding(.horizontal, 6)
      .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .inset(by: -1.5)
          .stroke(MLColor.focus, lineWidth: 3)
      )
      .padding(.horizontal, -6)
      .accessibilityLabel("重新命名")
    } else {
      Text(shown)
        .mlFont(\.title, lineBox: true)
        .foregroundStyle(MLColor.ink)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .onTapGesture(count: 2) {
          if !input.memberView { context.navigator.rename(matter.eventID) }
        }
        .accessibilityAddTraits(.isHeader)
    }
  }

  /// Return or blur saves (whitespace collapsed; the spaces autospace adds
  /// between scripts removed); an unchanged or empty name does nothing.
  private func save() {
    guard input.renaming, !finished else { return }
    finished = true
    let name = MatterHeader.cleanName(draft)
    context.navigator.rename(nil)
    guard !name.isEmpty, name != matter.title, name != MatterHeader.cleanName(matter.title) else {
      return
    }
    context.actions.correct(.rename(eventID: matter.eventID, from: matter.title, to: name))
  }

  /// 「TES 论文 RoboPrior」 → 「TES论文RoboPrior」: runs of whitespace become
  /// one space, and a space between a Chinese and a Latin character goes
  /// (autospace puts it back on display).
  static func cleanName(_ text: String) -> String {
    let collapsed = text.replacingOccurrences(of: "\u{2005}", with: " ")
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    var out = ""
    let characters = Array(collapsed)
    for (index, character) in characters.enumerated() {
      if character == " ", index > 0, index + 1 < characters.count {
        let a = characters[index - 1]
        let b = characters[index + 1]
        if isCJK(a) != isCJK(b) { continue }
      }
      out.append(character)
    }
    return out
  }

  private static func isCJK(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first?.value else { return false }
    return (0x2E80...0x2FFF).contains(scalar) || (0x3040...0x30FF).contains(scalar)
      || (0x3400...0x4DBF).contains(scalar) || (0x4E00...0x9FFF).contains(scalar)
      || (0xF900...0xFAFF).contains(scalar) || (0xFF00...0xFFEF).contains(scalar)
      || (0x3000...0x303F).contains(scalar)
  }
}

/// 「在「{group}」里」 (a link) · 「{M月D日}起」 · up to five people · sharing.
struct MatterMetaLine: View {
  let context: MindloomPageContext
  let matter: MatterDigest

  var body: some View {
    let state = context.state
    let group = state.group(of: matter.eventID)
    let people = matter.people.filter { !$0.name.isEmpty }.prefix(5)
    let share = state.sharing[matter.eventID]
    var items: [AnyView] = []
    if let group {
      items.append(
        AnyView(
          HStack(spacing: 0) {
            Text("在“")
            Button(MLAutospace.apply(group.name)) {
              context.navigator.openRoot(.group(group.routeID))
            }
            .buttonStyle(.plain)
            .foregroundStyle(MLColor.accent)
            Text("”中")
          }))
    }
    if let first = matter.firstDay ?? matter.days.first {
      items.append(AnyView(Text(MindloomDates.monthDay(first, calendar: state.calendar) + "起")))
    }
    if !people.isEmpty {
      // Each name opens the person's page (v12 理3-1: a page for everyone).
      items.append(
        AnyView(
          HStack(spacing: 0) {
            ForEach(Array(people.enumerated()), id: \.element.personID) { index, person in
              if index > 0 { Text("、") }
              Button(person.name) { context.navigator.openPerson(person.personID) }
                .buttonStyle(HoverAccentStyle())
                .accessibilityHint("打开此人")
            }
          }))
    }
    if let share {
      items.append(
        AnyView(
          Text(
            share.sharedBy.map { "\($0)共享在“\(share.spaceName)”" } ?? "已共享到“\(share.spaceName)”")))
    }
    return FlowRows(spacing: 0) {
      ForEach(items.indices, id: \.self) { index in
        HStack(spacing: 0) {
          if index > 0 {
            Text("·").foregroundStyle(MLColor.ink3).padding(.horizontal, 6.5)
          }
          items[index]
        }
      }
    }
    .mlFont(\.sub, lineBox: true)
    .foregroundStyle(MLColor.ink2)
    .lineLimit(1)
  }
}

/// The matter is not there any more (deleted, merged, or taken back by
/// whoever shared it).
struct MatterGone: View {
  let context: MindloomPageContext

  var body: some View {
    MLEmptyState(
      "此事已不存在", message: "它可能已被删除，或已与其他事合并。", actionTitle: "返回首页"
    ) { context.navigator.openRoot(.home) }
    .padding(.top, 92)
  }
}
