import MindloomDesign
import MindloomPhoneKit
import SwiftUI
import UIKit

/// Our 212 pt panel (PHONE-SPEC §5.13): ，。？！～ / the speak key / 空格 ⌫ 换行, with the listening
/// canvas over all of it. The background stays the system keyboard's; the globe and microphone row
/// under the panel is the system's too.
struct KeyboardPanel: View {
  let model: KeyboardModel
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @State private var tracking = false
  /// Resets also when the system cancels the touch (Notification Center, a call banner), where
  /// `onEnded` never runs: then the utterance is cancelled instead of listening on.
  @GestureState private var pressing = false

  static let height = KeyboardViewController.panelHeight

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let frozen = model.frozen
      let paused = frozen == nil && model.listener.pressedAt == nil
      TimelineView(.animation(minimumInterval: nil, paused: paused)) { _ in
        let t = frozen?.time ?? ListenerModel.now()
        let reduced = frozen?.reduced ?? systemReduceMotion
        let chrome = KeyChrome(model: model, time: t, reduceMotion: reduced)
        panel(width: width, time: t, reduced: reduced, chrome: chrome)
      }
    }
    .frame(height: Self.height)
    .coordinateSpace(.named(Self.space))
  }

  static let space = "panel"

  private var mic: KeyboardVoiceController.Mic {
    model.frozen?.mic ?? model.mic
  }

  /// The key shows the mark and 「按住说话」 (the listening canvas draws the mark).
  private var showsMark: Bool {
    switch mic {
    case .ready, .listening, .finishing: true
    default: model.listener.pressedAt != nil
    }
  }

  @ViewBuilder
  private func panel(width w: CGFloat, time t: TimeInterval, reduced: Bool, chrome: KeyChrome)
    -> some View
  {
    let metrics = KeyMetrics(width: w)
    ZStack(alignment: .topLeading) {
      PunctuationRow(model: model, metrics: metrics)
        .opacity(chrome.keys)
        .allowsHitTesting(chrome.keys > 0.9)

      speakKey(metrics: metrics, chrome: chrome)

      BottomRow(model: model, metrics: metrics)
        .opacity(chrome.keys)
        .allowsHitTesting(chrome.keys > 0.9)

      if showsMark {
        ListenerView(model: model.listener, time: t, reduceMotion: reduced)
          .frame(width: w, height: Self.height)
      }

      controls(metrics: metrics, chrome: chrome)
    }
    .frame(width: w, height: Self.height, alignment: .topLeading)
  }

  // MARK: Speak key

  @ViewBuilder
  private func speakKey(metrics m: KeyMetrics, chrome: KeyChrome) -> some View {
    let frame = m.speakKey
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(chrome.keyFill(scheme))
        .shadow(color: MLColor.kbShadow.color(for: scheme), radius: 0, x: 0, y: 1)
        .opacity(chrome.keyOpacity)
        .frame(width: frame.width, height: frame.height)

      keyLabel(metrics: m, chrome: chrome)
    }
    .frame(width: frame.width, height: frame.height, alignment: .topLeading)
    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .gesture(talkGesture, isEnabled: mic == .ready || mic.isListening || model.latched)
    .onChange(of: pressing) { was, now in
      guard was, !now else { return }
      // `onEnded` runs in the same transaction; whatever is still tracking after it was cancelled
      // by the system.
      DispatchQueue.main.async {
        guard tracking else { return }
        tracking = false
        model.up(at: .zero, moved: 0, cancelled: true)
      }
    }
    .offset(x: frame.minX, y: frame.minY)
    .accessibilityElement()
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { accessibilityTap() }
  }

  @ViewBuilder
  private func keyLabel(metrics m: KeyMetrics, chrome: KeyChrome) -> some View {
    let frame = m.speakKey
    switch mic {
    case .needsSession, .needsFullAccess:
      OpenAppKey(model: model, size: frame.size, fullAccess: mic == .needsSession)
    case .microphoneDenied:
      MicrophoneOffKey(size: frame.size)
    case .unavailable(let problem):
      Text(KeyboardCopy.problem(problem))
        .font(.system(size: 15))
        .foregroundStyle(MLColor.kbKeyInk)
        .frame(width: frame.width, height: frame.height)
    default:
      ZStack(alignment: .leading) {
        Text(KeyboardCopy.holdToTalk).opacity(chrome.speakLabel)
        Text(KeyboardCopy.saved).opacity(chrome.saved)
      }
      .font(.system(size: 17, weight: .medium))
      .foregroundStyle(MLColor.kbKeyInk)
      .frame(height: frame.height)
      .offset(x: m.width / 2 - 20 - frame.minX)
      .allowsHitTesting(false)
    }
  }

  private var talkGesture: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
      .updating($pressing) { _, state, _ in state = true }
      .onChanged { value in
        if !tracking {
          tracking = true
          model.down(at: value.location)
        } else {
          model.move(to: value.location)
        }
      }
      .onEnded { value in
        tracking = false
        let moved = hypot(value.translation.width, value.translation.height)
        model.up(at: value.location, moved: moved)
      }
  }

  // MARK: ×, ✓, 撤销

  @ViewBuilder
  private func controls(metrics m: KeyMetrics, chrome: KeyChrome) -> some View {
    let frozen = model.frozen != nil
    // ×: 40 pt at left 13, top 87.
    Button {
      model.cancel()
    } label: {
      Image(systemName: "xmark")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(MLColor.kbKeyInk)
        .frame(width: 40, height: 40)
        .background(Circle().fill(chrome.hot ? MLColor.kbKey : MLColor.kbKeyFn))
        .scaleEffect(chrome.hot ? 1.1 : 1)
        .animation(MLSpring.snappy.animation, value: chrome.hot)
    }
    .buttonStyle(.plain)
    .opacity(chrome.cancel)
    .allowsHitTesting(chrome.cancel > 0.5 && !frozen)
    .accessibilityLabel(KeyboardCopy.cancel)
    .offset(x: 13, y: 87)

    // ✓: 40 pt at right 13, tap mode only.
    Button {
      model.done()
    } label: {
      Image(systemName: "checkmark")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(MLColor.kbKeyInk)
        .frame(width: 40, height: 40)
        .background(
          Circle().fill(MLColor.kbKey)
            .shadow(color: MLColor.kbShadow.color(for: scheme), radius: 0, x: 0, y: 1))
    }
    .buttonStyle(.plain)
    .opacity(chrome.done)
    .allowsHitTesting(chrome.done > 0.5 && !frozen)
    .accessibilityLabel(KeyboardCopy.finish)
    .offset(x: m.width - 13 - 40, y: 87)

    // 撤销: right 10 of the speak key, 40 high.
    let key = m.speakKey
    Button {
      model.undo()
    } label: {
      Text(KeyboardCopy.undo)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(scheme == .dark ? Color.white : MLColor.accent.color(for: scheme))
        .padding(.horizontal, 14)
        .frame(height: 40)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(chrome.saved)
    .allowsHitTesting(chrome.undoActive && !frozen)
    .frame(width: key.width - 10, height: key.height, alignment: .trailing)
    .offset(x: key.minX, y: key.minY)
  }

  // MARK: Accessibility

  private var accessibilityLabel: String {
    switch mic {
    case .needsSession, .needsFullAccess: KeyboardCopy.openApp
    case .microphoneDenied: KeyboardCopy.microphoneOff
    case .unavailable(let problem): KeyboardCopy.problem(problem)
    default: KeyboardCopy.holdToTalk
    }
  }

  private func accessibilityTap() {
    if model.latched {
      model.done()
    } else if mic == .ready {
      model.down(at: .zero)
      model.up(at: .zero, moved: 0)
    }
  }
}

// MARK: - Geometry

/// The panel's rows from the width (PHONE-SPEC §5.13, §11): top 9, sides 3, gaps 6 / 11.
struct KeyMetrics {
  let width: CGFloat

  var punctuationWidth: CGFloat { (width - 6 - 4 * 6) / 5 }
  func punctuationKey(_ index: Int) -> CGRect {
    CGRect(
      x: 3 + CGFloat(index) * (punctuationWidth + 6), y: 9, width: punctuationWidth, height: 44)
  }
  var speakKey: CGRect { CGRect(x: 3, y: 9 + 44 + 11, width: width - 6, height: 76) }
  var bottomY: CGFloat { speakKey.maxY + 11 }
  var spaceWidth: CGFloat { (width - 18) * 3.2 / 5.2 }
  var smallWidth: CGFloat { (width - 18) / 5.2 }
}

// MARK: - The moment's chrome

/// Everything around the cord at one moment (PHONE-SPEC §7.9 "Chrome tied to the frame",
/// keyboard column).
@MainActor
struct KeyChrome {
  var keys: Double = 1
  var speakLabel: Double = 1
  var saved: Double = 0
  var cancel: Double = 0
  var done: Double = 0
  var undoActive = false
  var hot = false
  /// 0 = `kbKey`, 1 = `kbKeyFn` (the speak key while pressed).
  var fn: Double = 0
  var keyOpacity: Double = 1

  init(model: KeyboardModel, time t: TimeInterval, reduceMotion: Bool) {
    let listener = model.listener
    let frame = listener.frame(at: t)
    let snap = { (v: Double) -> Double in reduceMotion ? (v > 0.5 ? 1 : 0) : v }
    hot = model.frozen?.hot ?? model.hot
    guard let press = listener.pressedAt else { return }
    let smooth = { (u: Double) -> Double in
      let x = min(1, max(0, u))
      return x * x * (3 - 2 * x)
    }
    let released = listener.releasedAt.map { t >= $0 } ?? false
    let tr = listener.releasedAt.map { t - $0 } ?? 0
    let cancelled = listener.isCancelled
    let u = model.resetAt.map { smooth((t - $0) / 0.25) } ?? 0
    keys = snap(frame.keys)
    // The key darkens on the press and never flashes back to white.
    if frame.phase == .press {
      fn = 1
      keyOpacity = 1
    } else {
      fn = released ? 1 - smooth((tr - 0.3) / 0.4) : 1
      keyOpacity = snap(frame.keys)
    }
    var label: Double
    if released {
      label = cancelled ? frame.keys * smooth((tr - 0.75) / 0.25) : 0
    } else {
      label = 1 - smooth((t - press - 0.06) / 0.10)
    }
    if model.resetAt != nil { label = max(label, u) }
    speakLabel = snap(label)
    let committed = model.frozen?.committed ?? model.committed
    saved = committed ? snap(frame.saved * frame.keys * (1 - u)) : 0
    undoActive = saved > 0.5 && model.resetAt == nil && committed
    cancel = snap(frame.listen)
    let latched = model.frozen?.latched ?? model.latched
    done = latched ? snap(frame.listen) : 0
  }

  func keyFill(_ scheme: ColorScheme) -> Color {
    let a = MLColor.kbKey.rgba(for: scheme)
    let b = MLColor.kbKeyFn.rgba(for: scheme)
    let k = min(1, max(0, fn))
    return Color(
      .sRGB, red: a.red + (b.red - a.red) * k, green: a.green + (b.green - a.green) * k,
      blue: a.blue + (b.blue - a.blue) * k, opacity: 1)
  }
}

// MARK: - Rows

/// ，。？！～ with the system-style key pop-up; release inserts, sliding off cancels.
struct PunctuationRow: View {
  static let glyphs: [(String, CGFloat, CGFloat)] = [
    // The prototype's PingFang offsets (§5.13) less the left bearing iOS already centres away.
    ("，", 0.2, -0.39), ("。", 0.2, -0.355), ("？", 0, 0), ("！", 0, 0), ("～", 0, 0),
  ]
  let model: KeyboardModel
  let metrics: KeyMetrics

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(Array(Self.glyphs.enumerated()), id: \.offset) { index, glyph in
        PunctuationKey(
          model: model, character: glyph.0, shift: CGSize(width: glyph.1, height: glyph.2),
          frame: metrics.punctuationKey(index), panelWidth: metrics.width)
      }
    }
  }
}

struct PunctuationKey: View {
  let model: KeyboardModel
  let character: String
  let shift: CGSize
  let frame: CGRect
  let panelWidth: CGFloat
  @State private var down = false
  @State private var inside = true
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(MLColor.kbKey)
        .shadow(color: MLColor.kbShadow.color(for: scheme), radius: 0, x: 0, y: 1)
        .frame(width: frame.width, height: frame.height)
      glyph(size: 22)
        .frame(width: frame.width, height: frame.height)
    }
    .frame(width: frame.width, height: frame.height)
    .contentShape(Rectangle())
    .overlay(alignment: .topLeading) {
      if down && inside { popUp }
    }
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          if !down { down = true }
          inside = CGRect(origin: .zero, size: frame.size).insetBy(dx: -8, dy: -8)
            .contains(value.location)
        }
        .onEnded { _ in
          if down && inside { model.insert(character) }
          down = false
          inside = true
        }
    )
    .offset(x: frame.minX, y: frame.minY)
    .zIndex(down ? 1 : 0)
    .accessibilityLabel(character)
    .accessibilityAddTraits(.isKeyboardKey)
  }

  private func glyph(size: CGFloat) -> some View {
    Text(character)
      .font(.system(size: size))
      .foregroundStyle(MLColor.kbKeyInk)
      .offset(x: shift.width * size, y: shift.height * size)
  }

  /// The system's key pop-up: a bubble (key + 14 wide, 52 high, radius 11) joined to the key by a
  /// stem as wide as the key; clamped inside the panel with a 2 pt margin (also vertically: the
  /// system clips extensions to their bounds).
  private var popUp: some View {
    let bubbleWidth = frame.width + 14
    let left = max(2, min(panelWidth - bubbleWidth - 2, frame.minX - 7))
    let x = left - frame.minX
    let fill = MLColor.kbKey.color(for: scheme)
    return ZStack(alignment: .topLeading) {
      PopUpShape(bubble: CGRect(x: 0, y: 0, width: bubbleWidth, height: 52),
        stem: CGRect(x: frame.minX - left, y: 48, width: frame.width, height: 52))
        .fill(fill)
        .shadow(color: .black.opacity(0.3), radius: 0.25)
        .shadow(color: .black.opacity(0.18), radius: 2, y: 2)
      glyph(size: 32)
        .frame(width: bubbleWidth, height: 52)
    }
    .frame(width: bubbleWidth, height: 100, alignment: .topLeading)
    // iOS clips a keyboard extension to its own bounds, so the bubble cannot rise above the panel
    // as the system's does: it is clamped inside with the same 2 pt margin, over the key.
    .offset(x: x, y: max(-56, 2 - frame.minY))
    .allowsHitTesting(false)
  }
}

struct PopUpShape: Shape {
  let bubble: CGRect
  let stem: CGRect

  func path(in rect: CGRect) -> Path {
    let top = Path(roundedRect: bubble, cornerRadius: 11, style: .continuous)
    let stemPath = Path(
      roundedRect: stem, cornerRadii: RectangleCornerRadii(bottomLeading: 9, bottomTrailing: 9),
      style: .continuous)
    return top.union(stemPath)
  }
}

/// 空格 · ⌫ · 换行.
struct BottomRow: View {
  let model: KeyboardModel
  let metrics: KeyMetrics

  var body: some View {
    let y = metrics.bottomY
    let space = metrics.spaceWidth
    let small = metrics.smallWidth
    ZStack(alignment: .topLeading) {
      PlainKey(title: KeyboardCopy.space, function: false) { model.insert(" ") }
        .frame(width: space, height: 44)
        .offset(x: 3, y: y)
      DeleteKey(model: model)
        .frame(width: small, height: 44)
        .offset(x: 3 + space + 6, y: y)
      PlainKey(title: KeyboardCopy.newline, function: true) { model.insert("\n") }
        .frame(width: small, height: 44)
        .offset(x: 3 + space + 6 + small + 6, y: y)
      if model.needsGlobe {
        // Only on devices without the system's globe row (never on Face ID iPhones).
        Button {
          model.advanceToNextInputMode()
        } label: {
          Image(systemName: "globe")
            .font(.system(size: 20))
            .foregroundStyle(MLColor.kbKeyInk)
            .frame(width: 40, height: 17)
        }
        .buttonStyle(.plain)
        .offset(x: 3, y: y + 46)
        .accessibilityLabel("下一个键盘")
      }
    }
  }
}

/// 空格 (`kbKey`, pressed `kbKeyFn`) and 换行 (`kbKeyFn`, pressed `kbKey`).
struct PlainKey: View {
  let title: String
  let function: Bool
  let action: () -> Void
  @State private var pressed = false
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let light = function ? pressed : !pressed
    Text(title)
      .font(.system(size: 16))
      .foregroundStyle(MLColor.kbKeyInk)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(light ? MLColor.kbKey : MLColor.kbKeyFn)
          .shadow(color: MLColor.kbShadow.color(for: scheme), radius: 0, x: 0, y: 1)
      )
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            guard !pressed else { return }
            pressed = true
            action()
          }
          .onEnded { _ in pressed = false }
      )
      .accessibilityLabel(title)
      .accessibilityAddTraits(.isKeyboardKey)
  }
}

struct DeleteKey: View {
  let model: KeyboardModel
  @State private var pressed = false
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Image(systemName: "delete.left")
      .font(.system(size: 19))
      .foregroundStyle(MLColor.kbKeyInk)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(pressed ? MLColor.kbKey : MLColor.kbKeyFn)
          .shadow(color: MLColor.kbShadow.color(for: scheme), radius: 0, x: 0, y: 1)
      )
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            guard !pressed else { return }
            pressed = true
            model.deleteDown()
          }
          .onEnded { _ in
            pressed = false
            model.deleteUp()
          }
      )
      .accessibilityLabel(KeyboardCopy.delete)
      .accessibilityAddTraits(.isKeyboardKey)
  }
}

// MARK: - The key without a session

/// 「轻点开启语音 ›」: opens Mindloom already listening (`mindloom://voice/start`); the system then
/// shows 「◀ <host>」 to come back. Without Full Access the same words open Mindloom's keyboard page
/// (the steps); if the system refuses to open the app, the key says what to do instead.
struct OpenAppKey: View {
  let model: KeyboardModel
  let size: CGSize
  /// True when the keyboard can reach the app (only the session is off).
  let fullAccess: Bool
  @Environment(\.openURL) private var openURL

  var body: some View {
    Button {
      let url = fullAccess ? PhoneAppGroup.startVoiceURL : PhoneAppGroup.keyboardSettingsURL
      openURL(url) { accepted in
        Task { @MainActor in model.openAppFailed = !accepted }
      }
    } label: {
      Group {
        if model.openAppFailed {
          Text(KeyboardCopy.needsFullAccess)
            .font(.system(size: 15))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
        } else {
          HStack(spacing: 3) {
            Text(KeyboardCopy.openApp)
              .font(.system(size: 17, weight: .medium))
            Image(systemName: "chevron.right")
              .font(.system(size: 13, weight: .semibold))
          }
        }
      }
      .foregroundStyle(MLColor.kbKeyInk)
      .frame(width: size.width, height: size.height)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// 「麦克风没有打开 去设置」: Mindloom opens iOS Settings › Mindloom.
struct MicrophoneOffKey: View {
  let size: CGSize
  @Environment(\.openURL) private var openURL
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Button {
      openURL(PhoneAppGroup.microphoneSettingsURL)
    } label: {
      HStack(spacing: 14) {
        Text(KeyboardCopy.microphoneOff)
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(MLColor.kbKeyInk)
        Text(KeyboardCopy.openSettings)
          .font(.system(size: 17))
          .foregroundStyle(
            scheme == .dark
              ? Color(red: 0xA8 / 255, green: 0xD1 / 255, blue: 1)
              : Color(red: 0, green: 0x7A / 255, blue: 1))
      }
      .frame(width: size.width, height: size.height)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
