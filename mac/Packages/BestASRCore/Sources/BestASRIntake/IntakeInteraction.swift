import AppKit
import BestASRDomain
import Foundation

/// When ⌘V in the main window takes the clipboard in (pure, testable).
public enum IntakePasteShortcut {
  /// Plain ⌘V, pressed (not auto-repeated while held).
  public static func isPlainPaste(
    modifierFlags: NSEvent.ModifierFlags, charactersIgnoringModifiers: String?,
    isARepeat: Bool
  ) -> Bool {
    !isARepeat
      && modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
      && charactersIgnoringModifiers?.lowercased() == "v"
  }

  /// While text is being edited (the first responder is a text view), ⌘V
  /// pastes into it as usual; otherwise it takes the clipboard in.
  public static func takesClipboard(
    modifierFlags: NSEvent.ModifierFlags, charactersIgnoringModifiers: String?,
    isARepeat: Bool, firstResponderIsText: Bool
  ) -> Bool {
    !firstResponderIsText
      && isPlainPaste(
        modifierFlags: modifierFlags, charactersIgnoringModifiers: charactersIgnoringModifiers,
        isARepeat: isARepeat)
  }
}

/// The transient confirmation for one intake action. Content is never echoed
/// back; only counts and the source label are shown. Audio and video wait in
/// a queue that lives only while the App runs, and the text says so.
public enum IntakeConfirmation {
  public static func text(
    stored: Int, mediaStarted: Bool, mediaWaiting: Int, rejected: [String],
    source: ItemSourceApplication?
  ) -> String {
    var parts: [String] = []
    // "已收进来 · 来自 微信"; with no known source, nothing is claimed.
    let name = source?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let label = name.isEmpty ? "" : " · 来自 \(name)"
    if stored == 1 {
      parts.append("已收进来\(label)")
    } else if stored > 1 {
      parts.append("已收进来 \(stored) 条\(label)")
    }
    switch (mediaStarted, mediaWaiting) {
    case (true, 0):
      parts.append("已开始导入音视频文件")
    case (true, let waiting):
      parts.append("已开始导入音视频文件，另 \(waiting) 个等待中（退出 App 会取消等待，需重新拖入）")
    case (false, let waiting) where waiting > 0:
      parts.append("\(waiting) 个音视频文件等待导入（退出 App 会取消等待，需重新拖入）")
    default:
      break
    }
    if let first = rejected.first {
      parts.append(rejected.count == 1 ? first : "\(first)（另有 \(rejected.count - 1) 项未收进来）")
    }
    return parts.isEmpty ? "没有可收进来的内容" : parts.joined(separator: "；")
  }
}
