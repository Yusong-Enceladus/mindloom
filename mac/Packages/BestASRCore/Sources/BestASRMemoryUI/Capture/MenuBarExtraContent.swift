import AppKit
import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-capture. S20 · The menu bar extra (MAC-SPEC §3.2): the T-form
// mark (or the recording capsule with 「12:04」 and the orange dot); menu
// 开始记录会议 · 录：腾讯会议 › · 最近记录 › · DGX Spark 已连接 / 没连上 + 重新连接 · 打开
// Mindloom · 设置…; while recording 正在记录会议 12:04 · 录：腾讯会议 (or
// 只录了麦克风) · 暂停 / 继续 · 结束并保存 · 放弃这次记录… · 隐藏字幕 / 显示字幕
// (v12 1C, ALIGNMENT 收2-2, 收2-3; 最近记录 from v12 find). The App's
// `MenuBarContentView` hosts the real (system) menu; this draws it for a still
// image, and makes the label images the App puts in the menu bar.

public struct MenuBarExtraInput: Equatable, Sendable {
  public var link: MemoryLinkState
  public var recording: MemoryCaptureIndicator?
  /// What the meeting records (nil: the rows are left out).
  public var meeting: MenuBarMeetingInput?
  /// Draw the menu open under the icon (else only the menu bar).
  public var menuOpen: Bool
  /// Demo mode: the demo library is open (review v12-B #7).
  public var demo: Bool

  public init(
    link: MemoryLinkState, recording: MemoryCaptureIndicator? = nil,
    meeting: MenuBarMeetingInput? = nil, menuOpen: Bool = true, demo: Bool = false
  ) {
    self.link = link
    self.recording = recording
    self.meeting = meeting
    self.menuOpen = menuOpen
    self.demo = demo
  }
}

/// One choice in a submenu (「整台电脑」, 「腾讯会议」), ticked when chosen.
public struct MenuBarExtraOption: Equatable, Sendable {
  public let id: String
  public let title: String
  public let checked: Bool

  public init(id: String, title: String, checked: Bool) {
    self.id = id
    self.title = title
    self.checked = checked
  }
}

/// What 开始记录会议 records (ALIGNMENT 收2-2) and whether the caption strip
/// shows (收2-3).
public struct MenuBarMeetingInput: Equatable, Sendable {
  public enum Sound: Equatable, Sendable {
    /// The computer's sound and the microphone: 「录：{source}」, with the
    /// choices while no meeting records.
    case computer(source: String, options: [MenuBarExtraOption])
    /// Only the microphone: 屏幕与系统录音 is not allowed, or is allowed but
    /// Mindloom has to open again to use it.
    case microphoneOnly(needsRelaunch: Bool)
  }

  public var sound: Sound
  /// The caption strip shows during this meeting (「隐藏字幕」) or not
  /// (「显示字幕」).
  public var captionsShown: Bool

  public init(sound: Sound, captionsShown: Bool = true) {
    self.sound = sound
    self.captionsShown = captionsShown
  }

  /// 「只录了麦克风」: what a microphone-only meeting says, in the menu and
  /// on its item.
  public static let microphoneOnlyLine = MemoryItemSource.microphoneOnlyNote
}

/// The menu's rows, shared by the real menu (App) and the still image.
public enum MenuBarExtraRow: Equatable, Sendable {
  case action(id: String, title: String, symbol: String?, shortcut: String? = nil)
  /// A grey, not clickable line (「DGX Spark 已连接」); `alert` for 没连上.
  case header(title: String, symbol: String?, detail: String? = nil, alert: Bool = false)
  /// A submenu: 「录：腾讯会议 ›」, whose choices report their own ids, or
  /// one the App fills (「最近记录」: the latest records, each to copy or to
  /// see in 历史; no options here).
  case submenu(id: String, title: String, symbol: String?, options: [MenuBarExtraOption] = [])
  case separator

  /// The rows for a state (§3.2's table; v12 1C adds what the meeting
  /// records and the caption strip's switch).
  public static func rows(
    link: MemoryLinkState, recording: MemoryCaptureIndicator?,
    meeting: MenuBarMeetingInput? = nil, demo: Bool = false
  ) -> [MenuBarExtraRow] {
    var rows: [MenuBarExtraRow] = []
    // Demo mode says so first, always (review v12-B #7).
    if demo {
      rows.append(.header(title: MindloomDemoMarker.menuHeader, symbol: MindloomDemoMarker.symbol))
      rows.append(.separator)
    }
    if let recording, recording.kind != .importing {
      rows.append(
        .header(
          title: recording.paused ? "已暂停" : "正在记录会议", symbol: nil,
          detail: MenuBarClock.text(recording.elapsed)))
      switch meeting?.sound {
      case .computer(let source, _)?:
        rows.append(.header(title: "录制：\(source)", symbol: "speaker.wave.2"))
      case .microphoneOnly?:
        rows.append(
          .header(title: MenuBarMeetingInput.microphoneOnlyLine, symbol: "mic"))
      case nil:
        break
      }
      rows.append(
        recording.paused
          ? .action(id: "resume", title: "继续", symbol: "play.fill")
          : .action(id: "pause", title: "暂停", symbol: "pause.fill"))
      rows.append(.action(id: "stop", title: "结束并保存", symbol: "stop.fill"))
      rows.append(.action(id: "discard", title: "放弃此次记录…", symbol: "trash"))
      if let meeting {
        rows.append(
          meeting.captionsShown
            ? .action(id: "hide-captions", title: "隐藏字幕", symbol: "captions.bubble")
            : .action(id: "show-captions", title: "显示字幕", symbol: "captions.bubble"))
      }
    } else {
      rows.append(.action(id: "start", title: "开始记录会议", symbol: "record.circle"))
      switch meeting?.sound {
      case .computer(let source, let options)?:
        rows.append(
          .submenu(id: "source", title: "录制：\(source)", symbol: "speaker.wave.2", options: options))
      case .microphoneOnly(let needsRelaunch)?:
        rows.append(.header(title: "仅录制麦克风", symbol: "mic"))
        // A demo launch lives in its arguments: a plain reopen would open
        // the owner's library, so demo mode says to reopen the demo way.
        rows.append(
          needsRelaunch
            ? .header(
              title: demo
                ? MindloomDemoMarker.relaunchForComputerSound : "重新打开 Mindloom 后可录制电脑声音",
              symbol: nil)
            : .action(id: "allow-computer-sound", title: "允许录制电脑声音…", symbol: nil))
      case nil:
        break
      }
      rows.append(.submenu(id: "recent", title: "最近记录", symbol: "clock"))
      switch link.status {
      case .connected:
        rows.append(.separator)
        rows.append(.header(title: "DGX Spark 已连接", symbol: "device.box"))
      case .notConnected:
        rows.append(.separator)
        rows.append(.header(title: "DGX Spark 未连接", symbol: "device.box", alert: true))
        rows.append(.action(id: "reconnect", title: "重新连接", symbol: "arrow.clockwise"))
      case .connecting:
        rows.append(.separator)
        rows.append(.header(title: "正在连接 DGX Spark…", symbol: "device.box"))
      case .off:
        break
      }
    }
    rows.append(.separator)
    rows.append(.action(id: "open", title: "打开 Mindloom", symbol: nil))
    rows.append(.action(id: "settings", title: "设置…", symbol: nil, shortcut: "⌘,"))
    return rows
  }
}

/// 「12:04」: minutes unpadded, seconds two digits.
public enum MenuBarClock {
  public static func text(_ elapsed: TimeInterval) -> String {
    let total = max(0, Int(elapsed))
    if total >= 3600 {
      return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}

/// The still image: the menu bar strip with the icon, and the menu under it.
public struct MenuBarExtraContent: View {
  let input: MenuBarExtraInput

  public init(input: MenuBarExtraInput) { self.input = input }

  public var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      HStack(spacing: 14) {
        Spacer()
        MenuBarIcon(elapsed: input.recording.map(\.elapsed))
      }
      .padding(.horizontal, 14)
      .frame(height: 24)
      .background(MLColor.paper2.opacity(0.9))
      if input.menuOpen {
        MenuBarMenuStill(
          rows: MenuBarExtraRow.rows(
            link: input.link, recording: input.recording, meeting: input.meeting,
            demo: input.demo)
        )
        .padding(.trailing, 8)
      }
      Spacer(minLength: 0)
    }
    .environment(\.mlPlatform, .mac)
  }
}

/// The icon as the menu bar draws it: the mark (template-tinted), or the
/// recording capsule (§3.2).
public struct MenuBarIcon: View {
  @Environment(\.colorScheme) private var scheme
  let elapsed: TimeInterval?

  public init(elapsed: TimeInterval?) { self.elapsed = elapsed }

  public var body: some View {
    if let elapsed {
      MenuBarRecordingCapsule(elapsed: elapsed)
    } else {
      MindloomMarkShape(form: .glyph)
        .fill(scheme == .dark ? Color.white : Color.black.opacity(0.85))
        .frame(width: 15 * MindloomMarkPainter.aspectRatio(.glyph), height: 15)
        .accessibilityLabel("Mindloom")
    }
  }
}

/// The recording capsule: 18 high, radius 9, padding 0 7 0 5, filled with
/// the menu bar's ink; the mark 13 and 「m:ss」 (12, 500, tabular) knocked
/// out; then a 6 pt orange dot at −2 pt.
public struct MenuBarRecordingCapsule: View {
  @Environment(\.colorScheme) private var scheme
  let elapsed: TimeInterval

  public init(elapsed: TimeInterval) { self.elapsed = elapsed }

  public var body: some View {
    let ink = scheme == .dark ? Color(white: 0.96) : Color(red: 0.12, green: 0.11, blue: 0.10)
    let knock =
      scheme == .dark
      ? Color(red: 0x1F / 255, green: 0x1D / 255, blue: 0x19 / 255)
      : Color(red: 0xF3 / 255, green: 0xF1 / 255, blue: 0xEA / 255)
    HStack(spacing: -2) {
      HStack(spacing: 4) {
        MindloomMarkShape(form: .glyph).fill(knock)
          .frame(width: 13 * MindloomMarkPainter.aspectRatio(.glyph), height: 13)
        Text(MenuBarClock.text(elapsed))
          .font(.system(size: 12, weight: .medium)).monospacedDigit()
          .foregroundStyle(knock)
      }
      .padding(.leading, 5)
      .padding(.trailing, 7)
      .frame(height: 18)
      .background(ink, in: Capsule())
      Circle().fill(Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255)).frame(width: 6, height: 6)
    }
    .accessibilityElement()
    .accessibilityLabel("正在记录会议 \(MenuBarClock.text(elapsed))")
  }
}

/// The label images the App puts in the menu bar (`MenuBarExtra` with the
/// menu style shows an image, not a live view).
@MainActor
public enum MenuBarLabelImage {
  /// The mark, 15 pt, as a template image (the menu bar tints it).
  public static func idle() -> NSImage {
    let side = CGSize(width: 15 * MindloomMarkPainter.aspectRatio(.glyph), height: 15)
    let renderer = ImageRenderer(
      content: MindloomMarkShape(form: .glyph).fill(Color.black).frame(
        width: side.width, height: side.height))
    renderer.scale = 2
    let image = renderer.nsImage ?? NSImage(size: side)
    image.size = side
    image.isTemplate = true
    image.accessibilityDescription = "Mindloom"
    return image
  }

  /// The recording capsule for an elapsed time, for the menu bar's
  /// appearance.
  public static func recording(_ elapsed: TimeInterval, dark: Bool) -> NSImage {
    let renderer = ImageRenderer(
      content: MenuBarRecordingCapsule(elapsed: elapsed)
        .environment(\.colorScheme, dark ? .dark : .light)
        .padding(.vertical, 2))
    renderer.scale = 2
    let image = renderer.nsImage ?? NSImage(size: CGSize(width: 60, height: 22))
    image.isTemplate = false
    image.accessibilityDescription = "正在记录会议 \(MenuBarClock.text(elapsed))"
    return image
  }
}

/// The open menu in a still image: thick glass, radius 12, padding 6, rows 24
/// (padding 4 10), icons 14 `ink2`, shortcuts `ink3`, min width 230.
struct MenuBarMenuStill: View {
  let rows: [MenuBarExtraRow]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(rows.indices, id: \.self) { i in
        switch rows[i] {
        case .separator:
          Rectangle().fill(MLColor.rule2).frame(height: 0.5).padding(.vertical, 5)
            .padding(.horizontal, 10)
        case .header(let title, let symbol, let detail, let alert):
          HStack(spacing: 8) {
            if let symbol { SettingsIcon(symbol: symbol, size: 13).frame(width: 16) }
            Text(title)
              .font(.system(size: 13, weight: detail == nil ? .regular : .semibold))
              .foregroundStyle(alert ? MLColor.alert : (detail == nil ? MLColor.ink2 : MLColor.ink))
            if let detail {
              Text(detail).mlFont(\.control).monospacedDigit().foregroundStyle(MLColor.ink2)
            }
          }
          .padding(.vertical, 6)
          .padding(.horizontal, 10)
        case .action(_, let title, let symbol, let shortcut):
          HStack(spacing: 8) {
            if let symbol {
              MLSymbol(symbol, size: 12, box: 13).foregroundStyle(MLColor.ink2)
                .frame(width: 16)
            }
            Text(title).mlFont(\.control).foregroundStyle(MLColor.ink)
            Spacer(minLength: 16)
            if let shortcut { Text(shortcut).mlFont(\.control).foregroundStyle(MLColor.ink3) }
          }
          .padding(.horizontal, 10)
          .frame(height: 24)
        case .submenu(_, let title, let symbol, _):
          HStack(spacing: 8) {
            if let symbol {
              MLSymbol(symbol, size: 12, box: 13).foregroundStyle(MLColor.ink2)
                .frame(width: 16)
            }
            Text(title).mlFont(\.control).foregroundStyle(MLColor.ink)
            Spacer(minLength: 16)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
              .foregroundStyle(MLColor.ink3)
          }
          .padding(.horizontal, 10)
          .frame(height: 24)
        }
      }
    }
    .padding(6)
    .frame(width: 230, alignment: .leading)
    .mlGlass(.thick, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

/// 放弃这次记录？ (§3.2): 420 wide, 「录下的声音会删掉，不会收进来。」, 继续记录 ·
/// 放弃 (destructive, primary). The App shows the system alert; this is its
/// still image.
public struct DiscardRecordingAlert: View {
  let keep: () -> Void
  let discard: () -> Void

  public init(keep: @escaping () -> Void = {}, discard: @escaping () -> Void = {}) {
    self.keep = keep
    self.discard = discard
  }

  public static let title = "放弃此次记录？"
  public static let message = "此次录制的声音将被删除。"

  public var body: some View {
    MindloomSheetChrome(width: 420) {
      SheetTitle(Self.title)
      SheetText(Self.message)
      SheetActions {
        Button("继续记录", action: keep).buttonStyle(MLButtonStyle(.standard))
        Button("放弃", action: discard).buttonStyle(MLButtonStyle(.destructivePrimary))
      }
    }
  }
}
