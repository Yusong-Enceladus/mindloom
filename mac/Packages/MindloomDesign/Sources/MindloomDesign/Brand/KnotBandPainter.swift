import SwiftUI

/// Draws a closed knot band from arbitrary points (px) with the mark's construction (kit.js `ML.mark`), so a moving or
/// growing mark (the title's cinch, Welcome) uses exactly the same over/under as the still mark.
///
/// The band is B wide with `strands` strands; `strandWidth` may differ from the form's (the cinch grows the strands
/// from hairlines at the band's edges inwards, so the band's outer edges and the strand pitch stay put).
enum KnotBandPainter {
  static func draw(
    points pts: [CGPoint], depth z: [Double], band b: Double, channel g: Double, strands n: Int,
    strandWidth w: Double,
    color: Color, in c: inout GraphicsContext
  ) {
    guard pts.count > 4 else { return }
    let count = pts.count - 1
    var length = 0.0
    for i in 0..<count { length += hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y) }
    let ds = length / Double(count)
    let shade = GraphicsContext.Shading.color(color)
    let erase = GraphicsContext.Shading.color(.black)
    let full = KnotMath.path(Array(pts.dropLast()), closed: true)
    let gapWidth = max(0, b - 2 * w)
    var channels: [Path] = []
    var overs: [(Path, Path)] = []
    for cr in KnotMath.crossings(pts, closed: true) {
      let si = KnotMath.overIndex(cr, depth: z)
      let sn = max(cr.sin, 0.25)
      let cot = (1 - sn * sn).squareRoot() / sn
      let r = ((b / 2 + g) * cot + b / 2 / sn) * 1.12 + 0.04 * b
      channels.append(
        KnotMath.path(KnotMath.window(pts, closed: true, at: si, halfLength: r, ds: ds)))
      overs.append(
        (
          KnotMath.path(
            KnotMath.window(pts, closed: true, at: si, halfLength: r + 0.3 * b, ds: ds)),
          KnotMath.path(
            KnotMath.window(pts, closed: true, at: si, halfLength: r + 0.3 * b + 2 * ds, ds: ds))
        ))
    }
    c.drawLayer { l in
      l.stroke(
        full, with: shade, style: StrokeStyle(lineWidth: b, lineCap: .butt, lineJoin: .round))
      if n >= 2 && gapWidth > 0.01 {
        l.blendMode = .destinationOut
        l.stroke(
          full, with: erase,
          style: StrokeStyle(lineWidth: gapWidth, lineCap: .butt, lineJoin: .round))
        l.blendMode = .normal
        if n == 3 {
          l.stroke(
            full, with: shade, style: StrokeStyle(lineWidth: w, lineCap: .butt, lineJoin: .round))
        }
      }
      l.blendMode = .destinationOut
      for ch in channels {
        l.stroke(
          ch, with: erase,
          style: StrokeStyle(lineWidth: b + 2 * g, lineCap: .butt, lineJoin: .round))
      }
    }
    c.drawLayer { l in
      for (d, gap) in overs {
        l.blendMode = .normal
        l.stroke(d, with: shade, style: StrokeStyle(lineWidth: b, lineCap: .butt, lineJoin: .miter))
        if n >= 2 && gapWidth > 0.01 {
          l.blendMode = .destinationOut
          l.stroke(
            gap, with: erase,
            style: StrokeStyle(lineWidth: gapWidth, lineCap: .butt, lineJoin: .miter))
          l.blendMode = .normal
          if n == 3 {
            l.stroke(
              d, with: shade, style: StrokeStyle(lineWidth: w, lineCap: .butt, lineJoin: .miter))
          }
        }
      }
    }
  }
}
