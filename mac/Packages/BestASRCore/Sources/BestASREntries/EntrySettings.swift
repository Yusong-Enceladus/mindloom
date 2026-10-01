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

  public var id: String { rawValue }

  /// Settings → 入口, in this order.
  public static let settingsOrder: [EntryKind] = [
    .shareSheet, .services, .browserExtension, .shortcuts, .commandLine, .folderWatch, .calendar,
    .reminders, .git, .zotero,
  ]

  /// Entries that take things in without the owner acting each time; off
  /// until the owner switches them on.
  public var capturesInBackground: Bool {
    switch self {
    case .folderWatch, .calendar, .git, .zotero: true
    default: false
    }
  }

  /// On by default: the ones the owner triggers by hand each time through
  /// the system (share, Shortcuts) and the Reminders button, which writes
  /// only when clicked. Services is off by default (review V8R-17): any app
  /// can call a Services item programmatically. The command line is off by default: anything
  /// running as the owner (an agent in a terminal too) could use it. The
  /// Chrome extension is off until the owner installs its connection (the
  /// host manifest) with a click in Settings.
  public var isOnByDefault: Bool {
    switch self {
    case .shareSheet, .shortcuts, .reminders: true
    // Review V8R-17: any app on this Mac can invoke a Services item; off until
    // the owner switches it on.
    case .services, .browserExtension, .commandLine, .folderWatch, .calendar, .git, .zotero: false
    }
  }

  public var title: String {
    switch self {
    case .shareSheet: "分享菜单「收进织机」"
    case .services: "服务菜单「收进织机」"
    case .browserExtension: "Chrome 扩展「收进织机」"
    case .shortcuts: "快捷指令"
    case .commandLine: "命令行 mindloom"
    case .folderWatch: "文件夹"
    case .calendar: "日历"
    case .reminders: "提醒事项"
    case .git: "Git 仓库"
    case .zotero: "Zotero"
    }
  }

  /// One plain sentence: what it takes in and what it never does.
  public var detail: String {
    switch self {
    case .shareSheet:
      "在 Safari、邮件、备忘录、访达等的「分享」里选「收进织机」。链接只记下，不会打开。"
    case .services:
      "选中文字后，在 App 菜单 → 服务 里选「收进织机」。打开后，本机任何 App 也能通过服务菜单把文字送进来，所以默认关着。"
    case .browserExtension:
      "在 Chrome 里右键或点工具栏的织机按钮，把选中的文字或网页链接收进来。链接只记下，不会打开；扩展不联网。"
    case .shortcuts:
      "「添加到织机」收进文字、文件或链接；「织机：今天到期」只读本机内容。"
    case .commandLine:
      "在终端里用 mindloom add / mindloom due。打开后，以你的身份运行的程序（包括终端里的 Agent）也能用它，算作你自己收进的内容。"
    case .folderWatch:
      "你选的文件夹里新出现的文件会被收进来。可以设排除规则、大小上限，随时暂停。打开前已有的文件不收。"
    case .calendar:
      "读取你选的日历里的日程（标题、时间、参与人姓名、备注），收成来源为「日历」的条目。从不写日历。"
    case .reminders:
      "只在你点「把下一步加到提醒事项」时，写一条提醒事项。不会自动写。优先写进只在这台 Mac 上的列表；没有的话写进默认列表，那通常经 iCloud 同步，写完会告诉你。"
    case .git:
      "本机仓库里所选分支的新提交：标题、说明、改动的文件名和数量。从不读取文件内容。Overleaf 的 git 仓库也可以。"
    case .zotero:
      "Zotero 在本机开放接口时，新的文献、笔记和批注收成带引用的条目。只连本机，不联网。"
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
