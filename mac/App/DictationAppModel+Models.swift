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

// Models: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  /// Asks the system to install one language pair. The system runs its own
  /// prompt and manages the files; nothing is downloaded without that.
  func installTranslationLanguage(_ target: String) {
    guard models.translationInstallInProgress == nil else { return }
    models.translationInstallInProgress = target
    Task { [weak self] in
      guard let self else { return }
      _ = await translationInstaller.install(
        fromLanguageNamed: Self.translationSource(for: target),
        intoLanguageNamed: target
      )
      models.translationInstallInProgress = nil
      refreshTranslationEngineStatus()
    }
  }

  func updateMenuBarInsertion(_ isInserted: Bool) {
    // MenuBarExtra may write its current value back through the binding while
    // reconciling the scene. Re-publishing an unchanged value invalidates the
    // scene again and can create an unbounded SwiftUI update loop.
    guard menuBarEnabled != isInserted else { return }
    menuBarEnabled = isInserted
  }

  func setRecommendedComponentLicensesAccepted(_ accepted: Bool) {
    setSpeechModelLicenseAccepted(accepted)
    setPolishModelLicenseAccepted(accepted)
    setSpeakerModelLicenseAccepted(accepted)
  }

  func setSpeechModelLicenseAccepted(_ accepted: Bool) {
    models.modelLicenseAccepted = accepted
    guard !fixtureMode else { return }
    LocalModelLicenseReceipts.setAccepted(
      accepted,
      key: Self.speechLicenseReceiptKey,
      receipt: Self.speechLicenseReceipt
    )
  }

  func setPolishModelLicenseAccepted(_ accepted: Bool) {
    models.polishModelLicenseAccepted = accepted
    guard !fixtureMode else { return }
    LocalModelLicenseReceipts.setAccepted(
      accepted,
      key: Self.polishLicenseReceiptKey,
      receipt: Self.polishLicenseReceipt
    )
  }

  nonisolated static func modelReadinessHeadline(
    ready: Bool,
    message: String
  ) -> String {
    if ready { return "已就绪" }
    if message.hasPrefix("正在检查") { return "正在校验" }
    return "需要准备"
  }

  func downloadRecommendedModels() {
    guard models.allowModelDownloads else {
      models.recommendedModelProgressMessage =
        "组件下载已在隐私设置中关闭；仍可使用高级离线部署选择本地文件夹"
      return
    }
    guard canInstallRecommendedModels, !models.recommendedModelInstallInProgress else {
      models.recommendedModelProgressMessage =
        "请先阅读并接受上方三个本地组件许可"
      return
    }
    if fixtureMode {
      models.recommendedModelProgress = 1
      models.modelRuntimeReady = true
      enhancedFinalASRReady = true
      models.modelReadinessMessage = "本机语音识别测试组件已就绪"
      polishRuntimeReady = true
      polishReadinessMessage = "本机文字整理测试组件已就绪"
      people.speakerRuntimeReady = true
      people.speakerReadinessMessage = "本机多人识别测试组件已就绪"
      models.recommendedModelProgressMessage =
        "三个本地组件均已校验并可离线使用"
      return
    }
    guard let localRuntime else {
      models.recommendedModelProgressMessage = "本地组件服务暂不可用"
      return
    }
    models.recommendedModelInstallInProgress = true
    models.modelInstallInProgress = true
    models.polishModelInstallInProgress = true
    models.speakerModelInstallInProgress = true
    models.recommendedModelProgress = 0
    models.recommendedModelProgressMessage =
      "正在下载并校验语音识别组件…"
    recommendedModelInstallTask = Task { [weak self] in
      guard let self else { return }
      defer {
        models.recommendedModelInstallInProgress = false
        models.modelInstallInProgress = false
        models.polishModelInstallInProgress = false
        models.speakerModelInstallInProgress = false
        recommendedModelInstallTask = nil
      }
      var failedComponents: [String] = []
      let speechWasReady = models.modelRuntimeReady
      let enhancedWasReady = enhancedFinalASRReady
      do {
        try await localRuntime.downloadRecommendedSpeechModel { [weak self] state in
          Task { @MainActor [weak self] in
            self?.applyDistributionState(
              state,
              component: "语音识别",
              offset: 0,
              weight: Double(Self.recommendedSpeechBytes) / Double(Self.recommendedTotalBytes)
            )
          }
        }
        models.modelRuntimeReady = true
        enhancedFinalASRReady = await localRuntime.hasEnhancedFinalASR()
        models.modelReadinessMessage = "本地语音识别与时间对齐已就绪"
        await localRuntime.beginFinalASRPrewarm()
      } catch {
        // An interrupted upgrade does not revoke an already usable local
        // speech pack or force the user to reinstall working components.
        if Task.isCancelled {
          models.modelRuntimeReady = speechWasReady
          enhancedFinalASRReady = enhancedWasReady
        } else {
          models.modelRuntimeReady = await localRuntime.discoverInstalledASR()
          enhancedFinalASRReady = await localRuntime.hasEnhancedFinalASR()
        }
        models.modelReadinessMessage =
          models.modelRuntimeReady
          ? "基础识别仍可用；增强组件安装未完成，可稍后继续"
          : "本地语音组件尚未准备；录音仍会保留供稍后处理"
        failedComponents.append("语音识别")
      }
      guard !Task.isCancelled else { return }

      do {
        try await localRuntime.downloadRecommendedSpeakerModel { [weak self] state in
          Task { @MainActor [weak self] in
            self?.applyDistributionState(
              state,
              component: "多人识别",
              offset: Double(Self.recommendedSpeechBytes) / Double(Self.recommendedTotalBytes),
              weight: 21_602_781.0 / Double(Self.recommendedTotalBytes)
            )
          }
        }
        people.speakerRuntimeReady = true
        people.speakerReadinessMessage = "本地多人识别组件已就绪"
      } catch {
        people.speakerRuntimeReady = false
        failedComponents.append("多人识别")
      }
      guard !Task.isCancelled else { return }

      do {
        try await localRuntime.downloadRecommendedPolishModel { [weak self] state in
          Task { @MainActor [weak self] in
            self?.applyDistributionState(
              state,
              component: "文字整理",
              offset: Double(Self.recommendedSpeechBytes + 21_602_781)
                / Double(Self.recommendedTotalBytes),
              weight: 930_271_884.0 / Double(Self.recommendedTotalBytes)
            )
          }
        }
        polishRuntimeReady = true
        polishReadinessMessage =
          "本地文字整理组件已就绪，并启用事实保护回退"
      } catch {
        polishRuntimeReady = false
        failedComponents.append("文字整理")
      }
      if failedComponents.isEmpty {
        models.recommendedModelProgress = 1
        models.recommendedModelProgressMessage = "三个本地组件均已校验并可离线使用"
        statusMessage = "已就绪——按 \(startEndShortcutTitle) 开始本地口述"
      } else {
        models.recommendedModelProgressMessage =
          "\(failedComponents.joined(separator: "、"))未完成；再次点击会从已校验进度继续"
        statusMessage =
          models.modelRuntimeReady
          ? "语音输入可用；其余本地组件可继续安装"
          : "语音识别组件尚未完成；可以先录音，稍后继续处理"
      }
    }
  }

  func cancelRecommendedModelDownload() {
    guard models.recommendedModelInstallInProgress else { return }
    models.recommendedModelProgressMessage =
      "正在安全暂停；已校验文件会保留，稍后可继续…"
    recommendedModelInstallTask?.cancel()
  }

  func verifyInstalledModels() {
    guard !models.recommendedModelInstallInProgress else { return }
    models.modelManagementStatusMessage = "正在逐文件校验已安装组件…"
    Task { [weak self] in
      guard let self else { return }
      await discoverInstalledModels()
      models.modelManagementStatusMessage =
        models.modelRuntimeReady
          && enhancedFinalASRReady && people.speakerRuntimeReady && polishRuntimeReady
        ? "推荐组件文件校验通过；模型将在本机按需加载"
        : "部分推荐组件尚未准备；已有组件仍可使用，可继续安装缺失部分"
      refreshStorageUsage()
    }
  }

  func restoreLastKnownGoodModel(_ component: LocalModelComponent) {
    guard !hasActiveCapture, let localRuntime else {
      models.modelManagementStatusMessage = "请先结束当前录音或导入"
      return
    }
    models.modelManagementStatusMessage = "正在校验并恢复上一可用的\(component.title)版本…"
    Task { [weak self] in
      guard let self else { return }
      do {
        try await localRuntime.restoreLastKnownGoodModel(component)
        await discoverInstalledModels()
        models.modelManagementStatusMessage =
          "\(component.title)已恢复到上一可用版本；组件文件已重新校验"
      } catch {
        models.modelManagementStatusMessage =
          "没有可恢复的独立上一版本；当前已校验组件未被更改"
      }
    }
  }

  func setAllowModelDownloads(_ enabled: Bool) {
    models.allowModelDownloads = enabled
    LocalPreferenceStore.defaults.set(
      enabled,
      forKey: "preferences.allow-model-downloads"
    )
    if !enabled {
      models.automaticModelUpdates = false
      LocalPreferenceStore.defaults.set(
        false,
        forKey: "preferences.automatic-model-updates"
      )
      cancelRecommendedModelDownload()
    }
  }

  func setAutomaticModelUpdates(_ enabled: Bool) {
    guard !enabled || models.allowModelDownloads else {
      preferencesStatusMessage = "请先允许组件下载"
      return
    }
    models.automaticModelUpdates = enabled
    LocalPreferenceStore.defaults.set(
      enabled,
      forKey: "preferences.automatic-model-updates"
    )
  }

  func setAutomaticAppUpdateChecks(_ enabled: Bool) {
    models.automaticAppUpdateChecks = enabled
    LocalPreferenceStore.defaults.set(
      enabled,
      forKey: AppUpdateChecker.automaticChecksPreferenceKey
    )
    models.appUpdateStatusMessage =
      enabled
      ? "已开启自动检查更新"
      : "已关闭自动检查；仍可随时手动检查"
  }

  func checkForAppUpdate() {
    performAppUpdateCheck(silentWhenCurrent: false)
  }

  func openAvailableAppUpdate() {
    guard let availableAppUpdateURL = models.availableAppUpdateURL else { return }
    NSWorkspace.shared.open(availableAppUpdateURL)
  }

  func performAppUpdateCheck(silentWhenCurrent: Bool) {
    guard !models.appUpdateCheckInProgress else { return }
    let currentVersion =
      Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
      ) as? String ?? "0"
    models.appUpdateCheckInProgress = true
    if !silentWhenCurrent {
      models.appUpdateStatusMessage = "正在检查公开发布版本…"
    }
    Task { [weak self] in
      guard let self else { return }
      defer { models.appUpdateCheckInProgress = false }
      do {
        let result = try await appUpdateChecker.check(
          currentVersion: currentVersion
        )
        if result.updateAvailable {
          models.availableAppUpdateURL = result.releasePageURL
          models.appUpdateStatusMessage =
            "发现 \(result.latestVersion)；打开官方发布页下载签名、公证版本"
        } else {
          models.availableAppUpdateURL = nil
          if !silentWhenCurrent {
            models.appUpdateStatusMessage = "当前 \(currentVersion) 已是最新公开版本"
          }
        }
      } catch {
        models.availableAppUpdateURL = nil
        if !silentWhenCurrent {
          models.appUpdateStatusMessage =
            "暂时无法检查更新；录音、识别和历史仍可完全离线使用"
        }
      }
    }
  }

  func chooseAndInstallLocalModel() {
    guard models.modelLicenseAccepted, !models.modelInstallInProgress else {
      models.modelReadinessMessage =
        "请先阅读并接受上方语音识别组件许可"
      return
    }
    let panel = NSOpenPanel()
    panel.title = "选择已固定版本的混输识别组件文件夹"
    panel.prompt = "安装本地组件"
    panel.message =
      "请选择包含固定 Core ML 模型目录和 vocab.json 的文件夹。应用只在本机复制并逐项校验。"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let source = panel.url else { return }

    models.modelInstallInProgress = true
    models.modelRuntimeReady = false
    models.modelReadinessMessage = "正在本机校验并安装语音识别组件…"
    Task { [weak self] in
      guard let self else { return }
      defer { models.modelInstallInProgress = false }
      do {
        guard let localRuntime else { return }
        try await localRuntime.installModel(from: source)
        models.modelRuntimeReady = true
        models.modelReadinessMessage = "本地语音识别组件已就绪"
        statusMessage = "已就绪——按设置的全局快捷键开始口述"
      } catch {
        models.modelRuntimeReady = false
        models.modelReadinessMessage =
          "组件被拒绝：文件夹、版本、大小、摘要或运行检查不匹配"
      }
    }
  }

  func chooseAndInstallPolishModel() {
    guard models.polishModelLicenseAccepted, !models.polishModelInstallInProgress else {
      polishReadinessMessage =
        "请先阅读并接受上方文字整理组件许可"
      return
    }
    let panel = NSOpenPanel()
    panel.title = "选择已固定版本的 Qwen3 1.7B MLX 文件夹"
    panel.prompt = "安装本地文字整理组件"
    panel.message =
      "请选择精确固定的 Qwen3-1.7B-MLX-4bit 文件夹。文件只在本机复制并校验，运行时不会联网补文件。"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let source = panel.url else { return }

    models.polishModelInstallInProgress = true
    polishRuntimeReady = false
    polishReadinessMessage = "正在本机校验并安装文字整理组件…"
    Task { [weak self] in
      guard let self else { return }
      defer { models.polishModelInstallInProgress = false }
      do {
        guard let localRuntime else { return }
        try await localRuntime.installPolishModel(from: source)
        polishRuntimeReady = true
        polishReadinessMessage =
          "本地文字整理组件已就绪，并启用事实保护"
        statusMessage = "已就绪——本机识别和事实保护整理均可用"
      } catch {
        polishRuntimeReady = false
        polishReadinessMessage =
          "组件被拒绝：文件夹、版本、大小、摘要或加载检查不匹配"
      }
    }
  }

  func discoverInstalledModels() async {
    guard !fixtureMode, let localRuntime else { return }
    models.modelReadinessMessage = "正在检查已验证的本地语音模型…"
    polishReadinessMessage = "正在检查已验证的本地润色模型…"
    people.speakerReadinessMessage = "正在检查已验证的本地多人识别组件…"
    await Self.discoverModelsProgressively(
      discoverASR: { [weak self] in
        let ready = await localRuntime.discoverInstalledASR()
        let enhanced = await localRuntime.hasEnhancedFinalASR()
        await self?.publishEnhancedASRReadiness(enhanced)
        return ready
      },
      publishASR: { [weak self] ready in self?.publishASRReadiness(ready) },
      discoverSpeaker: { await localRuntime.discoverInstalledSpeaker() },
      publishSpeaker: { [weak self] ready in
        self?.publishSpeakerReadiness(ready)
      },
      discoverPolish: { await localRuntime.discoverInstalledPolish() },
      publishPolish: { [weak self] ready in self?.publishPolishReadiness(ready) }
    )
    let hasPersonalCleanup = await localRuntime.hasPersonalCleanupModel()
    models.personalCleanupInstalled = hasPersonalCleanup
    // All ordinary component discovery is complete before the larger final
    // decoders are warmed. This avoids competing with first-launch checks, but
    // removes the minute-long cold load from the user's first End action.
    await localRuntime.beginFinalASRPrewarm()
  }

  nonisolated static func discoverModelsProgressively(
    discoverASR: @escaping @Sendable () async -> Bool,
    publishASR: @escaping @MainActor @Sendable (Bool) -> Void,
    discoverSpeaker: @escaping @Sendable () async -> Bool,
    publishSpeaker: @escaping @MainActor @Sendable (Bool) -> Void,
    discoverPolish: @escaping @Sendable () async -> Bool,
    publishPolish: @escaping @MainActor @Sendable (Bool) -> Void
  ) async {
    let asrReady = await discoverASR()
    await publishASR(asrReady)
    let speakerReady = await discoverSpeaker()
    await publishSpeaker(speakerReady)
    let polishReady = await discoverPolish()
    await publishPolish(polishReady)
  }
}
