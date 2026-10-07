import SwiftUI

/// The Mac Welcome's stacked lockup as a function of time (MAC-SPEC §10, motion M1–M3), drawn with the same
/// construction as `TitleCinch`:
///
/// - M1 (from 0.1 s): the mark (form L) fades in over 0.23 s while its strands grow from hairlines to their width and
///   the whole knot tightens from 1.07 to 1, one critically damped step with response 1.1 s (no overshoot).
/// - M2 (from 0.72 s): 「Mindloom」 is wiped in left to right with a soft edge (46 %→54 % of a 250 %-wide gradient)
///   over 0.56 s ease-out, every letter at full ink as it appears, plus a scale 0.985 → 1 over 0.7 s ease-out.
/// - M3 (from 1.12 s): 「织机」 fades in over 0.3 s ease-out, only with `showsZhiji` (the
///   secondary name is shown only in About, docs/UI-COPY.md §4; the Mac Welcome leaves it out).
///
/// With Reduce Motion the mark is already tight and fades in over 0.2 s; the word and 「织机」 fade in over 0.2 s, no
/// wipe, no scale.  `time` nil draws the settled lockup.  Cap height `cap` (26 on the Mac Welcome); the view's height
/// is the lockup's ink from the mark's top to 「织机」's bottom.
public struct WelcomeCinch: View {
  @Environment(\.colorScheme) private var scheme
  let cap: CGFloat
  let time: TimeInterval?
  let reduceMotion: Bool
  let showsZhiji: Bool

  public init(
    cap: CGFloat = 26, time: TimeInterval?, reduceMotion: Bool = false, showsZhiji: Bool = false
  ) {
    self.cap = cap
    self.time = time
    self.reduceMotion = reduceMotion
    self.showsZhiji = showsZhiji
  }

  /// Seconds until everything is still.
  public static let settledAfter: TimeInterval = 3.4

  /// The lockup's size at a cap height.
  public static func size(cap: CGFloat) -> CGSize {
    let l = TitleScene.lockupS(Double(cap), 0, 0)
    let markWidth = TitleScene.ink(.large).w * l.k
    return CGSize(
      width: max(markWidth, l.ww) + 2, height: l.cnTop + l.cnSize * 1.05)
  }

  public var body: some View {
    let size = Self.size(cap: cap)
    let pal = TitleCinchPalette.paper(scheme)
    let t = time ?? Self.settledAfter
    let reduced = reduceMotion
    let c = Double(cap)
    Canvas { ctx, canvas in
      let l = TitleScene.lockupS(c, Double(canvas.width) / 2, 0)
      // M1 · the mark
      let tight: Double
      let markOpacity: Double
      if reduced {
        tight = 1
        markOpacity = MLMath.clamp(t / 0.2)
      } else {
        tight = TitleScene.spring1(t - 0.1, 1.1)
        markOpacity = MLMath.clamp((t - 0.1) / 0.23)
      }
      TitleScene.drawCinch(
        form: .large, centre: CGPoint(x: l.cx, y: l.ky), k: l.k, band: l.band, channel: l.channel,
        c: tight, start: 0.1, opacity: markOpacity, color: pal.mark.color, in: &ctx)
      // M2 · the word
      let x = l.cx - l.ww / 2
      let wipe = reduced ? 1 : MLMotion.curveOut(MLMath.clamp((t - 0.72) / 0.56))
      let wordOpacity = reduced ? MLMath.clamp(t / 0.2) : (t >= 0.72 ? 1.0 : 0.0)
      let scale = reduced ? 1 : MLMath.mix(0.985, 1, MLMotion.curveOut(MLMath.clamp((t - 0.72) / 0.7)))
      if wordOpacity > 0.001, wipe > 0.0005 {
        ctx.drawLayer { layer in
          let mid = CGPoint(x: l.cx, y: l.baseline - c / 2)
          layer.translateBy(x: mid.x, y: mid.y)
          layer.scaleBy(x: scale, y: scale)
          layer.translateBy(x: -mid.x, y: -mid.y)
          layer.opacity = wordOpacity
          for i in 0..<8 {
            TitleScene.drawLetter(
              i, x: x, baseline: l.baseline, c: c, rise: 0, opacity: 1, color: pal.ink.color,
              in: &layer)
          }
          if wipe < 1 {
            // A 250 %-wide gradient, opaque to 46 % and clear from 54 %, slid from mask-position 100 % to 0 %:
            // its soft edge (0.2 of the word wide) travels from −0.25 to 1.25 of the word.
            let g = 2.5 * l.ww
            let edge = MLMath.mix(-0.25 * l.ww, 1.25 * l.ww, wipe)
            let left = x + edge - 0.5 * g
            layer.blendMode = .destinationIn
            layer.fill(
              Path(CGRect(x: x - 4, y: l.baseline - c * 1.3, width: l.ww + 8, height: c * 1.6)),
              with: .linearGradient(
                Gradient(stops: [
                  .init(color: .black, location: 0), .init(color: .black, location: 0.46),
                  .init(color: .black.opacity(0), location: 0.54),
                  .init(color: .black.opacity(0), location: 1),
                ]), startPoint: CGPoint(x: left, y: 0), endPoint: CGPoint(x: left + g, y: 0)))
          }
        }
      }
      // M3 · 「织机」
      let zh = reduced ? MLMath.clamp(t / 0.2) : MLMotion.curveOut(MLMath.clamp((t - 1.12) / 0.3))
      if showsZhiji, zh > 0.001 {
        TitleScene.drawZhiji(l, offset: 0, opacity: zh, color: pal.sub.color, in: &ctx)
      }
    }
    .frame(width: size.width, height: size.height)
    .accessibilityElement()
    .accessibilityLabel(showsZhiji ? "Mindloom 织机" : "Mindloom")
  }
}
