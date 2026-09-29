import BestASRDictation
import Foundation

/// The one global shortcut the app registers.
///
/// Pause used to have a second one. Nothing pauses a dictation any more, so
/// the binding is gone; a stored configuration that still carries it decodes
/// with the extra key ignored. The two other modes — 指令 and 翻译 — ride the
/// dictation key as Fn chords rather than bindings of their own, because a
/// bare-Fn dictation shortcut fires on its own down edge and would always
/// beat any other Fn combination to the event.
public struct DictationHotkeyConfiguration: Codable, Equatable, Sendable {
  public let startOrEnd: GlobalHotkeyBinding

  public init(startOrEnd: GlobalHotkeyBinding) {
    self.startOrEnd = startOrEnd
  }

  public static let defaultAlpha = DictationHotkeyConfiguration(
    startOrEnd: GlobalHotkeyBinding(keyCode: 63, modifiers: [.function])
  )

  public func migratingRetiredDefaults() -> DictationHotkeyConfiguration { self }
}

public struct DictationHotkeyPreset: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let binding: GlobalHotkeyBinding

  public init(id: String, title: String, binding: GlobalHotkeyBinding) {
    self.id = id
    self.title = title
    self.binding = binding
  }

  public static let alphaPresets = [
    Self(
      id: "function",
      title: "Fn",
      binding: GlobalHotkeyBinding(keyCode: 63, modifiers: [.function])
    ),
    Self(
      id: "function-space",
      title: "Fn Space",
      binding: GlobalHotkeyBinding(keyCode: 49, modifiers: [.function])
    ),
    Self(
      id: "option-space",
      title: "⌥ Space",
      binding: GlobalHotkeyBinding(keyCode: 49, modifiers: [.option])
    ),
    Self(
      id: "option-shift-space",
      title: "⌥ ⇧ Space",
      binding: GlobalHotkeyBinding(
        keyCode: 49,
        modifiers: [.option, .shift]
      )
    ),
    Self(
      id: "control-space",
      title: "⌃ Space",
      binding: GlobalHotkeyBinding(keyCode: 49, modifiers: [.control])
    ),
    Self(
      id: "control-shift-space",
      title: "⌃ ⇧ Space",
      binding: GlobalHotkeyBinding(
        keyCode: 49,
        modifiers: [.control, .shift]
      )
    ),
    Self(
      id: "command-shift-space",
      title: "⌘ ⇧ Space",
      binding: GlobalHotkeyBinding(
        keyCode: 49,
        modifiers: [.command, .shift]
      )
    ),
    Self(
      id: "command-option-space",
      title: "⌘ ⌥ Space",
      binding: GlobalHotkeyBinding(
        keyCode: 49,
        modifiers: [.command, .option]
      )
    ),
  ]

  public static func preset(
    for binding: GlobalHotkeyBinding
  ) -> DictationHotkeyPreset? {
    alphaPresets.first { $0.binding == binding }
  }
}

public protocol HotkeyConfigurationStore: Sendable {
  func load() async -> DictationHotkeyConfiguration?
  func save(_ configuration: DictationHotkeyConfiguration) async throws
}

public actor UserDefaultsHotkeyConfigurationStore: HotkeyConfigurationStore {
  private let suiteName: String?
  private let key: String

  public init(
    suiteName: String? = nil,
    key: String = "dictation.hotkeys.v1"
  ) {
    self.suiteName = suiteName
    self.key = key
  }

  public func load() async -> DictationHotkeyConfiguration? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(DictationHotkeyConfiguration.self, from: data)
  }

  public func save(_ configuration: DictationHotkeyConfiguration) async throws {
    let data = try JSONEncoder().encode(configuration)
    defaults.set(data, forKey: key)
  }

  private var defaults: UserDefaults {
    suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }
}

public enum HotkeyConfigurationResult: Equatable, Sendable {
  case registered
  case conflict(GlobalHotkeyAction)
  case invalidDuplicateBinding
  case unavailable(GlobalHotkeyAction, code: String)
}

public actor GlobalHotkeyConfigurationController {
  private let provider: any GlobalHotkeyPort
  private let store: any HotkeyConfigurationStore
  private var active: DictationHotkeyConfiguration?

  public init(
    provider: any GlobalHotkeyPort,
    store: any HotkeyConfigurationStore
  ) {
    self.provider = provider
    self.store = store
  }

  public func activateSavedOrDefault() async -> HotkeyConfigurationResult {
    guard let saved = await store.load()?.migratingRetiredDefaults() else {
      return await apply(.defaultAlpha)
    }
    let result = await apply(saved)
    if result == .invalidDuplicateBinding {
      return await apply(.defaultAlpha)
    }
    return result
  }

  public func apply(
    _ configuration: DictationHotkeyConfiguration
  ) async -> HotkeyConfigurationResult {
    let previous = active
    if previous != nil {
      await provider.unregister(action: .startOrEnd)
    }
    let startResult = await provider.register(
      action: .startOrEnd,
      binding: configuration.startOrEnd
    )
    guard startResult == .registered else {
      await restore(previous)
      return Self.result(for: startResult, action: .startOrEnd)
    }
    do {
      try await store.save(configuration)
      active = configuration
      return .registered
    } catch {
      await provider.unregister(action: .startOrEnd)
      await restore(previous)
      return .unavailable(.startOrEnd, code: "configuration-save-failed")
    }
  }

  public func activeConfiguration() -> DictationHotkeyConfiguration? { active }

  public func refreshActiveRegistration() async -> HotkeyConfigurationResult {
    let configuration: DictationHotkeyConfiguration
    if let active {
      configuration = active
    } else {
      configuration = await store.load()?.migratingRetiredDefaults() ?? .defaultAlpha
    }
    return await apply(configuration)
  }

  public nonisolated static func overlap(
    _ first: GlobalHotkeyBinding,
    _ second: GlobalHotkeyBinding
  ) -> Bool {
    // Fn alone fires on its down edge, so any other Fn-modified shortcut would
    // trigger it first.
    if first.isFunctionAlone, second.modifiers.contains(.function) { return true }
    if second.isFunctionAlone, first.modifiers.contains(.function) { return true }
    guard first.keyCode == second.keyCode else { return false }
    let firstBits = first.modifiers.rawValue
    let secondBits = second.modifiers.rawValue
    return firstBits & secondBits == firstBits
      || firstBits & secondBits == secondBits
  }

  private func restore(_ configuration: DictationHotkeyConfiguration?) async {
    guard let configuration else {
      active = nil
      return
    }
    let start = await provider.register(
      action: .startOrEnd,
      binding: configuration.startOrEnd
    )
    active = start == .registered ? configuration : nil
  }

  private nonisolated static func result(
    for registration: GlobalHotkeyRegistrationResult,
    action: GlobalHotkeyAction
  ) -> HotkeyConfigurationResult {
    switch registration {
    case .registered: .registered
    case .conflict: .conflict(action)
    case .unavailable(let code): .unavailable(action, code: code)
    }
  }
}

extension GlobalHotkeyBinding {
  /// The Globe/Fn key pressed on its own (virtual key 63).
  public var isFunctionAlone: Bool {
    keyCode == 63 && modifiers == [.function]
  }
}
