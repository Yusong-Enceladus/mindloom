import AppKit
import BestASRDictation
import BestASRMacUI
import BestASRMemoryUI
import MindloomDesign
import SwiftUI

// OWNER: mac-capture. The fn HUD's view in its panel (MAC-SPEC §8; v12 B1),
// the microphone hint, and the preview's fn guard (it does not arm fn while
// the user's own bestASR App runs, and says so in one quiet line).

/// The package's `FnHUDView` over the panel's live presentation.
struct FnHUDHost: View {
  @ObservedObject var presentation: FnHUDPresentation
  let openSettings: () -> Void

  var body: some View {
    FnHUDView(
      input: Self.input(presentation), listener: presentation.listener,
      openSettings: openSettings
    )
    .environment(\.mlPlatform, .mac)
  }

  static func input(_ presentation: FnHUDPresentation) -> FnHUDInput {
    let hint: FnHUDHint? =
      switch presentation.hint {
      case .microphoneOff?: .microphoneOff
      case .fnTaken?: .fnTaken
      case nil: nil
      }
    var input = FnHUDInput(
      caption: presentation.captionShown ? presentation.committed : nil,
      pending: presentation.captionShown ? presentation.pending : "", hint: hint,
      badge: presentation.badge.map { FnHUDBadge(text: $0.text, note: $0.note, label: $0.label) },
      notice: presentation.notice.map {
        FnHUDNotice(symbol: $0.symbol, text: $0.text, detail: $0.detail)
      })
    input.revised = presentation.captionShown ? presentation.revised : []
    return input
  }
}

extension DictationAppModel {
  /// Puts the v11 view into the HUD panel once.
  func installFnHUD() {
    guard recordingPanel.makeContent == nil else { return }
    recordingPanel.makeContent = { presentation in
      AnyView(
        FnHUDHost(presentation: presentation) { SettingsRouter.shared.open(.entries) }
          .mlNoAutospace())
    }
  }

  /// fn went down: with the microphone not allowed (or 按住 fn 说话 off) the
  /// HUD says 「麦克风没有打开 · 去设置」 instead of listening.
  /// Returns false when the press must not start a dictation.
  func fnPressAllowed() -> Bool {
    installFnHUD()
    // 按住 fn 说话 off, or the user's bestASR holds fn: never a dictation,
    // whatever is registered (fix-mac: a relaunch could arm fn anyway).
    guard fnEntryEnabled, !MindloomBuild.otherAppHoldsFn else { return false }
    // Blocked during Welcome (MAC-SPEC §8).
    if WelcomeState.isOpen { return false }
    if [.denied, .restricted, .revoked].contains(capture.microphonePermission) {
      recordingPanel.showHint(.microphoneOff)
      return false
    }
    return true
  }
}

/// Mindloom Preview beside the user's own App (Mindloom, app.mindloom, or
/// bestASR before it; and their development builds): fn is not armed at all while it runs, and armed again when it
/// quits. Settings › 入口 「按住 fn 说话」 off does the same in any build.
@MainActor
final class FnGuard {
  static let shared = FnGuard()
  private weak var app: DictationAppModel?
  private var observers: [NSObjectProtocol] = []
  /// The last arming or suspension: each waits for the one before, so the
  /// registration always ends in the state asked for last.
  private var chain: Task<Void, Never>?

  /// Follows other fn Apps launching and quitting. The App attaches it
  /// before its launch arming, which goes through `arm(atLaunch:)`.
  func attach(_ app: DictationAppModel, applyNow: Bool = true) {
    guard self.app == nil else {
      if applyNow { update() }
      return
    }
    self.app = app
    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
    ] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
          let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
            .bundleIdentifier
          guard let id, MindloomBuild.otherFnAppBundleIDs.contains(id) else { return }
          Task { @MainActor in self?.update() }
        })
    }
    if applyNow { update() }
  }

  /// The launch's first arming: the saved shortcut when fn may be armed,
  /// nothing otherwise. In the same chain as every later change.
  func arm(atLaunch app: DictationAppModel) async {
    guard let controller = app.hotkeyController else { return }
    let arm = Self.shouldArmAtLaunch(app)
    enqueue {
      if arm {
        let result = await controller.activateSavedOrDefault()
        await app.publishHotkeyResult(result, controller: controller)
      } else {
        await controller.suspend()
      }
    }
    await chain?.value
  }

  /// A shortcut chosen in 高级: registered when fn may be armed, otherwise
  /// only saved (按住 fn 说话 off, the user's bestASR running, a
  /// verification run), never armed for a moment. In the same chain.
  func apply(
    _ configuration: DictationHotkeyConfiguration, app: DictationAppModel?,
    controller: GlobalHotkeyConfigurationController
  ) async {
    let arm = shouldArm
    enqueue { [weak app] in
      if arm {
        let result = await controller.apply(configuration)
        await app?.publishHotkeyResult(result, controller: controller)
      } else {
        do {
          try await controller.remember(configuration)
          app?.hotkeys.hotkeyStatusMessage = "快捷键已保存"
        } catch {
          app?.hotkeys.hotkeyStatusMessage = "未能保存快捷键，原设置保持不变"
        }
      }
    }
    await chain?.value
  }

  private func enqueue(_ work: @escaping @MainActor () async -> Void) {
    let previous = chain
    chain = Task { @MainActor in
      await previous?.value
      await work()
    }
  }

  /// Whether fn should be armed now.
  var shouldArm: Bool {
    guard let app else { return true }
    return Self.shouldArmAtLaunch(app)
  }

  /// The same rule before the guard is attached (the launch's first arming).
  static func shouldArmAtLaunch(_ app: DictationAppModel) -> Bool {
    // A verification run never arms fn (`-MindloomNoArm YES`, in every build).
    if MindloomLaunch.noArm { return false }
    #if MINDLOOM_PREVIEW
      // Nor does a live-shots run.
      if PreviewLaunch.noArm { return false }
    #endif
    return app.fnEntryEnabled && !MindloomBuild.otherAppHoldsFn
  }

  func update() {
    let taken = MindloomBuild.otherAppHoldsFn
    if CaptureState.shared.fnHeldByOtherApp != taken {
      CaptureState.shared.fnHeldByOtherApp = taken
      // The one quiet line, once, when it starts to apply.
      if taken, let app {
        app.installFnHUD()
        app.recordingPanel.showHint(.fnTaken)
      }
    }
    // Always applied (no cached "armed" that could disagree with what is
    // registered), in order with every other arming.
    let arm = shouldArm
    guard let app, let controller = app.hotkeyController else { return }
    enqueue {
      if arm {
        let result = await controller.refreshActiveRegistration()
        await app.publishHotkeyResult(result, controller: controller)
      } else {
        await controller.suspend()
      }
    }
  }
}
