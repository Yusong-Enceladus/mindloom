import BestASRInference
import BestASRLocalText
import BestASRMLXRuntime
import BestASRProcessing
import Darwin
import Foundation

private struct ProbeSuite: Decodable {
  let schemaVersion: Int
  let kind: String
  let suiteID: String
  let minimumStylePassCount: Int
  let generationCountPerSample: Int
  let maximumModelLoadMilliseconds: Double
  let maximumP95LatencyMilliseconds: Double
  let maximumPeakResidentBytes: UInt64
  let samples: [ProbeSample]
}

private struct ProbeSample: Decodable {
  let sampleUUID: UUID
  let sourceText: String
  let dictionaryTerms: [String]
  let forbiddenSubstrings: [String]
  let requiresTerminalPunctuation: Bool
}

private struct ProbeSampleResult: Encodable {
  let sampleUUID: UUID
  let factualGatePassed: Bool
  let violatedCategories: [String]
  let changed: Bool
  let forbiddenSubstringsRemoved: Bool
  let terminalPunctuationPresent: Bool
  let styleGatePassed: Bool
  let deterministicOutputMatched: Bool
  let latencyMilliseconds: Double
  let errorCode: String?
}

private struct ProbeSummary: Encodable {
  let schemaVersion = 2
  let kind = "local-text-real-model-gate-summary"
  let suiteID: String
  let artifactID: String
  let sourceRevision: String
  let treeSHA256: String
  let runtimeRevision = "1c05248bb0899e2a7a4962b84d319cf12f4e12aa"
  let generationConfiguration: GenerationConfiguration
  let modelLoadMilliseconds: Double
  let sampleCount: Int
  let factualFailureCount: Int
  let generationFailureCount: Int
  let changedSampleCount: Int
  let stylePassCount: Int
  let minimumStylePassCount: Int
  let generationCountPerSample: Int
  let generationInvocationCount: Int
  let deterministicMismatchCount: Int
  let p50LatencyMilliseconds: Double
  let p95LatencyMilliseconds: Double
  let peakResidentBytes: UInt64
  let maximumModelLoadMilliseconds: Double
  let maximumP95LatencyMilliseconds: Double
  let maximumPeakResidentBytes: UInt64
  let resourceGatePassed: Bool
  let hardGateEligible: Bool
  let samples: [ProbeSampleResult]
}

private struct GenerationConfiguration: Encodable {
  let temperature: Double
  let maximumOutputTokens: Int
  let maximumKVCacheTokens: Int
  let prefillStepSize: Int
  let thinkingEnabled: Bool
}

private enum CLIError: Error, CustomStringConvertible {
  case invalidArguments(String)
  case invalidSuite(String)

  var description: String {
    switch self {
    case .invalidArguments(let value), .invalidSuite(let value): value
    }
  }
}

private enum LocalTextModelProbeCLI {
  static func run() async {
    do {
      let arguments = try parseArguments()
      let artifact = try resolveArtifact(arguments.artifactID)
      let suiteData = try Data(contentsOf: arguments.suiteURL)
      let suite = try JSONDecoder().decode(ProbeSuite.self, from: suiteData)
      try validate(suite)

      let policy = MLXLocalTextRuntimePolicy(
        maximumOutputTokens: 1_024,
        maximumKVCacheTokens: 4_096,
        prefillStepSize: 512,
        modelLoadTimeoutMilliseconds: 180_000,
        generationTimeoutMilliseconds: 60_000
      )
      let runtime = MLXLocalTextRuntime(
        verifiedModelDirectory: arguments.modelDirectory,
        policy: policy
      )
      let engine = VersionedLocalTextAdapter(
        artifact: artifact.descriptor,
        runtime: runtime
      )

      let loadStart = DispatchTime.now().uptimeNanoseconds
      try await runtime.prepare()
      let loadMilliseconds = milliseconds(since: loadStart)
      FileHandle.standardError.write(
        Data("model_prepared_ms=\(format(loadMilliseconds))\n".utf8)
      )

      var results: [ProbeSampleResult] = []
      var latencies: [Double] = []
      var generationInvocationCount = 0
      for sample in suite.samples {
        do {
          var outputs: [LocalTextResult] = []
          var sampleLatencies: [Double] = []
          for _ in 0..<suite.generationCountPerSample {
            let started = DispatchTime.now().uptimeNanoseconds
            generationInvocationCount += 1
            let output = try await engine.generate(
              LocalTextRequest(
                metadata: InferenceRequestMetadata(
                  jobID: sample.sampleUUID,
                  inputRevision: 1,
                  modelArtifactID: artifact.artifactID,
                  configHash: String(repeating: "a", count: 64)
                ),
                taskID: .rewrite,
                transcriptRevisionID: sample.sampleUUID,
                sourceSegmentIDs: [sample.sampleUUID],
                sourceText: sample.sourceText
              )
            )
            let elapsed = milliseconds(since: started)
            sampleLatencies.append(elapsed)
            latencies.append(elapsed)
            outputs.append(output)
          }
          guard let output = outputs.first else {
            throw CLIError.invalidSuite("generation count produced no output")
          }
          let deterministicOutputMatched = outputs.dropFirst().allSatisfy {
            $0.outputText == output.outputText
          }
          let factual = DictationProtectedFactValidator.validate(
            source: sample.sourceText,
            candidate: output.outputText,
            dictionaryTerms: sample.dictionaryTerms
          )
          let changed = normalized(output.outputText) != normalized(sample.sourceText)
          let forbiddenSubstringsRemoved = sample.forbiddenSubstrings.allSatisfy {
            !normalized(output.outputText).contains(normalized($0))
          }
          let terminalPunctuationPresent = hasTerminalPunctuation(output.outputText)
          let stylePassed =
            factual.passed
            && changed
            && forbiddenSubstringsRemoved
            && (!sample.requiresTerminalPunctuation
              || terminalPunctuationPresent)
          results.append(
            ProbeSampleResult(
              sampleUUID: sample.sampleUUID,
              factualGatePassed: factual.passed,
              violatedCategories: factual.violatedCategories.map(\.rawValue),
              changed: changed,
              forbiddenSubstringsRemoved: forbiddenSubstringsRemoved,
              terminalPunctuationPresent: terminalPunctuationPresent,
              styleGatePassed: stylePassed && deterministicOutputMatched,
              deterministicOutputMatched: deterministicOutputMatched,
              latencyMilliseconds: sampleLatencies.max() ?? 0,
              errorCode: nil
            )
          )
        } catch let error as InferenceEngineError {
          results.append(
            ProbeSampleResult(
              sampleUUID: sample.sampleUUID,
              factualGatePassed: false,
              violatedCategories: [],
              changed: false,
              forbiddenSubstringsRemoved: false,
              terminalPunctuationPresent: false,
              styleGatePassed: false,
              deterministicOutputMatched: false,
              latencyMilliseconds: 0,
              errorCode: error.code
            )
          )
        } catch {
          results.append(
            ProbeSampleResult(
              sampleUUID: sample.sampleUUID,
              factualGatePassed: false,
              violatedCategories: [],
              changed: false,
              forbiddenSubstringsRemoved: false,
              terminalPunctuationPresent: false,
              styleGatePassed: false,
              deterministicOutputMatched: false,
              latencyMilliseconds: 0,
              errorCode: "unexpected-probe-error"
            )
          )
        }
      }

      let factualFailures = results.filter { !$0.factualGatePassed }.count
      let generationFailures = results.filter { $0.errorCode != nil }.count
      let changedCount = results.filter(\.changed).count
      let stylePassCount = results.filter(\.styleGatePassed).count
      let deterministicMismatchCount = results.filter {
        !$0.deterministicOutputMatched
      }.count
      let p50LatencyMilliseconds = percentile(latencies, 0.50)
      let p95LatencyMilliseconds = percentile(latencies, 0.95)
      let peakResidentBytes = peakResidentBytes()
      let resourceGatePassed =
        loadMilliseconds <= suite.maximumModelLoadMilliseconds
        && p95LatencyMilliseconds <= suite.maximumP95LatencyMilliseconds
        && peakResidentBytes <= suite.maximumPeakResidentBytes
      let hardGateEligible =
        factualFailures == 0
        && generationFailures == 0
        && deterministicMismatchCount == 0
        && resourceGatePassed
        && stylePassCount >= suite.minimumStylePassCount
      let summary = ProbeSummary(
        suiteID: suite.suiteID,
        artifactID: artifact.artifactID,
        sourceRevision: artifact.sourceRevision,
        treeSHA256: artifact.treeSHA256,
        generationConfiguration: GenerationConfiguration(
          temperature: 0,
          maximumOutputTokens: policy.maximumOutputTokens,
          maximumKVCacheTokens: policy.maximumKVCacheTokens,
          prefillStepSize: policy.prefillStepSize,
          thinkingEnabled: false
        ),
        modelLoadMilliseconds: loadMilliseconds,
        sampleCount: results.count,
        factualFailureCount: factualFailures,
        generationFailureCount: generationFailures,
        changedSampleCount: changedCount,
        stylePassCount: stylePassCount,
        minimumStylePassCount: suite.minimumStylePassCount,
        generationCountPerSample: suite.generationCountPerSample,
        generationInvocationCount: generationInvocationCount,
        deterministicMismatchCount: deterministicMismatchCount,
        p50LatencyMilliseconds: p50LatencyMilliseconds,
        p95LatencyMilliseconds: p95LatencyMilliseconds,
        peakResidentBytes: peakResidentBytes,
        maximumModelLoadMilliseconds: suite.maximumModelLoadMilliseconds,
        maximumP95LatencyMilliseconds: suite.maximumP95LatencyMilliseconds,
        maximumPeakResidentBytes: suite.maximumPeakResidentBytes,
        resourceGatePassed: resourceGatePassed,
        hardGateEligible: hardGateEligible,
        samples: results
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let outputData = try encoder.encode(summary)
      try outputData.write(to: arguments.outputURL, options: .atomic)
      FileHandle.standardOutput.write(outputData)
      FileHandle.standardOutput.write(Data("\n".utf8))
      if !hardGateEligible { exit(2) }
    } catch {
      FileHandle.standardError.write(Data("error: \(error)\n".utf8))
      exit(64)
    }
  }

  private struct Arguments {
    let modelDirectory: URL
    let artifactID: String
    let suiteURL: URL
    let outputURL: URL
  }

  private static func parseArguments() throws -> Arguments {
    var values = Array(CommandLine.arguments.dropFirst())
    func value(for flag: String) throws -> String {
      guard let index = values.firstIndex(of: flag), index + 1 < values.count else {
        throw CLIError.invalidArguments("missing \(flag)")
      }
      let value = values[index + 1]
      values.removeSubrange(index...(index + 1))
      return value
    }
    let modelDirectory = URL(fileURLWithPath: try value(for: "--model-directory"))
    let artifactID = try value(for: "--artifact-id")
    let suiteURL = URL(fileURLWithPath: try value(for: "--suite"))
    let outputURL = URL(fileURLWithPath: try value(for: "--output"))
    guard values.isEmpty else {
      throw CLIError.invalidArguments("unknown arguments")
    }
    return Arguments(
      modelDirectory: modelDirectory,
      artifactID: artifactID,
      suiteURL: suiteURL,
      outputURL: outputURL
    )
  }

  private static func resolveArtifact(_ id: String) throws -> MLXLocalTextArtifact {
    switch id {
    case MLXLocalTextArtifact.qwen3Small.artifactID:
      MLXLocalTextArtifact.qwen3Small
    case MLXLocalTextArtifact.qwen3Selected.artifactID:
      MLXLocalTextArtifact.qwen3Selected
    case MLXLocalTextArtifact.qwen3Large.artifactID:
      MLXLocalTextArtifact.qwen3Large
    default:
      throw CLIError.invalidArguments("unsupported artifact id")
    }
  }

  private static func validate(_ suite: ProbeSuite) throws {
    guard
      suite.schemaVersion == 1,
      suite.kind == "local-text-real-model-gate-suite",
      !suite.suiteID.isEmpty,
      !suite.samples.isEmpty,
      suite.minimumStylePassCount > 0,
      suite.minimumStylePassCount <= suite.samples.count,
      suite.generationCountPerSample >= 2,
      suite.generationCountPerSample <= 4,
      suite.maximumModelLoadMilliseconds > 0,
      suite.maximumP95LatencyMilliseconds > 0,
      suite.maximumPeakResidentBytes > 0,
      Set(suite.samples.map(\.sampleUUID)).count == suite.samples.count,
      suite.samples.allSatisfy({ !$0.sourceText.isEmpty })
    else {
      throw CLIError.invalidSuite("invalid suite")
    }
  }

  private static func normalized(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private static func hasTerminalPunctuation(_ value: String) -> Bool {
    guard
      let scalar = value.trimmingCharacters(in: .whitespacesAndNewlines)
        .unicodeScalars.last
    else { return false }
    return CharacterSet(charactersIn: ".!?。！？").contains(scalar)
  }

  private static func milliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
  }

  private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let rank = max(1, Int(ceil(fraction * Double(sorted.count))))
    return sorted[min(sorted.count - 1, rank - 1)]
  }

  private static func peakResidentBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(max(0, usage.ru_maxrss))
  }

  private static func format(_ value: Double) -> String {
    String(format: "%.2f", value)
  }
}

await LocalTextModelProbeCLI.run()
