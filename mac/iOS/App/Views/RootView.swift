import MindloomDesign
import SwiftUI

/// The first-run screens, then Home with Settings pushed on the system navigation stack; pairing
/// over everything.
struct RootView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.colorScheme) private var scheme
  /// The first frames show the first screen as it is: no fade in at launch (PHONE-SPEC: content on
  /// the first frame, after the paper launch screen).
  @State private var launched = false

  var body: some View {
    @Bindable var model = model
    ZStack {
      switch model.route {
      case .welcome:
        WelcomeView(frozenTime: debugFrozen, reduceMotionOverride: debugReduceMotion)
          .transition(.opacity)
      case .permissions:
        NavigationStack { PermissionsView() }
          .transition(.opacity)
      case .home:
        NavigationStack(path: $model.navigationPath) {
          HomeView(frozenTime: debugFrozen, reduceMotionOverride: debugReduceMotion)
            .navigationDestination(for: SettingsRoute.self) { route in
              switch route {
              case .settings: SettingsView()
              case .autoEnd: AutoEndView()
              case .mac: MacPageView()
              case .privacy: PrivacyView()
              case .keyboard: KeyboardPageView()
              case .about: AboutView()
              case .licenses: LicensesView()
              }
            }
        }
        .transition(.opacity)
      }
    }
    .animation(launched ? .easeOut(duration: MLMotion.durBase) : nil, value: model.route)
    .task {
      try? await Task.sleep(for: .seconds(0.6))
      launched = true
    }
    .fullScreenCover(isPresented: $model.showsPair) {
      PairView(scheme: scheme)
    }
  }

  private var debugFrozen: TimeInterval? {
    #if DEBUG
      DebugLaunch.frozenTime
    #else
      nil
    #endif
  }

  private var debugReduceMotion: Bool? {
    #if DEBUG
      DebugLaunch.reduceMotion
    #else
      nil
    #endif
  }
}
