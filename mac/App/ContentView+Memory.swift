import BestASRDomain
import BestASREntries
import BestASRMemory
import BestASRMemoryUI
import SwiftUI

/// The Mindloom pages wired to the App (v11): value state from
/// `MemoryScreenModel`, corrections through its undo window to
/// `DictationAppModel.memoryCommit`, shared spaces from `SpacesModel`.
extension ContentView {
  var memoryShell: some View {
    let spacesModel = spaces
    var state = memoryScreen.state(app: model, capture: memoryCaptureIndicator)
    state.spaces = spaces.sidebarSpaces
    state.sharing = spaces.sharingInfo
    state.history = historySearch.state
    patchHomeState(&state)
    patchMatterState(&state)
    patchCaptureState(&state)
    return MindloomShell(
      navigation: $memoryNavigation, state: state, actions: memoryActions,
      spaces: spaces.screen, spacesActions: spacesActions,
      spaceState: { id in spacesModel.screen.scope == .space(id) ? spacesModel.scopeBase : nil },
      dropTargeted: dropTargeted)
  }

  var memoryActions: MemoryActions {
    let model = model
    let screen = memoryScreen
    let navigation = $memoryNavigation
    var actions = MemoryActions(
      correct: { screen.submit($0) },
      undo: { screen.undo() },
      createGroup: { name, moving in
        Task {
          guard let group = await model.memoryCreateGroup(name: name, moving: moving) else { return }
          await screen.reloadUser()
          if moving == nil {
            navigation.wrappedValue.root = .group(group.id.uuidString.lowercased())
            navigation.wrappedValue.path = []
          } else {
            screen.show(MemoryToast("已移到“\(group.name)”", icon: .symbol("folder")))
          }
        }
      },
      renameGroup: { id, name in
        Task {
          guard let uuid = UUID(uuidString: id) else { return }
          try? await model.repository?.renameUserGroup(uuid, name: name, at: Date())
          await screen.reloadUser()
        }
      },
      deleteGroup: { id in
        Task {
          guard let uuid = UUID(uuidString: id) else { return }
          try? await model.repository?.deleteUserGroup(uuid, at: Date())
          await screen.reloadUser()
        }
      },
      copyText: { id in
        model.memoryCopyText(id)
        screen.show(MemoryToast("已拷贝", icon: .symbol("doc.on.doc")))
      },
      exportText: { model.memoryExportText($0) },
      searchText: { [historySearch] in historySearch.search($0) },
      reconnect: { model.reconnectRemoteOrganizer() },
      openSettings: { SettingsRouter.shared.open(named: $0) },
      dismissToast: { screen.dismissToast($0) },
      holdToast: { screen.holdToast($0, hovering: $1) },
      play: { model.memoryPlay(itemID: $0) },
      playRange: { model.memoryPlayRange(itemID: $0, start: $1, end: $2) },
      stop: { model.memoryStop() },
      changeSource: { model.memoryChangeSource(itemID: $0, name: $1) },
      refresh: {
        // Reads the library again, once a minute at most; organizing is the
        // DGX Spark's (v12 理1-4: no whole-library local run on a visit).
        switch screen.claimPageRefresh() {
        case .reload?:
          model.reloadEventMemory()
          model.refreshPeople()
        case nil:
          break
        }
      },
      retryIssue: { model.memoryRetryIssue($0) },
      discardIssue: { model.memoryDiscardIssue($0) }
    )
    // 把下一步加到提醒事项 (V8 contract A5), only while 设置 → 入口 has it on.
    if model.entries.isOn(.reminders) {
      actions.addToReminders = { model.addNextStepToReminders($0) }
    }
    wireHistoryActions(&actions)
    wireHomeActions(&actions)
    wireMatterActions(&actions)
    wireCaptureActions(&actions)
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

  /// Follows the start of a long capture so the indicator can say since when.
  func trackCaptureStart() {
    let active =
      model.capture.roomSnapshot.phase.isActive
      || model.capture.systemAudioSnapshot.phase.isActive
    if active, captureStartedAt == nil { captureStartedAt = Date() }
    if !active { captureStartedAt = nil }
  }

  /// Maps the older section requests (menus, intents) onto the pages.
  func memoryNavigate(to destination: BestASRSection) {
    switch destination {
    case .history:
      // 历史 (菜单、快捷指令、菜单栏的最近记录): every record, a record lit
      // when one was asked for.
      var navigation = MemoryNavigation(root: .search)
      navigation.revealRow = model.pendingHistoryReveal
      model.pendingHistoryReveal = nil
      memoryNavigation = navigation
    case .dictionary:
      SettingsRouter.shared.open(.dictation)
    case .home, .events, .people:
      memoryNavigation = MemoryNavigation()
    case .roomRecording, .systemAudio, .importMedia:
      captureSection = destination
      memoryNavigation = MemoryNavigation()
    }
  }
}
