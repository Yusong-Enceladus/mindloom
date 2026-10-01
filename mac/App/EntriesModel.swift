import BestASREntries
import Combine
import Foundation
import MindloomShareDrop

/// Settings → 入口 (V8 contract §A): every way into 织机 besides paste and
/// drop, each with its own switch, and what the background ones watch. The
/// settings and each entry's small state live in the library's private
/// `entries` folder; the work is done by `DictationAppModel+Entries`.
@MainActor
final class EntriesModel: ObservableObject {
  @Published var settings = EntrySettings.defaults
  /// What each entry last did, or why it cannot run (no content).
  @Published var notes: [EntryKind: String] = [:]
  @Published var calendars: [CalendarInfo] = []
  @Published var calendarAccess: CalendarAccess = .notDetermined
  /// Branches of each watched repository, for the picker.
  @Published var repositoryBranches: [UUID: [String]] = [:]
  /// Files a watched folder did not take, newest first (names only).
  @Published var folderSkips: [String] = []
  /// Chrome's host manifest for the extension (A6), as last looked at.
  @Published var browserHost: BrowserHostManifest.Status = .absent
  /// Whether the library is open and entries are configured.
  @Published var isReady = false

  var folder: EntryFolder?
  var dropbox: ShareDropbox?
  var dropboxMonitor: FolderChangeMonitor?
  var folderMonitor: FolderChangeMonitor?
  var folderState = FolderWatchState()
  var calendarState = CalendarSyncState()
  var gitState = GitWatchState()
  var zoteroState = ZoteroWatchState()
  /// One loop per background entry while it is on.
  var loops: [EntryKind: Task<Void, Never>] = [:]
  var folderScan: Task<Void, Never>?
  var calendarObserver: NSObjectProtocol?
  var shareInFlight = false
  let calendarReader = EventKitCalendarReader()
  let remindersWriter = EventKitRemindersWriter()
  let zoteroTransport = ZoteroLoopbackTransport()
  let gitRunner = GitRunner.locate()

  func isOn(_ kind: EntryKind) -> Bool { settings.isOn(kind) }

  func note(_ kind: EntryKind, _ text: String?) {
    notes[kind] = text
  }

  /// "上次收进 3 条 · 10:02".
  static func took(_ count: Int, at date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return count == 0
      ? "已检查 · \(formatter.string(from: date))，没有新的"
      : "上次收进 \(count) 条 · \(formatter.string(from: date))"
  }
}

/// How the App Intents and the Services menu reach the running App's model.
@MainActor
final class EntryHub {
  static let shared = EntryHub()
  weak var model: DictationAppModel?

  /// The model once the library is open; the system may launch the App to
  /// run a Shortcut, so this waits a little for it.
  func readyModel(timeout: Duration = .seconds(15)) async -> DictationAppModel? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if let model, model.entries.isReady { return model }
      try? await Task.sleep(for: .milliseconds(200))
    }
    return nil
  }
}
