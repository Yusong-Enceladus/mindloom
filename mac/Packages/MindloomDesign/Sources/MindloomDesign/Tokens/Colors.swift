import SwiftUI

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// One sRGB colour with alpha, as written in `tokens.css` (`#RRGGBB` or `rgb(r g b / a)`).
public struct MLRGBA: Hashable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public var alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  /// `0xRRGGBB` with an optional alpha.
  public init(hex: UInt32, alpha: Double = 1) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255, alpha: alpha)
  }

  /// `rgb(r g b / a)` with 0–255 channels.
  public init(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) {
    self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: a)
  }

  /// A SwiftUI colour in the sRGB space.
  public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

  #if canImport(AppKit)
    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
  #elseif canImport(UIKit)
    public var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
  #endif
}

/// A colour token with exact light and dark values (`light-dark()` in `tokens.css`).
///
/// As a `ShapeStyle` it resolves from the view's `colorScheme`, so `.foregroundStyle(MLColor.ink)` follows the system
/// appearance (and any `.environment(\.colorScheme, …)` override, which is what snapshot renders use).  For drawing
/// in a `Canvas`, ask for `color(for:)` with the environment's scheme.  `dynamicColor` gives the same pair as an
/// AppKit/UIKit dynamic colour for code outside SwiftUI.
public struct MLColor: ShapeStyle, Hashable, Sendable {
  public let light: MLRGBA
  public let dark: MLRGBA

  public init(light: MLRGBA, dark: MLRGBA) {
    self.light = light
    self.dark = dark
  }

  /// Hex pair, opaque.
  public init(_ light: UInt32, _ dark: UInt32) {
    self.init(light: MLRGBA(hex: light), dark: MLRGBA(hex: dark))
  }

  /// The same value in both appearances (system-owned colours such as the traffic lights).
  public init(fixed: MLRGBA) {
    self.init(light: fixed, dark: fixed)
  }

  /// The value for one appearance.
  public func rgba(for scheme: ColorScheme) -> MLRGBA { scheme == .dark ? dark : light }

  /// The SwiftUI colour for one appearance.
  public func color(for scheme: ColorScheme) -> Color { rgba(for: scheme).color }

  public func resolve(in environment: EnvironmentValues) -> Color {
    color(for: environment.colorScheme)
  }

  /// A platform dynamic colour that follows the system appearance (AppKit `NSColor` / UIKit `UIColor`).
  public var dynamicColor: Color {
    #if canImport(AppKit)
      Color(nsColor: platformColor)
    #else
      Color(uiColor: platformColor)
    #endif
  }

  #if canImport(AppKit)
    /// `NSColor` that resolves with the drawing appearance.
    public var platformColor: NSColor {
      let l = light
      let d = dark
      return NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua])
          != nil
          ? d.nsColor : l.nsColor
      }
    }
  #elseif canImport(UIKit)
    /// `UIColor` that resolves with the trait collection.
    public var platformColor: UIColor {
      let l = light
      let d = dark
      return UIColor { traits in traits.userInterfaceStyle == .dark ? d.uiColor : l.uiColor }
    }
  #endif
}

// MARK: - The tokens (tokens.css §1)

extension MLColor {
  // warm neutrals: paper and ink (hue ~45°, low chroma)
  /// Content background (Mac window, iPhone plain screens).
  public static let paper = MLColor(0xFBFAF7, 0x161513)
  /// Grouped background, Mac sidebar base, sunken areas.
  public static let paper2 = MLColor(0xF4F2ED, 0x1E1D1A)
  /// Tracks, pressed fills.
  public static let paper3 = MLColor(0xECE9E2, 0x292724)
  /// Cells, cards, sheets, popovers (solid).
  public static let surface = MLColor(0xFFFFFF, 0x23221F)
  /// A surface on a surface (selected segment, menu on a sheet).
  public static let surface2 = MLColor(0xFFFFFF, 0x2C2A27)

  /// Primary text (16:1 on paper in both appearances).
  public static let ink = MLColor(0x1F1D19, 0xF2EFE8)
  /// Secondary text and meta (at least 5.7:1 on every surface).
  public static let ink2 = MLColor(0x5E594F, 0xADA79B)
  /// Placeholders, chevrons, disabled.  Never for content.
  public static let ink3 = MLColor(0x8A8478, 0x7D786E)
  /// Decoration only: axis ticks, track lines.
  public static let ink4 = MLColor(0xB8B2A6, 0x57534C)

  /// Hairlines.
  public static let rule = MLColor(
    light: MLRGBA(31, 29, 25, 0.10), dark: MLRGBA(242, 239, 232, 0.10))
  /// Control borders.
  public static let rule2 = MLColor(
    light: MLRGBA(31, 29, 25, 0.16), dark: MLRGBA(242, 239, 232, 0.16))
  /// Control fills, chips.
  public static let fill = MLColor(
    light: MLRGBA(120, 108, 86, 0.12), dark: MLRGBA(214, 204, 184, 0.14))
  /// Hover.
  public static let fill2 = MLColor(
    light: MLRGBA(120, 108, 86, 0.07), dark: MLRGBA(214, 204, 184, 0.08))
  /// Pressed.
  public static let fill3 = MLColor(
    light: MLRGBA(120, 108, 86, 0.18), dark: MLRGBA(214, 204, 184, 0.20))

  // the one accent: brand indigo
  /// Text, icons and marks that are interactive or selected.
  public static let accent = MLColor(0x23407D, 0xA9BCEB)
  /// Filled controls (primary button, switch on).
  public static let accentFill = MLColor(0x23407D, 0x4363A6)
  /// Filled control, hover.
  public static let accentFill2 = MLColor(0x1C3568, 0x4F70B4)
  /// Filled control, pressed.
  public static let accentFill3 = MLColor(0x172C57, 0x3A5895)
  /// Selected rows, soft buttons.
  public static let accentTint = MLColor(
    light: MLRGBA(35, 64, 125, 0.09), dark: MLRGBA(169, 188, 235, 0.14))
  /// Stronger tint (sidebar selection, the key span of a quote).
  public static let accentTint2 = MLColor(
    light: MLRGBA(35, 64, 125, 0.15), dark: MLRGBA(169, 188, 235, 0.22))
  /// Text on `accentFill`.
  public static let onAccent = MLColor(fixed: MLRGBA(hex: 0xFFFFFF))
  /// The mark, exactly the brand pair (#23407D / #AFC2EC).
  public static let mark = MLColor(0x23407D, 0xAFC2EC)

  // the one alert: vermilion.  Due today or tomorrow, overdue, not connected, destructive.  Nothing else.
  public static let alert = MLColor(0xB5371E, 0xFF8A6E)
  public static let alertFill = MLColor(0xB5371E, 0xD9583C)
  public static let alertTint = MLColor(
    light: MLRGBA(181, 55, 30, 0.09), dark: MLRGBA(255, 138, 110, 0.14))

  public static let focus = MLColor(
    light: MLRGBA(35, 64, 125, 0.42), dark: MLRGBA(169, 188, 235, 0.5))
  public static let selection = MLColor(
    light: MLRGBA(35, 64, 125, 0.16), dark: MLRGBA(169, 188, 235, 0.28))
  public static let scrim = MLColor(light: MLRGBA(25, 22, 16, 0.22), dark: MLRGBA(0, 0, 0, 0.45))

  // system-owned colours we only imitate (never re-tint them)
  public static let kbBackground = MLColor(0xD3D5DB, 0x2B2B2D)
  public static let kbKey = MLColor(0xFFFFFF, 0x6B6B6F)
  public static let kbKeyFn = MLColor(0xABB0BA, 0x464649)
  public static let kbKeyInk = MLColor(0x0E0E10, 0xFFFFFF)
  public static let kbShadow = MLColor(light: MLRGBA(0, 0, 0, 0.26), dark: MLRGBA(0, 0, 0, 0.5))
  public static let systemOrange = MLColor(fixed: MLRGBA(hex: 0xFF9F0A))
  public static let systemRed = MLColor(fixed: MLRGBA(hex: 0xFF5F57))
  public static let systemYellow = MLColor(fixed: MLRGBA(hex: 0xFEBC2E))
  public static let systemGreen = MLColor(fixed: MLRGBA(hex: 0x28C840))

  // brand (brand/DESIGN.md §5)
  /// The wordmark's ink (`.ml-wordmark`): #1B2440 / #F3F1EA.  Colour lives only in the mark.
  public static let wordmark = MLColor(0x1B2440, 0xF3F1EA)
  /// The mark in the Dynamic Island: pale in both appearances.
  public static let islandMark = MLColor(fixed: MLRGBA(hex: 0xAFC2EC))

  // materials (tokens.css §4)
  /// Liquid Glass approximation, regular: paper 66 % / warm black 58 %.
  public static let glassTint = MLColor(
    light: MLRGBA(252, 251, 248, 0.66), dark: MLRGBA(40, 38, 35, 0.58))
  /// Thick: menus, sheets, popovers, the HUD.
  public static let glassTint2 = MLColor(
    light: MLRGBA(252, 251, 248, 0.82), dark: MLRGBA(44, 42, 39, 0.76))
  /// Clear: only over photos, with `dim` under it.
  public static let glassClear = MLColor(
    light: MLRGBA(255, 255, 255, 0.22), dark: MLRGBA(30, 28, 26, 0.28))
  /// The top sheen of glass (top colour of a gradient that ends transparent at 45 %).
  public static let glassSheen = MLColor(
    light: MLRGBA(255, 255, 255, 0.5), dark: MLRGBA(255, 255, 255, 0.06))
  /// Inner edge of glass (0.5 pt) and its 1 pt top highlight.
  public static let glassEdge = MLColor(
    light: MLRGBA(255, 255, 255, 0.65), dark: MLRGBA(255, 255, 255, 0.10))
  public static let glassHighlight = MLColor(
    light: MLRGBA(255, 255, 255, 0.8), dark: MLRGBA(255, 255, 255, 0.12))
  /// macOS sidebar vibrancy tint.
  public static let sidebarTint = MLColor(
    light: MLRGBA(240, 237, 230, 0.72), dark: MLRGBA(34, 32, 29, 0.70))
  /// The dim layer under clear glass (35 % black, both appearances).
  public static let dim = MLColor(fixed: MLRGBA(0, 0, 0, 0.35))

  /// Every token by its CSS name, for specimens and checks.
  public static let all: [(name: String, color: MLColor)] = [
    ("--paper", paper), ("--paper-2", paper2), ("--paper-3", paper3), ("--surface", surface),
    ("--surface-2", surface2), ("--ink", ink), ("--ink-2", ink2), ("--ink-3", ink3),
    ("--ink-4", ink4),
    ("--rule", rule), ("--rule-2", rule2), ("--fill", fill), ("--fill-2", fill2),
    ("--fill-3", fill3),
    ("--accent", accent), ("--accent-fill", accentFill), ("--accent-fill-2", accentFill2),
    ("--accent-fill-3", accentFill3), ("--accent-tint", accentTint),
    ("--accent-tint-2", accentTint2),
    ("--on-accent", onAccent), ("--mark", mark), ("--alert", alert), ("--alert-fill", alertFill),
    ("--alert-tint", alertTint), ("--focus", focus), ("--selection", selection), ("--scrim", scrim),
    ("--kb-bg", kbBackground), ("--kb-key", kbKey), ("--kb-key-fn", kbKeyFn),
    ("--kb-key-ink", kbKeyInk),
    ("--kb-shadow", kbShadow), ("--sys-orange", systemOrange), ("--sys-red", systemRed),
    ("--sys-yellow", systemYellow), ("--sys-green", systemGreen), ("wordmark", wordmark),
    ("--glass-tint", glassTint), ("--glass-tint-2", glassTint2), ("--glass-clear", glassClear),
    ("--sidebar-tint", sidebarTint),
  ]
}

extension ShapeStyle where Self == MLColor {
  public static var mlPaper: MLColor { .paper }
  public static var mlPaper2: MLColor { .paper2 }
  public static var mlSurface: MLColor { .surface }
  public static var mlInk: MLColor { .ink }
  public static var mlInk2: MLColor { .ink2 }
  public static var mlInk3: MLColor { .ink3 }
  public static var mlInk4: MLColor { .ink4 }
  public static var mlRule: MLColor { .rule }
  public static var mlFill: MLColor { .fill }
  public static var mlAccent: MLColor { .accent }
  public static var mlAccentFill: MLColor { .accentFill }
  public static var mlAccentTint: MLColor { .accentTint }
  public static var mlMark: MLColor { .mark }
  public static var mlAlert: MLColor { .alert }
}
