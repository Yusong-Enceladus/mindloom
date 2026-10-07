import BestASREntries
import Darwin
import Foundation

/// tmeet's login folders in the library's private `entries` folder: the one
/// in use (`tencent-meeting`) and the one a new login is made in
/// (`tencent-meeting-new`, see `TencentMeetingHelper.newLoginDirectory`).
/// tmeet refuses a new login while one holds, so reconnecting makes it
/// beside the old one and puts it in place once the owner allowed it;
/// cancelling leaves the old one as it was. Only folders with these names
/// inside an `entries` folder are ever moved or removed.
public enum TencentMeetingLoginFolders {
  /// Whether either folder is on this Mac.
  public static func exist(_ stateDirectory: URL, newLogin: URL? = nil) -> Bool {
    [stateDirectory, newLogin].compactMap { $0 }.contains {
      var entry = stat()
      return lstat($0.path, &entry) == 0
    }
  }

  /// Removes what an earlier attempt left in the new login's folder.
  public static func clearNewLogin(_ newLogin: URL) {
    guard isNewLoginFolder(newLogin) else { return }
    try? FileManager.default.removeItem(at: newLogin)
  }

  /// The new login replaces the one in use: the two folders are swapped in
  /// one step, then the old login is removed.
  public static func adopt(newLogin: URL, into stateDirectory: URL) throws {
    guard isNewLoginFolder(newLogin), isStateFolder(stateDirectory),
      newLogin.deletingLastPathComponent().standardizedFileURL.path
        == stateDirectory.deletingLastPathComponent().standardizedFileURL.path
    else { throw CocoaError(.fileWriteInvalidFileName) }
    var entry = stat()
    guard lstat(newLogin.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFDIR else {
      throw CocoaError(.fileNoSuchFile)
    }
    if lstat(stateDirectory.path, &entry) != 0 {
      guard rename(newLogin.path, stateDirectory.path) == 0 else {
        throw CocoaError(.fileWriteUnknown)
      }
      return
    }
    guard renamex_np(newLogin.path, stateDirectory.path, UInt32(RENAME_SWAP)) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
    // The old login is now in the new login's folder.
    try? FileManager.default.removeItem(at: newLogin)
  }

  /// Both folders (switching the entry off).
  public static func removeAll(stateDirectory: URL, newLogin: URL?) {
    if isStateFolder(stateDirectory) { try? FileManager.default.removeItem(at: stateDirectory) }
    if let newLogin { clearNewLogin(newLogin) }
  }

  static func isStateFolder(_ url: URL) -> Bool {
    url.lastPathComponent == "tencent-meeting"
      && url.deletingLastPathComponent().lastPathComponent == EntryFolder.name
  }

  static func isNewLoginFolder(_ url: URL) -> Bool {
    url.lastPathComponent == "tencent-meeting-new"
      && url.deletingLastPathComponent().lastPathComponent == EntryFolder.name
  }
}
