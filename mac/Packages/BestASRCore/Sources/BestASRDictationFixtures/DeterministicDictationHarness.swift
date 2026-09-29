import BestASRAudioJournal
import BestASRDictation
import BestASRDomain
import BestASRPersistence
import BestASRProcessing
import Foundation

public struct DeterministicDictationHarnessConfiguration: Sendable {
  public let sessionID: SessionID
  public let transcriptRevisionID: TranscriptRevisionID
  public let rawText: String
  public let polishedText: String
  public let dictionaryTerms: [String]

  public init(
    sessionID: SessionID = SessionID(
      UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    ),
    transcriptRevisionID: TranscriptRevisionID = TranscriptRevisionID(
      UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    ),
    rawText: String = "meet Alice at 10:30",
    polishedText: String = "Meet Alice at 10:30.",
    dictionaryTerms: [String] = ["Alice"]
  ) {
    self.sessionID = sessionID
    self.transcriptRevisionID = transcriptRevisionID
    self.rawText = rawText
    self.polishedText = polishedText
    self.dictionaryTerms = dictionaryTerms
  }
}

public struct DeterministicDictationHarnessResult: Sendable {
  public let snapshot: DictationSessionSnapshot
  public let audioRangeCount: Int
  public let transcripts: [DictationPersistedTranscriptRecord]
  public let derivations: [DictationDerivedTextRecord]
  public let insertionCallCount: Int
  public let insertionMutationCount: Int
  public let speakerScheduleCount: Int
  public let networkAttemptCount: Int

  public init(
    snapshot: DictationSessionSnapshot,
    audioRangeCount: Int,
    transcripts: [DictationPersistedTranscriptRecord],
    derivations: [DictationDerivedTextRecord],
    insertionCallCount: Int,
    insertionMutationCount: Int,
    speakerScheduleCount: Int,
    networkAttemptCount: Int
  ) {
    self.snapshot = snapshot
    self.audioRangeCount = audioRangeCount
    self.transcripts = transcripts
    self.derivations = derivations
    self.insertionCallCount = insertionCallCount
    self.insertionMutationCount = insertionMutationCount
    self.speakerScheduleCount = speakerScheduleCount
    self.networkAttemptCount = networkAttemptCount
  }
}

public enum DeterministicDictationHarness {
  public static func run(
    at rootURL: URL,
    configuration: DeterministicDictationHarnessConfiguration = .init()
  ) async throws -> DeterministicDictationHarnessResult {
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true
    )
    let clock = DeterministicDictationClock()
    let repository = try GRDBDictationStore(
      databaseURL: rootURL.appendingPathComponent("history.sqlite"),
      clock: clock
    )
    let journal = try ProductionAudioJournal(
      assetRootURL: rootURL.appendingPathComponent("assets")
    )
    let capture = DeterministicMicrophoneCaptureAdapter(
      chunks: fixtureChunks()
    )
    let state = DictationSessionActor(clock: clock)
    let target = try fixtureTarget()
    let captureCoordinator = DictationCaptureCoordinator(
      sessionActor: state,
      capture: capture,
      journal: journal,
      repository: repository
    )

    do {
      _ = try await captureCoordinator.start(
        sessionID: configuration.sessionID,
        target: target
      )
      let finalization = try await captureCoordinator.end()
      let transcript = DictationTranscriptResult(
        revisionID: configuration.transcriptRevisionID,
        segmentIDs: [
          UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
        ],
        text: configuration.rawText,
        modelArtifactID: "fixture-asr-v1"
      )
      let asr = DeterministicASRAdapter(outcomes: [.result(transcript)])
      let polish = DeterministicPolishAdapter(
        outcomes: [
          .result(
            DictationPolishResult(
              sourceRevisionID: transcript.revisionID,
              text: configuration.polishedText,
              disposition: .model,
              modelArtifactID: "fixture-polish-v1"
            )
          )
        ]
      )
      let insertion = DeterministicInsertionAdapter(
        target: target,
        outcomes: [
          .result(method: .accessibilityReplacement, inserted: true)
        ]
      )
      let speaker = DeterministicSpeakerScheduler()
      let network = DeterministicNetworkAttemptRecorder()
      let processing = DictationProcessingCoordinator(
        initialSnapshot: finalization.snapshot,
        repository: repository,
        asr: asr,
        polish: polish,
        insertion: insertion,
        speaker: speaker,
        clock: clock
      )
      let request = DictationProcessingRequest(
        sessionID: configuration.sessionID,
        inputRevision: 1,
        audio: finalization.audio,
        dictionaryTerms: configuration.dictionaryTerms,
        asrConfigHash: try fixtureDigest("a"),
        polishConfigHash: try fixtureDigest("b"),
        insertionKey: try DictationIdempotencyKey(
          "insert:\(configuration.sessionID.rawValue.uuidString):1"
        )
      )
      let outcome = try await processing.process(request)
      let transcripts = try await repository.loadTranscripts(
        sessionID: configuration.sessionID
      )
      let derivations = try await repository.loadDerivations(
        sessionID: configuration.sessionID
      )
      let result = DeterministicDictationHarnessResult(
        snapshot: outcome.snapshot,
        audioRangeCount: finalization.audio.count,
        transcripts: transcripts,
        derivations: derivations,
        insertionCallCount: await insertion.callCount(),
        insertionMutationCount: await insertion.mutationCount(),
        speakerScheduleCount: await speaker.uniqueScheduleCount(),
        networkAttemptCount: await network.attemptCount()
      )
      try await repository.checkpointAndClose()
      return result
    } catch {
      try? await repository.checkpointAndClose()
      throw error
    }
  }

  public static func fixtureTarget() throws -> DictationTargetSnapshot {
    DictationTargetSnapshot(
      processIdentifier: 42, bundleIdentifier: "com.example.fixture-editor", isSecure: false)
  }

  public static func fixtureChunks() -> [CapturedPCMChunk] {
    (0..<3).map { index in
      let samples = [Float(index), Float(index) + 0.25]
      return CapturedPCMChunk(
        sequence: UInt64(index),
        monotonicStartNanoseconds: UInt64(index) * 1_000_000,
        frameCount: UInt64(samples.count),
        sampleRateHertz: 48_000,
        channelCount: 1,
        encoding: .float32LittleEndian,
        interleaved: true,
        bytes: samples.withUnsafeBytes { Data($0) }
      )
    }
  }

  public static func fixtureDigest(_ character: Character) throws -> SHA256Digest {
    try SHA256Digest(String(repeating: String(character), count: 64))
  }
}
