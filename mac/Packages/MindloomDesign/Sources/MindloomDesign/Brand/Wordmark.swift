import CoreText
import SwiftUI

struct WordmarkLetterData: Sendable {
  let x0: Double
  let x1: Double
  let ops: [Double]
}

struct WordmarkMasterData: Sendable {
  let width: Double
  let xHeight: Double
  let stem: Double
  let descender: Double
  let letters: [WordmarkLetterData]
}

/// The two optical masters of wordmark C (brand/DESIGN.md §4).
public enum MindloomWordmarkMaster: String, Sendable, CaseIterable {
  /// Cap height ≥ 13 pt.  Stem 12.8, word width 5.90 C.
  case display
  /// Below 13 pt: stems 27 % heavier, spacing 28 % looser.  Word width 6.43 C.
  case text

  /// kit.js: display at cap ≥ 13, text below.
  public static func automatic(cap: CGFloat) -> MindloomWordmarkMaster {
    cap >= 13 ? .display : .text
  }

  var data: WordmarkMasterData { self == .display ? WordmarkPaths.display : WordmarkPaths.text }

  /// Word width in cap heights (5.9019 display, 6.4307 text).
  public var widthPerCap: CGFloat { data.width / 100 }

  /// The letters' left ink edges in cap heights (M i n d l o o m), for a letter-by-letter reveal.
  public var letterLefts: [CGFloat] { data.letters.map { $0.x0 / 100 } }
}

/// Outlines of the wordmark, built once from the generated path data (units: cap 100, y down, baseline at 0).
enum WordmarkOutline {
  static let display = make(WordmarkPaths.display)
  static let text = make(WordmarkPaths.text)

  static func outline(_ m: MindloomWordmarkMaster) -> (word: Path, letters: [Path]) {
    m == .display ? display : text
  }

  static func make(_ d: WordmarkMasterData) -> (word: Path, letters: [Path]) {
    var word = Path()
    var letters: [Path] = []
    for letter in d.letters {
      let p = path(letter.ops)
      letters.append(p)
      word.addPath(p)
    }
    return (word, letters)
  }

  static func path(_ ops: [Double]) -> Path {
    var p = Path()
    var i = 0
    while i < ops.count {
      switch Int(ops[i]) {
      case 0:
        p.move(to: CGPoint(x: ops[i + 1], y: ops[i + 2]))
        i += 3
      case 1:
        p.addLine(to: CGPoint(x: ops[i + 1], y: ops[i + 2]))
        i += 3
      case 2:
        p.addCurve(
          to: CGPoint(x: ops[i + 5], y: ops[i + 6]),
          control1: CGPoint(x: ops[i + 1], y: ops[i + 2]),
          control2: CGPoint(x: ops[i + 3], y: ops[i + 4]))
        i += 7
      default:
        p.closeSubpath()
        i += 1
      }
    }
    return p
  }
}

/// The wordmark as a `Shape`.  Its frame is the SVG's viewBox (`0 -100.1 w 101.2`): the top edge is the cap line,
/// the baseline sits 1.1 % of the cap height above the bottom.  Optionally only some letters (0 = M … 7 = m).
public struct MindloomWordmarkShape: Shape {
  public var master: MindloomWordmarkMaster
  public var letters: IndexSet?

  public init(master: MindloomWordmarkMaster = .display, letters: IndexSet? = nil) {
    self.master = master
    self.letters = letters
  }

  public func path(in rect: CGRect) -> Path {
    let o = WordmarkOutline.outline(master)
    let s = rect.height / 101.2
    var src = Path()
    if let letters {
      for i in letters where i < o.letters.count { src.addPath(o.letters[i]) }
    } else {
      src = o.word
    }
    return src.applying(
      CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: rect.minX, ty: rect.minY + 100.1 * s))
  }

  public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
    let a = master.data.width / 101.2
    if let h = proposal.height, h.isFinite { return CGSize(width: h * a, height: h) }
    return CGSize(width: 14 * 1.012 * a, height: 14 * 1.012)
  }
}

/// "Mindloom", drawn (wordmark C).  Outlines only; no font.  Colour is `wordmark` (#1B2440 / #F3F1EA).
public struct MindloomWordmark: View {
  @Environment(\.colorScheme) private var scheme
  let cap: CGFloat
  let master: MindloomWordmarkMaster?
  let color: Color?

  /// - Parameters: cap = cap height in points (default 14); master nil = by size.
  public init(cap: CGFloat = 14, master: MindloomWordmarkMaster? = nil, color: Color? = nil) {
    self.cap = cap
    self.master = master
    self.color = color
  }

  public var body: some View {
    let m = master ?? .automatic(cap: cap)
    MindloomWordmarkShape(master: m)
      .fill(color ?? MLColor.wordmark.color(for: scheme))
      .frame(width: cap * m.widthPerCap, height: cap * 1.012)
      .accessibilityElement()
      .accessibilityLabel("Mindloom")
      .accessibilityAddTraits(.isImage)
  }
}

/// The horizontal lockup (brand §5): mark form M at 1.5 C, gap 0.5 C, the mark's centre 0.06 C below the cap
/// centre.  At C ≤ 12 the mark is form T and the word the text master.  Minimum C 11; clear space 0.75 C.
/// Never 「织机」 next to it.
public struct MindloomLockup: View {
  let cap: CGFloat
  let wordColor: Color?
  let markColor: Color?

  public init(cap: CGFloat = 14, wordColor: Color? = nil, markColor: Color? = nil) {
    self.cap = cap
    self.wordColor = wordColor
    self.markColor = markColor
  }

  public var body: some View {
    let small = cap <= 12
    HStack(alignment: .center, spacing: cap * 0.5) {
      Group {
        if let markColor {
          MindloomMark(height: 1.5 * cap, form: small ? .glyph : .medium, fixedColor: markColor)
        } else {
          MindloomMark(height: 1.5 * cap, form: small ? .glyph : .medium)
        }
      }
      .offset(y: cap * 0.06)
      MindloomWordmark(cap: cap, master: small ? .text : .display, color: wordColor)
    }
  }
}

/// The stacked lockup (brand §5): mark form L at 2.7 C (M below a 56 pt mark), 0.66 C to the cap line, the word,
/// then 「织机」 in PingFang SC Medium at 0.54 C, tracked 0.06 em, its ink top 0.72 C under the baseline, in `ink2`.
/// 「织机」 is drawn only when asked (`showsZhiji: true`): in the Apps that is About alone (docs/UI-COPY.md §4;
/// review 10-5c C4).
public struct MindloomStackedLockup: View {
  @Environment(\.colorScheme) private var scheme
  let cap: CGFloat
  public let showsZhiji: Bool
  let zhijiColor: Color?

  public init(cap: CGFloat = 30, showsZhiji: Bool = false, zhijiColor: Color? = nil) {
    self.cap = cap
    self.showsZhiji = showsZhiji
    self.zhijiColor = zhijiColor
  }

  public var body: some View {
    let markH = 2.7 * cap
    VStack(spacing: 0) {
      MindloomMark(height: markH, form: markH >= 56 ? .large : .medium)
        .padding(.bottom, cap * 0.66)
      MindloomWordmark(cap: cap)
      if showsZhiji {
        let size = cap * 0.54
        let m = ZhijiMetrics(size: size)
        Text("织机")
          .font(MLBrandFont.zhiji(size: size))
          .tracking(0.06 * size)
          .padding(.leading, 0.06 * size)
          .foregroundStyle(zhijiColor ?? MLColor.ink2.color(for: scheme))
          // wordmark frame bottom is 0.011 C under the baseline; the text frame's top is `ascent` above its baseline
          .padding(.top, max(0, 0.72 * cap + m.inkTop - m.ascent - 0.011 * cap))
          .fixedSize()
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(showsZhiji ? "Mindloom 织机" : "Mindloom")
  }
}

/// PingFang SC Medium metrics for 「织机」 at a size: CoreText ascent and the glyphs' ink top above the baseline.
struct ZhijiMetrics {
  let ascent: CGFloat
  let descent: CGFloat
  /// Ink top above the baseline.
  let inkTop: CGFloat
  /// Ink left and right edges from the first glyph's origin, with `tracking` between glyphs.
  let inkLeft: CGFloat
  let inkRight: CGFloat

  init(
    size: CGFloat, text: String = "织机", fontName: String = MLBrandFont.zhijiFontName,
    tracking: CGFloat = 0
  ) {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    ascent = CTFontGetAscent(font)
    descent = CTFontGetDescent(font)
    let chars = Array(text.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count)
    var rects = [CGRect](repeating: .zero, count: glyphs.count)
    CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &rects, glyphs.count)
    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
    inkTop = rects.map(\.maxY).max() ?? ascent
    var x: CGFloat = 0
    var lo = CGFloat.infinity
    var hi = -CGFloat.infinity
    for (i, r) in rects.enumerated() {
      lo = min(lo, x + r.minX)
      hi = max(hi, x + r.maxX)
      x += advances[i].width + tracking
    }
    inkLeft = lo.isFinite ? lo : 0
    inkRight = hi.isFinite ? hi : 0
  }
}
