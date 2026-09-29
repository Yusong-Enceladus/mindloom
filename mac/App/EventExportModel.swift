import AppKit
import BestASRDomain
import BestASRMemory
import BestASRPersistence
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension DictationHistoryItem {
  /// The "来源" label shared with the event projection and export.
  var sourceLabel: String {
    SourceLabel.label(
      inputMode: inputMode, bundleID: sourceApplicationBundleID, displayName: sourceDisplayName)
  }
}

/// A small "来源：<App>" capsule for item rows.
struct SourceChip: View {
  let label: String

  var body: some View {
    Text("来源：\(label)")
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(BestASRPalette.quietFill, in: Capsule())
      .accessibilityLabel("来源：\(label)")
      .accessibilityIdentifier("bestASR.item.source")
  }
}

/// "复制这件事" and "导出为文本…" for one event (PRD §0.3.6), and the read
/// model the upcoming Home/Event/People pages use. Copying writes the general
/// pasteboard only because the user chose this action.
extension DictationAppModel {
  /// Home, Event, and People read model: the organizing device's events
  /// while the link is on and has a projection, otherwise the local fallback
  /// organizer's (with its candidates as questions and recent unorganized
  /// captures and items as Unfiled).
  func loadMemoryProjection(now: Date = Date()) async -> MemoryProjection? {
    await memoryProjectionInputs(now: now)?.projection()
  }

  /// What the memory projection is built from, gathered on the main actor
  /// (the records are read by the store); `projection()` may then run
  /// anywhere.
  struct MemoryProjectionInputs: Sendable {
    let remote: RemoteOrganizerProjection?
    let sources: [MemoryEventSource]
    let records: [MemoryItemRecord]
    let unfiled: [RemoteOrganizerUnfiledItem]
    let localQuestions: [MemoryQuestion]
    let now: Date
    let owners: Set<String>

    func projection() -> MemoryProjection {
      if let remote {
        return MemoryProjection(remote: remote, records: records, now: now, ownerPersonIDs: owners)
      }
      return MemoryProjection(
        events: sources, records: records, unfiled: unfiled, localQuestions: localQuestions,
        now: now, ownerPersonIDs: owners)
    }
  }

  func memoryProjectionInputs(now: Date = Date()) async -> MemoryProjectionInputs? {
    guard let repository else { return nil }
    if memoryUsesRemote, let remote = events.remoteProjection {
      let sources = remote.events.filter { !$0.deleted }.map(MemoryProjection.source)
      let ids = MemoryProjection.sessionIDs(
        sources.flatMap(\.itemIDs) + remote.unfiled.map(\.itemID))
      let records = (try? await repository.memoryItemRecords(ids: ids)) ?? []
      return MemoryProjectionInputs(
        remote: remote, sources: [], records: records, unfiled: [], localQuestions: [],
        now: now, owners: memoryOwnerPersonIDs)
    }
    let summaries = events.summaries.sorted { $0.event.updatedAt > $1.event.updatedAt }
    let sources = summaries.map(Self.localEventSource)
    let unfiled = localUnfiled(now: now)
    let ids = MemoryProjection.sessionIDs(
      sources.flatMap(\.itemIDs) + unfiled.map(\.itemID))
    let records = (try? await repository.memoryItemRecords(ids: ids)) ?? []
    return MemoryProjectionInputs(
      remote: nil, sources: sources, records: records, unfiled: unfiled,
      localQuestions: localMemoryQuestions(), now: now, owners: memoryOwnerPersonIDs)
  }

  /// The Mac's user: the local "self" person of the microphone track.
  var memoryOwnerPersonIDs: Set<String> { [localSelfPersonID.rawValue.uuidString] }

  /// Every record the memory pages may need, whatever 全部 shows: the
  /// unfiltered set the event memory loads (up to 5000), then anything newer
  /// on the current history page. Never the page alone, which is 60 rows
  /// under whatever search and filters 全部 has on.
  var memorySourceItems: [DictationHistoryItem] {
    var seen = Set<SessionID>()
    return (history.eventAvailableHistoryItems + history.historyItems).filter {
      seen.insert($0.sessionID).inserted
    }
  }

  func memoryHistoryItem(_ sessionID: SessionID) -> DictationHistoryItem? {
    history.eventAvailableHistoryItems.first { $0.sessionID == sessionID }
      ?? history.historyItems.first { $0.sessionID == sessionID }
  }

  /// Without the organizing device: pasted items and recordings or imports of
  /// the last 14 days that no local event holds. Dictation stays under 全部.
  func localUnfiled(now: Date) -> [RemoteOrganizerUnfiledItem] {
    let held = Set(events.summaries.flatMap(\.sessionIDs))
    let modes: Set<SessionInputMode> = [.userItem, .roomMicrophone, .systemAudio, .importedMedia]
    let since = now.addingTimeInterval(-14 * 86_400)
    return memorySourceItems.filter {
      modes.contains($0.inputMode) && $0.createdAt >= since && !held.contains($0.sessionID)
        && $0.status == .completed
    }.map { RemoteOrganizerUnfiledItem(itemID: $0.sessionID.rawValue.uuidString, reason: "local") }
  }

  /// The local organizer's pending suggestions as yes/no questions.
  func localMemoryQuestions() -> [MemoryQuestion] {
    events.candidates.compactMap { candidate in
      guard candidate.state == .pending, let eventID = candidate.candidateEventID,
        let title = events.summaries.first(where: { $0.id == eventID })?.event.title
      else { return nil }
      // Names the item, as the organizing device's questions do.
      let item = memoryHistoryItem(candidate.sessionID)
      let text = item?.preferredText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return MemoryQuestion(
        questionID: candidate.id.rawValue.uuidString, kind: .itemIntoEvent,
        prompt: MemoryQuestion.itemPrompt(
          itemText: text.isEmpty ? "一段录音" : text, eventTitle: title),
        a: candidate.sessionID.rawValue.uuidString,
        b: eventID.rawValue.uuidString, createdAt: candidate.createdAt, origin: .local)
    }
  }

  func copyRemoteEventText(_ event: RemoteOrganizerEvent) {
    Task { [weak self] in
      guard let self, let detail = await remoteEventDetail(event) else { return }
      copyEventText(detail)
    }
  }

  func exportRemoteEventText(_ event: RemoteOrganizerEvent) {
    Task { [weak self] in
      guard let self, let detail = await remoteEventDetail(event) else { return }
      saveEventText(detail)
    }
  }

  func copySelectedLocalEventText() {
    guard let summary = selectedEventSummary else { return }
    copyLocalEventText(summary)
  }

  func exportSelectedLocalEventText() {
    guard let summary = selectedEventSummary else { return }
    exportLocalEventText(summary)
  }

  func copyLocalEventText(_ summary: EventSummary) {
    Task { [weak self] in
      guard let self, let detail = await localEventDetail(summary) else { return }
      copyEventText(detail)
    }
  }

  func exportLocalEventText(_ summary: EventSummary) {
    Task { [weak self] in
      guard let self, let detail = await localEventDetail(summary) else { return }
      saveEventText(detail)
    }
  }

  // MARK: - Helpers

  nonisolated static func localEventSource(_ summary: EventSummary) -> MemoryEventSource {
    MemoryProjection.localSource(
      eventID: summary.event.id, title: summary.event.title, notes: summary.event.notes,
      updatedAt: summary.event.updatedAt, sessionIDs: summary.sessionIDs,
      personIDs: summary.personIDs)
  }

  private func remoteEventDetail(_ event: RemoteOrganizerEvent) async -> MemoryEventDetail? {
    guard let repository, let remote = events.remoteProjection else { return nil }
    let ids = MemoryProjection.referencedSessionIDs([MemoryProjection.source(event)])
    guard let records = try? await repository.memoryItemRecords(ids: ids) else {
      intake.show("未能读取这件事的记录；请稍后再试")
      return nil
    }
    return MemoryProjection.sparkEventDetail(event.eventID, projection: remote, records: records)
  }

  private func localEventDetail(_ summary: EventSummary) async -> MemoryEventDetail? {
    guard let repository else { return nil }
    let source = Self.localEventSource(summary)
    guard
      let records = try? await repository.memoryItemRecords(
        ids: MemoryProjection.referencedSessionIDs([source]))
    else {
      intake.show("未能读取这件事的记录；请稍后再试")
      return nil
    }
    return MemoryProjection.localEventDetail(source, records: records)
  }

  private func copyEventText(_ detail: MemoryEventDetail) {
    let text = EventPlainTextFormatter().format(detail)
    intake.show(pasteboardWriter.write(text) ? "已复制这件事的文字" : "复制失败；记录仍保留在本机")
  }

  private func saveEventText(_ detail: MemoryEventDetail) {
    let panel = NSSavePanel()
    // Plain text (PRD §0.3.6): a Markdown viewer would merge its lines.
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = EventPlainTextFormatter.suggestedFilename(for: detail)
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      try Data(EventPlainTextFormatter().format(detail).utf8).write(
        to: destination, options: .atomic)
      intake.show("已导出为文本")
    } catch {
      intake.show("导出失败；记录仍保留在本机")
    }
  }
}
