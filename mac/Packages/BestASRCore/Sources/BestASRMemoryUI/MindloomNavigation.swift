import Foundation

// Routing for the main window (MAC-SPEC §1.1, §5.1). The App owns one
// `MemoryNavigation` value; the shell and every page change it only through
// `MindloomNavigator` (FOUNDATION.md), so moves stay consistent (scroll
// memory, the open popover, the back label).

/// A sidebar destination: the page at the bottom of the stack.
public enum MindloomRoot: Hashable, Sendable {
  /// S1–S4: Home with its lens.
  case home
  /// 历史: every record (nothing typed) or what the search field found
  /// (`MemoryNavigation.search`); one page for both (ALIGNMENT 2b).
  case search
  /// S10: a user group (lower-case UUID).
  case group(String)
  /// S11: a shared space (space ID).
  case space(String)
}

/// A page pushed over the root.
public enum MemoryRoute: Hashable, Sendable {
  /// S6–S8: a matter page (tab, open step and revealed item are in
  /// `MemoryNavigation`).
  case matter(String)
  /// S5: a person page (person ID).
  case person(String)
  /// 历史's 「还有 N 件」: every matter the query found, on a page of its own
  /// (the query), so nothing below is pushed down (B7 设计 5, 8; review
  /// v12-B #15).
  case matterResults(String)
}

/// Home's lens (S1–S3). A group or space page offers 按时间 and 按截止 only.
public enum MemoryHomeLens: String, CaseIterable, Hashable, Sendable {
  /// 按时间 (default).
  case time
  /// 按截止.
  case deadlines
  /// 按人.
  case people

  public var title: String {
    switch self {
    case .time: "按时间"
    case .deadlines: "按截止日期"
    case .people: "按人物"
    }
  }
}

/// A matter page's tab (S6–S8).
public enum MatterTab: String, CaseIterable, Hashable, Sendable {
  /// 进展: the time view, or the small page when the matter has no parts.
  case progress
  /// 原文.
  case text

  public var title: String {
    switch self {
    case .progress: "进展"
    case .text: "原文"
    }
  }
}

/// What a 移到哪件事？ sheet moves.
public enum MoveSubject: Hashable, Sendable {
  /// A step (and the item it rests on).
  case step(eventID: String, stepID: String)
  /// One 原文 item (or one part of it).
  case item(eventID: String, itemID: String, segID: String?)

  public var eventID: String {
    switch self {
    case .step(let id, _), .item(let id, _, _): id
    }
  }
}

/// The window-modal sheets of the main window that are not spaces' own
/// (those stay `SpaceSheet`, presented by the App).
public enum MindloomSheet: Hashable, Identifiable, Sendable {
  /// 新建分组; `moving` is the matter to put in it (移到分组 › 新建分组…).
  case newGroup(moving: String?)
  /// 添加到「{group}」 (group route ID).
  case addToGroup(String)
  /// 移到哪件事？
  case move(MoveSubject)
  /// 删除「{title}」？
  case deleteMatter(String)
  /// 加进词典 from a 历史 record (its upper-case item ID).
  case addToDictionary(itemID: String)
  /// 合并到… (v12): which person is the same as this one (person ID).
  case mergePerson(String)
  /// 不是他 (v12): which sentences of a recording are not this person's.
  case notPerson(NotPersonSubject)

  public var id: String {
    switch self {
    case .newGroup(let id): "new-group-\(id ?? "")"
    case .addToGroup(let id): "add-\(id)"
    case .move(let subject): "move-\(subject)"
    case .deleteMatter(let id): "delete-\(id)"
    case .addToDictionary(let id): "dictionary-\(id)"
    case .mergePerson(let id): "merge-person-\(id)"
    case .notPerson(let subject): "not-person-\(subject.itemID)-\(subject.personID)"
    }
  }
}

/// What a 「不是他」 sheet is about: one recording (as the matter shows it),
/// one speaker in it, and the sentence it was opened from (ticked).
public struct NotPersonSubject: Hashable, Sendable {
  public let eventID: String
  public let itemID: String
  public let segID: String?
  /// The person ID the recording's sentences carry.
  public let personID: String
  public let name: String
  /// The sentence it was opened from (monotonic start), ticked at first.
  public let start: UInt64?

  public init(
    eventID: String, itemID: String, segID: String?, personID: String, name: String,
    start: UInt64?
  ) {
    self.eventID = eventID
    self.itemID = itemID.uppercased()
    self.segID = segID
    self.personID = personID
    self.name = name
    self.start = start
  }
}

/// An overlay over a matter page (S12).
public enum MatterPopover: Hashable, Sendable {
  /// The step popover (§7.1).
  case step(String)
  /// A part's 经过 popover (§7.2).
  case segment(String)
}

/// Navigation state, owned by the App so other code (menus, toasts, the menu
/// bar extra) can move it.
public struct MemoryNavigation: Equatable, Sendable {
  public var root: MindloomRoot
  public var path: [MemoryRoute]
  /// Home's lens.
  public var homeLens: MemoryHomeLens
  /// A group's or space's lens (按时间 / 按截止).
  public var listLens: MemoryHomeLens
  /// The matter page's tab; a newly opened matter starts on 进展.
  public var matterTab: MatterTab
  /// The search field's text (one persistent field in the toolbar).
  public var search: String
  /// The root to go back to when the query is cleared (Esc).
  public var searchReturn: MindloomRoot?
  /// The popover open on the matter page.
  public var popover: MatterPopover?
  /// A 原文 row to highlight and scroll to once (打开原文, a search hit).
  public var revealRow: String?
  /// 原文 rows expanded in place (「展开」).
  public var expandedItems: Set<String>
  /// Home's 「更早」 group is open.
  public var earlierOpen: Bool
  /// The matter whose title is being renamed in place.
  public var renaming: String?
  public var sheet: MindloomSheet?

  public init(
    root: MindloomRoot = .home, path: [MemoryRoute] = [], homeLens: MemoryHomeLens = .time,
    listLens: MemoryHomeLens = .time, matterTab: MatterTab = .progress, search: String = "",
    popover: MatterPopover? = nil, revealRow: String? = nil, expandedItems: Set<String> = [],
    earlierOpen: Bool = false, renaming: String? = nil, sheet: MindloomSheet? = nil
  ) {
    self.root = root
    self.path = path
    self.homeLens = homeLens
    self.listLens = listLens
    self.matterTab = matterTab
    self.search = search
    self.searchReturn = nil
    self.popover = popover
    self.revealRow = revealRow
    self.expandedItems = expandedItems
    self.earlierOpen = earlierOpen
    self.renaming = renaming
    self.sheet = sheet
  }

  /// The page on top.
  public var top: MindloomPage {
    switch path.last {
    case .matter(let id)?: .matter(id)
    case .person(let id)?: .person(id)
    case .matterResults(let query)?: .matterResults(query)
    case nil:
      switch root {
      case .home: .home
      case .search: .search
      case .group(let id): .group(id)
      case .space(let id): .space(id)
      }
    }
  }

  /// The matter open on top, if any.
  public var openMatter: String? {
    if case .matter(let id)? = path.last { return id }
    return nil
  }

  /// Where the back capsule goes (nil: no back capsule).
  public var backTarget: MindloomPage? {
    guard !path.isEmpty else { return nil }
    var below = self
    below.path.removeLast()
    return below.top
  }

  /// The scroll-memory key of the page on top (`home:<lens>`, `group:<id>`,
  /// `space:<id>`, `matter`, `people`, `search`).
  public var scrollKey: String {
    switch top {
    case .home: "home:\(homeLens.rawValue)"
    case .search: "search"
    case .group(let id): "group:\(id):\(listLens.rawValue)"
    case .space(let id): "space:\(id):\(listLens.rawValue)"
    case .matter(let id): "matter:\(id):\(matterTab.rawValue)"
    case .person(let id): "people:\(id)"
    case .matterResults(let query): "matters:\(query)"
    }
  }
}

/// Every main-window page (S1–S11), as the shell switches on it.
public enum MindloomPage: Hashable, Sendable {
  case home
  case search
  case group(String)
  case space(String)
  case matter(String)
  case person(String)
  case matterResults(String)
}
