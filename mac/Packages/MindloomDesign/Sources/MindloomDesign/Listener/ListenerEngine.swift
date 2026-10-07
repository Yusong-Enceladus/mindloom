import Foundation
import SwiftUI

/// The listening animation's constants (kit.js `ML.listen`, SYSTEM.md §10).
public enum ListenerConstants {
  /// Stage 1 length (s).
  public static let pressDuration = 0.12
  /// Spring response of the lift / grow (stage 2) and the landing (stage 5), damping 1.
  public static let liftResponse = 0.42
  /// After the press ends (s): the lift is well under way.
  public static let untieDelay = 0.1
  /// λ 1 → 0 on ease-in-out: the cord is drawn out of the knot (s).
  public static let untieDuration = 0.7
  /// After release, while the arch settles (s).
  public static let tieDelay = 0.14
  /// λ → 1 on ease-in-out: drawn back in (s).
  public static let tieDuration = 0.62
  /// After release (s).
  public static let landDelay = 0.7
  /// ℓ = clamp((dBFS − gate) / span).
  public static let gateDB = -50.0
  public static let spanDB = 34.0
  /// Envelope follower time constants (s).
  public static let attack = 0.08
  public static let release = 0.5
  /// Critically damped display spring on the envelope (natural frequency, Hz).
  public static let springHz = 0.9
  /// Peak rise at full level, as a fraction of the cord length: one arch, pinned ends, never below the line.
  public static let archFraction = 0.04
  /// Breathing while silent, as a fraction of the full arch, and its rate (Hz).
  public static let idleAmplitude = 0.1
  public static let idleHz = 0.2
  /// Each free end of the line fades over this fraction of its length.
  public static let fadeFraction = 0.08

  /// dBFS (RMS) → level ℓ in 0…1 (kit.js `ML.levelFromDb`).
  public static func level(fromDBFS db: Double) -> Double { MLMath.clamp((db - gateDB) / spanDB) }
}

/// The five stages (and the in-betweens kit.js reports).
public enum ListenerPhase: String, Sendable, CaseIterable {
  case idle
  /// 1 按住: the key takes the press, the mark dips to 0.94.
  case press
  /// 2 松开: the mark lifts, the cord is drawn out of its bottom tip along its own path.
  case loosen
  /// 3 在听: one line, one low arch with the smoothed level.
  case listen
  /// 4 收拢: the arch settles, the cord is drawn back in along the same path.
  case gather
  /// 4→5: the tied mark lands.
  case land
  /// 5 收好: the mark has landed (before 「已收好」).
  case saved
}

/// Where the animation happens, in the coordinates of the view that draws it.
public struct ListenerLayout: Hashable, Sendable {
  /// Size of the drawing surface (the view's frame).
  public var canvasSize: CGSize
  /// Where the mark rests (the bar or key glyph): centre, ink height and band width.
  public var rest: CGPoint
  public var restHeight: CGFloat
  public var restBand: CGFloat
  /// Where it lands after saving, if not back at rest (e.g. before 「已收好」).
  public var landAt: CGPoint?
  /// Where it unties (the panel centre); tied size and band there.
  public var centre: CGPoint
  public var knotHeight: CGFloat
  public var knotBand: CGFloat
  /// The straight cord: length and width.
  public var cordLength: CGFloat
  public var lineWidth: CGFloat
  /// Samples along the knot.
  public var samples: Int

  public init(
    canvasSize: CGSize, rest: CGPoint, restHeight: CGFloat = 18, restBand: CGFloat = 2.46,
    landAt: CGPoint? = nil,
    centre: CGPoint, knotHeight: CGFloat = 56, knotBand: CGFloat = 4.2, cordLength: CGFloat = 240,
    lineWidth: CGFloat = 3, samples: Int = 360
  ) {
    self.canvasSize = canvasSize
    self.rest = rest
    self.restHeight = restHeight
    self.restBand = restBand
    self.landAt = landAt
    self.centre = centre
    self.knotHeight = knotHeight
    self.knotBand = knotBand
    self.cordLength = cordLength
    self.lineWidth = lineWidth
    self.samples = samples
  }

  /// The iPhone keyboard extension (SYSTEM.md §10.4): rest = the speak key's glyph (18 pt T form, band 2.46),
  /// tied 52 pt (band 3.8) at (width / 2, 106), cord 236 × 2.6 pt.  `landAt` = the glyph before 「已收好」.
  public static func phoneKeyboard(
    width: CGFloat = 402, height: CGFloat = 210, rest: CGPoint, landAt: CGPoint? = nil
  )
    -> ListenerLayout
  {
    ListenerLayout(
      canvasSize: CGSize(width: width, height: height), rest: rest, restHeight: 18, restBand: 2.46,
      landAt: landAt,
      centre: CGPoint(x: width / 2, y: 106), knotHeight: 52, knotBand: 3.8, cordLength: 236,
      lineWidth: 2.6)
  }

  /// The in-app note on the phone: rest = the speak bar's glyph (20 pt, band 2.6), tied 52 pt at
  /// (width / 2, height − 330), cord 236 × 2.6 pt.
  public static func phoneNote(size: CGSize, rest: CGPoint, landAt: CGPoint? = nil)
    -> ListenerLayout
  {
    ListenerLayout(
      canvasSize: size, rest: rest, restHeight: 20, restBand: 2.6, landAt: landAt,
      centre: CGPoint(x: size.width / 2, y: size.height - 330), knotHeight: 52, knotBand: 3.8,
      cordLength: 236,
      lineWidth: 2.6)
  }

  /// The Mac Fn HUD: 17 pt mark (band 2.3) that stays 17 pt, a 116 × 2.2 pt cord, centred in a canvas that holds the
  /// widest capsule (116 + 44 pt) with room for its shadow.
  public static func macHUD(size: CGSize = CGSize(width: 220, height: 80)) -> ListenerLayout {
    let c = CGPoint(x: size.width / 2, y: size.height / 2)
    return ListenerLayout(
      canvasSize: size, rest: c, restHeight: 17, restBand: 2.3, centre: c, knotHeight: 17,
      knotBand: 2.3,
      cordLength: 116, lineWidth: 2.2)
  }
}

/// The animation state at one moment, as plain numbers (kit.js `Listener.frame`).
public struct ListenerFrame: Hashable, Sendable {
  public var t: Double
  /// Untie progress: 1 = tied, 0 = straight.
  public var lambda: Double = 1
  public var lift: Double = 0
  public var land: Double = 0
  public var dip: Double = 1
  /// Opacity of the keys and labels around (1 = visible).
  public var keys: Double = 1
  /// Arch amplitude 0…1 (after gating).
  public var amp: Double = 0
  public var phase: ListenerPhase = .idle
  /// Opacity of 「已收好」 (starts only once the landing has settled).
  public var saved: Double = 0
  /// Opacity of the listening chrome (the × cancel).
  public var listen: Double = 0
}

/// The cord to draw for one frame: points in canvas coordinates, depth, band and channel widths, end fades.
public struct ListenerGeometry: Sendable {
  public var points: [CGPoint]
  public var depth: [Double]
  public var band: Double
  public var channel: Double
  public var closed: Bool
  public var lambda: Double
  public var length: Double
  /// The extent, symmetric about the centre (a capsule centred there covers all of it).
  public var minX: Double
  public var maxX: Double
  public var centre: CGPoint
  public var ends: CordEnds?
}

/// End fades of the straight run (kit.js `drawCord` `ends`): from x0 to x1 at height y, strengths l and r.
public struct CordEnds: Hashable, Sendable {
  public var x0: Double
  public var x1: Double
  public var y: Double
  public var left: Double
  public var right: Double
}

/// The state machine and filters (kit.js `Listener`), deterministic: fixed 1/240 s substeps.
public struct ListenerEngine: Sendable {
  public var layout: ListenerLayout {
    didSet {
      if layout.samples != oldValue.samples { knot = Self.knotGeometry(samples: layout.samples) }
    }
  }
  private var knot: KnotGeometry
  public private(set) var t: Double = 0
  public private(set) var pressAt: Double?
  public private(set) var releaseAt: Double?
  public private(set) var cancelled = false
  /// Raw level ℓ (set per mic frame), envelope, display amplitude and its velocity.
  public var level: Double = 0
  public private(set) var envelope: Double = 0
  public private(set) var amplitude: Double = 0
  private var velocity: Double = 0

  public init(layout: ListenerLayout) {
    self.layout = layout
    self.knot = Self.knotGeometry(samples: layout.samples)
  }

  static func knotGeometry(samples n: Int) -> KnotGeometry {
    n == 360 ? .n360 : n == 720 ? .n720 : KnotGeometry(count: n)
  }

  public mutating func reset() {
    t = 0
    pressAt = nil
    releaseAt = nil
    cancelled = false
    envelope = 0
    amplitude = 0
    velocity = 0
    level = 0
  }

  public mutating func press(at time: Double) {
    reset()
    pressAt = time
    t = time
  }

  /// A release at least 0.2 s after the press.
  public mutating func release(at time: Double) {
    if let p = pressAt, releaseAt == nil { releaseAt = max(time, p + 0.2) }
  }

  public mutating func cancel(at time: Double) {
    cancelled = true
    release(at: time)
  }

  /// Advance the filters to `time` (fixed 1/240 s substeps).  `levelAt` overrides `level` (synthetic tracks).
  public mutating func advance(to time: Double, levelAt: ((Double) -> Double)? = nil) {
    let dt = 1.0 / 240
    let w = 2 * Double.pi * ListenerConstants.springHz
    while t < time - 1e-9 {
      let h = min(dt, time - t)
      t += h
      let listening: Bool = {
        guard let p = pressAt, t >= p else { return false }
        if let r = releaseAt { return t < r }
        return true
      }()
      let raw = listening ? (levelAt?(t) ?? level) : 0
      let tau = raw > envelope ? ListenerConstants.attack : ListenerConstants.release
      envelope += (raw - envelope) * (1 - exp(-h / tau))
      let acc = w * w * (envelope - amplitude) - 2 * w * velocity
      velocity += acc * h
      amplitude = MLMath.clamp(amplitude + velocity * h)
    }
  }

  /// The animation state at `time` (kit.js `frame`).
  public func frame(at time: Double) -> ListenerFrame {
    typealias K = ListenerConstants
    let ss = MLMotion.springStep
    var f = ListenerFrame(t: time)
    guard let p0 = pressAt, time >= p0 else { return f }
    let tp = time - p0
    f.phase = tp < K.pressDuration ? .press : .loosen
    f.dip = 1 - 0.06 * MLMath.smooth(tp / 0.08) * (1 - MLMath.smooth((tp - K.pressDuration) / 0.14))
    let tl = tp - K.pressDuration
    f.lift = ss(tl, K.liftResponse, 1)
    f.keys = 1 - ss(tl + 0.02, 0.28, 1)
    let inOut = MLMotion.curveInOut
    let released = releaseAt.map { time >= $0 } ?? false
    // the untie stops where it was when the key is let go; the tie continues from there
    let tu = released ? releaseAt! - p0 - K.pressDuration : tl
    let untie = inOut(MLMath.clamp((tu - K.untieDelay) / K.untieDuration))
    f.lambda = 1 - untie
    f.listen = MLMath.smooth((untie - 0.75) / 0.25)
    if untie > 0.97 { f.phase = .listen }
    if released, let r0 = releaseAt {
      let tr = time - r0
      f.phase = .gather
      let tie = inOut(MLMath.clamp((tr - K.tieDelay) / K.tieDuration))
      f.lambda = f.lambda + (1 - f.lambda) * tie
      f.listen *= 1 - MLMath.smooth(tr / 0.18)
      f.land = ss(tr - K.landDelay, K.liftResponse, 1)
      if tr > K.landDelay { f.phase = .land }
      f.keys = max(f.keys, ss(tr - K.landDelay - 0.05, 0.3, 1))
      if f.land > 0.9 { f.phase = cancelled ? .idle : .saved }
      // 已收好 waits until the mark has settled where it lands (~98 % there at +0.38 s)
      f.saved = cancelled ? 0 : ss(tr - K.landDelay - 0.38, 0.25, 1)
    }
    // the arch rises only once the cord is all the way out, and settles first on release
    let straight = MLMath.smooth((1 - f.lambda - 0.85) / 0.15)
    let breath = K.idleAmplitude * (0.6 + 0.4 * sin(2 * Double.pi * K.idleHz * tp))
    let settle = released ? 1 - MLMath.smooth((time - releaseAt!) / 0.22) : 1
    f.amp = straight * max(amplitude, breath) * settle
    return f
  }

  /// The cord partly drawn out of the knot (kit.js `ML.cordPath`), scaled by sc.
  func cordPath(scale sc: Double, lambda lam: Double, lineLength: Double) -> (
    points: [CGPoint], depth: [Double], track: Int, tip: CGPoint, closed: Bool
  ) {
    let g = knot
    let n = g.count
    let p = g.points
    var pts: [CGPoint] = []
    var z: [Double] = []
    if lam > 0.9999 {
      for i in 0...n {
        pts.append(CGPoint(x: p[i].x * sc, y: p[i].y * sc))
        z.append(g.depth[i])
      }
      return (pts, z, n + 1, pts[n], true)
    }
    let a = (1 - lam) * Double(n)
    let i0 = min(n, Int(floor(a)))
    let u = a - Double(i0)
    if i0 < n {
      let q = MLMath.mix(p[i0], p[i0 + 1], u)
      pts.append(CGPoint(x: q.x * sc, y: q.y * sc))
      z.append(MLMath.mix(g.depth[i0], g.depth[i0 + 1], u))
      if i0 + 1 <= n {
        for i in (i0 + 1)...n {
          pts.append(CGPoint(x: p[i].x * sc, y: p[i].y * sc))
          z.append(g.depth[i])
        }
      }
    }
    let track = pts.count
    let tip = CGPoint(x: p[n].x * sc, y: p[n].y * sc)
    // the knot's own spacing (the crossing windows assume it)
    let m = max(1, Int(ceil(lineLength / max(0.2, g.ds * sc))))
    for j in (track > 0 ? 1 : 0)...m {
      pts.append(CGPoint(x: tip.x + lineLength * Double(j) / Double(m), y: tip.y))
      z.append(0)
    }
    return (pts, z, track, tip, false)
  }

  /// Cord points in canvas coordinates for a frame (kit.js `geometry`).
  public func geometry(for f: ListenerFrame, reduced: Bool) -> ListenerGeometry {
    let o = layout
    let g = knot
    let lam = reduced ? (f.lambda > 0.5 ? 1 : 0) : f.lambda
    let lift = reduced ? (f.lift > 0.5 ? 1 : 0) : f.lift
    let land = reduced ? (f.land > 0.5 ? 1 : 0) : f.land
    let to = cancelled ? o.rest : (o.landAt ?? o.rest)  // a cancel goes back where it came from
    let h = MLMath.mix(MLMath.mix(o.restHeight * f.dip, o.knotHeight, lift), o.restHeight, land)
    let bt = MLMath.mix(MLMath.mix(o.restBand, o.knotBand, lift), o.restBand, land)
    let cx0 = MLMath.mix(MLMath.mix(o.rest.x, o.centre.x, lift), to.x, land)
    let cy0 = MLMath.mix(MLMath.mix(o.rest.y, o.centre.y, lift), to.y, land)
    let sc = (h - bt) / g.bounds.height
    let len = (1 - lam) * o.cordLength
    let cp = cordPath(scale: sc, lambda: lam, lineLength: len)
    var q = cp.points
    // centre: the ink's arc-length centroid, eased to the mark's own ink-box centre as it closes
    var sx = 0.0
    var sy = 0.0
    var sl = 0.0
    for i in 1..<q.count {
      let l = hypot(q[i].x - q[i - 1].x, q[i].y - q[i - 1].y)
      sx += (q[i].x + q[i - 1].x) / 2 * l
      sy += (q[i].y + q[i - 1].y) / 2 * l
      sl += l
    }
    let wv = MLMath.smooth(lam)
    let cx = (sl > 0 ? sx / sl : 0) + (g.boxCentre.x - g.arcCentroid.x) * sc * wv
    let cy = (sl > 0 ? sy / sl : 0) + (g.boxCentre.y - g.arcCentroid.y) * sc * wv
    // the voice: one low arch on the straight run, ends pinned (zero height and slope), never below the line
    let amp = reduced ? 0 : ListenerConstants.archFraction * o.cordLength * f.amp
    let tipX = cp.tip.x
    var ex0 = Double.infinity
    var ex1 = -Double.infinity
    for i in 0..<q.count {
      var y = 0.0
      if i >= cp.track - 1 && !cp.closed && len > 0.5 && amp > 0 {
        let u = MLMath.clamp((q[i].x - tipX) / len)
        let s = sin(Double.pi * u)
        y = -amp * s * s
      }
      q[i] = CGPoint(x: q[i].x - cx + cx0, y: q[i].y - cy + cy0 + y)
      ex0 = min(ex0, q[i].x)
      ex1 = max(ex1, q[i].x)
    }
    let b = MLMath.mix(o.lineWidth, bt, MLMath.smooth(lam))
    // the over/under gaps open only on the whole mark: no crossing is cut while a strand runs in or out
    let gOpen = reduced ? 1 : MLMath.smooth((lam - 0.975) / 0.025)
    let hw = max(cx0 - ex0, ex1 - cx0)
    let lx = tipX - cx + cx0
    return ListenerGeometry(
      points: q, depth: cp.depth, band: b, channel: 0.44 * b * gOpen, closed: cp.closed,
      lambda: lam, length: len,
      minX: cx0 - hw, maxX: cx0 + hw, centre: CGPoint(x: cx0, y: cy0),
      ends: cp.closed
        ? nil
        : CordEnds(
          x0: lx, x1: lx + len, y: cp.tip.y - cy + cy0,
          left: MLMath.smooth((1 - lam - 0.96) / 0.04),
          right: MLMath.smooth(len / 50)))
  }

  /// What to paint for a frame: one cord, or (Reduce Motion) the mark and a still line crossfading.
  /// Reduce Motion: no lift, no arch; λ snaps, and while listening the line's opacity (0.55 + 0.45 a) shows the voice.
  public func layers(for f: ListenerFrame, reduced: Bool) -> [(
    geometry: ListenerGeometry, opacity: Double
  )] {
    if !reduced { return [(geometry(for: f, reduced: false), 1)] }
    let k = MLMath.smooth((f.lambda - 0.42) / 0.16)  // 1 = tied
    var still = f
    still.lift = f.land > 0.5 ? 0 : f.lift > 0.5 ? 1 : 0
    still.land = 0
    still.dip = 1
    still.amp = 0
    var tied = still
    tied.lambda = 1
    var line = still
    line.lambda = 0
    let voice = 0.55 + 0.45 * MLMath.clamp(amplitude)
    return [
      (geometry(for: line, reduced: false), (1 - k) * (f.phase == .listen ? voice : 1)),
      (geometry(for: tied, reduced: false), k),
    ]
  }

  /// The Mac Fn HUD (r2): at 17 pt the untie is not legible, so the knot and the straight cord crossfade; the cord
  /// grows from 0.6 to 1 in width as it appears; the capsule hugs the cord (cord + 44).  Returns the layers (with a
  /// horizontal scale about the centre for the line), the capsule width and its presence 0…1.
  public func hudLayers(for f: ListenerFrame, reduced: Bool) -> (
    layers: [(geometry: ListenerGeometry, opacity: Double, scaleX: Double)], capsuleWidth: Double,
    presence: Double
  ) {
    let hudOn: Double = {
      guard let p = pressAt else { return 0 }
      if f.phase == .idle && releaseAt == nil { return 0 }
      return min(MLMotion.springStep(f.t - p, response: 0.3, damping: 1), 1 - f.saved)
    }()
    let k = MLMath.smooth((f.lambda - 0.35) / 0.4)  // 1 = the knot, 0 = the cord
    var still = f
    still.lift = 0
    still.land = 0
    still.dip = 1
    var tied = still
    tied.lambda = 1
    tied.amp = 0
    var line = still
    line.lambda = 0
    if reduced { line.amp = 0 }
    let voice = reduced && f.phase == .listen ? 0.55 + 0.45 * amplitude : 1
    let w = 44 + Double(layout.cordLength) * (1 - k)
    let layers: [(geometry: ListenerGeometry, opacity: Double, scaleX: Double)] = [
      (geometry(for: line, reduced: false), hudOn * pow(1 - k, 1.5) * voice, 0.5 + 0.5 * (1 - k)),
      (geometry(for: tied, reduced: true), hudOn * k, 1),
    ]
    return (layers, w, hudOn)
  }
}

/// Synthetic inputs for demos and tests (kit.js `ML.speechTrack`).
public enum ListenerSynthetic {
  /// Two phrases with syllable bumps and a pause, deterministic.  ℓ(t) in 0…1 for a listening window start…end.
  public static func speechTrack(start: Double = 0.9, end: Double = 3.8, seed: Int = 7)
    -> @Sendable (Double) -> Double
  {
    var s = Double(seed)
    func rnd() -> Double {
      s = (s * 16807).truncatingRemainder(dividingBy: 2_147_483_647)
      return s / 2_147_483_647
    }
    var syl: [(c: Double, d: Double, a: Double)] = []
    func phrase(_ a: Double, _ b: Double, _ n: Int, _ loud: Double) {
      for i in 0..<n {
        let c = a + (b - a) * (Double(i) + 0.5) / Double(n) + (rnd() - 0.5) * 0.04
        let d = 0.11 + rnd() * 0.07
        let amp = loud * (0.55 + rnd() * 0.45)
        syl.append((c, d, amp))
      }
    }
    let span = end - start
    phrase(start + 0.15 * span, start + 0.47 * span, 6, 0.85)
    phrase(start + 0.58 * span, start + 0.95 * span, 8, 0.7)
    let table = syl
    return { t in
      var v = 0.0
      for q in table {
        let u = (t - q.c) / q.d
        if u > -1 && u < 1 {
          let c = cos(u * Double.pi / 2)
          v = max(v, q.a * c * c)
        }
      }
      return MLMath.clamp(v + 0.02 * sin(t * 37) * (v > 0.05 ? 1 : 0))
    }
  }
}
