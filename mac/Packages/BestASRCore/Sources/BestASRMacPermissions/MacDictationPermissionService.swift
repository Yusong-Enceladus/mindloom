import AVFoundation
import AppKit
import ApplicationServices
import BestASRDictation
import Foundation

public enum MacRawPermissionState: String, Codable, Sendable {
  case authorized
  case denied
  case notDetermined
  case restricted
}

public protocol MacMicrophonePermissionClient: Sendable {
  func authorizationState() async -> MacRawPermissionState
  func requestAccess() async -> Bool
}

public protocol MacAccessibilityPermissionClient: Sendable {
  func isTrusted(prompt: Bool) async -> Bool
  func openSettings() async
}

public protocol MacSystemAudioPermissionClient: Sendable {
  func isAuthorized() async -> Bool
  func requestAccess() async -> Bool
  func openSettings() async
}

public protocol MacPermissionHistoryStore: Sendable {
  func bool(forKey key: String) async -> Bool
  func set(_ value: Bool, forKey key: String) async
}

public actor UserDefaultsMacPermissionHistoryStore:
  MacPermissionHistoryStore
{
  private let defaults: UserDefaults

  public init(suiteName: String? = nil) {
    if let suiteName, let suiteDefaults = UserDefaults(suiteName: suiteName) {
      defaults = suiteDefaults
    } else {
      defaults = .standard
    }
  }

  public func bool(forKey key: String) -> Bool {
    defaults.bool(forKey: key)
  }

  public func set(_ value: Bool, forKey key: String) {
    defaults.set(value, forKey: key)
  }
}

public struct SystemMacMicrophonePermissionClient: MacMicrophonePermissionClient {
  public init() {}

  public func authorizationState() async -> MacRawPermissionState {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: .authorized
    case .denied: .denied
    case .notDetermined: .notDetermined
    case .restricted: .restricted
    @unknown default: .restricted
    }
  }

  public func requestAccess() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }
}

public struct SystemMacAccessibilityPermissionClient:
  MacAccessibilityPermissionClient
{
  public init() {}

  public func isTrusted(prompt: Bool) async -> Bool {
    guard prompt else { return AXIsProcessTrusted() }
    let options =
      [
        "AXTrustedCheckOptionPrompt": true
      ] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  public func openSettings() async {
    guard
      let url = URL(
        string:
          "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      )
    else { return }
    _ = await MainActor.run { NSWorkspace.shared.open(url) }
  }
}

public struct SystemMacSystemAudioPermissionClient:
  MacSystemAudioPermissionClient
{
  public init() {}

  public func isAuthorized() async -> Bool {
    CGPreflightScreenCaptureAccess()
  }

  public func requestAccess() async -> Bool {
    await MainActor.run { CGRequestScreenCaptureAccess() }
  }

  public func openSettings() async {
    guard
      let url = URL(
        string:
          "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
      )
    else { return }
    _ = await MainActor.run { NSWorkspace.shared.open(url) }
  }
}

public actor MacDictationPermissionService: DictationPermissionPort {
  private enum HistoryKey {
    static let microphoneGranted = "permissions.microphone-granted-v1"
    static let accessibilityRequested = "permissions.accessibility-requested-v1"
    static let accessibilityGranted = "permissions.accessibility-granted-v1"
    static let systemAudioRequested = "permissions.system-audio-requested-v1"
    static let systemAudioGranted = "permissions.system-audio-granted-v1"
  }

  private let microphone: any MacMicrophonePermissionClient
  private let accessibility: any MacAccessibilityPermissionClient
  private let systemAudio: any MacSystemAudioPermissionClient
  private let history: any MacPermissionHistoryStore
  private var historyLoaded = false
  private var microphoneWasGranted = false
  private var accessibilityWasGranted = false
  private var accessibilityWasRequested = false
  private var systemAudioWasGranted = false
  private var systemAudioWasRequested = false
  private var systemAudioGrantNeedsRestart = false

  public init(
    microphone: any MacMicrophonePermissionClient =
      SystemMacMicrophonePermissionClient(),
    accessibility: any MacAccessibilityPermissionClient =
      SystemMacAccessibilityPermissionClient(),
    systemAudio: any MacSystemAudioPermissionClient =
      SystemMacSystemAudioPermissionClient(),
    history: any MacPermissionHistoryStore =
      UserDefaultsMacPermissionHistoryStore()
  ) {
    self.microphone = microphone
    self.accessibility = accessibility
    self.systemAudio = systemAudio
    self.history = history
  }

  public func state(
    for permission: DictationPermissionKind
  ) async -> DictationPermissionState {
    await loadHistoryIfNeeded()
    switch permission {
    case .microphone:
      switch await microphone.authorizationState() {
      case .authorized:
        if !microphoneWasGranted {
          microphoneWasGranted = true
          await history.set(true, forKey: HistoryKey.microphoneGranted)
        }
        return .granted
      case .denied:
        return microphoneWasGranted ? .revoked : .denied
      case .notDetermined:
        return .notDetermined
      case .restricted:
        return .restricted
      }
    case .accessibility:
      if await accessibility.isTrusted(prompt: false) {
        if !accessibilityWasGranted {
          accessibilityWasGranted = true
          await history.set(true, forKey: HistoryKey.accessibilityGranted)
        }
        return .granted
      }
      if accessibilityWasGranted { return .revoked }
      return accessibilityWasRequested ? .denied : .notDetermined
    case .systemAudioCapture:
      if await systemAudio.isAuthorized() {
        if !systemAudioWasGranted {
          systemAudioWasGranted = true
          await history.set(true, forKey: HistoryKey.systemAudioGranted)
        }
        systemAudioGrantNeedsRestart = false
        return .granted
      }
      if systemAudioGrantNeedsRestart { return .restartRequired }
      if systemAudioWasGranted { return .revoked }
      return systemAudioWasRequested ? .denied : .notDetermined
    }
  }

  public func request(
    _ permission: DictationPermissionKind
  ) async -> DictationPermissionState {
    await loadHistoryIfNeeded()
    switch permission {
    case .microphone:
      if await microphone.authorizationState() == .notDetermined {
        _ = await microphone.requestAccess()
      }
    case .accessibility:
      accessibilityWasRequested = true
      await history.set(true, forKey: HistoryKey.accessibilityRequested)
      _ = await accessibility.isTrusted(prompt: true)
    case .systemAudioCapture:
      systemAudioWasRequested = true
      await history.set(true, forKey: HistoryKey.systemAudioRequested)
      let alreadyAuthorized = await systemAudio.isAuthorized()
      if !alreadyAuthorized {
        let requestAccepted = await systemAudio.requestAccess()
        if requestAccepted {
          let visibleToCurrentProcess = await systemAudio.isAuthorized()
          systemAudioGrantNeedsRestart = !visibleToCurrentProcess
        }
      }
    }
    return await state(for: permission)
  }

  private func loadHistoryIfNeeded() async {
    guard !historyLoaded else { return }
    microphoneWasGranted = await history.bool(
      forKey: HistoryKey.microphoneGranted
    )
    accessibilityWasRequested = await history.bool(
      forKey: HistoryKey.accessibilityRequested
    )
    accessibilityWasGranted = await history.bool(
      forKey: HistoryKey.accessibilityGranted
    )
    systemAudioWasRequested = await history.bool(
      forKey: HistoryKey.systemAudioRequested
    )
    systemAudioWasGranted = await history.bool(
      forKey: HistoryKey.systemAudioGranted
    )
    historyLoaded = true
  }

  public func openRecoverySettings(
    for permission: DictationPermissionKind
  ) async {
    switch permission {
    case .microphone:
      guard
        let url = URL(
          string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
      else { return }
      _ = await MainActor.run { NSWorkspace.shared.open(url) }
    case .accessibility:
      await accessibility.openSettings()
    case .systemAudioCapture:
      await systemAudio.openSettings()
    }
  }
}

public struct MacPermissionConfigurationReport: Equatable, Sendable {
  public let microphoneUsageDescriptionPresent: Bool
  public let systemAudioUsageDescriptionPresent: Bool
  public let audioInputEntitlementEnabled: Bool
  public let alphaRequestableKinds: Set<DictationPermissionKind>

  public init(
    microphoneUsageDescriptionPresent: Bool,
    systemAudioUsageDescriptionPresent: Bool,
    audioInputEntitlementEnabled: Bool,
    alphaRequestableKinds: Set<DictationPermissionKind>
  ) {
    self.microphoneUsageDescriptionPresent = microphoneUsageDescriptionPresent
    self.systemAudioUsageDescriptionPresent = systemAudioUsageDescriptionPresent
    self.audioInputEntitlementEnabled = audioInputEntitlementEnabled
    self.alphaRequestableKinds = alphaRequestableKinds
  }
}

public enum MacPermissionConfigurationError: Error, Equatable, Sendable {
  case invalidEntitlements
  case invalidInfoPlist
  case missingMicrophoneConfiguration
}

public enum MacPermissionConfigurationValidator {
  public static func validate(
    infoPlistURL: URL,
    entitlementsURL: URL
  ) throws -> MacPermissionConfigurationReport {
    guard let infoData = try? Data(contentsOf: infoPlistURL),
      let info = try? PropertyListSerialization.propertyList(
        from: infoData,
        format: nil
      ) as? [String: Any]
    else { throw MacPermissionConfigurationError.invalidInfoPlist }
    guard let entitlementData = try? Data(contentsOf: entitlementsURL),
      let entitlements = try? PropertyListSerialization.propertyList(
        from: entitlementData,
        format: nil
      ) as? [String: Any]
    else { throw MacPermissionConfigurationError.invalidEntitlements }
    let microphoneDescription = info["NSMicrophoneUsageDescription"] as? String
    let systemAudioDescription = info["NSAudioCaptureUsageDescription"] as? String
    let microphonePresent = !(microphoneDescription ?? "").isEmpty
    let audioInputEnabled =
      entitlements["com.apple.security.device.audio-input"] as? Bool == true
    guard microphonePresent, audioInputEnabled else {
      throw MacPermissionConfigurationError.missingMicrophoneConfiguration
    }
    return MacPermissionConfigurationReport(
      microphoneUsageDescriptionPresent: microphonePresent,
      systemAudioUsageDescriptionPresent: !(systemAudioDescription ?? "").isEmpty,
      audioInputEntitlementEnabled: audioInputEnabled,
      alphaRequestableKinds: [.microphone, .accessibility]
    )
  }
}
