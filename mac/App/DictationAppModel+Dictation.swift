import AppKit
import BestASRAudioJournal
import BestASRDictation
import BestASRDomain
import BestASRFluidRuntime
import BestASRInference
import BestASRIntake
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

// Dictation: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  /// The volume "important usage" capacity query takes tens of milliseconds,
  /// so dictation start uses a result refreshed in the background (launch and
  /// after each dictation). A cached hard stop is always re-checked, and the
  /// journal still enforces disk pressure while recording.
  func dictationStartDiskSpaceDecision(
    _ journal: ProductionAudioJournal
  ) async -> CaptureDiskSpaceDecision? {
    if let cache = diskSpaceDecisionCache,
      cache.decision.state != .hardStop,
      ContinuousClock.now - cache.checkedAt < .seconds(300)
    {
      return cache.decision
    }
    let decision = try? await journal.diskSpaceDecision()
    if let decision { diskSpaceDecisionCache = (decision, ContinuousClock.now) }
    return decision
  }

  func makeDictationCapture(
    deviceUID: String, sessionID: SessionID
  ) -> AVAudioEngineMicrophoneCapture {
    let runtime = localRuntime
    return AVAudioEngineMicrophoneCapture(
      selectedDeviceUID: deviceUID,
      levelHandler: { [weak self] level in
        Task { @MainActor in self?.receiveDictationInputLevel(level) }
      },
      // Decode at a pause while the key is still held; reused at release when
      // nothing was said after it.
      speechPauseHandler: { event in
        Task {
          switch event {
          case .paused(let through):
            await runtime?.requestFinalSpeculation(
              sessionID: sessionID, committedThroughNanoseconds: through)
          case .resumed:
            await runtime?.cancelFinalSpeculation(sessionID: sessionID)
          }
        }
      }
    )
  }

  /// Live input level for the capsule. The first buffer of a dictation also
  /// marks when audio actually started arriving after the shortcut.
  func receiveDictationInputLevel(_ level: Float) {
    if let since = firstAudioPendingSince {
      firstAudioPendingSince = nil
      logDictationStage("start-to-first-audio", since: since)
    }
    recordingPanel.updateInputLevel(level)
  }

  /// What a hotkey press means while a dictation command is still in flight.
  /// Only while the previous dictation is being sealed does it mean "start the
  /// next one"; during a start it still means "stop this dictation", which is
  /// what a quick press-and-release does.
  nonisolated static func inFlightDictationAction(
    inFlight: CaptureLifecycleCommandState.Action?
  ) -> CaptureLifecycleCommandState.Action {
    inFlight == .end ? .start : .end
  }

  nonisolated static func canStartDictation(
    phase: DictationPhase,
    sessionID: SessionID?,
    finalizingInBackground: Set<SessionID>
  ) -> Bool {
    if canStartNewDictation(from: phase) { return true }
    // The microphone is only free once the audio has been sealed.
    guard ![.preparing, .recording, .paused].contains(phase), let sessionID else {
      return false
    }
    return finalizingInBackground.contains(sessionID)
  }

  nonisolated static func canStartNewDictation(
    from phase: DictationPhase
  ) -> Bool {
    [.idle, .cancelled, .completed, .failedRecoverable].contains(phase)
  }

  func setCapsuleSubtitlesRequireHover(_ enabled: Bool) {
    capsuleSubtitlesRequireHover = enabled
    LocalPreferenceStore.defaults.set(
      enabled, forKey: "preferences.capsule-subtitles-hover-only")
    recordingPanel.subtitlesRequireHover = enabled
  }

  /// A dictation whose audio held no speech (usually a stray key press) is
  /// finished, not interrupted: it stays retryable in history but is not
  /// counted as unfinished work.
  static func isSilentDictationFailure(code: String?) -> Bool {
    DictationFailure.isSilentTake(code: code)
  }

  /// An interrupted take whose journal never committed a chunk of audio.
  nonisolated static func isTakeWithoutAudio(_ candidate: DictationRecoveryCandidate) -> Bool {
    guard let journal = candidate.journal else { return false }
    return candidate.snapshot.phase.isActive
      && candidate.disposition != .cleanupCompleted
      && journal.committedChunkCount == 0
      && journal.issueCount == 0
  }

  func prepareRecoveryFinalization(
    snapshot durableSnapshot: DictationSessionSnapshot,
    recovery: ProductionAudioJournalRecoveryReport,
    repository: GRDBDictationStore,
    journal: ProductionAudioJournal
  ) async throws -> DictationCaptureFinalization {
    guard let sessionID = durableSnapshot.sessionID else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let actor = DictationSessionActor(initialSnapshot: durableSnapshot)
    var current = durableSnapshot

    if current.phase == .failedRecoverable {
      current = try await actor.handle(.retry)
      try await repository.save(current)
    }
    if current.phase == .preparing {
      current = try await actor.handle(.preparationSucceeded)
      try await repository.save(current)
    }
    if [.recording, .paused].contains(current.phase) {
      current = try await actor.handle(.end)
      if recovery.state != .sealed, let marker = current.timeline.last {
        try await journal.append(
          sessionID: sessionID,
          marker: marker
        )
      }
      try await repository.save(current)
    }

    let ranges =
      recovery.state == .sealed
      ? recovery.ranges
      : try await journal.seal(sessionID: sessionID)
    guard !ranges.isEmpty else { throw CocoaError(.fileReadCorruptFile) }

    if current.phase == .finalizing {
      current = try await actor.handle(.journalSealed)
      try await repository.save(current)
    }
    guard
      [
        DictationPhase.recognizing,
        .polishing,
        .inserting,
        .failedRecoverable,
      ].contains(current.phase)
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return DictationCaptureFinalization(snapshot: current, audio: ranges)
  }

  nonisolated static func functionReleaseEndsDictation(heldFor duration: Duration) -> Bool {
    duration >= functionHoldThreshold
  }

  nonisolated static func capsuleListeningCaption(
    _ mode: DictationSpokenMode,
    language: String,
    languageReady: Bool = true
  ) -> String {
    switch mode {
    case .dictate: ""
    case .translate: languageReady ? "翻译成\(language)" : "\(language)语言包未下载 · 按原文写入"
    case .command: "指令"
    }
  }

  /// Decides what a finished dictation should actually deliver. Called from
  /// the insertion path, after polish and before the text reaches the target.
  /// The dictation just finished becomes a job (a pure routing table) and
  /// the job becomes a delivery (two engines behind functions). What is
  /// left here is app state: the mode record, the panel's copy of an
  /// answer, and the language pack to ask for.
  func deliveryForDictation(
    sessionID: SessionID,
    text: String
  ) async -> DictationDelivery {
    guard let plan = spokenModePlan else { return .asIs }
    spokenModePlan = nil
    if plan.mode != .dictate, let repository {
      let mode = plan.mode.rawValue
      Task { try? await repository.recordSpokenMode(sessionID: sessionID, mode: mode) }
    }
    let chosen = spoken.translationTargetLanguageNames
    let job = SpokenJobComposer.compose(
      mode: plan.mode,
      transcript: text,
      selection: plan.selection,
      translationLanguage: Self.translationLanguage(at: plan.languageIndex, among: chosen),
      targetForSelection: { Self.defaultTranslationTarget(forSelection: $0, chosen: chosen) }
    )
    let runtime = localRuntime
    let started = ContinuousClock.now
    let produced = await SpokenJobProducer(
      translate: { text, language in
        await AppleTranslation.translate(text, intoLanguageNamed: language)
      },
      follow: { instruction, selection in
        await runtime?.follow(instruction: instruction, on: selection)
      }
    ).produce(job)
    if job != .write { logDictationStage("produce", since: started) }
    if let answer = produced.answerForPanel { commandAnswers[sessionID] = answer }
    if let language = produced.languagePackNeeded { translationInstallNeeded = language }
    return produced.delivery
  }

  /// A release can arrive while the start command is still in flight; end
  /// only once recording has actually begun.
  func finishDictationAfterStartSettles() {
    pushToTalkFinishTask?.cancel()
    pushToTalkFinishTask = Task { [weak self] in
      guard let self else { return }
      // A release that lands while the microphone is still being opened
      // must still end the dictation once it is open; dropping it left the
      // capsule listening until the next press.
      let deadline = ContinuousClock.now + .seconds(3)
      while !Task.isCancelled, ContinuousClock.now < deadline,
        self.lifecycleCommands.inFlightMode == .dictation
          || self.snapshot.phase == .preparing
      {
        try? await Task.sleep(for: .milliseconds(50))
      }
      guard !Task.isCancelled,
        [.recording, .paused].contains(self.snapshot.phase)
      else { return }
      self.startOrEnd()
    }
  }

  func publishIdleReadinessStatus() {
    guard !hasActiveCapture else { return }
    if capture.microphonePermission != .granted {
      statusMessage = "需要麦克风权限；允许后即可开始录音"
    } else if !models.modelDiscoveryComplete {
      statusMessage = "正在检查本地语音识别组件…"
    } else if !models.modelRuntimeReady {
      statusMessage =
        "麦克风已就绪；可先安全录音，完成本地组件准备后从资料库转写"
    } else if !hotkeyRegistrationAvailable {
      statusMessage = "本地口述已就绪；快捷键暂不可用，可以先使用窗口或菜单栏"
    } else if hotkeys.globeKeyConflictsWithStartShortcut {
      statusMessage =
        "按 Fn 时系统也会执行 🌐 键操作：请在 系统设置 → 键盘 把“按下 🌐 键时”设为“不执行任何操作”"
    } else if onboarding.accessibilityPermission != .granted {
      statusMessage =
        "本地口述已就绪；允许辅助功能后可自动插入任意 App，否则结果保存在历史"
    } else {
      statusMessage = "已就绪——按 \(startEndShortcutTitle) 开始本地口述"
    }
  }

  /// Recognizes, cleans up and inserts a sealed dictation without holding the
  /// lifecycle lock. Sessions are chained so their text lands in the order it
  /// was spoken, and only the session still on screen may touch the capsule.
  func finalizeInBackground(
    _ finalization: DictationCaptureFinalization,
    coordinator: DictationCaptureCoordinator,
    runtime: LocalDictationRuntime,
    endRequested: ContinuousClock.Instant
  ) {
    guard let sessionID = finalization.snapshot.sessionID else { return }
    finalizingSessionIDs.insert(sessionID)
    dictationAppLogger.info(
      "dictation finalizing in background pending=\(self.finalizingSessionIDs.count, privacy: .public)"
    )
    let previous = finalizationChain
    finalizationChain = Task { [weak self] in
      _ = await previous?.result
      guard let self else { return }
      await self.completeFinalization(
        finalization,
        coordinator: coordinator,
        runtime: runtime,
        endRequested: endRequested,
        sessionID: sessionID
      )
    }
  }

  func completeFinalization(
    _ finalization: DictationCaptureFinalization,
    coordinator: DictationCaptureCoordinator,
    runtime: LocalDictationRuntime,
    endRequested: ContinuousClock.Instant,
    sessionID: SessionID
  ) async {
    defer { finalizingSessionIDs.remove(sessionID) }
    let onScreen = { [weak self] in self?.snapshot.sessionID == sessionID }
    do {
      let outcome = try await runtime.process(finalization)
      logDictationStage("end-to-inserted", since: endRequested)
      // Only now, with the dictation delivered and the keyboard back in the
      // user's field, may the system's download prompt take the screen.
      if let language = translationInstallNeeded {
        translationInstallNeeded = nil
        installTranslationLanguage(language)
      }
      // An answer the target would not take is shown rather than lost. The
      // field decides, not the presence of a selection: an editable one gets
      // the answer typed into it like any dictation, and read-only text, a
      // PDF or nothing focused gets the panel.
      if let answer = commandAnswers.removeValue(forKey: sessionID),
        outcome.snapshot.insertion?.inserted != true
      {
        presentSpokenAnswer(
          answer,
          question: outcome.snapshot.transcript?.text ?? "",
          sessionID: sessionID
        )
      }
      copyUninsertedDictationIfNeeded(outcome.snapshot)
      if onScreen() {
        snapshot = outcome.snapshot
        publishSnapshotStatus()
      }
      // The history query and event organization take seconds on a large
      // library. They are bookkeeping for a dictation that has already been
      // inserted, so they must not hold up the next one.
      recordFinishedDictation(
        outcome.snapshot,
        sessionID: sessionID,
        coordinator: coordinator,
        state: outcome.snapshot.phase == .completed ? .completed : .needsAttention
      )
    } catch {
      let durable = try? await repository?.load(sessionID: sessionID)
      if let durable {
        try? await coordinator.synchronizeProcessingSnapshot(durable)
      }
      let recovered = durable ?? finalization.snapshot
      // Speech detection is an inference result, never permission to delete
      // captured audio. A silent take ends normally and remains in the library.
      let silent = recovered.failure?.isSilentTake == true
      let detail = silent ? "没有听到说话" : "音频已保留；可以重试完成处理"
      copyUninsertedDictationIfNeeded(
        recovered, draft: onScreen() ? liveTranscriptText : "")
      if onScreen() {
        snapshot = recovered
        statusMessage = detail
        publishSnapshotStatus()
      }
      recordFinishedDictation(
        recovered,
        sessionID: sessionID,
        coordinator: nil,
        state: silent ? .completed : .needsAttention,
        detail: detail
      )
    }
  }

  /// Automatic cleanup is limited to a positively verified empty journal.
  /// Missing, corrupt, quarantined or otherwise unknown evidence is retained.
  func cleanUpVerifiedEmptyRecoveryCandidates(
    _ candidates: [DictationRecoveryCandidate]
  ) async -> [DictationRecoveryCandidate] {
    var remaining: [DictationRecoveryCandidate] = []
    for candidate in candidates {
      if Self.isTakeWithoutAudio(candidate), let sessionID = candidate.snapshot.sessionID,
        await discardVerifiedEmptyTake(sessionID)
      {
        continue
      }
      remaining.append(candidate)
    }
    return remaining
  }

  @discardableResult
  func discardVerifiedEmptyTake(_ sessionID: SessionID) async -> Bool {
    guard let journal, let repository else { return false }
    do {
      let report = try await journal.recover(sessionID: sessionID)
      guard report.readableCommittedChunkCount == 0, report.issueCount == 0,
        report.quarantinedByteCount == 0, report.ranges.isEmpty,
        let durable = try await repository.load(sessionID: sessionID), durable.phase.isActive,
        try await repository.retainedSourceAssets(sessionID: sessionID).isEmpty
      else { return false }

      let journalRoot = await journal.journalRootURL(sessionID: sessionID)
      let sessionEntries = try FileManager.default.contentsOfDirectory(
        at: journalRoot.deletingLastPathComponent(), includingPropertiesForKeys: nil)
      guard sessionEntries.allSatisfy({ $0.lastPathComponent == "journal" }) else { return false }
      let journalEntries = try FileManager.default.contentsOfDirectory(
        at: journalRoot, includingPropertiesForKeys: nil)
      let knownEntries: Set<String> = [
        "manifest.json", "production-metadata.json", "chunks", "staging", "quarantine",
      ]
      guard journalEntries.allSatisfy({ knownEntries.contains($0.lastPathComponent) }) else {
        return false
      }
      // recover() reports newly quarantined bytes only. Previously quarantined
      // audio must also block cleanup, even after a later scan reports no issues.
      for directory in ["chunks", "staging", "quarantine"] {
        let entries = try FileManager.default.contentsOfDirectory(
          at: journalRoot.appendingPathComponent(directory), includingPropertiesForKeys: nil)
        guard entries.isEmpty else { return false }
      }
      let staged = try await journal.stageExplicitDeletion(sessionID: sessionID)
      do {
        try await repository.deleteSessionRecordsExplicitly(sessionID: sessionID)
      } catch {
        if let staged { try? await journal.rollbackExplicitDeletion(staged) }
        throw error
      }
      if let staged { try await journal.commitExplicitDeletion(staged) }
      startupRecoverySessionIDs.remove(sessionID)
      recoveryItemCount = startupRecoverySessionIDs.count
      dictationAppLogger.notice("verified empty take discarded")
      return true
    } catch {
      dictationAppLogger.notice("unverified take retained during empty-take cleanup")
      return false
    }
  }

  func beginDictationLifecycleMonitoring(
    coordinator: DictationCaptureCoordinator
  ) {
    stopDictationLifecycleMonitoring()
    dictationLifecycleTask = Task { [weak self, weak coordinator] in
      guard let self, let coordinator else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled,
          self.coordinator === coordinator,
          self.snapshot.phase == .recording
        else { return }
        if let permissions = self.permissionService {
          let state = await permissions.state(for: .microphone)
          if state != .granted {
            self.capture.microphonePermission = state
            self.snapshot = (try? await coordinator.pause()) ?? self.snapshot
            self.statusMessage =
              "麦克风权限在口述中被撤销；已自动暂停，所有已提交音频完整保留。重新允许后可继续或直接结束"
            self.liveTranscriptStatus = "权限撤销前的实时文字已保留"
            self.renderRecordingPanel()
            return
          }
        }
        guard let failure = await coordinator.captureTerminalFailure() else {
          continue
        }
        do {
          self.snapshot = try await coordinator.pause()
          if failure.code == "disk-hard-stop" {
            self.statusMessage =
              "可用空间已到安全下限；口述已自动暂停，所有已提交音频都已保留。释放空间后可继续，或直接结束处理现有内容"
          } else if failure.category == .targetUnavailable {
            if let replacementDevice = try? MicrophoneDeviceCatalog.defaultDevice() {
              self.snapshot = try await coordinator.replacePausedCapture(
                with: AVAudioEngineMicrophoneCapture(
                  selectedDeviceUID: replacementDevice.uid
                )
              )
              self.activeDictationMicrophoneUID = replacementDevice.uid
              self.statusMessage =
                "麦克风发生变化；已在同一条口述中自动切换到 \(replacementDevice.name) 并继续，切换点已记录"
              self.liveTranscriptStatus = "实时文字继续追加；切换前音频完整保留"
              self.renderRecordingPanel()
              self.beginDictationLifecycleMonitoring(coordinator: coordinator)
              return
            }
            self.statusMessage =
              "麦克风设备发生变化或已断开；口述已自动暂停，已提交音频完整保留。连接任意可用麦克风后即可继续或直接结束"
          } else if failure.category == .resourcePressure,
            let replacementDevice = try? MicrophoneDeviceCatalog.defaultDevice()
          {
            self.snapshot = try await coordinator.replacePausedCapture(
              with: AVAudioEngineMicrophoneCapture(
                selectedDeviceUID: replacementDevice.uid
              )
            )
            self.activeDictationMicrophoneUID = replacementDevice.uid
            self.statusMessage =
              "采集队列短暂过载；已自动建立新音轨并继续，过载前的音频完整保留"
            self.liveTranscriptStatus = "实时文字继续追加；切换点已记录"
            self.renderRecordingPanel()
            self.beginDictationLifecycleMonitoring(coordinator: coordinator)
            return
          } else {
            self.statusMessage =
              "音频采集已自动暂停；已提交音频完整保留，可结束后从历史恢复"
          }
          self.liveTranscriptStatus = "采集中断前的实时文字已保留"
          self.renderRecordingPanel()
        } catch {
          self.statusMessage =
            "采集已停止；所有已提交音频仍在本机，请结束后从历史恢复处理"
          self.renderRecordingPanel()
        }
        return
      }
    }
  }

  func stopDictationLifecycleMonitoring() {
    dictationLifecycleTask?.cancel()
    dictationLifecycleTask = nil
  }

  func publishSnapshotStatus() {
    switch snapshot.phase {
    case .preparing:
      statusMessage = "正在准备麦克风；不会改变当前输入焦点"
      liveTranscriptStatus = statusMessage
    case .recording:
      statusMessage = "正在使用默认麦克风聆听"
      liveTranscriptStatus =
        models.modelRuntimeReady
        ? "正在本地聆听——草稿文字还会继续更新"
        : "正在保存音频；本地识别准备完成后可转写"
    case .paused:
      statusMessage = "已暂停——可继续同一段口述"
      liveTranscriptStatus = statusMessage
    case .finalizing: statusMessage = "正在保存已确认的音频"
    case .recognizing: statusMessage = "正在等待本地转写"
    case .polishing: statusMessage = "正在进行受保护的本地格式整理"
    case .inserting: statusMessage = "正在插入到原输入位置"
    case .completed:
      statusMessage =
        snapshot.insertion?.method == .retainedForCopy
        ? retainedInsertionStatus(snapshot.insertion?.failureReason)
        : "本地口述已完成"
    case .cancelling: statusMessage = "正在取消；不会插入任何文字"
    case .cancelled: statusMessage = "已取消；临时会话已移除"
    case .failedRecoverable:
      statusMessage =
        Self.isSilentDictationFailure(code: snapshot.failure?.code)
        ? "没有听到说话；这次没有记录文字"
        : "处理失败但可恢复；源音频已保留"
    default: break
    }
    renderRecordingPanel()
  }

  /// DICT-007: whenever a dictation ends without its text in the target —
  /// retained for safety or failed during processing — the best available
  /// text goes to the clipboard with an explicit prompt, never only into
  /// history. A failure with no final text falls back to the live draft.
  func copyUninsertedDictationIfNeeded(
    _ finished: DictationSessionSnapshot,
    draft: String = ""
  ) {
    // A 指令 whose answer was shown has already put that answer on the
    // clipboard. Copying the dictation now would replace the answer with the
    // question that asked for it.
    if let sessionID = finished.sessionID, answeredSessionIDs.remove(sessionID) != nil {
      return
    }
    guard let text = Self.uninsertedClipboardText(finished, draft: draft) else { return }
    // Marked as bestASR's own copy: ⌘V in the main window does not take it in
    // again as an item labelled with another App.
    if IntakePasteboardMarks.writeOwnText(text.value, to: .general) {
      copiedRetainedSessionID = finished.sessionID
      copiedRetainedTextWasDraft = text.isDraft
    }
  }

  nonisolated static func uninsertedClipboardText(
    _ finished: DictationSessionSnapshot,
    draft: String
  ) -> (value: String, isDraft: Bool)? {
    guard finished.insertion?.inserted != true,
      finished.phase == .completed || finished.phase == .failedRecoverable
    else { return nil }
    if let final = finished.polish?.text ?? finished.transcript?.text,
      !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return (final, false)
    }
    let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard finished.phase == .failedRecoverable, !trimmedDraft.isEmpty else { return nil }
    return (trimmedDraft, true)
  }

  func retainedInsertionStatus(
    _ reason: DictationInsertionFailureReason?
  ) -> String {
    let cause: String
    switch reason {
    case .permissionDenied:
      cause = "辅助功能权限未开启"
    case .secureInput:
      cause = "密码框不接收口述"
    case .applicationChanged:
      cause = "口述期间已切换到其他 App"
    case .unavailable:
      cause = "本机引擎没有给出结果"
    case .ambiguousReservation:
      cause = "为避免重复插入没有再次写入"
    case .nowhere, .nothingToInsert, .none:
      cause = "没有找到输入位置"
    }
    return retainedTextWasCopied
      ? "\(cause)；文字已复制，按 ⌘V 粘贴"
      : "\(cause)；结果已保存在资料库"
  }

  func externalInsertionTarget(
    _ target: DictationTargetSnapshot?
  ) -> DictationTargetSnapshot? {
    Self.externalInsertionTarget(
      target,
      ownBundleIdentifier: Bundle.main.bundleIdentifier,
      ownApplicationAllowed: onboardingPracticeTargetArmed
    )
  }

  /// A dictation aimed at this app's own window is aimed at nowhere, unless
  /// the onboarding practice field is up and waiting for it.
  nonisolated static func externalInsertionTarget(
    _ target: DictationTargetSnapshot?,
    ownBundleIdentifier: String?,
    ownApplicationAllowed: Bool = false
  ) -> DictationTargetSnapshot? {
    guard let target else { return nil }
    if let ownBundleIdentifier, target.bundleIdentifier == ownBundleIdentifier,
      !ownApplicationAllowed
    {
      return nil
    }
    return target
  }

  static func fixtureTarget() -> DictationTargetSnapshot {
    DictationTargetSnapshot(
      processIdentifier: 42, bundleIdentifier: "com.bestasr.fixture", isSecure: false)
  }
}
