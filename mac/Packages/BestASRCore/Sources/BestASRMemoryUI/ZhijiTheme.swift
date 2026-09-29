import AppKit
import SwiftUI

/// The design tokens of the memory pages, light and dark. Views read the
/// palette for the current colour scheme from the environment (`\.zhiji`), so
/// a snapshot rendered with `.environment(\.colorScheme, .dark)` is dark too.
public struct ZhijiPalette: Sendable {
  public let isDark: Bool
  public let bg: Color
  public let surface: Color
  public let sidebar: Color
  public let label: Color
  public let secondary: Color
  public let tertiary: Color
  public let separator: Color
  /// Hairline under the page header (6% black / 8% white).
  public let hairline: Color
  /// Quiet fills: the search field and the segmented track.
  public let quietFill: Color
  /// Sidebar selection and secondary capsule buttons.
  public let selectionFill: Color
  /// The one brand token.
  public let accent: Color
  /// Text and glyphs drawn on `accent`: white on the light accent, near-black
  /// on the dark one (white on #7FA3E0 is about 2.6:1).
  public let onAccent: Color
  /// The selected segment's knob.
  public let knob: Color
  public let toast: Color
  public let recording: Color

  public static let light = ZhijiPalette(
    isDark: false,
    bg: .hex(0xFFFFFF), surface: .hex(0xF5F5F7), sidebar: .hex(0xF2F2F4),
    label: .hex(0x1D1D1F), secondary: .hex(0x6E6E73), tertiary: .hex(0xAEAEB2),
    separator: .black.opacity(0.10), hairline: .black.opacity(0.06),
    quietFill: .black.opacity(0.05), selectionFill: .black.opacity(0.07),
    accent: .hex(0x2F5D9E), onAccent: .hex(0xFFFFFF), knob: .hex(0xFFFFFF),
    toast: .hex(0x1D1D1F).opacity(0.92),
    recording: .hex(0xE5484D)
  )

  public static let dark = ZhijiPalette(
    isDark: true,
    bg: .hex(0x1E1E1E), surface: .hex(0x2A2A2C), sidebar: .hex(0x252527),
    label: .hex(0xF5F5F7), secondary: .hex(0xA1A1A6), tertiary: .hex(0x636366),
    separator: .white.opacity(0.12), hairline: .white.opacity(0.08),
    quietFill: .white.opacity(0.07), selectionFill: .white.opacity(0.10),
    accent: .hex(0x7FA3E0), onAccent: .hex(0x1E1E1E), knob: .hex(0x5A5A5E),
    toast: .hex(0x3A3A3C).opacity(0.96),
    recording: .hex(0xFF6369)
  )

  public static func of(_ scheme: ColorScheme) -> ZhijiPalette {
    scheme == .dark ? .dark : .light
  }

  // MARK: - Thread colours (the lanes of 最近在动的事)

  private static let threadHues: [UInt32] = [
    0x4F7CC4, 0xD0784A, 0x4E9A6E, 0x9E68A8, 0xC49A2E, 0x3E97A3,
  ]

  /// One colour per lane of Home's time axis (+12% lightness in dark).
  public func thread(_ index: Int) -> Color {
    let count = Self.threadHues.count
    let hue = Self.threadHues[((index % count) + count) % count]
    return isDark ? Color.hex(hue).lighter(0.12) : .hex(hue)
  }

  // MARK: - Voice colours (avatars and speaker ticks only)

  private static let personHues: [UInt32] = [
    0x5E8BCE, 0xC9803F, 0x5FA37A, 0xB06BAE, 0xC9A43F, 0x6F7FA0,
  ]
  /// Darker ink for initials on the 15% tint in light mode.
  private static let personInk: [UInt32] = [
    0x3F6FB5, 0xA5642A, 0x3E8659, 0x8E4A8C, 0x8A6D1F, 0x4F5E80,
  ]

  /// The person's hue (+10% lightness in dark).
  public func person(_ index: Int) -> Color {
    let hue = Self.personHues[Self.clamp(index)]
    return isDark ? Color.hex(hue).lighter(0.10) : .hex(hue)
  }

  /// A 15% tint of the hue, for avatar fills and quiet cover fields.
  public func personTint(_ index: Int, opacity: Double = 0.16) -> Color {
    person(index).opacity(isDark ? opacity + 0.08 : opacity)
  }

  /// The initial's colour on a tinted avatar.
  public func personInk(_ index: Int) -> Color {
    isDark ? person(index).lighter(0.12) : .hex(Self.personInk[Self.clamp(index)])
  }

  /// A source tile's glyph: the light ink as is, or 30% toward white in
  /// dark so it keeps at least 3:1 on its own tint.
  public func sourceInk(_ light: Color) -> Color {
    isDark ? light.lighter(0.30) : light
  }

  private static func clamp(_ index: Int) -> Int {
    ((index % personHues.count) + personHues.count) % personHues.count
  }
}

/// Type sizes and radii from the design language.
public enum ZhijiMetrics {
  public static let homeTitle: CGFloat = 26
  public static let eventTitle: CGFloat = 22
  public static let statusLine: CGFloat = 15
  public static let body: CGFloat = 13
  public static let meta: CGFloat = 11
  public static let cardRadius: CGFloat = 14
  public static let visualRadius: CGFloat = 10
  public static let sheetRadius: CGFloat = 16
  public static let sidebarWidth: CGFloat = 212
  public static let headerHeight: CGFloat = 56
  public static let column: CGFloat = 760
}

private struct ZhijiPaletteKey: EnvironmentKey {
  static let defaultValue = ZhijiPalette.light
}

private struct ZhijiSnapshotKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  public var zhiji: ZhijiPalette {
    get { self[ZhijiPaletteKey.self] }
    set { self[ZhijiPaletteKey.self] = newValue }
  }

  /// True while rendering a still image: controls that AppKit draws (text
  /// fields, scroll views, pull-down menus) are replaced by their resting
  /// look so `ImageRenderer` can draw the page.
  public var zhijiSnapshot: Bool {
    get { self[ZhijiSnapshotKey.self] }
    set { self[ZhijiSnapshotKey.self] = newValue }
  }
}

/// Sets `\.zhiji` from the current colour scheme for everything inside.
public struct ZhijiThemed<Content: View>: View {
  @Environment(\.colorScheme) private var scheme
  private let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    content
      .environment(\.zhiji, ZhijiPalette.of(scheme))
      .tint(ZhijiPalette.of(scheme).accent)
  }
}

extension Color {
  static func hex(_ value: UInt32) -> Color {
    Color(
      .sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255, opacity: 1)
  }

  /// Mixes toward white by `amount` (0–1) in sRGB.
  func lighter(_ amount: Double) -> Color {
    let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
    func mix(_ c: CGFloat) -> Double { Double(c) + (1 - Double(c)) * amount }
    return Color(
      .sRGB, red: mix(ns.redComponent), green: mix(ns.greenComponent),
      blue: mix(ns.blueComponent), opacity: 1)
  }
}

extension Font {
  static func zhiji(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight)
  }
}

extension View {
  /// Metadata style: 11, secondary, tabular digits.
  func metaStyle(_ palette: ZhijiPalette) -> some View {
    font(.zhiji(ZhijiMetrics.meta)).monospacedDigit().foregroundStyle(palette.secondary)
  }
}
