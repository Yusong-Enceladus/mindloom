import SwiftUI
import UIKit

/// The phone's colours: the Mac app's warm light theme (Home's paper tones
/// and its one indigo accent, `ZhijiPalette` / `HomeTones` in
/// BestASRMemoryUI) with its dark counterpart. Shared by the app, 织机键盘
/// and 收进织机.
enum Loom {
  /// The page: warm paper.
  static let page = dynamic(0xFBFAF7, 0x1C1B19)
  /// Cards on the page.
  static let card = dynamic(0xFFFFFF, 0x262522)
  /// The keyboard's own background and quiet fills.
  static let well = dynamic(0xF4F2EC, 0x201F1D)
  /// Keys on the keyboard.
  static let key = dynamic(0xFFFFFF, 0x3A3935)
  static let keyPressed = dynamic(0xE9E6DF, 0x4A4843)
  static let hairline = dynamic(0xE6E3DC, 0xFFFFFF, darkAlpha: 0.10)
  static let ink = dynamic(0x1F1E1B, 0xEDEBE6)
  static let secondary = dynamic(0x5F5C56, 0xB8B4AB)
  static let tertiary = dynamic(0x8C887F, 0x8F8B82)
  /// The one brand colour (the indigo of the icon).
  static let accent = dynamic(0x2F5D9E, 0x7FA3E0)
  static let onAccent = dynamic(0xFFFFFF, 0x16181D)
  static let accentTint = dynamic(0xE7EEF9, 0x1F2B3D)
  /// The listening mic key: the icon's indigo, a little deeper in dark so
  /// the key glows without glaring.
  static let micActive = dynamic(0x2F5D9E, 0x2D4E86)
  static let onMicActive = dynamic(0xFFFFFF, 0xF2F5FB)
  /// The icon's gold thread: used sparingly for the "weft" highlight.
  static let gold = dynamic(0xC98A1E, 0xE8B45A)
  static let amber = dynamic(0x9A6414, 0xE8C07A)
  static let amberTint = dynamic(0xFAF0DC, 0x3A2D1A)
  static let green = dynamic(0x3E8659, 0x7CC495)
  static let greenTint = dynamic(0xE6F2EA, 0x1E2E24)
  static let red = dynamic(0xC23F35, 0xF2A59C)
  static let redTint = dynamic(0xFBE9E6, 0x3D2522)

  static func dynamic(_ light: UInt32, _ dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
    Color(
      uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
          ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: 1)
      })
  }
}

extension UIColor {
  convenience init(hex: UInt32, alpha: CGFloat) {
    self.init(
      red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
  }
}

extension Font {
  /// SF Pro with PingFang SC for Chinese, as on the Mac.
  static func loom(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight)
  }
}

/// A card on the warm page: white (or warm charcoal), a hairline, 20 pt
/// corners.
struct LoomCard<Content: View>: View {
  var padding: CGFloat = 18
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Loom.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(
          Loom.hairline, lineWidth: 1)
      )
  }
}

/// The primary action: a full-width indigo capsule.
struct LoomPrimaryButtonStyle: ButtonStyle {
  var tint: Color = Loom.accent
  var foreground: Color = Loom.onAccent

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.loom(17, .semibold))
      .foregroundStyle(foreground)
      .frame(maxWidth: .infinity, minHeight: 52)
      .background(tint, in: Capsule())
      .opacity(configuration.isPressed ? 0.82 : 1)
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

/// A quiet secondary action on the well colour.
struct LoomSecondaryButtonStyle: ButtonStyle {
  var foreground: Color = Loom.ink

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.loom(16, .medium))
      .foregroundStyle(foreground)
      .frame(maxWidth: .infinity, minHeight: 48)
      .background(Loom.well, in: Capsule())
      .overlay(Capsule().strokeBorder(Loom.hairline, lineWidth: 1))
      .opacity(configuration.isPressed ? 0.8 : 1)
  }
}

/// The calm waveform: bars that breathe with the input level, highest in the
/// middle, drifting slowly so silence still looks alive but never busy.
struct LoomWaveform: View {
  var level: Double
  var bars: Int = 21
  var color: Color
  var minimumHeight: CGFloat = 4
  var active: Bool = true

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { timeline in
      let time = timeline.date.timeIntervalSinceReferenceDate
      Canvas { context, size in
        draw(in: &context, size: size, time: time)
      }
    }
    .accessibilityHidden(true)
  }

  private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
    let count = max(bars, 3)
    let slot: CGFloat = size.width / CGFloat(count)
    let gap: CGFloat = slot * 0.42
    let width: CGFloat = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
    let clamped: Double = max(0, min(1, level))
    let energy: Double = active ? (0.12 + 0.88 * clamped) : 0.05
    for index in 0..<count {
      let position: Double = Double(index) / Double(count - 1)
      let envelope: Double = sin(position * Double.pi)
      let phase: Double = time * 2.2 + Double(index) * 0.55
      let drift: Double = 0.5 + 0.5 * sin(phase)
      let shape: Double = energy * (0.35 + 0.65 * envelope) * (0.62 + 0.38 * drift)
      let height: CGFloat = max(minimumHeight, size.height * CGFloat(shape))
      let x: CGFloat = CGFloat(index) * (width + gap)
      let rect = CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
      context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(color))
    }
  }
}
