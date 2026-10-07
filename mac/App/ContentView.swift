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
    case .events: "事情"
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
    case .memory: "人和事"
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
  @Environment(\.openSettings) var openSettingsAction
  @State var selection = BestASRSection.home
  @StateObject var memoryScreen = MemoryScreenModel()
  /// 历史: every record, and what the search field finds (v12 find).
  @StateObject var historySearch = HistorySearchModel()
  @StateObject var spaces = SpacesModel()
  @State var memoryNavigation = MemoryNavigation()
  /// Files are being dragged over the window (the drop overlay).
  @State var dropTargeted = false
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

  /// The pages, or why the library did not open instead of an empty window.
  private var windowContent: some View {
    memoryShell.overlay {
      if !model.startupFailureMessage.isEmpty {
        StartupRefusalView(message: model.startupFailureMessage)
      }
    }
    // fn needs 设备控制和数据访问: said here until it is allowed (review of 10-6).
    .overlay(alignment: .bottom) {
      FnAccessibilityBar(model: model, onboarding: model.onboarding)
    }
  }

  var body: some View {
    windowContent
    // No title bar band; the traffic lights in the sidebar card (§3.3).
    .mindloomWindowChrome()
    // ⌘V with no text field focused takes the clipboard in as an item.
    .background(IntakePasteKeyMonitor { model.receivePasteboard() })
    // ⌘F focuses the search field before the system's 查找… sees it.
    .background(MindloomFindKeyMonitor())
    // The sidebar's tagline is picked as the window comes on screen.
    .background(
      WindowShownMonitor { [memoryScreen, model] in
        memoryScreen.showTagline(app: model)
      }
    )
    // Anything dropped on the window: text, images, documents, audio/video.
    .onDrop(of: IntakePasteKeyMonitor.dropTypes, isTargeted: $dropTargeted) { providers in
      model.receiveDrop(providers)
    }
    .frame(minWidth: 900, minHeight: 600)
    .focusedSceneValue(\.mindloomCommands, commandContext)
    #if MINDLOOM_PREVIEW
      // The preview's live verification run (App/LiveShots.swift).
      .liveShotsProbe()
      .task { await runLiveShots() }
    #endif
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
      SettingsRouter.shared.opener = openSettingsAction
      model.refreshHistoryIfStale()
      memoryScreen.attach(to: model)
      historySearch.attach(to: model) { [memoryScreen, model] in
        memoryScreen.state(app: model, capture: nil)
      }
      spaces.attach(to: model, memory: memoryScreen)
      trackCaptureStart()
      followRequestedNavigation(model.requestedNavigationSectionID)
    }
    .onDisappear { memoryScreen.windowClosed() }
    .sheet(item: $spaces.sheet) { sheet in
      SpaceSheetHost(sheet: sheet, state: spaces.screen, actions: spacesActions)
    }
    .onChange(of: model.capture.roomSnapshot.phase) { _, _ in trackCaptureStart() }
    .onChange(of: model.capture.systemAudioSnapshot.phase) { _, _ in trackCaptureStart() }
    .onChange(of: memoryNavigation.root) { _, root in followSpaceScope(root) }
    // A matter opened without a map asks the DGX Spark to draw one (also
    // when the link comes up with the page open); the next pull shows 进展.
    .onChange(of: memoryNavigation.path) { _, path in requestMapForOpenMatter(path) }
    .onChange(of: model.remoteOrganizerLinkIsConnected) { _, up in
      if up { requestMapForOpenMatter(memoryNavigation.path) }
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
      "删除这条记录？",
      isPresented: historyDeletionIsPresented,
      titleVisibility: .visible
    ) {
      if let item = pendingHistoryDeletion {
        // A pasted or dragged item has no audio to delete on its own.
        let hasAudio = item.sourceAudioRetained && item.inputMode != .userItem
        if hasAudio {
          Button("删除录音，保留文字", role: .destructive) {
            pendingHistoryDeletion = nil
            model.deleteHistorySourceAudio(item)
          }
        }
        Button(hasAudio ? "删除记录和录音" : "删除记录", role: .destructive) {
          pendingHistoryDeletion = nil
          model.deleteHistoryItem(item) { [historySearch] in
            historySearch.forgetRow(item.sessionID.rawValue.uuidString.uppercased())
          }
        }
      }
      Button("取消", role: .cancel) { pendingHistoryDeletion = nil }
    } message: {
      Text(
        Self.historyDeletionMessage(
          hasAudio: pendingHistoryDeletion.map {
            $0.sourceAudioRetained && $0.inputMode != .userItem
          } ?? false))
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
      Text("将删除此次尚未提交的口述录音和临时文字；资料库中已完成的记录、录音和人物信息保持不变。")
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
      Text("将删除此次尚未提交的线下录音；已完成的历史记录和其他录音保持不变。")
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
      Text("将删除此次尚未提交的系统与麦克风音轨；已完成的历史记录保持不变。")
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
          ? "将移除 Mindloom 为此次导入创建的未完成进度；你选择的原始音视频文件和资料库中已有的内容保持不变。"
          : "源文件和已提取音频已保存在本机。停止后这条记录会留在资料库，可稍后继续识别和整理。"
      )
    }
    .confirmationDialog(
      "删除这件事？",
      isPresented: $confirmRetireEvent,
      titleVisibility: .visible
    ) {
      Button("仅删除这件事", role: .destructive) {
        model.retireSelectedEvent()
      }
      Button("取消", role: .cancel) {}
    } message: {
      if let summary = model.selectedEventSummary {
        Text(
          "将解除 \(summary.sessionIDs.count) 条记录和 \(summary.personIDs.count) 个人物与这件事的关系。历史记录、原始音频、逐字稿、人物与单条记录的整理结果全部保留。"
        )
      } else {
        Text("将删除这件事的名称、备注和分组关系。历史记录、原始音频、逐字稿和人物都会保留。")
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
      Text("将从当前整理版本中删除此摘要、决定或待办；原始音频、逐字稿、其他整理内容和人物关系都会保留。")
    }

  }

  /// The menu bar's view of this window (MindloomCommands).
  var commandContext: MindloomCommandContext {
    let screen = memoryScreen
    let spacesModel = spaces
    return MindloomCommandContext(
      undoTitle: screen.corrections?.undoState?.menuTitle,
      undo: { screen.undo() },
      navigation: $memoryNavigation,
      newSpace: { spacesModel.sheet = .newSpace },
      joinSpace: { spacesModel.sheet = .join },
      openAbout: { SettingsRouter.shared.open(.about) })
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
    case .recording: "再次按快捷键结束；原输入位置仍可用时输入文字，否则保存在历史记录中。"
    case .paused: "继续后仍属于同一条记录。"
    case .failedRecoverable: "原始音频没有丢失，请到历史记录中恢复。"
    default:
      if model.isReadyForDictation {
        "在任何 App 中按快捷键即可开始；有可用的输入位置时自动输入，否则保存在历史记录中。"
      } else if model.canStartDictationCapture {
        "识别尚未就绪；仍可录音，就绪后继续转写。"
      } else {
        "先允许麦克风；识别模型可在上方一次准备完成。"
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
