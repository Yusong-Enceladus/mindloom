import AppKit
import BestASRDictation
import BestASRMemory
import BestASRMemoryUI
import BestASRPersistence
import Combine
import SwiftUI

// OWNER: mac-capture. The menu bar extra (MAC-SPEC §3.2), a system menu:
// 开始记录会议 · 录：腾讯会议 › (or 只能录麦克风 · 允许录电脑的声音…) · DGX
// Spark 已连接 / 没连上 + 重新连接 · 打开 Mindloom · 设置…; while recording
// 正在记录会议 12:04 · 录：腾讯会议 (or 只录了麦克风) · 暂停 / 继续 · 结束并保存 ·
// 放弃这次记录… (asks first) · 隐藏字幕 / 显示字幕 (v12 1C). The label is the
// mark, or the recording capsule.

/// The meeting's elapsed time, paused spans left out; ticks once a second
/// while a meeting is recorded (M32).
@MainActor
final class MeetingClock: ObservableObject {
  static let shared = MeetingClock()
  @Published private(set) var elapsed: TimeInterval = 0
  @Published private(set) var phase: DictationPhase = .idle
  private var startedAt: Date?
  private var pausedAt: Date?
  private var pausedTotal: TimeInterval = 0
  private var timer: Timer?
  private var observer: AnyCancellable?

  func attach(_ model: DictationAppModel) {
    guard observer == nil else { return }
    // The meeting is the room microphone's recording or the computer's
    // sound (开始记录会议 records that when it may); whichever runs.
    observer = model.capture.$roomSnapshot.map(\.phase)
      .combineLatest(model.capture.$systemAudioSnapshot.map(\.phase))
      .map { room, system in
        let live: Set<DictationPhase> = [.preparing, .recording, .paused]
        return live.contains(system) && !live.contains(room) ? system : room
      }
      .removeDuplicates()
      .sink { [weak self] phase in self?.follow(phase) }
  }

  var isRecording: Bool { [.preparing, .recording, .paused].contains(phase) }

  private func follow(_ next: DictationPhase) {
    let now = Date()
    switch next {
    case .preparing, .recording:
      if startedAt == nil {
        startedAt = now
        pausedTotal = 0
      }
      if let pausedAt {
        pausedTotal += now.timeIntervalSince(pausedAt)
        self.pausedAt = nil
      }
      startTimer()
    case .paused:
      if pausedAt == nil { pausedAt = now }
    default:
      startedAt = nil
      pausedAt = nil
      pausedTotal = 0
      timer?.invalidate()
      timer = nil
      elapsed = 0
    }
    phase = next
    tick()
  }

  private func startTimer() {
    guard timer == nil else { return }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func tick() {
    guard let startedAt else { return }
    let end = pausedAt ?? Date()
    let value = max(0, end.timeIntervalSince(startedAt) - pausedTotal)
    if Int(value) != Int(elapsed) { elapsed = value }
  }
}

/// The menu bar's label: the mark as a template image, or while a meeting
/// is recorded the capsule with 「m:ss」 and the orange dot.
struct MenuBarLabel: View {
  @ObservedObject var clock = MeetingClock.shared
  @Environment(\.colorScheme) private var scheme
  private static let idle = MenuBarLabelImage.idle()

  var body: some View {
    if clock.isRecording {
      Image(nsImage: MenuBarLabelImage.recording(clock.elapsed, dark: scheme == .dark))
        .accessibilityLabel("正在记录会议 \(MenuBarClock.text(clock.elapsed))")
    } else {
      Image(nsImage: Self.idle).accessibilityLabel("Mindloom")
    }
  }
}

struct MenuBarContentView: View {
  @ObservedObject var model: DictationAppModel
  @ObservedObject private var clock = MeetingClock.shared
  @ObservedObject private var meeting = MeetingState.shared
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    let rows = MenuBarExtraRow.rows(
      link: MemoryScreenModel.link(model), recording: recording, meeting: model.meetingMenu,
      demo: MindloomLaunch.isDemo)
    // fn needs 设备控制和数据访问: said first until it is allowed (review of 10-6).
    FnAccessibilityMenuRows(model: model, onboarding: model.onboarding)
    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
      switch row {
      case .separator:
        Divider()
      case .header(let title, _, let detail, _):
        Text(detail.map { "\(title)  \($0)" } ?? title)
      case .submenu(let id, let title, let symbol, let options):
        if id == "recent" {
          // 最近记录 › — the latest records, each to copy or to see in 历史.
          Menu {
            recentRecords
          } label: {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
          }
        } else {
          // 录：腾讯会议 › — what the next meeting records.
          Menu(title) {
            ForEach(options, id: \.id) { option in
              Toggle(
                option.title,
                isOn: Binding(
                  get: { option.checked },
                  set: { if $0 { model.chooseMeetingSound(option.id) } }))
            }
          }
        }
      case .action(let id, let title, let symbol, _):
        if id == "settings" {
          SettingsLink { Text(title) }
            .keyboardShortcut(",", modifiers: .command)
        } else {
          Button {
            perform(id)
          } label: {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
          }
          .disabled(!enabled(id))
        }
      }
    }
    if model.fnHeldByOtherApp {
      Divider()
      Text(FnHUDHint.fnTakenLine)
    }
  }

  /// 最近记录 (v12 find): the latest five records, each to copy or to see
  /// in 历史.
  @ViewBuilder
  private var recentRecords: some View {
    let records = model.recentRecords
    if records.isEmpty {
      Text("尚无记录")
    } else {
      ForEach(records) { item in
        Menu(Self.recentTitle(item)) {
          Button("拷贝") { model.copyRecordText(item.preferredText ?? "") }
            .disabled((item.preferredText ?? "").isEmpty)
          Button("在“历史”中查看") {
            model.pendingHistoryReveal = item.sessionID.rawValue.uuidString.uppercased()
            model.requestNavigation(to: "history")
            MainWindow.show(openWindow)
          }
        }
      }
      Divider()
      Button("打开历史") {
        model.requestNavigation(to: "history")
        MainWindow.show(openWindow)
      }
    }
  }

  /// 「15:49  第一行文字」 (the line cut at 24 characters).
  static func recentTitle(_ item: DictationHistoryItem) -> String {
    let calendar = SearchClock.productCalendar
    let time = MindloomDates.clock(item.createdAt, calendar: calendar)
    let first = (item.preferredText ?? "").split(whereSeparator: \.isNewline).first
    let line = first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    let short = String(line.prefix(24))
    return time + "  " + (short.isEmpty ? "（无文字）" : short)
  }

  private var recording: MemoryCaptureIndicator? {
    guard clock.isRecording else { return nil }
    return MemoryCaptureIndicator(
      kind: .room, title: "正在记录会议", detail: MenuBarClock.text(clock.elapsed),
      paused: clock.phase == .paused, elapsed: clock.elapsed)
  }

  private func enabled(_ id: String) -> Bool {
    switch id {
    case "start": !model.snapshot.phase.isActive && !model.capture.importInProgress
    case "pause", "resume": model.meetingCanPauseOrResume
    case "discard": model.meetingCanCancel
    default: true
    }
  }

  private func perform(_ id: String) {
    switch id {
    case "start", "stop": model.startOrEndMeetingRecording()
    case "pause", "resume": model.pauseOrResumeMeetingRecording()
    case "discard": confirmDiscard()
    case "reconnect": model.reconnectRemoteOrganizer()
    case "allow-computer-sound": model.allowMeetingComputerSound()
    case "show-captions": model.showMeetingCaptions(true)
    case "hide-captions": model.showMeetingCaptions(false)
    case "open":
      model.requestNavigation(to: "home")
      MainWindow.show(openWindow)
    default: break
    }
  }

  /// 放弃这次记录？ — the recording not yet saved is deleted only after the
  /// user chose 放弃 here.
  private func confirmDiscard() {
    let alert = NSAlert()
    alert.messageText = DiscardRecordingAlert.title
    alert.informativeText = DiscardRecordingAlert.message
    alert.alertStyle = .warning
    let discard = alert.addButton(withTitle: "放弃")
    discard.hasDestructiveAction = true
    alert.addButton(withTitle: "继续记录").keyEquivalent = "\u{1b}"
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn, model.meetingCanCancel else { return }
    model.cancelMeetingRecording()
    CaptureFeedback.shared.show(MemoryToast("已放弃此次记录", icon: .symbol("trash")))
  }
}
