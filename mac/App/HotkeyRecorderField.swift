import AppKit
import BestASRDictation
import BestASRMacUI
import SwiftUI

enum BestASRHotkeyFormatter {
  static func title(_ binding: GlobalHotkeyBinding) -> String {
    var parts: [String] = []
    if binding.modifiers.contains(.function) { parts.append("Fn") }
    if binding.modifiers.contains(.control) { parts.append("⌃") }
    if binding.modifiers.contains(.option) { parts.append("⌥") }
    if binding.modifiers.contains(.shift) { parts.append("⇧") }
    if binding.modifiers.contains(.command) { parts.append("⌘") }
    if binding.keyCode != 63 || !binding.modifiers.contains(.function) {
      parts.append(keyTitle(binding.keyCode))
    }
    return parts.joined(separator: " ")
  }

  private static func keyTitle(_ keyCode: UInt32) -> String {
    switch keyCode {
    case 0: "A"
    case 1: "S"
    case 2: "D"
    case 3: "F"
    case 4: "H"
    case 5: "G"
    case 6: "Z"
    case 7: "X"
    case 8: "C"
    case 9: "V"
    case 11: "B"
    case 12: "Q"
    case 13: "W"
    case 14: "E"
    case 15: "R"
    case 16: "Y"
    case 17: "T"
    case 18: "1"
    case 19: "2"
    case 20: "3"
    case 21: "4"
    case 22: "6"
    case 23: "5"
    case 24: "="
    case 25: "9"
    case 26: "7"
    case 27: "-"
    case 28: "8"
    case 29: "0"
    case 31: "O"
    case 32: "U"
    case 34: "I"
    case 35: "P"
    case 37: "L"
    case 38: "J"
    case 40: "K"
    case 45: "N"
    case 46: "M"
    case 48: "Tab"
    case 49: "Space"
    case 51: "Delete"
    case 53: "Esc"
    case 76: "Enter"
    case 96: "F5"
    case 97: "F6"
    case 98: "F7"
    case 99: "F3"
    case 100: "F8"
    case 101: "F9"
    case 103: "F11"
    case 109: "F10"
    case 111: "F12"
    case 115: "Home"
    case 116: "Page Up"
    case 117: "Forward Delete"
    case 119: "End"
    case 121: "Page Down"
    case 123: "←"
    case 124: "→"
    case 125: "↓"
    case 126: "↑"
    default: "Key \(keyCode)"
    }
  }
}

struct HotkeyRecorderField: NSViewRepresentable {
  @Binding var binding: GlobalHotkeyBinding
  var accessibilityIdentifier: String
  var accessibilityLabel: String

  func makeNSView(context: Context) -> HotkeyRecorderNSView {
    let view = HotkeyRecorderNSView()
    view.onCapture = { binding = $0 }
    view.setBinding(binding)
    view.configureAccessibility(
      identifier: accessibilityIdentifier,
      label: accessibilityLabel
    )
    return view
  }

  func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
    nsView.onCapture = { binding = $0 }
    nsView.setBinding(binding)
    nsView.configureAccessibility(
      identifier: accessibilityIdentifier,
      label: accessibilityLabel
    )
  }
}

final class HotkeyRecorderNSView: NSView {
  var onCapture: ((GlobalHotkeyBinding) -> Void)?
  private let label = NSTextField(labelWithString: "")
  private var currentBinding = DictationHotkeyConfiguration.defaultAlpha.startOrEnd
  private var captureRequested = false
  private(set) var isCapturingHotkey = false
  var displayedTitle: String { label.stringValue }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.borderWidth = 1
    label.alignment = .center
    label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
    label.setAccessibilityElement(false)
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    updateAppearance(active: false)
  }

  required init?(coder: NSCoder) { nil }

  override var acceptsFirstResponder: Bool { true }

  override func accessibilityPerformPress() -> Bool {
    captureRequested = true
    let focused = window?.makeFirstResponder(self) ?? false
    captureRequested = false
    if focused, !isCapturingHotkey { beginCapture() }
    return focused
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result, captureRequested {
      beginCapture()
    } else if result {
      label.stringValue = BestASRHotkeyFormatter.title(currentBinding)
      updateAppearance(active: false)
    }
    return result
  }

  override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    captureRequested = false
    isCapturingHotkey = false
    label.stringValue = BestASRHotkeyFormatter.title(currentBinding)
    updateAccessibilityValue()
    updateAppearance(active: false)
    return result
  }

  override func mouseDown(with event: NSEvent) {
    captureRequested = true
    let focused = window?.makeFirstResponder(self) ?? false
    captureRequested = false
    if focused, !isCapturingHotkey { beginCapture() }
  }

  override func keyDown(with event: NSEvent) {
    guard isCapturingHotkey else {
      if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 {
        beginCapture()
      } else {
        super.keyDown(with: event)
      }
      return
    }
    if event.keyCode == 53 {
      window?.makeFirstResponder(nil)
      return
    }
    guard let binding = Self.binding(from: event),
      !binding.modifiers.isEmpty
    else {
      NSSound.beep()
      label.stringValue = "快捷键必须包含修饰键"
      return
    }
    commit(binding)
  }

  override func flagsChanged(with event: NSEvent) {
    guard isCapturingHotkey,
      event.keyCode == 63,
      event.modifierFlags.contains(.function)
    else { return }
    commit(
      GlobalHotkeyBinding(keyCode: 63, modifiers: [.function])
    )
  }

  func setBinding(_ binding: GlobalHotkeyBinding) {
    currentBinding = binding
    updateAccessibilityValue()
    guard !isCapturingHotkey else { return }
    label.stringValue = BestASRHotkeyFormatter.title(binding)
  }

  func configureAccessibility(identifier: String, label: String) {
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityIdentifier(identifier)
    setAccessibilityLabel(label)
    setAccessibilityHelp("点按后直接按新的全局快捷键")
    updateAccessibilityValue()
  }

  private func commit(_ binding: GlobalHotkeyBinding) {
    currentBinding = binding
    isCapturingHotkey = false
    label.stringValue = BestASRHotkeyFormatter.title(binding)
    updateAccessibilityValue()
    onCapture?(binding)
    window?.makeFirstResponder(nil)
  }

  private func beginCapture() {
    isCapturingHotkey = true
    label.stringValue = "请按新的全局快捷键…"
    setAccessibilityValue("等待输入新快捷键")
    updateAppearance(active: true)
  }

  private func updateAppearance(active: Bool) {
    layer?.borderColor =
      active
      ? NSColor.controlAccentColor.cgColor
      : NSColor.separatorColor.cgColor
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
  }

  private func updateAccessibilityValue() {
    setAccessibilityValue(BestASRHotkeyFormatter.title(currentBinding))
  }

  private static func binding(from event: NSEvent) -> GlobalHotkeyBinding? {
    var modifiers: GlobalHotkeyModifiers = []
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.command) { modifiers.insert(.command) }
    if flags.contains(.option) { modifiers.insert(.option) }
    if flags.contains(.control) { modifiers.insert(.control) }
    if flags.contains(.shift) { modifiers.insert(.shift) }
    if flags.contains(.function) { modifiers.insert(.function) }
    return GlobalHotkeyBinding(
      keyCode: UInt32(event.keyCode),
      modifiers: modifiers
    )
  }
}
