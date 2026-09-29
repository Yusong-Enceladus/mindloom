import AppKit
import BestASRAudioJournal
import BestASRDictation
import BestASRDomain
import BestASRFluidRuntime
import BestASRInference
import BestASRDelivery
import BestASRMLXRuntime
import BestASRMacAudio
import BestASRMacPermissions
import BestASRMacUI
import BestASRModelManager
import BestASRPersistence
import BestASRPortableArchiveProbe
import BestASRProcessing
import BestASRQwenRuntime
import Combine
import CoreGraphics
import CryptoKit
import Foundation
import OSLog
import ServiceManagement
import UniformTypeIdentifiers

// Settings: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  /// Opens the Keyboard pane; bestASR never changes the system setting itself.
  func openKeyboardSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    else { return }
    NSWorkspace.shared.open(url)
  }

  func applyRuntimePreferences() {
    guard let localRuntime else { return }
    let polish = defaultPolishEnabled
    let cleanup = people.personalCleanupEnabled
    let policies = appTextPolicies
    let remember = people.speakerMemoryEnabled
    Task {
      await localRuntime.configureUserPreferences(
        defaultPolishEnabled: polish,
        personalCleanupEnabled: cleanup,
        appPolicies: policies,
        speakerMemoryEnabled: remember
      )
    }
  }

  func startOrEndFromMenuBar() {
    startOrEnd(
      preCapturedTarget: nil,
      captureExternalTargetWhenMissing: true
    )
  }

  func portableSettings() -> [PortableSetting] {
    var settings = [
      PortableSetting(
        key: "hotkey.start-end-key-code",
        value: String(hotkeys.startEndHotkeyBinding.keyCode)
      ),
      PortableSetting(
        key: "hotkey.start-end-modifiers",
        value: String(hotkeys.startEndHotkeyBinding.modifiers.rawValue)
      ),
      PortableSetting(
        key: "system-audio.include-microphone",
        value: history.includeMicrophoneInSystemRecording ? "true" : "false"
      ),
      PortableSetting(
        key: "room.microphone-uid",
        value: capture.selectedRoomMicrophoneUID
      ),
      PortableSetting(
        key: "system-audio.microphone-uid",
        value: capture.selectedSystemMicrophoneUID
      ),
      PortableSetting(
        key: "system-audio.source",
        value: capture.selectedSystemAudioSourceID
      ),
      PortableSetting(
        key: "preferences.interface-language",
        value: spoken.interfaceLanguageID
      ),
      PortableSetting(
        key: "preferences.menu-bar-enabled",
        value: menuBarEnabled ? "true" : "false"
      ),
      PortableSetting(
        key: "preferences.default-polish-enabled",
        value: defaultPolishEnabled ? "true" : "false"
      ),
      PortableSetting(
        key: "preferences.speaker-memory-enabled",
        value: people.speakerMemoryEnabled ? "true" : "false"
      ),
      PortableSetting(
        key: "preferences.allow-model-downloads",
        value: models.allowModelDownloads ? "true" : "false"
      ),
      PortableSetting(
        key: "preferences.automatic-model-updates",
        value: models.automaticModelUpdates ? "true" : "false"
      ),
      PortableSetting(
        key: AppUpdateChecker.automaticChecksPreferenceKey,
        value: models.automaticAppUpdateChecks ? "true" : "false"
      ),
    ]
    if let data = try? JSONEncoder().encode(appTextPolicies) {
      settings.append(
        PortableSetting(
          key: "preferences.app-text-policies.v1",
          value: data.base64EncodedString()
        )
      )
    }
    if let data = try? JSONEncoder().encode(systemAudioMicrophoneOverrides) {
      settings.append(
        PortableSetting(
          key: "preferences.system-audio-microphone-overrides.v1",
          value: data.base64EncodedString()
        )
      )
    }
    return settings
  }

  func applyPortableSettings(_ settings: [PortableSetting]) async {
    let values = Dictionary(
      settings.map { ($0.key, $0.value) },
      uniquingKeysWith: { first, _ in first }
    )
    if let keyValue = values["hotkey.start-end-key-code"],
      let modifierValue = values["hotkey.start-end-modifiers"],
      let keyCode = UInt32(keyValue),
      let modifierBits = UInt32(modifierValue)
    {
      hotkeys.startEndHotkeyBinding = GlobalHotkeyBinding(
        keyCode: keyCode,
        modifiers: GlobalHotkeyModifiers(rawValue: modifierBits)
      )
    } else if let value = values["hotkey.start-end-preset"] {
      useHotkeyPreset(value, for: .startOrEnd)
    }
    if let value = values["room.microphone-uid"] {
      capture.selectedRoomMicrophoneUID = value
    }
    if let value = values["system-audio.microphone-uid"] {
      capture.selectedSystemMicrophoneUID = value
    }
    if let value = values["system-audio.source"] {
      capture.selectedSystemAudioSourceID = value
    }
    if let value = values[
      "preferences.system-audio-microphone-overrides.v1"
    ], let data = Data(base64Encoded: value),
      let overrides = try? JSONDecoder().decode(
        [String: Bool].self,
        from: data
      ), overrides.count <= 1_000,
      overrides.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1_024 })
    {
      systemAudioMicrophoneOverrides = overrides
      applySystemAudioMicrophonePreference(for: capture.selectedSystemAudioSourceID)
      persistSystemAudioMicrophoneOverrides()
    } else if let value = values["system-audio.include-microphone"] {
      // Archives produced before per-source defaults stored one global value.
      // Attach it to the restored source instead of whichever source happened
      // to be selected before import.
      setIncludeMicrophoneInSystemRecording(value == "true")
    } else {
      applySystemAudioMicrophonePreference(for: capture.selectedSystemAudioSourceID)
    }
    // V1 ships one complete UI language.  Ignore obsolete archive values that
    // selected the never-completed English development surface.
    spoken.interfaceLanguageID = "zh-Hans"
    if let value = values["preferences.menu-bar-enabled"] {
      menuBarEnabled = value == "true"
    }
    if let value = values["preferences.default-polish-enabled"] {
      setDefaultPolishEnabled(value == "true")
    }
    if let value = values["preferences.allow-model-downloads"] {
      setAllowModelDownloads(value == "true")
    }
    if let value = values["preferences.automatic-model-updates"] {
      setAutomaticModelUpdates(value == "true")
    }
    if let value = values[AppUpdateChecker.automaticChecksPreferenceKey] {
      setAutomaticAppUpdateChecks(value == "true")
    }
    if let value = values["preferences.app-text-policies.v1"],
      let data = Data(base64Encoded: value),
      let policies = try? JSONDecoder().decode([AppTextPolicy].self, from: data),
      policies.count <= 1_000,
      policies.allSatisfy({
        !$0.bundleIdentifier.isEmpty && $0.bundleIdentifier.count <= 255
      })
    {
      appTextPolicies = policies
      persistAppTextPolicies()
    }
    if let value = values["preferences.speaker-memory-enabled"] {
      let enabled = value == "true"
      if enabled {
        people.speakerMemoryEnabled = true
        LocalPreferenceStore.defaults.set(
          true,
          forKey: "preferences.speaker-memory-enabled"
        )
      } else if let repository {
        try? await repository.deleteAllSpeakerEmbeddings()
        people.speakerMemoryEnabled = false
        LocalPreferenceStore.defaults.set(
          false,
          forKey: "preferences.speaker-memory-enabled"
        )
      }
      applyRuntimePreferences()
    }
    if hotkeySelectionIsSafe { applyHotkeyConfiguration() }
  }
}
