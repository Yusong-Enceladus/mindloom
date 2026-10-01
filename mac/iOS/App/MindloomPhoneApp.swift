import BackgroundTasks
import MindloomPhoneKit
import SwiftUI
import UIKit

/// 织机 on the iPhone (PHONE-CONTRACT §1): pairing with the Mac, the voice
/// session behind 织机键盘, the outbox and the plain-words privacy page.
@main
struct MindloomPhoneApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = AppModel.make()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(model)
        .tint(Loom.accent)
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
        let work = Task { @MainActor in await AppModel.shared?.delivery.deliver() }
        refresh.expirationHandler = { work.cancel() }
        _ = await work.value
        AppModel.shared?.delivery.scheduleBackgroundRefresh()
        refresh.setTaskCompleted(success: true)
      }
    }
    return true
  }
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
  let container: URL?
  private(set) var keyboardStatus: KeyboardStatus?
  var showsPairing = false
  /// A short banner after the keyboard opened the app to start voice.
  var voiceBanner = false

  init(pairing: PairingModel, delivery: DeliveryService, voice: VoiceSessionModel, container: URL?)
  {
    self.pairing = pairing
    self.delivery = delivery
    self.voice = voice
    self.container = container
    showsPairing = !pairing.isPaired && !UserDefaults.standard.bool(forKey: "pairingDeferred")
    refreshKeyboardStatus()
    voice.onTick = { [weak delivery] in delivery?.retryIfDue() }
  }

  static func make() -> AppModel {
    let container = PhoneAppGroup.containerURL()
    let base =
      container
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let recordStore = PairingRecordStore(file: PhoneAppGroup.pairingRecordFile(in: base))
    let pairing = PairingModel(recordStore: recordStore)
    // The outbox and voice files live in the App Group; the fallback only
    // matters for a build without the entitlement.
    let outbox =
      (try? OutboxStore(root: PhoneAppGroup.outboxDirectory(in: base)))
      ?? (try! OutboxStore(
        root: FileManager.default.temporaryDirectory.appendingPathComponent("outbox")))
    let channel =
      (try? VoiceChannel(directory: PhoneAppGroup.voiceDirectory(in: base)))
      ?? (try! VoiceChannel(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("voice")))
    let model = AppModel(
      pairing: pairing, delivery: DeliveryService(outbox: outbox, pairing: pairing),
      voice: VoiceSessionModel(channel: channel), container: container)
    shared = model
    return model
  }

  func refreshKeyboardStatus() {
    keyboardStatus = container.flatMap(KeyboardStatus.read(from:))
  }

  var keyboardReady: Bool { keyboardStatus?.hasFullAccess == true }

  func becameActive() {
    pairing.reload()
    refreshKeyboardStatus()
    delivery.refresh()
    voice.touch()
    Task { await delivery.deliver() }
  }

  func enteredBackground() {
    delivery.scheduleBackgroundRefresh()
  }

  /// `mindloom://voice/start` from 织机键盘: start the session and say how to
  /// go back.
  func open(_ url: URL) {
    guard url.scheme == PhoneAppGroup.urlScheme, url.host() == "voice" else { return }
    if url.path().hasPrefix("/start") {
      voiceBanner = true
      Task { await voice.start() }
    }
  }

  func deferPairing() {
    UserDefaults.standard.set(true, forKey: "pairingDeferred")
    showsPairing = false
  }
}
