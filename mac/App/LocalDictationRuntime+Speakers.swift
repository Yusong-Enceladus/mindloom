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

// Speakers: moved out of LocalDictationRuntime.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension LocalDictationRuntime {
  func discoverInstalledSpeaker() async -> Bool {
    do {
      try await configureSpeaker()
      return true
    } catch {
      speakerRuntime = nil
      return false
    }
  }

  func downloadRecommendedSpeakerModel(
    onState: @escaping ModelDistributionCoordinator.StateHandler
  ) async throws {
    _ = try await modelDistribution.install(
      artifactID: FluidSpeakerPinnedArtifact.artifactID,
      healthCheck: FluidSpeakerModelHealthCheck(),
      onState: onState
    )
    try await configureSpeaker()
    try await rebuildSpeakerIndexForCurrentModel()
  }

  func installSpeakerModel(from sourceDirectory: URL) async throws {
    _ = try await modelManager.activate(
      artifactID: FluidSpeakerPinnedArtifact.artifactID,
      version: FluidSpeakerPinnedArtifact.sourceRevision,
      from: sourceDirectory,
      healthCheck: FluidSpeakerModelHealthCheck()
    )
    try await configureSpeaker()
    try await rebuildSpeakerIndexForCurrentModel()
  }

  func reevaluateAutomaticPersonMatches() async throws -> Int {
    try await rebuildSpeakerIndexForCurrentModel()
  }

  @discardableResult
  func rebuildSpeakerIndexForCurrentModel() async throws -> Int {
    let count = try await repository.requeueAutomaticSpeakerJobs(
      modelArtifactKey: FluidSpeakerPinnedArtifact.artifactID,
      embeddingSpaceID: FluidSpeakerPinnedArtifact.embeddingSpaceID,
      configHash: speakerConfigHash
    )
    beginSpeakerDrainIfReady()
    return count
  }

  func assignLiveSpeakerLabel(
    sessionID: SessionID,
    vector: [Float],
    weight: Double
  ) -> String {
    var centroids = liveSpeakerCentroids[sessionID] ?? []
    let best = centroids.indices.map { index in
      (index, Self.cosineSimilarity(vector, centroids[index].vector))
    }.max { $0.1 < $1.1 }
    if let best, best.1 >= 0.72 {
      let previousWeight = centroids[best.0].weight
      let totalWeight = previousWeight + weight
      if centroids[best.0].vector.count == vector.count, totalWeight > 0 {
        centroids[best.0].vector = zip(centroids[best.0].vector, vector).map {
          Float((Double($0.0) * previousWeight + Double($0.1) * weight) / totalWeight)
        }
        centroids[best.0].weight = totalWeight
      }
      liveSpeakerCentroids[sessionID] = centroids
      return centroids[best.0].label
    }
    let label = Self.liveSpeakerLabel(index: centroids.count)
    centroids.append(LiveSpeakerCentroid(label: label, vector: vector, weight: weight))
    liveSpeakerCentroids[sessionID] = centroids
    return label
  }

  static func liveSpeakerLabel(index: Int) -> String {
    var value = max(0, index)
    var label = ""
    repeat {
      label = String(UnicodeScalar(65 + value % 26)!) + label
      value = value / 26 - 1
    } while value >= 0
    return label
  }

  /// Finds the personal cleanup model, if one was built on this Mac. It is
  /// trained on the user's own dictations, so it is never downloaded or
  /// shipped and has no registry entry: the directory is the whole contract.
  /// Whether a personal cleanup model is installed, for Settings.
  func hasPersonalCleanupModel() -> Bool { personalCleanup != nil }

  func configurePersonalCleanup() {
    guard
      let directory = PersonalDictationCleanupModel.installedDirectory(
        applicationSupport: applicationRoot)
    else {
      personalCleanup = nil
      return
    }
    personalCleanup = PersonalDictationCleanupAdapter(
      service: PersonalDictationCleanupService(
        generator: MLXLocalTextRuntime(verifiedModelDirectory: directory)),
      revision: PersonalDictationCleanupModel.revision(of: directory)
    )
    localDictationRuntimeLogger.notice("personal cleanup model available")
  }

  /// Text written by this model is tied to the model and its guard, so a
  /// later model or limit re-derives history instead of silently reusing it.
  func personalCleanupConfigHash(
    _ revision: String
  ) -> BestASRDomain.SHA256Digest {
    (try? BestASRDomain.SHA256Digest(
      Self.sha256(
        "\(revision)|guard:\(DictationCleanupGuard.introducedCharacterLimit)"
          + "|\(DictationTextCleanup.revision)")))
      ?? deterministicPolishConfigHash
  }

  func configureSpeaker() async throws {
    speakerRuntime = try await FluidSpeakerRuntimeFactory.make(
      modelManager: modelManager,
      audioAssetRoot: journal.assetRootURL
    )
    beginSpeakerDrainIfReady()
  }

  func beginSpeakerDrainIfReady() {
    guard speakerRuntime != nil, speakerWorkerTask == nil else { return }
    speakerWorkerTask = Task { [weak self] in
      await self?.drainSpeakerJobs()
    }
  }

  func drainSpeakerJobs() async {
    defer { speakerWorkerTask = nil }
    guard let speakerRuntime else { return }
    var attemptedJobIDs = Set<DurableJobID>()
    while !Task.isCancelled {
      let input: SpeakerFinalJobInputRecord
      do {
        guard
          let claimed = try await repository.claimNextSpeakerFinalJob(
            workerID: speakerWorkerID,
            excludingJobIDs: attemptedJobIDs
          )
        else { return }
        input = claimed
        attemptedJobIDs.insert(claimed.job.id)
      } catch {
        return
      }
      do {
        try await processSpeakerJob(input, runtime: speakerRuntime)
      } catch {
        let failure = Self.speakerJobFailure(for: error)
        localDictationRuntimeLogger.error(
          "speaker final job failed: job=\(input.job.id.rawValue.uuidString, privacy: .public) category=\(failure.category.rawValue, privacy: .public) code=\(Self.jobDiagnosticCode(for: error), privacy: .public)"
        )
        try? await repository.failSpeakerFinalJob(
          jobID: input.job.id,
          workerID: speakerWorkerID,
          category: failure.category,
          retryable: failure.retryable && input.job.retryCount < 2
        )
        // This job is excluded for the remainder of the current drain, so
        // continuing cannot create a tight retry loop. Other sessions still
        // receive one fair attempt; this job waits for the next explicit wake
        // or launch before another retry.
        continue
      }
    }
  }

  func processSpeakerJob(
    _ input: SpeakerFinalJobInputRecord,
    runtime: FluidSpeakerRuntime
  ) async throws {
    guard
      input.modelArtifactKey == FluidSpeakerPinnedArtifact.artifactID,
      input.embeddingSpaceID == FluidSpeakerPinnedArtifact.embeddingSpaceID
    else { throw LocalDictationRuntimeError.speakerEvidenceUnavailable }
    let prepared = try await journal.prepareInferenceAudio(
      sessionID: input.session.id,
      sourceAudio: input.audio
    )
    do {
      try await processSpeakerJob(
        input,
        runtime: runtime,
        prepared: prepared
      )
      await journal.discardInferenceAudio(
        sessionID: input.session.id,
        preparedAudio: prepared
      )
    } catch {
      await journal.discardInferenceAudio(
        sessionID: input.session.id,
        preparedAudio: prepared
      )
      throw error
    }
  }

  func processSpeakerJob(
    _ input: SpeakerFinalJobInputRecord,
    runtime: FluidSpeakerRuntime,
    prepared: [AudioRangeInput]
  ) async throws {
    let localSelfTrackIDs: Set<UUID> =
      input.session.inputMode == .systemAudio
      ? Set(
        input.tracks.filter { $0.role == .microphoneLocal }.map {
          $0.id.rawValue
        }
      )
      : []
    if !localSelfTrackIDs.isEmpty {
      try await repository.ensureLocalSelfPerson(personID: localSelfPersonID)
    }
    let trackIDs = Set(prepared.map(\.trackID)).sorted {
      $0.uuidString < $1.uuidString
    }
    let people =
      speakerMemoryEnabled
      ? try await repository.loadPersonEmbeddings(
        embeddingSpaceID: input.embeddingSpaceID
      )
      : []
    let rejectedMatches =
      speakerMemoryEnabled
      ? try await repository.loadRejectedPersonMatches(
        embeddingSpaceID: input.embeddingSpaceID
      )
      : []
    var clusters: [LocalSpeakerClusterWork] = []
    for trackID in trackIDs {
      let ranges = prepared.filter { $0.trackID == trackID }.sorted {
        $0.monotonicStartNanoseconds < $1.monotonicStartNanoseconds
      }
      let analysis = try await runtime.analyze(
        DiarizationRequest(
          metadata: InferenceRequestMetadata(
            jobID: input.job.id.rawValue,
            inputRevision: input.job.inputRevision.value,
            modelArtifactID: FluidSpeakerPinnedArtifact.artifactID,
            configHash: input.job.configHash.value
          ),
          audio: ranges,
          expectedSpeakerRange: nil
        )
      )
      for evidence in analysis.clusters {
        let key = "\(trackID.uuidString.lowercased()):\(evidence.speakerClusterID)"
        let turns = analysis.diarization.turns.filter {
          $0.speakerClusterID == evidence.speakerClusterID
        }
        guard !turns.isEmpty else { continue }
        clusters.append(
          LocalSpeakerClusterWork(
            key: key,
            trackID: TrackID(trackID),
            turns: turns,
            evidence: evidence,
            personMatch: localSelfTrackIDs.contains(trackID)
              ? try PersonMatchEvidence(
                personID: localSelfPersonID,
                confidence: Confidence(1)
              )
              : Self.bestPersonMatch(
                vector: evidence.vector,
                candidates: people,
                rejectedMatches: rejectedMatches
              )
          )
        )
      }
    }
    guard !clusters.isEmpty else {
      throw LocalDictationRuntimeError.speakerEvidenceUnavailable
    }
    clusters.sort { $0.key < $1.key }
    let revision = try Revision(input.job.inputRevision.value)
    let routingClusters = try clusters.enumerated().map { index, cluster in
      let speakerID = SessionSpeakerID(
        Self.deterministicUUID([
          "session-speaker-v2",
          input.session.id.rawValue.uuidString.lowercased(),
          cluster.key,
        ])
      )
      let quality = try Confidence(max(0, min(1, cluster.evidence.signalQuality)))
      let turns = cluster.turns.map { turn in
        SpeakerTurnEvidence(
          occurrenceID: SpeakerOccurrenceID(
            Self.deterministicUUID([
              "speaker-occurrence-v2",
              input.session.id.rawValue.uuidString.lowercased(),
              cluster.key,
              String(turn.monotonicStartNanoseconds),
              String(turn.monotonicEndNanoseconds),
            ])
          ),
          trackIDs: [cluster.trackID],
          monotonicStartNanoseconds: turn.monotonicStartNanoseconds,
          monotonicEndNanoseconds: turn.monotonicEndNanoseconds,
          overlapsAnotherSpeaker: turn.overlapsAnotherSpeaker,
          isBackgroundSpeech: false,
          signalQuality: quality,
          personMatch: cluster.personMatch
        )
      }
      return SpeakerClusterEvidence(
        sessionSpeakerID: speakerID,
        stableOrdinal: UInt32(index + 1),
        turns: turns
      )
    }
    let routing = try UnifiedSpeakerRouter.route(
      SpeakerRoutingRequest(
        session: input.session,
        tracks: input.tracks,
        evidenceRevision: revision,
        clusters: routingClusters
      ),
      policy: try SpeakerRoutingPolicy.local()
    )
    let embeddings: [StoredSpeakerEmbedding] =
      if speakerMemoryEnabled {
        try zip(routingClusters, clusters).map { routed, cluster in
          StoredSpeakerEmbedding(
            sessionSpeakerID: routed.sessionSpeakerID,
            revision: revision,
            embeddingSpaceID: input.embeddingSpaceID,
            vector: cluster.evidence.vector,
            speechDurationNanoseconds: cluster.evidence.speechDurationNanoseconds,
            signalQuality: try Confidence(
              max(0, min(1, cluster.evidence.signalQuality))
            ),
            modelArtifactKey: input.modelArtifactKey
          )
        }
      } else {
        []
      }
    let sourceContexts =
      input.session.inputMode == .systemAudio
      ? ((try? await repository.loadSourceContexts(
        sessionID: input.session.id
      )) ?? [])
      : []
    let platformNameEvidence = Self.platformSpeakerNameEvidence(
      sessionID: input.session.id,
      revision: revision,
      tracks: input.tracks,
      occurrences: routing.occurrences,
      contexts: sourceContexts
    )
    try await repository.completeSpeakerFinalJob(
      jobID: input.job.id,
      workerID: speakerWorkerID,
      commit: SpeakerFinalPersistenceCommit(
        sessionID: input.session.id,
        sessionSpeakers: routing.sessionSpeakers,
        occurrences: routing.occurrences,
        embeddings: embeddings,
        platformNameEvidence: platformNameEvidence
      )
    )
  }

  static func platformSpeakerNameEvidence(
    sessionID: SessionID,
    revision: Revision,
    tracks: [SourceTrack],
    occurrences: [SpeakerOccurrence],
    contexts: [SourceContextSnapshot]
  ) -> [PlatformSpeakerNameEvidence] {
    let remoteTrackIDs = Set(
      tracks.filter { $0.role == .systemRemote }.map(\.id)
    )
    guard !remoteTrackIDs.isEmpty else { return [] }
    let orderedContexts =
      contexts
      .filter { $0.sessionID == sessionID }
      .sorted {
        if $0.monotonicNanoseconds == $1.monotonicNanoseconds {
          return $0.id.uuidString < $1.id.uuidString
        }
        return $0.monotonicNanoseconds < $1.monotonicNanoseconds
      }
    guard !orderedContexts.isEmpty else { return [] }

    struct Interval {
      let contextID: UUID
      let displayName: String
      let normalizedName: String
      let start: UInt64
      let end: UInt64
    }
    var intervals: [Interval] = []
    for index in orderedContexts.indices {
      let context = orderedContexts[index]
      guard context.reliability == .reliable,
        let displayName = normalizedPlatformDisplayName(
          context.activeSpeakerDisplayName
        )
      else { continue }
      let maximumEnd = context.monotonicNanoseconds.addingReportingOverflow(
        4_500_000_000
      )
      let cappedEnd = maximumEnd.overflow ? UInt64.max : maximumEnd.partialValue
      let nextStart =
        index + 1 < orderedContexts.count
        ? orderedContexts[index + 1].monotonicNanoseconds
        : cappedEnd
      let end = min(cappedEnd, nextStart)
      guard end > context.monotonicNanoseconds else { continue }
      intervals.append(
        Interval(
          contextID: context.id,
          displayName: displayName,
          normalizedName: normalizedPlatformName(displayName),
          start: context.monotonicNanoseconds,
          end: end
        )
      )
    }
    guard !intervals.isEmpty else { return [] }

    var matched: [LocalPlatformOccurrenceName] = []
    for occurrence in occurrences where !occurrence.overlapsAnotherSpeaker {
      guard occurrence.trackIDs.contains(where: remoteTrackIDs.contains),
        occurrence.monotonicEndNanoseconds
          > occurrence.monotonicStartNanoseconds
      else { continue }
      let duration =
        occurrence.monotonicEndNanoseconds
        - occurrence.monotonicStartNanoseconds
      guard duration >= 500_000_000 else { continue }
      var alignedByName: [String: UInt64] = [:]
      var displayByName: [String: String] = [:]
      var contextIDsByName: [String: Set<UUID>] = [:]
      for interval in intervals {
        let start = max(occurrence.monotonicStartNanoseconds, interval.start)
        let end = min(occurrence.monotonicEndNanoseconds, interval.end)
        guard end > start else { continue }
        let overlap = end - start
        alignedByName[interval.normalizedName, default: 0] += overlap
        displayByName[interval.normalizedName] = interval.displayName
        contextIDsByName[interval.normalizedName, default: []]
          .insert(interval.contextID)
      }
      guard alignedByName.count == 1,
        let (normalizedName, aligned) = alignedByName.first,
        aligned >= 500_000_000,
        Double(aligned) / Double(duration) >= 0.60,
        let displayName = displayByName[normalizedName]
      else { continue }
      matched.append(
        LocalPlatformOccurrenceName(
          sessionSpeakerID: occurrence.sessionSpeakerID,
          occurrenceID: occurrence.id,
          displayName: displayName,
          normalizedName: normalizedName,
          sourceContextIDs: Array(
            contextIDsByName[normalizedName] ?? []
          ).sorted { $0.uuidString < $1.uuidString },
          alignedSpeechNanoseconds: aligned
        )
      )
    }

    return Dictionary(grouping: matched, by: \.sessionSpeakerID)
      .compactMap { speakerID, values in
        let names = Set(values.map(\.normalizedName))
        let aligned = values.reduce(UInt64(0)) {
          $0.addingReportingOverflow($1.alignedSpeechNanoseconds).overflow
            ? UInt64.max
            : $0 + $1.alignedSpeechNanoseconds
        }
        guard names.count == 1, aligned >= 1_000_000_000,
          let first = values.first
        else { return nil }
        let occurrenceIDs = Array(Set(values.map(\.occurrenceID))).sorted {
          $0.rawValue.uuidString < $1.rawValue.uuidString
        }
        let contextIDs = Array(Set(values.flatMap(\.sourceContextIDs))).sorted {
          $0.uuidString < $1.uuidString
        }
        return PlatformSpeakerNameEvidence(
          id: deterministicUUID([
            "platform-speaker-name-evidence-v1",
            sessionID.rawValue.uuidString.lowercased(),
            speakerID.rawValue.uuidString.lowercased(),
            String(revision.value),
            first.normalizedName,
          ]),
          sessionID: sessionID,
          sessionSpeakerID: speakerID,
          revision: revision,
          displayName: first.displayName,
          occurrenceIDs: occurrenceIDs,
          sourceContextIDs: contextIDs,
          alignedSpeechNanoseconds: aligned
        )
      }.sorted {
        $0.sessionSpeakerID.rawValue.uuidString
          < $1.sessionSpeakerID.rawValue.uuidString
      }
  }

  static func bestPersonMatch(
    vector: [Float],
    candidates: [StoredPersonEmbedding],
    rejectedMatches: [StoredRejectedPersonMatch]
  ) -> PersonMatchEvidence? {
    var best: (PersonID, Double)?
    for candidate in candidates where candidate.vector.count == vector.count {
      let similarity = cosineSimilarity(vector, candidate.vector)
      let isExplicitlyRejected = rejectedMatches.contains { rejection in
        rejection.candidatePersonID == candidate.personID
          && rejection.vector.count == vector.count
          && cosineSimilarity(vector, rejection.vector) >= 0.90
      }
      guard !isExplicitlyRejected else { continue }
      if best == nil || similarity > best!.1 {
        best = (candidate.personID, similarity)
      }
    }
    guard let best else { return nil }
    return try? PersonMatchEvidence(
      personID: best.0,
      confidence: Confidence(max(0, min(1, best.1)))
    )
  }

  static func speakerJobFailure(
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
    if let journal = error as? ProductionAudioJournalError {
      switch journal {
      case .fileOperation:
        return (.transientWorker, true)
      default:
        return (.corruptInput, false)
      }
    }
    if error is LocalDictationRuntimeError {
      return (.corruptInput, false)
    }
    return (.transientWorker, true)
  }
}
