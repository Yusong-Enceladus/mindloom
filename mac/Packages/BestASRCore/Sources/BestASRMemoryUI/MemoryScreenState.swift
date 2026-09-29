import AppKit
import BestASRDomain
import BestASRMemory
import Foundation

/// Everything the memory pages show, as values. The App builds it from its
/// models (or a test builds it from a synthetic fixture); the views never
/// read storage, the link, or a model SDK.
public struct MemoryScreenState {
  public enum Mode: Equatable, Sendable {
    /// Organized by the user's own organizing device.
    case spark
    /// Organized on this Mac (the link is off or has nothing yet). Looks the
    /// same; pinning and "feature less" are hidden because local events have
    /// no fields for them.
    case local
  }

  public var mode: Mode
  /// The read model; nil until the first load.
  public var projection: MemoryProjection? { didSet { derive() } }
  /// Derived once per projection, in Home order.
  public private(set) var home: [MemoryHomeEntry] = []
  /// Everyone seen in an event, most recently seen first (the 人物 page).
  public private(set) var recentPeople: [MemoryPersonEntry] = []
  /// The Home people row: the people who matter, in the most matters first.
  public private(set) var featuredPeople: [MemoryPersonEntry] = []
  public private(set) var people: [MemoryPersonEntry] = []
  public private(set) var unfiled: [MemoryUnfiledItem] = []
  public private(set) var bannerQuestion: MemoryQuestion?
  /// Open questions (Home's 「N 个问题等你确认」).
  public private(set) var questionCount = 0
  /// Home's 「最近在动的事」, for each span.
  public private(set) var looms: [MemoryLoom.Span: MemoryLoom] = [:]
  /// Review rows for the Person page, keyed by upper-case person ID.
  public var personReviews: [String: [MemoryPersonReview]]
  public var toast: MemoryToast?
  public var capture: MemoryCaptureIndicator?
  /// Corrections the organizing device did not take (Home lists them with
  /// 重试 / 放弃); the local overlay still shows them applied.
  public var issues: [MemoryIssue]
  /// The item whose audio is playing, if any.
  public var playingItemID: String?
  public var now: Date
  public var calendar: Calendar
  /// Loads a thumbnail by its path relative to the asset root.
  public var thumbnail: (String) -> NSImage?

  public init(
    mode: MemoryScreenState.Mode = .local, projection: MemoryProjection? = nil,
    personReviews: [String: [MemoryPersonReview]] = [:], toast: MemoryToast? = nil,
    capture: MemoryCaptureIndicator? = nil, issues: [MemoryIssue] = [],
    playingItemID: String? = nil,
    now: Date = Date(), calendar: Calendar = .current,
    thumbnail: @escaping (String) -> NSImage? = { _ in nil }
  ) {
    self.mode = mode
    self.projection = projection
    self.personReviews = personReviews
    self.toast = toast
    self.capture = capture
    self.issues = issues
    self.playingItemID = playingItemID
    self.now = now
    self.calendar = calendar
    self.thumbnail = thumbnail
    derive()
  }

  /// The same state from a read model derived elsewhere (the App derives it
  /// off the main thread); nothing is derived again here.
  public init(
    mode: MemoryScreenState.Mode, readModel: MemoryReadModel,
    personReviews: [String: [MemoryPersonReview]] = [:], toast: MemoryToast? = nil,
    capture: MemoryCaptureIndicator? = nil, issues: [MemoryIssue] = [],
    playingItemID: String? = nil,
    now: Date = Date(), calendar: Calendar = .current,
    thumbnail: @escaping (String) -> NSImage? = { _ in nil }
  ) {
    self.mode = mode
    self.projection = readModel.projection
    self.personReviews = personReviews
    self.toast = toast
    self.capture = capture
    self.issues = issues
    self.playingItemID = playingItemID
    self.now = now
    self.calendar = calendar
    self.thumbnail = thumbnail
    apply(readModel)
  }

  private mutating func derive() {
    guard let projection else {
      home = []
      people = []
      recentPeople = []
      featuredPeople = []
      unfiled = []
      bannerQuestion = nil
      questionCount = 0
      looms = [:]
      return
    }
    apply(MemoryReadModel(projection, calendar: calendar))
  }

  private mutating func apply(_ model: MemoryReadModel) {
    home = model.home
    people = model.people
    recentPeople = model.recentPeople
    featuredPeople = model.featuredPeople
    unfiled = model.unfiled
    bannerQuestion = model.bannerQuestion
    questionCount = model.questionCount
    looms = model.looms
  }

  public var canPin: Bool { mode == .spark }

  /// False until the first load finished: nothing is drawn rather than the
  /// first-run page a returning user does not have.
  public var isLoaded: Bool { projection != nil }

  func person(_ personID: String) -> MemoryPersonEntry? {
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

/// The confirmation after something was taken in.
public struct MemoryToast: Equatable, Sendable {
  public let message: String
  /// Set when the confirmation is about one item whose source can be changed.
  public let itemID: String?
  public let sourceName: String?

  public init(message: String, itemID: String? = nil, sourceName: String? = nil) {
    self.message = message
    self.itemID = itemID
    self.sourceName = sourceName
  }
}

/// "正在记录 · 腾讯会议 · 12:04": a long capture the user may walk away from.
/// Dictation is not shown (it lasts seconds and is aimed at another App).
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

  public init(kind: Kind, title: String, detail: String, paused: Bool = false) {
    self.kind = kind
    self.title = title
    self.detail = detail
    self.paused = paused
  }
}

/// One yes/no row on a Person page ("这段声音是王姐吗？").
public struct MemoryPersonReview: Equatable, Identifiable, Sendable {
  public enum Origin: Equatable, Sendable {
    /// A same-person question from the organizing device.
    case question(MemoryQuestion)
    /// A voice match waiting for confirmation on this Mac (its speaker ID).
    case voiceMatch(String)
  }

  public let id: String
  public let prompt: String
  public let meta: String
  /// The recording to play for a voice match.
  public let itemID: String?
  public let origin: Origin
  /// The candidate's own stretch of that recording (monotonic nanoseconds),
  /// so 播放 plays their voice rather than the start of the recording.
  public let startNanoseconds: UInt64?
  public let endNanoseconds: UInt64?

  public init(
    id: String, prompt: String, meta: String, itemID: String?, origin: Origin,
    startNanoseconds: UInt64? = nil, endNanoseconds: UInt64? = nil
  ) {
    self.id = id
    self.prompt = prompt
    self.meta = meta
    self.itemID = itemID
    self.origin = origin
    self.startNanoseconds = startNanoseconds
    self.endNanoseconds = endNanoseconds
  }
}

/// A correction the organizing device did not take, as one line with its
/// two ways out.
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

/// Where the detail column is.
public enum MemoryRoute: Hashable, Sendable {
  case event(String)
  case person(String)
  case unfiled
  case capture
}

public enum MemoryTab: Hashable, Sendable {
  case home
  case people
  case dictionary
}

public enum MemoryHomeMode: Hashable, Sendable {
  /// Events (事件).
  case events
  /// The plain chronological list (全部).
  case all
}

/// Navigation state, owned by the App so other code can move it.
public struct MemoryNavigation: Equatable, Sendable {
  public var tab: MemoryTab
  public var homeMode: MemoryHomeMode
  public var path: [MemoryRoute]
  public var search: String
  /// Items expanded in place on the Event and Unfiled pages.
  public var expandedItems: Set<String>

  public init(
    tab: MemoryTab = .home, homeMode: MemoryHomeMode = .events, path: [MemoryRoute] = [],
    search: String = "", expandedItems: Set<String> = []
  ) {
    self.tab = tab
    self.homeMode = homeMode
    self.path = path
    self.search = search
    self.expandedItems = expandedItems
  }
}
