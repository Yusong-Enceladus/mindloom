import BestASRDomain
import BestASREntries
import BestASRMemory
import BestASRMemoryUI
import SwiftUI

/// The memory pages (Home, Event, Person, Unfiled) wired to the App: value
/// state from `MemoryScreenModel`, corrections to `DictationAppModel`, and
/// the existing History, Dictionary and capture pages as slots.
extension ContentView {
  var memoryShell: some View {
    ZhijiShell(
      navigation: $memoryNavigation,
      state: spacesScopedState(memoryScreen.state(app: model, capture: memoryCaptureIndicator)),
      actions: spacesScopedActions(memoryActions),
      slots: MemoryShellSlots(
        allItems: { AnyView(historyView) },
        dictionary: { AnyView(dictionaryView) },
        capture: { AnyView(memoryCapturePage) },
        homeAccessory: { spacesHomeAccessory(memoryHomeAccessory) },
        eventAccessory: { spacesEventAccessory($0) }
      )
    )
  }

  var memoryActions: MemoryActions {
    let model = model
    let screen = memoryScreen
    var actions = MemoryActions(
      answer: { model.memoryAnswer($0, yes: $1) },
      answerReview: { model.memoryAnswerReview($0, yes: $1) },
      pin: { model.memoryPin($0, pinned: $1) },
      featureLess: { model.memoryFeatureLess($0) },
      copyText: { model.memoryCopyText($0) },
      exportText: { model.memoryExportText($0) },
      renameEvent: { model.memoryRenameEvent($0, title: $1) },
      namePerson: { model.memoryNamePerson($0, name: $1) },
      removeItem: { model.memoryRemoveItem(eventID: $0, itemID: $1, segID: $2) },
      moveItem: {
        model.memoryMoveItem(itemID: $0, toEventID: $1, fromEventID: $2, segID: $3)
      },
      fileItemNewEvent: { model.memoryFileItemNewEvent(itemID: $0) },
      play: { model.memoryPlay(itemID: $0) },
      playRange: { model.memoryPlayRange(itemID: $0, start: $1, end: $2) },
      stop: { model.memoryStop() },
      playPersonSample: { model.memoryPlayPersonSample($0, projection: screen.projection) },
      changeSource: { model.memoryChangeSource(itemID: $0, name: $1) },
      refresh: {
        // Organizing runs on the Mac; once a minute is enough for page visits.
        guard screen.claimPageRefresh() else { return }
        model.refreshEvents()
        model.refreshPeople()
      },
      retryIssue: { model.memoryRetryIssue($0) },
      discardIssue: { model.memoryDiscardIssue($0) },
      relation: { model.memoryRelationDecision($0) },
      requestMap: { model.memoryRequestMap($0) }
    )
    // 把下一步加到提醒事项 (V8 contract A5), only while 设置 → 入口 has it on.
    if model.entries.isOn(.reminders) {
      actions.addToReminders = { model.addNextStepToReminders($0) }
    }
    return actions
  }

  /// A room or system recording, or an import, the user may walk away from.
  /// Dictation is not shown.
  var memoryCaptureIndicator: MemoryCaptureIndicator? {
    let started = captureStartedAt.map { memoryClock($0) }
    if model.capture.roomSnapshot.phase.isActive {
      let paused = model.capture.roomSnapshot.phase == .paused
      return MemoryCaptureIndicator(
        kind: .room, title: paused ? ZhijiCopy.recordingPaused : ZhijiCopy.recording,
        detail: [ZhijiCopy.inPerson, started].compactMap { $0 }.joined(separator: " · "),
        paused: paused)
    }
    if model.capture.systemAudioSnapshot.phase.isActive {
      let paused = model.capture.systemAudioSnapshot.phase == .paused
      let source =
        model.capture.systemAudioSources.first {
          $0.id == model.capture.selectedSystemAudioSourceID
        }?.displayName ?? "这台 Mac"
      return MemoryCaptureIndicator(
        kind: .systemAudio, title: paused ? ZhijiCopy.recordingPaused : ZhijiCopy.recording,
        detail: [source, started].compactMap { $0 }.joined(separator: " · "), paused: paused)
    }
    if model.capture.importInProgress {
      return MemoryCaptureIndicator(
        kind: .importing, title: ZhijiCopy.importing,
        detail: "\(Int(model.capture.importProgress * 100))%",
        paused: model.capture.importPaused)
    }
    return nil
  }

  private func memoryClock(_ date: Date) -> String {
    MemoryDateText.time(date, calendar: .current)
  }

  /// The page behind the recording indicator (or the one a menu asked for).
  @ViewBuilder
  var memoryCapturePage: some View {
    switch memoryCaptureSection {
    case .systemAudio: systemAudioRecordingView
    case .importMedia: importMediaView
    default: roomRecordingView
    }
  }

  var memoryCaptureSection: BestASRSection {
    if model.capture.systemAudioSnapshot.phase.isActive { return .systemAudio }
    if model.capture.importInProgress { return .importMedia }
    if model.capture.roomSnapshot.phase.isActive { return .roomRecording }
    return captureSection ?? .roomRecording
  }

  /// First-run setup, and a dictation started from this window, above Home.
  var memoryHomeAccessory: AnyView? {
    let setup =
      !model.startupFailureMessage.isEmpty || shouldShowPermissionSetup
      || isOnboardingIncomplete
    let watching = showsActiveCaptureWorkspace && activeCaptureSection == .home
    guard setup || watching else { return nil }
    return AnyView(
      VStack(alignment: .leading, spacing: 16) {
        if watching { unifiedActiveCaptureWorkspace }
        if setup {
          homeSetupCards
          homeAttentionCards
        }
      }
      .frame(maxWidth: 900, alignment: .leading)
    )
  }

  /// Follows the start of a long capture so the indicator can say since when.
  func trackCaptureStart() {
    let active =
      model.capture.roomSnapshot.phase.isActive
      || model.capture.systemAudioSnapshot.phase.isActive
    if active, captureStartedAt == nil { captureStartedAt = Date() }
    if !active { captureStartedAt = nil }
  }

  /// Maps the older section requests onto the memory navigation.
  func memoryNavigate(to destination: BestASRSection) {
    switch destination {
    case .home, .events:
      memoryNavigation = MemoryNavigation(tab: .home, homeMode: .events)
    case .history:
      memoryNavigation = MemoryNavigation(
        tab: .home, homeMode: .all, search: memoryNavigation.search)
    case .people:
      var navigation = MemoryNavigation(tab: .people)
      if let person = model.people.selectedPersonID {
        navigation.path = [.person(person.rawValue.uuidString)]
      }
      memoryNavigation = navigation
    case .dictionary:
      memoryNavigation = MemoryNavigation(tab: .dictionary)
    case .roomRecording, .systemAudio, .importMedia:
      captureSection = destination
      memoryNavigation = MemoryNavigation(tab: .home, path: [.capture])
    }
  }
}
