import BestASRUpdateProbe
import Foundation

private enum UpdateRollbackProbeCLIError: Error {
  case invalidArguments
  case probeFailed
}

@main
enum UpdateRollbackProbeCLI {
  static func main() throws {
    let summary = try parseArguments(CommandLine.arguments)
    let report = try UpdateRollbackProbeRunner.run(
      summaryURL: URL(fileURLWithPath: summary)
    )
    print(
      "update rollback probe \(report.conclusion): "
        + "\(report.scenarios.count) signed update scenarios"
    )
    guard report.conclusion == "pass" else {
      throw UpdateRollbackProbeCLIError.probeFailed
    }
  }

  private static func parseArguments(_ arguments: [String]) throws -> String {
    guard arguments.count == 3, arguments[1] == "--summary" else {
      throw UpdateRollbackProbeCLIError.invalidArguments
    }
    return arguments[2]
  }
}
