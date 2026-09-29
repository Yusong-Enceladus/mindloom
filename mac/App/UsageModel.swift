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

/// UsageModel: the usage state, moved out of DictationAppModel without change.
/// Behaviour still lives on DictationAppModel+*.swift and reaches this
/// state as `usage.<property>`; moving it here concern by concern is the
/// next step. See DICTATION_ARCHITECTURE.md §13.5.
@MainActor
final class UsageModel: ObservableObject {
  @Published var usageStatistics = LocalHistoryUsageStatistics()

  @Published var usage = DictationUsageSummary()

  /// False until history has been read once. Until then the usage figures are
  /// unknown, not zero, and a zero shown for an unknown reads as "you have
  /// never used this" to someone with five thousand dictations on disk.
  @Published var usageLoaded = false
}
