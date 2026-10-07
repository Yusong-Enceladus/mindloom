import SwiftUI

/// The 4-pt spacing grid (`--s-0` … `--s-16`).  Use these; anything else needs a reason.
public enum MLSpace {
  public static let s0: CGFloat = 2
  public static let s1: CGFloat = 4
  public static let s1h: CGFloat = 6
  public static let s2: CGFloat = 8
  public static let s3: CGFloat = 12
  public static let s4: CGFloat = 16
  public static let s5: CGFloat = 20
  public static let s6: CGFloat = 24
  public static let s8: CGFloat = 32
  public static let s10: CGFloat = 40
  public static let s12: CGFloat = 48
  public static let s16: CGFloat = 64
  /// Hairlines are 0.5 pt (`--hair`).
  public static let hair: CGFloat = 0.5
  /// Between groups (a section header plus space, no boxes).
  public static let groupGap: CGFloat = 24
  /// From a section header to its first row.
  public static let headerGap: CGFloat = 8
}

/// Platform sizes and radii (tokens.css §3).  Corners are concentric: outer = inner + inset.
public struct MLMetrics: Hashable, Sendable {
  /// Screen side margin (iOS) or content side margin (Mac).
  public var gutter: CGFloat
  public var cellPadding: CGFloat
  public var rowMinHeight: CGFloat
  /// Minimum tap or click target.
  public var tapTarget: CGFloat
  /// Prominent button / push button height.
  public var controlHeight: CGFloat
  public var controlHeightSmall: CGFloat
  /// Segmented control height.
  public var segmentedHeight: CGFloat
  public var searchHeight: CGFloat
  public var icon: CGFloat
  public var iconSmall: CGFloat
  public var iconLarge: CGFloat
  public var radiusXS: CGFloat
  public var radiusSmall: CGFloat
  public var radiusMedium: CGFloat
  public var radiusLarge: CGFloat
  /// Inset grouped list (iOS) / cell (Mac).
  public var radiusCell: CGFloat
  public var radiusSheet: CGFloat
  /// Menus (Mac 12, iOS 22) and their items (Mac 7, iOS 12).
  public var radiusMenu: CGFloat
  public var radiusMenuItem: CGFloat
  /// iOS keyboard key (9).  0 on the Mac.
  public var radiusKey: CGFloat
  /// iPhone 17 Pro display corner (55) / Mac window (24 = sidebar 16 + inset 8).
  public var radiusScreen: CGFloat
  /// Mac inset sidebar (16) and its width (232).  0 on iOS.
  public var radiusSidebar: CGFloat
  public var sidebarWidth: CGFloat

  /// `.ml-ios`.
  public static let ios = MLMetrics(
    gutter: 20, cellPadding: 16, rowMinHeight: 52, tapTarget: 44, controlHeight: 50,
    controlHeightSmall: 36,
    segmentedHeight: 36, searchHeight: 44, icon: 20, iconSmall: 17, iconLarge: 24,
    radiusXS: 6, radiusSmall: 10, radiusMedium: 14, radiusLarge: 22, radiusCell: 26,
    radiusSheet: 38,
    radiusMenu: 22, radiusMenuItem: 12, radiusKey: 9, radiusScreen: 55, radiusSidebar: 0,
    sidebarWidth: 0)

  /// `.ml-mac` (macOS 26 regular control size).
  public static let mac = MLMetrics(
    gutter: 32, cellPadding: 12, rowMinHeight: 32, tapTarget: 28, controlHeight: 28,
    controlHeightSmall: 22,
    segmentedHeight: 28, searchHeight: 30, icon: 16, iconSmall: 14, iconLarge: 20,
    radiusXS: 4, radiusSmall: 7, radiusMedium: 10, radiusLarge: 14, radiusCell: 12, radiusSheet: 20,
    radiusMenu: 12, radiusMenuItem: 7, radiusKey: 0, radiusScreen: 24, radiusSidebar: 16,
    sidebarWidth: 232)

  public static func metrics(for platform: MLPlatform) -> MLMetrics {
    platform == .mac ? .mac : .ios
  }
}

/// One layer of a CSS `box-shadow` (`0 y blur color`).
public struct MLShadowLayer: Hashable, Sendable {
  public var color: MLColor
  /// CSS blur radius in points.
  public var blur: CGFloat
  public var y: CGFloat

  public init(color: MLColor, blur: CGFloat, y: CGFloat) {
    self.color = color
    self.blur = blur
    self.y = y
  }
}

/// Warm, layered shadows (`--shadow-1/2/3`, `--shadow-window`, `--glass-shadow`).  Never one large blur on a slab.
public struct MLShadow: Hashable, Sendable {
  public var layers: [MLShadowLayer]

  public init(_ layers: [MLShadowLayer]) { self.layers = layers }

  private static func c(_ l: MLRGBA, _ d: MLRGBA) -> MLColor { MLColor(light: l, dark: d) }

  public static let level1 = MLShadow([
    .init(color: c(MLRGBA(40, 30, 15, 0.10), MLRGBA(0, 0, 0, 0.4)), blur: 1, y: 0.5),
    .init(color: c(MLRGBA(40, 30, 15, 0.06), MLRGBA(0, 0, 0, 0.3)), blur: 3, y: 1),
  ])
  public static let level2 = MLShadow([
    .init(color: c(MLRGBA(40, 30, 15, 0.08), MLRGBA(0, 0, 0, 0.35)), blur: 2, y: 1),
    .init(color: c(MLRGBA(40, 30, 15, 0.08), MLRGBA(0, 0, 0, 0.35)), blur: 18, y: 6),
  ])
  public static let level3 = MLShadow([
    .init(color: c(MLRGBA(40, 30, 15, 0.08), MLRGBA(0, 0, 0, 0.35)), blur: 6, y: 2),
    .init(color: c(MLRGBA(40, 30, 15, 0.16), MLRGBA(0, 0, 0, 0.5)), blur: 48, y: 18),
  ])
  public static let window = MLShadow([
    .init(color: c(MLRGBA(30, 22, 10, 0.26), MLRGBA(0, 0, 0, 0.6)), blur: 70, y: 24),
    .init(color: c(MLRGBA(30, 22, 10, 0.10), MLRGBA(0, 0, 0, 0.4)), blur: 18, y: 6),
  ])
  public static let glass = MLShadow([
    .init(color: c(MLRGBA(30, 22, 10, 0.10), MLRGBA(0, 0, 0, 0.35)), blur: 24, y: 8),
    .init(color: c(MLRGBA(30, 22, 10, 0.06), MLRGBA(0, 0, 0, 0.3)), blur: 3, y: 1),
  ])
  /// The raised thumb of a segmented control.
  public static let thumb = MLShadow([
    .init(color: c(MLRGBA(40, 30, 15, 0.10), MLRGBA(0, 0, 0, 0.35)), blur: 2, y: 1),
    .init(color: c(MLRGBA(40, 30, 15, 0.06), MLRGBA(0, 0, 0, 0.2)), blur: 8, y: 2),
  ])
}

/// Applies an `MLShadow` (each CSS layer as one SwiftUI shadow; SwiftUI radius ≈ CSS blur / 2).
public struct MLShadowModifier: ViewModifier {
  @Environment(\.colorScheme) private var scheme
  let shadow: MLShadow

  public func body(content: Content) -> some View {
    shadow.layers.reduce(AnyView(content)) { view, layer in
      AnyView(
        view.shadow(color: layer.color.color(for: scheme), radius: layer.blur / 2, x: 0, y: layer.y)
      )
    }
  }
}

extension View {
  /// A warm layered shadow, e.g. `.mlShadow(.level2)`.
  public func mlShadow(_ shadow: MLShadow) -> some View {
    modifier(MLShadowModifier(shadow: shadow))
  }

  /// A 0.5 pt hairline under the view in `rule`.
  public func mlHairlineBelow() -> some View {
    overlay(alignment: .bottom) { Rectangle().fill(MLColor.rule).frame(height: MLSpace.hair) }
  }
}
