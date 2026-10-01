import MindloomPhoneKit
import SwiftUI
import UIKit

/// 织机键盘: a live transcript strip, one big mic key and the plain keys.
struct KeyboardRootView: View {
  @ObservedObject var model: KeyboardModel
  let globe: GlobeKey

  var body: some View {
    VStack(spacing: 8) {
      TranscriptStrip(model: model)
        .frame(height: 38)
      MicKey(model: model)
        .frame(maxHeight: .infinity)
      HStack(spacing: 6) {
        if model.needsGlobe {
          globe
            .frame(width: 46)
            .keyStyle()
        }
        PlainKey(title: "空格") { model.insertSpace() }
          .accessibilityLabel("空格")
        DeleteKey(model: model)
          .frame(width: 58)
        PlainKey(title: model.returnLabel, emphasized: true) { model.insertReturn() }
          .frame(width: 78)
      }
      .frame(height: 46)
    }
    .padding(.horizontal, 6)
    .padding(.top, 8)
    .padding(.bottom, 6)
    // The system draws the keyboard's own glass behind us (iOS 26); the
    // warm keys and the indigo mic key sit on it like the system's keys.
    .background(Color.clear)
  }
}

// MARK: - Transcript strip

struct TranscriptStrip: View {
  @ObservedObject var model: KeyboardModel

  var body: some View {
    let display = model.display
    HStack(alignment: .center, spacing: 8) {
      Group {
        if let notice = display.notice {
          Label(notice, systemImage: "exclamationmark.circle")
            .foregroundStyle(Loom.amber)
            .lineLimit(2)
        } else if !display.transcript.isEmpty {
          HStack(spacing: 5) {
            if !display.transcriptIsLive {
              Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Loom.green)
            }
            Text(display.transcript)
              .foregroundStyle(display.transcriptIsLive ? Loom.ink : Loom.secondary)
              .lineLimit(2)
              .truncationMode(.head)
          }
        } else {
          Text(hint(display.mic))
            .foregroundStyle(Loom.tertiary)
            .lineLimit(1)
        }
      }
      .font(.system(size: 15))
      .frame(maxWidth: .infinity, alignment: .leading)
      .animation(.easeOut(duration: 0.15), value: display.transcript)

      if model.hasFullAccess { StatusPill(collected: display.collected) }
    }
    .padding(.horizontal, 8)
  }

  private func hint(_ mic: KeyboardVoiceController.Mic) -> String {
    switch mic {
    case .ready: "按住下面的键说话"
    case .listening: "正在听…"
    case .finishing: KeyboardCopy.finishing
    case .needsSession: "语音还没开启"
    case .needsFullAccess: "需要「允许完全访问」"
    case .unavailable: "语音暂时不能用"
    }
  }
}

struct StatusPill: View {
  let collected: Int?

  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(collected == nil ? Loom.tertiary : Loom.gold)
        .frame(width: 5, height: 5)
      Text(collected.map(KeyboardCopy.collected) ?? KeyboardCopy.notPairedStatus)
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(Loom.secondary)
        .contentTransition(.numericText())
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(Loom.card.opacity(0.9), in: Capsule())
    .overlay(Capsule().strokeBorder(Loom.hairline, lineWidth: 1))
    .fixedSize()
    .animation(.snappy, value: collected)
  }
}

// MARK: - The mic key

struct MicKey: View {
  @ObservedObject var model: KeyboardModel
  @Environment(\.openURL) private var openURL
  @State private var pressed = false

  var body: some View {
    let mic = model.display.mic
    ZStack {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(fill(mic))
        .shadow(color: .black.opacity(isListening(mic) ? 0.18 : 0.12), radius: 0.5, y: 1)
      content(mic)
        .padding(.horizontal, 16)
    }
    .scaleEffect(pressed && isListening(mic) ? 0.985 : 1)
    .animation(.spring(duration: 0.28, bounce: 0.2), value: mic)
    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .gesture(gesture(mic))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel(mic))
    .accessibilityAddTraits(.isButton)
  }

  private func isListening(_ mic: KeyboardVoiceController.Mic) -> Bool {
    if case .listening = mic { return true }
    return false
  }

  private func fill(_ mic: KeyboardVoiceController.Mic) -> Color {
    isListening(mic) ? Loom.micActive : Loom.key
  }

  @ViewBuilder
  private func content(_ mic: KeyboardVoiceController.Mic) -> some View {
    switch mic {
    case .ready:
      VStack(spacing: 8) {
        ZStack {
          Circle().fill(Loom.accentTint).frame(width: 48, height: 48)
          Image(systemName: "mic.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(Loom.accent)
        }
        Text(KeyboardCopy.holdToTalk).font(.system(size: 17, weight: .semibold))
          .foregroundStyle(Loom.ink)
        Text(KeyboardCopy.holdToTalkDetail).font(.system(size: 12))
          .foregroundStyle(Loom.tertiary)
      }
    case .listening(let toggle):
      VStack(spacing: 12) {
        LoomWaveform(level: model.level, bars: 25, color: Loom.onMicActive, minimumHeight: 5)
          .frame(height: 46)
          .padding(.horizontal, 24)
        Text(toggle ? KeyboardCopy.tapToFinish : KeyboardCopy.releaseToFinish)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Loom.onMicActive.opacity(0.92))
      }
    case .finishing:
      HStack(spacing: 10) {
        ProgressView().tint(Loom.accent)
        Text(KeyboardCopy.finishing).font(.system(size: 16, weight: .medium))
          .foregroundStyle(Loom.secondary)
      }
    case .needsSession:
      VStack(spacing: 8) {
        ZStack {
          Circle().fill(Loom.accentTint).frame(width: 44, height: 44)
          Image(systemName: "arrow.up.forward.app")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Loom.accent)
        }
        Text(KeyboardCopy.openApp).font(.system(size: 17, weight: .semibold))
          .foregroundStyle(Loom.accent)
        Text(model.openAppFailed ? KeyboardCopy.openAppInstruction : KeyboardCopy.openAppDetail)
          .font(.system(size: 12))
          .foregroundStyle(Loom.tertiary)
          .multilineTextAlignment(.center)
      }
    case .needsFullAccess:
      VStack(spacing: 8) {
        Image(systemName: "lock.open")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(Loom.accent)
        Text(KeyboardCopy.needsFullAccess)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(Loom.ink)
          .multilineTextAlignment(.center)
        Text("设置 → 通用 → 键盘 → 键盘 → 织机键盘")
          .font(.system(size: 12))
          .foregroundStyle(Loom.tertiary)
      }
    case .unavailable(let problem):
      VStack(spacing: 8) {
        Image(systemName: "mic.slash")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(Loom.amber)
        Text(KeyboardCopy.problem(problem))
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(Loom.ink)
          .multilineTextAlignment(.center)
      }
    }
  }

  private func gesture(_ mic: KeyboardVoiceController.Mic) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .local)
      .onChanged { _ in
        guard !pressed else { return }
        pressed = true
        if mic == .needsSession {
          openApp()
        } else {
          model.pressDown()
        }
      }
      .onEnded { _ in
        pressed = false
        model.pressUp()
      }
  }

  /// Opens 织机 to start the voice session. SwiftUI's `openURL` is the
  /// supported way for an extension view; if the system refuses, the key
  /// shows the one-line instruction instead. No private API.
  private func openApp() {
    openURL(PhoneAppGroup.startVoiceURL) { accepted in
      Task { @MainActor in model.openAppFailed = !accepted }
    }
  }

  private func accessibilityLabel(_ mic: KeyboardVoiceController.Mic) -> String {
    switch mic {
    case .ready: "语音输入，按住说话"
    case .listening: "正在听，松开结束"
    case .finishing: KeyboardCopy.finishing
    case .needsSession: KeyboardCopy.openApp
    case .needsFullAccess: KeyboardCopy.needsFullAccess
    case .unavailable(let problem): KeyboardCopy.problem(problem)
    }
  }
}

// MARK: - Plain keys

struct KeyStyle: ViewModifier {
  var pressed = false
  var emphasized = false

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(pressed ? Loom.keyPressed : (emphasized ? Loom.accentTint : Loom.key))
          .shadow(color: .black.opacity(0.16), radius: 0, y: 1)
      )
  }
}

extension View {
  func keyStyle(pressed: Bool = false, emphasized: Bool = false) -> some View {
    modifier(KeyStyle(pressed: pressed, emphasized: emphasized))
  }
}

struct PlainKey: View {
  let title: String
  var emphasized = false
  let action: () -> Void
  @State private var pressed = false

  var body: some View {
    Text(title)
      .font(.system(size: 16, weight: emphasized ? .semibold : .regular))
      .foregroundStyle(emphasized ? Loom.accent : Loom.ink)
      .keyStyle(pressed: pressed, emphasized: emphasized)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in pressed = true }
          .onEnded { _ in
            pressed = false
            action()
          }
      )
      .accessibilityAddTraits(.isButton)
  }
}

struct DeleteKey: View {
  @ObservedObject var model: KeyboardModel
  @State private var pressed = false

  var body: some View {
    Image(systemName: pressed ? "delete.left.fill" : "delete.left")
      .font(.system(size: 18, weight: .medium))
      .foregroundStyle(Loom.ink)
      .keyStyle(pressed: pressed)
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
      .accessibilityLabel("删除")
      .accessibilityAddTraits(.isButton)
  }
}

/// The next-keyboard key. It must be a UIKit control wired to
/// `handleInputModeList(from:with:)` so a tap switches keyboards and a long
/// press shows the list, as the system keyboards do.
struct GlobeKey: UIViewRepresentable {
  weak var controller: UIInputViewController?

  func makeUIView(context: Context) -> UIButton {
    let button = UIButton(type: .system)
    let configuration = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
    button.setImage(UIImage(systemName: "globe", withConfiguration: configuration), for: .normal)
    button.tintColor = UIColor(Loom.ink)
    button.accessibilityLabel = "下一个键盘"
    if let controller {
      button.addTarget(
        controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
        for: .allTouchEvents)
    }
    return button
  }

  func updateUIView(_ button: UIButton, context: Context) {}
}
