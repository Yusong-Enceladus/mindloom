import BestASRMemory
import SwiftUI

/// A two- or three-way switch drawn like the design (a white knob on a quiet
/// track), not an AppKit segmented control.
struct ZhijiSegmented<Value: Hashable>: View {
  @Environment(\.zhiji) private var palette
  let options: [(Value, String)]
  @Binding var selection: Value
  var height: CGFloat = 26
  var fontSize: CGFloat = 13
  var horizontalPadding: CGFloat = 16

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(options.enumerated()), id: \.offset) { _, option in
        let selected = option.0 == selection
        Button {
          selection = option.0
        } label: {
          Text(option.1)
            .font(.zhiji(fontSize, selected ? .semibold : .regular))
            .foregroundStyle(palette.label)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background {
              if selected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .fill(palette.knob)
                  .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
              }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(2)
    .background(palette.quietFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

/// The header search field (240×30 on a quiet fill).
struct ZhijiSearchField: View {
  @Environment(\.zhiji) private var palette
  @Environment(\.zhijiSnapshot) private var snapshot
  @Binding var text: String
  let prompt: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(palette.secondary)
      ZStack(alignment: .leading) {
        if text.isEmpty {
          Text(prompt).font(.zhiji(13)).foregroundStyle(palette.secondary)
            .allowsHitTesting(false)
        }
        if snapshot {
          Text(text).font(.zhiji(13)).foregroundStyle(palette.label)
        } else {
          TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.zhiji(13))
            .foregroundStyle(palette.label)
            .accessibilityLabel(prompt)
        }
      }
      if !text.isEmpty, !snapshot {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(palette.tertiary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 10)
    .frame(width: 240, height: 30)
    .background(palette.quietFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

/// A capsule answer button: 是 in the accent, 不是 quiet.
struct CapsuleButton: View {
  enum Style {
    case accent
    case quiet
  }

  @Environment(\.zhiji) private var palette
  let title: String
  var style: Style = .quiet
  var height: CGFloat = 28
  var fontSize: CGFloat = 13
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.zhiji(fontSize, style == .accent ? .semibold : .regular))
        .foregroundStyle(style == .accent ? palette.onAccent : palette.label)
        .padding(.horizontal, height >= 28 ? 16 : 14)
        .frame(height: height)
        .background(
          style == .accent ? palette.accent : palette.selectionFill, in: Capsule()
        )
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }
}

/// Is / is not, side by side.
struct YesNoButtons: View {
  var height: CGFloat = 28
  var fontSize: CGFloat = 13
  let answer: (Bool) -> Void

  var body: some View {
    HStack(spacing: 8) {
      CapsuleButton(title: ZhijiCopy.yes, style: .accent, height: height, fontSize: fontSize) {
        answer(true)
      }
      CapsuleButton(title: ZhijiCopy.no, height: height, fontSize: fontSize) { answer(false) }
    }
  }
}

/// A scroll view, or while rendering a still image, the content clipped to
/// the top (AppKit scroll views do not draw into `ImageRenderer`).
struct ZhijiScroll<Content: View>: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    if snapshot {
      // Take exactly the space offered and show the top of the content.
      content
        .fixedSize(horizontal: false, vertical: true)
        .frame(
          minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top
        )
        .clipped()
    } else {
      ScrollView { content }
    }
  }
}

/// Text that becomes a field when clicked and saves on Return; Escape or an
/// empty value keeps the old text.
struct InPlaceText: View {
  @Environment(\.zhiji) private var palette
  @Environment(\.zhijiSnapshot) private var snapshot
  let text: String
  let font: Font
  var placeholder = ""
  let commit: (String) -> Void
  @State private var editing = false
  @State private var draft = ""
  @FocusState private var focused: Bool

  var body: some View {
    if editing, !snapshot {
      TextField(placeholder, text: $draft)
        .textFieldStyle(.plain)
        .font(font)
        .foregroundStyle(palette.label)
        .focused($focused)
        .onSubmit(save)
        .onExitCommand { editing = false }
        .onAppear { focused = true }
        .onChange(of: focused) { _, isFocused in
          if !isFocused { save() }
        }
    } else {
      // A real button: Tab / Return reach it, and VoiceOver offers 改名.
      Button(action: begin) {
        Text(text.isEmpty ? placeholder : text)
          .font(font)
          .foregroundStyle(text.isEmpty ? palette.secondary : palette.label)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(ZhijiCopy.rename)
      .accessibilityHint(ZhijiCopy.rename)
      .accessibilityAction(named: ZhijiCopy.rename, begin)
    }
  }

  private func begin() {
    draft = text
    editing = true
  }

  private func save() {
    guard editing else { return }
    editing = false
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, trimmed != text { commit(trimmed) }
  }
}

/// A small popover asking for one name or label.
struct NamePopover: View {
  @Environment(\.zhiji) private var palette
  let prompt: String
  let initial: String
  let save: (String) -> Void
  let cancel: () -> Void
  @State private var draft = ""
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField(prompt, text: $draft)
        .textFieldStyle(.roundedBorder)
        .frame(width: 200)
        .focused($focused)
        .onSubmit(commit)
      HStack {
        Spacer()
        Button(ZhijiCopy.cancel, action: cancel)
        Button(ZhijiCopy.save, action: commit)
          .keyboardShortcut(.defaultAction)
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(14)
    .onAppear {
      draft = initial
      focused = true
    }
  }

  private func commit() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    save(trimmed)
  }
}

extension View {
  /// The page header bar: 56 tall with a hairline under it.
  func pageHeader(_ palette: ZhijiPalette, horizontalPadding: CGFloat) -> some View {
    padding(.horizontal, horizontalPadding)
      .frame(height: ZhijiMetrics.headerHeight)
      .frame(maxWidth: .infinity)
      .overlay(alignment: .bottom) { Rectangle().fill(palette.hairline).frame(height: 1) }
  }
}

/// Buttons in the setup cards above Home: a capsule in the accent (the one
/// step to take) or quiet.
public struct ZhijiCapsuleButtonStyle: ButtonStyle {
  var prominent: Bool

  public init(prominent: Bool = false) {
    self.prominent = prominent
  }

  public func makeBody(configuration: Configuration) -> some View {
    CapsuleLabel(configuration: configuration, prominent: prominent)
  }

  private struct CapsuleLabel: View {
    @Environment(\.zhiji) private var palette
    @Environment(\.isEnabled) private var enabled
    let configuration: ButtonStyleConfiguration
    let prominent: Bool

    var body: some View {
      configuration.label
        .font(.zhiji(13, prominent ? .semibold : .regular))
        .foregroundStyle(prominent ? palette.onAccent : palette.label)
        .padding(.horizontal, 14)
        .frame(minHeight: 28)
        .background(prominent ? palette.accent : palette.selectionFill, in: Capsule())
        .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
        .contentShape(Capsule())
    }
  }
}

/// A first-run setup step as a quiet surface card: "首次使用" and the step
/// dots, a 15 pt title, a 13 pt line, then the step's own controls.
public struct ZhijiSetupCard<Content: View>: View {
  @Environment(\.zhiji) private var palette
  let step: Int?
  let total: Int
  let stepTitle: String
  let title: String
  let detail: String?
  let content: Content

  public init(
    step: Int?, total: Int = 3, stepTitle: String = "", title: String, detail: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.step = step
    self.total = total
    self.stepTitle = stepTitle
    self.title = title
    self.detail = detail
    self.content = content()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let step {
        ZhijiSetupStepHeader(step: step, total: total, title: stepTitle)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.zhiji(ZhijiMetrics.statusLine, .semibold))
          .foregroundStyle(palette.label)
        if let detail, !detail.isEmpty {
          Text(detail)
            .font(.zhiji(ZhijiMetrics.body))
            .foregroundStyle(palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      content
        .font(.zhiji(ZhijiMetrics.body))
        .buttonStyle(ZhijiCapsuleButtonStyle())
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      palette.surface,
      in: RoundedRectangle(cornerRadius: ZhijiMetrics.cardRadius, style: .continuous))
  }
}

/// "首次使用 ●●○ 第 2 步，共 3 步 · 准备离线能力".
public struct ZhijiSetupStepHeader: View {
  @Environment(\.zhiji) private var palette
  let step: Int
  let total: Int
  let title: String

  public init(step: Int, total: Int = 3, title: String) {
    self.step = step
    self.total = total
    self.title = title
  }

  public var body: some View {
    HStack(spacing: 10) {
      Text(ZhijiCopy.setupFirstUse)
        .font(.zhiji(ZhijiMetrics.meta, .semibold))
        .foregroundStyle(palette.secondary)
      HStack(spacing: 5) {
        ForEach(1...max(total, 1), id: \.self) { index in
          Capsule()
            .fill(index <= step ? palette.accent : palette.separator)
            .frame(width: index == step ? 28 : 12, height: 5)
        }
      }
      Spacer()
      Text(ZhijiCopy.setupStep(step, of: total, title))
        .metaStyle(palette)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(ZhijiCopy.setupStep(step, of: total, title))
  }
}

/// One permission or readiness line inside a setup card: glyph, name, state,
/// and the action while one is needed.
public struct ZhijiSetupRow: View {
  @Environment(\.zhiji) private var palette
  let symbol: String
  let title: String
  let state: String
  let done: Bool
  let actionTitle: String?
  let actionIdentifier: String?
  let action: () -> Void

  public init(
    symbol: String, title: String, state: String, done: Bool, actionTitle: String?,
    actionIdentifier: String? = nil, action: @escaping () -> Void = {}
  ) {
    self.symbol = symbol
    self.title = title
    self.state = state
    self.done = done
    self.actionTitle = actionTitle
    self.actionIdentifier = actionIdentifier
    self.action = action
  }

  public var body: some View {
    HStack(spacing: 12) {
      Image(systemName: done ? "checkmark.circle.fill" : symbol)
        .font(.system(size: 13))
        .foregroundStyle(done ? palette.accent : palette.secondary)
        .frame(width: 30, height: 30)
        .background(palette.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.zhiji(ZhijiMetrics.body, .semibold)).foregroundStyle(palette.label)
        Text(state).metaStyle(palette)
      }
      Spacer(minLength: 8)
      if let actionTitle {
        Button(actionTitle, action: action)
          .buttonStyle(ZhijiCapsuleButtonStyle(prominent: true))
          .accessibilityIdentifier(actionIdentifier ?? "")
      }
    }
  }
}

extension View {
  /// A quiet rounded surface: the setup cards' background, or (on a surface
  /// already) the page colour.
  public func zhijiSurface(onSurface: Bool = false) -> some View {
    modifier(ZhijiSurface(onSurface: onSurface))
  }

  /// The card-to-header morph, only when motion is allowed: under Reduce
  /// Motion the pages cross-fade and nothing slides.
  func zhijiMorph(_ id: String, in namespace: Namespace.ID, isSource: Bool) -> some View {
    modifier(ZhijiMorph(id: id, namespace: namespace, isSource: isSource))
  }

  /// Makes a tappable card or row reachable without a pointer: Tab focus
  /// (Full Keyboard Access), Return or Space, and VoiceOver's default action.
  func zhijiActivatable(_ action: @escaping () -> Void) -> some View {
    modifier(ZhijiActivatable(action: action))
  }
}

private struct ZhijiSurface: ViewModifier {
  @Environment(\.zhiji) private var palette
  let onSurface: Bool

  func body(content: Content) -> some View {
    content.background(
      onSurface ? palette.bg : palette.surface,
      in: RoundedRectangle(
        cornerRadius: onSurface ? ZhijiMetrics.visualRadius : ZhijiMetrics.cardRadius,
        style: .continuous))
  }
}

private struct ZhijiMorph: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let id: String
  let namespace: Namespace.ID
  let isSource: Bool

  func body(content: Content) -> some View {
    if reduceMotion {
      content
    } else {
      content.matchedGeometryEffect(id: id, in: namespace, isSource: isSource)
    }
  }
}

private struct ZhijiActivatable: ViewModifier {
  let action: () -> Void

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .onTapGesture(perform: action)
      .focusable()
      .onKeyPress(.return) {
        action()
        return .handled
      }
      .onKeyPress(.space) {
        action()
        return .handled
      }
      .accessibilityAddTraits(.isButton)
      .accessibilityAction(.default, action)
  }
}

/// A searchable list of events, for 移到… / 放进…: every event, not only the
/// first few, found by title.
struct EventPicker: View {
  @Environment(\.zhiji) private var palette
  let entries: [MemoryHomeEntry]
  let pick: (String) -> Void
  @State private var query = ""
  @FocusState private var focused: Bool

  private var matches: [MemoryHomeEntry] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return entries }
    return entries.filter { $0.title.localizedCaseInsensitiveContains(needle) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(ZhijiCopy.findEvent, text: $query)
        .textFieldStyle(.roundedBorder)
        .focused($focused)
        .onSubmit { if let first = matches.first { pick(first.eventID) } }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(matches) { entry in
            Button {
              pick(entry.eventID)
            } label: {
              Text(entry.title)
                .font(.zhiji(13))
                .foregroundStyle(palette.label)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
          if matches.isEmpty {
            Text(ZhijiCopy.noMatches).font(.zhiji(13)).foregroundStyle(palette.secondary)
          }
        }
      }
      .frame(height: min(CGFloat(max(matches.count, 1)) * 26, 260))
    }
    .padding(12)
    .frame(width: 260)
    .onAppear { focused = true }
  }
}
