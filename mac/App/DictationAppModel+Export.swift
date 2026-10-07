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


// Export: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  func exportDiagnostics() {
    refreshDiagnosticsPreview()
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "Mindloom 诊断信息.txt"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      try diagnosticsPreview.data(using: .utf8)?.write(
        to: destination,
        options: .atomic
      )
      preferencesStatusMessage = "不含音频、文字、词典、人物或窗口信息的诊断摘要已导出"
    } catch {
      preferencesStatusMessage = "诊断摘要导出失败"
    }
  }

  /// Converts a selection in the gap-free player timeline back into the
  /// capture's monotonic clock. A range can span discontinuities, but export
  /// still copies only authenticated committed chunks from the selected track.
  func historySelectedExportMonotonicRange() -> Range<UInt64>? {
    let ranges = selectedHistoryPlaybackRanges()
    guard !ranges.isEmpty else { return nil }
    let duration = ranges.reduce(0.0) {
      $0 + Double($1.monotonicEndNanoseconds - $1.monotonicStartNanoseconds)
        / 1_000_000_000
    }
    let start = min(max(0, export.exportSelectionStart), duration)
    let end = min(max(start, export.exportSelectionEnd), duration)
    guard start > 0.000_001 || end < duration - 0.000_001 else { return nil }
    guard end - start >= 0.001 else { return nil }

    func monotonicTimestamp(at position: Double, preferEnd: Bool) -> UInt64 {
      var remaining = position
      for range in ranges {
        let rangeDuration =
          Double(
            range.monotonicEndNanoseconds - range.monotonicStartNanoseconds
          ) / 1_000_000_000
        if remaining < rangeDuration || (preferEnd && remaining <= rangeDuration) {
          let offset = UInt64(max(0, remaining) * 1_000_000_000)
          return min(
            range.monotonicEndNanoseconds,
            range.monotonicStartNanoseconds + offset
          )
        }
        remaining -= rangeDuration
      }
      return ranges.last!.monotonicEndNanoseconds
    }

    let lower = monotonicTimestamp(at: start, preferEnd: false)
    let upper = monotonicTimestamp(at: end, preferEnd: true)
    return lower < upper ? lower..<upper : nil
  }

  /// `item` is the selected record when it is not in the App's lists (a 历史
  /// row's own export); `report` hears how it went.
  func exportSelectedHistory(
    _ format: LocalHistoryExportFormat, item selected: DictationHistoryItem? = nil,
    report: (@MainActor (String) -> Void)? = nil
  ) {
    guard !export.exportInProgress,
      let sessionID = history.selectedHistorySessionID,
      let item = selected.flatMap({ $0.sessionID == sessionID ? $0 : nil })
        ?? history.historyItems.first(where: { $0.sessionID == sessionID })
    else {
      export.exportStatusMessage = "请先打开一条历史记录"
      report?(export.exportInProgress ? "上一次导出尚未完成" : "这条记录暂时无法打开")
      return
    }
    let panel = NSSavePanel()
    panel.title = "导出\(format.displayName)"
    panel.nameFieldStringValue = Self.historyExportFilename(
      item: item,
      extensionValue: format.rawValue
    )
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    if let type = UTType(filenameExtension: format.rawValue) {
      panel.allowedContentTypes = [type]
    }
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    let context = LocalHistoryExportContext(
      history: item,
      transcripts: history.selectedHistoryTranscripts,
      documents: history.selectedHistoryDocuments,
      speakers: people.selectedSessionSpeakers,
      occurrences: selectedSessionOccurrences
    )
    // A dictation from the last hour may not have its sentences timed yet
    // (DICTATION_ARCHITECTURE §15.7): time them now, so captions and
    // timestamps are per sentence, with the aligner alone (a recognizer in
    // memory is released first; the next press loads it again while the
    // user speaks). Without them it exports as one sentence.
    let timeSentences =
      history.selectedHistoryTranscripts.contains(where: Self.hasUntimedSentences)
      ? localRuntime : nil
    let repository = repository
    export.exportInProgress = true
    export.exportStatusMessage = "正在本机生成\(format.displayName)…"
    Task { [weak self] in
      guard let self else { return }
      defer { export.exportInProgress = false }
      do {
        var exported = context
        if let timeSentences, let repository,
          await timeSentences.alignDeferredWords(
            sessionID: sessionID, releasingRecognizer: true) > 0,
          let timed = try? await repository.loadTranscripts(sessionID: sessionID)
        {
          exported = LocalHistoryExportContext(
            history: item, transcripts: timed, documents: context.documents,
            speakers: context.speakers, occurrences: context.occurrences)
        }
        try await historyExporter.exportText(
          format: format,
          context: exported,
          to: destination
        )
        export.exportStatusMessage = "已导出到 \(destination.lastPathComponent)；历史记录未被修改"
        report?("已导出到“\(destination.lastPathComponent)”")
      } catch {
        export.exportStatusMessage = "导出未完成；历史记录和原始音频未被修改"
        report?("未能导出。请重试。")
      }
    }
  }

  func exportSelectedHistorySourceAudio(report: (@MainActor (String) -> Void)? = nil) {
    guard !export.exportInProgress,
      let sessionID = history.selectedHistorySessionID,
      let journal
    else {
      export.exportStatusMessage = "请先打开一条包含原音的历史记录"
      report?(export.exportInProgress ? "上一次导出尚未完成" : "这段录音暂时无法打开")
      return
    }
    let imported = history.selectedHistorySourceAssets.first(where: {
      $0.kind == .importedOriginal
    })
    let selectedTrackID = UUID(uuidString: playback.selectedHistoryPlaybackTrackID)
    let selectedRange = historySelectedExportMonotonicRange()
    let exportsImportedOriginal = imported != nil && selectedRange == nil
    guard imported != nil || selectedTrackID != nil else {
      export.exportStatusMessage = "这条记录没有可导出的保留原音"
      report?("这条记录没有保留录音")
      return
    }
    guard exportsImportedOriginal || selectedTrackID != nil else {
      export.exportStatusMessage = "所选范围没有可导出的本地音轨"
      report?("这段录音暂时无法打开")
      return
    }
    let panel = NSSavePanel()
    panel.title =
      exportsImportedOriginal
      ? "导出未转码的导入原文件"
      : "导出当前音轨的保留原音"
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    if exportsImportedOriginal, let imported {
      let sourceExtension = (imported.originalFilename as NSString)
        .pathExtension.lowercased()
      panel.nameFieldStringValue =
        sourceExtension.isEmpty
        ? "Mindloom-导入原文件"
        : "Mindloom-导入原文件.\(sourceExtension)"
      if let type = UTType(filenameExtension: sourceExtension) {
        panel.allowedContentTypes = [type]
      }
    } else {
      let trackTitle = historyPlaybackTrackTitle(playback.selectedHistoryPlaybackTrackID)
      panel.nameFieldStringValue = "Mindloom-\(trackTitle)-原音.wav"
      panel.allowedContentTypes = [.wav]
    }
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    export.exportInProgress = true
    export.exportStatusMessage =
      exportsImportedOriginal
      ? "正在校验并逐字节导出未转码原文件…"
      : "正在校验并导出当前音轨…"
    Task { [weak self] in
      guard let self else { return }
      defer { export.exportInProgress = false }
      do {
        if exportsImportedOriginal, let imported {
          try await historyExporter.exportImportedOriginal(
            imported,
            assetRoot: journal.assetRootURL,
            to: destination
          )
        } else if let selectedTrackID {
          _ = try await journal.exportSourceTrackAsWave(
            sessionID: sessionID,
            trackID: TrackID(selectedTrackID),
            to: destination,
            monotonicRange: selectedRange
          )
        }
        export.exportStatusMessage =
          exportsImportedOriginal
          ? "导入原文件已校验并原样导出；历史源资产未被改写"
          : "当前音轨已按所选范围导出为无损 WAV；历史源资产未被改写"
        report?("已导出到“\(destination.lastPathComponent)”")
      } catch {
        export.exportStatusMessage = "原音导出失败；源资产未被修改"
        report?("未能导出。请重试。")
      }
    }
  }

  func exportPortableArchive() {
    guard !export.archiveOperationInProgress, let repository, let journal else { return }
    guard archiveSecretIsValid else {
      export.archiveStatusMessage = "请设置至少 12 个字符的归档口令，并再次输入确认"
      return
    }
    guard !hasActiveCapture else {
      export.archiveStatusMessage = "请先结束或取消当前录音/导入，再生成一致的完整归档"
      return
    }
    let panel = NSSavePanel()
    panel.title = "导出 Mindloom 完整加密归档"
    panel.nameFieldStringValue = "Mindloom-\(Self.archiveDateStamp()).bestasrarchive"
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    if let type = UTType(filenameExtension: "bestasrarchive") {
      panel.allowedContentTypes = [type]
    }
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    let secretBytes = Data(export.archiveSecretDraft.utf8)
    export.archiveOperationInProgress = true
    export.archiveStatusMessage = "正在校验并加密全部可迁移数据；原始历史保持可用…"
    Task { [weak self] in
      guard let self else { return }
      defer {
        export.archiveOperationInProgress = false
        export.archiveSecretDraft = ""
        export.archiveSecretConfirmationDraft = ""
      }
      do {
        let secret = try PortableArchiveSecret(bytes: secretBytes)
        let state = try await repository.exportPortablePersistenceState()
        let result = try await portableArchiveStore.exportArchive(
          persistence: state,
          assetRoot: journal.assetRootURL,
          settings: portableSettings(),
          secret: secret,
          to: destination
        )
        export.archiveStatusMessage =
          "加密归档已完成：\(result.assetCount) 个本地资产；模型和缓存未包含"
      } catch {
        export.archiveStatusMessage = "归档未完成；现有历史、原音和设置未被修改"
      }
    }
  }

  func importPortableArchive() {
    guard !export.archiveOperationInProgress, let repository, let journal else { return }
    guard archiveSecretIsValid else {
      export.archiveStatusMessage = "请输入归档口令，并在第二栏再次确认"
      return
    }
    guard !hasActiveCapture else {
      export.archiveStatusMessage = "请先结束或取消当前录音/导入，再恢复完整归档"
      return
    }
    guard !remoteOrganizerRefusesArchiveImport else {
      // A marked synthetic root is the only library that may be sent during
      // development; an archive (possibly of the real library) must not
      // enter it.
      export.archiveStatusMessage =
        "开发阶段不向合成演示资料库导入归档：它是唯一允许发往 Spark 的资料库，归档内容来源无法确认"
      return
    }
    let panel = NSOpenPanel()
    panel.title = "恢复 Mindloom 完整加密归档"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    if let type = UTType(filenameExtension: "bestasrarchive") {
      panel.allowedContentTypes = [type]
    }
    guard panel.runModal() == .OK, let source = panel.url else { return }
    let secretBytes = Data(export.archiveSecretDraft.utf8)
    export.archiveOperationInProgress = true
    export.archiveStatusMessage =
      "正在验证口令、认证标签、版本、摘要、空间和所有关系；验证完成后开始导入…"
    Task { [weak self] in
      guard let self else { return }
      defer {
        export.archiveOperationInProgress = false
        export.archiveSecretDraft = ""
        export.archiveSecretConfirmationDraft = ""
      }
      do {
        let secret = try PortableArchiveSecret(bytes: secretBytes)
        let result = try await portableArchiveStore.importArchive(
          at: source,
          secret: secret,
          repository: repository,
          assetRoot: journal.assetRootURL
        )
        await applyPortableSettings(result.settings)
        // The import turned the Spark link off (imported rows have unknown
        // provenance); the app reflects that now, not at the next launch.
        await remoteOrganizerArchiveImported()
        await refreshHistoryItems(organizeEvents: true)
        await dictionary.refreshEntries()
        people.personSummaries = Self.browsablePersonSummaries(
          try await repository.personSummaries()
        )
        export.archiveStatusMessage =
          "归档已恢复：新增 \(result.importedAssetCount) 个资产，复用 \(result.reusedAssetCount) 个相同资产"
      } catch {
        export.archiveStatusMessage =
          "恢复失败：口令、完整性、版本、空间或数据冲突未通过；现有历史未被部分覆盖"
      }
    }
  }

  static func historyExportFilename(
    item: DictationHistoryItem,
    extensionValue: String
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "Mindloom-\(formatter.string(from: item.createdAt)).\(extensionValue)"
  }

  static func archiveDateStamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }
}
