import BestASRLongRecordingProbe
import Foundation

let arguments = CommandLine.arguments

func value(_ name: String, fallback: String) -> String {
  guard let index = arguments.firstIndex(of: name),
    arguments.indices.contains(index + 1)
  else { return fallback }
  return arguments[index + 1]
}

let durationSeconds = UInt64(value("--duration-seconds", fallback: "7200")) ?? 0
let evidenceURL = URL(
  fileURLWithPath: value(
    "--evidence",
    fallback: "artifacts/evidence/SPIKE-JRN-001/long-recording.json"
  )
)
let workingRoot = URL(
  fileURLWithPath: value(
    "--working-root",
    fallback: FileManager.default.temporaryDirectory.path
  ),
  isDirectory: true
)

do {
  let conclusion = try LongRecordingProbeRunner.run(
    configuration: LongRecordingProbeConfiguration(
      durationNanoseconds: durationSeconds * 1_000_000_000,
      evidenceURL: evidenceURL,
      workingRootURL: workingRoot
    )
  )
  print("long recording probe completed with conclusion: \(conclusion)")
  if conclusion != "pass" { exit(1) }
} catch {
  fputs("long recording probe failed: \(String(describing: error))\n", stderr)
  exit(1)
}
