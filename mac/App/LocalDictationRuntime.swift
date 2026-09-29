import BestASRAudioJournal
import BestASRCandidateAdapters
import BestASRDictation
import BestASRDomain
import BestASRFluidRuntime
import BestASRInference
import BestASRDelivery
import BestASRLocalText
import BestASRMLXRuntime
import BestASRModelManager
import BestASRPersistence
import BestASRProcessing
import BestASRQwenRuntime
import BestASRRecognition
import BestASRSpeakerRouting
import CryptoKit
import Foundation
import OSLog

let localDictationRuntimeLogger = Logger(
  subsystem: "com.bestasr.app",
  category: "local-dictation-runtime"
)

enum LocalDictationRuntimeError: Error, Sendable {
  case alphaCandidateMissing
  case bundledRegistryMissing
  case modelNotReady
  case speakerEvidenceUnavailable
  case staleInputRevision
}

struct LocalModelReadiness: Equatable, Sendable {
  let asrReady: Bool
  let polishReady: Bool
  let speakerReady: Bool
}

enum HistorySpeakerRefreshOutcome: Equatable, Sendable {
  case completed
  case queued
  case failed
  case preservedHumanDecisions

  var detailMessage: String {
    switch self {
    case .completed:
      "文字与说话人已重新识别；旧文字版本和原音仍保留"
    case .queued:
      "文字已更新；人物处理已排队，组件就绪后会继续，原音和旧版本仍保留"
    case .failed:
      "文字已更新，人物处理未完成；原人物结果、原音和旧文字仍保留，可重试"
    case .preservedHumanDecisions:
      "文字已更新；已确认的人物关系保持不变，未自动重新划分说话人"
    }
  }
}

enum LocalModelComponent: String, CaseIterable, Identifiable, Sendable {
  case speech
  case speaker
  case localText

  var id: String { rawValue }

  var title: String {
    switch self {
    case .speech: "语音识别"
    case .speaker: "多人人物识别"
    case .localText: "本地文字整理"
    }
  }
}

struct LocalLiveTranscriptEvent: Equatable, Sendable {
  enum State: Equatable, Sendable {
    case text(kind: TranscriptRevisionKind)
    case unavailable
  }

  let sessionID: SessionID
  let text: String
  let state: State
}

struct LocalSpeakerClusterWork: Sendable {
  let key: String
  let trackID: TrackID
  let turns: [DiarizationTurn]
  let evidence: FluidSpeakerClusterEvidence
  let personMatch: PersonMatchEvidence?
}

struct LocalPlatformOccurrenceName: Sendable {
  let sessionSpeakerID: SessionSpeakerID
  let occurrenceID: SpeakerOccurrenceID
  let displayName: String
  let normalizedName: String
  let sourceContextIDs: [UUID]
  let alignedSpeechNanoseconds: UInt64
}

struct LiveSpeakerCentroid: Sendable {
  let label: String
  var vector: [Float]
  var weight: Double
}

struct LiveLabeledTurn: Sendable {
  let label: String
  let startNanoseconds: UInt64
  let endNanoseconds: UInt64
  let confidence: Double
}

/// One bounded input node for hierarchical local-text processing. `id` is an
/// ephemeral request-local bundle identifier; `sourceSegmentIDs` always points
/// back to the immutable transcript evidence that the node represents.
struct LocalTextEvidenceNode: Equatable, Sendable {
  let id: UUID
  let text: String
  let sourceSegmentIDs: [UUID]
  let context: String?

  init(id: UUID, text: String, sourceSegmentIDs: [UUID], context: String? = nil) {
    self.id = id
    self.text = text
    self.sourceSegmentIDs = sourceSegmentIDs
    self.context = context
  }
}

/// Records one dictation stage duration. Only the stage name and elapsed
/// milliseconds are logged; never audio, text, or target identity.
func logDictationStage(_ stage: String, since start: ContinuousClock.Instant) {
  let elapsed = ContinuousClock.now - start
  let milliseconds =
    elapsed.components.seconds * 1_000
    + elapsed.components.attoseconds / 1_000_000_000_000_000
  localDictationRuntimeLogger.notice(
    "dictation timing stage=\(stage, privacy: .public) ms=\(milliseconds, privacy: .public)"
  )
}

struct LateDictationPolish: Sendable {
  let request: DictationPolishRequest
  let result: DictationPolishResult
  let inputRevision: UInt64
  let configHash: BestASRDomain.SHA256Digest
}

struct TimedDictationASR: DictationASRPort {
  let base: any DictationASRPort

  func recognize(_ request: DictationASRRequest) async throws
    -> DictationTranscriptResult
  {
    let started = ContinuousClock.now
    defer { logDictationStage("final-asr", since: started) }
    return try await base.recognize(request)
  }
}

struct TimedDictationPolish: DictationPolishPort {
  let base: any DictationPolishPort

  func polish(_ request: DictationPolishRequest) async throws
    -> DictationPolishResult
  {
    let started = ContinuousClock.now
    defer { logDictationStage("model-polish", since: started) }
    return try await base.polish(request)
  }
}

/// What a mode dictation should actually deliver, decided after recognition
/// and before insertion.
///
/// 翻译 and 指令 are not different ways of tidying a dictation — they replace
/// what the user said with something else entirely, which is exactly what the
/// polish stage is built to refuse (its validator accepts a candidate only
/// when it is a subsequence of the transcript). So the substitution happens
/// here instead, between a finished polish and the insertion that delivers it.
enum DictationDelivery: Sendable, Equatable {
  /// An ordinary dictation: deliver the polished text unchanged.
  case asIs
  /// Deliver this instead — a translation, or the result of an instruction.
  case replaced(String)
  /// Nothing goes into the target; this is shown instead — a translation or
  /// an explanation of highlighted text, which the user asked to read, not
  /// to have written over their selection.
  case shown(String)
  /// The model could not produce it. The dictation is kept and copied rather
  /// than delivering the untransformed text, because inserting the original
  /// sentence where a translation was asked for is a wrong answer, not a
  /// degraded one.
  case unavailable
}

typealias DictationDeliveryTransform =
  @Sendable (SessionID, String) async -> DictationDelivery

struct TimedDictationInsertion: DictationInsertionPort {
  let base: any DictationInsertionPort
  let deliver: DictationDeliveryTransform?

  func captureTarget() async throws -> DictationTargetSnapshot {
    try await base.captureTarget()
  }

  func insert(_ request: DictationInsertionRequest) async throws
    -> DictationInsertionResult
  {
    let started = ContinuousClock.now
    defer { logDictationStage("insertion", since: started) }
    var request = request
    switch await deliver?(request.sessionID, request.text) ?? .asIs {
    case .asIs:
      break
    case .replaced(let text):
      request = DictationInsertionRequest(
        sessionID: request.sessionID,
        target: request.target,
        text: text,
        idempotencyKey: request.idempotencyKey
      )
    case .shown:
      return DictationInsertionResult(
        idempotencyKey: request.idempotencyKey,
        method: .retainedForCopy,
        inserted: false,
        failureReason: .nothingToInsert
      )
    case .unavailable:
      localDictationRuntimeLogger.notice("dictation delivery unavailable")
      return DictationInsertionResult(
        idempotencyKey: request.idempotencyKey,
        method: .retainedForCopy,
        inserted: false,
        failureReason: .unavailable
      )
    }
    let result = try await base.insert(request)
    let app = request.target?.bundleIdentifier ?? "-"
    localDictationRuntimeLogger.notice(
      "dictation insertion app=\(app, privacy: .public) inserted=\(result.inserted, privacy: .public) reason=\(result.failureReason?.rawValue ?? "-", privacy: .public)"
    )
    return result
  }
}

struct AppFormattingPolishAdapter: DictationPolishPort {
  let base: any DictationPolishPort
  let style: AppTextFormattingStyle

  func polish(_ request: DictationPolishRequest) async throws
    -> DictationPolishResult
  {
    let result = try await base.polish(request)
    let formatted: String
    switch style {
    case .automatic, .markdown:
      formatted = result.text
    case .plainText:
      formatted = result.text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .joined(separator: "\n")
    case .codeComment:
      formatted = result.text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line in line.isEmpty ? "//" : "// \(line)" }
        .joined(separator: "\n")
    }
    return DictationPolishResult(
      sourceRevisionID: result.sourceRevisionID,
      text: formatted,
      disposition: result.disposition,
      modelArtifactID: result.modelArtifactID
    )
  }
}

actor LocalDictationRuntime: DictationCommittedChunkObserver {
  let journal: ProductionAudioJournal
  let repository: GRDBDictationStore
  let insertion: any DictationInsertionPort
  let modelManager: LocalModelManager
  let modelRegistry: ManagedModelRegistry
  let modelDistribution: ModelDistributionCoordinator
  let candidateManifest: ASRCandidateManifest
  let silenceConfiguration: DictationSilenceConfiguration
  let baseASRConfigHash: BestASRDomain.SHA256Digest
  let deterministicPolishConfigHash: BestASRDomain.SHA256Digest
  let mlxPolishConfigHash: BestASRDomain.SHA256Digest
  let speakerConfigHash: BestASRDomain.SHA256Digest
  var asrEngine: (any ASREngine)?
  var mandarinFinalASREngine: LazyManagedASREngine?
  var englishFinalASREngine: LazyManagedASREngine?
  var multilingualFinalASREngine: LazyManagedASREngine?
  var finalASRPrewarmTask: Task<Void, Never>?
  var polishAdapter: (any DictationPolishPort)?
  var personalCleanup: PersonalDictationCleanupAdapter?
  /// The generic local model, held directly as well as behind the versioned
  /// task adapter, because translation and spoken instructions are not tasks.
  var generalTextRuntime: MLXLocalTextRuntime?
  /// Set by the app when a dictation is started in 翻译 or 指令 mode; consulted
  /// once, between polish and insertion. Nil for an ordinary dictation.
  var deliveryTransform: DictationDeliveryTransform?
  let applicationRoot: URL
  var localTextEngine: (any LocalTextEngine)?
  var speakerRuntime: FluidSpeakerRuntime?
  var speakerWorkerTask: Task<Void, Never>?
  let speakerWorkerID = UUID()
  var localTextWorkerTask: Task<Void, Never>?
  let localTextWorkerID = UUID()
  let localSelfPersonID: PersonID
  var liveCoordinator: LiveDictationCoordinator?
  var liveContinuations: [UUID: AsyncStream<LocalLiveTranscriptEvent>.Continuation] = [:]
  var liveInputModes: [SessionID: SessionInputMode] = [:]
  var liveSpeakerCentroids: [SessionID: [LiveSpeakerCentroid]] = [:]
  var liveAttributedLines: [SessionID: [String]] = [:]
  var liveAttributedRevision: [SessionID: UInt64] = [:]
  var liveSpeakerTasks: [SessionID: Task<Void, Never>] = [:]
  var defaultPolishEnabled = true
  var personalCleanupEnabled = true
  var sessionsAwaitingInsertion: Set<SessionID> = []
  var finalASRWarmupRuntime: QwenASRRuntime?
  var finalASRWarmupTask: Task<Void, Never>?
  var idleModelReleaseTask: Task<Void, Never>?
  var textModelReleaseTask: Task<Void, Never>?
  var lastFinalASRActivity: ContinuousClock.Instant?
  var finalSpeculation: FinalSpeculation?
  var deferredLatePolish: [SessionID: LateDictationPolish] = [:]
  var appPolicies: [String: AppTextPolicy] = [:]
  var speakerMemoryEnabled = true

  init(
    applicationRoot: URL,
    cacheRoot: URL,
    journal: ProductionAudioJournal,
    repository: GRDBDictationStore,
    insertion: any DictationInsertionPort,
    localSelfPersonID: PersonID,
    bundle: Bundle = .main
  ) throws {
    self.localSelfPersonID = localSelfPersonID
    self.applicationRoot = applicationRoot
    guard
      let modelRegistryURL = bundle.url(
        forResource: "model-artifacts",
        withExtension: "json"
      ),
      let candidateRegistryURL = bundle.url(
        forResource: "inference-candidates",
        withExtension: "json"
      )
    else {
      throw LocalDictationRuntimeError.bundledRegistryMissing
    }
    let modelRegistry = try ManagedModelRegistry.decode(
      Data(contentsOf: modelRegistryURL)
    )
    candidateManifest = try ASRCandidateManifest.decode(
      Data(contentsOf: candidateRegistryURL)
    )
    let manager = try LocalModelManager(
      rootDirectory: applicationRoot.appendingPathComponent(
        "models",
        isDirectory: true
      ),
      registry: modelRegistry
    )
    modelManager = manager
    self.modelRegistry = modelRegistry
    modelDistribution = try ModelDistributionCoordinator(
      rootDirectory: cacheRoot.appendingPathComponent(
        "model-downloads",
        isDirectory: true
      ),
      registry: modelRegistry,
      manager: manager
    )
    self.journal = journal
    self.repository = repository
    self.insertion = insertion
    let silenceConfiguration = try DictationSilenceConfiguration()
    self.silenceConfiguration = silenceConfiguration
    baseASRConfigHash = try BestASRDomain.SHA256Digest(
      Self.sha256(
        "automatic-language-routing-v5|fp32-gpu-preprocessing"
          + "|\(FluidSenseVoicePinnedArtifact.runtimeRevision)"
          + "|\(FluidSenseVoicePinnedArtifact.treeSHA256)"
          + "|paraformer-zh-final:\(FluidParaformerPinnedArtifact.treeSHA256)"
          + "|parakeet-en-final:\(FluidParakeetUnifiedPinnedArtifact.treeSHA256)"
          + "|qwen-final:\(QwenASRPinnedArtifact.treeSHA256)"
          + "|qwen-alignment:\(QwenAlignmentPinnedArtifact.treeSHA256)"
          + "|\(QwenASRPinnedArtifact.pipelineRevision)"
          + "|vad-v1:\(silenceConfiguration.provenanceIdentifier)|dictionary-v1"
      )
    )
    // Model weights stay resident; freed GPU buffers beyond this are returned
    // instead of cached (no measurable decode cost on the evaluation set).
    QwenRuntimeMemory.limitIdleBuffers(toBytes: 256 << 20)
    deterministicPolishConfigHash = try BestASRDomain.SHA256Digest(
      Self.sha256(DictationTextCleanup.revision)
    )
    mlxPolishConfigHash = try BestASRDomain.SHA256Digest(
      Self.sha256(
        "\(MLXLocalTextArtifact.polishPipelineRevision)"
          + "|\(MLXLocalTextArtifact.runtimeRevision)"
          + "|\(MLXLocalTextArtifact.qwen3Selected.treeSHA256)"
      )
    )
    speakerConfigHash = try BestASRDomain.SHA256Digest(
      Self.sha256(
        "\(FluidSpeakerPinnedArtifact.pipelineRevision)|\(FluidSpeakerPinnedArtifact.runtimeRevision)"
          + "|\(FluidSpeakerPinnedArtifact.treeSHA256)"
          + "|\(FluidSpeakerPinnedArtifact.embeddingSpaceID)"
      )
    )
  }


  func configureUserPreferences(
    defaultPolishEnabled: Bool,
    personalCleanupEnabled: Bool,
    appPolicies: [AppTextPolicy],
    speakerMemoryEnabled: Bool
  ) {
    self.defaultPolishEnabled = defaultPolishEnabled
    self.personalCleanupEnabled = personalCleanupEnabled
    self.appPolicies = Dictionary(
      appPolicies.map { ($0.bundleIdentifier, $0) },
      uniquingKeysWith: { _, newest in newest }
    )
    self.speakerMemoryEnabled = speakerMemoryEnabled
  }


  func hasEnhancedFinalASR() -> Bool {
    multilingualFinalASREngine != nil
  }


















  /// Longest time insertion waits for local model polish. Zero since
  /// 2026-09-19: on the personal evaluation set the model returned the text
  /// unchanged for 191 of 228 dictations while costing about 450 ms median,
  /// so polish now only updates history (PRD V1.6 §0.1 item 4).
  static let polishInsertionBudget: Duration = .zero

  /// How long insertion may wait for the personal cleanup model. Pause
  /// decodes usually have the answer ready; this only covers the last words.
  static let personalCleanupInsertionBudget: Duration = .milliseconds(250)

  /// Final ASR idle longer than this is warmed when the next dictation starts.
  static let finalASRIdleWarmupThreshold: Duration = .seconds(90)


  /// A decode of the active dictation's committed audio, started when the
  /// speaker pauses so it can be reused at release
  /// (`QwenSpeculativeDecodeCache`).
  struct FinalSpeculation {
    let sessionID: SessionID
    let audio: CommittedInferenceAudio
    var requestedThroughNanoseconds: UInt64?
    var dictionaryTerms: [String] = []
    /// Final-recognizer text of each completed window, in order.
    var windowTexts: [String?] = []
    /// Bumped by every pause and every resumption, so a late result of an
    /// outdated pause decode is never shown.
    var pauseGeneration = 0
    /// The live display currently shows final-recognizer text; live drafts
    /// for the same audio must not replace it until speech resumes.
    var showsRecognizedText = false
  }

  /// Called before a dictation's first chunk can be committed.
  func beginFinalSpeculation(sessionID: SessionID) async {
    await finalASRWarmupRuntime?.clearSpeculation()
    guard
      let audio = try? CommittedInferenceAudio(
        windowLimit: QwenASRPinnedArtifact.maximumSamples)
    else {
      finalSpeculation = nil
      return
    }
    finalSpeculation = FinalSpeculation(sessionID: sessionID, audio: audio)
    // Match the terms final ASR receives (BoundedDictationASRAdapter).
    let terms =
      (try? await repository.dictionaryContext(maximumEntries: 64, maximumUTF8Bytes: 16_384))?
      .canonicalTerms ?? []
    guard finalSpeculation?.sessionID == sessionID else { return }
    finalSpeculation?.dictionaryTerms = Array(
      terms.filter { !$0.isEmpty && $0.count <= 128 }.prefix(64))
  }

  /// The speaker paused and all audio through `committedThroughNanoseconds`
  /// is on its way to the journal: decode it once it has been committed.
  func requestFinalSpeculation(sessionID: SessionID, committedThroughNanoseconds: UInt64) async {
    guard finalSpeculation?.sessionID == sessionID else {
      localDictationRuntimeLogger.notice("speculation skipped reason=no-session")
      return
    }
    localDictationRuntimeLogger.notice("speculation pause detected")
    finalSpeculation?.requestedThroughNanoseconds = committedThroughNanoseconds
    await startFinalSpeculationIfReady()
  }

  func cancelFinalSpeculation(sessionID: SessionID) async {
    guard finalSpeculation?.sessionID == sessionID else { return }
    localDictationRuntimeLogger.notice("speculation cancelled reason=speech-resumed")
    finalSpeculation?.requestedThroughNanoseconds = nil
    finalSpeculation?.pauseGeneration += 1
    finalSpeculation?.showsRecognizedText = false
    await finalASRWarmupRuntime?.clearPauseSpeculation()
  }

  func appendForFinalSpeculation(sessionID: SessionID, chunk: CapturedPCMChunk) async {
    guard let speculation = finalSpeculation, speculation.sessionID == sessionID else { return }
    await speculation.audio.append(chunk)
    // Long dictations: decode each window as soon as it is final.
    let windows = await speculation.audio.takeCompletedWindows()
    if !windows.isEmpty, let runtime = finalASRWarmupRuntime {
      for window in windows {
        localDictationRuntimeLogger.notice("speculation window completed")
        let index = finalSpeculation?.windowTexts.count ?? 0
        finalSpeculation?.windowTexts.append(nil)
        await runtime.precomputeWindow(
          samples: window, dictionaryTerms: speculation.dictionaryTerms
        ) { [weak self] text in
          await self?.receiveSpeculativeWindowText(sessionID: sessionID, index: index, text: text)
        }
      }
    }
    await startFinalSpeculationIfReady()
  }

  func startFinalSpeculationIfReady() async {
    guard let speculation = finalSpeculation,
      let through = speculation.requestedThroughNanoseconds
    else { return }
    guard let runtime = finalASRWarmupRuntime else {
      finalSpeculation?.requestedThroughNanoseconds = nil
      localDictationRuntimeLogger.notice("speculation skipped reason=recognizer-not-loaded")
      return
    }
    let audio = speculation.audio
    if await audio.ended {
      finalSpeculation?.requestedThroughNanoseconds = nil
      localDictationRuntimeLogger.notice("speculation skipped reason=audio-gap")
      return
    }
    guard await audio.committedThroughNanoseconds >= through,
      finalSpeculation?.requestedThroughNanoseconds == through
    else { return }
    localDictationRuntimeLogger.notice("speculation started")
    finalSpeculation?.requestedThroughNanoseconds = nil
    finalSpeculation?.pauseGeneration += 1
    let generation = finalSpeculation?.pauseGeneration ?? 0
    let sessionID = speculation.sessionID
    await runtime.speculate(
      samples: await audio.samples, dictionaryTerms: speculation.dictionaryTerms
    ) { [weak self] text in
      await self?.receiveSpeculativePauseText(
        sessionID: sessionID, generation: generation, text: text)
    }
  }

  func receiveSpeculativeWindowText(sessionID: SessionID, index: Int, text: String) {
    guard finalSpeculation?.sessionID == sessionID,
      let count = finalSpeculation?.windowTexts.count, index < count
    else { return }
    finalSpeculation?.windowTexts[index] = text
  }

  /// Replaces the live draft with the final recognizer's reading of
  /// everything said so far, cleaned like the text that will be inserted.
  func receiveSpeculativePauseText(
    sessionID: SessionID, generation: Int, text: String
  ) {
    guard let speculation = finalSpeculation, speculation.sessionID == sessionID,
      speculation.pauseGeneration == generation
    else { return }
    let joined = TranscriptTextJoiner.join(speculation.windowTexts.compactMap { $0 } + [text])
    guard !joined.isEmpty else { return }
    // Clean up this pause's text while the user keeps talking, so the final
    // text is usually already waiting when they release the key.
    if personalCleanupEnabled, let service = personalCleanup?.service {
      Task { await service.precompute(joined) }
    }
    finalSpeculation?.showsRecognizedText = true
    emit(
      LocalLiveTranscriptEvent(
        sessionID: sessionID,
        text: DictationTextCleanup.apply(joined),
        state: .text(kind: .sentence)
      )
    )
  }

  /// How long the models stay resident after the last dictation. Loading them
  /// again costs a second or two, which the warm-up at the start of the next
  /// dictation covers; holding about 4 GB of GPU memory for an App the user
  /// is not dictating into does not.
  static let idleModelReleaseDelay: Duration = .seconds(600)
  /// The general text model serves the occasional instruction, not every
  /// dictation, so it leaves a minute after the last one rather than riding
  /// the recogniser's ten-minute timer.
  static let textModelReleaseDelay: Duration = .seconds(60)




  /// How many recordings one idle pass rewrites. The whole library took six
  /// seconds, but this runs on the user's Mac while they are doing something
  /// else, so it takes a bite and leaves the rest for the next idle period.
  static let idleCompactionLimit = 40










  nonisolated static func safeDiagnosticCode(
    _ code: String,
    fallback: String
  ) -> String {
    guard !code.isEmpty, code.count <= 128,
      code.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil
    else { return fallback }
    return code
  }

  func registerLiveSession(
    sessionID: SessionID,
    inputMode: SessionInputMode
  ) {
    beginFinalASRPrewarm()
    liveSpeakerTasks[sessionID]?.cancel()
    liveSpeakerTasks[sessionID] = nil
    liveInputModes[sessionID] = inputMode
    liveSpeakerCentroids[sessionID] = []
    liveAttributedLines[sessionID] = []
    liveAttributedRevision[sessionID] = 0
  }

  func clearLiveSession(sessionID: SessionID) async {
    await liveCoordinator?.clear(sessionID: sessionID)
    clearLivePresentationState(sessionID: sessionID)
  }

  func liveTranscriptEvents() -> AsyncStream<LocalLiveTranscriptEvent> {
    let identifier = UUID()
    return AsyncStream { continuation in
      liveContinuations[identifier] = continuation
      continuation.onTermination = { @Sendable [weak self] _ in
        Task { await self?.removeLiveContinuation(identifier) }
      }
    }
  }

  func didCommit(
    sessionID: SessionID,
    chunk: CapturedPCMChunk
  ) async {
    await appendForFinalSpeculation(sessionID: sessionID, chunk: chunk)
    guard let liveCoordinator else {
      emit(
        LocalLiveTranscriptEvent(
          sessionID: sessionID,
          text: "",
          state: .unavailable
        )
      )
      return
    }
    await liveCoordinator.didCommit(sessionID: sessionID, chunk: chunk)
  }

  func didReachBoundary(
    sessionID: SessionID,
    kind: TranscriptRevisionKind
  ) async {
    await liveCoordinator?.didReachBoundary(sessionID: sessionID, kind: kind)
  }

  func didResume(sessionID: SessionID) async {
    await liveCoordinator?.didResume(sessionID: sessionID)
  }

  func emit(_ event: LocalLiveTranscriptEvent) {
    for continuation in liveContinuations.values {
      continuation.yield(event)
    }
  }

  func removeLiveContinuation(_ identifier: UUID) {
    liveContinuations[identifier] = nil
  }

  func configureASR() async throws {
    finalASRPrewarmTask?.cancel()
    finalASRPrewarmTask = nil
    guard
      let candidate = candidateManifest.candidates.first(where: {
        $0.alphaDefault && $0.adapterKind == .fluidSenseVoice
      })
    else {
      throw LocalDictationRuntimeError.alphaCandidateMissing
    }
    let runtime = try await FluidSenseVoiceRuntimeFactory.make(
      modelManager: modelManager,
      audioAssetRoot: journal.assetRootURL
    )
    let engine = try FluidSenseVoiceASRAdapter(
      candidate: candidate,
      runtime: runtime,
      artifact: FluidSenseVoicePinnedArtifact.descriptor
    )
    asrEngine = engine
    mandarinFinalASREngine = await makeMandarinFinalASREngineIfInstalled()
    englishFinalASREngine = await makeEnglishFinalASREngineIfInstalled()
    multilingualFinalASREngine = await makeMultilingualFinalASREngineIfInstalled()
    let adapter = DynamicLiveASRAdapter(
      engine: engine,
      audio: MappedInferenceAudioPort(base: journal),
      baseConfigHash: baseASRConfigHash.value
    )
    liveCoordinator = try LiveDictationCoordinator(
      audio: journal,
      asr: adapter,
      repository: repository,
      contextProvider: { [weak self] in
        guard let self else { throw LocalDictationRuntimeError.modelNotReady }
        return try await self.liveContext()
      },
      policy: LiveDictationPolicy(),
      silenceConfiguration: silenceConfiguration,
      eventHandler: { [weak self] event in
        Task { [weak self] in
          await self?.emit(event)
        }
      }
    )
  }




  func makeAutomaticFinalASR(
    configHash: BestASRDomain.SHA256Digest,
    languageEvidenceText: String,
    languageEvidenceHints: [String],
    permitsEmptyResult: Bool
  ) throws -> AutomaticLanguageRoutedASRAdapter {
    guard let asrEngine else {
      throw LocalDictationRuntimeError.modelNotReady
    }
    let audio = MappedInferenceAudioPort(base: journal)
    func bounded(_ engine: any ASREngine) throws
      -> BoundedDictationASRAdapter
    {
      BoundedDictationASRAdapter(
        engine: engine,
        audio: audio,
        configHash: configHash,
        policy: try BoundedDictationASRPolicy(
          permitsEmptyFinalResultForReconciliation: true
        )
      )
    }
    return AutomaticLanguageRoutedASRAdapter(
      mixedLanguageFallback: try bounded(asrEngine),
      mandarinFinal: try mandarinFinalASREngine.map { try bounded($0) },
      englishFinal: try englishFinalASREngine.map { try bounded($0) },
      multilingualFinal: try multilingualFinalASREngine.map { try bounded($0) },
      languageEvidenceText: languageEvidenceText,
      languageEvidenceHints: languageEvidenceHints,
      permitsEmptyResult: permitsEmptyResult
    )
  }

  var finalRoutingAvailabilityFingerprint: String {
    "automatic-v5"
      + "|final=\(multilingualFinalASREngine == nil ? "unavailable" : QwenASRPinnedArtifact.artifactID)"
      + "|alignment=\(multilingualFinalASREngine == nil ? "unavailable" : QwenAlignmentPinnedArtifact.artifactID)"
      + "|mixed=\(FluidSenseVoicePinnedArtifact.artifactID)"
      + "|zh=\(mandarinFinalASREngine == nil ? "unavailable" : FluidParaformerPinnedArtifact.artifactID)"
      + "|en=\(englishFinalASREngine == nil ? "unavailable" : FluidParakeetUnifiedPinnedArtifact.artifactID)"
  }

  func liveContext() async throws -> LiveDictationContext {
    let dictionary = try await repository.dictionaryContext(
      maximumEntries: 64,
      maximumUTF8Bytes: 16_384
    )
    return LiveDictationContext(
      dictionaryTerms: dictionary.canonicalTerms,
      dictionaryHints: dictionary.asrDictionaryHints,
      configHash: try liveConfigHash(
        base: baseASRConfigHash.value,
        dictionaryTerms: dictionary.canonicalTerms,
        dictionaryHints: dictionary.asrDictionaryHints
      )
    )
  }

  func emit(_ event: LiveDictationEvent) {
    // A late draft for audio the final recognizer has already read must not
    // bring the older wording back.
    if finalSpeculation?.sessionID == event.sessionID,
      finalSpeculation?.showsRecognizedText == true,
      case .text = event.state
    {
      return
    }
    let state: LocalLiveTranscriptEvent.State =
      switch event.state {
      case .text(let kind): .text(kind: kind)
      case .unavailable: .unavailable
      }
    let mode = liveInputModes[event.sessionID] ?? .dictation
    let attributedLines = liveAttributedLines[event.sessionID] ?? []
    let immediateText: String
    if mode == .roomMicrophone || mode == .systemAudio,
      !attributedLines.isEmpty,
      case .text = event.state
    {
      let latest = event.latestText.trimmingCharacters(in: .whitespacesAndNewlines)
      immediateText = (attributedLines + (latest.isEmpty ? [] : ["正在识别  \(latest)"]))
        .joined(separator: "\n")
    } else {
      immediateText = event.text
    }
    emit(
      LocalLiveTranscriptEvent(
        sessionID: event.sessionID,
        text: immediateText,
        state: state
      )
    )
    guard
      mode == .roomMicrophone || mode == .systemAudio,
      case .text(let kind) = event.state,
      kind == .sentence,
      !event.latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      event.inputRevision > (liveAttributedRevision[event.sessionID] ?? 0)
    else { return }
    let previous = liveSpeakerTasks[event.sessionID]
    let task = Task { [weak self] in
      await previous?.value
      guard !Task.isCancelled else { return }
      await self?.attributeLiveSentence(event, inputMode: mode)
    }
    liveSpeakerTasks[event.sessionID] = task
  }

  func attributeLiveSentence(
    _ event: LiveDictationEvent,
    inputMode: SessionInputMode
  ) async {
    guard event.inputRevision > (liveAttributedRevision[event.sessionID] ?? 0)
    else { return }
    let fallback = Self.liveSpeakerLabel(index: 0)
    var labeledTurns: [LiveLabeledTurn] = []
    do {
      guard let speakerRuntime, !event.audioRanges.isEmpty else {
        throw LocalDictationRuntimeError.speakerEvidenceUnavailable
      }
      let roles = try await repository.loadTrackRoles(sessionID: event.sessionID)
      let grouped = Dictionary(grouping: event.audioRanges, by: \.trackID)
      for trackID in grouped.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
        try Task.checkCancellation()
        guard let sourceRanges = grouped[trackID], !sourceRanges.isEmpty else { continue }
        let prepared = try await journal.prepareInferenceAudio(
          sessionID: event.sessionID,
          sourceAudio: sourceRanges.sorted {
            $0.monotonicStartNanoseconds < $1.monotonicStartNanoseconds
          }
        )
        let analysis: FluidSpeakerAnalysis
        do {
          analysis = try await speakerRuntime.analyze(
            DiarizationRequest(
              metadata: InferenceRequestMetadata(
                jobID: Self.deterministicUUID([
                  "live-speaker-v1",
                  event.sessionID.rawValue.uuidString.lowercased(),
                  String(event.inputRevision),
                  trackID.uuidString.lowercased(),
                ]),
                inputRevision: max(1, event.inputRevision),
                modelArtifactID: FluidSpeakerPinnedArtifact.artifactID,
                configHash: speakerConfigHash.value
              ),
              audio: prepared,
              expectedSpeakerRange: 1...6
            )
          )
        } catch {
          await journal.discardInferenceAudio(
            sessionID: event.sessionID,
            preparedAudio: prepared
          )
          throw error
        }
        await journal.discardInferenceAudio(
          sessionID: event.sessionID,
          preparedAudio: prepared
        )
        let isLocalMicrophone =
          inputMode == .systemAudio
          && roles[trackID] == .microphoneLocal
        var labelByCluster: [String: String] = [:]
        for evidence in analysis.clusters.sorted(by: {
          $0.speakerClusterID < $1.speakerClusterID
        }) {
          labelByCluster[evidence.speakerClusterID] =
            isLocalMicrophone
            ? "我"
            : assignLiveSpeakerLabel(
              sessionID: event.sessionID,
              vector: evidence.vector,
              weight: Double(max(1, evidence.speechDurationNanoseconds))
            )
        }
        labeledTurns.append(
          contentsOf: analysis.diarization.turns.compactMap { turn in
            guard let label = labelByCluster[turn.speakerClusterID] else { return nil }
            return LiveLabeledTurn(
              label: label,
              startNanoseconds: turn.monotonicStartNanoseconds,
              endNanoseconds: turn.monotonicEndNanoseconds,
              confidence: turn.confidence ?? 0
            )
          })
      }
    } catch is CancellationError {
      return
    } catch {
      labeledTurns = []
    }
    guard !Task.isCancelled else { return }
    let lines = Self.liveAttributedLines(
      text: event.latestText,
      segments: event.segments,
      turns: labeledTurns,
      fallbackLabel: fallback
    )
    liveAttributedLines[event.sessionID, default: []].append(contentsOf: lines)
    liveAttributedRevision[event.sessionID] = event.inputRevision
    emit(
      LocalLiveTranscriptEvent(
        sessionID: event.sessionID,
        text: (liveAttributedLines[event.sessionID] ?? []).joined(separator: "\n"),
        state: .text(kind: .sentence)
      )
    )
  }


  static func liveAttributedLines(
    text: String,
    segments: [DictationTranscriptSegment],
    turns: [LiveLabeledTurn],
    fallbackLabel: String
  ) -> [String] {
    let usableSegments = segments.filter {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !usableSegments.isEmpty else {
      return ["说话人 \(fallbackLabel)  \(text.trimmingCharacters(in: .whitespacesAndNewlines))"]
    }
    var groups: [(label: String, text: String)] = []
    for segment in usableSegments {
      var label = fallbackLabel
      var bestOverlap: UInt64 = 0
      var bestConfidence = -Double.infinity
      for turn in turns {
        let start: UInt64 = Swift.max(
          segment.monotonicStartNanoseconds,
          turn.startNanoseconds
        )
        let end: UInt64 = Swift.min(
          segment.monotonicEndNanoseconds,
          turn.endNanoseconds
        )
        let overlap: UInt64 = end > start ? end - start : 0
        if overlap > bestOverlap
          || (overlap == bestOverlap && turn.confidence > bestConfidence)
        {
          label = turn.label
          bestOverlap = overlap
          bestConfidence = turn.confidence
        }
      }
      let part = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if groups.last?.label == label {
        groups[groups.count - 1].text += " \(part)"
      } else {
        groups.append((label, part))
      }
    }
    return groups.map {
      $0.label == "我" ? "我  \($0.text)" : "说话人 \($0.label)  \($0.text)"
    }
  }


  func clearLivePresentationState(sessionID: SessionID) {
    liveSpeakerTasks[sessionID]?.cancel()
    liveSpeakerTasks[sessionID] = nil
    liveInputModes[sessionID] = nil
    liveSpeakerCentroids[sessionID] = nil
    liveAttributedLines[sessionID] = nil
    liveAttributedRevision[sessionID] = nil
  }







  func generateLocalTextDocument(
    sessionID: SessionID,
    taskID: LocalTextTaskID,
    expectedInputRevision: UInt64? = nil
  ) async throws -> LocalTextDocumentRecord {
    guard
      [
        .structuredSummary,
        .actionItems,
        .chapters,
        .decisions,
      ].contains(taskID)
    else {
      throw LocalDictationRuntimeError.modelNotReady
    }
    guard let localTextEngine else {
      throw LocalDictationRuntimeError.modelNotReady
    }
    let transcripts = try await repository.loadTranscripts(sessionID: sessionID)
    guard let source = TranscriptSelection.current(in: transcripts) else {
      throw LocalDictationRuntimeError.modelNotReady
    }
    if let expectedInputRevision,
      source.inputRevision != expectedInputRevision
    {
      throw LocalDictationRuntimeError.staleInputRevision
    }
    let rawLines: [(sourceID: UUID, text: String)] =
      source.segments.isEmpty
      ? [(source.id.rawValue, source.content)]
      : source.segments.map { ($0.id, $0.text) }
    let namespace = [
      "session-local-text-v2",
      sessionID.rawValue.uuidString.lowercased(),
      source.id.rawValue.uuidString.lowercased(),
      String(source.inputRevision),
      taskID.rawValue,
    ].joined(separator: "|")
    let evidenceNodes = rawLines.enumerated().flatMap { lineIndex, line in
      Self.utf8Chunks(line.text, maximumBytes: 1_200).enumerated().map {
        fragmentIndex, fragment in
        LocalTextEvidenceNode(
          id: Self.deterministicUUID([
            namespace,
            String(lineIndex),
            String(fragmentIndex),
            line.sourceID.uuidString.lowercased(),
          ]),
          text: fragment,
          sourceSegmentIDs: [line.sourceID]
        )
      }
    }
    guard !evidenceNodes.isEmpty else {
      throw LocalDictationRuntimeError.modelNotReady
    }
    let documentID = Self.deterministicUUID([
      "local-text-document-v1",
      sessionID.rawValue.uuidString.lowercased(),
      source.id.rawValue.uuidString.lowercased(),
      String(source.inputRevision),
      taskID.rawValue,
      mlxPolishConfigHash.value,
    ])
    let result = try await Self.generateHierarchicalLocalText(
      engine: localTextEngine,
      taskID: taskID,
      transcriptRevisionID: source.id.rawValue,
      inputRevision: source.inputRevision,
      namespace: namespace,
      configHash: mlxPolishConfigHash.value,
      nodes: evidenceNodes
    )
    let record = LocalTextDocumentRecord(
      id: documentID,
      sessionID: sessionID,
      sourceTranscriptID: source.id,
      sourceRevision: try Revision(source.inputRevision),
      taskID: taskID,
      modelArtifactID: result.modelArtifactID,
      configHash: mlxPolishConfigHash,
      result: result,
      createdAt: Date()
    )
    try await repository.saveLocalTextDocument(record)
    return record
  }

  func generateEventTextDocument(
    eventID: EventID,
    taskID: LocalTextTaskID
  ) async throws -> EventTextDocumentRecord {
    guard
      [
        .structuredSummary,
        .actionItems,
        .chapters,
        .decisions,
      ].contains(taskID),
      let localTextEngine,
      let detail = try await repository.eventDetail(id: eventID)
    else { throw LocalDictationRuntimeError.modelNotReady }

    struct SourceLine {
      let sessionID: SessionID
      let transcriptID: TranscriptRevisionID
      let sourceRevision: Revision
      let segmentID: UUID
      let context: String
      let text: String
    }
    let historyBySessionID = Dictionary(
      uniqueKeysWithValues: try await repository.loadHistory(limit: 5_000).map {
        ($0.sessionID, $0)
      }
    )
    var allLines: [SourceLine] = []
    for sessionID in detail.summary.sessionIDs {
      let transcripts = try await repository.loadTranscripts(sessionID: sessionID)
      guard let source = TranscriptSelection.current(in: transcripts) else {
        continue
      }
      let occurrences = try await repository.sessionOccurrenceSummaries(
        sessionID: sessionID
      )
      let history = historyBySessionID[sessionID]
      let sessionContext = Self.eventSessionContext(
        inputMode: history?.inputMode,
        createdAt: history?.createdAt ?? source.createdAt
      )
      let revision = try Revision(source.inputRevision)
      if source.segments.isEmpty {
        allLines.append(
          SourceLine(
            sessionID: sessionID,
            transcriptID: source.id,
            sourceRevision: revision,
            segmentID: source.id.rawValue,
            context: sessionContext,
            text: source.content
          )
        )
      } else {
        allLines.append(
          contentsOf: source.segments.map {
            SourceLine(
              sessionID: sessionID,
              transcriptID: source.id,
              sourceRevision: revision,
              segmentID: $0.id,
              context: Self.eventSegmentContext(
                sessionContext: sessionContext,
                startNanoseconds: $0.monotonicStartNanoseconds,
                endNanoseconds: $0.monotonicEndNanoseconds,
                occurrences: occurrences
              ),
              text: $0.text
            )
          }
        )
      }
    }
    guard !allLines.isEmpty else {
      throw LocalDictationRuntimeError.modelNotReady
    }

    let namespace = [
      "event-local-text-v3",
      eventID.rawValue.uuidString.lowercased(),
      String(detail.summary.event.revision.value),
      taskID.rawValue,
    ].joined(separator: "|")
    let evidenceNodes = allLines.enumerated().flatMap { lineIndex, line in
      Self.utf8Chunks(line.text, maximumBytes: 900).enumerated().map {
        fragmentIndex, fragment in
        LocalTextEvidenceNode(
          id: Self.deterministicUUID([
            namespace,
            String(lineIndex),
            String(fragmentIndex),
            line.segmentID.uuidString.lowercased(),
          ]),
          text: fragment,
          sourceSegmentIDs: [line.segmentID],
          context: line.context
        )
      }
    }
    guard !evidenceNodes.isEmpty else {
      throw LocalDictationRuntimeError.modelNotReady
    }

    struct ReferenceKey: Hashable {
      let sessionID: SessionID
      let transcriptID: TranscriptRevisionID
      let revision: Revision
    }
    var referenceOrder: [ReferenceKey] = []
    var segmentIDsByReference: [ReferenceKey: [UUID]] = [:]
    for line in allLines {
      let key = ReferenceKey(
        sessionID: line.sessionID,
        transcriptID: line.transcriptID,
        revision: line.sourceRevision
      )
      if segmentIDsByReference[key] == nil { referenceOrder.append(key) }
      segmentIDsByReference[key, default: []].append(line.segmentID)
    }
    let references = referenceOrder.map { key in
      EventTextSourceReference(
        sessionID: key.sessionID,
        transcriptRevisionID: key.transcriptID,
        sourceRevision: key.revision,
        segmentIDs: Self.orderedUnique(segmentIDsByReference[key] ?? [])
      )
    }
    let eventConfigHash = try BestASRDomain.SHA256Digest(
      Self.sha256("event-source-context-v1|\(mlxPolishConfigHash.value)")
    )
    let documentID = Self.eventTextDocumentID(
      eventID: eventID,
      eventRevision: detail.summary.event.revision,
      taskID: taskID,
      configHash: eventConfigHash.value,
      references: references,
      contexts: allLines.map(\.context)
    )
    if let existing = try await repository.eventTextDocuments(eventID: eventID)
      .first(where: { $0.id == documentID && $0.state == .current })
    {
      return existing
    }
    let result = try await Self.generateHierarchicalLocalText(
      engine: localTextEngine,
      taskID: taskID,
      transcriptRevisionID: eventID.rawValue,
      inputRevision: detail.summary.event.revision.value,
      namespace: "\(namespace)|\(documentID.uuidString.lowercased())",
      configHash: eventConfigHash.value,
      nodes: evidenceNodes
    )
    let record = EventTextDocumentRecord(
      id: documentID,
      eventID: eventID,
      eventRevision: detail.summary.event.revision,
      taskID: taskID,
      modelArtifactID: result.modelArtifactID,
      configHash: eventConfigHash,
      sourceReferences: references,
      result: result,
      createdAt: Date()
    )
    try await repository.saveEventTextDocument(record)
    return record
  }

  static func eventTextDocumentID(
    eventID: EventID,
    eventRevision: Revision,
    taskID: LocalTextTaskID,
    configHash: String,
    references: [EventTextSourceReference],
    contexts: [String]
  ) -> UUID {
    let sources = references.map {
      [
        $0.sessionID.rawValue.uuidString,
        $0.transcriptRevisionID.rawValue.uuidString,
        String($0.sourceRevision.value),
        $0.segmentIDs.map(\.uuidString).joined(separator: ","),
      ].joined(separator: "|")
    }
    return deterministicUUID(
      [
        "event-local-text-document-v2",
        eventID.rawValue.uuidString,
        String(eventRevision.value),
        taskID.rawValue,
        configHash,
      ] + sources + contexts
    )
  }

  /// Processes every source segment through bounded local-only passes. Long
  /// sessions/events are reduced hierarchically instead of sampling or
  /// truncating the timeline. Ephemeral bundle identifiers are translated back
  /// to the original segment IDs after every pass, preserving provenance.
  static func generateHierarchicalLocalText(
    engine: any LocalTextEngine,
    taskID: LocalTextTaskID,
    transcriptRevisionID: UUID,
    inputRevision: UInt64,
    namespace: String,
    configHash: String,
    nodes: [LocalTextEvidenceNode]
  ) async throws -> LocalTextResult {
    guard !nodes.isEmpty else { throw LocalDictationRuntimeError.modelNotReady }
    var currentNodes = nodes
    for round in 0..<12 {
      let batches = Self.localTextBatches(currentNodes)
      guard !batches.isEmpty else {
        throw LocalDictationRuntimeError.modelNotReady
      }
      var outputs: [(nodes: [LocalTextEvidenceNode], result: LocalTextResult)] = []
      outputs.reserveCapacity(batches.count)
      for (batchIndex, batch) in batches.enumerated() {
        let structuredSource = batch.enumerated().map { index, node in
          "[S\(index + 1)] \(node.text)"
        }.joined(separator: "\n")
        let structuredContext = batch.enumerated().compactMap { index, node in
          node.context.map { "[S\(index + 1)] \($0)" }
        }.joined(separator: "\n")
        guard !structuredSource.isEmpty,
          structuredSource.utf8.count + structuredContext.utf8.count <= 16_384,
          batch.count <= 256
        else { throw LocalDictationRuntimeError.modelNotReady }
        let rawResult = try await engine.generate(
          LocalTextRequest(
            metadata: InferenceRequestMetadata(
              jobID: Self.deterministicUUID([
                namespace,
                "hierarchical-pass-v1",
                String(round),
                String(batchIndex),
              ]),
              inputRevision: inputRevision,
              modelArtifactID: MLXLocalTextArtifact.qwen3Selected.artifactID,
              configHash: configHash
            ),
            taskID: taskID,
            transcriptRevisionID: transcriptRevisionID,
            sourceSegmentIDs: batch.map(\.id),
            sourceText: structuredSource,
            sourceContext: structuredContext.isEmpty ? nil : structuredContext
          )
        )
        let mapping = Dictionary(
          uniqueKeysWithValues: batch.map { ($0.id, $0.sourceSegmentIDs) }
        )
        outputs.append(
          (
            nodes: batch,
            result: try Self.remapLocalTextResult(
              rawResult,
              sourceIDsByNodeID: mapping
            )
          )
        )
      }
      if outputs.count == 1, let result = outputs.first?.result {
        return result
      }

      var nextNodes: [LocalTextEvidenceNode] = []
      for (batchIndex, output) in outputs.enumerated() {
        for (itemIndex, item) in output.result.structuredItems.enumerated() {
          let fragments = Self.utf8Chunks(item.text, maximumBytes: 1_200)
          for (fragmentIndex, fragment) in fragments.enumerated() {
            nextNodes.append(
              LocalTextEvidenceNode(
                id: Self.deterministicUUID([
                  namespace,
                  "hierarchical-evidence-v1",
                  String(round),
                  String(batchIndex),
                  String(itemIndex),
                  String(fragmentIndex),
                  item.itemID.uuidString.lowercased(),
                ]),
                text: fragment,
                sourceSegmentIDs: item.sourceSegmentIDs
              )
            )
          }
        }
      }
      guard !nextNodes.isEmpty, nextNodes != currentNodes else {
        throw LocalDictationRuntimeError.modelNotReady
      }
      currentNodes = nextNodes
    }
    throw LocalDictationRuntimeError.modelNotReady
  }



  func beginLocalTextDrainIfReady() {
    guard localTextEngine != nil, localTextWorkerTask == nil else { return }
    localTextWorkerTask = Task { [weak self] in
      await self?.drainLocalTextJobs()
    }
  }

  func drainLocalTextJobs() async {
    defer { localTextWorkerTask = nil }
    guard localTextEngine != nil else { return }
    var attemptedJobIDs = Set<DurableJobID>()
    while !Task.isCancelled {
      let input: LocalTextBundleJobRecord
      do {
        guard
          let claimed = try await repository.claimNextDefaultLocalTextJob(
            workerID: localTextWorkerID,
            excludingJobIDs: attemptedJobIDs,
            modelArtifactKey: MLXLocalTextArtifact.qwen3Selected.artifactID
          )
        else { return }
        input = claimed
        attemptedJobIDs.insert(claimed.job.id)
      } catch {
        return
      }
      do {
        for taskID in [
          LocalTextTaskID.structuredSummary,
          .chapters,
          .decisions,
          .actionItems,
        ] {
          _ = try await generateLocalTextDocument(
            sessionID: input.sessionID,
            taskID: taskID,
            expectedInputRevision: input.job.inputRevision.value
          )
        }
        try await repository.completeDefaultLocalTextJob(
          jobID: input.job.id,
          workerID: localTextWorkerID
        )
      } catch LocalDictationRuntimeError.staleInputRevision {
        // A newer final transcript already owns the current bundle. The newer
        // revision has its own deterministic job, so the obsolete job is done
        // without allowing old output to replace new documents.
        try? await repository.completeDefaultLocalTextJob(
          jobID: input.job.id,
          workerID: localTextWorkerID
        )
      } catch {
        let failure = Self.localTextJobFailure(for: error)
        localDictationRuntimeLogger.error(
          "local text job failed: job=\(input.job.id.rawValue.uuidString, privacy: .public) category=\(failure.category.rawValue, privacy: .public) code=\(Self.jobDiagnosticCode(for: error), privacy: .public)"
        )
        try? await repository.failDefaultLocalTextJob(
          jobID: input.job.id,
          workerID: localTextWorkerID,
          category: failure.category,
          retryable: failure.retryable && input.job.retryCount < 3
        )
        // Each job is attempted at most once per drain. A retryable failure
        // waits for the next explicit wake while unrelated work can continue.
        continue
      }
    }
  }







  static func normalizedPlatformDisplayName(
    _ value: String?
  ) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.utf8.count <= 256,
      !normalized.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
      })
    else { return nil }
    return normalized
  }

  static func normalizedPlatformName(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "zh_Hans")
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }


  static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
    var dot = 0.0
    var lhsNorm = 0.0
    var rhsNorm = 0.0
    for index in lhs.indices {
      let left = Double(lhs[index])
      let right = Double(rhs[index])
      dot += left * right
      lhsNorm += left * left
      rhsNorm += right * right
    }
    let denominator = sqrt(lhsNorm * rhsNorm)
    guard denominator.isFinite, denominator > 0 else { return 0 }
    return dot / denominator
  }


  static func localTextJobFailure(
    for error: Error
  ) -> (category: DurableJobErrorCategory, retryable: Bool) {
    if error is CancellationError {
      return (.cancelled, true)
    }
    if let inference = error as? InferenceEngineError {
      let category: DurableJobErrorCategory =
        switch inference.category {
        case .cancelled: .cancelled
        case .corruptInput, .invalidRequest: .corruptInput
        case .incompatibleArtifact, .unsupportedContractVersion:
          .incompatibleArtifact
        case .modelUnavailable: .modelUnavailable
        case .resourcePressure: .resourcePressure
        case .transientRuntime: .transientWorker
        }
      return (category, inference.retryable)
    }
    if error is LocalDictationRuntimeError {
      return (.corruptInput, false)
    }
    return (.transientWorker, true)
  }

  static func jobDiagnosticCode(for error: Error) -> String {
    if error is CancellationError {
      return "task-cancelled"
    }
    if let inference = error as? InferenceEngineError {
      return inference.code
    }
    if let journal = error as? ProductionAudioJournalError {
      switch journal {
      case .committedSourceCannotBeCancelled:
        return "audio-committed-source-cannot-be-cancelled"
      case .destinationExists:
        return "audio-destination-exists"
      case .digestMismatch:
        return "audio-digest-mismatch"
      case .fileOperation(let operation):
        return "audio-file-operation-\(operation)"
      case .formatChanged:
        return "audio-format-changed"
      case .invalidFrameCount:
        return "audio-invalid-frame-count"
      case .invalidMetadata:
        return "audio-invalid-metadata"
      case .invalidSequence:
        return "audio-invalid-sequence"
      case .inferenceDerivationInvalid:
        return "audio-inference-derivation-invalid"
      case .missingSession:
        return "audio-missing-session"
      case .sourceRangeMismatch:
        return "audio-source-range-mismatch"
      case .sourceChunkEmpty:
        return "audio-source-chunk-empty"
      case .unsupportedSourceExport:
        return "audio-unsupported-source-export"
      }
    }
    if error is LocalDictationRuntimeError {
      return "local-speaker-evidence-unavailable"
    }
    let bridged = error as NSError
    let domain = bridged.domain.unicodeScalars.map { scalar in
      CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-"
        ? String(scalar) : "-"
    }.joined()
    return "ns-\(String(domain.prefix(96)))-\(bridged.code)"
  }

  static func deterministicUUID(_ components: [String]) -> UUID {
    var bytes = Array(
      SHA256.hash(data: Data(components.joined(separator: "\u{1f}").utf8))
        .prefix(16)
    )
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      )
    )
  }

  static func utf8Prefix(
    _ value: String,
    maximumBytes: Int
  ) -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.utf8.count > maximumBytes else { return normalized }
    var result = ""
    var byteCount = 0
    for character in normalized {
      let characterBytes = String(character).utf8.count
      guard byteCount + characterBytes <= max(0, maximumBytes - 3) else { break }
      result.append(character)
      byteCount += characterBytes
    }
    return result + "…"
  }

  static func eventSessionContext(
    inputMode: SessionInputMode?,
    createdAt: Date
  ) -> String {
    let mode: String
    switch inputMode {
    case .dictation: mode = "口述"
    case .roomMicrophone: mode = "线下录音"
    case .systemAudio: mode = "电脑内录"
    case .importedMedia: mode = "文件导入"
    case .userItem: mode = "收进来的内容"
    case nil: mode = "语音记录"
    }
    // Automatic titles can predate a user correction. They are navigation
    // metadata, not a second transcript, so never feed them as speech evidence.
    return "来源：\(mode)｜录制时间：\(createdAt.ISO8601Format())"
  }

  static func eventSegmentContext(
    sessionContext: String,
    startNanoseconds: UInt64,
    endNanoseconds: UInt64,
    occurrences: [SpeakerOccurrenceSummary]
  ) -> String {
    let labels = occurrences.compactMap { occurrence -> (UInt64, String)? in
      let start = max(startNanoseconds, occurrence.monotonicStartNanoseconds)
      let end = min(endNanoseconds, occurrence.monotonicEndNanoseconds)
      guard end > start else { return nil }
      let anonymous = "说话人 \(Self.liveSpeakerLabel(index: Int(occurrence.stableOrdinal) - 1))"
      let label: String
      switch occurrence.associationStatus {
      case .userConfirmed, .automaticMatch, .anonymousIdentity:
        label = occurrence.personDisplayName ?? anonymous
      case .candidate:
        label =
          occurrence.personDisplayName.map { "\(anonymous)（可能是 \($0)）" }
          ?? anonymous
      case .rejected, .unknown:
        label = anonymous
      }
      return (end - start, label)
    }
    .sorted {
      $0.0 == $1.0
        ? $0.1.localizedStandardCompare($1.1) == .orderedAscending
        : $0.0 > $1.0
    }
    var seen = Set<String>()
    let speakerText = labels.map(\.1).filter { seen.insert($0).inserted }
      .joined(separator: " + ")
    return
      "\(sessionContext)｜\(Self.eventTimecode(startNanoseconds))–\(Self.eventTimecode(endNanoseconds))｜\(speakerText.isEmpty ? "说话人未知" : speakerText)"
  }

  static func eventTimecode(_ nanoseconds: UInt64) -> String {
    let seconds = nanoseconds / 1_000_000_000
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainder = seconds % 60
    return hours > 0
      ? String(format: "%02d:%02d:%02d", Int(hours), Int(minutes), Int(remainder))
      : String(format: "%02d:%02d", Int(minutes), Int(remainder))
  }

  static func utf8Chunks(
    _ value: String,
    maximumBytes: Int
  ) -> [String] {
    guard maximumBytes >= 4 else { return [] }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [] }
    var chunks: [String] = []
    var current = ""
    var byteCount = 0
    for character in normalized {
      let text = String(character)
      let characterBytes = text.utf8.count
      if !current.isEmpty, byteCount + characterBytes > maximumBytes {
        chunks.append(current)
        current = ""
        byteCount = 0
      }
      current.append(character)
      byteCount += characterBytes
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }

  static func localTextBatches(
    _ nodes: [LocalTextEvidenceNode]
  ) -> [[LocalTextEvidenceNode]] {
    let maximumBytes = 15_500
    let maximumNodes = 200
    var batches: [[LocalTextEvidenceNode]] = []
    var current: [LocalTextEvidenceNode] = []
    var currentBytes = 0
    for node in nodes {
      let lineBytes =
        "[S\(current.count + 1)] \(node.text)".utf8.count
        + (node.context.map { "[S\(current.count + 1)] \($0)\n".utf8.count } ?? 0)
        + (current.isEmpty ? 0 : 1)
      if !current.isEmpty,
        current.count >= maximumNodes || currentBytes + lineBytes > maximumBytes
      {
        batches.append(current)
        current = []
        currentBytes = 0
      }
      let restartedLineBytes =
        "[S\(current.count + 1)] \(node.text)".utf8.count
        + (node.context.map { "[S\(current.count + 1)] \($0)\n".utf8.count } ?? 0)
        + (current.isEmpty ? 0 : 1)
      current.append(node)
      currentBytes += restartedLineBytes
    }
    if !current.isEmpty { batches.append(current) }
    return batches
  }

  static func remapLocalTextResult(
    _ result: LocalTextResult,
    sourceIDsByNodeID: [UUID: [UUID]]
  ) throws -> LocalTextResult {
    func originalIDs(_ nodeIDs: [UUID]) throws -> [UUID] {
      let ids = Self.orderedUnique(
        nodeIDs.flatMap { sourceIDsByNodeID[$0] ?? [] }
      )
      guard !ids.isEmpty else { throw LocalDictationRuntimeError.modelNotReady }
      return ids
    }
    let claims = try result.claims.map { claim in
      LocalTextClaim(
        claimID: claim.claimID,
        text: claim.text,
        sourceSegmentIDs: try originalIDs(claim.sourceSegmentIDs),
        confidence: claim.confidence,
        disposition: claim.disposition
      )
    }
    let items = try result.structuredItems.map { item in
      LocalTextStructuredItem(
        itemID: item.itemID,
        kind: item.kind,
        text: item.text,
        owner: item.owner,
        sourceSegmentIDs: try originalIDs(item.sourceSegmentIDs),
        confidence: item.confidence,
        disposition: item.disposition,
        dueDateText: item.dueDateText,
        completedAt: item.completedAt
      )
    }
    return LocalTextResult(
      contractVersion: result.contractVersion,
      modelArtifactID: result.modelArtifactID,
      taskID: result.taskID,
      outputText: result.outputText,
      claims: claims,
      structuredItems: items
    )
  }

  static func orderedUnique(_ values: [UUID]) -> [UUID] {
    var seen = Set<UUID>()
    return values.filter { seen.insert($0).inserted }
  }

  static func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
  }
}

struct MappedInferenceAudioPort: DictationInferenceAudioPort {
  let base: ProductionAudioJournal

  func prepareInferenceAudio(
    sessionID: SessionID,
    sourceAudio: [AudioRangeInput]
  ) async throws -> [AudioRangeInput] {
    do {
      return try await base.prepareInferenceAudio(
        sessionID: sessionID,
        sourceAudio: sourceAudio
      )
    } catch let error as ProductionAudioJournalError {
      throw InferenceEngineError(
        category: .corruptInput,
        code: Self.safeCode(for: error),
        retryable: true
      )
    }
  }

  func discardInferenceAudio(
    sessionID: SessionID,
    preparedAudio: [AudioRangeInput]
  ) async {
    await base.discardInferenceAudio(
      sessionID: sessionID,
      preparedAudio: preparedAudio
    )
  }

  private static func safeCode(for error: ProductionAudioJournalError) -> String {
    switch error {
    case .committedSourceCannotBeCancelled: "audio-source-committed"
    case .destinationExists: "audio-destination-exists"
    case .digestMismatch: "audio-digest-mismatch"
    case .fileOperation: "audio-file-operation-failed"
    case .formatChanged: "audio-format-changed"
    case .invalidFrameCount: "audio-frame-count-invalid"
    case .invalidMetadata: "audio-metadata-invalid"
    case .invalidSequence: "audio-sequence-invalid"
    case .inferenceDerivationInvalid: "audio-inference-derivation-invalid"
    case .missingSession: "audio-session-missing"
    case .sourceRangeMismatch: "audio-source-range-mismatch"
    case .sourceChunkEmpty: "audio-source-chunk-empty"
    case .unsupportedSourceExport: "audio-source-export-unsupported"
    }
  }
}

actor LazyManagedASREngine: ASREngine {
  typealias Factory = @Sendable () async throws -> any ASREngine

  private let artifact: ModelArtifactDescriptor
  private let factory: Factory
  private var loadedEngine: (any ASREngine)?
  private var loadingTask: Task<any ASREngine, Error>?

  init(
    artifact: ModelArtifactDescriptor,
    factory: @escaping Factory
  ) {
    self.artifact = artifact
    self.factory = factory
  }

  func descriptor() async -> InferenceEngineDescriptor {
    InferenceEngineDescriptor(artifact: artifact)
  }

  func prepare() async throws {
    _ = try await resolveEngine()
  }

  func transcribe(_ request: ASRRequest) async throws -> ASRResult {
    let engine = try await resolveEngine()
    return try await engine.transcribe(request)
  }

  private func resolveEngine() async throws -> any ASREngine {
    if let loadedEngine {
      return loadedEngine
    }
    let task: Task<any ASREngine, Error>
    if let loadingTask {
      task = loadingTask
    } else {
      let factory = self.factory
      let created = Task { try await factory() }
      loadingTask = created
      task = created
    }
    do {
      let loaded = try await task.value
      guard await loaded.descriptor().artifact == artifact else {
        throw InferenceEngineError(
          category: .incompatibleArtifact,
          code: "lazy-asr-artifact-mismatch",
          retryable: false
        )
      }
      loadedEngine = loaded
      loadingTask = nil
      return loaded
    } catch {
      loadingTask = nil
      throw error
    }
  }
}

enum AutomaticASRLanguageProfile: Equatable, Hashable, Sendable {
  case mandarin
  case english
  case mixed
  case unknown
}

struct AutomaticASRLanguageClassifier: Sendable {
  struct Counts: Equatable, Sendable {
    let han: Int
    let latin: Int
  }

  static func counts(in text: String) -> Counts {
    var han = 0
    var latin = 0
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x20000...0x2FA1F:
        han += 1
      case 0x41...0x5A, 0x61...0x7A:
        latin += 1
      default:
        break
      }
    }
    return Counts(han: han, latin: latin)
  }

  static func profile(for text: String) -> AutomaticASRLanguageProfile {
    let counts = counts(in: text)
    if counts.han >= 2, counts.latin >= 2 { return .mixed }
    if counts.han > 0, counts.han >= max(1, counts.latin * 2) {
      return .mandarin
    }
    if counts.latin >= 2, counts.latin >= max(1, counts.han * 2) {
      return .english
    }
    if counts.han > 0 { return .mandarin }
    if counts.latin >= 2 { return .english }
    return .unknown
  }

  static func profile(
    forLanguageHints languageHints: [String]
  ) -> AutomaticASRLanguageProfile {
    let profiles: Set<AutomaticASRLanguageProfile> = Set(
      languageHints.compactMap { hint -> AutomaticASRLanguageProfile? in
        let normalized = hint.replacingOccurrences(of: "_", with: "-")
          .lowercased()
        if normalized == "zh" || normalized.hasPrefix("zh-")
          || normalized == "cmn" || normalized.hasPrefix("cmn-")
        {
          return .mandarin
        }
        if normalized == "en" || normalized.hasPrefix("en-") {
          return .english
        }
        return nil
      }
    )
    return profiles.count == 1 ? profiles.first ?? .unknown : .unknown
  }

  static func profile(
    for text: String,
    detectedLanguageHints: [String]
  ) -> AutomaticASRLanguageProfile {
    let textProfile = profile(for: text)
    // SenseVoice emits one dominant-language tag even for a code-switched
    // utterance. Positive mixed-script evidence must retain the mixed model.
    if textProfile == .mixed { return .mixed }
    let detectedProfile = profile(forLanguageHints: detectedLanguageHints)
    return detectedProfile == .unknown ? textProfile : detectedProfile
  }

  static func isCompatible(
    _ text: String,
    with profile: AutomaticASRLanguageProfile
  ) -> Bool {
    let counts = counts(in: text)
    switch profile {
    case .mandarin:
      return counts.han > 0 && counts.han >= counts.latin
    case .english:
      return counts.latin >= 2 && counts.latin >= counts.han * 2
    case .mixed:
      return counts.han >= 2 && counts.latin >= 2
    case .unknown:
      return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }
}

/// Keeps the low-latency live path, prefers a fully aligned multilingual final
/// and retains the earlier language-specialized final route on runtime failure.
/// Cancellation and authoritative empty final results never start a fallback.
actor AutomaticLanguageRoutedASRAdapter: VersionedDictationASRPort {
  private let mixedLanguageFallback: any VersionedDictationASRPort
  private let mandarinFinal: (any VersionedDictationASRPort)?
  private let englishFinal: (any VersionedDictationASRPort)?
  private let multilingualFinal: (any VersionedDictationASRPort)?
  private let languageEvidenceText: String
  private let languageEvidenceHints: [String]
  private let permitsEmptyResult: Bool

  init(
    mixedLanguageFallback: any VersionedDictationASRPort,
    mandarinFinal: (any VersionedDictationASRPort)?,
    englishFinal: (any VersionedDictationASRPort)?,
    multilingualFinal: (any VersionedDictationASRPort)? = nil,
    languageEvidenceText: String = "",
    languageEvidenceHints: [String] = [],
    permitsEmptyResult: Bool
  ) {
    self.mixedLanguageFallback = mixedLanguageFallback
    self.mandarinFinal = mandarinFinal
    self.englishFinal = englishFinal
    self.multilingualFinal = multilingualFinal
    self.languageEvidenceText = languageEvidenceText
    self.languageEvidenceHints = languageEvidenceHints
    self.permitsEmptyResult = permitsEmptyResult
  }

  func recognize(
    _ request: DictationASRRequest
  ) async throws -> DictationTranscriptResult {
    try await recognize(
      VersionedDictationASRRequest(
        request: request,
        mode: .final,
        languageHints: ["zh-CN", "en-US"],
        supersedesRevisionID: nil
      )
    )
  }

  func recognize(
    _ request: VersionedDictationASRRequest
  ) async throws -> DictationTranscriptResult {
    guard request.mode == .final else {
      return try await mixedLanguageFallback.recognize(request)
    }

    if let multilingualFinal {
      let preferred: DictationTranscriptResult?
      do {
        preferred = try await multilingualFinal.recognize(request)
      } catch is CancellationError {
        throw InferenceEngineError.cancelled
      } catch let error as InferenceEngineError where error.category == .cancelled {
        throw error
      } catch {
        preferred = nil
      }
      try InferenceCancellation.check()
      if let preferred {
        if permitsEmptyResult
          || !preferred.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          return preferred
        }
        throw InferenceEngineError(
          category: .invalidRequest, code: "dictation-asr-no-speech-detected", retryable: true)
      }
    }

    let evidenceProfile = AutomaticASRLanguageClassifier.profile(
      for: languageEvidenceText,
      detectedLanguageHints: languageEvidenceHints
    )
    if evidenceProfile == .mandarin,
      let result = try await specializedResult(
        mandarinFinal,
        request: request,
        profile: .mandarin
      )
    {
      return result
    }
    if evidenceProfile == .english,
      let result = try await specializedResult(
        englishFinal,
        request: request,
        profile: .english
      )
    {
      return result
    }

    let baseline = try await mixedLanguageFallback.recognize(request)

    let baselineText = baseline.text.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let baselineProfile = AutomaticASRLanguageClassifier.profile(
      for: baselineText,
      detectedLanguageHints: baseline.provenance?.languageHints ?? []
    )
    switch baselineProfile {
    case .mandarin:
      return try await specializedResult(
        mandarinFinal,
        request: request,
        profile: .mandarin
      ) ?? baseline
    case .english:
      return try await specializedResult(
        englishFinal,
        request: request,
        profile: .english
      ) ?? baseline
    case .mixed:
      return baseline
    case .unknown:
      if !baselineText.isEmpty { return baseline }
    }

    switch evidenceProfile {
    case .mandarin:
      if let result = try await specializedResult(
        mandarinFinal,
        request: request,
        profile: .mandarin
      ) {
        return result
      }
    case .english:
      if let result = try await specializedResult(
        englishFinal,
        request: request,
        profile: .english
      ) {
        return result
      }
    case .mixed:
      if permitsEmptyResult { return baseline }
    case .unknown:
      break
    }

    // SenseVoice's realistic English evaluation most often failed as an empty
    // result, while its Mandarin empty-result rate was low. Try the English
    // final decoder first, then Mandarin; both independently suppress silence.
    if let result = try await specializedResult(
      englishFinal,
      request: request,
      profile: .english
    ) {
      return result
    }
    if let result = try await specializedResult(
      mandarinFinal,
      request: request,
      profile: .mandarin
    ) {
      return result
    }
    if permitsEmptyResult { return baseline }
    throw InferenceEngineError(
      category: .invalidRequest,
      code: "dictation-asr-no-speech-detected",
      retryable: true
    )
  }

  private func specializedResult(
    _ port: (any VersionedDictationASRPort)?,
    request: VersionedDictationASRRequest,
    profile: AutomaticASRLanguageProfile
  ) async throws -> DictationTranscriptResult? {
    guard let port else { return nil }
    do {
      let result = try await port.recognize(request)
      return AutomaticASRLanguageClassifier.isCompatible(
        result.text,
        with: profile
      ) ? result : nil
    } catch is CancellationError {
      throw InferenceEngineError.cancelled
    } catch let error as InferenceEngineError
      where error.category == .cancelled
    {
      throw error
    } catch {
      return nil
    }
  }
}

actor DynamicLiveASRAdapter: VersionedDictationASRPort {
  private let engine: any ASREngine
  private let audio: any DictationInferenceAudioPort
  private let baseConfigHash: String

  init(
    engine: any ASREngine,
    audio: any DictationInferenceAudioPort,
    baseConfigHash: String
  ) {
    self.engine = engine
    self.audio = audio
    self.baseConfigHash = baseConfigHash
  }

  func recognize(
    _ request: DictationASRRequest
  ) async throws -> DictationTranscriptResult {
    try await recognize(
      VersionedDictationASRRequest(
        request: request,
        mode: .streaming,
        languageHints: ["zh-CN", "en-US"],
        supersedesRevisionID: nil
      )
    )
  }

  func recognize(
    _ request: VersionedDictationASRRequest
  ) async throws -> DictationTranscriptResult {
    let adapter = BoundedDictationASRAdapter(
      engine: engine,
      audio: audio,
      configHash: try liveConfigHash(
        base: baseConfigHash,
        dictionaryTerms: request.request.dictionaryTerms,
        dictionaryHints: request.request.dictionaryHints
      ),
      policy: try BoundedDictationASRPolicy(
        maximumRangeNanoseconds: 30_000_000_000,
        timeoutNanoseconds: 12_000_000_000
      )
    )
    return try await adapter.recognize(request)
  }
}

func liveConfigHash(
  base: String,
  dictionaryTerms: [String],
  dictionaryHints: [ASRDictionaryHint]
) throws -> BestASRDomain.SHA256Digest {
  let boundedDictionary = dictionaryTerms.map {
    "\($0.utf8.count):\($0)"
  }.joined(separator: "|")
  let boundedHints = dictionaryHints.map { hint in
    let spoken = hint.spokenForms.map {
      "\($0.utf8.count):\($0)"
    }.joined(separator: ",")
    return "\(hint.canonicalForm.utf8.count):\(hint.canonicalForm):\(spoken)"
  }.joined(separator: "|")
  let value =
    "\(base)|\(boundedDictionary)|\(boundedHints)"
    + "|live-v1|rms-0.012|speech-250ms|silence-650ms"
    + "|window-30s|cadence-900ms"
  let digest = SHA256.hash(data: Data(value.utf8)).map {
    String(format: "%02x", $0)
  }.joined()
  return try BestASRDomain.SHA256Digest(digest)
}

actor FinalParentingASRAdapter: DictationASRPort {
  private let base: any VersionedDictationASRPort
  private let parentRevisionID: TranscriptRevisionID
  private let liveCandidates: [DictationTranscriptResult]
  private let dictionaryTerms: [String]

  init(
    base: any VersionedDictationASRPort,
    parentRevisionID: TranscriptRevisionID,
    liveCandidates: [DictationTranscriptResult],
    dictionaryTerms: [String]
  ) {
    self.base = base
    self.parentRevisionID = parentRevisionID
    self.liveCandidates = liveCandidates
    self.dictionaryTerms = dictionaryTerms
  }

  func recognize(
    _ request: DictationASRRequest
  ) async throws -> DictationTranscriptResult {
    let final = try await base.recognize(
      VersionedDictationASRRequest(
        request: request,
        mode: .final,
        languageHints: ["zh-CN", "en-US"],
        supersedesRevisionID: parentRevisionID
      )
    )
    return FinalTranscriptReconciler.reconcile(
      final: final,
      liveCandidates: liveCandidates,
      parentRevisionID: parentRevisionID,
      dictionaryTerms: dictionaryTerms
    )
  }
}

func finalTranscriptCandidate(
  _ record: DictationPersistedTranscriptRecord
) -> DictationTranscriptResult? {
  guard record.kind == .streaming || record.kind == .sentence,
    let modelArtifactID = record.modelArtifactID,
    !modelArtifactID.isEmpty,
    !record.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  else { return nil }
  return DictationTranscriptResult(
    revisionID: record.id,
    segmentIDs: record.segments.map(\.id),
    text: record.content,
    modelArtifactID: modelArtifactID,
    provenance: DictationTranscriptProvenance(
      parentRevisionID: record.parentID,
      kind: record.kind,
      languageHints: record.languageHints,
      audioRanges: record.audioRanges,
      segments: record.segments
    )
  )
}
