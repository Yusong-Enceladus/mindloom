import MindloomDesign
import SwiftUI

// OWNER: mac-capture. S19 · The fn HUD (MAC-SPEC §8; v12 B1): the kit's
// `ListenerHUD` (knot ↔ line crossfade, the voice arch fed by the real capture
// level); the caption above it during every take (口述时显示文字: 「正在听」,
// pending words in `ink2`, the final text at the end); the target language
// (「英」) or 「指令」 on its left; how the take ended in its place (「已复制 ·
// ⌘V 粘贴」, 「没有听到」, one sentence for an error); 「麦克风没有打开 ·
// 去设置」. Hosted by the App in a borderless click-through panel whose HUD
// centre is 102 pt above the bottom of the active screen.

public enum FnHUDHint: Equatable, Sendable {
  /// 「麦克风没有打开」 + 去设置.
  case microphoneOff
  /// The preview runs beside the user's bestASR App, which has fn.
  case fnTaken

  /// The words of the hint capsule.
  public var text: String {
    switch self {
    case .microphoneOff: "未允许访问麦克风"
    case .fnTaken: FnHUDHint.fnTakenLine
    }
  }

  /// The one quiet line the preview says while the user's own bestASR App
  /// (named 织机 on this Mac) holds fn.
  public static let fnTakenLine = "bestASR 正在使用 fn 键。请先退出 bestASR。"

  /// How long it stays (M19).
  public var lifetime: TimeInterval { 3.6 }
}

/// The take's mode on the capsule's left: 「英」 (翻译 into English), 「指令」.
public struct FnHUDBadge: Equatable, Sendable {
  public var text: String
  /// 「未下载」: the language is not installed on this Mac.
  public var note: String?
  /// The spoken label (「翻译成英语」).
  public var label: String

  public init(text: String, note: String? = nil, label: String) {
    self.text = text
    self.note = note
    self.label = label
  }
}

/// How the take ended, in the capsule's place: an SF Symbol, the line and
/// what the user can do after 「 · 」.
public struct FnHUDNotice: Equatable, Sendable {
  public var symbol: String
  public var text: String
  public var detail: String?

  public init(symbol: String, text: String, detail: String? = nil) {
    self.symbol = symbol
    self.text = text
    self.detail = detail
  }
}

public struct FnHUDInput: Equatable, Sendable {
  /// The caption above the HUD: nil = none (口述时显示文字 off, or the take
  /// ended with nothing heard); "" = 「正在听」 (nothing heard yet); else the
  /// committed words.
  public var caption: String?
  /// Words still pending (drawn in `ink2` after the committed ones).
  public var pending: String
  /// Character ranges of `caption` where the final text differs from the
  /// live caption: drawn with a light dotted underline (收1-18).
  public var revised: [Range<Int>] = []
  public var hint: FnHUDHint?
  public var badge: FnHUDBadge?
  public var notice: FnHUDNotice?

  public init(
    caption: String? = nil, pending: String = "", hint: FnHUDHint? = nil, badge: FnHUDBadge? = nil,
    notice: FnHUDNotice? = nil
  ) {
    self.caption = caption
    self.pending = pending
    self.hint = hint
    self.badge = badge
    self.notice = notice
  }

  /// Nothing to draw in the caption bubble but 「正在听」.
  public var captionIsListening: Bool { (caption ?? "").isEmpty && pending.isEmpty }
}

/// Geometry of the HUD panel (MAC-SPEC §8 on a 1440 × 900 screen: HUD centre
/// 102 pt above the bottom, caption top 76 pt above the HUD centre).
public enum FnHUDGeometry {
  /// The panel's size; wide enough for the 520 pt caption and the capsule's
  /// shadow.
  public static let panelSize = CGSize(width: 600, height: 172)
  /// The HUD centre inside the panel (from the top left).
  public static let hudCentre = CGPoint(x: 300, y: 124)
  /// The HUD centre's height above the screen's bottom edge.
  public static let hudAboveBottom: CGFloat = 102
  /// The caption bubble's top above the HUD centre (798 − 722).
  public static let captionAboveCentre: CGFloat = 76
  /// The caption's bottom above the HUD centre (half the capsule, 22, plus
  /// the 14 pt gap the prototype leaves).
  public static let captionGap: CGFloat = 36
  /// The listener's canvas (holds the widest capsule, 160 pt, with room for
  /// its shadow).
  public static let listenerSize = CGSize(width: 240, height: 96)
  /// The badge's right edge sits this far left of the HUD centre (half the
  /// widest capsule, 80, plus an 8 pt gap).
  public static let badgeEndFromCentre: CGFloat = 88
}

/// The fn HUD: the caption bubble, the listener capsule with the mode badge
/// on its left (or a hint or how the take ended in its place). `listener`
/// nil draws only the caption, badge, hints and notices (stills).
public struct FnHUDView: View {
  let input: FnHUDInput
  let listener: ListenerModel?
  let time: TimeInterval?
  let openSettings: () -> Void

  /// - Parameters:
  ///   - listener: the kit's model the App presses / releases and feeds the
  ///     microphone level to.
  ///   - time: a fixed moment for a still image (nil: live).
  public init(
    input: FnHUDInput, listener: ListenerModel? = nil, time: TimeInterval? = nil,
    openSettings: @escaping () -> Void = {}
  ) {
    self.input = input
    self.listener = listener
    self.time = time
    self.openSettings = openSettings
  }

  public var body: some View {
    let centre = FnHUDGeometry.hudCentre
    ZStack(alignment: .topLeading) {
      Color.clear
      if input.caption != nil {
        // One line sits with its top 76 pt above the HUD centre (14 pt over
        // the capsule); longer captions grow upwards.
        FnHUDCaption(input: input)
          .frame(maxWidth: 520)
          .fixedSize(horizontal: false, vertical: true)
          .frame(
            width: FnHUDGeometry.panelSize.width, height: centre.y - FnHUDGeometry.captionGap,
            alignment: .bottom
          )
          .transition(.opacity)
      }
      let inPlace = input.hint != nil || input.notice != nil
      if let listener, !inPlace {
        ListenerHUD(model: listener, time: time)
          .position(x: centre.x, y: centre.y)
      }
      if let badge = input.badge, !inPlace {
        // Ends 8 pt left of the widest capsule, vertically on its centre.
        let width = centre.x - FnHUDGeometry.badgeEndFromCentre
        FnHUDBadgeCapsule(badge: badge)
          .frame(width: width, alignment: .trailing)
          .position(x: width / 2, y: centre.y)
          .transition(.opacity)
      }
      if let hint = input.hint {
        FnHUDHintCapsule(hint: hint, openSettings: openSettings)
          .position(x: centre.x, y: centre.y)
          .transition(.opacity)
      } else if let notice = input.notice {
        MLToast(notice.text, detail: notice.detail, leading: .symbol(notice.symbol))
          .fixedSize()
          .position(x: centre.x, y: centre.y)
          .transition(.opacity)
      }
    }
    .frame(width: FnHUDGeometry.panelSize.width, height: FnHUDGeometry.panelSize.height)
    .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.24), value: input.caption != nil)
    .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.26), value: input.hint)
    .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.26), value: input.notice)
    .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.18), value: input.badge)
    .environment(\.mlPlatform, .mac)
  }
}

/// The words above the HUD during a take (M30): thick glass,
/// radius 18, padding 9 16, body type, centred; pending words in `ink2`.
struct FnHUDCaption: View {
  /// The prototype's caption sits outside the Mac type scope: 16 pt.
  static let font = Font.system(size: 16)
  let input: FnHUDInput

  var body: some View {
    Group {
      if input.captionIsListening {
        Text("正在聆听").foregroundStyle(MLColor.ink2)
      } else {
        let body = FnHUDCaption.font
        Text(
          "\(FnHUDCaption.marked(input.caption ?? "", revised: input.revised).font(body).foregroundStyle(MLColor.ink))\(Text(input.pending).font(body).foregroundStyle(MLColor.ink2))"
        )
      }
    }
    .font(Self.font)
    .multilineTextAlignment(.center)
    .lineLimit(3)
    .padding(.vertical, 9)
    .padding(.horizontal, 16)
    .mlGlass(.thick, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  /// The final text with the parts recognition changed since the live
  /// caption underlined, lightly, in the accent colour.
  static func marked(_ text: String, revised: [Range<Int>]) -> Text {
    let characters = Array(text)
    guard !revised.isEmpty, !characters.isEmpty else { return Text(text) }
    var result = Text("")
    var cursor = 0
    for range in revised.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      let lower = max(cursor, min(range.lowerBound, characters.count))
      let upper = min(range.upperBound, characters.count)
      guard upper > lower else { continue }
      if lower > cursor { result = result + Text(String(characters[cursor..<lower])) }
      result =
        result
        + Text(String(characters[lower..<upper]))
        .underline(true, pattern: .dot, color: MLColor.accent.dynamicColor.opacity(0.7))
      cursor = upper
    }
    if cursor < characters.count { result = result + Text(String(characters[cursor...])) }
    return result
  }
}

/// The mode on the capsule's left: 「英」, 「指令」, or 「日 · 未下载」 — a small
/// thick-glass capsule, 32 high, as tall as the toasts' text.
struct FnHUDBadgeCapsule: View {
  let badge: FnHUDBadge

  var body: some View {
    HStack(spacing: 0) {
      Text(badge.text).foregroundStyle(MLColor.ink)
      if let note = badge.note {
        Text(" · ").foregroundStyle(MLColor.ink3)
        Text(note).foregroundStyle(MLColor.ink2)
      }
    }
    .mlFont(\.controlSmall)
    .lineLimit(1)
    .fixedSize()
    .padding(.horizontal, 12)
    .frame(height: 32)
    .mlGlass(.thick, in: Capsule())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(badge.label)
  }
}

/// A hint at the HUD's place (§8): the microphone hint with 去设置, the
/// preview's fn line.
struct FnHUDHintCapsule: View {
  let hint: FnHUDHint
  let openSettings: () -> Void

  var body: some View {
    switch hint {
    case .microphoneOff:
      MLToast(
        hint.text, leading: .symbol("mic.slash"), actionTitle: "打开设置", action: openSettings
      )
      .fixedSize()
    case .fnTaken:
      MLToast(hint.text, leading: .symbol("keyboard")).fixedSize()
    }
  }
}
