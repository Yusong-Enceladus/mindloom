import BestASRBenchmark
import BestASRCore
import Foundation

struct BenchSmokeResult: Codable {
  let schemaVersion: Int
  let status: String
  let workspace: WorkspaceIdentity
  let networkRequired: Bool
}

private func write<T: Encodable>(_ value: T, to outputURL: URL?) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  let data = try encoder.encode(value)
  if let outputURL {
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: outputURL, options: .atomic)
  } else {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}

private func value(after name: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: name),
    arguments.indices.contains(index + 1)
  else { return nil }
  return arguments[index + 1]
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  if arguments == ["--smoke"] {
    try write(
      BenchSmokeResult(
        schemaVersion: 1,
        status: "pass",
        workspace: WorkspaceIdentity(),
        networkRequired: false
      ),
      to: nil
    )
  } else if arguments.first == "score",
    let inputPath = value(after: "--input", in: arguments)
  {
    let input = try JSONDecoder().decode(
      BenchmarkRunInput.self,
      from: Data(contentsOf: URL(fileURLWithPath: inputPath))
    )
    let result = try BenchmarkRunner.evaluate(input)
    let outputURL = value(after: "--output", in: arguments).map {
      URL(fileURLWithPath: $0)
    }
    try write(result, to: outputURL)
  } else {
    throw BenchCLIError.invalidArguments
  }
} catch {
  FileHandle.standardError.write(
    Data(
      "BenchCLI failed: \(String(describing: error))\nusage: BenchCLI --smoke | BenchCLI score --input <run.json> [--output <result.json>]\n"
        .utf8
    )
  )
  exit(EXIT_FAILURE)
}

private enum BenchCLIError: Error {
  case invalidArguments
}
