import MindloomDesign
import SwiftUI

/// The main window (MAC-SPEC §3.3): the inset sidebar, the page column with
/// the floating toolbar, the window's sheets, the drop overlay and the
/// toast. Pages are chosen from `MemoryNavigation.top`; each page is one
/// view in its owner's file (FOUNDATION.md) with a documented input.
///
/// The window chrome is the system's (hidden title bar, traffic lights over
/// the sidebar); everything inside is drawn here so a still image of any
/// state can be rendered with `ImageRenderer` (`\.zhijiSnapshot`).
public struct MindloomShell: View {
  @Binding private var navigation: MemoryNavigation
  private let state: MemoryScreenState
  private let actions: MemoryActions
  private let spaces: SpacesScreenState
  private let spacesActions: SpacesActions
  private let spaceState: (String) -> MemoryScreenState?
  private let dropTargeted: Bool
  @StateObject private var scrollMemory = MindloomScrollMemory()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// - Parameters:
  ///   - spaceState: a shared space's own library state, for its page.
  ///   - dropTargeted: files are being dragged over the window (S22).
  public init(
    navigation: Binding<MemoryNavigation>, state: MemoryScreenState, actions: MemoryActions,
    spaces: SpacesScreenState = SpacesScreenState(), spacesActions: SpacesActions = SpacesActions(),
    spaceState: @escaping (String) -> MemoryScreenState? = { _ in nil }, dropTargeted: Bool = false
  ) {
    _navigation = navigation
    self.state = state
    self.actions = actions
    self.spaces = spaces
    self.spacesActions = spacesActions
    self.spaceState = spaceState
    self.dropTargeted = dropTargeted
  }

  private var context: MindloomPageContext {
    MindloomPageContext(
      state: state, actions: actions,
      navigator: MindloomNavigator($navigation, reduceMotion: reduceMotion), spaces: spaces,
      spacesActions: spacesActions, spaceState: spaceState)
  }

  public var body: some View {
    let context = context
    HStack(spacing: 0) {
      MindloomSidebar(context: context)
      ZStack(alignment: .top) {
        Rectangle().fill(MLColor.paper)
        if state.isLoaded {
          MindloomPageHost(context: context)
        }
        MindloomToolbar(context: context)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(MLColor.paper)
    .overlay { if dropTargeted { DropOverlay(input: DropOverlayInput(targeted: true)) } }
    .overlay(alignment: .bottom) { MindloomToastHost(context: context) }
    .overlay(alignment: .topLeading) { TrafficLights() }
    .sheet(item: $navigation.sheet) { sheet in
      MindloomSheetHost(context: context, sheet: sheet)
    }
    .environment(\.mindloomScrollMemory, scrollMemory)
    .environment(\.mlPlatform, .mac)
    .foregroundStyle(MLColor.ink)
    .tint(MLColor.accent)
  }
}

/// The page on top of the navigation stack.
struct MindloomPageHost: View {
  let context: MindloomPageContext

  var body: some View {
    let navigation = context.navigation
    Group {
      switch navigation.top {
      case .home:
        HomePage(context: context, input: HomePageInput(lens: navigation.homeLens))
      case .search:
        HistoryPage(
          context: context,
          input: HistoryPageInput(query: navigation.search, revealRow: navigation.revealRow))
      case .group(let id):
        GroupPage(context: context, input: GroupPageInput(groupID: id, lens: navigation.listLens))
      case .space(let id):
        SpacePage(
          context: context,
          input: SpacePageInput(
            spaceID: id, lens: navigation.listLens, spaceState: context.spaceState(id)))
      case .person(let id):
        PersonPage(context: context, input: PersonPageInput(personID: id))
      case .matterResults(let query):
        HistoryMatterResultsPage(context: context, query: query)
      case .matter(let id):
        MatterPage(
          context: context,
          input: MatterPageInput(
            eventID: id, tab: navigation.matterTab, popover: navigation.popover,
            revealRow: navigation.revealRow, renaming: navigation.renaming == id,
            memberView: context.state.sharing[id]?.isMemberView ?? false))
      }
    }
    .id(navigation.scrollKey)
    .transition(.opacity)
  }
}

/// The window's own sheets (spaces' sheets are the App's `SpaceSheetHost`).
struct MindloomSheetHost: View {
  let context: MindloomPageContext
  let sheet: MindloomSheet

  var body: some View {
    switch sheet {
    case .newGroup(let moving):
      NewGroupSheet(context: context, input: NewGroupSheetInput(moving: moving))
    case .addToGroup(let id):
      AddToGroupSheet(context: context, input: AddToGroupSheetInput(groupID: id))
    case .move(let subject):
      MoveSheet(context: context, input: MoveSheetInput(subject: subject))
    case .deleteMatter(let id):
      DeleteMatterSheet(context: context, input: DeleteMatterSheetInput(eventID: id))
    case .addToDictionary(let id):
      AddToDictionarySheet(context: context, input: AddToDictionarySheetInput(itemID: id))
    case .mergePerson(let id):
      MergePersonSheet(context: context, input: MergePersonSheetInput(personID: id))
    case .notPerson(let subject):
      NotPersonSheet(context: context, input: NotPersonSheetInput(subject: subject))
    }
  }
}

/// One toast at a time, bottom centre, 28 pt above the window's bottom
/// (§7.6). Lifetimes (M18): 8 s with 撤销, 6 s with another action, 3.2 s
/// plain; the pointer over it pauses it.
struct MindloomToastHost: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.zhijiSnapshot) private var snapshot
  let context: MindloomPageContext
  @State private var hovering = false

  var body: some View {
    ZStack {
      if let toast = context.state.toast {
        MLToast(
          toast.text, detail: toast.detail, leading: leading(toast), actionTitle: toast.actionTitle,
          action: toast.action.map { action in { run(action, toast: toast) } }
        )
        .fixedSize()
        .onHover { inside in
          hovering = inside
          context.actions.holdToast(toast.id, inside)
        }
        .task(id: toast.id) {
          guard !snapshot else { return }
          try? await Task.sleep(for: .seconds(toast.lifetime))
          while hovering { try? await Task.sleep(for: .seconds(2.4)) }
          guard !Task.isCancelled else { return }
          context.actions.dismissToast(toast.id)
        }
        .transition(
          reduceMotion
            ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .accessibilityAddTraits(.updatesFrequently)
      }
    }
    .padding(.bottom, 28)
    .animation(MLSpring.smooth.animation, value: context.state.toast?.id)
  }

  private func leading(_ toast: MemoryToast) -> MLToast.Leading {
    switch toast.icon {
    case .mark: .mark
    case .symbol(let name): .symbol(name)
    case .none: .none
    }
  }

  private func run(_ action: MemoryToast.Action, toast: MemoryToast) {
    switch action {
    case .undo:
      context.actions.undo()
    case .view(let eventID, let stepID):
      context.navigator.openMatter(eventID, step: stepID)
    case .settings(let pane):
      context.actions.openSettings(pane)
    }
    context.actions.dismissToast(toast.id)
  }
}

/// The window's traffic lights in a still image (the real window draws its
/// own): 12 pt circles at (20, 18).
private struct TrafficLights: View {
  @Environment(\.zhijiSnapshot) private var snapshot

  var body: some View {
    if snapshot {
      HStack(spacing: 8) {
        ForEach([MLColor.systemRed, .systemYellow, .systemGreen], id: \.self) { color in
          Circle().fill(color).frame(width: 12, height: 12)
        }
      }
      .padding(.leading, 20)
      .padding(.top, 18)
      .allowsHitTesting(false)
    }
  }
}
