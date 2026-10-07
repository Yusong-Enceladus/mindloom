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
import BestASRMemoryUI
import BestASRModelManager
import BestASRPersistence
import BestASRPortableArchiveProbe
import BestASRProcessing
import BestASRQwenRuntime
import Combine
import CoreGraphics
import CryptoKit
import Foundation
import MindloomLibrary
import OSLog
import ServiceManagement
import UniformTypeIdentifiers


// Usage: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  func refreshStorageUsage() {
    guard !storageRefreshInProgress else { return }
    storageRefreshInProgress = true
    storageStatusMessage = "正在统计本机储存空间…"
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
          : "储存空间统计已更新；原始音频在你删除时移除"
        refreshDiagnosticsPreview()
      } catch {
        storageStatusMessage = "暂时无法读取储存空间用量，未删除内容"
      }
    }
  }

  /// 设置 › 口述 › 速度与占用: key up to text over 7 and 30 days, the
  /// memory the App holds now, and what recordings, models and files take.
  /// Read when the pane appears; the figures come first, storage after.
  func refreshDictationMetrics() {
    let store = dictationMetricsStore
    let repository = repository
    let inspector = storageInspector
    Task { [weak self] in
      var metrics = self?.dictationMetrics ?? SettingsDictationMetrics()
      if let store {
        metrics.week = Self.settingsLatency(try? await store.releaseToTextSummary(lastDays: 7))
        metrics.month = Self.settingsLatency(
          try? await store.releaseToTextSummary(lastDays: 30))
      }
      metrics.memoryBytes = ProcessFootprint.current()?.bytes
      self?.dictationMetrics = metrics
      guard let root = try? Self.applicationDataRoot() else { return }
      let modes = (try? await repository?.sessionModes()) ?? [:]
      let userItems = Set(modes.compactMap { $0.value == .userItem ? $0.key : nil })
      guard
        let breakdown = try? await inspector.dictationBreakdown(
          dataRoot: root, userItemSessions: userItems)
      else { return }
      metrics.recordingsBytes = breakdown.recordingsBytes
      metrics.modelsBytes = breakdown.modelsBytes
      metrics.filesBytes = breakdown.filesBytes
      self?.dictationMetrics = metrics
    }
  }

  nonisolated static func settingsLatency(
    _ summary: DictationLatencySummary?
  ) -> SettingsDictationMetrics.Latency? {
    guard let summary, summary.count > 0, let p50 = summary.p50Milliseconds,
      let p95 = summary.p95Milliseconds
    else { return nil }
    return SettingsDictationMetrics.Latency(
      count: summary.count, p50Milliseconds: p50, p95Milliseconds: p95)
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

  /// What the HUD needs beyond the snapshot to say how a take ended: whether
  /// its words were copied (and whether they are the draft), and whether a
  /// translation went in as said.
  func recordingPanelFacts(for renderedSnapshot: DictationSessionSnapshot) -> FnHUDTakeFacts {
    let session = renderedSnapshot.sessionID
    let copied = session != nil && session == copiedRetainedSessionID
    let copiedDraft = copied && copiedRetainedTextWasDraft
    // Demo mode: a take whose words reached the owner leaves the demo
    // library, by the same rule `settleDemoDictation` applies (根-10).
    let leaves =
      !keepsDictations
      && DemoDictationKeeping.wordsReachedOwner(
        renderedSnapshot, copiedFinalWords: copied && !copiedDraft)
    return FnHUDTakeFacts(
      copied: copied, copiedDraft: copiedDraft,
      untranslatedLanguage: untranslatedDictation.flatMap {
        $0.session == session ? $0.language : nil
      }, leavesLibrary: leaves)
  }
}

// Settings › 通用 › 储存空间 and the low-disk notice (ALIGNMENT 收3-5).
extension DictationAppModel {
  /// Measures the library by kind and by month, off the main thread.
  func refreshLibraryStorage() {
    guard let repository, let root = try? Self.applicationDataRoot() else { return }
    Task { [weak self] in
      let classes = (try? await repository.sessionStorageClasses()) ?? []
      let report = await Task.detached(priority: .utility) {
        LibraryStorageReport.scan(dataRoot: root, classes: classes)
      }.value
      guard let self else { return }
      libraryStorage = report
      noticeLowDiskIfNeeded(available: report.availableBytes, capacity: report.capacityBytes)
    }
  }

  /// A quick look at the disk (no walk): at launch and after a recording.
  /// The volume query takes tens of milliseconds, so it runs off the main
  /// thread (review 10-6 S11).
  func checkLowDisk() {
    guard let root = try? Self.applicationDataRoot() else { return }
    Task { [weak self] in
      let volume = await Task.detached(priority: .utility) {
        LibraryStorageReport.volume(of: root)
      }.value
      self?.noticeLowDiskIfNeeded(available: volume.available, capacity: volume.capacity)
    }
  }

  static let lowDiskNoticeKey = "MindloomLowDiskNotice"

  /// When free space becomes short, once; again only after it recovered and
  /// became short again, or when what is free has halved — never twice in a
  /// day. Remembered across launches in the App's preferences
  /// (`LibraryStorageReport.lowDiskNotice`, review 10-6 S11).
  func noticeLowDiskIfNeeded(available: Int64, capacity: Int64) {
    let defaults = UserDefaults.standard
    let last = defaults.data(forKey: Self.lowDiskNoticeKey).flatMap {
      try? JSONDecoder().decode(LibraryStorageReport.LowDiskNotice.self, from: $0)
    }
    let decision = LibraryStorageReport.lowDiskNotice(
      available: available, capacity: capacity, last: last, now: Date())
    if decision.remember != last {
      if let remember = decision.remember, let data = try? JSONEncoder().encode(remember) {
        defaults.set(data, forKey: Self.lowDiskNoticeKey)
      } else {
        defaults.removeObject(forKey: Self.lowDiskNoticeKey)
      }
    }
    guard decision.show else { return }
    CaptureFeedback.shared.show(
      MemoryToast(
        "可用空间不足", icon: .symbol("externaldrive"),
        action: .settings(SettingsPane.general.rawValue)))
  }

  /// What Settings shows.
  static func settingsStorage(_ report: LibraryStorageReport?) -> SettingsStorage? {
    guard let report else { return nil }
    let titles: [(LibraryStorageKind, String)] = [
      (.dictation, "口述录音"),
      (.meetings, "会议和电脑声音"),
      (.imported, "导入的录音和视频"),
      (.typeless, "Typeless 历史"),
      (.items, "文件和截图"),
    ]
    var rows = titles.map { kind, title in
      SettingsStorage.Row(id: kind.rawValue, title: title, bytes: report.bytesByKind[kind] ?? 0)
    }
    rows.append(.init(id: "database", title: "文字和整理结果", bytes: report.databaseBytes))
    rows.append(.init(id: "models", title: "识别和整理模型", bytes: report.modelBytes))
    if report.otherBytes > 0 {
      rows.append(.init(id: "other", title: "其他", bytes: report.otherBytes))
    }
    let calendar = Calendar.current
    let months = report.months.map { month in
      let parts = calendar.dateComponents([.year, .month], from: month.start)
      return SettingsStorage.Month(
        id: String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0),
        label: "\(parts.month ?? 0)月", bytes: month.bytes)
    }
    return SettingsStorage(
      rows: rows, months: months, availableBytes: report.availableBytes,
      capacityBytes: report.capacityBytes, lowDisk: report.lowDisk)
  }
}
