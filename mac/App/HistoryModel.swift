import AppKit
import BestASRAudioJournal
import BestASRDelivery
import BestASRDictation
import BestASRDomain
import BestASRFluidRuntime
import BestASRInference
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

/// Read-only library queries shared by production storage and deterministic tests.
/// Capture and durable writes remain on their existing repository boundary.
protocol HistoryQueryRepository: Sendable {
  func searchHistory(
    query: String, mode: SessionInputMode?, status: DictationHistoryStatus?,
    candidatePhases: [DictationPhase]?, includingSessionID: SessionID?,
    sourceApplication: String?, since: Date?, limit: Int, offset: Int
  ) async throws -> [DictationHistoryItem]
  func loadHistory(limit: Int) async throws -> [DictationHistoryItem]
  func historySourceApplications() async throws -> [DictationHistorySourceApplication]
  func historyUsageStatistics() async throws -> LocalHistoryUsageStatistics
  func dictationActivityRecords() async throws -> [DictationActivityRecord]
}

extension GRDBDictationStore: HistoryQueryRepository {}

/// An immutable query identity accompanies every first page and subsequent page.
/// A matching row count alone cannot identify the query that produced a page.
struct HistoryListQuery: Equatable, Sendable {
  let search: String
  let mode: String
  let status: String
  let dateRange: String
  let sourceApplication: String
  let personID: PersonID?
  let eventID: EventID?
  let duration: String
  let summaryOnly: Bool

}

/// HistoryModel: the history state, moved out of DictationAppModel without change.
/// Behaviour still lives on DictationAppModel+*.swift and reaches this
/// state as `history.<property>`; moving it here concern by concern is the
/// next step. See DICTATION_ARCHITECTURE.md §13.5.
@MainActor
final class HistoryModel: ObservableObject {
  var repository: (any HistoryQueryRepository)?
  var listTask: Task<Void, Never>?
  var pageTask: Task<Void, Never>?
  var overviewTask: Task<Void, Never>?
  var maintenanceTask: Task<Void, Never>?
  var overviewNeedsRefresh = false
  var presentedQuery: HistoryListQuery?
  var requestedQuery: HistoryListQuery?
  var nextPageOffset = 0
  var pageRequestID: UUID?

  @Published var listLoading = false
  @Published var listErrorMessage: String?
  @Published var pageErrorMessage: String?

  var currentQuery: HistoryListQuery {
    HistoryListQuery(
      search: searchQuery, mode: modeFilter, status: statusFilter,
      dateRange: dateRangeFilter, sourceApplication: sourceApplicationQuery,
      personID: personFilterID, eventID: eventFilterID,
      duration: durationFilter, summaryOnly: hasSummaryOnly
    )
  }

  @Published var historyItems: [DictationHistoryItem] = []

  @Published var homeRecentHistoryItems: [DictationHistoryItem] = []

  /// The history page shows one record's full detail instead of the list.
  @Published var detailPresented = false

  @Published var historyStatusMessage = "正在载入本地历史记录…"

  @Published var searchQuery = ""

  @Published var modeFilter = "all"

  @Published var statusFilter = "all"

  @Published var dateRangeFilter = "all"

  @Published var sourceApplicationQuery = ""

  @Published var personFilterID: PersonID?

  @Published var eventFilterID: EventID?

  @Published var durationFilter = "all"

  @Published var hasSummaryOnly = false

  @Published var sourceApplications: [DictationHistorySourceApplication] = []

  /// True once the store has no more rows for the current filters, so the list
  /// stops asking for another page.
  @Published var pagingExhausted = true

  @Published var pageLoading = false

  @Published var retryingHistorySessionID: SessionID?

  @Published var selectedHistorySessionID: SessionID?

  @Published var selectedHistoryTranscripts: [DictationPersistedTranscriptRecord] = []

  @Published var selectedHistoryDocuments: [LocalTextDocumentRecord] = []

  @Published var selectedHistorySourceAssets: [RetainedSourceAssetRecord] = []

  @Published var selectedHistoryTimelineEvents: [TimelineEvent] = []

  @Published var selectedHistorySourceContexts: [SourceContextSnapshot] = []

  @Published var documentTextDrafts: [UUID: String] = [:]

  @Published var structuredItemTextDrafts: [UUID: String] = [:]

  @Published var structuredItemOwnerDrafts: [UUID: String] = [:]

  @Published var structuredItemDueDateDrafts: [UUID: String] = [:]

  @Published var titleDraft = ""

  @Published var titleSaveInProgress = false

  @Published var transcriptEditDraft = ""

  @Published var correctionOriginalDraft = ""

  @Published var correctionReplacementDraft = ""

  @Published var reprocessingInProgress = false

  @Published var generatingHistoryDocumentTaskID: LocalTextTaskID?

  @Published var detailStatusMessage = ""

  @Published var searchNavigationQuery = ""

  @Published var locatedSegmentID: UUID?

  @Published var peopleSearchQuery = ""

  @Published var selectedPersonHistoryItems: [DictationHistoryItem] = []

  @Published var eventSearchQuery = "" {
    didSet {
      if eventSearchQuery != oldValue { eventSearchResultIDs = nil }
    }
  }

  @Published var eventSearchResultIDs: Set<EventID>?

  @Published var selectedEventHistoryItems: [DictationHistoryItem] = []

  @Published var eventAvailableHistoryItems: [DictationHistoryItem] = []

  @Published var includeMicrophoneInSystemRecording = LocalPreferenceStore.bool(
    "preferences.system-audio-include-microphone",
    default: false
  )

  @Published var storageHistoryCounts: [SessionInputMode: Int] = [:]

  @Published var navigationOrigin: HistoryNavigationOrigin?
}
