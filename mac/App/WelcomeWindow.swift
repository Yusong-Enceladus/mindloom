import AppKit
import BestASRDictation
import BestASRMemoryUI
import BestASRRemoteOrganizer
import MindloomLibrary
import SwiftUI

// OWNER: mac-capture. Welcome (MAC-SPEC §10): its own 680 × 600 window on
// the first launch, the main window hidden until it is done; the three
// steps wired to the real permission prompts, the DGX Spark link, the
// iPhone pairing code and (Mindloom Preview) the model import. fn does not
// dictate while it is open.

@MainActor
enum WelcomeFlow {
  static let doneKey = "v11.welcome-done"

  static var isDone: Bool {
    get { LocalPreferenceStore.defaults.bool(forKey: doneKey) }
    set { LocalPreferenceStore.defaults.set(newValue, forKey: doneKey) }
  }

  /// UI tests and hosted unit tests skip it.
  static var applies: Bool {
    !isDone && !BestASRProcessEnvironment.isXCTestHost
      && !ProcessInfo.processInfo.arguments.contains("--ui-testing")
  }
}

/// True while Welcome is on screen (fn is blocked during it).
@MainActor
enum WelcomeState {
  static var isOpen = false
}

struct WelcomeScene: View {
  @ObservedObject var model: DictationAppModel
  @ObservedObject private var phone: PhoneLinkModel
  @ObservedObject private var onboarding: OnboardingModel
  @ObservedObject private var capture = CaptureState.shared
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var step = WelcomeStep.title
  @State private var connecting = false
  /// The current tagline (docs/TAGLINES.md), picked as the window opens; on a
  /// new install the line marked first.
  @State private var tagline: MindloomTagline?

  init(model: DictationAppModel) {
    self.model = model
    phone = model.phoneLink
    onboarding = model.onboarding
  }

  var body: some View {
    MindloomFixedWindow(size: CGSize(width: 680, height: 600)) {
      WelcomeView(input: input, actions: actions)
    }
      .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.36), value: step)
      .environment(\.locale, Locale(identifier: "zh-Hans"))
      .onAppear {
        WelcomeState.isOpen = true
        let board = MindloomTaglineBoard(defaults: LocalPreferenceStore.defaults)
        let language = model.spoken.interfaceLanguageID
        tagline = board.line(zone: model.productTimeZone, interfaceLanguage: language)
        model.refreshPermissions()
        model.refreshModelImportOffer()
        FnGuard.shared.attach(model)
      }
      .onDisappear {
        WelcomeState.isOpen = false
        model.finishPhonePairingCode()
      }
      .onChange(of: model.remoteOrganizerLinkStatus) { _, status in
        if status != .connecting { connecting = false }
      }
      #if MINDLOOM_PREVIEW
        // The live verification run steps through Welcome (LiveShots).
        .onReceive(LiveShots.welcomeSteps) { if let next = $0 { step = next } }
      #endif
  }

  private var input: WelcomeInput {
    WelcomeInput(
      step: step, microphoneOn: model.capture.microphonePermission == .granted,
      accessibilityOn: onboarding.accessibilityPermission == .granted,
      sparkConnected: model.remoteOrganizerLinkStatus == .connected,
      sparkFound: DictationAppModel.configuredRemoteOrganizerHost() != nil,
      sparkConnecting: connecting && model.remoteOrganizerLinkStatus != .connected,
      iphoneName: phone.paired == nil ? nil : "iPhone",
      qrShown: phone.pairingCode != nil || phone.working,
      models: capture.modelImportOffer.map(Self.models),
      fromBestASR: LocalPreferenceStore.defaults.bool(forKey: ProductCarryOver.cameFromBestASRKey),
      sparkAvailable: model.remoteOrganizerCanConnect, tagline: tagline)
  }

  private var actions: WelcomeActions {
    let model = model
    return WelcomeActions(
      setStep: { step = $0 },
      allowMicrophone: { model.resolvePermission(.microphone) },
      allowAccessibility: { model.resolvePermission(.accessibility) },
      importModels: { model.importInstalledModels() },
      connectSpark: {
        connecting = true
        if model.remoteOrganizerEnabled {
          model.reconnectRemoteOrganizer()
        } else {
          model.setRemoteOrganizerEnabled(true)
        }
        // No link to start (no Spark named, or the library may not be
        // sent): nothing will change the status, so no spinner either.
        if !model.remoteOrganizerCanConnect { connecting = false }
      },
      toggleQR: {
        if phone.pairingCode != nil || phone.working {
          model.finishPhonePairingCode()
        } else {
          model.connectIPhone()
        }
      },
      finish: { finish() },
      qr: phone.pairingCode.flatMap { PhonePairingQRCode.image(for: $0) })
  }

  private func finish() {
    WelcomeFlow.isDone = true
    WelcomeState.isOpen = false
    model.finishPhonePairingCode()
    MainWindow.show(openWindow)
    dismissWindow(id: "welcome")
  }

  static func models(_ offer: SettingsModelImport) -> WelcomeModels {
    switch offer {
    case .offered: .offered
    case .working: .working
    case .ready: .ready
    case .failed(let why): .failed(why)
    }
  }
}
