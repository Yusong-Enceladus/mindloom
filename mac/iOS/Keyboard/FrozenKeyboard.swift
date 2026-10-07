import MindloomDesign
import MindloomPhoneKit
import UIKit

/// A PHONE-SPEC keyboard state frozen for the screenshot harness. The app
/// writes the state id (`-MindloomDebugKeyboard kb-listen`) into the voice records and posts
/// `signal`; the keyboard on screen then draws that moment of the scripted talk (press 0.30 s,
/// release 4.00 s, the synthetic speech level) and puts the matching synthetic text into the
/// host field. Only DEBUG builds read it (`KeyboardModel.loadFrozen`).
struct FrozenKeyboard: Equatable {
  static let signal = PhoneNames.signal("debug.keyboard")
  static let pressAt = 0.30
  static let releaseAt = 4.00
  static let partial = "明天下午三点"
  static let finalText = "明天下午三点在三楼会议室开会。"
  static let typed = "好的，我问到了："

  let state: String
  let base: String
  let time: Double?
  let reduced: Bool

  init?(state raw: String) {
    guard raw.hasPrefix("kb") else { return nil }
    state = raw
    var id = raw
    var reduced = false
    if id.hasSuffix("-rm") {
      reduced = true
      id = String(id.dropLast(3))
    }
    var time: Double?
    if let range = id.range(of: "-t", options: .backwards), let t = Double(id[range.upperBound...]) {
      time = t
      id = String(id[..<range.lowerBound])
    }
    base = id
    self.reduced = reduced
    switch id {
    case "kb-press": self.time = time ?? 0.38
    case "kb-loosen": self.time = time ?? 0.72
    case "kb-listen", "kb-talk", "kb-tap": self.time = time ?? 2.62
    case "kb-cancel": self.time = time ?? 2.3
    case "kb-gather": self.time = time ?? 4.55
    case "kb-land": self.time = time ?? 4.9
    case "kb-saved": self.time = time ?? 5.6
    default: self.time = time
    }
  }

  var latched: Bool { base == "kb-tap" }
  var hot: Bool { base == "kb-cancel" }
  var isTalk: Bool { time != nil }
  var committed: Bool { (time ?? 0) >= Self.releaseAt + KeyboardVoiceController.commitDelay }

  /// The key's state outside the talk.
  var mic: KeyboardVoiceController.Mic {
    switch base {
    case "kb-off": .needsSession
    case "kb-nomic": .microphoneDenied
    case "kb-fullaccess": .needsFullAccess
    default: .ready
    }
  }

  @MainActor
  func prepare(_ listener: ListenerModel) {
    guard let time else { return }
    listener.levelTrack = ListenerSynthetic.speechTrack()
    listener.press(at: Self.pressAt)
    if time >= Self.releaseAt, !latched, !hot { listener.release(at: Self.releaseAt) }
  }

  /// The host field's synthetic text for this moment (marked while listening).
  @MainActor
  func writeHostText(_ proxy: (any UITextDocumentProxy)?) {
    guard let proxy else { return }
    proxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
    proxy.unmarkText()
    // The context the host reports is short; delete until it reports nothing (synthetic text only).
    for _ in 0..<120 {
      proxy.deleteBackward()
    }
    if base == "kb-typed" {
      proxy.insertText(Self.typed)
      return
    }
    guard let time, time >= 1.0 else { return }
    if committed {
      proxy.insertText(Self.finalText)
    } else {
      proxy.setMarkedText(
        Self.partial,
        selectedRange: NSRange(location: (Self.partial as NSString).length, length: 0))
    }
  }
}
