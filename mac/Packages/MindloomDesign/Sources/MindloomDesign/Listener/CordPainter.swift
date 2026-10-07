import SwiftUI

/// Draws a cord (open or closed polyline) with over/under channels (kit.js `ML.drawCord`), composed in a layer with
/// `.destinationOut` exactly like the canvas version: the band, then at each crossing a channel erased along the band on
/// top and that band redrawn 0.6 B longer.  Depth decides which band is on top, so the order never flips.
public enum CordPainter {
  /// Strands inside the band (forms M and L): n strands of width w with gaps `gap`.
  public struct Strands: Hashable, Sendable {
    public var count: Int
    public var width: Double
    public var gap: Double
    public init(count: Int, width: Double, gap: Double) {
      self.count = count
      self.width = width
      self.gap = gap
    }
  }

  /// Paints one listener frame's geometry.
  public static func draw(
    _ geo: ListenerGeometry, color: Color, opacity: Double = 1, useEnds: Bool = true,
    in context: inout GraphicsContext
  ) {
    draw(
      points: geo.points, depth: geo.depth, band: geo.band, channel: geo.channel,
      closed: geo.closed, color: color,
      ends: useEnds ? geo.ends : nil, strands: nil, opacity: opacity, in: &context)
  }

  public static func draw(
    points pts: [CGPoint], depth z: [Double], band b: Double, channel g: Double, closed: Bool,
    color: Color,
    ends: CordEnds?, strands: Strands?, opacity: Double = 1, in context: inout GraphicsContext
  ) {
    guard opacity > 0.003, pts.count >= 2 else { return }
    let st = (strands?.gap ?? 0) > 0.02 ? strands : nil
    let shade = GraphicsContext.Shading.color(color)
    let erase = GraphicsContext.Shading.color(.black)
    let n = pts.count - 1
    var total = 0.0
    for i in 0..<n { total += hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y) }
    let ds = total / Double(n)
    var c = context
    c.opacity = opacity
    c.drawLayer { l in
      // the band along a path, split into strands when asked (gaps erased, then the centre strand)
      func band(_ path: Path, _ width: Double, cap: CGLineCap) {
        l.blendMode = .normal
        l.stroke(
          path, with: shade, style: StrokeStyle(lineWidth: width, lineCap: cap, lineJoin: .round))
        guard let st else { return }
        l.blendMode = .destinationOut
        l.stroke(
          path, with: erase,
          style: StrokeStyle(
            lineWidth: st.count == 3 ? st.width + 2 * st.gap : st.gap, lineCap: cap,
            lineJoin: .round))
        l.blendMode = .normal
        if st.count == 3 {
          l.stroke(
            path, with: shade,
            style: StrokeStyle(lineWidth: st.width, lineCap: cap, lineJoin: .round))
        }
      }
      band(KnotMath.path(closed ? Array(pts.dropLast()) : pts, closed: closed), b, cap: .round)
      // crossings
      if g >= 0.04 * b {
        for cr in KnotMath.crossings(pts, closed: closed) where cr.sin >= 0.22 {
          let si = KnotMath.overIndex(cr, depth: z)
          let sn = cr.sin
          let cot = (1 - sn * sn).squareRoot() / sn
          let r = ((b / 2 + g) * cot + b / 2 / sn) * 1.12 + 0.04 * b
          l.blendMode = .destinationOut
          l.stroke(
            KnotMath.path(KnotMath.window(pts, closed: closed, at: si, halfLength: r, ds: ds)),
            with: erase,
            style: StrokeStyle(lineWidth: b + 2 * g, lineCap: .butt, lineJoin: .round))
          let wo = r + 0.6 * b
          l.blendMode = .normal
          l.stroke(
            KnotMath.path(KnotMath.window(pts, closed: closed, at: si, halfLength: wo, ds: ds)),
            with: shade,
            style: StrokeStyle(lineWidth: b, lineCap: .butt, lineJoin: .round))
          if let st {
            // gaps erased a little past the redrawn band, the centre strand redrawn a little past that: no seams
            let d1 = max(2 * ds, 0.15 * b)
            l.blendMode = .destinationOut
            l.stroke(
              KnotMath.path(
                KnotMath.window(pts, closed: closed, at: si, halfLength: wo + d1, ds: ds)),
              with: erase,
              style: StrokeStyle(
                lineWidth: st.count == 3 ? st.width + 2 * st.gap : st.gap, lineCap: .butt,
                lineJoin: .round))
            l.blendMode = .normal
            if st.count == 3 {
              l.stroke(
                KnotMath.path(
                  KnotMath.window(pts, closed: closed, at: si, halfLength: wo + 2 * d1, ds: ds)),
                with: shade,
                style: StrokeStyle(lineWidth: st.width, lineCap: .butt, lineJoin: .round))
            }
          }
        }
      }
      // soft ends of an open cord: erased in a thin band around the line only, so the knot is never touched
      if !closed, let e = ends {
        let span = e.x1 - e.x0
        let ff = ListenerConstants.fadeFraction
        if span > 1 && (e.left > 0.001 || e.right > 0.001) {
          let gradient = Gradient(stops: [
            .init(color: .black.opacity(e.left), location: 0),
            .init(color: .black.opacity(0), location: ff),
            .init(color: .black.opacity(0), location: 1 - ff),
            .init(color: .black.opacity(e.right), location: 1),
          ])
          let hh = b + 3
          l.blendMode = .destinationOut
          l.fill(
            Path(CGRect(x: e.x0 - 3 * b, y: e.y - hh, width: span + 6 * b, height: 2 * hh)),
            with: .linearGradient(
              gradient, startPoint: CGPoint(x: e.x0 - b / 2, y: 0),
              endPoint: CGPoint(x: e.x1 + b / 2, y: 0)))
        }
      }
    }
  }
}
