import SwiftUI
import WatchConnectivity
import WatchKit

/// Mindloom on Apple Watch (PRD WATCH-001–008): records, and hands each recording to the iPhone,
/// which keeps the original and transcribes it. The complication, the control and Siri open it and
/// start recording at once.
@main
struct MindloomWatchApp: App {
  @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = WatchModel.shared

  var body: some Scene {
    WindowGroup {
      RecordView()
        .environment(model)
        .onOpenURL { url in model.open(url) }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { model.becameActive() }
    }
  }
}

/// Background refreshes (send what waits) and WatchConnectivity wake-ups (an iPhone "stored").
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
  func applicationDidFinishLaunching() {
    _ = MainActor.assumeIsolated { WatchModel.shared }
    #if DEBUG
      MainActor.assumeIsolated { DebugStarts.install() }
    #endif
  }

  func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
    for task in backgroundTasks {
      switch task {
      case let refresh as WKApplicationRefreshBackgroundTask:
        // After a launch in the background the session has only just been asked to activate:
        // wait for it (bounded), then hand over what is due.
        let link = MainActor.assumeIsolated { WatchModel.shared.link }
        let pending = refresh
        Task {
          _ = await link.waitUntilActivated(seconds: 10)
          await MainActor.run {
            link.sendDue()
            WatchModel.shared.refresh()
          }
          pending.setTaskCompletedWithSnapshot(false)
        }
      case let connectivity as WKWatchConnectivityRefreshBackgroundTask:
        // Keep the task until WatchConnectivity has delivered what woke the app.
        let link = MainActor.assumeIsolated { WatchModel.shared.link }
        let pending = connectivity
        Task {
          var waited = 0
          while waited < 20, !link.isActivated || link.hasContentPending {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
          }
          await MainActor.run { WatchModel.shared.refresh() }
          pending.setTaskCompletedWithSnapshot(false)
        }
      default:
        task.setTaskCompletedWithSnapshot(false)
      }
    }
  }
}

#if DEBUG
  /// DEBUG only, for the simulator. Neither `XCUIApplication.open(_:)` nor `simctl openurl` can
  /// open `mindloom://record` on the watchOS 26.5 simulator (the launch fails; LaunchServices
  /// error 115), and a control or Siri cannot be driven from a test. These hooks call exactly what
  /// those paths call once the system hands them over:
  /// - `-MindloomWatchOpenURL <url>` at launch: `WatchModel.open(_:)`, as `onOpenURL` does, before
  ///   the app is active (a cold launch from the complication);
  /// - the Darwin notification `app.mindloom.watchkitapp.debug.open-record`: the same, in a running app;
  /// - the Darwin notification `app.mindloom.watchkitapp.debug.intent-record`: `RecordRequest.post()`, the
  ///   body of `StartRecordingIntent.perform` (the control, Siri, Shortcuts).
  @MainActor
  enum DebugStarts {
    static let openRecord = "app.mindloom.watchkitapp.debug.open-record"
    static let intentRecord = "app.mindloom.watchkitapp.debug.intent-record"

    static func install() {
      if let link = UserDefaults.standard.string(forKey: "MindloomWatchOpenURL"),
        let url = URL(string: link)
      {
        WatchModel.shared.open(url)
      }
      let center = CFNotificationCenterGetDarwinNotifyCenter()
      for name in [openRecord, intentRecord] {
        CFNotificationCenterAddObserver(
          center, nil,
          { _, _, name, _, _ in
            let which = name?.rawValue as String?
            DispatchQueue.main.async {
              MainActor.assumeIsolated {
                if which == DebugStarts.openRecord {
                  WatchModel.shared.open(RecordRequest.url)
                } else if which == DebugStarts.intentRecord {
                  RecordRequest.post()
                }
              }
            }
          }, name as CFString, nil, .deliverImmediately)
      }
    }
  }
#endif
