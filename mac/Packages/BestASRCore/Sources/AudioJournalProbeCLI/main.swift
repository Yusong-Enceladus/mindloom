import BestASRAudioJournalProbe
import Darwin
import Foundation

let arguments = CommandLine.arguments

func value(_ name: String, fallback: String? = nil) -> String? {
  guard let index = arguments.firstIndex(of: name),
    arguments.indices.contains(index + 1)
  else { return fallback }
  return arguments[index + 1]
}

if arguments.contains("--kill-child") {
  guard let root = value("--root"),
    let seedText = value("--seed"),
    let seed = UInt64(seedText)
  else {
    fputs("kill child requires --root and --seed\n", stderr)
    exit(64)
  }
  do {
    try AudioJournalKillFixture.performWrite(
      rootURL: URL(fileURLWithPath: root),
      seed: seed
    )
    fputs("kill injection unexpectedly returned\n", stderr)
    exit(2)
  } catch AudioJournalError.injectedCrash {
    Darwin.kill(Darwin.getpid(), SIGKILL)
    Darwin.pause()
    exit(137)
  } catch {
    fputs("kill child failed before injection: \(error)\n", stderr)
    exit(3)
  }
}

let summaryURL = URL(
  fileURLWithPath: value(
    "--summary",
    fallback: "artifacts/evidence/SPIKE-JRN-001/summary.json"
  )!
)
let matrixURL = URL(
  fileURLWithPath: value(
    "--matrix",
    fallback: "artifacts/evidence/SPIKE-JRN-001/matrix.json"
  )!
)

do {
  guard let executableURL = Bundle.main.executableURL else {
    fputs("audio journal probe could not resolve its executable\n", stderr)
    exit(1)
  }
  let conclusion = try AudioJournalProbeRunner.run(
    configuration: AudioJournalProbeConfiguration(
      summaryURL: summaryURL,
      matrixURL: matrixURL
    ),
    executableURL: executableURL.standardizedFileURL
  )
  print("SPIKE-JRN-001 completed with conclusion: \(conclusion)")
  if conclusion == "fail" { exit(1) }
} catch {
  fputs("audio journal probe failed: \(String(describing: error))\n", stderr)
  exit(1)
}
