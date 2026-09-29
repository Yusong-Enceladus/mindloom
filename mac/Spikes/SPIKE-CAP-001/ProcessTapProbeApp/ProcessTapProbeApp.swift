import AppKit
import BestASRProcessTapProbe
import Darwin
import Foundation

@main
struct ProcessTapProbeApp {
  static func main() {
    let application = NSApplication.shared
    let delegate = ProcessTapProbeApplicationDelegate(
      arguments: CommandLine.arguments
    )
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
    exit(delegate.exitCode)
  }
}

private final class ProcessTapProbeApplicationDelegate: NSObject,
  NSApplicationDelegate, @unchecked Sendable
{
  private let arguments: [String]
  private let stateLock = NSLock()
  private var worker: Thread?
  private var storedExitCode: Int32 = 1

  init(arguments: [String]) {
    self.arguments = arguments
    super.init()
  }

  var exitCode: Int32 {
    stateLock.withLock { storedExitCode }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let worker = Thread { [weak self] in
      self?.runProbe()
    }
    worker.name = "bestASR Process Tap probe"
    self.worker = worker
    worker.start()
  }

  private func runProbe() {
    let result: Int32
    do {
      let arguments = Arguments(arguments)
      let conclusion = try ProcessTapProbeRunner.run(
        configuration: ProcessTapProbeConfiguration(
          selectedPlayerURL: arguments.selectedPlayerURL,
          nonselectedPlayerURL: arguments.nonselectedPlayerURL,
          summaryURL: arguments.summaryURL,
          matrixURL: arguments.matrixURL,
          allowOutputDeviceSwitch: arguments.allowOutputDeviceSwitch,
          tccDenialEvidenceURL: arguments.tccDenialEvidenceURL
        )
      )
      print("SPIKE-CAP-001 completed with conclusion: \(conclusion)")
      result = conclusion == "fail" ? 1 : 0
    } catch {
      fputs("process tap probe failed: \(String(describing: error))\n", stderr)
      result = 1
    }

    stateLock.withLock {
      storedExitCode = result
    }
    DispatchQueue.main.async {
      NSApplication.shared.terminate(nil)
    }
  }
}

private struct Arguments {
  let selectedPlayerURL: URL
  let nonselectedPlayerURL: URL
  let summaryURL: URL
  let matrixURL: URL
  let allowOutputDeviceSwitch: Bool
  let tccDenialEvidenceURL: URL?

  init(_ arguments: [String]) {
    selectedPlayerURL = URL(
      fileURLWithPath: Self.value("--selected-player", in: arguments)
        ?? "SelectedWatermarkPlayer"
    )
    nonselectedPlayerURL = URL(
      fileURLWithPath: Self.value("--nonselected-player", in: arguments)
        ?? "NonselectedWatermarkPlayer"
    )
    summaryURL = URL(
      fileURLWithPath: Self.value("--summary", in: arguments)
        ?? "artifacts/evidence/SPIKE-CAP-001/summary.json"
    )
    matrixURL = URL(
      fileURLWithPath: Self.value("--matrix", in: arguments)
        ?? "artifacts/evidence/SPIKE-CAP-001/matrix.json"
    )
    allowOutputDeviceSwitch = arguments.contains(
      "--allow-output-device-switch"
    )
    tccDenialEvidenceURL = Self.value(
      "--tcc-denial-evidence",
      in: arguments
    ).map(URL.init(fileURLWithPath:))
  }

  private static func value(
    _ name: String,
    in arguments: [String]
  ) -> String? {
    guard let index = arguments.firstIndex(of: name),
      arguments.indices.contains(index + 1)
    else {
      return nil
    }
    return arguments[index + 1]
  }
}
