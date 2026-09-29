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

/// ExportModel: the export state, moved out of DictationAppModel without change.
/// Behaviour still lives on DictationAppModel+*.swift and reaches this
/// state as `export.<property>`; moving it here concern by concern is the
/// next step. See DICTATION_ARCHITECTURE.md §13.5.
@MainActor
final class ExportModel: ObservableObject {
  @Published var exportStatusMessage = ""

  @Published var exportInProgress = false

  @Published var exportSelectionStart = 0.0

  @Published var exportSelectionEnd = 0.0

  @Published var archiveSecretDraft = ""

  @Published var archiveSecretConfirmationDraft = ""

  @Published var archiveOperationInProgress = false

  @Published var archiveStatusMessage =
    "完整归档包含历史、原音、逐字稿、人物、词典和整理结果；不包含可重新下载的组件或缓存"
}
