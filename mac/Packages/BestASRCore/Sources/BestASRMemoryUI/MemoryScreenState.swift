import AppKit
import BestASRDomain
import BestASRMemory
import Foundation

/// Everything the Mindloom pages show, as values. The App builds it from its
/// models (or a test builds it from a synthetic fixture); the views never
/// read storage, the link, or a model SDK. See FOUNDATION.md for which agent
/// owns which page.
public struct MemoryScreenState {
  public enum Mode: Equatable, Sendable {
    /// Organized by the user's own DGX Spark.
    case spark
    /// Organized on this Mac (the link is off or has nothing yet). Looks the
    /// same.
    case local
  }

  public var mode: Mode
  /// The read model's projection; nil until the first load. Setting it
  /// derives everything again (fixtures; the App passes a read model).
  public var projection: MemoryProjection? { didSet { derive() } }
  /// The organizer's Home order.
  public private(set) var home: [MemoryHomeEntry] = []
  /// Everyone seen in a matter, most recently seen first.
  public private(set) var recentPeople: [MemoryPersonEntry] = []
  /// The people who matter (in the most matters first).
  public private(set) var featuredPeople: [MemoryPersonEntry] = []
  public private(set) var people: [MemoryPersonEntry] = []
  /// Items in no matter (the organizer's own unfiled list).
  public private(set) var unfiled: [MemoryUnfiledItem] = []
  /// v11 derivations (§13): parts, steps, due / overdue, risk, 待定, the same
  /// capture's other matters, 按截止's rows. Nil before the first load.
  public private(set) var digest: MemoryDigest?

  /// Pins, user groups and step overrides (the digest already has the
  /// overrides applied; set `user` before `projection` in fixtures, or pass
  /// a read model built with it).
  public var user: UserOrganizingSnapshot
  /// Sidebar 共享 rows: the shared spaces this Mac is an active member of.
  public var spaces: [MemorySidebarSpace]
  /// Matter → how it is shared (meta line 「已共享到「…」」, row prefix
  /// 「{name}共享 · 」, member view).
  public var sharing: [String: MemoryShareInfo]
  /// The DGX Spark link as Home's offline line, Settings and the menu bar
  /// extra show it.
  public var link: MemoryLinkState
  /// Home's 「刚收进来」: captures that cannot be filed yet.
  public var waitingCaptures: [MemoryWaitingCapture]
  /// The row lit after something was filed into it (fades by itself).
  public var highlightedEventID: String?
  public var toast: MemoryToast?
  /// The one undo slot (编辑 › 撤销{label}, the toast's 撤销, ⌘Z).
  public var undo: MemoryUndoState?
  /// A meeting recording in progress.
  public var capture: MemoryCaptureIndicator?
  /// Corrections the DGX Spark did not take.
  public var issues: [MemoryIssue]
  /// The 历史 page: every record, or what the query found (filled by
  /// `searchText`).
  public var history = MemoryHistoryState()
  /// The record whose recording is loaded for playing (playing or paused):
  /// space and ← → steer it.
  public var playbackItemID: String?
  /// The item whose audio is playing, if any.
  public var playingItemID: String?
  /// Items other members shared (upper-case IDs).
  public var sharedItemIDs: Set<String> = []
  /// Demo mode (ALIGNMENT 根-10): the demo library is on screen. The
  /// sidebar says 「演示」 as long as it is (review v12-B #7).
  public var demo = false
  /// The tagline at the foot of the sidebar (docs/TAGLINES.md): the App
  /// picks it when the window comes on screen, never while it is shown; nil
  /// shows none.
  public var tagline: MindloomTagline?
  /// Each v11 branch's own values (Home/, Matter/, Capture/ files).
  public var homeExtras = MemoryHomeExtras()
  public var matterExtras = MemoryMatterExtras()
  public var captureExtras = MemoryCaptureExtras()
  /// "Now": the real clock in the App, a fixed moment in fixtures.
  public var now: Date
  public var calendar: Calendar
  /// Loads a thumbnail by its path relative to the asset root.
  public var thumbnail: (String) -> NSImage?

  public init(
    mode: MemoryScreenState.Mode = .local, projection: MemoryProjection? = nil,
    user: UserOrganizingSnapshot = .empty, toast: MemoryToast? = nil,
    capture: MemoryCaptureIndicator? = nil, issues: [MemoryIssue] = [],
    playingItemID: String? = nil, now: Date = Date(), calendar: Calendar = .current,
    ownerNames: [String] = [],
    thumbnail: @escaping (String) -> NSImage? = { _ in nil }
  ) {
    self.mode = mode
    self.user = user
    self.spaces = []
    self.sharing = [:]
    self.link = MemoryLinkState()
    self.waitingCaptures = []
    self.toast = toast
    self.capture = capture
    self.issues = issues
    self.playingItemID = playingItemID
    self.now = now
    self.calendar = calendar
    self.thumbnail = thumbnail
    self.ownerNames = ownerNames
    self.projection = projection
    derive()
  }

  /// The same state from a read model derived elsewhere (the App derives it
  /// off the main thread, with the user's overrides and the clock).
  public init(
    mode: MemoryScreenState.Mode, readModel: MemoryReadModel, user: UserOrganizingSnapshot = .empty,
    toast: MemoryToast? = nil, capture: MemoryCaptureIndicator? = nil, issues: [MemoryIssue] = [],
    playingItemID: String? = nil, now: Date = Date(), calendar: Calendar = .current,
    thumbnail: @escaping (String) -> NSImage? = { _ in nil }
  ) {
    self.mode = mode
    self.user = user
    self.spaces = []
    self.sharing = [:]
    self.link = MemoryLinkState()
    self.waitingCaptures = []
    self.toast = toast
    self.capture = capture
    self.issues = issues
    self.playingItemID = playingItemID
    self.now = now
    self.calendar = calendar
    self.thumbnail = thumbnail
    self.ownerNames = []
    self.projection = readModel.projection
    apply(readModel)
  }

  /// Extra spellings of the owner's name for the display guards (fixtures).
  private var ownerNames: [String]

  private mutating func derive() {
    guard let projection else {
      home = []
      people = []
      recentPeople = []
      featuredPeople = []
      unfiled = []
      digest = nil
      return
    }
    apply(
      MemoryReadModel(
        projection, user: user, now: now, calendar: calendar, ownerNames: ownerNames))
  }

  private mutating func apply(_ model: MemoryReadModel) {
    home = model.home
    people = model.people
    recentPeople = model.recentPeople
    featuredPeople = model.featuredPeople
    unfiled = model.unfiled
    digest = model.digest
  }

  /// False until the first load finished: nothing is drawn rather than an
  /// empty page a returning user does not have.
  public var isLoaded: Bool { projection != nil }

  /// No matter, nothing waiting and nobody known: the empty Home (sidebar
  /// without 置顶 / 分组 / 共享, no lens control).
  public var isEmptyLibrary: Bool {
    isLoaded && home.isEmpty && waitingCaptures.isEmpty && people.isEmpty
  }

  /// Midnight of "now".
  public var today: Date { calendar.startOfDay(for: now) }

  /// Live pinned matters, in pin order (sidebar 置顶).
  public var pinnedMatters: [MatterRef] {
    user.pins.compactMap { pin in
      digest?.matter(pin.eventID).map { MatterRef(eventID: $0.eventID, title: $0.title) }
    }
  }

  /// The user's groups with their live members only (sidebar 分组, group pages).
  public var groups: [MemoryUserGroup] {
    user.groups.map { group in
      MemoryUserGroup(
        id: group.id, name: group.name,
        eventIDs: group.eventIDs.filter { digest?.matter($0) != nil })
    }
  }

  /// The user's pins and groups as read from the library after this state
  /// was derived. The read model is rebuilt a moment later (debounced, off the
  /// main thread); until then the sidebar, the menus and the group pages
  /// already follow the latest read, so a group made a moment ago opens to its
  /// own empty page instead of 「这个分组已经删掉了」 (finish-mac).
  public mutating func overlayUser(_ latest: UserOrganizingSnapshot) {
    user = latest
  }

  public func group(_ id: String) -> MemoryUserGroup? {
    groups.first { $0.id.uuidString.lowercased() == id.lowercased() }
  }

  /// The group a matter is in, if any.
  public func group(of eventID: String) -> MemoryUserGroup? {
    groups.first { $0.eventIDs.contains(eventID) }
  }

  public func space(_ id: String) -> MemorySidebarSpace? { spaces.first { $0.id == id } }

  public func matter(_ eventID: String) -> MatterDigest? { digest?.matter(eventID) }

  public func person(_ personID: String) -> MemoryPersonEntry? {
    people.first { $0.personID.caseInsensitiveCompare(personID) == .orderedSame }
  }

  func entry(_ eventID: String) -> MemoryHomeEntry? {
    home.first { $0.eventID == eventID }
  }

  // MARK: - Text

  func span(_ span: MemoryEventSpan?) -> String {
    span.map { MemoryDateText.span($0, calendar: calendar, now: now) } ?? ""
  }

  func time(_ date: Date) -> String { MemoryDateText.time(date, calendar: calendar) }

  func dayHeader(_ date: Date) -> String {
    MemoryDateText.dayHeader(date, calendar: calendar, now: now)
  }

  func day(_ date: Date) -> String { MemoryDateText.day(date, calendar: calendar, now: now) }
}

/// A user group as the pages show it (live members only).
public struct MemoryUserGroup: Equatable, Identifiable, Hashable, Sendable {
  public let id: UUID
  public let name: String
  public let eventIDs: [String]

  public init(id: UUID, name: String, eventIDs: [String]) {
    self.id = id
    self.name = name
    self.eventIDs = eventIDs
  }

  /// The ID routes use (lower-case UUID).
  public var routeID: String { id.uuidString.lowercased() }
}

/// A sidebar 共享 row.
public struct MemorySidebarSpace: Equatable, Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  /// Other members' names (「周明澜、宋雨桐…和你」).
  public let memberNames: [String]
  public let admins: Set<String>
  /// This Mac's user is an admin (may invite and remove).
  public let youAreAdmin: Bool

  public init(
    id: String, name: String, memberNames: [String] = [], admins: Set<String> = [],
    youAreAdmin: Bool = false
  ) {
    self.id = id
    self.name = name
    self.memberNames = memberNames
    self.admins = admins
    self.youAreAdmin = youAreAdmin
  }
}

/// How one matter is shared.
public struct MemoryShareInfo: Equatable, Hashable, Sendable {
  public let spaceID: String
  public let spaceName: String
  /// nil when you shared it; else the member who did (member view).
  public let sharedBy: String?

  public init(spaceID: String, spaceName: String, sharedBy: String? = nil) {
    self.spaceID = spaceID
    self.spaceName = spaceName
    self.sharedBy = sharedBy
  }

  public var isMemberView: Bool { sharedBy != nil }
}

/// The DGX Spark link as the pages say it: 已连接 / 没连上 / 连接中.
public struct MemoryLinkState: Equatable, Sendable {
  public enum Status: Equatable, Sendable {
    /// The user never turned the link on (local organizing only): nothing
    /// is said on Home.
    case off
    case connecting
    case connected
    case notConnected
  }

  public var status: Status
  /// Captures waiting on this Mac to be organized.
  public var waiting: Int
  /// The last successful pull from the DGX Spark (「上次整理 22:40」).
  public var lastOrganizedAt: Date?

  public init(status: Status = .off, waiting: Int = 0, lastOrganizedAt: Date? = nil) {
    self.status = status
    self.waiting = waiting
    self.lastOrganizedAt = lastOrganizedAt
  }

  /// Home's offline line and the menu's 「DGX Spark 没连上」 show.
  public var showsNotConnected: Bool { status == .notConnected }
}

/// A capture that cannot be filed yet (Home's 「刚收进来」).
public struct MemoryWaitingCapture: Equatable, Identifiable, Sendable {
  public enum Thumbnail: String, Equatable, Sendable {
    case pdf
    case photo
    case video
  }

  /// The item's ID (upper-case).
  public let id: String
  /// Its first line (never a file name).
  public let firstLine: String
  /// 口述 · 微信 · 截图 · PDF · 视频 · 42 分钟 · 会议记录 · 会议录音 · 粘贴 · 文件
  public let kind: String
  public let symbol: String
  public let capturedAt: Date
  public let thumbnail: Thumbnail?
  /// Relative path of a real thumbnail image, when there is one.
  public let thumbnailPath: String?

  public init(
    id: String, firstLine: String, kind: String, symbol: String, capturedAt: Date,
    thumbnail: Thumbnail? = nil, thumbnailPath: String? = nil
  ) {
    self.id = id
    self.firstLine = firstLine
    self.kind = kind
    self.symbol = symbol
    self.capturedAt = capturedAt
    self.thumbnail = thumbnail
    self.thumbnailPath = thumbnailPath
  }
}

/// One toast (MAC-SPEC §7.6): an icon, the words, an optional grey suffix and
/// at most one action.
public struct MemoryToast: Equatable, Identifiable, Sendable {
  public enum Icon: Equatable, Sendable {
    /// The brand mark (T form) in `--mark`.
    case mark
    case symbol(String)
    /// No leading icon (「已归进「…」 · 查看」, §7.6).
    case none
  }

  public enum Action: Equatable, Sendable {
    /// 撤销: the undo slot.
    case undo
    /// 查看: open a matter (and a step's popover).
    case view(eventID: String, stepID: String?)
    /// 去设置 (a Settings pane by name).
    case settings(String)
  }

  public let id: UUID
  public let icon: Icon
  public let text: String
  /// Grey words after the text (「 · 先放在这台 Mac」).
  public let detail: String?
  public let action: Action?
  /// When the toast was shown (lifetimes in M18 are from here).
  public let shownAt: Date

  public init(
    _ text: String, icon: Icon = .mark, detail: String? = nil, action: Action? = nil,
    id: UUID = UUID(), shownAt: Date = Date()
  ) {
    self.id = id
    self.icon = icon
    self.text = text
    self.detail = detail
    self.action = action
    self.shownAt = shownAt
  }

  /// 撤销 · 查看 · 去设置.
  public var actionTitle: String? {
    switch action {
    case .undo?: "撤销"
    case .view?: "查看"
    case .settings?: "打开设置"
    case nil: nil
    }
  }

  /// Seconds before it goes (M18): 8 with 撤销, 6 with another action, 3.2 plain.
  public var lifetime: TimeInterval {
    switch action {
    case .undo?: 8
    case .some: 6
    case nil: 3.2
    }
  }
}

/// The undo slot as the menus show it.
public struct MemoryUndoState: Equatable, Sendable {
  /// 标为完成 · 重命名 · 移到分组 · 移动 · 共享 · 停止共享 · 删除 · 退出
  public let label: String
  /// Still held (not sent yet): undo drops it and nothing leaves the Mac.
  public let pending: Bool

  public init(label: String, pending: Bool) {
    self.label = label
    self.pending = pending
  }

  /// 「撤销标为完成」.
  public var menuTitle: String { "撤销" + label }
}

/// A meeting recording the user may walk away from (menu bar extra).
public struct MemoryCaptureIndicator: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case room
    case systemAudio
    case importing
  }

  public let kind: Kind
  public let title: String
  public let detail: String
  public let paused: Bool
  /// When it started, for 「12:04」 (paused spans excluded by the App).
  public let elapsed: TimeInterval

  public init(
    kind: Kind, title: String, detail: String, paused: Bool = false, elapsed: TimeInterval = 0
  ) {
    self.kind = kind
    self.title = title
    self.detail = detail
    self.paused = paused
    self.elapsed = elapsed
  }
}

/// A correction the DGX Spark did not take, as one line with its two ways
/// out.
public struct MemoryIssue: Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  /// It may already have arrived: the retry confirms it, and it cannot be
  /// discarded until then.
  public let deliveryUnknown: Bool

  public init(id: String, title: String, deliveryUnknown: Bool) {
    self.id = id
    self.title = title
    self.deliveryUnknown = deliveryUnknown
  }
}
