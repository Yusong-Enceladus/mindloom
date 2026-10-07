import MindloomDesign
import SwiftUI
import UIKit

/// System bars in the v10 type (PHONE-SPEC §2.2): large titles 28/34 600, inline titles 17/22 600,
/// both in `ink`; the bars stay the system's (Liquid Glass back button, push and pop).
enum PhoneAppearance {
  @MainActor static func configure() {
    let ink = MLColor.ink.platformColor
    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.largeTitleTextAttributes = [
      .font: PhoneTitleFont.uiFont(28), .foregroundColor: ink,
    ]
    appearance.titleTextAttributes = [
      .font: UIFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: ink,
    ]
    // (Layout margins are not an appearance property: setting them through `appearance()` throws
    // at launch. The 20 pt gutter is set on each bar by `navigationGutter()`.)
    let bar = UINavigationBar.appearance()
    bar.standardAppearance = appearance
    bar.compactAppearance = appearance
    bar.scrollEdgeAppearance = appearance
    bar.tintColor = ink
    UISwitch.appearance().onTintColor = MLColor.accentFill.platformColor
  }
}

/// Puts the navigation bar's large title on the 20 pt screen gutter, like Home and Permissions
/// (the system's margin is 16): sets the margins on the bar that shows this page.
struct NavigationGutter: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> Controller { Controller() }
  func updateUIViewController(_ controller: Controller, context: Context) {}

  final class Controller: UIViewController {
    override func viewWillAppear(_ animated: Bool) {
      super.viewWillAppear(animated)
      apply()
    }

    override func didMove(toParent parent: UIViewController?) {
      super.didMove(toParent: parent)
      apply()
    }

    private func apply() {
      guard let bar = navigationController?.navigationBar else { return }
      let margins = NSDirectionalEdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
      if bar.directionalLayoutMargins != margins {
        bar.insetsLayoutMarginsFromSafeArea = false
        bar.directionalLayoutMargins = margins
      }
    }
  }
}

extension View {
  func navigationGutter() -> some View {
    background(NavigationGutter().frame(width: 0, height: 0).accessibilityHidden(true))
  }
}

/// A full-width capsule button, 50 high (primary, neutral, destructive).
struct BlockButton: View {
  enum Kind {
    case primary
    case neutral
    case destructive
    case plain
    case onDark
  }

  let title: String
  var kind: Kind = .primary
  let action: () -> Void

  init(_ title: String, kind: Kind = .primary, action: @escaping () -> Void) {
    self.title = title
    self.kind = kind
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .contentShape(Capsule())
    }
    .buttonStyle(BlockButtonStyle(kind: kind))
  }
}

struct BlockButtonStyle: ButtonStyle {
  let kind: BlockButton.Kind
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    let (fg, bg): (Color, Color) = {
      switch kind {
      case .primary:
        (.white, (pressed ? MLColor.accentFill3 : MLColor.accentFill).dynamicColor)
      case .neutral:
        (MLColor.ink.dynamicColor, (pressed ? MLColor.fill3 : MLColor.fill).dynamicColor)
      case .destructive:
        (.white, MLColor.alertFill.dynamicColor.opacity(pressed ? 0.85 : 1))
      case .plain:
        (MLColor.ink2.dynamicColor, pressed ? MLColor.fill2.dynamicColor : .clear)
      case .onDark:
        (.white, Color.white.opacity(pressed ? 0.26 : 0.16))
      }
    }()
    return configuration.label
      .font(.system(size: 17, weight: .medium))
      .foregroundStyle(fg)
      .background(Capsule().fill(bg))
      .scaleEffect(pressed && !reduceMotion ? MLMotion.pressedScale : 1)
      .opacity(isEnabled ? 1 : 0.4)
      .animation(MLSpring.snappy.animation, value: pressed)
  }
}

/// A tinted small capsule (打开, 去设置, 粘贴, 加一句): 15/20 500 `accent` on `accentTint`.
struct SmallTintedButton: View {
  let title: String
  var height: CGFloat = 36
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(MLColor.accent)
        .padding(.horizontal, 14)
        .frame(height: height)
        .background(Capsule().fill(MLColor.accentTint))
        .contentShape(Capsule())
    }
    .buttonStyle(PressFade())
  }
}

/// Dims a little while pressed (plain text actions).
struct PressFade: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
  }
}

/// A round 44 pt glass button (the gear, back, close).
struct GlassCircleButton: View {
  let systemName: String
  var size: CGFloat = 21
  var weight: Font.Weight = .regular
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: size, weight: weight))
        .foregroundStyle(MLColor.ink)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: Circle())
    .accessibilityLabel(label)
  }
}

/// Text with the v10 line height (Chinese lines ≥ 1.5) and words kept whole.
struct BodyText: View {
  let text: String
  var size: CGFloat = 17
  var lineHeight: CGFloat = 26
  var weight: Font.Weight = .regular
  var color: MLColor = .ink
  var alignment: TextAlignment = .leading

  var body: some View {
    Text(PhoneText.keepingWordsWhole(text))
      .font(.system(size: size, weight: weight))
      .lineSpacing(PhoneLine.spacing(size: size, lineHeight: lineHeight))
      // CSS puts half the leading above the first line and below the last
      .padding(.vertical, PhoneLine.spacing(size: size, lineHeight: lineHeight) / 2)
      .fixedSize(horizontal: false, vertical: true)
      .foregroundStyle(color)
      .multilineTextAlignment(alignment)
      .accessibilityLabel(PhoneText.plain(text))
  }
}

extension View {
  /// The trailing ？！。 of a centred title hangs 0.6 em out, so the title centres on its ink
  /// (PHONE-SPEC §6.0). Applied by `TrimmedTitle`.
  func phoneFont(_ size: CGFloat, _ weight: Font.Weight = .regular, lineHeight: CGFloat? = nil)
    -> some View
  {
    let spacing = lineHeight.map { PhoneLine.spacing(size: size, lineHeight: $0) } ?? 0
    return self.font(.system(size: size, weight: weight)).lineSpacing(spacing)
  }
}

/// A centred title (`title2` by default) that centres on its ink (PHONE-SPEC §6.0): the blank
/// the font leaves before the first glyph and after the last (a full-width 「？」 carries a lot) is
/// measured and trimmed, so 「与 Mac 断开？」 sits on the sheet's centre line.
struct TrimmedTitle: View {
  let text: String
  var size: CGFloat = 20

  var body: some View {
    let blank = PhoneTitleFont.inkBlanks(text, size: size)
    Text(text)
      .font(PhoneTitleFont.font(size))
      .foregroundStyle(MLColor.ink)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .padding(.leading, -blank.leading)
      .padding(.trailing, -blank.trailing)
      .accessibilityLabel(text)
  }
}

/// A sheet sized to its content (PHONE-SPEC §5.2, §5.8: padding 8 20 20): the measured height is
/// the detent, and the content hugs the sheet's bottom edge, so the last button sits 20 pt above
/// it in the thumb zone instead of under a band of empty sheet.
struct FittedSheet: ViewModifier {
  @State private var height: CGFloat

  init(estimate: CGFloat) {
    _height = State(initialValue: estimate)
  }

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { new in
        let rounded = ceil(new)
        if abs(rounded - height) > 0.5 { height = rounded }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
      .ignoresSafeArea(.container, edges: .bottom)
      .presentationDetents([.height(height)])
  }
}

extension View {
  func fittedSheet(estimate: CGFloat) -> some View { modifier(FittedSheet(estimate: estimate)) }
}

/// Text wrapped to balanced lines (CSS `text-wrap: balance`): when it does not fit on one line in
/// `available`, the measure narrows so the lines come out about even.
struct BalancedText: View {
  let text: String
  var size: CGFloat = 15
  var lineHeight: CGFloat = 21
  var weight: Font.Weight = .regular
  var color: MLColor = .ink2
  var alignment: TextAlignment = .leading
  let available: CGFloat

  var body: some View {
    BodyText(
      text: text, size: size, lineHeight: lineHeight, weight: weight, color: color,
      alignment: alignment
    )
    .frame(width: Self.measure(text, size: size, weight: weight, available: available),
      alignment: alignment == .center ? .center : .leading)
    .fixedSize(horizontal: false, vertical: true)
  }

  static func measure(_ text: String, size: CGFloat, weight: Font.Weight, available: CGFloat)
    -> CGFloat
  {
    let font = UIFont.systemFont(ofSize: size, weight: weight == .medium ? .medium : .regular)
    let widest = text.split(separator: "\n").map {
      (String($0) as NSString).size(withAttributes: [.font: font]).width
    }.max() ?? 0
    if text.contains("\n") || widest <= available { return min(available, ceil(widest) + 1) }
    let lines = ceil(widest / available)
    return min(available, ceil(widest / lines) + size * 1.2)
  }
}

/// Line spacing for a CSS line height. SwiftUI's line box for the system font is SF's own line
/// height (≈ 1.19 × size) even when every glyph comes from PingFang, so the spacing is what is left
/// above that (PHONE-SPEC §2.2: body 17/26, sub 15/21, foot 13/18).
enum PhoneLine {
  static func spacing(size: CGFloat, lineHeight: CGFloat) -> CGFloat {
    max(0, lineHeight - UIFont.systemFont(ofSize: size).lineHeight)
  }
}
