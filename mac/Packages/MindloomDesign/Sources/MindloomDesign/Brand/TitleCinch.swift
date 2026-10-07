import CoreText
import SwiftUI

/// Colours of the name introduction (brand/DESIGN.md §5).
public struct TitleCinchPalette: Hashable, Sendable {
  public var ground: MLRGBA
  public var mark: MLRGBA
  public var ink: MLRGBA
  /// 「织机」 and the tagline.
  public var sub: MLRGBA

  public init(ground: MLRGBA, mark: MLRGBA, ink: MLRGBA, sub: MLRGBA) {
    self.ground = ground
    self.mark = mark
    self.ink = ink
    self.sub = sub
  }

  /// The film: stage #0B0C0F, mark #AFC2EC, word #F3F1EA, 「织机」 and tagline #C9C5BB.
  public static let film = TitleCinchPalette(
    ground: MLRGBA(hex: 0x0B0C0F), mark: MLRGBA(hex: 0xAFC2EC), ink: MLRGBA(hex: 0xF3F1EA),
    sub: MLRGBA(hex: 0xC9C5BB))
  /// The app, light: paper #FBFAF7, mark #23407D, word #1B2440, sub #5E594F.
  public static let paperLight = TitleCinchPalette(
    ground: MLRGBA(hex: 0xFBFAF7), mark: MLRGBA(hex: 0x23407D), ink: MLRGBA(hex: 0x1B2440),
    sub: MLRGBA(hex: 0x5E594F))
  /// The app, dark: paper #161513, mark #AFC2EC, word #F3F1EA, sub #ADA79B.
  public static let paperDark = TitleCinchPalette(
    ground: MLRGBA(hex: 0x161513), mark: MLRGBA(hex: 0xAFC2EC), ink: MLRGBA(hex: 0xF3F1EA),
    sub: MLRGBA(hex: 0xADA79B))

  /// The app palette for an appearance.
  public static func paper(_ scheme: ColorScheme) -> TitleCinchPalette {
    scheme == .dark ? .paperDark : .paperLight
  }
}

/// The v10 name introduction (brand/DESIGN.md §6–7; Remotion `Title.tsx` 「收」 and `Close.tsx`), as a pure function
/// of time, drawn in the film's 1920 × 1080 frame and scaled to fit the view.
///
/// - `.title` (5.93 s): the mark fades in at the centre as two hairline strokes at the edges of its band, 7 % larger
///   than it ends, and draws itself tight (one critically damped move, response 1.1 s); from 1.10 s one sine ease
///   moves it left to its place in the horizontal lockup (378 px at 1080p, peak 540 px/s); from 「Mindloom」 each
///   letter rises 0.12 C at full ink once the mark has cleared it; then the tagline, flush left under the name, in two
///   halves on its words.  One slow push 1.000 → 1.025.  No 「织机」 (brand rule).
/// - `.closeCard` (4 s): the stacked lockup's mark (three strokes) cinches; 「织机」 enters on 「织机」 (0.62 s) and
///   Mindloom's letters rise on 「Mindloom」 (1.10 s).
/// - `.cover`: the stacked lockup and the tagline, still.  No 「织机」.
///
/// Nothing travels, ties or wriggles; nothing passes through the letters.
public struct TitleCinch: View {
  public enum Variant: String, Sendable, CaseIterable {
    case title
    case closeCard
    case cover

    /// Length in seconds (the film's 60 fps frames: 356 and 240).
    public var duration: TimeInterval {
      switch self {
      case .title: 356.0 / 60
      case .closeCard: 240.0 / 60
      case .cover: 0
      }
    }
  }

  @Environment(\.colorScheme) private var scheme
  let variant: Variant
  let time: TimeInterval
  let palette: TitleCinchPalette?
  let drawsGround: Bool

  /// - Parameters: time in seconds from the start; palette nil = paper in the current appearance; drawsGround false
  ///   leaves the background to the host.
  public init(
    _ variant: Variant = .title, time: TimeInterval, palette: TitleCinchPalette? = nil,
    drawsGround: Bool = true
  ) {
    self.variant = variant
    self.time = time
    self.palette = palette
    self.drawsGround = drawsGround
  }

  /// The same, by progress 0…1 through the variant's duration.
  public init(
    _ variant: Variant = .title, progress: Double, palette: TitleCinchPalette? = nil,
    drawsGround: Bool = true
  ) {
    self.init(
      variant, time: max(0, min(1, progress)) * variant.duration, palette: palette,
      drawsGround: drawsGround)
  }

  public var body: some View {
    let pal = palette ?? .paper(scheme)
    let f = time * 60
    let v = variant
    let ground = drawsGround
    Canvas { ctx, size in
      if ground {
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(pal.ground.color))
      }
      let s = min(size.width / 1920, size.height / 1080)
      ctx.translateBy(x: (size.width - 1920 * s) / 2, y: (size.height - 1080 * s) / 2)
      ctx.scaleBy(x: s, y: s)
      switch v {
      case .title: TitleScene.drawTitle(frame: f, palette: pal, in: &ctx)
      case .closeCard: TitleScene.drawClose(frame: f, palette: pal, in: &ctx)
      case .cover: TitleScene.drawCover(palette: pal, in: &ctx)
      }
    }
    .aspectRatio(16 / 9, contentMode: .fit)
    .accessibilityElement()
    .accessibilityLabel(variant == .closeCard ? "Mindloom 织机" : "Mindloom，只管丢进来，不用整理。")
  }
}

/// Plays a `TitleCinch` once from when it appears, then holds the last frame.  With Reduce Motion the last frame fades
/// in (0.2 s) and nothing moves.
public struct TitleCinchPlayer: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let variant: TitleCinch.Variant
  let palette: TitleCinchPalette?
  let onFinished: (@MainActor () -> Void)?
  @State private var start: Date?
  @State private var finished = false
  @State private var shown = false

  public init(
    _ variant: TitleCinch.Variant = .title, palette: TitleCinchPalette? = nil,
    onFinished: (@MainActor () -> Void)? = nil
  ) {
    self.variant = variant
    self.palette = palette
    self.onFinished = onFinished
  }

  public var body: some View {
    Group {
      if reduceMotion {
        TitleCinch(variant, time: variant.duration, palette: palette)
          .opacity(shown ? 1 : 0)
          .animation(.easeOut(duration: MLMotion.durReduced), value: shown)
      } else {
        TimelineView(.animation(minimumInterval: nil, paused: finished || start == nil)) { tl in
          let t = start.map { min(variant.duration, tl.date.timeIntervalSince($0)) } ?? 0
          TitleCinch(variant, time: t, palette: palette)
        }
      }
    }
    .task {
      start = Date()
      shown = true
      try? await Task.sleep(for: .seconds(reduceMotion ? MLMotion.durReduced : variant.duration))
      finished = true
      onFinished?()
    }
  }
}

/// The scenes, in film px (1920 × 1080), ported from Title.tsx / Close.tsx / kit.tsx.
enum TitleScene {
  // knot.ts BRAND.lockup
  static let hGlyphHeight = 1.5, hGap = 0.5, hDrop = 0.06
  static let sGlyphHeight = 2.7, sGap = 0.66, sZhiji = 0.54, sZhijiGap = 0.72, sTrack = 0.06
  /// Measured word onsets (DESIGN.md §6): Mindloom f122, 只管丢进来 f175, 不用整理 f242; each starts 4 frames ahead.
  static let tName = 118.0, tTagA = 171.0, tTagB = 238.0
  /// The cinch starts (0.20 s), the move left starts (1.10 s) and takes 1.10 s.
  static let c0 = 12.0, m0 = 66.0, md = 66.0
  static let tagBearing = 0.067

  struct Horizontal {
    let c: Double, kh: Double, k: Double, kw: Double, band: Double, channel: Double, kx: Double,
      ky: Double
    let wx: Double, baseline: Double, ww: Double
  }

  static func ink(_ form: MindloomMarkForm) -> (h: Double, w: Double) {
    let g = KnotGeometry.n720
    return (g.bounds.height + form.band, g.bounds.width + form.band)
  }

  /// kit.tsx `lockupH(C = 118, cx = 960, capMid = 448)`.
  static let lockupH: Horizontal = {
    let c = 118.0
    let cx = 960.0
    let capMid = 448.0
    let i = ink(.medium)
    let kh = c * hGlyphHeight
    let k = kh / i.h
    let kw = i.w * k
    let ww = MindloomWordmarkMaster.display.data.width * c / 100
    let total = kw + c * hGap + ww
    let left = cx - total / 2
    return Horizontal(
      c: c, kh: kh, k: k, kw: kw, band: MindloomMarkForm.medium.band * k,
      channel: MindloomMarkForm.medium.channel * k,
      kx: left + kw / 2, ky: capMid + c * hDrop, wx: left + kw + c * hGap, baseline: capMid + c / 2,
      ww: ww)
  }()

  static func markX(_ f: Double) -> Double {
    MLMath.mix(960, lockupH.kx, sineInOut((f - m0) / md))
  }

  /// First frame at which the mark's right ink edge is 0.3 C clear of letter i (Title.tsx `clearFrame`).
  static let letterStart: [Double] = {
    let l = lockupH
    return MindloomWordmarkMaster.display.letterLefts.enumerated().map { i, x0 in
      let left = l.wx + Double(x0) * l.c
      var clear = 356.0
      for f in 0..<356 where markX(Double(f)) + l.kw / 2 + 0.3 * l.c < left {
        clear = Double(f)
        break
      }
      return max(tName + 2 + Double(i) * 3.5, clear)
    }
  }()

  struct Stacked {
    let c: Double, cx: Double, kh: Double, k: Double, band: Double, channel: Double, ky: Double,
      baseline: Double
    let ww: Double, cnTop: Double, cnSize: Double
  }

  /// Close.tsx `lockupS(C, cx, top)`.
  static func lockupS(_ c: Double, _ cx: Double, _ top: Double) -> Stacked {
    let i = ink(.large)
    let kh = c * sGlyphHeight
    let k = kh / i.h
    let baseline = top + kh + c * sGap + c
    return Stacked(
      c: c, cx: cx, kh: kh, k: k, band: MindloomMarkForm.large.band * k,
      channel: MindloomMarkForm.large.channel * k,
      ky: top + kh / 2, baseline: baseline, ww: MindloomWordmarkMaster.display.data.width * c / 100,
      cnTop: baseline + c * sZhijiGap, cnSize: c * sZhiji)
  }

  // easing (kit.tsx)
  static func spring1(_ t: Double, _ response: Double) -> Double {
    MLMotion.springStep(t, response: response, damping: 1)
  }
  static func sineInOut(_ x: Double) -> Double { 0.5 - 0.5 * cos(Double.pi * MLMath.clamp(x)) }
  static func outCubic(_ x: Double) -> Double { 1 - pow(1 - MLMath.clamp(x), 3) }

  /// The knot cinching: strokes grow from `start` × B (hairlines at the band's edges) to their width as it settles.
  static func drawCinch(
    form: MindloomMarkForm, centre: CGPoint, k: Double, band: Double, channel: Double, c: Double,
    start: Double,
    opacity: Double, color: Color, in ctx: inout GraphicsContext
  ) {
    guard opacity > 0.001 else { return }
    let g = KnotGeometry.n720
    let n = form.strands
    let wf = band / (Double(n) + Double(n - 1) * form.ratio)
    let w = MLMath.mix(start * band, wf, c)
    let sc = MLMath.mix(1.07, 1, c)
    let pts = g.points.map { CGPoint(x: centre.x + $0.x * k * sc, y: centre.y + $0.y * k * sc) }
    var l = ctx
    l.opacity = opacity
    KnotBandPainter.draw(
      points: pts, depth: g.depth, band: band, channel: channel, strands: n, strandWidth: w,
      color: color, in: &l)
  }

  /// One letter of the display master at cap c, its baseline at (x, baseline), risen by `rise` px, at `opacity`.
  static func drawLetter(
    _ i: Int, x: Double, baseline: Double, c: Double, rise: Double, opacity: Double, color: Color,
    in ctx: inout GraphicsContext
  ) {
    guard opacity > 0.001 else { return }
    let s = c / 100
    let p = WordmarkOutline.display.letters[i].applying(
      CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: x, ty: baseline + rise))
    var l = ctx
    l.opacity = opacity
    l.fill(p, with: .color(color))
  }

  /// CSS baseline of a line box: top + half-leading + ascent.
  static func cssBaseline(top: Double, lineHeight: Double, fontName: String, size: Double) -> Double
  {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    let a = CTFontGetAscent(font)
    let d = CTFontGetDescent(font)
    return top + (lineHeight - (a + d)) / 2 + a
  }

  /// The tagline in two halves (kit.tsx `Tagline`): each rises 0.62 em out of an invisible slot with a fade.
  static func drawTagline(
    left: Double, top: Double, size: Double, weight: Font.Weight, tracking: Double, a: Double,
    b: Double, color: Color,
    in ctx: inout GraphicsContext
  ) {
    let fontName = weight == .medium ? "PingFangSC-Medium" : MLBrandFont.taglineFontName
    let lh = 1.2 * size
    let base = cssBaseline(top: top, lineHeight: lh, fontName: fontName, size: size)
    func resolved(_ s: String) -> GraphicsContext.ResolvedText {
      ctx.resolve(
        Text(s).font(.custom(fontName, fixedSize: size)).tracking(tracking).foregroundColor(color))
    }
    let first = resolved("只管丢进来，")
    let second = resolved("不用整理。")
    let big = CGSize(width: 4000, height: 1000)
    let s1 = first.measure(in: big)
    let s2 = second.measure(in: big)
    let halves: [(GraphicsContext.ResolvedText, CGSize, Double, Double)] = [
      (first, s1, left, a), (second, s2, left + s1.width - 0.36 * size, b),
    ]
    for (text, sz, x, p) in halves where p > 0.001 {
      var l = ctx
      // the slot: the line box, 0.1 em above and 0.16 em below, a hair wider
      l.clip(
        to: Path(
          CGRect(
            x: x - 0.02 * size, y: top - 0.1 * size, width: sz.width + 0.04 * size,
            height: lh + 0.26 * size)))
      l.opacity = MLMath.smooth(p * 1.6)
      let y = base + (1 - p) * 0.62 * size - text.firstBaseline(in: sz)
      l.draw(text, in: CGRect(x: x, y: y, width: sz.width, height: sz.height))
    }
  }

  // MARK: scenes

  static func drawTitle(frame f: Double, palette: TitleCinchPalette, in ctx: inout GraphicsContext)
  {
    let l = lockupH
    // one slow push over the whole scene
    let push = 1 + 0.025 * MLMath.smooth(f / 356)
    ctx.translateBy(x: 960, y: 470)
    ctx.scaleBy(x: push, y: push)
    ctx.translateBy(x: -960, y: -470)
    // the mark: made at the centre, then one move left
    let c = spring1((f - c0) / 60, 1.1)
    drawCinch(
      form: .medium, centre: CGPoint(x: markX(f), y: l.ky), k: l.k, band: l.band,
      channel: l.channel,
      c: c, start: 0.11,
      opacity: MLMath.smooth((f - c0) / 14), color: palette.mark.color, in: &ctx)
    // the name: each letter rises once the mark has cleared it
    for i in 0..<letterStart.count {
      let v = outCubic((f - letterStart[i]) / 24)
      guard v > 0 else { continue }
      drawLetter(
        i, x: l.wx, baseline: l.baseline, c: l.c, rise: (1 - v) * 0.12 * l.c, opacity: v,
        color: palette.ink.color,
        in: &ctx)
    }
    // the tagline, flush left under the name (its first glyph's ink on the M's stem)
    drawTagline(
      left: l.wx - tagBearing * 48, top: l.baseline + 0.86 * l.c, size: 48, weight: .regular,
      tracking: 0.08 * 48,
      a: outCubic((f - tTagA) / 30), b: outCubic((f - tTagB) / 30), color: palette.sub.color,
      in: &ctx)
  }

  static func drawClose(frame f: Double, palette: TitleCinchPalette, in ctx: inout GraphicsContext)
  {
    let l = lockupS(104, 960, 238)
    let push = 1 + 0.02 * MLMath.smooth(f / 240)
    ctx.translateBy(x: 960, y: 500)
    ctx.scaleBy(x: push, y: push)
    ctx.translateBy(x: -960, y: -500)
    let c = spring1((f - 2) / 60, 1.4)
    drawCinch(
      form: .large, centre: CGPoint(x: l.cx, y: l.ky), k: l.k, band: l.band, channel: l.channel,
      c: c,
      start: 0.1,
      opacity: MLMath.smooth((f - 1) / 14), color: palette.mark.color, in: &ctx)
    // Mindloom's letters rise on 「Mindloom」 (f66)
    let x = l.cx - l.ww / 2
    for i in 0..<8 {
      let v = outCubic((f - 66 - Double(i) * 3) / 24)
      guard v > 0 else { continue }
      drawLetter(
        i, x: x, baseline: l.baseline, c: l.c, rise: (1 - v) * 0.12 * l.c, opacity: v,
        color: palette.ink.color,
        in: &ctx)
    }
    // 「织机」 enters on 「织机」 (f37), rising 14 px
    let zh = outCubic((f - 37) / 30)
    if zh > 0.001 {
      drawZhiji(l, offset: (1 - zh) * 14, opacity: zh, color: palette.sub.color, in: &ctx)
    }
  }

  static func drawCover(palette: TitleCinchPalette, in ctx: inout GraphicsContext) {
    let l = lockupS(116, 960, 206)
    drawCinch(
      form: .large, centre: CGPoint(x: l.cx, y: l.ky), k: l.k, band: l.band, channel: l.channel,
      c: 1,
      start: 0.1,
      opacity: 1, color: palette.mark.color, in: &ctx)
    let x = l.cx - l.ww / 2
    for i in 0..<8 {
      drawLetter(
        i, x: x, baseline: l.baseline, c: l.c, rise: 0, opacity: 1, color: palette.ink.color,
        in: &ctx)
    }
    // centred, the 。's empty right half compensated (padding-left 0.66 em), PingFang Medium 62, tracked 0.06 em
    let size = 62.0
    let r1 = ctx.resolve(
      Text("只管丢进来，").font(.custom("PingFangSC-Medium", fixedSize: size)).tracking(0.06 * size))
    let r2 = ctx.resolve(
      Text("不用整理。").font(.custom("PingFangSC-Medium", fixedSize: size)).tracking(0.06 * size))
    let big = CGSize(width: 4000, height: 1000)
    let w = r1.measure(in: big).width + r2.measure(in: big).width - 0.36 * size + 0.66 * size
    drawTagline(
      left: 960 - w / 2 + 0.66 * size, top: l.baseline + 0.62 * l.c, size: size, weight: .medium,
      tracking: 0.06 * size, a: 1, b: 1, color: palette.sub.color, in: &ctx)
  }

  /// 「织机」 in PingFang SC Medium, centred on its ink, ink top at the lockup's `cnTop`, tracked 0.06 em between glyphs.
  static func drawZhiji(
    _ l: Stacked, offset: Double, opacity: Double, color: Color, in ctx: inout GraphicsContext
  ) {
    let size = l.cnSize
    let m = ZhijiMetrics(size: size, tracking: sTrack * size)
    let text = ctx.resolve(Text("织").font(MLBrandFont.zhiji(size: size)).foregroundColor(color))
    let text2 = ctx.resolve(Text("机").font(MLBrandFont.zhiji(size: size)).foregroundColor(color))
    let big = CGSize(width: 1000, height: 1000)
    let s1 = text.measure(in: big)
    let s2 = text2.measure(in: big)
    let x0 = l.cx - (m.inkLeft + m.inkRight) / 2
    let baseline = l.cnTop + m.inkTop + offset
    var c = ctx
    c.opacity = opacity
    c.draw(
      text,
      in: CGRect(
        x: x0, y: baseline - text.firstBaseline(in: s1), width: s1.width, height: s1.height))
    let x1 = x0 + s1.width + sTrack * size
    c.draw(
      text2,
      in: CGRect(
        x: x1, y: baseline - text2.firstBaseline(in: s2), width: s2.width, height: s2.height))
  }
}
