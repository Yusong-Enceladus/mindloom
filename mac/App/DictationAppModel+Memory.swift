import AppKit
import BestASRDomain
import BestASRMemory
import BestASRMemoryUI
import BestASRPersistence
import Foundation

/// Corrections from the Mindloom pages (v11). Every correction is one
/// `MemoryCorrection`, committed by `memoryCommit` after the undo window
/// (`MemoryScreenModel.corrections`): while the DGX Spark's projection is
/// shown it is recorded as an organizer decision (the local overlay applies
/// it at once); otherwise it goes to the local organizer's events. Pins,
/// groups and step marks are this Mac's own (`UserOrganizingStore`); a pin is
/// also sent to the Spark while the link is on, so its Home rank sees it.
extension DictationAppModel {
  /// True while Home shows the organizing device's events: live with the
  /// link on, or the library's mirror of them with the link off (offline).
  var memoryUsesRemote: Bool { events.remoteProjection != nil }

  /// Other spellings of the owner's name, so pages say 我 / leave the name
  /// out where the organizer wrote it (「林知远博士中期考核」 → 「博士中期考核」):
  /// `preferences.owner-names` (comma-separated) and the Mac user's full
  /// name; in demo mode the demo root's own (`LibraryIdentity`).
  static let memoryOwnerNames: [String] = LibraryIdentity.ownerNames()

  /// The App's one undo window. Its commits are serialized and journaled in
  /// the library (`held-corrections.json`) while they are held.
  func makeMemoryCorrections() -> MemoryCorrectionQueue {
    let journal = (try? Self.applicationDataRoot()).map { HeldCorrectionsFile(dataRoot: $0) }
    let queue = MemoryCorrectionQueue(journal: journal) { [weak self] correction in
      await self?.memoryCommit(correction)
    }
    MemoryCorrectionQuit.queue = queue
    return queue
  }

  /// The link is up (the pages ask the DGX Spark for missing maps then).
  var remoteOrganizerLinkIsConnected: Bool {
    if case .connected = remoteOrganizerLinkStatus { return true }
    return false
  }

  /// A matter opened with no map (the small page): while the link is on,
  /// the DGX Spark is asked to draw one (`POST /v1/events/{id}/map`, once
  /// per matter per connection); the pull that brings it turns the page
  /// into the full 进展 view. Nothing is asked while the link is off.
  func requestMatterMapIfMissing(_ eventID: String) {
    guard remoteOrganizerEnabled, remoteOrganizerLinkIsConnected, let remoteOrganizer,
      let event = events.remoteProjection?.events.first(where: {
        $0.eventID.caseInsensitiveCompare(eventID) == .orderedSame
      }),
      event.map == nil
    else { return }
    remoteOrganizer.requestMap(eventID: event.eventID)
  }

  /// Commits one correction and returns once it is durable.
  func memoryCommit(_ correction: MemoryCorrection) async {
    switch correction {
    case .moveItem(let item, let seg, let from, let to):
      await memoryMoveItem(itemID: item, toEventID: to, fromEventID: from.isEmpty ? nil : from, segID: seg)
    case .takeOut(let item, let seg, let from):
      await memoryRemoveItem(eventID: from, itemID: item, segID: seg)
    case .newMatter(let item, let seg, let from, let title, let provisional):
      await memoryFileItemNewEvent(
        itemID: item, segID: seg, from: from, title: title, newEventID: UUID(uuidString: provisional))
    case .markStep(let event, let step, let state, _):
      try? await repository?.setStepOverride(eventID: event, stepID: step, state: state, at: Date())
    case .rename(let event, _, let title):
      await memoryRenameEvent(event, title: title)
    case .delete(let event, _):
      await memoryDeleteEvent(event)
    case .group(let event, _, let to):
      try? await repository?.moveToUserGroup(
        eventID: event, groupID: to.flatMap(UUID.init(uuidString:)), at: Date())
    case .pin(let event, let pinned):
      try? await repository?.setPinned(pinned, eventID: event, at: Date())
      // A pin is this Mac's own; it is sent only so a live link's Home rank
      // sees it.
      if memoryUsesRemote, remoteOrganizerEnabled {
        await recordRemoteDecisionAndWait(MemoryDecisions.pin(eventID: event, pinned: pinned))
      }
    case .namePerson(let person, _, let to):
      await memoryNamePersonNow(person, name: to)
    case .mergePerson(let person, let into):
      await memoryMergePerson(person, into: into)
    case .notPerson(let item, let person, let starts, let newID):
      await memoryNotPerson(itemID: item, personID: person, starts: starts, newPersonID: newID)
    }
  }

  /// 新建分组; `moving` joins it.
  func memoryCreateGroup(name: String, moving: String?) async -> UserGroup? {
    guard let repository, let group = try? await repository.createUserGroup(name: name, at: Date())
    else { return nil }
    if let moving {
      try? await repository.moveToUserGroup(eventID: moving, groupID: group.id, at: Date())
    }
    return group
  }

  func memoryRenameEvent(_ eventID: String, title: String) async {
    if memoryUsesRemote {
      await recordRemoteDecisionAndWait(MemoryDecisions.rename(eventID: eventID, title: title))
      return
    }
    guard let repository, let id = localEventID(eventID),
      let summary = events.summaries.first(where: { $0.id == id })
    else { return }
    do {
      _ = try await repository.updateEvent(id: id, title: title, notes: summary.event.notes)
      await refreshEventMemory(organize: false)
    } catch {
      intake.show("未能更改标题，原标题保持不变")
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

  /// A person's name, committed after the undo window (v12, 理3-1): this
  /// Mac's own person is renamed in the library (its other names kept);
  /// while Home shows the organizing device's people it is also recorded as
  /// a decision (see `memoryRenameRoutes`).
  func memoryNamePersonNow(_ personID: String, name: String) async {
    let local = localPersonSummary(personID)
    let routes = Self.memoryRenameRoutes(
      knownLocally: local != nil && repository != nil, usesRemote: memoryUsesRemote)
    // Only for someone the organizing device has (it refuses a name for a
    // voice it was never sent).
    if routes.decision, remotePersonKnown(personID) {
      await recordRemoteDecisionAndWait(MemoryDecisions.name(personID: personID, name: name))
    }
    guard routes.local, let local, let repository else { return }
    do {
      _ = try await repository.renamePerson(
        personID: local.person.id, displayName: name, aliases: local.person.aliases,
        originDeviceID: Self.localOriginDeviceID())
      await refreshPeopleNow()
      // The history and its search index carry people's names too.
      await refreshHistoryItems(preserveStatus: true, organizeEvents: false)
    } catch {
      intake.show("未能更改姓名，原姓名保持不变")
    }
  }

  /// 合并到…, committed (v12, 理3-1). Two voices of this Mac are merged in
  /// the library (the one chosen keeps its name and the other's name joins
  /// its names); with the organizing device's people shown it is also
  /// recorded as `same_person`, and when a voice stays over a person read
  /// from texts (`MemoryPersonMerge`) the voice takes that person's name.
  /// A voice the organizer has not seen, joined to a person only the
  /// organizer knows, takes that person's name on this Mac.
  func memoryMergePerson(_ personID: String, into: String) async {
    let persons = events.remoteProjection?.persons ?? []
    let outcome = MemoryPersonMerge.outcome(person: personID, into: into, persons: persons)
    let localJoining = localPersonSummary(personID)
    let localTarget = localPersonSummary(into)
    let targetName =
      persons.first { $0.personID.caseInsensitiveCompare(into) == .orderedSame }?.displayName
      ?? localTarget?.person.displayName
    if memoryUsesRemote, remotePersonKnown(personID), remotePersonKnown(into) {
      await recordRemoteDecisionAndWait(
        RemoteOrganizerDecision(kind: "same_person", a: into, b: personID, answer: true))
      if outcome.stays.caseInsensitiveCompare(personID) == .orderedSame, let targetName,
        !targetName.isEmpty
      {
        await recordRemoteDecisionAndWait(
          MemoryDecisions.name(personID: personID, name: targetName))
      }
    }
    guard let repository, let localJoining else { return }
    do {
      if let localTarget {
        try await repository.mergePersons(
          primaryID: localTarget.person.id, mergedID: localJoining.person.id,
          originDeviceID: Self.localOriginDeviceID())
      } else if let targetName, !targetName.isEmpty,
        localJoining.person.displayName != targetName
      {
        _ = try await repository.renamePerson(
          personID: localJoining.person.id, displayName: targetName,
          aliases: localJoining.person.aliases, originDeviceID: Self.localOriginDeviceID())
      }
      await refreshPeopleNow()
      // The history and its search index carry people's names too.
      await refreshHistoryItems(preserveStatus: true, organizeEvents: false)
    } catch {
      intake.show("未合并，两个人物均保持不变")
    }
  }

  /// 不是他, committed (v12, 理3-1): the speaker turns that make the chosen
  /// sentences this person's go to a new unnamed person (the ID the page
  /// already shows). Voice evidence only: the recording and its words stay.
  func memoryNotPerson(itemID: String, personID: String, starts: [UInt64], newPersonID: String)
    async
  {
    guard let repository, let session = sessionID(itemID),
      let source = UUID(uuidString: personID).map(PersonID.init),
      let newID = UUID(uuidString: newPersonID).map(PersonID.init)
    else { return }
    do {
      let record = try await repository.memoryItemRecords(ids: [session]).first
      let wanted = Set(starts)
      let sentences = (record?.segments ?? []).compactMap {
        segment -> (start: UInt64, end: UInt64)? in
        guard let start = segment.monotonicStartNanoseconds, wanted.contains(start),
          let end = segment.monotonicEndNanoseconds
        else { return nil }
        return (start, end)
      }
      let turns = try await repository.sessionOccurrenceSummaries(sessionID: session)
        .filter {
          [.anonymousIdentity, .automaticMatch, .userConfirmed].contains($0.associationStatus)
        }
        .map {
          MemorySpeakerSplit.Turn(
            id: $0.id.rawValue.uuidString, start: $0.monotonicStartNanoseconds,
            end: $0.monotonicEndNanoseconds, personID: $0.personID?.rawValue.uuidString)
        }
      let ids = MemorySpeakerSplit.turns(for: sentences, among: turns, person: personID)
        .compactMap { UUID(uuidString: $0).map(SpeakerOccurrenceID.init) }
      guard !ids.isEmpty else {
        intake.show("这几句找不到了；没有改动")
        return
      }
      _ = try await repository.splitPersonOccurrences(
        sourcePersonID: source, occurrenceIDs: ids, newDisplayName: nil, newPersonID: newID,
        originDeviceID: Self.localOriginDeviceID())
      await refreshPeopleNow()
      // The history and its search index carry people's names too.
      await refreshHistoryItems(preserveStatus: true, organizeEvents: false)
    } catch {
      intake.show("没有分开；说话的人没有变化")
    }
  }

  /// The organizing device lists this person (its mirror on this Mac).
  func remotePersonKnown(_ personID: String) -> Bool {
    events.remoteProjection?.persons.contains {
      $0.personID.caseInsensitiveCompare(personID) == .orderedSame
    } ?? false
  }

  /// This Mac's own person with that ID, if it is one.
  func localPersonSummary(_ personID: String) -> PersonSummary? {
    UUID(uuidString: personID).flatMap { uuid in
      people.personSummaries.first { $0.person.id == PersonID(uuid) }
    }
  }

  /// 不属于这件事: the item (or only its part `segID`) leaves the matter and
  /// waits in 刚收进来.
  func memoryRemoveItem(eventID: String, itemID: String, segID: String? = nil) async {
    if memoryUsesRemote {
      await recordRemoteDecisionAndWait(
        MemoryDecisions.remove(itemID: itemID, from: eventID, segID: segID))
      return
    }
    guard let repository, let event = localEventID(eventID), let session = sessionID(itemID)
    else { return }
    do {
      try await repository.removeSessions([session], from: event)
      await refreshEventMemory(organize: false)
    } catch {
      intake.show("没有移出；这件事没有变化")
    }
  }

  /// `fromEventID` is the matter the user moved it from (nil from 刚收进来):
  /// a record may sit in several local events, and only that one gives it up.
  func memoryMoveItem(
    itemID: String, toEventID: String, fromEventID: String?, segID: String? = nil
  ) async {
    if memoryUsesRemote {
      await recordRemoteDecisionAndWait(
        MemoryDecisions.move(itemID: itemID, to: toEventID, segID: segID))
      return
    }
    guard let repository, let target = localEventID(toEventID), let session = sessionID(itemID)
    else { return }
    let source = Self.memoryLocalMoveSource(
      from: fromEventID.flatMap(localEventID), session: session, summaries: events.summaries)
    if source == target { return }
    do {
      if let source, source != target {
        try await repository.moveSessions([session], from: source, to: target, evidence: .manual())
      } else if source == nil {
        try await repository.linkSessions(
          [session], to: target, source: .manual, evidence: .manual())
      }
      await refreshEventMemory(organize: false)
    } catch {
      intake.show("没有移过去；原来的位置没有变化")
    }
  }

  /// + 新建一件事: the item founds a new matter titled `title` (the DGX
  /// Spark files it under `newEventID`, then takes the title).
  func memoryFileItemNewEvent(
    itemID: String, segID: String?, from: String, title: String, newEventID: UUID?
  ) async {
    if memoryUsesRemote {
      let id = newEventID ?? UUID()
      await recordRemoteDecisionAndWait(MemoryDecisions.fileAsNewEvent(itemID: itemID, newEventID: id))
      await recordRemoteDecisionAndWait(
        MemoryDecisions.rename(eventID: id.uuidString.lowercased(), title: title))
      return
    }
    guard let repository, let session = sessionID(itemID) else { return }
    let holders = events.summaries.filter { $0.sessionIDs.contains(session) }.map(\.id)
    let name = title.isEmpty ? memoryTitle(for: session) : title
    do {
      for holder in holders where holder == localEventID(from) || from.isEmpty {
        try await repository.removeSessions([session], from: holder)
      }
      _ = try await repository.createEvent(title: name, notes: "", sessionIDs: [session])
      await refreshEventMemory(organize: false)
    } catch {
      intake.show("没有新建；原来的位置没有变化")
    }
  }

  /// 删除…: the matter goes; its items stay.
  func memoryDeleteEvent(_ eventID: String) async {
    if memoryUsesRemote {
      await recordRemoteDecisionAndWait(MemoryDecisions.delete(eventID: eventID))
      return
    }
    guard let repository, let id = localEventID(eventID) else { return }
    do {
      try await repository.retireEvent(id: id)
      if events.selectedEventID == id { events.selectedEventID = nil }
      await refreshEventMemory(organize: false)
    } catch {
      intake.show("没有删除；这件事没有变化")
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
      intake.show("这段录音暂时无法打开")
      return
    }
    playback.stopAt = nil
    playback.voicePersonID = nil
    playHistoryItem(item)
  }

  /// Plays one stretch of a recording (monotonic nanoseconds) and stops at
  /// its end: a sentence of 原文, a voice to name (`voice`: whose). A record
  /// older than the App's in-memory lists is read from the library first.
  func memoryPlayRange(itemID: String, start: UInt64, end: UInt64, voice: String? = nil) {
    guard let session = sessionID(itemID) else { return }
    guard let item = memoryHistoryItem(session) else {
      guard let repository else { return }
      Task { [weak self] in
        guard let item = try? await repository.historyItems(sessionIDs: [session]).first else {
          self?.intake.show("这段录音暂时无法打开")
          return
        }
        self?.memoryPlayRange(item, session: session, start: start, end: end, voice: voice)
      }
      return
    }
    memoryPlayRange(item, session: session, start: start, end: end, voice: voice)
  }

  private func memoryPlayRange(
    _ item: DictationHistoryItem, session: SessionID, start: UInt64, end: UInt64, voice: String?
  ) {
    playback.voicePersonID = voice
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

  /// 「听一段」 (v12, 理3-1): about three seconds of a person's own voice
  /// (`MemoryVoiceSample`), from the recordings the pages hold, else from
  /// any recording of theirs in the library. Played on this Mac only.
  func memoryPlayVoiceSample(_ personID: String, projection: MemoryProjection?) {
    if let sample = projection?.voiceSample(of: personID) {
      memoryPlayRange(itemID: sample.itemID, start: sample.start, end: sample.end, voice: personID)
      return
    }
    guard let repository, let uuid = UUID(uuidString: personID) else {
      intake.show("这段声音暂时找不到")
      return
    }
    Task { [weak self] in
      let turns = (try? await repository.personOccurrenceSummaries(personID: PersonID(uuid))) ?? []
      // Newest recording first (as the library lists them), its turns in order.
      let stretches = turns.map {
        MemoryVoiceStretch(
          itemID: $0.sessionID.rawValue.uuidString, start: $0.monotonicStartNanoseconds,
          end: $0.monotonicEndNanoseconds)
      }
      guard let self else { return }
      guard let sample = MemoryVoiceSample.choose(stretches) else {
        intake.show("这段声音暂时找不到")
        return
      }
      memoryPlayRange(itemID: sample.itemID, start: sample.start, end: sample.end, voice: personID)
    }
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
