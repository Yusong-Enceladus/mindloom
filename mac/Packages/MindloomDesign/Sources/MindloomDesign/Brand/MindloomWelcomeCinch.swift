import SwiftUI

/// The iPhone Welcome's mark (PHONE-SPEC §7.10, beat 1): the stacked lockup's mark (form L) drawn in
/// place, from three hairline strands 7 % larger to the mark itself. Nothing travels.
///
/// u = springStep(t, 1.5); scale = mix(1.07, 1, u) about the ink centre; strand width
/// sw = mix(0.11, 1, u)·w_F; strand pitch = (w_F + gap_F)·scale; band = 2·pitch + sw;
/// channel G = G_F·scale; global alpha = smooth(t / 0.12). The last frame is the mark itself.
/// Reduce Motion: the finished mark fades in over 0.3 s.
///
/// The frame is the still mark's (`height` × height·aspect), so the lockup around it never moves.
public struct MindloomWelcomeCinch: View {
  @Environment(\.colorScheme) private var scheme
  let height: CGFloat
  let time: TimeInterval
  let reduceMotion: Bool
  let color: MLColor

  /// - Parameters: height = the finished mark's ink height (81 on Welcome); time = seconds since
  ///   the screen appeared.
  public init(height: CGFloat, time: TimeInterval, reduceMotion: Bool = false, color: MLColor = .mark)
  {
    self.height = height
    self.time = time
    self.reduceMotion = reduceMotion
    self.color = color
  }

  /// The finished mark's frame width for an ink height.
  public static func width(forHeight height: CGFloat) -> CGFloat {
    height * MindloomMarkPainter.aspectRatio(.large)
  }

  public var body: some View {
    let ink = color.color(for: scheme)
    let t = time
    let reduced = reduceMotion
    let h = height
    Canvas { ctx, size in
      Self.draw(time: t, reduced: reduced, height: h, centre: CGPoint(x: size.width / 2, y: size.height / 2),
        color: ink, in: &ctx)
    }
    .frame(width: Self.width(forHeight: height), height: height)
    .accessibilityHidden(true)
  }

  /// Draws the cinch at `time` centred on `centre` (the ink box centre).
  public static func draw(
    time t: TimeInterval, reduced: Bool, height: CGFloat, centre: CGPoint, color: Color,
    in ctx: inout GraphicsContext
  ) {
    let form = MindloomMarkForm.large
    let g = KnotGeometry.n720
    // knot units → points for the finished mark (ink box = centreline box grown by B/2 each side)
    let k = height / (g.bounds.height + form.band)
    let u = reduced ? 1 : MLMotion.springStep(t, response: 1.5, damping: 1)
    let alpha = reduced ? MLMath.smooth(t / 0.3) : MLMath.smooth(t / 0.12)
    guard alpha > 0.001 else { return }
    let wF = form.strandWidth
    let gapF = wF * form.ratio
    let sc = MLMath.mix(1.07, 1, u)
    let sw = MLMath.mix(0.11, 1, u) * wF
    let pitch = (wF + gapF) * sc
    let band = 2 * pitch + sw
    let channel = form.channel * sc
    let ox = centre.x - g.boxCentre.x * k * sc
    let oy = centre.y - g.boxCentre.y * k * sc
    let pts = g.points.map { CGPoint(x: ox + $0.x * k * sc, y: oy + $0.y * k * sc) }
    var layer = ctx
    layer.opacity = alpha
    KnotBandPainter.draw(
      points: pts, depth: g.depth, band: band * k, channel: channel * k, strands: form.strands,
      strandWidth: sw * k, color: color, in: &layer)
  }
}

/// The iPhone Welcome's stacked lockup with its intro (PHONE-SPEC §7.10, beats 1 and 2): the mark
/// cinches in place; at 0.75 s 「Mindloom」 (and 「织机」 with `showsZhiji`) appear together,
/// rising 8 pt (a = springStep(t − 0.75, 0.6)). The layout is `MindloomStackedLockup`'s, so the
/// finished frame is the still lockup. Reduce Motion: the mark fades in over 0.3 s, the name over
/// 0.15–0.45 s. 「织机」 is the secondary name, shown only in About (docs/UI-COPY.md §4), so the
/// Welcome leaves it out.
public struct MindloomWelcomeLockup: View {
  @Environment(\.colorScheme) private var scheme
  let cap: CGFloat
  let time: TimeInterval
  let reduceMotion: Bool
  let showsZhiji: Bool

  public init(
    cap: CGFloat = 30, time: TimeInterval, reduceMotion: Bool = false, showsZhiji: Bool = false
  ) {
    self.cap = cap
    self.time = time
    self.reduceMotion = reduceMotion
    self.showsZhiji = showsZhiji
  }

  /// Opacity and rise (pt) of a beat starting at `t0` that rises `distance` pt (the app uses the
  /// same rule for beat 3: the sentence at 1.25 s, 6 pt).
  public static func beat(_ t: TimeInterval, at t0: TimeInterval, rise distance: CGFloat, reduceMotion: Bool)
    -> (opacity: Double, offset: CGFloat)
  {
    if reduceMotion { return (MLMath.smooth((t - t0 + 0.6) / 0.3), 0) }
    let u = MLMotion.springStep(t - t0, response: 0.6, damping: 1)
    return (u, (1 - u) * distance)
  }

  public var body: some View {
    let markH = 2.7 * cap
    let name = Self.beat(time, at: 0.75, rise: 8, reduceMotion: reduceMotion)
    let size = cap * 0.54
    let m = ZhijiMetrics(size: size)
    VStack(spacing: 0) {
      MindloomWelcomeCinch(height: markH, time: time, reduceMotion: reduceMotion)
        .padding(.bottom, cap * 0.66)
      VStack(spacing: 0) {
        MindloomWordmark(cap: cap)
        if showsZhiji {
          Text("织机")
            .font(MLBrandFont.zhiji(size: size))
            .tracking(0.06 * size)
            .padding(.leading, 0.06 * size)
            .foregroundStyle(MLColor.ink2.color(for: scheme))
            .padding(.top, max(0, 0.72 * cap + m.inkTop - m.ascent - 0.011 * cap))
            .fixedSize()
        }
      }
      .opacity(name.opacity)
      .offset(y: name.offset)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(showsZhiji ? "Mindloom 织机" : "Mindloom")
  }
}
