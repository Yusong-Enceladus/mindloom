import BestASRDomain
import BestASRPersistence
import Combine
import Foundation

/// Keeps UI queries bounded while preserving the existing dictionary repository
/// contract used by recognition and durable processing.
protocol DictionaryManagementRepository: DictionaryRepository {
  func searchDictionaryEntries(
    query: String, includeDisabled: Bool, limit: Int, offset: Int
  ) async throws -> [DictionaryEntry]
  func allDictionaryEntries() async throws -> [DictionaryEntry]
  func importDictionaryEntries(_ entries: [DictionaryTransferEntry]) async throws
    -> [DictionaryEntry]
}

extension GRDBDictationStore: DictionaryManagementRepository {}

@MainActor
final class DictionaryModel: ObservableObject {
  var repository: (any DictionaryManagementRepository)?
  var captureIsActive: () -> Bool = { false }
  let transferWorker = LocalDictionaryTransferWorker()

  static let pageSize = 100
  var queryTask: Task<Void, Never>?
  var queryGeneration = 0
  var requestedPageIndex = 0

  @Published var entries: [DictionaryEntry] = []
  @Published var isLoadingEntries = false
  @Published var pageIndex = 0
  @Published var hasNextPage = false
  @Published var mutationInProgress = false
  @Published var editingDictionaryEntryID: DictionaryEntryID?
  @Published var dictionaryStatusMessage = "已启用的词条会用于本地识别和事实保护"
  @Published var saveInProgress = false
  @Published var searchQuery = ""
  @Published var canonicalDraft = ""
  @Published var spokenFormsDraft = ""

  deinit { queryTask?.cancel() }
}
