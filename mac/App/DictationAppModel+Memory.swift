import AppKit
import BestASRDomain
import BestASRMemory
import BestASRMemoryUI
import BestASRPersistence
import Foundation

/// Corrections from the memory pages. Each one happens in place: while the
/// organizing device's projection is shown it is recorded as a decision (the
/// local overlay applies it at once); otherwise it goes to the local
/// organizer's events and people.
extension DictationAppModel {
  /// True while Home shows the organizing device's events.
  var memoryUsesRemote: Bool { remoteOrganizerEnabled && events.remoteProjection != nil }

  func memoryAnswer(_ question: MemoryQuestion, yes: Bool) {
    switch question.origin {
    case .spark:
      guard
        let asked = events.remoteProjection?.questions.first(where: {
          $0.questionID == question.questionID
        })
      else { return }
      answerRemoteQuestion(asked, yes: yes)
    case .local:
      guard
        let candidate = events.candidates.first(where: {
          $0.id.rawValue.uuidString == question.questionID
        })
      else { return }
      if yes { acceptEventCandidate(candidate) } else { dismissEventCandidate(candidate) }
    }
  }

  func memoryAnswerReview(_ review: MemoryPersonReview, yes: Bool) {
    switch review.origin {
    case .question(let question):
      memoryAnswer(question, yes: yes)
    case .voiceMatch(let speakerID):
      guard
        let candidate = people.personReviewCandidates.first(where: {
          $0.speakerID.rawValue.uuidString == speakerID
        })
      else { return }
      // The speaker actions work on the selected record.
      history.selectedHistorySessionID = candidate.sessionID
      if yes {
        confirmSpeakerCandidate(candidate.speaker)
      } else {
        rejectSpeakerPersonMatch(candidate.speaker)
      }
    }
  }

  func memoryPin(_ eventID: String, pinned: Bool) {
    guard memoryUsesRemote else { return }
    recordRemoteDecision(MemoryDecisions.pin(eventID: eventID, pinned: pinned))
  }

  func memoryFeatureLess(_ eventID: String) {
    guard memoryUsesRemote else { return }
    recordRemoteDecision(MemoryDecisions.featureLess(eventID: eventID))
  }

  func memoryRenameEvent(_ eventID: String, title: String) {
    if memoryUsesRemote {
      recordRemoteDecision(MemoryDecisions.rename(eventID: eventID, title: title))
      return
    }
    guard let repository, let id = localEventID(eventID),
      let summary = events.summaries.first(where: { $0.id == id })
    else { return }
    Task { [weak self] in
      do {
        _ = try await repository.updateEvent(id: id, title: title, notes: summary.event.notes)
        await self?.refreshEventMemory(organize: false)
      } catch {
        self?.intake.show("标题没有改成；原来的还在")
      }
    }
  }

  /// Where a rename goes. A voice this Mac knows is renamed here; while
  /// Home shows the organizing device's people it is also recorded as a
  /// decision, because the page shows the device's name for that person and
  /// the overlay applies the decision at once (the device marks the name as
  /// the user's). Waiting for the recordings to be re-sent would leave the
  /// old name on screen until a later pull, or indefinitely with the link off.
  nonisolated static func memoryRenameRoutes(knownLocally: Bool, usesRemote: Bool)
    -> (local: Bool, decision: Bool)
  {
    (knownLocally, usesRemote)
  }

  func memoryNamePerson(_ personID: String, name: String) {
    let summary = UUID(uuidString: personID).flatMap { uuid in
      people.personSummaries.first(where: { $0.person.id == PersonID(uuid) })
    }
    let routes = Self.memoryRenameRoutes(
      knownLocally: summary != nil && repository != nil, usesRemote: memoryUsesRemote)
    if routes.decision {
      recordRemoteDecision(MemoryDecisions.name(personID: personID, name: name))
    }
    if routes.local, let summary, let repository {
      Task { [weak self] in
        do {
          _ = try await repository.renamePerson(
            personID: summary.person.id, displayName: name, aliases: summary.person.aliases,
            originDeviceID: Self.localOriginDeviceID())
          await self?.refreshPeopleNow()
          await self?.refreshHistoryItems(preserveStatus: true, organizeEvents: false)
        } catch {
          self?.intake.show("名字没有改成；原来的还在")
        }
      }
    }
  }

  /// `segID`: the row showed one part of the record (only the organizing
  /// device splits records, so a local event never has one).
  func memoryRemoveItem(eventID: String, itemID: String, segID: String? = nil) {
    if memoryUsesRemote {
      recordRemoteDecision(MemoryDecisions.remove(itemID: itemID, from: eventID, segID: segID))
      return
    }
    guard let repository, let event = localEventID(eventID), let session = sessionID(itemID)
    else { return }
    Task { [weak self] in
      do {
        try await repository.removeSessions([session], from: event)
        await self?.refreshEventMemory(organize: false)
      } catch {
        self?.intake.show("没有移出；这件事没有变化")
      }
    }
  }

  /// `fromEventID` is the event page the user moved it from (nil from
  /// Unfiled): a record may sit in several local events, and only that one
  /// gives it up.
  func memoryMoveItem(
    itemID: String, toEventID: String, fromEventID: String?, segID: String? = nil
  ) {
    if memoryUsesRemote {
      recordRemoteDecision(MemoryDecisions.move(itemID: itemID, to: toEventID, segID: segID))
      return
    }
    guard let repository, let target = localEventID(toEventID), let session = sessionID(itemID)
    else { return }
    let source = Self.memoryLocalMoveSource(
      from: fromEventID.flatMap(localEventID), session: session, summaries: events.summaries)
    if source == target { return }
    Task { [weak self] in
      do {
        if let source, source != target {
          try await repository.moveSessions(
            [session], from: source, to: target, evidence: .manual())
        } else if source == nil {
          try await repository.linkSessions(
            [session], to: target, source: .manual, evidence: .manual())
        }
        await self?.refreshEventMemory(organize: false)
      } catch {
        self?.intake.show("没有移过去；原来的位置没有变化")
      }
    }
  }

  func memoryFileItemNewEvent(itemID: String) {
    if memoryUsesRemote {
      // One ID for the local overlay and the organizing device.
      recordRemoteDecision(MemoryDecisions.fileAsNewEvent(itemID: itemID))
      return
    }
    guard let repository, let session = sessionID(itemID) else { return }
    let holders = events.summaries.filter { $0.sessionIDs.contains(session) }.map(\.id)
    let title = memoryTitle(for: session)
    Task { [weak self] in
      do {
        for holder in holders { try await repository.removeSessions([session], from: holder) }
        _ = try await repository.createEvent(title: title, notes: "", sessionIDs: [session])
        await self?.refreshEventMemory(organize: false)
      } catch {
        self?.intake.show("没有单独成一件事；原来的位置没有变化")
      }
    }
  }

  func memoryCopyText(_ eventID: String) {
    if memoryUsesRemote,
      let event = events.remoteProjection?.events.first(where: { $0.eventID == eventID })
    {
      copyRemoteEventText(event)
    } else if let id = localEventID(eventID),
      let summary = events.summaries.first(where: { $0.id == id })
    {
      copyLocalEventText(summary)
    }
  }

  func memoryExportText(_ eventID: String) {
    if memoryUsesRemote,
      let event = events.remoteProjection?.events.first(where: { $0.eventID == eventID })
    {
      exportRemoteEventText(event)
    } else if let id = localEventID(eventID),
      let summary = events.summaries.first(where: { $0.id == id })
    {
      exportLocalEventText(summary)
    }
  }

  func memoryPlay(itemID: String) {
    guard let session = sessionID(itemID) else { return }
    guard let item = memoryHistoryItem(session) else {
      intake.show("这段录音暂时打不开")
      return
    }
    playback.stopAt = nil
    playHistoryItem(item)
  }

  /// Plays one stretch of a recording (monotonic nanoseconds) and stops at
  /// its end: the voice a yes/no question asks about.
  func memoryPlayRange(itemID: String, start: UInt64, end: UInt64) {
    guard let session = sessionID(itemID), let item = memoryHistoryItem(session) else {
      intake.show("这段录音暂时打不开")
      return
    }
    let begin: @MainActor (DictationAppModel) -> Void = { model in
      guard model.history.selectedHistorySessionID == session,
        !model.playback.playbackTrackIDs.isEmpty,
        let from = model.historyPlaybackPosition(forMonotonicNanoseconds: start)
      else {
        model.intake.show("这段声音暂时找不到")
        return
      }
      let to =
        model.historyPlaybackPosition(forMonotonicNanoseconds: end)
        ?? from + Double(end &- start) / 1_000_000_000
      model.seekHistoryPlayback(to: from)
      model.playback.stopAt = PlaybackModel.StopPoint(sessionID: session, position: max(to, from))
      if !model.playback.playbackIsPlaying { model.toggleHistoryPlayback() }
    }
    if history.selectedHistorySessionID == session, !playback.playbackTrackIDs.isEmpty {
      begin(self)
      return
    }
    playback.stopAt = nil
    beginHistoryNavigation(item, returningTo: nil, presentingDetail: false)
    Task { [weak self] in
      guard let self else { return }
      await refreshSelectedSpeakerDetails(sessionID: session)
      begin(self)
    }
  }

  func memoryStop() {
    if playback.playbackIsPlaying { toggleHistoryPlayback() }
  }

  /// Their first stretch of speech in a recording held on this Mac, not the
  /// start of a recording where someone else may speak first.
  func memoryPlayPersonSample(_ personID: String, projection: MemoryProjection?) {
    guard let sample = projection?.firstVoiceSegment(of: personID) else {
      intake.show("这段声音暂时找不到")
      return
    }
    memoryPlayRange(itemID: sample.itemID, start: sample.start, end: sample.end)
  }

  func memoryRetryIssue(_ issueID: String) {
    guard let issue = memoryIssue(issueID) else { return }
    retryRemoteDecision(issue)
  }

  func memoryDiscardIssue(_ issueID: String) {
    guard let issue = memoryIssue(issueID), issue.state != .deliveryUnknown else { return }
    discardRemoteDecision(issue)
  }

  private func memoryIssue(_ issueID: String) -> RemoteOrganizerDecisionIssue? {
    events.remoteProjection?.unacceptedDecisions.first {
      $0.decisionID.uuidString.caseInsensitiveCompare(issueID) == .orderedSame
    }
  }

  func memoryChangeSource(itemID: String, name: String) {
    guard let session = sessionID(itemID) else { return }
    if let item = memoryHistoryItem(session) {
      changeItemSource(item, to: name)
      return
    }
    guard let repository else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    Task { [weak self] in
      do {
        try await repository.setItemSourceApplication(
          sessionID: session, source: ItemSourceApplication(bundleID: nil, name: trimmed))
        self?.intake.show(trimmed.isEmpty ? "已清除来源" : "来源已改为 \(trimmed)")
        await self?.refreshHistoryItems(preserveStatus: true, organizeEvents: true)
      } catch {
        self?.intake.show("未能修改来源；原记录没有改变")
      }
    }
  }

  // MARK: - Helpers

  func localEventID(_ value: String) -> EventID? {
    UUID(uuidString: value).map(EventID.init)
  }

  func sessionID(_ value: String) -> SessionID? {
    UUID(uuidString: value).map(SessionID.init)
  }

  /// The local event a move takes the record out of: the page it was moved
  /// from when that event holds it, else (from Unfiled) the first holder.
  nonisolated static func memoryLocalMoveSource(
    from page: EventID?, session: SessionID, summaries: [EventSummary]
  ) -> EventID? {
    if let page, summaries.contains(where: { $0.id == page && $0.sessionIDs.contains(session) }) {
      return page
    }
    return summaries.first { $0.sessionIDs.contains(session) }?.id
  }

  /// A new event from one item is titled with the item's first line.
  private func memoryTitle(for session: SessionID) -> String {
    let item = memoryHistoryItem(session)
    let text = item?.preferredText ?? ""
    let line =
      text.split(whereSeparator: \.isNewline)
      .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? item?.title ?? "一件事"
    return String(line.prefix(RemoteOrganizerDecision.maximumTitleScalars))
  }
}
