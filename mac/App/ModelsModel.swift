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

/// ModelsModel: the models state, moved out of DictationAppModel without change.
/// Behaviour still lives on DictationAppModel+*.swift and reaches this
/// state as `models.<property>`; moving it here concern by concern is the
/// next step. See DICTATION_ARCHITECTURE.md §13.5.
@MainActor
final class ModelsModel: ObservableObject {
  @Published var modelRuntimeReady = false

  @Published var modelDiscoveryComplete = false

  @Published var modelReadinessMessage =
    "本地语音识别尚未准备"

  @Published var modelInstallInProgress = false

  @Published var modelLicenseAccepted = false

  @Published var polishModelInstallInProgress = false

  @Published var polishModelLicenseAccepted = false

  @Published var speakerModelInstallInProgress = false

  @Published var speakerModelLicenseAccepted = false

  @Published var recommendedModelInstallInProgress = false

  @Published var recommendedModelProgress = 0.0

  @Published var recommendedModelProgressMessage =
    "总计约 5.77 GB；已安装组件不会重复下载，运行所需模型保留在本机，临时下载文件使用缓存目录"

  @Published var translationInstallInProgress: String?

  @Published var personalCleanupInstalled = false

  @Published var allowModelDownloads = LocalPreferenceStore.bool(
    "preferences.allow-model-downloads",
    default: true
  )

  @Published var automaticModelUpdates = LocalPreferenceStore.bool(
    "preferences.automatic-model-updates",
    default: false
  )

  @Published var automaticAppUpdateChecks = LocalPreferenceStore.bool(
    AppUpdateChecker.automaticChecksPreferenceKey,
    default: AppUpdateChecker.automaticChecksEnabledByDefault
  )

  @Published var appUpdateCheckInProgress = false

  @Published var appUpdateStatusMessage =
    LocalPreferenceStore.bool(
      AppUpdateChecker.automaticChecksPreferenceKey,
      default: AppUpdateChecker.automaticChecksEnabledByDefault
    )
    ? "会定期检查是否有新版本"
    : "自动检查未开启；可随时手动检查"

  @Published var availableAppUpdateURL: URL?

  @Published var modelManagementStatusMessage =
    "本地组件会逐文件校验；更新失败时保留上一可用版本"
}
