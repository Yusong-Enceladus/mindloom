import MindloomDesign
import SwiftUI

/// Welcome (PHONE-SPEC §5.1, §7.10): the stacked lockup made in place (the mark cinches, then the
/// name, then the sentence and the buttons), 「连接 Mac」 and 「稍后」.
struct WelcomeView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @State private var start = Date()
  @State private var finished = false

  /// DEBUG: a frozen moment (welcome-t0.3 …).
  var frozenTime: TimeInterval? = nil
  var reduceMotionOverride: Bool? = nil

  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  var body: some View {
    GeometryReader { proxy in
      let insets = proxy.safeAreaInsets
      let h = proxy.size.height + insets.top + insets.bottom
      let w = proxy.size.width
      TimelineView(.animation(minimumInterval: nil, paused: finished || frozenTime != nil)) {
        context in
        let t = frozenTime ?? context.date.timeIntervalSince(start)
        let rest = MindloomWelcomeLockup.beat(t, at: 1.25, rise: 6, reduceMotion: reduceMotion)
        ZStack(alignment: .top) {
          MLColor.paper.dynamicColor
          MindloomWelcomeLockup(cap: 30, time: t, reduceMotion: reduceMotion)
            .padding(.top, h * 0.34)
          BodyText(
            text: "按住说话，或从分享菜单发送，\n内容都会发送到你的 Mac。", color: .ink2, alignment: .center
          )
          .frame(width: w - 72)
          .padding(.top, h * 0.34 + 206)
          .opacity(rest.opacity)
          .offset(y: rest.offset)
          VStack(spacing: 8) {
            Spacer()
            BlockButton("连接 Mac") { model.startPairing(fromFirstRun: true) }
            BlockButton("稍后", kind: .plain) { model.skipWelcome() }
          }
          .padding(.horizontal, 20)
          .padding(.bottom, insets.bottom + 4)
          .opacity(rest.opacity)
          .allowsHitTesting(rest.opacity > 0.5)
        }
        .frame(width: w, height: h)
      }
      .ignoresSafeArea()
    }
    .task {
      start = Date()
      try? await Task.sleep(for: .seconds(2.8))
      finished = true
    }
  }
}
