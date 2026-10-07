import AppKit
import BestASRDomain
import BestASREntries
import BestASRIntake
import BestASRMemoryUI
import BestASRRemoteOrganizer
import Foundation
import MindloomTencentMeeting

/// 入口 › 腾讯会议 (ENTRY-013, ARCH v3 §6): the bundled tmeet, connected
/// once from Settings with a QR code; then every meeting this account may
/// view is added as 「会议记录 · 腾讯会议」 — on launch, on wake, every 90
/// minutes while the Mac is awake, catching up what was missed. Off by
/// default; switching it off removes this Mac's login (the authorization
/// itself stays with Tencent until it ends).
extension DictationAppModel {
  var tencent: TencentMeetingModel { entries.tencent }

  /// With the entries, once the library is open.
  func configureTencentMeeting(dataRoot: URL, folder: EntryFolder) {
    let model = tencent
    model.helper = TencentMeetingHelper.bundled(in: Bundle.main.bundleURL)
    let stateDirectory = TencentMeetingHelper.stateDirectory(dataRoot: dataRoot)
    model.stateDirectory = stateDirectory
    model.newLoginDirectory = TencentMeetingHelper.newLoginDirectory(dataRoot: dataRoot)
    let keyStore = KeychainTencentMeetingKeyStore(dataRoot: dataRoot)
    model.keyStore = keyStore
    model.state =
      folder.loadState(.tencentMeeting, as: TencentMeetingState.self) ?? TencentMeetingState()
    guard let helper = model.helper, let processor = intakeProcessor, let repository else {
      finishInterruptedTencentDisconnect()
      return
    }
    // The key goes only to the helper sealed into this App, as it runs.
    let environment = TmeetEnvironment(
      executable: helper, stateDirectory: stateDirectory,
      masterKey: .descriptor({ try keyStore.existingOrNewKey() }),
      helperCheck: .sealedIntoRunningApp(Bundle.main.bundleURL))
    model.environment = environment
    let runner = TmeetProcessRunner(environment: environment)
    model.runner = runner
    let ready = intakeReady
    let writer = TencentMeetingLibraryWriter(
      assetStore: processor.assetStore, store: repository, ready: { await ready?.value })
    model.sync = TencentMeetingSync(
      state: model.state, runner: runner, writer: writer,
      configuration: .init(tmeetVersion: TencentMeetingHelper.version),
      save: { try? folder.saveState($0, for: .tencentMeeting) })
    finishInterruptedTencentDisconnect()
  }

  /// Switched off, and a login still on this Mac (the App quit before
  /// switching off had finished): finish it now.
  private func finishInterruptedTencentDisconnect() {
    let model = tencent
    guard !entries.isOn(.tencentMeeting), let stateDirectory = model.stateDirectory,
      model.state.connectedAt != nil
        || TencentMeetingLoginFolders.exist(stateDirectory, newLogin: model.newLoginDirectory)
    else { return }
    removeTencentLogin()
  }

  /// Starts or stops the regular checks with the switch and the connection.
  func applyTencentMeeting() {
    let model = tencent
    let running = entries.isOn(.tencentMeeting) && model.isConnected && model.sync != nil
    if running {
      if model.loop == nil {
        model.loop = Task { [weak self] in
          try? await Task.sleep(for: .seconds(20))
          var trigger = TencentMeetingSync.Trigger.launch
          while !Task.isCancelled {
            await self?.tencentPass(trigger)
            trigger = .regular
            try? await Task.sleep(for: TencentMeetingModel.interval)
          }
        }
      }
      if model.wakeObserver == nil {
        model.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
          forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in
            // The network comes back a little after the Mac wakes.
            try? await Task.sleep(for: .seconds(60))
            await self?.tencentPass(.wake)
          }
        }
      }
    } else {
      model.loop?.cancel()
      model.loop = nil
      if let observer = model.wakeObserver {
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        model.wakeObserver = nil
      }
    }
  }

  /// One pass, if the trigger gets one (`TencentMeetingSync.kind`: none
  /// right after another, a full one at most every three hours unless the
  /// owner asked).
  func tencentPass(_ trigger: TencentMeetingSync.Trigger) async {
    let model = tencent
    guard entries.isOn(.tencentMeeting), model.isConnected, let sync = model.sync,
      !model.working
    else { return }
    model.state = await sync.snapshot
    guard let kind = TencentMeetingSync.kind(for: trigger, state: model.state, now: Date())
    else { return }
    model.working = true
    let report = await sync.pass(kind)
    model.state = await sync.snapshot
    model.working = false
    if report.added > 0 {
      await refreshHistoryItems(preserveStatus: true, organizeEvents: true)
    }
  }

  // MARK: The switch

  func setTencentMeeting(on: Bool) {
    guard entries.isOn(.tencentMeeting) != on else { return }
    entries.settings.set(.tencentMeeting, on: on)
    saveEntrySettings()
    if on {
      applyTencentMeeting()
      if !tencent.isConnected { connectTencentMeeting() }
    } else {
      disconnectTencentMeeting()
    }
  }

  /// Off: no more checks, and this Mac's login is removed (tmeet's folders
  /// and Mindloom's key, at once; then the entry's state). What was added
  /// stays, and so does the list of recordings already seen, so nothing
  /// comes back twice. The authorization given on the phone stays with
  /// Tencent until it ends (tmeet has no way to withdraw it).
  func disconnectTencentMeeting() {
    let model = tencent
    model.loginCancellation?.cancel()
    model.loginCancellation = nil
    model.connecting = nil
    model.qr = nil
    model.authorizationURL = nil
    applyTencentMeeting()
    // Switching on again shows a QR code, even before the state is saved.
    model.state.connectedAt = nil
    removeTencentLogin()
  }

  /// Removes tmeet's folders and the key (on this Mac, nothing sent), then
  /// marks the entry disconnected. Safe to repeat: also run on launch when
  /// the switch is off and a login is still here.
  func removeTencentLogin() {
    let model = tencent
    if let stateDirectory = model.stateDirectory {
      TencentMeetingLoginFolders.removeAll(
        stateDirectory: stateDirectory, newLogin: model.newLoginDirectory)
    }
    try? model.keyStore?.delete()
    guard let sync = model.sync else {
      model.state.connectedAt = nil
      return
    }
    Task { [weak self] in
      await sync.disconnected()
      let snapshot = await sync.snapshot
      self?.tencent.state = snapshot
    }
  }

  // MARK: Connecting

  /// Shows the QR code of Tencent's authorization page; done when the owner
  /// allows it on the phone (or in the Mac's browser). The new login is
  /// made in a folder of its own and replaces the one in use only once
  /// allowed, so reconnecting before the old login has ended works, and
  /// cancelling keeps the old one.
  func connectTencentMeeting() {
    let model = tencent
    guard let environment = model.environment, let stateDirectory = model.stateDirectory,
      let newLogin = model.newLoginDirectory, model.loginCancellation == nil
    else {
      if model.helper == nil { model.connecting = .failed(TencentMeetingStatus.helperMissing) }
      return
    }
    TencentMeetingLoginFolders.clearNewLogin(newLogin)
    let runner = TmeetProcessRunner(environment: environment.withStateDirectory(newLogin))
    let cancellation = TencentMeetingCancellation()
    model.loginCancellation = cancellation
    model.connecting = .starting
    model.qr = nil
    Task { [weak self] in
      let result = await runner.login(
        onLine: { line in
          guard let url = TencentMeetingLoginOutput.authorizationURL(in: line) else { return }
          Task { @MainActor in
            guard model.loginCancellation === cancellation else { return }
            model.authorizationURL = url
            model.qr = PhonePairingQRCode.image(for: url.absoluteString)
            model.connecting = .code(url)
          }
        }, cancellation: cancellation)
      var outcome = TencentMeetingLoginOutput.outcome(result, cancelled: cancellation.isCancelled)
      if result.launchFailure == .key { outcome = .failed }
      guard model.loginCancellation === cancellation else {
        TencentMeetingLoginFolders.clearNewLogin(newLogin)
        return
      }
      model.loginCancellation = nil
      model.qr = nil
      model.authorizationURL = nil
      switch outcome {
      case .connected, .alreadyConnected:
        do {
          try TencentMeetingLoginFolders.adopt(newLogin: newLogin, into: stateDirectory)
        } catch {
          TencentMeetingLoginFolders.clearNewLogin(newLogin)
          model.connecting = .failed(TencentMeetingStatus.connectFailed)
          return
        }
        model.connecting = nil
        await model.sync?.connected(at: Date())
        if let sync = model.sync { model.state = await sync.snapshot }
        self?.applyTencentMeeting()
        await self?.tencentPass(.connected)
      case .expired:
        TencentMeetingLoginFolders.clearNewLogin(newLogin)
        model.connecting = .expired
      case .cancelled:
        TencentMeetingLoginFolders.clearNewLogin(newLogin)
        model.connecting = nil
      case .network, .failed:
        TencentMeetingLoginFolders.clearNewLogin(newLogin)
        model.connecting = .failed(
          result.launchFailure == .key
            ? TencentMeetingStatus.keyUnavailable : TencentMeetingStatus.connectFailed)
      }
    }
  }

  func cancelTencentConnecting() {
    tencent.loginCancellation?.cancel()
    tencent.loginCancellation = nil
    tencent.connecting = nil
    tencent.qr = nil
    if let newLogin = tencent.newLoginDirectory {
      TencentMeetingLoginFolders.clearNewLogin(newLogin)
    }
  }

  func openTencentAuthorizationInBrowser() {
    guard let url = tencent.authorizationURL else { return }
    NSWorkspace.shared.open(url)
  }

  /// The status line's button.
  func actOnTencentStatus() {
    let line = TencentMeetingStatus.line(
      state: tencent.state, helperAvailable: tencent.helper != nil)
    switch line.action {
    case .connect?, .reconnect?: connectTencentMeeting()
    case .learnMore?: NSWorkspace.shared.open(TencentMeetingStatus.learnMoreURL)
    case .retry?: checkTencentMeetingNow()
    case nil: break
    }
  }

  func answerTencentBackfill(add: Bool) {
    Task { [weak self] in
      guard let self, let sync = self.tencent.sync else { return }
      await sync.answerBackfill(add: add, now: Date())
      self.tencent.state = await sync.snapshot
      if add { await self.tencentPass(.answered) }
    }
  }

  /// 「申请查看…」: the recording's page on meeting.tencent.com, where the
  /// owner asks its owner; Mindloom sends nothing for them.
  func openTencentRecordingPage(_ recordFileID: String) {
    guard
      let row = TencentMeetingStatus.rows(state: tencent.state).first(where: {
        $0.id == recordFileID
      }), let url = row.pageURL
    else { return }
    NSWorkspace.shared.open(url)
  }

  func checkTencentMeetingNow() {
    Task { [weak self] in await self?.tencentPass(.checkNow) }
  }
}
