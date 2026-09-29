import BestASRDictation
import BestASRDictationFixtures
import BestASRDomain
import BestASRInference
import BestASRPersistence
import BestASRProcessing
import Foundation

func processingUUID(_ value: UInt64) -> UUID {
  UUID(
    uuidString: "20000000-0000-4000-8000-\(String(format: "%012llx", value))"
  )!
}

func processingTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bestasr-processing-tests-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func processingDigest(_ character: Character) throws -> SHA256Digest {
  try SHA256Digest(String(repeating: String(character), count: 64))
}

func processingAudio(sessionID: SessionID) -> [AudioRangeInput] {
  [
    AudioRangeInput(
      sourceID: sessionID.rawValue,
      trackID: processingUUID(900),
      assetReference: "sessions/fixture/journal/chunks/chunk-0.pcm",
      contentDigest: String(repeating: "f", count: 64),
      monotonicStartNanoseconds: 100,
      monotonicEndNanoseconds: 1_000_100,
      sampleRateHertz: 48_000,
      channelCount: 1
    )
  ]
}

func makeRecognizingSnapshot(
  store: GRDBDictationStore,
  sessionID: SessionID,
  duplicateEnd: Bool = false,
  target: DictationTargetSnapshot? = try? DeterministicDictationHarness.fixtureTarget()
) async throws -> DictationSessionSnapshot {
  let actor = DictationSessionActor(clock: DeterministicDictationClock())
  let preparing = try await actor.handle(
    .start(
      sessionID: sessionID,
      target: target
    )
  )
  try await store.create(preparing)
  let recording = try await actor.handle(.preparationSucceeded)
  try await store.save(recording)
  let finalizing = try await actor.handle(.end)
  if duplicateEnd {
    let duplicate = try await actor.handle(.end)
    precondition(duplicate == finalizing)
  }
  try await store.save(finalizing)
  let recognizing = try await actor.handle(.journalSealed)
  try await store.save(recognizing)
  return recognizing
}

func processingTranscript(
  id: UInt64 = 10,
  text: String = "do not send 25% to Alice at 10:30"
) -> DictationTranscriptResult {
  DictationTranscriptResult(
    revisionID: TranscriptRevisionID(processingUUID(id)),
    segmentIDs: [processingUUID(id + 1)],
    text: text,
    modelArtifactID: "fixture-asr-v1"
  )
}

func processingRequest(sessionID: SessionID) throws -> DictationProcessingRequest {
  DictationProcessingRequest(
    sessionID: sessionID,
    inputRevision: 1,
    audio: processingAudio(sessionID: sessionID),
    dictionaryTerms: ["Alice"],
    dictionaryHints: [
      ASRDictionaryHint(
        canonicalForm: "Alice",
        spokenForms: ["Allis"]
      )
    ],
    asrConfigHash: try processingDigest("a"),
    polishConfigHash: try processingDigest("b"),
    insertionKey: try DictationIdempotencyKey(
      "insert:\(sessionID.rawValue.uuidString):1"
    )
  )
}

func processingPolish(
  transcript: DictationTranscriptResult,
  text: String = "Do not send 25% to Alice at 10:30."
) -> DictationPolishResult {
  DictationPolishResult(
    sourceRevisionID: transcript.revisionID,
    text: text,
    disposition: .model,
    modelArtifactID: "fixture-polish-v1"
  )
}

enum ProcessingRepositoryFixtureError: Error {
  case simulatedAcknowledgementLoss
}

actor AcknowledgementLossRepository: DictationProcessingRepositoryPort {
  private let store: GRDBDictationStore
  private var shouldLoseRecognitionAcknowledgement = true

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
  func commitRecognition(
    _ commit: DictationRecognitionCommit
  ) async throws {
    try await store.commitRecognition(commit)
    if shouldLoseRecognitionAcknowledgement {
      shouldLoseRecognitionAcknowledgement = false
      throw ProcessingRepositoryFixtureError.simulatedAcknowledgementLoss
    }
  }
  func commitPolish(_ commit: DictationPolishCommit) async throws {
    try await store.commitPolish(commit)
  }
  func commitInsertion(_ commit: DictationInsertionCommit) async throws {
    try await store.commitInsertion(commit)
  }
}
