import AppKit
import BestASRCore
import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRMemoryUI
import BestASRPersistence
import Dispatch
import SwiftUI

enum BestASRSection: String, CaseIterable, Identifiable {
  case home
  case history
  case people
  case events
  case dictionary
  case roomRecording
  case systemAudio
  case importMedia

  var id: String { rawValue }

  var title: String {
    switch self {
    case .home: "首页"
    case .history: "历史记录"
    case .people: "人物"
    case .events: "事件"
    case .dictionary: "词典"
    case .roomRecording: "线下录音"
    case .systemAudio: "电脑内录"
    case .importMedia: "文件导入"
    }
  }

  var symbol: String {
    switch self {
    case .home: "house"
    case .history: "clock.arrow.circlepath"
    case .people: "person.2.crop.square.stack"
    case .events: "point.3.connected.trianglepath.dotted"
    case .dictionary: "character.book.closed"
    case .roomRecording: "person.2.wave.2"
    case .systemAudio: "macbook.and.iphone"
    case .importMedia: "square.and.arrow.down"
    }
  }

  static let primaryCases: [Self] = [.home, .history, .dictionary]
  static let secondaryCases: [Self] = [
    .roomRecording, .systemAudio, .importMedia, .people, .events,
  ]

  var navigationShortcut: KeyEquivalent? {
    switch self {
    case .home: "1"
    case .history: "2"
    case .dictionary: "3"
    case .people, .events, .roomRecording, .systemAudio, .importMedia: nil
    }
  }
}

enum HistoryWorkspaceTab: String, CaseIterable, Identifiable {
  case transcript
  case notes
  case memory
  case source

  var id: String { rawValue }

  var title: String {
    switch self {
    case .transcript: "逐字稿"
    case .notes: "整理"
    case .memory: "人物与事件"
    case .source: "来源"
    }
  }
}

enum HistoryFocusedField: Hashable {
  case search
  case sourceApplication
  case title
  case transcript
  case segment
  case correction
  case speaker
  case personSplit
  case document
}

struct HistoryDateGroup: Identifiable {
  let date: Date
  let items: [DictationHistoryItem]
  var id: Date { date }
}

struct PendingStructuredItemDeletion {
  let item: LocalTextStructuredItem
  let document: LocalTextDocumentRecord
}

struct PersonOccurrenceGroup: Identifiable {
  let sessionID: SessionID
  let item: DictationHistoryItem?
  let occurrences: [SpeakerOccurrenceSummary]

  var id: SessionID { sessionID }
}

enum MemoryDocumentPresentation {
  /// Generated prose is often just the same structured points with bullets.
  /// Hide only that exact repetition, never a separately edited narrative.
  static func distinctBody(_ body: String, itemTexts: [String]) -> String? {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !itemTexts.isEmpty else { return trimmed }
    func normalized(_ text: String) -> String {
      text.components(separatedBy: .newlines).map { line in
        let value = line.trimmingCharacters(in: .whitespaces)
        if ["• ", "- ", "* "].contains(where: value.hasPrefix) {
          return String(value.dropFirst(2))
        }
        return value.replacingOccurrences(
          of: #"^\d+[.)、]\s+"#, with: "", options: .regularExpression
        )
      }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    return normalized(trimmed) == normalized(itemTexts.joined(separator: "\n"))
      ? nil : trimmed
  }
}

struct ContentView: View {
  @ObservedObject var model: DictationAppModel
  @Environment(\.openWindow) var openWindow
  @State var selection = BestASRSection.home
  @StateObject var memoryScreen = MemoryScreenModel()
  @StateObject var spaces = SpacesModel()
  @State var memoryNavigation = MemoryNavigation()
  /// Which capture page the indicator (or a menu) opens when none is running.
  @State var captureSection: BestASRSection?
  @State var captureStartedAt: Date?
  @State var pendingHistoryDeletion: DictationHistoryItem?
  @State var expandedHistoryRawSessionID: SessionID?
  @State var confirmDeletePersonVoiceprints = false
  @State var confirmDeletePersonIdentity = false
  @State var confirmDiscardDictation = false
  @State var confirmDiscardRoomRecording = false
  @State var confirmDiscardSystemRecording = false
  @State var confirmCancelImport = false
  @State var confirmRetireEvent = false
  @State var creatingEvent = false
  @State var showsEventReview = false
  @State var showsPersonReview = false
  @State var historyFilterField: HistoryFilterField?
  @State var editingHistoryDocuments: Set<UUID> = []
  @State var importDropTargeted = false
  @State var historyWorkspaceTab = HistoryWorkspaceTab.transcript
  @State var followsHistoryPlayback = true
  @State var editingHistorySegmentID: UUID?
  @State var historySegmentEditDraft = ""
  @State var editingHistoryTitleID: SessionID?
  @State var showsInlinePersonCorrectionFeedback = false
  /// Which result the arrow keys are on, as an offset into the loaded rows.
  @State var historyKeyboardIndex: Int?
  @State var pendingStructuredItemDeletion: PendingStructuredItemDeletion?
  @AppStorage("onboarding.practice-completed-v1")
  var practiceCompleted = false
  @AppStorage("onboarding.practice-deferred-v1")
  var practiceDeferred = false
  @AppStorage("onboarding.permissions-deferred-v1")
  var permissionSetupDeferred = false
  @AppStorage("onboarding.models-deferred-v1")
  var modelSetupDeferred = false
  @AppStorage("onboarding.microphone-checked-v1")
  var onboardingMicrophoneChecked = false
  @State var practiceText = ""
  @State var practiceTextAtStart = ""
  @State var practiceSessionID: SessionID?
  @State var practiceStatusMessage = ""
  @FocusState var practiceFieldFocused: Bool
  @FocusState var historyFocusedField: HistoryFocusedField?

  var body: some View {
    memoryShell
    // ⌘V with no text field focused takes the clipboard in as an item.
    .background(IntakePasteKeyMonitor { model.receivePasteboard() })
    // Anything dropped on the window: text, images, documents, audio/video.
    .onDrop(of: IntakePasteKeyMonitor.dropTypes, isTargeted: nil) { providers in
      model.receiveDrop(providers)
    }
    .frame(minWidth: 1000, minHeight: 680)
    .onAppear {
      if ProcessInfo.processInfo.arguments.contains("--onboarding-ui-testing") {
        practiceCompleted = false
        practiceDeferred = false
        permissionSetupDeferred = false
        modelSetupDeferred = false
        onboardingMicrophoneChecked = false
        practiceText = ""
        practiceTextAtStart = ""
        practiceSessionID = nil
        practiceStatusMessage = ""
      }
      model.refreshHistoryIfStale()
      memoryScreen.attach(to: model)
      spaces.attach(to: model, memory: memoryScreen)
      trackCaptureStart()
      followRequestedNavigation(model.requestedNavigationSectionID)
    }
    .sheet(item: $spaces.sheet) { sheet in
      SpaceSheetHost(sheet: sheet, state: spaces.screen, actions: spacesActions)
    }
    .onChange(of: model.capture.roomSnapshot.phase) { _, _ in trackCaptureStart() }
    .onChange(of: model.capture.systemAudioSnapshot.phase) { _, _ in trackCaptureStart() }
    .onChange(of: memoryNavigation.search) { _, query in
      // In 全部 the header search is the history search.
      if memoryNavigation.homeMode == .all { model.history.searchQuery = query }
    }
    .onChange(of: memoryNavigation.homeMode) { _, mode in
      if mode == .all {
        model.history.detailPresented = false
        model.history.searchQuery = memoryNavigation.search
        model.refreshHistoryIfStale()
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: NSApplication.didBecomeActiveNotification
      )
    ) { _ in
      model.refreshPermissions()
    }
    .onChange(of: model.requestedNavigationSectionID) { _, requested in
      followRequestedNavigation(requested)
    }
    .onChange(of: model.snapshot.phase) { _, phase in
      observePracticeDictation(phase)
    }
    .onChange(of: model.capture.roomInputLevel) { _, level in
      if model.capture.roomLevelPreviewActive, level >= 0.02 {
        onboardingMicrophoneChecked = true
      }
    }
    .confirmationDialog(
      "永久删除这条记录？",
      isPresented: historyDeletionIsPresented,
      titleVisibility: .visible
    ) {
      if let item = pendingHistoryDeletion {
        // A pasted or dragged item has no audio to delete on its own.
        if item.sourceAudioRetained, item.inputMode != .userItem {
          Button("仅删除保留原音，保留文字与人物", role: .destructive) {
            pendingHistoryDeletion = nil
            model.deleteHistorySourceAudio(item)
          }
        }
        Button("删除记录和保留原音", role: .destructive) {
          pendingHistoryDeletion = nil
          model.deleteHistoryItem(item)
        }
      }
      Button("取消", role: .cancel) { pendingHistoryDeletion = nil }
    } message: {
      Text("你可以只删除占空间的原音并保留逐字稿版本、摘要、人物和时间线；也可以永久删除整条记录。两种操作都不能撤销。")
    }
    .confirmationDialog(
      "删除当前口述？",
      isPresented: $confirmDiscardDictation,
      titleVisibility: .visible
    ) {
      Button("删除本次未提交口述", role: .destructive) {
        model.cancel()
      }
      .accessibilityIdentifier("bestASR.main.confirmCancel")
      Button("继续保留口述", role: .cancel) {}
    } message: {
      Text("只会删除这次尚未提交的口述录音和临时文字；资料库中已完成的记录、原音和人物信息不会改变。")
    }
    .confirmationDialog(
      "删除当前线下录音？",
      isPresented: $confirmDiscardRoomRecording,
      titleVisibility: .visible
    ) {
      Button("删除本次未提交录音", role: .destructive) {
        model.cancelRoomRecording()
      }
      Button("继续保留录音", role: .cancel) {}
    } message: {
      Text("只有这次尚未提交的线下录音会被删除；已完成的历史和其他原音不受影响。")
    }
    .confirmationDialog(
      "删除当前电脑内录？",
      isPresented: $confirmDiscardSystemRecording,
      titleVisibility: .visible
    ) {
      Button("删除本次未提交录音", role: .destructive) {
        model.cancelSystemAudioRecording()
      }
      Button("继续保留录音", role: .cancel) {}
    } message: {
      Text("只有这次尚未提交的系统/麦克风音轨会被删除；已完成的历史不受影响。")
    }
    .confirmationDialog(
      model.capture.importCanDiscard
        ? "取消当前文件处理？" : "停止当前处理？",
      isPresented: $confirmCancelImport,
      titleVisibility: .visible
    ) {
      if model.capture.importCanDiscard {
        Button("取消并删除本次处理进度", role: .destructive) {
          model.cancelImport()
        }
      } else {
        Button("停止并保留到资料库") {
          model.cancelImport()
        }
      }
      Button("继续处理", role: .cancel) {}
    } message: {
      Text(
        model.capture.importCanDiscard
          ? "只会移除织机为这次导入创建的未完成进度；你选择的原始音视频文件不会被修改，资料库中已有内容也不会改变。"
          : "源文件和已提取音频已经安全保存在本机。停止后这条记录会留在资料库，可稍后继续识别和整理。"
      )
    }
    .confirmationDialog(
      "删除这个事件？",
      isPresented: $confirmRetireEvent,
      titleVisibility: .visible
    ) {
      Button("仅删除事件关系", role: .destructive) {
        model.retireSelectedEvent()
      }
      Button("取消", role: .cancel) {}
    } message: {
      if let summary = model.selectedEventSummary {
        Text(
          "将解除 \(summary.sessionIDs.count) 条记录和 \(summary.personIDs.count) 个人物的事件关系。历史记录、原始音频、逐字稿、人物与单条记录的整理结果全部保留。"
        )
      } else {
        Text("只会删除事件名称、备注和分组关系。历史记录、原始音频、逐字稿与人物全部保留。")
      }
    }
    .confirmationDialog(
      "删除这条整理内容？",
      isPresented: structuredItemDeletionIsPresented,
      titleVisibility: .visible
    ) {
      if let deletion = pendingStructuredItemDeletion {
        Button("删除这条整理内容", role: .destructive) {
          pendingStructuredItemDeletion = nil
          model.deleteHistoryStructuredItem(
            deletion.item,
            from: deletion.document
          )
        }
      }
      Button("取消", role: .cancel) {
        pendingStructuredItemDeletion = nil
      }
    } message: {
      Text("只会从当前整理版本中删除这条摘要、决定或待办；原始音频、逐字稿、其他整理内容和人物关系都会保留。")
    }

  }

  var structuredItemDeletionIsPresented: Binding<Bool> {
    Binding(
      get: { pendingStructuredItemDeletion != nil },
      set: { if !$0 { pendingStructuredItemDeletion = nil } }
    )
  }

  var recordingTitle: String {
    switch model.snapshot.phase {
    case .recording: "正在听你说话"
    case .paused: "口述已暂停"
    case .finalizing, .recognizing, .polishing, .inserting: "正在完成这次口述"
    case .failedRecoverable: "结果已保留，可重试"
    default: "在任何应用里开始口述"
    }
  }

  var recordingDetail: String {
    switch model.snapshot.phase {
    case .recording: "再次按快捷键结束；安全目标仍有效时插入，否则结果保存在历史记录。"
    case .paused: "继续后仍属于同一条记录。"
    case .failedRecoverable: "原始音频没有丢失，请到历史记录中恢复。"
    default:
      if model.isReadyForDictation {
        "在任何应用按快捷键即可开始；有安全输入位置时自动插入，否则保存在历史记录。"
      } else if model.canStartDictationCapture {
        "识别还没准备好；仍可安全录音，准备好后会接着转写。"
      } else {
        "先允许麦克风；识别组件可在上方一次准备完成。"
      }
    }
  }

  static var installedBuildTitle: String {
    let bundle = Bundle.main
    let version =
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "?"
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    let revision =
      bundle.object(forInfoDictionaryKey: "BestASRBuildRevision") as? String
      ?? "unidentified"
    return "版本 \(version)（\(build)） · \(revision.prefix(12))"
  }

  func formatPlaybackTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let remainder = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
      : String(format: "%d:%02d", minutes, remainder)
  }

}

struct SectionNavigationShortcut: ViewModifier {
  let shortcut: KeyEquivalent?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let shortcut {
      content.keyboardShortcut(shortcut, modifiers: .command)
    } else {
      content
    }
  }
}

#Preview {
  ContentView(model: DictationAppModel(preview: true))
}
