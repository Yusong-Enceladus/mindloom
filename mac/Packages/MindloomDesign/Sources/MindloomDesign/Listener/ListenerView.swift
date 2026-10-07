import Foundation
import Observation
import SwiftUI
import os

/// Drives the listening animation.  The app feeds the gesture (`press`, `release`, `cancel`) and the microphone
/// level (`submitLevel(dBFS:)`, from any thread, e.g. an `AVAudioEngine` tap's RMS); the view samples it every frame.
///
/// Times are seconds on the monotonic clock (`ListenerModel.now()`, system uptime) unless the caller passes its own,
/// so a test can drive it deterministically.  The stage is a function of time: ask `phase(at:)` / `frame(at:)`.
@MainActor
@Observable
public final class ListenerModel {
  /// Seconds on the monotonic clock the model uses by default.
  public nonisolated static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

  /// The layout (re-layout keeps whatever is in progress: the press, the release and the filters).
  public var layout: ListenerLayout {
    didSet { engine.layout = layout }
  }
  /// When the current press started (nil while idle).  Observed: a view starts animating when it changes.
  public private(set) var pressedAt: TimeInterval?
  public private(set) var releasedAt: TimeInterval?
  public private(set) var isCancelled = false

  /// A synthetic level track ℓ(t) that overrides the microphone (demos, tests).
  @ObservationIgnored public var levelTrack: (@Sendable (TimeInterval) -> Double)?

  @ObservationIgnored private var engine: ListenerEngine
  @ObservationIgnored private nonisolated let levelBox = OSAllocatedUnfairLock<Double>(
    initialState: 0)

  public init(layout: ListenerLayout) {
    self.layout = layout
    self.engine = ListenerEngine(layout: layout)
  }

  /// Stage 1: the key or Fn is down.
  public func press(at time: TimeInterval = ListenerModel.now()) {
    engine.press(at: time)
    levelBox.withLock { $0 = 0 }
    pressedAt = time
    releasedAt = nil
    isCancelled = false
  }

  /// Let go: the cord is drawn back in and the mark lands before 「已收好」.  At least 0.2 s after the press.
  public func release(at time: TimeInterval = ListenerModel.now()) {
    engine.release(at: time)
    releasedAt = engine.releaseAt
  }

  /// Cancel: the same way back, but the mark returns to rest and 「已收好」 never shows.
  public func cancel(at time: TimeInterval = ListenerModel.now()) {
    engine.cancel(at: time)
    releasedAt = engine.releaseAt
    isCancelled = true
  }

  /// Back to idle (after 「已收好」 and the undo window).
  public func reset() {
    engine.reset()
    pressedAt = nil
    releasedAt = nil
    isCancelled = false
    levelBox.withLock { $0 = 0 }
  }

  /// The microphone level as RMS dBFS, from any thread (≈ every 21 ms).  Mapped by gate −50 dB, span 34 dB.
  public nonisolated func submitLevel(dBFS: Double) {
    let l = ListenerConstants.level(fromDBFS: dBFS)
    levelBox.withLock { $0 = l }
  }

  /// The level as ℓ in 0…1, from any thread.
  public nonisolated func submitLevel(normalized: Double) {
    let l = MLMath.clamp(normalized)
    levelBox.withLock { $0 = l }
  }

  /// The smoothed display amplitude (0…1) after the last frame.
  public var smoothedLevel: Double { engine.amplitude }

  /// Advances the filters to `time` and returns the frame.
  public func frame(at time: TimeInterval) -> ListenerFrame {
    engine.level = levelBox.withLock { $0 }
    if let track = levelTrack {
      engine.advance(to: time, levelAt: { track($0) })
    } else {
      engine.advance(to: time)
    }
    return engine.frame(at: time)
  }

  /// The stage at `time`.
  public func phase(at time: TimeInterval = ListenerModel.now()) -> ListenerPhase {
    frame(at: time).phase
  }

  /// True once the saved state has fully shown (or a cancel has returned to rest): the app may `reset()` after its
  /// undo window.
  public func isSettled(at time: TimeInterval = ListenerModel.now()) -> Bool {
    guard let r = releasedAt else { return false }
    return time > r + (isCancelled ? 1.25 : 1.6)
  }

  /// The layers to paint at `time` (advances the filters).
  func layers(at time: TimeInterval, reduced: Bool) -> (
    frame: ListenerFrame, layers: [(ListenerGeometry, Double)]
  ) {
    let f = frame(at: time)
    return (f, engine.layers(for: f, reduced: reduced).map { ($0.geometry, $0.opacity) })
  }

  func hud(at time: TimeInterval, reduced: Bool) -> (
    frame: ListenerFrame, layers: [(geometry: ListenerGeometry, opacity: Double, scaleX: Double)],
    width: Double,
    presence: Double
  ) {
    let f = frame(at: time)
    let h = engine.hudLayers(for: f, reduced: reduced)
    return (f, h.layers, h.capsuleWidth, h.presence)
  }
}

/// The listening animation on the phone (keyboard or in-app note): the mark lifts, the cord is drawn out of its
/// bottom tip along its own path, rises into one low arch with the voice, is drawn back in, and lands.
///
/// Drawn with `Canvas` in a `TimelineView(.animation)` (display refresh, 120 Hz on ProMotion; timings are in seconds,
/// not frames).  The view's frame is `layout.canvasSize`; put it over the keyboard's own surface.  Pass `time` to
/// draw one fixed moment (snapshots).
public struct ListenerView: View {
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.colorScheme) private var scheme
  let model: ListenerModel
  let time: TimeInterval?
  let reduceMotion: Bool?
  let color: MLColor

  /// - Parameters: time = a fixed moment (nil = live); reduceMotion nil = the system setting; color default `mark`.
  ///
  /// The chrome around it (the keys' opacity, 「按住说话」 / 「已收好」, the × cancel) reads the same moment from
  /// `model.frame(at:)` (`keys`, `saved`, `listen`) in the host's own `TimelineView`; asking twice for the same time
  /// is free and gives the same frame.
  public init(
    model: ListenerModel, time: TimeInterval? = nil, reduceMotion: Bool? = nil,
    color: MLColor = .mark
  ) {
    self.model = model
    self.time = time
    self.reduceMotion = reduceMotion
    self.color = color
  }

  public var body: some View {
    let size = model.layout.canvasSize
    Group {
      if let time {
        canvas(at: time)
      } else {
        TimelineView(.animation(minimumInterval: nil, paused: model.pressedAt == nil)) { _ in
          canvas(at: ListenerModel.now())
        }
      }
    }
    .frame(width: size.width, height: size.height)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func canvas(at t: TimeInterval) -> some View {
    let reduced = reduceMotion ?? systemReduceMotion
    let out = model.layers(at: t, reduced: reduced)
    let ink = color.color(for: scheme)
    let layers = out.layers
    return Canvas { ctx, _ in
      for (geo, a) in layers { CordPainter.draw(geo, color: ink, opacity: a, in: &ctx) }
    }
  }
}

/// The Mac Fn dictation HUD: a thick-glass capsule (44 pt high) that hugs the cord; at 17 pt the knot and the straight
/// cord crossfade (Mac r2) instead of untying.  The capsule shrinks back to a 44 pt circle and fades with
/// 「已收好」 timing.  Place it 80 pt above the Dock; its frame is `layout.canvasSize`, the capsule centred on
/// `layout.centre`.
public struct ListenerHUD: View {
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.colorScheme) private var scheme
  let model: ListenerModel
  let time: TimeInterval?
  let reduceMotion: Bool?

  public init(model: ListenerModel, time: TimeInterval? = nil, reduceMotion: Bool? = nil) {
    self.model = model
    self.time = time
    self.reduceMotion = reduceMotion
  }

  public var body: some View {
    let size = model.layout.canvasSize
    Group {
      if let time {
        content(at: time)
      } else {
        TimelineView(.animation(minimumInterval: nil, paused: model.pressedAt == nil)) { _ in
          content(at: ListenerModel.now())
        }
      }
    }
    .frame(width: size.width, height: size.height)
    .allowsHitTesting(false)
    .accessibilityElement()
    .accessibilityLabel(model.pressedAt != nil && model.releasedAt == nil ? "正在听" : "")
  }

  private func content(at t: TimeInterval) -> some View {
    let reduced = reduceMotion ?? systemReduceMotion
    let h = model.hud(at: t, reduced: reduced)
    let c = model.layout.centre
    let ink = MLColor.mark.color(for: scheme)
    let layers = h.layers
    return ZStack(alignment: .topLeading) {
      Capsule()
        .fill(Color.clear)
        .frame(width: h.width, height: 44)
        .mlGlass(.thick)
        .scaleEffect(0.92 + 0.08 * h.presence)
        .opacity(h.presence)
        .position(x: c.x, y: c.y)
      Canvas { ctx, _ in
        guard h.presence > 0.01 else { return }
        for layer in layers {
          var l = ctx
          if layer.scaleX != 1 {
            l.translateBy(x: c.x, y: c.y)
            l.scaleBy(x: layer.scaleX, y: 1)
            l.translateBy(x: -c.x, y: -c.y)
          }
          // the r2 HUD draws its line without end fades
          CordPainter.draw(
            layer.geometry, color: ink, opacity: layer.opacity, useEnds: false, in: &l)
        }
      }
    }
  }
}
