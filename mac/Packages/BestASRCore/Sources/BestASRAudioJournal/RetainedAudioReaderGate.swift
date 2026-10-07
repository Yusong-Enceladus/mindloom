import Foundation
import MindloomIdentity

/// Whether archived recordings may be written yet (review 10-6 S6).
///
/// Archival writes chunk files named `<track>-<sequence>.lossless.caf` (or
/// `.caf`). A build without `RetainedAudioCodec` — every build before v12
/// storage — rejects any chunk name but `.pcm` when it opens a journal, so a
/// recording archived by this build can no longer be played, exported or
/// recognized again by an older one. Nothing converts it back. The change is
/// forward-only, so the reader ships before the writer runs: each build that
/// reads archived chunks says so in its Info.plist (`readerKey`), and
/// archival runs only while every copy of the App installed on this Mac
/// says so. An older copy left anywhere holds archival back until it is
/// gone; the 16 kHz rewrite (plain `.pcm`) is not held back.
public enum RetainedAudioReaderGate {
  public static let readerKey = "MindloomRetainedAudioReader"
  /// The archived formats this build reads: 1 = Apple Lossless and Opus in
  /// CAF (`RetainedAudioContainer`).
  public static let readerVersion = 1
  /// Every bundle identifier the Mac App has shipped under; each of them
  /// opens the same library.
  public static let appBundleIdentifiers = [
    MindloomIdentity.bundleID, MindloomIdentity.debugBundleID,
    MindloomIdentity.Previous.bundleID, MindloomIdentity.Previous.debugBundleID,
    "com.bestasr.mindloom.preview",
  ]

  /// True when every installed copy's Info.plist (`installed`) declares a
  /// reader at least `readerVersion`. No copy found (a test, a tool) allows
  /// nothing: the App itself is always among them.
  public static func allowsArchival(installed: [[String: Any]]) -> Bool {
    guard !installed.isEmpty else { return false }
    return installed.allSatisfy { info in
      ((info[readerKey] as? NSNumber)?.intValue ?? 0) >= readerVersion
    }
  }

  /// The Info.plist of each copy at `applicationURLs` that still exists
  /// (LaunchServices remembers copies that were deleted).
  public static func infoDictionaries(of applicationURLs: [URL]) -> [[String: Any]] {
    applicationURLs.compactMap { url in
      NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        as? [String: Any]
    }
  }
}
