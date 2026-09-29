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



// HistoryEditing: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  func saveHistoryTitle(completion: @escaping (Bool) -> Void = { _ in }) {
    guard !history.titleSaveInProgress,
      let sessionID = history.selectedHistorySessionID, let repository
    else {
      completion(false)
      return
    }
    let title = history.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      history.detailStatusMessage = "标题不能为空"
      completion(false)
      return
    }
    history.titleSaveInProgress = true
    history.detailStatusMessage = "正在保存标题…"
    Task { [weak self] in
      guard let self else {
        completion(false)
        return
      }
      defer { history.titleSaveInProgress = false }
      do {
        try await repository.renameSession(sessionID: sessionID, title: title)
        await refreshHistoryItems(organizeEvents: true)
        if history.selectedHistorySessionID == sessionID {
          history.detailStatusMessage = "标题已保存在本机"
          if history.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines) == title {
            history.titleDraft = title
          }
        }
        completion(true)
      } catch {
        if history.selectedHistorySessionID == sessionID {
          history.detailStatusMessage = "标题未能保存；草稿和原记录仍保留，请重试"
        }
        completion(false)
      }
    }
  }

  nonisolated static func refreshedHistoryTitleDraft(
    _ draft: String,
    previousTitle: String?,
    currentTitle: String?
  ) -> String {
    guard draft == previousTitle, let currentTitle else { return draft }
    return currentTitle
  }

  func discardUnsavedHistoryTranscriptEdit() {
    history.transcriptEditDraft =
      selectedHistoryFinalText
      ?? selectedHistoryRawText
      ?? ""
    history.detailStatusMessage = "已放弃未保存的文字修改"
  }

  func restoreHistoryTranscriptRevision(
    _ transcript: DictationPersistedTranscriptRecord
  ) {
    guard let sessionID = history.selectedHistorySessionID, let repository,
      transcript.sessionID == sessionID,
      let current = selectedHistoryCurrentTranscript,
      !history.reprocessingInProgress
    else { return }
    history.reprocessingInProgress = true
    history.detailStatusMessage = "正在恢复所选版本；当前版本和原音仍会保留…"
    Task { [weak self] in
      guard let self else { return }
      defer { history.reprocessingInProgress = false }
      do {
        let restored = try await repository.restoreTranscriptRevision(
          sessionID: sessionID,
          sourceTranscriptID: transcript.id,
          expectedCurrentTranscriptID: current.id
        )
        try? await repository.setAutomaticSessionTitle(sessionID: sessionID, from: restored.content)
        historyTranscriptEditSessionID = nil
        await refreshSelectedSpeakerDetails(sessionID: sessionID)
        await refreshHistoryItems(preserveStatus: true, organizeEvents: true)
        history.detailStatusMessage = "所选版本已恢复，时间戳和原音关联保持不变；其他版本仍可找回"
      } catch {
        history.detailStatusMessage = "恢复未完成；当前文字、未保存修改和原音没有变化"
      }
    }
  }

  func generateHistoryActionItems() {
    generateHistoryDocument(taskID: .actionItems)
  }

  func generateHistoryChapters() {
    generateHistoryDocument(taskID: .chapters)
  }

  func generateHistoryDecisions() {
    generateHistoryDocument(taskID: .decisions)
  }

  func saveHistoryDocumentEdit(_ document: LocalTextDocumentRecord) {
    persistHistoryDocumentEdit(document) { $0 }
  }

  func toggleHistoryStructuredItemCompletion(
    _ item: LocalTextStructuredItem,
    in document: LocalTextDocumentRecord
  ) {
    persistHistoryDocumentEdit(document) { items in
      items.map { candidate in
        guard candidate.itemID == item.itemID else { return candidate }
        return LocalTextStructuredItem(
          itemID: candidate.itemID,
          kind: candidate.kind,
          text: candidate.text,
          owner: candidate.owner,
          sourceSegmentIDs: candidate.sourceSegmentIDs,
          confidence: candidate.confidence,
          disposition: candidate.disposition,
          dueDateText: candidate.dueDateText,
          completedAt: candidate.completedAt == nil ? Date() : nil
        )
      }
    }
  }

  func deleteHistoryStructuredItem(
    _ item: LocalTextStructuredItem,
    from document: LocalTextDocumentRecord
  ) {
    persistHistoryDocumentEdit(document) { items in
      items.filter { $0.itemID != item.itemID }
    }
  }

  func persistHistoryDocumentEdit(
    _ document: LocalTextDocumentRecord,
    transform: @escaping ([LocalTextStructuredItem]) -> [LocalTextStructuredItem]
  ) {
    guard document.state == .current, let repository,
      !history.reprocessingInProgress
    else { return }
    var items = document.result.structuredItems.compactMap { item -> LocalTextStructuredItem? in
      let text = history.structuredItemTextDrafts[item.itemID, default: item.text]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      let ownerDraft = history.structuredItemOwnerDrafts[
        item.itemID,
        default: item.owner ?? ""
      ].trimmingCharacters(in: .whitespacesAndNewlines)
      let dueDateDraft = history.structuredItemDueDateDrafts[
        item.itemID,
        default: item.dueDateText ?? ""
      ].trimmingCharacters(in: .whitespacesAndNewlines)
      return LocalTextStructuredItem(
        itemID: item.itemID,
        kind: item.kind,
        text: text,
        owner: ownerDraft.isEmpty ? nil : ownerDraft,
        sourceSegmentIDs: item.sourceSegmentIDs,
        confidence: item.confidence,
        disposition: item.disposition,
        dueDateText: dueDateDraft.isEmpty ? nil : dueDateDraft,
        completedAt: item.completedAt
      )
    }
    items = transform(items)
    var outputText = history.documentTextDrafts[
      document.id,
      default: document.result.outputText
    ].trimmingCharacters(in: .whitespacesAndNewlines)
    if outputText.isEmpty, !items.isEmpty {
      outputText = items.map(\.text).joined(separator: "\n")
    }
    if items.isEmpty,
      [.actionItems, .chapters, .decisions].contains(document.taskID)
    {
      outputText =
        switch document.taskID {
        case .actionItems: "当前没有保留的待办。"
        case .chapters: "当前没有保留的章节。"
        case .decisions: "当前没有保留的结论。"
        default: outputText
        }
    }
    guard !outputText.isEmpty else {
      history.detailStatusMessage = "整理结果不能为空"
      return
    }
    let editedModelID = "bestasr-user-edit-v1"
    let editedClaims: [LocalTextClaim] =
      if !items.isEmpty {
        items.map { item in
          LocalTextClaim(
            claimID: item.itemID,
            text: item.text,
            sourceSegmentIDs: item.sourceSegmentIDs,
            confidence: item.confidence,
            // User-edited wording remains linked to its source timestamps but
            // is never misrepresented as untouched model-supported text.
            disposition: .cautious
          )
        }
      } else {
        [
          LocalTextClaim(
            claimID: UUID(),
            text: outputText,
            sourceSegmentIDs: Array(
              Set(document.result.claims.flatMap(\.sourceSegmentIDs))
            ).sorted { $0.uuidString < $1.uuidString },
            confidence: nil,
            disposition: .cautious
          )
        ]
      }
    let result = LocalTextResult(
      contractVersion: document.result.contractVersion,
      modelArtifactID: editedModelID,
      taskID: document.taskID,
      outputText: outputText,
      claims: editedClaims,
      structuredItems: items
    )
    history.reprocessingInProgress = true
    history.detailStatusMessage = "正在保存编辑；原来的整理结果仍会保留…"
    Task { [weak self] in
      guard let self else { return }
      defer { history.reprocessingInProgress = false }
      do {
        let encoded = try JSONEncoder().encode(result)
        let hash = SHA256.hash(data: encoded).map {
          String(format: "%02x", $0)
        }.joined()
        let edited = LocalTextDocumentRecord(
          id: UUID(),
          sessionID: document.sessionID,
          sourceTranscriptID: document.sourceTranscriptID,
          sourceRevision: document.sourceRevision,
          taskID: document.taskID,
          modelArtifactID: editedModelID,
          configHash: try SHA256Digest(hash),
          result: result,
          state: .current,
          createdAt: Date()
        )
        try await repository.saveLocalTextDocument(edited)
        history.detailStatusMessage =
          "编辑已保存为新版本；来源逐字稿、时间戳和旧整理结果均未覆盖"
        await refreshSelectedSpeakerDetails(sessionID: document.sessionID)
        await refreshHistoryItems(
          preserveStatus: true,
          organizeEvents: true
        )
      } catch {
        history.detailStatusMessage = "编辑未保存；现有整理结果没有变化"
      }
    }
  }

  func saveHistoryTranscriptEdit() {
    guard let sessionID = history.selectedHistorySessionID, let repository,
      !history.reprocessingInProgress
    else { return }
    let content = history.transcriptEditDraft
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      history.detailStatusMessage = "修改后的文字不能为空"
      return
    }
    history.reprocessingInProgress = true
    history.detailStatusMessage = "正在保存新的人工校对版本；旧版本不会被覆盖…"
    Task { [weak self] in
      guard let self else { return }
      defer { history.reprocessingInProgress = false }
      do {
        let edited = try await repository.saveUserTranscriptEdit(
          sessionID: sessionID,
          content: content
        )
        try? await repository.setAutomaticSessionTitle(sessionID: sessionID, from: edited.content)
        history.detailStatusMessage =
          "人工校对已保存为新版本；旧逐字稿、时间戳和原音仍完整保留"
        historyTranscriptEditSessionID = nil
        await refreshSelectedSpeakerDetails(sessionID: sessionID)
        await refreshHistoryItems(
          preserveStatus: true,
          organizeEvents: true
        )
      } catch {
        history.detailStatusMessage = "人工校对未保存；现有版本没有变化"
      }
    }
  }

  func canEditHistoryTranscriptSegments(
    _ transcript: DictationPersistedTranscriptRecord
  ) -> Bool {
    selectedHistoryCurrentTranscript?.id == transcript.id
      && !transcript.segments.isEmpty
      && !history.reprocessingInProgress
  }

  func saveHistoryTranscriptSegmentEdit(
    transcript: DictationPersistedTranscriptRecord,
    segment: DictationTranscriptSegment,
    replacement: String,
    completion: ((Bool) -> Void)? = nil
  ) {
    guard canEditHistoryTranscriptSegments(transcript) else {
      history.detailStatusMessage = "逐字稿刚刚发生了变化；请在当前内容上重新修改"
      completion?(false)
      return
    }
    let text = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      history.detailStatusMessage = "这一段文字不能为空"
      completion?(false)
      return
    }
    guard text != segment.text else {
      history.detailStatusMessage = "这一段没有需要保存的修改"
      completion?(false)
      return
    }
    if fixtureMode,
      var fixture = historyPlaybackUIFixture,
      fixture.sessionID == transcript.sessionID
    {
      let editedSegments = transcript.segments.map { current in
        current.id == segment.id
          ? DictationTranscriptSegment(
            id: current.id,
            monotonicStartNanoseconds: current.monotonicStartNanoseconds,
            monotonicEndNanoseconds: current.monotonicEndNanoseconds,
            text: text,
            confidence: current.confidence
          ) : current
      }
      let edited = DictationPersistedTranscriptRecord(
        id: TranscriptRevisionID(),
        sessionID: transcript.sessionID,
        inputRevision: transcript.inputRevision + 1,
        parentID: transcript.id,
        kind: .userEdit,
        content: TranscriptTextJoiner.join(editedSegments.map(\.text)),
        modelArtifactID: "user-inline-edit-ui-fixture-v1",
        configHash: transcript.configHash,
        languageHints: transcript.languageHints,
        audioRanges: transcript.audioRanges,
        segments: editedSegments,
        createdAt: Date()
      )
      fixture.transcript = edited
      historyPlaybackUIFixture = fixture
      history.selectedHistoryTranscripts.append(edited)
      history.transcriptEditDraft = edited.content
      history.detailStatusMessage =
        "修改已保存；播放时间点、人物线索和原音都保持不变"
      completion?(true)
      return
    }
    guard let repository else {
      history.detailStatusMessage = "这一段没有保存；现有文字、时间点和原音都没有变化"
      completion?(false)
      return
    }
    history.reprocessingInProgress = true
    history.detailStatusMessage = "正在保存这一段修改…"
    Task { [weak self] in
      guard let self else { return }
      defer { history.reprocessingInProgress = false }
      do {
        let edited = try await repository.saveUserTranscriptSegmentEdit(
          sessionID: transcript.sessionID,
          sourceTranscriptID: transcript.id,
          segmentID: segment.id,
          replacement: text
        )
        try? await repository.setAutomaticSessionTitle(
          sessionID: transcript.sessionID, from: edited.content
        )
        history.detailStatusMessage = "修改已保存；播放时间点、人物线索和原音都保持不变"
        await refreshSelectedSpeakerDetails(sessionID: transcript.sessionID)
        await refreshHistoryItems(
          preserveStatus: true,
          organizeEvents: true
        )
        completion?(true)
      } catch BestASRPersistenceError.processingCommitConflict {
        history.detailStatusMessage = "逐字稿刚刚发生了变化；请在当前内容上重新修改"
        await refreshSelectedSpeakerDetails(sessionID: transcript.sessionID)
        completion?(false)
      } catch {
        history.detailStatusMessage = "这一段没有保存；现有文字、时间点和原音都没有变化"
        completion?(false)
      }
    }
  }

  func rerecognizeSelectedHistory() {
    guard let sessionID = history.selectedHistorySessionID, let localRuntime,
      models.modelRuntimeReady, !history.reprocessingInProgress,
      history.historyItems.first(where: { $0.sessionID == sessionID })?
        .sourceAudioRetained == true
    else {
      history.detailStatusMessage = "本地语音识别组件未就绪，或这条记录的原音已由你删除"
      return
    }
    history.reprocessingInProgress = true
    history.detailStatusMessage = "正在从保留原音重新识别文字与说话人；原音、旧文字和人工确认仍保留…"
    Task { [weak self] in
      guard let self else { return }
      defer { history.reprocessingInProgress = false }
      do {
        let outcome = try await localRuntime.rerecognizeHistory(sessionID: sessionID)
        setHistoryDetailFeedback(outcome.detailMessage, for: sessionID)
        if history.selectedHistorySessionID == sessionID {
          historyTranscriptEditSessionID = nil
        }
        await refreshSelectedSpeakerDetails(sessionID: sessionID)
        await refreshHistoryItems(
          preserveStatus: true,
          organizeEvents: true
        )
      } catch {
        setHistoryDetailFeedback("重新识别未完成；原音和现有文字版本仍保留", for: sessionID)
      }
    }
  }

  func repolishSelectedHistory() {
    guard let sessionID = history.selectedHistorySessionID, let localRuntime,
      !history.reprocessingInProgress
    else { return }
    history.reprocessingInProgress = true
    history.detailStatusMessage = "正在按当前词典和 App 策略重新整理…"
    Task { [weak self] in
      guard let self else { return }
      defer { history.reprocessingInProgress = false }
      do {
        try await localRuntime.repolishHistory(sessionID: sessionID)
        setHistoryDetailFeedback("新的整理结果已保存；来源文字版本仍可追溯", for: sessionID)
        await refreshSelectedSpeakerDetails(sessionID: sessionID)
        await refreshHistoryItems(
          preserveStatus: true,
          organizeEvents: true
        )
      } catch {
        setHistoryDetailFeedback("重新整理未完成；来源文字没有变化", for: sessionID)
      }
    }
  }

  func generateHistoryDocument(taskID: LocalTextTaskID) {
    guard let sessionID = history.selectedHistorySessionID,
      history.generatingHistoryDocumentTaskID == nil
    else { return }
    guard polishRuntimeReady, let localRuntime else {
      history.detailStatusMessage = "请先安装并校验本地文字整理组件"
      return
    }
    history.generatingHistoryDocumentTaskID = taskID
    let title = Self.localTextTaskTitle(taskID)
    history.detailStatusMessage = "正在这台 Mac 上生成\(title)…"
    Task { [weak self] in
      guard let self else { return }
      defer { history.generatingHistoryDocumentTaskID = nil }
      do {
        _ = try await localRuntime.generateLocalTextDocument(
          sessionID: sessionID,
          taskID: taskID
        )
        guard history.selectedHistorySessionID == sessionID else { return }
        history.detailStatusMessage =
          "\(title)已生成，并保留到原始逐字稿及时间戳的来源关系"
        await refreshSelectedSpeakerDetails(sessionID: sessionID)
      } catch {
        let diagnosticCode = LocalDictationRuntime.processingDiagnosticCode(
          for: error
        )
        let taskCode = taskID.rawValue
        dictationAppLogger.error(
          "local text failed: task=\(taskCode, privacy: .public) code=\(diagnosticCode, privacy: .public)"
        )
        if history.selectedHistorySessionID == sessionID {
          history.detailStatusMessage =
            "本地整理未完成；原始逐字稿未被修改，请稍后重试"
        }
      }
    }
  }

  func historyTranscriptSegment(
    overlappingStart start: UInt64,
    end: UInt64
  ) -> DictationTranscriptSegment? {
    selectedHistoryTimestampedTranscript?.segments.first { segment in
      segment.monotonicStartNanoseconds < end
        && segment.monotonicEndNanoseconds > start
    }
  }
}
