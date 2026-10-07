import BestASRMemory
import Foundation

// OWNER: mac-matter. State and actions only mac-matter's pages need (the matter page, its popovers, the move and delete sheets, the undo window's page side).
// Add fields here (not to MemoryScreenState / MemoryActions) so the three
// v11 branches never edit the same lines; the App fills them in
// App/MindloomWiring+Matter.swift.

/// Extra values for mac-matter's pages (`MemoryScreenState.matterExtras`).
public struct MemoryMatterExtras {
  /// A 原文 row whose 「⋯」 menu a still image shows open (the real menu is
  /// AppKit's and is not drawn by `ImageRenderer`). Nil in the App.
  public var stillMenuRow: String?

  public init(stillMenuRow: String? = nil) {
    self.stillMenuRow = stillMenuRow
  }
}

/// Extra actions for mac-matter's pages (`MemoryActions.matter`); every
/// default does nothing.
public struct MemoryMatterActions {
  /// 「复制」 on a 原文 item: its words as plain text (toast 「已复制」).
  public var copyWords: @MainActor (_ text: String) -> Void = { _ in }

  public init() {}
}
