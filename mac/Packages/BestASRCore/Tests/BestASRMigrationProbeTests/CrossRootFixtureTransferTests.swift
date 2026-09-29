import BestASRDomain
import Foundation
import XCTest

@testable import BestASRMigrationProbe

final class CrossRootFixtureTransferTests: XCTestCase {
  func testRoundTripAcrossDifferentRootsPreservesBytesAndRelationships() throws {
    let fixtureRoot = try makeFixtureRoot()
    let sourceRoot = fixtureRoot.appendingPathComponent("root-a", isDirectory: true)
    let packageRoot = fixtureRoot.appendingPathComponent("portable", isDirectory: true)
    let destinationRoot = fixtureRoot.appendingPathComponent("root-b", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sourceRoot,
      withIntermediateDirectories: true
    )
    let sourceBytes = Data("synthetic source audio bytes".utf8)
    let modelBytes = Data("synthetic model artifact bytes".utf8)
    let modelDigest = try SHA256Digest(
      CrossRootFixtureTransfer.sha256(modelBytes)
    )
    let relativeReference = try PortableAssetReference(
      relativePath: "sessions/fixture/source.caf"
    )
    let contentReference = PortableAssetReference(contentDigest: modelDigest)
    try write(
      sourceBytes,
      to: CrossRootFixtureTransfer.resolvedURL(
        for: relativeReference,
        root: sourceRoot
      )
    )
    try write(
      modelBytes,
      to: CrossRootFixtureTransfer.resolvedURL(
        for: contentReference,
        root: sourceRoot
      )
    )
    let snapshot = try makeSnapshot(
      audioReference: relativeReference,
      modelReference: contentReference,
      modelDigest: modelDigest
    )

    let manifest = try CrossRootFixtureTransfer.exportFixture(
      snapshot: snapshot,
      sourceRoot: sourceRoot,
      packageRoot: packageRoot
    )
    let imported = try CrossRootFixtureTransfer.importFixture(
      packageRoot: packageRoot,
      destinationRoot: destinationRoot
    )

    XCTAssertNotEqual(sourceRoot.path, destinationRoot.path)
    XCTAssertEqual(imported, snapshot)
    XCTAssertEqual(imported.sessions.map(\.id), snapshot.sessions.map(\.id))
    XCTAssertEqual(imported.tracks.map(\.sessionID), snapshot.tracks.map(\.sessionID))
    XCTAssertEqual(
      imported.speakerOccurrences.map(\.association.personID),
      snapshot.speakerOccurrences.map(\.association.personID)
    )
    XCTAssertEqual(manifest.assets.count, 2)
    XCTAssertEqual(
      try Data(
        contentsOf: CrossRootFixtureTransfer.resolvedURL(
          for: relativeReference,
          root: destinationRoot
        )
      ),
      sourceBytes
    )
    XCTAssertEqual(
      try Data(
        contentsOf: CrossRootFixtureTransfer.resolvedURL(
          for: contentReference,
          root: destinationRoot
        )
      ),
      modelBytes
    )
    XCTAssertEqual(
      try Data(
        contentsOf: CrossRootFixtureTransfer.resolvedURL(
          for: relativeReference,
          root: sourceRoot
        )
      ),
      sourceBytes
    )

    let manifestText = try String(
      contentsOf: packageRoot.appendingPathComponent("manifest.json"),
      encoding: .utf8
    )
    XCTAssertFalse(manifestText.contains(sourceRoot.path))
    XCTAssertFalse(manifestText.contains(destinationRoot.path))
    XCTAssertFalse(manifestText.contains("/Users/"))
  }

  func testImportRejectsTamperedAsset() throws {
    let fixtureRoot = try makeFixtureRoot()
    let sourceRoot = fixtureRoot.appendingPathComponent("source", isDirectory: true)
    let packageRoot = fixtureRoot.appendingPathComponent("package", isDirectory: true)
    let destinationRoot = fixtureRoot.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sourceRoot,
      withIntermediateDirectories: true
    )
    let sourceBytes = Data("synthetic source audio bytes".utf8)
    let modelBytes = Data("synthetic model artifact bytes".utf8)
    let modelDigest = try SHA256Digest(
      CrossRootFixtureTransfer.sha256(modelBytes)
    )
    let relativeReference = try PortableAssetReference(
      relativePath: "sessions/fixture/source.caf"
    )
    let contentReference = PortableAssetReference(contentDigest: modelDigest)
    try write(
      sourceBytes,
      to: CrossRootFixtureTransfer.resolvedURL(
        for: relativeReference,
        root: sourceRoot
      )
    )
    try write(
      modelBytes,
      to: CrossRootFixtureTransfer.resolvedURL(
        for: contentReference,
        root: sourceRoot
      )
    )
    let snapshot = try makeSnapshot(
      audioReference: relativeReference,
      modelReference: contentReference,
      modelDigest: modelDigest
    )
    let manifest = try CrossRootFixtureTransfer.exportFixture(
      snapshot: snapshot,
      sourceRoot: sourceRoot,
      packageRoot: packageRoot
    )
    let firstAsset = try XCTUnwrap(manifest.assets.first)
    try Data("tampered".utf8)
      .write(to: packageRoot.appendingPathComponent(firstAsset.packagePath))

    XCTAssertThrowsError(
      try CrossRootFixtureTransfer.importFixture(
        packageRoot: packageRoot,
        destinationRoot: destinationRoot
      )
    )
  }

  private func makeSnapshot(
    audioReference: PortableAssetReference,
    modelReference: PortableAssetReference,
    modelDigest: SHA256Digest
  ) throws -> DomainSnapshot {
    let revision = try Revision(1)
    let sessionID = SessionID(uuid(1))
    let trackID = TrackID(uuid(2))
    let modelID = ModelArtifactID(uuid(3))
    let speakerID = SessionSpeakerID(uuid(4))
    let personID = PersonID(uuid(5))
    let occurrenceID = SpeakerOccurrenceID(uuid(6))
    let correctionID = PersonCorrectionID(uuid(7))
    let changeID = ChangeID(uuid(8))
    let association = try PersonAssociation(
      status: .userConfirmed,
      personID: personID,
      confidence: nil,
      evidenceRevision: revision
    )
    let correction = PersonCorrectionOperation(
      id: correctionID,
      revision: revision,
      occurredAt: fixedDate,
      actor: .user,
      payload: .confirm(occurrenceID: occurrenceID, personID: personID),
      reversesOperationID: nil
    )
    let change = ChangeLogEntry(
      id: changeID,
      entity: DomainEntityReference(kind: .person, stableID: personID.rawValue),
      revision: revision,
      occurredAt: fixedDate,
      originDeviceID: uuid(9),
      operation: .personCorrection,
      payloadDigest: modelDigest,
      personCorrection: correction
    )
    return DomainSnapshot(
      sessions: [
        Session(
          id: sessionID,
          revision: revision,
          inputMode: .dictation,
          state: .completed,
          createdAt: fixedDate,
          updatedAt: fixedDate
        )
      ],
      tracks: [
        SourceTrack(
          id: trackID,
          sessionID: sessionID,
          revision: revision,
          role: .microphoneLocal,
          assetReference: audioReference,
          sampleRateHertz: 48_000,
          channelCount: 1
        )
      ],
      chunks: [
        AudioChunk(
          id: ChunkID(uuid(10)),
          sessionID: sessionID,
          trackID: trackID,
          revision: revision,
          sequence: 0,
          monotonicStartNanoseconds: 1,
          frameCount: 48_000,
          contentDigest: try SHA256Digest(String(repeating: "a", count: 64)),
          assetReference: audioReference
        )
      ],
      timelineEvents: [],
      transcriptRevisions: [],
      durableJobs: [],
      modelArtifacts: [
        ModelArtifact(
          id: modelID,
          revision: revision,
          registryKey: "fixture-model",
          version: "1.0.0",
          capability: .asr,
          digest: modelDigest,
          directoryReference: modelReference,
          licenseIdentifier: "fixture-license",
          state: .active
        )
      ],
      sessionSpeakers: [
        SessionSpeaker(
          id: speakerID,
          sessionID: sessionID,
          revision: revision,
          stableOrdinal: 1
        )
      ],
      speakerOccurrences: [
        SpeakerOccurrence(
          id: occurrenceID,
          sessionID: sessionID,
          sessionSpeakerID: speakerID,
          revision: revision,
          trackIDs: [trackID],
          monotonicStartNanoseconds: 1,
          monotonicEndNanoseconds: 2,
          overlapsAnotherSpeaker: false,
          association: association
        )
      ],
      persons: [
        Person(
          id: personID,
          revision: revision,
          displayName: nil,
          aliases: [],
          createdAt: fixedDate,
          updatedAt: fixedDate
        )
      ],
      personCorrections: [correction],
      changeLog: [change],
      tombstones: [
        Tombstone(
          id: TombstoneID(uuid(11)),
          entity: DomainEntityReference(
            kind: .durableJob,
            stableID: uuid(12)
          ),
          revision: revision,
          deletedAt: fixedDate,
          deletionScope: .metadataOnly,
          changeID: changeID
        )
      ]
    )
  }

  private func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url)
  }

  private func makeFixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-cross-root-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root
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
}
