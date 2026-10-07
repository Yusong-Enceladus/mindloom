import Foundation
import SwiftUI

/// The brand trefoil's centreline (kit.js `knotGeo`), in knot units.
///
/// `x = sin t + k sin 2t`, `y = −(cos t − k cos 2t)` (screen, y down), `k = 2.15`, `t ∈ [−π, π]`, fitted so the
/// centreline's larger side is 490 units (the 1000-unit icon tile), centred on its bounding box, and resampled to N
/// points of equal arc length.  It is cut at the bottom lobe tip (`t = ±π`), so sample 0 and sample N are the tip and
/// sample N/2 is `t = 0`.  Depth `z = sin 3t` gives icon A's over/under at every crossing.
public struct KnotGeometry: Sendable {
  public static let k: Double = 2.15
  /// Larger side of the centreline's bounding box, in knot units.
  public static let size: Double = 490

  /// Number of segments (N); `points` has N + 1 entries and the last equals the first.
  public let count: Int
  public let points: [CGPoint]
  /// Curve parameter of each sample.
  public let parameters: [Double]
  /// Depth of each sample (`sin 3t`): the higher one is on top at a crossing.
  public let depth: [Double]
  /// Arc length of the closed centreline.
  public let length: Double
  /// Bounding box of the samples (excluding the band).
  public let bounds: CGRect
  /// Arc-length centroid of the centreline (kit.js `knotCentres().mid`).
  public let arcCentroid: CGPoint

  /// Spacing between samples.
  public var ds: Double { length / Double(count) }
  /// Centre of the bounding box (kit.js `knotCentres().box`).
  public var boxCentre: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

  /// 720 samples: the mark, the icon and the title (kit.js `ML.mark`, knot.ts).
  public static let n720 = KnotGeometry(count: 720)
  /// 360 samples: the listening animation (kit.js `Listener` default).
  public static let n360 = KnotGeometry(count: 360)

  public init(count n: Int) {
    let m = 12000
    var raw: [CGPoint] = []
    var ts: [Double] = []
    raw.reserveCapacity(m + 1)
    ts.reserveCapacity(m + 1)
    for i in 0...m {
      let t = -Double.pi + 2 * Double.pi * Double(i) / Double(m)
      raw.append(
        CGPoint(x: sin(t) + Self.k * sin(2 * t), y: -(cos(t) - Self.k * cos(2 * t))))
      ts.append(t)
    }
    var x0 = Double.infinity
    var x1 = -Double.infinity
    var y0 = Double.infinity
    var y1 = -Double.infinity
    for p in raw {
      x0 = min(x0, p.x)
      x1 = max(x1, p.x)
      y0 = min(y0, p.y)
      y1 = max(y1, p.y)
    }
    let sc = Self.size / max(x1 - x0, y1 - y0)
    let mx = (x0 + x1) / 2
    let my = (y0 + y1) / 2
    let pts = raw.map { CGPoint(x: ($0.x - mx) * sc, y: ($0.y - my) * sc) }
    var s: [Double] = [0]
    s.reserveCapacity(pts.count)
    for i in 1..<pts.count {
      s.append(s[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))
    }
    let total = s[s.count - 1]
    var p: [CGPoint] = []
    var tt: [Double] = []
    var j = 0
    for i in 0...n {
      let si = total * Double(i) / Double(n)
      while j < s.count - 2 && s[j + 1] < si { j += 1 }
      let d = s[j + 1] - s[j]
      let u = (si - s[j]) / (d == 0 ? 1 : d)
      p.append(MLMath.mix(pts[j], pts[j + 1], u))
      tt.append(MLMath.mix(ts[j], ts[j + 1], u))
    }
    p[n] = p[0]
    count = n
    points = p
    parameters = tt
    depth = tt.map { sin(3 * $0) }
    length = total
    // centres (kit.js knotCentres): box over P[0..<N], arc centroid over the N segments
    var bx0 = Double.infinity
    var bx1 = -Double.infinity
    var by0 = Double.infinity
    var by1 = -Double.infinity
    var sx = 0.0
    var sy = 0.0
    var sl = 0.0
    for i in 0..<n {
      let a = p[i]
      let b = p[i + 1]
      let l = hypot(b.x - a.x, b.y - a.y)
      sx += (a.x + b.x) / 2 * l
      sy += (a.y + b.y) / 2 * l
      sl += l
      bx0 = min(bx0, a.x)
      bx1 = max(bx1, a.x)
      by0 = min(by0, a.y)
      by1 = max(by1, a.y)
    }
    bounds = CGRect(x: bx0, y: by0, width: bx1 - bx0, height: by1 - by0)
    arcCentroid = CGPoint(x: sx / sl, y: sy / sl)
  }
}

/// A self-crossing of a polyline: segments i < j, the fractions a, b along them, the point, and |sin| of the angle.
struct KnotCrossing: Sendable {
  var i: Int
  var j: Int
  var a: Double
  var b: Double
  var point: CGPoint
  var sin: Double
}

enum KnotMath {
  /// Every self-crossing of a polyline (kit.js `crossings`), sorted by (i, j) so drawing order is stable.
  static func crossings(_ pts: [CGPoint], closed: Bool) -> [KnotCrossing] {
    let n = pts.count - 1
    guard n > 3 else { return [] }
    var minx = Double.infinity
    var miny = Double.infinity
    var maxx = -Double.infinity
    var maxy = -Double.infinity
    for p in pts {
      minx = min(minx, p.x)
      maxx = max(maxx, p.x)
      miny = min(miny, p.y)
      maxy = max(maxy, p.y)
    }
    var cell = max(maxx - minx, maxy - miny) / 24
    if cell == 0 || !cell.isFinite { cell = 1 }
    var grid: [Int: [Int]] = [:]
    for i in 0..<n {
      let a = pts[i]
      let b = pts[i + 1]
      let gx0 = Int(floor((min(a.x, b.x) - minx) / cell))
      let gx1 = Int(floor((max(a.x, b.x) - minx) / cell))
      let gy0 = Int(floor((min(a.y, b.y) - miny) / cell))
      let gy1 = Int(floor((max(a.y, b.y) - miny) / cell))
      for gx in gx0...gx1 { for gy in gy0...gy1 { grid[gx * 4096 + gy, default: []].append(i) } }
    }
    var seen = Set<Int>()
    var out: [KnotCrossing] = []
    for segs in grid.values {
      for p in 0..<segs.count {
        for q in (p + 1)..<max(p + 1, segs.count) {
          var i = segs[p]
          var j = segs[q]
          if i > j { swap(&i, &j) }
          if j - i < 3 || (closed && i + n - j < 3) { continue }
          let key = i * 100000 + j
          if seen.contains(key) { continue }
          seen.insert(key)
          let (x1, y1, x2, y2) = (pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y)
          let (x3, y3, x4, y4) = (pts[j].x, pts[j].y, pts[j + 1].x, pts[j + 1].y)
          let den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
          if abs(den) < 1e-12 { continue }
          let a = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / den
          let b = -((x1 - x2) * (y1 - y3) - (y1 - y2) * (x1 - x3)) / den
          if a < 0 || a >= 1 || b < 0 || b >= 1 { continue }
          let ax = x2 - x1
          let ay = y2 - y1
          let bx = x4 - x3
          let by = y4 - y3
          let l = hypot(ax, ay) * hypot(bx, by)
          let sn = abs(ax * by - ay * bx) / (l == 0 ? 1 : l)
          out.append(
            KnotCrossing(
              i: i, j: j, a: a, b: b, point: CGPoint(x: x1 + ax * a, y: y1 + ay * a), sin: sn))
        }
      }
    }
    return out.sorted { $0.i != $1.i ? $0.i < $1.i : $0.j < $1.j }
  }

  /// The samples within half-length R (arc units) of fractional index si (kit.js `windowPts`).
  static func window(
    _ pts: [CGPoint], closed: Bool, at si: Double, halfLength r: Double, ds: Double
  ) -> [CGPoint] {
    let n = pts.count - 1
    let k = Int(ceil(r / ds))
    var out: [CGPoint] = []
    let lo = Int(floor(si)) - k
    let hi = Int(ceil(si)) + k
    guard lo <= hi else { return out }
    for q in lo...hi {
      if closed {
        out.append(pts[((q % n) + n) % n])
      } else if q >= 0 && q <= n {
        out.append(pts[q])
      }
    }
    return out
  }

  /// The depth-ordered over position of a crossing (fractional sample index of the band on top).
  static func overIndex(_ c: KnotCrossing, depth z: [Double]) -> Double {
    let zi = MLMath.mix(z[c.i], z[c.i + 1], c.a)
    let zj = MLMath.mix(z[c.j], z[c.j + 1], c.b)
    return zi > zj ? Double(c.i) + c.a : Double(c.j) + c.b
  }

  /// A polyline path.
  static func path(_ pts: [CGPoint], closed: Bool = false) -> Path {
    var p = Path()
    guard let first = pts.first else { return p }
    p.move(to: first)
    for q in pts.dropFirst() { p.addLine(to: q) }
    if closed { p.closeSubpath() }
    return p
  }
}
