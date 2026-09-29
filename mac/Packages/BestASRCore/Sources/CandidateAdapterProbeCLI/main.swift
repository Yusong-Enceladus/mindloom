import BestASRCandidateAdapters
import CryptoKit
import Foundation

enum CandidateAdapterProbeCLIError: Error {
  case artifactDigestMismatch(String)
  case invalidArguments
  case probeFailed
}

@main
enum CandidateAdapterProbeCLI {
  static func main() async throws {
    let arguments = try parseArguments(CommandLine.arguments)
    let repositoryRoot = URL(
      fileURLWithPath: arguments.repositoryRoot,
      isDirectory: true
    )
    let manifestURL = repositoryRoot.appendingPathComponent(
      "config/inference-candidates.json"
    )
    let fixtureSuiteURL = repositoryRoot.appendingPathComponent(
      "Tests/Fixtures/CandidateAdapters/contract-cases.json"
    )
    let manifestData = try Data(contentsOf: manifestURL)
    let fixtureSuiteData = try Data(contentsOf: fixtureSuiteURL)
    let manifest = try ASRCandidateManifest.decode(manifestData)
    let fixtureSuite = try CandidateContractFixtureSuite.decode(fixtureSuiteData)

    for candidate in manifest.candidates {
      let artifactURL = repositoryRoot.appendingPathComponent(
        candidate.probeArtifact.relativePath
      )
      let actualDigest = sha256(try Data(contentsOf: artifactURL))
      guard actualDigest == candidate.probeArtifact.sha256 else {
        throw CandidateAdapterProbeCLIError.artifactDigestMismatch(
          candidate.candidateID
        )
      }
    }

    let report = await CandidateAdapterProbe.run(
      manifest: manifest,
      fixtureSuite: fixtureSuite,
      manifestSHA256: sha256(manifestData),
      fixtureSuiteSHA256: sha256(fixtureSuiteData)
    )
    let outputURL = URL(fileURLWithPath: arguments.output)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var outputData = try encoder.encode(report)
    outputData.append(0x0A)
    try outputData.write(to: outputURL, options: .atomic)

    print(
      "candidate adapter contract probe \(report.conclusion): "
        + "\(report.candidates.count) candidates, "
        + "\(fixtureSuite.cases.count) shared scenarios"
    )
    guard report.conclusion == "pass" else {
      throw CandidateAdapterProbeCLIError.probeFailed
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func parseArguments(
    _ arguments: [String]
  ) throws -> (repositoryRoot: String, output: String) {
    var repositoryRoot: String?
    var output: String?
    var index = 1
    while index < arguments.count {
      switch arguments[index] {
      case "--repository-root":
        index += 1
        guard index < arguments.count else {
          throw CandidateAdapterProbeCLIError.invalidArguments
        }
        repositoryRoot = arguments[index]
      case "--output":
        index += 1
        guard index < arguments.count else {
          throw CandidateAdapterProbeCLIError.invalidArguments
        }
        output = arguments[index]
      default:
        throw CandidateAdapterProbeCLIError.invalidArguments
      }
      index += 1
    }
    guard let repositoryRoot, let output else {
      throw CandidateAdapterProbeCLIError.invalidArguments
    }
    return (repositoryRoot, output)
  }
}
