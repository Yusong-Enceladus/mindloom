import AppKit

/// ⌘F in the main window always focuses Mindloom's search field (MAC-SPEC
/// §5.3). The system's 编辑 › 查找 submenu (with 拼写和语法, 替换 …) stays in
/// the menu; the App looks at ⌘F before the menu does, so the system's own
/// 查找… never takes the key from the search field (finish-mac).
public enum MindloomFindShortcut {
  /// Exactly ⌘F (caps lock and the fn/number-pad bits ignored; ⇧⌘F, ⌥⌘F
  /// and ⌃⌘F are other commands).
  public static func isFind(
    modifierFlags: NSEvent.ModifierFlags, charactersIgnoringModifiers: String?
  ) -> Bool {
    let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    return flags == .command && charactersIgnoringModifiers?.lowercased() == "f"
  }

  /// The menu's 查找… (`performTextFinderAction:` / `performFindPanelAction:`)
  /// with this tag shows the find interface; the other tags (查找下一个 …)
  /// have nothing to do outside a text view.
  public static func showsFindInterface(tag: Int) -> Bool {
    tag == NSTextFinder.Action.showFindInterface.rawValue
  }

  /// Whether ⌘F or 查找… may focus the search field of `window`: never while
  /// a sheet is open on it (the field is behind the sheet; review
  /// finish-ship).
  @MainActor
  public static func mayFocusSearch(in window: NSWindow?) -> Bool {
    mayFocusSearch(sheetOpen: window?.attachedSheet != nil)
  }

  public static func mayFocusSearch(sheetOpen: Bool) -> Bool { !sheetOpen }
}
