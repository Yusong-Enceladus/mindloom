import AppKit
import BestASRRemoteOrganizer
import Foundation
import MindloomIdentity
import MindloomLibrary

/// Which build this is, and what that changes (v11 FOUNDATION.md §Preview,
/// v12 phase B).
///
/// - Release (`MINDLOOM_RELEASE`, `app.mindloom`): the product. Opens the
///   owner's library by default.
/// - Mindloom Preview (`MINDLOOM_PREVIEW`, `com.bestasr.mindloom.preview`):
///   its own defaults domain, URL scheme, extension IDs, cache folder and
///   synthetic data root (`MindloomPreviewDataRoot` in its Info.plist); it
///   opens that root in demo mode and never the real library.
/// - Debug and every other configuration: never opens the real library by
///   default (`MindloomLaunch`); its own URL scheme (`mindloom-debug`), link
///   state folder and share drop folder.
enum MindloomBuild {
  #if MINDLOOM_PREVIEW
    static let flavor = MindloomBuildFlavor.preview
  #elseif MINDLOOM_RELEASE
    static let flavor = MindloomBuildFlavor.release
  #else
    static let flavor = MindloomBuildFlavor.development
  #endif

  static var isPreview: Bool { flavor == .preview }

  /// The App's own URL scheme (`mindloom`, `mindloom-preview` or
  /// `mindloom-debug`), from its Info.plist, so the share extension of one
  /// build never pokes another.
  static var urlScheme: String {
    urlScheme(infoDictionary: Bundle.main.infoDictionary ?? [:])
  }

  static func urlScheme(infoDictionary: [String: Any]) -> String {
    let types = infoDictionary["CFBundleURLTypes"] as? [[String: Any]] ?? []
    let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    return schemes.first { !$0.isEmpty && !$0.hasPrefix("$(") } ?? "mindloom"
  }

  /// The cache folder name under `~/Library/Caches`: the preview never shares
  /// the App's caches or model downloads, and a preview copy run under its
  /// own bundle ID (a check build on a demo clone) never shares the preview's.
  static var cacheFolderName: String {
    let id = Bundle.main.bundleIdentifier ?? ""
    guard isPreview else {
      // A verification copy of the product keeps its own too.
      return MindloomIdentity.isCheckIdentity(id) ? id : MindloomIdentity.bundleID
    }
    return id.hasPrefix("com.bestasr.mindloom.") ? id : "com.bestasr.mindloom.preview"
  }

  /// The folder (in Application Support) for the organizing link's state:
  /// ssh tunnel records, link-on files and the iPhone pairing. Each build
  /// keeps its own, and demo mode in the product keeps its own too, so a
  /// demo or a development build never touches the product's.
  static func organizerLinkStateFolderName(
    flavor: MindloomBuildFlavor = flavor, demo: Bool = MindloomLaunch.isDemo
  ) -> String {
    switch flavor {
    case .preview: "bestASR-organizer-link-preview"
    case .development: "Mindloom-organizer-link-debug"
    case .release: demo ? "Mindloom-organizer-link-demo" : "Mindloom-organizer-link"
    }
  }

  /// The organizer link key's store for this data root: in demo mode a
  /// marked synthetic root keeps its key as `organizer-link.key` in the root
  /// (the demo Spark instance's store was made with it); everything else
  /// uses the login Keychain.
  static func organizerKeyStore(dataRoot: URL) -> any OrganizerKeyStore {
    if MindloomLaunch.isDemo, let file = try? FileOrganizerKeyStore(dataRoot: dataRoot) {
      return file
    }
    return KeychainOrganizerKeyStore(dataRoot: dataRoot)
  }

  /// The user's own Mindloom (any build), and bestASR before it, which also
  /// listen to fn.
  static let otherFnAppBundleIDs = [
    MindloomIdentity.bundleID, MindloomIdentity.debugBundleID,
    MindloomIdentity.Previous.bundleID, MindloomIdentity.Previous.debugBundleID,
  ]

  /// True while the preview runs beside the user's own App: the preview
  /// then does not arm fn (one fn press would dictate twice).
  @MainActor
  static var otherAppHoldsFn: Bool {
    guard isPreview else { return false }
    return otherFnAppBundleIDs.contains {
      !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
    }
  }
}
