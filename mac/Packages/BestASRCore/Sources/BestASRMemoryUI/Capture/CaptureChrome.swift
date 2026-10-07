import AppKit
import MindloomDesign
import SwiftUI

// OWNER: mac-capture. Small pieces the capture surfaces share: the two dims
// (MAC-SPEC §2.1), the settings box and rows (§9), the sheet chrome (§7.4),
// disclosure buttons, the text field and the QR block.

extension MLColor {
  /// The window overlay while files are dragged over it.
  static let dropDim = MLColor(light: MLRGBA(30, 22, 10, 0.04), dark: MLRGBA(0, 0, 0, 0.14))
  /// Behind the consent panel.
  static let consentDim = MLColor(light: MLRGBA(25, 22, 16, 0.10), dark: MLRGBA(0, 0, 0, 0.30))
}

// MARK: - Sheets (§7.4)

/// The window-modal sheet chrome: `surface`, radius 20, padding 22 24 18,
/// the level-3 shadow and a 0.5 pt `rule2` ring.
///
/// Presented live, the system sheet window is the card (its corner, shadow
/// and slide); a still image or a floating panel (`drawsCard`) draws the
/// card itself.
public struct MindloomSheetChrome<Content: View>: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let width: CGFloat
  let drawsCard: Bool
  let content: Content

  public init(width: CGFloat, drawsCard: Bool = false, @ViewBuilder content: () -> Content) {
    self.width = width
    self.drawsCard = drawsCard
    self.content = content()
  }

  public var body: some View {
    let card = drawsCard || snapshot
    VStack(alignment: .leading, spacing: 0) { content }
      .padding(EdgeInsets(top: 22, leading: 24, bottom: 18, trailing: 24))
      .frame(width: width, alignment: .leading)
      .background {
        if card {
          RoundedRectangle(cornerRadius: 20, style: .continuous).fill(MLColor.surface)
            .overlay(
              RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(
                MLColor.rule2, lineWidth: 0.5)
            )
            .mlShadow(.level3)
        } else {
          Rectangle().fill(MLColor.surface)
        }
      }
      .foregroundStyle(MLColor.ink)
      .environment(\.mlPlatform, .mac)
      .environment(\.sheetTextWidth, width - 48)
      .presentationBackground(MLColor.surface)
  }
}

extension EnvironmentValues {
  /// The text column of the sheet a view is in (titles and sentences break
  /// between phrases with balanced lines within it).
  @Entry var sheetTextWidth: CGFloat = 332
}

/// A sheet's title (`title2`, margin-bottom 6).
struct SheetTitle: View {
  @Environment(\.sheetTextWidth) private var width
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    BalancedText(text, size: 17, weight: .semibold, maxWidth: width)
      .mlFont(\.title2).padding(.bottom, 6).accessibilityAddTraits(.isHeader)
  }
}

/// A sheet's sentence (`callout`, `ink2`).
struct SheetText: View {
  @Environment(\.sheetTextWidth) private var width
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    BalancedText(text, size: 13, maxWidth: width)
      .mlFont(\.callout).foregroundStyle(MLColor.ink2)
  }
}

/// The actions row: margin-top 20, gap 8, right-aligned (an optional leading
/// group on the left).
struct SheetActions<Leading: View, Trailing: View>: View {
  let leading: Leading
  let trailing: Trailing

  init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
    self.leading = leading()
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: 8) {
      leading
      Spacer(minLength: 8)
      trailing
    }
    .padding(.top, 20)
  }
}

extension SheetActions where Leading == EmptyView {
  init(@ViewBuilder trailing: () -> Trailing) {
    self.init(leading: { EmptyView() }, trailing: trailing)
  }
}

/// The sheets' text field: 30 high, radius 8, `surface`, an inset 0.5 pt
/// `rule2` ring and the 3 pt focus ring.
struct SheetField: View {
  let placeholder: String
  @Binding var text: String
  let accessibility: String
  var mono = false
  var onSubmit: () -> Void = {}
  @FocusState private var focused: Bool
  @Environment(\.zhijiSnapshot) private var snapshot

  var body: some View {
    Group {
      if snapshot {
        // AppKit fields do not draw into a still image.
        Text(text.isEmpty ? placeholder : text)
          .foregroundStyle(text.isEmpty ? MLColor.ink3 : MLColor.ink)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(MLColor.ink3))
      }
    }
    .textFieldStyle(.plain)
    .font(mono ? .system(size: 13, design: .monospaced) : MLTypeScale.mac.control.font)
    .foregroundStyle(MLColor.ink)
    .padding(.horizontal, 10)
    .frame(height: 30)
    .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(
        MLColor.rule2, lineWidth: 0.5)
    )
    .background(
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .fill(MLColor.focus)
        .padding(-3)
        .opacity(focused ? 1 : 0)
    )
    .focused($focused)
    .onSubmit(onSubmit)
    .accessibilityLabel(accessibility)
    .onAppear { focused = true }
  }
}

// MARK: - Disclosure (详细说明, 更多选项, 查看会共享什么)

/// An accent text button with a chevron that turns 90° when open (M21).
struct DisclosureLink: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let title: String
  let open: Bool
  /// The chevron after the words (更多选项 ›) instead of before (› 详细说明).
  var chevronAfter = false
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: chevronAfter ? 2 : 4) {
        if !chevronAfter { chevron }
        Text(title).mlFont(\.control)
        if chevronAfter { chevron }
      }
      .foregroundStyle(MLColor.accent)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(open ? [.isSelected] : [])
  }

  private var chevron: some View {
    Image(systemName: "chevron.right")
      .font(.system(size: 10, weight: .semibold))
      .rotationEffect(.degrees(open ? 90 : 0))
      .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.24), value: open)
  }
}

// MARK: - Balanced lines

/// Short statements and titles break only between phrases with balanced
/// lines (`word-break: keep-all; text-wrap: balance`, MAC-SPEC §2.2): the text
/// is given the narrowest width that keeps its line count.
struct BalancedText: View {
  let text: String
  let size: CGFloat
  let weight: NSFont.Weight
  let maxWidth: CGFloat
  let alignment: Alignment

  init(
    _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, maxWidth: CGFloat,
    alignment: Alignment = .leading
  ) {
    self.text = text
    self.size = size
    self.weight = weight
    self.maxWidth = maxWidth
    self.alignment = alignment
  }

  /// The width that balances `text` into as few lines as fit `maxWidth`:
  /// lines break only between keep-all chunks (after punctuation, at
  /// spaces); the narrowest width that keeps the line count wins.
  static func width(_ text: String, size: CGFloat, weight: NSFont.Weight, maxWidth: CGFloat)
    -> CGFloat
  {
    // Measured as drawn: SF with the PingFang face first in its cascade and
    // the kern that turns off the system's Chinese–Latin gap.
    let font = MLTextStyle.cascadeNSFont(size: size, weight: weight)
    let chunks = Self.chunks(text).map {
      ($0 as NSString).size(withAttributes: [.font: font, .kern: MLTextStyle.noAutospaceKern]).width
    }
    let full = chunks.reduce(0, +)
    guard full > maxWidth else { return maxWidth }
    func lines(_ width: CGFloat) -> Int {
      var count = 1
      var line: CGFloat = 0
      for chunk in chunks {
        if line > 0, line + chunk > width {
          count += 1
          line = chunk
        } else {
          line += chunk
        }
      }
      return count
    }
    let target = lines(maxWidth)
    var low = min(maxWidth, (full / CGFloat(target)).rounded(.down))
    var high = maxWidth
    while high - low > 1 {
      let mid = (low + high) / 2
      if lines(mid) <= target { high = mid } else { low = mid }
    }
    // Slack for the difference between this measure and the laid-out text.
    return min(maxWidth, (high * 1.06 + size).rounded(.up))
  }

  /// The pieces a keep-all line may break between.
  static func chunks(_ text: String) -> [String] {
    // copy-guard: characters
    let breakAfter: Set<Character> = ["，", "。", "、", "；", "：", "？", "！", "」", "”", "）", ",", "."]
    var out: [String] = []
    var current = ""
    for c in text {
      current.append(c)
      if (c.isWhitespace && c != "\u{00A0}") || breakAfter.contains(c) {
        out.append(current)
        current = ""
      }
    }
    if !current.isEmpty { out.append(current) }
    return out
  }

  /// `keep-all`: a word joiner between characters, so lines break only at
  /// spaces (incl. autospace) and after punctuation.
  static func keepAll(_ text: String) -> String {
    // copy-guard: characters
    let breakAfter: Set<Character> = ["，", "。", "、", "；", "：", "？", "！", "」", "”", "）", ",", "."]
    var out = ""
    var previous: Character?
    for c in text {
      if let p = previous, !p.isWhitespace, !c.isWhitespace, !breakAfter.contains(p),
        c != "\u{2005}", p != "\u{2005}"
      {
        out.append("\u{2060}")
      }
      out.append(c)
      previous = c
    }
    return out
  }

  var body: some View {
    Text(Self.keepAll(text))
      .frame(
        width: Self.width(text, size: size, weight: weight, maxWidth: maxWidth),
        alignment: alignment
      )
      .fixedSize(horizontal: false, vertical: true)
  }
}

// MARK: - Settings boxes (§9)

/// A settings group: optional header (`section`, `ink2`, padding 0 12 6),
/// a box (`surface`, radius 12, 0.5 pt `rule`), optional footer.
struct SettingsGroup<Content: View>: View {
  let header: String?
  let footer: String?
  let content: Content

  init(_ header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
    self.header = header
    self.footer = footer
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let header {
        Text(header).mlFont(\.section).foregroundStyle(MLColor.ink2)
          .padding(.horizontal, 12).padding(.bottom, 6)
          .accessibilityAddTraits(.isHeader)
      }
      VStack(spacing: 0) { content }
        .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
            MLColor.rule, lineWidth: 0.5))
      if let footer {
        Text(footer).mlFont(\.foot).foregroundStyle(MLColor.ink2)
          .padding(.horizontal, 12).padding(.top, 6)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// A hairline between rows: inset 12, or 44 between icon rows.
struct SettingsSeparator: View {
  var leading: CGFloat = 12

  var body: some View {
    Rectangle().fill(MLColor.rule).frame(height: 0.5)
      .padding(.leading, leading).padding(.trailing, 12)
  }
}

/// A settings row: icon column 20, title (`control`) + description (`foot`),
/// then whatever trails (value, small button, switch). Min 44, padding 9 12.
struct SettingsRow<Trailing: View>: View {
  let symbol: String?
  let title: String
  let detail: String?
  var titleStyle: KeyPath<MLTypeScale, MLTextStyle> = \.control
  var minHeight: CGFloat = 44
  /// Break the title between phrases with balanced lines (the three sentences).
  var balancedWidth: CGFloat? = nil
  let trailing: Trailing

  init(
    _ symbol: String?, _ title: String, detail: String? = nil,
    titleStyle: KeyPath<MLTypeScale, MLTextStyle> = \.control, minHeight: CGFloat = 44,
    balancedWidth: CGFloat? = nil, @ViewBuilder trailing: () -> Trailing
  ) {
    self.balancedWidth = balancedWidth
    self.symbol = symbol
    self.title = title
    self.detail = detail
    self.titleStyle = titleStyle
    self.minHeight = minHeight
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: 12) {
      if let symbol {
        SettingsIcon(symbol: symbol).frame(width: 20)
      }
      VStack(alignment: .leading, spacing: 2) {
        Group {
          if let balancedWidth {
            let size = MLTypeScale.mac[keyPath: titleStyle].size
            BalancedText(title, size: size, maxWidth: balancedWidth)
          } else {
            Text(title).fixedSize(horizontal: false, vertical: true)
          }
        }
        .mlFont(titleStyle).foregroundStyle(MLColor.ink)
        if let detail {
          Text(detail).mlFont(\.foot).foregroundStyle(MLColor.ink2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      trailing
    }
    .padding(.vertical, 9)
    .padding(.horizontal, 12)
    .frame(minHeight: minHeight)
    .accessibilityElement(children: .contain)
  }
}

extension SettingsRow where Trailing == EmptyView {
  init(
    _ symbol: String?, _ title: String, detail: String? = nil,
    titleStyle: KeyPath<MLTypeScale, MLTextStyle> = \.control, minHeight: CGFloat = 44,
    balancedWidth: CGFloat? = nil
  ) {
    self.init(
      symbol, title, detail: detail, titleStyle: titleStyle, minHeight: minHeight,
      balancedWidth: balancedWidth, trailing: { EmptyView() })
  }
}

/// A row icon: an SF Symbol in `ink2`, or the DGX Spark's box.
struct SettingsIcon: View {
  let symbol: String
  var color: MLColor = .ink2
  var size: CGFloat = 13

  var body: some View {
    Group {
      if symbol == "device.box" {
        DeviceBoxGlyph().frame(width: size + 3, height: size + 3)
      } else {
        MLSymbol(symbol, size: size, box: size + 3)
      }
    }
    .foregroundStyle(color)
    .accessibilityHidden(true)
  }
}

/// The DGX Spark glyph (§2.6 `device.box`): an 18 × 8.4 rounded rect (r 2.2)
/// with a dot at the left and a 7.2 pt slot, on a 24 grid.
struct DeviceBoxGlyph: View {
  var body: some View {
    Canvas { ctx, size in
      let s = min(size.width, size.height) / 24
      let stroke = 1.35 * s
      let box = CGRect(x: 3 * s, y: 7.8 * s, width: 18 * s, height: 8.4 * s)
      ctx.stroke(
        Path(roundedRect: box, cornerRadius: 2.2 * s), with: .foreground, lineWidth: stroke)
      ctx.fill(
        Path(ellipseIn: CGRect(x: 6.1 * s, y: 11.1 * s, width: 1.8 * s, height: 1.8 * s)),
        with: .foreground)
      var slot = Path()
      slot.move(to: CGPoint(x: 10.8 * s, y: 12 * s))
      slot.addLine(to: CGPoint(x: 18 * s, y: 12 * s))
      ctx.stroke(slot, with: .foreground, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
    }
  }
}

/// The switch (32 × 19, knob 15), indigo when on (M23), never green.
struct SettingsSwitch: View {
  let title: String
  let isOn: Bool
  let toggle: (Bool) -> Void

  var body: some View {
    Toggle(title, isOn: Binding(get: { isOn }, set: toggle))
      .toggleStyle(MindloomSwitchStyle())
      .labelsHidden()
      .accessibilityLabel(title)
  }
}

struct MindloomSwitchStyle: ToggleStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    let on = configuration.isOn
    Button {
      configuration.isOn.toggle()
    } label: {
      ZStack(alignment: on ? .trailing : .leading) {
        Capsule().fill(on ? MLColor.accentFill : MLColor.fill3)
          .frame(width: 32, height: 19)
        Circle().fill(Color.white)
          .frame(width: 15, height: 15)
          .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
          .padding(2)
      }
      .animation(reduceMotion ? nil : MLSpring.snappy.animation, value: on)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
  }
}

// MARK: - QR

/// The pairing QR (§9.2): 132 pt in a `surface` box (padding 8, radius 8,
/// 0.5 ring) and its two sentences. `image` nil draws an empty box.
struct PairingQRBlock: View {
  let image: CGImage?
  var title = "在 iPhone 上打开 Mindloom，轻点“连接 Mac”，然后扫描此二维码。"
  var detail = "二维码 10 分钟后失效。再次打开时会生成新的二维码。"
  var label = "配对码"

  var body: some View {
    HStack(spacing: 16) {
      Group {
        if let image {
          Image(decorative: image, scale: 1).interpolation(.none).resizable()
        } else {
          ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(width: 132, height: 132)
      .padding(8)
      .background(MLColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(
          MLColor.rule2, lineWidth: 0.5)
      )
      .accessibilityLabel(label)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).mlFont(\.control).foregroundStyle(MLColor.ink)
          .fixedSize(horizontal: false, vertical: true)
        Text(detail).mlFont(\.foot).foregroundStyle(MLColor.ink2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 4)
  }
}
