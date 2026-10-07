import Darwin
import Foundation

/// Every way into 织机 besides paste and drop (V8 contract §A, "兼容一切"),
/// each listed in Settings → 入口 with its own switch. All of them go through
/// the same intake rules as a paste or a drop and keep their source and time.
/// Nothing captures in the background unless the owner switched it on.
public enum EntryKind: String, Codable, CaseIterable, Identifiable, Sendable {
  /// The macOS share extension 「收进织机」 (A1).
  case shareSheet
  /// The Services menu item for selected text (A1).
  case services
  /// The Chrome extension 「收进织机」 through the native messaging host (A6);
  /// on only while its host manifest is installed from Settings.
  case browserExtension
  /// App Intents / Shortcuts: 添加到织机, 织机：今天到期 (A2).
  case shortcuts
  /// The `mindloom` command line over the private socket (A3).
  case commandLine
  /// Watched folders (A4).
  case folderWatch
  /// Calendar events as items (A5).
  case calendar
  /// 把下一步加到提醒事项, only on the owner's click (A5).
  case reminders
  /// New commits in watched local Git repositories (A7).
  case git
  /// Zotero's local API on this Mac (A7).
  case zotero
  /// Meeting transcripts from the owner's Tencent Meeting account, fetched
  /// on this Mac through the bundled tmeet (ENTRY-013).
  case tencentMeeting

  public var id: String { rawValue }

  /// Settings → 入口, in this order.
  public static let settingsOrder: [EntryKind] = [
    .shareSheet, .services, .browserExtension, .shortcuts, .commandLine, .folderWatch, .calendar,
    .reminders, .git, .zotero, .tencentMeeting,
  ]

  /// Entries that take things in without the owner acting each time; off
  /// until the owner switches them on.
  public var capturesInBackground: Bool {
    switch self {
    case .folderWatch, .calendar, .git, .zotero, .tencentMeeting: true
    default: false
    }
  }

  /// On by default: the share sheet, which the owner triggers by hand each
  /// time through the system, and the Reminders button, which writes only
  /// when clicked. Services is off by default (review V8R-17): any app can
  /// call a Services item programmatically. Shortcuts is off by default for
  /// the same reason (v12 F10): any program can run a shortcut
  /// (`shortcuts run`), and 「今天到期」 reads the owner's steps. The command
  /// line is off by default: anything running as the owner (an agent in a
  /// terminal too) could use it. The Chrome extension is off until the owner
  /// installs its connection (the host manifest) with a click in Settings.
  public var isOnByDefault: Bool {
    switch self {
    case .shareSheet, .reminders: true
    // Review V8R-17 and v12 F10: any app on this Mac can invoke a Services
    // item or run a shortcut; off until the owner switches them on.
    case .services, .shortcuts, .browserExtension, .commandLine, .folderWatch, .calendar, .git,
      .zotero, .tencentMeeting:
      false
    }
  }

  /// What a shortcut answers while 快捷指令 is off in 设置 › 入口.
  public static let shortcutsOffMessage = "快捷指令未打开。请在 Mindloom 的“设置”>“入口”中打开。"

  public var title: String {
    switch self {
    case .shareSheet: "共享菜单中的 Mindloom"
    case .services: "服务菜单“添加到 Mindloom”"
    case .browserExtension: "Chrome 扩展“添加到 Mindloom”"
    case .shortcuts: "快捷指令"
    case .commandLine: "命令行 mindloom"
    case .folderWatch: "文件夹"
    case .calendar: "日历"
    case .reminders: "提醒事项"
    case .git: "Git 仓库"
    case .zotero: "Zotero"
    case .tencentMeeting: "腾讯会议"
    }
  }

  /// One plain sentence: what it takes in and what it never does.
  public var detail: String {
    switch self {
    case .shareSheet:
      "在 Safari、邮件、备忘录、访达等 App 的“共享”菜单中选取 Mindloom。链接按文字添加。"
    case .services:
      "选中文字后，在 App 菜单 >“服务”中选取“添加到 Mindloom”。打开后，这台 Mac 上的任何 App 都可以通过服务菜单添加文字，因此默认关闭。"
    case .browserExtension:
      "在 Chrome 中右键点按或点按工具栏中的 Mindloom 按钮，将所选文字或网页链接添加到 Mindloom。链接按文字添加。"
    case .shortcuts:
      "“添加到 Mindloom”添加文字、文件或链接；“Mindloom：今天到期”将今天到期和已过期的下一步提供给快捷指令。打开后，这台 Mac 上的其他程序也可以运行这两个快捷指令，因此默认关闭。"
    case .commandLine:
      "在“终端”中使用 mindloom add / mindloom due。打开后，以你的身份运行的程序（包括“终端”中的 Agent）也可以使用它，添加的内容视为你本人添加。"
    case .folderWatch:
      "添加你所选文件夹中的新文件。可以设置排除规则和大小上限，也可以随时暂停。仅添加打开此入口之后的新文件。"
    case .calendar:
      "读取你所选日历中的日程（标题、时间、参与人姓名、备注），添加为来源是“日历”的条目。"
    case .reminders:
      "点按“将下一步添加到提醒事项”时，创建一个提醒事项。优先添加到储存在这台 Mac 上的列表；没有此类列表时添加到默认列表，默认列表通常通过 iCloud 同步，添加后会告诉你。"
    case .git:
      "读取本机仓库中所选分支的新提交：标题、说明、更改的文件名和数量。也支持 Overleaf 的 git 仓库。"
    case .zotero:
      "Zotero 在这台 Mac 上开放接口时，将新的文献、笔记和批注添加为带引用的条目。"
    case .tencentMeeting:
      "会议结束后，自动添加你的腾讯会议账户可以查看的会议转写，包括其他人主持并向你共享转写的会议。在这台 Mac 上连接一次后，之后的会议都会自动添加。"
    }
  }
}

/// A folder the owner chose to watch (A4).
public struct WatchedFolder: Codable, Equatable, Identifiable, Sendable {
  public static let defaultMaximumMegabytes = 50

  public var id: UUID
  public var path: String
  /// Glob patterns on file names (`*.dmg`, `截屏*`), case-insensitive.
  public var exclusions: [String]
  public var maximumMegabytes: Int
  public var paused: Bool

  public init(
    id: UUID = UUID(), path: String, exclusions: [String] = [],
    maximumMegabytes: Int = WatchedFolder.defaultMaximumMegabytes, paused: Bool = false
  ) {
    self.id = id
    self.path = path
    self.exclusions = exclusions
    self.maximumMegabytes = maximumMegabytes
    self.paused = paused
  }

  public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
  public var displayName: String { url.lastPathComponent }
  public var maximumBytes: UInt64 { UInt64(max(1, maximumMegabytes)) * 1_024 * 1_024 }
}

/// A local Git repository and the branches whose new commits are taken (A7).
public struct WatchedRepository: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var path: String
  /// Empty means the branch checked out when the repository was added.
  public var branches: [String]

  public init(id: UUID = UUID(), path: String, branches: [String] = []) {
    self.id = id
    self.path = path
    self.branches = branches
  }

  public var displayName: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// Settings → 入口: one switch per entry, plus what each entry watches.
/// Stored in the library's private `entries` folder, never sent.
public struct EntrySettings: Codable, Equatable, Sendable {
  /// Switches the owner changed (`EntryKind.rawValue` → on); the rest use
  /// `EntryKind.isOnByDefault`.
  public var switches: [String: Bool]
  public var folders: [WatchedFolder]
  /// Pauses every watched folder at once.
  public var foldersPaused: Bool
  /// Calendar identifiers the owner chose to read.
  public var calendarIDs: [String]
  public var repositories: [WatchedRepository]

  public init(
    switches: [String: Bool] = [:], folders: [WatchedFolder] = [], foldersPaused: Bool = false,
    calendarIDs: [String] = [], repositories: [WatchedRepository] = []
  ) {
    self.switches = switches
    self.folders = folders
    self.foldersPaused = foldersPaused
    self.calendarIDs = calendarIDs
    self.repositories = repositories
  }

  public static let defaults = EntrySettings()

  public func isOn(_ kind: EntryKind) -> Bool {
    switches[kind.rawValue] ?? kind.isOnByDefault
  }

  public mutating func set(_ kind: EntryKind, on: Bool) {
    switches[kind.rawValue] = on
  }

  enum CodingKeys: String, CodingKey {
    case switches, folders
    case foldersPaused = "folders_paused"
    case calendarIDs = "calendar_ids"
    case repositories
  }

  /// Unknown or missing fields fall back to the defaults, so an older or
  /// newer file never turns anything on by itself.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawSwitches = (try? container.decode([String: Bool].self, forKey: .switches)) ?? [:]
    switches = rawSwitches.filter { EntryKind(rawValue: $0.key) != nil }
    folders = (try? container.decode([WatchedFolder].self, forKey: .folders)) ?? []
    foldersPaused = (try? container.decode(Bool.self, forKey: .foldersPaused)) ?? false
    calendarIDs = (try? container.decode([String].self, forKey: .calendarIDs)) ?? []
    repositories = (try? container.decode([WatchedRepository].self, forKey: .repositories)) ?? []
  }
}

/// The library's private `entries` folder (0700): settings, each entry's
/// small state file, and the share extension's drop folder. Local only:
/// never sent, never in a portable archive.
public struct EntryFolder: Sendable {
  public static let name = "entries"
  public let url: URL

  public init(dataRoot: URL) {
    url = dataRoot.appendingPathComponent(Self.name, isDirectory: true)
  }

  public var settingsURL: URL { url.appendingPathComponent("settings.json") }

  public func stateURL(_ kind: EntryKind) -> URL {
    url.appendingPathComponent("state-\(kind.rawValue).json")
  }

  /// Creates the folder 0700 (an existing one must be this user's folder).
  @discardableResult
  public func prepare() -> Bool {
    var entry = stat()
    if lstat(url.path, &entry) != 0 {
      guard mkdir(url.path, S_IRWXU) == 0 || errno == EEXIST else { return false }
      guard lstat(url.path, &entry) == 0 else { return false }
    }
    guard entry.st_mode & S_IFMT == S_IFDIR, entry.st_uid == getuid() else { return false }
    if entry.st_mode & 0o077 != 0 { chmod(url.path, S_IRWXU) }
    return true
  }

  public func loadSettings() -> EntrySettings {
    guard let data = Self.read(settingsURL),
      let settings = try? JSONDecoder().decode(EntrySettings.self, from: data)
    else { return .defaults }
    return settings
  }

  public func save(_ settings: EntrySettings) throws {
    try write(settings, to: settingsURL)
  }

  public func loadState<State: Decodable>(_ kind: EntryKind, as type: State.Type) -> State? {
    Self.read(stateURL(kind)).flatMap { try? JSONDecoder().decode(type, from: $0) }
  }

  public func saveState<State: Encodable>(_ state: State, for kind: EntryKind) throws {
    try write(state, to: stateURL(kind))
  }

  /// Forgets what an entry has seen (it was switched off): switching it on
  /// again starts from "now", never from what happened while it was off.
  public func clearState(_ kind: EntryKind) {
    unlink(stateURL(kind).path)
  }

  public enum WriteError: Error, Equatable, Sendable {
    case folder
    case write
  }

  /// Atomic, 0600.
  func write<Value: Encodable>(_ value: Value, to destination: URL) throws {
    guard prepare() else { throw WriteError.folder }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    let temporary = url.appendingPathComponent(".\(UUID().uuidString).tmp")
    let descriptor = Darwin.open(
      temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw WriteError.write }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
    } catch {
      unlink(temporary.path)
      throw WriteError.write
    }
    guard rename(temporary.path, destination.path) == 0 else {
      unlink(temporary.path)
      throw WriteError.write
    }
  }

  static func read(_ url: URL) -> Data? {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    return try? handle.readToEnd()
  }
}
