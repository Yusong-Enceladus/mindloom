import BestASRBenchmark
import BestASRFluidRuntime
import BestASRModelManager
import BestASRSpeakerReleaseEvaluation
import Foundation

private enum Command: String {
  case calibrate
  case evaluate
  case prepare
}

private enum CLIError: Error {
  case invalidArguments
  case networkSandboxRequired
}

@main
private enum PublicSpeakerEvalCLI {
  static func main() async {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard let commandValue = arguments.first,
        let command = Command(rawValue: commandValue)
      else {
        throw CLIError.invalidArguments
      }
      let options = try parseOptions(Array(arguments.dropFirst()))
      switch command {
      case .prepare:
        try prepare(options)
      case .calibrate:
        try await calibrate(options)
      case .evaluate:
        try await evaluate(options)
      }
    } catch {
      FileHandle.standardError.write(
        Data("PublicSpeakerEvalCLI failed safely: \(String(reflecting: error))\n".utf8)
      )
      exit(EXIT_FAILURE)
    }
  }

  private static func prepare(_ options: [String: String]) throws {
    try AMIPublicSpeakerCorpusPreparer.prepare(
      planURL: try requiredURL("--plan", options),
      downloadsRoot: try requiredURL("--downloads-root", options),
      annotationsRoot: try requiredURL("--annotations-root", options),
      tuningRoot: try requiredURL("--tuning-root", options),
      releaseHoldoutRoot: try requiredURL("--release-root", options),
      tuningManifestTemplate: try requiredURL(
        "--tuning-manifest-template", options
      ),
      releaseManifestTemplate: try requiredURL(
        "--release-manifest-template", options
      )
    )
    print("AMI public speaker corpus prepared")
  }

  private static func calibrate(_ options: [String: String]) async throws {
    try requireNetworkSandbox(options)
    let tuningRoot = try requiredURL("--tuning-root", options)
    let releaseRoot = try requiredURL("--release-root", options)
    let engine = try await makeEngine(
      audioRoot: tuningRoot,
      options: options
    )
    let output = try await SpeakerReleaseEvaluator.calibrate(
      tuningRoot: tuningRoot,
      releaseHoldoutRoot: releaseRoot,
      engine: engine,
      thresholdMargin: try optionalDouble(
        "--threshold-margin",
        options: options,
        defaultValue: 0.03
      ),
      hardware: hardwareContext,
      networkDeniedByParentSandbox: true
    )
    guard let frozenModel = output.frozenModel else {
      throw CLIError.invalidArguments
    }
    try write(
      frozenModel,
      to: try requiredURL("--frozen-profile-output", options)
    )
    try writeOutputs(output, options: options)
    print("speaker tuning calibration: \(output.decision.status)")
  }

  private static func evaluate(_ options: [String: String]) async throws {
    try requireNetworkSandbox(options)
    let tuningRoot = try requiredURL("--tuning-root", options)
    let releaseRoot = try requiredURL("--release-root", options)
    let frozen = try SpeakerFrozenIdentityModel.decode(
      Data(contentsOf: try requiredURL("--frozen-profile", options))
    )
    let engine = try await makeEngine(
      audioRoot: releaseRoot,
      options: options
    )
    let output = try await SpeakerReleaseEvaluator.evaluateReleaseHoldout(
      tuningRoot: tuningRoot,
      releaseHoldoutRoot: releaseRoot,
      frozenModel: frozen,
      engine: engine,
      hardware: hardwareContext,
      networkDeniedByParentSandbox: true
    )
    try writeOutputs(output, options: options)
    print("speaker release holdout: \(output.decision.status)")
  }

  private static func makeEngine(
    audioRoot: URL,
    options: [String: String]
  ) async throws -> FluidProductionSpeakerEvaluationEngine {
    let registry = try ManagedModelRegistry.decode(
      Data(contentsOf: try requiredURL("--model-registry", options))
    )
    let manager = try LocalModelManager(
      rootDirectory: try requiredURL("--model-store", options),
      registry: registry
    )
    do {
      _ = try await manager.discoverActive(
        artifactID: FluidSpeakerPinnedArtifact.artifactID,
        healthCheck: FluidSpeakerModelHealthCheck()
      )
    } catch {
      _ = try await manager.activate(
        artifactID: FluidSpeakerPinnedArtifact.artifactID,
        version: FluidSpeakerPinnedArtifact.sourceRevision,
        from: try requiredURL("--model-source", options),
        healthCheck: FluidSpeakerModelHealthCheck()
      )
    }
    let runtime = try await FluidSpeakerRuntimeFactory.make(
      modelManager: manager,
      audioAssetRoot: audioRoot
    )
    return FluidProductionSpeakerEvaluationEngine(runtime: runtime)
  }

  private static func writeOutputs(
    _ output: SpeakerEvaluationOutput,
    options: [String: String]
  ) throws {
    try write(
      output.benchmark,
      to: try requiredURL("--benchmark-output", options)
    )
    try write(
      output.decision,
      to: try requiredURL("--decision-output", options)
    )
    try write(
      output.diagnostics,
      to: try requiredURL("--diagnostics-output", options)
    )
  }

  private static func requireNetworkSandbox(
    _ options: [String: String]
  ) throws {
    guard options["--network-denied"] == "true" else {
      throw CLIError.networkSandboxRequired
    }
  }

  private static func parseOptions(_ arguments: [String]) throws
    -> [String: String]
  {
    guard arguments.count.isMultiple(of: 2) else {
      throw CLIError.invalidArguments
    }
    var options: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let key = arguments[index]
      let value = arguments[index + 1]
      guard key.hasPrefix("--"),
        key.count > 2,
        !value.isEmpty,
        options.updateValue(value, forKey: key) == nil
      else {
        throw CLIError.invalidArguments
      }
      index += 2
    }
    return options
  }

  private static func requiredURL(
    _ key: String,
    _ options: [String: String]
  ) throws -> URL {
    guard let value = options[key], value.hasPrefix("/") else {
      throw CLIError.invalidArguments
    }
    return URL(fileURLWithPath: value)
  }

  private static func optionalDouble(
    _ key: String,
    options: [String: String],
    defaultValue: Double
  ) throws -> Double {
    guard let value = options[key] else { return defaultValue }
    guard let parsed = Double(value), parsed.isFinite else {
      throw CLIError.invalidArguments
    }
    return parsed
  }

  private static func write<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
  }

  private static var hardwareContext: BenchmarkHardwareContext {
    BenchmarkHardwareContext(
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      architecture: architecture,
      unifiedMemoryBytes: ProcessInfo.processInfo.physicalMemory,
      toolchainVersion: ProcessInfo.processInfo.environment[
        "BESTASR_TOOLCHAIN_VERSION"
      ] ?? "Apple Swift 6"
    )
  }

  private static var architecture: String {
    #if arch(arm64)
      "arm64"
    #elseif arch(x86_64)
      "x86_64"
    #else
      "unknown"
    #endif
  }
}
