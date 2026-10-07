import BackgroundTasks
import MindloomDesign
import MindloomLink
import MindloomPhoneKit
import SwiftUI
import UIKit
import os

/// Mindloom on the iPhone (PHONE-SPEC §1): Welcome, pairing with the Mac, permissions, Home (what
/// the user sent, the speak bar), Settings; the voice session behind the keyboard; the outbox.
@main
struct MindloomPhoneApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = AppModel.make()

  init() {
    PhoneAppearance.configure()
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(model)
        .tint(MLColor.accent.dynamicColor)
        .onOpenURL { url in model.open(url) }
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active: model.becameActive()
      case .background: model.enteredBackground()
      default: break
      }
    }
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    DeliveryService.registerBackgroundRefresh { task in
      // The task object is only touched from the main actor below.
      nonisolated(unsafe) let refresh = task
      Task { @MainActor in
        let work = Task { @MainActor in
          // What is queued goes first: a long recording from Apple Watch must not use up the
          // time. Then what WatchConnectivity holds for this app, the recordings that wait for
          // their text, and what they gave.
          await AppModel.shared?.delivery.deliver()
          await PhoneWatchLink.shared.waitUntilDrained(seconds: 5)
          await AppModel.shared?.watchRecordings?.finish()
          await AppModel.shared?.delivery.deliver()
        }
        refresh.expirationHandler = { work.cancel() }
        _ = await work.value
        AppModel.shared?.delivery.scheduleBackgroundRefresh()
        refresh.setTaskCompleted(success: true)
      }
    }
    return true
  }
}

/// The screens in the order a first run meets them.
enum AppRoute: Equatable {
  case welcome
  case permissions
  case home
}

/// Everything the screens share.
@MainActor
@Observable
final class AppModel {
  /// The running app's model, for the background refresh handler.
  static weak var shared: AppModel?

  let pairing: PairingModel
  let delivery: DeliveryService
  let voice: VoiceSessionModel
  let settings: PhoneSettings
  let talk: TalkController
  let container: URL?
  let liveActivity = VoiceLiveActivity()
  /// Recordings from Apple Watch (nil only if the app's own storage cannot be opened).
  @ObservationIgnored var watchRecordings: WatchRecordings?
  /// 「备份 Apple Watch 录音」 is up (shown once, the first time Home is in front with a
  /// recording from Apple Watch here; owner's decision 2026-10-06).
  var watchBackupNoticeShown = false
  @ObservationIgnored private var watchBackupNoticeSettled = false
  @ObservationIgnored var shareHandoff: ShareHandoff?
  /// Where the stores are, and whether what a build without the App Group kept has been brought
  /// into it (retried when the app becomes active if the launch could not read it).
  @ObservationIgnored private var storage: PhoneAppGroup.StorageRoot?
  @ObservationIgnored private var storageMigrated = true
  /// A build without the App Group runs after one with it: the pairing and the items are in the
  /// group, out of this build's reach. Home says so instead of looking like a fresh install.
  let dataInAppGroup: Bool
  /// Keyboard utterances kept for the Mac, by utterance number (for 「撤销」 from the keyboard).
  @ObservationIgnored private var keyboardItems: [Int: String] = [:]

  var route: AppRoute
  /// The camera / paste pairing screen is up.
  var showsPair = false
  /// Pairing started from the first run (close → Welcome, connect → Permissions).
  var pairFromFirstRun = false
  /// A code that came with a `mindloom://pair/…` link (the pairing screen opens on it).
  var pendingPairCode: String?
  /// The bounce tip (「语音已开启 / 回到信息，按住说话就行」) is showing.
  var showsBounceTip = false
  /// Keyboard state as the keyboard last reported it.
  private(set) var keyboardAdded = false
  private(set) var keyboardFullAccess = false
  /// Bumped when a sheet or push should close (e.g. after disconnecting).
  var navigationPath: [SettingsRoute] = []

  init(
    pairing: PairingModel, delivery: DeliveryService, voice: VoiceSessionModel,
    settings: PhoneSettings, container: URL?, dataInAppGroup: Bool = false
  ) {
    self.dataInAppGroup = dataInAppGroup
    self.pairing = pairing
    self.delivery = delivery
    self.voice = voice
    self.settings = settings
    self.container = container
    let listener = ListenerModel(
      layout: .phoneNote(size: CGSize(width: 402, height: 874), rest: CGPoint(x: 162, y: 816)))
    self.talk = TalkController(listener: listener, voice: voice, delivery: delivery)
    route = settings.welcomeDone || pairing.isPaired || dataInAppGroup ? .home : .welcome
    refreshKeyboardStatus()
    voice.onTick = { [weak delivery] in delivery?.retryIfDue() }
  }

  static func make() -> AppModel {
    #if DEBUG
      DebugLaunch.prepareStorage()
    #endif
    // The App Group, or the app's own Application Support when the build has
    // no App Group entitlement (a free Personal Team device build). Then the
    // voice session still runs, but the extensions cannot reach its files.
    let storage =
      (try? PhoneAppGroup.storageRoot())
      ?? PhoneAppGroup.StorageRoot(url: FileManager.default.temporaryDirectory, isShared: false)
    if !storage.isShared {
      Logger(subsystem: PhoneNames.appLog, category: "storage").notice(
        "App Group unavailable: using app-private storage; keyboard and share are not connected")
    }
    let migrated = migrateStorage(storage)
    #if DEBUG
      DebugLaunch.writeStorageListing(storage: storage)
    #endif
    let container = storage.isShared ? storage.url : nil
    let base = storage.url
    let settings = PhoneSettings.shared()
    let recordStore = PairingRecordStore(file: PhoneAppGroup.pairingRecordFile(in: base))
    let pairing = PairingModel(recordStore: recordStore)
    // The last resort only matters if even the chosen root is unwritable.
    let outbox =
      (try? OutboxStore(root: PhoneAppGroup.outboxDirectory(in: base)))
      ?? (try! OutboxStore(
        root: FileManager.default.temporaryDirectory.appendingPathComponent("outbox")))
    let items =
      (try? PhoneItemStore(root: PhoneItemStore.directory(in: base)))
      ?? (try! PhoneItemStore(
        root: FileManager.default.temporaryDirectory.appendingPathComponent("items")))
    // The keyboard link: App Group files, else the shared keychain group (a build signed
    // without the App Group, IOS-CODE-MAP §3b), else private files (no keyboard).
    let channel =
      PhoneLink.voiceChannel()
      ?? (try? VoiceChannel(directory: PhoneAppGroup.voiceDirectory(in: base)))
      ?? (try! VoiceChannel(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("voice")))
    if !storage.isShared {
      Logger(subsystem: PhoneNames.appLog, category: "storage").notice(
        "keyboard link: \(channel.isAppGroup ? "files" : "shared keychain", privacy: .public)")
    }
    let collector = PhoneItemCollector(
      items: items, outbox: outbox, pairing: recordStore, signaling: DarwinSignaling.shared)
    #if DEBUG
      DebugLaunch.seed(pairing: pairing, collector: collector, settings: settings)
    #endif
    let delivery = DeliveryService(collector: collector, pairing: pairing, settings: settings)
    // Shared before the app moved its pairing into the group, or brought over unsealed.
    delivery.sealPending()
    // Without the App Group the share extension keeps and sends what is shared by itself; the
    // app hands it the pairing and lists its items (ShareHandoff).
    let handoff = storage.isShared ? nil : ShareHandoff.keychain()
    delivery.shareHandoff = handoff
    if storage.isShared, let leftover = ShareHandoff.keychain(), leftover.hasItems {
      // With the group: the list a build without it left stays on Home until the share extension
      // next runs and moves its own items (and their unsent parts) into the group.
      delivery.shareHandoff = leftover
      delivery.shareHandoffIsLeftover = true
      delivery.refresh()
    }
    let model = AppModel(
      pairing: pairing, delivery: delivery,
      voice: VoiceSessionModel(channel: channel, settings: settings), settings: settings,
      container: container,
      dataInAppGroup: !storage.isShared && UserDefaults.standard.bool(forKey: dataInAppGroupKey))
    model.storage = storage
    model.storageMigrated = migrated
    shared = model
    model.shareHandoff = handoff
    model.syncShareHandoff()
    model.wireKeyboardSpeech()
    model.liveActivity.attach(to: model.voice)
    model.connectWatch()
    #if DEBUG
      DebugVoiceBench.startIfRequested(voice: model.voice)
      DebugLaunch.apply(to: model)
    #endif
    return model
  }

  /// In the standard defaults of a build without the App Group: a build with it ran before and
  /// moved this app's data into the group.
  static let dataInAppGroupKey = "storage.data_in_app_group"

  /// With the App Group: brings what a build without it kept in the app's own Application Support
  /// and standard defaults into the group, once (`PhoneStorageMigration`). Without it: the old
  /// place is in use again, so the next build with the group looks at it once more.
  /// Runs before any store is opened. The phone's SSH key stays where it is (the app-only keychain
  /// group, the same in both builds). Returns false when it must be tried again (protected data
  /// not available yet, or a file could not be moved).
  @discardableResult
  static func migrateStorage(_ storage: PhoneAppGroup.StorageRoot) -> Bool {
    let log = Logger(subsystem: PhoneNames.appLog, category: "storage")
    let legacy = PhoneAppGroup.privateApplicationSupport()
    guard storage.isShared else {
      if let legacy, PhoneStorageMigration.isDone(from: legacy) {
        UserDefaults.standard.set(true, forKey: dataInAppGroupKey)
        log.notice("the pairing and items are in the App Group, which this build cannot reach")
      }
      PhoneStorageMigration.forget(legacy: legacy, defaults: .standard)
      return true
    }
    UserDefaults.standard.removeObject(forKey: dataInAppGroupKey)
    guard let legacy else { return true }
    let settingsDone = UserDefaults.standard.bool(forKey: PhoneStorageMigration.settingsMarkerKey)
    let filesDone = PhoneStorageMigration.isDone(from: legacy)
    if settingsDone && filesDone { return true }
    // Before the first unlock (a background launch) the old files and defaults cannot be read.
    guard PhoneStorageMigration.canUseProtectedData(in: legacy) else {
      log.notice("storage migration waits for protected data")
      return false
    }
    if !settingsDone, let group = UserDefaults(suiteName: PhoneAppGroup.identifier) {
      PhoneStorageMigration.migrateSettings(
        from: .standard, to: group, legacyDomain: Bundle.main.bundleIdentifier)
    }
    guard !filesDone else { return true }
    do {
      let report = try PhoneStorageMigration.migrateApp(from: legacy, to: storage.url)
      log.notice(
        "storage migrated to the App Group: moved \(report.moved) kept-aside \(report.kept) superseded \(report.superseded) same \(report.deduplicated) failed \(report.failed)"
      )
      guard report.failed == 0 else { return false }
      // The share extension now uses the group; the copy of the phone's key handed to it through
      // the keychain (ShareHandoff) is no longer needed, nor are the voice records the keyboard
      // and the app exchanged through the shared keychain group.
      ShareHandoff.keychain()?.clearPairing()
      if let group = PhoneLink.keychainGroup() { KeychainRecords(accessGroup: group).removeAll() }
      return true
    } catch {
      log.error("storage migration: \(String(describing: error), privacy: .public)")
      return false
    }
  }

  /// The launch could not finish the migration (protected data, a file): try again now.
  private func retryStorageMigration() {
    guard !storageMigrated, let storage else { return }
    storageMigrated = Self.migrateStorage(storage)
    pairing.reload()
    if route == .welcome, settings.welcomeDone || pairing.isPaired { route = .home }
  }

  // MARK: - Apple Watch

  /// Receives recordings from Apple Watch (WATCH-004). Started at every launch, including one in
  /// the background for a recording the watch sends.
  private func connectWatch() {
    guard let inbox = WatchRecordings.makeInbox() else {
      Logger(subsystem: PhoneNames.appLog, category: "watch").error(
        "watch recordings unavailable")
      return
    }
    let recordings = WatchRecordings(inbox: inbox, delivery: delivery)
    watchRecordings = recordings
    PhoneWatchLink.shared.activate(inbox: inbox) { recording in recordings.stored(recording) }
  }

  /// The one-time notice that a recording from Apple Watch is kept only on this iPhone until it
  /// is in a backup. Called while Home is in front: it is claimed only here, so a recording that
  /// arrived with the app in the background still gets its notice at the next opening, and once
  /// claimed it never comes back (`WatchRecordingInbox.claimBackupNotice`).
  func presentWatchBackupNoticeIfDue() {
    guard !watchBackupNoticeSettled, !watchBackupNoticeShown, let inbox = watchRecordings?.inbox,
      UIApplication.shared.applicationState == .active, !inbox.all().isEmpty
    else { return }
    watchBackupNoticeSettled = true
    if inbox.claimBackupNotice() { watchBackupNoticeShown = true }
  }

  // MARK: - Keyboard

  /// A Full Access report older than this is treated as unknown (Full Access may be off now).
  static let keyboardStatusLifetime: TimeInterval = 24 * 60 * 60

  func refreshKeyboardStatus() {
    #if DEBUG
      if let forced = DebugLaunch.keyboard {
        keyboardAdded = forced.added
        keyboardFullAccess = forced.fullAccess
        return
      }
    #endif
    let status = voice.channel.readKeyboardStatus() ?? container.flatMap(KeyboardStatus.read(from:))
    let listed =
      (UserDefaults.standard.array(forKey: "AppleKeyboards") as? [String])?
      .contains(PhoneAppGroup.keyboardBundleID) ?? false
    keyboardAdded = listed || status != nil
    // Without Full Access the keyboard cannot write anything, so its last report may be old:
    // trust it only while it is recent.
    let seen = status.map { Date(timeIntervalSince1970: $0.seenAt) }
    let fresh = seen.map { Date().timeIntervalSince($0) < Self.keyboardStatusLifetime } ?? false
    keyboardFullAccess = status?.hasFullAccess == true && fresh
  }

  /// Hands the pairing to the share extension (only without the App Group).
  func syncShareHandoff() {
    guard let shareHandoff else { return }
    if let record = pairing.record, let key = pairing.keychain.load() {
      try? shareHandoff.writePairing(record, phoneKey: key)
    } else {
      shareHandoff.clearPairing()
    }
  }

  // MARK: - Keyboard speech for the Mac

  /// 「键盘说的话也送到 Mac」 (PHONE-SPEC §7.1, §7.6): every final the keyboard inserted becomes an
  /// item (source 键盘), held for the keyboard's undo window, then sent. The app keeps it, not the
  /// keyboard, so the keyboard never needs the outbox or the pairing.
  func wireKeyboardSpeech() {
    voice.onKeyboardInserted = { [weak self] final, at in self?.keepKeyboardSpeech(final, at: at) }
    voice.onKeyboardWithdrawn = { [weak self] seq in
      guard let self, let id = self.keyboardItems.removeValue(forKey: seq) else { return }
      self.delivery.withdraw(itemID: id)
    }
  }

  private func keepKeyboardSpeech(_ final: VoiceText, at: Date) {
    guard settings.sendKeyboardSpeech else { return }
    let text = PhoneTextRules.finalized(final.text)
    guard !text.isEmpty else { return }
    let item = PhoneItem(createdAt: at, kind: .text, source: .keyboard, text: text)
    do {
      let payload = try InboxItemPayload.text(text, source: .keyboard, createdAt: at)
      let saved = try delivery.collector.collect(
        item, payloads: [payload],
        heldUntil: at.addingTimeInterval(KeyboardVoiceController.undoWindow + 0.3))
      keyboardItems[final.seq] = saved.id
      if keyboardItems.count > 16, let oldest = keyboardItems.keys.min() {
        keyboardItems[oldest] = nil
      }
      delivery.refresh()
    } catch {
      Logger(subsystem: PhoneNames.appLog, category: "keyboard").error(
        "keyboard item not kept: \(String(describing: error), privacy: .public)")
    }
  }

  // MARK: - Pairing

  enum PairingState: Equatable {
    case never
    case paired(name: String)
    case disconnected
  }

  var pairingState: PairingState {
    if let record = pairing.record { return .paired(name: record.label) }
    return settings.disconnected ? .disconnected : .never
  }

  var macName: String? { pairing.record?.label }

  var homeStatus: HomeStatus {
    let pairing: HomeStatus.Pairing =
      switch pairingState {
      case .never: .never
      case .disconnected: .disconnected
      case .paired(let name): .paired(name: name)
      }
    return HomeStatus.derive(
      pairing: pairing, unreachable: delivery.unreachable, pending: delivery.pendingCount,
      itemCount: delivery.rows.count, lastSentAt: delivery.lastSentAt ?? latestSentAt)
  }

  private var latestSentAt: Date? {
    delivery.rows.compactMap(\.sentAt).max()
  }

  /// Opens the camera pairing screen.
  func startPairing(fromFirstRun: Bool) {
    pairFromFirstRun = fromFirstRun
    showsPair = true
  }

  /// 连接 on the found sheet: store the pairing, then Permissions on a first run, otherwise Home.
  func confirmPairing(_ text: String) throws {
    try pairing.pair(text: text)
    settings.pairedAt = Date()
    settings.disconnected = false
    settings.welcomeDone = true
    syncShareHandoff()
    delivery.paired()
    showsPair = false
    if pairFromFirstRun && !(voice.microphone == .granted && keyboardAdded && keyboardFullAccess) {
      route = .permissions
    } else {
      route = .home
    }
  }

  /// × on the camera screen.
  func closePairing() {
    showsPair = false
    route = pairFromFirstRun && !settings.welcomeDone ? .welcome : .home
  }

  /// 稍后 on Welcome.
  func skipWelcome() {
    settings.welcomeDone = true
    route = .home
  }

  /// 断开: forget the Mac; what has not left stays on the phone.
  func disconnect() {
    pairing.unpair()
    syncShareHandoff()
    settings.disconnected = true
    navigationPath = []
    delivery.refresh()
  }

  // MARK: - Life cycle

  func becameActive() {
    retryStorageMigration()
    pairing.reload()
    delivery.sealPending()
    refreshKeyboardStatus()
    voice.refreshMicrophone()
    delivery.startMonitoring()
    delivery.prune()
    watchRecordings?.process()
    voice.touch()
    liveActivity.foreground()
    if voice.microphone == .granted { voice.prewarm() }
    Task { await delivery.deliver() }
  }

  func enteredBackground() {
    // The speak bar never listens behind the user's back.
    talk.leaveApp()
    delivery.scheduleBackgroundRefresh()
    // The tip is for this visit only.
    showsBounceTip = false
  }

  /// `mindloom://voice/start` from the keyboard: start the session and show the tip the first
  /// three times (PHONE-SPEC §7.2).
  func open(_ url: URL) {
    guard url.scheme == PhoneAppGroup.urlScheme else { return }
    if url.host() == "voice", url.path().hasPrefix("/start") {
      route = settings.welcomeDone || pairing.isPaired ? .home : route
      if settings.bounceTipsShown < 3 {
        settings.bounceTipsShown += 1
        showsBounceTip = true
      }
      Task { await voice.start() }
    } else if url.host() == "pair" {
      // mindloom://pair/mlpair1.… carries the code: straight to the found sheet.
      let code = PairView.pairingText(url.absoluteString)
      pendingPairCode = PairView.macName(code) == nil ? nil : code
      startPairing(fromFirstRun: route == .welcome)
    } else if url.host() == "settings", url.path().hasPrefix("/microphone") {
      // The keyboard's 「麦克风没有打开 去设置」: iOS Settings › Mindloom.
      if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(settingsURL)
      }
    } else if url.host() == "settings", url.path().hasPrefix("/keyboard") {
      // The keyboard without Full Access: the Mindloom 键盘 page with the steps.
      if settings.welcomeDone || pairing.isPaired { route = .home }
      navigationPath = [.settings, .keyboard]
    }
  }
}
