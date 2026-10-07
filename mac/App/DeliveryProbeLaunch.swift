import AppKit
import BestASRDelivery
import Foundation

#if DEBUG
  /// The delivery probe (`DeliveryProbe`): in the check app only, launched
  /// with `-MindloomDeliveryProbe <absolute directory>`, the process skips the
  /// app entirely, drives the target applications through the production
  /// delivery path, writes its matrix into that directory and exits. Without
  /// the argument, or in any other App identity, nothing here runs. Without
  /// the permission macOS 27 calls 「设备控制和数据访问」 it writes
  /// NEEDS-ACCESSIBILITY.txt and exits at once; it never asks for the
  /// permission (that would put a system prompt on the screen).
  ///
  /// With `-MindloomDeliveryProbeRestore <the same directory>` it only puts
  /// back the accessibility switches a probe that did not finish left
  /// turned (review 10-5d R3), and exits.
  ///
  /// The one-shot paste probe (`BESTASR_PASTE_PROBE`) that pasted into
  /// whatever was in front is gone: the delivery probe covers it with its own
  /// surfaces (review 10-5d R9).
  enum DeliveryProbeLaunch {
    /// True when this process is the probe; the caller must then not start
    /// the app. The process exits from inside.
    @MainActor
    static func runIfRequested() -> Bool {
      let arguments = ProcessInfo.processInfo.arguments
      let identity = Bundle.main.bundleIdentifier
      if let directory = DeliveryProbe.outputDirectory(
        in: arguments, bundleIdentifier: identity, argument: DeliveryProbe.restoreArgument)
      {
        NSApplication.shared.setActivationPolicy(.prohibited)
        exit(DeliveryProbeRunner.restoreSwitches(outputDirectory: directory).rawValue)
      }
      guard let directory = DeliveryProbe.outputDirectory(in: arguments, bundleIdentifier: identity)
      else { return false }
      // No Dock icon and never in front: the applications under test are.
      NSApplication.shared.setActivationPolicy(.prohibited)
      Task { @MainActor in
        let code = await DeliveryProbeRunner.run(outputDirectory: directory)
        exit(code.rawValue)
      }
      RunLoop.main.run()
      return true
    }
  }
#endif
