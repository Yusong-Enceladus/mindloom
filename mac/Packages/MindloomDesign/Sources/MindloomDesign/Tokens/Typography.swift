import CoreText
import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The platform whose type scale, control sizes and radii a view uses (`.ml-ios` / `.ml-mac` in `tokens.css`).
public enum MLPlatform: String, Sendable, CaseIterable {
  case ios
  case mac

  /// The platform this binary runs on.
  public static var current: MLPlatform {
    #if os(macOS)
      .mac
    #else
      .ios
    #endif
  }
}

extension EnvironmentValues {
  /// Which platform's metrics the kit's components use.  Defaults to the running platform; specimens override it.
  @Entry public var mlPlatform: MLPlatform = .current
}

/// One step of a type scale: size, weight, line height and tracking, in points.
///
/// SF Pro for Latin and digits, PingFang SC for Chinese (the system cascade does this by itself).  No synthesized
/// bold: PingFang stops at Semibold (600), so titles are 600, row titles 500, everything else 400.  No negative
/// tracking on Chinese.
public struct MLTextStyle: Hashable, Sendable {
  public var size: CGFloat
  public var weight: Font.Weight
  /// CSS line height (the line box), in points.
  public var lineHeight: CGFloat
  /// Extra tracking in points (0 except the invite code).
  public var tracking: CGFloat
  /// Tabular figures (times, dates and counts in columns; the invite code).
  public var monospacedDigits: Bool

  public init(
    size: CGFloat, weight: Font.Weight, lineHeight: CGFloat, tracking: CGFloat = 0,
    monospacedDigits: Bool = false
  ) {
    self.size = size
    self.weight = weight
    self.lineHeight = lineHeight
    self.tracking = tracking
    self.monospacedDigits = monospacedDigits
  }

  /// The SwiftUI font: SF for Latin and digits, PingFang SC for Chinese.
  ///
  /// On macOS the PingFang face is named in the font's cascade list.  Left to the system cascade, macOS 27 draws
  /// PingFang at 17 pt and above scaled down (26 pt: 24.9 pt per character, ink 45 instead of 48 px @2x), so titles
  /// looked condensed next to the prototype.  The weight picks the matching PingFang face (500 Medium, 600 Semibold).
  public var font: Font {
    #if os(macOS)
      let f = MLTextStyle.cascadeFont(size: size, weight: weight)
    #else
      let f = Font.system(size: size, weight: weight)
    #endif
    return monospacedDigits ? f.monospacedDigit() : f
  }

  /// The same step at another weight (a 500 word inside a 400 line).
  public func weight(_ weight: Font.Weight) -> MLTextStyle {
    var copy = self
    copy.weight = weight
    return copy
  }

  #if os(macOS)
    /// Line spacing that makes every line `lineHeight` apart.  SwiftUI's line is the system font's own line
    /// (measured once per size: `naturalLineBox`), not PingFang's, so the spacing is the difference to that line.
    @MainActor public var lineSpacing: CGFloat {
      max(0, lineHeight - MLTextStyle.naturalLineBox(size: size))
    }

    /// Half the leading, put above the first line and below the last so a block is `lines × lineHeight` tall with
    /// its text centred in each line box, as CSS does.
    @MainActor public var halfLeading: CGFloat { lineSpacing / 2 }

    /// The height SwiftUI gives one line of text in the system font at `size` (with the PingFang cascade; the
    /// weight does not change it).  Measured from SwiftUI's own layout, once per size, on the main actor.
    @MainActor public static func naturalLineBox(size: CGFloat) -> CGFloat {
      if let known = lineBoxes[size] { return known }
      let probe = NSHostingView(
        rootView: Text(verbatim: "表Ag").font(cascadeFont(size: size, weight: .regular)).kerning(0.001)
          .fixedSize())
      let measured = probe.fittingSize.height
      let value = measured > 0 ? measured : (size * 1.18).rounded(.up)
      lineBoxes[size] = value
      return value
    }

    @MainActor private static var lineBoxes: [CGFloat: CGFloat] = [:]

    /// SF at `size`/`weight` with the PingFang SC face of the same weight first in its cascade list.
    public static func cascadeFont(size: CGFloat, weight: Font.Weight) -> Font {
      let key = CascadeKey(size: size, weight: weight)
      cascadeLock.lock()
      defer { cascadeLock.unlock() }
      if let font = cascadeFonts[key] { return font }
      let font = Font(cascadeNSFont(size: size, weight: nsWeight(weight)) as CTFont)
      cascadeFonts[key] = font
      return font
    }

    /// The same font as an `NSFont`, for measuring text the way it is drawn (balanced lines).
    public static func cascadeNSFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
      let base = NSFont.systemFont(ofSize: size, weight: weight)
      let descriptor = base.fontDescriptor.addingAttributes([
        .cascadeList: [NSFontDescriptor(name: pingFangName(weight), size: size)]
      ])
      return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private struct CascadeKey: Hashable {
      var size: CGFloat
      var weight: Font.Weight
    }

    nonisolated(unsafe) private static var cascadeFonts: [CascadeKey: Font] = [:]
    private static let cascadeLock = NSLock()

    static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
      switch weight {
      case .ultraLight: .ultraLight
      case .thin: .thin
      case .light: .light
      case .medium: .medium
      case .semibold: .semibold
      case .bold: .bold
      case .heavy: .heavy
      case .black: .black
      default: .regular
      }
    }

    /// PingFang SC stops at Semibold: bolder weights use it too (no synthesized bold).
    static func pingFangName(_ weight: NSFont.Weight) -> String {
      let w = weight.rawValue
      if w < NSFont.Weight.thin.rawValue { return "PingFangSC-Ultralight" }
      if w < NSFont.Weight.light.rawValue { return "PingFangSC-Thin" }
      if w < NSFont.Weight.regular.rawValue { return "PingFangSC-Light" }
      if w < NSFont.Weight.medium.rawValue { return "PingFangSC-Regular" }
      if w < NSFont.Weight.semibold.rawValue { return "PingFangSC-Medium" }
      return "PingFangSC-Semibold"
    }
  #else
    /// Line spacing that makes a line of Chinese text `lineHeight` tall (PingFang's natural height; iOS keeps the
    /// v11 behaviour its screens were tuned to).
    public var lineSpacing: CGFloat {
      max(0, lineHeight - MLTextStyle.naturalCJKLineHeight(size: size))
    }
  #endif

  /// The natural line height of PingFang SC at `size` (ascent + descent + leading from CoreText).
  public static func naturalCJKLineHeight(size: CGFloat) -> CGFloat {
    let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
    return CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
  }
}

/// A platform's type scale (tokens.css §2).  A screen uses at most four steps; chrome is not counted.
public struct MLTypeScale: Hashable, Sendable {
  /// One per screen at most: Welcome, empty states.
  public var large: MLTextStyle
  /// Page title (iOS) · Home date, matter title (Mac).
  public var title: MLTextStyle
  /// Sheet title · sheet / popover / pane title.
  public var title2: MLTextStyle
  /// Row title, button.
  public var headline: MLTextStyle
  /// Content: what the user said or shared; quotes.
  public var body: MLTextStyle
  public var callout: MLTextStyle
  /// Second line, meta.
  public var sub: MLTextStyle
  /// Time stamps, section headers (iOS), footers, axis dates.
  public var foot: MLTextStyle
  public var caption: MLTextStyle
  /// Section headers (sidebar and list); always in `ink2`.
  public var section: MLTextStyle
  /// Controls.
  public var control: MLTextStyle
  public var controlSmall: MLTextStyle
  /// A matter's one-line status under its title (Mac r2; on iOS the same as `callout`).
  public var lead: MLTextStyle
  /// Part names in the progress view, emphasised meta (Mac r2; on iOS `section` weight at sub size).
  public var label: MLTextStyle
  /// An invite code: tabular, tracked (Mac r2).
  public var code: MLTextStyle

  /// `.ml-ios` (pt in a 402 × 874 iPhone 17 Pro screen).
  public static let ios = MLTypeScale(
    large: .init(size: 30, weight: .semibold, lineHeight: 36),
    title: .init(size: 28, weight: .semibold, lineHeight: 34),
    title2: .init(size: 20, weight: .semibold, lineHeight: 26),
    headline: .init(size: 17, weight: .medium, lineHeight: 24),
    body: .init(size: 17, weight: .regular, lineHeight: 26),
    callout: .init(size: 16, weight: .regular, lineHeight: 22),
    sub: .init(size: 15, weight: .regular, lineHeight: 21),
    foot: .init(size: 13, weight: .regular, lineHeight: 18),
    caption: .init(size: 12, weight: .regular, lineHeight: 16),
    section: .init(size: 13, weight: .medium, lineHeight: 18),
    control: .init(size: 17, weight: .medium, lineHeight: 22),
    controlSmall: .init(size: 15, weight: .medium, lineHeight: 20),
    lead: .init(size: 16, weight: .regular, lineHeight: 22),
    label: .init(size: 15, weight: .medium, lineHeight: 21),
    code: .init(size: 28, weight: .medium, lineHeight: 34, tracking: 2, monospacedDigits: true))

  /// `.ml-mac` (pt in a window; macOS controls stay at 13).
  public static let mac = MLTypeScale(
    large: .init(size: 30, weight: .semibold, lineHeight: 36),
    title: .init(size: 26, weight: .semibold, lineHeight: 32),
    title2: .init(size: 17, weight: .semibold, lineHeight: 22),
    headline: .init(size: 15, weight: .medium, lineHeight: 21),
    body: .init(size: 14, weight: .regular, lineHeight: 22),
    callout: .init(size: 13, weight: .regular, lineHeight: 18),
    sub: .init(size: 13, weight: .regular, lineHeight: 18),
    foot: .init(size: 12, weight: .regular, lineHeight: 16),
    caption: .init(size: 11, weight: .regular, lineHeight: 14),
    section: .init(size: 11, weight: .semibold, lineHeight: 14),
    control: .init(size: 13, weight: .regular, lineHeight: 16),
    controlSmall: .init(size: 12, weight: .regular, lineHeight: 15),
    lead: .init(size: 15, weight: .regular, lineHeight: 22),
    label: .init(size: 13, weight: .medium, lineHeight: 18),
    code: .init(size: 26, weight: .medium, lineHeight: 32, tracking: 2, monospacedDigits: true))

  /// The scale for a platform.
  public static func scale(for platform: MLPlatform) -> MLTypeScale {
    platform == .mac ? .mac : .ios
  }
}

/// Applies a type step from the current platform's scale: font, line spacing and tracking.
///
/// On macOS it also turns off the system's own spacing between Chinese and Latin letters or digits: macOS 27 adds
/// about 1.5 pt at each boundary to text built from a String («表2数据» 50 pt instead of 47 at 13 pt), but not to
/// text built from a string literal, so static copy and organizer text disagreed, and dates and numbers must stay
/// tight (表2数据, 9月21日).  Any non-zero kern turns that spacing off; MLAutospace's U+2005 spaces stay where the
/// rules put them.  With `lineBox`, the text also gets the CSS line box: every line `lineHeight` tall, the text
/// centred in it.
public struct MLFontModifier: ViewModifier {
  @Environment(\.mlPlatform) private var platform
  let step: KeyPath<MLTypeScale, MLTextStyle>?
  var custom: MLTextStyle?
  var weight: Font.Weight?
  var lineBox: Bool = false

  public func body(content: Content) -> some View {
    var style = custom ?? MLTypeScale.scale(for: platform)[keyPath: step ?? \.body]
    if let weight { style.weight = weight }
    #if os(macOS)
      let spacing = style.lineSpacing
      return
        content
        .font(style.font)
        .lineSpacing(spacing)
        .tracking(style.tracking)
        .kerning(MLTextStyle.noAutospaceKern)
        .padding(.vertical, lineBox ? spacing / 2 : 0)
    #else
      return
        content
        .font(style.font)
        .lineSpacing(style.lineSpacing)
        .tracking(style.tracking)
    #endif
  }
}

/// Only the CSS line box of a step (the font is set elsewhere): half the leading above and below.
public struct MLLineBoxModifier: ViewModifier {
  @Environment(\.mlPlatform) private var platform
  let step: KeyPath<MLTypeScale, MLTextStyle>

  public func body(content: Content) -> some View {
    let style = MLTypeScale.scale(for: platform)[keyPath: step]
    #if os(macOS)
      content.padding(.vertical, style.halfLeading)
    #else
      content.frame(minHeight: style.lineHeight)
    #endif
  }
}

extension MLTextStyle {
  /// The kern that turns off macOS 27's automatic Chinese–Latin spacing without moving any glyph visibly.
  public static let noAutospaceKern: CGFloat = 0.001
}

extension View {
  /// Sets a step of the platform type scale, e.g. `.mlFont(\.headline)`; `weight` overrides the step's weight,
  /// `lineBox` adds the CSS line box (half the leading above the first line and below the last).
  public func mlFont(
    _ step: KeyPath<MLTypeScale, MLTextStyle>, weight: Font.Weight? = nil, lineBox: Bool = false
  ) -> some View {
    modifier(MLFontModifier(step: step, weight: weight, lineBox: lineBox))
  }

  /// A style that is not a step of the scale (Welcome's 17/26 tagline), applied the same way.
  public func mlFont(style: MLTextStyle, lineBox: Bool = false) -> some View {
    modifier(MLFontModifier(step: nil, custom: style, lineBox: lineBox))
  }

  /// The CSS line box of a step around text whose font is already set (a one-line row keeps its 21/18 pt height).
  public func mlLineBox(_ step: KeyPath<MLTypeScale, MLTextStyle>) -> some View {
    modifier(MLLineBoxModifier(step: step))
  }

  /// Turns off the system's automatic Chinese–Latin spacing for text styled without `mlFont` (macOS only).
  public func mlNoAutospace() -> some View {
    #if os(macOS)
      kerning(MLTextStyle.noAutospaceKern)
    #else
      self
    #endif
  }
}

/// The brand's Chinese name 「织机」: PingFang SC Medium (苹方 中黑体).  Only on Welcome, About and the close card.
public enum MLBrandFont {
  /// PostScript name of the face 「织机」 is set in.
  public static let zhijiFontName = "PingFangSC-Medium"
  /// The face of the film's tagline (PingFang SC Regular).
  public static let taglineFontName = "PingFangSC-Regular"

  /// 「织机」 at a size, tracked 0.06 em by the caller.
  public static func zhiji(size: CGFloat) -> Font { .custom(zhijiFontName, fixedSize: size) }
}
