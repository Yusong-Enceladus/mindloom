import SwiftUI

/// The four forms of the mark.  A form changes only what is inside the band, never the silhouette.
public enum MindloomMarkForm: String, Sendable, CaseIterable {
  /// Three strands: large marks (≥ 112 device px), the app icon, Welcome.
  case large = "L"
  /// Two strands: medium marks (56–112 device px), the horizontal lockup.
  case medium = "M"
  /// One band: reserved for the 16 and 32 px icon slots.
  case small = "S"
  /// One band at SF weight: every UI glyph next to text (bars, keys, toasts, the island, the menu bar).
  case glyph = "T"

  /// Strand count, band width B and channel G in knot units, and the gap/strand ratio (kit.js `FORMS`).
  public var strands: Int {
    switch self {
    case .large: 3
    case .medium: 2
    case .small, .glyph: 1
    }
  }
  public var band: Double {
    switch self {
    case .large: 120
    case .medium: 128
    case .small: 86
    case .glyph: 72
    }
  }
  public var channel: Double {
    switch self {
    case .large: 12
    case .medium: 17
    case .small: 38
    case .glyph: 32
    }
  }
  public var ratio: Double {
    switch self {
    case .large: 0.34
    case .medium: 0.36
    case .small, .glyph: 0
    }
  }

  /// Width of one strand in knot units (the band for one-strand forms).
  public var strandWidth: Double {
    strands == 1 ? band : band / (Double(strands) + Double(strands - 1) * ratio)
  }

  /// The form for a mark `points` tall at a display scale (kit.js `ML.formFor`, a brand rule in device px):
  /// ≥ 112 device px L, ≥ 56 M, else T.
  public static func automatic(points: CGFloat, displayScale: CGFloat) -> MindloomMarkForm {
    let d = points * displayScale
    return d >= 112 ? .large : d >= 56 ? .medium : .glyph
  }
}

/// The mark's construction for one form (kit.js `ML.mark`), in knot units, computed once.
///
/// Mask a: the whole band (strands made by erasing the gaps), then a channel of width B + 2G erased along the band
/// on top at every crossing.  Mask b: the band on top redrawn over each crossing, a little longer than its channel.
struct MarkPlan: Sendable {
  let form: MindloomMarkForm
  /// The ink box (the centreline's box grown by B/2), the mark's frame.
  let viewBox: CGRect
  let full: [CGPoint]
  let channels: [[CGPoint]]
  let overs: [(band: [CGPoint], gap: [CGPoint])]

  var aspect: CGFloat { viewBox.width / viewBox.height }

  init(form: MindloomMarkForm) {
    self.form = form
    let g = KnotGeometry.n720
    let pts = g.points
    let b = form.band
    let gg = form.channel
    viewBox = g.bounds.insetBy(dx: -b / 2, dy: -b / 2)
    full = Array(pts.dropLast())
    var chans: [[CGPoint]] = []
    var overs: [(band: [CGPoint], gap: [CGPoint])] = []
    let ds = g.length / Double(g.count)
    for c in KnotMath.crossings(pts, closed: true) {
      let si = KnotMath.overIndex(c, depth: g.depth)
      let sn = max(c.sin, 0.25)
      let cot = (1 - sn * sn).squareRoot() / sn
      // half-length along the band on top over which its channel meets the band underneath
      let r = ((b / 2 + gg) * cot + b / 2 / sn) * 1.12 + 0.04 * b
      chans.append(KnotMath.window(pts, closed: true, at: si, halfLength: r, ds: ds))
      overs.append(
        (
          KnotMath.window(pts, closed: true, at: si, halfLength: r + 0.3 * b, ds: ds),
          KnotMath.window(pts, closed: true, at: si, halfLength: r + 0.3 * b + 2 * ds, ds: ds)
        ))
    }
    channels = chans
    self.overs = overs
  }

  static let large = MarkPlan(form: .large)
  static let medium = MarkPlan(form: .medium)
  static let small = MarkPlan(form: .small)
  static let glyph = MarkPlan(form: .glyph)

  static func plan(_ form: MindloomMarkForm) -> MarkPlan {
    switch form {
    case .large: large
    case .medium: medium
    case .small: small
    case .glyph: glyph
    }
  }
}

/// Draws the mark into a `GraphicsContext` (Canvas, ImageRenderer, the app icon).
public enum MindloomMarkPainter {
  /// Draws `form` so its ink box fills `rect`'s height, left-aligned, centred vertically.
  public static func draw(
    _ form: MindloomMarkForm, in context: inout GraphicsContext, rect: CGRect, color: Color
  ) {
    let plan = MarkPlan.plan(form)
    let s = rect.height / plan.viewBox.height
    var c = context
    c.translateBy(x: rect.minX, y: rect.minY)
    c.scaleBy(x: s, y: s)
    c.translateBy(x: -plan.viewBox.minX, y: -plan.viewBox.minY)
    draw(plan, in: &c, color: color)
  }

  /// Draws the mark centred on `centre` (knot units scaled by `scale` points per unit).
  public static func draw(
    _ form: MindloomMarkForm, in context: inout GraphicsContext, centre: CGPoint, scale: CGFloat,
    color: Color
  ) {
    var c = context
    c.translateBy(x: centre.x, y: centre.y)
    c.scaleBy(x: scale, y: scale)
    draw(MarkPlan.plan(form), in: &c, color: color)
  }

  static func draw(_ plan: MarkPlan, in c: inout GraphicsContext, color: Color) {
    let form = plan.form
    let b = form.band
    let g = form.channel
    let n = form.strands
    let w = form.strandWidth
    let shade = GraphicsContext.Shading.color(color)
    let erase = GraphicsContext.Shading.color(.black)
    let full = KnotMath.path(plan.full, closed: true)
    let round = StrokeStyle(lineWidth: b, lineCap: .butt, lineJoin: .round)
    // mask a: the band (strands by erasing the gaps) and the channels
    c.drawLayer { l in
      l.stroke(full, with: shade, style: round)
      if n >= 2 {
        l.blendMode = .destinationOut
        l.stroke(
          full, with: erase,
          style: StrokeStyle(lineWidth: b - 2 * w, lineCap: .butt, lineJoin: .round))
        l.blendMode = .normal
        if n == 3 {
          l.stroke(
            full, with: shade, style: StrokeStyle(lineWidth: w, lineCap: .butt, lineJoin: .round))
        }
      }
      l.blendMode = .destinationOut
      for ch in plan.channels {
        l.stroke(
          KnotMath.path(ch), with: erase,
          style: StrokeStyle(lineWidth: b + 2 * g, lineCap: .butt, lineJoin: .round))
      }
    }
    // mask b: the band on top over each crossing
    c.drawLayer { l in
      for o in plan.overs {
        let d = KnotMath.path(o.band)
        l.blendMode = .normal
        l.stroke(d, with: shade, style: StrokeStyle(lineWidth: b, lineCap: .butt, lineJoin: .miter))
        if n >= 2 {
          l.blendMode = .destinationOut
          l.stroke(
            KnotMath.path(o.gap), with: erase,
            style: StrokeStyle(lineWidth: b - 2 * w, lineCap: .butt, lineJoin: .miter))
          l.blendMode = .normal
          if n == 3 {
            l.stroke(
              d, with: shade, style: StrokeStyle(lineWidth: w, lineCap: .butt, lineJoin: .miter))
          }
        }
      }
    }
  }

  /// Width ÷ height of a form's ink box.
  public static func aspectRatio(_ form: MindloomMarkForm = .large) -> CGFloat {
    MarkPlan.plan(form).aspect
  }
}

/// The mark (the trefoil knot), sized by its ink height.  Colour defaults to the `mark` token.
///
/// `form: nil` picks the form from the rendered size in device pixels (kit.js `ML.formFor`).
public struct MindloomMark: View {
  @Environment(\.displayScale) private var displayScale
  @Environment(\.colorScheme) private var scheme
  let height: CGFloat
  let form: MindloomMarkForm?
  let color: MLColor?
  let fixedColor: Color?

  /// - Parameters: height = ink height in points; form = nil for automatic; color = a token (default `mark`).
  public init(height: CGFloat, form: MindloomMarkForm? = nil, color: MLColor? = nil) {
    self.height = height
    self.form = form
    self.color = color
    self.fixedColor = nil
  }

  /// A mark in a fixed colour (the film, the icon).
  public init(height: CGFloat, form: MindloomMarkForm? = nil, fixedColor: Color) {
    self.height = height
    self.form = form
    self.color = nil
    self.fixedColor = fixedColor
  }

  /// The form this mark draws at the current display scale.
  public var resolvedForm: MindloomMarkForm {
    form ?? .automatic(points: height, displayScale: displayScale)
  }

  public var body: some View {
    let f = resolvedForm
    let ink = fixedColor ?? (color ?? .mark).color(for: scheme)
    Canvas { ctx, size in
      MindloomMarkPainter.draw(f, in: &ctx, rect: CGRect(origin: .zero, size: size), color: ink)
    }
    .frame(width: height * MarkPlan.plan(f).aspect, height: height)
    .accessibilityElement()
    .accessibilityLabel("Mindloom")
    .accessibilityAddTraits(.isImage)
  }
}

/// The mark as a `Shape` (one filled outline, built with path Booleans), for template images (the menu bar), masks
/// and anywhere a `Shape` is needed.  Same construction as `MindloomMark`; fits the rect's height, centred.
public struct MindloomMarkShape: Shape {
  public var form: MindloomMarkForm

  public init(form: MindloomMarkForm = .glyph) { self.form = form }

  public func path(in rect: CGRect) -> Path {
    let base = MarkOutline.outline(form)
    let vb = MarkPlan.plan(form).viewBox
    let s = min(rect.height / vb.height, rect.width / vb.width)
    let ox = rect.midX - vb.midX * s
    let oy = rect.midY - vb.midY * s
    return base.applying(CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: ox, ty: oy))
  }

  public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
    let a = MarkPlan.plan(form).aspect
    if let h = proposal.height, h.isFinite { return CGSize(width: h * a, height: h) }
    if let w = proposal.width, w.isFinite { return CGSize(width: w, height: w / a) }
    return CGSize(width: 24 * a, height: 24)
  }
}

/// Filled outlines of each form (path Booleans of the same strokes the painter draws), cached.
enum MarkOutline {
  static let large = make(.large)
  static let medium = make(.medium)
  static let small = make(.small)
  static let glyph = make(.glyph)

  static func outline(_ form: MindloomMarkForm) -> Path {
    switch form {
    case .large: large
    case .medium: medium
    case .small: small
    case .glyph: glyph
    }
  }

  static func make(_ form: MindloomMarkForm) -> Path {
    let plan = MarkPlan.plan(form)
    let b = form.band
    let g = form.channel
    let n = form.strands
    let w = form.strandWidth
    let full = KnotMath.path(plan.full, closed: true).cgPath
    func stroke(_ p: CGPath, _ width: Double, join: CGLineJoin) -> CGPath {
      p.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: join, miterLimit: 10).normalized()
    }
    func strands(_ band: CGPath, gap: CGPath, join: CGLineJoin) -> CGPath {
      var a = stroke(band, b, join: join)
      if n >= 2 {
        a = a.subtracting(stroke(gap, b - 2 * w, join: join))
        if n == 3 { a = a.union(stroke(band, w, join: join)) }
      }
      return a
    }
    var a = strands(full, gap: full, join: .round)
    for ch in plan.channels {
      a = a.subtracting(stroke(KnotMath.path(ch).cgPath, b + 2 * g, join: .round))
    }
    for o in plan.overs {
      a = a.union(
        strands(KnotMath.path(o.band).cgPath, gap: KnotMath.path(o.gap).cgPath, join: .miter))
    }
    return Path(a)
  }
}
