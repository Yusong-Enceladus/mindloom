import BestASRModelManagerProbe
import Foundation

private enum CLIError: Error {
  case invalidArguments
  case probeFailed
}

private func fileDescriptor(relativePath: String, source: URL) throws -> ModelFileDescriptor {
  let file = source.appendingPathComponent(relativePath)
  let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
  guard let size = (attributes[.size] as? NSNumber)?.intValue else {
    throw CLIError.probeFailed
  }
  return ModelFileDescriptor(
    relativePath: relativePath,
    sizeBytes: size,
    sha256: try ModelManagerProbe.sha256(of: file)
  )
}

private func descriptor(version: String, source: URL) throws -> ModelArtifactDescriptor {
  ModelArtifactDescriptor(
    artifactID: "fixture-model",
    version: version,
    files: [
      try fileDescriptor(relativePath: "weights.bin", source: source)
    ]
  )
}

private func evaluate(
  name: String,
  attempt: ModelActivationAttempt,
  expectedFailure: ModelActivationFailureCategory?,
  expectedActiveVersion: String
) -> ModelActivationProbeScenario {
  let expectedStatus: ModelActivationStatus = expectedFailure == nil ? .pass : .fail
  let passed =
    attempt.status == expectedStatus
    && attempt.failureCategory == expectedFailure
    && attempt.activeVersionAfter == expectedActiveVersion
    && attempt.lastKnownGoodPreserved
    && attempt.stagingRemoved
  return ModelActivationProbeScenario(
    name: name,
    result: passed ? .pass : .fail,
    expectedFailureCategory: expectedFailure,
    attempt: attempt
  )
}

private func run(summaryURL: URL) throws {
  let fileManager = FileManager.default
  let fixtureRoot = fileManager.temporaryDirectory
    .appendingPathComponent("bestasr-model-probe-\(UUID().uuidString)")
  defer {
    try? fileManager.removeItem(at: fixtureRoot)
  }
  let source = fixtureRoot.appendingPathComponent("source", isDirectory: true)
  let store = fixtureRoot.appendingPathComponent("store", isDirectory: true)
  try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
  try Data("fixture model bytes".utf8)
    .write(to: source.appendingPathComponent("weights.bin"))

  let manager = ModelManagerProbe(root: store)
  var scenarios: [ModelActivationProbeScenario] = []

  let knownGood = manager.stageVerifyAndActivate(
    descriptor: try descriptor(version: "1.0.0", source: source),
    sourceDirectory: source,
    healthCheck: PassingModelHealthCheck()
  )
  scenarios.append(
    evaluate(
      name: "known-good-activation",
      attempt: knownGood,
      expectedFailure: nil,
      expectedActiveVersion: "1.0.0"
    )
  )

  let partial = ModelArtifactDescriptor(
    artifactID: "fixture-model",
    version: "2.0.0",
    files: [
      try fileDescriptor(relativePath: "weights.bin", source: source),
      ModelFileDescriptor(
        relativePath: "missing.bin",
        sizeBytes: 4,
        sha256: String(repeating: "0", count: 64)
      ),
    ]
  )
  scenarios.append(
    evaluate(
      name: "partial-download",
      attempt: manager.stageVerifyAndActivate(
        descriptor: partial,
        sourceDirectory: source,
        healthCheck: PassingModelHealthCheck()
      ),
      expectedFailure: .partialDownload,
      expectedActiveVersion: "1.0.0"
    )
  )

  let validFile = try fileDescriptor(relativePath: "weights.bin", source: source)
  let mismatchedDigest = ModelArtifactDescriptor(
    artifactID: "fixture-model",
    version: "3.0.0",
    files: [
      ModelFileDescriptor(
        relativePath: validFile.relativePath,
        sizeBytes: validFile.sizeBytes,
        sha256: String(repeating: "f", count: 64)
      )
    ]
  )
  scenarios.append(
    evaluate(
      name: "digest-mismatch",
      attempt: manager.stageVerifyAndActivate(
        descriptor: mismatchedDigest,
        sourceDirectory: source,
        healthCheck: PassingModelHealthCheck()
      ),
      expectedFailure: .digestMismatch,
      expectedActiveVersion: "1.0.0"
    )
  )

  scenarios.append(
    evaluate(
      name: "health-check-failure",
      attempt: manager.stageVerifyAndActivate(
        descriptor: try descriptor(version: "4.0.0", source: source),
        sourceDirectory: source,
        healthCheck: FailingModelHealthCheck()
      ),
      expectedFailure: .healthCheckFailed,
      expectedActiveVersion: "1.0.0"
    )
  )

  let report = ModelActivationProbeReport(runID: UUID(), scenarios: scenarios)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  let data = try encoder.encode(report)
  try fileManager.createDirectory(
    at: summaryURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try data.write(to: summaryURL, options: .atomic)

  guard report.status == .pass else {
    throw CLIError.probeFailed
  }
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard arguments.count == 2, arguments[0] == "--summary" else {
    throw CLIError.invalidArguments
  }
  try run(summaryURL: URL(fileURLWithPath: arguments[1]))
  print("model activation probe passed")
} catch {
  FileHandle.standardError.write(Data("model activation probe failed: \(error)\n".utf8))
  exit(1)
}
