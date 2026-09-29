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

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard
    let candidate = value(after: "--candidate", in: arguments),
    let manifest = value(after: "--manifest", in: arguments),
    let embeddings = value(after: "--embeddings", in: arguments),
    let formatValue = value(after: "--format", in: arguments),
    let format = SpeakerIdentityEmbeddingFormat(rawValue: formatValue),
    let output = value(after: "--output", in: arguments)
  else {
    throw CLIError.invalidArguments
  }
  let evaluation = try SpeakerIdentityEvaluator.evaluate(
    SpeakerIdentityEvaluationRequest(
      candidate: candidate,
      manifestURL: URL(fileURLWithPath: manifest),
      embeddingsURL: URL(fileURLWithPath: embeddings),
      embeddingFormat: format
    ))
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  try encoder.encode(evaluation).write(
    to: URL(fileURLWithPath: output),
    options: .atomic
  )
} catch {
  FileHandle.standardError.write(
    Data("SpeakerIdentityEvaluatorCLI failed: \(error)\n".utf8)
  )
  exit(EXIT_FAILURE)
}
