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

// Hotkeys: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  func useHotkeyPreset(
    _ presetID: String,
    for action: GlobalHotkeyAction
  ) {
    guard
      let preset = DictationHotkeyPreset.alphaPresets.first(where: {
        $0.id == presetID
      })
    else { return }
    switch action {
    case .startOrEnd:
      hotkeys.startEndHotkeyPresetID = presetID
      hotkeys.startEndHotkeyBinding = preset.binding
    case .pauseOrResume, .cancel:
      break
    }
  }

  func applyHotkeyConfiguration() {
    guard hotkeySelectionIsSafe else {
      hotkeys.hotkeyStatusMessage = "快捷键至少要带一个修饰键"
      return
    }
    let configuration = DictationHotkeyConfiguration(
      startOrEnd: hotkeys.startEndHotkeyBinding
    )
    if fixtureMode {
      hotkeys.hotkeyStatusMessage = "快捷键配置已在本机验证"
      return
    }
    guard let hotkeyController else {
      hotkeys.hotkeyStatusMessage = "全局快捷键暂不可用"
      return
    }
    hotkeys.hotkeyStatusMessage = "正在注册全局快捷键…"
    Task { [weak self] in
      guard let self else { return }
      let result = await hotkeyController.apply(configuration)
      await publishHotkeyResult(result, controller: hotkeyController)
    }
  }

  func beginHotkeyObservation(
    using provider: NativeGlobalHotkeyProvider
  ) async {
    if let existingTask = hotkeyTask {
      existingTask.cancel()
      await existingTask.value
      hotkeyTask = nil
    }
    let transitions = await provider.transitions()
    hotkeyTask = Task { [weak self] in
      for await transition in transitions {
        guard let self else { return }
        await self.handle(transition)
      }
    }
  }

  func publishHotkeyResult(
    _ result: HotkeyConfigurationResult,
    controller: GlobalHotkeyConfigurationController
  ) async {
    let activeConfiguration = await controller.activeConfiguration()
    hotkeyRegistrationAvailable = activeConfiguration != nil
    if let active = activeConfiguration {
      hotkeys.startEndHotkeyBinding = active.startOrEnd
      refreshGlobeKeyConflict()
      hotkeys.startEndHotkeyPresetID =
        DictationHotkeyPreset.preset(for: active.startOrEnd)?.id ?? "custom"
    }
    switch result {
    case .registered:
      hotkeys.hotkeyStatusMessage = "全局快捷键已保存并生效"
    case .conflict:
      hotkeys.hotkeyStatusMessage =
        "该快捷键已被其他 App 占用；原快捷键仍保持生效"
    case .invalidDuplicateBinding:
      hotkeys.hotkeyStatusMessage = "两组快捷键不能相同或使用彼此包含的修饰键"
    case .unavailable:
      hotkeys.hotkeyStatusMessage =
        "快捷键注册失败；原快捷键仍保持生效"
    }
    publishIdleReadinessStatus()
  }

  func captureHotkeyInsertionTarget() -> DictationTargetSnapshot? {
    let now = DispatchTime.now().uptimeNanoseconds
    if let preflightHotkeyInsertionTarget,
      now >= preflightHotkeyTargetUptimeNanoseconds,
      now - preflightHotkeyTargetUptimeNanoseconds < 1_000_000_000
    {
      self.preflightHotkeyInsertionTarget = nil
      preflightHotkeyTargetUptimeNanoseconds = 0
      dictationAppLogger.info("using preflight global hotkey insertion target")
      return preflightHotkeyInsertionTarget
    }
    preflightHotkeyInsertionTarget = nil
    preflightHotkeyTargetUptimeNanoseconds = 0
    do {
      let target = try captureHotkeyTarget()
      dictationAppLogger.info("global hotkey captured insertion target")
      return target
    } catch {
      let diagnostic = error as NSError
      dictationAppLogger.notice(
        "global hotkey target unavailable: domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code)"
      )
      return nil
    }
  }

  func preflightHotkeyTarget(identifier: UInt32) {
    guard identifier == GlobalHotkeyAction.startOrEnd.rawValue,
      canStartDictationNow,
      !capture.roomSnapshot.phase.isActive,
      !capture.systemAudioSnapshot.phase.isActive,
      !capture.importInProgress
    else {
      preflightHotkeyInsertionTarget = nil
      preflightHotkeyTargetUptimeNanoseconds = 0
      return
    }
    startMicrophoneAtKeyPress()
    do {
      preflightHotkeyInsertionTarget =
        try captureHotkeyTarget()
      preflightHotkeyTargetUptimeNanoseconds =
        DispatchTime.now().uptimeNanoseconds
      dictationAppLogger.info("global hotkey preflight captured insertion target")
    } catch {
      preflightHotkeyInsertionTarget = nil
      preflightHotkeyTargetUptimeNanoseconds = 0
      let diagnostic = error as NSError
      dictationAppLogger.notice(
        "global hotkey preflight target unavailable: domain=\(diagnostic.domain, privacy: .public) code=\(diagnostic.code)"
      )
    }
  }

  /// The application in front right now. Reading it is instantaneous, so
  /// the key-down path and the start path share one call.
  func captureHotkeyTarget() throws -> DictationTargetSnapshot {
    guard let insertionService else { throw DeliveryInsertionPort.CaptureError.noTarget }
    return try insertionService.captureTargetNow()
  }
}
