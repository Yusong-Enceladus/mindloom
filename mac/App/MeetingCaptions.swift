import AppKit
import BestASRDictation
import BestASRMacAudio
import BestASRMacUI
import BestASRMemoryUI
import Combine
import MindloomDesign
import SwiftUI

// OWNER: mac-capture. 开始记录会议 must not regress (v12 1C; ALIGNMENT
// 收2-2, 收2-3): what the meeting records (the meeting App playing sound,
// chosen by itself, changeable in the menu bar's 「录：… ›」; only the
// microphone, said plainly, when 屏幕与系统录音 is not allowed) and the
// caption strip at the bottom of the screen while it records (the last two
// lines of the live text; draggable; ✕ turns it off until 显示字幕).

/// The meeting's menu state and caption strip, App-wide (extensions of
/// `DictationAppModel` cannot hold stored values).
@MainActor
final class MeetingState: ObservableObject {
  static let shared = MeetingState()

  static let captionsKey = "preferences.meeting-captions"
  static let captionsOriginKey = "preferences.meeting-captions-origin"

  /// What the next meeting records; back to automatic after each meeting.
  @Published var choice: MeetingAudioChoice = .automatic
  /// The Apps with sound (read when a menu opens and when a meeting starts).
  @Published private(set) var sources: [SystemAudioSource] = []
  /// The computer sound the meeting under way records (nil: none, or it
  /// records the microphone only).
  @Published var recordingPick: MeetingAudioPick?
  /// The caption strip (on by default; ✕ turns it off, 显示字幕 back on).
  @Published var captionsEnabled = LocalPreferenceStore.bool(captionsKey, default: true) {
    didSet { LocalPreferenceStore.defaults.set(captionsEnabled, forKey: Self.captionsKey) }
  }

  private weak var model: DictationAppModel?
  private var observers: Set<AnyCancellable> = []
  private var menuObserver: NSObjectProtocol?
  private var lastSourcesRead = Date.distantPast
  /// A meeting is being recorded (or paused).
  private var meetingLive = false

  lazy var captions: MeetingCaptionPanelController = {
    let controller = MeetingCaptionPanelController(
      placement: MeetingCaptionPlacement(
        load: {
          let values = LocalPreferenceStore.defaults.array(forKey: MeetingState.captionsOriginKey)
          guard let values = values as? [Double], values.count == 2 else { return nil }
          return CGPoint(x: values[0], y: values[1])
        },
        save: { origin in
          LocalPreferenceStore.defaults.set(
            [Double(origin.x), Double(origin.y)], forKey: MeetingState.captionsOriginKey)
        }))
    controller.makeContent = { [weak controller] presentation in
      AnyView(
        MeetingCaptionHost(
          presentation: presentation, close: { controller?.close() },
          moved: { controller?.moved() }
        )
        .mlNoAutospace())
    }
    // ✕ while a meeting records turns the strip off (显示字幕 brings it
    // back); ✕ on an ending only puts that ending away.
    controller.onClose = { [weak self] turnsOff in
      if turnsOff { self?.captionsEnabled = false }
    }
    return controller
  }()

  /// Follows the meeting's recordings (their phases and live text) and
  /// reads the Apps with sound when a menu opens.
  func attach(_ model: DictationAppModel) {
    guard self.model == nil else { return }
    self.model = model
    let capture = model.capture
    capture.$roomSnapshot.map(\.phase)
      .combineLatest(capture.$systemAudioSnapshot.map(\.phase))
      .combineLatest(capture.$roomLiveTranscriptText, capture.$systemAudioLiveTranscriptText)
      // In order, at once: an ending told right after must not be overtaken
      // by an older live line.
      .sink { [weak self] phases, roomText, systemText in
        self?.follow(room: phases.0, system: phases.1, roomText: roomText, systemText: systemText)
      }
      .store(in: &observers)
    $captionsEnabled.dropFirst().removeDuplicates()
      .sink { [weak self] enabled in
        guard let self else { return }
        if enabled {
          // 显示字幕 during a meeting: at once, with what was said so far.
          let capture = model.capture
          follow(
            room: capture.roomSnapshot.phase, system: capture.systemAudioSnapshot.phase,
            roomText: capture.roomLiveTranscriptText,
            systemText: capture.systemAudioLiveTranscriptText, enabled: true)
        } else {
          captions.hide()
        }
      }
      .store(in: &observers)
    // The menu bar's menu: its 「录：… ›」 lists the Apps with sound now.
    menuObserver = NotificationCenter.default.addObserver(
      forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.readSources(atMostEvery: 1) }
    }
    readSources()
  }

  /// Reads the Apps with sound (a Core Audio property read; no prompt).
  func readSources(atMostEvery seconds: TimeInterval = 0) {
    guard Date().timeIntervalSince(lastSourcesRead) >= seconds else { return }
    lastSourcesRead = Date()
    let read = (try? SystemAudioSourceCatalog.sources()) ?? []
    let selectable = DictationAppModel.selectableAudioSources(read)
    if selectable != sources { sources = selectable }
  }

  /// The pick a meeting starting now would record.
  var pick: MeetingAudioPick { MeetingAudioSourcePolicy.pick(choice, sources: sources) }

  private static let live: Set<DictationPhase> = [.preparing, .recording, .paused]

  /// The strip while a meeting records: listening or paused with the live
  /// text; gone when the recording goes without being saved (放弃, a start
  /// that failed). Endings are told by the recording itself (`ended`).
  private func follow(
    room: DictationPhase, system: DictationPhase, roomText: String, systemText: String,
    enabled: Bool? = nil
  ) {
    let usesSystem = Self.live.contains(system)
    let phase = usesSystem ? system : room
    guard Self.live.contains(phase) else {
      // 放弃这次记录, or a start that did not happen: nothing was saved.
      if meetingLive, [.idle, .cancelled].contains(phase) {
        captions.hide()
        recordingPick = nil
        choice = .automatic
      }
      meetingLive = false
      return
    }
    meetingLive = true
    guard enabled ?? captionsEnabled else { return }
    captions.update(
      phase == .paused ? .paused : .listening, text: usesSystem ? systemText : roomText)
  }

  /// How the meeting ended: saving, then the recomputed text (or what
  /// happened). The choice of sound goes back to automatic.
  func ended(_ stage: MeetingCaptionPresentation.Stage, text: String = "") {
    if stage != .saving {
      choice = .automatic
      recordingPick = nil
    }
    guard captionsEnabled else { return }
    if stage == .saving, !captions.isShown { return }
    captions.update(stage, text: text)
  }
}

/// The package's `MeetingCaptionView` over the strip's live presentation.
struct MeetingCaptionHost: View {
  @ObservedObject var presentation: MeetingCaptionPresentation
  let close: () -> Void
  let moved: () -> Void

  var body: some View {
    MeetingCaptionView(input: Self.input(presentation), close: close, moved: moved)
      .environment(\.mlPlatform, .mac)
  }

  static func input(_ presentation: MeetingCaptionPresentation) -> MeetingCaptionInput {
    MeetingCaptionInput(
      lines: presentation.lines.map {
        MeetingCaptionInput.Line(speaker: $0.speaker, words: $0.words, pending: $0.pending)
      },
      status: presentation.status, live: presentation.live)
  }
}

extension DictationAppModel {
  /// What the menu bar's menu says the meeting records (ALIGNMENT 收2-2).
  var meetingMenu: MenuBarMeetingInput {
    let state = MeetingState.shared
    let live: Set<DictationPhase> = [.preparing, .recording, .paused]
    let sound: MenuBarMeetingInput.Sound
    if live.contains(capture.systemAudioSnapshot.phase) {
      sound = .computer(
        source: state.recordingPick?.title ?? MeetingAudioSourcePolicy.entireSystemTitle,
        options: [])
    } else if live.contains(capture.roomSnapshot.phase) {
      sound = .microphoneOnly(needsRelaunch: false)
    } else {
      switch capture.systemAudioPermission {
      case .granted, .notDetermined:
        // Never asked: 开始记录会议 asks first.
        let pick = state.pick
        sound = .computer(
          source: pick.title,
          options: MeetingAudioSourcePolicy.options(sources: state.sources).map {
            MenuBarExtraOption(id: $0.id, title: $0.title, checked: $0.id == pick.sourceID)
          })
      case .restartRequired:
        sound = .microphoneOnly(needsRelaunch: true)
      case .denied, .restricted, .revoked:
        sound = .microphoneOnly(needsRelaunch: false)
      }
    }
    return MenuBarMeetingInput(sound: sound, captionsShown: state.captionsEnabled)
  }

  /// 录：… › {App}: what the next meeting records.
  func chooseMeetingSound(_ id: String) {
    MeetingState.shared.choice =
      id == MeetingAudioSourcePolicy.entireSystemID ? .entireSystem : .application(id: id)
  }

  /// 允许录电脑的声音…: the system's own settings pane (asked once already).
  func allowMeetingComputerSound() {
    openSystemAudioPermissionSettings()
  }

  /// 显示字幕 / 隐藏字幕.
  func showMeetingCaptions(_ shown: Bool) {
    MeetingState.shared.captionsEnabled = shown
  }
}
