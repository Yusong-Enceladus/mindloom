import BestASRAudioTimelineProbe
import Foundation

let arguments = CommandLine.arguments

func value(_ name: String, fallback: String) -> URL {
  guard let index = arguments.firstIndex(of: name),
    arguments.indices.contains(index + 1)
  else { return URL(fileURLWithPath: fallback) }
  return URL(fileURLWithPath: arguments[index + 1])
}

do {
  let conclusion = try AudioTimelineProbeRunner.run(
    configuration: AudioTimelineProbeConfiguration(
      summaryURL: value(
        "--summary",
        fallback: "artifacts/evidence/SPIKE-TIM-001/summary.json"
      ),
      matrixURL: value(
        "--matrix",
        fallback: "artifacts/evidence/SPIKE-TIM-001/matrix.json"
      )
    )
  )
  print("SPIKE-TIM-001 completed with conclusion: \(conclusion)")
  if conclusion == "fail" { exit(1) }
} catch {
  fputs("audio timeline probe failed: \(String(describing: error))\n", stderr)
  exit(1)
}
