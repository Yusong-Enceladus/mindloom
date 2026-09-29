import Foundation

struct ProbeScenarioDetail: Codable, Sendable {
  let scenarioID: String
  let status: String
  let errorCategory: String
  let metrics: [String: String]
}

struct SecurityProbeMatrixEvidence: Codable, Sendable {
  let schemaVersion: Int
  let kind: String
  let spikeID: String
  let runID: UUID
  let generatedAt: Date
  let sqlCipherPackageVersion: String
  let scenarios: [ProbeScenarioDetail]
}

struct SpikeCriteria: Codable, Sendable {
  let pass: [String]
  let fail: [String]
}

struct SpikeMatrixReference: Codable, Sendable {
  let scenarioID: String
  let status: String
  let evidenceRefs: [String]
}

struct SpikeSummary: Codable, Sendable {
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

func runScenario(
  _ scenarioID: String,
  _ body: () throws -> [String: String]
) -> ProbeScenarioDetail {
  do {
    return ProbeScenarioDetail(
      scenarioID: scenarioID,
      status: "pass",
      errorCategory: "none",
      metrics: try body()
    )
  } catch {
    return ProbeScenarioDetail(
      scenarioID: scenarioID,
      status: "fail",
      errorCategory: String(describing: error),
      metrics: [:]
    )
  }
}
