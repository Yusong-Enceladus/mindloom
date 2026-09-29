import BestASRDomain
import BestASRPortableArchiveProbe
import BestASRSecurityEnvelopeProbe
import CryptoKit
import Foundation

struct Scenario: Codable {
  let scenarioID: String
  let status: String
  let errorCategory: String
  let metrics: [String: String]
}

struct MatrixEvidence: Codable {
  let schemaVersion: Int
  let kind: String
  let spikeID: String
  let runID: UUID
  let generatedAt: Date
  let kdf: String
  let scenarios: [Scenario]
}

struct Criteria: Codable {
  let pass: [String]
  let fail: [String]
}

struct MatrixReference: Codable {
  let scenarioID: String
  let status: String
  let evidenceRefs: [String]
}

struct Summary: Codable {
  let schemaVersion: Int
  let kind: String
  let spikeID: String
  let runID: UUID
  let question: String
  let environmentRef: String
  let criteria: Criteria
  let commands: [[String]]
  let matrix: [MatrixReference]
  let conclusion: String
  let unmetCriteria: [String]
}

struct Fixture {
  let payload: PortableArchivePayload
  let sessionID: SessionID
  let markers: [Data]
}

enum CLIProbeError: Error {
  case expectedFailureMissing(String)
  case invariant(String)
}

let defaultSummaryPath = "artifacts/evidence/SPIKE-MIG-001/summary.json"
let defaultMatrixPath = "artifacts/evidence/SPIKE-MIG-001/matrix.json"

func argumentValue(_ name: String, fallback: String) -> String {
  guard let index = CommandLine.arguments.firstIndex(of: name),
    CommandLine.arguments.indices.contains(index + 1)
  else {
    return fallback
  }
  return CommandLine.arguments[index + 1]
}

func scenario(
  _ id: String,
  _ body: () throws -> [String: String]
) -> Scenario {
  do {
    return Scenario(
      scenarioID: id,
      status: "pass",
      errorCategory: "none",
      metrics: try body()
    )
  } catch {
    return Scenario(
      scenarioID: id,
      status: "fail",
      errorCategory: String(describing: error),
      metrics: [:]
    )
  }
}

func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
  let url = URL(fileURLWithPath: path)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  try encoder.encode(value).write(to: url, options: .atomic)
}

func digest(_ data: Data) throws -> BestASRDomain.SHA256Digest {
  try BestASRDomain.SHA256Digest(
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  )
}

func uuid(_ value: UInt64) -> UUID {
  UUID(
    uuidString: String(
      format: "00000000-0000-4000-8000-%012llx",
      value
    )
  )!
}

func makeFixture() throws -> Fixture {
  let revision = try Revision(1)
  let fixedDate = Date(timeIntervalSince1970: 1_753_286_400)
  let sessionID = SessionID(uuid(1))
  let trackID = TrackID(uuid(2))
  let speakerID = SessionSpeakerID(uuid(3))
  let personID = PersonID(uuid(4))
  let occurrenceID = SpeakerOccurrenceID(uuid(5))
  let transcriptID = TranscriptRevisionID(uuid(6))
  let modelID = ModelArtifactID(uuid(7))
  let correctionID = PersonCorrectionID(uuid(8))
  let changeID = ChangeID(uuid(9))
  let audioBytes = Data("migration_audio_marker_6d21".utf8)
  let audioDigest = try digest(audioBytes)
  let assetReference = try PortableAssetReference(
    relativePath: "sessions/migration/source.wav"
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
    originDeviceID: uuid(10),
    operation: .personCorrection,
    payloadDigest: try digest(Data("change".utf8)),
    personCorrection: correction
  )
  let snapshot = DomainSnapshot(
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
        assetReference: assetReference,
        sampleRateHertz: 48_000,
        channelCount: 1
      )
    ],
    chunks: [
      AudioChunk(
        id: ChunkID(uuid(11)),
        sessionID: sessionID,
        trackID: trackID,
        revision: revision,
        sequence: 1,
        monotonicStartNanoseconds: 0,
        frameCount: 48_000,
        contentDigest: audioDigest,
        assetReference: assetReference
      )
    ],
    timelineEvents: [],
    transcriptRevisions: [
      TranscriptRevision(
        id: transcriptID,
        sessionID: sessionID,
        revision: revision,
        parentID: nil,
        kind: .userEdit,
        content: "migration_transcript_marker_77e1",
        modelArtifactID: modelID,
        configHash: try digest(Data("config".utf8)),
        createdAt: fixedDate
      )
    ],
    durableJobs: [],
    modelArtifacts: [
      ModelArtifact(
        id: modelID,
        revision: revision,
        registryKey: "metadata-only",
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
        trackIDs: [trackID],
        monotonicStartNanoseconds: 0,
        monotonicEndNanoseconds: 1_000_000_000,
        overlapsAnotherSpeaker: false,
        association: try PersonAssociation(
          status: .userConfirmed,
          personID: personID,
          confidence: nil,
          evidenceRevision: revision
        )
      )
    ],
    persons: [
      Person(
        id: personID,
        revision: revision,
        displayName: "migration_person_marker_23a8",
        aliases: [],
        createdAt: fixedDate,
        updatedAt: fixedDate
      )
    ],
    personCorrections: [correction],
    changeLog: [change],
    tombstones: [
      Tombstone(
        id: TombstoneID(uuid(12)),
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
    id: uuid(13),
    revision: revision,
    spokenForm: "migration_dictionary_marker_8f02",
    canonicalForm: "MigrationDictionary"
  )
  let derived = DerivedDocument(
    id: DerivedDocumentID(uuid(14)),
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
    contentDigest: try digest(Data("migration_summary_marker_a731".utf8)),
    createdAt: fixedDate
  )
  return Fixture(
    payload: PortableArchivePayload(
      snapshot: snapshot,
      assets: [
        PortableArchiveAsset(
          reference: assetReference,
          origin: .nativeCapture,
          contentDigest: audioDigest,
          bytes: audioBytes
        )
      ],
      dictionaries: [dictionary],
      derivedDocuments: [derived],
      settings: [PortableSetting(key: "language", value: "zh-Hans")]
    ),
    sessionID: sessionID,
    markers: [
      audioBytes,
      Data("migration_transcript_marker_77e1".utf8),
      Data("migration_person_marker_23a8".utf8),
      Data("migration_dictionary_marker_8f02".utf8),
    ]
  )
}

func makeWave(frameCount: Int) -> Data {
  func appendUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
  }
  func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 24) & 0xff))
  }
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

func filesUnder(_ root: URL) -> [URL] {
  let enumerator = FileManager.default.enumerator(
    at: root,
    includingPropertiesForKeys: [.isRegularFileKey]
  )
  var files: [URL] = []
  while let file = enumerator?.nextObject() as? URL {
    if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile)
      == true
    {
      files.append(file)
    }
  }
  return files
}

func requireNoMarkers(_ markers: [Data], under root: URL) throws {
  for file in filesUnder(root) {
    let data = try Data(contentsOf: file)
    for marker in markers where data.range(of: marker) != nil {
      throw CLIProbeError.invariant("plaintext-marker")
    }
  }
}

do {
  let summaryPath = argumentValue("--summary", fallback: defaultSummaryPath)
  let matrixPath = argumentValue("--matrix", fallback: defaultMatrixPath)
  let runID = UUID()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bestasr-migration-probe-\(runID.uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(
    at: root,
    withIntermediateDirectories: true
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let fixture = try makeFixture()
  let secret = try PortableArchiveSecret(
    bytes: Data("synthetic-portable-recovery-secret-32".utf8)
  )
  let archiveURL = root.appendingPathComponent("backup.bestasrarchive")
  let sourceImported = root.appendingPathComponent("source-imported.bin")
  let sourceNative = root.appendingPathComponent("source-native.wav")
  try Data("imported_source_fixture".utf8).write(to: sourceImported)
  try makeWave(frameCount: 100).write(to: sourceNative)
  var archiveID: UUID?
  var destinationKeyData: Data?
  var destinationKeychain: TemporaryKeychainStore?
  defer { try? destinationKeychain?.destroy() }

  let scenarios = [
    scenario("export-imported-original-byte-identical") {
      let output = root.appendingPathComponent("export-imported.bin")
      let result = try SourceAudioExporter.exportWholeSource(
        from: sourceImported,
        to: output,
        origin: .importedOriginal
      )
      guard result.sourceUnchanged,
        result.sourceDigestBefore == result.exportDigest
      else { throw CLIProbeError.invariant("imported-export") }
      return ["byteIdentical": "true", "sourceUnchanged": "true"]
    },
    scenario("export-native-capture-byte-identical") {
      let output = root.appendingPathComponent("export-native.wav")
      let result = try SourceAudioExporter.exportWholeSource(
        from: sourceNative,
        to: output,
        origin: .nativeCapture
      )
      guard result.sourceUnchanged,
        result.sourceDigestBefore == result.exportDigest
      else { throw CLIProbeError.invariant("native-export") }
      return ["byteIdentical": "true", "sourceUnchanged": "true"]
    },
    scenario("export-lossless-range-without-source-rewrite") {
      let output = root.appendingPathComponent("export-range.wav")
      let result = try SourceAudioExporter.exportPCM16WaveRange(
        from: sourceNative,
        to: output,
        startFrame: 20,
        endFrame: 40,
        origin: .nativeCapture
      )
      guard result.sourceUnchanged, result.exportedBytes == 84 else {
        throw CLIProbeError.invariant("range-export")
      }
      return ["format": "PCM16-WAV", "sourceUnchanged": "true"]
    },
    scenario("portable-archive-encrypted-export") {
      archiveID = try PortableArchiveStore.export(
        payload: fixture.payload,
        secret: secret,
        to: archiveURL
      )
      let bytes = try Data(contentsOf: archiveURL)
      for marker in fixture.markers where bytes.range(of: marker) != nil {
        throw CLIProbeError.invariant("archive-plaintext")
      }
      guard bytes.range(of: Data("excluded-model-binary".utf8)) == nil else {
        throw CLIProbeError.invariant("excluded-model")
      }
      return [
        "archiveBytes": String(bytes.count),
        "kdfIterations": String(PortableArchiveStore.defaultKDFIterations),
        "plaintextMarkers": "0",
      ]
    },
    scenario("restore-without-source-keychain") {
      guard let archiveID else {
        throw CLIProbeError.invariant("archive-prerequisite")
      }
      let store = try TemporaryKeychainStore(
        url: root.appendingPathComponent("destination.keychain-db"),
        password: "destination-\(UUID().uuidString)"
      )
      destinationKeychain = store
      let keyData = EnvelopeCrypto.keyData(EnvelopeCrypto.makeMasterKey())
      try store.store(
        keyData,
        service: "local.bestasr.migration-probe",
        account: "destination-master-key"
      )
      destinationKeyData = try store.load(
        service: "local.bestasr.migration-probe",
        account: "destination-master-key"
      )
      guard let destinationKeyData else {
        throw CLIProbeError.invariant("destination-key")
      }
      let destination = root.appendingPathComponent("clean-destination")
      let result = try PortableArchiveStore.importArchive(
        at: archiveURL,
        secret: secret,
        destinationRoot: destination,
        destinationMasterKey: try EnvelopeCrypto.key(
          from: destinationKeyData
        )
      )
      guard result.archiveID == archiveID,
        result.payload == fixture.payload,
        result.payload.snapshot.sessions.map(\.id) == [fixture.sessionID]
      else { throw CLIProbeError.invariant("cross-identity-roundtrip") }
      try requireNoMarkers(fixture.markers, under: result.destination)
      return [
        "destinationKeychainIndependent": "true",
        "sourceKeychainItemsUsed": "0",
        "stableUUIDsPreserved": "true",
      ]
    },
    scenario("duplicate-import-is-idempotent") {
      guard let destinationKeyData else {
        throw CLIProbeError.invariant("destination-key")
      }
      let result = try PortableArchiveStore.importArchive(
        at: archiveURL,
        secret: secret,
        destinationRoot: root.appendingPathComponent("clean-destination"),
        destinationMasterKey: try EnvelopeCrypto.key(from: destinationKeyData)
      )
      guard result.outcome == .alreadyImported else {
        throw CLIProbeError.invariant("duplicate-import")
      }
      return ["outcome": "alreadyImported", "writes": "0"]
    },
    scenario("wrong-secret-tamper-and-truncation-rejected") {
      let failureRoot = root.appendingPathComponent("failure-destination")
      var wrongRejected = false
      do {
        _ = try PortableArchiveStore.importArchive(
          at: archiveURL,
          secret: PortableArchiveSecret(bytes: Data(repeating: 0x91, count: 32)),
          destinationRoot: failureRoot,
          destinationMasterKey: EnvelopeCrypto.makeMasterKey()
        )
      } catch PortableArchiveError.authenticationFailed {
        wrongRejected = true
      }
      let container = try JSONDecoder().decode(
        PortableArchiveContainer.self,
        from: Data(contentsOf: archiveURL)
      )
      var tamperedBytes = container.envelope.sealedPayload
      tamperedBytes[tamperedBytes.startIndex] ^= 0x01
      let tamperedURL = root.appendingPathComponent("tampered.bestasrarchive")
      try JSONEncoder().encode(
        PortableArchiveContainer(
          archiveID: container.archiveID,
          kdf: container.kdf,
          envelope: EncryptedEnvelope(
            keyIdentifier: container.envelope.keyIdentifier,
            purpose: container.envelope.purpose,
            wrappedDataKey: container.envelope.wrappedDataKey,
            sealedPayload: tamperedBytes
          )
        )
      ).write(to: tamperedURL)
      var tamperRejected = false
      do {
        _ = try PortableArchiveStore.importArchive(
          at: tamperedURL,
          secret: secret,
          destinationRoot: failureRoot,
          destinationMasterKey: EnvelopeCrypto.makeMasterKey()
        )
      } catch {
        tamperRejected = true
      }
      let original = try Data(contentsOf: archiveURL)
      let truncatedURL = root.appendingPathComponent("truncated.bestasrarchive")
      try original.prefix(original.count / 2).write(to: truncatedURL)
      var truncationRejected = false
      do {
        _ = try PortableArchiveStore.importArchive(
          at: truncatedURL,
          secret: secret,
          destinationRoot: failureRoot,
          destinationMasterKey: EnvelopeCrypto.makeMasterKey()
        )
      } catch {
        truncationRejected = true
      }
      guard wrongRejected, tamperRejected, truncationRejected else {
        throw CLIProbeError.expectedFailureMissing("archive-rejection")
      }
      return [
        "tamperRejected": "true",
        "truncationRejected": "true",
        "wrongSecretRejected": "true",
      ]
    },
    scenario("insufficient-space-preflight-rejects-before-staging") {
      let destination = root.appendingPathComponent("disk-destination")
      var rejected = false
      do {
        _ = try PortableArchiveStore.importArchive(
          at: archiveURL,
          secret: secret,
          destinationRoot: destination,
          destinationMasterKey: EnvelopeCrypto.makeMasterKey(),
          availableBytes: 0
        )
      } catch PortableArchiveError.insufficientSpace {
        rejected = true
      }
      guard rejected,
        !FileManager.default.fileExists(
          atPath: destination.appendingPathComponent("imports").path
        )
      else { throw CLIProbeError.invariant("disk-preflight") }
      return ["partialCommit": "false", "stagingCreated": "false"]
    },
    scenario("cancel-and-kill-recovery-has-no-plaintext-staging") {
      let destination = root.appendingPathComponent("recovery-destination")
      let key = EnvelopeCrypto.makeMasterKey()
      var cancellationRejected = false
      do {
        _ = try PortableArchiveStore.importArchive(
          at: archiveURL,
          secret: secret,
          destinationRoot: destination,
          destinationMasterKey: key,
          fault: .cancelledAfterFirstEncryptedWrite
        )
      } catch PortableArchiveError.cancelled {
        cancellationRejected = true
      }
      var killInjected = false
      do {
        _ = try PortableArchiveStore.importArchive(
          at: archiveURL,
          secret: secret,
          destinationRoot: destination,
          destinationMasterKey: key,
          fault: .simulatedKillAfterFirstEncryptedWrite
        )
      } catch PortableArchiveError.simulatedProcessKill {
        killInjected = true
      }
      let imports = destination.appendingPathComponent("imports")
      let staging = try FileManager.default.contentsOfDirectory(
        at: imports,
        includingPropertiesForKeys: nil
      ).first { $0.lastPathComponent.hasSuffix(".staging") }
      guard let staging else {
        throw CLIProbeError.invariant("kill-staging")
      }
      try requireNoMarkers(fixture.markers, under: staging)
      let removed = try PortableArchiveStore.recoverImportStaging(
        destinationRoot: destination
      )
      guard cancellationRejected, killInjected, removed == 1 else {
        throw CLIProbeError.invariant("recovery")
      }
      return [
        "cancelled": "true",
        "orphanEncryptedOnly": "true",
        "recoveredStagingCount": "1",
      ]
    },
    scenario("legacy-n-minus-one-migrates-to-current") {
      let legacyURL = root.appendingPathComponent("legacy.bestasrarchive")
      _ = try PortableArchiveStore.exportLegacyV0(
        snapshot: fixture.payload.snapshot,
        assets: fixture.payload.assets,
        dictionaries: fixture.payload.dictionaries,
        secret: secret,
        to: legacyURL
      )
      let result = try PortableArchiveStore.importArchive(
        at: legacyURL,
        secret: secret,
        destinationRoot: root.appendingPathComponent("legacy-destination"),
        destinationMasterKey: EnvelopeCrypto.makeMasterKey()
      )
      guard result.migratedFromSchemaVersion == 0,
        result.payload.schemaVersion == 1,
        result.payload.snapshot.sessions.map(\.id) == [fixture.sessionID]
      else { throw CLIProbeError.invariant("legacy-migration") }
      return [
        "fromSchema": "0",
        "stableUUIDsPreserved": "true",
        "toSchema": "1",
      ]
    },
  ]
  let matrix = MatrixEvidence(
    schemaVersion: 1,
    kind: "portable-migration-matrix",
    spikeID: "SPIKE-MIG-001",
    runID: runID,
    generatedAt: Date(),
    kdf: "PBKDF2-HMAC-SHA256/100000 + AES-256-GCM",
    scenarios: scenarios
  )
  try writeJSON(matrix, to: matrixPath)
  let failed = scenarios.filter { $0.status == "fail" }
  let conclusion = failed.isEmpty ? "conditional" : "fail"
  let unmet =
    failed.isEmpty
    ? [
      "Production password UX and a memory-hard KDF remain unfrozen; this probe uses explicit PBKDF2 parameters and also supports a high-entropy recovery secret.",
      "Multi-gigabyte streaming, real second macOS account, disk-full syscall injection, and all release audio containers remain pending.",
    ]
    : failed.map { "Failed scenario: \($0.scenarioID)" }
  let evidenceRef = "artifacts/evidence/SPIKE-MIG-001/matrix.json"
  let summary = Summary(
    schemaVersion: 1,
    kind: "spike-summary",
    spikeID: "SPIKE-MIG-001",
    runID: runID,
    question:
      "Can source audio be exported non-destructively and can a versioned authenticated archive restore under an independent local key identity without plaintext staging?",
    environmentRef: "artifacts/evidence/environment/check-summary.json",
    criteria: Criteria(
      pass: [
        "Whole retained sources are byte-identical and range export is lossless without modifying source assets.",
        "A portable user secret restores UUIDs, revisions, tombstones, person operations, dictionaries, derived documents, settings, and source bytes without the source Keychain.",
        "Wrong secret, tampering, truncation, insufficient space, cancellation, and kill injection never partially commit or leave plaintext staging.",
        "N-1 migration and duplicate import preserve stable identities and idempotency.",
      ],
      fail: [
        "Any failure path modifies source history, accepts unauthenticated data, partially overwrites a destination, or leaves plaintext staging.",
        "A clean destination identity requires the source Mac Keychain or rewrites stable UUIDs.",
      ]
    ),
    commands: [
      [
        "swift",
        "run",
        "--package-path",
        "Packages/BestASRCore",
        "--scratch-path",
        ".build/SwiftPM",
        "PortableMigrationProbeCLI",
      ]
    ],
    matrix: scenarios.map {
      MatrixReference(
        scenarioID: $0.scenarioID,
        status: $0.status,
        evidenceRefs: [evidenceRef]
      )
    },
    conclusion: conclusion,
    unmetCriteria: unmet
  )
  try writeJSON(summary, to: summaryPath)
  if failed.isEmpty {
    print("SPIKE-MIG-001 matrix passed; conclusion remains conditional")
  } else {
    fputs("SPIKE-MIG-001 matrix failed\n", stderr)
    exit(1)
  }
} catch {
  fputs("portable migration probe failed: \(String(describing: error))\n", stderr)
  exit(1)
}
