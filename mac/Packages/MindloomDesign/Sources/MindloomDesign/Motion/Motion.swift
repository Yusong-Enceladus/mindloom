import Foundation
import SwiftUI

/// A spring in SwiftUI semantics: `response` = undamped period in seconds, `damping` = damping fraction.
/// The CSS `linear()` curves in `tokens.css` are samples of exactly these springs (`ML.motion.springCSS`).
public struct MLSpring: Hashable, Sendable {
  public var response: Double
  public var damping: Double

  public init(response: Double, damping: Double) {
    self.response = response
    self.damping = damping
  }

  /// `--spring-smooth`: response 0.5, damping 1 (680 ms as `linear()`).  Default for anything that moves.
  public static let smooth = MLSpring(response: 0.5, damping: 1)
  /// `--spring-snappy`: response 0.32, damping 0.86 (400 ms, 0.4 % overshoot).  Press feedback, toggles.
  public static let snappy = MLSpring(response: 0.32, damping: 0.86)
  /// `--spring-gentle`: response 0.7, damping 1 (950 ms).  Large surfaces, the mark.
  public static let gentle = MLSpring(response: 0.7, damping: 1)
  /// `quick`: response 0.25, damping 1.  Fades that must not lag.
  public static let quick = MLSpring(response: 0.25, damping: 1)

  /// The SwiftUI animation.
  public var animation: Animation {
    .spring(response: response, dampingFraction: damping, blendDuration: 0)
  }

  /// Step response at `t` seconds (0 → 1), exactly `ML.motion.springStep`.
  public func step(_ t: Double) -> Double {
    MLMotion.springStep(t, response: response, damping: damping)
  }

  /// Settling time to within 0.2 % (the CSS `--spring-*-dur`).
  public var settlingDuration: Double {
    MLMotion.springDuration(response: response, damping: damping)
  }
}

/// Durations, easings and springs (tokens.css §5, SYSTEM.md §9).  No bouncy spring anywhere (damping ≥ 0.86);
/// nothing loops while idle; distances are small and multiplied by `move` (0 with Reduce Motion).
public enum MLMotion {
  /// `--dur-instant` 100 ms: press feedback.
  public static let durInstant: Double = 0.10
  /// `--dur-fast` 160 ms: hover, fades, small state changes.
  public static let durFast: Double = 0.16
  /// `--dur-base` 240 ms: menus, toasts, the segmented thumb.
  public static let durBase: Double = 0.24
  /// `--dur-slow` 360 ms: sheets, navigation (200 ms with Reduce Motion).
  public static let durSlow: Double = 0.36
  /// `--dur-mark` 600 ms: the mark ties or unties (200 ms with Reduce Motion).
  public static let durMark: Double = 0.60
  /// Reduce Motion's ceiling for every remaining fade.
  public static let durReduced: Double = 0.20

  /// `--ease-out` cubic-bezier(.16, 1, .3, 1): things arriving.
  public static func easeOut(_ duration: Double = durBase) -> Animation {
    .timingCurve(0.16, 1, 0.3, 1, duration: duration)
  }
  /// `--ease-in-out` cubic-bezier(.65, 0, .35, 1): things moving from A to B.
  public static func easeInOut(_ duration: Double = durSlow) -> Animation {
    .timingCurve(0.65, 0, 0.35, 1, duration: duration)
  }
  /// `--ease-in` cubic-bezier(.55, 0, 1, .45): things leaving (short).
  public static func easeIn(_ duration: Double = durFast) -> Animation {
    .timingCurve(0.55, 0, 1, 0.45, duration: duration)
  }

  /// `--spring-smooth` as an animation.
  public static var springSmooth: Animation { MLSpring.smooth.animation }
  /// `--spring-snappy` as an animation.
  public static var springSnappy: Animation { MLSpring.snappy.animation }
  /// `--spring-gentle` as an animation.
  public static var springGentle: Animation { MLSpring.gentle.animation }

  /// Distance multiplier (`--move`): 1, or 0 with Reduce Motion (transforms vanish, fades remain).
  public static func move(reduceMotion: Bool) -> CGFloat { reduceMotion ? 0 : 1 }

  /// How far a sheet rises (24 pt), a toast rises (8 pt), and the scale of a pressed control (0.97).
  public static let sheetRise: CGFloat = 24
  public static let toastRise: CGFloat = 8
  public static let pressedScale: CGFloat = 0.97

  // MARK: pure maths (kit.js ML.motion), shared with the listening animation and the title

  /// Step response of a damped spring, SwiftUI semantics (`ML.motion.springStep`).
  public static func springStep(_ t: Double, response: Double = 0.5, damping: Double = 1) -> Double
  {
    if t <= 0 { return 0 }
    let w = 2 * Double.pi / response
    if damping >= 1 { return 1 - (1 + w * t) * exp(-w * t) }
    let wd = w * (1 - damping * damping).squareRoot()
    let e = exp(-damping * w * t)
    return 1 - e * (cos(wd * t) + (damping * w / wd) * sin(wd * t))
  }

  /// Settling time (to within 0.2 %) of `springStep`, in seconds (`ML.motion.springDuration`).
  public static func springDuration(response: Double = 0.5, damping: Double = 1) -> Double {
    var t = 0.0
    while t < 4 {
      t += 0.005
      if abs(1 - springStep(t, response: response, damping: damping)) < 0.002
        && abs(1 - springStep(t + 0.05, response: response, damping: damping)) < 0.002
      {
        break
      }
    }
    return t
  }

  /// A CSS cubic-bezier timing function as a function of x in 0…1 (`ML.motion.bezier`, Newton–Raphson).
  public static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double)
    -> @Sendable (Double) -> Double
  {
    let cx = 3 * x1
    let bx = 3 * (x2 - x1) - cx
    let ax = 1 - cx - bx
    let cy = 3 * y1
    let by = 3 * (y2 - y1) - cy
    let ay = 1 - cy - by
    return { x in
      var t = x
      for _ in 0..<8 {
        let xt = ((ax * t + bx) * t + cx) * t - x
        let d = (3 * ax * t + 2 * bx) * t + cx
        if abs(xt) < 1e-6 || d == 0 { break }
        t -= xt / d
      }
      t = min(1, max(0, t))
      return ((ay * t + by) * t + cy) * t
    }
  }

  /// `ML.motion.ease.out`, `.inOut`, `.in`, `.standard` as functions.
  public static let curveOut = bezier(0.16, 1, 0.3, 1)
  public static let curveInOut = bezier(0.65, 0, 0.35, 1)
  public static let curveIn = bezier(0.55, 0, 1, 0.45)
  public static let curveStandard = bezier(0.25, 0.1, 0.25, 1)
}

/// The named motion tokens, so a view can say what it means and Reduce Motion is handled in one place.
public enum MLAnimationToken: Sendable, Hashable {
  case instant, fast, base, slow, mark
  case springSmooth, springSnappy, springGentle, springQuick

  /// The animation, or a short opacity-friendly ease (≤ 200 ms) with Reduce Motion.
  public func animation(reduceMotion: Bool) -> Animation {
    if reduceMotion {
      switch self {
      case .instant: return .easeOut(duration: MLMotion.durInstant)
      case .fast: return .easeOut(duration: MLMotion.durFast)
      default: return .easeOut(duration: MLMotion.durReduced)
      }
    }
    switch self {
    case .instant: return MLMotion.easeOut(MLMotion.durInstant)
    case .fast: return MLMotion.easeOut(MLMotion.durFast)
    case .base: return MLMotion.easeOut(MLMotion.durBase)
    case .slow: return MLMotion.easeInOut(MLMotion.durSlow)
    case .mark: return MLMotion.easeInOut(MLMotion.durMark)
    case .springSmooth: return MLSpring.smooth.animation
    case .springSnappy: return MLSpring.snappy.animation
    case .springGentle: return MLSpring.gentle.animation
    case .springQuick: return MLSpring.quick.animation
    }
  }
}

private struct MLAnimationModifier<V: Equatable>: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let token: MLAnimationToken
  let value: V

  func body(content: Content) -> some View {
    content.animation(token.animation(reduceMotion: reduceMotion), value: value)
  }
}

extension View {
  /// `.animation` with a kit token that respects Reduce Motion.
  public func mlAnimation<V: Equatable>(_ token: MLAnimationToken, value: V) -> some View {
    modifier(MLAnimationModifier(token: token, value: value))
  }
}

/// `withAnimation` with a kit token that respects Reduce Motion.
@MainActor
public func withMLAnimation<R>(
  _ token: MLAnimationToken, reduceMotion: Bool, _ body: () throws -> R
) rethrows -> R {
  try withAnimation(token.animation(reduceMotion: reduceMotion), body)
}

/// Small numeric helpers shared by the drawings (kit.js `ML.util`).
enum MLMath {
  @inline(__always) static func clamp(_ v: Double, _ a: Double = 0, _ b: Double = 1) -> Double {
    min(b, max(a, v))
  }
  @inline(__always) static func mix(_ a: Double, _ b: Double, _ u: Double) -> Double {
    a + (b - a) * u
  }
  @inline(__always) static func smooth(_ u: Double) -> Double {
    let x = clamp(u)
    return x * x * (3 - 2 * x)
  }
  @inline(__always) static func mix(_ a: CGPoint, _ b: CGPoint, _ u: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
  }
}
