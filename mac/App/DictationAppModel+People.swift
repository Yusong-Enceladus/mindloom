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

// People: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  func setSpeakerModelLicenseAccepted(_ accepted: Bool) {
    models.speakerModelLicenseAccepted = accepted
    guard !fixtureMode else { return }
    LocalModelLicenseReceipts.setAccepted(
      accepted,
      key: Self.speakerLicenseReceiptKey,
      receipt: Self.speakerLicenseReceipt
    )
  }

  func setPersonalCleanupEnabled(_ enabled: Bool) {
    people.personalCleanupEnabled = enabled
    LocalPreferenceStore.defaults.set(
      enabled,
      forKey: "preferences.personal-cleanup-enabled"
    )
    applyRuntimePreferences()
  }

  func setSpeakerMemoryEnabled(_ enabled: Bool) {
    guard enabled != people.speakerMemoryEnabled else { return }
    guard !hasActiveCapture else {
      preferencesStatusMessage = "请先结束当前录音或导入，再更改声纹记忆"
      return
    }
    if enabled {
      people.speakerMemoryEnabled = true
      LocalPreferenceStore.defaults.set(
        true,
        forKey: "preferences.speaker-memory-enabled"
      )
      preferencesStatusMessage = "已启用本机人物匹配；新的声纹证据只保存在这台 Mac 上"
      applyRuntimePreferences()
      return
    }
    guard let repository else {
      preferencesStatusMessage = "人物存储暂不可用"
      return
    }
    preferencesStatusMessage = "正在删除本机声纹向量…"
    Task { [weak self] in
      guard let self else { return }
      do {
        try await repository.deleteAllSpeakerEmbeddings()
        people.speakerMemoryEnabled = false
        LocalPreferenceStore.defaults.set(
          false,
          forKey: "preferences.speaker-memory-enabled"
        )
        preferencesStatusMessage =
          "声纹向量已删除；原音、文字、人物名称和人工确认关系仍保留"
        applyRuntimePreferences()
        await refreshPeopleNow()
        if let selectedHistorySessionID = history.selectedHistorySessionID {
          await refreshSelectedSpeakerDetails(sessionID: selectedHistorySessionID)
        }
      } catch {
        preferencesStatusMessage = "声纹向量未删除；现有设置保持不变"
      }
    }
  }

  func chooseAndInstallSpeakerModel() {
    guard models.speakerModelLicenseAccepted, !models.speakerModelInstallInProgress else {
      people.speakerReadinessMessage = "请先阅读并接受多人识别组件的 CC BY 4.0 许可"
      return
    }
    let panel = NSOpenPanel()
    panel.title = "选择已固定版本的多人识别组件文件夹"
    panel.prompt = "安装本地组件"
    panel.message =
      "请选择包含 Segmentation、Embedding、FBank、PldaRho 和 plda-parameters.json 的文件夹。应用只在本机复制并逐项校验。"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let source = panel.url else { return }

    models.speakerModelInstallInProgress = true
    people.speakerRuntimeReady = false
    people.speakerReadinessMessage = "正在校验并安装本地多人识别组件…"
    Task { [weak self] in
      guard let self else { return }
      defer { models.speakerModelInstallInProgress = false }
      do {
        guard let localRuntime else { return }
        try await localRuntime.installSpeakerModel(from: source)
        people.speakerRuntimeReady = true
        people.speakerReadinessMessage = "本地多人识别组件已就绪"
      } catch {
        people.speakerRuntimeReady = false
        people.speakerReadinessMessage =
          "组件被拒绝：文件夹、版本、大小、摘要或 Core ML 加载检查不匹配"
      }
    }
  }

  static func personSummary(
    _ summary: PersonSummary,
    matches query: String
  ) -> Bool {
    if (summary.person.displayName ?? "")
      .localizedCaseInsensitiveContains(query)
      || summary.person.aliases.contains(where: {
        $0.localizedCaseInsensitiveContains(query)
      })
    {
      return true
    }
    guard summary.person.displayName == nil,
      summary.sessionCount > 0
        || summary.occurrenceCount > 0
        || summary.embeddingCount > 0
    else { return false }
    // UUIDs and other storage identities are provenance, not words a person
    // can remember. Matching them made ordinary numeric searches surface
    // unrelated, indistinguishable anonymous profiles.
    return "待命名人物".localizedCaseInsensitiveContains(query)
  }

  static func browsablePersonSummaries(
    _ summaries: [PersonSummary]
  ) -> [PersonSummary] {
    summaries.filter { summary in
      let hasName = !(summary.person.displayName ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let hasAlias = summary.person.aliases.contains {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      return hasName
        || hasAlias
        || summary.sessionCount > 0
        || summary.occurrenceCount > 0
        || summary.embeddingCount > 0
    }
  }

  func confirmSpeakerAsNewPerson(_ speaker: SessionSpeakerSummary) {
    let name =
      people.speakerNameDrafts[speaker.id]?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !name.isEmpty else {
      people.speakerIdentityStatusMessage = "请先输入人物名称"
      return
    }
    updateSpeakerIdentity(speaker, personID: nil, newDisplayName: name)
  }

  func confirmSpeakerCandidate(_ speaker: SessionSpeakerSummary) {
    guard let personID = speaker.personID,
      [.candidate, .automaticMatch].contains(speaker.associationStatus)
    else {
      people.speakerIdentityStatusMessage = "这位说话人目前没有可确认的人物候选"
      return
    }
    updateSpeakerIdentity(
      speaker,
      personID: personID,
      newDisplayName: nil
    )
  }

  func refreshPeople() {
    if fixtureMode, let fixture = historyPlaybackUIFixture {
      people.personSummaries = Self.browsablePersonSummaries(fixture.people)
      people.personReviewCandidates = Self.personReviewCandidates(from: fixture)
      people.peopleStatusMessage = Self.peopleStatus(
        personCount: people.personSummaries.count,
        reviewCount: people.personReviewCandidates.count
      )
      return
    }
    Task { [weak self] in
      guard let self, let repository else { return }
      do {
        async let summaries = repository.personSummaries()
        async let candidates = repository.pendingPersonReviewCandidates()
        let loaded = try await (summaries, candidates)
        people.personSummaries = Self.browsablePersonSummaries(loaded.0)
        people.personReviewCandidates = loaded.1
        people.peopleStatusMessage = Self.peopleStatus(
          personCount: people.personSummaries.count,
          reviewCount: loaded.1.count
        )
      } catch {
        people.peopleStatusMessage = "无法读取本地人物资料"
      }
    }
  }

  func personReviewCandidateSessionTitle(
    _ candidate: PersonReviewCandidateSummary
  ) -> String {
    history.historyItems.first(where: { $0.sessionID == candidate.sessionID })?.title
      ?? "本地记录"
  }

  static func peopleStatus(
    personCount: Int,
    reviewCount: Int
  ) -> String {
    if personCount == 0, reviewCount == 0 {
      return "人物会在本机识别到足够的说话证据后出现在这里"
    }
    let review = reviewCount == 0 ? "没有待确认线索" : "\(reviewCount) 条待确认线索"
    return "\(personCount) 个人物 · \(review)；声纹和出现记录只保存在本机"
  }

  func openPersonReviewCandidate(
    _ candidate: PersonReviewCandidateSummary
  ) {
    guard
      let item = history.historyItems.first(where: {
        $0.sessionID == candidate.sessionID
      })
    else {
      people.peopleStatusMessage = "这条人物线索的来源记录当前不可用；请刷新后重试"
      return
    }
    let candidateName = candidate.candidateDisplayName?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    beginHistoryNavigation(
      item,
      returningTo: HistoryNavigationOrigin(
        kind: .person,
        title: candidateName.flatMap { $0.isEmpty ? nil : $0 } ?? "待确认人物"
      )
    )
    Task { [weak self] in
      guard let self else { return }
      await refreshSelectedSpeakerDetails(sessionID: item.sessionID)
      guard history.selectedHistorySessionID == item.sessionID else { return }
      if let firstTrack = playback.playbackTrackIDs.first {
        selectHistoryPlaybackTrack(firstTrack)
      }
      if let segment = historyTranscriptSegment(
        overlappingStart: candidate.monotonicStartNanoseconds,
        end: candidate.monotonicEndNanoseconds
      ) {
        playHistoryTranscriptSegment(segment)
      } else {
        seekHistoryPlayback(
          toMonotonicNanoseconds: candidate.monotonicStartNanoseconds
        )
        history.detailStatusMessage =
          "已定位到待确认人物的原音；这条旧记录没有可高亮的逐字稿分段"
      }
    }
  }

  func beginEditingPerson(_ summary: PersonSummary) {
    people.selectedPersonID = summary.person.id
    people.personNameDraft = summary.person.displayName ?? ""
    people.personAliasesDraft = summary.person.aliases.joined(separator: "，")
    people.mergeTargetPersonID = nil
    people.selectedPersonOccurrences = []
    history.selectedPersonHistoryItems = []
    Task { [weak self] in
      guard let self, let repository else { return }
      async let occurrences = repository.personOccurrenceSummaries(
        personID: summary.person.id
      )
      async let allHistory = repository.loadHistory(limit: 5_000)
      let loadedOccurrences = (try? await occurrences) ?? []
      let sessionIDs = Set(loadedOccurrences.map(\.sessionID))
      guard people.selectedPersonID == summary.person.id else { return }
      people.selectedPersonOccurrences = loadedOccurrences
      history.selectedPersonHistoryItems = ((try? await allHistory) ?? []).filter {
        sessionIDs.contains($0.sessionID)
      }
    }
  }

  func openPersonOccurrence(
    _ occurrence: SpeakerOccurrenceSummary,
    play: Bool = false
  ) {
    guard
      let item = history.selectedPersonHistoryItems.first(where: {
        $0.sessionID == occurrence.sessionID
      })
    else {
      people.peopleStatusMessage = "这条相关记录当前未加载；请刷新历史后重试"
      return
    }
    let personTitle =
      selectedPersonSummary?.person.displayName?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let returnTitle =
      personTitle.flatMap { $0.isEmpty ? nil : $0 }
      ?? "未命名人物"
    beginHistoryNavigation(
      item,
      returningTo: HistoryNavigationOrigin(
        kind: .person,
        title: returnTitle
      )
    )
    Task { [weak self] in
      guard let self else { return }
      await refreshSelectedSpeakerDetails(sessionID: item.sessionID)
      if let firstTrack = playback.playbackTrackIDs.first {
        selectHistoryPlaybackTrack(firstTrack)
      }
      if let segment = historyTranscriptSegment(
        overlappingStart: occurrence.monotonicStartNanoseconds,
        end: occurrence.monotonicEndNanoseconds
      ) {
        if play {
          playHistoryTranscriptSegment(segment)
        } else {
          locateHistoryTranscriptSegment(segment)
        }
      } else {
        seekHistoryPlayback(
          toMonotonicNanoseconds: occurrence.monotonicStartNanoseconds
        )
        history.detailStatusMessage =
          "已定位到人物出现的原音；这条旧记录没有可高亮的逐字稿分段"
        if play { toggleHistoryPlayback() }
      }
    }
  }

  func savePersonDraft() {
    guard let selectedPersonID = people.selectedPersonID, let repository else { return }
    let aliases = DictionaryModel.spokenForms(people.personAliasesDraft)
    people.peopleStatusMessage = "正在保存人物资料…"
    Task { [weak self] in
      guard let self else { return }
      do {
        _ = try await repository.renamePerson(
          personID: selectedPersonID,
          displayName: people.personNameDraft,
          aliases: aliases,
          originDeviceID: Self.localOriginDeviceID()
        )
        await refreshPeopleNow()
        people.peopleStatusMessage = "人物名称和别名已保存"
      } catch {
        people.peopleStatusMessage = "人物资料未保存；请检查名称或稍后重试"
      }
    }
  }

  func mergeSelectedPerson() {
    guard let primaryID = people.selectedPersonID,
      let mergedID = people.mergeTargetPersonID,
      primaryID != mergedID,
      let repository
    else { return }
    people.peopleStatusMessage = "正在合并人物和本地声纹证据…"
    Task { [weak self] in
      guard let self else { return }
      do {
        try await repository.mergePersons(
          primaryID: primaryID,
          mergedID: mergedID,
          originDeviceID: Self.localOriginDeviceID()
        )
        people.mergeTargetPersonID = nil
        await refreshPeopleNow()
        if let selectedHistorySessionID = history.selectedHistorySessionID {
          await refreshSelectedSpeakerDetails(sessionID: selectedHistorySessionID)
        }
        people.peopleStatusMessage = "人物已合并；可以使用撤销恢复"
      } catch {
        people.peopleStatusMessage = "人物合并失败；现有资料没有被改变"
      }
    }
  }

  func undoLastPersonEdit() {
    if fixtureMode, historyPlaybackUIFixture != nil {
      guard let previous = historyPlaybackFixturePersonUndoStack.popLast() else {
        people.speakerIdentityStatusMessage = "没有可撤销的人物修改"
        people.peopleStatusMessage = people.speakerIdentityStatusMessage
        return
      }
      people.selectedSessionSpeakers = previous.0
      selectedSessionOccurrences = previous.1
      people.personSummaries = Self.browsablePersonSummaries(previous.2)
      if var fixture = historyPlaybackUIFixture {
        fixture.speakers = previous.0
        fixture.occurrences = previous.1
        fixture.people = previous.2
        historyPlaybackUIFixture = fixture
        people.personReviewCandidates = Self.personReviewCandidates(from: fixture)
      }
      people.speakerIdentityStatusMessage = "最近一次人物修改已撤销"
      people.peopleStatusMessage = people.speakerIdentityStatusMessage
      return
    }
    guard let repository else { return }
    people.peopleStatusMessage = "正在撤销最近一次人物修改…"
    people.speakerIdentityStatusMessage = people.peopleStatusMessage
    Task { [weak self] in
      guard let self else { return }
      do {
        let changed = try await repository.undoLastPersonEdit(
          originDeviceID: Self.localOriginDeviceID()
        )
        await refreshPeopleNow()
        if let selectedHistorySessionID = history.selectedHistorySessionID {
          await refreshSelectedSpeakerDetails(sessionID: selectedHistorySessionID)
        }
        people.peopleStatusMessage =
          changed
          ? "最近一次人物修改已撤销" : "没有可撤销的人物修改"
        people.speakerIdentityStatusMessage = people.peopleStatusMessage
      } catch {
        people.peopleStatusMessage = "撤销失败；现有资料没有被改变"
        people.speakerIdentityStatusMessage = people.peopleStatusMessage
      }
    }
  }

  func refreshPeopleNow() async {
    if fixtureMode, let fixture = historyPlaybackUIFixture {
      people.personSummaries = Self.browsablePersonSummaries(fixture.people)
      people.personReviewCandidates = Self.personReviewCandidates(from: fixture)
      people.peopleStatusMessage = Self.peopleStatus(
        personCount: people.personSummaries.count,
        reviewCount: people.personReviewCandidates.count
      )
      return
    }
    guard let repository else { return }
    async let summaries = repository.personSummaries()
    async let candidates = repository.pendingPersonReviewCandidates()
    if let loaded = try? await (summaries, candidates) {
      people.personSummaries = Self.browsablePersonSummaries(loaded.0)
      people.personReviewCandidates = loaded.1
      people.peopleStatusMessage = Self.peopleStatus(
        personCount: people.personSummaries.count,
        reviewCount: loaded.1.count
      )
    }
    if let selectedPersonID = people.selectedPersonID,
      let selected = people.personSummaries.first(where: {
        $0.person.id == selectedPersonID
      })
    {
      people.personNameDraft = selected.person.displayName ?? ""
      people.personAliasesDraft = selected.person.aliases.joined(separator: "，")
      people.selectedPersonOccurrences =
        (try? await repository.personOccurrenceSummaries(
          personID: selectedPersonID
        )) ?? people.selectedPersonOccurrences
      let sessionIDs = Set(people.selectedPersonOccurrences.map(\.sessionID))
      history.selectedPersonHistoryItems =
        ((try? await repository.loadHistory(limit: 5_000)) ?? []).filter {
          sessionIDs.contains($0.sessionID)
        }
    } else {
      people.selectedPersonID = nil
      people.selectedPersonOccurrences = []
      history.selectedPersonHistoryItems = []
      people.personNameDraft = ""
      people.personAliasesDraft = ""
    }
  }

  func assignSpeaker(
    _ speaker: SessionSpeakerSummary,
    to person: PersonSummary
  ) {
    updateSpeakerIdentity(
      speaker,
      personID: person.person.id,
      newDisplayName: nil
    )
  }

  func rejectSpeakerPersonMatch(_ speaker: SessionSpeakerSummary) {
    guard let candidate = speaker.personID,
      let sessionID = history.selectedHistorySessionID
    else {
      people.speakerIdentityStatusMessage = "这位说话人目前没有可拒绝的人物候选"
      return
    }
    if fixtureMode, historyPlaybackUIFixture != nil {
      mutateHistoryPlaybackFixtureSpeaker(speaker.id) { summary in
        SessionSpeakerSummary(
          id: summary.id,
          stableOrdinal: summary.stableOrdinal,
          personID: summary.personID,
          displayName: summary.displayName,
          associationStatus: .rejected,
          confidence: nil,
          speechDurationNanoseconds: summary.speechDurationNanoseconds,
          occurrenceCount: summary.occurrenceCount
        )
      } occurrence: { occurrence in
        SpeakerOccurrenceSummary(
          id: occurrence.id,
          sessionID: occurrence.sessionID,
          sessionSpeakerID: occurrence.sessionSpeakerID,
          stableOrdinal: occurrence.stableOrdinal,
          monotonicStartNanoseconds: occurrence.monotonicStartNanoseconds,
          monotonicEndNanoseconds: occurrence.monotonicEndNanoseconds,
          personID: occurrence.personID,
          personDisplayName: occurrence.personDisplayName,
          associationStatus: .rejected
        )
      }
      people.speakerIdentityStatusMessage =
        "已拒绝这个人物候选；本次记录不会再关联到该人物"
      return
    }
    guard let repository else {
      people.speakerIdentityStatusMessage = "人物资料当前不可用；现有关系没有变化"
      return
    }
    people.speakerIdentityStatusMessage = "正在记录“不是同一人物”…"
    Task { [weak self] in
      guard let self else { return }
      do {
        try await repository.rejectSessionSpeakerCandidate(
          sessionSpeakerID: speaker.id,
          candidatePersonID: candidate,
          originDeviceID: Self.localOriginDeviceID()
        )
        people.speakerIdentityStatusMessage =
          "已拒绝这个人物候选；本次记录不会再自动关联到该人物"
        await refreshSelectedSpeakerDetails(sessionID: sessionID)
        await refreshPeopleNow()
      } catch {
        people.speakerIdentityStatusMessage = "拒绝未保存；现有关系没有变化"
      }
    }
  }

  func clearSpeakerPersonAssociation(_ speaker: SessionSpeakerSummary) {
    guard let sessionID = history.selectedHistorySessionID else { return }
    if fixtureMode, historyPlaybackUIFixture != nil {
      mutateHistoryPlaybackFixtureSpeaker(speaker.id) { summary in
        SessionSpeakerSummary(
          id: summary.id,
          stableOrdinal: summary.stableOrdinal,
          personID: nil,
          displayName: nil,
          associationStatus: .unknown,
          confidence: nil,
          speechDurationNanoseconds: summary.speechDurationNanoseconds,
          occurrenceCount: summary.occurrenceCount
        )
      } occurrence: { occurrence in
        SpeakerOccurrenceSummary(
          id: occurrence.id,
          sessionID: occurrence.sessionID,
          sessionSpeakerID: occurrence.sessionSpeakerID,
          stableOrdinal: occurrence.stableOrdinal,
          monotonicStartNanoseconds: occurrence.monotonicStartNanoseconds,
          monotonicEndNanoseconds: occurrence.monotonicEndNanoseconds,
          personID: nil,
          personDisplayName: nil,
          associationStatus: .unknown
        )
      }
      people.speakerIdentityStatusMessage =
        "人物关联已移除；说话人片段和原始证据仍完整保留"
      return
    }
    guard let repository else { return }
    people.speakerIdentityStatusMessage = "正在移除本次记录的人物关联…"
    Task { [weak self] in
      guard let self else { return }
      do {
        try await repository.clearSessionSpeakerAssociation(
          sessionSpeakerID: speaker.id,
          originDeviceID: Self.localOriginDeviceID()
        )
        people.speakerIdentityStatusMessage =
          "人物关联已移除；说话人片段和原始证据仍完整保留"
        await refreshSelectedSpeakerDetails(sessionID: sessionID)
      } catch {
        people.speakerIdentityStatusMessage = "人物关联未移除"
      }
    }
  }

  func deleteSelectedPersonVoiceprints() {
    guard let selectedPersonID = people.selectedPersonID, let repository else { return }
    people.peopleStatusMessage = "正在删除所选人物的本机声纹向量…"
    Task { [weak self] in
      guard let self else { return }
      do {
        try await repository.deleteSpeakerEmbeddings(personID: selectedPersonID)
        await refreshPeopleNow()
        if let selectedHistorySessionID = history.selectedHistorySessionID {
          await refreshSelectedSpeakerDetails(sessionID: selectedHistorySessionID)
        }
        people.peopleStatusMessage =
          "该人物的声纹向量已删除；名称、人工确认关系、原音和文字仍保留"
      } catch {
        people.peopleStatusMessage = "声纹向量未删除；现有人物资料没有变化"
      }
    }
  }

  func deleteSelectedPersonIdentity() {
    guard let selectedPersonID = people.selectedPersonID, let repository else { return }
    people.peopleStatusMessage = "正在解除人物关联并删除本机识别特征…"
    Task { [weak self] in
      guard let self else { return }
      do {
        try await repository.retirePersonAndClearAssociations(
          personID: selectedPersonID,
          originDeviceID: Self.localOriginDeviceID()
        )
        self.people.selectedPersonID = nil
        people.selectedPersonOccurrences = []
        history.selectedPersonHistoryItems = []
        await refreshPeopleNow()
        await refreshHistoryItems(
          preserveStatus: true,
          organizeEvents: true
        )
        people.peopleStatusMessage =
          "人物身份、声纹和记录关联已删除；相关历史、逐字稿和原音均未删除"
      } catch {
        people.peopleStatusMessage = "人物身份未删除；现有资料没有变化"
      }
    }
  }

  func reevaluateAutomaticPersonMatches() {
    guard people.speakerMemoryEnabled, let localRuntime else {
      people.peopleStatusMessage = "请先启用本机声纹记忆"
      return
    }
    guard !hasActiveCapture else {
      people.peopleStatusMessage = "请先结束当前录音或导入"
      return
    }
    people.peopleStatusMessage = "正在重新排队未人工确认的人物匹配…"
    Task { [weak self] in
      guard let self else { return }
      do {
        let count = try await localRuntime.reevaluateAutomaticPersonMatches()
        await refreshPeopleNow()
        if let selectedHistorySessionID = history.selectedHistorySessionID {
          await refreshSelectedSpeakerDetails(sessionID: selectedHistorySessionID)
        }
        people.peopleStatusMessage =
          count == 0
          ? "没有需要重新评估的自动匹配"
          : "已重新评估 \(count) 条记录；人工确认和拒绝不会被覆盖"
      } catch {
        people.peopleStatusMessage = "重新评估未完成；现有人工关系没有变化"
      }
    }
  }

  func updateSpeakerIdentity(
    _ speaker: SessionSpeakerSummary,
    personID: PersonID?,
    newDisplayName: String?
  ) {
    guard let sessionID = history.selectedHistorySessionID else { return }
    if fixtureMode, historyPlaybackUIFixture != nil {
      let resolvedPerson: PersonSummary? = {
        if let personID {
          return people.personSummaries.first { $0.person.id == personID }
        }
        guard let newDisplayName else { return nil }
        guard let revision = people.personSummaries.first?.person.revision else {
          return nil
        }
        let now = Date()
        let created = PersonSummary(
          person: Person(
            id: PersonID(),
            revision: revision,
            displayName: newDisplayName,
            aliases: [],
            createdAt: now,
            updatedAt: now
          ),
          occurrenceCount: speaker.occurrenceCount,
          embeddingCount: 1,
          sessionCount: 1,
          speechDurationNanoseconds: speaker.speechDurationNanoseconds,
          latestOccurrenceAt: now
        )
        people.personSummaries.append(created)
        if var fixture = historyPlaybackUIFixture {
          fixture.people = people.personSummaries
          historyPlaybackUIFixture = fixture
        }
        return created
      }()
      guard let resolvedPerson else {
        people.speakerIdentityStatusMessage = "人物匹配未保存；请选择一个人物"
        return
      }
      mutateHistoryPlaybackFixtureSpeaker(speaker.id) { summary in
        SessionSpeakerSummary(
          id: summary.id,
          stableOrdinal: summary.stableOrdinal,
          personID: resolvedPerson.person.id,
          displayName: resolvedPerson.person.displayName,
          associationStatus: .userConfirmed,
          confidence: try? Confidence(1),
          speechDurationNanoseconds: summary.speechDurationNanoseconds,
          occurrenceCount: summary.occurrenceCount
        )
      } occurrence: { occurrence in
        SpeakerOccurrenceSummary(
          id: occurrence.id,
          sessionID: occurrence.sessionID,
          sessionSpeakerID: occurrence.sessionSpeakerID,
          stableOrdinal: occurrence.stableOrdinal,
          monotonicStartNanoseconds: occurrence.monotonicStartNanoseconds,
          monotonicEndNanoseconds: occurrence.monotonicEndNanoseconds,
          personID: resolvedPerson.person.id,
          personDisplayName: resolvedPerson.person.displayName,
          associationStatus: .userConfirmed
        )
      }
      people.speakerNameDrafts[speaker.id] = ""
      people.speakerIdentityStatusMessage = "人物匹配已保存，并会用于之后的本地识别"
      return
    }
    people.speakerIdentityStatusMessage = "正在保存本地人物匹配…"
    Task { [weak self] in
      guard let self, let repository else { return }
      do {
        _ = try await repository.confirmSessionSpeaker(
          sessionSpeakerID: speaker.id,
          personID: personID,
          newDisplayName: newDisplayName,
          originDeviceID: Self.localOriginDeviceID()
        )
        people.speakerNameDrafts[speaker.id] = ""
        people.speakerIdentityStatusMessage = "人物匹配已保存，并会用于之后的本地识别"
        await refreshSelectedSpeakerDetails(sessionID: sessionID)
        await refreshPeopleNow()
      } catch {
        people.speakerIdentityStatusMessage =
          "人物匹配未保存；请等待多人处理完成后重试"
      }
    }
  }

  func publishSpeakerReadiness(_ ready: Bool) {
    if ready {
      people.speakerRuntimeReady = true
      people.speakerReadinessMessage = "本地多人识别组件已就绪"
    } else {
      people.speakerRuntimeReady = false
      people.speakerReadinessMessage = "尚未安装本地多人识别组件"
    }
  }

  func refreshSelectedSpeakerDetails(sessionID: SessionID) async {
    guard history.selectedHistorySessionID == sessionID else { return }
    if let fixture = historyPlaybackUIFixture,
      fixture.sessionID == sessionID
    {
      applyHistoryPlaybackUIFixture(fixture)
      return
    }
    guard let repository else { return }
    let selectionGeneration = historyPlaybackGeneration
    async let speakers = try? await repository.sessionSpeakerSummaries(
      sessionID: sessionID
    )
    async let people = try? await repository.personSummaries()
    async let occurrences = try? await repository.sessionOccurrenceSummaries(
      sessionID: sessionID
    )
    async let transcripts = try? await repository.loadTranscripts(
      sessionID: sessionID
    )
    async let documents = try? await repository.loadLocalTextDocuments(
      sessionID: sessionID
    )
    async let assets = try? await repository.retainedSourceAssets(
      sessionID: sessionID
    )
    async let timelineEvents = try? await repository.loadTimelineEvents(
      sessionID: sessionID
    )
    async let sourceContexts = try? await repository.loadSourceContexts(
      sessionID: sessionID
    )
    let playbackJournal = journal
    async let trackDescriptors: [CaptureTrackDescriptor]? = {
      guard let playbackJournal else { return nil }
      return try? await playbackJournal.sourceTrackDescriptors(sessionID: sessionID)
    }()
    async let playbackRanges: [AudioRangeInput]? = {
      guard let playbackJournal else { return nil }
      return try? await playbackJournal.committedAudioSnapshot(sessionID: sessionID)
    }()

    let loaded = await (
      speakers, people, occurrences, transcripts, documents, assets,
      timelineEvents, sourceContexts, trackDescriptors, playbackRanges
    )
    guard historyPlaybackGeneration == selectionGeneration,
      history.selectedHistorySessionID == sessionID
    else { return }

    let previousTranscriptText = selectedHistoryCurrentTranscript?.content ?? ""
    self.people.selectedSessionSpeakers = loaded.0 ?? []
    if let loadedPeople = loaded.1 {
      self.people.personSummaries = Self.browsablePersonSummaries(loadedPeople)
    }
    selectedSessionOccurrences = loaded.2 ?? []
    history.selectedHistoryTranscripts = loaded.3 ?? []
    if historyTranscriptEditSessionID != sessionID
      || history.transcriptEditDraft == previousTranscriptText
    {
      history.transcriptEditDraft = selectedHistoryCurrentTranscript?.content ?? ""
      historyTranscriptEditSessionID = sessionID
    }
    history.selectedHistoryDocuments = loaded.4 ?? []
    let currentDocuments = history.selectedHistoryDocuments.filter { $0.state == .current }
    history.documentTextDrafts = Dictionary(
      uniqueKeysWithValues: currentDocuments.map { ($0.id, $0.result.outputText) }
    )
    let currentItems = currentDocuments.flatMap(\.result.structuredItems)
    history.structuredItemTextDrafts = Dictionary(
      uniqueKeysWithValues: currentItems.map { ($0.itemID, $0.text) }
    )
    history.structuredItemOwnerDrafts = Dictionary(
      uniqueKeysWithValues: currentItems.map { ($0.itemID, $0.owner ?? "") }
    )
    history.structuredItemDueDateDrafts = Dictionary(
      uniqueKeysWithValues: currentItems.map { ($0.itemID, $0.dueDateText ?? "") }
    )
    history.selectedHistorySourceAssets = loaded.5 ?? []
    history.selectedHistoryTimelineEvents = loaded.6 ?? []
    history.selectedHistorySourceContexts = loaded.7 ?? []

    let descriptors = loaded.8 ?? []
    let ranges = loaded.9 ?? []
    if !descriptors.isEmpty, !ranges.isEmpty {
      historyPlaybackAssetRootURL = playbackJournal?.assetRootURL
      playback.playbackTrackRoles = Dictionary(
        uniqueKeysWithValues: descriptors.map {
          ($0.id.rawValue.uuidString, $0.role)
        }
      )
      historyPlaybackTrackDescriptors = Dictionary(
        uniqueKeysWithValues: descriptors.map {
          ($0.id.rawValue.uuidString, $0)
        }
      )
      historyPlaybackRangesByTrack = Dictionary(
        grouping: ranges,
        by: { $0.trackID.uuidString }
      )
    } else {
      historyPlaybackAssetRootURL = nil
      playback.playbackTrackRoles = [:]
      historyPlaybackTrackDescriptors = [:]
      historyPlaybackRangesByTrack = [:]
    }
    playback.playbackTrackIDs = historyPlaybackRangesByTrack.keys
      .filter { historyPlaybackTrackDescriptors[$0] != nil }
      .sorted { lhs, rhs in
        let lhsPriority = Self.historyPlaybackTrackPriority(
          playback.playbackTrackRoles[lhs]
        )
        let rhsPriority = Self.historyPlaybackTrackPriority(
          playback.playbackTrackRoles[rhs]
        )
        return lhsPriority == rhsPriority ? lhs < rhs : lhsPriority < rhsPriority
      }
    if !playback.playbackTrackIDs.contains(playback.selectedHistoryPlaybackTrackID) {
      playback.selectedHistoryPlaybackTrackID = playback.playbackTrackIDs.first ?? ""
    }
    updateHistoryPlaybackDurationForSelectedTrack()
    loadHistoryWaveform()
    if playback.playbackTrackIDs.isEmpty {
      let sourceWasRetained =
        history.historyItems.first(where: {
          $0.sessionID == sessionID
        })?.sourceAudioRetained == true
      playback.playbackStatusMessage =
        sourceWasRetained
        ? "原音仍保留，但本机播放索引暂不可用"
        : "这条记录没有保留可播放的原音"
    } else {
      playback.playbackStatusMessage = "本机原音已就绪"
    }
    self.people.speakerIdentityStatusMessage =
      loaded.0 == nil
      ? "人物信息暂时无法读取；原音与逐字稿不受影响"
      : self.people.selectedSessionSpeakers.isEmpty
        ? "多人识别仍在本机处理中，完成后可命名人物"
        : "所有人物和声纹证据只保存在这台 Mac 上"
  }

  static func personReviewCandidates(
    from fixture: HistoryPlaybackUIFixture
  ) -> [PersonReviewCandidateSummary] {
    fixture.speakers.compactMap { speaker in
      guard speaker.associationStatus == .candidate,
        let personID = speaker.personID,
        let confidence = speaker.confidence,
        let occurrence = fixture.occurrences.first(where: {
          $0.sessionSpeakerID == speaker.id
            && $0.associationStatus == .candidate
        })
      else { return nil }
      return PersonReviewCandidateSummary(
        speakerID: speaker.id,
        sessionID: occurrence.sessionID,
        representativeOccurrenceID: occurrence.id,
        stableOrdinal: speaker.stableOrdinal,
        candidatePersonID: personID,
        candidateDisplayName: speaker.displayName,
        confidence: confidence,
        monotonicStartNanoseconds: occurrence.monotonicStartNanoseconds,
        monotonicEndNanoseconds: occurrence.monotonicEndNanoseconds,
        speechDurationNanoseconds: speaker.speechDurationNanoseconds,
        occurrenceCount: speaker.occurrenceCount
      )
    }
  }
}
