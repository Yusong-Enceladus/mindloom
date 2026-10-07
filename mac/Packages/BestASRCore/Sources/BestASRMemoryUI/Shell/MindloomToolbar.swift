import MindloomDesign
import SwiftUI

/// The toolbar floating over the page (MAC-SPEC §3.5): 52 high, padding
/// 0 16 0 20. Left: the back capsule. Middle (centred in the column, top
/// 10): the lens or tab control. Right: the page's buttons, then the search
/// field (one persistent field; typing is never interrupted, IME included).
struct MindloomToolbar: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let context: MindloomPageContext

  private var state: MemoryScreenState { context.state }
  private var navigation: MemoryNavigation { context.navigation }

  var body: some View {
    ZStack(alignment: .top) {
      HStack(spacing: 10) {
        if let target = navigation.backTarget {
          backCapsule(target)
        }
        Spacer(minLength: 0)
        trailingButtons
        MindloomSearchField(
          text: navigation.search, set: context.navigator.setSearch,
          clear: context.navigator.clearSearch)
      }
      .padding(.leading, 20)
      .padding(.trailing, 16)
      .frame(height: 52)
      middle
        .padding(.top, 10)
    }
    .frame(height: 52, alignment: .top)
  }

  // MARK: - Middle

  @ViewBuilder
  private var middle: some View {
    switch navigation.top {
    case .home:
      if !state.isEmptyLibrary {
        MLLensControl(
          MemoryHomeLens.allCases.map { ($0, $0.title) },
          selection: Binding(
            get: { navigation.homeLens }, set: { context.navigator.setHomeLens($0) }),
          onGlass: true)
      }
    case .group(let id):
      if !(state.group(id)?.eventIDs.isEmpty ?? true) { listLens }
    case .space:
      listLens
    case .matter:
      MLLensControl(
        MatterTab.allCases.map { ($0, $0.title) },
        selection: Binding(get: { navigation.matterTab }, set: { context.navigator.setTab($0) }),
        onGlass: true)
    case .search, .person, .matterResults:
      EmptyView()
    }
  }

  private var listLens: some View {
    MLLensControl(
      [MemoryHomeLens.time, .deadlines].map { ($0, $0.title) },
      selection: Binding(
        get: { navigation.listLens == .people ? .time : navigation.listLens },
        set: { context.navigator.setListLens($0) }),
      onGlass: true)
  }

  // MARK: - Left

  private func backCapsule(_ target: MindloomPage) -> some View {
    Button(action: context.navigator.back) {
      HStack(spacing: 6) {
        Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
        Text(backLabel(target)).mlFont(\.control)
      }
      .foregroundStyle(MLColor.ink)
      .padding(.leading, 8)
      .padding(.trailing, 12)
      .frame(height: 32)
      .contentShape(Capsule())
      .mlGlass(.regular)
    }
    .buttonStyle(.plain)
    .keyboardShortcut("[", modifiers: .command)
    .help("返回")
    .accessibilityLabel("返回 " + backLabel(target))
  }

  /// The group's or space's name, 「人」, 「历史」, else 「首页」.
  private func backLabel(_ target: MindloomPage) -> String {
    switch target {
    case .group(let id): state.group(id)?.name ?? "首页"
    case .space(let id): state.space(id)?.name ?? "首页"
    case .person: "人物"
    case .search: "历史"
    case .matterResults: "事"
    case .home, .matter: "首页"
    }
  }

  // MARK: - Right

  @ViewBuilder
  private var trailingButtons: some View {
    switch navigation.top {
    case .matter(let id):
      let memberView = state.sharing[id]?.isMemberView ?? false
      if !memberView {
        roundButton("square.and.arrow.up", label: "共享") {
          context.spacesActions.present(.share(eventID: id))
        }
      }
      moreMenu {
        MatterMenu(context: context, input: MatterMenuInput(eventID: id, memberView: memberView))
      }
    case .space(let id):
      Button {
        context.spacesActions.present(.members(spaceID: id))
      } label: {
        HStack(spacing: 6) {
          MLSymbol("person.2", size: 14, box: 16)
          Text("成员").mlFont(\.control)
        }
        .foregroundStyle(MLColor.ink)
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 32)
        .contentShape(Capsule())
        .mlGlass(.regular)
      }
      .buttonStyle(.plain)
      moreMenu { SpaceMoreMenu(context: context, spaceID: id) }
    case .person(let id):
      if let person = state.person(id) {
        moreMenu { PersonMenuItems(context: context, person: person) }
      }
    default:
      EmptyView()
    }
  }

  private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 15))
        .foregroundStyle(MLColor.ink)
        .frame(width: 32, height: 32)
        .contentShape(Circle())
        .mlGlass(.regular, in: Circle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
  }

  @ViewBuilder
  private func moreMenu<Items: View>(@ViewBuilder _ items: () -> Items) -> some View {
    let face = Image(systemName: "ellipsis")
      .font(.system(size: 15))
      .foregroundStyle(MLColor.ink)
      .frame(width: 32, height: 32)
      .contentShape(Circle())
      .mlGlass(.regular, in: Circle())
    if snapshot {
      face
    } else {
      Menu { items() } label: { face }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
        .accessibilityLabel("更多")
    }
  }
}

/// The toolbar's search field (§3.5): a glass capsule 196 × 32, the
/// magnifying glass, placeholder 「搜索」, a clear button when not empty. Esc
/// clears the query and returns to the page it replaced; ⌘F focuses it.
struct MindloomSearchField: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let text: String
  let set: (String) -> Void
  let clear: () -> Void
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 13))
        .foregroundStyle(MLColor.ink3)
      if snapshot {
        Text(text.isEmpty ? "搜索" : text)
          .mlFont(\.control)
          .foregroundStyle(text.isEmpty ? MLColor.ink3 : MLColor.ink)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        TextField("搜索", text: Binding(get: { text }, set: set))
          .textFieldStyle(.plain)
          .mlFont(\.control)
          .foregroundStyle(MLColor.ink)
          .focused($focused)
          .onExitCommand(perform: clear)
      }
      if !text.isEmpty {
        Button(action: clear) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 13))
            .foregroundStyle(MLColor.ink3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("清除")
      }
    }
    .padding(.horizontal, 10)
    .frame(width: 196, height: 32)
    .mlGlass(.regular)
    .onReceive(NotificationCenter.default.publisher(for: .mindloomFocusSearch)) { _ in
      focused = true
    }
  }
}

extension Notification.Name {
  /// ⌘F / 编辑 › 查找 (the App's menu posts it): the search field takes focus.
  public static let mindloomFocusSearch = Notification.Name("mindloom.focusSearch")
}
