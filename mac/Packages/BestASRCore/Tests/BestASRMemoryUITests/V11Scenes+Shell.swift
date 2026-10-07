import BestASRMemory
import MindloomDesign
import SwiftUI

@testable import BestASRMemoryUI

// OWNER: mac-foundation. Helpers every scene file uses, and the shell's own
// states (the App menus, S21).

@MainActor
enum V11Page {
  /// The main window on a page.
  @MainActor
  static func window(
    _ state: MemoryScreenState, _ navigation: MemoryNavigation = MemoryNavigation(),
    dropTargeted: Bool = false, scroll: CGFloat = 0
  ) -> AnyView {
    AnyView(
      MindloomShell(
        navigation: .constant(navigation), state: state, actions: .inert,
        dropTargeted: dropTargeted
      )
      .environment(\.mindloomSnapshotScroll, scroll))
  }

  /// A matter page by the prototype's handle (E6).
  static func matter(
    _ loaded: V11Fixture.Loaded, _ handle: String, tab: MatterTab = .progress,
    popover: MatterPopover? = nil, from root: MindloomRoot = .home
  ) -> MemoryNavigation {
    var navigation = MemoryNavigation(root: root, matterTab: tab, popover: popover)
    if let id = loaded.handles[handle] { navigation.path = [.matter(id)] }
    return navigation
  }

  /// A standalone surface (sheet, popover, panel, menu) on the paper colour.
  static func surface<Content: View>(@ViewBuilder _ content: () -> Content) -> AnyView {
    AnyView(
      ZStack {
        Rectangle().fill(MLColor.paper2)
        content()
      })
  }

  /// A still image of a system menu (S21: the real menus are AppKit's).
  static func menu(_ title: String, items: [String]) -> AnyView {
    surface {
      VStack(alignment: .leading, spacing: 0) {
        Text(title).mlFont(\.control).padding(.horizontal, 10).frame(height: 24)
        Divider()
        ForEach(items, id: \.self) { item in
          if item == "-" {
            Divider().padding(.vertical, 4)
          } else {
            Text(item).mlFont(\.control).padding(.horizontal, 10).frame(height: 24)
          }
        }
      }
      .padding(6)
      .frame(width: 220, alignment: .leading)
      .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .mlShadow(.level3)
    }
  }
}

extension V11Scenes {
  @MainActor static var shell: [V11Scene] {
    [
      V11Scene(id: "file-menu", size: CGSize(width: 320, height: 220)) { _ in
        V11Page.menu("文件", items: ["导入会议记录…", "-", "新建分组…", "新建共享空间…", "用邀请码加入…"])
      },
      V11Scene(id: "edit-menu", size: CGSize(width: 320, height: 180)) { _ in
        V11Page.menu("编辑", items: ["撤销标为完成", "-", "粘贴", "查找"])
      },
      // The current tagline at the foot of the sidebar (docs/TAGLINES.md): a
      // plain line, a quotation with its source, the longest Chinese line,
      // English lines, and the empty library.
      taglineScene("x-sidebar-tagline", "zh-16"),
      taglineScene("x-sidebar-tagline-quote", "zh-01"),
      taglineScene("x-sidebar-tagline-long", "zh-11"),
      taglineScene("x-sidebar-tagline-en", "en-15"),
      taglineScene("x-sidebar-tagline-en-quote", "en-12"),
      // A return's line (after more than three days away).
      taglineScene("x-sidebar-tagline-return", "zh-45"),
      taglineScene("x-sidebar-tagline-en-return", "en-43"),
      V11Scene(id: "x-sidebar-tagline-empty") { _ in
        var state = V11Fixture.emptyState
        state.tagline = MindloomTaglineBoard.line(id: "zh-16")
        return V11Page.window(state)
      },
    ]
  }

  @MainActor static func taglineScene(_ id: String, _ line: String) -> V11Scene {
    V11Scene(id: id) { loaded in
      var state = V11Fixture.state(loaded)
      state.tagline = MindloomTaglineBoard.line(id: line)
      return V11Page.window(state)
    }
  }
}
