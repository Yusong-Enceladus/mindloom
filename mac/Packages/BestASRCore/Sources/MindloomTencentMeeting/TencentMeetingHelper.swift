import Darwin
import Foundation
import Security

/// The tmeet Mindloom ships (`Contents/Helpers/tmeet`): TencentCloud's
/// tencentmeeting-cli built from pinned source with Mindloom's patches
/// (`third_party/tencentmeeting-cli`). Keep `version` equal to that folder's
/// `VERSION` file (a test checks).
public enum TencentMeetingHelper {
  public static let version = "v1.0.18-mindloom3"
  public static let relativePath = "Contents/Helpers/tmeet"

  /// The helper inside an App bundle, when it is there and executable.
  public static func bundled(in bundle: URL) -> URL? {
    let url = bundle.appendingPathComponent(relativePath)
    var entry = stat()
    guard lstat(url.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG,
      access(url.path, X_OK) == 0
    else { return nil }
    return url
  }

  /// tmeet's own folder in the library's private `entries` folder (0700):
  /// its login (encrypted with Mindloom's key) and its 7-day local log.
  public static func stateDirectory(dataRoot: URL) -> URL {
    dataRoot.appendingPathComponent("entries/tencent-meeting", isDirectory: true)
  }

  /// Where a new login is made while the one in use stays (reconnecting
  /// before the old login has ended); it replaces the old one once allowed.
  public static func newLoginDirectory(dataRoot: URL) -> URL {
    dataRoot.appendingPathComponent("entries/tencent-meeting-new", isDirectory: true)
  }
}

/// Decides whether a helper may be given the login's key (the runner asks
/// before every run that hands it over).
public struct TencentMeetingHelperCheck: Sendable {
  private let check: @Sendable (URL) -> Bool

  public init(_ check: @escaping @Sendable (URL) -> Bool) {
    self.check = check
  }

  public func trusts(_ helper: URL) -> Bool { check(helper) }

  /// No check. Only for the developer's probe on a tmeet built outside the
  /// App and for tests with a fake tmeet; the App never uses it.
  public static let unchecked = TencentMeetingHelperCheck { _ in true }

  /// The App's check: the helper is the code sealed into the App that is
  /// running. The first time (and again whenever the helper changes): the
  /// App on disk is the App running, its seal holds for every resource and
  /// nested code (a file put at `Contents/Helpers/tmeet` after the App was
  /// signed breaks it), and the helper's code hash is pinned. Every run then
  /// validates the helper in full against that hash. Works the same for an
  /// ad-hoc and a Developer ID signature.
  public static func sealedIntoRunningApp(_ bundle: URL) -> TencentMeetingHelperCheck {
    let pin = TencentMeetingHelperPin(
      bundle: bundle, runningAppIsOnDisk: TencentMeetingHelperSignature.runningCodeIsOnDisk)
    return TencentMeetingHelperCheck { pin.trusts($0) }
  }
}

/// The pinned code hash of the App's helper (see
/// `TencentMeetingHelperCheck.sealedIntoRunningApp`).
final class TencentMeetingHelperPin: @unchecked Sendable {
  let bundle: URL
  private let runningAppIsOnDisk: @Sendable () -> Bool
  private let lock = NSLock()
  private var pinned: Data?

  init(bundle: URL, runningAppIsOnDisk: @escaping @Sendable () -> Bool) {
    self.bundle = bundle.standardizedFileURL
    self.runningAppIsOnDisk = runningAppIsOnDisk
  }

  func trusts(_ helper: URL) -> Bool {
    let expected = bundle.appendingPathComponent(TencentMeetingHelper.relativePath)
      .standardizedFileURL
    guard helper.standardizedFileURL.path == expected.path else { return false }
    if let pinned = lock.withLock({ self.pinned }),
      TencentMeetingHelperSignature.validate(helper, cdhash: pinned)
    {
      return true
    }
    // First use, or the helper changed: the App and its seal again. The
    // helper's hash is read before and after, so a file swapped in while
    // the seal is checked is not pinned.
    guard let before = TencentMeetingHelperSignature.cdhash(helper), runningAppIsOnDisk(),
      TencentMeetingHelperSignature.bundleIsSealed(bundle),
      let after = TencentMeetingHelperSignature.cdhash(helper), before == after,
      TencentMeetingHelperSignature.validate(helper, cdhash: after)
    else {
      lock.withLock { pinned = nil }
      return false
    }
    lock.withLock { pinned = after }
    return true
  }
}

/// Code signature checks with the Security framework (no network).
enum TencentMeetingHelperSignature {
  /// The code directory hash of the signed code at `url`; nil when it is
  /// unsigned or unreadable.
  static func cdhash(_ url: URL) -> Data? {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code
    else { return nil }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        == errSecSuccess,
      let values = information as? [String: Any]
    else { return nil }
    return values[kSecCodeInfoUnique as String] as? Data
  }

  /// The code at `url` is intact (its pages included) and its code
  /// directory hash is `cdhash` (the architecture this Mac runs; tmeet is
  /// built for arm64 only).
  static func validate(_ url: URL, cdhash: Data) -> Bool {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
      return false
    }
    let hex = cdhash.map { String(format: "%02x", $0) }.joined()
    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString("cdhash H\"\(hex)\"" as CFString, [], &requirement)
        == errSecSuccess, let requirement
    else { return false }
    let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSRestrictSidebandData)
      .union(.noNetworkAccess)
    return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
  }

  /// The App bundle's seal holds: its signature, every resource and every
  /// nested code (`Contents/Helpers` included). The main executable's pages
  /// are left to the system, which checks them as the App runs.
  static func bundleIsSealed(_ bundle: URL) -> Bool {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
      return false
    }
    let flags = SecCSFlags(
      rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSDoNotValidateExecutable
    ).union(.noNetworkAccess)
    return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
  }

  /// The running process is valid and the App on disk is the one it was
  /// started from (not a bundle signed again since launch).
  @Sendable static func runningCodeIsOnDisk() -> Bool {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
    return SecCodeCheckValidity(code, [], nil) == errSecSuccess
  }
}
