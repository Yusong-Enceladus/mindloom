import SwiftUI

/// The only way pages move the window (MAC-SPEC §5.1). Built by the shell
/// from the App's `MemoryNavigation` binding; pages get it in their
/// `MindloomPageContext`. Every move closes the open popover and keeps the
/// rules of the prototype: a matter opens on 进展, back returns to where it
/// was opened from, the sidebar clears the query.
@MainActor
public struct MindloomNavigator {
  private let binding: Binding<MemoryNavigation>
  private let reduceMotion: Bool

  public init(_ binding: Binding<MemoryNavigation>, reduceMotion: Bool = false) {
    self.binding = binding
    self.reduceMotion = reduceMotion
  }

  /// A navigator that goes nowhere (snapshots of standalone views).
  public static var inert: MindloomNavigator { MindloomNavigator(.constant(MemoryNavigation())) }

  public var navigation: MemoryNavigation { binding.wrappedValue }

  private func change(animated: Bool = true, _ body: (inout MemoryNavigation) -> Void) {
    var next = binding.wrappedValue
    body(&next)
    if animated && !reduceMotion {
      withAnimation(.spring(response: 0.5, dampingFraction: 1)) { binding.wrappedValue = next }
    } else {
      binding.wrappedValue = next
    }
  }

  // MARK: - Pages

  /// A sidebar item: that page, the query cleared.
  public func openRoot(_ root: MindloomRoot) {
    change(animated: false) {
      $0.root = root
      $0.path = []
      $0.search = ""
      $0.searchReturn = nil
      $0.popover = nil
      $0.revealRow = nil
    }
  }

  /// A matter page (tab 进展 unless told), optionally with a step's popover
  /// open (按截止 rows, a toast's 查看) or a 原文 row revealed (打开原文, a
  /// search hit).
  public func openMatter(
    _ eventID: String, tab: MatterTab = .progress, step: String? = nil, revealRow: String? = nil
  ) {
    change {
      if $0.path.last != .matter(eventID) { $0.path.append(.matter(eventID)) }
      $0.matterTab = revealRow == nil ? tab : .text
      $0.popover = step.map(MatterPopover.step)
      $0.revealRow = revealRow
      $0.renaming = nil
    }
  }

  /// A person page; `renaming` starts with their name being typed (改名…
  /// from 按人).
  public func openPerson(_ personID: String, renaming: Bool = false) {
    change {
      if $0.path.last != .person(personID) { $0.path.append(.person(personID)) }
      $0.popover = nil
      $0.renaming = renaming ? personID : nil
    }
  }

  /// 历史's 「还有 N 件」: every matter the query found, on its own page.
  public func openMatterResults(_ query: String) {
    change {
      if $0.path.last != .matterResults(query) { $0.path.append(.matterResults(query)) }
      $0.popover = nil
      $0.renaming = nil
    }
  }

  /// After 合并到…: the person page on top becomes the person they joined
  /// (back still returns to where it was opened from).
  public func replacePerson(_ personID: String, with other: String) {
    change {
      if let index = $0.path.lastIndex(of: .person(personID)) {
        $0.path[index] = .person(other)
      }
      $0.renaming = nil
    }
  }

  /// The back capsule: one page down (scroll restored by the page).
  public func back() {
    guard !binding.wrappedValue.path.isEmpty else { return }
    change {
      $0.path.removeLast()
      $0.popover = nil
      $0.revealRow = nil
      $0.renaming = nil
    }
  }

  public func setHomeLens(_ lens: MemoryHomeLens) {
    change(animated: false) {
      $0.root = .home
      $0.path = []
      $0.homeLens = lens
    }
  }

  public func setListLens(_ lens: MemoryHomeLens) {
    change(animated: false) { $0.listLens = lens == .people ? .time : lens }
  }

  public func setTab(_ tab: MatterTab) {
    change(animated: false) {
      $0.matterTab = tab
      $0.popover = nil
    }
  }

  // MARK: - Search

  /// Typing in the toolbar field: results replace the page (remembered for
  /// Esc); an empty field goes back.
  public func setSearch(_ text: String) {
    change(animated: false) { navigation in
      navigation.search = text
      if text.isEmpty {
        if let back = navigation.searchReturn {
          navigation.root = back
          navigation.searchReturn = nil
        }
      } else if navigation.root != .search || !navigation.path.isEmpty {
        if navigation.searchReturn == nil, navigation.root != .search {
          navigation.searchReturn = navigation.root
        }
        navigation.root = .search
        navigation.path = []
      }
    }
  }

  /// Esc in the field: the query cleared, the previous page back.
  public func clearSearch() { setSearch("") }

  // MARK: - Overlays

  public func present(_ sheet: MindloomSheet?) {
    change(animated: false) { $0.sheet = sheet }
  }

  public func openPopover(_ popover: MatterPopover?) {
    change(animated: false) { $0.popover = popover }
  }

  public func reveal(_ row: String?) {
    change(animated: false) { $0.revealRow = row }
  }

  public func toggleExpanded(_ row: String) {
    change(animated: false) {
      if $0.expandedItems.contains(row) {
        $0.expandedItems.remove(row)
      } else {
        $0.expandedItems.insert(row)
      }
    }
  }

  public func setEarlierOpen(_ open: Bool) {
    change(animated: false) { $0.earlierOpen = open }
  }

  /// Inline rename of a matter's title (nil ends it).
  public func rename(_ eventID: String?) {
    change(animated: false) { $0.renaming = eventID }
  }
}

/// What every page gets from the shell.
@MainActor
public struct MindloomPageContext {
  public let state: MemoryScreenState
  public let actions: MemoryActions
  public let navigator: MindloomNavigator
  public let spaces: SpacesScreenState
  public let spacesActions: SpacesActions
  /// The state of a shared space's own library (its page reads it), when
  /// the App has built it.
  public let spaceState: (String) -> MemoryScreenState?

  public init(
    state: MemoryScreenState, actions: MemoryActions = .inert,
    navigator: MindloomNavigator = .inert, spaces: SpacesScreenState = SpacesScreenState(),
    spacesActions: SpacesActions = SpacesActions(),
    spaceState: @escaping (String) -> MemoryScreenState? = { _ in nil }
  ) {
    self.state = state
    self.actions = actions
    self.navigator = navigator
    self.spaces = spaces
    self.spacesActions = spacesActions
    self.spaceState = spaceState
  }

  public var navigation: MemoryNavigation { navigator.navigation }
}
