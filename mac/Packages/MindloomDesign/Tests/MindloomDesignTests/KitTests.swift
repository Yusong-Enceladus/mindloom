import SwiftUI
import Testing

@testable import MindloomDesign

@Suite struct KitTests {
  @Test func knotHasThreeCrossingsAndCentredBox() {
    let g = KnotGeometry.n720
    #expect(g.points.count == 721)
    #expect(KnotMath.crossings(g.points, closed: true).count == 3)
    #expect(abs(max(g.bounds.width, g.bounds.height) - 490) < 1)
    #expect(abs(g.boxCentre.x) < 0.5 && abs(g.boxCentre.y) < 0.5)
    // sample 0 is the bottom lobe tip (the lowest point), its tangent horizontal
    #expect(abs(g.points[0].y - g.bounds.maxY) < 0.5)
    #expect(abs(g.points[1].y - g.points[0].y) < 0.2)
  }

  @Test func formsMatchKit() {
    #expect(MindloomMarkForm.automatic(points: 56, displayScale: 2) == .large)
    #expect(MindloomMarkForm.automatic(points: 28, displayScale: 2) == .medium)
    #expect(MindloomMarkForm.automatic(points: 27.9, displayScale: 2) == .glyph)
    #expect(MindloomMarkForm.automatic(points: 56, displayScale: 1) == .medium)
    #expect(abs(MindloomMarkForm.large.strandWidth - 120 / 3.68) < 1e-9)
  }

  @Test func wordmarkMatchesBrandFile() {
    #expect(MindloomWordmarkMaster.display.data.letters.count == 8)
    #expect(MindloomWordmarkMaster.text.data.letters.count == 8)
    #expect(abs(MindloomWordmarkMaster.display.widthPerCap - 5.9019) < 1e-4)
    #expect(abs(MindloomWordmarkMaster.text.widthPerCap - 6.4307) < 1e-4)
    let r = WordmarkOutline.display.word.boundingRect
    #expect(abs(r.minY + 100) < 0.5 && abs(r.maxY - 1.1) < 0.2 && abs(r.minX) < 0.01)
  }

  @Test func motionMatchesTokens() {
    // the CSS --spring-*-dur values are the settling times of these springs
    #expect(abs(MLSpring.smooth.settlingDuration - 0.68) < 0.01)
    // kit.js gives 0.41; tokens.css rounds it to 400 ms
    #expect(abs(MLSpring.snappy.settlingDuration - 0.40) < 0.015)
    #expect(abs(MLSpring.gentle.settlingDuration - 0.95) < 0.01)
    #expect(abs(MLMotion.curveInOut(0.5) - 0.5) < 1e-4)
  }

  @Test func listenerLevelAndStages() {
    #expect(ListenerConstants.level(fromDBFS: -50) == 0)
    #expect(ListenerConstants.level(fromDBFS: -16) == 1)
    var e = ListenerEngine(layout: .phoneKeyboard(rest: CGPoint(x: 162, y: 102)))
    e.press(at: 0.3)
    let track = ListenerSynthetic.speechTrack(start: 1.2, end: 3.9)
    var phases: [ListenerPhase] = []
    for t in stride(from: 0.31, through: 6.2, by: 0.05) {
      if t >= 4.0 && e.releaseAt == nil { e.release(at: 4.0) }
      e.advance(to: t, levelAt: track)
      let p = e.frame(at: t).phase
      if phases.last != p { phases.append(p) }
    }
    #expect(phases == [.press, .loosen, .listen, .gather, .land, .saved])
    // one arch: the straight run never goes below the line and its ends stay put
    e = ListenerEngine(layout: .phoneKeyboard(rest: CGPoint(x: 162, y: 102)))
    e.press(at: 0)
    e.advance(to: 2.3, levelAt: { _ in 1 })
    let geo = e.geometry(for: e.frame(at: 2.3), reduced: false)
    #expect(!geo.closed)
    let ys = geo.points.map(\.y)
    let base = geo.ends!.y
    #expect(ys.allSatisfy { $0 <= base + 1e-6 })
    let rise = base - (ys.min() ?? base)
    #expect(rise > 3 && rise <= 0.04 * 236 + 1e-6)
  }

  @Test func autospaceAndVocabulary() {
    #expect(MLAutospace.apply("TES论文RoboPrior大修返修") == "TES\u{2005}论文\u{2005}RoboPrior\u{2005}大修返修")
    #expect(MLAutospace.apply("R2已完成") == "R2\u{2005}已完成")
    #expect(MLAutospace.apply("9月21日") == "9月21日")
    // as kit.js: the word itself stays tight (T恤), the Chinese before it is spaced
    #expect(MLAutospace.apply("买T恤") == "买\u{2005}T恤")
    #expect(MLAutospace.apply("CoRA 2026新加坡") == "CoRA 2026\u{2005}新加坡")
    #expect(MLVocabulary.check("已发送 · 按时间 · 织机").isEmpty)
    #expect(MLVocabulary.check("线索").map(\.word) == ["线索"])
    #expect(MLVocabulary.check("在线").isEmpty)
    #expect(MLVocabulary.check("已送到").first?.use == "已发送")
  }
}
