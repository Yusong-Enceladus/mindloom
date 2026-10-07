import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-home. S13 · The matter menu (MAC-SPEC §7.5): 「置顶」/「取消置顶」 ·
// 「重命名」 · 「移到分组」 (submenu: groups with a checkmark, 「不放在分组里」,
// 「新建分组…」) · 「共享…」/「停止共享」 · ─ · 「复制为文本」 ⌘C · ─ · 「删除…」;
// member view: 「复制为文本」 only. Used by Home rows' context menu and the
// matter page's toolbar 「…」 button.

public struct MatterMenuInput: Equatable, Sendable {
  public let eventID: String
  /// The matter is shared to you by someone else.
  public let memberView: Bool

  public init(eventID: String, memberView: Bool) {
    self.eventID = eventID
    self.memberView = memberView
  }
}

/// What the matter menu offers for one matter (pure; the menu and its still
/// image both read it).
struct MatterMenuModel: Equatable {
  struct GroupItem: Equatable {
    let routeID: String
    let name: String
    let current: Bool
  }

  let pinned: Bool
  let groups: [GroupItem]
  let inGroup: Bool
  /// You shared it (「停止共享」), else 「共享…」.
  let sharedByYou: Bool
  let memberView: Bool

  init(state: MemoryScreenState, input: MatterMenuInput) {
    let current = state.group(of: input.eventID)?.routeID
    pinned = state.user.pins.contains { $0.eventID == input.eventID }
    groups = state.groups.map {
      GroupItem(routeID: $0.routeID, name: MLAutospace.apply($0.name), current: $0.routeID == current)
    }
    inGroup = current != nil
    let share = state.sharing[input.eventID]
    sharedByYou = share != nil && share?.sharedBy == nil
    memberView = input.memberView
  }
}

/// Menu items (for a `Menu` or `.contextMenu`).
public struct MatterMenu: View {
  let context: MindloomPageContext
  let input: MatterMenuInput

  public init(context: MindloomPageContext, input: MatterMenuInput) {
    self.context = context
    self.input = input
  }

  public var body: some View {
    let model = MatterMenuModel(state: context.state, input: input)
    let id = input.eventID
    if !model.memberView {
      Button {
        context.actions.correct(.pin(eventID: id, pinned: !model.pinned))
      } label: {
        Label(model.pinned ? "取消置顶" : "置顶", systemImage: model.pinned ? "pin.slash" : "pin")
      }
      Button {
        if context.navigation.openMatter != id { context.navigator.openMatter(id) }
        context.navigator.rename(id)
      } label: {
        Label("重新命名", systemImage: "pencil")
      }
      Menu {
        ForEach(model.groups, id: \.routeID) { group in
          Toggle(
            group.name,
            isOn: Binding(
              get: { group.current },
              set: { _ in
                guard !group.current else { return }
                context.actions.correct(
                  .group(eventID: id, from: currentGroup, to: group.routeID))
              }))
        }
        if !model.groups.isEmpty { Divider() }
        if model.inGroup {
          Button("移出分组") {
            context.actions.correct(.group(eventID: id, from: currentGroup, to: nil))
          }
        }
        Button("新建分组…") { context.navigator.present(.newGroup(moving: id)) }
      } label: {
        Label("移到分组", systemImage: "folder")
      }
      if model.sharedByYou, let share = context.state.sharing[id] {
        Button {
          context.spacesActions.unshare(share.spaceID, id)
        } label: {
          Label("停止共享", systemImage: "person.2")
        }
      } else {
        Button {
          context.spacesActions.present(context.state.spaces.isEmpty ? .newSpace : .share(eventID: id))
        } label: {
          Label("共享…", systemImage: "square.and.arrow.up")
        }
      }
      Divider()
    }
    Button {
      context.actions.copyText(id)
    } label: {
      Label("拷贝为文本", systemImage: "doc.on.doc")
    }
    // No ⌘C here: a popup menu's key equivalent would take ⌘C from the
    // search field and other text fields of the window.
    if !model.memberView {
      Divider()
      Button(role: .destructive) {
        context.navigator.present(.deleteMatter(id))
      } label: {
        Label("删除…", systemImage: "trash")
      }
    }
  }

  private var currentGroup: String? { context.state.group(of: input.eventID)?.routeID }
}

/// A still image of the matter menu and its 移到分组 submenu (the real one
/// is the system's, which `ImageRenderer` does not draw): 200 wide, 24 pt
/// rows, icons 14, the shortcut in `ink3`, highlight `accentFill`.
public struct MatterMenuStill: View {
  let model: MatterMenuModel
  let highlightGroups: Bool

  init(model: MatterMenuModel, highlightGroups: Bool) {
    self.model = model
    self.highlightGroups = highlightGroups
  }

  public init(state: MemoryScreenState, eventID: String, submenu: Bool) {
    self.init(
      model: MatterMenuModel(state: state, input: MatterMenuInput(eventID: eventID, memberView: false)),
      highlightGroups: submenu)
  }

  public var body: some View {
    HStack(alignment: .top, spacing: 2) {
      panel(width: 200) {
        item(model.pinned ? "取消置顶" : "置顶", icon: "pin")
        item("重新命名", icon: "pencil")
        item("移到分组", icon: "folder", chevron: true, on: highlightGroups)
        if model.sharedByYou {
          item("停止共享", icon: "person.2")
        } else {
          item("共享…", icon: "square.and.arrow.up")
        }
        separator
        item("拷贝为文本", icon: "doc.on.doc")
        separator
        item("删除…", icon: "trash", destructive: true)
      }
      if highlightGroups {
        panel(width: 180) {
          ForEach(model.groups, id: \.routeID) { group in
            HStack(spacing: 0) {
              Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .opacity(group.current ? 1 : 0)
                .frame(width: 24, alignment: .leading)
              Text(group.name).mlFont(\.control)
              Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
          }
          separator
          if model.inGroup { plain("移出分组") }
          plain("新建分组…")
        }
        .padding(.top, 66)
      }
    }
    .foregroundStyle(MLColor.ink)
  }

  private func panel<Content: View>(width: CGFloat, @ViewBuilder _ content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 0) { content() }
      .padding(5)
      .frame(width: width, alignment: .leading)
      .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MLColor.rule, lineWidth: 0.5)
      )
      .mlShadow(.level3)
  }

  private func item(
    _ title: String, icon: String, shortcut: String? = nil, chevron: Bool = false,
    destructive: Bool = false, on: Bool = false
  ) -> some View {
    HStack(spacing: 8) {
      Image(systemName: icon).font(.system(size: 13)).frame(width: 16)
      Text(title).mlFont(\.control)
      Spacer(minLength: 0)
      if let shortcut {
        Text(shortcut).mlFont(\.control).foregroundStyle(on ? MLColor.onAccent : MLColor.ink3)
      }
      if chevron { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)) }
    }
    .foregroundStyle(on ? MLColor.onAccent : destructive ? MLColor.alert : MLColor.ink)
    .padding(.horizontal, 10)
    .frame(height: 24)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? MLColor.accentFill : .transparent))
  }

  private func plain(_ title: String) -> some View {
    Text(title).mlFont(\.control).padding(.horizontal, 10).frame(height: 24)
  }

  private var separator: some View {
    Rectangle().fill(MLColor.rule).frame(height: 0.5).padding(.horizontal, 10).padding(.vertical, 5)
  }
}
