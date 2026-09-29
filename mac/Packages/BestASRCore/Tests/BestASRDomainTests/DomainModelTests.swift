import Foundation
import XCTest

@testable import BestASRDomain

final class DomainModelTests: XCTestCase {
  func testFourInputModesUseOnePersonGraphAndRoundTrip() throws {
    let globalPersonID = PersonID(uuid(42))

    // The four audio entry points; a pasted item (`userItem`) has no track.
    for (index, mode) in Self.audioModes.enumerated() {
      let snapshot = try makeSnapshot(
        mode: mode,
        seed: UInt64(index + 1),
        globalPersonID: globalPersonID
      )
      let data = try encoder.encode(snapshot)
      let decoded = try decoder.decode(DomainSnapshot.self, from: data)

      XCTAssertEqual(decoded, snapshot)
      XCTAssertEqual(decoded.sessions.first?.inputMode, mode)
      XCTAssertEqual(decoded.sessionSpeakers.count, 1)
      XCTAssertEqual(decoded.speakerOccurrences.count, 1)
      XCTAssertEqual(decoded.persons.map(\.id), [globalPersonID])
      XCTAssertEqual(
        decoded.speakerOccurrences.first?.association.personID,
        globalPersonID
      )

      let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
      XCTAssertFalse(encoded.contains("rowID"))
      XCTAssertFalse(encoded.contains("DictationPerson"))
      XCTAssertFalse(encoded.contains("/Users/"))
    }
  }

  func testPropertyRoundTripsDeterministicSnapshots() throws {
    let globalPersonID = PersonID(uuid(42))
    var idempotencyKeys = Set<String>()

    for seed in UInt64(1)...64 {
      let modes = Self.audioModes
      let mode = modes[Int(seed - 1) % modes.count]
      let snapshot = try makeSnapshot(
        mode: mode,
        seed: seed,
        globalPersonID: globalPersonID
      )
      let data = try encoder.encode(snapshot)
      XCTAssertEqual(
        try decoder.decode(DomainSnapshot.self, from: data),
        snapshot,
        "round-trip failed for seed \(seed)"
      )
      let key = try XCTUnwrap(snapshot.durableJobs.first?.idempotencyKey)
      XCTAssertTrue(idempotencyKeys.insert(key).inserted)
    }
  }

  func testPortableAssetReferencesRejectMachineLocalIdentity() throws {
    XCTAssertThrowsError(
      try PortableAssetReference(relativePath: "/Users/fixture/audio.caf")
    )
    XCTAssertThrowsError(
      try PortableAssetReference(relativePath: "../outside/audio.caf")
    )
    XCTAssertThrowsError(
      try PortableAssetReference(relativePath: "file://machine/audio.caf")
    )
    XCTAssertNoThrow(
      try PortableAssetReference(relativePath: "sessions/fixture/source.caf")
    )
    XCTAssertThrowsError(
      try decoder.decode(SessionID.self, from: Data("1".utf8))
    )
  }

  func testPersonAssociationRejectsInvalidConfidenceSemantics() throws {
    let personID = PersonID(uuid(42))
    let revision = try Revision(1)

    XCTAssertThrowsError(
      try PersonAssociation(
        status: .unknown,
        personID: personID,
        confidence: nil,
        evidenceRevision: revision
      )
    )
    XCTAssertThrowsError(
      try PersonAssociation(
        status: .candidate,
        personID: personID,
        confidence: nil,
        evidenceRevision: revision
      )
    )
    XCTAssertNoThrow(
      try PersonAssociation(
        status: .candidate,
        personID: personID,
        confidence: Confidence(0.65),
        evidenceRevision: revision
      )
    )
  }

  func testEveryPersonCorrectionPayloadIsVersionedAndReversible() throws {
    let personA = PersonID(uuid(42))
    let personB = PersonID(uuid(43))
    let occurrenceA = SpeakerOccurrenceID(uuid(44))
    let occurrenceB = SpeakerOccurrenceID(uuid(45))
    let reverseTarget = PersonCorrectionID(uuid(46))
    let payloads: [PersonCorrectionPayload] = [
      .confirm(occurrenceID: occurrenceA, personID: personA),
      .merge(primaryID: personA, mergedID: personB),
      .reject(occurrenceID: occurrenceA, candidatePersonID: personB),
      .rename(personID: personA, displayName: "Synthetic Person"),
      .split(
        sourcePersonID: personA,
        newPersonID: personB,
        occurrenceIDs: [occurrenceA, occurrenceB]
      ),
    ]
    let operations = try payloads.enumerated().map { index, payload in
      PersonCorrectionOperation(
        id: PersonCorrectionID(uuid(UInt64(100 + index))),
        revision: try Revision(UInt64(index + 1)),
        occurredAt: fixedDate,
        actor: .user,
        payload: payload,
        reversesOperationID: reverseTarget
      )
    }

    let data = try encoder.encode(operations)
    XCTAssertEqual(
      try decoder.decode([PersonCorrectionOperation].self, from: data),
      operations
    )
    XCTAssertTrue(operations.allSatisfy { $0.reversesOperationID == reverseTarget })
  }

  private func makeSnapshot(
    mode: SessionInputMode,
    seed: UInt64,
    globalPersonID: PersonID
  ) throws -> DomainSnapshot {
    let base = seed * 100
    let revision = try Revision(seed)
    let sessionID = SessionID(uuid(base + 1))
    let trackID = TrackID(uuid(base + 2))
    let modelArtifactID = ModelArtifactID(uuid(base + 3))
    let speakerID = SessionSpeakerID(uuid(base + 4))
    let occurrenceID = SpeakerOccurrenceID(uuid(base + 5))
    let correctionID = PersonCorrectionID(uuid(base + 6))
    let changeID = ChangeID(uuid(base + 7))
    let asset = try PortableAssetReference(
      relativePath: "sessions/s\(seed)/source.caf"
    )
    let contentDigest = try digest(seed)
    let configHash = try digest(seed + 1_000)
    let session = Session(
      id: sessionID,
      revision: revision,
      inputMode: mode,
      state: .completed,
      createdAt: fixedDate,
      updatedAt: fixedDate
    )
    let track = SourceTrack(
      id: trackID,
      sessionID: sessionID,
      revision: revision,
      role: trackRole(for: mode),
      assetReference: asset,
      sampleRateHertz: 48_000,
      channelCount: 1
    )
    let chunk = AudioChunk(
      id: ChunkID(uuid(base + 8)),
      sessionID: sessionID,
      trackID: trackID,
      revision: revision,
      sequence: seed,
      monotonicStartNanoseconds: seed * 1_000_000,
      frameCount: 48_000,
      contentDigest: contentDigest,
      assetReference: asset
    )
    let timelineEvent = TimelineEvent(
      id: TimelineEventID(uuid(base + 9)),
      sessionID: sessionID,
      revision: revision,
      kind: .pause,
      monotonicNanoseconds: seed * 1_000_000,
      durationNanoseconds: 500_000
    )
    let transcriptRevision = TranscriptRevision(
      id: TranscriptRevisionID(uuid(base + 10)),
      sessionID: sessionID,
      revision: revision,
      parentID: nil,
      kind: .final,
      content: "synthetic fixture \(seed)",
      modelArtifactID: modelArtifactID,
      configHash: configHash,
      createdAt: fixedDate
    )
    let durableJob = DurableJob(
      id: DurableJobID(uuid(base + 11)),
      revision: revision,
      kind: .speakerFinal,
      state: .succeeded,
      inputRevision: revision,
      modelArtifactID: modelArtifactID,
      configHash: configHash,
      retryCount: 0,
      errorCategory: .none,
      leaseOwner: nil,
      leaseExpiresAt: nil
    )
    let modelArtifact = ModelArtifact(
      id: modelArtifactID,
      revision: revision,
      registryKey: "fixture-model",
      version: "1.0.0",
      capability: .asr,
      digest: contentDigest,
      directoryReference: PortableAssetReference(contentDigest: contentDigest),
      licenseIdentifier: "fixture-license",
      state: .active
    )
    let sessionSpeaker = SessionSpeaker(
      id: speakerID,
      sessionID: sessionID,
      revision: revision,
      stableOrdinal: 1
    )
    let association = try PersonAssociation(
      status: .userConfirmed,
      personID: globalPersonID,
      confidence: nil,
      evidenceRevision: revision
    )
    let occurrence = SpeakerOccurrence(
      id: occurrenceID,
      sessionID: sessionID,
      sessionSpeakerID: speakerID,
      revision: revision,
      trackIDs: [trackID],
      monotonicStartNanoseconds: seed * 1_000_000,
      monotonicEndNanoseconds: seed * 1_000_000 + 1_000_000,
      overlapsAnotherSpeaker: false,
      association: association
    )
    let person = Person(
      id: globalPersonID,
      revision: revision,
      displayName: nil,
      aliases: [],
      createdAt: fixedDate,
      updatedAt: fixedDate
    )
    let correction = PersonCorrectionOperation(
      id: correctionID,
      revision: revision,
      occurredAt: fixedDate,
      actor: .user,
      payload: .confirm(occurrenceID: occurrenceID, personID: globalPersonID),
      reversesOperationID: nil
    )
    let change = ChangeLogEntry(
      id: changeID,
      entity: DomainEntityReference(
        kind: .person,
        stableID: globalPersonID.rawValue
      ),
      revision: revision,
      occurredAt: fixedDate,
      originDeviceID: uuid(base + 12),
      operation: .personCorrection,
      payloadDigest: contentDigest,
      personCorrection: correction
    )
    let tombstone = Tombstone(
      id: TombstoneID(uuid(base + 13)),
      entity: DomainEntityReference(
        kind: .durableJob,
        stableID: durableJob.id.rawValue
      ),
      revision: revision,
      deletedAt: fixedDate,
      deletionScope: .metadataOnly,
      changeID: changeID
    )
    return DomainSnapshot(
      sessions: [session],
      tracks: [track],
      chunks: [chunk],
      timelineEvents: [timelineEvent],
      transcriptRevisions: [transcriptRevision],
      durableJobs: [durableJob],
      modelArtifacts: [modelArtifact],
      sessionSpeakers: [sessionSpeaker],
      speakerOccurrences: [occurrence],
      persons: [person],
      personCorrections: [correction],
      changeLog: [change],
      tombstones: [tombstone]
    )
  }

  private static let audioModes = SessionInputMode.allCases.filter { $0 != .userItem }

  private func trackRole(for mode: SessionInputMode) -> SourceTrackRole {
    switch mode {
    case .userItem:
      preconditionFailure("a pasted or dragged item has no audio track")
    case .dictation:
      return .microphoneLocal
    case .roomMicrophone:
      return .roomMicrophone
    case .systemAudio:
      return .systemRemote
    case .importedMedia:
      return .importedSource
    }
  }

  private func digest(_ value: UInt64) throws -> SHA256Digest {
    try SHA256Digest(String(format: "%064llx", value))
  }

  private func uuid(_ value: UInt64) -> UUID {
    UUID(
      uuidString: String(
        format: "00000000-0000-4000-8000-%012llx",
        value
      )
    )!
  }

  private var fixedDate: Date {
    Date(timeIntervalSince1970: 1_753_286_400)
  }

  private var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private var decoder: JSONDecoder {
    JSONDecoder()
  }
}
