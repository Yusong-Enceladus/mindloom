import AppKit
import BestASRMemoryUI
import BestASRPersistence
import BestASRRemoteOrganizer
import MindloomDesign
import MindloomLibrary
import SwiftUI

enum BestASRProcessEnvironment {
  static var isXCTestHost: Bool {
    isXCTestHost(
      environment: ProcessInfo.processInfo.environment,
      xctestClassAvailable: NSClassFromString("XCTestCase") != nil
    )
  }

  static func isXCTestHost(
    environment: [String: String],
    xctestClassAvailable: Bool
  ) -> Bool {
    environment["XCTestConfigurationFilePath"] != nil
      || environment["XCInjectBundleInto"] != nil
      || xctestClassAvailable
  }
}

@MainActor
private final class BestASRApplicationDelegate: NSObject, NSApplicationDelegate {
  /// With the organizing link on, quitting first asks the organizing device
  /// to lock its store (at most two seconds; privacy review F1).
  /// Corrections still in their undo window are committed first (v11: a
  /// held correction is never lost by quitting). The library is closed last,
  /// its WAL checkpointed, so the next open has nothing to recover
  /// (REHEARSAL.md §8); quitting waits at most `LibraryQuit.quitWaitSeconds`
  /// for it (review 10-5d R6). With none of these the app quits at once.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let held = MemoryCorrectionQuit.queue?.hasWork ?? false
    let controller = RemoteOrganizerQuitLock.controller
    let locking = controller?.isRuntimeRunning ?? false
    let libraryOpen = LibraryQuit.store != nil
    guard held || locking || libraryOpen else { return .terminateNow }
    Task { @MainActor in
      await MemoryCorrectionQuit.queue?.commitAll()
      if let controller, controller.isRuntimeRunning { await controller.shutdownLocking() }
      await LibraryQuit.close(within: LibraryQuit.quitWaitSeconds)
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Ends the organizer ssh child synchronously; a crash leaves a durable
    // record that the next launch uses to end the orphan.
    RemoteOrganizerProcessRegistry.terminateAll()
    // The agent socket goes with the App (the helper then says 织机没有在运行).
    AgentAccessQuit.server?.stop()
  }

  /// 编辑 › 查找 › 查找… outside a text view (nothing nearer the key window
  /// takes it): Mindloom's search field (MAC-SPEC §3.1). ⌘F itself is taken
  /// by `MindloomFindKeyMonitor` before the menu.
  @objc func performTextFinderAction(_ sender: Any?) {
    findMenuItem(sender)
  }

  @objc func performFindPanelAction(_ sender: Any?) {
    findMenuItem(sender)
  }

  private func findMenuItem(_ sender: Any?) {
    let tag = (sender as? NSMenuItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
    guard MindloomFindShortcut.showsFindInterface(tag: tag) else { return }
    MindloomFind.focusSearch()
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    #if MINDLOOM_PREVIEW
      // `-MindloomAppearance light|dark` (verification runs shoot both).
      PreviewLaunch.applyAppearance()
    #endif
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Window menus with their icons and red destructive items (§7.5).
    MindloomMenuStyle.install()
    // Words selected in the window and copied carry Mindloom's origin mark.
    MindloomCopyMarker.install()
    // 收进织机 in other Apps' Services menu (V8 contract A1).
    if !BestASRProcessEnvironment.isXCTestHost {
      NSApplication.shared.servicesProvider = MindloomServicesProvider.shared
      NSUpdateDynamicServices()
    }
    // End an organizer ssh forward orphaned by a crash of an earlier run,
    // whatever happens later with the library or the link preferences. Each
    // record carries its own exact command line; nothing else is touched.
    if let stateDirectory = try? DictationAppModel.remoteOrganizerStateDirectory() {
      RemoteOrganizerTunnelRecordStore(directory: stateDirectory).cleanUpStale()
    }
    guard
      ProcessInfo.processInfo.arguments.contains("--ui-testing")
        || BestASRProcessEnvironment.isXCTestHost
    else { return }

    // Menu-bar apps are allowed to finish launching in the background. XCTest's
    // launch handshake, however, waits for both hosted unit-test and UI-test
    // processes to become active. Keep this behavior isolated to XCTest so the
    // production focus-preservation contract is unchanged.
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}

/// `mindloom://share-inbox`: the share extension tells the App to look in
/// its drop folder. Any other `mindloom:` URL does the same and nothing more.
/// (Mindloom Preview: `mindloom-preview:`, from its Info.plist.)
enum ShareEntryURL {
  static var scheme: String { MindloomBuild.urlScheme }
}

@main
enum BestASREntry {
  @MainActor
  static func main() {
    #if DEBUG
      // The delivery probe is a diagnostic process, not the app, only with
      // its explicit launch argument. It runs only in the check app and is
      // never compiled into the product or the preview (review 10-5c P4).
      if DeliveryProbeLaunch.runIfRequested() { return }
    #endif
    #if MINDLOOM_PREVIEW
      // The preview's 「使用这台 Mac 上已装的识别模型」 without any window.
      if HeadlessModelImport.runIfRequested() { return }
    #endif
    // Before anything reads a preference: bestASR's settings imported into
    // Mindloom's domain, then the ones Mindloom names differently (switch
    // 10-6). The import waits for the launch's decision on the library
    // (`MindloomLaunch.current` reads the arguments only, no preference):
    // only the team-signed product opening the owner's library imports.
    if !BestASRProcessEnvironment.isXCTestHost {
      CarryOverLaunch.importPreferences(launch: MindloomLaunch.current)
      ProductCarryOver.migratePreferences(.standard)
    }
    // Before anything reads a date: the process counts days in the
    // library's product time zone (根-13), whatever the Mac is set to.
    MindloomLaunch.applyProductTimeZone()
    // Before any store reads the keychain: the items the switch's helper
    // hands over (switch 10-6).
    if !BestASRProcessEnvironment.isXCTestHost, let launch = MindloomLaunch.launch {
      CarryOverLaunch.takeKeychainItems(launch: launch)
    }
    // A refused launch also says why on the terminal it was started from.
    if case .failure(let refusal) = MindloomLaunch.current,
      !BestASRProcessEnvironment.isXCTestHost
    {
      FileHandle.standardError.write(Data((MindloomLaunch.refusalMessage(refusal) + "\n").utf8))
    }
    BestASRApp.main()
  }
}

struct BestASRApp: App {
  @NSApplicationDelegateAdaptor(BestASRApplicationDelegate.self)
  private var applicationDelegate
  @StateObject private var model = DictationAppModel()
  private let hostedUnitTest =
    BestASRProcessEnvironment.isXCTestHost
    && !ProcessInfo.processInfo.arguments.contains("--ui-testing")
  private let settingsUITest = ProcessInfo.processInfo.arguments.contains(
    "--settings-ui-testing"
  )
  private let menuBarContentUITest = ProcessInfo.processInfo.arguments.contains(
    "--menu-bar-content-ui-testing"
  )

  var body: some Scene {
    WindowGroup("Mindloom", id: "main") {
      Group {
        if hostedUnitTest {
          Color.clear
            .frame(width: 1, height: 1)
        } else if menuBarContentUITest {
          MenuBarContentView(model: model)
        } else if settingsUITest {
          DictationSettingsView(model: model, scope: .all)
        } else {
          ContentView(model: model)
        }
      }
      .environment(\.locale, Locale(identifier: model.spoken.interfaceLanguageID))
      // Every text in the window keeps the prototype's spacing: no system
      // gap between Chinese and Latin letters or digits (macOS 27).
      .mlNoAutospace()
      // Finder's Open With should route to this workspace, not create another
      // main window sharing the same capture and selection state.
      .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
      .onOpenURL { url in
        // The share extension's poke: look in the drop folder (the URL
        // carries nothing else).
        if url.scheme == ShareEntryURL.scheme {
          model.pickUpShares()
          return
        }
        model.importMedia(url)
      }
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1188, height: 848)
    .commands {
      MindloomCommands(
        pasteIn: { model.receivePasteboard() }, pasteInDisabled: hostedUnitTest,
        importMedia: { model.chooseMediaToImport() },
        importTranscript: { model.chooseMeetingTranscripts() })
      // 编辑 › 查找 ›, 拼写和语法 ›, 替换 ›, 转换 ›, 语音 › (the system's own
      // items; ⌘F still goes to Mindloom's search field first).
      TextEditingCommands()
    }

    MenuBarExtra(
      isInserted: Binding(
        get: { !hostedUnitTest && model.menuBarEnabled },
        set: { if !hostedUnitTest { model.updateMenuBarInsertion($0) } }
      )
    ) {
      MenuBarContentView(model: model)
    } label: {
      MenuBarLabel()
        .accessibilityIdentifier("bestASR.menuBar")
        .task {
          MeetingClock.shared.attach(model)
          MeetingState.shared.attach(model)
        }
    }
    .menuBarExtraStyle(.menu)

    // v11 Settings (MAC-SPEC §9): 入口 · 设备与隐私 · 其他 App · 关于.
    Settings {
      MindloomSettingsScene(model: model).mlNoAutospace()
    }
    .windowResizability(.contentSize)

    // v11 Welcome (MAC-SPEC §10), first launch only.
    Window("欢迎使用 Mindloom", id: "welcome") {
      WelcomeScene(model: model).mlNoAutospace()
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)
    .defaultPosition(.center)

    // The older knobs (shortcut, microphone, storage, components, text
    // formats) live in their own window, reached from Settings › 关于.
    Window("高级", id: "advanced-settings") {
      DictationSettingsView(model: model, scope: .advanced)
        .environment(\.locale, Locale(identifier: model.spoken.interfaceLanguageID))
        .mlNoAutospace()
    }
    .windowResizability(.contentSize)
  }
}
