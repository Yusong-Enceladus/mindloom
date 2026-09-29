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

// Events: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  func closeSystemInterruptionEvents() async {
    guard let repository, !systemInterruptionEvents.isEmpty else { return }
    let resumedAt = DispatchTime.now().uptimeNanoseconds
    let pending = systemInterruptionEvents
    systemInterruptionEvents.removeAll()
    for (sessionID, interruption) in pending {
      let duration =
        resumedAt >= interruption.startedAt
        ? resumedAt - interruption.startedAt
        : nil
      try? await repository.save(
        timelineEvent: TimelineEvent(
          id: interruption.id,
          sessionID: sessionID,
          revision: interruption.revision,
          kind: .gap,
          monotonicNanoseconds: interruption.startedAt,
          durationNanoseconds: duration
        )
      )
    }
  }

  func refreshEvents() {
    if fixtureMode, eventReviewUIFixture != nil {
      history.eventAvailableHistoryItems = history.historyItems
      events.eventStatusMessage = Self.eventStatus(
        eventCount: events.summaries.count,
        candidateCount: events.candidates.count
      )
      return
    }
    eventMemoryWanted = true
    Task { [weak self] in
      await self?.refreshEventMemory(organize: true)
    }
  }

  func beginEditingEvent(_ summary: EventSummary) {
    events.selectedEventID = summary.id
    events.titleDraft = summary.event.title
    events.notesDraft = summary.event.notes
    events.sessionSelection = []
    events.mergeTargetEventID = nil
    events.moveTargetEventID = nil
    events.addSessionID = nil
    events.textDocuments = []
    events.documentTextDrafts = [:]
    history.selectedEventHistoryItems = eventTimelineItems(
      sessionIDs: summary.sessionIDs
    )
    Task { [weak self] in
      guard let self, let repository else { return }
      async let loadedDetail = repository.eventDetail(id: summary.id)
      async let loadedDocuments = repository.eventTextDocuments(eventID: summary.id)
      guard let detail = try? await loadedDetail else { return }
      guard events.selectedEventID == summary.id else { return }
      history.selectedEventHistoryItems = eventTimelineItems(
        sessionIDs: detail.summary.sessionIDs
      )
      events.textDocuments = (try? await loadedDocuments) ?? []
      events.documentTextDrafts = Dictionary(
        uniqueKeysWithValues: events.textDocuments.map {
          ($0.id, $0.result.outputText)
        }
      )
    }
  }

  func eventTimelineItems(
    sessionIDs: [SessionID]
  ) -> [DictationHistoryItem] {
    let included = Set(sessionIDs)
    return history.eventAvailableHistoryItems.filter {
      included.contains($0.sessionID)
    }.sorted { left, right in
      if left.createdAt == right.createdAt {
        return left.sessionID.rawValue.uuidString
          < right.sessionID.rawValue.uuidString
      }
      return left.createdAt < right.createdAt
    }
  }

  func beginNewEvent() {
    events.selectedEventID = nil
    history.selectedEventHistoryItems = []
    events.titleDraft = ""
    events.notesDraft = ""
    events.newEventTitleDraft = ""
    events.sessionSelection = []
    events.mergeTargetEventID = nil
    events.moveTargetEventID = nil
    events.addSessionID = nil
    events.textDocuments = []
    events.documentTextDrafts = [:]
    events.eventStatusMessage = "选择零条或多条未归类记录，然后建立事件"
  }

  func openEventPerson(_ personID: PersonID) {
    guard let summary = people.personSummaries.first(where: { $0.id == personID }) else {
      events.eventStatusMessage = "人物资料当前未加载；请刷新人物后重试"
      return
    }
    beginEditingPerson(summary)
    requestedNavigationSectionID = "people"
  }

  func toggleEventSessionSelection(_ sessionID: SessionID) {
    if events.sessionSelection.contains(sessionID) {
      events.sessionSelection.remove(sessionID)
    } else {
      events.sessionSelection.insert(sessionID)
    }
  }

  func createEventFromSelection() {
    guard let repository else { return }
    let title = events.newEventTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      events.eventStatusMessage = "请先输入事件名称"
      return
    }
    events.eventStatusMessage = "正在建立本地事件…"
    let sessionIDs = Array(events.sessionSelection)
    Task { [weak self] in
      guard let self else { return }
      do {
        let created = try await repository.createEvent(
          title: title,
          notes: "",
          sessionIDs: sessionIDs
        )
        events.newEventTitleDraft = ""
        events.sessionSelection = []
        events.selectedEventID = created.id
        // Keep the just-created user operation at the top of the undo stack.
        // Automatic organization runs on the next explicit/history refresh.
        await refreshEventMemory(organize: false)
        if let summary = events.summaries.first(where: { $0.id == created.id }) {
          beginEditingEvent(summary)
        }
        events.eventStatusMessage = "事件已建立；原音、逐字稿和人物证据保持独立可追溯"
      } catch {
        events.eventStatusMessage = "事件未能建立；现有记录没有变化"
      }
    }
  }

  func saveEventDraft() {
    guard let repository, let selectedEventID = events.selectedEventID else { return }
    let title = events.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      events.eventStatusMessage = "事件名称不能为空"
      return
    }
    events.eventStatusMessage = "正在保存事件…"
    Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await repository.updateEvent(
          id: selectedEventID,
          title: title,
          notes: events.notesDraft
        )
        await refreshEventMemory(organize: false)
        events.eventStatusMessage = "事件名称和备注已保存在本机"
      } catch {
        events.eventStatusMessage = "事件未能保存；原内容没有变化"
      }
    }
  }

  func mergeSelectedEvent() {
    guard let repository, let primaryID = events.selectedEventID,
      let mergedID = events.mergeTargetEventID, primaryID != mergedID
    else { return }
    events.eventStatusMessage = "正在合并事件关系…"
    Task { [weak self] in
      guard let self else { return }
      do {
        try await repository.mergeEvents(primaryID: primaryID, mergedID: mergedID)
        events.mergeTargetEventID = nil
        await refreshEventMemory(organize: false)
        events.eventStatusMessage = "事件已合并；可以撤销，任何原音和逐字稿都没有被改写"
      } catch {
        events.eventStatusMessage = "事件合并失败；现有关系没有变化"
      }
    }
  }

  func splitSelectedEventSessions() {
    guard let repository, let selectedEventID = events.selectedEventID,
      !events.sessionSelection.isEmpty
    else {
      events.eventStatusMessage = "请先选择要拆出的记录"
      return
    }
    let title = events.newEventTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      events.eventStatusMessage = "请为拆分后的事件输入名称"
      return
    }
    events.eventStatusMessage = "正在拆分事件…"
    Task { [weak self] in
      guard let self else { return }
      do {
        let created = try await repository.splitEvent(
          sourceID: selectedEventID,
          sessionIDs: Array(events.sessionSelection),
          newTitle: title
        )
        events.sessionSelection = []
        events.newEventTitleDraft = ""
        self.events.selectedEventID = created.id
        await refreshEventMemory(organize: false)
        if let summary = events.summaries.first(where: { $0.id == created.id }) {
          beginEditingEvent(summary)
        }
        events.eventStatusMessage = "所选记录已拆成新事件；可以撤销"
      } catch {
        events.eventStatusMessage = "事件拆分失败；现有关系没有变化"
      }
    }
  }

  func moveSelectedEventSessions() {
    guard let repository, let sourceID = events.selectedEventID,
      let targetID = events.moveTargetEventID,
      !events.sessionSelection.isEmpty
    else {
      events.eventStatusMessage = "请选择记录和目标事件"
      return
    }
    events.eventStatusMessage = "正在移动事件记录…"
    Task { [weak self] in
      guard let self else { return }
      do {
        try await repository.moveSessions(
          Array(events.sessionSelection),
          from: sourceID,
          to: targetID,
          evidence: .manual()
        )
        events.sessionSelection = []
        events.moveTargetEventID = nil
        await refreshEventMemory(organize: false)
        events.eventStatusMessage = "记录已移动到目标事件；可以撤销"
      } catch {
        events.eventStatusMessage = "记录移动失败；现有关系没有变化"
      }
    }
  }

  func removeSelectedSessionsFromEvent() {
    guard let repository, let selectedEventID = events.selectedEventID,
      !events.sessionSelection.isEmpty
    else { return }
    events.eventStatusMessage = "正在从事件中移除所选关系…"
    Task { [weak self] in
      guard let self else { return }
      do {
        try await repository.removeSessions(
          Array(events.sessionSelection),
          from: selectedEventID
        )
        events.sessionSelection = []
        await refreshEventMemory(organize: false)
        events.eventStatusMessage = "关系已移除；记录和原音仍在历史中，可以撤销"
      } catch {
        events.eventStatusMessage = "关系未能移除；现有内容没有变化"
      }
    }
  }

  func retireSelectedEvent() {
    guard let repository, let selectedEventID = events.selectedEventID else { return }
    Task { [weak self] in
      guard let self else { return }
      do {
        try await repository.retireEvent(id: selectedEventID)
        self.events.selectedEventID = nil
        history.selectedEventHistoryItems = []
        events.textDocuments = []
        events.documentTextDrafts = [:]
        await refreshEventMemory(organize: false)
        events.eventStatusMessage = "事件已删除；其中的记录、人物、原音和逐字稿全部保留"
      } catch {
        events.eventStatusMessage = "事件未能删除；现有内容没有变化"
      }
    }
  }

  func undoLastEventEdit() {
    if fixtureMode, eventReviewUIFixture != nil {
      guard let previous = eventReviewUIFixtureUndoStack.popLast() else {
        events.eventStatusMessage = "没有可撤销的事件修改"
        return
      }
      events.summaries = previous.summaries
      events.candidates = previous.candidates
      events.selectedEventID = previous.selectedEventID
      if let selectedEventID = events.selectedEventID,
        let selected = events.summaries.first(where: { $0.id == selectedEventID })
      {
        beginEditingEvent(selected)
      } else {
        history.selectedEventHistoryItems = []
      }
      events.eventStatusMessage = "最近一次事件修改已撤销"
      return
    }
    guard let repository else { return }
    events.eventStatusMessage = "正在撤销最近一次事件修改…"
    Task { [weak self] in
      guard let self else { return }
      do {
        let changed = try await repository.undoLastEventEdit()
        await refreshEventMemory(organize: false)
        events.eventStatusMessage = changed ? "最近一次事件修改已撤销" : "没有可撤销的事件修改"
      } catch {
        events.eventStatusMessage = "撤销失败；现有内容没有变化"
      }
    }
  }

  func acceptEventCandidate(_ candidate: EventCandidate) {
    if fixtureMode, let fixture = eventReviewUIFixture,
      candidate.id == fixture.candidate.id,
      events.candidates.contains(where: { $0.id == candidate.id })
    {
      saveEventReviewUIFixtureUndoState()
      events.candidates.removeAll { $0.id == candidate.id }
      events.summaries = events.summaries.map {
        $0.id == fixture.acceptedSummary.id ? fixture.acceptedSummary : $0
      }
      events.selectedEventID = fixture.acceptedSummary.id
      events.activeEventReviewCandidateID = nil
      beginEditingEvent(fixture.acceptedSummary)
      events.eventStatusMessage = "事件线索已确认；时间线已更新，可以撤销"
      history.detailStatusMessage = "已确认归入事件；原音和逐字稿没有改变"
      return
    }
    guard let repository else { return }
    events.eventStatusMessage = "正在确认事件建议…"
    Task { [weak self] in
      guard let self else { return }
      do {
        events.selectedEventID = try await repository.acceptEventCandidate(id: candidate.id)
        if events.activeEventReviewCandidateID == candidate.id {
          events.activeEventReviewCandidateID = nil
          history.detailStatusMessage = "已确认归入事件；原音和逐字稿没有改变"
        }
        await refreshEventMemory(organize: false)
        events.eventStatusMessage = "事件线索已确认；时间线已更新，可以撤销"
      } catch {
        events.eventStatusMessage = "事件建议未能确认；现有内容没有变化"
      }
    }
  }

  func dismissEventCandidate(_ candidate: EventCandidate) {
    if fixtureMode, eventReviewUIFixture != nil,
      events.candidates.contains(where: { $0.id == candidate.id })
    {
      saveEventReviewUIFixtureUndoState()
      events.candidates.removeAll { $0.id == candidate.id }
      events.activeEventReviewCandidateID = nil
      events.eventStatusMessage = "已忽略这条事件线索；可以撤销"
      history.detailStatusMessage = "已忽略这条事件线索；原始记录没有改变"
      return
    }
    guard let repository else { return }
    Task { [weak self] in
      guard let self else { return }
      do {
        try await repository.dismissEventCandidate(id: candidate.id)
        if events.activeEventReviewCandidateID == candidate.id {
          events.activeEventReviewCandidateID = nil
          history.detailStatusMessage = "已忽略这条事件线索；原始记录没有改变"
        }
        await refreshEventMemory(organize: false)
        events.eventStatusMessage = "已忽略这条事件线索；可以撤销"
      } catch {
        events.eventStatusMessage = "未能忽略这条建议"
      }
    }
  }

  func saveEventReviewUIFixtureUndoState() {
    eventReviewUIFixtureUndoStack.append(
      EventReviewUIFixtureState(
        summaries: events.summaries,
        candidates: events.candidates,
        selectedEventID: events.selectedEventID
      )
    )
  }

  func eventCandidateDestinationTitle(_ candidate: EventCandidate) -> String {
    guard let id = candidate.candidateEventID else { return candidate.proposedTitle }
    return events.summaries.first(where: { $0.id == id })?.event.title
      ?? candidate.proposedTitle
  }

  func openEventCandidateSource(_ candidate: EventCandidate) {
    guard
      let item = history.eventAvailableHistoryItems.first(where: {
        $0.sessionID == candidate.sessionID
      })
    else {
      events.eventStatusMessage = "这条建议的来源记录当前不可用；请刷新后重试"
      return
    }
    beginHistoryNavigation(
      item,
      returningTo: HistoryNavigationOrigin(
        kind: .event,
        title: eventCandidateDestinationTitle(candidate)
      )
    )
    events.activeEventReviewCandidateID = candidate.id
    Task { [weak self] in
      guard let self else { return }
      await refreshSelectedSpeakerDetails(sessionID: item.sessionID)
      guard history.selectedHistorySessionID == item.sessionID,
        events.activeEventReviewCandidateID == candidate.id
      else { return }
      if let firstTrack = playback.playbackTrackIDs.first {
        selectHistoryPlaybackTrack(firstTrack)
      }
      let segments = selectedHistoryTimestampedTranscript?.segments ?? []
      if let segment = Self.eventCandidateEvidenceSegment(
        proposedTitle: candidate.proposedTitle,
        segments: segments
      ) {
        playHistoryTranscriptSegment(segment)
        history.detailStatusMessage =
          "正在播放这条事件线索最相关的原音片段；请听过后再确认"
      } else if !playback.playbackTrackIDs.isEmpty {
        seekHistoryPlayback(to: 0)
        if !playback.playbackIsPlaying { toggleHistoryPlayback() }
        history.detailStatusMessage = "正在从来源原音开头播放；这条旧记录没有分段逐字稿"
      } else {
        history.detailStatusMessage = "已打开事件线索的来源记录；当前没有可播放的原音索引"
      }
    }
  }

  nonisolated static func eventCandidateEvidenceSegment(
    proposedTitle: String,
    segments: [DictationTranscriptSegment]
  ) -> DictationTranscriptSegment? {
    guard !segments.isEmpty else { return nil }
    let normalizedTitle = proposedTitle.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !normalizedTitle.isEmpty else { return segments.first }
    let queryTokens = eventEvidenceTokens(normalizedTitle)
    var best: (segment: DictationTranscriptSegment, score: Double, index: Int)?
    for (index, segment) in segments.enumerated() {
      let directMatch = segment.text.localizedCaseInsensitiveContains(
        normalizedTitle
      )
      let segmentTokens = eventEvidenceTokens(segment.text)
      let overlap = queryTokens.intersection(segmentTokens).count
      let lexical =
        queryTokens.isEmpty
        ? 0 : Double(overlap) / Double(queryTokens.count)
      let score = (directMatch ? 2 : 0) + lexical
      if best == nil || score > best!.score
        || (score == best!.score && index < best!.index)
      {
        best = (segment, score, index)
      }
    }
    guard let best else { return segments.first }
    return best.score > 0 ? best.segment : segments.first
  }

  func generateEventDocument(_ taskID: LocalTextTaskID) {
    guard let selectedEventID = events.selectedEventID, events.generatingEventDocumentTaskID == nil else { return }
    guard polishRuntimeReady, let localRuntime, let repository else {
      events.eventStatusMessage = "请先安装并校验本地文字整理组件"
      return
    }
    events.generatingEventDocumentTaskID = taskID
    events.eventStatusMessage = "正在这台 Mac 上整理整个事件的\(Self.localTextTaskTitle(taskID))…"
    Task { [weak self] in
      guard let self else { return }
      defer { events.generatingEventDocumentTaskID = nil }
      do {
        _ = try await localRuntime.generateEventTextDocument(
          eventID: selectedEventID,
          taskID: taskID
        )
        let loadedDocuments = try await repository.eventTextDocuments(
          eventID: selectedEventID
        )
        guard self.events.selectedEventID == selectedEventID else { return }
        events.textDocuments = loadedDocuments
        events.documentTextDrafts = Dictionary(
          uniqueKeysWithValues: events.textDocuments.map {
            ($0.id, $0.result.outputText)
          }
        )
        events.eventStatusMessage = "事件整理已保存；每条内容都保留到来源记录和时间戳的引用"
      } catch {
        if self.events.selectedEventID == selectedEventID {
          events.eventStatusMessage = "事件整理未完成；所有原始记录和已有结果保持不变"
        }
      }
    }
  }

  func saveEventDocumentEdit(_ document: EventTextDocumentRecord) {
    guard document.state == .current, let repository,
      events.generatingEventDocumentTaskID == nil,
      events.selectedEventID == document.eventID
    else { return }
    let text = events.documentTextDrafts[
      document.id,
      default: document.result.outputText
    ].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      events.eventStatusMessage = "事件整理结果不能为空"
      return
    }
    let sourceIDs = Array(
      Set(document.sourceReferences.flatMap(\.segmentIDs))
    ).sorted { $0.uuidString < $1.uuidString }
    let editedModelID = "bestasr-user-edit-v1"
    let result = LocalTextResult(
      contractVersion: document.result.contractVersion,
      modelArtifactID: editedModelID,
      taskID: document.taskID,
      outputText: text,
      claims: [
        LocalTextClaim(
          claimID: UUID(),
          text: text,
          sourceSegmentIDs: sourceIDs,
          confidence: nil,
          disposition: .cautious
        )
      ],
      structuredItems: document.result.structuredItems
    )
    events.generatingEventDocumentTaskID = document.taskID
    events.eventStatusMessage = "正在把编辑保存为新版本…"
    Task { [weak self] in
      guard let self else { return }
      defer { events.generatingEventDocumentTaskID = nil }
      do {
        let encoded = try JSONEncoder().encode(result)
        let hash = SHA256.hash(data: encoded).map {
          String(format: "%02x", $0)
        }.joined()
        let edited = EventTextDocumentRecord(
          id: UUID(),
          eventID: document.eventID,
          eventRevision: document.eventRevision,
          taskID: document.taskID,
          modelArtifactID: editedModelID,
          configHash: try SHA256Digest(hash),
          sourceReferences: document.sourceReferences,
          result: result,
          createdAt: Date()
        )
        try await repository.saveEventTextDocument(edited)
        let loadedDocuments = try await repository.eventTextDocuments(
          eventID: document.eventID
        )
        guard events.selectedEventID == document.eventID else { return }
        events.textDocuments = loadedDocuments
        events.documentTextDrafts = Dictionary(
          uniqueKeysWithValues: events.textDocuments.map {
            ($0.id, $0.result.outputText)
          }
        )
        events.eventStatusMessage = "编辑已另存为新版本；来源记录和旧整理结果均未覆盖"
      } catch {
        if events.selectedEventID == document.eventID {
          events.eventStatusMessage = "事件编辑未保存；现有结果没有变化"
        }
      }
    }
  }

  func openEventDocumentSource(
    _ document: EventTextDocumentRecord,
    segmentIDs: [UUID]
  ) {
    let requestedIDs = Set(segmentIDs)
    guard
      let reference = document.sourceReferences.first(where: {
        !requestedIDs.isDisjoint(with: Set($0.segmentIDs))
      }),
      let item = history.eventAvailableHistoryItems.first(where: {
        $0.sessionID == reference.sessionID
      })
    else {
      events.eventStatusMessage = "这条整理结果的来源记录当前不可用"
      return
    }
    beginHistoryNavigation(
      item,
      returningTo: HistoryNavigationOrigin(
        kind: .event,
        title: selectedEventSummary?.event.title ?? "当前事件"
      )
    )
    Task { [weak self] in
      guard let self else { return }
      await refreshSelectedSpeakerDetails(sessionID: item.sessionID)
      if let segment = history.selectedHistoryTranscripts.reversed()
        .flatMap(\.segments)
        .first(where: { requestedIDs.contains($0.id) })
      {
        locateHistoryTranscriptSegment(segment)
      } else {
        playback.playbackPosition = 0
        history.detailStatusMessage = "已打开来源记录；这条旧记录没有分段时间戳"
      }
    }
  }

  func refreshEventMemory(organize: Bool) async {
    guard let repository, !self.events.organizationInProgress else { return }
    self.events.organizationInProgress = true
    defer { self.events.organizationInProgress = false }
    do {
      let allEvents = try await repository.eventSummaries()
      if organize {
        let sessions = try await repository.eventOrganizationSessions()
        let result = await localEventOrganizer.organize(
          sessions: sessions,
          events: allEvents
        )
        for link in result.automaticLinks {
          try await repository.linkSessions(
            [link.sessionID],
            to: link.eventID,
            source: .automatic,
            evidence: link.evidence
          )
        }
        try await repository.replacePendingEventCandidates(result.candidates)
      }
      // Keep the complete relationship graph in memory even while the event
      // search field is active. Filtering the source array itself made records
      // in nonmatching events look unassigned and allowed accidental regrouping.
      async let loadedEvents = repository.eventSummaries()
      async let loadedCandidates = repository.eventCandidates()
      async let allHistory = repository.loadHistory(limit: 5_000)
      let (events, candidates, history) = try await (
        loadedEvents,
        loadedCandidates,
        allHistory
      )
      let normalizedSearch = self.history.eventSearchQuery.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      if normalizedSearch.isEmpty {
        self.history.eventSearchResultIDs = nil
      } else {
        let matchingEvents = try await repository.eventSummaries(
          query: normalizedSearch
        )
        self.history.eventSearchResultIDs = Set(matchingEvents.map(\.id))
      }
      self.events.summaries = events
      self.events.candidates = candidates
      self.history.eventAvailableHistoryItems = history
      if let selectedEventID = self.events.selectedEventID,
        let selected = events.first(where: { $0.id == selectedEventID })
      {
        self.events.titleDraft = selected.event.title
        self.events.notesDraft = selected.event.notes
        self.history.selectedEventHistoryItems = eventTimelineItems(
          sessionIDs: selected.sessionIDs
        )
        self.events.textDocuments = try await repository.eventTextDocuments(
          eventID: selectedEventID
        )
        self.events.documentTextDrafts = Dictionary(
          uniqueKeysWithValues: self.events.textDocuments.map {
            ($0.id, $0.result.outputText)
          }
        )
      } else if self.events.selectedEventID != nil {
        self.events.selectedEventID = nil
        self.history.selectedEventHistoryItems = []
        self.events.textDocuments = []
        self.events.documentTextDrafts = [:]
      }
      self.events.eventStatusMessage = Self.eventStatus(
        eventCount: events.count,
        candidateCount: candidates.count
      )
    } catch {
      self.events.eventStatusMessage = "无法整理本地事件；历史记录和原音没有变化"
    }
  }

  func applyLiveTranscriptEvent(
    _ event: LocalLiveTranscriptEvent
  ) {
    let status: String
    switch event.state {
    case .text(let kind):
      status =
        kind == .sentence
        ? "句子已在本机确认"
        : "本地实时草稿——文字还会继续更新"
    case .unavailable:
      status = "音频仍已保存；实时转写将在本机重试"
    }
    if event.sessionID == snapshot.sessionID {
      if case .text = event.state { liveTranscriptText = event.text }
      liveTranscriptStatus = status
      renderRecordingPanel()
    } else if event.sessionID == capture.roomSnapshot.sessionID {
      if case .text = event.state { capture.roomLiveTranscriptText = event.text }
      capture.roomLiveTranscriptStatus = status
    } else if event.sessionID == capture.systemAudioSnapshot.sessionID {
      if case .text = event.state { capture.systemAudioLiveTranscriptText = event.text }
      capture.systemAudioLiveTranscriptStatus = status
    }
  }

  static func makeEventReviewUIFixture(
    playbackFixture: HistoryPlaybackUIFixture,
    historyItems: [DictationHistoryItem]
  ) throws -> EventReviewUIFixture {
    guard
      let candidateItem = historyItems.first(where: {
        $0.sessionID == playbackFixture.sessionID
      }),
      let existingItem = historyItems.first(where: {
        $0.sessionID != playbackFixture.sessionID
          && $0.status == .recovered
      })
    else { throw BestASRPersistenceError.missingSession }
    let eventID = EventID(
      UUID(uuidString: "48000000-0000-4000-8000-000000000001")!
    )
    let candidate = EventCandidate(
      id: EventCandidateID(
        UUID(uuidString: "49000000-0000-4000-8000-000000000001")!
      ),
      sessionID: candidateItem.sessionID,
      candidateEventID: eventID,
      proposedTitle: "播放进度与交互复盘",
      evidence: EventLinkEvidence(
        semanticScore: 0.86,
        temporalScore: 0.65,
        peopleScore: 0.5,
        sourceScore: 0.4,
        aggregateScore: 0.76,
        modelIdentifier: "bestasr-event-review-ui-fixture-v1",
        evaluatedAt: candidateItem.updatedAt
      ),
      createdAt: candidateItem.updatedAt,
      updatedAt: candidateItem.updatedAt
    )
    let people = playbackFixture.people.filter {
      $0.person.displayName != nil
    }
    let personIDs = people.map(\.id)
    let personNames = people.compactMap(\.person.displayName)
    let initialEvent = MemoryEvent(
      id: eventID,
      revision: try Revision(1),
      title: candidate.proposedTitle,
      notes: "跨记录保留原音、逐字稿和进展线索",
      startAt: existingItem.createdAt,
      endAt: existingItem.updatedAt,
      titleIsUserEdited: true,
      confirmationState: .userConfirmed,
      createdAt: existingItem.createdAt,
      updatedAt: existingItem.updatedAt
    )
    let acceptedEvent = MemoryEvent(
      id: eventID,
      revision: try Revision(2),
      title: initialEvent.title,
      notes: initialEvent.notes,
      startAt: min(existingItem.createdAt, candidateItem.createdAt),
      endAt: max(existingItem.updatedAt, candidateItem.updatedAt),
      titleIsUserEdited: true,
      confirmationState: .userConfirmed,
      createdAt: initialEvent.createdAt,
      updatedAt: candidateItem.updatedAt
    )
    return EventReviewUIFixture(
      candidate: candidate,
      initialSummary: EventSummary(
        event: initialEvent,
        sessionIDs: [existingItem.sessionID],
        personIDs: Array(personIDs.prefix(1)),
        personDisplayNames: Array(personNames.prefix(1)),
        inputModes: [SessionInputMode.dictation.rawValue],
        pendingCandidateCount: 1
      ),
      acceptedSummary: EventSummary(
        event: acceptedEvent,
        sessionIDs: [existingItem.sessionID, candidateItem.sessionID],
        personIDs: personIDs,
        personDisplayNames: personNames,
        inputModes: [
          SessionInputMode.dictation.rawValue,
          SessionInputMode.roomMicrophone.rawValue,
        ],
        pendingCandidateCount: 0
      )
    )
  }
}
