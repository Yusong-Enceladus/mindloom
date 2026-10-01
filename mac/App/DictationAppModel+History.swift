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

// History: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  /// Clicking a finished capsule opens the main window at that record.
  func openFinishedDictationRecord() {
    let mainWindow = NSApplication.shared.windows.first {
      $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
    if let mainWindow {
      mainWindow.makeKeyAndOrderFront(nil)
    } else {
      // Reopening the running app makes SwiftUI create the main window.
      NSWorkspace.shared.open(Bundle.main.bundleURL)
    }
    openCaptureWorkspaceHandoff()
  }

  nonisolated static func canRecord(
    microphonePermission: DictationPermissionState
  ) -> Bool {
    microphonePermission == .granted
  }

  func clearHistoryRecords(mode: SessionInputMode) {
    guard !hasActiveCapture, !models.recommendedModelInstallInProgress,
      !export.archiveOperationInProgress, let repository, let journal
    else {
      storageStatusMessage = "请先结束录音、导入、组件下载或归档操作"
      return
    }
    storageStatusMessage = "正在安全暂存并删除\(Self.storageModeTitle(mode))记录…"
    Task { [weak self] in
      guard let self else { return }
      var staged: [StagedSessionDeletion] = []
      var databaseCommitted = false
      do {
        let items = try await repository.searchHistory(
          query: "",
          mode: mode,
          status: nil,
          limit: 100_000
        )
        guard !items.contains(where: { $0.phase.isActive }) else {
          throw BestASRPersistenceError.processingCommitConflict
        }
        guard !items.isEmpty else {
          storageStatusMessage = "没有可删除的\(Self.storageModeTitle(mode))记录"
          return
        }
        for item in items where item.sourceAudioRetained {
          if let deletion = try await journal.stageExplicitDeletion(
            sessionID: item.sessionID
          ) {
            staged.append(deletion)
          }
        }
        // Keyframe items of deleted recordings go with them (privacy review F6).
        let listed = Set(items.map(\.sessionID))
        for frame in try await repository.keyframeSessionIDs(of: items.map(\.sessionID))
        where !listed.contains(frame) {
          if let deletion = try await journal.stageExplicitDeletion(sessionID: frame) {
            staged.append(deletion)
          }
        }
        try await repository.deleteSessionRecordsExplicitly(
          sessionIDs: items.map(\.sessionID)
        )
        databaseCommitted = true
        for deletion in staged {
          try await journal.commitExplicitDeletion(deletion)
        }
        if let selectedHistorySessionID = history.selectedHistorySessionID,
          items.contains(where: { $0.sessionID == selectedHistorySessionID })
        {
          stopHistoryPlayback()
          self.history.selectedHistorySessionID = nil
          history.selectedHistoryTranscripts = []
          history.selectedHistoryDocuments = []
          history.selectedHistorySourceAssets = []
          history.selectedHistoryTimelineEvents = []
          history.selectedHistorySourceContexts = []
          people.selectedSessionSpeakers = []
          selectedSessionOccurrences = []
          history.documentTextDrafts = [:]
          history.structuredItemTextDrafts = [:]
          history.structuredItemOwnerDrafts = [:]
          history.structuredItemDueDateDrafts = [:]
          history.titleDraft = ""
          history.transcriptEditDraft = ""
          history.correctionOriginalDraft = ""
          history.correctionReplacementDraft = ""
          playback.playbackTrackIDs = []
          playback.playbackTrackRoles = [:]
          playback.selectedHistoryPlaybackTrackID = ""
          people.speakerNameDrafts = [:]
          splitOccurrenceIDs = []
        }
        storageStatusMessage =
          "已删除 \(items.count) 条\(Self.storageModeTitle(mode))记录及其明确关联的保留原音；其他类型未受影响"
        await refreshHistoryItems(preserveStatus: true)
        await refreshEventMemory(organize: false)
        await refreshPeopleNow()
        refreshStorageUsage()
      } catch {
        if databaseCommitted {
          for deletion in staged {
            try? await journal.commitExplicitDeletion(deletion)
          }
        } else {
          for deletion in staged.reversed() {
            try? await journal.rollbackExplicitDeletion(deletion)
          }
        }
        storageStatusMessage =
          databaseCommitted
          ? "记录已删除；少量已授权删除的暂存文件将在下次清理时继续移除"
          : "批量删除未完成；本机记录和已暂存原音已恢复，其他用户数据没有变化"
      }
    }
  }

  func refreshHistory() {
    attemptedLegacySourceAudioIndex.removeAll()
    Task { [weak self] in
      guard let self else { return }
      await refreshHistoryItems(refreshOverview: false)
      scheduleHistoryMaintenance()
    }
  }

  /// Repair old source metadata at launch or explicit Refresh, never on a filter
  /// click. The first page is already visible before this maintenance starts.
  func scheduleHistoryMaintenance() {
    guard !fixtureMode, history.maintenanceTask == nil else { return }
    history.maintenanceTask = Task { [weak self] in
      guard let self else { return }
      await reconcileLegacySourceAudioIndex()
      guard !Task.isCancelled else { return }
      await refreshHistoryItems()
      history.maintenanceTask = nil
    }
  }

  static func canRetryHistoryItem(
    _ item: DictationHistoryItem,
    startupRecoverySessionIDs: Set<SessionID>
  ) -> Bool {
    item.canRetry
      || (item.phase.isActive
        && startupRecoverySessionIDs.contains(item.sessionID))
  }

  func canRetryHistoryItem(_ item: DictationHistoryItem) -> Bool {
    Self.canRetryHistoryItem(
      item,
      startupRecoverySessionIDs: startupRecoverySessionIDs
    )
  }

  static func canDeleteHistoryItem(
    _ item: DictationHistoryItem,
    startupRecoverySessionIDs: Set<SessionID>,
    retryingSessionID: SessionID? = nil
  ) -> Bool {
    retryingSessionID != item.sessionID
      && (!item.phase.isActive || startupRecoverySessionIDs.contains(item.sessionID))
  }

  func canDeleteHistoryItem(_ item: DictationHistoryItem) -> Bool {
    Self.canDeleteHistoryItem(
      item,
      startupRecoverySessionIDs: startupRecoverySessionIDs,
      retryingSessionID: history.retryingHistorySessionID
    )
  }

  func historyRetryTitle(_ item: DictationHistoryItem) -> String {
    if item.inputMode == .importedMedia, item.phase.isActive {
      return "继续导入"
    }
    return startupRecoverySessionIDs.contains(item.sessionID) ? "恢复" : "重试"
  }

  static func historyFilterAfterRecovery(
    _ filter: String,
    recoveredSessionID: SessionID,
    selectedSessionID: SessionID?
  ) -> String {
    // Keep the record being read visible when it leaves a recovery-only list.
    selectedSessionID == recoveredSessionID
      && ["recoverable", "failed", "processing"].contains(filter) ? "all" : filter
  }

  static func historyItemMatchesDurationFilter(
    _ item: DictationHistoryItem,
    filter: String
  ) -> Bool {
    guard ["short", "medium", "long"].contains(filter) else { return true }
    guard let duration = item.durationNanoseconds else { return false }
    switch filter {
    case "short": return duration < 5 * 60 * 1_000_000_000
    case "medium": return duration >= 5 * 60 * 1_000_000_000 && duration < 30 * 60 * 1_000_000_000
    case "long": return duration >= 30 * 60 * 1_000_000_000
    default: return true
    }
  }

  static func historyEmptyText(_ item: DictationHistoryItem) -> String {
    if isSilentDictationFailure(code: item.failureCode) {
      return "没有听到说话。"
    }
    if item.failureCode == "journal-no-committed-audio" {
      return "没有可恢复的已提交音频；可在确认后删除这条记录。"
    }
    if !item.sourceAudioRetained {
      return "文字尚未生成；原始音频已删除。"
    }
    if [.completed, .recovered].contains(item.status) {
      return "没有检测到可识别的语音；原始音频仍保留在本机。"
    }
    return "文字尚未生成，原始音频仍保留在本机。"
  }

  func applyHistoryFilters() {
    let query = history.currentQuery
    // SwiftUI can report several changed bindings in one update. Coalesce an
    // identical in-flight request, while a new query cancels the old task.
    guard history.requestedQuery != query || !history.listLoading else { return }
    let searchChanged = history.requestedQuery.map { $0.search != query.search } ?? false
    startHistoryListRefresh(debounceSearch: searchChanged)
  }

  @discardableResult
  func openFirstHistorySearchResult() -> Task<Void, Never> {
    let query = history.currentQuery
    let task = startHistoryListRefresh()
    let generation = historyRefreshGenerationGate.current
    return Task { [weak self] in
      await task?.value
      guard !Task.isCancelled, let self, historyRefreshGenerationGate.accepts(generation),
        history.currentQuery == query, history.listErrorMessage == nil,
        history.presentedQuery == query || (fixtureMode && history.repository == nil),
        let first = history.historyItems.first
      else { return }
      openHistoryItem(first, locating: query.search)
    }
  }

  func resetHistoryFilters() {
    history.searchQuery = ""
    history.modeFilter = "all"
    history.statusFilter = "all"
    history.dateRangeFilter = "all"
    history.durationFilter = "all"
    history.personFilterID = nil
    history.eventFilterID = nil
    history.sourceApplicationQuery = ""
    history.hasSummaryOnly = false
    applyHistoryFilters()
  }

  func toggleHistoryDetails(_ item: DictationHistoryItem) {
    historyPlaybackFixturePersonUndoStack = []
    history.detailStatusMessage = ""
    if history.selectedHistorySessionID == item.sessionID {
      stopHistoryPlayback()
      history.selectedHistorySessionID = nil
      people.selectedSessionSpeakers = []
      selectedSessionOccurrences = []
      history.selectedHistoryTranscripts = []
      history.selectedHistoryDocuments = []
      history.selectedHistorySourceAssets = []
      history.selectedHistoryTimelineEvents = []
      history.selectedHistorySourceContexts = []
      history.documentTextDrafts = [:]
      history.structuredItemTextDrafts = [:]
      history.structuredItemOwnerDrafts = [:]
      history.structuredItemDueDateDrafts = [:]
      history.titleDraft = ""
      playback.playbackTrackRoles = [:]
      export.exportSelectionStart = 0
      export.exportSelectionEnd = 0
      history.transcriptEditDraft = ""
      history.correctionOriginalDraft = ""
      history.correctionReplacementDraft = ""
      historyTranscriptEditSessionID = nil
      people.speakerNameDrafts = [:]
      people.speakerIdentityStatusMessage = ""
      return
    }
    stopHistoryPlayback()
    history.selectedHistorySessionID = item.sessionID
    history.titleDraft = item.title
    people.speakerIdentityStatusMessage = "正在读取本地人物信息…"
    Task { [weak self] in
      await self?.refreshSelectedSpeakerDetails(sessionID: item.sessionID)
    }
  }

  func copyHistoryText(_ text: String, label: String) {
    guard !text.isEmpty else { return }
    let requestID = UUID()
    historyDetailCopyRequestID = requestID
    history.detailStatusMessage = "正在复制\(label)…"
    Task { [weak self] in
      guard let self else { return }
      let copied = pasteboardWriter.write(text)
      guard historyDetailCopyRequestID == requestID else { return }
      history.detailStatusMessage =
        copied ? "已复制\(label)" : "复制失败；本地记录没有变化"
    }
  }

  func restoreSelectedHistoryRawText() {
    if let current = selectedHistoryCurrentTranscript,
      let source = TranscriptSelection.recognitionSource(
        for: current, in: history.selectedHistoryTranscripts
      )
    {
      restoreHistoryTranscriptRevision(source)
      return
    }
    guard let raw = selectedHistoryRecognitionText, !raw.isEmpty else {
      history.detailStatusMessage = "这条记录没有可恢复的原始识别文字"
      return
    }
    history.transcriptEditDraft = raw
    saveHistoryTranscriptEdit()
  }

  func applyEventSearch() {
    if fixtureMode, eventReviewUIFixture != nil {
      history.eventSearchResultIDs = nil
      return
    }
    Task { [weak self] in
      await self?.refreshEventMemory(organize: false)
    }
  }

  func linkSelectedHistoryToEvent() {
    guard let repository, let selectedEventID = events.selectedEventID,
      let eventAddSessionID = events.addSessionID
    else {
      events.eventStatusMessage = "请选择要关联的历史记录"
      return
    }
    events.eventStatusMessage = "正在关联记录…"
    Task { [weak self] in
      guard let self else { return }
      do {
        try await repository.linkSessions(
          [eventAddSessionID],
          to: selectedEventID,
          source: .manual,
          evidence: .manual()
        )
        self.events.addSessionID = nil
        await refreshEventMemory(organize: false)
        events.eventStatusMessage = "记录已关联到当前事件；它仍可同时属于其他相关事件"
      } catch {
        events.eventStatusMessage = "记录未能关联；现有关系没有变化"
      }
    }
  }

  func openEventHistoryItem(_ item: DictationHistoryItem) {
    openHistoryItem(
      item,
      returningTo: HistoryNavigationOrigin(
        kind: .event,
        title: selectedEventSummary?.event.title ?? "当前事件"
      )
    )
  }

  func openHistoryItem(
    _ item: DictationHistoryItem,
    returningTo origin: HistoryNavigationOrigin? = nil,
    locating query: String? = nil
  ) {
    beginHistoryNavigation(item, returningTo: origin)
    let normalizedQuery =
      query?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ) ?? ""
    history.searchNavigationQuery = normalizedQuery
    Task { [weak self] in
      guard let self else { return }
      await refreshSelectedSpeakerDetails(sessionID: item.sessionID)
      guard history.selectedHistorySessionID == item.sessionID,
        history.searchNavigationQuery == normalizedQuery,
        !normalizedQuery.isEmpty
      else { return }
      locateHistorySearchResult(query: normalizedQuery)
    }
  }

  func openHistorySearchResult(_ item: DictationHistoryItem) {
    openHistoryItem(item, locating: history.searchQuery)
  }

  func clearHistoryNavigationOrigin() {
    history.navigationOrigin = nil
    events.activeEventReviewCandidateID = nil
  }

  func beginHistoryNavigation(
    _ item: DictationHistoryItem,
    returningTo origin: HistoryNavigationOrigin?,
    presentingDetail: Bool = true
  ) {
    if presentingDetail {
      history.detailPresented = true
      requestedNavigationSectionID = "history"
    }
    stopHistoryPlayback()
    history.detailStatusMessage = ""
    history.navigationOrigin = origin
    events.activeEventReviewCandidateID = nil
    history.searchNavigationQuery = ""
    history.locatedSegmentID = nil
    if origin != nil {
      revealLinkedHistoryItem(item)
    }
    history.selectedHistorySessionID = item.sessionID
    history.titleDraft = item.title
  }

  func setHistoryDetailFeedback(_ message: String, for sessionID: SessionID) {
    guard history.selectedHistorySessionID == sessionID else { return }
    history.detailStatusMessage = message
  }

  func revealLinkedHistoryItem(_ item: DictationHistoryItem) {
    history.searchQuery = ""
    history.modeFilter = "all"
    history.statusFilter = "all"
    history.dateRangeFilter = "all"
    history.durationFilter = "all"
    history.personFilterID = nil
    history.eventFilterID = nil
    history.sourceApplicationQuery = ""
    history.hasSummaryOnly = false
    if !history.historyItems.contains(where: { $0.sessionID == item.sessionID }) {
      history.historyItems.append(item)
      history.historyItems.sort { $0.updatedAt > $1.updatedAt }
    }
    if !fixtureMode {
      applyHistoryFilters()
    }
  }

  func locateHistorySearchResult(query: String) {
    let segments = selectedHistoryTimestampedTranscript?.segments ?? []
    guard
      let segmentID = Self.historySearchSegmentID(
        query: query,
        segments: segments,
        documents: history.selectedHistoryDocuments
      ),
      let segment = segments.first(where: { $0.id == segmentID })
    else {
      history.detailStatusMessage =
        "已打开匹配记录；命中来自标题、人物、事件、来源或无时间戳文字"
      return
    }
    locateHistoryTranscriptSegment(segment)
    history.detailStatusMessage = "已定位到匹配内容引用的原音位置"
  }

  nonisolated static func historySearchSegmentID(
    query: String,
    segments: [DictationTranscriptSegment],
    documents: [LocalTextDocumentRecord]
  ) -> UUID? {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    if let direct = segments.first(where: {
      $0.text.localizedCaseInsensitiveContains(normalized)
    }) {
      return direct.id
    }
    let referencedIDs = Set(
      documents.filter { $0.state == .current }.flatMap { document in
        let itemIDs = document.result.structuredItems.filter {
          $0.text.localizedCaseInsensitiveContains(normalized)
        }.flatMap(\.sourceSegmentIDs)
        let claimIDs = document.result.claims.filter {
          $0.text.localizedCaseInsensitiveContains(normalized)
        }.flatMap(\.sourceSegmentIDs)
        return itemIDs + claimIDs
      }
    )
    return segments.first(where: { referencedIDs.contains($0.id) })?.id
  }

  nonisolated static func historySearchSnippet(
    text: String?,
    query: String,
    contextBefore: Int = 28,
    contextAfter: Int = 52
  ) -> String? {
    let normalizedQuery = query.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !normalizedQuery.isEmpty,
      let text,
      let match = text.range(
        of: normalizedQuery,
        options: [.caseInsensitive, .diacriticInsensitive]
      )
    else { return nil }

    let lower =
      text.index(
        match.lowerBound,
        offsetBy: -max(0, contextBefore),
        limitedBy: text.startIndex
      ) ?? text.startIndex
    let upper =
      text.index(
        match.upperBound,
        offsetBy: max(0, contextAfter),
        limitedBy: text.endIndex
      ) ?? text.endIndex
    let body = text[lower..<upper]
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
    guard !body.isEmpty else { return nil }
    return (lower == text.startIndex ? "" : "…") + body
      + (upper == text.endIndex ? "" : "…")
  }

  func copyHistoryItem(_ item: DictationHistoryItem) {
    guard let text = item.preferredText, !text.isEmpty else {
      history.historyStatusMessage = "这条记录尚没有可复制的完成文字"
      return
    }
    let requestID = UUID()
    historyListCopyRequestID = requestID
    history.historyStatusMessage = "正在复制…"
    let repository = self.repository
    Task { [weak self] in
      // A long item's list row holds only a preview; copy its full text.
      var fullText = text
      if item.textIsPreview, let repository,
        let stored = try? await repository.memoryItemRecords(ids: [item.sessionID]).first?.text,
        !stored.isEmpty
      {
        fullText = stored
      }
      guard let self else { return }
      let copied = pasteboardWriter.write(fullText)
      guard historyListCopyRequestID == requestID else { return }
      history.historyStatusMessage =
        copied ? "已复制所选本地口述" : "复制失败；口述内容仍保留在本机"
    }
  }

  func deleteHistoryItem(_ item: DictationHistoryItem) {
    guard canDeleteHistoryItem(item), let journal, let repository else {
      history.historyStatusMessage = "仍在本次运行中处理的记录不能删除"
      return
    }
    if history.selectedHistorySessionID == item.sessionID {
      stopHistoryPlayback()
    }
    history.historyStatusMessage = "正在删除这条记录和它保留的本地原音…"
    Task { [weak self] in
      guard let self else { return }
      do {
        // A recording's keyframe items go with it (privacy review F6): their
        // files are staged with the recording's, and the store deletes their
        // records in the same transaction and queues their remote deletion.
        let frames = (try? await repository.keyframeSessionIDs(of: [item.sessionID])) ?? []
        var staged: [StagedSessionDeletion] = []
        do {
          if item.sourceAudioRetained,
            let deletion = try await journal.stageExplicitDeletion(sessionID: item.sessionID)
          {
            staged.append(deletion)
          }
          for frame in frames {
            if let deletion = try await journal.stageExplicitDeletion(sessionID: frame) {
              staged.append(deletion)
            }
          }
          try await repository.deleteSessionRecordsExplicitly(
            sessionID: item.sessionID
          )
        } catch {
          for deletion in staged.reversed() {
            try? await journal.rollbackExplicitDeletion(deletion)
          }
          throw error
        }
        for deletion in staged {
          try await journal.commitExplicitDeletion(deletion)
        }
        if history.selectedHistorySessionID == item.sessionID {
          history.selectedHistorySessionID = nil
          history.selectedHistoryTranscripts = []
          history.selectedHistoryDocuments = []
          history.selectedHistorySourceAssets = []
          history.selectedHistoryTimelineEvents = []
          history.selectedHistorySourceContexts = []
          playback.playbackTrackRoles = [:]
          people.selectedSessionSpeakers = []
          selectedSessionOccurrences = []
        }
        clearCaptureWorkspaceHandoff(afterDeleting: item.sessionID)
        startupRecoverySessionIDs.remove(item.sessionID)
        recoveryItemCount = startupRecoverySessionIDs.count
        history.historyStatusMessage = "记录、派生结果和保留原音已从这台 Mac 删除"
        await refreshHistoryItems(preserveStatus: true)
      } catch {
        history.historyStatusMessage = "删除未完成；记录和原始音频已恢复到原位置"
      }
    }
  }

  func deleteHistorySourceAudio(_ item: DictationHistoryItem) {
    guard item.sourceAudioRetained, !item.phase.isActive,
      history.retryingHistorySessionID != item.sessionID,
      let journal, let repository
    else {
      history.historyStatusMessage = "这条记录没有可删除的保留原音，或仍在处理中"
      return
    }
    if history.selectedHistorySessionID == item.sessionID {
      stopHistoryPlayback()
    }
    history.historyStatusMessage = "正在仅删除保留原音；文字版本、人物和时间线会保留…"
    Task { [weak self] in
      guard let self else { return }
      do {
        let staged = try await journal.stageExplicitDeletion(
          sessionID: item.sessionID
        )
        do {
          try await repository.markSessionSourceAudioExplicitlyDeleted(
            sessionID: item.sessionID
          )
        } catch {
          if let staged {
            try? await journal.rollbackExplicitDeletion(staged)
          }
          throw error
        }
        if let staged {
          try await journal.commitExplicitDeletion(staged)
        }
        history.selectedHistorySourceAssets = []
        playback.playbackTrackIDs = []
        playback.playbackTrackRoles = [:]
        playback.selectedHistoryPlaybackTrackID = ""
        playback.waveformSamples = []
        export.exportSelectionStart = 0
        export.exportSelectionEnd = 0
        history.historyStatusMessage =
          "保留原音已删除；逐字稿全部版本、整理结果、人物和来源信息仍在"
        await refreshHistoryItems(preserveStatus: true)
        if history.selectedHistorySessionID == item.sessionID {
          await refreshSelectedSpeakerDetails(sessionID: item.sessionID)
        }
      } catch {
        history.historyStatusMessage = "原音删除未完成；文件和记录已恢复到删除前状态"
      }
    }
  }

  func retryHistoryItem(_ item: DictationHistoryItem) {
    guard canRetryHistoryItem(item), history.retryingHistorySessionID == nil else {
      return
    }
    guard !fixtureMode else {
      history.historyStatusMessage = "测试记录已完成本机恢复"
      return
    }
    guard models.modelRuntimeReady else {
      history.historyStatusMessage = "请等待本地语音识别组件就绪后再恢复"
      return
    }
    if item.inputMode == .importedMedia,
      [.preparing, .recording, .paused, .finalizing].contains(item.phase)
    {
      resumeInterruptedImport(item)
      return
    }
    history.retryingHistorySessionID = item.sessionID
    history.historyStatusMessage = "正在恢复已提交原音并继续本机处理…"
    Task { [weak self] in
      guard let self else { return }
      defer { history.retryingHistorySessionID = nil }
      do {
        guard let repository, let journal, let localRuntime,
          let durableSnapshot = try await repository.load(
            sessionID: item.sessionID
          )
        else {
          history.historyStatusMessage = "本机恢复记录暂不可用"
          return
        }
        let recovery = try await journal.recover(sessionID: item.sessionID)
        guard !recovery.ranges.isEmpty else {
          if durableSnapshot.phase.isActive {
            let actor = DictationSessionActor(initialSnapshot: durableSnapshot)
            let failure = try DictationFailure(
              stage: .journal,
              category: .corruptInput,
              code: "journal-no-committed-audio",
              retryable: false,
              recoveryPhase: .finalizing
            )
            let failed = try await actor.handle(.failed(failure))
            try await repository.save(failed)
          }
          startupRecoverySessionIDs.remove(item.sessionID)
          recoveryItemCount = startupRecoverySessionIDs.count
          history.historyStatusMessage =
            "这条中断记录没有可恢复的已提交音频；已停止重复恢复，可在确认后删除"
          await refreshHistoryItems(
            preserveStatus: true, completingRecoverySessionID: item.sessionID
          )
          return
        }
        let finalization = try await prepareRecoveryFinalization(
          snapshot: durableSnapshot,
          recovery: recovery,
          repository: repository,
          journal: journal
        )
        let outcome = try await localRuntime.process(
          finalization
        )
        guard outcome.snapshot.phase == .completed else {
          history.historyStatusMessage = "恢复尚未完成；原音与进度仍可再次恢复"
          await refreshHistoryItems(
            preserveStatus: true, completingRecoverySessionID: item.sessionID
          )
          return
        }
        try await repository.markRecovered(sessionID: item.sessionID)
        history.historyStatusMessage = "记录已在本机完整恢复"
        history.statusFilter = Self.historyFilterAfterRecovery(
          history.statusFilter, recoveredSessionID: item.sessionID,
          selectedSessionID: history.selectedHistorySessionID
        )
        startupRecoverySessionIDs.remove(item.sessionID)
        recoveryItemCount = startupRecoverySessionIDs.count
        await refreshHistoryItems(
          preserveStatus: true,
          organizeEvents: true,
          completingRecoverySessionID: item.sessionID
        )
        await refreshSelectedSpeakerDetails(sessionID: item.sessionID)
      } catch {
        history.historyStatusMessage = "恢复未完成；原始音频和现有进度仍完整保留"
        await refreshHistoryItems(
          preserveStatus: true, completingRecoverySessionID: item.sessionID
        )
      }
    }
  }

  /// Writes a finished dictation into history and the capture workspace, after
  /// it has been inserted. Runs on its own chain so several dictations in a row
  /// queue their bookkeeping instead of running it all at once, and only the
  /// last of a burst pays for organizing events.
  func recordFinishedDictation(
    _ snapshot: DictationSessionSnapshot,
    sessionID: SessionID,
    coordinator: DictationCaptureCoordinator?,
    state: CaptureWorkspaceHandoff.State,
    detail: String? = nil
  ) {
    let message = detail ?? statusMessage
    let previous = bookkeepingChain
    bookkeepingChain = Task { @MainActor [weak self] in
      _ = await previous?.result
      guard let self else { return }
      let started = ContinuousClock.now
      if let coordinator {
        try? await coordinator.synchronizeProcessingSnapshot(snapshot)
      }
      // Reading history back costs seconds on a large library. While the main
      // window is closed nobody can see the result, and during a burst only
      // the last dictation's read survives, so both are deferred.
      let readsHistoryBack = Self.readsHistoryBackNow(
        historyOnScreen: Self.mainWindowIsVisible,
        dictationsStillFinishing: finalizingSessionIDs.count
      )
      await presentCaptureWorkspaceHandoff(
        sessionID: sessionID,
        inputMode: .dictation,
        state: state,
        detail: message,
        organizeEvents: readsHistoryBack,
        refreshHistory: readsHistoryBack
      )
      if !readsHistoryBack { historyNeedsRefresh = true }
      logDictationStage("history-bookkeeping", since: started)
    }
  }

  func upsertFixtureDictationHistory(
    state: CaptureWorkspaceHandoff.State
  ) {
    guard fixtureMode, let sessionID = snapshot.sessionID else { return }
    let now = Date()
    let item = DictationHistoryItem(
      sessionID: sessionID,
      title: "刚刚完成的测试口述",
      inputMode: .dictation,
      revision: snapshot.revision,
      phase: snapshot.phase,
      status: state == .completed ? .completed : .processing,
      rawText: snapshot.transcript?.text,
      polishedText: snapshot.polish?.text,
      failureCode: snapshot.failure?.code,
      canRetry: state != .completed,
      sourceAudioRetained: true,
      createdAt: now,
      updatedAt: now,
      recoveredAt: nil
    )
    history.historyItems.removeAll { $0.sessionID == sessionID }
    history.historyItems.insert(item, at: 0)
    history.homeRecentHistoryItems.removeAll { $0.sessionID == sessionID }
    history.homeRecentHistoryItems.insert(item, at: 0)
    history.homeRecentHistoryItems = Array(history.homeRecentHistoryItems.prefix(5))
  }

  /// Whether a finished dictation reads history back right away. It does so
  /// only when someone can see the result and no other dictation is about to
  /// replace it, because the read costs seconds on a large library.
  nonisolated static func readsHistoryBackNow(
    historyOnScreen: Bool,
    dictationsStillFinishing: Int
  ) -> Bool {
    historyOnScreen && dictationsStillFinishing == 0
  }

  /// Reads history back for whoever opens the window after it went stale.
  func refreshHistoryIfStale() {
    guard historyNeedsRefresh else { return }
    historyNeedsRefresh = false
    Task { [weak self] in
      await self?.refreshHistoryItems(organizeEvents: true)
    }
  }

  nonisolated static func historyCutoff(_ dateRangeFilter: String) -> Date? {
    let calendar = Calendar.current
    let now = Date()
    return switch dateRangeFilter {
    case "today": calendar.startOfDay(for: now)
    case "7-days": calendar.date(byAdding: .day, value: -7, to: now)
    case "30-days": calendar.date(byAdding: .day, value: -30, to: now)
    default: nil
    }
  }

  /// Appends a page only to the exact first-page request that created its cursor.
  func loadMoreHistoryItems() {
    guard !history.pagingExhausted, !history.pageLoading, !history.listLoading,
      let repository = history.repository,
      let query = history.presentedQuery, query == history.currentQuery
    else { return }
    let generation = historyRefreshGenerationGate.current
    let requestID = UUID()
    history.pageRequestID = requestID
    history.pageLoading = true
    history.pageErrorMessage = nil
    let started = ContinuousClock.now
    let recoverySessionIDs = startupRecoverySessionIDs
    let retryingSessionID = history.retryingHistorySessionID
    let eventSessionIDs = historyEventSessionIDs(query)
    let offset = history.nextPageOffset
    history.pageTask = Task { [weak self] in
      defer {
        if let self, history.pageRequestID == requestID {
          history.pageLoading = false
          history.pageRequestID = nil
          history.pageTask = nil
        }
      }
      do {
        let page = try await Self.queryVisibleHistoryPage(
          repository, query: query, offset: offset,
          startupRecoverySessionIDs: recoverySessionIDs,
          retryingSessionID: retryingSessionID, eventSessionIDs: eventSessionIDs
        )
        try Task.checkCancellation()
        guard let self,
          historyRefreshGenerationGate.accepts(generation),
          history.presentedQuery == query, history.currentQuery == query,
          history.pageRequestID == requestID
        else { return }
        let known = Set(history.historyItems.map(\.sessionID))
        let appended = page.items.filter { !known.contains($0.sessionID) }
        history.historyItems.append(contentsOf: appended)
        history.nextPageOffset = page.nextOffset
        history.pagingExhausted = page.exhausted
        updateHistoryListStatus(query)
        Self.logHistoryPublication(started: started, count: appended.count, isPage: true)
      } catch {
        guard !Task.isCancelled, let self,
          historyRefreshGenerationGate.accepts(generation),
          history.presentedQuery == query, history.currentQuery == query,
          history.pageRequestID == requestID
        else { return }
        history.pageErrorMessage = "暂时无法载入更多记录"
      }
    }
  }

  /// Library changes refresh the list immediately and update the independent
  /// Home/source overview in the background. Filter changes call only the list.
  func refreshHistoryItems(
    preserveStatus: Bool = false,
    requestGeneration: UInt64? = nil,
    organizeEvents: Bool = false,
    completingRecoverySessionID: SessionID? = nil,
    refreshOverview: Bool = true
  ) async {
    let task = startHistoryListRefresh(
      preserveStatus: preserveStatus,
      requestGeneration: requestGeneration,
      completingRecoverySessionID: completingRecoverySessionID
    )
    await task?.value
    if refreshOverview { scheduleHistoryOverviewRefresh() }
    if organizeEvents, eventMemoryWanted {
      await refreshEventMemory(organize: true)
    }
  }

  @discardableResult
  func startHistoryListRefresh(
    preserveStatus: Bool = false,
    requestGeneration: UInt64? = nil,
    completingRecoverySessionID: SessionID? = nil,
    debounceSearch: Bool = false
  ) -> Task<Void, Never>? {
    guard let repository = history.repository else { return nil }
    history.listTask?.cancel()
    history.pageTask?.cancel()
    history.pageTask = nil
    history.pageRequestID = nil
    history.pageLoading = false
    history.pageErrorMessage = nil
    history.listErrorMessage = nil
    let started = ContinuousClock.now
    let generation = requestGeneration ?? historyRefreshGenerationGate.begin()
    let query = history.currentQuery
    history.requestedQuery = query
    history.listLoading = true
    let recoverySessionIDs = startupRecoverySessionIDs
    let retryingSessionID =
      history.retryingHistorySessionID == completingRecoverySessionID
      ? nil : history.retryingHistorySessionID
    let eventSessionIDs = historyEventSessionIDs(query)
    let task = Task { [weak self] in
      defer {
        if let self, historyRefreshGenerationGate.accepts(generation) {
          history.listLoading = false
          history.listTask = nil
        }
      }
      do {
        if debounceSearch { try await Task.sleep(for: .milliseconds(180)) }
        try Task.checkCancellation()
        let page = try await Self.queryVisibleHistoryPage(
          repository, query: query, offset: 0,
          startupRecoverySessionIDs: recoverySessionIDs,
          retryingSessionID: retryingSessionID, eventSessionIDs: eventSessionIDs
        )
        try Task.checkCancellation()
        guard let self, historyRefreshGenerationGate.accepts(generation),
          query == history.currentQuery
        else { return }
        let items = page.items
        history.titleDraft = Self.refreshedHistoryTitleDraft(
          history.titleDraft,
          previousTitle: history.historyItems.first {
            $0.sessionID == history.selectedHistorySessionID
          }?.title,
          currentTitle: items.first {
            $0.sessionID == history.selectedHistorySessionID
          }?.title
        )
        history.historyItems = items
        history.presentedQuery = query
        history.nextPageOffset = page.nextOffset
        history.pagingExhausted = page.exhausted
        if !preserveStatus { updateHistoryListStatus(query) }
        Self.logHistoryPublication(started: started, count: items.count, isPage: false)
      } catch is CancellationError {
        // A replacement query owns presentation and loading state now.
      } catch {
        guard !Task.isCancelled, let self,
          historyRefreshGenerationGate.accepts(generation), query == history.currentQuery
        else { return }
        history.listErrorMessage = "暂时无法读取本地历史记录"
        history.historyStatusMessage = "无法读取本地历史记录"
      }
    }
    history.listTask = task
    return task
  }

  private func updateHistoryListStatus(_ query: HistoryListQuery) {
    let searching = !query.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let noun = searching ? "条结果" : "条记录"
    history.historyStatusMessage =
      history.historyItems.isEmpty
      ? (searching ? "没有结果" : "还没有符合条件的本机记录")
      : "\(history.historyItems.count) \(noun)"
  }

  private func historyEventSessionIDs(_ query: HistoryListQuery) -> Set<SessionID>? {
    query.eventID.map { eventID in
      Set(events.summaries.first { $0.id == eventID }?.sessionIDs ?? [])
    }
  }

  /// A presentation filter may exclude every raw row in a page. Continue with
  /// another bounded read until a visible row or the end, checking cancellation
  /// between reads. This applies equally to first pages and later pages.
  private static func queryVisibleHistoryPage(
    _ repository: any HistoryQueryRepository, query: HistoryListQuery, offset: Int,
    startupRecoverySessionIDs: Set<SessionID>, retryingSessionID: SessionID?,
    eventSessionIDs: Set<SessionID>?
  ) async throws -> (items: [DictationHistoryItem], nextOffset: Int, exhausted: Bool) {
    var nextOffset = offset
    while true {
      try Task.checkCancellation()
      let rows = try await queryHistory(
        repository, query: query, offset: nextOffset, retryingSessionID: retryingSessionID
      )
      try Task.checkCancellation()
      nextOffset += rows.count
      let items = rows.filter { item in
        historyItemMatchesStatusFilter(
          item, filter: query.status, startupRecoverySessionIDs: startupRecoverySessionIDs,
          retryingSessionID: retryingSessionID
        )
          && (query.personID.map { item.personIDs.contains($0) } ?? true)
          && (eventSessionIDs.map { $0.contains(item.sessionID) } ?? true)
          && historyItemMatchesDurationFilter(item, filter: query.duration)
          && (!query.summaryOnly || item.hasLocalTextDocuments)
      }
      let exhausted = rows.count < historyPageSize
      if !items.isEmpty || exhausted { return (items, nextOffset, exhausted) }
    }
  }

  nonisolated private static func logHistoryPublication(
    started: ContinuousClock.Instant, count: Int, isPage: Bool
  ) {
    let elapsed = (ContinuousClock.now - started).components
    let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
    // Only timing and result cardinality; never query text, app IDs or content.
    if isPage {
      dictationAppLogger.notice(
        "history page published ms=\(milliseconds, privacy: .public) count=\(count, privacy: .public)"
      )
    } else {
      dictationAppLogger.notice(
        "history list published ms=\(milliseconds, privacy: .public) count=\(count, privacy: .public)"
      )
    }
  }

  nonisolated private static func queryHistory(
    _ repository: any HistoryQueryRepository,
    query: HistoryListQuery, offset: Int, retryingSessionID: SessionID?
  ) async throws -> [DictationHistoryItem] {
    try Task.checkCancellation()
    let candidatePhases: [DictationPhase]? =
      switch query.status {
      case "processing":
        DictationPhase.allCases.filter {
          ![.completed, .cancelled, .failedRecoverable].contains($0)
        }
      case "recoverable":
        DictationPhase.allCases.filter { $0.isActive || $0 == .failedRecoverable }
      case "completed": [.completed]
      default: nil
      }
    return try await repository.searchHistory(
      query: query.search,
      mode: query.mode == "all" ? nil : SessionInputMode(rawValue: query.mode),
      status: ["all", "recoverable", "processing", "completed"].contains(query.status)
        ? nil : DictationHistoryStatus(rawValue: query.status),
      candidatePhases: candidatePhases,
      includingSessionID: query.status == "processing" ? retryingSessionID : nil,
      sourceApplication: query.sourceApplication.isEmpty ? nil : query.sourceApplication,
      since: historyCutoff(query.dateRange),
      limit: historyPageSize,
      offset: offset
    )
  }

  /// Coalesce library mutations during an overview read into one follow-up read.
  /// Selecting filters never starts, cancels, or waits for these library-wide jobs.
  func scheduleHistoryOverviewRefresh() {
    guard let repository = history.repository else { return }
    history.overviewNeedsRefresh = true
    guard history.overviewTask == nil else { return }
    history.overviewTask = Task(priority: .utility) { [weak self] in
      guard let self else { return }
      defer { history.overviewTask = nil }
      repeat {
        history.overviewNeedsRefresh = false
        do {
          async let applications = repository.historySourceApplications()
          async let recent = repository.loadHistory(limit: 5)
          let (sources, recentItems) = try await (applications, recent)
          try Task.checkCancellation()
          history.sourceApplications = sources
          history.homeRecentHistoryItems = recentItems
          let (statistics, summary) = try await Self.loadHistoryUsage(repository)
          try Task.checkCancellation()
          usage.usageStatistics = statistics
          usage.usage = summary
          usage.usageLoaded = true
        } catch is CancellationError {
          return
        } catch {
          // Keep the previous overview on a transient read failure. List errors
          // belong to the list request and must not be overwritten here.
        }
      } while history.overviewNeedsRefresh && !Task.isCancelled
    }
  }

  /// Aggregate the activity text off MainActor; only the small result is published.
  nonisolated private static func loadHistoryUsage(
    _ repository: any HistoryQueryRepository
  ) async throws -> (LocalHistoryUsageStatistics, DictationUsageSummary) {
    async let statistics = repository.historyUsageStatistics()
    async let records = repository.dictationActivityRecords()
    let (usage, activity) = try await (statistics, records)
    try Task.checkCancellation()
    return (usage, DictationUsageSummary.make(activity))
  }

  static func fixtureHistoryItems() -> [DictationHistoryItem] {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return [
      DictationHistoryItem(
        sessionID: SessionID(
          UUID(uuidString: "41000000-0000-4000-8000-000000000001")!
        ),
        revision: 8,
        phase: .completed,
        status: .completed,
        rawText: "fixture raw dictation",
        polishedText: "Fixture raw dictation.",
        failureCode: nil,
        canRetry: false,
        sourceAudioRetained: true,
        createdAt: now,
        updatedAt: now,
        recoveredAt: nil
      ),
      DictationHistoryItem(
        sessionID: SessionID(
          UUID(uuidString: "41000000-0000-4000-8000-000000000002")!
        ),
        revision: 4,
        phase: .failedRecoverable,
        status: .failed,
        rawText: nil,
        polishedText: nil,
        failureCode: "fixture-model-unavailable",
        canRetry: true,
        sourceAudioRetained: true,
        createdAt: now.addingTimeInterval(-60),
        updatedAt: now,
        recoveredAt: nil
      ),
      DictationHistoryItem(
        sessionID: SessionID(
          UUID(uuidString: "41000000-0000-4000-8000-000000000003")!
        ),
        revision: 6,
        phase: .completed,
        status: .recovered,
        rawText: "recovered fixture",
        polishedText: "Recovered fixture.",
        failureCode: nil,
        canRetry: false,
        sourceAudioRetained: true,
        createdAt: now.addingTimeInterval(-120),
        updatedAt: now,
        recoveredAt: now
      ),
      DictationHistoryItem(
        sessionID: SessionID(
          UUID(uuidString: "41000000-0000-4000-8000-000000000004")!
        ),
        revision: 3,
        phase: .recognizing,
        status: .processing,
        rawText: nil,
        polishedText: nil,
        failureCode: nil,
        canRetry: true,
        sourceAudioRetained: true,
        createdAt: now.addingTimeInterval(-180),
        updatedAt: now,
        recoveredAt: nil
      ),
    ]
  }
}
