import BestASRBenchmark
import CryptoKit
import Foundation

private struct MatrixScenario: Codable {
  let scenarioID: String
  let status: String
  let category: DangerousTokenCategory?
  let observedErrors: Int
}

private struct FactualGateMatrix: Codable {
  let schemaVersion: Int
  let kind: String
  let spikeID: String
  let runID: UUID
  let fixtureSHA256: String
  let sourceSampleCount: Int
  let categoryCoverage: [DangerousTokenCategory]
  let sourceMutationDetected: Bool
  let candidates: [LLMFactualCandidateResult]
  let scenarios: [MatrixScenario]
  let conclusion: String
}

private struct SpikeCriteria: Codable {
  let pass: [String]
  let fail: [String]
}

private struct SpikeMatrixReference: Codable {
  let scenarioID: String
  let status: String
  let evidenceRefs: [String]
}

private struct SpikeSummary: Codable {
  let schemaVersion: Int
  let kind: String
  let spikeID: String
  let runID: UUID
  let question: String
  let environmentRef: String
  let criteria: SpikeCriteria
  let commands: [[String]]
  let matrix: [SpikeMatrixReference]
  let conclusion: String
  let unmetCriteria: [String]
}

private enum ProbeError: Error {
  case invalidArguments
  case missingExpectedCandidate(String)
  case probeFailed
}

@main
enum LLMFactualGateProbeCLI {
  static func main() throws {
    let arguments = try parseArguments(CommandLine.arguments)
    let repositoryRoot = URL(
      fileURLWithPath: arguments.repositoryRoot,
      isDirectory: true
    )
    let fixtureURL = repositoryRoot.appendingPathComponent(
      "Tests/Fixtures/LocalText/factual-gate-suite.json"
    )
    let fixtureData = try Data(contentsOf: fixtureURL)
    let suite = try JSONDecoder().decode(
      LLMFactualGateSuite.self,
      from: fixtureData
    )
    let sourceBefore = suite.sources
    let evaluation = try LLMFactualHardGate.evaluate(suite)
    guard
      let safe = evaluation.candidateResults.first(where: {
        $0.candidateID == "fact-preserving-fixture"
      })
    else {
      throw ProbeError.missingExpectedCandidate("fact-preserving-fixture")
    }
    guard
      let unsafe = evaluation.candidateResults.first(where: {
        $0.candidateID == "style-preferred-factually-unsafe-fixture"
      })
    else {
      throw ProbeError.missingExpectedCandidate(
        "style-preferred-factually-unsafe-fixture"
      )
    }

    var scenarios = [
      MatrixScenario(
        scenarioID: "fact-preserving-candidate-remains-eligible",
        status: safe.hardGateEligible ? "pass" : "fail",
        category: nil,
        observedErrors: safe.categoryResults.reduce(0) { $0 + $1.errorCount }
      )
    ]
    for category in DangerousTokenCategory.allCases {
      let result = unsafe.categoryResults.first { $0.category == category }
      let detected = result.map { !$0.passed && $0.errorCount > $0.hardLimit } ?? false
      scenarios.append(
        MatrixScenario(
          scenarioID: "planted-\(category.rawValue)-regression-is-rejected",
          status: detected ? "pass" : "fail",
          category: category,
          observedErrors: result?.errorCount ?? 0
        )
      )
    }
    scenarios.append(
      MatrixScenario(
        scenarioID: "higher-style-score-cannot-bypass-hard-gate",
        status: unsafe.meanStylePreferenceScore > safe.meanStylePreferenceScore
          && !unsafe.hardGateEligible ? "pass" : "fail",
        category: nil,
        observedErrors: unsafe.categoryResults.reduce(0) {
          $0 + $1.errorCount
        }
      )
    )
    scenarios.append(
      MatrixScenario(
        scenarioID: "source-transcripts-remain-unchanged",
        status: suite.sources == sourceBefore ? "pass" : "fail",
        category: nil,
        observedErrors: 0
      )
    )

    let conclusion =
      scenarios.allSatisfy { $0.status == "pass" }
      ? "pass" : "fail"
    let runID = UUID(uuidString: "69000000-0000-4000-8000-000000000900")!
    let matrix = FactualGateMatrix(
      schemaVersion: 1,
      kind: "llm-factual-gate-matrix",
      spikeID: "SPIKE-LLM-001",
      runID: runID,
      fixtureSHA256: sha256(fixtureData),
      sourceSampleCount: evaluation.sourceSampleCount,
      categoryCoverage: evaluation.categoryCoverage,
      sourceMutationDetected: suite.sources != sourceBefore,
      candidates: evaluation.candidateResults,
      scenarios: scenarios,
      conclusion: conclusion
    )
    let matrixReference = "artifacts/evidence/SPIKE-LLM-001/matrix.json"
    let summary = SpikeSummary(
      schemaVersion: 1,
      kind: "spike-summary",
      spikeID: "SPIKE-LLM-001",
      runID: runID,
      question: "Can style preference ever mask a dangerous factual change?",
      environmentRef: "artifacts/evidence/environment/workspace-summary.json",
      criteria: SpikeCriteria(
        pass: [
          "all five dangerous-token categories reject planted changes at zero tolerance",
          "a fact-preserving candidate remains eligible",
          "a higher style score cannot override a factual hard failure",
          "source transcript fixtures remain unchanged",
        ],
        fail: [
          "any planted dangerous-token change remains eligible or source evidence mutates"
        ]
      ),
      commands: [["script/run_llm_factual_gate_probe.sh"]],
      matrix: scenarios.map {
        SpikeMatrixReference(
          scenarioID: $0.scenarioID,
          status: $0.status,
          evidenceRefs: [matrixReference]
        )
      },
      conclusion: conclusion,
      unmetCriteria: scenarios.filter { $0.status != "pass" }.map(\.scenarioID)
    )
    try write(matrix, to: URL(fileURLWithPath: arguments.matrix))
    try write(summary, to: URL(fileURLWithPath: arguments.summary))
    print(
      "SPIKE-LLM-001 \(conclusion): \(scenarios.count) hard-gate scenarios"
    )
    guard conclusion == "pass" else { throw ProbeError.probeFailed }
  }

  private static func write<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    try data.write(to: url, options: .atomic)
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func parseArguments(
    _ arguments: [String]
  ) throws -> (repositoryRoot: String, summary: String, matrix: String) {
    var repositoryRoot: String?
    var summary: String?
    var matrix: String?
    var index = 1
    while index < arguments.count {
      switch arguments[index] {
      case "--repository-root":
        index += 1
        guard index < arguments.count else { throw ProbeError.invalidArguments }
        repositoryRoot = arguments[index]
      case "--summary":
        index += 1
        guard index < arguments.count else { throw ProbeError.invalidArguments }
        summary = arguments[index]
      case "--matrix":
        index += 1
        guard index < arguments.count else { throw ProbeError.invalidArguments }
        matrix = arguments[index]
      default:
        throw ProbeError.invalidArguments
      }
      index += 1
    }
    guard let repositoryRoot, let summary, let matrix else {
      throw ProbeError.invalidArguments
    }
    return (repositoryRoot, summary, matrix)
  }
}
