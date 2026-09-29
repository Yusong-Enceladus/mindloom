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

// Capture: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  /// The dictation language a translation starts from. Translating into
  /// Chinese starts from English; everything else starts from Chinese.
  nonisolated static func translationSource(for target: String) -> String {
    target == "简体中文" || target == "繁体中文" ? "英语" : "简体中文"
  }

  func startMicrophoneEarly(
    since startRequested: ContinuousClock.Instant
  ) -> EarlyMicrophoneStart? {
    guard let device = try? MicrophoneDeviceCatalog.defaultDevice() else { return nil }
    firstAudioPendingSince = startRequested
    let sessionID = SessionID()
    let capture = makeDictationCapture(deviceUID: device.uid, sessionID: sessionID)
    // Detached: the microphone must not wait for the main actor, which is
    // often busy with UI updates at the moment of the key press.
    let start = Task.detached(priority: .userInitiated) {
      try await capture.prestart(sessionID: sessionID)
    }
    return EarlyMicrophoneStart(
      sessionID: sessionID, deviceUID: device.uid, capture: capture, start: start)
  }

  /// Runs inside the global-shortcut event tap: start recording on the key
  /// press itself, before the start command is scheduled on the main actor.
  /// An unadopted microphone is discarded after a few seconds.
  func startMicrophoneAtKeyPress() {
    guard !fixtureMode, capture.microphonePermission == .granted, keyPressMicrophone == nil else {
      return
    }
    let now = ContinuousClock.now
    guard let early = startMicrophoneEarly(since: now) else { return }
    keyPressMicrophone = (early, now)
    let sessionID = early.sessionID
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard let self, let pending = self.keyPressMicrophone,
        pending.early.sessionID == sessionID
      else { return }
      self.keyPressMicrophone = nil
      self.discardEarlyMicrophone(pending.early)
    }
  }

  func takeKeyPressMicrophone(
    startRequested: ContinuousClock.Instant
  ) -> EarlyMicrophoneStart? {
    guard let pending = keyPressMicrophone else { return nil }
    keyPressMicrophone = nil
    logDictationStage("keypress-to-start", since: pending.at)
    return pending.early
  }

  /// Stops an early microphone that no session adopted. No audio from it was
  /// journaled, so nothing is saved or left behind.
  func discardEarlyMicrophone(_ early: EarlyMicrophoneStart) {
    firstAudioPendingSince = nil
    Task {
      _ = try? await early.start.value
      await early.capture.cancel()
    }
  }

  func refreshMicrophoneDevices() {
    guard !fixtureMode else {
      capture.roomMicrophoneDevices = [
        MicrophoneDeviceInfo(
          deviceID: 1,
          uid: "fixture-microphone",
          name: "内置麦克风（测试）",
          transportType: 0,
          isBuiltIn: true
        )
      ]
      return
    }
    do {
      capture.roomMicrophoneDevices = try MicrophoneDeviceCatalog.devices()
      if !capture.selectedRoomMicrophoneUID.isEmpty,
        !capture.roomMicrophoneDevices.contains(where: {
          $0.uid == capture.selectedRoomMicrophoneUID
        })
      {
        capture.selectedRoomMicrophoneUID = ""
      }
      if !capture.selectedSystemMicrophoneUID.isEmpty,
        !capture.roomMicrophoneDevices.contains(where: {
          $0.uid == capture.selectedSystemMicrophoneUID
        })
      {
        capture.selectedSystemMicrophoneUID = ""
      }
    } catch {
      capture.roomMicrophoneDevices = []
      capture.roomStatusMessage = "无法读取麦克风列表；请检查设备连接"
    }
  }

  func toggleRoomLevelPreview() {
    if capture.roomLevelPreviewActive {
      stopRoomLevelPreview(announce: true)
      return
    }
    guard capture.microphonePermission == .granted else {
      capture.roomStatusMessage = "需要麦克风权限；已为你打开授权入口"
      resolvePermission(.microphone)
      return
    }
    let monitor = AVAudioEngineMicrophoneLevelMonitor(
      selectedDeviceUID: capture.selectedRoomMicrophoneUID.isEmpty
        ? nil : capture.selectedRoomMicrophoneUID
    )
    roomLevelMonitor = monitor
    capture.roomLevelPreviewActive = true
    capture.roomStatusMessage = "正在本机预览输入音量；不会保存预览音频"
    if fixtureMode {
      capture.roomInputLevel = 0.42
      return
    }
    roomLevelTask = Task { [weak self] in
      guard let self else { return }
      do {
        let levels = try await monitor.start()
        for await level in levels {
          guard !Task.isCancelled else { return }
          capture.roomInputLevel = level
        }
      } catch {
        capture.roomLevelPreviewActive = false
        capture.roomInputLevel = 0
        capture.roomStatusMessage = "音量预览无法启动；请刷新设备或检查权限"
      }
    }
  }

  func stopRoomLevelPreview(announce: Bool = false) {
    let wasActive = capture.roomLevelPreviewActive
    roomLevelTask?.cancel()
    roomLevelTask = nil
    let monitor = roomLevelMonitor
    roomLevelMonitor = nil
    capture.roomLevelPreviewActive = false
    capture.roomInputLevel = 0
    Task { await monitor?.stop() }
    if announce, wasActive {
      capture.roomStatusMessage = "已停止音量预览；可以开始线下录音"
    }
  }

  func refreshSystemAudioSources(announce: Bool = true) {
    guard !fixtureMode else {
      capture.systemAudioSources = [
        SystemAudioSource(
          id: "bundle:com.example.meeting",
          displayName: "会议应用",
          bundleID: "com.example.meeting",
          isRunningOutput: true
        )
      ]
      return
    }
    do {
      let previousSourceIDs = capture.systemAudioSources.map(\.id)
      capture.systemAudioSources = try SystemAudioSourceCatalog.sources()
      let sourcesChanged = previousSourceIDs != capture.systemAudioSources.map(\.id)
      let selectableSources = selectableSystemAudioSources
      if !capture.systemAudioSnapshot.phase.isActive,
        capture.selectedSystemAudioSourceID != "entire-system",
        !selectableSources.contains(where: {
          $0.id == capture.selectedSystemAudioSourceID
        })
      {
        capture.selectedSystemAudioSourceID = "entire-system"
      }
      applySystemAudioMicrophonePreference(
        for: capture.selectedSystemAudioSourceID
      )
      if announce || sourcesChanged,
        let selected = capture.systemAudioSources.first(where: {
          $0.id == capture.selectedSystemAudioSourceID
        })
      {
        let expectedSourceID = selected.id
        Task { [weak self] in
          await self?.refineAutomaticMicrophonePreference(
            for: selected,
            expectedSourceID: expectedSourceID
          )
        }
      }
      if announce || sourcesChanged {
        capture.systemAudioStatusMessage =
          selectableSources.isEmpty
          ? "当前没有可选的音频应用；可以录制整个 Mac"
          : "已发现 \(selectableSources.count) 个可录制音频应用"
      }
    } catch {
      capture.systemAudioSources = []
      capture.systemAudioStatusMessage = "暂时无法读取本机音频来源；请稍后刷新"
    }
  }

  static func shouldShowSystemAudioSource(
    _ source: SystemAudioSource,
    isUserFacingApplication: Bool
  ) -> Bool {
    if isUserFacingApplication { return true }
    // A bundle-less process can still be a user-started player such as afplay,
    // but it is useful only while it is actively producing audio. Background
    // services with non-application bundle identifiers stay out of the picker,
    // even if an older build accidentally persisted them as recent sources.
    return source.bundleID == nil && source.isRunningOutput
  }

  static func applicationAudioSourceIsUserFacing(
    bundleID: String,
    activationPolicy: NSApplication.ActivationPolicy,
    resolvesToApplication: Bool
  ) -> Bool {
    guard resolvesToApplication,
      activationPolicy != .prohibited,
      !bundleID.hasPrefix("com.bestasr.app")
    else { return false }

    // Apple menu-bar agents and login/system UI components are technically
    // packaged as applications, but presenting them as recording sources makes
    // the picker look like a process inspector. Regular Apple applications
    // (Music, Safari, QuickTime, meeting clients) remain selectable. Third-party
    // menu-bar audio applications remain eligible as well.
    if bundleID.hasPrefix("com.apple."), activationPolicy != .regular {
      return false
    }
    return true
  }

  func selectSystemAudioSource(_ identifier: String) {
    guard !capture.systemAudioSnapshot.phase.isActive else { return }
    stopSystemAudioPreview()
    capture.selectedSystemAudioSourceID = identifier
    applySystemAudioMicrophonePreference(for: identifier)
    guard identifier != "entire-system",
      let source = capture.systemAudioSources.first(where: { $0.id == identifier })
    else { return }
    Task { [weak self] in
      await self?.refineAutomaticMicrophonePreference(
        for: source,
        expectedSourceID: identifier
      )
    }
    // An explicit per-source choice always wins.  Sources without an override
    // receive the safe product default: meeting Apps include the microphone;
    // media and whole-system capture record output only.
    recentSystemAudioSourceIDs.removeAll { $0 == identifier }
    recentSystemAudioSourceIDs.insert(identifier, at: 0)
    recentSystemAudioSourceIDs = Array(recentSystemAudioSourceIDs.prefix(8))
    LocalPreferenceStore.defaults.set(
      recentSystemAudioSourceIDs,
      forKey: "preferences.recent-system-audio-sources"
    )
  }

  func applySystemAudioMicrophonePreference(for identifier: String) {
    if let explicit = systemAudioMicrophoneOverrides[identifier] {
      history.includeMicrophoneInSystemRecording = explicit
      systemAudioMicrophoneSelectionIsAutomatic = false
    } else {
      let source = capture.systemAudioSources.first(where: { $0.id == identifier })
      history.includeMicrophoneInSystemRecording =
        source.map(
          Self.isLikelyMeetingSource
        ) ?? false
      systemAudioMicrophoneSelectionIsAutomatic = true
    }
    LocalPreferenceStore.defaults.set(
      history.includeMicrophoneInSystemRecording,
      forKey: "preferences.system-audio-include-microphone"
    )
  }

  func persistSystemAudioMicrophoneOverrides() {
    LocalPreferenceStore.defaults.set(
      systemAudioMicrophoneOverrides,
      forKey: "preferences.system-audio-microphone-overrides.v1"
    )
    LocalPreferenceStore.defaults.set(
      history.includeMicrophoneInSystemRecording,
      forKey: "preferences.system-audio-include-microphone"
    )
  }

  static func isLikelyMeetingSource(_ source: SystemAudioSource) -> Bool {
    let identity = "\(source.bundleID ?? "") \(source.displayName)".lowercased()
    return [
      "wemeet", "tencentmeeting", "tencent meeting", "腾讯会议",
      "zoom.us", "zoom", "microsoft teams", "webex", "feishu",
      "lark", "dingtalk", "钉钉", "飞书",
    ].contains(where: identity.contains)
  }

  func refineAutomaticMicrophonePreference(
    for source: SystemAudioSource,
    expectedSourceID: String
  ) async {
    guard systemAudioMicrophoneOverrides[expectedSourceID] == nil,
      capture.selectedSystemAudioSourceID == expectedSourceID,
      !Self.isLikelyMeetingSource(source),
      let revision = try? Revision(1),
      let context = await sourceContextAdapterRegistry.snapshot(
        source: source,
        sessionID: SessionID(),
        revision: revision,
        monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds
      ), let title = context.displayTitle?.lowercased(),
      Self.isLikelyMeetingWindowTitle(title)
    else { return }
    // Browser capture remains App-wide.  A visible meeting title is only used
    // to choose the reversible microphone default; it never narrows the audio
    // boundary or becomes identity evidence.
    history.includeMicrophoneInSystemRecording = true
    systemAudioMicrophoneSelectionIsAutomatic = true
    LocalPreferenceStore.defaults.set(
      true,
      forKey: "preferences.system-audio-include-microphone"
    )
  }

  func toggleSystemAudioPreview() {
    if self.capture.systemAudioPreviewActive {
      stopSystemAudioPreview(announce: true)
      return
    }
    guard !self.capture.systemAudioSnapshot.phase.isActive else { return }
    guard self.capture.systemAudioPermission == .granted else {
      self.capture.systemAudioStatusMessage =
        self.capture.systemAudioPermission == .restartRequired
        ? "系统已授权；请退出并重新打开织机后再预听"
        : "请先允许“屏幕与系统音频录制”权限"
      resolvePermission(.systemAudioCapture)
      return
    }
    self.capture.systemAudioPreviewActive = true
    self.capture.systemAudioPreviewLevel = 0
    self.capture.systemAudioStatusMessage = "正在预听输出电平；此操作不保存音频"
    let previewID = UUID()
    systemAudioPreviewID = previewID
    if fixtureMode {
      self.capture.systemAudioPreviewLevel = 0.42
      return
    }
    let scope: SystemAudioCaptureScope =
      self.capture.selectedSystemAudioSourceID == "entire-system"
      ? .entireSystem
      : .application(identity: self.capture.selectedSystemAudioSourceID)
    let capture = ProcessTapSystemAudioCapture(scope: scope)
    systemAudioPreviewCapture = capture
    systemAudioPreviewTask = Task { [weak self, capture] in
      guard let self else { return }
      do {
        _ = try await capture.prepare(sessionID: SessionID())
        let chunks = await capture.chunks()
        try await capture.start()
        for await chunk in chunks {
          guard !Task.isCancelled else { break }
          let level = Self.float32RMS(chunk.bytes)
          self.capture.systemAudioPreviewLevel = min(1, level * 8)
        }
      } catch {
        if !Task.isCancelled, self.systemAudioPreviewID == previewID {
          self.capture.systemAudioStatusMessage =
            "无法预听所选来源；请确认它正在发声并允许系统音频权限"
        }
      }
      await capture.cancel()
      if self.systemAudioPreviewID == previewID {
        self.systemAudioPreviewID = nil
        self.systemAudioPreviewCapture = nil
        self.capture.systemAudioPreviewActive = false
        self.capture.systemAudioPreviewLevel = 0
      }
    }
  }

  func stopSystemAudioPreview(announce: Bool = false) {
    let wasActive = self.capture.systemAudioPreviewActive
    systemAudioPreviewTask?.cancel()
    systemAudioPreviewTask = nil
    let capture = systemAudioPreviewCapture
    systemAudioPreviewID = nil
    systemAudioPreviewCapture = nil
    self.capture.systemAudioPreviewActive = false
    self.capture.systemAudioPreviewLevel = 0
    Task { await capture?.cancel() }
    if announce, wasActive {
      self.capture.systemAudioStatusMessage = "已停止电脑输出音量预览；可以开始电脑内录"
    }
  }

  func openSystemAudioPermissionSettings() {
    openPermissionSettings(.systemAudioCapture)
  }

  func chooseAndImportMedia() {
    guard !capture.importInProgress, importOpenPanel == nil else { return }
    guard models.modelRuntimeReady else {
      capture.importStatusMessage = "请先完成本地语音识别组件准备"
      return
    }
    guard !snapshot.phase.isActive, !capture.roomSnapshot.phase.isActive,
      !capture.systemAudioSnapshot.phase.isActive
    else {
      capture.importStatusMessage = "请先结束正在进行的口述或录音"
      return
    }
    let panel = NSOpenPanel()
    panel.title = "选择要在本机处理的音频或视频"
    panel.prompt = "导入"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = [.audio, .audiovisualContent, .movie]
      + MediaImportFormats.extensions.sorted().compactMap { UTType(filenameExtension: $0) }
    importOpenPanel = panel
    let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
      guard let self else { return }
      let source = response == .OK ? panel?.url : nil
      importOpenPanel = nil
      if let source { importMedia(source) }
    }
    let application = NSApplication.shared
    let parent = Self.importPresentationWindow(
      keyWindow: application.keyWindow,
      mainWindow: application.mainWindow,
      windows: application.windows
    )
    if let parent {
      application.activate()
      parent.makeKeyAndOrderFront(nil)
      panel.beginSheetModal(for: parent, completionHandler: finish)
    } else {
      panel.begin(completionHandler: finish)
    }
  }

  static func importPresentationWindow(
    keyWindow: NSWindow?, mainWindow: NSWindow?, windows: [NSWindow]
  ) -> NSWindow? {
    // Main/key can both be nil while the existing workspace is inactive.
    // Ignore utility panels and find that visible workspace before allowing
    // AppKit to create an independent chooser on another display.
    ([keyWindow, mainWindow].compactMap { $0 } + windows).first {
      $0.isVisible && $0.canBecomeMain && !($0 is NSPanel)
    }
  }

  func importMedia(_ source: URL) {
    guard !capture.importInProgress else {
      capture.importStatusMessage = "已有文件正在处理；完成或取消后再导入下一份"
      return
    }
    guard models.modelRuntimeReady else {
      capture.importStatusMessage = "请先完成本地语音识别组件准备"
      return
    }
    guard !snapshot.phase.isActive, !capture.roomSnapshot.phase.isActive,
      !capture.systemAudioSnapshot.phase.isActive
    else {
      capture.importStatusMessage = "请先结束正在进行的口述或录音"
      return
    }
    guard MediaImportFormats.extensions.contains(source.pathExtension.lowercased()),
      IntakeProcessor.canDecodeMedia(source)
    else {
      capture.importStatusMessage =
        "这台 Mac 无法解码这个文件；请选择常见的音频或视频（如 M4A、MP3、WAV、MP4、MOV）"
      return
    }
    startImport(source)
  }

  func toggleImportPause() {
    guard capture.importInProgress, capture.importPauseControlAvailable else {
      capture.importStatusMessage = "源音频已安全提取；当前本地识别阶段会自动完成，也可停止后从资料库继续"
      return
    }
    let wantsPaused = importPauseIntent.toggle()
    capture.importPaused = wantsPaused
    capture.importStatusMessage =
      wantsPaused
      ? "正在暂停；已完成的导入进度不会丢失…"
      : "正在继续同一份本地导入…"
    enqueueImportPauseSynchronization()
  }

  func cancelImport() {
    guard capture.importInProgress else { return }
    importCancellationShouldDiscard = capture.importCanDiscard
    startupRecoverySessionIDs = Self.recoverySessionIDsAfterStoppingImport(
      startupRecoverySessionIDs,
      sessionID: importSessionID,
      canDiscard: importCancellationShouldDiscard
    )
    recoveryItemCount = startupRecoverySessionIDs.count
    capture.importStatusMessage =
      capture.importCanDiscard
      ? "正在取消未完成的导入；原始外部文件不会被修改…"
      : "正在停止本地处理；已保留的原文件、音频与进度会留在资料库…"
    capture.importPauseControlAvailable = false
    importPauseIntent.reset()
    capture.importPaused = false
    Task { await importPauseGate.setPaused(false) }
    importTask?.cancel()
  }

  func enqueueImportPauseSynchronization() {
    let previous = importPauseControlTask
    importPauseControlTask = Task { @MainActor [weak self] in
      await previous?.value
      guard let self else { return }
      _ = await synchronizeImportPauseIntent()
    }
  }

  @discardableResult
  func synchronizeImportPauseIntent() async
    -> DictationSessionSnapshot?
  {
    guard capture.importInProgress else {
      await importPauseGate.setPaused(false)
      return nil
    }
    let desiredPause = importPauseIntent.wantsPaused
    guard let actor = importSessionActor,
      let sessionID = importSessionID,
      let repository,
      let journal
    else {
      await importPauseGate.setPaused(desiredPause)
      if desiredPause, importPauseIntent.wantsPaused == desiredPause {
        capture.importStatusMessage = "正在准备本地导入；准备完成后会保持暂停"
      }
      return nil
    }

    let current = await actor.currentSnapshot()
    let action = importPauseIntent.action(for: current.phase)
    if desiredPause {
      // Stop the decoder before committing the pause marker so no later audio
      // chunk can cross the durable pause boundary.
      await importPauseGate.setPaused(true)
    } else if action != .resume {
      await importPauseGate.setPaused(false)
    }
    do {
      let updated: DictationSessionSnapshot
      switch action {
      case .waitForPreparation:
        if importPauseIntent.wantsPaused == desiredPause {
          capture.importPaused = true
          capture.importStatusMessage = "正在准备本地导入；准备完成后会保持暂停"
        }
        return current
      case .pause:
        updated = try await actor.handle(.pause)
        if let marker = updated.timeline.last {
          try await journal.append(sessionID: sessionID, marker: marker)
        }
        try await repository.save(updated)
      case .resume:
        // Keep the decoder stopped until the resumed marker and snapshot are
        // durable. This preserves the ordering of timeline evidence and audio.
        await importPauseGate.setPaused(true)
        updated = try await actor.handle(.resume)
        if let marker = updated.timeline.last {
          try await journal.append(sessionID: sessionID, marker: marker)
        }
        try await repository.save(updated)
        await importPauseGate.setPaused(false)
      case .none:
        updated = current
      case .unavailable:
        await importPauseGate.setPaused(false)
        if importPauseIntent.wantsPaused == desiredPause {
          importPauseIntent.reset()
          capture.importPaused = false
          capture.importPauseControlAvailable = false
          capture.importStatusMessage =
            "源音频已安全提取；正在完成本地识别与整理，可停止后从资料库继续"
        }
        return current
      }
      if importPauseIntent.wantsPaused == desiredPause {
        capture.importPaused = updated.phase == .paused
        capture.importStatusMessage =
          updated.phase == .paused
          ? "导入已暂停；原始文件和已完成进度均已保留"
          : "继续以快于实时的速度在本机处理…"
      }
      return updated
    } catch {
      let actual = await actor.currentSnapshot()
      let actuallyPaused = actual.phase == .paused
      await importPauseGate.setPaused(actuallyPaused)
      if importPauseIntent.wantsPaused == desiredPause {
        importPauseIntent.setPaused(actuallyPaused)
        capture.importPaused = actuallyPaused
        capture.importStatusMessage =
          actuallyPaused
          ? "导入已经暂停；状态记录尚未完全写入，原文件和已完成进度仍保留"
          : "暂停状态未能保存；处理已安全继续"
      }
      return actual
    }
  }

  func finishImportPauseableStage() async {
    await importPauseControlTask?.value
    capture.importPauseControlAvailable = false
    importPauseIntent.reset()
    capture.importPaused = false
    await importPauseGate.setPaused(false)
  }

  static func recoverySessionIDsAfterStoppingImport(
    _ current: Set<SessionID>,
    sessionID: SessionID?,
    canDiscard: Bool
  ) -> Set<SessionID> {
    guard !canDiscard, let sessionID else { return current }
    var updated = current
    updated.insert(sessionID)
    return updated
  }

  func resumeInterruptedImport(_ item: DictationHistoryItem) {
    guard let decoder = importedMediaDecoder,
      let fileStore = importedMediaFileStore,
      let repository,
      let journal,
      let localRuntime,
      importTask == nil
    else {
      history.historyStatusMessage = "本地导入恢复服务暂不可用"
      return
    }
    capture.captureWorkspaceHandoff = nil
    history.retryingHistorySessionID = item.sessionID
    capture.importInProgress = true
    capture.importPaused = false
    capture.importPauseControlAvailable = true
    // This is an existing Library record with retained source evidence. A stop
    // during recovery must never turn into deletion of the record the user is
    // explicitly trying to recover.
    capture.importCanDiscard = false
    importCancellationShouldDiscard = false
    importPauseIntent.reset()
    capture.importProgress = 0
    capture.importedFilename = nil
    history.historyStatusMessage = "正在从已校验的本地原文件继续导入…"
    capture.importStatusMessage = "正在恢复上次安全落盘的位置…"
    importTask = Task { [weak self] in
      guard let self else { return }
      await importPauseGate.setPaused(false)
      defer {
        history.retryingHistorySessionID = nil
        capture.importInProgress = false
        capture.importPaused = false
        capture.importPauseControlAvailable = false
        capture.importCanDiscard = false
        importPauseIntent.reset()
        importTask = nil
        importSessionActor = nil
        importSessionID = nil
        Task { await self.importPauseGate.setPaused(false) }
        if let refusal = startNextQueuedMediaImport() { intake.show(refusal) }
      }
      do {
        guard let durable = try await repository.load(sessionID: item.sessionID)
        else { throw CocoaError(.fileReadNoSuchFile) }
        let actor = DictationSessionActor(initialSnapshot: durable)
        importSessionActor = actor
        importSessionID = item.sessionID
        let recovery = try await journal.recover(sessionID: item.sessionID)
        if recovery.state == .stoppedForDiskPressure {
          let disk = try await journal.diskSpaceDecision()
          guard disk.state != .hardStop else {
            throw CocoaError(.fileWriteOutOfSpace)
          }
          try await journal.resumeAfterRecoverableStop(
            sessionID: item.sessionID
          )
        }
        let ranges: [AudioRangeInput]
        let recognizing: DictationSessionSnapshot
        if recovery.state == .sealed {
          await finishImportPauseableStage()
          capture.importCanDiscard = false
          ranges = recovery.ranges
          recognizing = durable
        } else {
          let assets = try await repository.retainedSourceAssets(
            sessionID: item.sessionID
          )
          guard let retained = assets.last(where: { $0.kind == .importedOriginal })
          else { throw CocoaError(.fileReadNoSuchFile) }
          capture.importedFilename = retained.originalFilename
          let retainedURL = try await fileStore.verifiedURL(for: retained)
          let inspection = try await decoder.inspect(
            url: retainedURL,
            sessionID: item.sessionID
          )
          guard let track = inspection.descriptor.tracks?.first else {
            throw ImportedMediaDecoderError.unsupportedAudioFormat
          }
          let progress = try await journal.trackProgress(
            sessionID: item.sessionID,
            trackID: track.id
          )
          if durable.phase == .preparing {
            let recording = try await actor.handle(.preparationSucceeded)
            try await repository.save(recording)
          } else if durable.phase == .paused {
            let recording = try await actor.handle(.resume)
            if let marker = recording.timeline.last {
              try await journal.append(sessionID: item.sessionID, marker: marker)
            }
            try await repository.save(recording)
          }
          _ = await synchronizeImportPauseIntent()
          capture.importProgress = min(
            0.55,
            Double(progress.committedFrameCount)
              / Double(max(1, inspection.totalFrames)) * 0.55
          )
          _ = try await decoder.decode(
            url: retainedURL,
            sessionID: item.sessionID,
            startingFrame: progress.committedFrameCount,
            startingSequence: progress.committedChunkCount,
            onChunk: { [journal, pauseGate = importPauseGate] chunk in
              await pauseGate.waitIfPaused()
              try Task.checkCancellation()
              try await journal.append(sessionID: item.sessionID, chunk: chunk)
            },
            onProgress: { [weak self] progress in
              Task { @MainActor [weak self] in
                self?.capture.importProgress = progress.fractionCompleted * 0.55
                self?.capture.importStatusMessage =
                  "正在从已保存位置继续解码 \(Int(progress.fractionCompleted * 100))%"
              }
            }
          )
          await finishImportPauseableStage()
          capture.importCanDiscard = false
          let finalizing = try await actor.handle(.end)
          if let marker = finalizing.timeline.last {
            try await journal.append(sessionID: item.sessionID, marker: marker)
          }
          try await repository.save(finalizing)
          ranges = try await journal.seal(sessionID: item.sessionID)
          recognizing = try await actor.handle(.journalSealed)
          try await repository.save(recognizing)
        }
        capture.importProgress = 0.6
        capture.importStatusMessage = "源文件已完整恢复，正在本地识别和匹配人物…"
        let outcome = try await localRuntime.process(
          DictationCaptureFinalization(snapshot: recognizing, audio: ranges)
        )
        try Task.checkCancellation()
        try await actor.synchronizeProcessingSnapshot(outcome.snapshot)
        try Task.checkCancellation()
        try await repository.markRecovered(sessionID: item.sessionID)
        capture.importProgress = 1
        capture.importStatusMessage = "导入已从中断位置恢复完成"
        history.historyStatusMessage = "文件导入已完整恢复"
        history.statusFilter = Self.historyFilterAfterRecovery(
          history.statusFilter, recoveredSessionID: item.sessionID,
          selectedSessionID: history.selectedHistorySessionID
        )
        startupRecoverySessionIDs.remove(item.sessionID)
        recoveryItemCount = startupRecoverySessionIDs.count
        await refreshHistoryItems(
          preserveStatus: true,
          organizeEvents: true,
          completingRecoverySessionID: item.sessionID
        )
        await refreshSelectedSpeakerDetails(sessionID: item.sessionID)
      } catch is CancellationError {
        if !importCancellationShouldDiscard,
          let durable = try? await repository.load(sessionID: item.sessionID)
        {
          capture.importStatusMessage =
            "本地处理已停止；原文件、已提取音频和进度都保留在资料库，可稍后继续"
          await presentCaptureWorkspaceHandoff(
            sessionID: item.sessionID,
            inputMode: .importedMedia,
            state: .needsAttention,
            detail: capture.importStatusMessage,
            organizeEvents: false
          )
          registerRetainedImportForRecovery(
            sessionID: item.sessionID,
            snapshot: durable
          )
          await refreshHistoryItems(
            preserveStatus: true, completingRecoverySessionID: item.sessionID
          )
        } else {
          if let actor = importSessionActor {
            await cancelIncompleteImport(
              sessionID: item.sessionID,
              actor: actor,
              repository: repository,
              journal: journal
            )
          }
          capture.importProgress = 0
          capture.importStatusMessage = "恢复中的导入已取消；外部原文件未被修改"
          await refreshHistoryItems(completingRecoverySessionID: item.sessionID)
        }
      } catch {
        if let durable = try? await repository.load(sessionID: item.sessionID) {
          registerRetainedImportForRecovery(
            sessionID: item.sessionID,
            snapshot: durable
          )
        }
        capture.importStatusMessage =
          (error as? CocoaError)?.code == .fileWriteOutOfSpace
          ? "可用空间仍低于 1 GB 安全线；恢复尚未开始，原文件和进度完整保留"
          : "恢复中断；本地原文件和已提交进度仍保留，可再次继续"
        history.historyStatusMessage = "恢复未完成；源文件和进度仍保留"
        await refreshHistoryItems(
          preserveStatus: true, completingRecoverySessionID: item.sessionID
        )
      }
    }
  }

  func beginRoomLifecycleMonitoring(
    coordinator: DictationCaptureCoordinator
  ) {
    stopRoomLifecycleMonitoring()
    let expectedUID = activeRoomMicrophoneUID
    roomLifecycleTask = Task { [weak self, weak coordinator] in
      guard let self, let coordinator else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled,
          self.roomCoordinator === coordinator,
          self.capture.roomSnapshot.phase == .recording
        else { return }
        if let permissions = self.permissionService {
          let state = await permissions.state(for: .microphone)
          if state != .granted {
            self.capture.microphonePermission = state
            self.capture.roomSnapshot =
              (try? await coordinator.pause()) ?? self.capture.roomSnapshot
            self.capture.roomStatusMessage =
              "麦克风权限在录音中被撤销；已自动暂停，已提交原音完整保留。重新允许后可继续或直接结束"
            self.capture.roomLiveTranscriptStatus = "权限撤销前的逐字稿已保留"
            return
          }
        }
        let deviceStillPresent =
          (try? MicrophoneDeviceCatalog.devices())?
          .contains(where: { $0.uid == expectedUID }) == true
        let captureFailure = await coordinator.captureTerminalFailure()
        guard !deviceStillPresent || captureFailure != nil else { continue }
        do {
          self.capture.roomSnapshot = try await coordinator.pause()
          if captureFailure?.code == "disk-hard-stop" {
            self.capture.roomStatusMessage =
              "可用空间已到安全下限；线下录音已自动暂停，所有已提交音频完整保留。释放空间后可继续，或直接结束处理"
          } else if !deviceStillPresent,
            let replacement = try? MicrophoneDeviceCatalog.defaultDevice()
          {
            self.capture.roomSnapshot = try await coordinator.replacePausedCapture(
              with: AVAudioEngineMicrophoneCapture(
                sourceRole: .roomMicrophone,
                selectedDeviceUID: replacement.uid
              )
            )
            self.activeRoomMicrophoneUID = replacement.uid
            self.capture.roomStatusMessage =
              "录音设备发生变化；已自动切换到 \(replacement.name) 并继续，旧音轨和切换点均已保留"
            self.capture.roomLiveTranscriptStatus =
              "实时逐字稿继续追加；设备切换前的文字和原音完整保留"
            self.beginRoomLifecycleMonitoring(coordinator: coordinator)
            return
          } else if captureFailure?.category == .resourcePressure,
            let replacement = try? MicrophoneDeviceCatalog.defaultDevice()
          {
            self.capture.roomSnapshot = try await coordinator.replacePausedCapture(
              with: AVAudioEngineMicrophoneCapture(
                sourceRole: .roomMicrophone,
                selectedDeviceUID: replacement.uid
              )
            )
            self.activeRoomMicrophoneUID = replacement.uid
            self.capture.roomStatusMessage =
              "采集队列短暂过载；已自动建立新音轨并继续，过载前的音频完整保留"
            self.capture.roomLiveTranscriptStatus =
              "实时逐字稿继续追加；切换点与已有原音均已保留"
            self.beginRoomLifecycleMonitoring(coordinator: coordinator)
            return
          } else {
            self.capture.roomStatusMessage =
              "录音设备已断开；本次录音已自动暂停，已提交音频完整保留。连接任意麦克风后可继续，或直接结束并处理现有内容"
          }
          self.capture.roomLiveTranscriptStatus =
            "设备中断前的实时文字已保留；继续后会在同一记录中追加"
        } catch {
          self.capture.roomStatusMessage =
            "录音设备已断开；已提交音频完整保留。请结束本次记录并从历史中恢复处理"
        }
        return
      }
    }
  }

  func stopRoomLifecycleMonitoring() {
    roomLifecycleTask?.cancel()
    roomLifecycleTask = nil
  }

  func beginSystemAudioLifecycleMonitoring(
    coordinator: DictationCaptureCoordinator
  ) {
    stopSystemAudioLifecycleMonitoring()
    systemAudioLifecycleTask = Task { [weak self, weak coordinator] in
      guard let self, let coordinator else { return }
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled,
          self.systemAudioCoordinator === coordinator,
          self.capture.systemAudioSnapshot.phase == .recording
        else { return }
        if let permissions = self.permissionService {
          let systemState = await permissions.state(for: .systemAudioCapture)
          if systemState != .granted {
            self.capture.systemAudioPermission = systemState
            self.capture.systemAudioSnapshot =
              (try? await coordinator.pause()) ?? self.capture.systemAudioSnapshot
            self.capture.systemAudioStatusMessage =
              "系统音频权限在录制中被关闭；已自动暂停，所有已提交音轨完整保留。重新允许后可继续或直接结束"
            return
          }
        }
        if let currentOutputID =
          try? SystemAudioOutputDeviceCatalog
          .defaultOutputDeviceID()
        {
          if let previousOutputID = self.activeSystemOutputDeviceID,
            previousOutputID != currentOutputID,
            let sessionID = self.capture.systemAudioSnapshot.sessionID,
            let repository = self.repository,
            let revision = try? Revision(
              max(1, self.capture.systemAudioSnapshot.revision)
            )
          {
            try? await repository.save(
              timelineEvent: TimelineEvent(
                id: TimelineEventID(),
                sessionID: sessionID,
                revision: revision,
                kind: .deviceChanged,
                monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
                durationNanoseconds: nil
              )
            )
            self.capture.systemAudioStatusMessage =
              "系统输出设备已变更；录制仍在同一条记录中继续"
          }
          self.activeSystemOutputDeviceID = currentOutputID
        }
        if let sessionID = self.capture.systemAudioSnapshot.sessionID,
          let source = self.capture.systemAudioSources.first(where: {
            $0.id == self.capture.selectedSystemAudioSourceID
          })
        {
          await self.captureSystemSourceContext(
            sessionID: sessionID,
            source: source
          )
        }
        if self.history.includeMicrophoneInSystemRecording,
          let permissions = self.permissionService
        {
          let state = await permissions.state(for: .microphone)
          if state != .granted {
            self.capture.microphonePermission = state
            self.capture.systemAudioSnapshot =
              (try? await coordinator.pause()) ?? self.capture.systemAudioSnapshot
            self.capture.systemAudioStatusMessage =
              "麦克风权限在录制中被撤销；电脑输出与麦克风分轨已自动暂停，现有音频完整保留"
            return
          }
        }
        guard let failure = await coordinator.captureTerminalFailure() else {
          continue
        }
        if failure.code == "disk-hard-stop" {
          do {
            self.capture.systemAudioSnapshot = try await coordinator.pause()
            self.capture.systemAudioStatusMessage =
              "可用空间已到安全下限；电脑内录已自动暂停，所有已提交音轨完整保留。释放空间后可继续，或直接结束处理"
          } catch {
            self.capture.systemAudioStatusMessage =
              "空间不足导致采集停止；所有已提交音轨仍保留，请结束后从历史恢复"
          }
        } else if failure.category == .resourcePressure {
          do {
            self.capture.systemAudioSnapshot = try await coordinator.pause()
            let scope: SystemAudioCaptureScope =
              self.capture.selectedSystemAudioSourceID == "entire-system"
              ? .entireSystem
              : .application(identity: self.capture.selectedSystemAudioSourceID)
            let replacement: any MicrophoneCapturePort
            if self.history.includeMicrophoneInSystemRecording {
              let microphone = try MicrophoneDeviceCatalog.device(
                uid: self.activeSystemMicrophoneUID.isEmpty
                  ? nil : self.activeSystemMicrophoneUID
              )
              replacement = SystemAudioWithMicrophoneCapture(
                scope: scope,
                microphoneDeviceUID: microphone.uid
              )
              self.activeSystemMicrophoneUID = microphone.uid
            } else {
              replacement = ProcessTapSystemAudioCapture(scope: scope)
            }
            self.capture.systemAudioSnapshot = try await coordinator.replacePausedCapture(
              with: replacement
            )
            self.capture.systemAudioStatusMessage =
              "采集队列短暂过载；已自动建立新音轨并继续，过载前的音频完整保留"
            self.capture.systemAudioLiveTranscriptStatus =
              "实时逐字稿继续追加；切换点与已有原音均已保留"
            self.beginSystemAudioLifecycleMonitoring(coordinator: coordinator)
            return
          } catch {
            self.capture.systemAudioStatusMessage =
              "采集队列过载；已提交音轨完整保留。可直接结束并从历史恢复处理"
          }
        } else if failure.code == "microphone-device-unavailable" {
          do {
            self.capture.systemAudioSnapshot = try await coordinator.pause()
            if let replacement = try? MicrophoneDeviceCatalog.defaultDevice() {
              let scope: SystemAudioCaptureScope =
                self.capture.selectedSystemAudioSourceID == "entire-system"
                ? .entireSystem
                : .application(identity: self.capture.selectedSystemAudioSourceID)
              self.capture.systemAudioSnapshot = try await coordinator.replacePausedCapture(
                with: SystemAudioWithMicrophoneCapture(
                  scope: scope,
                  microphoneDeviceUID: replacement.uid
                )
              )
              self.activeSystemMicrophoneUID = replacement.uid
              self.capture.systemAudioStatusMessage =
                "麦克风发生变化；已自动切换到 \(replacement.name)，电脑输出和新麦克风轨已在同一记录中继续"
              self.capture.systemAudioLiveTranscriptStatus =
                "实时逐字稿继续追加；切换前的独立音轨完整保留"
              self.beginSystemAudioLifecycleMonitoring(coordinator: coordinator)
              return
            }
            self.capture.systemAudioStatusMessage =
              "麦克风设备已断开；电脑输出与麦克风分轨已自动暂停，现有音频完整保留。连接任意麦克风后可继续，或直接结束处理"
          } catch {
            self.capture.systemAudioStatusMessage =
              "麦克风设备已断开；已提交的电脑输出和麦克风音频仍完整保留，请结束后从历史恢复处理"
          }
        } else if failure.category == .targetUnavailable {
          do {
            self.capture.systemAudioSnapshot = try await coordinator.pause()
            self.capture.systemAudioStatusMessage =
              "所选应用已经退出或停止输出；录制已自动暂停，已录音频已保存。重新打开该应用后点“继续”，也可以直接结束并处理现有内容"
          } catch {
            self.capture.systemAudioStatusMessage =
              "所选应用已经退出；已录音频仍保留。请结束本次记录并从历史中恢复处理"
          }
        } else {
          self.capture.systemAudioStatusMessage =
            "电脑音频采集已停止；已录音频仍保留，请结束后从历史中恢复处理"
        }
        return
      }
    }
  }

  func stopSystemAudioLifecycleMonitoring() {
    systemAudioLifecycleTask?.cancel()
    systemAudioLifecycleTask = nil
  }

  func captureSystemSourceContext(
    sessionID: SessionID,
    source: SystemAudioSource,
    force: Bool = false
  ) async {
    let now = DispatchTime.now().uptimeNanoseconds
    if !force, now >= lastSystemSourceContextPollNanoseconds,
      now - lastSystemSourceContextPollNanoseconds < 2_000_000_000
    {
      return
    }
    lastSystemSourceContextPollNanoseconds = now
    guard let repository,
      let revision = try? Revision(max(1, capture.systemAudioSnapshot.revision)),
      let context = await sourceContextAdapterRegistry.snapshot(
        source: source,
        sessionID: sessionID,
        revision: revision,
        monotonicNanoseconds: now
      )
    else { return }
    let fingerprint = [
      context.adapterID,
      context.meetingTitle ?? "",
      context.windowTitle ?? "",
      context.participantDisplayNames.joined(separator: "\u{1f}"),
      context.activeSpeakerDisplayName ?? "",
    ].joined(separator: "\u{1e}")
    let isHeartbeatDue =
      now >= lastSystemSourceContextPersistedNanoseconds
      && now - lastSystemSourceContextPersistedNanoseconds >= 4_000_000_000
    guard
      force || fingerprint != lastSystemSourceContextFingerprint
        || isHeartbeatDue
    else { return }
    lastSystemSourceContextFingerprint = fingerprint
    do {
      try await repository.saveSourceContext(context)
      lastSystemSourceContextPersistedNanoseconds = now
      if let title = context.displayTitle {
        try? await repository.setAutomaticSessionTitle(
          sessionID: sessionID,
          from: title
        )
      }
      let participantDetail =
        context.participantDisplayNames.isEmpty
        ? ""
        : " · 本地读取到 \(context.participantDisplayNames.count) 位参会者"
      let speakerDetail =
        context.activeSpeakerDisplayName.map {
          " · 当前发言：\($0)"
        } ?? ""
      capture.systemAudioSourceContextMessage =
        "来源说明：\(context.displayTitle ?? source.displayName)\(participantDetail)\(speakerDetail)"
    } catch {
      // Optional metadata must never alter or stop the durable capture path.
      capture.systemAudioSourceContextMessage =
        "来源说明暂不可用；录音和匿名说话人处理仍正常继续"
    }
  }

  func startImport(_ source: URL) {
    guard
      let decoder = importedMediaDecoder,
      let fileStore = importedMediaFileStore,
      let repository,
      let journal,
      let localRuntime
    else {
      capture.importStatusMessage = "本地导入服务暂不可用"
      return
    }
    capture.captureWorkspaceHandoff = nil
    capture.importInProgress = true
    capture.importPaused = false
    capture.importPauseControlAvailable = true
    capture.importCanDiscard = true
    importCancellationShouldDiscard = true
    importPauseIntent.reset()
    capture.importProgress = 0
    capture.importedFilename = source.lastPathComponent
    capture.importStatusMessage = "正在校验媒体并创建可恢复的本地任务…"
    // Set only when intake routed this file here; a file chosen in the import
    // panel keeps its filename as the label.
    let intakeSource = pendingImportSourceApplication
    pendingImportSourceApplication = nil
    let sessionID = SessionID()
    let actor = DictationSessionActor()
    importSessionID = sessionID
    importSessionActor = actor
    importTask = Task { [weak self] in
      guard let self else { return }
      await importPauseGate.setPaused(false)
      defer {
        capture.importInProgress = false
        capture.importPaused = false
        capture.importPauseControlAvailable = false
        capture.importCanDiscard = false
        importPauseIntent.reset()
        importTask = nil
        importSessionActor = nil
        importSessionID = nil
        Task { await self.importPauseGate.setPaused(false) }
        // Audio/video that arrived through intake waits here, one at a time.
        if let refusal = startNextQueuedMediaImport() { intake.show(refusal) }
      }
      do {
        let inspection = try await decoder.inspect(
          url: source,
          sessionID: sessionID
        )
        let sourceSize = UInt64(
          max(
            0,
            try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
          ))
        guard let track = inspection.descriptor.tracks?.first else {
          throw ImportedMediaDecoderError.unsupportedAudioFormat
        }
        let bytesPerSample: UInt64 =
          track.encoding == .float32LittleEndian
          ? 4 : 2
        let framesResult = inspection.totalFrames.multipliedReportingOverflow(
          by: UInt64(track.channelCount)
        )
        let decodedResult = framesResult.partialValue.multipliedReportingOverflow(
          by: bytesPerSample
        )
        let workingResult = sourceSize.addingReportingOverflow(
          decodedResult.partialValue
        )
        let requiredResult = workingResult.partialValue.addingReportingOverflow(
          1_073_741_824
        )
        let availableBytes = try VolumeDiskSpaceMonitor().availableBytes(
          at: journal.assetRootURL
        )
        guard !framesResult.overflow, !decodedResult.overflow,
          !workingResult.overflow, !requiredResult.overflow,
          availableBytes > requiredResult.partialValue
        else { throw CocoaError(.fileWriteOutOfSpace) }
        let preparing = try await actor.handle(
          .start(sessionID: sessionID, target: nil)
        )
        try await repository.create(preparing, inputMode: .importedMedia)
        // A user-started import counts as live capture for the organizer
        // link (eligible only while it is on); a failure keeps it local.
        try? await repository.markLiveCaptureRemoteEligible(sessionID: sessionID)
        try await repository.setSessionSourceMetadata(
          sessionID: sessionID,
          sourceKind: SessionInputMode.importedMedia.rawValue,
          sourceIdentifier: source.lastPathComponent,
          sourceDisplayName: intakeSource?.name ?? source.lastPathComponent,
          sourceBundleID: intakeSource?.bundleID,
          recordingFormat: source.pathExtension.lowercased()
        )
        try await journal.create(
          sessionID: sessionID,
          descriptor: inspection.descriptor
        )
        if let tracks = inspection.descriptor.tracks {
          try await repository.saveCaptureTracks(
            sessionID: sessionID,
            tracks: tracks
          )
        }
        if let marker = preparing.timeline.last {
          try await journal.append(sessionID: sessionID, marker: marker)
        }
        let recording = try await actor.handle(.preparationSucceeded)
        try await repository.save(recording)
        _ = await synchronizeImportPauseIntent()

        let retained = try await fileStore.stage(
          source: source,
          sessionID: sessionID
        )
        try await repository.saveRetainedSourceAsset(retained)
        guard case .relativePath(let retainedPath) = retained.assetReference else {
          throw CocoaError(.fileReadCorruptFile)
        }
        let retainedURL = journal.assetRootURL.appendingPathComponent(retainedPath)
        if MediaImportFormats.isVideo(source.pathExtension) {
          // Keyframes (no model: scene changes in small grey frames) become
          // image items under this recording; the audio stays on this Mac.
          capture.importStatusMessage = "正在取视频画面…"
          await takeVideoKeyframes(
            retainedURL, parent: sessionID, videoName: source.lastPathComponent,
            capturedAt: Date(), source: intakeSource)
        }
        capture.importStatusMessage = "正在本机解码；速度取决于文件长度和这台 Mac…"
        _ = try await decoder.decode(
          url: retainedURL,
          sessionID: sessionID,
          onChunk: { [journal, pauseGate = importPauseGate] chunk in
            await pauseGate.waitIfPaused()
            try Task.checkCancellation()
            try await journal.append(sessionID: sessionID, chunk: chunk)
          },
          onProgress: { [weak self] progress in
            Task { @MainActor [weak self] in
              self?.capture.importProgress = progress.fractionCompleted * 0.55
              self?.capture.importStatusMessage =
                "正在本机解码 \(Int(progress.fractionCompleted * 100))%"
            }
          }
        )
        await finishImportPauseableStage()
        capture.importCanDiscard = false
        let finalizing = try await actor.handle(.end)
        if let marker = finalizing.timeline.last {
          try await journal.append(sessionID: sessionID, marker: marker)
        }
        try await repository.save(finalizing)
        let ranges = try await journal.seal(sessionID: sessionID)
        let recognizing = try await actor.handle(.journalSealed)
        try await repository.save(recognizing)
        capture.importProgress = 0.6
        capture.importStatusMessage = "解码完成，正在运行本地识别、人物匹配和整理…"
        let outcome = try await localRuntime.process(
          DictationCaptureFinalization(snapshot: recognizing, audio: ranges)
        )
        try Task.checkCancellation()
        try await actor.synchronizeProcessingSnapshot(outcome.snapshot)
        try Task.checkCancellation()
        startupRecoverySessionIDs.remove(sessionID)
        recoveryItemCount = startupRecoverySessionIDs.count
        capture.importProgress = 1
        capture.importStatusMessage = "导入处理完成；可在历史记录查看、搜索和导出"
        await presentCaptureWorkspaceHandoff(
          sessionID: outcome.snapshot.sessionID,
          inputMode: .importedMedia,
          state: outcome.snapshot.phase == .completed
            ? .completed : .needsAttention,
          detail: capture.importStatusMessage,
          organizeEvents: true
        )
      } catch is CancellationError {
        if !importCancellationShouldDiscard,
          let durable = try? await repository.load(sessionID: sessionID)
        {
          capture.importStatusMessage =
            "本地处理已停止；原文件、已提取音频和进度都保留在资料库，可稍后继续"
          await presentCaptureWorkspaceHandoff(
            sessionID: sessionID,
            inputMode: .importedMedia,
            state: .needsAttention,
            detail: capture.importStatusMessage,
            organizeEvents: false
          )
          registerRetainedImportForRecovery(
            sessionID: sessionID,
            snapshot: durable
          )
          await refreshHistoryItems(preserveStatus: true)
        } else {
          await cancelIncompleteImport(
            sessionID: sessionID,
            actor: actor,
            repository: repository,
            journal: journal
          )
          capture.importStatusMessage = "未完成的导入已取消；外部原始文件未被修改"
          capture.importProgress = 0
        }
      } catch {
        if (error as? CocoaError)?.code == .fileWriteOutOfSpace {
          capture.importStatusMessage =
            "空间不足以同时保留原文件、解码音频和 1 GB 安全余量；没有删除或覆盖任何已有数据"
          await refreshHistoryItems()
          return
        }
        if let durable = try? await repository.load(sessionID: sessionID),
          durable.phase.isActive
        {
          registerRetainedImportForRecovery(
            sessionID: sessionID,
            snapshot: durable
          )
          capture.importStatusMessage =
            "导入中断；已复制的原始文件和处理进度保留在本机，可从历史恢复"
          await presentCaptureWorkspaceHandoff(
            sessionID: sessionID,
            inputMode: .importedMedia,
            state: .needsAttention,
            detail: capture.importStatusMessage,
            organizeEvents: false
          )
        } else {
          await cancelIncompleteImport(
            sessionID: sessionID,
            actor: actor,
            repository: repository,
            journal: journal
          )
          capture.importStatusMessage = "媒体格式无法读取；外部原始文件未被修改"
          await refreshHistoryItems()
        }
      }
    }
  }

  func registerRetainedImportForRecovery(
    sessionID: SessionID,
    snapshot: DictationSessionSnapshot
  ) {
    guard snapshot.phase.isActive else { return }
    startupRecoverySessionIDs.insert(sessionID)
    recoveryItemCount = startupRecoverySessionIDs.count
  }

  func cancelIncompleteImport(
    sessionID: SessionID,
    actor: DictationSessionActor,
    repository: GRDBDictationStore,
    journal: ProductionAudioJournal
  ) async {
    if let snapshot = try? await repository.load(sessionID: sessionID),
      [.preparing, .recording, .paused].contains(snapshot.phase)
    {
      _ = try? await actor.handle(.cancel)
      try? await journal.cancelEphemeral(sessionID: sessionID)
      try? await repository.cancelEphemeral(sessionID: sessionID)
      _ = try? await actor.handle(.cancellationCompleted)
    }
  }

  func reconcileLegacySourceAudioIndex() async {
    if let task = legacySourceAudioIndexTask {
      await task.value
      return
    }
    guard let repository, let journal else { return }
    let task = Task { [weak self] in
      guard let self,
        let sessions = try? await repository.sessionsMissingSourceAudioIndex()
      else { return }
      for sessionID in sessions where attemptedLegacySourceAudioIndex.insert(sessionID).inserted {
        guard !Task.isCancelled else { return }
        // A capture-start failure can legitimately have no journal. It must
        // not hide other records or acquire an invented zero/ASR/wall-clock
        // duration. Explicit Refresh or relaunch can retry missing metadata;
        // source-only deletion is independently checked inside the store.
        try? await journal.synchronizeSourceIndex(sessionID: sessionID)
      }
    }
    legacySourceAudioIndexTask = task
    await task.value
    legacySourceAudioIndexTask = nil
  }
}
