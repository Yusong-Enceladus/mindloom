import AVFoundation
import BestASRAlphaEvaluation
import BestASRBenchmark
import BestASRFluidRuntime
import BestASRInference
import BestASRModelManager
import BestASRQwenRuntime
import Foundation

private enum Command: String {
  case buildCorpus = "build-corpus"
  case buildAlignmentCorpus = "build-alignment-corpus"
  case evaluateAlignment = "evaluate-alignment"
  case alignmentControls = "alignment-controls"
  case evaluate
  case installModel = "install-model"
}

private enum EvaluationBackend: String {
  case parakeet
  case paraformer
  case senseVoice = "sensevoice"
  case whisper
  case qwen = "qwen3-asr"
  case qwenNative = "qwen3-native"
}

private struct SyntheticScriptPlan: Decodable {
  let schemaVersion: Int
  let kind: String
  let runID: UUID
  let manifestID: String
  let version: String
  let samples: [SyntheticScriptSample]
}

private struct SyntheticScriptSample: Decodable {
  let sampleUUID: UUID
  let key: String
  let generator: String
  let fileName: String
  let voice: String?
  let rate: Int?
  let durationSeconds: Double?
  let amplitude: Float?
  let spokenText: String?
  let reference: String
  let languages: [String]
  let tags: [String]
  let dictionaryTerms: [String]
  let dangerousTokens: [AlphaDangerousTokenSpec]
}

private struct ContentFreeCorpusManifest: Encodable {
  let schemaVersion = 1
  let kind = "corpus-manifest"
  let manifestID: String
  let version: String
  let tier = "product-synthetic"
  let releaseHoldout = false
  let containsPrivateContent = false
  let samples: [ContentFreeCorpusSample]
}

private struct ContentFreeCorpusSample: Encodable {
  let sampleUUID: UUID
  let consentClass = "synthetic"
  let assetReference: String
  let contentDigest: String
  let languages: [String]
  let tags: [String]
}

private struct FluidFileTranscriber: AlphaASRFileTranscribing {
  let backend: FluidSenseVoiceBackend

  func transcribe(audioURL: URL, dictionaryTerms: [String]) async throws -> String {
    try await backend.transcribe(
      audioURL: audioURL,
      dictionaryTerms: dictionaryTerms
    )
  }
}

private struct ParaformerFileTranscriber: AlphaASRFileTranscribing {
  let backend: FluidParaformerBackend

  func transcribe(audioURL: URL, dictionaryTerms: [String]) async throws -> String {
    try await backend.transcribe(audioURL: audioURL)
  }
}

private struct ParakeetFileTranscriber: AlphaASRFileTranscribing {
  let backend: FluidParakeetUnifiedBackend

  func transcribe(audioURL: URL, dictionaryTerms: [String]) async throws -> String {
    try await backend.transcribe(audioURL: audioURL)
  }
}

@main
private enum AlphaASREvalCLI {
  static func main() async {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      guard let commandName = arguments.first,
        let command = Command(rawValue: commandName)
      else {
        throw CLIError.invalidArguments
      }
      let options = try parseOptions(Array(arguments.dropFirst()))
      switch command {
      case .buildCorpus:
        try buildCorpus(options: options)
      case .buildAlignmentCorpus:
        try AlignmentCorpusBuilder.build(options: options)
      case .evaluateAlignment:
        try await QwenAlignmentEvaluation.run(options: options)
      case .alignmentControls:
        try await QwenAlignmentControls.run(options: options)
      case .evaluate:
        try await evaluate(options: options)
      case .installModel:
        try await installModel(options: options)
      }
    } catch {
      let code = safeFailureCode(error)
      FileHandle.standardError.write(
        Data("AlphaASREvalCLI failed safely [\(code)]\n".utf8)
      )
      exit(EXIT_FAILURE)
    }
  }

  private static func safeFailureCode(_ error: Error) -> String {
    if let error = error as? AlphaASREvaluationError {
      return "alpha-evaluation-\(String(describing: error))"
    }
    if let error = error as? ModelManagerError {
      return "model-manager-\(error.code)"
    }
    if let error = error as? QwenASREvaluationError {
      return "qwen-asr-\(String(describing: error))"
    }
    if let error = error as? AlignmentEvaluationError {
      return "alignment-\(String(describing: error))"
    }
    if let error = error as? InferenceEngineError { return error.code }
    if error is DecodingError {
      return "json-decoding"
    }
    if let error = error as? CLIError {
      return "cli-\(String(describing: error))"
    }
    let cocoaError = error as NSError
    return "unexpected-\(String(reflecting: type(of: error)))-\(cocoaError.code)"
  }

  private static func buildCorpus(options: [String: String]) throws {
    let planURL = try requiredURL("--plan", options: options)
    let audioRoot = try requiredURL("--audio-root", options: options)
    let localRunURL = try requiredURL("--local-run-output", options: options)
    let contentManifestURL = try requiredURL(
      "--content-manifest-output",
      options: options
    )
    let plan = try JSONDecoder().decode(
      SyntheticScriptPlan.self,
      from: Data(contentsOf: planURL)
    )
    guard plan.schemaVersion == 1,
      plan.kind == "synthetic-asr-script-plan",
      !plan.samples.isEmpty,
      Set(plan.samples.map(\.sampleUUID)).count == plan.samples.count,
      Set(plan.samples.map(\.key)).count == plan.samples.count,
      Set(plan.samples.map(\.fileName)).count == plan.samples.count
    else {
      throw CLIError.invalidPlan
    }
    try FileManager.default.createDirectory(
      at: audioRoot,
      withIntermediateDirectories: true
    )

    var localSamples: [AlphaASRLocalSample] = []
    var contentSamples: [ContentFreeCorpusSample] = []
    for sample in plan.samples {
      guard safeFileName(sample.fileName),
        sample.key.range(
          of: "^[a-z0-9-]+$",
          options: .regularExpression
        ) != nil
      else {
        throw CLIError.invalidPlan
      }
      let output = audioRoot.appendingPathComponent(sample.fileName)
      if FileManager.default.fileExists(atPath: output.path) {
        try FileManager.default.removeItem(at: output)
      }
      switch sample.generator {
      case "speech":
        try synthesizeSpeech(sample, output: output)
      case "silence":
        try writeSyntheticAudio(
          output: output,
          seconds: sample.durationSeconds ?? 4,
          amplitude: 0,
          noise: false
        )
      case "noise":
        try writeSyntheticAudio(
          output: output,
          seconds: sample.durationSeconds ?? 4,
          amplitude: sample.amplitude ?? 0.01,
          noise: true
        )
      default:
        throw CLIError.invalidPlan
      }
      let digest = try LocalModelManager.sha256(of: output)
      localSamples.append(
        AlphaASRLocalSample(
          sampleUUID: sample.sampleUUID,
          relativeAudioPath: sample.fileName,
          languages: sample.languages,
          tags: sample.tags,
          reference: sample.reference,
          dictionaryTerms: sample.dictionaryTerms,
          dangerousTokens: sample.dangerousTokens
        )
      )
      contentSamples.append(
        ContentFreeCorpusSample(
          sampleUUID: sample.sampleUUID,
          assetReference:
            "local-corpus://product-synthetic/alpha-asr-v1/\(sample.key)",
          contentDigest: digest,
          languages: sample.languages,
          tags: Array(Set(sample.tags + ["asr", "local-only"])).sorted()
        )
      )
    }

    let run = AlphaASRLocalRun(
      runID: plan.runID,
      manifestID: plan.manifestID,
      version: plan.version,
      samples: localSamples
    )
    try run.validate()
    try write(run, to: localRunURL)
    try write(
      ContentFreeCorpusManifest(
        manifestID: plan.manifestID,
        version: plan.version,
        samples: contentSamples
      ),
      to: contentManifestURL
    )
    print("alpha ASR synthetic corpus built: \(localSamples.count) samples")
  }

  private static func evaluate(options: [String: String]) async throws {
    let localRunURL = try requiredURL("--local-run", options: options)
    let audioRoot = try requiredURL("--audio-root", options: options)
    let registryURL = try requiredURL("--model-registry", options: options)
    let modelSource = try requiredURL("--model-source", options: options)
    let modelStore = try requiredURL("--model-store", options: options)
    let benchmarkOutput = try requiredURL("--benchmark-output", options: options)
    let decisionOutput = try requiredURL("--decision-output", options: options)
    let localDiagnosticsOutput = try requiredURL(
      "--local-diagnostics-output",
      options: options
    )
    guard
      let evaluationBackend = EvaluationBackend(
        rawValue: options["--backend"] ?? EvaluationBackend.senseVoice.rawValue
      ),
      let evaluationProfile = AlphaASREvaluationProfile(
        rawValue: options["--evaluation-profile"]
          ?? AlphaASREvaluationProfile.combined.rawValue
      )
    else {
      throw CLIError.invalidArguments
    }
    guard options["--network-denied"] == "true" else {
      throw CLIError.networkSandboxRequired
    }
    guard
      isLocalDiagnosticsPath(
        localDiagnosticsOutput,
        explicitRoot: options["--local-diagnostics-root"]
      )
    else {
      throw CLIError.invalidArguments
    }

    let run = try AlphaASRLocalRun.decode(Data(contentsOf: localRunURL))
    let registry = try ManagedModelRegistry.decode(Data(contentsOf: registryURL))
    let manager = try LocalModelManager(
      rootDirectory: modelStore,
      registry: registry
    )
    let artifactID: String
    let sourceRevision: String
    let treeSHA256: String
    let runtimeRevision: String
    let encoderPrecision: String
    var additionalConfiguration: [String: String] = [:]
    var nativeQwenTranscriber: NativeQwenFileTranscriber?
    let transcriber: any AlphaASRFileTranscribing
    switch evaluationBackend {
    case .parakeet:
      let active = try await activateModel(
        manager: manager,
        artifactID: FluidParakeetUnifiedPinnedArtifact.artifactID,
        version: FluidParakeetUnifiedPinnedArtifact.sourceRevision,
        source: modelSource,
        healthCheck: FluidParakeetUnifiedModelHealthCheck()
      )
      artifactID = FluidParakeetUnifiedPinnedArtifact.artifactID
      sourceRevision = FluidParakeetUnifiedPinnedArtifact.sourceRevision
      treeSHA256 = FluidParakeetUnifiedPinnedArtifact.treeSHA256
      runtimeRevision = FluidParakeetUnifiedPinnedArtifact.runtimeRevision
      encoderPrecision = "int8"
      transcriber = ParakeetFileTranscriber(
        backend: try await FluidParakeetUnifiedBackend(
          verifiedModelDirectory: active.directory
        )
      )
    case .senseVoice:
      let active = try await activateModel(
        manager: manager,
        artifactID: FluidSenseVoicePinnedArtifact.artifactID,
        version: FluidSenseVoicePinnedArtifact.sourceRevision,
        source: modelSource,
        healthCheck: FluidSenseVoiceModelHealthCheck()
      )
      artifactID = FluidSenseVoicePinnedArtifact.artifactID
      sourceRevision = FluidSenseVoicePinnedArtifact.sourceRevision
      treeSHA256 = FluidSenseVoicePinnedArtifact.treeSHA256
      runtimeRevision = FluidSenseVoicePinnedArtifact.runtimeRevision
      encoderPrecision = "int8"
      transcriber = FluidFileTranscriber(
        backend: try FluidSenseVoiceBackend(
          verifiedModelDirectory: active.directory
        )
      )
    case .paraformer:
      let active = try await activateModel(
        manager: manager,
        artifactID: FluidParaformerPinnedArtifact.artifactID,
        version: FluidParaformerPinnedArtifact.sourceRevision,
        source: modelSource,
        healthCheck: FluidParaformerModelHealthCheck()
      )
      artifactID = FluidParaformerPinnedArtifact.artifactID
      sourceRevision = FluidParaformerPinnedArtifact.sourceRevision
      treeSHA256 = FluidParaformerPinnedArtifact.treeSHA256
      runtimeRevision = FluidParaformerPinnedArtifact.runtimeRevision
      encoderPrecision = "int8"
      transcriber = ParaformerFileTranscriber(
        backend: try FluidParaformerBackend(
          verifiedModelDirectory: active.directory
        )
      )
    case .whisper:
      guard
        let descriptor = registry.artifact(
          id: WhisperEvaluationArtifact.modelID,
          version: WhisperEvaluationArtifact.modelRevision
        )
      else { throw CLIError.invalidArguments }
      let active = try await activateModel(
        manager: manager,
        artifactID: descriptor.id,
        version: descriptor.exactVersion,
        source: modelSource,
        healthCheck: FileSetModelHealthCheck()
      )
      let tokenizer = try await activateModel(
        manager: manager,
        artifactID: WhisperEvaluationArtifact.tokenizerID,
        version: WhisperEvaluationArtifact.tokenizerRevision,
        source: try requiredURL("--tokenizer-source", options: options),
        healthCheck: FileSetModelHealthCheck()
      )
      artifactID = descriptor.id
      sourceRevision = descriptor.sourceRevision
      treeSHA256 = descriptor.treeSHA256
      runtimeRevision = WhisperEvaluationArtifact.runtimeRevision
      encoderPrecision = "upstream-626mb-quantized-coreml"
      additionalConfiguration = [
        "executionMode": "developer-challenger-local-corpus",
        "tokenizerArtifact": tokenizer.descriptor.id,
        "tokenizerRevision": tokenizer.descriptor.sourceRevision,
        "tokenizerTreeSHA256": tokenizer.descriptor.treeSHA256,
        "decoding": "greedy-temperature-zero-no-fallback-auto-language",
        "dictionaryPromptMaximumTokens": "128",
        "concurrentWorkers": "1",
        "compute": "mel-cpu-gpu-encoder-decoder-cpu-ane",
      ]
      let whisper = WhisperFileTranscriber(
        verifiedModelDirectory: active.directory,
        verifiedTokenizerDirectory: tokenizer.directory
      )
      try await whisper.prepare()
      transcriber = whisper
    case .qwen, .qwenNative:
      guard
        let descriptor = registry.artifact(
          id: QwenASREvaluationArtifact.modelID,
          version: QwenASREvaluationArtifact.modelRevision
        )
      else { throw CLIError.invalidArguments }
      let active = try await activateModel(
        manager: manager,
        artifactID: descriptor.id,
        version: descriptor.exactVersion,
        source: modelSource,
        healthCheck: FileSetModelHealthCheck()
      )
      artifactID = descriptor.id
      sourceRevision = descriptor.sourceRevision
      treeSHA256 = descriptor.treeSHA256
      runtimeRevision = QwenASREvaluationArtifact.runtimeRevision
      encoderPrecision = "mlx-upstream-float-encoder-8bit-text"
      additionalConfiguration = [
        "executionMode": "developer-challenger-local-corpus",
        "tokenizer": "in-memory-upstream-qwen2-bpe-no-model-writes",
        "decoding": "greedy-temperature-zero-auto-language",
        "maximumTokensPerChunk": "2048",
        "maximumChunkSeconds": "30",
        "dictionaryMaximumTerms": "64",
        "dictionaryMaximumCharactersPerTerm": "128",
        "compute": "mlx-metal",
        "concurrentWorkers": "1",
      ]
      if evaluationBackend == .qwenNative {
        let alignment = try await activateModel(
          manager: manager,
          artifactID: QwenAlignmentPinnedArtifact.artifactID,
          version: QwenAlignmentPinnedArtifact.sourceRevision,
          source: try requiredURL("--alignment-source", options: options),
          healthCheck: FileSetModelHealthCheck())
        let qwen = NativeQwenFileTranscriber(
          verifiedASRDirectory: active.directory,
          verifiedAlignmentDirectory: alignment.directory)
        try await qwen.prepare()
        nativeQwenTranscriber = qwen
        transcriber = qwen
        additionalConfiguration["executionMode"] = "native-product-final-runtime-local-corpus"
        additionalConfiguration["pipelineRevision"] = QwenASRPinnedArtifact.pipelineRevision
        additionalConfiguration["alignmentArtifactID"] = QwenAlignmentPinnedArtifact.artifactID
        additionalConfiguration["alignmentRevision"] = QwenAlignmentPinnedArtifact.sourceRevision
        additionalConfiguration["alignmentTreeSHA256"] = QwenAlignmentPinnedArtifact.treeSHA256
        additionalConfiguration["dictionaryContextMaximumUTF8Bytes"] = "2048"
        additionalConfiguration["decoding"] = "actor-owned-greedy-public-forward-token-cancellation"
      } else {
        let qwen = QwenASRFileTranscriber(verifiedModelDirectory: active.directory)
        try await qwen.prepare()
        transcriber = qwen
      }
    }
    let evaluator = AlphaASREvaluator(
      transcriber: transcriber,
      policy: AlphaASREvaluationPolicy(profile: evaluationProfile)
    )
    let output = try await evaluator.evaluate(
      run: run,
      audioRoot: audioRoot,
      benchmarkID: options["--benchmark-id"]
        ?? "asr-alpha-fluid-sensevoice-v1",
      implementationRevision: runtimeRevision,
      modelArtifact: BenchmarkModelArtifact(
        artifactID: artifactID,
        sha256: treeSHA256
      ),
      configuration: [
        "backend": evaluationBackend.rawValue,
        "encoderPrecision": encoderPrecision,
        "evaluationProfile": evaluationProfile.rawValue,
        "executionMode": "production-runtime-local-corpus",
        "networkPolicy": "parent-sandbox-deny-all",
        "runtimeRevision": runtimeRevision,
        "sourceRevision": sourceRevision,
      ].merging(additionalConfiguration) { _, additional in additional },
      environmentRef: "artifacts/evidence/environment/check-summary.json",
      hardware: BenchmarkHardwareContext(
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: architecture,
        unifiedMemoryBytes: ProcessInfo.processInfo.physicalMemory,
        toolchainVersion: ProcessInfo.processInfo.environment[
          "BESTASR_TOOLCHAIN_VERSION"
        ] ?? "Apple Swift 6"
      ),
      networkDeniedByParentSandbox: true
    )
    try write(output.benchmark, to: benchmarkOutput)
    try write(output.decision, to: decisionOutput)
    try write(output.localDiagnostics, to: localDiagnosticsOutput)
    if let nativeQwenTranscriber {
      try await nativeQwenTranscriber.writeTimings(
        to:
          localDiagnosticsOutput.deletingLastPathComponent().appendingPathComponent(
            "aligned-segments.json"))
    }
    print(
      "alpha ASR evaluation \(output.decision.status): "
        + "\(output.decision.sampleCount) samples"
    )
  }

  /// Installs one exact-pinned ASR artifact into a local model store. This is
  /// intentionally a source-directory operation so dogfood and offline
  /// provisioning use the same verified, atomic activation path as the app.
  private static func installModel(options: [String: String]) async throws {
    let registryURL = try requiredURL("--model-registry", options: options)
    let modelSource = try requiredURL("--model-source", options: options)
    let modelStore = try requiredURL("--model-store", options: options)
    guard options["--network-denied"] == "true" else {
      throw CLIError.networkSandboxRequired
    }
    guard let backend = EvaluationBackend(rawValue: options["--backend"] ?? "")
    else { throw CLIError.invalidArguments }

    let registry = try ManagedModelRegistry.decode(
      Data(contentsOf: registryURL)
    )
    let manager = try LocalModelManager(
      rootDirectory: modelStore,
      registry: registry
    )
    let result: ModelActivationResult
    switch backend {
    case .senseVoice:
      result = try await manager.activate(
        artifactID: FluidSenseVoicePinnedArtifact.artifactID,
        version: FluidSenseVoicePinnedArtifact.sourceRevision,
        from: modelSource,
        healthCheck: FluidSenseVoiceModelHealthCheck()
      )
    case .paraformer:
      result = try await manager.activate(
        artifactID: FluidParaformerPinnedArtifact.artifactID,
        version: FluidParaformerPinnedArtifact.sourceRevision,
        from: modelSource,
        healthCheck: FluidParaformerModelHealthCheck()
      )
    case .parakeet:
      result = try await manager.activate(
        artifactID: FluidParakeetUnifiedPinnedArtifact.artifactID,
        version: FluidParakeetUnifiedPinnedArtifact.sourceRevision,
        from: modelSource,
        healthCheck: FluidParakeetUnifiedModelHealthCheck()
      )
    case .qwenNative:
      result = try await manager.activate(
        artifactID: QwenASRPinnedArtifact.artifactID,
        version: QwenASRPinnedArtifact.sourceRevision, from: modelSource,
        healthCheck: QwenASRModelHealthCheck())
      _ = try await manager.activate(
        artifactID: QwenAlignmentPinnedArtifact.artifactID,
        version: QwenAlignmentPinnedArtifact.sourceRevision,
        from: try requiredURL("--alignment-source", options: options),
        healthCheck: QwenAlignmentModelHealthCheck())
      _ = try await manager.discoverActive(
        artifactID: QwenAlignmentPinnedArtifact.artifactID,
        healthCheck: FileSetModelHealthCheck())
    case .whisper, .qwen:
      // Evaluation activates the separate pinned model/tokenizer pair. This
      // command provisions production ASR only, so it must not install a
      // challenger into the user's active App model store.
      throw CLIError.invalidArguments
    }
    _ = try await manager.discoverActive(
      artifactID: result.artifactID,
      healthCheck: FileSetModelHealthCheck()
    )
    print(
      "installed exact local model: \(result.artifactID) "
        + "(\(result.disposition.rawValue), \(result.verifiedFileCount) files)"
    )
  }

  private static func activateModel(
    manager: LocalModelManager,
    artifactID: String,
    version: String,
    source: URL,
    healthCheck: any ManagedModelHealthChecking
  ) async throws -> ActiveManagedModel {
    do {
      return try await manager.discoverActive(
        artifactID: artifactID,
        healthCheck: FileSetModelHealthCheck()
      )
    } catch {
      _ = try await manager.activate(
        artifactID: artifactID,
        version: version,
        from: source,
        healthCheck: healthCheck
      )
      return try await manager.discoverActive(
        artifactID: artifactID,
        healthCheck: FileSetModelHealthCheck()
      )
    }
  }

  private static func synthesizeSpeech(
    _ sample: SyntheticScriptSample,
    output: URL
  ) throws {
    guard let voice = sample.voice,
      let rate = sample.rate,
      (80...360).contains(rate),
      let spokenText = sample.spokenText,
      !spokenText.isEmpty
    else {
      throw CLIError.invalidPlan
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = [
      "-v", voice,
      "-r", String(rate),
      "-o", output.path,
      spokenText,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
      FileManager.default.fileExists(atPath: output.path)
    else {
      throw CLIError.synthesisFailed
    }
  }

  private static func writeSyntheticAudio(
    output: URL,
    seconds: Double,
    amplitude: Float,
    noise: Bool
  ) throws {
    guard seconds.isFinite, seconds > 0, seconds <= 30,
      amplitude.isFinite, amplitude >= 0, amplitude <= 0.1,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      )
    else {
      throw CLIError.invalidPlan
    }
    let frameCount = AVAudioFrameCount((seconds * 16_000).rounded())
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
      ), let samples = buffer.floatChannelData?[0]
    else {
      throw CLIError.synthesisFailed
    }
    buffer.frameLength = frameCount
    var state: UInt64 = 0x6a09_e667_f3bc_c909
    for index in 0..<Int(frameCount) {
      if noise {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        let unit = Float((state >> 40) & 0x00ff_ffff) / Float(0x00ff_ffff)
        samples[index] = (unit * 2 - 1) * amplitude
      } else {
        samples[index] = 0
      }
    }
    let file = try AVAudioFile(forWriting: output, settings: format.settings)
    try file.write(from: buffer)
  }

  private static func parseOptions(_ arguments: [String]) throws
    -> [String: String]
  {
    var options: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let key = arguments[index]
      guard key.hasPrefix("--"), index + 1 < arguments.count,
        options[key] == nil
      else {
        throw CLIError.invalidArguments
      }
      options[key] = arguments[index + 1]
      index += 2
    }
    return options
  }

  private static func requiredURL(
    _ key: String,
    options: [String: String]
  ) throws -> URL {
    guard let value = options[key], !value.isEmpty else {
      throw CLIError.invalidArguments
    }
    return URL(fileURLWithPath: value)
  }

  private static func safeFileName(_ value: String) -> Bool {
    !value.isEmpty
      && !value.contains("/")
      && value != "."
      && value != ".."
      && value.range(
        of: "^[A-Za-z0-9._-]+$",
        options: .regularExpression
      ) != nil
  }

  private static func isLocalDiagnosticsPath(
    _ url: URL,
    explicitRoot: String?
  ) -> Bool {
    if let explicitRoot, !explicitRoot.isEmpty {
      let root = URL(fileURLWithPath: explicitRoot)
        .resolvingSymlinksInPath()
        .standardizedFileURL
      let output =
        url
        .resolvingSymlinksInPath()
        .standardizedFileURL
      return output.path.hasPrefix(root.path + "/")
    }
    let components = url.standardizedFileURL.pathComponents
    guard components.count >= 4 else { return false }
    return components.indices.dropLast(2).contains { index in
      components[index] == "benchmarks"
        && components[index + 1] == "results"
        && components[index + 2] == "local"
    }
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

  private static var architecture: String {
    #if arch(arm64)
      "arm64"
    #else
      "unsupported"
    #endif
  }
}

private enum CLIError: Error {
  case invalidArguments
  case invalidPlan
  case networkSandboxRequired
  case synthesisFailed
}
