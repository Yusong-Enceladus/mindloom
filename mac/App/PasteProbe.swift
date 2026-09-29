import AppKit
import BestASRDelivery
import Foundation

/// A one-shot diagnostic that only the installed app can run, because only
/// the installed app is trusted to post keystrokes.
///
/// Launched with `BESTASR_PASTE_PROBE=<file>`, the process skips the app
/// entirely: it waits four seconds — long enough to bring the application
/// under test to the front — delivers one probe string to whatever is in
/// front by the same path a dictation takes, writes the outcome to the file,
/// and exits. This is how "what does this application do with ⌘V when no
/// field has the keyboard?" is answered per application before a build
/// ships, instead of by the user's next dictation.
enum PasteProbe {
  static let environmentKey = "BESTASR_PASTE_PROBE"
  static let delaySeconds: Double = 4

  /// True when this process is a probe; the caller must then not start the
  /// app. The process exits from inside.
  @MainActor
  static func runIfRequested() -> Bool {
    guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty
    else { return false }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(delaySeconds))
      let line: String
      let reader = TargetReader()
      if let target = reader.frontmostApplication(ownApplicationAllowed: false) {
        let app = target.bundleIdentifier ?? "-"
        let before = reader.focusedText(in: target.processIdentifier)
        let focus = before.map { $0.exposesText ? "text" : "no-text" } ?? "none"
        switch await TextDeliverer(reader: reader).deliver(
          "bestASR paste probe", to: target, observing: before)
        {
        case .delivered(let evidence, let wait):
          line = "app=\(app) focus=\(focus) outcome=delivered evidence=\(evidence.rawValue) wait_ms=\(wait)"
        case .kept(let reason):
          line = "app=\(app) focus=\(focus) outcome=kept reason=\(reason.rawValue)"
        }
      } else {
        line = "no application in front"
      }
      try? line.write(toFile: path, atomically: true, encoding: .utf8)
      exit(0)
    }
    RunLoop.main.run()
    return true
  }
}
