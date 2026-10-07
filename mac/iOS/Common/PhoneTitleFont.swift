import CoreText
import SwiftUI
import UIKit

/// Display-size titles (PHONE-SPEC §2.2: title 28/34/600, title2 20/26/600). At display sizes the
/// system font's own fallback draws Chinese (PingFang) about 7 % smaller and lighter than the CSS
/// stack the design was drawn with (`-apple-system, "PingFang SC"`), so 「最近」 looked weaker
/// than designed. Here PingFang SC comes first in the cascade at the nominal size: Chinese at its
/// designed size, Latin (Mac, MacBook Pro) still SF.
enum PhoneTitleFont {
  static func uiFont(_ size: CGFloat, weight: UIFont.Weight = .semibold) -> UIFont {
    let base = UIFont.systemFont(ofSize: size, weight: weight)
    let name =
      weight >= .semibold
      ? "PingFangSC-Semibold" : (weight >= .medium ? "PingFangSC-Medium" : "PingFangSC-Regular")
    let chinese = UIFontDescriptor(fontAttributes: [.name: name, .size: size])
    let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [chinese]])
    return UIFont(descriptor: descriptor, size: size)
  }

  static func font(_ size: CGFloat, weight: UIFont.Weight = .semibold) -> Font {
    Font(uiFont(size, weight: weight))
  }

  /// The blank before the first glyph's ink and after the last glyph's ink of a one-line title.
  static func inkBlanks(_ text: String, size: CGFloat, weight: UIFont.Weight = .semibold)
    -> (leading: CGFloat, trailing: CGFloat)
  {
    let font = uiFont(size, weight: weight)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: [.font: font]))
    let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    guard advance > 0, ink.width > 0 else { return (0, 0) }
    return (max(0, ink.minX), max(0, advance - ink.maxX))
  }

  /// The blank to the right of a glyph's ink (advance − inked right edge), for trimming a trailing
  /// 「？」 so a centred title centres on its ink (PHONE-SPEC §6.0).
  static func trailingBlank(of character: Character, size: CGFloat, weight: UIFont.Weight = .semibold)
    -> CGFloat
  {
    let font = uiFont(size, weight: weight)
    let string = String(character) as CFString
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: string as String, attributes: [.font: font]))
    let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    guard advance > 0, ink.width > 0 else { return 0 }
    return max(0, advance - ink.maxX)
  }
}
