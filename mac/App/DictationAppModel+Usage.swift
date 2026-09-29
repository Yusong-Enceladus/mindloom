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


// Usage: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  func refreshStorageUsage() {
    guard !storageRefreshInProgress else { return }
    storageRefreshInProgress = true
    storageStatusMessage = "正在统计本机存储…"
    Task { [weak self] in
      guard let self else { return }
      defer { storageRefreshInProgress = false }
      do {
        let dataRoot = try Self.applicationDataRoot()
        let cacheRoot = try Self.applicationCacheRoot()
        storageSnapshot = try await storageInspector.snapshot(
          dataRoot: dataRoot,
          cacheRoot: cacheRoot
        )
        if let repository {
          history.storageHistoryCounts = try await repository.historyCountsByMode()
          capture.storageSourceAudioBytes =
            try await storageInspector
            .sourceAudioBytesByMode(
              dataRoot: dataRoot,
              sessionModes: try await repository.sessionModes()
            )
        }
        storageStatusMessage =
          storageSnapshot.availableBytes
            < 4 * 1_073_741_824
          ? "磁盘空间偏低；录音前请至少保留 4 GB"
          : "存储统计已更新；原始音频只会在你明确删除时移除"
        refreshDiagnosticsPreview()
      } catch {
        storageStatusMessage = "暂时无法读取存储用量；没有删除任何内容"
      }
    }
  }

  func finishMemorySearchStatus() {
    memorySearch.searchInProgress = false
    let count =
      memorySearch.searchHistoryItems.count
      + memorySearch.searchPersonSummaries.count
      + memorySearch.searchEventSummaries.count
    memorySearch.searchStatusMessage =
      count == 0 ? "没有找到相关的本机记忆" : "找到 \(count) 项本机记忆"
  }

  func historyStatusTitle(_ item: DictationHistoryItem) -> String {
    Self.historyStatusTitle(
      item,
      startupRecoverySessionIDs: startupRecoverySessionIDs,
      retryingSessionID: history.retryingHistorySessionID
    )
  }

  static func historyStatusTitle(
    _ item: DictationHistoryItem,
    startupRecoverySessionIDs: Set<SessionID> = [],
    retryingSessionID: SessionID? = nil
  ) -> String {
    if retryingSessionID == item.sessionID { return "正在恢复" }
    if item.phase.isActive,
      canRetryHistoryItem(item, startupRecoverySessionIDs: startupRecoverySessionIDs)
    {
      return "可恢复"
    }
    return switch item.status {
    case .completed: "已完成"
    case .failed: item.canRetry ? "可恢复" : "失败"
    case .processing: "处理中"
    case .recovered: "已恢复"
    }
  }

  static func historyItemMatchesStatusFilter(
    _ item: DictationHistoryItem,
    filter: String,
    startupRecoverySessionIDs: Set<SessionID>,
    retryingSessionID: SessionID? = nil
  ) -> Bool {
    switch filter {
    case "all":
      return true
    case "recoverable":
      return retryingSessionID != item.sessionID
        && canRetryHistoryItem(item, startupRecoverySessionIDs: startupRecoverySessionIDs)
    case "processing":
      return retryingSessionID == item.sessionID
        || (item.status == .processing && !startupRecoverySessionIDs.contains(item.sessionID))
    case "completed":
      return retryingSessionID != item.sessionID
        && [.completed, .recovered].contains(item.status)
    default:
      return retryingSessionID != item.sessionID && item.status.rawValue == filter
    }
  }

  func generateHistorySummary() {
    generateHistoryDocument(taskID: .structuredSummary)
  }

  /// One short line for the capsule's finished states; empty otherwise.
  func recordingPanelCompactStatus(
    for renderedSnapshot: DictationSessionSnapshot
  ) -> String {
    let copied =
      renderedSnapshot.sessionID != nil
      && renderedSnapshot.sessionID == copiedRetainedSessionID
    switch renderedSnapshot.phase {
    case .completed where renderedSnapshot.insertion?.inserted != true:
      return copied ? "已复制 · ⌘V 粘贴" : "已保存到资料库"
    // Tapping the key and saying nothing is not a failure and must not be
    // reported as one. It is the commonest way a dictation ends with no text.
    case .failedRecoverable
    where Self.isSilentDictationFailure(code: renderedSnapshot.failure?.code):
      return "没有听到说话"
    case .failedRecoverable:
      guard copied else { return "处理失败，原音已保存" }
      return copiedRetainedTextWasDraft ? "处理失败，已复制草稿 · ⌘V 粘贴" : "已复制 · ⌘V 粘贴"
    default:
      return ""
    }
  }
}
