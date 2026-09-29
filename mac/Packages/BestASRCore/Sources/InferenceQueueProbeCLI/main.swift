import BestASRInferenceQueueProbe
import Foundation

let arguments = CommandLine.arguments

func value(_ name: String, fallback: String) -> URL {
  guard let index = arguments.firstIndex(of: name),
    arguments.indices.contains(index + 1)
  else { return URL(fileURLWithPath: fallback) }
  return URL(fileURLWithPath: arguments[index + 1])
}

do {
  let conclusion = try await InferenceQueueProbeRunner.run(
    configuration: InferenceQueueProbeConfiguration(
      summaryURL: value(
        "--summary",
        fallback: "artifacts/evidence/SPIKE-WRK-001/summary.json"
      ),
      matrixURL: value(
        "--matrix",
        fallback: "artifacts/evidence/SPIKE-WRK-001/matrix.json"
      )
    )
  )
  print("SPIKE-WRK-001 completed with conclusion: \(conclusion)")
  if conclusion != "pass" { exit(1) }
} catch {
  fputs("inference queue probe failed: \(String(describing: error))\n", stderr)
  exit(1)
}
