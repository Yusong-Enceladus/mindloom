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

/// MemorySearchModel: the memorySearch state, moved out of DictationAppModel without change.
/// Behaviour still lives on DictationAppModel+*.swift and reaches this
/// state as `memorySearch.<property>`; moving it here concern by concern is the
/// next step. See DICTATION_ARCHITECTURE.md §13.5.
@MainActor
final class MemorySearchModel: ObservableObject {
  @Published var searchQuery = ""

  @Published var searchHistoryItems: [DictationHistoryItem] = []

  @Published var searchPersonSummaries: [PersonSummary] = []

  @Published var searchEventSummaries: [EventSummary] = []

  @Published var searchInProgress = false

  @Published var searchStatusMessage =
    "搜索逐字稿、整理、人物、事件和来源"
}
