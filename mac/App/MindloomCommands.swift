import AppKit
import BestASRMemoryUI
import SwiftUI

/// What the main window offers the menu bar's commands (S21, MAC-SPEC §3.1):
/// the undo slot, the lens or tab, and the window's sheets. Published by
/// `ContentView` as a focused scene value.
struct MindloomCommandContext {
  /// 「撤销{label}」, nil when there is nothing to undo.
  var undoTitle: String?
  var undo: () -> Void
  var navigation: Binding<MemoryNavigation>
  var newSpace: () -> Void
  var joinSpace: () -> Void
  var openAbout: () -> Void
}

struct MindloomCommandKey: FocusedValueKey {
  typealias Value = MindloomCommandContext
}

extension FocusedValues {
  var mindloomCommands: MindloomCommandContext? {
    get { self[MindloomCommandKey.self] }
    set { self[MindloomCommandKey.self] = newValue }
  }
}

/// The App menus: Mindloom · 文件 · 编辑 · 显示 · 窗口 · 帮助, with the
/// items of §3.1 added to the ones macOS keeps.
struct MindloomCommands: Commands {
  @FocusedValue(\.mindloomCommands) private var context
  let pasteIn: () -> Void
  let pasteInDisabled: Bool
  /// 文件 › 导入… ⌘O: recordings and videos, recognised on this Mac (v12 1C,
  /// ALIGNMENT 收2-6). Not tied to the main window's focus.
  let importMedia: () -> Void
  /// 文件 › 导入会议记录…: a meeting App's exported transcript (txt, md, docx,
  /// srt, vtt), read into turns (ALIGNMENT 收2-5).
  let importTranscript: () -> Void

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button("关于 Mindloom") { context?.openAbout() }
    }
    CommandGroup(replacing: .newItem) {
      Button("导入…") { importMedia() }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(pasteInDisabled)
      Button("导入会议记录…") { importTranscript() }
        .disabled(pasteInDisabled)
      Divider()
      Button("新建分组…") { context?.navigation.wrappedValue.sheet = .newGroup(moving: nil) }
        .disabled(context == nil)
      Button("新建共享空间…") { context?.newSpace() }
        .disabled(context == nil)
      Button("用邀请码加入…") { context?.joinSpace() }
        .disabled(context == nil)
    }
    CommandGroup(replacing: .undoRedo) {
      // A text field being edited keeps its own undo and redo; elsewhere the
      // undo slot (§5.7). The menu is not rebuilt when the focus moves into
      // or out of a field, so the items stay enabled and decide when chosen
      // (a disabled 撤销 left ⌘Z dead in a rename field).
      Button(undoTitle) {
        if Self.textIsEditing {
          NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        } else {
          context?.undo()
        }
      }
      .keyboardShortcut("z", modifiers: .command)
      Button("重做") {
        NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
      }
      .keyboardShortcut("z", modifiers: [.command, .shift])
    }
    CommandGroup(after: .pasteboard) {
      // Takes the clipboard in as an item even while a text field has focus.
      Button("粘贴到 Mindloom") { pasteIn() }
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(pasteInDisabled)
    }
    // 查找 ›, 拼写和语法 ›, 替换 ›, 转换 ›, 语音 › come from the scene's
    // `TextEditingCommands()`: the system's items, which check and validate
    // themselves in text fields. ⌘F goes to Mindloom's search field first
    // (`MindloomFindKeyMonitor`), and 查找… chosen with the pointer outside
    // a text view reaches the App delegate, which focuses the same field.
    // In the system 显示 menu (a CommandMenu named 显示 made a second one on
    // a Chinese system), above the sidebar and full-screen items.
    CommandGroup(before: .sidebar) {
      if let navigation = context?.navigation {
        if case .matter = navigation.wrappedValue.top {
          Picker("", selection: navigation.matterTab) {
            ForEach(MatterTab.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        } else {
          Picker(
            "",
            selection: Binding(
              get: { navigation.wrappedValue.homeLens },
              set: { lens in
                navigation.wrappedValue.root = .home
                navigation.wrappedValue.path = []
                navigation.wrappedValue.homeLens = lens
              })
          ) {
            ForEach(MemoryHomeLens.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        }
        Divider()
      }
    }
    // No help book yet: the menu keeps only the system's search field
    // rather than a permanently disabled item.
    CommandGroup(replacing: .help) {}
  }

  private var undoTitle: String {
    if Self.textIsEditing { return "撤销" }
    return context?.undoTitle ?? "撤销"
  }


  /// A text field or view has keyboard focus (its own undo applies).
  @MainActor
  static var textIsEditing: Bool {
    NSApp.keyWindow?.firstResponder is NSTextView
  }
}
