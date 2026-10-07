import CryptoKit
import Darwin
import Foundation

/// Mindloom's identity on the Mac and the iPhone, in one place (the owner's
/// decision of 2026-10-06: `app.mindloom`; `com.mindloom.app` was already
/// taken on Apple's side). Everything else is derived from `bundleID`.
///
/// The build files carry the same value once each, and
/// `MindloomIdentityTests` keeps them equal to this one: `project.yml`
/// (`MINDLOOM_BUNDLE_ID`), `iOS/project.yml` (`MINDLOOM_PHONE_BUNDLE_ID`) and
/// `script/identity.sh` (`MINDLOOM_BUNDLE_ID`, for the shell scripts and the
/// agent launchers).
public enum MindloomIdentity {
  /// The App on the Mac and on the iPhone (one App ID, all platforms).
  public static let bundleID = "app.mindloom"
  /// The iPhone's App Group (the Mac App uses none).
  public static let appGroup = "group." + bundleID
  /// Registered with the team; attached to no App ID or entitlement yet
  /// (sync comes later).
  public static let iCloudContainer = "iCloud." + bundleID
  /// The name people see: the App, its executable, menus, files.
  public static let displayName = "Mindloom"
  /// `mindloom://` (the share extensions' poke, the keyboard's voice link).
  public static let urlScheme = "mindloom"
  /// `~/Library/Application Support/Mindloom`: the owner's library.
  public static let libraryFolderName = displayName
  /// The development build's identity (`-configuration Debug`).
  public static let debugBundleID = bundleID + ".debug"

  /// What runs inside or beside the App, named `<bundle id>.<suffix>`.
  public enum Part: String, CaseIterable, Sendable {
    /// iPhone: the Mindloom keyboard.
    case keyboard
    /// Mac and iPhone: the share extension.
    case share
    /// iPhone: the voice session's Live Activity widget.
    case live
    /// Apple Watch (the watch stream derives its App the same way).
    case watch = "watchkitapp"
    /// Mac: the inference XPC service.
    case inferenceWorker = "inference-worker"
    /// Mac: the bundled MCP helper agents start (`Contents/Helpers/mindloom-mcp`).
    case mcp
  }

  public static func bundleID(of part: Part, base: String = bundleID) -> String {
    base + "." + part.rawValue
  }

  /// Generic passwords in the login keychain (Mac) or the App's keychain
  /// groups (iPhone): service `app.mindloom.<name>`.
  public static func keychainService(_ name: String) -> String { bundleID + "." + name }

  /// The unified log subsystem (categories tell the parts apart).
  public static let logSubsystem = bundleID

  /// A Darwin notification shared by the iPhone App and its extensions.
  public static func darwinNotification(_ name: String) -> String { bundleID + "." + name }

  /// A dispatch queue label.
  public static func queueLabel(_ name: String) -> String { bundleID + "." + name }

  /// Chrome's native messaging host (the manifest's file name and `name`).
  public static let nativeMessagingHost = bundleID

  /// The iPhone App's `BGAppRefreshTask` that sends the outbox.
  public static let outboxRefreshTask = bundleID + ".outbox-refresh"

  /// bestASR, the App Mindloom replaces on the owner's Mac (d54fb45, and the
  /// v12 builds before 2026-10-06). Read only to carry the owner over.
  public enum Previous {
    public static let bundleID = "com.bestasr.app"
    public static let debugBundleID = "com.bestasr.app.debug"
    /// `~/Library/Application Support/bestASR`.
    public static let libraryFolderName = "bestASR"
    /// The keychain services the v12 builds before 10-6 used:
    /// `com.bestasr.<name>` (the same `<name>` as `keychainService`).
    public static func keychainService(_ name: String) -> String { "com.bestasr." + name }
  }

  /// Verification copies (the check App, dry runs): never the product, never
  /// the owner's preferences, keychain items or library.
  public static let checkBundleIDPrefix = "com.bestasr.mindloom.check"

  public static func isCheckIdentity(_ identifier: String) -> Bool {
    identifier == checkBundleIDPrefix || identifier.hasPrefix(checkBundleIDPrefix + ".")
  }
}

/// The identity of a library root: its kernel-canonical path (`F_GETPATH`,
/// so symlinks, `/.nofollow` spellings and case variants give the same key),
/// SHA-256, the first 16 bytes in hex. It names the root's keychain accounts
/// and its organizing-link marker, so a library moved to another folder has a
/// new identity (the carry-over re-keys its items).
public enum LibraryRootIdentity {
  public static func hash(of root: URL) -> String {
    let standardized = root.standardizedFileURL.path
    let canonical =
      kernelPath(ofExisting: standardized)
      ?? root.standardizedFileURL.resolvingSymlinksInPath().path
    return SHA256.hash(data: Data(canonical.utf8))
      .prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  /// The kernel's path for an existing file (resolves symlinks, firmlinks and
  /// magic prefixes), or nil.
  public static func kernelPath(ofExisting path: String) -> String? {
    let descriptor = open(path, O_EVTONLY | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
    let result = buffer.withUnsafeMutableBytes {
      fcntl(descriptor, F_GETPATH, $0.baseAddress!)
    }
    guard result != -1 else { return nil }
    return String(
      decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}
