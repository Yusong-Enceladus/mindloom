import Darwin
import Foundation
import MindloomIdentity

/// The owner's library folder after the rename (2026-10-06):
/// `~/Library/Application Support/bestASR` becomes
/// `~/Library/Application Support/Mindloom`. Only the switch script moves it,
/// after bestASR has quit, the backup is taken and nothing holds the database
/// open (review of the rename, 10-6: a move by the App itself had no backup,
/// no record a rollback could follow, and after a rollback it would have
/// taken the folder from bestASR again). Mindloom itself never moves, merges
/// or empties either folder: it opens its own when that holds the library,
/// and otherwise refuses while bestASR's holds it, so there is never a
/// second, empty library beside the owner's.
public enum LibraryFolderCarryOver {
  public enum Outcome: Equatable, Sendable {
    /// Mindloom's folder holds the library, or neither folder does (a new
    /// library).
    case ready
    /// Both hold a library: Mindloom's opens; bestASR's stays as it is.
    case bothPresent
    /// Only bestASR's folder holds the library, and bestASR is running.
    case previousAppRunning
    /// Only bestASR's folder holds the library (before the switch, or after
    /// a rollback). Mindloom opens nothing; a Mindloom folder without a
    /// library (an eval script's, an empty one) changes nothing here.
    case atPreviousLocation
  }

  /// `previous` and `current` are siblings (`bestASR`, `Mindloom`).
  /// `previousAppRunning`: bestASR runs now (only changes what the refusal
  /// says). Reads only; never changes either folder.
  public static func check(previous: URL, current: URL, previousAppRunning: () -> Bool)
    -> Outcome
  {
    let currentHolds = holdsLibrary(current)
    let previousHolds = holdsLibrary(previous)
    if currentHolds { return previousHolds ? .bothPresent : .ready }
    guard previousHolds else { return .ready }
    return previousAppRunning() ? .previousAppRunning : .atPreviousLocation
  }

  /// The team-signed product: `app.mindloom` signed with a team (the release
  /// `build_release.sh` makes). Only it imports bestASR's preferences into
  /// its domain; an ad hoc build with the same bundle id (the gate's Release
  /// build, registered by Xcode) opened by mistake must not use up that
  /// one-time import.
  public static func isTeamSignedProduct(bundleID: String?, signingTeam: String?) -> Bool {
    guard bundleID == MindloomIdentity.bundleID, let signingTeam else { return false }
    return !signingTeam.isEmpty
  }

  /// The previous library folder next to `current` (`…/bestASR`).
  public static func previousFolder(besides current: URL) -> URL {
    current.deletingLastPathComponent()
      .appendingPathComponent(MindloomIdentity.Previous.libraryFolderName, isDirectory: true)
  }

  /// A folder (or a link to one) whose `history.sqlite` is a file: the
  /// library's database. Anything else there (an eval set, a `.DS_Store`)
  /// is no library.
  public static func holdsLibrary(_ folder: URL) -> Bool {
    var entry = stat()
    let database = folder.appendingPathComponent("history.sqlite").path
    guard stat(database, &entry) == 0 else { return false }
    return entry.st_mode & S_IFMT == S_IFREG
  }
}
