import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRPersistence
import CryptoKit
import Foundation

enum LocalHistoryExportFormat: String, CaseIterable, Sendable {
  case plainText = "txt"
  case markdown = "md"
  case srt
  case vtt
  case json

  var displayName: String {
    switch self {
    case .plainText: "纯文本"
    case .markdown: "Markdown"
    case .srt: "SRT 字幕"
    case .vtt: "VTT 字幕"
    case .json: "结构化 JSON"
    }
  }
}

struct LocalHistoryExportContext: Sendable {
  let history: DictationHistoryItem
  let transcripts: [DictationPersistedTranscriptRecord]
  let documents: [LocalTextDocumentRecord]
  let speakers: [SessionSpeakerSummary]
  let occurrences: [SpeakerOccurrenceSummary]
}

enum LocalHistoryExportError: Error, Equatable, Sendable {
  case destinationExists
  case digestMismatch
  case missingTranscript
  case sourceMissing
}

actor LocalHistoryExporter {
  func exportText(
    format: LocalHistoryExportFormat,
    context: LocalHistoryExportContext,
    to destination: URL
  ) throws {
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw LocalHistoryExportError.destinationExists
    }
    let data: Data
    switch format {
    case .plainText:
      data = Data(plainText(context).utf8)
    case .markdown:
      data = Data(markdown(context).utf8)
    case .srt:
      data = Data(try captions(context, webVTT: false).utf8)
    case .vtt:
      data = Data(try captions(context, webVTT: true).utf8)
    case .json:
      data = try structuredJSON(context)
    }
    try atomicWrite(data, to: destination)
  }

  func exportImportedOriginal(
    _ asset: RetainedSourceAssetRecord,
    assetRoot: URL,
    to destination: URL
  ) throws {
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw LocalHistoryExportError.destinationExists
    }
    guard case .relativePath(let relativePath) = asset.assetReference,
      relativePath.hasPrefix(
        "sessions/\(asset.sessionID.rawValue.uuidString.lowercased())/source/"
      )
    else {
      throw LocalHistoryExportError.sourceMissing
    }
    let source = assetRoot.appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw LocalHistoryExportError.sourceMissing
    }
    guard try fileDigest(source) == asset.digest.value.lowercased() else {
      throw LocalHistoryExportError.digestMismatch
    }
    let parent = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent,
      withIntermediateDirectories: true
    )
    let staging = parent.appendingPathComponent(
      ".\(UUID().uuidString).source-exporting"
    )
    defer { try? FileManager.default.removeItem(at: staging) }
    guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let input = try FileHandle(forReadingFrom: source)
    let output = try FileHandle(forWritingTo: staging)
    do {
      while true {
        try Task.checkCancellation()
        let data = try input.read(upToCount: 1_048_576) ?? Data()
        if data.isEmpty { break }
        try output.write(contentsOf: data)
      }
      try output.synchronize()
      try input.close()
      try output.close()
      guard try fileDigest(staging) == asset.digest.value.lowercased() else {
        throw LocalHistoryExportError.digestMismatch
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: staging.path
      )
      try FileManager.default.moveItem(at: staging, to: destination)
    } catch {
      try? input.close()
      try? output.close()
      throw error
    }
  }

  private func preferredTranscript(
    _ context: LocalHistoryExportContext
  ) -> DictationPersistedTranscriptRecord? {
    TranscriptSelection.current(in: context.transcripts)
  }

  private func fullRawText(_ context: LocalHistoryExportContext) -> String? {
    context.history.textIsPreview
      ? preferredTranscript(context)?.content ?? context.history.rawText
      : context.history.rawText
  }

  private func plainText(_ context: LocalHistoryExportContext) -> String {
    // A long item's history row holds only a preview; its transcripts hold
    // the full text.
    let preferred =
      (context.history.textIsPreview ? preferredTranscript(context)?.content : nil)
      ?? context.history.preferredText
      ?? preferredTranscript(context)?.content
      ?? ""
    return preferred.hasSuffix("\n") ? preferred : preferred + "\n"
  }

  private func markdown(_ context: LocalHistoryExportContext) -> String {
    var lines = [
      "# 织机 记录",
      "",
      "- 时间：\(context.history.createdAt.ISO8601Format())",
      "- 来源：\(context.history.inputMode.rawValue)",
      "- 会话：\(context.history.sessionID.rawValue.uuidString.lowercased())",
      "",
    ]
    if let polished = context.history.polishedText, !polished.isEmpty {
      lines += ["## 最终整理稿", "", polished, ""]
    }
    if let raw = fullRawText(context), !raw.isEmpty {
      let current = preferredTranscript(context)
      lines += [current?.kind == .userEdit ? "## 校对稿" : "## 原始识别", "", raw, ""]
      if let current, current.kind == .userEdit,
        let source = TranscriptSelection.recognitionSource(for: current, in: context.transcripts)
      {
        lines += ["## 原始识别", "", source.content, ""]
      }
    } else if let transcript = preferredTranscript(context) {
      lines += ["## 逐字稿", "", transcript.content, ""]
    }
    if !context.speakers.isEmpty {
      lines += ["## 谁在说话", ""]
      for speaker in context.speakers {
        let name = TranscriptSpeakerSelection.displayTitle(
          displayName: speaker.displayName,
          personID: speaker.personID,
          associationStatus: speaker.associationStatus,
          stableOrdinal: speaker.stableOrdinal
        )
        let seconds = Double(speaker.speechDurationNanoseconds) / 1_000_000_000
        lines.append(
          "- \(name)：\(speaker.occurrenceCount) 段，\(String(format: "%.1f", seconds)) 秒"
        )
      }
      lines.append("")
    }
    for document in context.documents where document.state == .current {
      let title = Self.taskTitle(document.taskID)
      lines += ["## \(title)", "", document.result.outputText, ""]
    }
    if let transcript = preferredTranscript(context), !transcript.segments.isEmpty {
      let base = timelineBase(transcript)
      lines += ["## 带时间戳逐字稿", ""]
      for segment in transcript.segments {
        let speaker = speakerName(for: segment, context: context)
        let time = Self.clockTime(seconds: seconds(segment.monotonicStartNanoseconds, from: base))
        lines.append("- `\(time)` **\(speaker)**：\(segment.text)")
      }
      lines.append("")
    }
    lines += [
      "---",
      "此文件由织机在这台 Mac 上生成；导出未修改历史记录或保留的原始音频。",
      "",
    ]
    return lines.joined(separator: "\n")
  }

  private func captions(
    _ context: LocalHistoryExportContext,
    webVTT: Bool
  ) throws -> String {
    guard let transcript = preferredTranscript(context),
      !transcript.segments.isEmpty
    else { throw LocalHistoryExportError.missingTranscript }
    let base = timelineBase(transcript)
    var blocks: [String] = webVTT ? ["WEBVTT", ""] : []
    for (index, segment) in transcript.segments.enumerated() {
      let start = seconds(segment.monotonicStartNanoseconds, from: base)
      let end = max(start + 0.001, seconds(segment.monotonicEndNanoseconds, from: base))
      let separator = webVTT ? "." : ","
      let timing =
        "\(Self.captionTime(start, separator: separator)) --> \(Self.captionTime(end, separator: separator))"
      let speaker = speakerName(for: segment, context: context)
      let text = context.speakers.isEmpty ? segment.text : "[\(speaker)] \(segment.text)"
      if webVTT {
        blocks.append("\(timing)\n\(text)\n")
      } else {
        blocks.append("\(index + 1)\n\(timing)\n\(text)\n")
      }
    }
    return blocks.joined(separator: "\n") + "\n"
  }

  private struct JSONExport: Codable {
    let schemaVersion: Int
    let sessionID: UUID
    let inputMode: String
    let createdAt: Date
    let updatedAt: Date
    let status: String
    let rawText: String?
    let polishedText: String?
    let transcripts: [DictationPersistedTranscriptRecord]
    let localDocuments: [LocalTextDocumentRecord]
    let speakers: [SessionSpeakerSummary]
    let occurrences: [SpeakerOccurrenceSummary]
  }

  private func structuredJSON(_ context: LocalHistoryExportContext) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(
      JSONExport(
        schemaVersion: 1,
        sessionID: context.history.sessionID.rawValue,
        inputMode: context.history.inputMode.rawValue,
        createdAt: context.history.createdAt,
        updatedAt: context.history.updatedAt,
        status: context.history.status.rawValue,
        rawText: fullRawText(context),
        polishedText: context.history.polishedText,
        transcripts: context.transcripts,
        localDocuments: context.documents,
        speakers: context.speakers,
        occurrences: context.occurrences
      )
    )
  }

  private func timelineBase(
    _ transcript: DictationPersistedTranscriptRecord
  ) -> UInt64 {
    transcript.audioRanges.map(\.monotonicStartNanoseconds).min()
      ?? transcript.segments.map(\.monotonicStartNanoseconds).min()
      ?? 0
  }

  private func speakerName(
    for segment: DictationTranscriptSegment,
    context: LocalHistoryExportContext
  ) -> String {
    guard
      let occurrence = TranscriptSpeakerSelection.occurrence(
        for: segment,
        in: context.occurrences
      )
    else { return "还不知道是谁" }
    return TranscriptSpeakerSelection.displayTitle(
      displayName: occurrence.personDisplayName,
      personID: occurrence.personID,
      associationStatus: occurrence.associationStatus,
      stableOrdinal: occurrence.stableOrdinal
    )
  }

  private func seconds(_ timestamp: UInt64, from base: UInt64) -> Double {
    guard timestamp >= base else { return 0 }
    return Double(timestamp - base) / 1_000_000_000
  }

  private func atomicWrite(_ data: Data, to destination: URL) throws {
    let parent = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent,
      withIntermediateDirectories: true
    )
    let staging = parent.appendingPathComponent(
      ".\(UUID().uuidString).history-exporting"
    )
    defer { try? FileManager.default.removeItem(at: staging) }
    try data.write(to: staging, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: staging.path
    )
    try FileManager.default.moveItem(at: staging, to: destination)
  }

  private func fileDigest(_ url: URL) throws -> String {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    var hasher = SHA256()
    while true {
      let data = try input.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func captionTime(_ seconds: Double, separator: String) -> String {
    let totalMilliseconds = max(0, Int((seconds * 1_000).rounded()))
    let hours = totalMilliseconds / 3_600_000
    let minutes = (totalMilliseconds / 60_000) % 60
    let wholeSeconds = (totalMilliseconds / 1_000) % 60
    let milliseconds = totalMilliseconds % 1_000
    return String(
      format: "%02d:%02d:%02d%@%03d",
      hours,
      minutes,
      wholeSeconds,
      separator,
      milliseconds
    )
  }

  private static func clockTime(seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
  }

  private static func taskTitle(_ taskID: LocalTextTaskID) -> String {
    switch taskID {
    case .structuredSummary: "摘要"
    case .actionItems: "待办"
    case .chapters: "章节"
    case .decisions: "结论与决定"
    default: taskID.rawValue
    }
  }
}
