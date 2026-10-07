import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-home. S10 · Group page (MAC-SPEC §4.12): the group's name, then
// 按时间 (`HomeTimeView` with the members) or 按截止; empty: 「这个分组还是空的」
// / 「把事拖到这里。」 + 「添加事…」 (`.addToGroup` sheet). Rows dropped on the
// page join the group. Double-click the name (or right-click it) to rename;
// the same menu deletes the group (its matters stay).

public struct GroupPageInput: Equatable, Sendable {
  /// `MemoryUserGroup.routeID`.
  public let groupID: String
  /// 按时间 or 按截止.
  public let lens: MemoryHomeLens

  public init(groupID: String, lens: MemoryHomeLens) {
    self.groupID = groupID
    self.lens = lens
  }
}

public struct GroupPage: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let context: MindloomPageContext
  let input: GroupPageInput
  @State private var renaming = false
  @State private var draft = ""
  @State private var targeted = false
  @FocusState private var fieldFocused: Bool

  public init(context: MindloomPageContext, input: GroupPageInput) {
    self.context = context
    self.input = input
  }

  /// What the page shows. The group comes from `state.user`, which the App
  /// keeps at the latest read of the library (`overlayUser`), so a group made
  /// a moment ago opens straight to its empty page.
  enum Content: Equatable {
    /// 「这个分组已经删掉了」.
    case gone
    /// 「这个分组还是空的」.
    case empty
    /// The live members' event IDs.
    case members([String])
  }

  static func content(_ state: MemoryScreenState, groupID: String) -> Content {
    guard let group = state.group(groupID) else { return .gone }
    let members = group.eventIDs.filter { state.matter($0) != nil }
    return members.isEmpty ? .empty : .members(members)
  }

  public var body: some View {
    let state = context.state
    let group = state.group(input.groupID)
    let content = Self.content(state, groupID: input.groupID)
    let members = (group?.eventIDs ?? []).compactMap { state.matter($0) }
    MindloomPageScroll(key: context.navigation.scrollKey) {
      VStack(alignment: .leading, spacing: 0) {
        title(group)
        if content == .gone {
          HomeEmptyMessage(title: "此分组已删除").padding(.top, 100)
        } else if content == .empty {
          HomeEmptyMessage(
            title: "此分组为空", message: "将事拖到这里。", actionTitle: "添加事…"
          ) {
            context.navigator.present(.addToGroup(input.groupID))
          }
          .padding(.top, 100)
        } else if input.lens == .deadlines {
          HomeDeadlineView(context: context, input: HomeDeadlineInput(eventIDs: Set(members.map(\.eventID))))
        } else {
          HomeTimeView(
            context: context,
            input: HomeListInput(
              matters: members, showsCaptures: false,
              sharedBy: [:]))
        }
      }
    }
    .overlay {
      if targeted {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(MLColor.accent, lineWidth: 2)
          .background(MLColor.accentTint.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
          .padding(8)
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    .modifier(GroupPageDrop(snapshot: snapshot, targeted: $targeted) { ids in
      for id in ids where state.group(of: id)?.routeID != input.groupID {
        context.actions.correct(
          .group(eventID: id, from: state.group(of: id)?.routeID, to: input.groupID))
      }
    })
  }

  @ViewBuilder
  private func title(_ group: MemoryUserGroup?) -> some View {
    if renaming, !snapshot {
      TextField("名称", text: $draft)
        .textFieldStyle(.plain)
        .mlFont(\.title)
        .foregroundStyle(MLColor.ink)
        .padding(.horizontal, 6)
        .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(MLColor.focus, lineWidth: 3)
            .padding(-3)
        )
        .padding(.leading, -6)
        .padding(.top, 10)
        .focused($fieldFocused)
        .onAppear { fieldFocused = true }
        .onSubmit { commitRename() }
        .onExitCommand { renaming = false }
        .onChange(of: fieldFocused) { _, focused in if !focused { commitRename() } }
    } else {
      Text(MLAutospace.apply(group?.name ?? ""))
        .mlFont(\.title)
        .foregroundStyle(MLColor.ink)
        .padding(.top, 10)
        .accessibilityAddTraits(.isHeader)
        .onTapGesture(count: 2) { startRename(group) }
        .contextMenu {
          if let group {
            Button {
              startRename(group)
            } label: {
              Label("重新命名", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
              context.actions.deleteGroup(group.routeID)
              context.navigator.openRoot(.home)
            } label: {
              Label("删除分组", systemImage: "trash")
            }
          }
        }
    }
  }

  private func startRename(_ group: MemoryUserGroup?) {
    guard let group else { return }
    draft = group.name
    renaming = true
  }

  private func commitRename() {
    guard renaming else { return }
    renaming = false
    let name = GroupName.clean(draft)
    guard !name.isEmpty, name != context.state.group(input.groupID)?.name else { return }
    context.actions.renameGroup(input.groupID, name)
  }
}

/// Matters dropped anywhere on a group page join it (§4.12, §5.5).
private struct GroupPageDrop: ViewModifier {
  let snapshot: Bool
  @Binding var targeted: Bool
  let drop: ([String]) -> Void

  func body(content: Content) -> some View {
    if snapshot {
      content
    } else {
      content.dropDestination(for: String.self) { ids, _ in
        drop(ids)
        return !ids.isEmpty
      } isTargeted: { inside in
        withAnimation(MLMotion.easeOut(MLMotion.durFast)) { targeted = inside }
      }
    }
  }
}

/// A group's name as typed: whitespace collapsed, spaces between Chinese and
/// Latin removed (autospace puts them back on display).
enum GroupName {
  static func clean(_ raw: String) -> String {
    let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return collapsed.replacingOccurrences(
      of: #"(?<=[\x{2E80}-\x{9FFF}\x{F900}-\x{FAFF}]) (?=[A-Za-z0-9])|(?<=[A-Za-z0-9]) (?=[\x{2E80}-\x{9FFF}\x{F900}-\x{FAFF}])"#,
      with: "", options: .regularExpression)
  }
}
