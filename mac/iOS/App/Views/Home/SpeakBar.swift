import MindloomDesign
import SwiftUI
import UIKit

/// The speak bar (PHONE-SPEC §5.4, §7.1): a 56 pt glass capsule 30 pt above the bottom edge. Hold
/// to talk; a short tap latches (✓ finishes); slide onto × to cancel. The rest mark is drawn by the
/// listening canvas above it, so the resting and the moving mark are the same drawing.
struct SpeakBar: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  let size: CGSize
  let chrome: TalkChrome
  let microphone: VoiceSessionModel.Microphone
  /// DEBUG frozen moment: no touches.
  let frozen: Bool
  @State private var tracking = false
  /// True while the system considers the touch alive; it resets also when the system cancels the
  /// touch (an alert, Control Center, a call), where `onEnded` never runs.
  @GestureState private var pressing = false

  private var barFrame: CGRect {
    CGRect(x: 20, y: size.height - 30 - 56, width: size.width - 40, height: 56)
  }

  var body: some View {
    let bar = barFrame
    ZStack(alignment: .topLeading) {
      if microphone == .denied {
        deniedBar
      } else {
        glass
        labels
        buttons
      }
    }
    .frame(width: bar.width, height: bar.height)
    .offset(x: bar.minX, y: bar.minY)
    .onAppear { updateCancelRect() }
    .onChange(of: size) { _, _ in updateCancelRect() }
  }

  private func updateCancelRect() {
    let bar = barFrame
    model.talk.cancelRect = CGRect(x: bar.minX + 6, y: bar.minY + 6, width: 44, height: 44)
  }

  // MARK: Parts

  @Environment(\.colorScheme) private var scheme

  /// In dark the plain glass is nearly the paper's colour (only its edge shows), so the bar gets a
  /// faint light tint to read as a control on an empty Home; both themes carry the 0.5 pt hairline.
  private var barGlass: Glass {
    scheme == .dark ? .regular.tint(Color.white.opacity(0.07)).interactive() : .regular.interactive()
  }

  private var glass: some View {
    Capsule()
      .fill(Color.clear)
      .frame(width: barFrame.width, height: 56)
      .glassEffect(barGlass, in: Capsule())
      .overlay(Capsule().strokeBorder(MLColor.rule2, lineWidth: 0.5).allowsHitTesting(false))
      .brightness(chrome.glassBrightness < 1 ? -0.04 : 0)
      .opacity(chrome.glass)
      .contentShape(Capsule())
      .gesture(frozen ? nil : press)
      .onChange(of: pressing) { was, now in
        guard was, !now else { return }
        // After `onEnded` (same transaction) has had its turn: anything still tracking was cancelled.
        DispatchQueue.main.async {
          guard tracking else { return }
          tracking = false
          model.talk.up(at: .zero, cancelled: true)
        }
      }
      .accessibilityElement()
      .accessibilityLabel("按住说话")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { accessibilityTap() }
  }

  /// 「按住说话」 / 「已收好」 at centre − 20; the mark slot at centre − 49 is the canvas's.
  private var labels: some View {
    let x = size.width / 2 - 20 - barFrame.minX
    return ZStack(alignment: .leading) {
      Text("按住说话")
        .opacity(chrome.speakLabel)
      Text("已保存")
        .opacity(chrome.saved)
    }
    .font(.system(size: 17, weight: .medium))
    .foregroundStyle(MLColor.ink)
    .frame(height: 56)
    .offset(x: x)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var buttons: some View {
    ZStack(alignment: .topLeading) {
      // ×: left 6, top 6
      Button {
        model.talk.cancel()
      } label: {
        // 14 pt draws the prototype's visual size (the 17 pt symbol reads ~30 % larger).
        Image(systemName: "xmark")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(MLColor.ink)
          .frame(width: 44, height: 44)
          .background(Circle().fill(chrome.hot ? MLColor.fill3 : MLColor.fill))
          .scaleEffect(chrome.hot ? 1.08 : 1)
          .animation(MLSpring.snappy.animation, value: chrome.hot)
      }
      .buttonStyle(.plain)
      .opacity(chrome.cancel)
      .allowsHitTesting(chrome.cancel > 0.5 && !frozen)
      .accessibilityLabel("取消")
      .offset(x: 6, y: 6)

      // ✓: right 6, tap mode only
      Button {
        model.talk.done()
      } label: {
        Image(systemName: "checkmark")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .background(Circle().fill(MLColor.accentFill))
      }
      .buttonStyle(.plain)
      .opacity(chrome.done)
      .allowsHitTesting(chrome.done > 0.5 && !frozen)
      .accessibilityLabel("完成")
      .offset(x: barFrame.width - 50, y: 6)

      // 撤销: right 8, 40 high
      Button {
        model.talk.undo()
      } label: {
        Text("撤销")
          .font(.system(size: 16))
          .foregroundStyle(MLColor.accent)
          .padding(.horizontal, 14)
          .frame(height: 40)
          .contentShape(Capsule())
      }
      .buttonStyle(UndoStyle())
      .opacity(chrome.saved)
      .allowsHitTesting(chrome.undoActive && !frozen)
      .frame(width: barFrame.width - 8, height: 56, alignment: .trailing)
    }
  }

  /// 「麦克风没有打开 去设置」: no mark; tapping opens iOS Settings › Mindloom.
  private var deniedBar: some View {
    Button {
      if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    } label: {
      HStack(spacing: 12) {
        Text("未允许访问麦克风").foregroundStyle(MLColor.ink)
        Text("打开设置").foregroundStyle(MLColor.accent)
      }
      .font(.system(size: 17, weight: .medium))
      .frame(width: barFrame.width, height: 56)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .glassEffect(barGlass, in: Capsule())
    .overlay(Capsule().strokeBorder(MLColor.rule2, lineWidth: 0.5).allowsHitTesting(false))
  }

  // MARK: Touches

  private var press: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .global)
      .updating($pressing) { _, state, _ in state = true }
      .onChanged { value in
        if !tracking {
          tracking = true
          begin(at: value.location)
        } else {
          model.talk.move(to: value.location)
        }
      }
      .onEnded { value in
        tracking = false
        model.talk.up(at: value.location)
      }
  }

  private func begin(at point: CGPoint) {
    switch model.voice.microphone {
    case .granted:
      model.talk.down(at: point)
    case .undetermined:
      // The alert cancels this touch (`pressing` resets and ends the tracking); the next press
      // talks.
      Task { await model.voice.requestMicrophone() }
    case .denied:
      break
    }
  }

  private func accessibilityTap() {
    if model.talk.latched {
      model.talk.done()
    } else if model.voice.microphone == .granted {
      model.talk.down(at: .zero)
      model.talk.up(at: .zero)
    }
  }
}

private struct UndoStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(Capsule().fill(configuration.isPressed ? MLColor.fill2.dynamicColor : Color.clear))
  }
}

/// The words above the line while listening (PHONE-SPEC §7.9): centred, left/right 32, bottom at
/// centre.y − 46; pending text in `ink2` with an accent caret, the committed text in `ink`.
///
/// The words stay where they are while they are drawn back: the pending and the committed text
/// are set at one balanced measure (kept until the line count changes, and kept at the commit),
/// the caret is joined to the last character and is as wide as the 「。」 that replaces it, so a
/// lone character with the caret never sits on its own line and the paragraph does not re-wrap
/// when it turns from `ink2` to `ink`.
struct LiveWords: View {
  /// The caret: 2 × 20 pt, radius 1, tinted by the text colour, in a box as wide as a full-width
  /// 「。」 (17 pt) so the commit takes exactly its place.
  static let caret: UIImage = {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 15, height: 20))
    return renderer.image { _ in
      UIBezierPath(roundedRect: CGRect(x: 1, y: 0, width: 2, height: 20), cornerRadius: 1).fill()
    }.withRenderingMode(.alwaysTemplate)
  }()

  let talk: TalkController
  let chrome: TalkChrome
  let size: CGSize
  @State private var measure: CGFloat?
  @State private var lines = 0

  private var available: CGFloat { size.width - 64 }

  var body: some View {
    let bottom = size.height - 330 - 46
    let text = talk.committed ?? talk.partial
    let committed = talk.committed != nil
    let words = PhoneText.keepingWordsWhole(text)
    VStack {
      Spacer(minLength: 0)
      (Text(words)
        .foregroundStyle(committed ? MLColor.ink : MLColor.ink2)
        + (committed || text.isEmpty
          ? Text("")
          : Text("\u{2060}") + Text(Image(uiImage: Self.caret)).foregroundStyle(MLColor.accent)
            .baselineOffset(-4)))
        .font(.system(size: 17))
        .lineSpacing(PhoneLine.spacing(size: 17, lineHeight: 26))
        .multilineTextAlignment(.center)
        .frame(width: max(1, min(measure ?? available, available)))
    }
    .frame(width: available, height: bottom)
    .offset(x: 32)
    .opacity(chrome.words)
    .allowsHitTesting(false)
    .accessibilityHidden(chrome.words < 0.5)
    .onChange(of: text, initial: true) { _, new in relayout(new, committed: committed) }
    .onChange(of: available) { _, _ in
      // The first layout pass can come with no size yet: measure again for the real one.
      measure = nil
      lines = 0
      relayout(text, committed: false)
    }
  }

  /// A new measure only when the line count changes (or the text outgrows it); the commit keeps
  /// the last one.
  private func relayout(_ text: String, committed: Bool) {
    guard !text.isEmpty, available > 0 else {
      measure = nil
      lines = 0
      return
    }
    if committed, measure != nil { return }
    let font = UIFont.systemFont(ofSize: 17)
    // As it will be once committed: with the 「。」.
    let width = ceil((PhoneText.finalized(text) as NSString).size(withAttributes: [.font: font]).width)
    let needed = max(1, Int(ceil(width / available)))
    if needed == 1 {
      if lines != 1 || measure != available {
        lines = 1
        measure = available
      }
      return
    }
    if needed != lines || width > (measure ?? 0) * CGFloat(needed) - 17 {
      lines = needed
      measure = min(available, ceil(width / CGFloat(needed)) + 17 * 2)
    }
  }
}
