import AppKit
import BestASRDictation
import SwiftUI

private enum MenuBarDestructiveAction {
  case dictation
  case roomRecording
  case systemAudio
  case mediaImport
}

struct MenuBarContentView: View {
  @ObservedObject var model: DictationAppModel
  @Environment(\.openWindow) private var openWindow
  @State private var pendingDestructiveAction: MenuBarDestructiveAction?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(model.menuBarStatusMessage, systemImage: model.menuBarSymbol)
        .font(.headline)
        .accessibilityIdentifier("bestASR.menuStatus")
      if model.snapshot.phase.isActive {
        HStack {
          if model.canPauseOrResume {
            Button(model.startEndTitle) { model.startOrEnd() }
              .accessibilityLabel(model.startEndTitle)
              .accessibilityIdentifier("bestASR.menu.dictation.end")
            // Resume, never pause. Nothing offers to pause a dictation any
            // more; this is only here to release one the system paused for
            // the user — on sleep, on lock, or when the microphone went away.
            if model.snapshot.phase == .paused {
              Button("继续") { model.pauseOrResume() }
                .accessibilityLabel("继续口述")
                .accessibilityIdentifier("bestASR.menu.dictation.resume")
            }
          } else {
            ProgressView().controlSize(.small)
            Text(
              model.snapshot.phase == .preparing
                ? "正在准备麦克风" : "正在完成本次口述"
            )
            .foregroundStyle(.secondary)
          }
          if model.canCancel {
            Button("放弃本次口述…", role: .destructive) {
              pendingDestructiveAction = .dictation
            }
            .accessibilityLabel("放弃本次口述")
            .accessibilityIdentifier("bestASR.menu.dictation.discard")
          }
        }
      } else if model.capture.roomSnapshot.phase.isActive {
        HStack {
          if model.roomCanPauseOrResume {
            Button("结束线下录音") { model.startOrEndRoomRecording() }
              .accessibilityLabel("结束线下录音")
              .accessibilityIdentifier("bestASR.menu.room.end")
            Button(model.capture.roomSnapshot.phase == .paused ? "继续" : "暂停") {
              model.pauseOrResumeRoomRecording()
            }
            .accessibilityLabel(
              model.capture.roomSnapshot.phase == .paused ? "继续线下录音" : "暂停线下录音"
            )
            .accessibilityIdentifier("bestASR.menu.room.pauseResume")
            Button("删除本次未完成录音…", role: .destructive) {
              pendingDestructiveAction = .roomRecording
            }
            .accessibilityLabel("删除本次未完成线下录音")
            .accessibilityIdentifier("bestASR.menu.room.discard")
            .disabled(!model.roomCanCancel)
          } else {
            ProgressView().controlSize(.small)
            Text("正在处理线下录音").foregroundStyle(.secondary)
          }
        }
      } else if model.capture.systemAudioSnapshot.phase.isActive {
        HStack {
          if model.systemAudioCanPauseOrResume {
            Button("结束电脑内录") { model.startOrEndSystemAudioRecording() }
              .accessibilityLabel("结束电脑内录")
              .accessibilityIdentifier("bestASR.menu.systemAudio.end")
            Button(model.capture.systemAudioSnapshot.phase == .paused ? "继续" : "暂停") {
              model.pauseOrResumeSystemAudioRecording()
            }
            .accessibilityLabel(
              model.capture.systemAudioSnapshot.phase == .paused ? "继续电脑内录" : "暂停电脑内录"
            )
            .accessibilityIdentifier("bestASR.menu.systemAudio.pauseResume")
            Button("删除本次未完成录音…", role: .destructive) {
              pendingDestructiveAction = .systemAudio
            }
            .accessibilityLabel("删除本次未完成电脑内录")
            .accessibilityIdentifier("bestASR.menu.systemAudio.discard")
            .disabled(!model.systemAudioCanCancel)
          } else {
            ProgressView().controlSize(.small)
            Text("正在处理电脑内录").foregroundStyle(.secondary)
          }
        }
      } else if model.capture.importInProgress {
        HStack {
          Button(model.capture.importPaused ? "继续导入" : "暂停导入") {
            model.toggleImportPause()
          }
          .accessibilityLabel(model.capture.importPaused ? "继续导入" : "暂停导入")
          .accessibilityIdentifier("bestASR.menu.import.pauseResume")
          Button("取消导入…", role: .destructive) {
            pendingDestructiveAction = .mediaImport
          }
          .accessibilityLabel("取消导入")
          .accessibilityIdentifier("bestASR.menu.import.discard")
        }
      } else if let handoff = model.capture.captureWorkspaceHandoff {
        VStack(alignment: .leading, spacing: 8) {
          Text(handoff.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("bestASR.menu.handoff.detail")
          HStack {
            Button("打开这条记录") {
              model.openCaptureWorkspaceHandoff()
              openWindow(id: "main")
              NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .accessibilityLabel("打开这条记录")
            .accessibilityIdentifier("bestASR.menu.handoff.openRecord")
            Button("开始下一条") {
              model.dismissCaptureWorkspaceHandoff()
            }
            .accessibilityLabel("开始下一条")
            .accessibilityIdentifier("bestASR.menu.handoff.next")
          }
        }
      } else {
        Button("\(model.startEndTitle)  \(model.startEndShortcutTitle)") {
          model.startOrEndFromMenuBar()
        }
        .accessibilityLabel(model.startEndTitle)
        .accessibilityIdentifier("bestASR.menuStartEnd")
        Button("开始线下录音") { model.startOrEndRoomRecording() }
          .accessibilityLabel("开始线下录音")
          .accessibilityIdentifier("bestASR.menu.room.start")
        Button("录制电脑声音…") { openSection("systemAudio") }
          .accessibilityLabel("录制电脑声音")
          .accessibilityIdentifier("bestASR.menu.systemAudio.open")
        Button("导入音视频…") { model.chooseAndImportMedia() }
          .accessibilityLabel("导入音视频")
          .accessibilityIdentifier("bestASR.menu.import.open")
      }
      if let pendingDestructiveAction,
        destructiveActionIsAvailable(pendingDestructiveAction)
      {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
          Text(destructiveActionMessage(pendingDestructiveAction))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("bestASR.menu.destructive.message")
          HStack {
            Button("确认删除", role: .destructive) {
              performDestructiveAction(pendingDestructiveAction)
              self.pendingDestructiveAction = nil
            }
            .accessibilityLabel("确认删除")
            .accessibilityIdentifier("bestASR.menu.destructive.confirm")
            Button("继续保留") {
              self.pendingDestructiveAction = nil
            }
            .accessibilityLabel("继续保留")
            .accessibilityIdentifier("bestASR.menu.destructive.keep")
          }
        }
      }
      Divider()
      if !model.history.homeRecentHistoryItems.isEmpty {
        Text("最近记录")
          .font(.caption)
          .foregroundStyle(.secondary)
        ForEach(model.history.homeRecentHistoryItems.prefix(3)) { item in
          Button {
            model.openHistoryItem(item)
            openSection("history")
          } label: {
            HStack {
              Text(item.title).lineLimit(1)
              Spacer()
              Text(item.updatedAt, style: .time)
                .foregroundStyle(.secondary)
            }
          }
        }
        Divider()
      }
      Button("打开织机…") { openWindow(id: "main") }
        .accessibilityIdentifier("bestASR.menu.openApp")
      SettingsLink { Text("设置…") }
        .accessibilityIdentifier("bestASR.menu.settings")
      Button("退出织机") { NSApplication.shared.terminate(nil) }
        .accessibilityIdentifier("bestASR.menu.quit")
    }
    .padding(14)
    .frame(width: 340)
  }

  private func openSection(_ identifier: String) {
    model.requestNavigation(to: identifier)
    openWindow(id: "main")
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  private func destructiveActionMessage(
    _ action: MenuBarDestructiveAction
  ) -> String {
    switch action {
    case .dictation:
      "只删除这次尚未提交的口述录音和临时文字；已有资料库内容不变。"
    case .roomRecording:
      "只删除这次尚未提交的线下录音；已完成的记录和原音不变。"
    case .systemAudio:
      "只删除这次尚未提交的系统与麦克风音轨；已完成的记录不变。"
    case .mediaImport:
      "只删除这次未完成的处理进度；你选择的原始文件和已有资料库内容不变。"
    }
  }

  private func performDestructiveAction(_ action: MenuBarDestructiveAction) {
    switch action {
    case .dictation:
      model.cancel()
    case .roomRecording:
      model.cancelRoomRecording()
    case .systemAudio:
      model.cancelSystemAudioRecording()
    case .mediaImport:
      model.cancelImport()
    }
  }

  private func destructiveActionIsAvailable(
    _ action: MenuBarDestructiveAction
  ) -> Bool {
    switch action {
    case .dictation:
      model.snapshot.phase.isActive
    case .roomRecording:
      model.capture.roomSnapshot.phase.isActive
    case .systemAudio:
      model.capture.systemAudioSnapshot.phase.isActive
    case .mediaImport:
      model.capture.importInProgress
    }
  }
}
