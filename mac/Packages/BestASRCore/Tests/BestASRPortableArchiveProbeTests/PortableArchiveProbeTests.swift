import BestASRDomain
import BestASRSecurityEnvelopeProbe
import CryptoKit
import Foundation
import XCTest

@testable import BestASRPortableArchiveProbe

final class PortableArchiveProbeTests: XCTestCase {
  func testPBKDF2HMACSHA256KnownVector() throws {
    let key = try PortableSecretKDF.deriveKeyData(
      secret: Data("password".utf8),
      salt: Data("salt".utf8),
      iterations: 1
    )
    XCTAssertEqual(
      key.map { String(format: "%02x", $0) }.joined(),
      "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"
    )
  }

  func testWholeSourceAndPCMRangeExportsAreNonDestructive() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let imported = root.appendingPathComponent("imported.bin")
    let importedBytes = Data("synthetic imported original".utf8)
    try importedBytes.write(to: imported)
    let importedExport = root.appendingPathComponent("imported-export.bin")
    let importedResult = try SourceAudioExporter.exportWholeSource(
      from: imported,
      to: importedExport,
      origin: .importedOriginal
    )
    XCTAssertTrue(importedResult.sourceUnchanged)
    XCTAssertEqual(try Data(contentsOf: importedExport), importedBytes)

    let native = root.appendingPathComponent("native.wav")
    let nativeBytes = makeWave(frameCount: 100)
    try nativeBytes.write(to: native)
    let nativeExport = root.appendingPathComponent("native-export.wav")
    let nativeResult = try SourceAudioExporter.exportWholeSource(
      from: native,
      to: nativeExport,
      origin: .nativeCapture
    )
    XCTAssertTrue(nativeResult.sourceUnchanged)
    XCTAssertEqual(try Data(contentsOf: nativeExport), nativeBytes)

    let rangeExport = root.appendingPathComponent("range.wav")
    let rangeResult = try SourceAudioExporter.exportPCM16WaveRange(
      from: native,
      to: rangeExport,
      startFrame: 20,
      endFrame: 40,
      origin: .nativeCapture
    )
    XCTAssertTrue(rangeResult.sourceUnchanged)
    XCTAssertEqual(try Data(contentsOf: native), nativeBytes)
    let rangeBytes = try Data(contentsOf: rangeExport)
    XCTAssertEqual(String(decoding: rangeBytes[0..<4], as: UTF8.self), "RIFF")
    XCTAssertEqual(rangeBytes.count, 44 + (20 * 2))
    XCTAssertEqual(rangeBytes[44], nativeBytes[44 + (20 * 2)])
    XCTAssertEqual(rangeBytes[45], nativeBytes[45 + (20 * 2)])
  }

  func testArchiveRoundTripAcrossIndependentRootsAndDuplicateImport() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeFixture()
    let archiveURL = root.appendingPathComponent("backup.bestasrarchive")
    let secret = try portableSecret()
    let archiveID = try PortableArchiveStore.export(
      payload: fixture.payload,
      secret: secret,
      to: archiveURL,
      kdfIterations: 100
    )
    let archiveBytes = try Data(contentsOf: archiveURL)
    for marker in fixture.plaintextMarkers {
      XCTAssertNil(archiveBytes.range(of: marker))
    }

    let destinationRoot = root.appendingPathComponent("other-user")
    let destinationKey = EnvelopeCrypto.makeMasterKey()
    let imported = try PortableArchiveStore.importArchive(
      at: archiveURL,
      secret: secret,
      destinationRoot: destinationRoot,
      destinationMasterKey: destinationKey
    )
    XCTAssertEqual(imported.outcome, .imported)
    XCTAssertEqual(imported.archiveID, archiveID)
    XCTAssertEqual(imported.payload, fixture.payload)
    XCTAssertEqual(imported.payload.snapshot.sessions.map(\.id), [fixture.sessionID])
    XCTAssertTrue(imported.destination.path.hasPrefix(destinationRoot.path))
    try assertNoMarkers(
      fixture.plaintextMarkers,
      under: imported.destination
    )

    let receiptBefore = try Data(
      contentsOf: imported.destination.appendingPathComponent("receipt.json")
    )
    let duplicate = try PortableArchiveStore.importArchive(
      at: archiveURL,
      secret: secret,
      destinationRoot: destinationRoot,
      destinationMasterKey: destinationKey
    )
    XCTAssertEqual(duplicate.outcome, .alreadyImported)
    XCTAssertEqual(
      try Data(
        contentsOf: imported.destination.appendingPathComponent("receipt.json")
      ),
      receiptBefore
    )
  }

  func testWrongSecretTamperingAndTruncationFailBeforeCommit() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeFixture()
    let archiveURL = root.appendingPathComponent("backup.bestasrarchive")
    let secret = try portableSecret()
    _ = try PortableArchiveStore.export(
      payload: fixture.payload,
      secret: secret,
      to: archiveURL,
      kdfIterations: 50
    )
    let destinationRoot = root.appendingPathComponent("destination")

    XCTAssertThrowsError(
      try PortableArchiveStore.importArchive(
        at: archiveURL,
        secret: PortableArchiveSecret(bytes: Data(repeating: 0x99, count: 32)),
        destinationRoot: destinationRoot,
        destinationMasterKey: EnvelopeCrypto.makeMasterKey()
      )
    ) { error in
      XCTAssertEqual(error as? PortableArchiveError, .authenticationFailed)
    }

    let container = try JSONDecoder().decode(
      PortableArchiveContainer.self,
      from: Data(contentsOf: archiveURL)
    )
    var tamperedPayload = container.envelope.sealedPayload
    tamperedPayload[tamperedPayload.startIndex] ^= 0x01
    let tamperedEnvelope = EncryptedEnvelope(
      keyIdentifier: container.envelope.keyIdentifier,
      purpose: container.envelope.purpose,
      wrappedDataKey: container.envelope.wrappedDataKey,
      sealedPayload: tamperedPayload
    )
    let tampered = PortableArchiveContainer(
      archiveID: container.archiveID,
      kdf: container.kdf,
      envelope: tamperedEnvelope
    )
    let tamperedURL = root.appendingPathComponent("tampered.bestasrarchive")
    try JSONEncoder().encode(tampered).write(to: tamperedURL)
    XCTAssertThrowsError(
      try PortableArchiveStore.importArchive(
        at: tamperedURL,
        secret: secret,
        destinationRoot: destinationRoot,
        destinationMasterKey: EnvelopeCrypto.makeMasterKey()
      )
    )

    let truncatedURL = root.appendingPathComponent("truncated.bestasrarchive")
    let bytes = try Data(contentsOf: archiveURL)
    try bytes.prefix(bytes.count / 2).write(to: truncatedURL)
    XCTAssertThrowsError(
      try PortableArchiveStore.importArchive(
        at: truncatedURL,
        secret: secret,
        destinationRoot: destinationRoot,
        destinationMasterKey: EnvelopeCrypto.makeMasterKey()
      )
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: destinationRoot.appendingPathComponent("imports").path
      )
    )
  }

  func testDiskCancellationAndKillRecoveryLeaveNoPlaintextOrPartialCommit()
    throws
  {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeFixture()
    let archiveURL = root.appendingPathComponent("backup.bestasrarchive")
    let secret = try portableSecret()
    _ = try PortableArchiveStore.export(
      payload: fixture.payload,
      secret: secret,
      to: archiveURL,
      kdfIterations: 25
    )
    let destinationRoot = root.appendingPathComponent("destination")
    let destinationKey = EnvelopeCrypto.makeMasterKey()

    XCTAssertThrowsError(
      try PortableArchiveStore.importArchive(
        at: archiveURL,
        secret: secret,
        destinationRoot: destinationRoot,
        destinationMasterKey: destinationKey,
        availableBytes: 0
      )
    ) { error in
      XCTAssertEqual(error as? PortableArchiveError, .insufficientSpace)
    }
    XCTAssertThrowsError(
      try PortableArchiveStore.importArchive(
        at: archiveURL,
        secret: secret,
        destinationRoot: destinationRoot,
        destinationMasterKey: destinationKey,
        fault: .cancelledAfterFirstEncryptedWrite
      )
    ) { error in
      XCTAssertEqual(error as? PortableArchiveError, .cancelled)
    }

    XCTAssertThrowsError(
      try PortableArchiveStore.importArchive(
        at: archiveURL,
        secret: secret,
        destinationRoot: destinationRoot,
        destinationMasterKey: destinationKey,
        fault: .simulatedKillAfterFirstEncryptedWrite
      )
    ) { error in
      XCTAssertEqual(error as? PortableArchiveError, .simulatedProcessKill)
    }
    let importsRoot = destinationRoot.appendingPathComponent("imports")
    let staging = try XCTUnwrap(
      try FileManager.default.contentsOfDirectory(
        at: importsRoot,
        includingPropertiesForKeys: nil
      ).first { $0.lastPathComponent.hasSuffix(".staging") }
    )
    try assertNoMarkers(fixture.plaintextMarkers, under: staging)
    XCTAssertEqual(
      try PortableArchiveStore.recoverImportStaging(
        destinationRoot: destinationRoot
      ),
      1
    )
    XCTAssertEqual(
      try PortableArchiveStore.importArchive(
        at: archiveURL,
        secret: secret,
        destinationRoot: destinationRoot,
        destinationMasterKey: destinationKey
      ).outcome,
      .imported
    )
  }

  func testExportCancellationAndKillStagingRecovery() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeFixture()
    let secret = try portableSecret()
    let cancelledURL = root.appendingPathComponent("cancelled.bestasrarchive")
    XCTAssertThrowsError(
      try PortableArchiveStore.export(
        payload: fixture.payload,
        secret: secret,
        to: cancelledURL,
        kdfIterations: 10,
        fault: .cancelled
      )
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledURL.path))
    XCTAssertEqual(
      try PortableArchiveStore.recoverExportStaging(in: root),
      0
    )

    let killedURL = root.appendingPathComponent("killed.bestasrarchive")
    XCTAssertThrowsError(
      try PortableArchiveStore.export(
        payload: fixture.payload,
        secret: secret,
        to: killedURL,
        kdfIterations: 10,
        fault: .simulatedProcessKill
      )
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: killedURL.path))
    let staging = try XCTUnwrap(
      try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
      ).first { $0.lastPathComponent.hasSuffix(".bestasrarchive-staging") }
    )
    try assertNoMarkers(fixture.plaintextMarkers, in: staging)
    XCTAssertEqual(
      try PortableArchiveStore.recoverExportStaging(in: root),
      1
    )
  }

  func testLegacyV0ArchiveMigratesToCurrentWithoutRewritingIDs() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try makeFixture()
    let archiveURL = root.appendingPathComponent("legacy.bestasrarchive")
    let secret = try portableSecret()
    _ = try PortableArchiveStore.exportLegacyV0(
      snapshot: fixture.payload.snapshot,
      assets: fixture.payload.assets,
      dictionaries: fixture.payload.dictionaries,
      secret: secret,
      to: archiveURL,
      kdfIterations: 25
    )
    let imported = try PortableArchiveStore.importArchive(
      at: archiveURL,
      secret: secret,
      destinationRoot: root.appendingPathComponent("new-user"),
      destinationMasterKey: EnvelopeCrypto.makeMasterKey()
    )

    XCTAssertEqual(imported.migratedFromSchemaVersion, 0)
    XCTAssertEqual(imported.payload.schemaVersion, 1)
    XCTAssertEqual(imported.payload.snapshot.sessions.map(\.id), [fixture.sessionID])
    XCTAssertTrue(imported.payload.derivedDocuments.isEmpty)
    XCTAssertTrue(imported.payload.settings.isEmpty)
  }

  private func makeFixture() throws -> Fixture {
    let revision = try Revision(1)
    let sessionID = SessionID(uuid(1))
    let trackA = TrackID(uuid(2))
    let trackB = TrackID(uuid(3))
    let speakerID = SessionSpeakerID(uuid(4))
    let personID = PersonID(uuid(5))
    let occurrenceID = SpeakerOccurrenceID(uuid(6))
    let modelID = ModelArtifactID(uuid(7))
    let transcriptID = TranscriptRevisionID(uuid(8))
    let correctionID = PersonCorrectionID(uuid(9))
    let changeID = ChangeID(uuid(10))
    let importedBytes = Data("portable_audio_marker_imported".utf8)
    let nativeBytes = Data("portable_audio_marker_native".utf8)
    let importedDigest = try digest(importedBytes)
    let nativeDigest = try digest(nativeBytes)
    let relativeReference = try PortableAssetReference(
      relativePath: "sessions/fixture/imported.wav"
    )
    let contentReference = PortableAssetReference(
      contentDigest: nativeDigest
    )
    let session = Session(
      id: sessionID,
      revision: revision,
      inputMode: .dictation,
      state: .completed,
      createdAt: fixedDate,
      updatedAt: fixedDate
    )
    let tracks = [
      SourceTrack(
        id: trackA,
        sessionID: sessionID,
        revision: revision,
        role: .importedSource,
        assetReference: relativeReference,
        sampleRateHertz: 48_000,
        channelCount: 1
      ),
      SourceTrack(
        id: trackB,
        sessionID: sessionID,
        revision: revision,
        role: .microphoneLocal,
        assetReference: contentReference,
        sampleRateHertz: 48_000,
        channelCount: 1
      ),
    ]
    let chunks = [
      AudioChunk(
        id: ChunkID(uuid(11)),
        sessionID: sessionID,
        trackID: trackA,
        revision: revision,
        sequence: 1,
        monotonicStartNanoseconds: 0,
        frameCount: 48_000,
        contentDigest: importedDigest,
        assetReference: relativeReference
      ),
      AudioChunk(
        id: ChunkID(uuid(12)),
        sessionID: sessionID,
        trackID: trackB,
        revision: revision,
        sequence: 2,
        monotonicStartNanoseconds: 1_000_000_000,
        frameCount: 48_000,
        contentDigest: nativeDigest,
        assetReference: contentReference
      ),
    ]
    let transcript = TranscriptRevision(
      id: transcriptID,
      sessionID: sessionID,
      revision: revision,
      parentID: nil,
      kind: .final,
      content: "portable_transcript_marker",
      modelArtifactID: modelID,
      configHash: try digest(Data("config".utf8)),
      createdAt: fixedDate
    )
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
      originDeviceID: uuid(13),
      operation: .personCorrection,
      payloadDigest: try digest(Data("change".utf8)),
      personCorrection: correction
    )
    let snapshot = DomainSnapshot(
      sessions: [session],
      tracks: tracks,
      chunks: chunks,
      timelineEvents: [],
      transcriptRevisions: [transcript],
      durableJobs: [],
      modelArtifacts: [
        ModelArtifact(
          id: modelID,
          revision: revision,
          registryKey: "model-metadata-only",
          version: "1.0.0",
          capability: .asr,
          digest: try digest(Data("model-metadata".utf8)),
          directoryReference: PortableAssetReference(
            contentDigest: try digest(Data("excluded-model-binary".utf8))
          ),
          licenseIdentifier: "fixture",
          state: .inactive
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
          trackIDs: [trackA, trackB],
          monotonicStartNanoseconds: 0,
          monotonicEndNanoseconds: 2_000_000_000,
          overlapsAnotherSpeaker: false,
          association: association
        )
      ],
      persons: [
        Person(
          id: personID,
          revision: revision,
          displayName: "portable_person_marker",
          aliases: [],
          createdAt: fixedDate,
          updatedAt: fixedDate
        )
      ],
      personCorrections: [correction],
      changeLog: [change],
      tombstones: [
        Tombstone(
          id: TombstoneID(uuid(14)),
          entity: DomainEntityReference(
            kind: .transcriptRevision,
            stableID: transcriptID.rawValue
          ),
          revision: revision,
          deletedAt: fixedDate,
          deletionScope: .metadataOnly,
          changeID: changeID
        )
      ]
    )
    let dictionary = PortableDictionaryEntry(
      id: uuid(15),
      revision: revision,
      spokenForm: "portable_dictionary_marker",
      canonicalForm: "PortableDictionary"
    )
    let derived = DerivedDocument(
      id: DerivedDocumentID(uuid(16)),
      revision: revision,
      kind: .summary,
      lineage: DerivedDocumentLineage(
        input: DerivedDocumentInput(
          entity: DomainEntityReference(
            kind: .transcriptRevision,
            stableID: transcriptID.rawValue
          ),
          revision: revision
        ),
        modelArtifactID: modelID,
        configHash: try digest(Data("derived-config".utf8))
      ),
      contentDigest: try digest(Data("portable_summary_marker".utf8)),
      createdAt: fixedDate
    )
    let payload = PortableArchivePayload(
      snapshot: snapshot,
      assets: [
        PortableArchiveAsset(
          reference: relativeReference,
          origin: .importedOriginal,
          contentDigest: importedDigest,
          bytes: importedBytes
        ),
        PortableArchiveAsset(
          reference: contentReference,
          origin: .nativeCapture,
          contentDigest: nativeDigest,
          bytes: nativeBytes
        ),
      ],
      dictionaries: [dictionary],
      derivedDocuments: [derived],
      settings: [PortableSetting(key: "language", value: "zh-Hans")]
    )
    return Fixture(
      payload: payload,
      sessionID: sessionID,
      plaintextMarkers: [
        importedBytes,
        nativeBytes,
        Data("portable_transcript_marker".utf8),
        Data("portable_person_marker".utf8),
        Data("portable_dictionary_marker".utf8),
      ]
    )
  }

  private func assertNoMarkers(_ markers: [Data], under root: URL) throws {
    let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey]
    )
    while let file = enumerator?.nextObject() as? URL {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else { continue }
      try assertNoMarkers(markers, in: file)
    }
  }

  private func assertNoMarkers(_ markers: [Data], in file: URL) throws {
    let bytes = try Data(contentsOf: file)
    for marker in markers {
      XCTAssertNil(bytes.range(of: marker), "plaintext marker in \(file.lastPathComponent)")
    }
  }

  private func makeWave(frameCount: Int) -> Data {
    var samples = Data()
    for frame in 0..<frameCount {
      let value = Int16(frame * 100)
      samples.append(UInt8(truncatingIfNeeded: value))
      samples.append(UInt8(truncatingIfNeeded: value >> 8))
    }
    var data = Data()
    data.append(contentsOf: "RIFF".utf8)
    appendUInt32(UInt32(36 + samples.count), to: &data)
    data.append(contentsOf: "WAVEfmt ".utf8)
    appendUInt32(16, to: &data)
    appendUInt16(1, to: &data)
    appendUInt16(1, to: &data)
    appendUInt32(48_000, to: &data)
    appendUInt32(96_000, to: &data)
    appendUInt16(2, to: &data)
    appendUInt16(16, to: &data)
    data.append(contentsOf: "data".utf8)
    appendUInt32(UInt32(samples.count), to: &data)
    data.append(samples)
    return data
  }

  private func appendUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
  }

  private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 24) & 0xff))
  }

  private func portableSecret() throws -> PortableArchiveSecret {
    try PortableArchiveSecret(bytes: Data(repeating: 0x42, count: 32))
  }

  private func digest(_ data: Data) throws -> BestASRDomain.SHA256Digest {
    try BestASRDomain.SHA256Digest(
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    )
  }

  private func temporaryRoot() -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-portable-archive-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    try! FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
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

  private struct Fixture {
    let payload: PortableArchivePayload
    let sessionID: SessionID
    let plaintextMarkers: [Data]
  }
}
