import Foundation
import MindloomCarryOver
import MindloomIdentity
import MindloomLibrary
import OSLog
import ServiceManagement

/// What the owner brings from bestASR on Mindloom's first launch (switch
/// 2026-10-06, a new identity): bestASR's preferences, imported before
/// anything reads them, and its keychain items, taken from the switch's
/// helper when one waits. The library folder is moved by the switch script
/// only (`MindloomLaunch` refuses while it is still bestASR's). Only the
/// team-signed product, opening the owner's library, carries over from
/// bestASR; a verification copy only from another verification copy
/// (`CarryOverSource`).
enum CarryOverLaunch {
  private static let log = Logger(subsystem: MindloomIdentity.logSubsystem, category: "carry-over")
  private static var arguments: [String] { ProcessInfo.processInfo.arguments }
  private static var ownBundleID: String? { Bundle.main.bundleIdentifier }

  /// bestASR's settings into Mindloom's domain, once (`ProductCarryOver`),
  /// after `MindloomLaunch` decided the library: the product only when it is
  /// the team-signed one and opens the owner's library (an ad hoc build with
  /// the same bundle id, or a launch refused because the library is still
  /// bestASR's, must not use up the one-time import; review of 10-6).
  static func importPreferences(launch: Result<LibraryLaunch, LibraryLaunchError>) {
    guard
      let previous = CarryOverSource.previousIdentity(
        ownBundleID: ownBundleID, arguments: arguments),
      mayImport(
        ownBundleID: ownBundleID, signingTeam: CarryOverChannel.ownSignature()?.team,
        launch: launch)
    else { return }
    let count = ProductCarryOver.importPreferences(fromDomain: previous, into: .standard)
    if count > 0 { log.notice("imported \(count, privacy: .public) settings from bestASR") }
  }

  /// A verification copy imports from the copy it was told about (dry
  /// runs); the product only as the team-signed product on the owner's
  /// library.
  static func mayImport(
    ownBundleID: String?, signingTeam: String?, launch: Result<LibraryLaunch, LibraryLaunchError>
  ) -> Bool {
    if let ownBundleID, MindloomIdentity.isCheckIdentity(ownBundleID) { return true }
    guard
      LibraryFolderCarryOver.isTeamSignedProduct(bundleID: ownBundleID, signingTeam: signingTeam),
      case .success(let opened) = launch
    else { return false }
    return opened.mode == .ownerLibrary
  }

  /// The keychain items of the moved library, from the switch's helper. The
  /// product does this for the owner's library only; a verification copy
  /// only into the keychain file it was given.
  static func takeKeychainItems(launch: LibraryLaunch) {
    guard
      let previous = CarryOverSource.previousIdentity(
        ownBundleID: ownBundleID, arguments: arguments),
      let receiver = ownBundleID, let signature = CarryOverChannel.ownSignature(),
      let requirement = CarryOverChannel.requirement(identifier: previous, team: signature.team),
      let temporary = CarryOverChannel.userTemporaryDirectory()
    else { return }
    let file = CarryOverSource.keychainFile(ownBundleID: receiver, arguments: arguments)
    if MindloomIdentity.isCheckIdentity(receiver) {
      // A verification copy never touches the login keychain.
      guard file != nil else { return }
    } else {
      guard launch.mode == .ownerLibrary else { return }
    }
    let socket = CarryOverChannel.socketURL(receiver: receiver, temporaryDirectory: temporary)
    do {
      let keychain = try SystemCarryOverKeychain(file: file)
      let outcome = try KeychainCarryOverReceiver.run(
        socket: socket, check: CarryOverChannel.signatureCheck(requirement: requirement),
        // Only the items of bestASR's folder beside this library (review of
        // 10-6): a helper run by hand on another folder adds nothing here.
        acceptsLibrary: {
          CarryOverSource.isPreviousLibrary(offered: $0, currentRoot: launch.root)
        },
        newRoot: LibraryRootIdentity.hash(of: launch.root), keychain: keychain,
        registerLoginItem: {
          // Called synchronously from `run`, on the main thread `main()` runs on.
          MainActor.assumeIsolated {
            LoginItemRepair.adoptPreviousApp(
              service: MainAppLoginItem(), defaults: LocalPreferenceStore.defaults,
              currentPath: Bundle.main.bundleURL.path)
          }
        })
      guard let outcome else { return }
      log.notice(
        """
        keychain carry-over: offered \(outcome.offered, privacy: .public) \
        created \(outcome.created, privacy: .public) existing \(outcome.existing, privacy: .public) \
        failed \(outcome.failed, privacy: .public) unreadable \(outcome.unreadable, privacy: .public) \
        login item \(outcome.loginItemWasEnabled ? (outcome.loginItemRegistered ? "moved" : "not moved") : "off", privacy: .public)
        """)
    } catch {
      log.error("keychain carry-over failed: \(String(describing: error), privacy: .public)")
    }
  }
}
