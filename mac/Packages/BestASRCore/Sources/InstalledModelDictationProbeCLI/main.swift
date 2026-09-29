import AVFoundation
import BestASRAudioJournal
import BestASRCandidateAdapters
import BestASRDictation
import BestASRDomain
import BestASRFluidRuntime
import BestASRInference
import BestASRMLXRuntime
import BestASRModelManager
import BestASRPersistence
import BestASRProcessing
import BestASRRecognition
import Darwin
import Foundation

private enum ProbeError: Error {
  case invalidArguments
  case invalidAudio
  case invalidCandidate
  case invalidResult
  case networkSandboxRequired
  case persistence(String)
  case recognition(String)
}

private struct ProbeSummary: Encodable {
  let schemaVersion = 6
  let kind = "installed-model-dictation-probe"
  let status: String
  let appVersion: String
  let buildConfiguration: String
  let networkDeniedByParentSandbox: Bool
  let modelArtifactID: String
  let modelVersion: String
  let modelActivation: String
  let polishModelArtifactID: String
  let polishModelVersion: String
  let polishModelTreeSHA256: String
  let polishModelActivation: String
  let finalPhase: String
  let sourceAudioRangeCount: Int
  let sourceAudioPreserved: Bool
  let transcriptCharacterCount: Int
  let transcriptSegmentCount: Int
  let polishDisposition: String
  let insertionMethod: String
  let externalInsertionPerformed: Bool
  let dictionaryEntryCount: Int
  let sessionSpeakerCount: Int
  let speakerOccurrenceCount: Int
  let speakerJobState: String
  let firstRunToReadyMilliseconds: Double
  let readyToFirstLiveTextMilliseconds: Double
  let finishToFinalTextMilliseconds: Double
  let liveTranscriptCharacterCount: Int
  let maximumLiveQueueDepth: Int
  let offlineRelaunchReady: Bool
  let recoveryOutcome: String
  let asrProcessingMilliseconds: Double
  let postASRProcessingMilliseconds: Double
  let pipelineOverheadMilliseconds: Double
  let dictationProcessingMilliseconds: Double
  let elapsedMilliseconds: Double
  let peakRSSBytes: UInt64
}

private struct ProbeActivation {
  let artifactID: String
  let version: String
  let disposition: ModelActivationDisposition
}

private actor ProbeInsertion: DictationInsertionPort {
  private let target: DictationTargetSnapshot
  private(set) var characterCount = 0

  init(target: DictationTargetSnapshot) {
    self.target = target
  }

  func captureTarget() async throws -> DictationTargetSnapshot { target }

  func insert(
    _ request: DictationInsertionRequest
  ) async throws -> DictationInsertionResult {
    characterCount = request.text.count
    return DictationInsertionResult(
      idempotencyKey: request.idempotencyKey,
      method: .retainedForCopy,
      inserted: false
    )
  }
}

private struct ProbeASRResult: DictationASRPort {
  let result: DictationTranscriptResult

  func recognize(
    _ request: DictationASRRequest
  ) async throws -> DictationTranscriptResult {
    result
  }
}

private actor ProbeRepository: DictationProcessingRepositoryPort {
  private let store: GRDBDictationStore
  private(set) var lastErrorCode: String?

  init(store: GRDBDictationStore) { self.store = store }

  func create(_ snapshot: DictationSessionSnapshot) async throws {
    try await store.create(snapshot)
  }
  func save(_ snapshot: DictationSessionSnapshot) async throws {
    try await store.save(snapshot)
  }
  func load(sessionID: SessionID) async throws -> DictationSessionSnapshot? {
    try await store.load(sessionID: sessionID)
  }
  func loadRecoverable() async throws -> [DictationSessionSnapshot] {
    try await store.loadRecoverable()
  }
  func reserveInsertion(
    sessionID: SessionID,
    key: DictationIdempotencyKey
  ) async throws -> InsertionReservation {
    try await store.reserveInsertion(sessionID: sessionID, key: key)
  }
  func completeInsertion(
    sessionID: SessionID,
    result: DictationInsertionResult
  ) async throws {
    try await store.completeInsertion(sessionID: sessionID, result: result)
  }
  func insertionResult(
    sessionID: SessionID
  ) async throws -> DictationInsertionResult? {
    try await store.insertionResult(sessionID: sessionID)
  }
  func cancelEphemeral(sessionID: SessionID) async throws {
    try await store.cancelEphemeral(sessionID: sessionID)
  }
  func commitRecognition(_ commit: DictationRecognitionCommit) async throws {
    do {
      try await store.commitRecognition(commit)
    } catch {
      lastErrorCode = String(describing: error)
      throw error
    }
  }
  func commitPolish(_ commit: DictationPolishCommit) async throws {
    do {
      try await store.commitPolish(commit)
    } catch {
      lastErrorCode = String(describing: error)
      throw error
    }
  }
  func commitInsertion(_ commit: DictationInsertionCommit) async throws {
    do {
      try await store.commitInsertion(commit)
    } catch {
      lastErrorCode = String(describing: error)
      throw error
    }
  }
}

private actor ProbeLiveRepository: DictationTranscriptRevisionRepositoryPort {
  private var commits: [DictationTranscriptRevisionCommit] = []

  func commitTranscriptRevision(
    _ commit: DictationTranscriptRevisionCommit
  ) async throws {
    commits.append(commit)
  }

  func commitCount() -> Int { commits.count }
}

private final class ProbeLiveRecorder: @unchecked Sendable {
  struct Snapshot {
    let firstTextNanoseconds: UInt64?
    let characterCount: Int
    let maximumPendingDepth: Int
  }

  private let lock = NSLock()
  private var firstTextNanoseconds: UInt64?
  private var characterCount = 0
  private var maximumPendingDepth = 0

  func record(_ event: LiveDictationEvent) {
    guard case .text = event.state, !event.text.isEmpty else { return }
    lock.lock()
    if firstTextNanoseconds == nil {
      firstTextNanoseconds = DispatchTime.now().uptimeNanoseconds
      characterCount = event.text.count
    }
    lock.unlock()
  }

  func record(pendingDepth: Int) {
    lock.lock()
    maximumPendingDepth = max(maximumPendingDepth, pendingDepth)
    lock.unlock()
  }

  func snapshot() -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(
      firstTextNanoseconds: firstTextNanoseconds,
      characterCount: characterCount,
      maximumPendingDepth: maximumPendingDepth
    )
  }
}

@main
private enum InstalledModelDictationProbeCLI {
  static func main() async {
    do {
      let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
      try await run(options)
    } catch {
      FileHandle.standardError.write(
        Data(
          "InstalledModelDictationProbeCLI failed safely: \(safeErrorCode(error))\n"
            .utf8
        )
      )
      exit(EXIT_FAILURE)
    }
  }

  private static func run(_ options: [String: String]) async throws {
    guard options["--network-denied"] == "true" else {
      throw ProbeError.networkSandboxRequired
    }
    guard options["--build-configuration"] == "release" else {
      throw ProbeError.invalidArguments
    }
    let audioURL = try requiredURL("--audio", options)
    let modelRegistryURL = try requiredURL("--model-registry", options)
    let candidateRegistryURL = try requiredURL("--candidate-registry", options)
    let modelSourceURL = try requiredURL("--model-source", options)
    let polishModelSourceURL = try requiredURL(
      "--polish-model-source",
      options
    )
    let modelStoreURL = try requiredURL("--model-store", options)
    let workRootURL = try requiredURL("--work-root", options)
    let summaryURL = try requiredURL("--summary", options)
    try FileManager.default.createDirectory(
      at: workRootURL,
      withIntermediateDirectories: true
    )

    let started = DispatchTime.now().uptimeNanoseconds
    let registry = try ManagedModelRegistry.decode(
      Data(contentsOf: modelRegistryURL)
    )
    let manager = try LocalModelManager(
      rootDirectory: modelStoreURL,
      registry: registry
    )

    let candidateManifest = try ASRCandidateManifest.decode(
      Data(contentsOf: candidateRegistryURL)
    )
    guard
      let candidate = candidateManifest.candidates.first(where: {
        $0.alphaDefault && $0.adapterKind == .fluidSenseVoice
      })
    else {
      throw ProbeError.invalidCandidate
    }

    let sessionID = SessionID(
      UUID(uuidString: "31000000-0000-4000-8000-000000000001")!
    )
    let repository = try GRDBDictationStore(
      databaseURL: workRootURL.appendingPathComponent("history.sqlite")
    )
    let journal = try ProductionAudioJournal(
      assetRootURL: workRootURL.appendingPathComponent("assets", isDirectory: true)
    )
    let actor = DictationSessionActor()
    let targetSnapshot = try target()
    let preparing = try await actor.handle(
      .start(sessionID: sessionID, target: targetSnapshot)
    )
    try await repository.create(preparing)
    let recording = try await actor.handle(.preparationSucceeded)
    try await repository.save(recording)

    let capture = try capturedAudio(at: audioURL, sessionID: sessionID)
    try await journal.create(sessionID: sessionID, descriptor: capture.descriptor)
    for chunk in capture.chunks {
      try await journal.append(sessionID: sessionID, chunk: chunk)
    }
    _ = try await repository.createDictionaryEntry(
      canonicalForm: "bestASR",
      spokenForms: ["best A S R"]
    )
    let dictionary = try await repository.dictionaryContext(
      maximumEntries: 64,
      maximumUTF8Bytes: 16_384
    )
    let committedRanges = try await journal.committedAudioSnapshot(
      sessionID: sessionID
    )
    let preparedRanges = try await journal.prepareInferenceAudio(
      sessionID: sessionID,
      sourceAudio: committedRanges
    )
    let preparedRangesAreValid =
      !preparedRanges.isEmpty
      && preparedRanges.allSatisfy({
        $0.sampleRateHertz == 16_000 && $0.channelCount == 1
      })
    await journal.discardInferenceAudio(
      sessionID: sessionID,
      preparedAudio: preparedRanges
    )
    guard preparedRangesAreValid else {
      throw ProbeError.invalidAudio
    }
    let runtime: FluidSenseVoiceRuntime
    let activation: ProbeActivation
    do {
      runtime = try await FluidSenseVoiceRuntimeFactory.make(
        modelManager: manager,
        audioAssetRoot: await journal.assetRootURL
      )
      activation = ProbeActivation(
        artifactID: FluidSenseVoicePinnedArtifact.artifactID,
        version: FluidSenseVoicePinnedArtifact.sourceRevision,
        disposition: .alreadyActive
      )
    } catch {
      let activated = try await manager.activate(
        artifactID: FluidSenseVoicePinnedArtifact.artifactID,
        version: FluidSenseVoicePinnedArtifact.sourceRevision,
        from: modelSourceURL,
        healthCheck: FluidSenseVoiceModelHealthCheck()
      )
      runtime = try await FluidSenseVoiceRuntimeFactory.make(
        modelManager: manager,
        audioAssetRoot: await journal.assetRootURL
      )
      activation = ProbeActivation(
        artifactID: activated.artifactID,
        version: activated.version,
        disposition: activated.disposition
      )
    }
    let engine = try FluidSenseVoiceASRAdapter(
      candidate: candidate,
      runtime: runtime,
      artifact: FluidSenseVoicePinnedArtifact.descriptor
    )
    let polishArtifact = MLXLocalTextArtifact.qwen3Selected
    let polishActivation: ProbeActivation
    do {
      _ = try await manager.discoverActive(
        artifactID: polishArtifact.artifactID,
        healthCheck: FileSetModelHealthCheck()
      )
      polishActivation = ProbeActivation(
        artifactID: polishArtifact.artifactID,
        version: polishArtifact.sourceRevision,
        disposition: .alreadyActive
      )
    } catch {
      let activated = try await manager.activate(
        artifactID: polishArtifact.artifactID,
        version: polishArtifact.sourceRevision,
        from: polishModelSourceURL,
        healthCheck: MLXLocalTextModelHealthCheck()
      )
      polishActivation = ProbeActivation(
        artifactID: activated.artifactID,
        version: activated.version,
        disposition: activated.disposition
      )
    }
    let polishEngine = try await MLXLocalTextRuntimeFactory.make(
      modelManager: manager,
      artifact: polishArtifact
    )
    let modelReady = DispatchTime.now().uptimeNanoseconds
    let asrHash = try SHA256Digest(String(repeating: "a", count: 64))
    let polishHash = try SHA256Digest(String(repeating: "b", count: 64))
    let polishAdapter = try MLXDictationPolishAdapter(
      engine: polishEngine,
      artifactID: polishArtifact.artifactID,
      configHash: polishHash.value
    )
    let asr = BoundedDictationASRAdapter(
      engine: engine,
      audio: journal,
      configHash: asrHash,
      policy: try BoundedDictationASRPolicy()
    )
    let liveRepository = ProbeLiveRepository()
    let liveRecorder = ProbeLiveRecorder()
    let liveCoordinator = LiveDictationCoordinator(
      audio: journal,
      asr: asr,
      repository: liveRepository,
      contextProvider: {
        LiveDictationContext(
          dictionaryTerms: dictionary.canonicalTerms,
          dictionaryHints: dictionary.asrDictionaryHints,
          configHash: asrHash
        )
      },
      policy: try LiveDictationPolicy(),
      silenceConfiguration: try DictationSilenceConfiguration(),
      eventHandler: { event in liveRecorder.record(event) }
    )
    for chunk in capture.chunks {
      await liveCoordinator.didCommit(sessionID: sessionID, chunk: chunk)
      if let scheduling = await liveCoordinator.schedulingSnapshot(
        sessionID: sessionID
      ) {
        liveRecorder.record(pendingDepth: scheduling.pendingRequestCount)
      }
    }
    try await waitForFirstLiveText(liveRecorder)
    let liveMeasurement = liveRecorder.snapshot()
    guard let firstLiveText = liveMeasurement.firstTextNanoseconds,
      liveMeasurement.characterCount > 0,
      await liveRepository.commitCount() > 0
    else {
      throw ProbeError.invalidResult
    }
    await liveCoordinator.didReachBoundary(sessionID: sessionID, kind: .final)

    let finalizing = try await actor.handle(.end)
    try await repository.save(finalizing)
    let ranges = try await journal.seal(sessionID: sessionID)
    let finishStarted = DispatchTime.now().uptimeNanoseconds
    let recognitionRequest = DictationASRRequest(
      sessionID: sessionID,
      inputRevision: finalizing.revision,
      audio: ranges,
      dictionaryTerms: dictionary.canonicalTerms,
      dictionaryHints: dictionary.asrDictionaryHints
    )
    let dictationStarted = DispatchTime.now().uptimeNanoseconds
    let recognized = try await asr.recognize(recognitionRequest)
    let asrFinished = DispatchTime.now().uptimeNanoseconds
    try validateRecognition(
      recognized,
      sourceAudio: ranges,
      expectedKind: .final
    )
    let validationActor = DictationSessionActor(initialSnapshot: finalizing)
    _ = try await validationActor.handle(.journalSealed)
    let validationSnapshot = try await validationActor.handle(
      .recognitionSucceeded(recognized)
    )
    try validationSnapshot.validate()
    let insertion = ProbeInsertion(target: targetSnapshot)
    let processingRepository = ProbeRepository(store: repository)
    let coordinator = DictationProcessingCoordinator(
      initialSnapshot: finalizing,
      repository: processingRepository,
      asr: ProbeASRResult(result: recognized),
      polish: polishAdapter,
      insertion: insertion,
      speaker: GRDBSingleSpeakerScheduler(store: repository)
    )
    let processingRequest = DictationProcessingRequest(
      sessionID: sessionID,
      inputRevision: finalizing.revision,
      audio: ranges,
      dictionaryTerms: dictionary.canonicalTerms,
      dictionaryHints: dictionary.asrDictionaryHints,
      asrConfigHash: asrHash,
      polishConfigHash: polishHash,
      insertionKey: try DictationIdempotencyKey(
        "insert:\(sessionID.rawValue.uuidString):\(finalizing.revision)"
      )
    )
    let outcome: DictationProcessingOutcome
    let postASRStarted = DispatchTime.now().uptimeNanoseconds
    do {
      outcome = try await coordinator.process(processingRequest)
    } catch {
      if let persistenceCode = await processingRepository.lastErrorCode {
        throw ProbeError.persistence(persistenceCode)
      }
      throw error
    }
    let dictationFinished = DispatchTime.now().uptimeNanoseconds

    let persistedTranscripts = try await repository.loadTranscripts(
      sessionID: sessionID
    )
    let speakerWork = try await repository.loadSingleSpeakerWork(
      sessionID: sessionID
    )
    let recovery = try await journal.recover(sessionID: sessionID)
    let reopenedManager = try LocalModelManager(
      rootDirectory: modelStoreURL,
      registry: registry
    )
    let reopenedSpeech = try await reopenedManager.discoverActive(
      artifactID: FluidSenseVoicePinnedArtifact.artifactID,
      healthCheck: FluidSenseVoiceModelHealthCheck()
    )
    let reopenedPolish = try await reopenedManager.discoverActive(
      artifactID: polishArtifact.artifactID,
      healthCheck: FileSetModelHealthCheck()
    )
    let offlineRelaunchReady =
      reopenedSpeech.descriptor.exactVersion == activation.version
      && reopenedPolish.descriptor.exactVersion == polishActivation.version
    let insertedCharacterCount = await insertion.characterCount
    guard outcome.snapshot.phase == .completed,
      let transcript = outcome.snapshot.transcript,
      let polish = outcome.snapshot.polish,
      let insertionResult = outcome.snapshot.insertion,
      !transcript.text.isEmpty,
      insertedCharacterCount == polish.text.count,
      persistedTranscripts.count == 1,
      persistedTranscripts[0].audioRanges == ranges,
      speakerWork?.occurrences.count == ranges.count,
      speakerWork?.job.state == .queued,
      recovery.state == .sealed,
      recovery.readableCommittedChunkCount == capture.chunks.count,
      recovery.issueCount == 0
    else {
      throw ProbeError.invalidResult
    }
    let assetRootURL = await journal.assetRootURL
    let sourceAudioPreserved = ranges.allSatisfy {
      FileManager.default.fileExists(
        atPath: assetRootURL.appendingPathComponent(
          $0.assetReference
        ).path
      )
    }
    guard sourceAudioPreserved else { throw ProbeError.invalidResult }

    let finished = DispatchTime.now().uptimeNanoseconds
    let elapsed = Double(finished - started) / 1_000_000
    let modelPreparation = Double(modelReady - started) / 1_000_000
    let asrProcessing = Double(asrFinished - dictationStarted) / 1_000_000
    let postASRProcessing =
      Double(dictationFinished - postASRStarted)
      / 1_000_000
    let dictationProcessing =
      Double(dictationFinished - dictationStarted)
      / 1_000_000
    let pipelineOverhead =
      dictationProcessing - asrProcessing - postASRProcessing
    let summary = ProbeSummary(
      status: "pass",
      appVersion: "0.1.0",
      buildConfiguration: "release",
      networkDeniedByParentSandbox: true,
      modelArtifactID: activation.artifactID,
      modelVersion: activation.version,
      modelActivation: activation.disposition.rawValue,
      polishModelArtifactID: polishActivation.artifactID,
      polishModelVersion: polishActivation.version,
      polishModelTreeSHA256: polishArtifact.treeSHA256,
      polishModelActivation: polishActivation.disposition.rawValue,
      finalPhase: outcome.snapshot.phase.rawValue,
      sourceAudioRangeCount: ranges.count,
      sourceAudioPreserved: sourceAudioPreserved,
      transcriptCharacterCount: transcript.text.count,
      transcriptSegmentCount: transcript.segmentIDs.count,
      polishDisposition: polish.disposition.rawValue,
      insertionMethod: insertionResult.method.rawValue,
      externalInsertionPerformed: insertionResult.inserted,
      dictionaryEntryCount: dictionary.entries.count,
      sessionSpeakerCount: speakerWork == nil ? 0 : 1,
      speakerOccurrenceCount: speakerWork?.occurrences.count ?? 0,
      speakerJobState: speakerWork?.job.state.rawValue ?? "missing",
      firstRunToReadyMilliseconds: modelPreparation,
      readyToFirstLiveTextMilliseconds: Double(firstLiveText - modelReady)
        / 1_000_000,
      finishToFinalTextMilliseconds: Double(asrFinished - finishStarted)
        / 1_000_000,
      liveTranscriptCharacterCount: liveMeasurement.characterCount,
      maximumLiveQueueDepth: liveMeasurement.maximumPendingDepth,
      offlineRelaunchReady: offlineRelaunchReady,
      recoveryOutcome: "sealed-source-readable",
      asrProcessingMilliseconds: asrProcessing,
      postASRProcessingMilliseconds: postASRProcessing,
      pipelineOverheadMilliseconds: pipelineOverhead,
      dictationProcessingMilliseconds: dictationProcessing,
      elapsedMilliseconds: elapsed,
      peakRSSBytes: peakRSSBytes()
    )
    try write(summary, to: summaryURL)
    try await repository.checkpointAndClose()
    print("installed-model dictation probe passed")
  }

  private static func capturedAudio(
    at url: URL,
    sessionID: SessionID
  ) throws -> (
    descriptor: MicrophoneCaptureDescriptor,
    chunks: [CapturedPCMChunk]
  ) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    guard format.commonFormat == .pcmFormatFloat32,
      format.channelCount > 0,
      format.channelCount <= UInt32(UInt16.max),
      format.sampleRate > 0,
      format.sampleRate <= Double(UInt32.max),
      file.length > 0,
      file.length <= Int64(UInt32.max),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(file.length)
      )
    else {
      throw ProbeError.invalidAudio
    }
    try file.read(into: buffer)
    guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
      throw ProbeError.invalidAudio
    }
    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(format.channelCount)
    var interleaved = [Float]()
    interleaved.reserveCapacity(frameCount * channelCount)
    for frame in 0..<frameCount {
      for channel in 0..<channelCount {
        interleaved.append(channels[channel][frame])
      }
    }
    let descriptor = MicrophoneCaptureDescriptor(
      sessionID: sessionID,
      deviceUID: "synthetic-microphone-fixture",
      sampleRateHertz: UInt32(format.sampleRate.rounded()),
      channelCount: UInt16(format.channelCount),
      encoding: .float32LittleEndian,
      interleaved: true
    )
    let maximumChunkFrames = max(1, Int(descriptor.sampleRateHertz) * 2)
    let baseStart = DispatchTime.now().uptimeNanoseconds
    var chunks: [CapturedPCMChunk] = []
    var frameOffset = 0
    while frameOffset < frameCount {
      let chunkFrames = min(maximumChunkFrames, frameCount - frameOffset)
      let sampleStart = frameOffset * channelCount
      let sampleEnd = (frameOffset + chunkFrames) * channelCount
      let bytes =
        interleaved[sampleStart..<sampleEnd].withContiguousStorageIfAvailable {
          Data(bytes: $0.baseAddress!, count: $0.count * MemoryLayout<Float>.size)
        } ?? Data()
      guard !bytes.isEmpty else { throw ProbeError.invalidAudio }
      let startOffset = UInt64(
        (Double(frameOffset) * 1_000_000_000
          / Double(descriptor.sampleRateHertz)).rounded()
      )
      chunks.append(
        CapturedPCMChunk(
          sequence: UInt64(chunks.count),
          monotonicStartNanoseconds: baseStart + startOffset,
          frameCount: UInt64(chunkFrames),
          sampleRateHertz: descriptor.sampleRateHertz,
          channelCount: descriptor.channelCount,
          encoding: descriptor.encoding,
          interleaved: true,
          bytes: bytes
        )
      )
      frameOffset += chunkFrames
    }
    return (descriptor, chunks)
  }

  private static func target() throws -> DictationTargetSnapshot {
    DictationTargetSnapshot(
      processIdentifier: 42, bundleIdentifier: "com.bestasr.probe-target", isSecure: false)
  }

  private static func parseOptions(_ arguments: [String]) throws
    -> [String: String]
  {
    guard arguments.count.isMultiple(of: 2) else {
      throw ProbeError.invalidArguments
    }
    var options: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let key = arguments[index]
      guard key.hasPrefix("--"), options[key] == nil else {
        throw ProbeError.invalidArguments
      }
      options[key] = arguments[index + 1]
      index += 2
    }
    return options
  }

  private static func requiredURL(
    _ key: String,
    _ options: [String: String]
  ) throws -> URL {
    guard let value = options[key], !value.isEmpty else {
      throw ProbeError.invalidArguments
    }
    return URL(fileURLWithPath: value).standardizedFileURL
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

  private static func peakRSSBytes() -> UInt64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return UInt64(max(0, usage.ru_maxrss))
  }

  private static func safeErrorCode(_ error: Error) -> String {
    if let error = error as? ProbeError {
      switch error {
      case .invalidArguments: return "invalid-arguments"
      case .invalidAudio: return "invalid-audio"
      case .invalidCandidate: return "invalid-candidate"
      case .invalidResult: return "invalid-result"
      case .networkSandboxRequired: return "network-sandbox-required"
      case .persistence(let code): return "persistence-\(code)"
      case .recognition(let code): return "recognition-\(code)"
      }
    }
    if let error = error as? ModelManagerError { return error.code }
    if let error = error as? InferenceEngineError { return error.code }
    if let error = error as? DictationProcessingError {
      return String(describing: error)
    }
    if let error = error as? BestASRPersistenceError {
      return String(describing: error)
    }
    if let error = error as? ProductionAudioJournalError {
      return String(describing: error)
    }
    return String(describing: type(of: error))
  }

  private static func validateRecognition(
    _ transcript: DictationTranscriptResult,
    sourceAudio: [AudioRangeInput],
    expectedKind: TranscriptRevisionKind
  ) throws {
    guard let provenance = transcript.provenance,
      provenance.kind == expectedKind,
      !provenance.languageHints.isEmpty,
      provenance.audioRanges == sourceAudio,
      transcript.segmentIDs == provenance.segments.map(\.id),
      Set(transcript.segmentIDs).count == transcript.segmentIDs.count
    else {
      throw ProbeError.recognition("provenance-shape")
    }
    var previousRangeEnd: UInt64?
    for range in provenance.audioRanges {
      guard previousRangeEnd.map({ range.monotonicStartNanoseconds >= $0 }) ?? true
      else {
        throw ProbeError.recognition("source-range-order")
      }
      previousRangeEnd = range.monotonicEndNanoseconds
    }
    var previousSegmentEnd: UInt64?
    for segment in provenance.segments {
      guard
        previousSegmentEnd.map({
          segment.monotonicStartNanoseconds >= $0
        }) ?? true
      else {
        throw ProbeError.recognition("segment-order")
      }
      guard
        rangesCover(
          start: segment.monotonicStartNanoseconds,
          end: segment.monotonicEndNanoseconds,
          ranges: provenance.audioRanges
        )
      else {
        throw ProbeError.recognition("segment-source-coverage")
      }
      previousSegmentEnd = segment.monotonicEndNanoseconds
    }
  }

  private static func waitForFirstLiveText(
    _ recorder: ProbeLiveRecorder
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(120))
    while clock.now < deadline {
      if recorder.snapshot().firstTextNanoseconds != nil { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw ProbeError.recognition("live-timeout")
  }

  private static func rangesCover(
    start: UInt64,
    end: UInt64,
    ranges: [AudioRangeInput]
  ) -> Bool {
    guard start < end,
      let firstIndex = ranges.firstIndex(where: {
        start >= $0.monotonicStartNanoseconds
          && start < $0.monotonicEndNanoseconds
      })
    else { return false }
    var coveredEnd = ranges[firstIndex].monotonicEndNanoseconds
    if end <= coveredEnd { return true }
    for range in ranges.dropFirst(firstIndex + 1) {
      let tolerance = max(
        UInt64(1),
        2_000_000_000 / UInt64(max(1, range.sampleRateHertz))
      )
      let toleratedEnd =
        coveredEnd > UInt64.max - tolerance
        ? UInt64.max
        : coveredEnd + tolerance
      guard range.monotonicStartNanoseconds <= toleratedEnd else { return false }
      coveredEnd = max(coveredEnd, range.monotonicEndNanoseconds)
      if end <= coveredEnd { return true }
    }
    return false
  }
}
