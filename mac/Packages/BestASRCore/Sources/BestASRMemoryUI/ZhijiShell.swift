import SwiftUI

/// Pages the App supplies from its existing views: the chronological list
/// (全部), the dictionary, the capture in progress, and setup cards shown
/// above Home while first-run setup is incomplete.
public struct MemoryShellSlots {
  public var allItems: () -> AnyView
  public var dictionary: () -> AnyView
  public var capture: () -> AnyView
  public var homeAccessory: () -> AnyView?
  /// A bar under a matter page (shared spaces: the badge, 共享这件事…, the
  /// items' rights), by event ID; nil for none.
  public var eventAccessory: (String) -> AnyView?

  public init(
    allItems: @escaping () -> AnyView = { AnyView(EmptyView()) },
    dictionary: @escaping () -> AnyView = { AnyView(EmptyView()) },
    capture: @escaping () -> AnyView = { AnyView(EmptyView()) },
    homeAccessory: @escaping () -> AnyView? = { nil },
    eventAccessory: @escaping (String) -> AnyView? = { _ in nil }
  ) {
    self.allItems = allItems
    self.dictionary = dictionary
    self.capture = capture
    self.homeAccessory = homeAccessory
    self.eventAccessory = eventAccessory
  }
}

/// The main window: a 212 pt sidebar and one detail column that pushes
/// Event, Person, Unfiled and capture pages over Home. Only the card-to-event
/// morph animates: a 0.35 s spring in which Home fades, the Event page grows
/// in from the card's place and the title slides into the header. Under
/// Reduce Motion nothing slides or grows; the two pages only cross-fade.
public struct ZhijiShell: View {
  @Binding private var navigation: MemoryNavigation
  private let state: MemoryScreenState
  private let actions: MemoryActions
  private let slots: MemoryShellSlots

  public init(
    navigation: Binding<MemoryNavigation>, state: MemoryScreenState, actions: MemoryActions,
    slots: MemoryShellSlots = MemoryShellSlots()
  ) {
    _navigation = navigation
    self.state = state
    self.actions = actions
    self.slots = slots
  }

  public var body: some View {
    ZhijiThemed {
      ShellBody(navigation: $navigation, state: state, actions: actions, slots: slots)
    }
  }
}

private struct ShellBody: View {
  @Environment(\.zhiji) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var navigation: MemoryNavigation
  let state: MemoryScreenState
  let actions: MemoryActions
  let slots: MemoryShellSlots
  @Namespace private var morph

  var body: some View {
    HStack(spacing: 0) {
      Sidebar(navigation: $navigation, capture: state.capture) {
        navigation.tab = .home
        push(.capture, animated: false)
      }
      ZStack {
        palette.bg
        detail
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .bottom) {
        if let toast = state.toast {
          ToastView(toast: toast, changeSource: actions.changeSource)
            .padding(.bottom, 24)
        }
      }
    }
    .background(palette.bg)
    .foregroundStyle(palette.label)
  }

  @ViewBuilder
  private var detail: some View {
    switch navigation.path.last {
    case .event(let id)?:
      EventPage(
        eventID: id, state: state, actions: actions, morph: morph, back: back, open: open,
        expanded: $navigation.expandedItems, lens: $navigation.eventLens,
        focusedKnot: $navigation.focusedKnot, revealRow: $navigation.revealRow,
        showRopes: {
          navigation.homeLens = .ropes
          navigation.tab = .home
          navigation.path = []
        }
      )
      .safeAreaInset(edge: .bottom, spacing: 0) { slots.eventAccessory(id) }
      .transition(eventTransition)
    case .person(let id)?:
      PersonPage(
        personID: id, state: state, actions: actions, back: back, open: open,
        openAt: { eventID, rows in
          navigation.expandedItems.formUnion(rows)
          open(.event(eventID))
        })
    case .unfiled?:
      UnfiledPage(
        state: state, actions: actions, back: back, expanded: $navigation.expandedItems)
    case .capture?:
      VStack(spacing: 0) {
        BackBar(title: ZhijiCopy.back, action: back)
        slots.capture()
      }
    case nil:
      switch navigation.tab {
      case .home:
        HomePage(
          navigation: $navigation, state: state, actions: actions, morph: morph,
          accessory: slots.homeAccessory(), allItems: slots.allItems, open: open
        )
        .transition(.opacity)
      case .people:
        PeopleIndexPage(state: state, actions: actions, open: open)
      case .dictionary:
        slots.dictionary()
      }
    }
  }

  private var eventTransition: AnyTransition {
    reduceMotion
      ? .opacity
      : .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
        removal: .opacity)
  }

  private func open(_ route: MemoryRoute) {
    // Another matter starts with no knot picked.
    if case .event = route { navigation.focusedKnot = nil }
    push(route, animated: { if case .event = route { true } else { false } }())
  }

  private func push(_ route: MemoryRoute, animated: Bool) {
    if animated {
      withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35)) {
        navigation.path.append(route)
      }
    } else {
      navigation.path.append(route)
    }
  }

  private func back() {
    guard let last = navigation.path.last else { return }
    if case .event = last {
      withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35)) {
        _ = navigation.path.popLast()
      }
    } else {
      _ = navigation.path.popLast()
    }
  }
}

/// "‹ 首页" in a page header.
struct BackBar<Trailing: View>: View {
  @Environment(\.zhiji) private var palette
  let title: String
  let action: () -> Void
  let trailing: Trailing

  init(title: String, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
    self.title = title
    self.action = action
    self.trailing = trailing()
  }

  var body: some View {
    HStack {
      Button(action: action) {
        HStack(spacing: 4) {
          Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
          Text(title).font(.zhiji(13))
        }
        .foregroundStyle(palette.label)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .keyboardShortcut("[", modifiers: .command)
      .accessibilityIdentifier("bestASR.memory.back")
      Spacer()
      trailing
    }
    .pageHeader(palette, horizontalPadding: 24)
  }
}

extension BackBar where Trailing == EmptyView {
  init(title: String, action: @escaping () -> Void) {
    self.init(title: title, action: action) { EmptyView() }
  }
}
