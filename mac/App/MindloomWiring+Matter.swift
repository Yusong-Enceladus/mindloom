import BestASRMemory
import BestASRMemoryUI
import SwiftUI

// OWNER: mac-matter. Wires the matter page to the App: fill `MemoryScreenState.matterExtras`
// and `MemoryActions.matter` here, so the three v11 branches never
// edit the same lines of ContentView+Memory.swift.
extension ContentView {
  /// Adds this branch's values to the page state.
  func patchMatterState(_ state: inout MemoryScreenState) {}

  /// Adds this branch's actions.
  func wireMatterActions(_ actions: inout MemoryActions) {
    let screen = memoryScreen
    // 原文 item › 复制: the words as plain text, with bestASR's own mark so
    // ⌘V here does not take them in again as an item.
    actions.matter.copyWords = { text in
      if LocalPasteboardWriter().write(text) {
        screen.show(MemoryToast("已拷贝", icon: .symbol("doc.on.doc")))
      }
    }
  }
}
