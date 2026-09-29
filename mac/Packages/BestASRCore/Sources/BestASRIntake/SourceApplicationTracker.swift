import AppKit
import BestASRDomain
import Foundation

/// One App activation seen by the tracker.
public struct TrackedApplication: Equatable, Sendable {
  public let bundleID: String?
  public let name: String?
  public let activatedAt: Date
  /// A regular App with a Dock icon. Launchers, password-manager panels,
  /// and the screenshot UI are accessory Apps and never become a source.
  public let isRegular: Bool

  public init(bundleID: String?, name: String?, activatedAt: Date, isRegular: Bool = true) {
    self.bundleID = bundleID
    self.name = name
    self.activatedAt = activatedAt
    self.isRegular = isRegular
  }

  public var source: ItemSourceApplication? {
    ItemSourceApplication(bundleID: bundleID, name: name)
  }
}

/// Pure state of "which App was the user in before bestASR". Testable without
/// real Apps; the workspace tracker only feeds it activation notifications.
public struct SourceApplicationTrackerState: Equatable, Sendable {
  public static let finderBundleID = "com.apple.finder"
  public static let finderFallbackName = "访达"

  public let ownBundleID: String?
  /// The most recently activated regular App that is not bestASR.
  public private(set) var lastExternal: TrackedApplication?
  /// The App that is frontmost now (may be bestASR).
  public private(set) var frontmost: TrackedApplication?

  public init(ownBundleID: String?) {
    self.ownBundleID = ownBundleID
  }

  public mutating func activated(_ application: TrackedApplication) {
    frontmost = application
    if !isOwn(application), application.isRegular { lastExternal = application }
  }

  public func isOwn(_ application: TrackedApplication) -> Bool {
    guard let ownBundleID, let bundle = application.bundleID else { return false }
    return bundle == ownBundleID
  }

  /// Paste or the "收进来" command: the App that was frontmost just before
  /// bestASR became active.
  public func sourceForPaste() -> (ItemSourceApplication?, ItemSourceOrigin) {
    guard let source = lastExternal?.source else { return (nil, .unknown) }
    return (source, .previousFrontmost)
  }

  /// A drop. While bestASR is inactive the frontmost regular App is the drag
  /// source (Finder for files dragged from Finder). While bestASR is active,
  /// files come from a background Finder window or the Desktop, so they are
  /// labelled Finder; other content gets the App the user was in before.
  public func sourceForDrop(
    ownAppIsActive: Bool, containsFiles: Bool, finderName: String = finderFallbackName
  ) -> (ItemSourceApplication?, ItemSourceOrigin) {
    if ownAppIsActive, containsFiles,
      let finder = ItemSourceApplication(bundleID: Self.finderBundleID, name: finderName)
    {
      return (finder, .finder)
    }
    let candidate: TrackedApplication?
    if !ownAppIsActive, let frontmost, !isOwn(frontmost), frontmost.isRegular {
      candidate = frontmost
    } else {
      candidate = lastExternal
    }
    guard let candidate, let source = candidate.source else { return (nil, .unknown) }
    if containsFiles, candidate.bundleID == Self.finderBundleID { return (source, .finder) }
    return (source, ownAppIsActive ? .previousFrontmost : .dragSource)
  }
}

/// Supplies the source label for a paste or a drop.
@MainActor
public protocol SourceApplicationProviding: AnyObject {
  func sourceForPaste() -> (ItemSourceApplication?, ItemSourceOrigin)
  func sourceForDrop(containsFiles: Bool) -> (ItemSourceApplication?, ItemSourceOrigin)
}

/// Follows `NSWorkspace` activation notifications. Keeps only a bundle ID,
/// a display name, and a time in memory; never logs them.
@MainActor
public final class WorkspaceSourceApplicationTracker: SourceApplicationProviding {
  private var state: SourceApplicationTrackerState
  nonisolated(unsafe) private var observer: NSObjectProtocol?

  public init(ownBundleID: String? = Bundle.main.bundleIdentifier) {
    state = SourceApplicationTrackerState(ownBundleID: ownBundleID)
    if let frontmost = NSWorkspace.shared.frontmostApplication {
      state.activated(Self.tracked(frontmost))
    }
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication
      else { return }
      let tracked = Self.tracked(application)
      MainActor.assumeIsolated { self?.state.activated(tracked) }
    }
  }

  deinit {
    if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
  }

  public func sourceForPaste() -> (ItemSourceApplication?, ItemSourceOrigin) {
    state.sourceForPaste()
  }

  public func sourceForDrop(containsFiles: Bool) -> (ItemSourceApplication?, ItemSourceOrigin) {
    // Refresh from the system: a drop does not activate bestASR.
    if let frontmost = NSWorkspace.shared.frontmostApplication {
      state.activated(Self.tracked(frontmost))
    }
    let finderName =
      NSRunningApplication.runningApplications(
        withBundleIdentifier: SourceApplicationTrackerState.finderBundleID
      ).first?.localizedName ?? SourceApplicationTrackerState.finderFallbackName
    return state.sourceForDrop(
      ownAppIsActive: NSApplication.shared.isActive, containsFiles: containsFiles,
      finderName: finderName
    )
  }

  private nonisolated static func tracked(_ application: NSRunningApplication)
    -> TrackedApplication
  {
    TrackedApplication(
      bundleID: application.bundleIdentifier, name: application.localizedName,
      activatedAt: Date(), isRegular: application.activationPolicy == .regular
    )
  }
}
