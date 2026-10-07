import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// App icon A (藍): a paper ground and the indigo knot (S4 三线结), as brand/src/icons.py draws it.
///
/// - iOS: a full-bleed 1024 square (the system masks it); form L, the knot's centreline box 490 of 1000 tile units
///   (ink ≈ 61 % of the tile).  Light: paper #FBF9F4 → #ECE7DC, ink #23407D.  Dark: #1F2645 → #0E1226, ink #C9D6F2.
///   Tinted: #1A1A1A → black, ink #F2F2F2.
/// - Mac: the macOS 26 grid: an 824 squircle tile inset 100 on a 1024 canvas, a soft two-layer shadow, a light rim;
///   form by slot size (1024–256 L, 128–64 M, 32–16 S).
public struct MindloomAppIcon: View {
  public enum Platform: String, Sendable, CaseIterable {
    case ios
    case mac
  }

  public enum Appearance: String, Sendable, CaseIterable {
    case light
    case dark
    /// iOS tinted (luminance on black).
    case tinted
  }

  let platform: Platform
  let appearance: Appearance
  let side: CGFloat
  let form: MindloomMarkForm?

  /// - Parameters: side = the canvas side in points (1024 for the master); form nil = by slot size.
  public init(
    platform: Platform = .ios, appearance: Appearance = .light, side: CGFloat = 1024,
    form: MindloomMarkForm? = nil
  ) {
    self.platform = platform
    self.appearance = appearance
    self.side = side
    self.form = form
  }

  struct Palette {
    let ink: MLRGBA
    let top: MLRGBA
    let bottom: MLRGBA
  }

  var palette: Palette {
    switch appearance {
    case .light:
      Palette(ink: MLRGBA(hex: 0x23407D), top: MLRGBA(hex: 0xFBF9F4), bottom: MLRGBA(hex: 0xECE7DC))
    case .dark:
      Palette(ink: MLRGBA(hex: 0xC9D6F2), top: MLRGBA(hex: 0x1F2645), bottom: MLRGBA(hex: 0x0E1226))
    case .tinted:
      Palette(ink: MLRGBA(hex: 0xF2F2F2), top: MLRGBA(hex: 0x1A1A1A), bottom: MLRGBA(hex: 0x000000))
    }
  }

  /// icons.py SLOT_FORM: which form each pixel size uses.
  public static func form(forPixels px: CGFloat) -> MindloomMarkForm {
    px >= 256 ? .large : px >= 64 ? .medium : .small
  }

  public var body: some View {
    let u = side / 1024
    let p = palette
    let markForm = form ?? (platform == .ios ? .large : Self.form(forPixels: side))
    ZStack {
      switch platform {
      case .ios:
        Rectangle().fill(
          LinearGradient(
            colors: [p.top.color, p.bottom.color], startPoint: .top, endPoint: .bottom))
        Canvas { ctx, _ in
          MindloomMarkPainter.draw(
            markForm, in: &ctx, centre: CGPoint(x: 512 * u, y: 512 * u), scale: 1.024 * u,
            color: p.ink.color)
        }
      case .mac:
        let tile = SquircleTile()
        let dark = appearance != .light
        // shadow: blur 14 / dy 12 at 26 %, blur 3 / dy 3 at 22 % (SourceAlpha, so black)
        tile.fill(p.bottom.color)
          .shadow(color: .black.opacity(0.26), radius: 14 * u, x: 0, y: 12 * u)
          .shadow(color: .black.opacity(0.22), radius: 3 * u, x: 0, y: 3 * u)
        tile.fill(
          LinearGradient(
            stops: [
              .init(color: p.top.color, location: 100 / 1024),
              .init(color: p.bottom.color, location: 924 / 1024),
            ],
            startPoint: .top, endPoint: .bottom))
        Canvas { ctx, _ in
          MindloomMarkPainter.draw(
            markForm, in: &ctx, centre: CGPoint(x: 512 * u, y: 512 * u), scale: 0.824 * u,
            color: p.ink.color)
        }
        .clipShape(tile)
        tile.stroke(
          LinearGradient(
            stops: [
              .init(color: .white.opacity(dark ? 0.30 : 0.85), location: 100 / 1024),
              .init(color: .white.opacity(0), location: (100 + 0.25 * 824) / 1024),
              .init(color: .white.opacity(0), location: (100 + 0.85 * 824) / 1024),
              .init(color: .white.opacity(dark ? 0.10 : 0.35), location: 924 / 1024),
            ], startPoint: .top, endPoint: .bottom), lineWidth: 5 * u
        )
        .clipShape(tile)
        tile.stroke(Color.black.opacity(dark ? 0.28 : 0.10), lineWidth: 1.5 * u)
      }
    }
    .frame(width: side, height: side)
    .accessibilityElement()
    .accessibilityLabel("Mindloom")
  }

  /// A PNG of the icon at `pixels` × `pixels` (default 1024): sRGB, opaque for iOS, transparent around the Mac tile.
  @MainActor
  public static func pngData(
    platform: Platform = .ios, appearance: Appearance = .light, pixels: Int = 1024
  ) -> Data? {
    let renderer = ImageRenderer(
      content: MindloomAppIcon(platform: platform, appearance: appearance, side: CGFloat(pixels))
        .environment(\.colorScheme, appearance == .light ? .light : .dark))
    renderer.scale = 1
    renderer.isOpaque = platform == .ios
    guard let image = renderer.cgImage else { return nil }
    return pngData(image)
  }

  /// PNG encoding of a CGImage (ImageIO).
  public static func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard
      let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
  }
}

/// The macOS 26 icon tile: a squircle 824 wide at (100, 100) on a 1024 canvas, corner 185.4, smoothing 0.6
/// (brand/src/knot.py `squircle`), scaled to the rect.
public struct SquircleTile: Shape {
  public init() {}

  public func path(in rect: CGRect) -> Path {
    let s = min(rect.width, rect.height) / 1024
    let p = Self.unit.applying(
      CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: rect.midX - 512 * s, ty: rect.midY - 512 * s))
    return p
  }

  /// The tile in 1024 units.
  static let unit: Path = squircle(x: 100, y: 100, w: 824, h: 824, r: 185.4)

  /// Port of knot.py `squircle` (relative cubic and arc commands, arcs turned into one cubic each).
  static func squircle(x: Double, y: Double, w: Double, h: Double, r: Double, s: Double = 0.6)
    -> Path
  {
    let rad = Double.pi / 180
    let p = min((1 + s) * r, w / 2)
    let am = 90 * (1 - s)
    let al = sin(am / 2 * rad) * r * 2.0.squareRoot()
    let p34 = r * tan((90 - am) / 4 * rad)
    let beta = 45 * s
    let c = p34 * cos(beta * rad)
    let d = c * tan(beta * rad)
    let b = (p - al - c - d) / 3
    let a = 2 * b
    var path = Path()
    var cur = CGPoint(x: x + w - p, y: y)
    path.move(to: cur)
    func curve(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ dx: Double, _ dy: Double) {
      let end = CGPoint(x: cur.x + dx, y: cur.y + dy)
      path.addCurve(
        to: end, control1: CGPoint(x: cur.x + x1, y: cur.y + y1),
        control2: CGPoint(x: cur.x + x2, y: cur.y + y2))
      cur = end
    }
    func arc(_ dx: Double, _ dy: Double) {
      // SVG "a r r 0 0 1 dx dy": small arc, sweep 1 (clockwise on screen)
      let end = CGPoint(x: cur.x + dx, y: cur.y + dy)
      let x1p = (cur.x - end.x) / 2
      let y1p = (cur.y - end.y) / 2
      let rr = r * r
      let q = x1p * x1p + y1p * y1p
      let k = (max(0, rr - q) / q).squareRoot()  // large-arc 0 != sweep 1 → sign +
      let cxp = k * y1p
      let cyp = k * -x1p
      let centre = CGPoint(x: cxp + (cur.x + end.x) / 2, y: cyp + (cur.y + end.y) / 2)
      let t1 = atan2(cur.y - centre.y, cur.x - centre.x)
      var t2 = atan2(end.y - centre.y, end.x - centre.x)
      while t2 < t1 { t2 += 2 * .pi }
      let kk = 4.0 / 3.0 * tan((t2 - t1) / 4) * r
      path.addCurve(
        to: end, control1: CGPoint(x: cur.x - kk * sin(t1), y: cur.y + kk * cos(t1)),
        control2: CGPoint(x: end.x + kk * sin(t2), y: end.y - kk * cos(t2)))
      cur = end
    }
    func line(_ px: Double, _ py: Double) {
      cur = CGPoint(x: px, y: py)
      path.addLine(to: cur)
    }
    curve(a, 0, a + b, 0, a + b + c, d)
    arc(al, al)
    curve(d, c, d, b + c, d, a + b + c)
    line(x + w, y + h - p)
    curve(0, a, 0, a + b, -d, a + b + c)
    arc(-al, al)
    curve(-c, d, -(b + c), d, -(a + b + c), d)
    line(x + p, y + h)
    curve(-a, 0, -(a + b), 0, -(a + b + c), -d)
    arc(-al, -al)
    curve(-d, -c, -d, -(b + c), -d, -(a + b + c))
    line(x, y + p)
    curve(0, -a, 0, -(a + b), d, -(a + b + c))
    arc(al, -al)
    curve(c, -d, b + c, -d, a + b + c, -d)
    path.closeSubpath()
    return path
  }
}
