import Darwin
import Foundation
import MindloomIdentity

/// Which App this process carries the owner over from (its preferences
/// domain, and the signing identifier of the keychain helper): the product
/// from bestASR; a verification copy only from another verification copy
/// named with `-MindloomCarryOverFrom` (dry runs); anything else from none.
public enum CarryOverSource {
  public static let fromArgument = "MindloomCarryOverFrom"
  /// Verification copies only: the keychain file the dry run made.
  public static let keychainArgument = "MindloomCarryOverKeychain"

  public static func previousIdentity(ownBundleID: String?, arguments: [String]) -> String? {
    guard let ownBundleID else { return nil }
    if ownBundleID == MindloomIdentity.bundleID { return MindloomIdentity.Previous.bundleID }
    guard MindloomIdentity.isCheckIdentity(ownBundleID),
      let named = value(of: fromArgument, in: arguments),
      MindloomIdentity.isCheckIdentity(named), named != ownBundleID
    else { return nil }
    return named
  }

  /// The keychain file a verification copy was told to use (absolute), or nil.
  public static func keychainFile(ownBundleID: String?, arguments: [String]) -> URL? {
    guard let ownBundleID, MindloomIdentity.isCheckIdentity(ownBundleID),
      let path = value(of: keychainArgument, in: arguments), path.hasPrefix("/")
    else { return nil }
    return URL(fileURLWithPath: path)
  }

  /// The App a helper signed as `helperIdentifier` hands over to: bestASR's
  /// helper to Mindloom only; a verification helper to another verification
  /// copy it is told about; nothing else.
  public static func receiver(helperIdentifier: String, requested: String?) -> String? {
    if helperIdentifier == MindloomIdentity.Previous.bundleID {
      guard requested == nil || requested == MindloomIdentity.bundleID else { return nil }
      return MindloomIdentity.bundleID
    }
    guard MindloomIdentity.isCheckIdentity(helperIdentifier), let requested,
      MindloomIdentity.isCheckIdentity(requested), requested != helperIdentifier
    else { return nil }
    return requested
  }

  /// A helper signed as a check identity (dry runs) reads only the keychain
  /// file it is given (`--keychain`), never the login keychain; bestASR's
  /// own helper reads only the login keychain.
  public static func keychainFileRequired(helperIdentifier: String) -> Bool {
    MindloomIdentity.isCheckIdentity(helperIdentifier)
  }

  /// `--unregister-login-item` (the rollback): a helper signed as Mindloom
  /// (or, in a dry run, as a check identity) turns that identity's
  /// 「登录时打开」 off. bestASR's helper does not: it removes bestASR's item
  /// only after Mindloom took it over.
  public static func mayUnregisterLoginItem(helperIdentifier: String) -> Bool {
    helperIdentifier == MindloomIdentity.bundleID
      || MindloomIdentity.isCheckIdentity(helperIdentifier)
  }

  /// The folder a helper's offer was read for is bestASR's library folder
  /// beside `currentRoot` (the library Mindloom opened): named
  /// `MindloomIdentity.Previous.libraryFolderName` (any case) in the same
  /// parent folder, compared by the parent's file identity, so no spelling
  /// of the path (case, links) matters. The parent must exist; the folder
  /// itself has moved by then.
  public static func isPreviousLibrary(offered: String?, currentRoot: URL) -> Bool {
    guard let offered, offered.hasPrefix("/") else { return false }
    let folder = URL(fileURLWithPath: offered).standardizedFileURL
    guard
      folder.lastPathComponent.compare(
        MindloomIdentity.Previous.libraryFolderName, options: .caseInsensitive) == .orderedSame
    else { return false }
    var offeredParent = stat()
    var currentParent = stat()
    guard stat(folder.deletingLastPathComponent().path, &offeredParent) == 0,
      stat(currentRoot.standardizedFileURL.deletingLastPathComponent().path, &currentParent) == 0
    else { return false }
    return offeredParent.st_dev == currentParent.st_dev
      && offeredParent.st_ino == currentParent.st_ino
  }

  /// `-<key> <value>` exactly once.
  static func value(of key: String, in arguments: [String]) -> String? {
    let flags = arguments.indices.dropFirst().filter { arguments[$0] == "-" + key }
    guard flags.count == 1, let index = flags.first, index + 1 < arguments.count else {
      return nil
    }
    let value = arguments[index + 1]
    return value.isEmpty || value.hasPrefix("-") ? nil : value
  }
}
