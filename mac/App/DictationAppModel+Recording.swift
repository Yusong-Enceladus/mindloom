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



// Recording: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  func recordSystemInterruption(
    for interruptedSnapshot: DictationSessionSnapshot
  ) async {
    guard interruptedSnapshot.phase == .paused,
      let sessionID = interruptedSnapshot.sessionID,
      let repository,
      systemInterruptionEvents[sessionID] == nil
    else { return }
    let startedAt =
      interruptedSnapshot.timeline.last(where: {
        $0.kind == .paused
      })?.monotonicNanoseconds ?? DispatchTime.now().uptimeNanoseconds
    guard let revision = try? Revision(max(1, interruptedSnapshot.revision))
    else { return }
    let eventID = TimelineEventID()
    let event = TimelineEvent(
      id: eventID,
      sessionID: sessionID,
      revision: revision,
      kind: .gap,
      monotonicNanoseconds: startedAt,
      durationNanoseconds: nil
    )
    if (try? await repository.save(timelineEvent: event)) != nil {
      systemInterruptionEvents[sessionID] = (
        id: eventID,
        startedAt: startedAt,
        revision: revision
      )
    }
  }

  func startOrEndRoomRecording() {
    if lifecycleCommands.queueIfInFlight(.end, for: .roomRecording) {
      capture.roomStatusMessage = "当前操作完成后立即结束，并处理已保存的录音"
      return
    }
    if [.recording, .paused].contains(capture.roomSnapshot.phase) {
      performLifecycleCommand(mode: .roomRecording, intent: .end) { [weak self] in
        guard let self else { return }
        await endRoomRecording()
      }
    } else if Self.canStartNewDictation(from: capture.roomSnapshot.phase) {
      let sessionID = SessionID()
      performLifecycleCommand(
        mode: .roomRecording,
        intent: .start,
        preparation: { [weak self] in
          guard let self else { return }
          capture.captureWorkspaceHandoff = nil
          capture.roomSnapshot = Self.preparingCaptureSnapshot(sessionID: sessionID)
          capture.roomLiveTranscriptText = ""
          capture.roomLiveTranscriptStatus = "正在准备麦克风；开始后实时逐字稿会显示在这里"
          capture.roomStatusMessage = "正在准备所选麦克风；现在即可暂停、结束或取消"
          stopRoomLevelPreview()
        },
        operation: { [weak self] in
          await self?.startRoomRecording(sessionID: sessionID)
        }
      )
    }
  }

  // MARK: - 开始记录会议 (menu bar)

  /// The meeting the menu bar follows: a system-audio recording when one is
  /// under way, the room microphone's otherwise.
  var meetingUsesComputerSound: Bool {
    capture.systemAudioSnapshot.phase.isActive
  }

  var meetingSnapshot: DictationSessionSnapshot {
    meetingUsesComputerSound ? capture.systemAudioSnapshot : capture.roomSnapshot
  }

  var meetingCanPauseOrResume: Bool {
    meetingUsesComputerSound ? systemAudioCanPauseOrResume : roomCanPauseOrResume
  }

  var meetingCanCancel: Bool {
    meetingUsesComputerSound ? systemAudioCanCancel : roomCanCancel
  }

  /// 开始记录会议 / 结束并保存 (v12 1C, ALIGNMENT 收2-2). Starting records
  /// like the old meeting mode: with the 屏幕与系统录音 permission, the
  /// computer's sound (the meeting App that is playing sound, chosen by
  /// itself, or what 「录：… ›」 chose; the other people in an online meeting,
  /// even on headphones) and the microphone as two tracks of one recording;
  /// without it, the room microphone, and the menu and the item say 「只录了
  /// 麦克风」. The permission is asked once, with the system's own prompt,
  /// the first time a meeting starts; the meeting starts at once either way.
  /// The source audio is journaled and kept until the user deletes it.
  func startOrEndMeetingRecording() {
    if capture.systemAudioSnapshot.phase.isActive {
      startOrEndSystemAudioRecording()
      return
    }
    if capture.roomSnapshot.phase.isActive {
      startOrEndRoomRecording()
      return
    }
    Task { [weak self] in
      guard let self else { return }
      // A read (CGPreflightScreenCaptureAccess) …
      var state = await permissionService?.state(for: .systemAudioCapture) ?? .notDetermined
      // … and, never asked before, the system's prompt, once.
      if MeetingCapturePlan.asksFirst(state), !fixtureMode, let permissionService {
        state = await permissionService.request(.systemAudioCapture)
      }
      capture.systemAudioPermission = state
      guard !capture.roomSnapshot.phase.isActive, !capture.systemAudioSnapshot.phase.isActive
      else { return }
      if MeetingCapturePlan.plan(systemAudio: state) == .computerSound, !fixtureMode {
        let meeting = MeetingState.shared
        meeting.readSources()
        meetingComputerSound = meeting.pick
        meeting.recordingPick = meeting.pick
        startOrEndSystemAudioRecording()
      } else {
        MeetingState.shared.recordingPick = nil
        startOrEndRoomRecording()
      }
    }
  }

  func pauseOrResumeMeetingRecording() {
    if meetingUsesComputerSound {
      pauseOrResumeSystemAudioRecording()
    } else {
      pauseOrResumeRoomRecording()
    }
  }

  func cancelMeetingRecording() {
    if meetingUsesComputerSound {
      cancelSystemAudioRecording()
    } else {
      cancelRoomRecording()
    }
  }

  func pauseOrResumeRoomRecording() {
    if lifecycleCommands.queueIfInFlight(.pauseOrResume, for: .roomRecording) {
      capture.roomStatusMessage = "当前操作完成后立即暂停；已保存的音频会保留"
      return
    }
    performLifecycleCommand(mode: .roomRecording, intent: .pauseOrResume) { [weak self] in
      guard let self, let roomCoordinator else { return }
      do {
        if capture.roomSnapshot.phase == .paused {
          let devices = try MicrophoneDeviceCatalog.devices()
          if devices.contains(where: { $0.uid == activeRoomMicrophoneUID }) {
            capture.roomSnapshot = try await roomCoordinator.resume()
          } else {
            let replacement = try MicrophoneDeviceCatalog.defaultDevice()
            capture.roomSnapshot = try await roomCoordinator.replacePausedCapture(
              with: AVAudioEngineMicrophoneCapture(
                sourceRole: .roomMicrophone,
                selectedDeviceUID: replacement.uid
              )
            )
            activeRoomMicrophoneUID = replacement.uid
            capture.roomStatusMessage =
              "原麦克风不可用；已切换到 \(replacement.name)，并在同一条记录中继续"
          }
          beginRoomLifecycleMonitoring(coordinator: roomCoordinator)
        } else if capture.roomSnapshot.phase == .recording {
          capture.roomSnapshot = try await roomCoordinator.pause()
          stopRoomLifecycleMonitoring()
        }
        capture.roomStatusMessage =
          capture.roomSnapshot.phase == .paused
          ? "录音已暂停；继续后仍属于同一条记录"
          : "正在使用本机麦克风录音，原始音频持续保存"
      } catch {
        capture.roomStatusMessage = "暂停或继续失败；已经保存的音频不受影响"
      }
    }
  }

  func cancelRoomRecording() {
    if lifecycleCommands.queueIfInFlight(.cancel, for: .roomRecording) {
      capture.roomStatusMessage = "当前操作完成后立即取消这次未提交录音"
      return
    }
    performLifecycleCommand(mode: .roomRecording, intent: .cancel) { [weak self] in
      guard let self, roomCanCancel, let roomCoordinator else { return }
      do {
        stopRoomLifecycleMonitoring()
        let sessionID = capture.roomSnapshot.sessionID
        capture.roomSnapshot = try await roomCoordinator.cancel()
        if let sessionID {
          await localRuntime?.clearLiveSession(sessionID: sessionID)
        }
        self.roomCoordinator = nil
        activeRoomMicrophoneUID = ""
        capture.roomLiveTranscriptText = ""
        capture.roomLiveTranscriptStatus = "录音开始后会显示本机实时逐字稿"
        capture.roomStatusMessage = "已取消这次未提交的录音"
      } catch {
        capture.roomStatusMessage = "取消将在下次启动时完成；已保存的音频会保留"
      }
    }
  }

  func setIncludeMicrophoneInSystemRecording(_ enabled: Bool) {
    guard !capture.systemAudioSnapshot.phase.isActive else { return }
    history.includeMicrophoneInSystemRecording = enabled
    systemAudioMicrophoneSelectionIsAutomatic = false
    systemAudioMicrophoneOverrides[capture.selectedSystemAudioSourceID] = enabled
    persistSystemAudioMicrophoneOverrides()
  }

  func startOrEndSystemAudioRecording() {
    if lifecycleCommands.queueIfInFlight(.end, for: .systemAudio) {
      capture.systemAudioStatusMessage = "当前操作完成后立即结束，并处理已保存的音轨"
      return
    }
    if [.recording, .paused].contains(capture.systemAudioSnapshot.phase) {
      performLifecycleCommand(mode: .systemAudio, intent: .end) { [weak self] in
        guard let self else { return }
        await endSystemAudioRecording()
      }
    } else if Self.canStartNewDictation(from: capture.systemAudioSnapshot.phase) {
      let sessionID = SessionID()
      performLifecycleCommand(
        mode: .systemAudio,
        intent: .start,
        preparation: { [weak self] in
          guard let self else { return }
          capture.captureWorkspaceHandoff = nil
          capture.systemAudioSnapshot = Self.preparingCaptureSnapshot(sessionID: sessionID)
          capture.systemAudioLiveTranscriptText = ""
          capture.systemAudioLiveTranscriptStatus = "正在准备电脑音频；开始后实时逐字稿会显示在这里"
          capture.systemAudioStatusMessage = "正在准备所选来源；现在即可暂停、结束或取消"
          stopSystemAudioPreview()
        },
        operation: { [weak self] in
          await self?.startSystemAudioRecording(sessionID: sessionID)
        }
      )
    }
  }

  func pauseOrResumeSystemAudioRecording() {
    if lifecycleCommands.queueIfInFlight(.pauseOrResume, for: .systemAudio) {
      capture.systemAudioStatusMessage = "当前操作完成后立即暂停；已保存的音轨会保留"
      return
    }
    performLifecycleCommand(mode: .systemAudio, intent: .pauseOrResume) { [weak self] in
      guard let self, let coordinator = systemAudioCoordinator else { return }
      do {
        if capture.systemAudioSnapshot.phase == .paused {
          let devices = (try? MicrophoneDeviceCatalog.devices()) ?? []
          if activeSystemIncludesMicrophone,
            !devices.contains(where: { $0.uid == activeSystemMicrophoneUID })
          {
            let replacement = try MicrophoneDeviceCatalog.defaultDevice()
            let scope: SystemAudioCaptureScope =
              activeSystemScope
              ?? (capture.selectedSystemAudioSourceID == "entire-system"
                ? .entireSystem
                : .application(identity: capture.selectedSystemAudioSourceID))
            capture.systemAudioSnapshot = try await coordinator.replacePausedCapture(
              with: SystemAudioWithMicrophoneCapture(
                scope: scope,
                microphoneDeviceUID: replacement.uid
              )
            )
            activeSystemMicrophoneUID = replacement.uid
            capture.systemAudioStatusMessage =
              "麦克风已切换到 \(replacement.name)；电脑输出和新麦克风轨继续保存"
          } else {
            capture.systemAudioSnapshot = try await coordinator.resume()
          }
          capture.systemAudioStatusMessage = "电脑内录已继续，音轨继续独立保存"
          beginSystemAudioLifecycleMonitoring(coordinator: coordinator)
        } else if capture.systemAudioSnapshot.phase == .recording {
          capture.systemAudioSnapshot = try await coordinator.pause()
          stopSystemAudioLifecycleMonitoring()
          capture.systemAudioStatusMessage = "电脑内录已暂停；已经录下的音频已保存"
        }
      } catch {
        capture.systemAudioStatusMessage =
          capture.systemAudioSnapshot.phase == .paused
          ? "所选应用仍未输出音频；请重新打开它后再继续。已经保存的音频不受影响"
          : "暂停失败；已经保存的音频不受影响"
      }
    }
  }

  func cancelSystemAudioRecording() {
    if lifecycleCommands.queueIfInFlight(.cancel, for: .systemAudio) {
      capture.systemAudioStatusMessage = "当前操作完成后立即取消这次未提交电脑内录"
      return
    }
    performLifecycleCommand(mode: .systemAudio, intent: .cancel) { [weak self] in
      guard let self, systemAudioCanCancel,
        let coordinator = systemAudioCoordinator
      else { return }
      do {
        stopSystemAudioLifecycleMonitoring()
        let sessionID = capture.systemAudioSnapshot.sessionID
        capture.systemAudioSnapshot = try await coordinator.cancel()
        if let sessionID {
          await localRuntime?.clearLiveSession(sessionID: sessionID)
        }
        systemAudioCoordinator = nil
        activeSystemMicrophoneUID = ""
        activeSystemOutputDeviceID = nil
        lastSystemSourceContextFingerprint = ""
        lastSystemSourceContextPollNanoseconds = 0
        lastSystemSourceContextPersistedNanoseconds = 0
        capture.systemAudioSourceContextMessage = ""
        capture.systemAudioLiveTranscriptText = ""
        capture.systemAudioLiveTranscriptStatus = "录制开始后会显示本机实时逐字稿"
        capture.systemAudioStatusMessage = "已取消这次未提交的电脑内录"
      } catch {
        capture.systemAudioStatusMessage = "取消将在下次启动时完成；已保存的音频会保留"
      }
    }
  }

  func startRoomRecording(sessionID: SessionID) async {
    defer {
      if capture.roomSnapshot.phase == .preparing {
        capture.roomSnapshot = DictationSessionSnapshot()
      }
    }
    guard !snapshot.phase.isActive, !capture.systemAudioSnapshot.phase.isActive,
      !capture.importInProgress
    else {
      capture.roomStatusMessage = "请先结束当前口述、电脑内录或文件导入"
      return
    }
    if let permissions = permissionService {
      capture.microphonePermission = await permissions.state(for: .microphone)
      if capture.microphonePermission == .notDetermined {
        capture.microphonePermission = await permissions.request(.microphone)
      }
    }
    guard capture.microphonePermission == .granted else {
      capture.roomStatusMessage = "需要麦克风权限；已为你打开授权入口"
      resolvePermission(.microphone)
      return
    }
    guard !fixtureMode, let journal, let repository, let localRuntime else {
      capture.roomStatusMessage = "线下录音服务暂不可用"
      return
    }
    if let disk = try? await journal.diskSpaceDecision(),
      disk.state == .hardStop
    {
      capture.roomStatusMessage = "这台 Mac 的可用空间不足 1 GB，无法开始录音。请先管理储存空间"
      return
    }
    stopRoomLevelPreview()
    let roomDevice: MicrophoneDeviceInfo
    do {
      roomDevice = try MicrophoneDeviceCatalog.device(
        uid: capture.selectedRoomMicrophoneUID.isEmpty
          ? nil : capture.selectedRoomMicrophoneUID
      )
      activeRoomMicrophoneUID = roomDevice.uid
    } catch {
      capture.roomStatusMessage = "所选麦克风目前不可用；请重新连接或选择其他设备"
      return
    }
    capture.captureWorkspaceHandoff = nil
    let roomCoordinator = DictationCaptureCoordinator(
      sessionActor: DictationSessionActor(),
      capture: AVAudioEngineMicrophoneCapture(
        sourceRole: .roomMicrophone,
        selectedDeviceUID: capture.selectedRoomMicrophoneUID.isEmpty
          ? nil : capture.selectedRoomMicrophoneUID
      ),
      journal: journal,
      repository: repository,
      inputMode: .roomMicrophone,
      committedChunkObserver: localRuntime
    )
    self.roomCoordinator = roomCoordinator
    do {
      capture.roomLiveTranscriptText = ""
      capture.roomLiveTranscriptStatus =
        models.modelRuntimeReady
        ? "正在保存第一段音频…"
        : "正在保存音频；本地识别准备完成后可从资料库转写"
      capture.roomSnapshot = try await roomCoordinator.start(
        sessionID: sessionID,
        target: nil
      )
      if let sessionID = capture.roomSnapshot.sessionID {
        await localRuntime.registerLiveSession(
          sessionID: sessionID,
          inputMode: .roomMicrophone
        )
        try await repository.setSessionSourceMetadata(
          sessionID: sessionID,
          sourceKind: SessionInputMode.roomMicrophone.rawValue,
          sourceIdentifier: roomDevice.uid,
          sourceDisplayName: roomDevice.name,
          sourceBundleID: nil
        )
      }
      beginRoomLifecycleMonitoring(coordinator: roomCoordinator)
      capture.roomStatusMessage =
        models.modelRuntimeReady
        ? "正在录音；原始音频会持续保存在这台 Mac 上"
        : "正在录音并保存原音；本地识别就绪后可从资料库继续处理"
    } catch {
      stopRoomLifecycleMonitoring()
      activeRoomMicrophoneUID = ""
      self.roomCoordinator = nil
      capture.roomStatusMessage = "线下录音未能开始；没有创建不完整记录"
    }
  }

  func endRoomRecording() async {
    guard let roomCoordinator else { return }
    stopRoomLifecycleMonitoring()
    do {
      let finalization = try await roomCoordinator.end()
      capture.roomSnapshot = finalization.snapshot
      MeetingState.shared.ended(.saving)
      guard models.modelRuntimeReady else {
        MeetingState.shared.ended(.waitingForModels)
        self.roomCoordinator = nil
        activeRoomMicrophoneUID = ""
        capture.roomLiveTranscriptStatus = "原始音频已保留；本地识别就绪后可恢复转写"
        capture.roomStatusMessage = "录音已保存；完成本地模型准备后可在资料库继续处理"
        await presentCaptureWorkspaceHandoff(
          sessionID: finalization.snapshot.sessionID,
          inputMode: .roomMicrophone,
          state: .processing,
          detail: capture.roomStatusMessage,
          organizeEvents: false
        )
        return
      }
      capture.roomStatusMessage = "录音已保存，正在本地识别和整理…"
      guard let localRuntime else {
        MeetingState.shared.ended(.waitingForModels)
        capture.roomStatusMessage = "录音已保存；本地识别服务恢复后可继续处理"
        await presentCaptureWorkspaceHandoff(
          sessionID: finalization.snapshot.sessionID,
          inputMode: .roomMicrophone,
          state: .processing,
          detail: capture.roomStatusMessage,
          organizeEvents: false
        )
        return
      }
      let outcome = try await localRuntime.process(finalization)
      try await roomCoordinator.synchronizeProcessingSnapshot(outcome.snapshot)
      capture.roomSnapshot = outcome.snapshot
      Self.meetingEnded(outcome.snapshot)
      self.roomCoordinator = nil
      activeRoomMicrophoneUID = ""
      capture.roomLiveTranscriptStatus = "最终逐字稿已保存；可在资料库查看和校对"
      capture.roomStatusMessage = "线下录音已完成；可在历史记录查看文字和人物"
      await presentCaptureWorkspaceHandoff(
        sessionID: outcome.snapshot.sessionID,
        inputMode: .roomMicrophone,
        state: outcome.snapshot.phase == .completed
          ? .completed : .needsAttention,
        detail: capture.roomStatusMessage,
        organizeEvents: true
      )
    } catch {
      if let sessionID = capture.roomSnapshot.sessionID,
        let durable = try? await repository?.load(sessionID: sessionID)
      {
        capture.roomSnapshot = durable
        try? await roomCoordinator.synchronizeProcessingSnapshot(durable)
      }
      capture.roomStatusMessage = "音频已保留；可在历史记录中重试处理"
      MeetingState.shared.ended(.failed)
      await presentCaptureWorkspaceHandoff(
        sessionID: capture.roomSnapshot.sessionID,
        inputMode: .roomMicrophone,
        state: .needsAttention,
        detail: capture.roomStatusMessage,
        organizeEvents: false
      )
    }
  }

  func startSystemAudioRecording(sessionID: SessionID) async {
    // Read once, first: an early return below never leaves it set for a
    // later 电脑内录 started from its own page.
    let meetingPick = meetingComputerSound
    let meeting = meetingPick != nil
    meetingComputerSound = nil
    defer {
      if self.capture.systemAudioSnapshot.phase == .preparing {
        self.capture.systemAudioSnapshot = DictationSessionSnapshot()
      }
    }
    stopSystemAudioPreview()
    guard !fixtureMode else {
      self.capture.systemAudioStatusMessage = "电脑内录测试环境已就绪"
      return
    }
    guard !snapshot.phase.isActive, !self.capture.roomSnapshot.phase.isActive,
      !self.capture.importInProgress
    else {
      self.capture.systemAudioStatusMessage = "请先结束当前口述、线下录音或文件导入"
      return
    }
    guard let journal, let repository, let localRuntime else {
      self.capture.systemAudioStatusMessage = "电脑内录服务暂不可用"
      return
    }
    self.capture.systemAudioPermission =
      await permissionService?.state(
        for: .systemAudioCapture
      ) ?? .notDetermined
    guard self.capture.systemAudioPermission == .granted else {
      self.capture.systemAudioStatusMessage =
        self.capture.systemAudioPermission == .restartRequired
        ? "系统已授权；请\(MindloomLaunch.reopenWords)，使电脑内录权限生效"
        : "需要“录屏与系统录音”权限；已为你打开系统授权"
      resolvePermission(.systemAudioCapture)
      return
    }
    if let disk = try? await journal.diskSpaceDecision(),
      disk.state == .hardStop
    {
      self.capture.systemAudioStatusMessage = "这台 Mac 的可用空间不足 1 GB，无法开始录制。请先管理储存空间"
      return
    }
    // 开始记录会议: the whole computer's sound, with the microphone as a
    // second track when it is allowed (the meeting's own voice).
    let includeMicrophone =
      meeting
      ? self.capture.microphonePermission == .granted
      : history.includeMicrophoneInSystemRecording
    if includeMicrophone,
      self.capture.microphonePermission != .granted
    {
      self.capture.systemAudioStatusMessage = "勾选麦克风分轨时需要麦克风权限；已为你打开授权入口"
      resolvePermission(.microphone)
      return
    }
    let scope: SystemAudioCaptureScope =
      meetingPick?.scope
      ?? (self.capture.selectedSystemAudioSourceID == "entire-system"
        ? .entireSystem
        : .application(identity: self.capture.selectedSystemAudioSourceID))
    // The source the recording names: the meeting's pick, else the page's.
    let sourceID = meetingPick?.sourceID ?? self.capture.selectedSystemAudioSourceID
    let systemMicrophoneUID: String?
    if includeMicrophone {
      guard
        let device = try? MicrophoneDeviceCatalog.device(
          uid: self.capture.selectedSystemMicrophoneUID.isEmpty
            ? nil : self.capture.selectedSystemMicrophoneUID
        )
      else {
        self.capture.systemAudioStatusMessage = "所选麦克风目前不可用；请重新连接或选择其他设备"
        return
      }
      activeSystemMicrophoneUID = device.uid
      systemMicrophoneUID = device.uid
    } else {
      activeSystemMicrophoneUID = ""
      systemMicrophoneUID = nil
    }
    self.capture.captureWorkspaceHandoff = nil
    activeSystemScope = scope
    activeSystemIncludesMicrophone = includeMicrophone
    let capture: any MicrophoneCapturePort =
      includeMicrophone
      ? SystemAudioWithMicrophoneCapture(
        scope: scope,
        microphoneDeviceUID: systemMicrophoneUID
      )
      : ProcessTapSystemAudioCapture(scope: scope)
    let coordinator = DictationCaptureCoordinator(
      sessionActor: DictationSessionActor(),
      capture: capture,
      journal: journal,
      repository: repository,
      inputMode: .systemAudio,
      committedChunkObserver: localRuntime
    )
    systemAudioCoordinator = coordinator
    do {
      self.capture.systemAudioLiveTranscriptText = ""
      self.capture.systemAudioLiveTranscriptStatus =
        models.modelRuntimeReady
        ? "正在保存第一段音频…"
        : "正在保存音轨；本地识别准备完成后可从资料库转写"
      self.capture.systemAudioSourceContextMessage = ""
      lastSystemSourceContextFingerprint = ""
      lastSystemSourceContextPollNanoseconds = 0
      lastSystemSourceContextPersistedNanoseconds = 0
      self.capture.systemAudioSnapshot = try await coordinator.start(
        sessionID: sessionID,
        target: nil
      )
      if let sessionID = self.capture.systemAudioSnapshot.sessionID {
        await localRuntime.registerLiveSession(
          sessionID: sessionID,
          inputMode: .systemAudio
        )
        let source = (self.capture.systemAudioSources + MeetingState.shared.sources).first(where: {
          $0.id == sourceID
        })
        try await repository.setSessionSourceMetadata(
          sessionID: sessionID,
          sourceKind: SessionInputMode.systemAudio.rawValue,
          sourceIdentifier: sourceID,
          sourceDisplayName: source?.displayName ?? "整个 Mac 的输出",
          sourceBundleID: source?.bundleID
        )
        if let source {
          await captureSystemSourceContext(
            sessionID: sessionID,
            source: source,
            force: true
          )
        } else {
          self.capture.systemAudioSourceContextMessage =
            "整个 Mac 模式不读取或猜测单个窗口标题"
        }
      }
      beginSystemAudioLifecycleMonitoring(coordinator: coordinator)
      activeSystemOutputDeviceID =
        try? SystemAudioOutputDeviceCatalog
        .defaultOutputDeviceID()
      if models.modelRuntimeReady {
        self.capture.systemAudioStatusMessage =
          history.includeMicrophoneInSystemRecording
          ? "正在录制电脑输出和独立麦克风音轨；原始音频持续保存"
          : "正在录制电脑输出；原始音频持续保存"
      } else {
        self.capture.systemAudioStatusMessage =
          "正在录制并保存原始音轨；本地识别就绪后可从资料库继续处理"
      }
    } catch {
      stopSystemAudioLifecycleMonitoring()
      systemAudioCoordinator = nil
      activeSystemMicrophoneUID = ""
      activeSystemOutputDeviceID = nil
      lastSystemSourceContextFingerprint = ""
      lastSystemSourceContextPollNanoseconds = 0
      lastSystemSourceContextPersistedNanoseconds = 0
      self.capture.systemAudioSourceContextMessage = ""
      let detail = String(describing: error)
      self.capture.systemAudioStatusMessage =
        detail.contains("permission") || detail.contains("denied")
        ? "未允许录制系统音频。请在“系统设置”中允许 Mindloom 后重试。"
        : "电脑内录未能开始；请刷新来源并确认所选应用仍在运行"
      if meeting {
        // A meeting is recorded whatever happens to the computer's sound
        // (durability first): the microphone alone, and it says so. Started
        // once this start command has finished (one command at a time).
        self.capture.systemAudioSnapshot = DictationSessionSnapshot()
        MeetingState.shared.recordingPick = nil
        Task { @MainActor [weak self] in self?.startOrEndRoomRecording() }
      }
    }
  }

  func endSystemAudioRecording() async {
    guard let coordinator = systemAudioCoordinator else { return }
    stopSystemAudioLifecycleMonitoring()
    do {
      let finalization = try await coordinator.end()
      capture.systemAudioSnapshot = finalization.snapshot
      MeetingState.shared.ended(.saving)
      guard models.modelRuntimeReady else {
        MeetingState.shared.ended(.waitingForModels)
        systemAudioCoordinator = nil
        activeSystemMicrophoneUID = ""
        activeSystemOutputDeviceID = nil
        capture.systemAudioLiveTranscriptStatus = "原始音轨已保留；本地识别就绪后可恢复转写"
        capture.systemAudioStatusMessage = "音轨已保存；完成本地模型准备后可在资料库继续处理"
        await presentCaptureWorkspaceHandoff(
          sessionID: finalization.snapshot.sessionID,
          inputMode: .systemAudio,
          state: .processing,
          detail: capture.systemAudioStatusMessage,
          organizeEvents: false
        )
        return
      }
      capture.systemAudioStatusMessage = "音轨已保存，正在本地识别和匹配人物…"
      guard let localRuntime else {
        MeetingState.shared.ended(.waitingForModels)
        capture.systemAudioStatusMessage = "音频已保存；本地识别服务恢复后可继续处理"
        await presentCaptureWorkspaceHandoff(
          sessionID: finalization.snapshot.sessionID,
          inputMode: .systemAudio,
          state: .processing,
          detail: capture.systemAudioStatusMessage,
          organizeEvents: false
        )
        return
      }
      let outcome = try await localRuntime.process(finalization)
      try await coordinator.synchronizeProcessingSnapshot(outcome.snapshot)
      capture.systemAudioSnapshot = outcome.snapshot
      Self.meetingEnded(outcome.snapshot)
      systemAudioCoordinator = nil
      activeSystemMicrophoneUID = ""
      activeSystemOutputDeviceID = nil
      capture.systemAudioLiveTranscriptStatus =
        "最终逐字稿已保存；可在资料库按音轨回放和校对"
      capture.systemAudioStatusMessage = "电脑内录已完成；可在历史记录查看文字、音轨和人物"
      await presentCaptureWorkspaceHandoff(
        sessionID: outcome.snapshot.sessionID,
        inputMode: .systemAudio,
        state: outcome.snapshot.phase == .completed
          ? .completed : .needsAttention,
        detail: capture.systemAudioStatusMessage,
        organizeEvents: true
      )
    } catch {
      if let sessionID = capture.systemAudioSnapshot.sessionID,
        let durable = try? await repository?.load(sessionID: sessionID)
      {
        capture.systemAudioSnapshot = durable
        try? await coordinator.synchronizeProcessingSnapshot(durable)
      }
      capture.systemAudioStatusMessage = "音频已保留；可在历史记录中重试处理"
      MeetingState.shared.ended(.failed)
      await presentCaptureWorkspaceHandoff(
        sessionID: capture.systemAudioSnapshot.sessionID,
        inputMode: .systemAudio,
        state: .needsAttention,
        detail: capture.systemAudioStatusMessage,
        organizeEvents: false
      )
    }
  }

  /// The caption strip's ending once the whole meeting was recognised
  /// again: the recomputed text, or 没能转成文字.
  static func meetingEnded(_ snapshot: DictationSessionSnapshot) {
    if snapshot.phase == .completed {
      MeetingState.shared.ended(.saved, text: snapshot.transcript?.text ?? "")
    } else {
      MeetingState.shared.ended(.failed)
    }
  }

  func renderRecordingPanel(
    snapshot override: DictationSessionSnapshot? = nil
  ) {
    if fixtureMode,
      ProcessInfo.processInfo.arguments.contains(
        "--menu-bar-content-ui-testing"
      )
    {
      return
    }
    let renderedSnapshot = override ?? snapshot
    installFnHUD()
    recordingPanel.showsCaptions = dictationCaptionsEnabled
    // Set before every render, so ⇧ (the next language) or Space shows on
    // the capsule at once.
    recordingPanel.badge = Self.hudBadge(
      dictationMode, language: spoken.activeTranslationLanguage,
      languageReady: translationEngineReady(for: spoken.activeTranslationLanguage))
    recordingPanel.render(
      renderedSnapshot,
      liveText: recordingPanelText(for: renderedSnapshot),
      facts: recordingPanelFacts(for: renderedSnapshot)
    )
  }

  func recordingPanelText(
    for renderedSnapshot: DictationSessionSnapshot
  ) -> String {
    if renderedSnapshot.phase == .completed, let delivered = deliveredDictationText,
      delivered.session == renderedSnapshot.sessionID
    {
      return delivered.text
    }
    switch renderedSnapshot.phase {
    case .polishing, .inserting, .completed, .failedRecoverable:
      return renderedSnapshot.polish?.text
        ?? renderedSnapshot.transcript?.text
        ?? liveTranscriptText
    default:
      return liveTranscriptText
    }
  }
}
