import SwiftUI

/// The watch's one screen (WATCH-001): the time recorded, one button (record / stop; Double Tap
/// presses it), and one line saying where the recordings are: on their way to the iPhone while it
/// is in reach, waiting on the watch while it is not.
struct RecordView: View {
  @Environment(WatchModel.self) private var model

  var body: some View {
    VStack(spacing: 6) {
      header
        .frame(height: 30)
      RecordButton(isRecording: model.isRecording, isStarting: model.phase == .starting) {
        model.toggle()
      }
      Text(status)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineLimit(3)
        .minimumScaleFactor(0.8)
        .accessibilityIdentifier("watch.status")
        #if DEBUG
          // UI tests read how many recordings wait on the watch.
          .accessibilityValue("\(model.pendingCount)")
        #endif
    }
    .padding(.horizontal, 4)
  }

  @ViewBuilder private var header: some View {
    if case .recording(let since) = model.phase {
      TimelineView(.periodic(from: since, by: 0.25)) { context in
        Text(Self.elapsed(context.date.timeIntervalSince(since)))
          .font(.system(size: 26, weight: .semibold).monospacedDigit())
          .accessibilityIdentifier("watch.elapsed")
      }
    } else {
      Text("Mindloom")
        .font(.headline)
    }
  }

  private var status: String {
    switch model.problem {
    case .microphoneDenied:
      return "请在 Apple Watch 的“设置”>“隐私与安全”>“麦克风”中允许 Mindloom。"
    case .couldNotStart:
      return "无法开始录音。请稍后再试。"
    case .couldNotContinue:
      return "未能继续录音。请再轻点一次。"
    case nil:
      break
    }
    if model.isRecording { return "正在录制" }
    if model.pendingCount > 0 {
      // On its way while the iPhone is in reach and answering; waiting when it is not.
      return model.sending
        ? "正在发送到 iPhone…" : "\(model.pendingCount) 个录音尚未发送到 iPhone"
    }
    if model.recordedThisVisit { return "已发送到 iPhone" }
    return "轻点录音"
  }

  /// 「0:12」, 「12:05」.
  static func elapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}

/// Red circle to record, red square to stop; a ring that follows the voice while recording.
struct RecordButton: View {
  let isRecording: Bool
  let isStarting: Bool
  let action: () -> Void
  @Environment(WatchModel.self) private var model

  var body: some View {
    Button(action: action) {
      ZStack {
        Circle()
          .strokeBorder(.white.opacity(0.85), lineWidth: 4)
        if isRecording {
          TimelineView(.animation(minimumInterval: 0.1)) { _ in
            Circle()
              .strokeBorder(.red.opacity(0.55), lineWidth: 4)
              .scaleEffect(1 + 0.18 * model.level())
          }
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.red)
            .frame(width: 34, height: 34)
        } else {
          Circle()
            .fill(.red)
            .padding(10)
            .opacity(isStarting ? 0.5 : 1)
        }
      }
      .frame(width: 92, height: 92)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    // Double Tap presses it (WATCH-001).
    .handGestureShortcut(.primaryAction)
    .disabled(isStarting)
    .accessibilityLabel(isRecording ? "停止" : "录音")
    .accessibilityIdentifier("watch.record")
  }
}
