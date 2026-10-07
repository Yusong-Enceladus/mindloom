import MindloomDesign
import SwiftUI

/// The inset sidebar (MAC-SPEC §3.4): 首页 · 历史 · 置顶 · 分组 (+) · 共享 (+),
/// 设置 at the bottom. 232 wide, inset 8 from the window's top, bottom and
/// left edges, radius 16, padding 46 (clears the traffic lights) 10 10. No
/// brand lockup and no status lines. An empty library shows only 首页, 历史
/// and 设置. The current tagline sits quietly above 设置 (docs/TAGLINES.md).
struct MindloomSidebar: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  @Environment(\.colorScheme) private var scheme
  let context: MindloomPageContext

  private var state: MemoryScreenState { context.state }
  private var navigation: MemoryNavigation { context.navigation }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ZhijiScroll {
        VStack(alignment: .leading, spacing: 2) {
          item("首页", symbol: "house", current: isHome) { context.navigator.openRoot(.home) }
            .keyboardShortcut("1", modifiers: .command)
          // 历史: every record, by day; typing in the toolbar's field
          // narrows the same page (the one search entry is that field).
          item("历史", symbol: "clock", current: navigation.top == .search) {
            context.navigator.openRoot(.search)
          }
          .keyboardShortcut("2", modifiers: .command)
          if !state.isEmptyLibrary {
            sections
          }
        }
      }
      .scrollIndicators(.never)
      Spacer(minLength: 8)
      if let line = state.tagline { SidebarTagline(line: line) }
      if state.demo { demoRow }
      settingsRow
    }
    .padding(.top, 46)
    .padding(.horizontal, 10)
    .padding(.bottom, 8)
    .frame(width: MLMetrics.mac.sidebarWidth)
    .frame(maxHeight: .infinity)
    .background {
      RoundedRectangle(cornerRadius: MLMetrics.mac.radiusSidebar, style: .continuous)
        .fill(MLColor.sidebarTint)
        .background {
          // What the prototype's blur sees behind the sidebar is the window's
          // paper, so the tint sits on paper (#F3F1EA / #1F1C19), not on the
          // system's grey material (#ECE9E3 / #1B1A17).
          RoundedRectangle(cornerRadius: MLMetrics.mac.radiusSidebar, style: .continuous)
            .fill(MLColor.paper)
        }
        .overlay(
          RoundedRectangle(cornerRadius: MLMetrics.mac.radiusSidebar, style: .continuous)
            .strokeBorder(MLColor.rule, lineWidth: 0.5)
        )
        // One layer for the shadow: without it the translucent tint casts
        // its own shadow onto the paper under it (#EEECE5 instead of
        // #F3F1EA).
        .compositingGroup()
        .mlShadow(.level1)
    }
    .padding([.top, .bottom, .leading], 8)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("边栏")
  }

  /// Demo mode: the demo library is on screen (review v12-B #7), above 设置
  /// for as long as it is.
  /// A small tag, not a row: it must never read as a selected page.
  private var demoRow: some View {
    HStack(spacing: 5) {
      Image(systemName: MindloomDemoMarker.symbol)
        .font(.system(size: 11))
      Text(MindloomDemoMarker.label).mlFont(\.foot)
    }
    .foregroundStyle(MLColor.accent)
    .padding(.horizontal, 9)
    .frame(height: 22)
    .background(MLColor.accentTint, in: Capsule())
    .padding(.leading, 10)
    .padding(.bottom, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .help(MindloomDemoMarker.detail)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(MindloomDemoMarker.detail)
  }

  private var isHome: Bool {
    switch navigation.top {
    case .home, .person: true
    default: false
    }
  }

  @ViewBuilder
  private var sections: some View {
    let pins = state.pinnedMatters
    if !pins.isEmpty {
      header("置顶")
      ForEach(pins) { pin in
        item(
          MLAutospace.apply(pin.title), symbol: "pin", current: navigation.openMatter == pin.eventID
        ) {
          context.navigator.openRoot(.home)
          context.navigator.openMatter(pin.eventID)
        }
      }
    }
    header("分组", plus: "新建分组") { context.navigator.present(.newGroup(moving: nil)) }
    ForEach(state.groups) { group in
      item(
        MLAutospace.apply(group.name), symbol: "folder",
        current: navigation.top == .group(group.routeID)
      ) {
        context.navigator.openRoot(.group(group.routeID))
      }
      .modifier(
        GroupDropTarget(snapshot: snapshot) { ids in
          // A Home row dragged onto a group moves the matter there (§5.5).
          for id in ids {
            context.actions.correct(
              .group(eventID: id, from: state.group(of: id)?.routeID, to: group.routeID))
          }
        })
    }
    spacesHeader
    ForEach(state.spaces) { space in
      item(space.name, symbol: "person.2", current: navigation.top == .space(space.id)) {
        context.navigator.openRoot(.space(space.id))
      }
    }
  }

  private var spacesHeader: some View {
    HStack(spacing: 0) {
      Text("共享").mlFont(\.section).foregroundStyle(MLColor.ink2)
      Spacer(minLength: 0)
      if snapshot {
        plusLabel
      } else {
        Menu {
          Button {
            context.spacesActions.present(.newSpace)
          } label: {
            Label("新建共享空间…", systemImage: "plus")
          }
          Button {
            context.spacesActions.present(.join)
          } label: {
            Label("用邀请码加入…", systemImage: "qrcode.viewfinder")
          }
        } label: {
          plusLabel
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("新建或加入共享空间")
        .accessibilityLabel("新建或加入共享空间")
      }
    }
    .padding(EdgeInsets(top: 16, leading: 10, bottom: 5, trailing: 6))
  }

  private func header(_ title: String, plus: String? = nil, action: (() -> Void)? = nil)
    -> some View
  {
    HStack(spacing: 0) {
      Text(title).mlFont(\.section).foregroundStyle(MLColor.ink2)
      Spacer(minLength: 0)
      if let plus, let action {
        Button(action: action) { plusLabel }
          .buttonStyle(SidebarPlusStyle())
          .help(plus)
          .accessibilityLabel(plus)
      }
    }
    .padding(EdgeInsets(top: 16, leading: 10, bottom: 5, trailing: 6))
    .accessibilityAddTraits(.isHeader)
  }

  private var plusLabel: some View {
    Image(systemName: "plus")
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(MLColor.ink3)
      .frame(width: 20, height: 20)
      .contentShape(RoundedRectangle(cornerRadius: 6))
  }

  private func item(
    _ title: String, symbol: String, current: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      SidebarRowLabel(title: title, symbol: symbol, current: current)
    }
    .buttonStyle(SidebarRowStyle(current: current))
    .accessibilityAddTraits(current ? .isSelected : [])
  }

  @ViewBuilder
  private var settingsRow: some View {
    // ⌘, is the App menu's 设置….
    item("设置", symbol: "gearshape", current: false) { context.actions.openSettings(nil) }
  }
}

/// Icon 16 (`ink2`, `accent` when current) and the label (13, `ink`, its end
/// fading when too long).
private struct SidebarRowLabel: View {
  let title: String
  let symbol: String
  let current: Bool

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(current ? MLColor.accent : MLColor.ink2)
        .frame(width: 16, height: 16)
      FadingLine(title).mlFont(\.control).foregroundStyle(MLColor.ink)
    }
    .padding(.horizontal, 10)
    .frame(height: 30)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
  }
}

/// Matters dragged onto a group row (event IDs as text); the row is lit
/// while they hover (`accentTint2` + an inset 1.5 pt `accent` ring). Not in
/// a still image (AppKit drop targets do not draw into `ImageRenderer`).
private struct GroupDropTarget: ViewModifier {
  let snapshot: Bool
  let drop: ([String]) -> Void
  @State private var targeted = false

  func body(content: Content) -> some View {
    if snapshot {
      content
    } else {
      content
        .overlay {
          if targeted {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(MLColor.accentTint2)
              .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                  .strokeBorder(MLColor.accent, lineWidth: 1.5)
              )
              .allowsHitTesting(false)
          }
        }
        .dropDestination(for: String.self) { ids, _ in
          drop(ids)
          return !ids.isEmpty
        } isTargeted: { targeted = $0 }
    }
  }
}

private struct SidebarRowStyle: ButtonStyle {
  let current: Bool
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(
            current
              ? MLColor.accentTint2 : (configuration.isPressed ? MLColor.fill3 : (hovering ? MLColor.fill2 : .transparent)))
      }
      .onHover { hovering = $0 }
  }
}

private struct SidebarPlusStyle: ButtonStyle {
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(hovering ? MLColor.ink2 : MLColor.ink3)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(
          hovering || configuration.isPressed ? MLColor.fill2 : .transparent)
      )
      .onHover { hovering = $0 }
  }
}

/// One line whose end fades over its last 2.5 em instead of an ellipsis
/// (MAC-SPEC §2.3: never cut content with 「…」).
public struct FadingLine: View {
  let text: String

  public init(_ text: String) { self.text = text }

  public var body: some View {
    // mac-home: the clip never asks for more width than offered (a long
    // pinned title used to widen the whole window; `long` state).
    FadingText(Text(text), fade: 36)
      .accessibilityLabel(text)
  }
}
