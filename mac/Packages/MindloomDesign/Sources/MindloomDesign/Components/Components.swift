import SwiftUI

// MARK: - Status circle

/// The small progress and state marks (SYSTEM.md §8): no legend, each one labelled by the text next to it.
public enum MLStatus: String, Sendable, CaseIterable {
  /// ● happened: the latest finished step (7 pt, `ink2`).
  case done
  /// ○ coming (7 pt hollow, 1.5 pt `ink2`).
  case next
  /// ○ in vermilion: due today or tomorrow, or past its date.
  case due
  /// ○ small hollow in `ink3`: a row still on the phone (not yet on the Mac).  No amber "pending".
  case pending
  /// · a quiet dot (4 pt `ink3`), kept for the iPhone; the Mac no longer uses it.
  case quiet
}

/// A hollow or filled status circle.
public struct MLStatusCircle: View {
  let status: MLStatus
  let diameter: CGFloat?

  /// - Parameter diameter: overrides the token size (7 pt; 4 pt for `quiet`; 6 pt for `pending`).
  public init(_ status: MLStatus, diameter: CGFloat? = nil) {
    self.status = status
    self.diameter = diameter
  }

  public var body: some View {
    let d = diameter ?? (status == .quiet ? 4 : status == .pending ? 6 : 7)
    Group {
      switch status {
      case .done: Circle().fill(MLColor.ink2)
      case .quiet: Circle().fill(MLColor.ink3)
      case .next: Circle().strokeBorder(MLColor.ink2, lineWidth: 1.5)
      case .due: Circle().strokeBorder(MLColor.alert, lineWidth: 1.5)
      case .pending: Circle().strokeBorder(MLColor.ink3, lineWidth: 1.25)
      }
    }
    .frame(width: d, height: d)
    .accessibilityHidden(true)
  }
}

// MARK: - Toast

/// A one-line glass capsule with at most one action: 「已收好 · 撤销」, 「已安全送出 · 9:41」.
/// 44 pt high; leading glyph in `mark` (the T-form mark by default).
public struct MLToast: View {
  public enum Leading: Sendable {
    case mark
    case symbol(String)
    case none
  }

  @Environment(\.mlPlatform) private var platform
  let text: String
  let detail: String?
  let leading: Leading
  let actionTitle: String?
  let action: (() -> Void)?

  /// - Parameters: text = the one line; detail = an optional second word after 「 · 」 (e.g. a time);
  ///   actionTitle/action = the single action.
  public init(
    _ text: String, detail: String? = nil, leading: Leading = .mark, actionTitle: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.text = text
    self.detail = detail
    self.leading = leading
    self.actionTitle = actionTitle
    self.action = action
  }

  public var body: some View {
    let hasAction = actionTitle != nil && action != nil
    HStack(spacing: 10) {
      switch leading {
      case .mark: MindloomMark(height: 17, form: .glyph)
      case .symbol(let name):
        if platform == .mac {
          MLSymbol(name, size: 15, box: 16, weight: .medium).foregroundStyle(MLColor.mark)
        } else {
          Image(systemName: name).foregroundStyle(MLColor.mark).font(
            .system(size: 15, weight: .medium))
        }
      case .none: EmptyView()
      }
      HStack(spacing: 0) {
        Text(text).foregroundStyle(MLColor.ink)
        if let detail {
          Text(" · ").foregroundStyle(MLColor.ink3)
          Text(detail).foregroundStyle(MLColor.ink2).monospacedDigit()
        }
      }
      .mlFont(\.controlSmall)
      .lineLimit(1)
      if hasAction, let actionTitle, let action {
        Button(action: action) {
          Text(actionTitle)
            .font(
              .system(size: MLTypeScale.scale(for: platform).controlSmall.size, weight: .medium)
            )
            .foregroundStyle(MLColor.accent)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.leading, 16)
    .padding(.trailing, hasAction ? 8 : 18)
    // Mac: 40 tall on thick glass (`.toast.ml-glass--thick`), so rows behind
    // it never show through; iOS keeps the kit's 44 on regular glass.
    .frame(height: platform == .mac ? 40 : 44)
    .mlGlass(platform == .mac ? .thick : .regular)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Section header

/// A list or sidebar section header: `section` type in `ink2`, plain words (快到期 · 这周 · 上周 · 更早).
/// Grouping comes from the header plus space, never a box.
public struct MLSectionHeader: View {
  @Environment(\.mlPlatform) private var platform
  let title: String
  let insetForInsetList: Bool

  /// - Parameter insetForInsetList: iOS inset grouped list (32 pt in from the screen edge, 7 pt above the list).
  public init(_ title: String, insetForInsetList: Bool = false) {
    self.title = title
    self.insetForInsetList = insetForInsetList
  }

  public var body: some View {
    Text(title)
      .mlFont(\.section)
      .foregroundStyle(MLColor.ink2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, platform == .ios ? (insetForInsetList ? 32 : MLMetrics.ios.gutter) : 10)
      .padding(.bottom, platform == .ios ? 7 : 5)
      .padding(.top, platform == .mac ? 14 : 0)
      .accessibilityAddTraits(.isHeader)
  }
}

// MARK: - Lens (segmented) control

/// The one row of view controls on a page (按时间 / 按截止 / 按人): a capsule track in `fill` with a raised
/// `surface2` thumb.  iOS 36 pt, 500 14 pt labels; Mac 28 pt, 13 pt labels (500 when selected).
public struct MLLensControl<Value: Hashable>: View {
  @Environment(\.mlPlatform) private var platform
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var scheme
  @Namespace private var thumb
  let options: [(value: Value, title: String)]
  @Binding var selection: Value
  let onGlass: Bool

  /// - Parameter onGlass: the control floats over content (a toolbar): the glass replaces the track's fill.
  public init(
    _ options: [(value: Value, title: String)], selection: Binding<Value>, onGlass: Bool = false
  ) {
    self.options = options
    self._selection = selection
    self.onGlass = onGlass
  }

  public var body: some View {
    let ios = platform == .ios
    let height: CGFloat = ios ? 36 : (onGlass ? 32 : 28)
    HStack(spacing: 0) {
      ForEach(options.indices, id: \.self) { i in
        let o = options[i]
        let on = o.value == selection
        Button {
          withMLAnimation(.springSnappy, reduceMotion: reduceMotion) { selection = o.value }
        } label: {
          Text(o.title)
            .font(.system(size: ios ? 14 : 13, weight: ios || on ? .medium : .regular))
            .foregroundStyle(MLColor.ink)
            .lineLimit(1)
            .padding(.horizontal, ios ? 16 : 12)
            .frame(maxHeight: .infinity)
            .background {
              if on {
                Capsule()
                  .fill(MLColor.surface2)
                  .overlay(Capsule().strokeBorder(MLColor.rule, lineWidth: 0.5))
                  .mlShadow(.thumb)
                  .matchedGeometryEffect(id: "thumb", in: thumb)
              }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
      }
    }
    .padding(2)
    .frame(height: height)
    .background {
      if onGlass { Color.clear.mlGlass(.regular) } else { Capsule().fill(MLColor.fill) }
    }
  }
}

// MARK: - Empty state

/// A title and one sentence, with an optional single action.  No illustration and no mark.
public struct MLEmptyState: View {
  let title: String
  let message: String?
  let actionTitle: String?
  let action: (() -> Void)?

  public init(
    _ title: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil
  ) {
    self.title = title
    self.message = message
    self.actionTitle = actionTitle
    self.action = action
  }

  public var body: some View {
    VStack(spacing: 10) {
      Text(title).mlFont(\.headline).foregroundStyle(MLColor.ink)
      if let message {
        Text(message).mlFont(\.sub).foregroundStyle(MLColor.ink2).frame(maxWidth: 26 * 15)
      }
      if let actionTitle, let action {
        Button(actionTitle, action: action).buttonStyle(MLButtonStyle(.tinted)).padding(.top, 4)
      }
    }
    .multilineTextAlignment(.center)
    .padding(.vertical, 48)
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Button

/// Capsule buttons (`.ml-btn`): one primary per view; press scales to 0.97 on the snappy spring.
public struct MLButtonStyle: ButtonStyle {
  public enum Kind: Sendable {
    /// Filled indigo, white text.
    case primary
    /// Indigo text on `accentTint`.
    case tinted
    /// Indigo text on `fill`.
    case standard
    /// Ink text on `fill`.
    case neutral
    /// Indigo text, no fill.
    case plain
    /// Vermilion on `alertTint` (filled only in a confirm sheet).
    case destructive
    case destructivePrimary
  }

  @Environment(\.mlPlatform) private var platform
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  let kind: Kind
  let small: Bool
  let fullWidth: Bool

  public init(_ kind: Kind = .standard, small: Bool = false, fullWidth: Bool = false) {
    self.kind = kind
    self.small = small
    self.fullWidth = fullWidth
  }

  public func makeBody(configuration: Configuration) -> some View {
    let m = MLMetrics.metrics(for: platform)
    let type = MLTypeScale.scale(for: platform)
    let h = small ? m.controlHeightSmall : m.controlHeight
    let style = small ? type.controlSmall : type.control
    let pressed = configuration.isPressed
    let (fg, bg): (MLColor, MLColor?) = {
      switch kind {
      case .primary: (.onAccent, pressed ? .accentFill3 : .accentFill)
      case .tinted: (.accent, pressed ? .accentTint2 : .accentTint)
      case .standard: (.accent, pressed ? .fill3 : .fill)
      case .neutral: (.ink, pressed ? .fill3 : .fill)
      case .plain: (.accent, pressed ? .fill2 : nil)
      case .destructive: (.alert, .alertTint)
      case .destructivePrimary: (.onAccent, .alertFill)
      }
    }()
    let padX: CGFloat = platform == .mac ? (small ? 10 : 14) : (kind == .plain ? 8 : h / 2)
    return configuration.label
      .font(style.font)
      .foregroundStyle(fg)
      .lineLimit(1)
      .padding(.horizontal, padX)
      .frame(maxWidth: fullWidth ? .infinity : nil)
      .frame(height: h)
      .background { if let bg { Capsule().fill(bg) } }
      .contentShape(Capsule())
      .scaleEffect(pressed && !reduceMotion ? MLMotion.pressedScale : 1)
      .opacity(isEnabled ? 1 : 0.4)
      .animation(MLSpring.snappy.animation, value: pressed)
  }
}

// MARK: - Symbol in a square

/// An SF symbol in the prototype's square icon box: a wide symbol (person.2, person.3, keyboard …) is fitted into
/// `box` × `box` instead of being drawn at the text size, where it came out 1.5–2× wider than the prototype's 13/16
/// pt icons and pushed the words right.  Other symbols draw at `size`, centred in the box.
public struct MLSymbol: View {
  let name: String
  let size: CGFloat
  let box: CGFloat
  let weight: Font.Weight

  public init(_ name: String, size: CGFloat, box: CGFloat? = nil, weight: Font.Weight = .regular) {
    self.name = name
    self.size = size
    self.box = box ?? size + 1
    self.weight = weight
  }

  /// Symbols wider than they are tall by a third or more.
  public static func isWide(_ name: String) -> Bool {
    let base = name.replacingOccurrences(of: ".fill", with: "")
    return [
      "person.2", "person.3", "person.2.wave.2", "keyboard", "rectangle.stack", "car", "airplane",
      "rectangle.on.rectangle", "person.2.badge.plus",
    ].contains(base)
  }

  public var body: some View {
    if MLSymbol.isWide(name) {
      Image(systemName: name)
        .resizable()
        .fontWeight(weight)
        .scaledToFit()
        .frame(width: box, height: box)
    } else {
      Image(systemName: name)
        .font(.system(size: size, weight: weight))
        .frame(width: box, height: box)
    }
  }
}
