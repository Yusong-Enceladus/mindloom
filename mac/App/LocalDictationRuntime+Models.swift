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

// Models: moved out of LocalDictationRuntime.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension LocalDictationRuntime {
  func discoverInstalledModels() async -> LocalModelReadiness {
    let asrReady = await discoverInstalledASR()
    let polishReady = await discoverInstalledPolish()
    let speakerReady = await discoverInstalledSpeaker()
    return LocalModelReadiness(
      asrReady: asrReady,
      polishReady: polishReady,
      speakerReady: speakerReady
    )
  }

  func discoverInstalledASR() async -> Bool {
    do {
      try await configureASR()
      return true
    } catch {
      asrEngine = nil
      mandarinFinalASREngine = nil
      englishFinalASREngine = nil
      multilingualFinalASREngine = nil
      return false
    }
  }

  func discoverInstalledPolish() async -> Bool {
    configurePersonalCleanup()
    do {
      // Verify the model without loading its weights; it loads on first use
      // (model polish when enabled, or a requested 整理).
      try await configurePolish(prepare: false)
      return true
    } catch {
      polishAdapter = nil
      localTextEngine = nil
      return false
    }
  }

  /// Loads the preferred installed final runtime after the capture path
  /// is already available. The work is intentionally unstructured but owned
  /// and retained by this actor: capture and AudioJournal writes never await
  /// it, while a very short first dictation joins the same in-flight factory
  /// instead of starting a second cold model load after the user presses End.
  func beginFinalASRPrewarm() {
    guard finalASRPrewarmTask == nil else { return }
    if let multilingual = multilingualFinalASREngine {
      finalASRPrewarmTask = Task { [weak self] in
        await Self.prewarm(multilingual, label: "multilingual-aligned")
        // An App that launches and is not dictated into should not keep the
        // models resident either.
        await self?.scheduleIdleModelRelease()
      }
      return
    }
    let mandarin = mandarinFinalASREngine
    let english = englishFinalASREngine
    guard mandarin != nil || english != nil else { return }
    finalASRPrewarmTask = Task {
      async let mandarinPreparation: Void = Self.prewarm(
        mandarin,
        label: "mandarin"
      )
      async let englishPreparation: Void = Self.prewarm(
        english,
        label: "english"
      )
      _ = await (mandarinPreparation, englishPreparation)
    }
  }

  nonisolated static func prewarm(
    _ engine: LazyManagedASREngine?,
    label: String
  ) async {
    guard let engine else { return }
    do {
      let loadStarted = ContinuousClock.now
      try await engine.prepare()
      logDictationStage("final-asr-load", since: loadStarted)
      let usage = QwenRuntimeMemory.usage()
      localDictationRuntimeLogger.notice(
        """
        final ASR prewarm ready profile=\(label, privacy: .public)         mlx_active_mb=\(usage.active / 1_048_576, privacy: .public)         mlx_cached_mb=\(usage.cached / 1_048_576, privacy: .public)
        """
      )
    } catch is CancellationError {
      localDictationRuntimeLogger.info(
        "final ASR prewarm cancelled profile=\(label, privacy: .public)"
      )
    } catch {
      localDictationRuntimeLogger.error(
        "final ASR prewarm failed profile=\(label, privacy: .public)"
      )
    }
  }

  func installModel(from sourceDirectory: URL) async throws {
    _ = try await modelManager.activate(
      artifactID: FluidSenseVoicePinnedArtifact.artifactID,
      version: FluidSenseVoicePinnedArtifact.sourceRevision,
      from: sourceDirectory,
      healthCheck: FluidSenseVoiceModelHealthCheck()
    )
    try await configureASR()
  }

  func recommendedModelArtifacts() -> [ManagedModelArtifact] {
    [
      modelRegistry.artifact(id: FluidSenseVoicePinnedArtifact.artifactID),
      modelRegistry.artifact(id: FluidParaformerPinnedArtifact.artifactID),
      modelRegistry.artifact(id: FluidParakeetUnifiedPinnedArtifact.artifactID),
      modelRegistry.artifact(id: QwenASRPinnedArtifact.artifactID),
      modelRegistry.artifact(id: QwenAlignmentPinnedArtifact.artifactID),
      modelRegistry.artifact(id: MLXLocalTextArtifact.qwen3Selected.artifactID),
      modelRegistry.artifact(id: FluidSpeakerPinnedArtifact.artifactID),
    ].compactMap { $0 }
  }

  func downloadRecommendedSpeechModel(
    onState: @escaping ModelDistributionCoordinator.StateHandler
  ) async throws {
    let artifacts: [(ManagedModelArtifact, any ManagedModelHealthChecking)] = [
      (
        try requiredModelArtifact(FluidSenseVoicePinnedArtifact.artifactID),
        FluidSenseVoiceModelHealthCheck()
      ),
      (
        try requiredModelArtifact(FluidParaformerPinnedArtifact.artifactID),
        FluidParaformerModelHealthCheck()
      ),
      (
        try requiredModelArtifact(
          FluidParakeetUnifiedPinnedArtifact.artifactID
        ),
        FluidParakeetUnifiedModelHealthCheck()
      ),
      (
        try requiredModelArtifact(QwenASRPinnedArtifact.artifactID),
        QwenASRModelHealthCheck()
      ),
      (
        try requiredModelArtifact(QwenAlignmentPinnedArtifact.artifactID),
        QwenAlignmentModelHealthCheck()
      ),
    ]
    let totalBytes = artifacts.reduce(UInt64(0)) { $0 + $1.0.totalSizeBytes }
    var completedBeforeArtifact: UInt64 = 0
    for (index, item) in artifacts.enumerated() {
      let artifact = item.0
      let healthCheck = item.1
      let offset = completedBeforeArtifact
      _ = try await modelDistribution.install(
        artifactID: artifact.artifactID,
        healthCheck: healthCheck,
        onState: { state in
          let isLast = index == artifacts.count - 1
          onState(
            ModelDistributionState(
              artifactID: "bestasr-speech-pack-v3",
              version: "3",
              phase: state.phase == .ready && !isLast ? .downloading : state.phase,
              completedBytes: offset + state.completedBytes,
              totalBytes: totalBytes,
              currentFile: state.currentFile.map {
                "\(artifact.artifactID)/\($0)"
              },
              errorCode: state.errorCode
            )
          )
        }
      )
      completedBeforeArtifact += artifact.totalSizeBytes
    }
    try await configureASR()
  }

  func requiredModelArtifact(
    _ artifactID: String
  ) throws -> ManagedModelArtifact {
    guard let artifact = modelRegistry.artifact(id: artifactID) else {
      throw LocalDictationRuntimeError.bundledRegistryMissing
    }
    return artifact
  }

  func downloadRecommendedPolishModel(
    onState: @escaping ModelDistributionCoordinator.StateHandler
  ) async throws {
    let artifact = MLXLocalTextArtifact.qwen3Selected
    _ = try await modelDistribution.install(
      artifactID: artifact.artifactID,
      healthCheck: MLXLocalTextModelHealthCheck(),
      onState: onState
    )
    try await configurePolish(prepare: false)
  }

  func installPolishModel(from sourceDirectory: URL) async throws {
    let artifact = MLXLocalTextArtifact.qwen3Selected
    _ = try await modelManager.activate(
      artifactID: artifact.artifactID,
      version: artifact.sourceRevision,
      from: sourceDirectory,
      healthCheck: MLXLocalTextModelHealthCheck()
    )
    try await configurePolish(prepare: false)
  }

  func restoreLastKnownGoodModel(
    _ component: LocalModelComponent
  ) async throws {
    switch component {
    case .speech:
      _ = try await modelManager.restoreLastKnownGood(
        artifactID: FluidSenseVoicePinnedArtifact.artifactID,
        healthCheck: FluidSenseVoiceModelHealthCheck()
      )
      _ = try? await modelManager.restoreLastKnownGood(
        artifactID: FluidParaformerPinnedArtifact.artifactID,
        healthCheck: FluidParaformerModelHealthCheck()
      )
      _ = try? await modelManager.restoreLastKnownGood(
        artifactID: FluidParakeetUnifiedPinnedArtifact.artifactID,
        healthCheck: FluidParakeetUnifiedModelHealthCheck()
      )
      try await configureASR()
    case .speaker:
      _ = try await modelManager.restoreLastKnownGood(
        artifactID: FluidSpeakerPinnedArtifact.artifactID,
        healthCheck: FluidSpeakerModelHealthCheck()
      )
      try await configureSpeaker()
      try await rebuildSpeakerIndexForCurrentModel()
    case .localText:
      _ = try await modelManager.restoreLastKnownGood(
        artifactID: MLXLocalTextArtifact.qwen3Selected.artifactID,
        healthCheck: MLXLocalTextModelHealthCheck()
      )
      try await configurePolish(prepare: false)
    }
  }

  func adoptFinalASRWarmupRuntime(_ runtime: QwenASRRuntime) {
    finalASRWarmupRuntime = runtime
    // The first decode after load compiles GPU kernels; do it now, off the
    // End-to-insert path.
    warmFinalASRIfIdle()
  }

  func scheduleTextModelRelease() {
    textModelReleaseTask?.cancel()
    textModelReleaseTask = Task { [weak self] in
      try? await Task.sleep(for: Self.textModelReleaseDelay)
      guard !Task.isCancelled, let self else { return }
      await self.generalTextRuntime?.release()
      localDictationRuntimeLogger.notice("text model released after idle")
    }
  }

  /// Frees every model this runtime holds after the App has been idle.
  func scheduleIdleModelRelease() {
    idleModelReleaseTask?.cancel()
    idleModelReleaseTask = Task { [weak self] in
      try? await Task.sleep(for: Self.idleModelReleaseDelay)
      guard !Task.isCancelled else { return }
      await self?.releaseIdleModels()
    }
  }

  func releaseIdleModels() async {
    // Only work that is genuinely in flight may hold the models, and only
    // briefly: a dictation that starts cancels this timer, and one that
    // finishes leaves nothing behind. The guard used to also require an empty
    // speculation slot, which a finished dictation never emptied — so after
    // the first dictation the release stopped happening at all, for as long
    // as the App ran. A deferral now re-arms instead of dropping the release.
    guard sessionsAwaitingInsertion.isEmpty else {
      localDictationRuntimeLogger.notice("idle model release deferred, insertion in flight")
      scheduleIdleModelRelease()
      return
    }
    await personalCleanup?.service.release()
    if let runtime = finalASRWarmupRuntime {
      await runtime.releaseModels()
    }
    // The general text model is loaded by the first 指令 and, until now, was
    // never let go: an idle App kept it resident indefinitely. It reloads
    // itself on the next use.
    await generalTextRuntime?.release()
    let usage = QwenRuntimeMemory.usage()
    localDictationRuntimeLogger.notice(
      "idle models released mlx_active_mb=\(usage.active / 1_048_576, privacy: .public)"
    )
    await compactIdleRecordings()
  }

  /// Called when a dictation starts: while the user speaks, make sure the
  /// final recognizer is resident and compiled.
  func warmFinalASRIfIdle() {
    idleModelReleaseTask?.cancel()
    idleModelReleaseTask = nil
    // The cleanup model and the aligner load once, in the background, while
    // the user speaks, so an idle App holds neither.
    if personalCleanupEnabled, let service = personalCleanup?.service {
      Task { await service.warmUp() }
    }
    if let runtime = finalASRWarmupRuntime {
      Task { await runtime.warmAlignment() }
    }
    guard let runtime = finalASRWarmupRuntime, finalASRWarmupTask == nil else { return }
    if let last = lastFinalASRActivity,
      ContinuousClock.now - last < Self.finalASRIdleWarmupThreshold
    {
      return
    }
    lastFinalASRActivity = ContinuousClock.now
    finalASRWarmupTask = Task { [weak self] in
      await runtime.warmUp()
      await self?.finishFinalASRWarmup()
    }
  }

  func finishFinalASRWarmup() {
    finalASRWarmupTask = nil
    lastFinalASRActivity = ContinuousClock.now
  }

  func makeMultilingualFinalASREngineIfInstalled() async -> LazyManagedASREngine? {
    guard
      let asr = try? await modelManager.discoverActive(
        artifactID: QwenASRPinnedArtifact.artifactID, healthCheck: FileSetModelHealthCheck()),
      let alignment = try? await modelManager.discoverActive(
        artifactID: QwenAlignmentPinnedArtifact.artifactID, healthCheck: FileSetModelHealthCheck()),
      asr.descriptor.version == QwenASRPinnedArtifact.sourceRevision,
      asr.descriptor.treeSHA256 == QwenASRPinnedArtifact.treeSHA256,
      alignment.descriptor.version == QwenAlignmentPinnedArtifact.sourceRevision,
      alignment.descriptor.treeSHA256 == QwenAlignmentPinnedArtifact.treeSHA256
    else { return nil }
    return LazyManagedASREngine(artifact: QwenASRPinnedArtifact.descriptor) {
      [modelManager, journal, weak self] in
      let runtime = try await QwenASRRuntimeFactory.make(
        modelManager: modelManager, audioAssetRoot: journal.assetRootURL)
      await self?.adoptFinalASRWarmupRuntime(runtime)
      return PinnedOfflineASRAdapter(
        candidateID: QwenASRPinnedArtifact.candidateID,
        capabilities: QwenASRPinnedArtifact.descriptor.capabilities,
        runtime: runtime, artifact: QwenASRPinnedArtifact.descriptor)
    }
  }

  func makeMandarinFinalASREngineIfInstalled() async
    -> LazyManagedASREngine?
  {
    guard
      let active = try? await modelManager.discoverActive(
        artifactID: FluidParaformerPinnedArtifact.artifactID,
        healthCheck: FileSetModelHealthCheck()
      ),
      active.descriptor.version == FluidParaformerPinnedArtifact.sourceRevision,
      active.descriptor.treeSHA256 == FluidParaformerPinnedArtifact.treeSHA256
    else { return nil }
    return LazyManagedASREngine(
      artifact: FluidParaformerPinnedArtifact.descriptor,
      factory: { [modelManager, journal] in
        let runtime = try await FluidParaformerRuntimeFactory.make(
          modelManager: modelManager,
          audioAssetRoot: journal.assetRootURL
        )
        return PinnedOfflineASRAdapter(
          candidateID: FluidParaformerPinnedArtifact.candidateID,
          capabilities: [.asrBatch, .asrRevisioned, .asrTimestamps],
          runtime: runtime,
          artifact: FluidParaformerPinnedArtifact.descriptor
        )
      }
    )
  }

  func makeEnglishFinalASREngineIfInstalled() async
    -> LazyManagedASREngine?
  {
    guard
      let active = try? await modelManager.discoverActive(
        artifactID: FluidParakeetUnifiedPinnedArtifact.artifactID,
        healthCheck: FileSetModelHealthCheck()
      ),
      active.descriptor.version
        == FluidParakeetUnifiedPinnedArtifact.sourceRevision,
      active.descriptor.treeSHA256
        == FluidParakeetUnifiedPinnedArtifact.treeSHA256
    else { return nil }
    return LazyManagedASREngine(
      artifact: FluidParakeetUnifiedPinnedArtifact.descriptor,
      factory: { [modelManager, journal] in
        let runtime = try await FluidParakeetUnifiedRuntimeFactory.make(
          modelManager: modelManager,
          audioAssetRoot: journal.assetRootURL
        )
        return PinnedOfflineASRAdapter(
          candidateID: FluidParakeetUnifiedPinnedArtifact.candidateID,
          capabilities: [
            .asrBatch, .asrRevisioned, .asrStreaming, .asrTimestamps,
          ],
          runtime: runtime,
          artifact: FluidParakeetUnifiedPinnedArtifact.descriptor
        )
      }
    )
  }
}
