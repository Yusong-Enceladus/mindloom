import BestASRDictationFixtures
import Foundation

private struct DictationFixtureEvidence: Encodable {
  let schemaVersion = 1
  let kind = "dictation-deterministic-vertical-slice"
  let status: String
  let finalPhase: String
  let hardwareRequired = false
  let networkAttemptCount: Int
  let audioRangeCount: Int
  let rawTranscriptRevisionCount: Int
  let derivedRevisionCount: Int
  let insertionCallCount: Int
  let insertionMutationCount: Int
  let speakerScheduleCount: Int
}

@main
private enum DictationFixtureHarnessCLI {
  static func main() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 2, arguments[0] == "--output" else {
      FileHandle.standardError.write(
        Data("usage: DictationFixtureHarnessCLI --output <path>\n".utf8)
      )
      Foundation.exit(64)
    }
    let outputURL = URL(fileURLWithPath: arguments[1])
    let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-dictation-fixture-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let result = try await DeterministicDictationHarness.run(at: temporaryRoot)
    let passed =
      result.snapshot.phase.rawValue == "completed"
      && result.audioRangeCount > 0
      && result.transcripts.count == 1
      && result.derivations.count == 1
      && result.insertionCallCount == 1
      && result.insertionMutationCount == 1
      && result.speakerScheduleCount == 1
      && result.networkAttemptCount == 0
    let evidence = DictationFixtureEvidence(
      status: passed ? "pass" : "fail",
      finalPhase: result.snapshot.phase.rawValue,
      networkAttemptCount: result.networkAttemptCount,
      audioRangeCount: result.audioRangeCount,
      rawTranscriptRevisionCount: result.transcripts.count,
      derivedRevisionCount: result.derivations.count,
      insertionCallCount: result.insertionCallCount,
      insertionMutationCount: result.insertionMutationCount,
      speakerScheduleCount: result.speakerScheduleCount
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try encoder.encode(evidence).write(to: outputURL, options: .atomic)
    print("dictation fixture harness: \(evidence.status)")
    if !passed { Foundation.exit(1) }
  }
}
