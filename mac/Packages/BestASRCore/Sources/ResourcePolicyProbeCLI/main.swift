import BestASRResourcePolicyProbe
import Foundation

private enum ResourcePolicyProbeCLIError: Error {
  case invalidArguments
  case probeFailed
}

@main
enum ResourcePolicyProbeCLI {
  static func main() async throws {
    let arguments = try parseArguments(CommandLine.arguments)
    let matrix = try await ResourcePolicyProbeRunner.run(
      configuration: ResourcePolicyProbeConfiguration(
        summaryURL: URL(fileURLWithPath: arguments.summary),
        matrixURL: URL(fileURLWithPath: arguments.matrix)
      )
    )
    print(
      "SPIKE-RES-001 \(matrix.conclusion): "
        + "\(matrix.scenarios.count) pressure scenarios, "
        + "\(matrix.recoveredReadableChunkCount) chunks recovered"
    )
    guard matrix.conclusion == "pass" else {
      throw ResourcePolicyProbeCLIError.probeFailed
    }
  }

  private static func parseArguments(
    _ arguments: [String]
  ) throws -> (summary: String, matrix: String) {
    var summary: String?
    var matrix: String?
    var index = 1
    while index < arguments.count {
      switch arguments[index] {
      case "--summary":
        index += 1
        guard index < arguments.count else {
          throw ResourcePolicyProbeCLIError.invalidArguments
        }
        summary = arguments[index]
      case "--matrix":
        index += 1
        guard index < arguments.count else {
          throw ResourcePolicyProbeCLIError.invalidArguments
        }
        matrix = arguments[index]
      default:
        throw ResourcePolicyProbeCLIError.invalidArguments
      }
      index += 1
    }
    guard let summary, let matrix else {
      throw ResourcePolicyProbeCLIError.invalidArguments
    }
    return (summary, matrix)
  }
}
