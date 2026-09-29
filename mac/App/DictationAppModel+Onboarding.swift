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

// Onboarding: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  static func diagnosticPermissionTitle(
    _ state: DictationPermissionState
  ) -> String {
    switch state {
    case .granted: "已允许"
    case .denied: "已拒绝"
    case .notDetermined: "尚未选择"
    case .restricted: "受系统限制"
    case .revoked: "权限已关闭"
    case .restartRequired: "已允许，重新打开 App 后生效"
    }
  }

  func setOnboardingPracticeTargetArmed(_ armed: Bool) {
    onboardingPracticeTargetArmed = armed
  }

  func refreshPermissions() {
    Task { [weak self] in
      await self?.readPermissionStates(refreshHotkeysWhenGranted: true)
    }
  }

  func resolvePermission(_ kind: DictationPermissionKind) {
    if fixtureMode {
      switch kind {
      case .microphone:
        capture.microphonePermission = .granted
      case .accessibility:
        onboarding.accessibilityPermission = .granted
      case .systemAudioCapture:
        capture.systemAudioPermission = .granted
      }
      onboarding.permissionActionMessage = "权限已允许"
      return
    }
    onboarding.permissionActionMessage = "正在打开系统权限…"
    NSApplication.shared.activate(ignoringOtherApps: true)
    Task { [weak self] in
      guard let self, let permissionService else { return }
      let current = await permissionService.state(for: kind)
      if current == .notDetermined {
        let requested = await permissionService.request(kind)
        if kind == .systemAudioCapture, requested == .denied {
          await permissionService.openRecoverySettings(for: kind)
        }
      } else if current != .granted && current != .restartRequired {
        await permissionService.openRecoverySettings(for: kind)
      }
      await readPermissionStates(refreshHotkeysWhenGranted: true)
      let resolvedState = permissionState(for: kind)
      onboarding.permissionActionMessage =
        resolvedState == .granted
        ? "权限已允许"
        : resolvedState == .restartRequired
          ? "系统已允许；请退出并重新打开织机使系统音频权限生效"
          : "请在系统提示或系统设置中允许织机"
      if resolvedState != .granted && resolvedState != .restartRequired {
        beginPermissionRefreshMonitoring(kind)
      }
    }
  }

  func beginPermissionRefreshMonitoring(
    _ kind: DictationPermissionKind
  ) {
    permissionRefreshTask?.cancel()
    permissionRefreshTask = Task { [weak self] in
      guard let self else { return }
      // System Settings may update TCC while bestASR is in the background.
      // Poll locally for one minute so the UI and Fn event tap recover without
      // requiring a relaunch or another button press.
      for _ in 0..<120 {
        guard !Task.isCancelled else { return }
        try? await Task.sleep(for: .milliseconds(500))
        await readPermissionStates(refreshHotkeysWhenGranted: true)
        if permissionState(for: kind) == .granted {
          onboarding.permissionActionMessage = "权限已允许，全局快捷键已刷新"
          permissionRefreshTask = nil
          return
        }
      }
      permissionRefreshTask = nil
    }
  }

  func permissionState(
    for kind: DictationPermissionKind
  ) -> DictationPermissionState {
    switch kind {
    case .microphone: capture.microphonePermission
    case .accessibility: onboarding.accessibilityPermission
    case .systemAudioCapture: capture.systemAudioPermission
    }
  }

  func openPermissionSettings(_ kind: DictationPermissionKind) {
    Task { [weak self] in
      await self?.permissionService?.openRecoverySettings(for: kind)
    }
  }

  func readPermissionStates(
    refreshHotkeysWhenGranted: Bool = false
  ) async {
    guard let permissionService else { return }
    capture.microphonePermission = await permissionService.state(for: .microphone)
    onboarding.accessibilityPermission = await permissionService.state(for: .accessibility)
    capture.systemAudioPermission = await permissionService.state(
      for: .systemAudioCapture
    )
    if !refreshHotkeysWhenGranted { publishIdleReadinessStatus() }
    guard refreshHotkeysWhenGranted,
      !hasActiveCapture,
      let hotkeyController
    else { return }
    // Explicit refreshes and App re-activation also retry the native event
    // tap. A transient tap-registration failure must not leave an already
    // authorized Fn shortcut dead while the UI continues to say "已允许".
    let result = await hotkeyController.refreshActiveRegistration()
    await publishHotkeyResult(result, controller: hotkeyController)
  }

  func inspectSetupCompatibility(dataRoot: URL) {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let supportedOS =
      version.majorVersion > 14
      || (version.majorVersion == 14 && version.minorVersion >= 2)
    #if arch(arm64)
      let supportedArchitecture = true
    #else
      let supportedArchitecture = false
    #endif
    let supportedMemory = ProcessInfo.processInfo.physicalMemory >= 16 * 1_073_741_824
    let values = try? dataRoot.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey
    ])
    let available = values?.volumeAvailableCapacityForImportantUsage ?? 0
    let supportedDisk = available >= 4 * 1_073_741_824
    onboarding.setupHardwareSupported =
      supportedOS && supportedArchitecture
      && supportedMemory && supportedDisk
    if !supportedOS {
      onboarding.setupCompatibilityMessage = "需要 macOS 14.2 或更高版本"
    } else {
      #if !arch(arm64)
        onboarding.setupCompatibilityMessage = "需要 Apple Silicon Mac"
      #else
        if !supportedMemory {
          onboarding.setupCompatibilityMessage = "需要至少 16 GB 统一内存"
        } else if !supportedDisk {
          onboarding.setupCompatibilityMessage = "需要至少 4 GB 可用磁盘空间"
        } else {
          let memoryGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
          let diskGB = max(0, available) / 1_073_741_824
          onboarding.setupCompatibilityMessage = "这台 Mac 可以使用推荐配置 · \(memoryGB) GB 内存 · \(diskGB) GB 可用"
        }
      #endif
    }
  }
}
