import AppKit
import BestASRRemoteOrganizer
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
  /// to lock its store (at most two seconds; privacy review F1). Without a
  /// running link the app quits at once.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let controller = RemoteOrganizerQuitLock.controller, controller.isRuntimeRunning else {
      return .terminateNow
    }
    Task { @MainActor in
      await controller.shutdownLocking()
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

  func applicationDidFinishLaunching(_ notification: Notification) {
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

@main
enum BestASREntry {
  @MainActor
  static func main() {
    // A paste probe is a diagnostic process, not the app; see PasteProbe.
    if PasteProbe.runIfRequested() { return }
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
    WindowGroup("织机", id: "main") {
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
      // Finder's Open With should route to this workspace, not create another
      // main window sharing the same capture and selection state.
      .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
      .onOpenURL { url in
        model.importMedia(url)
      }
    }
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(after: .pasteboard) {
        // Takes the clipboard in as an item even while a text field has focus.
        Button("收进来") { model.receivePasteboard() }
          .keyboardShortcut("v", modifiers: [.command, .shift])
          .disabled(hostedUnitTest)
      }
    }

    MenuBarExtra(
      isInserted: Binding(
        get: { !hostedUnitTest && model.menuBarEnabled },
        set: { if !hostedUnitTest { model.updateMenuBarInsertion($0) } }
      )
    ) {
      MenuBarContentView(model: model)
    } label: {
      Label("织机", systemImage: model.menuBarSymbol)
        .accessibilityIdentifier("bestASR.menuBar")
    }
    .menuBarExtraStyle(.window)

    Settings {
      DictationSettingsView(model: model)
        .environment(\.locale, Locale(identifier: model.spoken.interfaceLanguageID))
    }

    // Operator tooling — component provisioning, offline deployment,
    // verification and rollback, per-App text policies — lives in its own
    // window, reached from 更多, so Settings stays the four panes a user of a
    // dictation app expects to find there.
    Window("高级", id: "advanced-settings") {
      DictationSettingsView(model: model, scope: .advanced)
        .environment(\.locale, Locale(identifier: model.spoken.interfaceLanguageID))
    }
    .windowResizability(.contentSize)
  }
}
