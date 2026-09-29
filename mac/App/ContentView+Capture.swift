import AppKit
import BestASRCore
import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRPersistence
import Dispatch
import SwiftUI

// Capture: moved out of ContentView.swift without change.
extension ContentView {
  /// Only a capture that is still happening. A finished one is a record in
  /// the library, not a state the app should keep announcing: the card that
  /// used to sit here said a dictation had completed, offered to open it, and
  /// occupied the top of the home page until it was dismissed by hand.
  var activeCaptureSection: BestASRSection? {
    if model.snapshot.phase.isActive { return .home }
    if model.capture.roomSnapshot.phase.isActive { return .roomRecording }
    if model.capture.systemAudioSnapshot.phase.isActive { return .systemAudio }
    if model.capture.importInProgress { return .importMedia }
    return nil
  }

  var activeCaptureIsPaused: Bool {
    model.snapshot.phase == .paused
      || model.capture.roomSnapshot.phase == .paused
      || model.capture.systemAudioSnapshot.phase == .paused
      || model.capture.importPaused
  }

  var activeCaptureSidebarTitle: String {
    if model.snapshot.phase.isActive {
      return captureSidebarTitle(
        phase: model.snapshot.phase,
        recording: "正在口述",
        paused: "口述已暂停"
      )
    }
    if model.capture.roomSnapshot.phase.isActive {
      return captureSidebarTitle(
        phase: model.capture.roomSnapshot.phase,
        recording: "正在录音",
        paused: "线下录音已暂停"
      )
    }
    if model.capture.systemAudioSnapshot.phase.isActive {
      return captureSidebarTitle(
        phase: model.capture.systemAudioSnapshot.phase,
        recording: "正在内录",
        paused: "电脑内录已暂停"
      )
    }
    if model.capture.importInProgress {
      return activeCaptureIsPaused ? "文件处理已暂停" : "正在处理文件"
    }
    return model.capture.captureWorkspaceHandoff?.title ?? "音频已保留"
  }

  var activeCaptureSidebarDetail: String {
    if model.snapshot.phase.isActive { return model.liveTranscriptStatus }
    if model.capture.roomSnapshot.phase.isActive { return model.capture.roomStatusMessage }
    if model.capture.systemAudioSnapshot.phase.isActive { return model.capture.systemAudioStatusMessage }
    if model.capture.importInProgress {
      return "\(Int(model.capture.importProgress * 100))% · \(model.capture.importStatusMessage)"
    }
    return model.capture.captureWorkspaceHandoff?.detail ?? ""
  }

  var activeCaptureSidebarTint: Color {
    if activeCaptureIsPaused { return .orange }
    if model.capture.captureWorkspaceHandoff?.state == .completed,
      !model.hasActiveCapture
    {
      return .green
    }
    if model.capture.captureWorkspaceHandoff?.state == .needsAttention,
      !model.hasActiveCapture
    {
      return .orange
    }
    if model.snapshot.phase == .recording
      || model.capture.roomSnapshot.phase == .recording
      || model.capture.systemAudioSnapshot.phase == .recording
    {
      return .red
    }
    return .accentColor
  }

  func captureSidebarTitle(
    phase: DictationPhase,
    recording: String,
    paused: String
  ) -> String {
    switch phase {
    case .preparing: "正在准备录音"
    case .recording: recording
    case .paused: paused
    case .finalizing: "正在安全保存原音"
    case .recognizing:
      model.models.modelRuntimeReady ? "正在本机识别" : "原音已保存，等待识别"
    case .polishing: "正在本机整理"
    case .inserting: "正在安全写回"
    case .cancelling: "正在取消"
    default: recording
    }
  }

  /// While the microphone is open for a dictation the hotkey started, this
  /// window shows nothing about it: the caret is in another app, the floating
  /// capsule already reports it, and a panel here with 暂停 and 结束并输入
  /// buttons asks the user to aim a pointer at a window they are not in. A
  /// dictation started from this window — 试一句 — is watched here, and so is
  /// one that has stopped recording and is still being processed, which is
  /// status worth coming back to rather than a control to press.
  /// A dictation started from the keyboard is reported by the capsule and
  /// nowhere else: this window never shows it, not while listening and not
  /// for the moment it is written. Room and system recordings and imports
  /// are watched here, and so is a dictation started from this window.
  var showsActiveCaptureWorkspace: Bool {
    guard let section = activeCaptureSection else { return false }
    return section != .home || model.dictationStartedInApp
  }

  /// The live panel for a capture that is genuinely watched in this window: a
  /// room or system recording, an import, a dictation started from here or
  /// still being processed, or the hand-off card one leaves behind.
  @ViewBuilder
  var unifiedActiveCaptureWorkspace: some View {
    if model.snapshot.phase.isActive {
      activeCaptureWorkspace(
        sourceTitle: "口述输入",
        sourceSymbol: "text.cursor",
        title: model.snapshot.phase == .preparing
          ? "正在准备麦克风"
          : (model.snapshot.phase == .paused ? "口述已暂停" : "正在听你说话"),
        status: [.preparing, .recording, .paused].contains(model.snapshot.phase)
          ? model.liveTranscriptStatus : model.statusMessage,
        transcript: model.liveTranscriptText,
        transcriptPlaceholder: "识别到的文字会在这里出现；原音正在持续保存在本机。",
        personStatus: model.people.speakerRuntimeReady
          ? "结束后可以确认是谁在说话"
          : "人物线索会随原音保留，离线能力就绪后可补全",
        finalStageTitle: "整理并写回",
        level: nil,
        snapshot: model.snapshot,
        pauseTitle: nil,
        endTitle: model.snapshot.target == nil ? "结束并保存" : "结束并输入",
        canPause: model.canPauseOrResume,
        canCancel: model.canCancel,
        pause: {},
        end: { model.startOrEnd() },
        cancel: { confirmDiscardDictation = true },
        identifier: "bestASR.main"
      )
    } else if model.capture.roomSnapshot.phase.isActive {
      activeCaptureWorkspace(
        sourceTitle: "线下录音",
        sourceSymbol: "person.2.wave.2",
        title: model.capture.roomSnapshot.phase == .paused
          ? "线下录音已暂停" : "正在记录现场声音",
        status: model.capture.roomStatusMessage,
        transcript: model.capture.roomLiveTranscriptText,
        transcriptPlaceholder: "说话后，实时逐字稿会出现在这里。",
        personStatus: model.people.speakerRuntimeReady
          ? "正在保留多人说话线索，结束后统一匹配人物"
          : "人物线索会随原音保留，离线能力就绪后可补全",
        finalStageTitle: "人物与整理",
        level: model.capture.roomInputLevel,
        snapshot: model.capture.roomSnapshot,
        pauseTitle: model.capture.roomSnapshot.phase == .paused ? "继续" : "暂停",
        endTitle: "结束并处理",
        canPause: model.roomCanPauseOrResume,
        canCancel: model.roomCanCancel,
        pause: { model.pauseOrResumeRoomRecording() },
        end: { model.startOrEndRoomRecording() },
        cancel: { confirmDiscardRoomRecording = true },
        identifier: "bestASR.room"
      )
    } else if model.capture.systemAudioSnapshot.phase.isActive {
      activeCaptureWorkspace(
        sourceTitle: "电脑内录",
        sourceSymbol: "macbook.and.iphone",
        title: model.capture.systemAudioSnapshot.phase == .paused
          ? "电脑内录已暂停" : "正在记录电脑声音",
        status: model.capture.systemAudioStatusMessage,
        transcript: model.capture.systemAudioLiveTranscriptText,
        transcriptPlaceholder: "开始说话或播放声音后，实时逐字稿会出现在这里。",
        personStatus: model.people.speakerRuntimeReady
          ? "正在分别保留对方与本机麦克风的人物线索"
          : "人物线索会随各音轨保留，离线能力就绪后可补全",
        finalStageTitle: "人物与整理",
        level: model.capture.systemAudioPreviewLevel,
        snapshot: model.capture.systemAudioSnapshot,
        pauseTitle: model.capture.systemAudioSnapshot.phase == .paused ? "继续" : "暂停",
        endTitle: "结束并处理",
        canPause: model.systemAudioCanPauseOrResume,
        canCancel: model.systemAudioCanCancel,
        pause: { model.pauseOrResumeSystemAudioRecording() },
        end: { model.startOrEndSystemAudioRecording() },
        cancel: { confirmDiscardSystemRecording = true },
        identifier: "bestASR.systemAudio"
      )
    } else if model.capture.importInProgress {
      activeImportWorkspace
    }
  }

  func activeCaptureWorkspace(
    sourceTitle: String,
    sourceSymbol: String,
    title: String,
    status: String,
    transcript: String,
    transcriptPlaceholder: String,
    personStatus: String,
    finalStageTitle: String,
    level: Double?,
    snapshot: DictationSessionSnapshot,
    /// Nil for a capture that cannot be paused — dictation no longer can.
    pauseTitle: String?,
    endTitle: String,
    canPause: Bool,
    canCancel: Bool,
    pause: @escaping () -> Void,
    end: @escaping () -> Void,
    cancel: @escaping () -> Void,
    identifier: String
  ) -> some View {
    let captureOpen = [
      DictationPhase.preparing,
      .recording,
      .paused,
    ].contains(snapshot.phase)
    let tint: Color =
      switch snapshot.phase {
      case .recording: .red
      case .paused: .orange
      default: .accentColor
      }
    let phaseTitle: String =
      switch snapshot.phase {
      case .preparing: "正在准备录音"
      case .recording, .paused: title
      case .finalizing: "正在安全保存原音"
      case .recognizing:
        model.models.modelRuntimeReady ? "正在本机识别" : "原音已保存，等待识别"
      case .polishing: "正在本机整理文字"
      case .inserting: "正在安全写回文字"
      case .cancelling: "正在移除未提交内容"
      default: title
      }
    let currentProcessingStage: Int =
      switch snapshot.phase {
      case .finalizing: 0
      case .recognizing: 1
      case .polishing, .inserting: 2
      default: 0
      }

    return VStack(alignment: .leading, spacing: 18) {
      HStack {
        Label(sourceTitle, systemImage: sourceSymbol)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Label("原音持续保存在本机", systemImage: "lock.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack(alignment: .center) {
        HStack(spacing: 10) {
          Circle()
            .fill(tint)
            .frame(width: 10, height: 10)
          Text(phaseTitle).font(.title2.bold())
        }
        Spacer()
        if captureOpen {
          TimelineView(.periodic(from: .now, by: 1)) { _ in
            Label(
              activeCaptureDurationTitle(snapshot),
              systemImage: "clock"
            )
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
          }
        } else {
          Label(
            activeCaptureDurationTitle(snapshot),
            systemImage: "clock"
          )
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        if !captureOpen {
          ProgressView().controlSize(.small)
        }
      }

      if captureOpen, let level {
        ProgressView(value: level)
          .tint(tint)
          .accessibilityLabel("当前输入音量")
          .accessibilityValue("\(Int(level * 100))%")
      }

      if captureOpen {
        VStack(alignment: .leading, spacing: 8) {
          Text("实时逐字稿")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(transcript.isEmpty ? transcriptPlaceholder : transcript)
            .font(.title3)
            .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        }
        .accessibilityIdentifier("\(identifier).liveTranscript")

        Label(personStatus, systemImage: "person.2.wave.2")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("\(identifier).peopleStatus")

        HStack(spacing: 10) {
          if let pauseTitle {
            Button(pauseTitle, action: pause)
              .disabled(!canPause)
              .accessibilityIdentifier("\(identifier).pauseResume")
          }
          Button(endTitle, action: end)
            .buttonStyle(.borderedProminent)
            .disabled(!canPause)
            .accessibilityIdentifier("\(identifier).startEnd")
          Spacer()
          Menu {
            Button("删除本次未提交内容…", role: .destructive, action: cancel)
              .accessibilityIdentifier("\(identifier).cancelAction")
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .menuStyle(.borderlessButton)
          .accessibilityLabel("更多录制操作")
          .disabled(!canCancel)
          .accessibilityIdentifier("\(identifier).cancel")
        }
      } else {
        HStack(spacing: 8) {
          captureProcessingStageChip(
            "保存原音",
            index: 0,
            currentIndex: currentProcessingStage
          )
          captureProcessingStageChip(
            "本机识别",
            index: 1,
            currentIndex: currentProcessingStage
          )
          captureProcessingStageChip(
            finalStageTitle,
            index: 2,
            currentIndex: currentProcessingStage
          )
        }
        .accessibilityIdentifier("\(identifier).processingStages")

        if !transcript.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("已保存的实时草稿")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            Text(transcript)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .topLeading)
          }
          .padding(12)
          .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
          .accessibilityIdentifier("\(identifier).liveTranscript")
        }

        Label(
          "录音已经结束；后续处理不会继续占用麦克风，原音不会被整理结果覆盖",
          systemImage: "checkmark.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if model.capture.captureWorkspaceHandoff?.sessionID == snapshot.sessionID {
          Button("打开资料库查看进度") {
            model.openCaptureWorkspaceHandoff()
          }
          .accessibilityIdentifier("\(identifier).openRecord")
        }
      }

      Text(status)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(22)
    .background(
      tint.opacity(0.08),
      in: RoundedRectangle(cornerRadius: 18)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 18)
        .stroke(tint.opacity(0.22))
    }
  }

  func captureProcessingStageChip(
    _ title: String,
    index: Int,
    currentIndex: Int
  ) -> some View {
    let complete = index < currentIndex
    let current = index == currentIndex
    return Label(
      title,
      systemImage: complete
        ? "checkmark.circle.fill"
        : current ? "ellipsis.circle.fill" : "circle"
    )
    .font(.caption)
    .foregroundStyle(complete || current ? Color.accentColor : .secondary)
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(.quaternary.opacity(0.5), in: Capsule())
  }

  var activeImportWorkspace: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Label("文件导入", systemImage: "square.and.arrow.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Label("原文件不会被修改", systemImage: "lock.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack(alignment: .center) {
        HStack(spacing: 10) {
          Circle()
            .fill(model.capture.importPaused ? Color.orange : Color.accentColor)
            .frame(width: 10, height: 10)
          Text(model.capture.importPaused ? "文件处理已暂停" : "正在本机处理")
            .font(.title2.bold())
        }
        Spacer()
        Text("\(Int(model.capture.importProgress * 100))%")
          .font(.title3.monospacedDigit().weight(.semibold))
      }
      if let importedFilename = model.capture.importedFilename {
        Text(importedFilename)
          .font(.headline)
          .lineLimit(2)
      }
      ProgressView(value: model.capture.importProgress)
        .accessibilityLabel("文件处理进度")
        .accessibilityValue("\(Int(model.capture.importProgress * 100))%")
      HStack(spacing: 8) {
        importStageChip("保留原文件", complete: model.capture.importProgress > 0)
        importStageChip("提取音频", complete: model.capture.importProgress >= 0.55)
        importStageChip("识别与整理", complete: model.capture.importProgress >= 1)
      }
      Text(model.capture.importStatusMessage)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("bestASR.import.status")
      Label(
        "逐字稿、人物和事件会进入与口述和录音相同的资料库",
        systemImage: "rectangle.stack"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      HStack {
        if model.capture.importPauseControlAvailable {
          Button(model.capture.importPaused ? "继续" : "暂停") {
            model.toggleImportPause()
          }
          .accessibilityIdentifier("bestASR.import.pauseResume")
        } else {
          Label("源音已保留，正在识别与整理", systemImage: "waveform")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Menu {
          if model.capture.importCanDiscard {
            Button("取消并删除本次处理进度…", role: .destructive) {
              confirmCancelImport = true
            }
          } else {
            Button("停止并保留到资料库…") {
              confirmCancelImport = true
            }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("更多文件处理操作")
        .accessibilityIdentifier("bestASR.import.cancel")
      }
    }
    .padding(22)
    .background(
      (model.capture.importPaused ? Color.orange : Color.accentColor).opacity(0.08),
      in: RoundedRectangle(cornerRadius: 18)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 18)
        .stroke(
          (model.capture.importPaused ? Color.orange : Color.accentColor).opacity(0.22)
        )
    }
  }

  func importStageChip(_ title: String, complete: Bool) -> some View {
    Label(
      title,
      systemImage: complete ? "checkmark.circle.fill" : "circle"
    )
    .font(.caption)
    .foregroundStyle(complete ? Color.accentColor : .secondary)
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(.quaternary.opacity(0.5), in: Capsule())
  }

  var roomRecordingView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 6) {
          Text("线下录音").font(.largeTitle.bold())
          Text("记录会议、访谈和现场交流；完成后自动进入统一人物与事件记忆。")
            .font(.title3)
            .foregroundStyle(.secondary)
        }

        if model.hasActiveCapture
          || model.capture.captureWorkspaceHandoff?.inputMode == .roomMicrophone
        {
          unifiedActiveCaptureWorkspace
        } else {
          VStack(alignment: .leading, spacing: 18) {
            Label("开始前", systemImage: "slider.horizontal.3")
              .font(.title2.bold())
            Picker("麦克风", selection: $model.capture.selectedRoomMicrophoneUID) {
              Text("系统默认麦克风").tag("")
              ForEach(model.capture.roomMicrophoneDevices) { device in
                Text(device.name).tag(device.uid)
              }
            }
            .pickerStyle(.menu)
            .disabled(model.capture.roomLevelPreviewActive)
            .accessibilityIdentifier("bestASR.room.microphone")

            HStack(spacing: 12) {
              ProgressView(value: model.capture.roomInputLevel)
                .frame(maxWidth: 360)
                .accessibilityLabel("麦克风输入音量")
                .accessibilityValue("\(Int(model.capture.roomInputLevel * 100))%")
              Button(model.capture.roomLevelPreviewActive ? "停止音量预览" : "检查音量") {
                model.toggleRoomLevelPreview()
              }
              .accessibilityIdentifier("bestASR.room.levelPreview")
              Button("刷新设备") { model.refreshMicrophoneDevices() }
                .disabled(model.capture.roomLevelPreviewActive)
            }
            Text("音量预览不会保存音频。开始后原音按小块持续写入本机。")
              .font(.caption)
              .foregroundStyle(.secondary)

            Button {
              model.startOrEndRoomRecording()
            } label: {
              Label("开始线下录音", systemImage: "record.circle")
                .font(.headline)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("bestASR.room.startEnd")
          }
          .padding(22)
          .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 18))
        }

        Text(model.capture.roomStatusMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("bestASR.room.status")

        Label(
          "原音、文字、谁在说话和时间线只保存在这台 Mac 上。",
          systemImage: "lock.shield"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      .padding(32)
      .frame(maxWidth: 920, alignment: .topLeading)
    }
    .navigationTitle("线下录音")
    .onAppear { model.refreshMicrophoneDevices() }
    .onDisappear { model.stopRoomLevelPreview() }
  }

  var systemAudioRecordingView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 6) {
          Text("电脑内录").font(.largeTitle.bold())
          Text("直接记录一个应用或整个 Mac 的声音；无需安装虚拟声卡。")
            .font(.title3)
            .foregroundStyle(.secondary)
        }

        if model.hasActiveCapture
          || model.capture.captureWorkspaceHandoff?.inputMode == .systemAudio
        {
          unifiedActiveCaptureWorkspace
        } else {
          VStack(alignment: .leading, spacing: 18) {
            HStack {
              Label("选择要记住的声音", systemImage: "speaker.wave.2")
                .font(.title2.bold())
              Spacer()
              Button("刷新来源") { model.refreshSystemAudioSources() }
                .disabled(model.capture.systemAudioPreviewActive)
                .accessibilityIdentifier("bestASR.systemAudio.refreshSources")
            }

            Picker(
              "录制来源",
              selection: Binding(
                get: { model.capture.selectedSystemAudioSourceID },
                set: { model.selectSystemAudioSource($0) }
              )
            ) {
              Label("整个 Mac 的输出", systemImage: "desktopcomputer")
                .tag("entire-system")
              if !model.runningSystemAudioSources.isEmpty {
                Section("正在发声") {
                  ForEach(model.runningSystemAudioSources) { source in
                    Label(source.displayName, systemImage: "speaker.wave.2.fill")
                      .tag(source.id)
                  }
                }
              }
              if !model.recentSystemAudioSources.isEmpty {
                Section("最近使用") {
                  ForEach(model.recentSystemAudioSources) { source in
                    Label(source.displayName, systemImage: "clock").tag(source.id)
                  }
                }
              }
              if !model.otherSystemAudioSources.isEmpty {
                Section("其他音频应用") {
                  ForEach(model.otherSystemAudioSources) { source in
                    Label(source.displayName, systemImage: "app").tag(source.id)
                  }
                }
              }
            }
            .pickerStyle(.menu)
            .disabled(model.capture.systemAudioPreviewActive)
            .accessibilityIdentifier("bestASR.systemAudio.source")

            if let guidance = model.selectedSystemAudioSourceGuidance {
              Label(guidance, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
              ProgressView(value: model.capture.systemAudioPreviewLevel)
                .frame(maxWidth: 360)
                .accessibilityLabel("所选电脑输出音量")
                .accessibilityValue("\(Int(model.capture.systemAudioPreviewLevel * 100))%")
              Button(model.capture.systemAudioPreviewActive ? "停止音量预览" : "检查音量") {
                model.toggleSystemAudioPreview()
              }
              .accessibilityIdentifier("bestASR.systemAudio.levelPreview")
              Text("不会保存预览音频")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Toggle(
              "同时把我的麦克风录成独立音轨",
              isOn: Binding(
                get: { model.history.includeMicrophoneInSystemRecording },
                set: { model.setIncludeMicrophoneInSystemRecording($0) }
              )
            )
            .accessibilityIdentifier("bestASR.systemAudio.microphoneTrack")
            if model.history.includeMicrophoneInSystemRecording {
              Picker("我的麦克风", selection: $model.capture.selectedSystemMicrophoneUID) {
                Text("系统默认麦克风").tag("")
                ForEach(model.capture.roomMicrophoneDevices) { device in
                  Text(device.name).tag(device.uid)
                }
              }
              .pickerStyle(.menu)
              .accessibilityIdentifier("bestASR.systemAudio.microphoneDevice")
            }

            if model.capture.systemAudioPermission != .granted {
              HStack {
                Label(
                  "需要“屏幕与系统音频录制”权限；织机不捕获画面。",
                  systemImage: "exclamationmark.shield"
                )
                .foregroundStyle(.orange)
                Spacer()
                Button(
                  model.capture.systemAudioPermission == .notDetermined
                    ? "允许" : "打开系统设置"
                ) {
                  model.resolvePermission(.systemAudioCapture)
                }
              }
            }

            Button {
              model.startOrEndSystemAudioRecording()
            } label: {
              Label("开始电脑内录", systemImage: "record.circle")
                .font(.headline)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("bestASR.systemAudio.startEnd")
          }
          .padding(22)
          .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 18))
        }

        if !model.capture.systemAudioSourceContextMessage.isEmpty {
          Label(
            model.capture.systemAudioSourceContextMessage,
            systemImage: "rectangle.and.text.magnifyingglass"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("bestASR.systemAudio.sourceContext")
        }

        Text(model.capture.systemAudioStatusMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("bestASR.systemAudio.status")

        Label(
          "应用选择、原始音频、逐字稿和来源信息只保留在这台 Mac 上。",
          systemImage: "lock.shield"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      .padding(32)
      .frame(maxWidth: 920, alignment: .topLeading)
    }
    .navigationTitle("电脑内录")
    .onDisappear { model.stopSystemAudioPreview() }
    .task {
      while !Task.isCancelled {
        if !model.capture.systemAudioSnapshot.phase.isActive
          && !model.capture.systemAudioPreviewActive
        {
          model.refreshSystemAudioSources(announce: false)
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  var importMediaView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 6) {
          Text("导入音视频").font(.largeTitle.bold())
          Text("把已有录音、播客和视频放进同一个本机资料库。")
            .font(.title3)
            .foregroundStyle(.secondary)
        }

        if model.hasActiveCapture
          || model.capture.captureWorkspaceHandoff?.inputMode == .importedMedia
        {
          unifiedActiveCaptureWorkspace
        } else {
          VStack(alignment: .leading, spacing: 15) {
            VStack(spacing: 10) {
              Image(systemName: importDropTargeted ? "arrow.down.doc.fill" : "waveform.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(importDropTargeted ? Color.accentColor : .secondary)
              Text(importDropTargeted ? "松开即可在本机导入" : "把音频或视频拖到这里")
                .font(.title3.bold())
              Text("支持 WAV、M4A、MP3、AAC、MP4、MOV 和 FLAC")
                .font(.callout)
                .foregroundStyle(.secondary)
              Button("选择文件…") { model.chooseAndImportMedia() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("bestASR.import.choose")
            }
            .frame(maxWidth: .infinity, minHeight: 170)
            .background(
              importDropTargeted
                ? Color.accentColor.opacity(0.12)
                : Color(nsColor: .controlBackgroundColor).opacity(0.45),
              in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                  importDropTargeted ? Color.accentColor : Color.secondary.opacity(0.45),
                  style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("文件拖放导入区")
            .accessibilityIdentifier("bestASR.import.dropZone")

            if let importedFilename = model.capture.importedFilename,
              model.capture.importProgress >= 1
            {
              Label(importedFilename, systemImage: "doc.badge.checkmark")
                .font(.headline)
                .accessibilityIdentifier("bestASR.import.filename")
            }
            Text(model.capture.importStatusMessage)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("bestASR.import.status")
          }
          .padding(22)
          .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 18))
          .dropDestination(for: URL.self) { urls, _ in
            // Same router as the rest of the window: audio/video is imported
            // here, text/images/documents become items.
            model.receiveDroppedFiles(urls)
          } isTargeted: { isTargeted in
            importDropTargeted = isTargeted
          }
        }

        Label("外部原文件只读；织机的保留副本只有在你明确删除该记录时才会删除。", systemImage: "lock.shield")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding(32)
      .frame(maxWidth: 920, alignment: .topLeading)
    }
    .navigationTitle("导入音视频")
  }

  func localTextDocumentSymbol(_ taskID: LocalTextTaskID) -> String {
    switch taskID {
    case .structuredSummary: "list.bullet.rectangle"
    case .actionItems: "checklist"
    case .chapters: "text.book.closed"
    case .decisions: "checkmark.seal"
    default: "doc.text"
    }
  }
}
