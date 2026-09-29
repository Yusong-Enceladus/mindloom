import BestASRSpeakerEvidence
import Foundation

private enum CLIError: Error {
  case invalidArguments
}

private func value(after name: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: name),
    arguments.indices.contains(index + 1)
  else { return nil }
  return arguments[index + 1]
}

private func write<T: Encodable>(_ value: T, to url: URL) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  let data = try encoder.encode(value)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try data.write(to: url, options: .atomic)
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  let identityEvaluation = try value(
    after: "--identity-result",
    in: arguments
  ).map {
    try JSONDecoder().decode(
      SpeakerIdentityEvaluation.self,
      from: Data(contentsOf: URL(fileURLWithPath: $0))
    )
  }
  guard
    let candidateValue = value(after: "--candidate", in: arguments),
    let candidate = SpeakerEvidenceCandidate(rawValue: candidateValue),
    let matrixMode = value(after: "--matrix-mode", in: arguments),
    let corpusDirectory = value(after: "--corpus-dir", in: arguments),
    let candidateOutputDirectory = value(
      after: "--candidate-output-dir", in: arguments),
    let benchmarkID = value(after: "--benchmark-id", in: arguments),
    let runIDValue = value(after: "--run-id", in: arguments),
    let runID = UUID(uuidString: runIDValue),
    let implementationRevision = value(
      after: "--implementation-revision", in: arguments),
    let artifactID = value(after: "--artifact-id", in: arguments),
    let artifactSHA256 = value(after: "--artifact-sha256", in: arguments),
    let provider = value(after: "--provider", in: arguments),
    let corpusManifestID = value(
      after: "--corpus-manifest-id", in: arguments),
    let corpusVersion = value(after: "--corpus-version", in: arguments),
    let environmentRef = value(after: "--environment-ref", in: arguments),
    let toolchainVersion = value(after: "--toolchain-version", in: arguments),
    let outputPath = value(after: "--output", in: arguments)
  else {
    throw CLIError.invalidArguments
  }

  let result = try SpeakerEvidenceCollator.collate(
    SpeakerEvidenceCollationRequest(
      candidate: candidate,
      matrixMode: matrixMode,
      corpusDirectory: URL(fileURLWithPath: corpusDirectory, isDirectory: true),
      candidateOutputDirectory: URL(
        fileURLWithPath: candidateOutputDirectory,
        isDirectory: true
      ),
      benchmarkID: benchmarkID,
      runID: runID,
      implementationRevision: implementationRevision,
      artifactID: artifactID,
      artifactSHA256: artifactSHA256,
      provider: provider,
      corpusManifestID: corpusManifestID,
      corpusVersion: corpusVersion,
      environmentRef: environmentRef,
      toolchainVersion: toolchainVersion,
      identityAssignments: identityEvaluation?.assignments ?? []
    ))
  try write(result, to: URL(fileURLWithPath: outputPath))
} catch {
  FileHandle.standardError.write(
    Data(
      "SpeakerEvidenceCollatorCLI failed: \(error)\n".utf8
    ))
  exit(EXIT_FAILURE)
}
