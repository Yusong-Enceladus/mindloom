import Foundation
import SwiftUI
import Testing

@testable import MindloomDesign

/// Renders every component with ImageRenderer, light and dark, at 2×, into `$MINDLOOM_KIT_SHOTS` (the run that makes
/// /Users/Shared/mindloom-demo/v11/kit-shots).  Skipped when the variable is not set, so ordinary test runs write nothing.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MINDLOOM_KIT_SHOTS"] != nil))
struct RenderShots {
  let out = URL(
    fileURLWithPath: ProcessInfo.processInfo.environment["MINDLOOM_KIT_SHOTS"] ?? "/tmp")
  static let schemes: [(String, ColorScheme)] = [("light", .light), ("dark", .dark)]

  @discardableResult
  func save<V: View>(_ name: String?, scale: CGFloat = 2, opaque: Bool = true, _ view: V) throws
    -> CGImage
  {
    let r = ImageRenderer(content: view)
    r.scale = scale
    r.isOpaque = opaque
    let image = try #require(r.cgImage, "render \(name ?? "image")")
    if let name {
      let data = try #require(MindloomAppIcon.pngData(image))
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      try data.write(to: out.appendingPathComponent(name + ".png"))
    }
    return image
  }

  /// A specimen sheet: title, content on paper, in one appearance, with the approximated glass.
  func sheet<V: View>(
    _ title: String, _ scheme: ColorScheme, platform: MLPlatform = .current,
    @ViewBuilder _ content: () -> V
  )
    -> some View
  {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(MLColor.ink2)
      content()
    }
    .padding(24)
    .background(MLColor.paper)
    .environment(\.colorScheme, scheme)
    .environment(\.mlGlassRendering, .approximation)
    .environment(\.mlPlatform, platform)
  }

  // MARK: tokens

  @Test func colours() throws {
    for (n, s) in Self.schemes {
      try save(
        "tokens-colour-\(n)",
        sheet("Colour tokens (\(n))", s) {
          let cols = Array(
            repeating: GridItem(.fixed(150), spacing: 10, alignment: .leading), count: 6)
          LazyVGrid(columns: cols, alignment: .leading, spacing: 10) {
            ForEach(MLColor.all.indices, id: \.self) { i in
              let t = MLColor.all[i]
              VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 8).fill(t.color).frame(height: 40)
                  .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(MLColor.rule, lineWidth: 0.5))
                Text(t.name).font(.system(size: 11, weight: .medium)).foregroundStyle(MLColor.ink)
                Text(hex(t.color.rgba(for: s))).font(.system(size: 10).monospaced())
                  .foregroundStyle(MLColor.ink2)
              }
            }
          }
          .frame(width: 950)
        })
    }
  }

  func hex(_ c: MLRGBA) -> String {
    let h = String(
      format: "#%02X%02X%02X", Int(round(c.red * 255)), Int(round(c.green * 255)),
      Int(round(c.blue * 255)))
    return c.alpha < 1 ? h + String(format: " %.0f%%", c.alpha * 100) : h
  }

  @Test func type() throws {
    let steps: [(String, KeyPath<MLTypeScale, MLTextStyle>, String)] = [
      ("large", \.large, "欢迎使用"), ("title", \.title, "今天 · 9月21日"),
      ("title2", \.title2, "要连接这台 Mac 吗？"),
      ("headline", \.headline, "TES\u{2005}论文\u{2005}RoboPrior\u{2005}大修返修"),
      ("body", \.body, "明天下午三点在三楼会议室开会，记得带上打印好的回复信。"),
      ("callout", \.callout, "R2\u{2005}已完成，回复信还差一段"),
      ("sub", \.sub, "键盘 · 9:41"), ("foot", \.foot, "9月21日 10:05"), ("caption", \.caption, "已发送"),
      ("section", \.section, "本周"), ("control", \.control, "按住说话"), ("lead", \.lead, "回复信还差一段"),
      ("label", \.label, "理论部分"), ("code", \.code, "4X7K-Q2RD"),
    ]
    for p in MLPlatform.allCases {
      for (n, s) in Self.schemes {
        try save(
          "type-\(p.rawValue)-\(n)",
          sheet("Type scale · \(p.rawValue) (\(n))", s, platform: p) {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(steps.indices, id: \.self) { i in
                let st = MLTypeScale.scale(for: p)[keyPath: steps[i].1]
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                  Text("\(steps[i].0)  \(Int(st.size))/\(Int(st.lineHeight))")
                    .font(.system(size: 11).monospaced()).foregroundStyle(MLColor.ink3).frame(
                      width: 130, alignment: .leading)
                  Text(steps[i].2).mlFont(steps[i].1).foregroundStyle(
                    i == 9 ? MLColor.ink2 : MLColor.ink)
                }
              }
            }
            .frame(width: 640, alignment: .leading)
          })
      }
    }
  }

  // MARK: brand

  @Test func marks() throws {
    for (n, s) in Self.schemes {
      try save(
        "mark-forms-\(n)",
        sheet("MindloomMark forms L · M · S · T, and auto by size at 2× (\(n))", s) {
          HStack(alignment: .bottom, spacing: 28) {
            ForEach(MindloomMarkForm.allCases, id: \.self) { f in
              VStack(spacing: 8) {
                MindloomMark(height: 112, form: f)
                Text(f.rawValue).font(.system(size: 11)).foregroundStyle(MLColor.ink2)
              }
            }
            ForEach([80, 56, 40, 28, 20, 14] as [CGFloat], id: \.self) { h in
              VStack(spacing: 8) {
                MindloomMark(height: h)
                Text("\(Int(h)) auto").font(.system(size: 11)).foregroundStyle(MLColor.ink2)
              }
            }
            VStack(spacing: 8) {
              MindloomMarkShape(form: .glyph).fill(MLColor.mark).frame(
                width: 40 * MindloomMarkPainter.aspectRatio(.glyph), height: 40)
              Text("Shape T").font(.system(size: 11)).foregroundStyle(MLColor.ink2)
            }
            VStack(spacing: 8) {
              MindloomMarkShape(form: .large).fill(MLColor.mark).frame(
                width: 112 * MindloomMarkPainter.aspectRatio(.large), height: 112)
              Text("Shape L").font(.system(size: 11)).foregroundStyle(MLColor.ink2)
            }
          }
        })
      // one large L, comparable with v10/brand/lockup/glyph-L-*.svg
      try save(
        "mark-L-400-\(n)", scale: 1,
        MindloomMark(height: 400, form: .large).padding(40).background(MLColor.paper).environment(
          \.colorScheme, s))
    }
  }

  @Test func appIcons() throws {
    for a in MindloomAppIcon.Appearance.allCases {
      let d = try #require(MindloomAppIcon.pngData(platform: .ios, appearance: a))
      try d.write(to: out.appendingPathComponent("icon-ios-\(a.rawValue)-1024.png"))
    }
    for a in [MindloomAppIcon.Appearance.light, .dark] {
      let d = try #require(MindloomAppIcon.pngData(platform: .mac, appearance: a))
      try d.write(to: out.appendingPathComponent("icon-mac-\(a.rawValue)-1024.png"))
    }
    try save(
      "icon-mac-slots", scale: 1, opaque: false,
      HStack(alignment: .bottom, spacing: 16) {
        ForEach([512, 256, 128, 64, 32, 16] as [CGFloat], id: \.self) { px in
          MindloomAppIcon(platform: .mac, side: px)
        }
      }.padding(16))
  }

  @Test func wordmarkAndLockups() throws {
    for (n, s) in Self.schemes {
      try save(
        "wordmark-\(n)",
        sheet("MindloomWordmark: display cap 80 · 40 · 14, text cap 12 · 11 (\(n))", s) {
          VStack(alignment: .leading, spacing: 18) {
            MindloomWordmark(cap: 80)
            MindloomWordmark(cap: 40)
            HStack(spacing: 24) {
              MindloomWordmark(cap: 14)
              MindloomWordmark(cap: 12)
              MindloomWordmark(cap: 11)
              MindloomWordmark(cap: 11, master: .display)
            }
          }
        })
      try save(
        "lockups-\(n)",
        sheet("Horizontal lockup cap 40 · 14 · 12, stacked lockup cap 30 with 织机 (\(n))", s) {
          HStack(alignment: .center, spacing: 48) {
            VStack(alignment: .leading, spacing: 24) {
              MindloomLockup(cap: 40)
              MindloomLockup(cap: 14)
              MindloomLockup(cap: 12)
            }
            MindloomStackedLockup(cap: 30, showsZhiji: true)
            MindloomStackedLockup(cap: 26, showsZhiji: false)
          }
        })
    }
  }

  @Test func titleFrames() throws {
    let palettes: [(String, TitleCinchPalette)] = [
      ("film", .film), ("light", .paperLight), ("dark", .paperDark),
    ]
    for v in [TitleCinch.Variant.title, .closeCard] {
      for (pn, p) in palettes {
        for q in [0.0, 0.25, 0.5, 0.75, 1.0] {
          try save(
            "title-\(v.rawValue)-\(pn)-\(String(format: "%.2f", q))", scale: 1,
            TitleCinch(v, progress: q, palette: p).frame(width: 960, height: 540))
        }
      }
    }
    // the film's measured stills (Title-024 … Title-355 at 60 fps), for side-by-side with v10/brand/title
    for fr in [24, 50, 60, 93, 100, 128, 140, 160, 200, 260, 355] {
      try save(
        String(format: "title-film-f%03d", fr), scale: 1,
        TitleCinch(.title, time: Double(fr) / 60, palette: .film).frame(width: 960, height: 540))
    }
    for fr in [20, 50, 80, 239] {
      try save(
        String(format: "close-film-f%03d", fr), scale: 1,
        TitleCinch(.closeCard, time: Double(fr) / 60, palette: .film).frame(width: 960, height: 540)
      )
    }
    try save(
      "cover-light", scale: 1,
      TitleCinch(.cover, time: 0, palette: .paperLight).frame(width: 960, height: 540))
    try save(
      "cover-film", scale: 1,
      TitleCinch(.cover, time: 0, palette: .film).frame(width: 960, height: 540))
  }

  // MARK: listener

  static let script = (press: 0.3, release: 4.0, speech: (1.2, 3.9))
  static let phoneTimes: [Double] = [0.2, 0.38, 0.72, 0.8, 0.9, 2.0, 2.62, 4.45, 4.55, 4.9, 5.6]
  static let rest = CGPoint(x: 162, y: 102)
  static let landAt = CGPoint(x: 170.5, y: 102)

  func scriptedModel(_ layout: ListenerLayout) -> ListenerModel {
    let m = ListenerModel(layout: layout)
    m.levelTrack = ListenerSynthetic.speechTrack(
      start: Self.script.speech.0, end: Self.script.speech.1)
    m.press(at: Self.script.press)
    m.release(at: Self.script.release)
    return m
  }

  @Test func listenerFilmstrips() throws {
    for (n, s) in Self.schemes {
      for reduced in [false, true] {
        let model = scriptedModel(.phoneKeyboard(rest: Self.rest, landAt: Self.landAt))
        var frames: [AnyView] = []
        for t in Self.phoneTimes {
          let frame = model.frame(at: t)
          let panel = KeyboardHarness(model: model, frame: frame, time: t, reduced: reduced)
            .environment(\.colorScheme, s)
          // rendered now, in time order: the level filters only run forwards
          let img = try save(
            reduced ? nil : "listen-phone-\(n)-\(String(format: "%.2f", t))", panel)
          frames.append(
            AnyView(
              VStack(alignment: .leading, spacing: 4) {
                Image(decorative: img, scale: 2)
                Text("\(String(format: "%.2f", t)) s · \(frame.phase.rawValue)").font(
                  .system(size: 11)
                ).foregroundStyle(MLColor.ink2)
              }))
        }
        try save(
          "listen-filmstrip-phone-\(n)\(reduced ? "-reduced" : "")", scale: 1,
          sheet(
            "ListenerView, phone keyboard, scripted (press 0.3 s, release 4.0 s)\(reduced ? ", Reduce Motion" : "") (\(n))",
            s
          ) {
            LazyVGrid(
              columns: Array(repeating: GridItem(.fixed(402), spacing: 12), count: 6),
              alignment: .leading, spacing: 12
            ) {
              ForEach(frames.indices, id: \.self) { frames[$0] }
            }
          })
      }
      // Mac Fn HUD
      let hud = scriptedModel(.macHUD(size: CGSize(width: 260, height: 80)))
      var cells: [AnyView] = []
      for t in [0.2, 0.45, 0.72, 0.9, 2.62, 4.3, 4.45, 4.7, 5.6] {
        let phase = hud.frame(at: t).phase
        let img = try save(
          nil, opaque: false,
          ListenerHUD(model: hud, time: t, reduceMotion: false)
            .background(Desktop())
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .environment(\.colorScheme, s)
            .environment(\.mlGlassRendering, .approximation))
        cells.append(
          AnyView(
            VStack(alignment: .leading, spacing: 4) {
              Image(decorative: img, scale: 2)
              Text("\(String(format: "%.2f", t)) s · \(phase.rawValue)").font(.system(size: 11))
                .foregroundStyle(MLColor.ink2)
            }))
      }
      try save(
        "listen-filmstrip-mac-hud-\(n)",
        sheet("ListenerHUD (Mac Fn), knot and cord crossfade (\(n))", s, platform: .mac) {
          LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(260), spacing: 12), count: 5),
            alignment: .leading, spacing: 12
          ) {
            ForEach(cells.indices, id: \.self) { cells[$0] }
          }
        })
    }
  }

  // MARK: components

  @Test func components() throws {
    for p in MLPlatform.allCases {
      for (n, s) in Self.schemes {
        try save(
          "components-\(p.rawValue)-\(n)",
          sheet("Components · \(p.rawValue) (\(n))", s, platform: p) {
            VStack(alignment: .leading, spacing: 22) {
              HStack(spacing: 18) {
                ForEach(MLStatus.allCases, id: \.self) { st in
                  HStack(spacing: 6) {
                    MLStatusCircle(st)
                    Text(st.rawValue).font(.system(size: 12)).foregroundStyle(MLColor.ink2)
                  }
                }
              }
              ZStack {
                Desktop().frame(height: 140)
                VStack(spacing: 12) {
                  MLToast("已添加", actionTitle: "撤销", action: {})
                  MLToast("已发送", detail: "9:41", leading: .symbol("checkmark"))
                }
              }
              .clipShape(RoundedRectangle(cornerRadius: 12))
              VStack(alignment: .leading, spacing: 0) {
                MLSectionHeader("本周")
                Text("TES\u{2005}论文返修").mlFont(\.headline).foregroundStyle(MLColor.ink)
                  .padding(.horizontal, p == .ios ? 20 : 10)
              }
              LensDemo()
              HStack(spacing: 10) {
                Button("连接 Mac") {}.buttonStyle(MLButtonStyle(.primary))
                Button("稍后") {}.buttonStyle(MLButtonStyle(.plain))
                Button("撤回") {}.buttonStyle(MLButtonStyle(.destructive, small: true))
                Button("按住说话") {}.buttonStyle(MLButtonStyle(.neutral))
              }
              MLEmptyState("这里还没有东西", message: "按住说话，或者从分享菜单发过来。", actionTitle: "按住说话", action: {})
                .background(MLColor.paper2, in: RoundedRectangle(cornerRadius: 12))
            }
            .frame(width: 560, alignment: .leading)
          })
      }
    }
  }
}

/// The lens control in a fixed state.
private struct LensDemo: View {
  @State var lens = 0
  var body: some View {
    MLLensControl([(0, "按时间"), (1, "按截止日期"), (2, "按人物")], selection: $lens)
  }
}

/// A calm warm wallpaper so glass has something to show (`.ml-desktop`).
struct Desktop: View {
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    let dark = scheme == .dark
    ZStack {
      (dark ? MLRGBA(hex: 0x15161C) : MLRGBA(hex: 0xE9E3D8)).color
      RadialGradient(
        colors: [(dark ? MLRGBA(hex: 0x3A2E3E) : MLRGBA(hex: 0xEFD9C2)).color, .clear],
        center: UnitPoint(x: 0.15, y: 0.1),
        startRadius: 0, endRadius: 300)
      RadialGradient(
        colors: [(dark ? MLRGBA(hex: 0x22304F) : MLRGBA(hex: 0xC9D4EA)).color, .clear],
        center: UnitPoint(x: 0.9, y: 0.2),
        startRadius: 0, endRadius: 300)
    }
  }
}

/// A stand-in for the iPhone keyboard extension around the ListenerView (listen-demo.html's phone panel, 402 × 210):
/// punctuation row, the speak key, space / delete / return; keys fade with `frame.keys`.
private struct KeyboardHarness: View {
  @Environment(\.colorScheme) private var scheme
  let model: ListenerModel
  let frame: ListenerFrame
  let time: Double
  let reduced: Bool

  var body: some View {
    let k = reduced ? (frame.keys > 0.5 ? 1 : 0) : frame.keys
    let pressed = model.pressedAt.map { time >= $0 } ?? false
    let released = model.releasedAt.map { time >= $0 } ?? false
    let sayOpacity =
      released ? 0 : (!pressed ? 1 : 1 - MLMath.smooth((time - model.pressedAt! - 0.06) / 0.1))
    ZStack(alignment: .topLeading) {
      MLColor.kbBackground.color(for: scheme)
      VStack(spacing: 11) {
        HStack(spacing: 6) { ForEach(["，", "。", "？", "！", "～"], id: \.self) { key($0) } }.opacity(k)
        ZStack {
          RoundedRectangle(cornerRadius: 9)
            .fill(
              frame.phase == .press
                ? MLColor.kbKeyFn.color(for: scheme) : MLColor.kbKey.color(for: scheme).opacity(k)
            )
            .shadow(
              color: MLColor.kbShadow.color(for: scheme).opacity(k > 0.02 ? k : 0), radius: 0, x: 0,
              y: 1)
          HStack(spacing: 10) {
            Color.clear.frame(width: 19, height: 18)
            Text("按住说话").font(.system(size: 17, weight: .medium))
          }
          .opacity(sayOpacity)
          HStack(spacing: 10) {
            Color.clear.frame(width: 19, height: 18)
            Text("已添加").font(.system(size: 17, weight: .medium))
          }
          .opacity(frame.saved * k)
          Text("撤销").font(.system(size: 16)).foregroundStyle(MLColor.accent)
            .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 18).opacity(
              frame.saved * k)
        }
        .frame(height: 76)
        HStack(spacing: 6) {
          key("空格", weight: 3.2, size: 16)
          key("⌫", fn: true, size: 18)
          key("换行", fn: true, size: 16)
        }
        .opacity(k)
      }
      .padding(.top, 9)
      .padding(.horizontal, 6)
      .foregroundStyle(MLColor.kbKeyInk.color(for: scheme))
      Circle().fill(MLColor.kbKeyFn.color(for: scheme))
        .frame(width: 38, height: 38)
        .overlay(Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)))
        .foregroundStyle(MLColor.kbKeyInk.color(for: scheme))
        .scaleEffect(0.9 + 0.1 * frame.listen)
        .opacity(reduced ? (frame.listen > 0.5 ? 1 : 0) : frame.listen)
        .position(x: 33, y: 102)
      ListenerView(model: model, time: time, reduceMotion: reduced)
    }
    .frame(width: 402, height: 210)
  }

  func key(_ s: String, fn: Bool = false, weight: CGFloat = 1, size: CGFloat = 22) -> some View {
    RoundedRectangle(cornerRadius: 9)
      .fill((fn ? MLColor.kbKeyFn : MLColor.kbKey).color(for: scheme))
      .shadow(color: MLColor.kbShadow.color(for: scheme), radius: 0, x: 0, y: 1)
      .overlay(Text(s).font(.system(size: size)))
      .frame(height: 44)
      .frame(maxWidth: weight == 1 ? .infinity : 402 * 0.55)
  }
}
