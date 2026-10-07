import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-home. S14 · 新建分组 (360 wide; field 「名字」) and 添加到「{group}」
// (440 wide; a filtered picker of live matters not in the group) (MAC-SPEC
// §7.4). Results through `actions.createGroup` / `actions.correct(.group…)`.

public struct NewGroupSheetInput: Equatable, Sendable {
  /// The matter to put in the new group (移到分组 › 新建分组…), if any.
  public let moving: String?
  /// The name already typed (still images).
  public var draft: String

  public init(moving: String?, draft: String = "") {
    self.moving = moving
    self.draft = draft
  }
}

public struct NewGroupSheet: View {
  let context: MindloomPageContext
  let input: NewGroupSheetInput
  @State private var name: String
  @FocusState private var focused: Bool

  public init(context: MindloomPageContext, input: NewGroupSheetInput) {
    self.context = context
    self.input = input
    _name = State(initialValue: input.draft)
  }

  public var body: some View {
    MindloomSheetChrome(width: 360) {
      Text("新建分组").mlFont(\.title2).foregroundStyle(MLColor.ink).padding(.bottom, 12)
      MindloomSheetField(placeholder: "名称", text: $name, focused: $focused)
        .accessibilityLabel("分组名称")
        .onSubmit(create)
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("取消") { context.navigator.present(nil) }
          .buttonStyle(MLButtonStyle(.standard))
          .keyboardShortcut(.cancelAction)
        Button("新建", action: create)
          .buttonStyle(MLButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
      }
      .padding(.top, 20)
    }
    .onAppear { focused = true }
  }

  private func create() {
    let clean = GroupName.clean(name)
    guard !clean.isEmpty else {
      focused = true
      return
    }
    context.navigator.present(nil)
    context.actions.createGroup(clean, input.moving)
  }
}

public struct AddToGroupSheetInput: Equatable, Sendable {
  /// `MemoryUserGroup.routeID`.
  public let groupID: String

  public init(groupID: String) { self.groupID = groupID }
}

public struct AddToGroupSheet: View {
  let context: MindloomPageContext
  let input: AddToGroupSheetInput
  @State private var filter = ""
  @State private var selection = 0
  @FocusState private var focused: Bool

  public init(context: MindloomPageContext, input: AddToGroupSheetInput) {
    self.context = context
    self.input = input
  }

  public var body: some View {
    let state = context.state
    let name = state.group(input.groupID)?.name ?? ""
    let choices = choices(state)
    MindloomSheetChrome(width: 440) {
      Text("添加到“\(MLAutospace.apply(name))”")
        .mlFont(\.title2).foregroundStyle(MLColor.ink).padding(.bottom, 12)
      MindloomSheetField(placeholder: "搜索", text: $filter, focused: $focused)
        .accessibilityLabel("搜索事")
        .onSubmit { pick(choices, at: selection) }
        .onKeyPress(.downArrow) {
          selection = min(selection + 1, max(0, choices.count - 1))
          return .handled
        }
        .onKeyPress(.upArrow) {
          selection = max(selection - 1, 0)
          return .handled
        }
        .onChange(of: filter) { selection = 0 }
      ScrollViewReader { proxy in
        ZhijiScroll {
          // 28 rows 1 apart (`.picker`): 300 ends part-way through a row.
          VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(choices.enumerated()), id: \.element.eventID) { index, matter in
              let on = index == selection
              FadingText(Text(MLAutospace.apply(matter.title)), fade: 32.5)
                .mlFont(\.control)
                .foregroundStyle(on ? MLColor.onAccent : MLColor.ink)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                  RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(on ? MLColor.accentFill : .transparent))
                .contentShape(Rectangle())
                .onTapGesture { pick(choices, at: index) }
                .onHover { if $0 { selection = index } }
                .id(matter.eventID)
                .accessibilityAddTraits(.isButton)
            }
            if choices.isEmpty {
              Text(filter.isEmpty ? "所有事都已在此分组中。" : "无结果")
                .mlFont(\.callout).foregroundStyle(MLColor.ink2)
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
          }
        }
        .frame(height: 300)
        .padding(.top, 12)
        .onChange(of: selection) { _, next in
          guard choices.indices.contains(next) else { return }
          proxy.scrollTo(choices[next].eventID)
        }
      }
      HStack {
        Spacer(minLength: 0)
        Button("取消") { context.navigator.present(nil) }
          .buttonStyle(MLButtonStyle(.standard))
          .keyboardShortcut(.cancelAction)
      }
      .padding(.top, 20)
    }
    .onAppear { focused = true }
  }

  /// Live matters not in the group, by urgency, filtered by the typed words.
  func choices(_ state: MemoryScreenState) -> [MatterDigest] {
    let members = Set(state.group(input.groupID)?.eventIDs ?? [])
    let all = (state.digest?.matters ?? []).filter { !members.contains($0.eventID) }
    let n = HomeSearch.norm(filter)
    let shown = n.isEmpty ? all : all.filter { HomeSearch.norm($0.title).contains(n) }
    return HomeDerivation.byUrgency(shown, HomeDays(state))
  }

  private func pick(_ choices: [MatterDigest], at index: Int) {
    guard choices.indices.contains(index) else { return }
    let id = choices[index].eventID
    context.navigator.present(nil)
    context.actions.correct(
      .group(eventID: id, from: context.state.group(of: id)?.routeID, to: input.groupID))
  }
}

// The sheet chrome is the shared `MindloomSheetChrome` (Capture/CaptureChrome.swift).

/// A sheet's text field (§7.4): 30 high, padding 0 10, radius 8, `surface`,
/// inset 0.5 pt `rule2`, a 3 pt focus ring.
struct MindloomSheetField: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let placeholder: String
  @Binding var text: String
  var focused: FocusState<Bool>.Binding

  var body: some View {
    Group {
      if snapshot {
        Text(text.isEmpty ? placeholder : text)
          .foregroundStyle(text.isEmpty ? MLColor.ink3 : MLColor.ink)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        TextField(placeholder, text: $text)
          .textFieldStyle(.plain)
          .foregroundStyle(MLColor.ink)
          .focused(focused)
      }
    }
    .mlFont(\.control)
    .padding(.horizontal, 10)
    .frame(height: 30)
    .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MLColor.rule2, lineWidth: 0.5)
    )
    .overlay {
      if focused.wrappedValue && !snapshot {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(MLColor.focus, lineWidth: 3)
          .padding(-3)
          .allowsHitTesting(false)
      }
    }
  }
}
