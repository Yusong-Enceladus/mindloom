import AppIntents

/// Siri and Shortcuts: 「用 Mindloom 录音」 starts recording on Apple Watch (WATCH-006).
struct WatchShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartRecordingIntent(),
      phrases: ["用\(.applicationName)录音", "\(.applicationName)录音"],
      shortTitle: "录音",
      systemImageName: "mic.fill")
  }
}
