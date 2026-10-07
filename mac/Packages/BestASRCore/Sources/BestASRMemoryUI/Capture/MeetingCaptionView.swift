import AppKit
import MindloomDesign
import SwiftUI

// OWNER: mac-capture. The meeting's caption strip (ALIGNMENT 收2-3, v12 1C):
// thick glass, 600 × 64, radius 16, centred 16 pt above the Dock; the last
// two lines of the live text (a speaker in `ink2`, words still being
// recognised in `ink2`), 「正在听」 before the first words; on the right the
// orange dot while it records or a few words (已暂停 · 正在转成文字 · 已收好),
// then ✕. Drag anywhere but ✕ to move it. Hosted by the App in a
// non-activating panel (`MeetingCaptionPanelController`).

public struct MeetingCaptionInput: Equatable, Sendable {
  public struct Line: Equatable, Sendable {
    public var speaker: String?
    public var words: String
    public var pending: Bool

    public init(speaker: String? = nil, words: String, pending: Bool = false) {
      self.speaker = speaker
      self.words = words
      self.pending = pending
    }
  }

  /// At most two; none: 「正在听」.
  public var lines: [Line]
  /// 「已暂停」, 「正在转成文字」, 「已收好」.
  public var status: String?
  /// Recording: the orange dot.
  public var live: Bool

  public init(lines: [Line] = [], status: String? = nil, live: Bool = true) {
    self.lines = lines
    self.status = status
    self.live = live
  }
}

public enum MeetingCaptionGeometry {
  public static let size = CGSize(width: 600, height: 64)
}

public struct MeetingCaptionView: View {
  let input: MeetingCaptionInput
  let close: () -> Void
  let moved: () -> Void

  public init(
    input: MeetingCaptionInput, close: @escaping () -> Void = {}, moved: @escaping () -> Void = {}
  ) {
    self.input = input
    self.close = close
    self.moved = moved
  }

  public var body: some View {
    HStack(spacing: 10) {
      ZStack(alignment: .leading) {
        MeetingCaptionText(lines: input.lines)
          .frame(maxWidth: .infinity, alignment: .leading)
        // Anywhere but ✕ moves the strip.
        MeetingCaptionDragArea(moved: moved)
      }
      if let status = input.status {
        Text(status)
          .mlFont(\.controlSmall)
          .foregroundStyle(MLColor.ink2)
          .lineLimit(1)
          .fixedSize()
          .transition(.opacity)
      } else if input.live {
        Circle().fill(MLColor.systemOrange).frame(width: 7, height: 7)
          .accessibilityLabel("正在记录")
      }
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(MLColor.ink2)
          .frame(width: 22, height: 22)
          .background(MLColor.fill, in: Circle())
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .help("关闭字幕")
      .accessibilityLabel("关闭字幕")
    }
    .padding(.leading, 18)
    .padding(.trailing, 12)
    .frame(width: MeetingCaptionGeometry.size.width, height: MeetingCaptionGeometry.size.height)
    .mlGlass(.thick, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.24), value: input)
    .environment(\.mlPlatform, .mac)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("会议字幕")
  }
}

/// The two lines: one running line may wrap onto both; two turns get one
/// line each. The start of a long line gives way to its end.
struct MeetingCaptionText: View {
  static let font = Font.system(size: 15)
  let lines: [MeetingCaptionInput.Line]

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if lines.isEmpty {
        Text("正在聆听").font(Self.font).foregroundStyle(MLColor.ink2)
      } else if lines.count == 1, let only = lines.first {
        line(only).lineLimit(2)
      } else {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, each in
          line(each).lineLimit(1)
        }
      }
    }
    .truncationMode(.head)
    .multilineTextAlignment(.leading)
    .accessibilityElement(children: .combine)
  }

  private func line(_ line: MeetingCaptionInput.Line) -> Text {
    let words = Text(line.words).font(Self.font)
      .foregroundStyle(line.pending ? MLColor.ink2 : MLColor.ink)
    guard let speaker = line.speaker else { return words }
    let name = Text(speaker + "  ").font(Self.font).foregroundStyle(MLColor.ink2)
    return Text("\(name)\(words)")
  }
}

/// A click-and-drag here moves the panel (AppKit's own window drag).
struct MeetingCaptionDragArea: NSViewRepresentable {
  let moved: () -> Void

  func makeNSView(context: Context) -> DragView {
    let view = DragView()
    view.moved = moved
    return view
  }

  func updateNSView(_ view: DragView, context: Context) { view.moved = moved }

  final class DragView: NSView {
    var moved: () -> Void = {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
      // The window server moves the window; the panel's controller keeps
      // where it ends (it follows the window's moves).
      window?.performDrag(with: event)
      moved()
    }
  }
}
