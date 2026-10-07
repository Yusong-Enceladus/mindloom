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
    await startModelHousekeeping()
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
    // The load counts as busy from now (not from when its task starts), so
    // the meaning index never starts alongside it (v12 search, HIST-009).
    let gauge = heavyWork
    if let multilingual = multilingualFinalASREngine {
      gauge.begin()
      finalASRPrewarmTask = Task { [weak self] in
        await Self.prewarm(multilingual, label: "multilingual-aligned")
        await self?.noteRecognizerResident()
        gauge.end()
        // An App that launches and is not dictated into should not keep the
        // models resident either.
        await self?.scheduleIdleModelRelease()
      }
      return
    }
    let mandarin = mandarinFinalASREngine
    let english = englishFinalASREngine
    guard mandarin != nil || english != nil else { return }
    gauge.begin()
    finalASRPrewarmTask = Task {
      defer { gauge.end() }
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

  /// The models a new Mac downloads. Paraformer and Parakeet are not among
  /// them since 2026-10-06: they are only a fallback behind Qwen3-ASR, and in
  /// the owner's library they produced none of 6,027 final transcripts (977
  /// Qwen3-ASR, 8 SenseVoice, 5,042 imported) (ALIGNMENT 收1-4).
  static let requiredSpeechArtifactIDs = [
    FluidSenseVoicePinnedArtifact.artifactID,
    QwenASRPinnedArtifact.artifactID,
    QwenAlignmentPinnedArtifact.artifactID,
  ]

  /// The models this App has retired. Launch housekeeping removes them
  /// from the store (`removeRetiredModels`): since 2026-10-06 that takes the
  /// Paraformer and Parakeet a Mac already has (0.84 GB, the owner chose to
  /// delete them), before discovery, so their fallback routes find nothing,
  /// as on a new Mac. Named one by one, never "everything this build does
  /// not use" (review 2026-10-07): other features install their own models
  /// into the same store (meaning search's embedding model), and a model
  /// this list does not name always stays.
  static let retiredModelArtifactIDs: Set<String> = [
    FluidParaformerPinnedArtifact.artifactID,
    FluidParakeetUnifiedPinnedArtifact.artifactID,
  ]

  nonisolated static func healthCheck(
    forSpeechArtifact artifactID: String
  ) -> any ManagedModelHealthChecking {
    switch artifactID {
    case FluidSenseVoicePinnedArtifact.artifactID: FluidSenseVoiceModelHealthCheck()
    case QwenASRPinnedArtifact.artifactID: QwenASRModelHealthCheck()
    case QwenAlignmentPinnedArtifact.artifactID: QwenAlignmentModelHealthCheck()
    default: FileSetModelHealthCheck()
    }
  }

  func recommendedModelArtifacts() -> [ManagedModelArtifact] {
    [
      modelRegistry.artifact(id: FluidSenseVoicePinnedArtifact.artifactID),
      modelRegistry.artifact(id: QwenASRPinnedArtifact.artifactID),
      modelRegistry.artifact(id: QwenAlignmentPinnedArtifact.artifactID),
      modelRegistry.artifact(id: MLXLocalTextArtifact.qwen3Selected.artifactID),
      modelRegistry.artifact(id: FluidSpeakerPinnedArtifact.artifactID),
      modelRegistry.artifact(id: MLXMeaningArtifact.selected.artifactID),
    ].compactMap { $0 }
  }

  func downloadRecommendedSpeechModel(
    onState: @escaping ModelDistributionCoordinator.StateHandler
  ) async throws {
    let artifacts: [(ManagedModelArtifact, any ManagedModelHealthChecking)] =
      try Self.requiredSpeechArtifactIDs.map { id in
        (try requiredModelArtifact(id), Self.healthCheck(forSpeechArtifact: id))
      }
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

  /// v12 search: the meaning model's embedder over its verified, active
  /// copy; nil when it is not installed or fails its check (nothing loads
  /// until the first piece is embedded).
  func makeMeaningEmbedder() async -> MLXMeaningEmbedder? {
    try? await MLXMeaningEmbedderFactory.make(modelManager: modelManager)
  }

  func downloadRecommendedMeaningModel(
    onState: @escaping ModelDistributionCoordinator.StateHandler
  ) async throws {
    _ = try await modelDistribution.install(
      artifactID: MLXMeaningArtifact.selected.artifactID,
      healthCheck: MLXMeaningModelHealthCheck(),
      onState: onState
    )
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
    case .meaning:
      _ = try await modelManager.restoreLastKnownGood(
        artifactID: MLXMeaningArtifact.selected.artifactID,
        healthCheck: MLXMeaningModelHealthCheck()
      )
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

  /// Frees the models this runtime holds after the App has been idle, step
  /// by step as `residency` says: after a dictation the cleanup model and
  /// the general text model after ten minutes and the recognizer after an
  /// hour; after a launch nobody dictated into, everything after ten
  /// minutes. Once the recognizer has gone, the sentences of the dictations
  /// it recognized are timed, with the aligner alone in memory
  /// (`startDeferredWordAlignment`). Every ending of a dictation re-arms it
  /// (`endDictationBookkeeping`).
  func scheduleIdleModelRelease() {
    idleModelReleaseTask?.cancel()
    let steps = residency.idleReleaseSchedule(afterDictation: dictationEndedSinceLaunch)
    idleModelReleaseTask = Task { [weak self] in
      var elapsed: Duration = .zero
      for step in steps {
        try? await Task.sleep(for: step.after - elapsed)
        elapsed = step.after
        guard !Task.isCancelled else { return }
        guard await self?.releaseIdleModels(step.models) == true else { return }
        // A press while the models were being released cancelled this
        // task: no timing next to the dictation it starts (review
        // 2026-10-07).
        guard !Task.isCancelled else { return }
        if step.models.contains(.recognizer) {
          await self?.startDeferredWordAlignment()
        }
      }
    }
  }

  /// Test seam: shorter residency timers.
  func useResidency(_ policy: ModelResidencyPolicy) {
    residency = policy
  }

  /// Releases `models`; false when a dictation still in flight deferred it.
  @discardableResult
  func releaseIdleModels(_ models: Set<ModelResidencyPolicy.Model>) async -> Bool {
    // Only work that is genuinely in flight may hold the models, and only
    // briefly: a dictation that starts cancels this timer, and one that
    // finishes leaves nothing behind. The guard used to also require an empty
    // speculation slot, which a finished dictation never emptied — so after
    // the first dictation the release stopped happening at all, for as long
    // as the App ran. A deferral now re-arms instead of dropping the release.
    guard sessionsAwaitingInsertion.isEmpty else {
      localDictationRuntimeLogger.notice("idle model release deferred, insertion in flight")
      scheduleIdleModelRelease()
      return false
    }
    if models.contains(.secondary) {
      // The aligner is one of them: sentences being timed wait for later.
      wordAlignmentTask?.cancel()
      await personalCleanup?.service.release()
      await finalASRWarmupRuntime?.releaseAlignment()
      // The general text model is loaded by the first 指令 and, until now,
      // was never let go: an idle App kept it resident indefinitely. It
      // reloads itself on the next use.
      await generalTextRuntime?.release()
    }
    if models.contains(.recognizer) {
      recognizerReleases += 1
      await finalASRWarmupRuntime?.releaseModels()
      recognizerResident = false
      // The next press must warm it again, however recent the last
      // dictation (review 2026-10-06: a release within 90 s of the last
      // activity left the next dictation to load it on the release path).
      lastFinalASRActivity = nil
    }
    QwenRuntimeMemory.trimNow()
    let usage = QwenRuntimeMemory.usage()
    let footprint = ProcessFootprint.current().map { ProcessFootprint.megabytes($0.bytes) } ?? -1
    let released = models.map(\.rawValue).sorted().joined(separator: ",")
    localDictationRuntimeLogger.notice(
      "idle models released models=\(released, privacy: .public) mlx_active_mb=\(usage.active / 1_048_576, privacy: .public) footprint_mb=\(footprint, privacy: .public)"
    )
    if models.contains(.secondary) { await compactIdleRecordings() }
    return true
  }

  func noteRecognizerResident() {
    recognizerResident = finalASRWarmupRuntime != nil
  }

  /// Once per launch, before the models are discovered: watch for memory
  /// pressure, remove the models the App no longer uses, and keep only the
  /// current and the previous version of each model. The App's discovery
  /// calls it (regression 2026-10-06: it was only in a discovery entry the
  /// App does not use, so neither ran).
  func startModelHousekeeping() async {
    startMemoryPressureWatch()
    guard !modelHousekeepingStarted else { return }
    modelHousekeepingStarted = true
    await removeRetiredModels()
    pruneUnreferencedModelVersions()
  }

  /// Removes the models in `retiredModelArtifactIDs` (ALIGNMENT 收1-4).
  func removeRetiredModels() async {
    do {
      let removed = try await modelManager.removeArtifacts(Self.retiredModelArtifactIDs)
      guard !removed.isEmpty else { return }
      localDictationRuntimeLogger.notice(
        "model store removed retired models=\(removed.joined(separator: ","), privacy: .public)")
    } catch {
      localDictationRuntimeLogger.error("model store could not remove a retired model")
    }
  }

  /// Whether this launch is watching for memory pressure.
  var watchesMemoryPressure: Bool { memoryPressureSource != nil }

  /// Memory pressure releases models whatever their timers say, with a
  /// buffer (`ModelResidencyPolicy.modelsToRelease(on:)`): a warning
  /// releases the others at once and the recognizer only if it lasts a
  /// minute; critical pressure releases everything. A dictation in flight
  /// finishes first and releases them as it ends
  /// (`endDictationBookkeeping`).
  func startMemoryPressureWatch() {
    guard memoryPressureSource == nil else { return }
    // One task handles the reports, in the order the system sent them
    // (review 2026-10-07: a task per report let a warning and the normal
    // right after it run in either order, and the App then stayed in
    // "warning": no sentences timed, the recognizer released a minute
    // later). A source's handler never runs concurrently with itself, so
    // the stream receives them in order.
    let (events, continuation) = AsyncStream.makeStream(
      of: ModelResidencyPolicy.MemoryPressure.self)
    memoryPressureEvents = continuation
    memoryPressureConsumer = Task { [weak self] in
      for await pressure in events {
        guard let self else { return }
        await self.handleMemoryPressure(pressure)
      }
    }
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
    source.setEventHandler { [weak source] in
      guard let event = source?.data else { return }
      continuation.yield(
        event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal)
    }
    memoryPressureSource = source
    source.resume()
  }

  /// A report as the system sends it, through the same queue
  /// (`startMemoryPressureWatch`); tests use it.
  func reportMemoryPressure(_ pressure: ModelResidencyPolicy.MemoryPressure) {
    memoryPressureEvents?.yield(pressure)
  }

  /// What a report from the system does (`ModelResidencyPolicy`).
  func handleMemoryPressure(_ pressure: ModelResidencyPolicy.MemoryPressure) async {
    memoryPressure = pressure
    localDictationRuntimeLogger.notice(
      "memory pressure: \(pressure.rawValue, privacy: .public)")
    switch pressure {
    case .normal:
      memoryPressureGeneration += 1
      recognizerPressureTask?.cancel()
      recognizerPressureTask = nil
      // The system has its memory back: nothing waits for a dictation to
      // end any more (review 2026-10-07: a recognizer release put off
      // until the end of a dictation still happened after normal, and the
      // next dictation started cold).
      pendingMemoryPressureRelease = []
      // Sentences that a release under pressure left untimed are timed
      // now, the aligner alone (`startDeferredWordAlignment` checks).
      if !recognizerResident { startDeferredWordAlignment() }
    case .warning:
      if recognizerPressureTask == nil {
        memoryPressureGeneration += 1
        let generation = memoryPressureGeneration
        let grace = residency.recognizerPressureGrace
        recognizerPressureTask = Task { [weak self] in
          try? await Task.sleep(for: grace)
          guard !Task.isCancelled else { return }
          await self?.memoryPressureWarningLasted(grace, generation: generation)
        }
      }
      await releaseForMemoryPressure(residency.modelsToRelease(on: .warning))
    case .critical:
      memoryPressureGeneration += 1
      recognizerPressureTask?.cancel()
      recognizerPressureTask = nil
      await releaseForMemoryPressure(residency.modelsToRelease(on: .critical))
    }
  }

  /// The warning whose grace timer is `generation` has lasted `duration`
  /// with no other report since. A timer from an earlier warning, already
  /// past its cancellation check when a later report came, does nothing
  /// (review 2026-10-07: it cleared the later warning's timer and released
  /// the recognizer at once).
  func memoryPressureWarningLasted(_ duration: Duration, generation: Int) async {
    guard generation == memoryPressureGeneration else { return }
    recognizerPressureTask = nil
    guard memoryPressure == .warning else { return }
    await releaseForMemoryPressure(residency.modelsToRelease(afterWarningLasting: duration))
  }

  /// Releases `models` (every model unless told otherwise) and whatever an
  /// earlier report left for later. A dictation that is recording (its
  /// speculation slot is taken) or waiting to be written finishes first;
  /// every way a dictation ends then applies the deferred release
  /// (`endDictationBookkeeping`).
  func releaseForMemoryPressure(
    _ models: Set<ModelResidencyPolicy.Model> = Set(ModelResidencyPolicy.Model.allCases)
  ) async {
    guard sessionsAwaitingInsertion.isEmpty, finalSpeculation == nil else {
      localDictationRuntimeLogger.notice("memory pressure: release after this dictation")
      pendingMemoryPressureRelease.formUnion(models)
      return
    }
    let releasing = models.union(pendingMemoryPressureRelease)
    pendingMemoryPressureRelease = []
    guard !releasing.isEmpty else { return }
    if releasing.contains(.recognizer) {
      idleModelReleaseTask?.cancel()
      idleModelReleaseTask = nil
    }
    let names = releasing.map(\.rawValue).sorted().joined(separator: ",")
    localDictationRuntimeLogger.notice("memory pressure: releasing \(names, privacy: .public)")
    await releaseIdleModels(releasing)
  }

  /// Keeps only the current and the previous version of each model, and
  /// drops what an interrupted install left behind (ALIGNMENT 收1-4).
  func pruneUnreferencedModelVersions() {
    let manager = modelManager
    let artifactIDs = Array(Set(modelRegistry.models.map(\.id))).sorted()
    Task(priority: .utility) {
      for artifactID in artifactIDs {
        if let removed = try? await manager.pruneUnreferencedVersions(artifactID: artifactID),
          !removed.isEmpty
        {
          localDictationRuntimeLogger.notice(
            "model store pruned artifact=\(artifactID, privacy: .public) folders=\(removed.count, privacy: .public)"
          )
        }
      }
    }
  }

  /// Called when a dictation starts: while the user speaks, make sure the
  /// final recognizer is resident and compiled, and the aligner is not
  /// (dictation's sentences are timed later, `DeferredWordAlignment`).
  func warmFinalASRIfIdle() {
    idleModelReleaseTask?.cancel()
    idleModelReleaseTask = nil
    // The cleanup model loads once, in the background, while the user
    // speaks, so an idle App does not hold it.
    if personalCleanupEnabled, let service = personalCleanup?.service {
      Task { await service.warmUp() }
    }
    // The recognizer and the aligner together are over the dictation
    // budget (3.58 GB of weights against 3.5 GB): any timing of sentences
    // stops, and the aligner leaves once the load or the window in hand is
    // done (the aligner checks for cancellation after loading).
    let stopping = wordAlignmentTask
    stopDeferredWordAlignment()
    guard let runtime = finalASRWarmupRuntime, finalASRWarmupTask == nil else { return }
    // Skipped only for a recognizer that is in memory and was used moments
    // ago. One that a timer or memory pressure released is always warmed,
    // so its reload runs while the user speaks rather than after release.
    if recognizerResident, let last = lastFinalASRActivity,
      ContinuousClock.now - last < Self.finalASRIdleWarmupThreshold
    {
      return
    }
    lastFinalASRActivity = ContinuousClock.now
    finalASRWarmupTask = Task { [weak self] in
      // The stopped pass releases the aligner before the recognizer loads,
      // so the two are not in memory together (review 2026-10-07).
      if let stopping { _ = await stopping.value }
      guard let releases = await self?.recognizerReleases else { return }
      await runtime.warmUp()
      await self?.finishFinalASRWarmup(releasesAtStart: releases)
    }
  }

  /// A release that happened while the warm-up ran leaves the recognizer
  /// out of memory; only a warm-up nobody released after marks it resident.
  func finishFinalASRWarmup(releasesAtStart: Int) {
    finalASRWarmupTask = nil
    guard recognizerReleases == releasesAtStart else { return }
    lastFinalASRActivity = ContinuousClock.now
    recognizerResident = true
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
