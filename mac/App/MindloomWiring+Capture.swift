import AppKit
import BestASRMemory
import BestASRMemoryUI
import SwiftUI

// OWNER: mac-capture. Wires capture, menu bar, Welcome, Settings, consent, spaces to the App: fill `MemoryScreenState.captureExtras`
// and `MemoryActions.capture` here, so the three v11 branches never
// edit the same lines of ContentView+Memory.swift.
extension ContentView {
  /// Adds this branch's values to the page state.
  func patchCaptureState(_ state: inout MemoryScreenState) {
    CaptureWiring.startOnce(self)
    // Settings and the consent panel name matters and groups as the pages do.
    MindloomTitles.shared.update(state)
    state.captureExtras.fnTaken = model.fnHeldByOtherApp
    // Home's offline line: 「{n} 条先放在这台 Mac」.
    if state.link.waiting == 0 { state.link.waiting = model.waitingForSpark }
  }

  /// Adds this branch's actions.
  func wireCaptureActions(_ actions: inout MemoryActions) {
    let spacesModel = spaces
    let navigation = $memoryNavigation
    // 去设置 and the sidebar's 设置 open the v11 Settings on the asked pane.
    actions.openSettings = { SettingsRouter.shared.open(named: $0) }
    actions.capture.leaveSpace = { spaceID in
      CaptureWiring.confirmLeave(spaceID, spaces: spacesModel) {
        navigation.wrappedValue = MemoryNavigation()
      }
    }
    spacesModel.onOpenSpace = { id in
      var next = MemoryNavigation()
      next.root = .space(id)
      navigation.wrappedValue = next
    }
  }
}

extension ContentView {
  func requestMapForOpenMatter(_ path: [MemoryRoute]) {
    guard case .matter(let id)? = path.last else { return }
    model.requestMatterMapIfMissing(id)
  }
}

/// The main window: brought back when it exists (also hidden behind
/// Welcome), opened only when there is none. `openWindow(id: "main")` on a
/// WindowGroup makes another instance, with its own screen model and spaces
/// loop (fix-mac).
@MainActor
enum MainWindow {
  static var existing: NSWindow? {
    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
  }

  static func show(_ openWindow: OpenWindowAction) {
    if let window = existing {
      if window.isMiniaturized { window.deminiaturize(nil) }
      window.makeKeyAndOrderFront(nil)
    } else {
      openWindow(id: "main")
    }
    NSApp.activate(ignoringOtherApps: true)
  }
}

/// One-time hookups of the main window to the capture surfaces.
@MainActor
enum CaptureWiring {
  private static var started = false

  static func startOnce(_ view: ContentView) {
    if started, !CaptureFeedback.shared.follows(view.memoryScreen) {
      let screen = view.memoryScreen
      let model = view.model
      DispatchQueue.main.async { CaptureFeedback.shared.attach(screen: screen, app: model) }
    }
    guard !started else { return }
    started = true
    let model = view.model
    let screen = view.memoryScreen
    let openWindow = view.openWindow
    DispatchQueue.main.async {
      CaptureFeedback.shared.attach(screen: screen, app: model)
      FnGuard.shared.attach(model)
      MeetingClock.shared.attach(model)
      MeetingState.shared.attach(model)
      model.installFnHUD()
      model.refreshWaitingForSpark()
      model.refreshModelImportOffer()
      // First launch: Welcome first, the main window after it.
      if WelcomeFlow.applies {
        openWindow(id: "welcome")
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true {
          window.orderOut(nil)
        }
      }
    }
    // The waiting count follows the link, while a window can show it
    // (ALIGNMENT 收1-3: no refresh work while the windows are hidden).
    Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
      Task { @MainActor in
        guard MemoryScreenModel.mainWindowOnScreen else { return }
        model.refreshWaitingForSpark()
      }
    }
  }

  /// 退出这个共享空间: asks first (leaving takes this Mac out of the space).
  static func confirmLeave(_ spaceID: String, spaces: SpacesModel, done: @escaping () -> Void) {
    let name = spaces.screen.space(spaceID)?.name ?? ""
    let alert = NSAlert()
    alert.messageText = "退出“\(name)”？"
    alert.informativeText = "这台 Mac 上此共享空间的内容将被删除。你共享过的事保留在空间中，你自己的事保持不变。"
    alert.alertStyle = .warning
    let leave = alert.addButton(withTitle: "退出")
    leave.hasDestructiveAction = true
    alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    spaces.leave(spaceID)
    done()
  }
}
