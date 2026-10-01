import BestASRDictation
import BestASRDomain
import BestASRInference
import Foundation
import GRDB

import struct CryptoKit.SHA256

public enum BestASRPersistenceError: Error, Equatable, Sendable {
  case databaseAlreadyClosed
  case duplicateSession
  case duplicateDictionaryEntry
  case dictionaryEntryMissing
  case dictionaryRevisionConflict(current: UInt64, expected: UInt64)
  case insertionKeyConflict
  case insertionNotReserved
  case invalidJournalMode
  case invalidSnapshot
  case missingSession
  case nonMonotonicRevision(current: UInt64, proposed: UInt64)
  case numericOverflow
  case processingCommitConflict
  case portableArchiveConflict
  case portableArchiveInvalidSchema
  case storedDataCorrupt
}

public struct LocalTextBundleJobRecord: Sendable {
  public let job: DurableJob
  public let sessionID: SessionID

  public init(job: DurableJob, sessionID: SessionID) {
    self.job = job
    self.sessionID = sessionID
  }
}

private struct PersonAssociationRowInverse: Codable {
  let occurrenceID: UUID
  let personID: UUID?
  let associationStatus: String
  let confidence: Double?
  let evidenceRevision: Int64
}

private struct RejectedPersonMatchRowInverse: Codable {
  let id: UUID
  let sessionSpeakerID: UUID
  let candidatePersonID: UUID
  let embeddingSpaceID: String
  let vectorData: Data
  let createdAt: Double
}

private enum PersonEditInverse: Codable {
  case rename(
    personID: UUID,
    displayName: String?,
    aliases: [String]
  )
  case merge(
    primaryID: UUID,
    mergedID: UUID,
    occurrenceIDs: [UUID],
    embeddingIDs: [UUID],
    nameEvidenceIDs: [UUID]?,
    primaryAliases: [String]
  )
  case split(
    sourceID: UUID,
    newPersonID: UUID,
    occurrenceIDs: [UUID],
    movedEmbeddingIDs: [UUID],
    createdEmbeddingIDs: [UUID]
  )
  case association(
    sessionSpeakerID: UUID,
    rows: [PersonAssociationRowInverse],
    rejectedMatches: [RejectedPersonMatchRowInverse],
    introducedRejectedMatchIDs: [UUID],
    createdPersonID: UUID?,
    createdEmbeddingIDs: [UUID]
  )
}

private struct PreparedSpeakerFinalWork: Sendable {
  let job: DurableJob
  let sessionID: SessionID
  let audioData: Data
  let formats: [UUID: (UInt32, UInt16)]
}

extension GRDBDictationStore {
  @discardableResult
  public func scheduleSpeakerFinalWork(
    sessionID: SessionID,
    audio: [AudioRangeInput],
    inputRevision: UInt64,
    modelArtifactKey: String,
    embeddingSpaceID: String,
    configHash: SHA256Digest
  ) async throws -> DurableJob {
    let work = try Self.prepareSpeakerFinalWork(
      sessionID: sessionID, audio: audio, inputRevision: inputRevision,
      modelArtifactKey: modelArtifactKey, embeddingSpaceID: embeddingSpaceID,
      configHash: configHash
    )
    let database = try requirePool()
    try await database.write { db in
      try Self.insertSpeakerFinalWork(
        work, modelArtifactKey: modelArtifactKey,
        embeddingSpaceID: embeddingSpaceID, in: db
      )
    }
    return work.job
  }

  private static func prepareSpeakerFinalWork(
    sessionID: SessionID,
    audio: [AudioRangeInput],
    inputRevision: UInt64,
    modelArtifactKey: String,
    embeddingSpaceID: String,
    configHash: SHA256Digest
  ) throws -> PreparedSpeakerFinalWork {
    guard
      inputRevision > 0,
      !audio.isEmpty,
      audio.count <= 4_096,
      !modelArtifactKey.isEmpty,
      !embeddingSpaceID.isEmpty
    else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    var previousEndByTrack: [UUID: UInt64] = [:]
    var trackFormats: [UUID: (UInt32, UInt16)] = [:]
    for range in audio {
      guard
        range.sourceID == sessionID.rawValue,
        range.monotonicStartNanoseconds < range.monotonicEndNanoseconds,
        range.sampleRateHertz > 0,
        range.channelCount > 0,
        Self.safeAssetReference(range.assetReference),
        range.contentDigest.range(
          of: "^[0-9a-f]{64}$",
          options: .regularExpression
        ) != nil,
        previousEndByTrack[range.trackID].map({
          range.monotonicStartNanoseconds >= $0
        }) ?? true
      else {
        throw BestASRPersistenceError.invalidSnapshot
      }
      if let format = trackFormats[range.trackID] {
        guard format.0 == range.sampleRateHertz, format.1 == range.channelCount
        else { throw BestASRPersistenceError.invalidSnapshot }
      } else {
        trackFormats[range.trackID] = (range.sampleRateHertz, range.channelCount)
      }
      previousEndByTrack[range.trackID] = range.monotonicEndNanoseconds
    }

    let job = DurableJob(
      id: DurableJobID(
        Self.deterministicUUID([
          "speaker-final-job-v2",
          sessionID.rawValue.uuidString.lowercased(),
          String(inputRevision),
          modelArtifactKey,
          configHash.value,
        ])
      ),
      revision: try Revision(1),
      kind: .speakerFinal,
      state: .queued,
      inputRevision: try Revision(inputRevision),
      modelArtifactID: ModelArtifactID(
        Self.deterministicUUID(["model-artifact-key-v1", modelArtifactKey])
      ),
      configHash: configHash,
      retryCount: 0,
      errorCategory: .none,
      leaseOwner: nil,
      leaseExpiresAt: nil
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let audioData = try encoder.encode(audio)
    return PreparedSpeakerFinalWork(
      job: job, sessionID: sessionID, audioData: audioData, formats: trackFormats
    )
  }

  private static func insertSpeakerFinalWork(
    _ work: PreparedSpeakerFinalWork,
    modelArtifactKey: String,
    embeddingSpaceID: String,
    in db: Database
  ) throws {
    let sessionID = work.sessionID
    let job = work.job
    let inputRevision = job.inputRevision.value
    let formats = work.formats
    let audioData = work.audioData
    guard
      let inputModeValue = try String.fetchOne(
        db,
        sql: "SELECT input_mode FROM sessions WHERE id = ?",
        arguments: [sessionID.rawValue.uuidString]
      ),
      let inputMode = SessionInputMode(rawValue: inputModeValue)
    else { throw BestASRPersistenceError.missingSession }
    let trackRole: SourceTrackRole =
      switch inputMode {
      case .dictation: .microphoneLocal
      case .roomMicrophone: .roomMicrophone
      case .importedMedia: .importedSource
      case .systemAudio: .systemRemote
      // An item has no audio, so there is never speaker work for it.
      case .userItem: throw BestASRPersistenceError.invalidSnapshot
      }

    let trackReference =
      "sessions/\(sessionID.rawValue.uuidString.lowercased())/journal/manifest.json"
    for (trackID, format) in formats {
      try db.execute(
        sql: """
          INSERT INTO tracks (
            id, session_id, revision, role, asset_reference,
            sample_rate_hz, channel_count
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO NOTHING
          """,
        arguments: [
          trackID.uuidString,
          sessionID.rawValue.uuidString,
          try Self.sqliteInt(inputRevision),
          trackRole.rawValue,
          trackReference,
          Int64(format.0),
          Int64(format.1),
        ]
      )
    }
    try Self.insert(job: job, sessionID: sessionID, in: db)
    try db.execute(
      sql: """
        INSERT INTO speaker_job_inputs (
          job_id, session_id, audio_ranges_json, model_artifact_key,
          embedding_space_id, created_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(job_id) DO NOTHING
        """,
      arguments: [
        job.id.rawValue.uuidString,
        sessionID.rawValue.uuidString,
        audioData,
        modelArtifactKey,
        embeddingSpaceID,
        Date().timeIntervalSince1970,
      ]
    )
    guard
      let storedData = try Data.fetchOne(
        db,
        sql: "SELECT audio_ranges_json FROM speaker_job_inputs WHERE job_id = ?",
        arguments: [job.id.rawValue.uuidString]
      ),
      storedData == audioData
    else { throw BestASRPersistenceError.processingCommitConflict }
  }

  public func claimNextSpeakerFinalJob(
    workerID: UUID,
    excludingJobIDs: Set<DurableJobID> = [],
    leaseDuration: TimeInterval = 300,
    now: Date = Date()
  ) async throws -> SpeakerFinalJobInputRecord? {
    guard leaseDuration >= 30, leaseDuration <= 3_600 else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let excludedValues = excludingJobIDs.map { $0.rawValue.uuidString }.sorted()
    let exclusionPlaceholders = Array(
      repeating: "?",
      count: excludedValues.count
    ).joined(separator: ", ")
    let exclusionPredicate: String
    if excludedValues.isEmpty {
      exclusionPredicate = ""
    } else {
      exclusionPredicate = "AND j.id NOT IN (\(exclusionPlaceholders))"
    }
    let database = try requirePool()
    return try await database.write { db in
      // V1 speaker jobs are claimable only when both the persisted input and
      // its session link agree. Older dictation builds created a
      // `speakerFinal` bookkeeping job without a `speaker_job_inputs` row;
      // leaving that row queued makes it sort first forever and starves every
      // valid job behind it. Preserve the job as audit evidence, but quarantine
      // structurally incomplete work before selecting the next candidate.
      try db.execute(
        sql: """
          UPDATE durable_jobs
          SET revision = revision + 1, state = ?, error_category = ?,
              lease_owner = NULL, lease_expires_at = NULL
          WHERE kind = ? AND (
            state = ? OR state = ? OR
            (state = ? AND lease_expires_at IS NOT NULL AND lease_expires_at < ?)
          ) AND NOT EXISTS (
            SELECT 1 FROM speaker_job_inputs i
            JOIN dictation_job_sessions d
              ON d.job_id = i.job_id AND d.session_id = i.session_id
            WHERE i.job_id = durable_jobs.id
          )
          """,
        arguments: [
          DurableJobState.permanentFailed.rawValue,
          DurableJobErrorCategory.corruptInput.rawValue,
          DurableJobKind.speakerFinal.rawValue,
          DurableJobState.queued.rawValue,
          DurableJobState.retryableFailed.rawValue,
          DurableJobState.running.rawValue,
          now.timeIntervalSince1970,
        ]
      )
      var claimArguments = StatementArguments()
      claimArguments += [
        DurableJobKind.speakerFinal.rawValue,
        DurableJobState.queued.rawValue,
        DurableJobState.retryableFailed.rawValue,
        DurableJobState.running.rawValue,
      ]
      claimArguments += [now.timeIntervalSince1970]
      claimArguments += StatementArguments(excludedValues)
      guard
        let jobID = try String.fetchOne(
          db,
          sql: """
            SELECT j.id FROM durable_jobs j
            JOIN speaker_job_inputs i ON i.job_id = j.id
            JOIN dictation_job_sessions d
              ON d.job_id = j.id AND d.session_id = i.session_id
            WHERE j.kind = ? AND (
              j.state = ? OR j.state = ? OR
              (j.state = ? AND j.lease_expires_at IS NOT NULL AND j.lease_expires_at < ?)
            ) \(exclusionPredicate)
            ORDER BY
              CASE j.state WHEN 'queued' THEN 0
                           WHEN 'retryableFailed' THEN 1 ELSE 2 END,
              j.retry_count, j.revision, j.id
            LIMIT 1
            """,
          arguments: claimArguments
        )
      else { return nil }
      try db.execute(
        sql: """
          UPDATE durable_jobs SET revision = revision + 1, state = ?,
            error_category = ?, lease_owner = ?, lease_expires_at = ?
          WHERE id = ?
          """,
        arguments: [
          DurableJobState.running.rawValue,
          DurableJobErrorCategory.none.rawValue,
          workerID.uuidString,
          now.addingTimeInterval(leaseDuration).timeIntervalSince1970,
          jobID,
        ]
      )
      return try Self.speakerJobInput(jobID: jobID, in: db)
    }
  }

  /// Persists one resumable bundle job for the four default meeting/media
  /// documents. The task set is versioned in the deterministic job identity;
  /// individual documents remain independently versioned and idempotent.
  @discardableResult
  public func scheduleDefaultLocalTextWork(
    sessionID: SessionID,
    inputRevision: UInt64,
    modelArtifactKey: String,
    configHash: SHA256Digest
  ) async throws -> DurableJob {
    guard inputRevision > 0, !modelArtifactKey.isEmpty else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let modelArtifactID = ModelArtifactID(
      Self.deterministicUUID(["model-artifact-key-v1", modelArtifactKey])
    )
    let job = DurableJob(
      id: DurableJobID(
        Self.deterministicUUID([
          "default-local-text-bundle-v1",
          sessionID.rawValue.uuidString.lowercased(),
          String(inputRevision),
          modelArtifactKey,
          configHash.value,
        ])
      ),
      revision: try Revision(1),
      kind: .localText,
      state: .queued,
      inputRevision: try Revision(inputRevision),
      modelArtifactID: modelArtifactID,
      configHash: configHash,
      retryCount: 0,
      errorCategory: .none,
      leaseOwner: nil,
      leaseExpiresAt: nil
    )
    let database = try requirePool()
    try await database.write { db in
      guard
        let modeValue = try String.fetchOne(
          db,
          sql: "SELECT input_mode FROM sessions WHERE id = ?",
          arguments: [sessionID.rawValue.uuidString]
        ), let mode = SessionInputMode(rawValue: modeValue), mode != .dictation
      else { throw BestASRPersistenceError.missingSession }
      if let existing = try Row.fetchOne(
        db,
        sql: """
          SELECT j.*, d.session_id FROM durable_jobs j
          JOIN dictation_job_sessions d ON d.job_id = j.id
          WHERE j.id = ?
          """,
        arguments: [job.id.rawValue.uuidString]
      ) {
        let stored = try Self.durableJob(existing)
        guard stored.kind == job.kind,
          stored.inputRevision == job.inputRevision,
          stored.modelArtifactID == job.modelArtifactID,
          stored.configHash == job.configHash,
          existing["session_id"] as String == sessionID.rawValue.uuidString
        else { throw BestASRPersistenceError.processingCommitConflict }
      } else {
        try Self.insert(job: job, sessionID: sessionID, in: db)
      }
    }
    return job
  }

  /// Requeues local-text bundles only when their recorded production
  /// configuration no longer matches the active runtime. Calling this on every
  /// launch is idempotent; a deterministic failure under the current
  /// configuration is not silently retried forever.
  public func requeueDefaultLocalTextJobsForConfiguration(
    modelArtifactKey: String,
    configHash: SHA256Digest
  ) async throws -> Int {
    guard !modelArtifactKey.isEmpty else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let modelArtifactID = ModelArtifactID(
      Self.deterministicUUID(["model-artifact-key-v1", modelArtifactKey])
    )
    let database = try requirePool()
    return try await database.write { db in
      try db.execute(
        sql: """
          UPDATE durable_jobs
          SET revision = revision + 1,
              state = ?,
              model_artifact_id = ?,
              config_hash = ?,
              retry_count = 0,
              error_category = ?,
              lease_owner = NULL,
              lease_expires_at = NULL
          WHERE kind = ?
            AND (model_artifact_id IS NOT ? OR config_hash <> ?)
            AND EXISTS (
              SELECT 1 FROM dictation_job_sessions mapping
              WHERE mapping.job_id = durable_jobs.id
            )
          """,
        arguments: [
          DurableJobState.queued.rawValue,
          modelArtifactID.rawValue.uuidString,
          configHash.value,
          DurableJobErrorCategory.none.rawValue,
          DurableJobKind.localText.rawValue,
          modelArtifactID.rawValue.uuidString,
          configHash.value,
        ]
      )
      return db.changesCount
    }
  }

  public func claimNextDefaultLocalTextJob(
    workerID: UUID,
    excludingJobIDs: Set<DurableJobID> = [],
    modelArtifactKey: String,
    leaseDuration: TimeInterval = 900,
    now: Date = Date()
  ) async throws -> LocalTextBundleJobRecord? {
    guard !modelArtifactKey.isEmpty,
      leaseDuration >= 30, leaseDuration <= 3_600
    else { throw BestASRPersistenceError.invalidSnapshot }
    let expectedModelID = Self.deterministicUUID([
      "model-artifact-key-v1", modelArtifactKey,
    ]).uuidString
    let excludedValues = excludingJobIDs.map { $0.rawValue.uuidString }.sorted()
    let exclusionPlaceholders = Array(
      repeating: "?",
      count: excludedValues.count
    ).joined(separator: ", ")
    let exclusionPredicate: String
    if excludedValues.isEmpty {
      exclusionPredicate = ""
    } else {
      exclusionPredicate = "AND j.id NOT IN (\(exclusionPlaceholders))"
    }
    let database = try requirePool()
    return try await database.write { db in
      var claimArguments = StatementArguments()
      claimArguments += [
        DurableJobKind.localText.rawValue,
        expectedModelID,
        DurableJobState.queued.rawValue,
        DurableJobState.retryableFailed.rawValue,
        DurableJobState.running.rawValue,
      ]
      claimArguments += [now.timeIntervalSince1970]
      claimArguments += StatementArguments(excludedValues)
      guard
        let jobID = try String.fetchOne(
          db,
          sql: """
            SELECT j.id FROM durable_jobs j
            JOIN dictation_job_sessions d ON d.job_id = j.id
            WHERE j.kind = ? AND j.model_artifact_id = ? AND (
              j.state = ? OR j.state = ? OR
              (j.state = ? AND j.lease_expires_at IS NOT NULL AND j.lease_expires_at < ?)
            ) \(exclusionPredicate)
            ORDER BY
              CASE j.state WHEN 'queued' THEN 0
                           WHEN 'retryableFailed' THEN 1 ELSE 2 END,
              j.retry_count, j.input_revision, j.id
            LIMIT 1
            """,
          arguments: claimArguments
        )
      else { return nil }
      try db.execute(
        sql: """
          UPDATE durable_jobs SET revision = revision + 1, state = ?,
            error_category = ?, lease_owner = ?, lease_expires_at = ?
          WHERE id = ?
          """,
        arguments: [
          DurableJobState.running.rawValue,
          DurableJobErrorCategory.none.rawValue,
          workerID.uuidString,
          now.addingTimeInterval(leaseDuration).timeIntervalSince1970,
          jobID,
        ]
      )
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT j.*, d.session_id FROM durable_jobs j
            JOIN dictation_job_sessions d ON d.job_id = j.id
            WHERE j.id = ?
            """,
          arguments: [jobID]
        ), let sessionUUID = UUID(uuidString: row["session_id"] as String)
      else { throw BestASRPersistenceError.storedDataCorrupt }
      return LocalTextBundleJobRecord(
        job: try Self.durableJob(row),
        sessionID: SessionID(sessionUUID)
      )
    }
  }

  public func completeDefaultLocalTextJob(
    jobID: DurableJobID,
    workerID: UUID
  ) async throws {
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE durable_jobs SET revision = revision + 1, state = ?,
            error_category = ?, lease_owner = NULL, lease_expires_at = NULL
          WHERE id = ? AND state = ? AND lease_owner = ?
          """,
        arguments: [
          DurableJobState.succeeded.rawValue,
          DurableJobErrorCategory.none.rawValue,
          jobID.rawValue.uuidString,
          DurableJobState.running.rawValue,
          workerID.uuidString,
        ]
      )
      guard db.changesCount == 1 else {
        throw BestASRPersistenceError.processingCommitConflict
      }
    }
  }

  public func failDefaultLocalTextJob(
    jobID: DurableJobID,
    workerID: UUID,
    category: DurableJobErrorCategory,
    retryable: Bool
  ) async throws {
    guard category != .none else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE durable_jobs SET revision = revision + 1, state = ?,
            retry_count = retry_count + 1, error_category = ?,
            lease_owner = NULL, lease_expires_at = NULL
          WHERE id = ? AND state = ? AND lease_owner = ?
          """,
        arguments: [
          retryable
            ? DurableJobState.retryableFailed.rawValue
            : DurableJobState.permanentFailed.rawValue,
          category.rawValue,
          jobID.rawValue.uuidString,
          DurableJobState.running.rawValue,
          workerID.uuidString,
        ]
      )
      guard db.changesCount == 1 else {
        throw BestASRPersistenceError.processingCommitConflict
      }
    }
  }

  public func loadPersonEmbeddings(
    embeddingSpaceID: String
  ) async throws -> [StoredPersonEmbedding] {
    guard !embeddingSpaceID.isEmpty else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let database = try requirePool()
    return try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT pe.id, pe.person_id, pe.revision, pe.embedding_space_id,
                 pe.vector_json, pe.speech_duration_ns, pe.signal_quality
          FROM person_embeddings pe
          JOIN persons p ON p.id = pe.person_id
          WHERE pe.embedding_space_id = ? AND pe.retired_at IS NULL
            AND p.retired_at IS NULL
          ORDER BY pe.person_id, pe.revision DESC, pe.id
          """,
        arguments: [embeddingSpaceID]
      ).map(Self.personEmbedding)
    }
  }

  /// Creates the stable, local "self" person used for the microphone track in
  /// system-audio meetings. Existing user edits are never overwritten.
  public func ensureLocalSelfPerson(
    personID: PersonID,
    now: Date = Date()
  ) async throws {
    let database = try requirePool()
    try await database.write { db in
      let emptyAliases = String(
        decoding: try JSONEncoder().encode([String]()),
        as: UTF8.self
      )
      try db.execute(
        sql: """
          INSERT INTO persons (
            id, revision, display_name, aliases_json, created_at, updated_at,
            retired_at, merged_into_person_id
          ) VALUES (?, 1, ?, ?, ?, ?, NULL, NULL)
          ON CONFLICT(id) DO NOTHING
          """,
        arguments: [
          personID.rawValue.uuidString,
          "我",
          emptyAliases,
          now.timeIntervalSince1970,
          now.timeIntervalSince1970,
        ]
      )
      guard
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM persons WHERE id = ? AND retired_at IS NULL)",
          arguments: [personID.rawValue.uuidString]
        ) == true
      else { throw BestASRPersistenceError.processingCommitConflict }
    }
  }

  /// Returns user-rejected voice/person pairings for the same embedding
  /// space. Retired people are followed through their merge chain so a
  /// rejection remains effective after a person merge and naturally reverts
  /// if that merge is undone.
  public func loadRejectedPersonMatches(
    embeddingSpaceID: String
  ) async throws -> [StoredRejectedPersonMatch] {
    guard !embeddingSpaceID.isEmpty else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let database = try requirePool()
    return try await database.read { db in
      let personRows = try Row.fetchAll(
        db,
        sql: "SELECT id, merged_into_person_id FROM persons"
      )
      var mergedInto: [UUID: UUID] = [:]
      for row in personRows {
        guard let id = UUID(uuidString: row["id"]) else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        let target: String? = row["merged_into_person_id"]
        if let target {
          guard let uuid = UUID(uuidString: target) else {
            throw BestASRPersistenceError.storedDataCorrupt
          }
          mergedInto[id] = uuid
        }
      }

      func activePerson(_ start: UUID) throws -> UUID {
        var current = start
        var visited = Set<UUID>()
        while let next = mergedInto[current] {
          guard visited.insert(current).inserted else {
            throw BestASRPersistenceError.storedDataCorrupt
          }
          current = next
        }
        return current
      }

      return try Row.fetchAll(
        db,
        sql: """
          SELECT id, candidate_person_id, embedding_space_id, vector_json
          FROM rejected_person_matches
          WHERE embedding_space_id = ?
          ORDER BY candidate_person_id, id
          """,
        arguments: [embeddingSpaceID]
      ).map { row in
        guard let id = UUID(uuidString: row["id"]),
          let candidate = UUID(uuidString: row["candidate_person_id"])
        else { throw BestASRPersistenceError.storedDataCorrupt }
        let data: Data = row["vector_json"]
        let vector: [Float]
        do { vector = try JSONDecoder().decode([Float].self, from: data) } catch {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        return StoredRejectedPersonMatch(
          id: id,
          candidatePersonID: PersonID(try activePerson(candidate)),
          embeddingSpaceID: row["embedding_space_id"],
          vector: vector
        )
      }
    }
  }

  /// Explicit privacy action. Removes biometric vectors while preserving raw
  /// audio, transcript evidence, user-confirmed labels and person names.
  public func deleteAllSpeakerEmbeddings() async throws {
    let database = try requirePool()
    try await database.write { db in
      let affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
        personValues: Set(
          try String.fetchAll(db, sql: "SELECT DISTINCT person_id FROM event_people")
        ),
        in: db
      )
      try db.execute(sql: "DELETE FROM rejected_person_matches")
      try db.execute(sql: "DELETE FROM person_embeddings")
      try db.execute(sql: "DELETE FROM session_speaker_embeddings")
      try db.execute(
        sql: """
          UPDATE speaker_occurrences
          SET association_status = ?, person_id = NULL, confidence = NULL
          WHERE association_status IN (?, ?, ?)
          """,
        arguments: [
          PersonAssociationStatus.unknown.rawValue,
          PersonAssociationStatus.anonymousIdentity.rawValue,
          PersonAssociationStatus.automaticMatch.rawValue,
          PersonAssociationStatus.candidate.rawValue,
        ]
      )
      try Self.refreshEventAggregates(
        eventIDs: affectedEventIDs,
        at: Date(),
        in: db
      )
    }
  }

  public func deleteSpeakerEmbeddings(personID: PersonID) async throws {
    let database = try requirePool()
    try await database.write { db in
      let personValue = personID.rawValue.uuidString
      let affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
        personValues: Set([personValue]),
        in: db
      )
      try db.execute(
        sql: """
          DELETE FROM rejected_person_matches
          WHERE candidate_person_id = ? OR session_speaker_id IN (
            SELECT DISTINCT session_speaker_id FROM speaker_occurrences
            WHERE person_id = ?
          )
          """,
        arguments: [personValue, personValue]
      )
      try db.execute(
        sql: """
          DELETE FROM session_speaker_embeddings
          WHERE session_speaker_id IN (
            SELECT DISTINCT session_speaker_id FROM speaker_occurrences
            WHERE person_id = ?
          )
          """,
        arguments: [personValue]
      )
      try db.execute(
        sql: "DELETE FROM person_embeddings WHERE person_id = ?",
        arguments: [personValue]
      )
      try db.execute(
        sql: """
          UPDATE speaker_occurrences
          SET association_status = ?, person_id = NULL, confidence = NULL
          WHERE person_id = ? AND association_status IN (?, ?, ?)
          """,
        arguments: [
          PersonAssociationStatus.unknown.rawValue,
          personValue,
          PersonAssociationStatus.anonymousIdentity.rawValue,
          PersonAssociationStatus.automaticMatch.rawValue,
          PersonAssociationStatus.candidate.rawValue,
        ]
      )
      try Self.refreshEventAggregates(
        eventIDs: affectedEventIDs,
        at: Date(),
        in: db
      )
    }
  }

  /// Removes a person identity and every biometric vector/association while
  /// deliberately preserving sessions, source audio, transcripts and speaker
  /// occurrences. The tombstone prevents migration or future sync from
  /// silently resurrecting the deleted identity.
  public func retirePersonAndClearAssociations(
    personID: PersonID,
    originDeviceID: UUID,
    now: Date = Date()
  ) async throws {
    let database = try requirePool()
    try await database.write { db in
      let personValue = personID.rawValue.uuidString
      let affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
        personValues: Set([personValue]),
        in: db
      )
      guard
        let revision = try Int64.fetchOne(
          db,
          sql: "SELECT revision FROM persons WHERE id = ? AND retired_at IS NULL",
          arguments: [personValue]
        ), revision > 0
      else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      let nextRevision = revision + 1
      try db.execute(
        sql: """
          DELETE FROM rejected_person_matches
          WHERE candidate_person_id = ? OR session_speaker_id IN (
            SELECT DISTINCT session_speaker_id FROM speaker_occurrences
            WHERE person_id = ?
          )
          """,
        arguments: [personValue, personValue]
      )
      try db.execute(
        sql: """
          DELETE FROM session_speaker_embeddings
          WHERE session_speaker_id IN (
            SELECT DISTINCT session_speaker_id FROM speaker_occurrences
            WHERE person_id = ?
          )
          """,
        arguments: [personValue]
      )
      try db.execute(
        sql: "DELETE FROM person_embeddings WHERE person_id = ?",
        arguments: [personValue]
      )
      try db.execute(
        sql: """
          UPDATE speaker_occurrences
          SET association_status = ?, person_id = NULL, confidence = NULL
          WHERE person_id = ?
          """,
        arguments: [
          PersonAssociationStatus.unknown.rawValue,
          personValue,
        ]
      )
      try db.execute(
        sql: "UPDATE speaker_name_evidence SET person_id = NULL WHERE person_id = ?",
        arguments: [personValue]
      )
      try db.execute(
        sql: """
          UPDATE persons
          SET revision = ?, retired_at = ?, merged_into_person_id = NULL,
              updated_at = ?
          WHERE id = ?
          """,
        arguments: [
          nextRevision,
          now.timeIntervalSince1970,
          now.timeIntervalSince1970,
          personValue,
        ]
      )
      let payload = Data("retire-person-and-unlink-v1".utf8)
      let digest = SHA256.hash(data: payload).map {
        String(format: "%02x", $0)
      }.joined()
      let changeID = UUID()
      try db.execute(
        sql: """
          INSERT INTO change_log (
            id, entity_kind, entity_stable_id, revision, occurred_at,
            origin_device_id, operation, payload_digest,
            person_correction_id
          ) VALUES (?, 'person', ?, ?, ?, ?, ?, ?, NULL)
          """,
        arguments: [
          changeID.uuidString,
          personValue,
          nextRevision,
          now.timeIntervalSince1970,
          originDeviceID.uuidString,
          "retire-person-and-unlink",
          digest,
        ]
      )
      try db.execute(
        sql: """
          INSERT INTO tombstones (
            id, entity_kind, entity_stable_id, revision, deleted_at,
            deletion_scope, change_id
          ) VALUES (?, 'person', ?, ?, ?, ?, ?)
          """,
        arguments: [
          Self.deterministicUUID([
            "person-tombstone-v1",
            personValue.lowercased(),
            String(nextRevision),
          ]).uuidString,
          personValue,
          nextRevision,
          now.timeIntervalSince1970,
          "identity-biometric-and-association-only",
          changeID.uuidString,
        ]
      )
      try Self.refreshEventAggregates(
        eventIDs: affectedEventIDs,
        at: now,
        in: db
      )
    }
  }

  public func rejectSessionSpeakerCandidate(
    sessionSpeakerID: SessionSpeakerID,
    candidatePersonID: PersonID,
    originDeviceID: UUID,
    now: Date = Date()
  ) async throws {
    let database = try requirePool()
    try await database.write { db in
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let inverseRows = try Self.associationInverseRows(
        sessionSpeakerID: sessionSpeakerID,
        in: db
      )
      let inverseRejectedMatches = try Self.rejectedMatchInverseRows(
        sessionSpeakerID: sessionSpeakerID,
        in: db
      )
      let previousRejectionIDs = Set(inverseRejectedMatches.map(\.id))
      var introducedRejectionIDs: [UUID] = []
      let embeddingRows = try Row.fetchAll(
        db,
        sql: """
          SELECT embedding_space_id, vector_json
          FROM session_speaker_embeddings
          WHERE session_speaker_id = ?
          ORDER BY revision DESC, embedding_space_id
          """,
        arguments: [sessionSpeakerID.rawValue.uuidString]
      )
      var recordedSpaces = Set<String>()
      for embeddingRow in embeddingRows {
        let space: String = embeddingRow["embedding_space_id"]
        guard recordedSpaces.insert(space).inserted else { continue }
        let vectorData: Data = embeddingRow["vector_json"]
        let vector: [Float]
        do { vector = try JSONDecoder().decode([Float].self, from: vectorData) } catch {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        let rejectionID = Self.deterministicUUID([
          "rejected-person-match-v1",
          sessionSpeakerID.rawValue.uuidString.lowercased(),
          candidatePersonID.rawValue.uuidString.lowercased(),
          space,
        ])
        if !previousRejectionIDs.contains(rejectionID) {
          introducedRejectionIDs.append(rejectionID)
        }
        try db.execute(
          sql: """
            INSERT INTO rejected_person_matches (
              id, session_speaker_id, candidate_person_id,
              embedding_space_id, vector_json, created_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_speaker_id, candidate_person_id, embedding_space_id)
            DO UPDATE SET vector_json = excluded.vector_json,
                          created_at = excluded.created_at
            """,
          arguments: [
            rejectionID.uuidString,
            sessionSpeakerID.rawValue.uuidString,
            candidatePersonID.rawValue.uuidString,
            space,
            try encoder.encode(vector),
            now.timeIntervalSince1970,
          ]
        )
      }
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT id, revision FROM speaker_occurrences
          WHERE session_speaker_id = ? AND person_id = ?
          ORDER BY monotonic_start_ns, id
          """,
        arguments: [
          sessionSpeakerID.rawValue.uuidString,
          candidatePersonID.rawValue.uuidString,
        ]
      )
      guard !rows.isEmpty else { throw BestASRPersistenceError.missingSession }
      let sessionValues = Set(
        try String.fetchAll(
          db,
          sql: "SELECT DISTINCT session_id FROM speaker_occurrences WHERE session_speaker_id = ?",
          arguments: [sessionSpeakerID.rawValue.uuidString]
        )
      )
      let affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
        sessionValues: sessionValues,
        personValues: Set([candidatePersonID.rawValue.uuidString]),
        in: db
      )
      for row in rows {
        let occurrenceValue: String = row["id"]
        guard let occurrenceUUID = UUID(uuidString: occurrenceValue) else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        let revision: Int64 = row["revision"]
        try db.execute(
          sql: """
            UPDATE speaker_occurrences
            SET association_status = ?, confidence = NULL,
                evidence_revision = ?
            WHERE id = ?
            """,
          arguments: [
            PersonAssociationStatus.rejected.rawValue,
            revision,
            occurrenceValue,
          ]
        )
        let payload = PersonCorrectionPayload.reject(
          occurrenceID: SpeakerOccurrenceID(occurrenceUUID),
          candidatePersonID: candidatePersonID
        )
        let payloadData = try encoder.encode(payload)
        let correctionID = PersonCorrectionID()
        try db.execute(
          sql: """
            INSERT INTO person_corrections (
              id, revision, occurred_at, actor, payload_json,
              reverses_operation_id
            ) VALUES (?, ?, ?, ?, ?, NULL)
            """,
          arguments: [
            correctionID.rawValue.uuidString,
            revision,
            now.timeIntervalSince1970,
            PersonCorrectionActor.user.rawValue,
            String(decoding: payloadData, as: UTF8.self),
          ]
        )
        let payloadDigest = SHA256.hash(data: payloadData).map {
          String(format: "%02x", $0)
        }.joined()
        try db.execute(
          sql: """
            INSERT INTO change_log (
              id, entity_kind, entity_stable_id, revision, occurred_at,
              origin_device_id, operation, payload_digest,
              person_correction_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            UUID().uuidString,
            "speaker_occurrence",
            occurrenceValue,
            revision,
            now.timeIntervalSince1970,
            originDeviceID.uuidString,
            "reject-person-candidate",
            payloadDigest,
            correctionID.rawValue.uuidString,
          ]
        )
      }
      guard let firstRow = rows.first,
        let firstID = UUID(uuidString: firstRow["id"] as String)
      else { throw BestASRPersistenceError.storedDataCorrupt }
      try Self.recordPersonEdit(
        payload: .reject(
          occurrenceID: SpeakerOccurrenceID(firstID),
          candidatePersonID: candidatePersonID
        ),
        inverse: .association(
          sessionSpeakerID: sessionSpeakerID.rawValue,
          rows: inverseRows,
          rejectedMatches: inverseRejectedMatches,
          introducedRejectedMatchIDs: introducedRejectionIDs,
          createdPersonID: nil,
          createdEmbeddingIDs: []
        ),
        kind: "reject-person-association",
        entityID: candidatePersonID.rawValue,
        originDeviceID: originDeviceID,
        now: now,
        in: db
      )
      try Self.refreshEventAggregates(
        eventIDs: affectedEventIDs,
        at: now,
        in: db
      )
    }
  }

  public func clearSessionSpeakerAssociation(
    sessionSpeakerID: SessionSpeakerID,
    originDeviceID: UUID,
    now: Date = Date()
  ) async throws {
    let database = try requirePool()
    try await database.write { db in
      let inverseRows = try Self.associationInverseRows(
        sessionSpeakerID: sessionSpeakerID,
        in: db
      )
      guard let first = inverseRows.first else {
        throw BestASRPersistenceError.missingSession
      }
      let sessionValues = Set(
        try String.fetchAll(
          db,
          sql: "SELECT DISTINCT session_id FROM speaker_occurrences WHERE session_speaker_id = ?",
          arguments: [sessionSpeakerID.rawValue.uuidString]
        )
      )
      let affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
        sessionValues: sessionValues,
        personValues: Set(inverseRows.compactMap(\.personID).map(\.uuidString)),
        in: db
      )
      let inverseRejectedMatches = try Self.rejectedMatchInverseRows(
        sessionSpeakerID: sessionSpeakerID,
        in: db
      )
      try db.execute(
        sql: "DELETE FROM rejected_person_matches WHERE session_speaker_id = ?",
        arguments: [sessionSpeakerID.rawValue.uuidString]
      )
      try db.execute(
        sql: """
          UPDATE speaker_occurrences
          SET association_status = ?, person_id = NULL, confidence = NULL
          WHERE session_speaker_id = ?
          """,
        arguments: [
          PersonAssociationStatus.unknown.rawValue,
          sessionSpeakerID.rawValue.uuidString,
        ]
      )
      guard db.changesCount > 0 else {
        throw BestASRPersistenceError.missingSession
      }
      let auditPersonID =
        first.personID.map(PersonID.init)
        ?? PersonID(
          Self.deterministicUUID([
            "unlinked-person-placeholder-v1",
            sessionSpeakerID.rawValue.uuidString.lowercased(),
          ])
        )
      try Self.recordPersonEdit(
        payload: .reject(
          occurrenceID: SpeakerOccurrenceID(first.occurrenceID),
          candidatePersonID: auditPersonID
        ),
        inverse: .association(
          sessionSpeakerID: sessionSpeakerID.rawValue,
          rows: inverseRows,
          rejectedMatches: inverseRejectedMatches,
          introducedRejectedMatchIDs: [],
          createdPersonID: nil,
          createdEmbeddingIDs: []
        ),
        kind: "clear-person-association",
        entityID: first.personID ?? sessionSpeakerID.rawValue,
        originDeviceID: originDeviceID,
        now: now,
        in: db
      )
      try Self.refreshEventAggregates(
        eventIDs: affectedEventIDs,
        at: now,
        in: db
      )
    }
  }

  public func requeueAutomaticSpeakerJobs(
    modelArtifactKey: String,
    embeddingSpaceID: String,
    configHash: SHA256Digest
  ) async throws -> Int {
    guard !modelArtifactKey.isEmpty, !embeddingSpaceID.isEmpty else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let modelArtifactID = ModelArtifactID(
      Self.deterministicUUID(["model-artifact-key-v1", modelArtifactKey])
    )
    let database = try requirePool()
    return try await database.write { db in
      let jobIDs = try String.fetchAll(
        db,
        sql: """
          SELECT id FROM durable_jobs
          WHERE kind = ? AND state IN (?, ?, ?, ?)
            AND id IN (SELECT job_id FROM speaker_job_inputs)
            AND NOT EXISTS (
              SELECT 1
              FROM dictation_job_sessions d
              JOIN speaker_occurrences so ON so.session_id = d.session_id
              WHERE d.job_id = durable_jobs.id
                AND so.association_status = ?
                AND so.person_id IS NOT NULL
              GROUP BY so.session_speaker_id
              HAVING COUNT(DISTINCT so.person_id) > 1
            )
          """,
        arguments: [
          DurableJobKind.speakerFinal.rawValue,
          DurableJobState.queued.rawValue,
          DurableJobState.succeeded.rawValue,
          DurableJobState.retryableFailed.rawValue,
          DurableJobState.permanentFailed.rawValue,
          PersonAssociationStatus.userConfirmed.rawValue,
        ]
      )
      for jobID in jobIDs {
        try db.execute(
          sql: """
            UPDATE durable_jobs
            SET revision = revision + 1, state = ?, retry_count = 0,
                error_category = ?, lease_owner = NULL,
                lease_expires_at = NULL, model_artifact_id = ?,
                config_hash = ?
            WHERE id = ?
            """,
          arguments: [
            DurableJobState.queued.rawValue,
            DurableJobErrorCategory.none.rawValue,
            modelArtifactID.rawValue.uuidString,
            configHash.value,
            jobID,
          ]
        )
        try db.execute(
          sql: """
            UPDATE speaker_job_inputs
            SET model_artifact_key = ?, embedding_space_id = ?
            WHERE job_id = ?
            """,
          arguments: [modelArtifactKey, embeddingSpaceID, jobID]
        )
      }
      return jobIDs.count
    }
  }

  public func sessionSpeakerSummaries(
    sessionID: SessionID
  ) async throws -> [SessionSpeakerSummary] {
    let database = try requirePool()
    return try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT ss.id, ss.stable_ordinal,
                 so.association_status, so.person_id, so.confidence,
                 so.monotonic_start_ns, so.monotonic_end_ns,
                 p.display_name
          FROM session_speakers ss
          JOIN speaker_occurrences so ON so.session_speaker_id = ss.id
          LEFT JOIN persons p ON p.id = so.person_id
          WHERE ss.session_id = ?
          ORDER BY ss.stable_ordinal, so.monotonic_start_ns, so.id
          """,
        arguments: [sessionID.rawValue.uuidString]
      )
      let grouped = Dictionary(grouping: rows) { row -> String in row["id"] }
      return try grouped.values.map { speakerRows in
        guard
          let first = speakerRows.first,
          let speakerUUID = UUID(uuidString: first["id"] as String)
        else { throw BestASRPersistenceError.storedDataCorrupt }
        let ordinal: Int64 = first["stable_ordinal"]
        guard ordinal > 0, ordinal <= Int64(UInt32.max) else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        let selected =
          speakerRows.max { lhs, rhs in
            Self.associationRank(lhs["association_status"])
              < Self.associationRank(rhs["association_status"])
          } ?? first
        guard
          let status = PersonAssociationStatus(
            rawValue: selected["association_status"]
          )
        else { throw BestASRPersistenceError.storedDataCorrupt }
        let personValue: String? = selected["person_id"]
        let personID = try personValue.map { value -> PersonID in
          guard let uuid = UUID(uuidString: value) else {
            throw BestASRPersistenceError.storedDataCorrupt
          }
          return PersonID(uuid)
        }
        let confidenceValue: Double? = selected["confidence"]
        let duration = try speakerRows.reduce(UInt64(0)) { partial, row in
          let start: Int64 = row["monotonic_start_ns"]
          let end: Int64 = row["monotonic_end_ns"]
          guard start >= 0, end > start else {
            throw BestASRPersistenceError.storedDataCorrupt
          }
          return partial + UInt64(end - start)
        }
        return SessionSpeakerSummary(
          id: SessionSpeakerID(speakerUUID),
          stableOrdinal: UInt32(ordinal),
          personID: personID,
          displayName: selected["display_name"],
          associationStatus: status,
          confidence: try confidenceValue.map(Confidence.init),
          speechDurationNanoseconds: duration,
          occurrenceCount: speakerRows.count
        )
      }.sorted { $0.stableOrdinal < $1.stableOrdinal }
    }
  }

  public func personSummaries() async throws -> [PersonSummary] {
    let database = try requirePool()
    return try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT p.*,
            (SELECT COUNT(*) FROM speaker_occurrences so
              WHERE so.person_id = p.id AND so.association_status IN (
                'anonymousIdentity', 'automaticMatch', 'userConfirmed'
              ))
              AS occurrence_count,
            (SELECT COUNT(*) FROM person_embeddings pe
              WHERE pe.person_id = p.id AND pe.retired_at IS NULL)
              AS embedding_count,
            (SELECT COUNT(DISTINCT so.session_id)
              FROM speaker_occurrences so
              WHERE so.person_id = p.id AND so.association_status IN (
                'anonymousIdentity', 'automaticMatch', 'userConfirmed'
              ))
              AS session_count,
            (SELECT COALESCE(SUM(
                so.monotonic_end_ns - so.monotonic_start_ns
              ), 0)
              FROM speaker_occurrences so
              WHERE so.person_id = p.id AND so.association_status IN (
                'anonymousIdentity', 'automaticMatch', 'userConfirmed'
              ))
              AS speech_duration_ns,
            (SELECT MAX(s.created_at)
              FROM speaker_occurrences so
              JOIN sessions s ON s.id = so.session_id
              WHERE so.person_id = p.id AND so.association_status IN (
                'anonymousIdentity', 'automaticMatch', 'userConfirmed'
              ))
              AS latest_occurrence_at
          FROM persons p
          WHERE p.retired_at IS NULL
          ORDER BY p.display_name COLLATE NOCASE, p.created_at, p.id
          """
      ).map(Self.personSummary)
    }
  }

  public func pendingPersonReviewCandidates(
    limit: Int = 200
  ) async throws -> [PersonReviewCandidateSummary] {
    let boundedLimit = min(max(limit, 0), 500)
    guard boundedLimit > 0 else { return [] }
    let database = try requirePool()
    return try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          WITH candidate_occurrences AS (
            SELECT ss.id AS speaker_id,
                   ss.session_id,
                   ss.stable_ordinal,
                   o.id AS occurrence_id,
                   o.monotonic_start_ns,
                   o.monotonic_end_ns,
                   o.person_id,
                   o.confidence,
                   p.display_name,
                   session_record.created_at,
                   COUNT(*) OVER (PARTITION BY ss.id) AS occurrence_count,
                   SUM(o.monotonic_end_ns - o.monotonic_start_ns)
                     OVER (PARTITION BY ss.id) AS speech_duration_ns,
                   ROW_NUMBER() OVER (
                     PARTITION BY ss.id
                     ORDER BY o.monotonic_start_ns, o.id
                   ) AS occurrence_position
            FROM session_speakers ss
            JOIN speaker_occurrences o ON o.session_speaker_id = ss.id
            JOIN sessions session_record ON session_record.id = ss.session_id
            JOIN persons p ON p.id = o.person_id
            WHERE o.association_status = 'candidate'
              AND p.retired_at IS NULL
          )
          SELECT *
          FROM candidate_occurrences
          WHERE occurrence_position = 1
          ORDER BY created_at DESC, stable_ordinal, speaker_id
          LIMIT ?
          """,
        arguments: [boundedLimit]
      ).map(Self.personReviewCandidateSummary)
    }
  }

  public func sessionOccurrenceSummaries(
    sessionID: SessionID
  ) async throws -> [SpeakerOccurrenceSummary] {
    let database = try requirePool()
    return try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT o.id, o.session_id, o.session_speaker_id,
                 s.stable_ordinal, o.monotonic_start_ns,
                 o.monotonic_end_ns, o.person_id, p.display_name,
                 o.association_status
          FROM speaker_occurrences o
          JOIN session_speakers s ON s.id = o.session_speaker_id
          LEFT JOIN persons p ON p.id = o.person_id
          WHERE o.session_id = ?
          ORDER BY o.monotonic_start_ns, o.monotonic_end_ns, o.id
          """,
        arguments: [sessionID.rawValue.uuidString]
      ).map { row in
        guard
          let occurrenceID = UUID(uuidString: row["id"] as String),
          let rawSessionID = UUID(uuidString: row["session_id"] as String),
          let speakerID = UUID(
            uuidString: row["session_speaker_id"] as String
          ),
          let status = PersonAssociationStatus(
            rawValue: row["association_status"] as String
          )
        else { throw BestASRPersistenceError.storedDataCorrupt }
        let ordinal: Int64 = row["stable_ordinal"]
        let start: Int64 = row["monotonic_start_ns"]
        let end: Int64 = row["monotonic_end_ns"]
        guard ordinal > 0, ordinal <= Int64(UInt32.max), start >= 0, end > start
        else { throw BestASRPersistenceError.storedDataCorrupt }
        let personValue: String? = row["person_id"]
        let personID = personValue.flatMap(UUID.init(uuidString:)).map(PersonID.init)
        return SpeakerOccurrenceSummary(
          id: SpeakerOccurrenceID(occurrenceID),
          sessionID: SessionID(rawSessionID),
          sessionSpeakerID: SessionSpeakerID(speakerID),
          stableOrdinal: UInt32(ordinal),
          monotonicStartNanoseconds: UInt64(start),
          monotonicEndNanoseconds: UInt64(end),
          personID: personID,
          personDisplayName: row["display_name"],
          associationStatus: status
        )
      }
    }
  }

  public func personOccurrenceSummaries(
    personID: PersonID
  ) async throws -> [SpeakerOccurrenceSummary] {
    let database = try requirePool()
    return try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT o.id, o.session_id, o.session_speaker_id,
                 s.stable_ordinal, o.monotonic_start_ns,
                 o.monotonic_end_ns, o.person_id, p.display_name,
                 o.association_status
          FROM speaker_occurrences o
          JOIN session_speakers s ON s.id = o.session_speaker_id
          LEFT JOIN persons p ON p.id = o.person_id
          JOIN sessions session_record ON session_record.id = o.session_id
          WHERE o.person_id = ? AND o.association_status IN (
            'anonymousIdentity', 'automaticMatch', 'userConfirmed'
          )
          ORDER BY session_record.created_at DESC,
                   o.monotonic_start_ns, o.id
          """,
        arguments: [personID.rawValue.uuidString]
      ).map(Self.occurrenceSummary)
    }
  }

  @discardableResult
  public func renamePerson(
    personID: PersonID,
    displayName: String,
    aliases: [String],
    originDeviceID: UUID,
    now: Date = Date()
  ) async throws -> Person {
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedAliases = Self.normalizedPersonAliases(
      aliases,
      excluding: name
    )
    guard !name.isEmpty, name.utf8.count <= 256 else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let database = try requirePool()
    return try await database.write { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM persons WHERE id = ? AND retired_at IS NULL",
          arguments: [personID.rawValue.uuidString]
        )
      else { throw BestASRPersistenceError.storedDataCorrupt }
      let before = try Self.person(row)
      let affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
        personValues: Set([personID.rawValue.uuidString]),
        in: db
      )
      let nextRevision = before.revision.value + 1
      let aliasData = try JSONEncoder().encode(normalizedAliases)
      try db.execute(
        sql: """
          UPDATE persons SET revision = ?, display_name = ?, aliases_json = ?,
            updated_at = ? WHERE id = ? AND retired_at IS NULL
          """,
        arguments: [
          try Self.sqliteInt(nextRevision),
          name,
          String(decoding: aliasData, as: UTF8.self),
          now.timeIntervalSince1970,
          personID.rawValue.uuidString,
        ]
      )
      try Self.recordPersonEdit(
        payload: .rename(personID: personID, displayName: name),
        inverse: .rename(
          personID: personID.rawValue,
          displayName: before.displayName,
          aliases: before.aliases
        ),
        kind: "rename",
        entityID: personID.rawValue,
        originDeviceID: originDeviceID,
        now: now,
        in: db
      )
      try Self.refreshEventAggregates(
        eventIDs: affectedEventIDs,
        at: now,
        in: db
      )
      return Person(
        id: personID,
        revision: try Revision(nextRevision),
        displayName: name,
        aliases: normalizedAliases,
        createdAt: before.createdAt,
        updatedAt: now
      )
    }
  }

  public func mergePersons(
    primaryID: PersonID,
    mergedID: PersonID,
    originDeviceID: UUID,
    now: Date = Date()
  ) async throws {
    guard primaryID != mergedID else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let database = try requirePool()
    try await database.write { db in
      let affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
        personValues: Set([
          primaryID.rawValue.uuidString,
          mergedID.rawValue.uuidString,
        ]),
        in: db
      )
      guard
        let primaryRow = try Row.fetchOne(
          db,
          sql: "SELECT * FROM persons WHERE id = ? AND retired_at IS NULL",
          arguments: [primaryID.rawValue.uuidString]
        ),
        let mergedRow = try Row.fetchOne(
          db,
          sql: "SELECT * FROM persons WHERE id = ? AND retired_at IS NULL",
          arguments: [mergedID.rawValue.uuidString]
        )
      else { throw BestASRPersistenceError.storedDataCorrupt }
      let primary = try Self.person(primaryRow)
      let merged = try Self.person(mergedRow)
      let occurrenceValues = try String.fetchAll(
        db,
        sql: "SELECT id FROM speaker_occurrences WHERE person_id = ?",
        arguments: [mergedID.rawValue.uuidString]
      )
      let embeddingValues = try String.fetchAll(
        db,
        sql: "SELECT id FROM person_embeddings WHERE person_id = ?",
        arguments: [mergedID.rawValue.uuidString]
      )
      let nameEvidenceValues = try String.fetchAll(
        db,
        sql: "SELECT id FROM speaker_name_evidence WHERE person_id = ?",
        arguments: [mergedID.rawValue.uuidString]
      )
      let combinedAliases = Self.normalizedPersonAliases(
        primary.aliases + merged.aliases + [merged.displayName].compactMap { $0 },
        excluding: primary.displayName ?? ""
      )
      let aliasData = try JSONEncoder().encode(combinedAliases)
      try db.execute(
        sql: "UPDATE speaker_occurrences SET person_id = ? WHERE person_id = ?",
        arguments: [primaryID.rawValue.uuidString, mergedID.rawValue.uuidString]
      )
      try db.execute(
        sql: "UPDATE person_embeddings SET person_id = ? WHERE person_id = ?",
        arguments: [primaryID.rawValue.uuidString, mergedID.rawValue.uuidString]
      )
      try db.execute(
        sql: "UPDATE speaker_name_evidence SET person_id = ? WHERE person_id = ?",
        arguments: [primaryID.rawValue.uuidString, mergedID.rawValue.uuidString]
      )
      try db.execute(
        sql: """
          UPDATE persons SET revision = revision + 1, aliases_json = ?,
            updated_at = ? WHERE id = ?
          """,
        arguments: [
          String(decoding: aliasData, as: UTF8.self),
          now.timeIntervalSince1970,
          primaryID.rawValue.uuidString,
        ]
      )
      try db.execute(
        sql: """
          UPDATE persons SET revision = revision + 1, retired_at = ?,
            merged_into_person_id = ?, updated_at = ? WHERE id = ?
          """,
        arguments: [
          now.timeIntervalSince1970,
          primaryID.rawValue.uuidString,
          now.timeIntervalSince1970,
          mergedID.rawValue.uuidString,
        ]
      )
      try Self.recordPersonEdit(
        payload: .merge(primaryID: primaryID, mergedID: mergedID),
        inverse: .merge(
          primaryID: primaryID.rawValue,
          mergedID: mergedID.rawValue,
          occurrenceIDs: try Self.uuidValues(occurrenceValues),
          embeddingIDs: try Self.uuidValues(embeddingValues),
          nameEvidenceIDs: try Self.uuidValues(nameEvidenceValues),
          primaryAliases: primary.aliases
        ),
        kind: "merge",
        entityID: primaryID.rawValue,
        originDeviceID: originDeviceID,
        now: now,
        in: db
      )
      try Self.refreshEventAggregates(
        eventIDs: affectedEventIDs,
        at: now,
        in: db
      )
    }
  }

  @discardableResult
  public func splitPersonOccurrences(
    sourcePersonID: PersonID,
    occurrenceIDs: [SpeakerOccurrenceID],
    newDisplayName: String,
    originDeviceID: UUID,
    now: Date = Date()
  ) async throws -> Person {
    let name = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let uniqueIDs = Array(Set(occurrenceIDs)).sorted {
      $0.rawValue.uuidString < $1.rawValue.uuidString
    }
    guard !name.isEmpty, name.utf8.count <= 256,
      !uniqueIDs.isEmpty, uniqueIDs.count <= 5_000
    else { throw BestASRPersistenceError.invalidSnapshot }
    let database = try requirePool()
    return try await database.write { db in
      let affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
        personValues: Set([sourcePersonID.rawValue.uuidString]),
        in: db
      )
      guard
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM persons WHERE id = ? AND retired_at IS NULL)",
          arguments: [sourcePersonID.rawValue.uuidString]
        ) == true
      else { throw BestASRPersistenceError.storedDataCorrupt }
      let values = uniqueIDs.map { $0.rawValue.uuidString }
      let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT id, session_speaker_id FROM speaker_occurrences
          WHERE person_id = ? AND id IN (\(placeholders))
          """,
        arguments: StatementArguments(
          [sourcePersonID.rawValue.uuidString] + values
        )
      )
      guard rows.count == values.count else {
        throw BestASRPersistenceError.processingCommitConflict
      }
      let newPersonID = PersonID()
      try db.execute(
        sql: """
          INSERT INTO persons (
            id, revision, display_name, aliases_json, created_at, updated_at
          ) VALUES (?, 1, ?, '[]', ?, ?)
          """,
        arguments: [
          newPersonID.rawValue.uuidString,
          name,
          now.timeIntervalSince1970,
          now.timeIntervalSince1970,
        ]
      )
      try db.execute(
        sql:
          "UPDATE speaker_occurrences SET person_id = ?, association_status = ?, confidence = 1.0 WHERE id IN (\(placeholders))",
        arguments: StatementArguments(
          [
            newPersonID.rawValue.uuidString,
            PersonAssociationStatus.userConfirmed.rawValue,
          ] + values
        )
      )
      let movedEmbeddingValues = try String.fetchAll(
        db,
        sql:
          "SELECT id FROM person_embeddings WHERE person_id = ? AND source_occurrence_id IN (\(placeholders))",
        arguments: StatementArguments([sourcePersonID.rawValue.uuidString] + values)
      )
      if !movedEmbeddingValues.isEmpty {
        let embeddingPlaceholders = Array(
          repeating: "?",
          count: movedEmbeddingValues.count
        ).joined(separator: ",")
        try db.execute(
          sql: "UPDATE person_embeddings SET person_id = ? WHERE id IN (\(embeddingPlaceholders))",
          arguments: StatementArguments(
            [newPersonID.rawValue.uuidString] + movedEmbeddingValues
          )
        )
      }
      var createdEmbeddingIDs: [UUID] = []
      let speakers = Dictionary(grouping: rows) {
        $0["session_speaker_id"] as String
      }
      for (speakerValue, speakerRows) in speakers {
        let speakerOccurrenceValues = speakerRows.map { $0["id"] as String }
        let speakerOccurrencePlaceholders = Array(
          repeating: "?",
          count: speakerOccurrenceValues.count
        ).joined(separator: ",")
        let alreadyMoved =
          try Bool.fetchOne(
            db,
            sql: """
              SELECT EXISTS(
                SELECT 1 FROM person_embeddings
                WHERE person_id = ?
                  AND source_occurrence_id IN (\(speakerOccurrencePlaceholders))
              )
              """,
            arguments: StatementArguments(
              [newPersonID.rawValue.uuidString] + speakerOccurrenceValues
            )
          ) == true
        if alreadyMoved { continue }
        guard
          let sourceEmbedding = try Row.fetchOne(
            db,
            sql: """
              SELECT * FROM session_speaker_embeddings
              WHERE session_speaker_id = ? ORDER BY revision DESC LIMIT 1
              """,
            arguments: [speakerValue]
          )
        else { continue }
        let occurrenceValue: String = speakerRows[0]["id"]
        let embeddingID = Self.deterministicUUID([
          "person-split-embedding-v1",
          newPersonID.rawValue.uuidString.lowercased(),
          speakerValue.lowercased(),
          occurrenceValue.lowercased(),
        ])
        try db.execute(
          sql: """
            INSERT INTO person_embeddings (
              id, person_id, revision, embedding_space_id, vector_json,
              speech_duration_ns, signal_quality, source_occurrence_id,
              created_at, retired_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """,
          arguments: [
            embeddingID.uuidString,
            newPersonID.rawValue.uuidString,
            sourceEmbedding["revision"] as Int64,
            sourceEmbedding["embedding_space_id"] as String,
            sourceEmbedding["vector_json"] as Data,
            sourceEmbedding["speech_duration_ns"] as Int64,
            sourceEmbedding["signal_quality"] as Double,
            occurrenceValue,
            now.timeIntervalSince1970,
          ]
        )
        createdEmbeddingIDs.append(embeddingID)
      }
      try db.execute(
        sql: "UPDATE persons SET revision = revision + 1, updated_at = ? WHERE id = ?",
        arguments: [now.timeIntervalSince1970, sourcePersonID.rawValue.uuidString]
      )
      try Self.recordPersonEdit(
        payload: .split(
          sourcePersonID: sourcePersonID,
          newPersonID: newPersonID,
          occurrenceIDs: uniqueIDs
        ),
        inverse: .split(
          sourceID: sourcePersonID.rawValue,
          newPersonID: newPersonID.rawValue,
          occurrenceIDs: uniqueIDs.map(\.rawValue),
          movedEmbeddingIDs: try Self.uuidValues(movedEmbeddingValues),
          createdEmbeddingIDs: createdEmbeddingIDs
        ),
        kind: "split",
        entityID: sourcePersonID.rawValue,
        originDeviceID: originDeviceID,
        now: now,
        in: db
      )
      try Self.refreshEventAggregates(
        eventIDs: affectedEventIDs,
        at: now,
        in: db
      )
      return Person(
        id: newPersonID,
        revision: try Revision(1),
        displayName: name,
        aliases: [],
        createdAt: now,
        updatedAt: now
      )
    }
  }

  @discardableResult
  public func undoLastPersonEdit(
    originDeviceID: UUID,
    now: Date = Date()
  ) async throws -> Bool {
    let database = try requirePool()
    return try await database.write { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT * FROM person_edit_operations
            WHERE reversed_at IS NULL
            ORDER BY occurred_at DESC, id DESC LIMIT 1
            """
        )
      else { return false }
      let inverseData: Data = row["inverse_json"]
      let inverse = try JSONDecoder().decode(
        PersonEditInverse.self,
        from: inverseData
      )
      let affectedEventIDs: Set<EventID>
      switch inverse {
      case .rename(let personID, _, _):
        affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
          personValues: Set([personID.uuidString]),
          in: db
        )
      case .merge(let primaryID, let mergedID, _, _, _, _):
        affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
          personValues: Set([primaryID.uuidString, mergedID.uuidString]),
          in: db
        )
      case .split(let sourceID, let newPersonID, _, _, _):
        affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
          personValues: Set([sourceID.uuidString, newPersonID.uuidString]),
          in: db
        )
      case .association(let sessionSpeakerID, let rows, _, _, _, _):
        let sessionValues = Set(
          try String.fetchAll(
            db,
            sql: "SELECT DISTINCT session_id FROM speaker_occurrences WHERE session_speaker_id = ?",
            arguments: [sessionSpeakerID.uuidString]
          )
        )
        affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
          sessionValues: sessionValues,
          personValues: Set(rows.compactMap(\.personID).map(\.uuidString)),
          in: db
        )
      }
      let correctionValue: String = row["correction_id"]
      guard let correctionUUID = UUID(uuidString: correctionValue) else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      let reversePayload: PersonCorrectionPayload
      let entityID: UUID
      switch inverse {
      case .rename(let personID, let displayName, let aliases):
        let aliasData = try JSONEncoder().encode(aliases)
        try db.execute(
          sql: """
            UPDATE persons SET revision = revision + 1, display_name = ?,
              aliases_json = ?, updated_at = ? WHERE id = ?
            """,
          arguments: [
            displayName,
            String(decoding: aliasData, as: UTF8.self),
            now.timeIntervalSince1970,
            personID.uuidString,
          ]
        )
        reversePayload = .rename(
          personID: PersonID(personID),
          displayName: displayName ?? ""
        )
        entityID = personID
      case .merge(
        let primaryID,
        let mergedID,
        let occurrenceIDs,
        let embeddingIDs,
        let nameEvidenceIDs,
        let primaryAliases
      ):
        try Self.updateUUIDSet(
          table: "speaker_occurrences",
          column: "person_id",
          value: mergedID.uuidString,
          ids: occurrenceIDs,
          in: db
        )
        try Self.updateUUIDSet(
          table: "person_embeddings",
          column: "person_id",
          value: mergedID.uuidString,
          ids: embeddingIDs,
          in: db
        )
        try Self.updateUUIDSet(
          table: "speaker_name_evidence",
          column: "person_id",
          value: mergedID.uuidString,
          ids: nameEvidenceIDs ?? [],
          in: db
        )
        let aliasData = try JSONEncoder().encode(primaryAliases)
        try db.execute(
          sql:
            "UPDATE persons SET aliases_json = ?, revision = revision + 1, updated_at = ? WHERE id = ?",
          arguments: [
            String(decoding: aliasData, as: UTF8.self),
            now.timeIntervalSince1970,
            primaryID.uuidString,
          ]
        )
        try db.execute(
          sql:
            "UPDATE persons SET retired_at = NULL, merged_into_person_id = NULL, revision = revision + 1, updated_at = ? WHERE id = ?",
          arguments: [now.timeIntervalSince1970, mergedID.uuidString]
        )
        reversePayload = .split(
          sourcePersonID: PersonID(primaryID),
          newPersonID: PersonID(mergedID),
          occurrenceIDs: occurrenceIDs.map(SpeakerOccurrenceID.init)
        )
        entityID = primaryID
      case .split(
        let sourceID,
        let newPersonID,
        let occurrenceIDs,
        let movedEmbeddingIDs,
        let createdEmbeddingIDs
      ):
        try Self.updateUUIDSet(
          table: "speaker_occurrences",
          column: "person_id",
          value: sourceID.uuidString,
          ids: occurrenceIDs,
          in: db
        )
        try Self.updateUUIDSet(
          table: "person_embeddings",
          column: "person_id",
          value: sourceID.uuidString,
          ids: movedEmbeddingIDs,
          in: db
        )
        if !createdEmbeddingIDs.isEmpty {
          let placeholders = Array(
            repeating: "?",
            count: createdEmbeddingIDs.count
          ).joined(separator: ",")
          try db.execute(
            sql: "UPDATE person_embeddings SET retired_at = ? WHERE id IN (\(placeholders))",
            arguments: StatementArguments(
              [now.timeIntervalSince1970]
                + createdEmbeddingIDs.map(\.uuidString)
            )
          )
        }
        try db.execute(
          sql:
            "UPDATE persons SET retired_at = ?, merged_into_person_id = ?, revision = revision + 1, updated_at = ? WHERE id = ?",
          arguments: [
            now.timeIntervalSince1970,
            sourceID.uuidString,
            now.timeIntervalSince1970,
            newPersonID.uuidString,
          ]
        )
        reversePayload = .merge(
          primaryID: PersonID(sourceID),
          mergedID: PersonID(newPersonID)
        )
        entityID = sourceID
      case .association(
        let sessionSpeakerID,
        let rows,
        let rejectedMatches,
        let introducedRejectedMatchIDs,
        let createdPersonID,
        let createdEmbeddingIDs
      ):
        for row in rows {
          try db.execute(
            sql: """
              UPDATE speaker_occurrences
              SET person_id = ?, association_status = ?, confidence = ?,
                  evidence_revision = ?
              WHERE id = ? AND session_speaker_id = ?
              """,
            arguments: [
              row.personID?.uuidString,
              row.associationStatus,
              row.confidence,
              row.evidenceRevision,
              row.occurrenceID.uuidString,
              sessionSpeakerID.uuidString,
            ]
          )
          guard db.changesCount == 1 else {
            throw BestASRPersistenceError.processingCommitConflict
          }
        }
        if !introducedRejectedMatchIDs.isEmpty {
          let placeholders = Array(
            repeating: "?",
            count: introducedRejectedMatchIDs.count
          ).joined(separator: ",")
          try db.execute(
            sql: "DELETE FROM rejected_person_matches WHERE id IN (\(placeholders))",
            arguments: StatementArguments(
              introducedRejectedMatchIDs.map(\.uuidString)
            )
          )
        }
        for rejection in rejectedMatches {
          try db.execute(
            sql: """
              INSERT INTO rejected_person_matches (
                id, session_speaker_id, candidate_person_id,
                embedding_space_id, vector_json, created_at
              ) VALUES (?, ?, ?, ?, ?, ?)
              ON CONFLICT(session_speaker_id, candidate_person_id, embedding_space_id)
              DO UPDATE SET vector_json = excluded.vector_json,
                            created_at = excluded.created_at
              """,
            arguments: [
              rejection.id.uuidString,
              rejection.sessionSpeakerID.uuidString,
              rejection.candidatePersonID.uuidString,
              rejection.embeddingSpaceID,
              rejection.vectorData,
              rejection.createdAt,
            ]
          )
        }
        if !createdEmbeddingIDs.isEmpty {
          let placeholders = Array(
            repeating: "?",
            count: createdEmbeddingIDs.count
          ).joined(separator: ",")
          try db.execute(
            sql: "DELETE FROM person_embeddings WHERE id IN (\(placeholders))",
            arguments: StatementArguments(createdEmbeddingIDs.map(\.uuidString))
          )
        }
        if let createdPersonID {
          try db.execute(
            sql: """
              DELETE FROM persons WHERE id = ?
                AND NOT EXISTS (
                  SELECT 1 FROM speaker_occurrences WHERE person_id = persons.id
                )
                AND NOT EXISTS (
                  SELECT 1 FROM person_embeddings WHERE person_id = persons.id
                )
              """,
            arguments: [createdPersonID.uuidString]
          )
        }
        guard let first = rows.first else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        if let restoredPersonID = first.personID {
          reversePayload = .confirm(
            occurrenceID: SpeakerOccurrenceID(first.occurrenceID),
            personID: PersonID(restoredPersonID)
          )
          entityID = restoredPersonID
        } else {
          let placeholder = createdPersonID ?? sessionSpeakerID
          reversePayload = .reject(
            occurrenceID: SpeakerOccurrenceID(first.occurrenceID),
            candidatePersonID: PersonID(placeholder)
          )
          entityID = sessionSpeakerID
        }
      }
      let reverseCorrectionID = PersonCorrectionID()
      let payloadData = try JSONEncoder().encode(reversePayload)
      let revision = max(1, Int64(now.timeIntervalSince1970 * 1_000_000))
      try db.execute(
        sql: """
          INSERT INTO person_corrections (
            id, revision, occurred_at, actor, payload_json,
            reverses_operation_id
          ) VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          reverseCorrectionID.rawValue.uuidString,
          revision,
          now.timeIntervalSince1970,
          PersonCorrectionActor.user.rawValue,
          String(decoding: payloadData, as: UTF8.self),
          correctionUUID.uuidString,
        ]
      )
      try db.execute(
        sql: "UPDATE person_edit_operations SET reversed_at = ? WHERE id = ?",
        arguments: [now.timeIntervalSince1970, row["id"] as String]
      )
      try Self.insertPersonChange(
        entityID: entityID,
        operation: "undo-person-edit",
        payloadData: payloadData,
        correctionID: reverseCorrectionID,
        revision: revision,
        originDeviceID: originDeviceID,
        now: now,
        in: db
      )
      try Self.refreshEventAggregates(
        eventIDs: affectedEventIDs,
        at: now,
        in: db
      )
      return true
    }
  }

  /// Records how long a retained original plays for, once something has
  /// measured it. History reads a session's length from here when its audio
  /// arrived as a file rather than through capture.
  public func setRetainedSourceDuration(
    sessionID: SessionID,
    durationNanoseconds: UInt64
  ) async throws {
    guard durationNanoseconds > 0 else { throw BestASRPersistenceError.invalidSnapshot }
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: "UPDATE session_source_assets SET duration_ns = ? WHERE session_id = ?",
        arguments: [try Self.sqliteInt(durationNanoseconds), sessionID.rawValue.uuidString]
      )
      guard db.changesCount > 0 else { throw BestASRPersistenceError.missingSession }
    }
  }

  public func saveRetainedSourceAsset(
    _ asset: RetainedSourceAssetRecord
  ) async throws {
    guard
      !asset.originalFilename.isEmpty,
      asset.originalFilename.utf8.count <= 1_024,
      !asset.mediaType.isEmpty,
      asset.sizeBytes > 0
    else { throw BestASRPersistenceError.invalidSnapshot }
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO session_source_assets (
            id, session_id, revision, kind, original_filename, media_type,
            asset_reference, digest, size_bytes, created_at, duration_ns
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          asset.id.uuidString,
          asset.sessionID.rawValue.uuidString,
          try Self.sqliteInt(asset.revision.value),
          asset.kind.rawValue,
          asset.originalFilename,
          asset.mediaType,
          Self.assetReference(asset.assetReference),
          asset.digest.value,
          try Self.sqliteInt(asset.sizeBytes),
          asset.createdAt.timeIntervalSince1970,
          try asset.durationNanoseconds.map { try Self.sqliteInt($0) },
        ]
      )
    }
  }

  public func retainedSourceAssets(
    sessionID: SessionID
  ) async throws -> [RetainedSourceAssetRecord] {
    let database = try requirePool()
    return try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM session_source_assets
          WHERE session_id = ? ORDER BY revision, kind, id
          """,
        arguments: [sessionID.rawValue.uuidString]
      ).map(Self.retainedSourceAsset)
    }
  }

  @discardableResult
  public func confirmSessionSpeaker(
    sessionSpeakerID: SessionSpeakerID,
    personID existingPersonID: PersonID?,
    newDisplayName: String?,
    originDeviceID: UUID,
    now: Date = Date()
  ) async throws -> Person {
    let displayName = newDisplayName?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      existingPersonID != nil || (displayName?.isEmpty == false),
      displayName.map({ $0.utf8.count <= 256 }) ?? true
    else { throw BestASRPersistenceError.invalidSnapshot }
    let newPersonID = existingPersonID ?? PersonID()
    let database = try requirePool()
    return try await database.write { db in
      guard
        let speakerRow = try Row.fetchOne(
          db,
          sql: "SELECT session_id, revision FROM session_speakers WHERE id = ?",
          arguments: [sessionSpeakerID.rawValue.uuidString]
        )
      else { throw BestASRPersistenceError.missingSession }
      let sessionValue: String = speakerRow["session_id"]
      let affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
        sessionValues: Set([sessionValue]),
        personValues: Set([newPersonID.rawValue.uuidString]),
        in: db
      )
      let embeddingRow = try Row.fetchOne(
        db,
        sql: """
          SELECT * FROM session_speaker_embeddings
          WHERE session_speaker_id = ?
          ORDER BY revision DESC, created_at DESC LIMIT 1
          """,
        arguments: [sessionSpeakerID.rawValue.uuidString]
      )
      let speakerRevision: Int64 = speakerRow["revision"]
      guard speakerRevision > 0 else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      let inverseRows = try Self.associationInverseRows(
        sessionSpeakerID: sessionSpeakerID,
        in: db
      )
      let inverseRejectedMatches = try Self.rejectedMatchInverseRows(
        sessionSpeakerID: sessionSpeakerID,
        in: db
      )
      var createdEmbeddingIDs: [UUID] = []

      let person: Person
      if let existingPersonID {
        guard
          let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM persons WHERE id = ?",
            arguments: [existingPersonID.rawValue.uuidString]
          )
        else { throw BestASRPersistenceError.storedDataCorrupt }
        person = try Self.person(row)
      } else {
        let aliases = "[]"
        try db.execute(
          sql: """
            INSERT INTO persons (
              id, revision, display_name, aliases_json, created_at, updated_at
            ) VALUES (?, 1, ?, ?, ?, ?)
            """,
          arguments: [
            newPersonID.rawValue.uuidString,
            displayName,
            aliases,
            now.timeIntervalSince1970,
            now.timeIntervalSince1970,
          ]
        )
        person = Person(
          id: newPersonID,
          revision: try Revision(1),
          displayName: displayName,
          aliases: [],
          createdAt: now,
          updatedAt: now
        )
      }

      let occurrenceRows = try Row.fetchAll(
        db,
        sql: """
          SELECT id FROM speaker_occurrences
          WHERE session_speaker_id = ? ORDER BY monotonic_start_ns, id
          """,
        arguments: [sessionSpeakerID.rawValue.uuidString]
      )
      guard !occurrenceRows.isEmpty else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      try db.execute(
        sql: """
          UPDATE speaker_occurrences SET association_status = ?, person_id = ?,
            confidence = 1.0, evidence_revision = ?
          WHERE session_speaker_id = ?
          """,
        arguments: [
          PersonAssociationStatus.userConfirmed.rawValue,
          newPersonID.rawValue.uuidString,
          speakerRevision,
          sessionSpeakerID.rawValue.uuidString,
        ]
      )

      if let embeddingRow {
        let firstOccurrenceID: String = occurrenceRows[0]["id"]
        let embeddingRevision: Int64 = embeddingRow["revision"]
        let embeddingID = Self.deterministicUUID([
          "person-embedding-v1",
          newPersonID.rawValue.uuidString.lowercased(),
          sessionSpeakerID.rawValue.uuidString.lowercased(),
          String(embeddingRevision),
        ])
        try db.execute(
          sql: """
            INSERT INTO person_embeddings (
              id, person_id, revision, embedding_space_id, vector_json,
              speech_duration_ns, signal_quality, source_occurrence_id,
              created_at, retired_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            ON CONFLICT(id) DO NOTHING
            """,
          arguments: [
            embeddingID.uuidString,
            newPersonID.rawValue.uuidString,
            embeddingRevision,
            embeddingRow["embedding_space_id"] as String,
            embeddingRow["vector_json"] as Data,
            embeddingRow["speech_duration_ns"] as Int64,
            embeddingRow["signal_quality"] as Double,
            firstOccurrenceID,
            now.timeIntervalSince1970,
          ]
        )
        if db.changesCount > 0 { createdEmbeddingIDs.append(embeddingID) }
      }

      try db.execute(
        sql: """
          DELETE FROM rejected_person_matches
          WHERE session_speaker_id = ? AND candidate_person_id = ?
          """,
        arguments: [
          sessionSpeakerID.rawValue.uuidString,
          newPersonID.rawValue.uuidString,
        ]
      )

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      for (index, occurrenceRow) in occurrenceRows.enumerated() {
        let occurrenceValue: String = occurrenceRow["id"]
        guard let occurrenceUUID = UUID(uuidString: occurrenceValue) else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        let payload = PersonCorrectionPayload.confirm(
          occurrenceID: SpeakerOccurrenceID(occurrenceUUID),
          personID: newPersonID
        )
        let payloadData = try encoder.encode(payload)
        let correctionID = Self.deterministicUUID([
          "person-confirm-v1",
          occurrenceValue.lowercased(),
          newPersonID.rawValue.uuidString.lowercased(),
          String(speakerRevision),
        ])
        try db.execute(
          sql: """
            INSERT INTO person_corrections (
              id, revision, occurred_at, actor, payload_json,
              reverses_operation_id
            ) VALUES (?, ?, ?, ?, ?, NULL)
            ON CONFLICT(id) DO NOTHING
            """,
          arguments: [
            correctionID.uuidString,
            speakerRevision + Int64(index),
            now.timeIntervalSince1970,
            PersonCorrectionActor.user.rawValue,
            String(decoding: payloadData, as: UTF8.self),
          ]
        )
        let changeID = Self.deterministicUUID([
          "person-confirm-change-v1", correctionID.uuidString.lowercased(),
        ])
        let payloadDigest = SHA256.hash(data: payloadData).map {
          String(format: "%02x", $0)
        }.joined()
        try db.execute(
          sql: """
            INSERT INTO change_log (
              id, entity_kind, entity_stable_id, revision, occurred_at,
              origin_device_id, operation, payload_digest,
              person_correction_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
          arguments: [
            changeID.uuidString,
            "speaker_occurrence",
            occurrenceValue,
            speakerRevision + Int64(index),
            now.timeIntervalSince1970,
            originDeviceID.uuidString,
            "confirm-person",
            payloadDigest,
            correctionID.uuidString,
          ]
        )
      }
      guard let firstOccurrence = occurrenceRows.first,
        let firstOccurrenceID = UUID(uuidString: firstOccurrence["id"] as String)
      else { throw BestASRPersistenceError.storedDataCorrupt }
      try Self.recordPersonEdit(
        payload: .confirm(
          occurrenceID: SpeakerOccurrenceID(firstOccurrenceID),
          personID: newPersonID
        ),
        inverse: .association(
          sessionSpeakerID: sessionSpeakerID.rawValue,
          rows: inverseRows,
          rejectedMatches: inverseRejectedMatches,
          introducedRejectedMatchIDs: [],
          createdPersonID: existingPersonID == nil ? newPersonID.rawValue : nil,
          createdEmbeddingIDs: createdEmbeddingIDs
        ),
        kind: "confirm-person-association",
        entityID: newPersonID.rawValue,
        originDeviceID: originDeviceID,
        now: now,
        in: db
      )
      try Self.refreshEventAggregates(
        eventIDs: affectedEventIDs,
        at: now,
        in: db
      )
      return person
    }
  }

  public func completeSpeakerFinalJob(
    jobID: DurableJobID,
    workerID: UUID,
    commit: SpeakerFinalPersistenceCommit,
    completedAt: Date = Date()
  ) async throws {
    guard
      !commit.sessionSpeakers.isEmpty,
      !commit.occurrences.isEmpty,
      commit.embeddings.isEmpty
        || Set(commit.embeddings.map(\.sessionSpeakerID))
          == Set(commit.sessionSpeakers.map(\.id)),
      commit.sessionSpeakers.allSatisfy({ $0.sessionID == commit.sessionID }),
      commit.occurrences.allSatisfy({ $0.sessionID == commit.sessionID }),
      Set(commit.sessionSpeakers.map(\.id)).count
        == commit.sessionSpeakers.count,
      Set(commit.sessionSpeakers.map(\.stableOrdinal)).count
        == commit.sessionSpeakers.count,
      Set(commit.occurrences.map(\.id)).count == commit.occurrences.count,
      commit.platformNameEvidence.allSatisfy({
        $0.sessionID == commit.sessionID
          && !$0.occurrenceIDs.isEmpty
          && !$0.sourceContextIDs.isEmpty
          && $0.alignedSpeechNanoseconds >= 1_000_000_000
      }),
      Set(commit.platformNameEvidence.map(\.sessionSpeakerID)).count
        == commit.platformNameEvidence.count
    else { throw BestASRPersistenceError.invalidSnapshot }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let database = try requirePool()
    try await database.write { db in
      guard
        let jobRow = try Row.fetchOne(
          db,
          sql: """
            SELECT j.state, j.lease_owner, d.session_id
            FROM durable_jobs j
            JOIN dictation_job_sessions d ON d.job_id = j.id
            WHERE j.id = ? AND j.kind = ?
            """,
          arguments: [jobID.rawValue.uuidString, DurableJobKind.speakerFinal.rawValue]
        ),
        jobRow["state"] as String == DurableJobState.running.rawValue,
        jobRow["lease_owner"] as String? == workerID.uuidString,
        jobRow["session_id"] as String == commit.sessionID.rawValue.uuidString
      else { throw BestASRPersistenceError.processingCommitConflict }

      let sessionValue = commit.sessionID.rawValue.uuidString
      let speakerValues = commit.sessionSpeakers.map { $0.id.rawValue.uuidString }
      let occurrenceValues = commit.occurrences.map { $0.id.rawValue.uuidString }

      let confirmedRows = try Row.fetchAll(
        db,
        sql: """
          SELECT id, session_speaker_id, person_id
          FROM speaker_occurrences
          WHERE session_id = ? AND association_status = ?
            AND person_id IS NOT NULL
          """,
        arguments: [
          sessionValue,
          PersonAssociationStatus.userConfirmed.rawValue,
        ]
      )
      let proposedConfirmedAnchors = Dictionary(
        uniqueKeysWithValues: commit.occurrences.map {
          ($0.id.rawValue.uuidString, $0.sessionSpeakerID.rawValue.uuidString)
        }
      )
      // A person may be confirmed while inference is already running. Never
      // delete or reassign that manual source anchor when publishing new clusters.
      guard
        confirmedRows.allSatisfy({ row in
          let id: String = row["id"]
          let speakerID: String = row["session_speaker_id"]
          return proposedConfirmedAnchors[id] == speakerID
        })
      else { throw BestASRPersistenceError.processingCommitConflict }
      var confirmedPersonSets: [String: Set<String>] = [:]
      var confirmedPersonIDsByOccurrence: [String: PersonID] = [:]
      for row in confirmedRows {
        let occurrence: String = row["id"]
        let speaker: String = row["session_speaker_id"]
        let person: String = row["person_id"]
        confirmedPersonSets[speaker, default: []].insert(person)
        guard let personUUID = UUID(uuidString: person) else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        confirmedPersonIDsByOccurrence[occurrence] = PersonID(personUUID)
      }
      let confirmedPersonIDs = confirmedPersonSets.compactMapValues {
        values -> PersonID? in
        guard values.count == 1, let value = values.first,
          let id = UUID(uuidString: value)
        else { return nil }
        return PersonID(id)
      }
      let priorAnonymousRows = try Row.fetchAll(
        db,
        sql: """
          SELECT so.session_speaker_id, so.person_id
          FROM speaker_occurrences so
          JOIN persons p ON p.id = so.person_id
          WHERE so.session_id = ? AND so.association_status = ?
            AND so.person_id IS NOT NULL AND p.retired_at IS NULL
          GROUP BY so.session_speaker_id
          HAVING COUNT(DISTINCT so.person_id) = 1
          """,
        arguments: [
          sessionValue,
          PersonAssociationStatus.anonymousIdentity.rawValue,
        ]
      )
      let priorAnonymousPersonIDs = try Dictionary(
        uniqueKeysWithValues: priorAnonymousRows.map { row -> (String, PersonID) in
          let speaker: String = row["session_speaker_id"]
          let person: String = row["person_id"]
          guard let personUUID = UUID(uuidString: person) else {
            throw BestASRPersistenceError.storedDataCorrupt
          }
          return (speaker, PersonID(personUUID))
        }
      )

      let occurrencePlaceholders = occurrenceValues.map { _ in "?" }
        .joined(separator: ", ")
      try db.execute(
        sql: """
          DELETE FROM speaker_occurrences
          WHERE session_id = ? AND id NOT IN (\(occurrencePlaceholders))
          """,
        arguments: StatementArguments([sessionValue] + occurrenceValues)
      )
      try db.execute(
        sql: """
          DELETE FROM speaker_occurrence_tracks
          WHERE occurrence_id IN (
            SELECT id FROM speaker_occurrences WHERE session_id = ?
          )
          """,
        arguments: [sessionValue]
      )
      try db.execute(
        sql: """
          DELETE FROM session_speaker_embeddings
          WHERE session_speaker_id IN (
            SELECT id FROM session_speakers WHERE session_id = ?
          )
          """,
        arguments: [sessionValue]
      )
      let speakerPlaceholders = speakerValues.map { _ in "?" }
        .joined(separator: ", ")
      try db.execute(
        sql: """
          DELETE FROM session_speakers
          WHERE session_id = ? AND id NOT IN (\(speakerPlaceholders))
          """,
        arguments: StatementArguments([sessionValue] + speakerValues)
      )

      for speaker in commit.sessionSpeakers {
        try db.execute(
          sql: """
            INSERT INTO session_speakers (
              id, session_id, revision, stable_ordinal
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              revision = excluded.revision,
              stable_ordinal = excluded.stable_ordinal
            """,
          arguments: [
            speaker.id.rawValue.uuidString,
            speaker.sessionID.rawValue.uuidString,
            try Self.sqliteInt(speaker.revision.value),
            Int64(speaker.stableOrdinal),
          ]
        )
      }

      let remoteTrackValues = Set(
        try String.fetchAll(
          db,
          sql: """
            SELECT id FROM tracks WHERE session_id = ? AND role = ?
            """,
          arguments: [sessionValue, SourceTrackRole.systemRemote.rawValue]
        )
      )
      let occurrencesByID = Dictionary(
        uniqueKeysWithValues: commit.occurrences.map {
          ($0.id, $0)
        }
      )
      let speakersByID = Dictionary(
        uniqueKeysWithValues: commit.sessionSpeakers.map { ($0.id, $0) }
      )
      var platformPersonIDs: [SessionSpeakerID: PersonID] = [:]
      var resolvedPlatformEvidence: [(evidence: PlatformSpeakerNameEvidence, personID: PersonID)] =
        []
      for evidence in commit.platformNameEvidence {
        let name = evidence.displayName.trimmingCharacters(
          in: .whitespacesAndNewlines
        )
        let normalizedName = Self.normalizedPlatformPersonName(name)
        let priorConfirmedPeople =
          confirmedPersonSets[
            evidence.sessionSpeakerID.rawValue.uuidString
          ] ?? []
        guard !name.isEmpty, name.utf8.count <= 256,
          !normalizedName.isEmpty,
          evidence.revision == speakersByID[evidence.sessionSpeakerID]?.revision,
          Set(evidence.occurrenceIDs).count == evidence.occurrenceIDs.count,
          Set(evidence.sourceContextIDs).count
            == evidence.sourceContextIDs.count
        else { throw BestASRPersistenceError.invalidSnapshot }
        // A prior occurrence-level split is a user decision. Reprocessing may
        // not collapse it back into one platform-derived identity.
        guard priorConfirmedPeople.count <= 1 else { continue }

        var alignedUpperBound: UInt64 = 0
        for occurrenceID in evidence.occurrenceIDs {
          guard let occurrence = occurrencesByID[occurrenceID],
            occurrence.sessionSpeakerID == evidence.sessionSpeakerID,
            !occurrence.overlapsAnotherSpeaker,
            occurrence.trackIDs.contains(where: {
              remoteTrackValues.contains($0.rawValue.uuidString)
            })
          else { throw BestASRPersistenceError.invalidSnapshot }
          let duration =
            occurrence.monotonicEndNanoseconds
            - occurrence.monotonicStartNanoseconds
          let sum = alignedUpperBound.addingReportingOverflow(duration)
          alignedUpperBound = sum.overflow ? UInt64.max : sum.partialValue
        }
        guard evidence.alignedSpeechNanoseconds <= alignedUpperBound else {
          throw BestASRPersistenceError.invalidSnapshot
        }

        let contextValues = evidence.sourceContextIDs.map(\.uuidString)
        let contextPlaceholders = contextValues.map { _ in "?" }
          .joined(separator: ", ")
        let contextRows = try Row.fetchAll(
          db,
          sql: """
            SELECT id, active_speaker_name, reliability
            FROM source_context_events
            WHERE session_id = ? AND id IN (\(contextPlaceholders))
            """,
          arguments: StatementArguments([sessionValue] + contextValues)
        )
        guard contextRows.count == contextValues.count,
          contextRows.allSatisfy({ row in
            let activeName: String? = row["active_speaker_name"]
            let reliability: String = row["reliability"]
            return reliability == SourceContextReliability.reliable.rawValue
              && activeName.map(Self.normalizedPlatformPersonName)
                == normalizedName
          })
        else { throw BestASRPersistenceError.invalidSnapshot }

        let confirmedPersonID = confirmedPersonIDs[
          evidence.sessionSpeakerID.rawValue.uuidString
        ]
        let voicePersonIDs = Set(
          commit.occurrences.compactMap { occurrence -> PersonID? in
            guard occurrence.sessionSpeakerID == evidence.sessionSpeakerID,
              occurrence.association.status == .automaticMatch
            else { return nil }
            return occurrence.association.personID
          }
        )
        let voicePersonID =
          voicePersonIDs.count == 1
          ? voicePersonIDs.first : nil
        let preferredPersonID = confirmedPersonID ?? voicePersonID
        let personID: PersonID
        if let preferredPersonID,
          let personRow = try Row.fetchOne(
            db,
            sql: "SELECT * FROM persons WHERE id = ? AND retired_at IS NULL",
            arguments: [preferredPersonID.rawValue.uuidString]
          )
        {
          let person = try Self.person(personRow)
          let knownNames =
            [person.displayName].compactMap { $0 }
            + person.aliases
          let normalizedKnownNames = Set(
            knownNames.map(Self.normalizedPlatformPersonName)
          )
          if normalizedKnownNames.isEmpty {
            try db.execute(
              sql: """
                UPDATE persons SET revision = revision + 1,
                  display_name = ?, updated_at = ?
                WHERE id = ? AND display_name IS NULL AND retired_at IS NULL
                """,
              arguments: [
                name,
                completedAt.timeIntervalSince1970,
                preferredPersonID.rawValue.uuidString,
              ]
            )
            personID = preferredPersonID
          } else if normalizedKnownNames.contains(normalizedName) {
            personID = preferredPersonID
          } else if confirmedPersonID != nil {
            // A user-confirmed identity/name outranks conflicting platform UI.
            continue
          } else {
            personID = PersonID(
              Self.deterministicUUID([
                "platform-named-person-v1",
                sessionValue.lowercased(),
                evidence.sessionSpeakerID.rawValue.uuidString.lowercased(),
                normalizedName,
              ])
            )
          }
        } else {
          personID = PersonID(
            Self.deterministicUUID([
              "platform-named-person-v1",
              sessionValue.lowercased(),
              evidence.sessionSpeakerID.rawValue.uuidString.lowercased(),
              normalizedName,
            ])
          )
        }
        if let existingPlatformPerson = try Row.fetchOne(
          db,
          sql: "SELECT retired_at FROM persons WHERE id = ?",
          arguments: [personID.rawValue.uuidString]
        ) {
          let retiredAt: Double? = existingPlatformPerson["retired_at"]
          guard retiredAt == nil else {
            // Explicit identity deletion must not be silently reversed by a
            // later automatic reprocess of the same meeting.
            continue
          }
        }
        try db.execute(
          sql: """
            INSERT INTO persons (
              id, revision, display_name, aliases_json, created_at, updated_at,
              retired_at, merged_into_person_id
            ) VALUES (?, 1, ?, '[]', ?, ?, NULL, NULL)
            ON CONFLICT(id) DO NOTHING
            """,
          arguments: [
            personID.rawValue.uuidString,
            name,
            completedAt.timeIntervalSince1970,
            completedAt.timeIntervalSince1970,
          ]
        )
        platformPersonIDs[evidence.sessionSpeakerID] = personID
        resolvedPlatformEvidence.append((evidence, personID))
      }

      // A sufficiently long, clean cluster that does not safely match an
      // existing person becomes a stable unnamed person.  This makes unknown
      // people searchable and matchable across every input mode without
      // inventing a name or promoting short/overlapped evidence.
      var anonymousPersonIDs: [SessionSpeakerID: PersonID] = [:]
      for embedding in commit.embeddings {
        guard
          (confirmedPersonSets[
            embedding.sessionSpeakerID.rawValue.uuidString
          ] ?? []).isEmpty,
          platformPersonIDs[embedding.sessionSpeakerID] == nil
        else { continue }
        let speakerOccurrences = commit.occurrences.filter {
          $0.sessionSpeakerID == embedding.sessionSpeakerID
        }
        let hasOnlyUnknownAssociations =
          !speakerOccurrences.isEmpty
          && speakerOccurrences.allSatisfy {
            $0.association.status == .unknown
              && $0.association.personID == nil
          }
        let hasCleanOccurrence = speakerOccurrences.contains {
          !$0.overlapsAnotherSpeaker
            && $0.monotonicEndNanoseconds - $0.monotonicStartNanoseconds
              >= 500_000_000
        }
        guard hasOnlyUnknownAssociations, hasCleanOccurrence,
          embedding.speechDurationNanoseconds >= 500_000_000,
          embedding.signalQuality.value >= 0.70
        else { continue }
        let personID =
          priorAnonymousPersonIDs[
            embedding.sessionSpeakerID.rawValue.uuidString
          ]
          ?? PersonID(
            Self.deterministicUUID([
              "anonymous-person-v2",
              commit.sessionID.rawValue.uuidString.lowercased(),
              embedding.sessionSpeakerID.rawValue.uuidString.lowercased(),
            ])
          )
        try db.execute(
          sql: """
            INSERT INTO persons (
              id, revision, display_name, aliases_json, created_at, updated_at,
              retired_at, merged_into_person_id
            ) VALUES (?, 1, NULL, '[]', ?, ?, NULL, NULL)
            ON CONFLICT(id) DO NOTHING
            """,
          arguments: [
            personID.rawValue.uuidString,
            completedAt.timeIntervalSince1970,
            completedAt.timeIntervalSince1970,
          ]
        )
        anonymousPersonIDs[embedding.sessionSpeakerID] = personID
      }
      for occurrence in commit.occurrences {
        let confirmedPersonID =
          confirmedPersonIDsByOccurrence[
            occurrence.id.rawValue.uuidString
          ]
          ?? confirmedPersonIDs[
            occurrence.sessionSpeakerID.rawValue.uuidString
          ]
        let platformPersonID = platformPersonIDs[occurrence.sessionSpeakerID]
        let anonymousPersonID = anonymousPersonIDs[occurrence.sessionSpeakerID]
        let associationStatus: PersonAssociationStatus
        let associatedPersonID: PersonID?
        let confidence: Double?
        if let confirmedPersonID {
          associationStatus = .userConfirmed
          associatedPersonID = confirmedPersonID
          confidence = 1
        } else if let platformPersonID {
          associationStatus = .automaticMatch
          associatedPersonID = platformPersonID
          confidence = 1
        } else if let anonymousPersonID {
          associationStatus = .anonymousIdentity
          associatedPersonID = anonymousPersonID
          confidence = nil
        } else {
          associationStatus = occurrence.association.status
          associatedPersonID = occurrence.association.personID
          confidence = occurrence.association.confidence?.value
        }
        try db.execute(
          sql: """
            INSERT INTO speaker_occurrences (
              id, session_id, session_speaker_id, revision,
              monotonic_start_ns, monotonic_end_ns,
              overlaps_another_speaker, association_status, person_id,
              confidence, evidence_revision
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              session_speaker_id = excluded.session_speaker_id,
              revision = excluded.revision,
              monotonic_start_ns = excluded.monotonic_start_ns,
              monotonic_end_ns = excluded.monotonic_end_ns,
              overlaps_another_speaker = excluded.overlaps_another_speaker,
              association_status = excluded.association_status,
              person_id = excluded.person_id,
              confidence = excluded.confidence,
              evidence_revision = excluded.evidence_revision
            """,
          arguments: [
            occurrence.id.rawValue.uuidString,
            occurrence.sessionID.rawValue.uuidString,
            occurrence.sessionSpeakerID.rawValue.uuidString,
            try Self.sqliteInt(occurrence.revision.value),
            try Self.sqliteInt(occurrence.monotonicStartNanoseconds),
            try Self.sqliteInt(occurrence.monotonicEndNanoseconds),
            occurrence.overlapsAnotherSpeaker,
            associationStatus.rawValue,
            associatedPersonID?.rawValue.uuidString,
            confidence,
            try Self.sqliteInt(occurrence.association.evidenceRevision.value),
          ]
        )
        for trackID in occurrence.trackIDs {
          try db.execute(
            sql: """
              INSERT INTO speaker_occurrence_tracks (occurrence_id, track_id)
              VALUES (?, ?)
              """,
            arguments: [
              occurrence.id.rawValue.uuidString,
              trackID.rawValue.uuidString,
            ]
          )
        }
      }
      try db.execute(
        sql: "DELETE FROM speaker_name_evidence WHERE session_id = ?",
        arguments: [sessionValue]
      )
      for resolved in resolvedPlatformEvidence {
        let contextData = try encoder.encode(
          resolved.evidence.sourceContextIDs.map(\.uuidString)
        )
        let occurrenceData = try encoder.encode(
          resolved.evidence.occurrenceIDs.map {
            $0.rawValue.uuidString
          }
        )
        try db.execute(
          sql: """
            INSERT INTO speaker_name_evidence (
              id, session_id, session_speaker_id, person_id, revision,
              display_name, source_kind, source_context_ids_json,
              occurrence_ids_json, aligned_speech_ns, reliability, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, 'platformActiveSpeaker', ?, ?, ?,
                      'reliable', ?)
            """,
          arguments: [
            resolved.evidence.id.uuidString,
            sessionValue,
            resolved.evidence.sessionSpeakerID.rawValue.uuidString,
            resolved.personID.rawValue.uuidString,
            try Self.sqliteInt(resolved.evidence.revision.value),
            resolved.evidence.displayName,
            contextData,
            occurrenceData,
            try Self.sqliteInt(resolved.evidence.alignedSpeechNanoseconds),
            completedAt.timeIntervalSince1970,
          ]
        )
      }
      for embedding in commit.embeddings {
        guard
          !embedding.vector.isEmpty,
          embedding.vector.allSatisfy(\.isFinite),
          embedding.speechDurationNanoseconds > 0
        else { throw BestASRPersistenceError.invalidSnapshot }
        try db.execute(
          sql: """
            INSERT INTO session_speaker_embeddings (
              session_speaker_id, revision, embedding_space_id, vector_json,
              speech_duration_ns, signal_quality, model_artifact_key, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            embedding.sessionSpeakerID.rawValue.uuidString,
            try Self.sqliteInt(embedding.revision.value),
            embedding.embeddingSpaceID,
            try encoder.encode(embedding.vector),
            try Self.sqliteInt(embedding.speechDurationNanoseconds),
            embedding.signalQuality.value,
            embedding.modelArtifactKey,
            completedAt.timeIntervalSince1970,
          ]
        )
        let cleanOccurrences = commit.occurrences.filter {
          $0.sessionSpeakerID == embedding.sessionSpeakerID
            && !$0.overlapsAnotherSpeaker
            && $0.monotonicEndNanoseconds - $0.monotonicStartNanoseconds
              >= 500_000_000
        }
        let automaticAssociation = cleanOccurrences.first {
          $0.association.status == .automaticMatch
            && $0.association.personID != nil
        }
        let priorConfirmedPeople =
          confirmedPersonSets[
            embedding.sessionSpeakerID.rawValue.uuidString
          ] ?? []
        let promotedPersonID =
          priorConfirmedPeople.count > 1
          ? nil
          : confirmedPersonIDs[
            embedding.sessionSpeakerID.rawValue.uuidString
          ]
            ?? platformPersonIDs[embedding.sessionSpeakerID]
            ?? anonymousPersonIDs[embedding.sessionSpeakerID]
            ?? automaticAssociation?.association.personID
        let sourceOccurrenceID =
          automaticAssociation?.id
          ?? cleanOccurrences.first?.id
        if let personID = promotedPersonID,
          let sourceOccurrenceID,
          embedding.speechDurationNanoseconds >= 500_000_000,
          embedding.signalQuality.value >= 0.70
        {
          let personEmbeddingID = Self.deterministicUUID([
            "person-evidence-center-v1",
            personID.rawValue.uuidString.lowercased(),
            embedding.sessionSpeakerID.rawValue.uuidString.lowercased(),
            String(embedding.revision.value),
            embedding.embeddingSpaceID,
          ])
          try db.execute(
            sql: """
              INSERT INTO person_embeddings (
                id, person_id, revision, embedding_space_id, vector_json,
                speech_duration_ns, signal_quality, source_occurrence_id,
                created_at, retired_at
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
              ON CONFLICT(id) DO NOTHING
              """,
            arguments: [
              personEmbeddingID.uuidString,
              personID.rawValue.uuidString,
              try Self.sqliteInt(embedding.revision.value),
              embedding.embeddingSpaceID,
              try encoder.encode(embedding.vector),
              try Self.sqliteInt(embedding.speechDurationNanoseconds),
              embedding.signalQuality.value,
              sourceOccurrenceID.rawValue.uuidString,
              completedAt.timeIntervalSince1970,
            ]
          )
        }
      }
      try db.execute(
        sql: """
          UPDATE durable_jobs SET revision = revision + 1, state = ?,
            error_category = ?, lease_owner = NULL, lease_expires_at = NULL
          WHERE id = ?
          """,
        arguments: [
          DurableJobState.succeeded.rawValue,
          DurableJobErrorCategory.none.rawValue,
          jobID.rawValue.uuidString,
        ]
      )
      try Self.refreshEventAggregates(
        eventIDs: try Self.eventIDsAffectedByIdentityChange(
          sessionValues: Set([sessionValue]),
          in: db
        ),
        at: completedAt,
        in: db
      )
    }
  }

  public func failSpeakerFinalJob(
    jobID: DurableJobID,
    workerID: UUID,
    category: DurableJobErrorCategory,
    retryable: Bool
  ) async throws {
    guard category != .none else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE durable_jobs SET revision = revision + 1, state = ?,
            retry_count = retry_count + 1, error_category = ?,
            lease_owner = NULL, lease_expires_at = NULL
          WHERE id = ? AND state = ? AND lease_owner = ?
          """,
        arguments: [
          retryable
            ? DurableJobState.retryableFailed.rawValue
            : DurableJobState.permanentFailed.rawValue,
          category.rawValue,
          jobID.rawValue.uuidString,
          DurableJobState.running.rawValue,
          workerID.uuidString,
        ]
      )
      guard db.changesCount == 1 else {
        throw BestASRPersistenceError.processingCommitConflict
      }
    }
  }

  private static func speakerJobInput(
    jobID: String,
    in db: Database
  ) throws -> SpeakerFinalJobInputRecord {
    guard
      let jobRow = try Row.fetchOne(
        db,
        sql: """
          SELECT j.*, d.session_id AS linked_session_id,
                 i.audio_ranges_json, i.model_artifact_key,
                 i.embedding_space_id
          FROM durable_jobs j
          JOIN dictation_job_sessions d ON d.job_id = j.id
          JOIN speaker_job_inputs i ON i.job_id = j.id
          WHERE j.id = ?
          """,
        arguments: [jobID]
      ),
      let sessionUUID = UUID(
        uuidString: jobRow["linked_session_id"] as String
      )
    else { throw BestASRPersistenceError.storedDataCorrupt }
    let sessionID = SessionID(sessionUUID)
    guard
      let sessionRow = try Row.fetchOne(
        db,
        sql: "SELECT * FROM sessions WHERE id = ?",
        arguments: [sessionUUID.uuidString]
      ),
      let inputMode = SessionInputMode(rawValue: sessionRow["input_mode"]),
      let state = SessionState(rawValue: sessionRow["state"]),
      let retention = SourceAudioRetention(
        rawValue: sessionRow["source_audio_retention"]
      )
    else { throw BestASRPersistenceError.storedDataCorrupt }
    let sessionRevision: Int64 = sessionRow["revision"]
    guard sessionRevision > 0 else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    let session = Session(
      id: sessionID,
      revision: try Revision(UInt64(sessionRevision)),
      inputMode: inputMode,
      state: state,
      createdAt: Date(timeIntervalSince1970: sessionRow["created_at"]),
      updatedAt: Date(timeIntervalSince1970: sessionRow["updated_at"]),
      sourceAudioRetention: retention
    )
    let tracks = try Row.fetchAll(
      db,
      sql: "SELECT * FROM tracks WHERE session_id = ? ORDER BY id",
      arguments: [sessionUUID.uuidString]
    ).map { row -> SourceTrack in
      guard
        let id = UUID(uuidString: row["id"]),
        let role = SourceTrackRole(rawValue: row["role"])
      else { throw BestASRPersistenceError.storedDataCorrupt }
      let revision: Int64 = row["revision"]
      let sampleRate: Int64 = row["sample_rate_hz"]
      let channels: Int64 = row["channel_count"]
      guard
        revision > 0,
        sampleRate > 0,
        sampleRate <= Int64(UInt32.max),
        channels > 0,
        channels <= Int64(UInt16.max)
      else { throw BestASRPersistenceError.storedDataCorrupt }
      return SourceTrack(
        id: TrackID(id),
        sessionID: sessionID,
        revision: try Revision(UInt64(revision)),
        role: role,
        assetReference: try PortableAssetReference(
          relativePath: row["asset_reference"]
        ),
        sampleRateHertz: UInt32(sampleRate),
        channelCount: UInt16(channels)
      )
    }
    let audioData: Data = jobRow["audio_ranges_json"]
    let audio: [AudioRangeInput]
    do {
      audio = try JSONDecoder().decode([AudioRangeInput].self, from: audioData)
    } catch {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    let knownTracks = Set(tracks.map { $0.id.rawValue })
    guard
      !audio.isEmpty,
      audio.allSatisfy({
        $0.sourceID == sessionUUID && knownTracks.contains($0.trackID)
      })
    else { throw BestASRPersistenceError.storedDataCorrupt }
    return SpeakerFinalJobInputRecord(
      job: try durableJob(jobRow),
      session: session,
      tracks: tracks,
      audio: audio,
      modelArtifactKey: jobRow["model_artifact_key"],
      embeddingSpaceID: jobRow["embedding_space_id"]
    )
  }

  private static func personEmbedding(_ row: Row) throws
    -> StoredPersonEmbedding
  {
    guard
      let id = UUID(uuidString: row["id"]),
      let personUUID = UUID(uuidString: row["person_id"])
    else { throw BestASRPersistenceError.storedDataCorrupt }
    let revision: Int64 = row["revision"]
    let duration: Int64 = row["speech_duration_ns"]
    let qualityValue: Double = row["signal_quality"]
    let data: Data = row["vector_json"]
    let vector: [Float]
    do {
      vector = try JSONDecoder().decode([Float].self, from: data)
    } catch {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    guard
      revision > 0,
      duration > 0,
      !vector.isEmpty,
      vector.allSatisfy(\.isFinite)
    else { throw BestASRPersistenceError.storedDataCorrupt }
    return StoredPersonEmbedding(
      id: id,
      personID: PersonID(personUUID),
      revision: try Revision(UInt64(revision)),
      embeddingSpaceID: row["embedding_space_id"],
      vector: vector,
      speechDurationNanoseconds: UInt64(duration),
      signalQuality: try Confidence(qualityValue)
    )
  }

  private static func associationRank(_ value: String) -> Int {
    switch PersonAssociationStatus(rawValue: value) {
    case .userConfirmed: 5
    case .automaticMatch: 4
    case .candidate: 3
    case .anonymousIdentity: 2
    case .unknown: 2
    case .rejected: 1
    case nil: 0
    }
  }

  private static func personSummary(_ row: Row) throws -> PersonSummary {
    let occurrenceCount: Int64 = row["occurrence_count"]
    let embeddingCount: Int64 = row["embedding_count"]
    let sessionCount: Int64 = row["session_count"]
    let speechDuration: Int64 = row["speech_duration_ns"]
    let latest: Double? = row["latest_occurrence_at"]
    guard occurrenceCount >= 0, embeddingCount >= 0,
      sessionCount >= 0, speechDuration >= 0
    else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    return PersonSummary(
      person: try person(row),
      occurrenceCount: Int(occurrenceCount),
      embeddingCount: Int(embeddingCount),
      sessionCount: Int(sessionCount),
      speechDurationNanoseconds: UInt64(speechDuration),
      latestOccurrenceAt: latest.map(Date.init(timeIntervalSince1970:))
    )
  }

  private static func occurrenceSummary(
    _ row: Row
  ) throws -> SpeakerOccurrenceSummary {
    guard
      let occurrenceID = UUID(uuidString: row["id"] as String),
      let rawSessionID = UUID(uuidString: row["session_id"] as String),
      let speakerID = UUID(uuidString: row["session_speaker_id"] as String),
      let status = PersonAssociationStatus(
        rawValue: row["association_status"] as String
      )
    else { throw BestASRPersistenceError.storedDataCorrupt }
    let ordinal: Int64 = row["stable_ordinal"]
    let start: Int64 = row["monotonic_start_ns"]
    let end: Int64 = row["monotonic_end_ns"]
    guard ordinal > 0, ordinal <= Int64(UInt32.max), start >= 0, end > start
    else { throw BestASRPersistenceError.storedDataCorrupt }
    let personValue: String? = row["person_id"]
    let personID = personValue.flatMap(UUID.init(uuidString:)).map(PersonID.init)
    return SpeakerOccurrenceSummary(
      id: SpeakerOccurrenceID(occurrenceID),
      sessionID: SessionID(rawSessionID),
      sessionSpeakerID: SessionSpeakerID(speakerID),
      stableOrdinal: UInt32(ordinal),
      monotonicStartNanoseconds: UInt64(start),
      monotonicEndNanoseconds: UInt64(end),
      personID: personID,
      personDisplayName: row["display_name"],
      associationStatus: status
    )
  }

  private static func personReviewCandidateSummary(
    _ row: Row
  ) throws -> PersonReviewCandidateSummary {
    guard
      let speakerUUID = UUID(uuidString: row["speaker_id"] as String),
      let sessionUUID = UUID(uuidString: row["session_id"] as String),
      let occurrenceUUID = UUID(uuidString: row["occurrence_id"] as String),
      let personUUID = UUID(uuidString: row["person_id"] as String)
    else { throw BestASRPersistenceError.storedDataCorrupt }
    let ordinal: Int64 = row["stable_ordinal"]
    let start: Int64 = row["monotonic_start_ns"]
    let end: Int64 = row["monotonic_end_ns"]
    let duration: Int64 = row["speech_duration_ns"]
    let occurrenceCount: Int64 = row["occurrence_count"]
    let confidence: Double = row["confidence"]
    guard ordinal > 0, ordinal <= Int64(UInt32.max), start >= 0,
      end > start, duration > 0, occurrenceCount > 0
    else { throw BestASRPersistenceError.storedDataCorrupt }
    return PersonReviewCandidateSummary(
      speakerID: SessionSpeakerID(speakerUUID),
      sessionID: SessionID(sessionUUID),
      representativeOccurrenceID: SpeakerOccurrenceID(occurrenceUUID),
      stableOrdinal: UInt32(ordinal),
      candidatePersonID: PersonID(personUUID),
      candidateDisplayName: row["display_name"],
      confidence: try Confidence(confidence),
      monotonicStartNanoseconds: UInt64(start),
      monotonicEndNanoseconds: UInt64(end),
      speechDurationNanoseconds: UInt64(duration),
      occurrenceCount: Int(occurrenceCount)
    )
  }

  private static func person(_ row: Row) throws -> Person {
    guard let uuid = UUID(uuidString: row["id"] as String) else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    let revision: Int64 = row["revision"]
    let aliasesValue: String = row["aliases_json"]
    let aliases: [String]
    do {
      aliases = try JSONDecoder().decode(
        [String].self,
        from: Data(aliasesValue.utf8)
      )
    } catch {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    guard revision > 0 else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    return Person(
      id: PersonID(uuid),
      revision: try Revision(UInt64(revision)),
      displayName: row["display_name"],
      aliases: aliases,
      createdAt: Date(timeIntervalSince1970: row["created_at"]),
      updatedAt: Date(timeIntervalSince1970: row["updated_at"])
    )
  }

  static func retainedSourceAsset(_ row: Row) throws
    -> RetainedSourceAssetRecord
  {
    guard
      let id = UUID(uuidString: row["id"] as String),
      let sessionUUID = UUID(uuidString: row["session_id"] as String),
      let kind = RetainedSourceAssetKind(rawValue: row["kind"] as String)
    else { throw BestASRPersistenceError.storedDataCorrupt }
    let revision: Int64 = row["revision"]
    let size: Int64 = row["size_bytes"]
    guard revision > 0, size > 0 else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    let duration: Int64? = row["duration_ns"]
    return RetainedSourceAssetRecord(
      id: id,
      sessionID: SessionID(sessionUUID),
      revision: try Revision(UInt64(revision)),
      kind: kind,
      originalFilename: row["original_filename"],
      mediaType: row["media_type"],
      assetReference: try PortableAssetReference(
        relativePath: row["asset_reference"]
      ),
      digest: try SHA256Digest(row["digest"]),
      sizeBytes: UInt64(size),
      createdAt: Date(timeIntervalSince1970: row["created_at"]),
      durationNanoseconds: duration.flatMap { $0 > 0 ? UInt64($0) : nil }
    )
  }
}

public struct BestASRPersistenceInspection: Codable, Equatable, Sendable {
  public let userVersion: Int
  public let appliedMigrations: [String]
  public let tableNames: [String]
  public let journalMode: String
  public let foreignKeysEnabled: Bool

  public init(
    userVersion: Int,
    appliedMigrations: [String],
    tableNames: [String],
    journalMode: String,
    foreignKeysEnabled: Bool
  ) {
    self.userVersion = userVersion
    self.appliedMigrations = appliedMigrations
    self.tableNames = tableNames
    self.journalMode = journalMode
    self.foreignKeysEnabled = foreignKeysEnabled
  }
}

public enum PortableSQLiteValue: Codable, Equatable, Sendable {
  case blob(Data)
  case double(Double)
  case integer(Int64)
  case null
  case text(String)

  fileprivate init(_ value: DatabaseValue) {
    switch value.storage {
    case .blob(let data): self = .blob(data)
    case .double(let value): self = .double(value)
    case .int64(let value): self = .integer(value)
    case .null: self = .null
    case .string(let value): self = .text(value)
    }
  }

  fileprivate var databaseValue: DatabaseValue {
    switch self {
    case .blob(let data): data.databaseValue
    case .double(let value): value.databaseValue
    case .integer(let value): value.databaseValue
    case .null: .null
    case .text(let value): value.databaseValue
    }
  }
}

public struct PortableDatabaseTable: Codable, Equatable, Sendable {
  public let name: String
  public let columns: [String]
  public let rows: [[PortableSQLiteValue]]

  public init(
    name: String,
    columns: [String],
    rows: [[PortableSQLiteValue]]
  ) {
    self.name = name
    self.columns = columns
    self.rows = rows
  }
}

public struct PortablePersistenceState: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let tables: [PortableDatabaseTable]

  public init(schemaVersion: Int, tables: [PortableDatabaseTable]) {
    self.schemaVersion = schemaVersion
    self.tables = tables
  }
}

public enum DictationDerivedTextState: String, Codable, Sendable {
  case current
  case stale
}

public struct LocalTextDocumentRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let sessionID: SessionID
  public let sourceTranscriptID: TranscriptRevisionID
  public let sourceRevision: Revision
  public let taskID: LocalTextTaskID
  public let modelArtifactID: String
  public let configHash: SHA256Digest
  public let result: LocalTextResult
  public let state: DictationDerivedTextState
  public let createdAt: Date

  public init(
    id: UUID,
    sessionID: SessionID,
    sourceTranscriptID: TranscriptRevisionID,
    sourceRevision: Revision,
    taskID: LocalTextTaskID,
    modelArtifactID: String,
    configHash: SHA256Digest,
    result: LocalTextResult,
    state: DictationDerivedTextState = .current,
    createdAt: Date
  ) {
    self.id = id
    self.sessionID = sessionID
    self.sourceTranscriptID = sourceTranscriptID
    self.sourceRevision = sourceRevision
    self.taskID = taskID
    self.modelArtifactID = modelArtifactID
    self.configHash = configHash
    self.result = result
    self.state = state
    self.createdAt = createdAt
  }
}

public struct DictationDerivedTextRecord: Codable, Equatable, Sendable {
  public let id: UUID
  public let sessionID: SessionID
  public let sourceTranscriptID: TranscriptRevisionID
  public let sourceRevision: Revision
  public let outputText: String
  public let modelArtifactID: String?
  public let configHash: SHA256Digest
  public let state: DictationDerivedTextState
  public let createdAt: Date

  public init(
    id: UUID,
    sessionID: SessionID,
    sourceTranscriptID: TranscriptRevisionID,
    sourceRevision: Revision,
    outputText: String,
    modelArtifactID: String?,
    configHash: SHA256Digest,
    state: DictationDerivedTextState,
    createdAt: Date
  ) {
    self.id = id
    self.sessionID = sessionID
    self.sourceTranscriptID = sourceTranscriptID
    self.sourceRevision = sourceRevision
    self.outputText = outputText
    self.modelArtifactID = modelArtifactID
    self.configHash = configHash
    self.state = state
    self.createdAt = createdAt
  }
}

public struct DictationPersistedTranscriptRecord: Codable, Equatable, Sendable {
  public let id: TranscriptRevisionID
  public let sessionID: SessionID
  public let inputRevision: UInt64
  public let parentID: TranscriptRevisionID?
  public let kind: TranscriptRevisionKind
  public let content: String
  public let modelArtifactID: String?
  public let configHash: SHA256Digest?
  public let languageHints: [String]
  public let audioRanges: [AudioRangeInput]
  public let segments: [DictationTranscriptSegment]
  public let createdAt: Date

  public init(
    id: TranscriptRevisionID,
    sessionID: SessionID,
    inputRevision: UInt64,
    parentID: TranscriptRevisionID?,
    kind: TranscriptRevisionKind,
    content: String,
    modelArtifactID: String?,
    configHash: SHA256Digest?,
    languageHints: [String],
    audioRanges: [AudioRangeInput],
    segments: [DictationTranscriptSegment],
    createdAt: Date
  ) {
    self.id = id
    self.sessionID = sessionID
    self.inputRevision = inputRevision
    self.parentID = parentID
    self.kind = kind
    self.content = content
    self.modelArtifactID = modelArtifactID
    self.configHash = configHash
    self.languageHints = languageHints
    self.audioRanges = audioRanges
    self.segments = segments
    self.createdAt = createdAt
  }
}

public struct DictationSpeakerWorkRecord: Codable, Equatable, Sendable {
  public let sessionSpeaker: SessionSpeaker
  public let occurrences: [SpeakerOccurrence]
  public let job: DurableJob

  public init(
    sessionSpeaker: SessionSpeaker,
    occurrences: [SpeakerOccurrence],
    job: DurableJob
  ) {
    self.sessionSpeaker = sessionSpeaker
    self.occurrences = occurrences
    self.job = job
  }
}

public struct SpeakerFinalJobInputRecord: Codable, Equatable, Sendable {
  public let job: DurableJob
  public let session: Session
  public let tracks: [SourceTrack]
  public let audio: [AudioRangeInput]
  public let modelArtifactKey: String
  public let embeddingSpaceID: String

  public init(
    job: DurableJob,
    session: Session,
    tracks: [SourceTrack],
    audio: [AudioRangeInput],
    modelArtifactKey: String,
    embeddingSpaceID: String
  ) {
    self.job = job
    self.session = session
    self.tracks = tracks
    self.audio = audio
    self.modelArtifactKey = modelArtifactKey
    self.embeddingSpaceID = embeddingSpaceID
  }
}

public struct StoredSpeakerEmbedding: Codable, Equatable, Sendable {
  public let sessionSpeakerID: SessionSpeakerID
  public let revision: Revision
  public let embeddingSpaceID: String
  public let vector: [Float]
  public let speechDurationNanoseconds: UInt64
  public let signalQuality: Confidence
  public let modelArtifactKey: String

  public init(
    sessionSpeakerID: SessionSpeakerID,
    revision: Revision,
    embeddingSpaceID: String,
    vector: [Float],
    speechDurationNanoseconds: UInt64,
    signalQuality: Confidence,
    modelArtifactKey: String
  ) {
    self.sessionSpeakerID = sessionSpeakerID
    self.revision = revision
    self.embeddingSpaceID = embeddingSpaceID
    self.vector = vector
    self.speechDurationNanoseconds = speechDurationNanoseconds
    self.signalQuality = signalQuality
    self.modelArtifactKey = modelArtifactKey
  }
}

public struct StoredPersonEmbedding: Codable, Equatable, Sendable {
  public let id: UUID
  public let personID: PersonID
  public let revision: Revision
  public let embeddingSpaceID: String
  public let vector: [Float]
  public let speechDurationNanoseconds: UInt64
  public let signalQuality: Confidence

  public init(
    id: UUID,
    personID: PersonID,
    revision: Revision,
    embeddingSpaceID: String,
    vector: [Float],
    speechDurationNanoseconds: UInt64,
    signalQuality: Confidence
  ) {
    self.id = id
    self.personID = personID
    self.revision = revision
    self.embeddingSpaceID = embeddingSpaceID
    self.vector = vector
    self.speechDurationNanoseconds = speechDurationNanoseconds
    self.signalQuality = signalQuality
  }
}

public struct StoredRejectedPersonMatch: Codable, Equatable, Sendable {
  public let id: UUID
  public let candidatePersonID: PersonID
  public let embeddingSpaceID: String
  public let vector: [Float]

  public init(
    id: UUID,
    candidatePersonID: PersonID,
    embeddingSpaceID: String,
    vector: [Float]
  ) {
    self.id = id
    self.candidatePersonID = candidatePersonID
    self.embeddingSpaceID = embeddingSpaceID
    self.vector = vector
  }
}

public struct SpeakerFinalPersistenceCommit: Codable, Equatable, Sendable {
  public let sessionID: SessionID
  public let sessionSpeakers: [SessionSpeaker]
  public let occurrences: [SpeakerOccurrence]
  public let embeddings: [StoredSpeakerEmbedding]
  public let platformNameEvidence: [PlatformSpeakerNameEvidence]

  public init(
    sessionID: SessionID,
    sessionSpeakers: [SessionSpeaker],
    occurrences: [SpeakerOccurrence],
    embeddings: [StoredSpeakerEmbedding],
    platformNameEvidence: [PlatformSpeakerNameEvidence] = []
  ) {
    self.sessionID = sessionID
    self.sessionSpeakers = sessionSpeakers
    self.occurrences = occurrences
    self.embeddings = embeddings
    self.platformNameEvidence = platformNameEvidence
  }
}

public struct SessionSpeakerSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: SessionSpeakerID
  public let stableOrdinal: UInt32
  public let personID: PersonID?
  public let displayName: String?
  public let associationStatus: PersonAssociationStatus
  public let confidence: Confidence?
  public let speechDurationNanoseconds: UInt64
  public let occurrenceCount: Int

  public init(
    id: SessionSpeakerID,
    stableOrdinal: UInt32,
    personID: PersonID?,
    displayName: String?,
    associationStatus: PersonAssociationStatus,
    confidence: Confidence?,
    speechDurationNanoseconds: UInt64,
    occurrenceCount: Int
  ) {
    self.id = id
    self.stableOrdinal = stableOrdinal
    self.personID = personID
    self.displayName = displayName
    self.associationStatus = associationStatus
    self.confidence = confidence
    self.speechDurationNanoseconds = speechDurationNanoseconds
    self.occurrenceCount = occurrenceCount
  }
}

public struct PersonReviewCandidateSummary: Codable, Equatable, Identifiable,
  Sendable
{
  public let speakerID: SessionSpeakerID
  public let sessionID: SessionID
  public let representativeOccurrenceID: SpeakerOccurrenceID
  public let stableOrdinal: UInt32
  public let candidatePersonID: PersonID
  public let candidateDisplayName: String?
  public let confidence: Confidence
  public let monotonicStartNanoseconds: UInt64
  public let monotonicEndNanoseconds: UInt64
  public let speechDurationNanoseconds: UInt64
  public let occurrenceCount: Int

  public var id: SessionSpeakerID { speakerID }

  public init(
    speakerID: SessionSpeakerID,
    sessionID: SessionID,
    representativeOccurrenceID: SpeakerOccurrenceID,
    stableOrdinal: UInt32,
    candidatePersonID: PersonID,
    candidateDisplayName: String?,
    confidence: Confidence,
    monotonicStartNanoseconds: UInt64,
    monotonicEndNanoseconds: UInt64,
    speechDurationNanoseconds: UInt64,
    occurrenceCount: Int
  ) {
    self.speakerID = speakerID
    self.sessionID = sessionID
    self.representativeOccurrenceID = representativeOccurrenceID
    self.stableOrdinal = stableOrdinal
    self.candidatePersonID = candidatePersonID
    self.candidateDisplayName = candidateDisplayName
    self.confidence = confidence
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.monotonicEndNanoseconds = monotonicEndNanoseconds
    self.speechDurationNanoseconds = speechDurationNanoseconds
    self.occurrenceCount = occurrenceCount
  }

  public var speaker: SessionSpeakerSummary {
    SessionSpeakerSummary(
      id: speakerID,
      stableOrdinal: stableOrdinal,
      personID: candidatePersonID,
      displayName: candidateDisplayName,
      associationStatus: .candidate,
      confidence: confidence,
      speechDurationNanoseconds: speechDurationNanoseconds,
      occurrenceCount: occurrenceCount
    )
  }

  public var representativeOccurrence: SpeakerOccurrenceSummary {
    SpeakerOccurrenceSummary(
      id: representativeOccurrenceID,
      sessionID: sessionID,
      sessionSpeakerID: speakerID,
      stableOrdinal: stableOrdinal,
      monotonicStartNanoseconds: monotonicStartNanoseconds,
      monotonicEndNanoseconds: monotonicEndNanoseconds,
      personID: candidatePersonID,
      personDisplayName: candidateDisplayName,
      associationStatus: .candidate
    )
  }
}

public struct PersonSummary: Codable, Equatable, Identifiable, Sendable {
  public let person: Person
  public let occurrenceCount: Int
  public let embeddingCount: Int
  public let sessionCount: Int
  public let speechDurationNanoseconds: UInt64
  public let latestOccurrenceAt: Date?

  public var id: PersonID { person.id }

  public var displayTitle: String {
    PersonDisplayTitle.formatted(displayName: person.displayName, createdAt: person.createdAt)
  }

  public init(
    person: Person,
    occurrenceCount: Int,
    embeddingCount: Int,
    sessionCount: Int = 0,
    speechDurationNanoseconds: UInt64 = 0,
    latestOccurrenceAt: Date? = nil
  ) {
    self.person = person
    self.occurrenceCount = occurrenceCount
    self.embeddingCount = embeddingCount
    self.sessionCount = sessionCount
    self.speechDurationNanoseconds = speechDurationNanoseconds
    self.latestOccurrenceAt = latestOccurrenceAt
  }
}

public struct SpeakerOccurrenceSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: SpeakerOccurrenceID
  public let sessionID: SessionID
  public let sessionSpeakerID: SessionSpeakerID
  public let stableOrdinal: UInt32
  public let monotonicStartNanoseconds: UInt64
  public let monotonicEndNanoseconds: UInt64
  public let personID: PersonID?
  public let personDisplayName: String?
  public let associationStatus: PersonAssociationStatus

  public init(
    id: SpeakerOccurrenceID,
    sessionID: SessionID,
    sessionSpeakerID: SessionSpeakerID,
    stableOrdinal: UInt32,
    monotonicStartNanoseconds: UInt64,
    monotonicEndNanoseconds: UInt64,
    personID: PersonID?,
    personDisplayName: String?,
    associationStatus: PersonAssociationStatus
  ) {
    self.id = id
    self.sessionID = sessionID
    self.sessionSpeakerID = sessionSpeakerID
    self.stableOrdinal = stableOrdinal
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.monotonicEndNanoseconds = monotonicEndNanoseconds
    self.personID = personID
    self.personDisplayName = personDisplayName
    self.associationStatus = associationStatus
  }
}

public enum RetainedSourceAssetKind: String, Codable, Sendable {
  case importedOriginal
  case microphoneOriginal
  case systemOriginal
  /// The exact file or pasteboard bytes of a pasted or dragged item.
  case userProvidedOriginal
  /// A downscaled PNG/JPEG made from an image item's original.
  case normalizedImage
  /// Further frames of an animated image item, normalized the same way.
  case animationFrame1
  case animationFrame2
  case animationFrame3
}

public struct RetainedSourceAssetRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let sessionID: SessionID
  public let revision: Revision
  public let kind: RetainedSourceAssetKind
  public let originalFilename: String
  public let mediaType: String
  public let assetReference: PortableAssetReference
  public let digest: SHA256Digest
  public let sizeBytes: UInt64
  public let createdAt: Date
  /// How long it plays for, when the file is this session's audio rather than
  /// a document it was derived from. Nil when nothing has measured it.
  public let durationNanoseconds: UInt64?

  public init(
    id: UUID,
    sessionID: SessionID,
    revision: Revision,
    kind: RetainedSourceAssetKind,
    originalFilename: String,
    mediaType: String,
    assetReference: PortableAssetReference,
    digest: SHA256Digest,
    sizeBytes: UInt64,
    createdAt: Date,
    durationNanoseconds: UInt64? = nil
  ) {
    self.id = id
    self.sessionID = sessionID
    self.revision = revision
    self.kind = kind
    self.originalFilename = originalFilename
    self.mediaType = mediaType
    self.assetReference = assetReference
    self.digest = digest
    self.sizeBytes = sizeBytes
    self.createdAt = createdAt
    self.durationNanoseconds = durationNanoseconds
  }
}

public enum DictationHistoryStatus: String, Codable, Equatable, Sendable {
  case completed
  case failed
  case processing
  case recovered
}

public struct DictationHistoryItem: Codable, Equatable, Identifiable, Sendable {
  public let sessionID: SessionID
  public let title: String
  public let inputMode: SessionInputMode
  public let revision: UInt64
  public let phase: DictationPhase
  public let status: DictationHistoryStatus
  public let rawText: String?
  public let polishedText: String?
  public let failureCode: String?
  public let canRetry: Bool
  public let sourceAudioRetained: Bool
  public let createdAt: Date
  public let updatedAt: Date
  public let recoveredAt: Date?
  public let sourceApplicationBundleID: String?
  public let sourceDisplayName: String?
  public let sourceIdentifier: String?
  /// Union of committed source intervals. This excludes user-paused gaps,
  /// includes successive device tracks, and counts simultaneous tracks once.
  public let durationNanoseconds: UInt64?
  /// Monotonic start-to-end session duration, including explicit pauses.
  public let wallClockDurationNanoseconds: UInt64?
  public let personDisplayNames: [String]
  public let personIDs: [PersonID]
  public let hasLocalTextDocuments: Bool
  /// "translate" or "command" when the dictation was delivered in that mode;
  /// nil for a plain dictation.
  public let spokenMode: String?
  /// Text, image, or document for a pasted or dragged item; nil otherwise.
  public let itemKind: UserItemKind?
  /// True when `rawText` is only the list preview of a long item; the full
  /// text is read by `memoryItemRecords(ids:)` or the selected transcripts.
  public let textIsPreview: Bool

  public var id: SessionID { sessionID }
  public var preferredText: String? { polishedText ?? rawText }

  public init(
    sessionID: SessionID,
    title: String = "本地记录",
    inputMode: SessionInputMode = .dictation,
    revision: UInt64,
    phase: DictationPhase,
    status: DictationHistoryStatus,
    rawText: String?,
    polishedText: String?,
    failureCode: String?,
    canRetry: Bool,
    sourceAudioRetained: Bool,
    createdAt: Date,
    updatedAt: Date,
    recoveredAt: Date?,
    sourceApplicationBundleID: String? = nil,
    sourceDisplayName: String? = nil,
    sourceIdentifier: String? = nil,
    durationNanoseconds: UInt64? = nil,
    wallClockDurationNanoseconds: UInt64? = nil,
    personDisplayNames: [String] = [],
    personIDs: [PersonID] = [],
    hasLocalTextDocuments: Bool = false,
    spokenMode: String? = nil,
    itemKind: UserItemKind? = nil,
    textIsPreview: Bool = false
  ) {
    self.sessionID = sessionID
    self.itemKind = itemKind
    self.textIsPreview = textIsPreview
    self.title = title
    self.inputMode = inputMode
    self.spokenMode = spokenMode
    self.revision = revision
    self.phase = phase
    self.status = status
    self.rawText = rawText
    self.polishedText = polishedText
    self.failureCode = failureCode
    self.canRetry = canRetry
    self.sourceAudioRetained = sourceAudioRetained
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.recoveredAt = recoveredAt
    self.sourceApplicationBundleID = sourceApplicationBundleID
    self.sourceDisplayName = sourceDisplayName
    self.sourceIdentifier = sourceIdentifier
    self.durationNanoseconds = durationNanoseconds
    self.wallClockDurationNanoseconds = wallClockDurationNanoseconds
    self.personDisplayNames = personDisplayNames
    self.personIDs = personIDs
    self.hasLocalTextDocuments = hasLocalTextDocuments
  }
}

public struct LocalHistoryUsageStatistics: Equatable, Sendable {
  public let sessionCount: Int
  public let recordedDurationNanoseconds: UInt64
  public let currentTextCharacterCount: UInt64
  public let activeDayCount: Int

  public init(
    sessionCount: Int = 0,
    recordedDurationNanoseconds: UInt64 = 0,
    currentTextCharacterCount: UInt64 = 0,
    activeDayCount: Int = 0
  ) {
    self.sessionCount = sessionCount
    self.recordedDurationNanoseconds = recordedDurationNanoseconds
    self.currentTextCharacterCount = currentTextCharacterCount
    self.activeDayCount = activeDayCount
  }
}

/// One application that dictation has been written into, with how often.
public struct DictationHistorySourceApplication: Equatable, Sendable, Identifiable {
  public let bundleIdentifier: String
  public let displayName: String
  public let sessionCount: Int

  public var id: String { bundleIdentifier }

  /// The display name the app recorded, falling back to the last component of
  /// its bundle identifier so a row is never blank.
  public var title: String {
    displayName.isEmpty
      ? (bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier)
      : displayName
  }

  public init(bundleIdentifier: String, displayName: String, sessionCount: Int) {
    self.bundleIdentifier = bundleIdentifier
    self.displayName = displayName
    self.sessionCount = sessionCount
  }
}

private struct HistoryPersonProjection: Decodable, Sendable {
  let id: UUID
  let displayName: String?
  let createdAt: Double
}

private struct DictationHistoryStorageRow: Sendable {
  let snapshotData: Data
  let title: String
  let inputMode: String
  let spokenMode: String?
  let sourceAudioRetention: String
  let createdAt: Double
  let updatedAt: Double
  let recoveredAt: Double?
  let durationNanoseconds: Int64?
  let people: [HistoryPersonProjection]
  let hasLocalTextDocuments: Bool
  let currentTranscriptID: String?
  let currentTranscript: String?
  let currentTranscriptIsPreview: Bool
  let currentPolish: String?
  let sourceDisplayName: String?
  let sourceIdentifier: String?
  let sourceBundleID: String?
  let itemKind: String?
}

/// Production scheduler. It only commits an idempotent durable job and its
/// immutable audio input. A separately owned worker claims and executes it, so
/// insertion and recording durability never wait for diarization.
public struct GRDBSpeakerJobScheduler: DictationSpeakerSchedulingPort {
  private let store: GRDBDictationStore
  private let modelArtifactKey: String
  private let embeddingSpaceID: String
  private let configHash: SHA256Digest

  public init(
    store: GRDBDictationStore,
    modelArtifactKey: String,
    embeddingSpaceID: String,
    configHash: SHA256Digest
  ) {
    self.store = store
    self.modelArtifactKey = modelArtifactKey
    self.embeddingSpaceID = embeddingSpaceID
    self.configHash = configHash
  }

  public func scheduleFinalSpeakerWork(
    sessionID: SessionID,
    audio: [AudioRangeInput],
    inputRevision: UInt64
  ) async throws {
    _ = try await store.scheduleSpeakerFinalWork(
      sessionID: sessionID,
      audio: audio,
      inputRevision: inputRevision,
      modelArtifactKey: modelArtifactKey,
      embeddingSpaceID: embeddingSpaceID,
      configHash: configHash
    )
  }
}

/// Alpha scheduler for the same speaker/person tables used by every V1 input
/// mode. It persists one conservative cluster and unknown associations; later
/// diarization/embedding work may refine history without changing inserted text.
public struct GRDBSingleSpeakerScheduler: DictationSpeakerSchedulingPort {
  private let store: GRDBDictationStore

  public init(store: GRDBDictationStore) {
    self.store = store
  }

  public func scheduleFinalSpeakerWork(
    sessionID: SessionID,
    audio: [AudioRangeInput],
    inputRevision: UInt64
  ) async throws {
    _ = try await store.scheduleSingleSpeakerWork(
      sessionID: sessionID,
      audio: audio,
      inputRevision: inputRevision
    )
  }
}

private enum DictionaryMutation: Sendable {
  case delete
  case edit(canonicalForm: String, spokenForms: [String])
  case setEnabled(Bool)
}

public actor GRDBDictationStore:
  DictationProcessingRepositoryPort,
  DictationTranscriptRevisionRepositoryPort,
  SessionModeDictationRepositoryPort,
  LiveCaptureRemoteEligibilityPort,
  DictationCaptureTrackRepositoryPort,
  SourceAudioIndexRepositoryPort,
  DictationTimelineEventRepositoryPort,
  DictionaryRepository,
  EventMemoryRepository
{
  public let databaseURL: URL

  private var pool: DatabasePool?
  private let clock: any DictationClock
  /// The zone whose offset item times carry when sent to the organizer
  /// (`started_at` with the local UTC offset). Follows later zone changes of
  /// a long-running App by default; injected by tests.
  public nonisolated let remoteItemTimeZone: TimeZone

  public init(
    databaseURL: URL,
    clock: any DictationClock = SystemDictationClock(),
    fileManager: FileManager = .default,
    remoteItemTimeZone: TimeZone = .autoupdatingCurrent
  ) throws {
    self.databaseURL = databaseURL
    self.clock = clock
    self.remoteItemTimeZone = remoteItemTimeZone
    try fileManager.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var configuration = Configuration()
    configuration.label = "bestASR.persistence"
    configuration.maximumReaderCount = 4
    configuration.prepareDatabase { database in
      try database.execute(sql: "PRAGMA foreign_keys = ON")
      let mode = (try String.fetchOne(database, sql: "PRAGMA journal_mode = WAL") ?? "")
        .lowercased()
      guard mode == "wal" else {
        throw BestASRPersistenceError.invalidJournalMode
      }
    }
    let openedPool = try DatabasePool(
      path: databaseURL.path,
      configuration: configuration
    )
    do {
      try BestASRPersistenceSchema.migrator().migrate(openedPool)
      try openedPool.write { database in
        try BestASRPersistenceSchema.installHistorySearchIndex(in: database)
      }
      pool = openedPool
    } catch {
      try? openedPool.close()
      throw error
    }
  }

  public func create(_ snapshot: DictationSessionSnapshot) async throws {
    try await create(snapshot, inputMode: .dictation)
  }

  public func indexCommittedSourceAudio(
    sessionID: SessionID,
    tracks: [CaptureTrackDescriptor],
    chunks: [CommittedSourceAudioChunk]
  ) async throws {
    guard !tracks.isEmpty, Set(tracks.map(\.id)).count == tracks.count,
      tracks.allSatisfy({ $0.sampleRateHertz > 0 && $0.channelCount > 0 })
    else { throw BestASRPersistenceError.invalidSnapshot }
    let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
    let value = sessionID.rawValue.uuidString
    let sourcePrefix = "sessions/\(value.lowercased())/journal/"
    let manifestReference = sourcePrefix + "manifest.json"
    var seen: Set<String> = []
    for chunk in chunks {
      guard let track = tracksByID[chunk.trackID],
        chunk.frameCount > 0, chunk.frameCount <= UInt64(UInt32.max),
        chunk.sampleRateHertz == track.sampleRateHertz,
        seen.insert("\(chunk.trackID.rawValue.uuidString):\(chunk.sequence)").inserted,
        case .relativePath(let path) = chunk.assetReference,
        path.hasPrefix(sourcePrefix)
      else { throw BestASRPersistenceError.invalidSnapshot }
      _ = try PortableAssetReference(relativePath: path)
      let duration = UInt64(
        (Double(chunk.frameCount) * 1_000_000_000 / Double(chunk.sampleRateHertz)).rounded()
      )
      guard chunk.monotonicStartNanoseconds <= UInt64(Int64.max) - duration else {
        throw BestASRPersistenceError.numericOverflow
      }
    }
    let database = try requirePool()
    try await database.write { db in
      guard
        let retention = try String.fetchOne(
          db, sql: "SELECT source_audio_retention FROM sessions WHERE id = ?", arguments: [value]
        )
      else { throw BestASRPersistenceError.missingSession }
      // A late background index result cannot reintroduce source handles after
      // the user's explicit source-only deletion transaction.
      guard retention == SourceAudioRetention.retainedUntilExplicitDeletion.rawValue else { return }
      for track in tracks {
        let trackValue = track.id.rawValue.uuidString
        if let existing = try Row.fetchOne(
          db, sql: "SELECT * FROM tracks WHERE id = ?", arguments: [trackValue]
        ) {
          guard existing["session_id"] as String == value,
            existing["sample_rate_hz"] as Int64 == Int64(track.sampleRateHertz),
            existing["channel_count"] as Int64 == Int64(track.channelCount),
            existing["role"] as String == track.role.rawValue,
            existing["asset_reference"] as String == manifestReference
          else { throw BestASRPersistenceError.processingCommitConflict }
        } else {
          try db.execute(
            sql: """
              INSERT INTO tracks (
                id, session_id, revision, role, asset_reference,
                sample_rate_hz, channel_count, device_uid
              ) VALUES (?, ?, 1, ?, ?, ?, ?, ?)
              """,
            arguments: [
              trackValue, value, track.role.rawValue, manifestReference,
              Int64(track.sampleRateHertz), Int64(track.channelCount), track.deviceUID,
            ]
          )
        }
      }
      for chunk in chunks {
        let trackValue = chunk.trackID.rawValue.uuidString
        let sequence = try Self.sqliteInt(chunk.sequence)
        let start = try Self.sqliteInt(chunk.monotonicStartNanoseconds)
        let frames = try Self.sqliteInt(chunk.frameCount)
        let reference = Self.assetReference(chunk.assetReference)
        try db.execute(
          sql: """
            INSERT INTO audio_chunks (
              id, session_id, track_id, revision, sequence,
              monotonic_start_ns, frame_count, digest, asset_reference
            ) VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?)
            ON CONFLICT(track_id, sequence) DO NOTHING
            """,
          arguments: [
            Self.deterministicUUID([
              "committed-source-chunk-v1", value, trackValue, String(sequence),
            ])
            .uuidString,
            value, trackValue, sequence, start, frames, chunk.contentDigest.value, reference,
          ]
        )
        if db.changesCount == 0 {
          guard
            let existing = try Row.fetchOne(
              db,
              sql: "SELECT * FROM audio_chunks WHERE track_id = ? AND sequence = ?",
              arguments: [trackValue, sequence]
            ), existing["session_id"] as String == value,
            existing["monotonic_start_ns"] as Int64 == start,
            existing["frame_count"] as Int64 == frames,
            existing["digest"] as String == chunk.contentDigest.value,
            existing["asset_reference"] as String == reference
          else { throw BestASRPersistenceError.processingCommitConflict }
        }
      }
    }
  }

  /// Points a session's audio index and its transcripts' provenance at a
  /// recording that has been rewritten in place.
  ///
  /// Compaction replaces a sealed session's chunk files with the same audio at
  /// 16 kHz, so every row that names one of the old files — the index the
  /// history duration is read from, and the ranges that say which audio
  /// produced a transcript — has to name the new one instead. Times do not
  /// change, so a range keeps its place in the recording; one that no longer
  /// falls inside any run is dropped rather than left pointing at a file that
  /// is gone.
  public func applySourceAudioCompaction(
    sessionID: SessionID,
    tracks: [CaptureTrackDescriptor],
    chunks: [CompactedAudioChunkRecord]
  ) async throws {
    guard !tracks.isEmpty, !chunks.isEmpty,
      Set(chunks.map { "\($0.trackID.rawValue.uuidString):\($0.sequence)" }).count
        == chunks.count,
      chunks.allSatisfy({
        $0.frameCount > 0 && $0.digest.count == 64
          && $0.monotonicEndNanoseconds > $0.monotonicStartNanoseconds
      })
    else { throw BestASRPersistenceError.invalidSnapshot }
    let value = sessionID.rawValue.uuidString
    // Validates the shape the schema's CHECK constraints also enforce.
    let references = try chunks.map { chunk -> String in
      _ = try PortableAssetReference(relativePath: chunk.assetReference)
      return chunk.assetReference
    }
    let database = try requirePool()
    try await database.write { db in
      guard
        try Bool.fetchOne(
          db, sql: "SELECT 1 FROM sessions WHERE id = ?", arguments: [value]) == true
      else { throw BestASRPersistenceError.missingSession }
      try db.execute(
        sql: "DELETE FROM audio_chunks WHERE session_id = ?", arguments: [value])
      for track in tracks {
        try db.execute(
          sql: """
            UPDATE tracks SET revision = revision + 1, sample_rate_hz = ?, channel_count = ?
            WHERE id = ? AND session_id = ?
            """,
          arguments: [
            Int64(track.sampleRateHertz), Int64(track.channelCount),
            track.id.rawValue.uuidString, value,
          ]
        )
      }
      for (chunk, reference) in zip(chunks, references) {
        let trackValue = chunk.trackID.rawValue.uuidString
        let sequence = try Self.sqliteInt(chunk.sequence)
        try db.execute(
          sql: """
            INSERT INTO audio_chunks (
              id, session_id, track_id, revision, sequence,
              monotonic_start_ns, frame_count, digest, asset_reference
            ) VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?)
            """,
          arguments: [
            Self.deterministicUUID([
              "committed-source-chunk-v1", value, trackValue, String(sequence),
            ]).uuidString,
            value, trackValue, sequence,
            try Self.sqliteInt(chunk.monotonicStartNanoseconds),
            try Self.sqliteInt(UInt64(chunk.frameCount)),
            chunk.digest, reference,
          ]
        )
        try db.execute(
          sql: """
            UPDATE transcript_audio_ranges
            SET asset_reference = ?, digest = ?, sample_rate_hz = ?, channel_count = ?,
                monotonic_end_ns = MIN(monotonic_end_ns, ?)
            WHERE track_id = ?
              AND monotonic_start_ns >= ? AND monotonic_start_ns < ?
              AND transcript_id IN (
                SELECT id FROM transcript_revisions WHERE session_id = ?
              )
            """,
          arguments: [
            reference, chunk.digest, Int64(chunk.sampleRateHertz),
            Int64(chunk.channelCount),
            try Self.sqliteInt(chunk.monotonicEndNanoseconds),
            trackValue,
            try Self.sqliteInt(chunk.monotonicStartNanoseconds),
            try Self.sqliteInt(chunk.monotonicEndNanoseconds),
            value,
          ]
        )
      }
      let kept = references
      try db.execute(
        sql: """
          DELETE FROM transcript_audio_ranges
          WHERE transcript_id IN (
            SELECT id FROM transcript_revisions WHERE session_id = ?
          ) AND asset_reference NOT IN (\(databaseQuestionMarks(count: kept.count)))
          """,
        arguments: StatementArguments([value] + kept)
      )
    }
  }

  /// Finished dictations still holding their recording at the capture device's
  /// rate, oldest first, for `SourceAudioCompaction` to rewrite when the App
  /// is idle. A session being written to has no finished state yet, so it is
  /// not in this list.
  ///
  /// Dictation only. 16 kHz mono is the whole band of a person talking into
  /// their own microphone, and it is what every speech model reads. A room
  /// recording or a capture of the computer's own output may hold music, a
  /// room, several people at once — material later features will want to
  /// analyse, and narrowing it to speech bandwidth cannot be undone.
  public func sessionsWithUncompactedSourceAudio(limit: Int) async throws -> [SessionID] {
    let bounded = max(1, min(limit, 1_000))
    let database = try requirePool()
    return try await database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT DISTINCT s.id FROM sessions s
          JOIN tracks t ON t.session_id = s.id
          WHERE s.source_audio_retention = 'retainedUntilExplicitDeletion'
            AND s.state IN ('completed', 'failedRecoverable')
            AND s.input_mode = 'dictation'
            AND (t.sample_rate_hz <> ? OR t.channel_count <> 1)
          ORDER BY s.created_at, s.id LIMIT ?
          """,
        // The rate every reader converts to; SourceAudioCompaction stores it.
        arguments: [Int64(16_000), bounded]
      ).map {
        guard let id = UUID(uuidString: $0) else { throw BestASRPersistenceError.storedDataCorrupt }
        return SessionID(id)
      }
    }
  }

  /// Legacy production versions journaled source blocks without registering
  /// their metadata. Only terminal retained records need this bounded repair;
  /// new and resumed capture is indexed at seal/recovery, not on every frame.
  public func sessionsMissingSourceAudioIndex() async throws -> [SessionID] {
    let database = try requirePool()
    return try await database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT s.id FROM sessions s
          WHERE s.source_audio_retention = 'retainedUntilExplicitDeletion'
            AND s.state IN ('completed', 'failedRecoverable')
            AND s.input_mode <> 'userItem'
            AND NOT EXISTS (SELECT 1 FROM audio_chunks a WHERE a.session_id = s.id)
          ORDER BY s.updated_at DESC, s.id LIMIT 10000
          """
      ).map {
        guard let id = UUID(uuidString: $0) else { throw BestASRPersistenceError.storedDataCorrupt }
        return SessionID(id)
      }
    }
  }

  // Union committed source intervals rather than summing simultaneous tracks
  // or taking only the longest device track. Pauses and missing source ranges
  // contribute no captured time. This expression is correlated to sessions s.
  /// Every session's recorded duration in one pass, overlapping chunks merged.
  ///
  /// A session whose audio arrived as a file has nothing in the audio index —
  /// that index describes what capture journaled — so its length comes from
  /// the retained original instead. What was journaled wins when both exist.
  ///
  /// This used to be a correlated subquery, which costs one scan of the audio
  /// index per session: fine for a page of history, and 2.3 s for a query that
  /// covers them all once the user's imported history reached 5,265 sessions.
  /// Joined once it is 29 ms, and the two forms were checked to agree session
  /// by session on that database before the old one was removed.
  static let recordedAudioDurationsCTE = """
    recorded_audio_durations AS (
      SELECT session_id,
             COALESCE(
               MAX(CASE WHEN origin = 'journal' THEN duration_ns END),
               MAX(CASE WHEN origin = 'file' THEN duration_ns END)
             ) AS duration_ns
      FROM (
        SELECT session_id, 'journal' AS origin,
               SUM(MAX(0, end_ns - MAX(start_ns, COALESCE(previous_end_ns, start_ns))))
                 AS duration_ns
        FROM (
          SELECT session_id, start_ns, end_ns,
                 MAX(end_ns) OVER (
                   PARTITION BY session_id
                   ORDER BY start_ns, end_ns, chunk_id
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                 ) AS previous_end_ns
          FROM (
            SELECT a.session_id AS session_id, a.id AS chunk_id,
                   a.monotonic_start_ns AS start_ns,
                   a.monotonic_start_ns + CAST(ROUND(
                     CAST(a.frame_count AS REAL) * 1000000000 / t.sample_rate_hz
                   ) AS INTEGER) AS end_ns
            FROM audio_chunks a JOIN tracks t ON t.id = a.track_id
          )
        )
        GROUP BY session_id
        UNION ALL
        SELECT session_id, 'file' AS origin, MAX(duration_ns) AS duration_ns
        FROM session_source_assets
        WHERE duration_ns IS NOT NULL
        GROUP BY session_id
      )
      GROUP BY session_id
    )
    """

  public func saveCaptureTracks(
    sessionID: SessionID,
    tracks: [CaptureTrackDescriptor]
  ) async throws {
    guard !tracks.isEmpty,
      Set(tracks.map(\.id)).count == tracks.count,
      tracks.allSatisfy({ $0.sampleRateHertz > 0 && $0.channelCount > 0 })
    else { throw BestASRPersistenceError.invalidSnapshot }
    let database = try requirePool()
    try await database.write { db in
      guard
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?)",
          arguments: [sessionID.rawValue.uuidString]
        ) == true
      else { throw BestASRPersistenceError.missingSession }
      let reference =
        "sessions/\(sessionID.rawValue.uuidString.lowercased())/journal/manifest.json"
      for track in tracks {
        try db.execute(
          sql: """
            INSERT INTO tracks (
              id, session_id, revision, role, asset_reference,
              sample_rate_hz, channel_count, device_uid
            ) VALUES (?, ?, 1, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              role = excluded.role,
              asset_reference = excluded.asset_reference,
              sample_rate_hz = excluded.sample_rate_hz,
              channel_count = excluded.channel_count,
              device_uid = excluded.device_uid
            WHERE tracks.session_id = excluded.session_id
            """,
          arguments: [
            track.id.rawValue.uuidString,
            sessionID.rawValue.uuidString,
            track.role.rawValue,
            reference,
            Int64(track.sampleRateHertz),
            Int64(track.channelCount),
            track.deviceUID,
          ]
        )
      }
    }
  }

  public func loadTrackRoles(
    sessionID: SessionID
  ) async throws -> [UUID: SourceTrackRole] {
    let database = try requirePool()
    return try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT id, role FROM tracks WHERE session_id = ? ORDER BY id",
        arguments: [sessionID.rawValue.uuidString]
      )
      return try Dictionary(
        uniqueKeysWithValues: rows.map { row in
          guard
            let trackID = UUID(uuidString: row["id"] as String),
            let role = SourceTrackRole(rawValue: row["role"] as String)
          else { throw BestASRPersistenceError.storedDataCorrupt }
          return (trackID, role)
        }
      )
    }
  }

  public func removeCaptureTracksIfUnused(
    sessionID: SessionID,
    trackIDs: Set<TrackID>
  ) async throws {
    guard !trackIDs.isEmpty else { return }
    let database = try requirePool()
    try await database.write { db in
      for trackID in trackIDs {
        try db.execute(
          sql: """
            DELETE FROM tracks
            WHERE id = ? AND session_id = ?
              AND NOT EXISTS (
                SELECT 1 FROM audio_chunks WHERE track_id = tracks.id
              )
            """,
          arguments: [
            trackID.rawValue.uuidString,
            sessionID.rawValue.uuidString,
          ]
        )
      }
    }
  }

  public func create(
    _ snapshot: DictationSessionSnapshot,
    inputMode: SessionInputMode
  ) async throws {
    do { try snapshot.validate() } catch { throw BestASRPersistenceError.invalidSnapshot }
    guard snapshot.phase == .preparing, let sessionID = snapshot.sessionID else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let data = try encode(snapshot)
    let now = clock.wallTime().timeIntervalSince1970
    let defaultTitle: String =
      switch inputMode {
      case .dictation: "口述"
      case .roomMicrophone: "线下录音"
      case .systemAudio: "电脑内录"
      case .importedMedia: "导入文件"
      // Items are committed whole by `createUserItem`, never through capture.
      case .userItem: throw BestASRPersistenceError.invalidSnapshot
      }
    let database = try requirePool()
    do {
      try await database.write { db in
        try db.execute(
          sql: """
            INSERT INTO sessions (
              id, revision, input_mode, state, source_audio_retention,
              created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            sessionID.rawValue.uuidString,
            try Self.sqliteInt(max(1, snapshot.revision)),
            inputMode.rawValue,
            Self.domainState(for: snapshot.phase).rawValue,
            SourceAudioRetention.retainedUntilExplicitDeletion.rawValue,
            now,
            now,
          ]
        )
        // Creating a session never makes it sendable: bulk writers (the
        // Typeless history import) use this path too. The live capture path
        // grants eligibility explicitly with `markLiveCaptureRemoteEligible`.
        try db.execute(
          sql: """
            INSERT INTO session_metadata (
              session_id, revision, title, title_is_user_edited, source_kind,
              source_identifier, source_display_name, source_bundle_id,
              recording_format, created_at, updated_at
            ) VALUES (?, 1, ?, 0, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            sessionID.rawValue.uuidString,
            defaultTitle,
            inputMode.rawValue,
            snapshot.target?.bundleIdentifier,
            snapshot.target?.bundleIdentifier,
            snapshot.target?.bundleIdentifier,
            "float32-pcm-journal",
            now,
            now,
          ]
        )
        try db.execute(
          sql: """
            INSERT INTO dictation_snapshots (
              session_id, control_revision, phase, snapshot_json,
              is_ephemeral, updated_at
            ) VALUES (?, ?, ?, ?, 1, ?)
            """,
          arguments: [
            sessionID.rawValue.uuidString,
            try Self.sqliteInt(snapshot.revision),
            snapshot.phase.rawValue,
            data,
            now,
          ]
        )
        try Self.synchronizeTimelineEvents(snapshot, in: db)
      }
    } catch let error as DatabaseError
      where error.extendedResultCode == .SQLITE_CONSTRAINT_PRIMARYKEY
    {
      throw BestASRPersistenceError.duplicateSession
    }
  }

  public func save(_ snapshot: DictationSessionSnapshot) async throws {
    do { try snapshot.validate() } catch { throw BestASRPersistenceError.invalidSnapshot }
    guard let sessionID = snapshot.sessionID else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let data = try encode(snapshot)
    let now = clock.wallTime().timeIntervalSince1970
    let database = try requirePool()
    try await database.write { db in
      guard
        let current = try Int64.fetchOne(
          db,
          sql: "SELECT control_revision FROM dictation_snapshots WHERE session_id = ?",
          arguments: [sessionID.rawValue.uuidString]
        )
      else {
        throw BestASRPersistenceError.missingSession
      }
      guard snapshot.revision > UInt64(current) else {
        throw BestASRPersistenceError.nonMonotonicRevision(
          current: UInt64(current),
          proposed: snapshot.revision
        )
      }
      try db.execute(
        sql: """
          UPDATE sessions
          SET revision = ?, state = ?, updated_at = ?
          WHERE id = ?
          """,
        arguments: [
          try Self.sqliteInt(snapshot.revision),
          Self.domainState(for: snapshot.phase).rawValue,
          now,
          sessionID.rawValue.uuidString,
        ]
      )
      try db.execute(
        sql: """
          UPDATE dictation_snapshots
          SET control_revision = ?, phase = ?, snapshot_json = ?,
              is_ephemeral = ?, updated_at = ?
          WHERE session_id = ?
          """,
        arguments: [
          try Self.sqliteInt(snapshot.revision),
          snapshot.phase.rawValue,
          data,
          Self.isEphemeral(snapshot.phase) ? 1 : 0,
          now,
          sessionID.rawValue.uuidString,
        ]
      )
      try Self.synchronizeTimelineEvents(snapshot, in: db)
    }
  }

  public func load(sessionID: SessionID) async throws -> DictationSessionSnapshot? {
    let database = try requirePool()
    let data = try await database.read { db in
      try Data.fetchOne(
        db,
        sql: "SELECT snapshot_json FROM dictation_snapshots WHERE session_id = ?",
        arguments: [sessionID.rawValue.uuidString]
      )
    }
    guard let data else { return nil }
    return try decodeSnapshot(data)
  }

  public func sessionInputMode(sessionID: SessionID) async throws
    -> SessionInputMode
  {
    let database = try requirePool()
    return try await database.read { db in
      guard
        let value = try String.fetchOne(
          db,
          sql: "SELECT input_mode FROM sessions WHERE id = ?",
          arguments: [sessionID.rawValue.uuidString]
        ), let mode = SessionInputMode(rawValue: value)
      else { throw BestASRPersistenceError.missingSession }
      return mode
    }
  }

  public func setSessionSourceMetadata(
    sessionID: SessionID,
    sourceKind: String,
    sourceIdentifier: String?,
    sourceDisplayName: String?,
    sourceBundleID: String?,
    recordingFormat: String = "float32-pcm-journal"
  ) async throws {
    let kind = sourceKind.trimmingCharacters(in: .whitespacesAndNewlines)
    let format = recordingFormat.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !kind.isEmpty, kind.utf8.count <= 128,
      !format.isEmpty, format.utf8.count <= 128,
      [sourceIdentifier, sourceDisplayName, sourceBundleID].allSatisfy({
        ($0?.utf8.count ?? 0) <= 1_024
      })
    else { throw BestASRPersistenceError.invalidSnapshot }
    let database = try requirePool()
    try await database.write { db in
      let now = clock.wallTime()
      let affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
        sessionValues: Set([sessionID.rawValue.uuidString]),
        in: db
      )
      try db.execute(
        sql: """
          UPDATE session_metadata
          SET revision = revision + 1, source_kind = ?,
              source_identifier = ?, source_display_name = ?,
              source_bundle_id = ?, recording_format = ?, updated_at = ?
          WHERE session_id = ?
          """,
        arguments: [
          kind,
          sourceIdentifier,
          sourceDisplayName,
          sourceBundleID,
          format,
          now.timeIntervalSince1970,
          sessionID.rawValue.uuidString,
        ]
      )
      guard db.changesCount == 1 else {
        throw BestASRPersistenceError.missingSession
      }
      try Self.refreshEventAggregates(
        eventIDs: affectedEventIDs,
        at: now,
        in: db
      )
    }
  }

  public func setAutomaticSessionTitle(
    sessionID: SessionID,
    from text: String
  ) async throws {
    guard let title = Self.normalizedSessionTitle(text) else { return }
    let database = try requirePool()
    try await database.write { db in
      let now = clock.wallTime()
      let affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
        sessionValues: Set([sessionID.rawValue.uuidString]),
        in: db
      )
      try db.execute(
        sql: """
          UPDATE session_metadata
          SET revision = revision + 1, title = ?, updated_at = ?
          WHERE session_id = ? AND title_is_user_edited = 0
          """,
        arguments: [
          title,
          now.timeIntervalSince1970,
          sessionID.rawValue.uuidString,
        ]
      )
      if db.changesCount == 1 {
        try Self.refreshEventAggregates(
          eventIDs: affectedEventIDs,
          at: now,
          in: db
        )
      }
    }
  }

  public func saveSourceContext(
    _ context: SourceContextSnapshot
  ) async throws {
    let adapterID = context.adapterID.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let names = context.participantDisplayNames.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    guard !adapterID.isEmpty, adapterID.utf8.count <= 128,
      names.count <= 500,
      names.allSatisfy({ $0.utf8.count <= 256 }),
      [
        context.sourceBundleID, context.meetingTitle, context.windowTitle,
        context.activeSpeakerDisplayName,
      ].allSatisfy({
        ($0?.utf8.count ?? 0) <= 1_024
      }), context.monotonicNanoseconds <= UInt64(Int64.max)
    else { throw BestASRPersistenceError.invalidSnapshot }
    let database = try requirePool()
    let namesData = try JSONEncoder().encode(names)
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO source_context_events (
            id, session_id, revision, adapter_id, source_bundle_id,
            meeting_title, window_title, participant_names_json,
            active_speaker_name, monotonic_ns, reliability
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(session_id, adapter_id, monotonic_ns) DO NOTHING
          """,
        arguments: [
          context.id.uuidString,
          context.sessionID.rawValue.uuidString,
          try Self.sqliteInt(context.revision.value),
          adapterID,
          context.sourceBundleID,
          context.meetingTitle,
          context.windowTitle,
          namesData,
          context.activeSpeakerDisplayName,
          Int64(context.monotonicNanoseconds),
          context.reliability.rawValue,
        ]
      )
    }
  }

  public func loadSourceContexts(
    sessionID: SessionID
  ) async throws -> [SourceContextSnapshot] {
    let database = try requirePool()
    return try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM source_context_events
          WHERE session_id = ? ORDER BY monotonic_ns, revision, id
          """,
        arguments: [sessionID.rawValue.uuidString]
      ).map { row in
        let id: String = row["id"]
        let revision: Int64 = row["revision"]
        let namesData: Data = row["participant_names_json"]
        let monotonic: Int64 = row["monotonic_ns"]
        let reliabilityValue: String = row["reliability"]
        guard let uuid = UUID(uuidString: id), revision > 0, monotonic >= 0,
          let reliability = SourceContextReliability(
            rawValue: reliabilityValue
          )
        else { throw BestASRPersistenceError.storedDataCorrupt }
        let names = try JSONDecoder().decode([String].self, from: namesData)
        return SourceContextSnapshot(
          id: uuid,
          sessionID: sessionID,
          revision: try Revision(UInt64(revision)),
          adapterID: row["adapter_id"],
          sourceBundleID: row["source_bundle_id"],
          meetingTitle: row["meeting_title"],
          windowTitle: row["window_title"],
          participantDisplayNames: names,
          activeSpeakerDisplayName: row["active_speaker_name"],
          monotonicNanoseconds: UInt64(monotonic),
          reliability: reliability
        )
      }
    }
  }

  public func recordSpokenMode(sessionID: SessionID, mode: String) async throws {
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: "UPDATE sessions SET spoken_mode = ? WHERE id = ?",
        arguments: [mode, sessionID.rawValue.uuidString]
      )
      guard db.changesCount == 1 else {
        throw BestASRPersistenceError.missingSession
      }
    }
  }

  public func renameSession(
    sessionID: SessionID,
    title: String
  ) async throws {
    guard let normalized = Self.normalizedSessionTitle(title) else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let database = try requirePool()
    try await database.write { db in
      let now = clock.wallTime()
      let affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
        sessionValues: Set([sessionID.rawValue.uuidString]),
        in: db
      )
      try db.execute(
        sql: """
          UPDATE session_metadata
          SET revision = revision + 1, title = ?, title_is_user_edited = 1,
              updated_at = ?
          WHERE session_id = ?
          """,
        arguments: [
          normalized,
          now.timeIntervalSince1970,
          sessionID.rawValue.uuidString,
        ]
      )
      guard db.changesCount == 1 else {
        throw BestASRPersistenceError.missingSession
      }
      try Self.refreshEventAggregates(
        eventIDs: affectedEventIDs,
        at: now,
        in: db
      )
    }
  }

  public func loadRecoverable() async throws -> [DictationSessionSnapshot] {
    let database = try requirePool()
    let rows = try await database.read { db in
      try Data.fetchAll(
        db,
        sql: """
          SELECT snapshot_json FROM dictation_snapshots
          WHERE phase NOT IN ('completed', 'cancelled')
          ORDER BY updated_at, session_id
          """
      )
    }
    return try rows.map(decodeSnapshot)
  }

  public func loadHistory(limit: Int = 100) async throws
    -> [DictationHistoryItem]
  {
    try await loadHistory(limit: limit, sessionIDs: nil)
  }

  private func loadHistory(
    limit: Int,
    sessionIDs: [SessionID]?
  ) async throws -> [DictationHistoryItem] {
    let boundedLimit = max(1, min(limit, 10_000))
    if let sessionIDs, sessionIDs.isEmpty { return [] }
    let sessionFilterSQL =
      sessionIDs == nil
      ? ""
      : "AND s.id IN (SELECT value FROM json_each(?))"
    let queryArguments: StatementArguments
    if let sessionIDs {
      let encoded = try JSONEncoder().encode(
        sessionIDs.map { $0.rawValue.uuidString }
      )
      guard let json = String(data: encoded, encoding: .utf8) else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      queryArguments = [json, boundedLimit]
    } else {
      queryArguments = [boundedLimit]
    }
    let database = try requirePool()
    let rows: [DictationHistoryStorageRow] = try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          WITH \(Self.recordedAudioDurationsCTE)
          SELECT d.snapshot_json, d.updated_at, d.recovered_at,
                 s.created_at, s.source_audio_retention, s.input_mode, s.spoken_mode,
                 m.title, m.source_display_name, m.source_identifier,
                 m.source_bundle_id,
                 rad.duration_ns AS duration_ns,
                 (
                   SELECT json_group_array(json_object(
                     'id', p.id, 'displayName', p.display_name, 'createdAt', p.created_at
                   )) FROM (
                     SELECT p.id, p.display_name, p.created_at,
                            MIN(o.monotonic_start_ns) AS first_occurrence
                     FROM speaker_occurrences o JOIN persons p ON p.id = o.person_id
                     WHERE o.session_id = s.id AND p.retired_at IS NULL
                       AND o.association_status IN (
                         'anonymousIdentity', 'automaticMatch', 'userConfirmed'
                       )
                     GROUP BY p.id
                     ORDER BY first_occurrence, p.id
                   ) p
                 ) AS people_json,
                 EXISTS(
                   SELECT 1 FROM local_text_documents l
                   WHERE l.session_id = s.id AND l.state = 'current'
                 ) AS has_local_text,
                 current_tr.id AS current_transcript_id,
                 -- A pasted or dragged document can hold up to 16 MB of text;
                 -- list rows carry a bounded preview and the full text is read
                 -- only where it is needed (detail, copy, export).
                 CASE WHEN s.input_mode = 'userItem'
                        AND length(current_tr.content) > \(UserItemLimits.historyPreviewCharacters)
                      THEN substr(current_tr.content, 1, \(UserItemLimits.historyPreviewCharacters))
                      ELSE current_tr.content END AS current_transcript,
                 (s.input_mode = 'userItem'
                  AND length(current_tr.content) > \(UserItemLimits.historyPreviewCharacters))
                   AS current_transcript_is_preview,
                 (SELECT uid.item_kind FROM user_item_details uid
                  WHERE uid.session_id = s.id) AS item_kind
                 ,(
                   SELECT dt.output_text FROM derived_text_revisions dt
                   WHERE dt.session_id = s.id AND dt.state = 'current'
                     AND dt.source_transcript_id = current_tr.id
                   ORDER BY dt.source_revision DESC, dt.created_at DESC, dt.id DESC
                   LIMIT 1
                 ) AS current_polish
          FROM dictation_snapshots d
          JOIN sessions s ON s.id = d.session_id
          JOIN session_metadata m ON m.session_id = s.id
          LEFT JOIN recorded_audio_durations rad ON rad.session_id = s.id
          LEFT JOIN transcript_revisions current_tr ON current_tr.id = (
            SELECT tr.id FROM transcript_revisions tr
            WHERE tr.session_id = s.id
            ORDER BY CASE WHEN tr.kind IN ('final', 'userEdit') THEN 1 ELSE 0 END DESC,
                     tr.created_at DESC, tr.revision DESC, tr.id DESC
            LIMIT 1
          )
          WHERE d.phase <> 'cancelled' \(sessionFilterSQL)
          ORDER BY d.updated_at DESC, d.session_id
          LIMIT ?
          """,
        arguments: queryArguments
      ).map { row in
        DictationHistoryStorageRow(
          snapshotData: row["snapshot_json"],
          title: row["title"],
          inputMode: row["input_mode"],
          spokenMode: row["spoken_mode"],
          sourceAudioRetention: row["source_audio_retention"],
          createdAt: row["created_at"],
          updatedAt: row["updated_at"],
          recoveredAt: row["recovered_at"],
          durationNanoseconds: row["duration_ns"],
          people: try JSONDecoder().decode(
            [HistoryPersonProjection].self,
            from: Data((row["people_json"] as String).utf8)
          ),
          hasLocalTextDocuments: row["has_local_text"],
          currentTranscriptID: row["current_transcript_id"],
          currentTranscript: row["current_transcript"],
          currentTranscriptIsPreview: (row["current_transcript_is_preview"] as Bool?) ?? false,
          currentPolish: row["current_polish"],
          sourceDisplayName: row["source_display_name"],
          sourceIdentifier: row["source_identifier"],
          sourceBundleID: row["source_bundle_id"],
          itemKind: row["item_kind"]
        )
      }
    }
    return try rows.map { row in
      let snapshot = try decodeSnapshot(row.snapshotData)
      guard let sessionID = snapshot.sessionID else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      let recoveredAt = row.recoveredAt.map(Date.init(timeIntervalSince1970:))
      guard let inputMode = SessionInputMode(rawValue: row.inputMode) else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      let status: DictationHistoryStatus
      if snapshot.phase == .completed, recoveredAt != nil {
        status = .recovered
      } else if snapshot.phase == .completed {
        status = .completed
      } else if snapshot.phase == .failedRecoverable {
        status = .failed
      } else {
        status = .processing
      }
      let hasRetainedSourceAudio =
        row.sourceAudioRetention
        == SourceAudioRetention.retainedUntilExplicitDeletion.rawValue
      let wallClockDuration: UInt64? = {
        guard
          let started = snapshot.timeline.first(where: { $0.kind == .started })?
            .monotonicNanoseconds,
          let ended = snapshot.timeline.last(where: {
            [.endRequested, .cancelRequested].contains($0.kind)
          })?.monotonicNanoseconds,
          ended >= started
        else { return nil }
        return ended - started
      }()
      let canRetry =
        hasRetainedSourceAudio && snapshot.phase == .failedRecoverable
        && snapshot.failure?.retryable == true
      // Legacy snapshots may contain the only polish, but re-recognition and
      // edits supersede that source. Never resurrect old text just because its
      // derived revision was correctly marked stale.
      let matchingSnapshotPolish = snapshot.polish.flatMap { polish -> String? in
        if let currentID = row.currentTranscriptID,
          UUID(uuidString: currentID) != polish.sourceRevisionID.rawValue
        {
          return nil
        }
        return polish.text
      }
      return DictationHistoryItem(
        sessionID: sessionID,
        title: row.title,
        inputMode: inputMode,
        revision: snapshot.revision,
        phase: snapshot.phase,
        status: status,
        rawText: row.currentTranscript ?? snapshot.transcript?.text,
        polishedText: row.currentPolish ?? matchingSnapshotPolish,
        failureCode: snapshot.failure?.code,
        canRetry: canRetry,
        sourceAudioRetained: hasRetainedSourceAudio,
        createdAt: Date(timeIntervalSince1970: row.createdAt),
        updatedAt: Date(timeIntervalSince1970: row.updatedAt),
        recoveredAt: recoveredAt,
        sourceApplicationBundleID:
          row.sourceBundleID ?? snapshot.target?.bundleIdentifier,
        sourceDisplayName: row.sourceDisplayName,
        sourceIdentifier: row.sourceIdentifier,
        durationNanoseconds: row.durationNanoseconds.flatMap {
          $0 >= 0 ? UInt64($0) : nil
        },
        wallClockDurationNanoseconds: wallClockDuration,
        personDisplayNames: row.people.map {
          PersonDisplayTitle.formatted(
            displayName: $0.displayName, createdAt: Date(timeIntervalSince1970: $0.createdAt)
          )
        },
        personIDs: row.people.map { PersonID($0.id) },
        hasLocalTextDocuments: row.hasLocalTextDocuments,
        spokenMode: row.spokenMode,
        itemKind: row.itemKind.flatMap(UserItemKind.init(rawValue:)),
        textIsPreview: row.currentTranscriptIsPreview
      )
    }
  }

  /// One page of history, newest first.
  ///
  /// `sourceApplication` and `since` are answered in SQL rather than by the
  /// caller, because a filter applied after the fetch cannot be paged: the
  /// page boundary would fall in the unfiltered order and each page would
  /// hold an arbitrary number of matches. Pass `offset` to continue a
  /// previous call made with the same arguments.
  public func searchHistory(
    query: String,
    mode: SessionInputMode?,
    status: DictationHistoryStatus?,
    sourceApplication: String? = nil,
    since: Date? = nil,
    limit: Int = 500,
    offset: Int = 0
  ) async throws -> [DictationHistoryItem] {
    try await searchHistory(
      query: query, mode: mode, status: status,
      candidatePhases: nil, includingSessionID: nil,
      sourceApplication: sourceApplication, since: since, limit: limit, offset: offset
    )
  }

  /// Limits presentation-state candidates before LIMIT/OFFSET. The optional
  /// included session widens only the phase predicate; all other filters remain
  /// in force. The original status API retains its exact persisted semantics.
  public func searchHistory(
    query: String,
    mode: SessionInputMode?,
    status: DictationHistoryStatus?,
    candidatePhases: [DictationPhase]?,
    includingSessionID: SessionID? = nil,
    sourceApplication: String? = nil,
    since: Date? = nil,
    limit: Int = 500,
    offset: Int = 0
  ) async throws -> [DictationHistoryItem] {
    let boundedLimit = min(max(1, limit), 10_000)
    let boundedOffset = max(0, offset)
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let database = try requirePool()
    let matchingIDs: [SessionID] = try await database.read { db in
      var predicates = ["d.phase <> 'cancelled'"]
      var arguments = StatementArguments()
      if let mode {
        predicates.append("s.input_mode = ?")
        arguments += [mode.rawValue]
      }
      if let sourceApplication, !sourceApplication.isEmpty {
        predicates.append("m.source_bundle_id = ?")
        arguments += [sourceApplication]
      }
      if let since {
        predicates.append("s.created_at >= ?")
        arguments += [since.timeIntervalSince1970]
      }
      if let status {
        switch status {
        case .completed:
          predicates.append("d.phase = 'completed' AND d.recovered_at IS NULL")
        case .recovered:
          predicates.append("d.phase = 'completed' AND d.recovered_at IS NOT NULL")
        case .failed:
          predicates.append("d.phase = 'failedRecoverable'")
        case .processing:
          predicates.append(
            "d.phase NOT IN ('completed', 'cancelled', 'failedRecoverable')"
          )
        }
      }
      if let candidatePhases {
        let placeholders = Array(repeating: "?", count: candidatePhases.count)
          .joined(separator: ", ")
        var candidatePredicate =
          candidatePhases.isEmpty
          ? "0" : "d.phase IN (\(placeholders))"
        arguments += StatementArguments(candidatePhases.map(\.rawValue))
        if let includingSessionID {
          candidatePredicate += " OR s.id = ?"
          arguments += [includingSessionID.rawValue.uuidString]
        }
        predicates.append("(\(candidatePredicate))")
      }
      if !normalized.isEmpty {
        if normalized.count >= 3 {
          let phrase = "\"\(normalized.replacingOccurrences(of: "\"", with: "\"\""))\""
          predicates.append(
            """
            (
              EXISTS (
                SELECT 1 FROM history_search_fts
                WHERE history_search_fts.session_id = s.id
                  AND history_search_fts MATCH ?
              ) OR EXISTS (
                SELECT 1 FROM history_search_fts
                JOIN speaker_occurrences o
                  ON o.person_id = history_search_fts.person_id
                JOIN persons p ON p.id = o.person_id
                WHERE history_search_fts.source_kind = 'person'
                  AND o.session_id = s.id AND p.retired_at IS NULL
                  AND o.association_status IN (
                    'anonymousIdentity', 'automaticMatch', 'userConfirmed'
                  )
                  AND history_search_fts MATCH ?
              ) OR EXISTS (
                SELECT 1 FROM history_search_fts
                JOIN event_sessions es
                  ON es.event_id = history_search_fts.source_id
                JOIN events e ON e.id = es.event_id
                WHERE history_search_fts.source_kind = 'event'
                  AND es.session_id = s.id AND e.retired_at IS NULL
                  AND history_search_fts MATCH ?
              ) OR EXISTS (
                SELECT 1 FROM history_search_fts
                JOIN event_text_documents etd
                  ON etd.id = history_search_fts.source_id
                JOIN event_sessions es ON es.event_id = etd.event_id
                JOIN events e ON e.id = es.event_id
                WHERE history_search_fts.source_kind = 'event_text'
                  AND es.session_id = s.id AND e.retired_at IS NULL
                  AND etd.state = 'current'
                  AND history_search_fts MATCH ?
              )
            )
            """)
          arguments += [phrase, phrase, phrase, phrase]
        } else {
          let pattern = "%\(normalized)%"
          predicates.append(
            """
            (
              m.title LIKE ? OR COALESCE(m.source_display_name, '') LIKE ? OR
              COALESCE(m.source_bundle_id, '') LIKE ? OR
              COALESCE(m.source_identifier, '') LIKE ? OR
              EXISTS (SELECT 1 FROM transcript_revisions tr
                WHERE tr.session_id = s.id AND tr.content LIKE ?) OR
              EXISTS (SELECT 1 FROM derived_text_revisions dt
                WHERE dt.session_id = s.id AND dt.output_text LIKE ?) OR
              EXISTS (SELECT 1 FROM local_text_documents lt
                WHERE lt.session_id = s.id AND CAST(lt.result_json AS TEXT) LIKE ?) OR
              EXISTS (SELECT 1 FROM session_source_assets sa
                WHERE sa.session_id = s.id AND sa.original_filename LIKE ?) OR
              EXISTS (SELECT 1 FROM speaker_occurrences o
                JOIN persons p ON p.id = o.person_id
                WHERE o.session_id = s.id AND p.retired_at IS NULL AND
                  o.association_status IN (
                    'anonymousIdentity', 'automaticMatch', 'userConfirmed'
                  ) AND
                  (COALESCE(p.display_name, '') LIKE ? OR
                   CAST(p.aliases_json AS TEXT) LIKE ? OR
                   (CASE WHEN trim(COALESCE(p.display_name, '')) = ''
                     THEN '待命名 未知人物' ELSE '' END) LIKE ?)) OR
              EXISTS (SELECT 1 FROM source_context_events sc
                WHERE sc.session_id = s.id AND
                  (COALESCE(sc.meeting_title, '') LIKE ? OR
                   COALESCE(sc.window_title, '') LIKE ? OR
                   CAST(sc.participant_names_json AS TEXT) LIKE ? OR
                   COALESCE(sc.active_speaker_name, '') LIKE ?)) OR
              EXISTS (SELECT 1 FROM event_sessions es
                JOIN events e ON e.id = es.event_id
                WHERE es.session_id = s.id AND e.retired_at IS NULL AND
                  (e.title LIKE ? OR e.notes LIKE ? OR EXISTS (
                    SELECT 1 FROM event_text_documents etd
                    WHERE etd.event_id = e.id AND etd.state = 'current'
                      AND CAST(etd.result_json AS TEXT) LIKE ?
                  )))
            )
            """)
          arguments += StatementArguments(
            Array(repeating: pattern, count: 18)
          )
        }
      }
      arguments += [boundedLimit, boundedOffset]
      let rows = try String.fetchAll(
        db,
        sql: """
          SELECT s.id
          FROM sessions s
          JOIN dictation_snapshots d ON d.session_id = s.id
          JOIN session_metadata m ON m.session_id = s.id
          WHERE \(predicates.joined(separator: " AND "))
          ORDER BY d.updated_at DESC, s.id
          LIMIT ? OFFSET ?
          """,
        arguments: arguments
      )
      return rows.compactMap { UUID(uuidString: $0).map(SessionID.init) }
    }
    return try await loadHistory(limit: boundedLimit, sessionIDs: matchingIDs)
  }

  /// The applications history was dictated into, most-used first, for the
  /// filter that offers them. Only sessions that recorded an application are
  /// counted, so the list is exactly what the filter can select.
  public func historySourceApplications() async throws
    -> [DictationHistorySourceApplication]
  {
    let database = try requirePool()
    return try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT m.source_bundle_id AS bundle_id,
                 COALESCE(MAX(m.source_display_name), '') AS display_name,
                 COUNT(*) AS session_count
          FROM session_metadata m
          JOIN dictation_snapshots d ON d.session_id = m.session_id
          WHERE d.phase <> 'cancelled'
            AND m.source_bundle_id IS NOT NULL AND m.source_bundle_id <> ''
          GROUP BY m.source_bundle_id
          ORDER BY session_count DESC, bundle_id
          """
      ).map { row in
        DictationHistorySourceApplication(
          bundleIdentifier: row["bundle_id"],
          displayName: row["display_name"],
          sessionCount: row["session_count"]
        )
      }
    }
  }

  public func historyCountsByMode() async throws -> [SessionInputMode: Int] {
    let database = try requirePool()
    return try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT input_mode, COUNT(*) AS count FROM sessions GROUP BY input_mode"
      )
      var result: [SessionInputMode: Int] = [:]
      for row in rows {
        guard let mode = SessionInputMode(rawValue: row["input_mode"] as String)
        else { throw BestASRPersistenceError.storedDataCorrupt }
        result[mode] = row["count"] as Int
      }
      return result
    }
  }

  public func historyUsageStatistics() async throws
    -> LocalHistoryUsageStatistics
  {
    let database = try requirePool()
    return try await database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            WITH \(Self.recordedAudioDurationsCTE)
            SELECT
              COUNT(*) AS session_count,
              COALESCE(SUM(COALESCE(rad.duration_ns, 0)), 0)
                AS recorded_duration_ns,
              COALESCE(SUM(LENGTH(COALESCE(
                (
                  SELECT dt.output_text FROM derived_text_revisions dt
                  WHERE dt.session_id = s.id AND dt.state = 'current'
                  ORDER BY dt.source_revision DESC, dt.created_at DESC, dt.id DESC
                  LIMIT 1
                ),
                (
                  SELECT tr.content FROM transcript_revisions tr
                  WHERE tr.session_id = s.id
                  ORDER BY CASE
                             WHEN tr.kind IN ('final', 'userEdit') THEN 1
                             ELSE 0
                           END DESC,
                           tr.created_at DESC, tr.revision DESC, tr.id DESC
                  LIMIT 1
                ),
                ''
              ))), 0) AS character_count,
              COUNT(DISTINCT strftime(
                '%Y-%m-%d', s.created_at, 'unixepoch', 'localtime'
              )) AS active_day_count
            FROM sessions s
            JOIN dictation_snapshots d ON d.session_id = s.id
            LEFT JOIN recorded_audio_durations rad ON rad.session_id = s.id
            WHERE d.phase <> 'cancelled'
            """
        )
      else { return LocalHistoryUsageStatistics() }
      let sessionCount: Int64 = row["session_count"]
      let duration: Int64 = row["recorded_duration_ns"]
      let characterCount: Int64 = row["character_count"]
      let activeDayCount: Int64 = row["active_day_count"]
      guard sessionCount >= 0, duration >= 0, characterCount >= 0,
        activeDayCount >= 0,
        sessionCount <= Int64(Int.max), activeDayCount <= Int64(Int.max)
      else { throw BestASRPersistenceError.numericOverflow }
      return LocalHistoryUsageStatistics(
        sessionCount: Int(sessionCount),
        recordedDurationNanoseconds: UInt64(duration),
        currentTextCharacterCount: UInt64(characterCount),
        activeDayCount: Int(activeDayCount)
      )
    }
  }

  /// Every non-cancelled dictation with its speech duration and current text,
  /// oldest first, for the Home statistics.
  public func dictationActivityRecords() async throws -> [DictationActivityRecord] {
    let database = try requirePool()
    return try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          WITH \(Self.recordedAudioDurationsCTE)
          SELECT
            s.created_at AS created_at,
            COALESCE(rad.duration_ns, 0) AS duration_ns,
            COALESCE(
              (
                SELECT dt.output_text FROM derived_text_revisions dt
                WHERE dt.session_id = s.id AND dt.state = 'current'
                ORDER BY dt.source_revision DESC, dt.created_at DESC, dt.id DESC
                LIMIT 1
              ),
              (
                SELECT tr.content FROM transcript_revisions tr
                WHERE tr.session_id = s.id
                ORDER BY CASE
                           WHEN tr.kind IN ('final', 'userEdit') THEN 1
                           ELSE 0
                         END DESC,
                         tr.created_at DESC, tr.revision DESC, tr.id DESC
                LIMIT 1
              ),
              ''
            ) AS text
          FROM sessions s
          JOIN dictation_snapshots d ON d.session_id = s.id
          LEFT JOIN recorded_audio_durations rad ON rad.session_id = s.id
          WHERE d.phase <> 'cancelled' AND s.input_mode = 'dictation'
          ORDER BY s.created_at
          """
      ).map { row in
        let duration: Int64 = row["duration_ns"]
        return DictationActivityRecord(
          createdAt: Date(timeIntervalSince1970: row["created_at"]),
          speechNanoseconds: UInt64(max(0, duration)),
          text: row["text"]
        )
      }
    }
  }

  public func sessionModes() async throws -> [SessionID: SessionInputMode] {
    let database = try requirePool()
    return try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT id, input_mode FROM sessions ORDER BY id"
      )
      var result: [SessionID: SessionInputMode] = [:]
      for row in rows {
        guard let rawID = UUID(uuidString: row["id"] as String),
          let mode = SessionInputMode(rawValue: row["input_mode"] as String)
        else { throw BestASRPersistenceError.storedDataCorrupt }
        result[SessionID(rawID)] = mode
      }
      return result
    }
  }

  public func markRecovered(sessionID: SessionID) async throws {
    let database = try requirePool()
    let recoveredAt = Self.databaseDate(clock.wallTime()).timeIntervalSince1970
    try await database.write { db in
      guard
        try String.fetchOne(
          db,
          sql: "SELECT phase FROM dictation_snapshots WHERE session_id = ?",
          arguments: [sessionID.rawValue.uuidString]
        ) == DictationPhase.completed.rawValue
      else {
        throw BestASRPersistenceError.invalidSnapshot
      }
      try db.execute(
        sql: """
          UPDATE dictation_snapshots SET recovered_at = ?
          WHERE session_id = ? AND recovered_at IS NULL
          """,
        arguments: [recoveredAt, sessionID.rawValue.uuidString]
      )
    }
  }

  /// Removes one session only after the UI has obtained explicit confirmation
  /// that retained source audio will also be deleted. Filesystem staging is
  /// owned by ProductionAudioJournal; this method changes database state only.
  public func deleteSessionRecordsExplicitly(
    sessionID: SessionID
  ) async throws {
    try await deleteSessionRecordsExplicitly(sessionIDs: [sessionID])
  }

  /// Deletes an explicitly confirmed set in one SQLite transaction. Callers
  /// stage every retained session directory before entering this method, so a
  /// database failure can restore every directory without leaving a partially
  /// cleared history category.
  public func deleteSessionRecordsExplicitly(
    sessionIDs: [SessionID]
  ) async throws {
    let requested = Array(Set(sessionIDs.map { $0.rawValue.uuidString })).sorted()
    guard !requested.isEmpty else { return }
    let database = try requirePool()
    let deletedAt = Self.databaseDate(clock.wallTime())
    try await database.write { db in
      for value in requested {
        guard
          try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?)",
            arguments: [value]
          ) == true
        else { throw BestASRPersistenceError.missingSession }
      }
      // A recording's video keyframes (items of their own that carry text read
      // from it) go with it, here and on the organizing device (privacy
      // review F6). Callers stage their directories with
      // `keyframeSessionIDs(of:)`.
      let values = try Self.withKeyframes(requested, in: db)
      for value in values {
        try Self.deleteSessionRecords(value: value, at: deletedAt, in: db)
      }
    }
  }

  /// The keyframe items taken from these recordings (not the recordings).
  public func keyframeSessionIDs(of parents: [SessionID]) async throws -> [SessionID] {
    let values = parents.map { $0.rawValue.uuidString }
    guard !values.isEmpty else { return [] }
    let database = try requirePool()
    return try await database.read { db in
      try Self.withKeyframes(values, in: db).filter { !values.contains($0) }
        .compactMap { UUID(uuidString: $0).map(SessionID.init) }
    }
  }

  /// `values` and the sessions of every keyframe taken from them, sorted.
  nonisolated static func withKeyframes(_ values: [String], in db: Database) throws -> [String] {
    var all = Set(values)
    for chunk in stride(from: 0, to: values.count, by: 500).map({
      Array(values[$0..<min($0 + 500, values.count)])
    }) {
      let marks = chunk.map { _ in "?" }.joined(separator: ",")
      let frames = try String.fetchAll(
        db,
        sql: """
          SELECT session_id FROM user_item_details
          WHERE parent_session_id IN (\(marks))
            AND EXISTS (SELECT 1 FROM sessions WHERE id = user_item_details.session_id)
          """,
        arguments: StatementArguments(chunk))
      all.formUnion(frames)
    }
    return all.sorted()
  }

  private static func deleteSessionRecords(
    value: String,
    at deletedAt: Date,
    in db: Database
  ) throws {
    // What the organizing device may hold is deleted there too (contract
    // v6): only items that were sent at least once, and the deletion itself
    // carries no content.
    try queueRemoteDeletion(db, itemID: value, at: deletedAt.timeIntervalSince1970)
    // A user-deleted source must never leave this Mac later from the outbox.
    try db.execute(
      sql: "DELETE FROM remote_organizer_item_jobs WHERE item_id = ?",
      arguments: [value]
    )
    try dropRemoteReading(db, itemID: value)
    try db.execute(
      sql: "DELETE FROM remote_organizer_eligible WHERE session_id = ?",
      arguments: [value]
    )
    // Event membership is deliberately RESTRICT rather than CASCADE so source
    // evidence cannot disappear through an unrelated cleanup path. Explicit
    // history deletion is the one authorized path that may detach it. Do that
    // first and recompute the surviving event from its remaining evidence.
    try detachSessionFromEventMemory(value: value, at: deletedAt, in: db)
    try db.execute(
      sql: "DELETE FROM local_text_documents WHERE session_id = ?",
      arguments: [value]
    )
    try db.execute(
      sql: "DELETE FROM derived_text_revisions WHERE session_id = ?",
      arguments: [value]
    )
    try db.execute(
      sql: "DELETE FROM insertion_outcomes WHERE session_id = ?",
      arguments: [value]
    )
    try db.execute(
      sql: "DELETE FROM session_source_assets WHERE session_id = ?",
      arguments: [value]
    )
    try db.execute(
      sql: """
        DELETE FROM person_embeddings WHERE source_occurrence_id IN (
          SELECT id FROM speaker_occurrences WHERE session_id = ?
        )
        """,
      arguments: [value]
    )
    try db.execute(
      sql: """
        DELETE FROM speaker_occurrence_tracks WHERE occurrence_id IN (
          SELECT id FROM speaker_occurrences WHERE session_id = ?
        )
        """,
      arguments: [value]
    )
    try db.execute(
      sql: "DELETE FROM speaker_occurrences WHERE session_id = ?",
      arguments: [value]
    )
    try db.execute(
      sql: """
        DELETE FROM session_speaker_embeddings WHERE session_speaker_id IN (
          SELECT id FROM session_speakers WHERE session_id = ?
        )
        """,
      arguments: [value]
    )
    try db.execute(
      sql: "DELETE FROM session_speakers WHERE session_id = ?",
      arguments: [value]
    )
    let jobIDs = try String.fetchAll(
      db,
      sql: "SELECT job_id FROM dictation_job_sessions WHERE session_id = ?",
      arguments: [value]
    )
    try db.execute(
      sql: "DELETE FROM dictation_job_sessions WHERE session_id = ?",
      arguments: [value]
    )
    for jobID in jobIDs {
      try db.execute(
        sql: "DELETE FROM speaker_job_inputs WHERE job_id = ?",
        arguments: [jobID]
      )
      try db.execute(
        sql: "DELETE FROM durable_jobs WHERE id = ?",
        arguments: [jobID]
      )
    }
    // `parent_id` intentionally uses RESTRICT so provenance cannot disappear
    // during ordinary revision updates. Explicitly deleting the whole session
    // is different: every revision in the chain is removed in this same
    // transaction, so sever the internal links before the bulk delete.
    try db.execute(
      sql: "UPDATE transcript_revisions SET parent_id = NULL WHERE session_id = ?",
      arguments: [value]
    )
    try db.execute(
      sql: "DELETE FROM transcript_revisions WHERE session_id = ?",
      arguments: [value]
    )
    try db.execute(
      sql: "DELETE FROM audio_chunks WHERE session_id = ?",
      arguments: [value]
    )
    try db.execute(
      sql: "DELETE FROM timeline_events WHERE session_id = ?",
      arguments: [value]
    )
    try db.execute(
      sql: "DELETE FROM tracks WHERE session_id = ?",
      arguments: [value]
    )
    try db.execute(
      sql: "DELETE FROM dictation_snapshots WHERE session_id = ?",
      arguments: [value]
    )
    try db.execute(
      sql: "DELETE FROM user_item_details WHERE session_id = ?",
      arguments: [value]
    )
    try db.execute(
      sql: "DELETE FROM sessions WHERE id = ?",
      arguments: [value]
    )
    guard db.changesCount == 1 else {
      throw BestASRPersistenceError.processingCommitConflict
    }
  }

  /// Records an explicit source-audio-only deletion without deleting any text,
  /// timeline, person, or provenance metadata. The filesystem is staged by the
  /// caller before this transaction and rolled back if this method fails.
  public func markSessionSourceAudioExplicitlyDeleted(
    sessionID: SessionID
  ) async throws {
    let value = sessionID.rawValue.uuidString
    let database = try requirePool()
    try await database.write { db in
      guard
        let current = try String.fetchOne(
          db,
          sql: "SELECT source_audio_retention FROM sessions WHERE id = ?",
          arguments: [value]
        )
      else { throw BestASRPersistenceError.missingSession }
      guard
        current
          == SourceAudioRetention.retainedUntilExplicitDeletion.rawValue
      else { throw BestASRPersistenceError.invalidSnapshot }
      // A pasted or dragged item has no audio; its original file is removed
      // only together with the whole item.
      guard
        try String.fetchOne(
          db, sql: "SELECT input_mode FROM sessions WHERE id = ?", arguments: [value]
        ) != SessionInputMode.userItem.rawValue
      else { throw BestASRPersistenceError.invalidSnapshot }

      // Imported originals live inside the same authenticated session asset
      // directory as the journal, so their database handles must disappear in
      // the same atomic user-authorized operation.
      try db.execute(
        sql: "DELETE FROM session_source_assets WHERE session_id = ?",
        arguments: [value]
      )
      try db.execute(
        sql: """
          UPDATE sessions
          SET source_audio_retention = ?, revision = revision + 1,
              updated_at = ?
          WHERE id = ? AND source_audio_retention = ?
          """,
        arguments: [
          SourceAudioRetention.explicitlyDeletedByUser.rawValue,
          clock.wallTime().timeIntervalSince1970,
          value,
          SourceAudioRetention.retainedUntilExplicitDeletion.rawValue,
        ]
      )
      guard db.changesCount == 1 else {
        throw BestASRPersistenceError.processingCommitConflict
      }
    }
  }

  public func reserveInsertion(
    sessionID: SessionID,
    key: DictationIdempotencyKey
  ) async throws -> InsertionReservation {
    let database = try requirePool()
    let now = clock.wallTime().timeIntervalSince1970
    return try await database.write { db in
      if let row = try Row.fetchOne(
        db,
        sql: """
          SELECT idempotency_key, state FROM insertion_outcomes
          WHERE session_id = ?
          """,
        arguments: [sessionID.rawValue.uuidString]
      ) {
        let storedKey: String = row["idempotency_key"]
        guard storedKey == key.value else {
          throw BestASRPersistenceError.insertionKeyConflict
        }
        let state: String = row["state"]
        return state == "completed" ? .alreadyCompleted : .alreadyReserved
      }
      try db.execute(
        sql: """
          INSERT INTO insertion_outcomes (
            session_id, idempotency_key, state, result_json, updated_at
          ) VALUES (?, ?, 'reserved', NULL, ?)
          """,
        arguments: [sessionID.rawValue.uuidString, key.value, now]
      )
      return .acquired
    }
  }

  public func completeInsertion(
    sessionID: SessionID,
    result: DictationInsertionResult
  ) async throws {
    let database = try requirePool()
    let data = try encode(result)
    let now = clock.wallTime().timeIntervalSince1970
    try await database.write { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT idempotency_key, state, result_json FROM insertion_outcomes
            WHERE session_id = ?
            """,
          arguments: [sessionID.rawValue.uuidString]
        )
      else {
        throw BestASRPersistenceError.insertionNotReserved
      }
      let storedKey: String = row["idempotency_key"]
      guard storedKey == result.idempotencyKey.value else {
        throw BestASRPersistenceError.insertionKeyConflict
      }
      let state: String = row["state"]
      if state == "completed" {
        guard let existingData: Data = row["result_json"],
          try self.decode(DictationInsertionResult.self, from: existingData) == result
        else {
          throw BestASRPersistenceError.insertionKeyConflict
        }
        return
      }
      try db.execute(
        sql: """
          UPDATE insertion_outcomes
          SET state = 'completed', result_json = ?, updated_at = ?
          WHERE session_id = ?
          """,
        arguments: [data, now, sessionID.rawValue.uuidString]
      )
    }
  }

  public func insertionResult(
    sessionID: SessionID
  ) async throws -> DictationInsertionResult? {
    let database = try requirePool()
    let data = try await database.read { db in
      try Data.fetchOne(
        db,
        sql: """
          SELECT result_json FROM insertion_outcomes
          WHERE session_id = ? AND state = 'completed'
          """,
        arguments: [sessionID.rawValue.uuidString]
      )
    }
    guard let data else { return nil }
    return try decode(DictationInsertionResult.self, from: data)
  }

  public func commitRecognition(
    _ commit: DictationRecognitionCommit
  ) async throws {
    do { try commit.snapshot.validate() } catch { throw BestASRPersistenceError.invalidSnapshot }
    guard commit.inputRevision > 0,
      commit.snapshot.phase == .polishing,
      let sessionID = commit.snapshot.sessionID,
      commit.snapshot.transcript == commit.transcript,
      (commit.transcript.provenance?.kind ?? .final) == .final
    else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    try Self.validateTranscript(commit.transcript)
    let snapshotData = try encode(commit.snapshot)
    let now = clock.wallTime().timeIntervalSince1970
    let expectedInputRevision = try Self.sqliteInt(commit.inputRevision)
    let database = try requirePool()
    try await database.write { db in
      try Self.commitTranscriptRevision(
        DictationTranscriptRevisionCommit(
          sessionID: sessionID,
          transcript: commit.transcript,
          inputRevision: commit.inputRevision,
          configHash: commit.configHash,
          createdAt: commit.createdAt
        ),
        expectedInputRevision: expectedInputRevision,
        in: db
      )
      try Self.commitSnapshot(
        commit.snapshot,
        data: snapshotData,
        updatedAt: now,
        in: db
      )
    }
  }

  public func commitTranscriptRevision(
    _ commit: DictationTranscriptRevisionCommit
  ) async throws {
    guard commit.inputRevision > 0 else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    try Self.validateTranscript(commit.transcript)
    let expectedInputRevision = try Self.sqliteInt(commit.inputRevision)
    let database = try requirePool()
    try await database.write { db in
      try Self.commitHistoryTranscriptRevision(
        commit,
        expectedInputRevision: expectedInputRevision,
        in: db
      )
    }
  }

  /// Publishes text and its automatic speaker follow-up atomically. A nil job
  /// means the recording contains user-confirmed identity decisions: those are
  /// deliberately retained rather than overwritten by automatic reclustering.
  public func commitRerecognizedTranscriptRevision(
    _ commit: DictationTranscriptRevisionCommit,
    sourceAudio: [AudioRangeInput],
    speakerModelArtifactKey: String,
    embeddingSpaceID: String,
    speakerConfigHash: SHA256Digest
  ) async throws -> DurableJob? {
    try Self.validateTranscript(commit.transcript)
    let expectedInputRevision = try Self.sqliteInt(commit.inputRevision)
    let work = try Self.prepareSpeakerFinalWork(
      sessionID: commit.sessionID, audio: sourceAudio,
      inputRevision: commit.inputRevision,
      modelArtifactKey: speakerModelArtifactKey,
      embeddingSpaceID: embeddingSpaceID, configHash: speakerConfigHash
    )
    let database = try requirePool()
    return try await database.write { db in
      guard
        try String.fetchOne(
          db, sql: "SELECT source_audio_retention FROM sessions WHERE id = ?",
          arguments: [commit.sessionID.rawValue.uuidString]
        ) == SourceAudioRetention.retainedUntilExplicitDeletion.rawValue
      else { throw BestASRPersistenceError.processingCommitConflict }
      let latestOtherRevision =
        try Int64.fetchOne(
          db,
          sql: "SELECT MAX(revision) FROM transcript_revisions WHERE session_id = ? AND id != ?",
          arguments: [
            commit.sessionID.rawValue.uuidString,
            commit.transcript.revisionID.rawValue.uuidString,
          ]
        ) ?? 0
      guard latestOtherRevision < expectedInputRevision
      else { throw BestASRPersistenceError.processingCommitConflict }
      try Self.commitHistoryTranscriptRevision(
        commit, expectedInputRevision: expectedInputRevision, in: db
      )
      let keepsHumanDecisions =
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS (
              SELECT 1 FROM speaker_occurrences
              WHERE session_id = ? AND association_status = ?
            )
            """,
          arguments: [
            commit.sessionID.rawValue.uuidString,
            PersonAssociationStatus.userConfirmed.rawValue,
          ]
        ) ?? false
      guard !keepsHumanDecisions else { return nil }
      try Self.insertSpeakerFinalWork(
        work, modelArtifactKey: speakerModelArtifactKey,
        embeddingSpaceID: embeddingSpaceID, in: db
      )
      return work.job
    }
  }

  public func speakerFinalJob(id: DurableJobID) async throws -> DurableJob? {
    let database = try requirePool()
    return try await database.read { db in
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT * FROM durable_jobs WHERE id = ? AND kind = ?",
          arguments: [id.rawValue.uuidString, DurableJobKind.speakerFinal.rawValue]
        )
      else { return nil }
      return try Self.durableJob(row)
    }
  }

  public func commitPolish(_ commit: DictationPolishCommit) async throws {
    do { try commit.snapshot.validate() } catch { throw BestASRPersistenceError.invalidSnapshot }
    guard commit.sourceRevision > 0,
      commit.snapshot.phase == .inserting,
      let sessionID = commit.snapshot.sessionID,
      commit.snapshot.polish == commit.polish,
      commit.snapshot.transcript?.revisionID == commit.polish.sourceRevisionID
    else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let snapshotData = try encode(commit.snapshot)
    let now = clock.wallTime().timeIntervalSince1970
    let expectedSourceRevision = try Self.sqliteInt(commit.sourceRevision)
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO derived_text_revisions (
            id, session_id, source_transcript_id, source_revision,
            output_text, model_artifact_id, config_hash, state, created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, 'current', ?)
          ON CONFLICT(id) DO NOTHING
          """,
        arguments: [
          commit.derivationID.uuidString,
          sessionID.rawValue.uuidString,
          commit.polish.sourceRevisionID.rawValue.uuidString,
          expectedSourceRevision,
          commit.polish.text,
          commit.polish.modelArtifactID,
          commit.configHash.value,
          commit.createdAt.timeIntervalSince1970,
        ]
      )
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT session_id, source_transcript_id, source_revision,
                   output_text, model_artifact_id, config_hash, state, created_at
            FROM derived_text_revisions WHERE id = ?
            """,
          arguments: [commit.derivationID.uuidString]
        )
      else {
        throw BestASRPersistenceError.processingCommitConflict
      }
      let storedSessionID: String = row["session_id"]
      let storedSourceID: String = row["source_transcript_id"]
      let storedRevision: Int64 = row["source_revision"]
      let storedOutput: String = row["output_text"]
      let storedModel: String? = row["model_artifact_id"]
      let storedConfig: String = row["config_hash"]
      let storedState: String = row["state"]
      let storedCreatedAt: Double = row["created_at"]
      guard storedSessionID == sessionID.rawValue.uuidString,
        storedSourceID == commit.polish.sourceRevisionID.rawValue.uuidString,
        storedRevision == expectedSourceRevision,
        storedOutput == commit.polish.text,
        storedModel == commit.polish.modelArtifactID,
        storedConfig == commit.configHash.value,
        storedState == DictationDerivedTextState.current.rawValue,
        storedCreatedAt == commit.createdAt.timeIntervalSince1970
      else {
        throw BestASRPersistenceError.processingCommitConflict
      }
      try Self.commitSnapshot(
        commit.snapshot,
        data: snapshotData,
        updatedAt: now,
        in: db
      )
    }
  }

  public func commitInsertion(
    _ commit: DictationInsertionCommit
  ) async throws {
    do { try commit.snapshot.validate() } catch { throw BestASRPersistenceError.invalidSnapshot }
    guard commit.snapshot.phase == .completed,
      let sessionID = commit.snapshot.sessionID,
      commit.snapshot.insertion == commit.result
    else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let resultData = try encode(commit.result)
    let snapshotData = try encode(commit.snapshot)
    let now = clock.wallTime().timeIntervalSince1970
    let database = try requirePool()
    try await database.write { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT idempotency_key, state, result_json FROM insertion_outcomes
            WHERE session_id = ?
            """,
          arguments: [sessionID.rawValue.uuidString]
        )
      else {
        throw BestASRPersistenceError.insertionNotReserved
      }
      let storedKey: String = row["idempotency_key"]
      guard storedKey == commit.result.idempotencyKey.value else {
        throw BestASRPersistenceError.insertionKeyConflict
      }
      let state: String = row["state"]
      if state == "completed" {
        guard let existingData: Data = row["result_json"],
          try self.decode(DictationInsertionResult.self, from: existingData)
            == commit.result
        else {
          throw BestASRPersistenceError.insertionKeyConflict
        }
      } else {
        try db.execute(
          sql: """
            UPDATE insertion_outcomes
            SET state = 'completed', result_json = ?, updated_at = ?
            WHERE session_id = ?
            """,
          arguments: [resultData, now, sessionID.rawValue.uuidString]
        )
      }
      try Self.commitSnapshot(
        commit.snapshot,
        data: snapshotData,
        updatedAt: now,
        in: db
      )
    }
  }

  public func cancelEphemeral(sessionID: SessionID) async throws {
    let database = try requirePool()
    let cancelledAt = Self.databaseDate(clock.wallTime())
    try await database.write { db in
      guard
        let ephemeral = try Bool.fetchOne(
          db,
          sql: "SELECT is_ephemeral FROM dictation_snapshots WHERE session_id = ?",
          arguments: [sessionID.rawValue.uuidString]
        )
      else {
        throw BestASRPersistenceError.missingSession
      }
      guard ephemeral else {
        throw BestASRPersistenceError.invalidSnapshot
      }
      try Self.detachSessionFromEventMemory(
        value: sessionID.rawValue.uuidString,
        at: cancelledAt,
        in: db
      )
      let jobIDs = try String.fetchAll(
        db,
        sql: "SELECT job_id FROM dictation_job_sessions WHERE session_id = ?",
        arguments: [sessionID.rawValue.uuidString]
      )
      try db.execute(
        sql: """
          DELETE FROM speaker_occurrence_tracks
          WHERE occurrence_id IN (
            SELECT id FROM speaker_occurrences WHERE session_id = ?
          )
          OR track_id IN (
            SELECT id FROM tracks WHERE session_id = ?
          )
          """,
        arguments: [
          sessionID.rawValue.uuidString,
          sessionID.rawValue.uuidString,
        ]
      )
      // parent_id is an immediate RESTRICT self-reference. A single bulk
      // DELETE still fails while child revisions point at parents selected by
      // that same statement, so detach only this ephemeral session's chain
      // inside the deletion transaction first.
      try db.execute(
        sql: """
          UPDATE transcript_revisions SET parent_id = NULL
          WHERE session_id = ?
          """,
        arguments: [sessionID.rawValue.uuidString]
      )
      for table in [
        "speaker_occurrences", "session_speakers", "derived_text_revisions",
        "insertion_outcomes", "transcript_revisions", "timeline_events",
        "audio_chunks", "session_source_assets", "tracks",
        "dictation_job_sessions", "dictation_snapshots",
      ] {
        try db.execute(
          sql: "DELETE FROM \(table) WHERE session_id = ?",
          arguments: [sessionID.rawValue.uuidString]
        )
      }
      for jobID in jobIDs {
        try db.execute(
          sql: "DELETE FROM durable_jobs WHERE id = ?",
          arguments: [jobID]
        )
      }
      try db.execute(
        sql: "DELETE FROM sessions WHERE id = ?",
        arguments: [sessionID.rawValue.uuidString]
      )
    }
  }

  public func save(track: SourceTrack) async throws {
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO tracks (
            id, session_id, revision, role, asset_reference,
            sample_rate_hz, channel_count
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          track.id.rawValue.uuidString,
          track.sessionID.rawValue.uuidString,
          try Self.sqliteInt(track.revision.value),
          track.role.rawValue,
          Self.assetReference(track.assetReference),
          Int64(track.sampleRateHertz),
          Int64(track.channelCount),
        ]
      )
    }
  }

  public func save(chunk: AudioChunk) async throws {
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO audio_chunks (
            id, session_id, track_id, revision, sequence,
            monotonic_start_ns, frame_count, digest, asset_reference
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          chunk.id.rawValue.uuidString,
          chunk.sessionID.rawValue.uuidString,
          chunk.trackID.rawValue.uuidString,
          try Self.sqliteInt(chunk.revision.value),
          try Self.sqliteInt(chunk.sequence),
          try Self.sqliteInt(chunk.monotonicStartNanoseconds),
          try Self.sqliteInt(chunk.frameCount),
          chunk.contentDigest.value,
          Self.assetReference(chunk.assetReference),
        ]
      )
    }
  }

  public func save(timelineEvent: TimelineEvent) async throws {
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO timeline_events (
            id, session_id, revision, kind, monotonic_ns, duration_ns
          ) VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET duration_ns = excluded.duration_ns
          WHERE timeline_events.session_id = excluded.session_id
            AND timeline_events.kind = excluded.kind
            AND timeline_events.monotonic_ns = excluded.monotonic_ns
          """,
        arguments: [
          timelineEvent.id.rawValue.uuidString,
          timelineEvent.sessionID.rawValue.uuidString,
          try Self.sqliteInt(timelineEvent.revision.value),
          timelineEvent.kind.rawValue,
          try Self.sqliteInt(timelineEvent.monotonicNanoseconds),
          try timelineEvent.durationNanoseconds.map(Self.sqliteInt),
        ]
      )
    }
  }

  public func loadTimelineEvents(
    sessionID: SessionID
  ) async throws -> [TimelineEvent] {
    let database = try requirePool()
    return try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT id, session_id, revision, kind, monotonic_ns, duration_ns
          FROM timeline_events
          WHERE session_id = ?
          ORDER BY monotonic_ns ASC, revision ASC, id ASC
          """,
        arguments: [sessionID.rawValue.uuidString]
      )
      return try rows.map { row in
        guard
          let id = UUID(uuidString: row["id"] as String),
          let storedSessionID = UUID(uuidString: row["session_id"] as String),
          let kind = TimelineEventKind(rawValue: row["kind"] as String)
        else { throw BestASRPersistenceError.invalidSnapshot }
        let revisionValue = row["revision"] as Int64
        let monotonicValue = row["monotonic_ns"] as Int64
        let durationValue: Int64? = row["duration_ns"]
        guard revisionValue > 0, monotonicValue >= 0,
          durationValue.map({ $0 >= 0 }) ?? true
        else { throw BestASRPersistenceError.invalidSnapshot }
        return TimelineEvent(
          id: TimelineEventID(id),
          sessionID: SessionID(storedSessionID),
          revision: try Revision(UInt64(revisionValue)),
          kind: kind,
          monotonicNanoseconds: UInt64(monotonicValue),
          durationNanoseconds: durationValue.map(UInt64.init)
        )
      }
    }
  }

  public func save(transcript: TranscriptRevision) async throws {
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO transcript_revisions (
            id, session_id, revision, parent_id, kind, content,
            model_artifact_id, config_hash, created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          transcript.id.rawValue.uuidString,
          transcript.sessionID.rawValue.uuidString,
          try Self.sqliteInt(transcript.revision.value),
          transcript.parentID?.rawValue.uuidString,
          transcript.kind.rawValue,
          transcript.content,
          transcript.modelArtifactID?.rawValue.uuidString,
          transcript.configHash?.value,
          transcript.createdAt.timeIntervalSince1970,
        ]
      )
    }
  }

  public func enqueue(job: DurableJob, sessionID: SessionID) async throws {
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO durable_jobs (
            id, revision, kind, state, input_revision, model_artifact_id,
            config_hash, retry_count, error_category, lease_owner,
            lease_expires_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          job.id.rawValue.uuidString,
          try Self.sqliteInt(job.revision.value),
          job.kind.rawValue,
          job.state.rawValue,
          try Self.sqliteInt(job.inputRevision.value),
          job.modelArtifactID?.rawValue.uuidString,
          job.configHash.value,
          Int64(job.retryCount),
          job.errorCategory.rawValue,
          job.leaseOwner?.uuidString,
          job.leaseExpiresAt?.timeIntervalSince1970,
        ]
      )
      try db.execute(
        sql: "INSERT INTO dictation_job_sessions (job_id, session_id) VALUES (?, ?)",
        arguments: [job.id.rawValue.uuidString, sessionID.rawValue.uuidString]
      )
    }
  }

  public func save(derivation: DictationDerivedTextRecord) async throws {
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO derived_text_revisions (
            id, session_id, source_transcript_id, source_revision,
            output_text, model_artifact_id, config_hash, state, created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          derivation.id.uuidString,
          derivation.sessionID.rawValue.uuidString,
          derivation.sourceTranscriptID.rawValue.uuidString,
          try Self.sqliteInt(derivation.sourceRevision.value),
          derivation.outputText,
          derivation.modelArtifactID,
          derivation.configHash.value,
          derivation.state.rawValue,
          derivation.createdAt.timeIntervalSince1970,
        ]
      )
    }
  }

  @discardableResult
  public func markDerivationsStale(
    sessionID: SessionID,
    currentSourceTranscriptID: TranscriptRevisionID,
    modelArtifactID: String?,
    configHash: SHA256Digest
  ) async throws -> Int {
    let database = try requirePool()
    return try await database.write { db in
      try db.execute(
        sql: """
          UPDATE derived_text_revisions
          SET state = 'stale'
          WHERE session_id = ? AND state = 'current' AND (
            source_transcript_id <> ? OR
            COALESCE(model_artifact_id, '') <> COALESCE(?, '') OR
            config_hash <> ?
          )
          """,
        arguments: [
          sessionID.rawValue.uuidString,
          currentSourceTranscriptID.rawValue.uuidString,
          modelArtifactID,
          configHash.value,
        ]
      )
      return db.changesCount
    }
  }

  public func loadDerivations(
    sessionID: SessionID
  ) async throws -> [DictationDerivedTextRecord] {
    let database = try requirePool()
    return try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM derived_text_revisions
          WHERE session_id = ? ORDER BY created_at, id
          """,
        arguments: [sessionID.rawValue.uuidString]
      )
      return try rows.map(Self.derivedTextRecord)
    }
  }

  public func saveLocalTextDocument(
    _ document: LocalTextDocumentRecord
  ) async throws {
    guard document.result.taskID == document.taskID,
      document.result.modelArtifactID == document.modelArtifactID,
      !document.result.outputText.isEmpty
    else { throw BestASRPersistenceError.invalidSnapshot }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let resultData = try encoder.encode(document.result)
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE local_text_documents SET state = 'stale'
          WHERE session_id = ? AND task_id = ? AND state = 'current'
            AND id <> ?
          """,
        arguments: [
          document.sessionID.rawValue.uuidString,
          document.taskID.rawValue,
          document.id.uuidString,
        ]
      )
      try db.execute(
        sql: """
          INSERT INTO local_text_documents (
            id, session_id, source_transcript_id, source_revision, task_id,
            model_artifact_id, config_hash, result_json, state, created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            result_json = excluded.result_json,
            state = excluded.state,
            created_at = excluded.created_at
          WHERE local_text_documents.session_id = excluded.session_id
            AND local_text_documents.source_transcript_id = excluded.source_transcript_id
            AND local_text_documents.source_revision = excluded.source_revision
            AND local_text_documents.task_id = excluded.task_id
            AND local_text_documents.model_artifact_id = excluded.model_artifact_id
            AND local_text_documents.config_hash = excluded.config_hash
          """,
        arguments: [
          document.id.uuidString,
          document.sessionID.rawValue.uuidString,
          document.sourceTranscriptID.rawValue.uuidString,
          try Self.sqliteInt(document.sourceRevision.value),
          document.taskID.rawValue,
          document.modelArtifactID,
          document.configHash.value,
          resultData,
          document.state.rawValue,
          document.createdAt.timeIntervalSince1970,
        ]
      )
    }
  }

  public func loadLocalTextDocuments(
    sessionID: SessionID
  ) async throws -> [LocalTextDocumentRecord] {
    let database = try requirePool()
    return try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT id, session_id, source_transcript_id, source_revision,
                 task_id, model_artifact_id, config_hash, result_json,
                 state, created_at
          FROM local_text_documents
          WHERE session_id = ?
          ORDER BY created_at DESC, id DESC
          """,
        arguments: [sessionID.rawValue.uuidString]
      )
      return try rows.map { row in
        guard
          let id = UUID(uuidString: row["id"] as String),
          let rawSessionID = UUID(uuidString: row["session_id"] as String),
          let rawTranscriptID = UUID(
            uuidString: row["source_transcript_id"] as String
          ),
          let state = DictationDerivedTextState(
            rawValue: row["state"] as String
          )
        else { throw BestASRPersistenceError.storedDataCorrupt }
        let sourceRevision: Int64 = row["source_revision"]
        let createdAt: Double = row["created_at"]
        let resultData: Data = row["result_json"]
        guard sourceRevision > 0 else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        return LocalTextDocumentRecord(
          id: id,
          sessionID: SessionID(rawSessionID),
          sourceTranscriptID: TranscriptRevisionID(rawTranscriptID),
          sourceRevision: try Revision(UInt64(sourceRevision)),
          taskID: LocalTextTaskID(row["task_id"] as String),
          modelArtifactID: row["model_artifact_id"] as String,
          configHash: try SHA256Digest(row["config_hash"] as String),
          result: try JSONDecoder().decode(
            LocalTextResult.self,
            from: resultData
          ),
          state: state,
          createdAt: Date(timeIntervalSince1970: createdAt)
        )
      }
    }
  }

  public func loadTranscripts(
    sessionID: SessionID
  ) async throws -> [DictationPersistedTranscriptRecord] {
    let database = try requirePool()
    return try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT id, session_id, revision, parent_id, kind, content,
                 model_artifact_id, config_hash, language_hints_json, created_at
          FROM transcript_revisions
          WHERE session_id = ? ORDER BY revision, created_at, id
          """,
        arguments: [sessionID.rawValue.uuidString]
      )
      return try rows.map { row in
        let transcriptID: String = row["id"]
        let segmentRows = try Row.fetchAll(
          db,
          sql: """
            SELECT segment_id, monotonic_start_ns, monotonic_end_ns,
                   text, confidence
            FROM transcript_segments
            WHERE transcript_id = ? ORDER BY ordinal
            """,
          arguments: [transcriptID]
        )
        let audioRows = try Row.fetchAll(
          db,
          sql: """
            SELECT source_id, track_id, asset_reference, digest,
                   monotonic_start_ns, monotonic_end_ns,
                   sample_rate_hz, channel_count
            FROM transcript_audio_ranges
            WHERE transcript_id = ? ORDER BY ordinal
            """,
          arguments: [transcriptID]
        )
        return try Self.persistedTranscriptRecord(
          row,
          segmentRows: segmentRows,
          audioRows: audioRows
        )
      }
    }
  }

  public func saveUserTranscriptEdit(
    sessionID: SessionID,
    content: String,
    createdAt: Date = Date()
  ) async throws -> DictationPersistedTranscriptRecord {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, content.utf8.count <= 1_000_000,
      !content.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
          && $0.value != 10 && $0.value != 9 && $0.value != 13
      })
    else { throw BestASRPersistenceError.invalidSnapshot }
    let database = try requirePool()
    let transcriptID = TranscriptRevisionID()
    let result: DictationPersistedTranscriptRecord = try await database.write { db in
      guard
        let parent = try Row.fetchOne(
          db,
          sql: """
            SELECT id, revision,
                   (SELECT MAX(all_revisions.revision)
                    FROM transcript_revisions AS all_revisions
                    WHERE all_revisions.session_id = transcript_revisions.session_id)
                     AS maximum_revision
            FROM transcript_revisions
            WHERE session_id = ?
            ORDER BY CASE
                       WHEN kind IN ('final', 'userEdit') THEN 1
                       ELSE 0
                     END DESC,
                     created_at DESC, revision DESC, id DESC LIMIT 1
            """,
          arguments: [sessionID.rawValue.uuidString]
        )
      else { throw BestASRPersistenceError.missingSession }
      let parentRevision: Int64 = parent["revision"]
      let maximumRevision: Int64 = parent["maximum_revision"]
      guard parentRevision > 0, maximumRevision > 0,
        maximumRevision < Int64.max
      else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      let revision = maximumRevision + 1
      let parentID: String = parent["id"]
      guard let parentUUID = UUID(uuidString: parentID) else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      try db.execute(
        sql: """
          INSERT INTO transcript_revisions (
            id, session_id, revision, parent_id, kind, content,
            model_artifact_id, config_hash, created_at, language_hints_json
          ) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?)
          """,
        arguments: [
          transcriptID.rawValue.uuidString,
          sessionID.rawValue.uuidString,
          revision,
          parentID,
          TranscriptRevisionKind.userEdit.rawValue,
          content,
          createdAt.timeIntervalSince1970,
          Data("[]".utf8),
        ]
      )
      try db.execute(
        sql:
          "UPDATE derived_text_revisions SET state = 'stale' WHERE session_id = ? AND state = 'current'",
        arguments: [sessionID.rawValue.uuidString]
      )
      try db.execute(
        sql:
          "UPDATE local_text_documents SET state = 'stale' WHERE session_id = ? AND state = 'current'",
        arguments: [sessionID.rawValue.uuidString]
      )
      try db.execute(
        sql: """
          UPDATE event_text_documents SET state = 'stale'
          WHERE state = 'current' AND event_id IN (
            SELECT event_id FROM event_sessions WHERE session_id = ?
          )
          """,
        arguments: [sessionID.rawValue.uuidString]
      )
      try db.execute(
        sql: "UPDATE dictation_snapshots SET updated_at = ? WHERE session_id = ?",
        arguments: [createdAt.timeIntervalSince1970, sessionID.rawValue.uuidString]
      )
      return DictationPersistedTranscriptRecord(
        id: transcriptID,
        sessionID: sessionID,
        inputRevision: UInt64(revision),
        parentID: TranscriptRevisionID(parentUUID),
        kind: .userEdit,
        content: content,
        modelArtifactID: nil,
        configHash: nil,
        languageHints: [],
        audioRanges: [],
        segments: [],
        createdAt: createdAt
      )
    }
    return result
  }

  public func saveUserTranscriptSegmentEdit(
    sessionID: SessionID,
    sourceTranscriptID: TranscriptRevisionID,
    segmentID: UUID,
    replacement: String,
    createdAt: Date = Date()
  ) async throws -> DictationPersistedTranscriptRecord {
    let text = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.utf8.count <= 100_000,
      !text.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0)
          && $0.value != 10 && $0.value != 9 && $0.value != 13
      })
    else { throw BestASRPersistenceError.invalidSnapshot }

    return try await saveUserTranscriptChange(
      sessionID: sessionID,
      sourceTranscriptID: sourceTranscriptID,
      expectedCurrentTranscriptID: sourceTranscriptID,
      segmentID: segmentID,
      replacement: text,
      createdAt: createdAt
    )
  }

  public func restoreTranscriptRevision(
    sessionID: SessionID,
    sourceTranscriptID: TranscriptRevisionID,
    expectedCurrentTranscriptID: TranscriptRevisionID,
    createdAt: Date = Date()
  ) async throws -> DictationPersistedTranscriptRecord {
    try await saveUserTranscriptChange(
      sessionID: sessionID,
      sourceTranscriptID: sourceTranscriptID,
      expectedCurrentTranscriptID: expectedCurrentTranscriptID,
      segmentID: nil,
      replacement: nil,
      createdAt: createdAt
    )
  }

  private func saveUserTranscriptChange(
    sessionID: SessionID,
    sourceTranscriptID: TranscriptRevisionID,
    expectedCurrentTranscriptID: TranscriptRevisionID,
    segmentID: UUID?,
    replacement: String?,
    createdAt: Date
  ) async throws -> DictationPersistedTranscriptRecord {
    let database = try requirePool()
    return try await database.write { db in
      guard
        let latest = try Row.fetchOne(
          db,
          sql: """
            SELECT id, revision,
                   (SELECT MAX(all_revisions.revision)
                    FROM transcript_revisions AS all_revisions
                    WHERE all_revisions.session_id = transcript_revisions.session_id)
                     AS maximum_revision
            FROM transcript_revisions
            WHERE session_id = ?
            ORDER BY CASE
                       WHEN kind IN ('final', 'userEdit') THEN 1
                       ELSE 0
                     END DESC,
                     created_at DESC, revision DESC, id DESC LIMIT 1
            """,
          arguments: [sessionID.rawValue.uuidString]
        )
      else { throw BestASRPersistenceError.missingSession }
      let latestID: String = latest["id"]
      let latestRevision: Int64 = latest["revision"]
      let maximumRevision: Int64 = latest["maximum_revision"]
      guard latestID == expectedCurrentTranscriptID.rawValue.uuidString,
        latestRevision > 0, maximumRevision > 0,
        maximumRevision < Int64.max
      else { throw BestASRPersistenceError.processingCommitConflict }

      guard
        let sourceRow = try Row.fetchOne(
          db,
          sql: """
            SELECT id, session_id, revision, parent_id, kind, content,
                   model_artifact_id, config_hash, created_at,
                   language_hints_json
            FROM transcript_revisions WHERE id = ? AND session_id = ?
            """,
          arguments: [
            sourceTranscriptID.rawValue.uuidString,
            sessionID.rawValue.uuidString,
          ]
        )
      else { throw BestASRPersistenceError.missingSession }
      let segmentRows = try Row.fetchAll(
        db,
        sql: """
          SELECT segment_id, monotonic_start_ns, monotonic_end_ns,
                 text, confidence
          FROM transcript_segments
          WHERE transcript_id = ? ORDER BY ordinal
          """,
        arguments: [sourceTranscriptID.rawValue.uuidString]
      )
      let audioRows = try Row.fetchAll(
        db,
        sql: """
          SELECT source_id, track_id, asset_reference, digest,
                 monotonic_start_ns, monotonic_end_ns,
                 sample_rate_hz, channel_count
          FROM transcript_audio_ranges
          WHERE transcript_id = ? ORDER BY ordinal
          """,
        arguments: [sourceTranscriptID.rawValue.uuidString]
      )
      let source = try Self.persistedTranscriptRecord(
        sourceRow,
        segmentRows: segmentRows,
        audioRows: audioRows
      )
      if let segmentID {
        guard replacement != nil, source.segments.contains(where: { $0.id == segmentID }) else {
          throw BestASRPersistenceError.invalidSnapshot
        }
      }

      let editedSegments = source.segments.map { segment in
        guard segment.id == segmentID, let replacement else { return segment }
        return DictationTranscriptSegment(
          id: segment.id,
          monotonicStartNanoseconds: segment.monotonicStartNanoseconds,
          monotonicEndNanoseconds: segment.monotonicEndNanoseconds,
          text: replacement,
          confidence: segment.confidence
        )
      }
      let content = segmentID == nil ? source.content : Self.joinTranscriptSegments(editedSegments)
      let modelArtifactID = segmentID == nil ? "user-restoration-v1" : "user-inline-edit-v1"
      let revisionID = TranscriptRevisionID()
      let provenance = DictationTranscriptProvenance(
        parentRevisionID: source.id,
        kind: .userEdit,
        languageHints: source.languageHints,
        audioRanges: source.audioRanges,
        segments: editedSegments
      )
      let provenanceData = try JSONEncoder().encode(provenance)
      let digest = SHA256.hash(data: provenanceData).map {
        String(format: "%02x", $0)
      }.joined()
      let configHash = try SHA256Digest(digest)
      let transcript = DictationTranscriptResult(
        revisionID: revisionID,
        segmentIDs: editedSegments.map(\.id),
        text: content,
        modelArtifactID: modelArtifactID,
        provenance: provenance
      )
      let inputRevision = UInt64(maximumRevision + 1)
      try Self.commitTranscriptRevision(
        DictationTranscriptRevisionCommit(
          sessionID: sessionID,
          transcript: transcript,
          inputRevision: inputRevision,
          configHash: configHash,
          createdAt: createdAt
        ),
        expectedInputRevision: maximumRevision + 1,
        in: db
      )
      for table in ["derived_text_revisions", "local_text_documents"] {
        try db.execute(
          sql: "UPDATE \(table) SET state = 'stale' WHERE session_id = ? AND state = 'current'",
          arguments: [sessionID.rawValue.uuidString]
        )
      }
      try db.execute(
        sql: """
          UPDATE event_text_documents SET state = 'stale'
          WHERE state = 'current' AND event_id IN (
            SELECT event_id FROM event_sessions WHERE session_id = ?
          )
          """,
        arguments: [sessionID.rawValue.uuidString]
      )
      try db.execute(
        sql: "UPDATE dictation_snapshots SET updated_at = ? WHERE session_id = ?",
        arguments: [
          createdAt.timeIntervalSince1970,
          sessionID.rawValue.uuidString,
        ]
      )
      return DictationPersistedTranscriptRecord(
        id: revisionID,
        sessionID: sessionID,
        inputRevision: inputRevision,
        parentID: source.id,
        kind: .userEdit,
        content: content,
        modelArtifactID: modelArtifactID,
        configHash: configHash,
        languageHints: source.languageHints,
        audioRanges: source.audioRanges,
        segments: editedSegments,
        createdAt: createdAt
      )
    }
  }

  public func saveRepolishedText(
    sessionID: SessionID,
    sourceTranscriptID: TranscriptRevisionID,
    sourceRevision: UInt64,
    result: DictationPolishResult,
    configHash: SHA256Digest,
    createdAt: Date = Date()
  ) async throws {
    guard sourceRevision > 0,
      result.sourceRevisionID == sourceTranscriptID,
      !result.text.isEmpty
    else { throw BestASRPersistenceError.invalidSnapshot }
    let derivationID = Self.deterministicUUID([
      "user-repolish-v1",
      sessionID.rawValue.uuidString.lowercased(),
      sourceTranscriptID.rawValue.uuidString.lowercased(),
      String(sourceRevision),
      configHash.value,
    ])
    let database = try requirePool()
    try await database.write { db in
      guard
        try Bool.fetchOne(
          db,
          sql:
            "SELECT EXISTS(SELECT 1 FROM transcript_revisions WHERE id = ? AND session_id = ? AND revision = ?)",
          arguments: [
            sourceTranscriptID.rawValue.uuidString,
            sessionID.rawValue.uuidString,
            try Self.sqliteInt(sourceRevision),
          ]
        ) == true
      else { throw BestASRPersistenceError.processingCommitConflict }
      try db.execute(
        sql:
          "UPDATE derived_text_revisions SET state = 'stale' WHERE session_id = ? AND state = 'current'",
        arguments: [sessionID.rawValue.uuidString]
      )
      try db.execute(
        sql: """
          INSERT INTO derived_text_revisions (
            id, session_id, source_transcript_id, source_revision,
            output_text, model_artifact_id, config_hash, state, created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, 'current', ?)
          ON CONFLICT(id) DO UPDATE SET state = 'current'
          """,
        arguments: [
          derivationID.uuidString,
          sessionID.rawValue.uuidString,
          sourceTranscriptID.rawValue.uuidString,
          try Self.sqliteInt(sourceRevision),
          result.text,
          result.modelArtifactID,
          configHash.value,
          createdAt.timeIntervalSince1970,
        ]
      )
      try db.execute(
        sql: "UPDATE dictation_snapshots SET updated_at = ? WHERE session_id = ?",
        arguments: [createdAt.timeIntervalSince1970, sessionID.rawValue.uuidString]
      )
    }
  }

  public func assetReferences(sessionID: SessionID) async throws -> [String] {
    let database = try requirePool()
    return try await database.read { db in
      let tracks = try String.fetchAll(
        db,
        sql: "SELECT asset_reference FROM tracks WHERE session_id = ?",
        arguments: [sessionID.rawValue.uuidString]
      )
      let chunks = try String.fetchAll(
        db,
        sql: "SELECT asset_reference FROM audio_chunks WHERE session_id = ?",
        arguments: [sessionID.rawValue.uuidString]
      )
      return (tracks + chunks).sorted()
    }
  }

  public func jobCount(sessionID: SessionID) async throws -> Int {
    let database = try requirePool()
    return try await database.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM dictation_job_sessions WHERE session_id = ?",
        arguments: [sessionID.rawValue.uuidString]
      ) ?? 0
    }
  }

  @discardableResult
  public func scheduleSingleSpeakerWork(
    sessionID: SessionID,
    audio: [AudioRangeInput],
    inputRevision: UInt64
  ) async throws -> DictationSpeakerWorkRecord {
    guard inputRevision > 0,
      !audio.isEmpty,
      audio.count <= 4_096
    else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    var previousEnd: UInt64?
    var trackFormats: [UUID: (sampleRate: UInt32, channels: UInt16)] = [:]
    for range in audio {
      guard range.sourceID == sessionID.rawValue,
        range.monotonicStartNanoseconds < range.monotonicEndNanoseconds,
        range.sampleRateHertz > 0,
        range.channelCount > 0,
        Self.safeAssetReference(range.assetReference),
        range.contentDigest.range(
          of: "^[0-9a-f]{64}$",
          options: .regularExpression
        ) != nil,
        previousEnd.map({ range.monotonicStartNanoseconds >= $0 }) ?? true
      else {
        throw BestASRPersistenceError.invalidSnapshot
      }
      if let existing = trackFormats[range.trackID] {
        guard existing.sampleRate == range.sampleRateHertz,
          existing.channels == range.channelCount
        else {
          throw BestASRPersistenceError.invalidSnapshot
        }
      } else {
        trackFormats[range.trackID] = (
          range.sampleRateHertz,
          range.channelCount
        )
      }
      previousEnd = range.monotonicEndNanoseconds
    }

    let revision = try Revision(inputRevision)
    let speakerID = SessionSpeakerID(
      Self.deterministicUUID([
        "dictation-single-speaker-v1",
        sessionID.rawValue.uuidString.lowercased(),
      ])
    )
    let sessionSpeaker = SessionSpeaker(
      id: speakerID,
      sessionID: sessionID,
      revision: revision,
      stableOrdinal: 1
    )
    let association = try PersonAssociation(
      status: .unknown,
      personID: nil,
      confidence: nil,
      evidenceRevision: revision
    )
    let occurrences = audio.map { range in
      SpeakerOccurrence(
        id: SpeakerOccurrenceID(
          Self.deterministicUUID([
            "dictation-speaker-occurrence-v1",
            sessionID.rawValue.uuidString.lowercased(),
            range.trackID.uuidString.lowercased(),
            String(range.monotonicStartNanoseconds),
            String(range.monotonicEndNanoseconds),
            range.contentDigest,
          ])
        ),
        sessionID: sessionID,
        sessionSpeakerID: speakerID,
        revision: revision,
        trackIDs: [TrackID(range.trackID)],
        monotonicStartNanoseconds: range.monotonicStartNanoseconds,
        monotonicEndNanoseconds: range.monotonicEndNanoseconds,
        overlapsAnotherSpeaker: false,
        association: association
      )
    }
    let configHash = try SHA256Digest(
      Self.sha256("dictation-single-speaker-alpha-v1")
    )
    let job = DurableJob(
      id: DurableJobID(
        Self.deterministicUUID([
          "dictation-speaker-final-job-v1",
          sessionID.rawValue.uuidString.lowercased(),
          String(inputRevision),
          configHash.value,
        ])
      ),
      revision: try Revision(1),
      kind: .speakerFinal,
      state: .queued,
      inputRevision: revision,
      modelArtifactID: nil,
      configHash: configHash,
      retryCount: 0,
      errorCategory: .none,
      leaseOwner: nil,
      leaseExpiresAt: nil
    )
    let immutableTrackFormats = trackFormats
    let database = try requirePool()
    try await database.write { db in
      guard
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?)",
          arguments: [sessionID.rawValue.uuidString]
        ) == true
      else {
        throw BestASRPersistenceError.missingSession
      }
      let trackReference =
        "sessions/\(sessionID.rawValue.uuidString.lowercased())/journal/manifest.json"
      for (trackUUID, format) in immutableTrackFormats {
        try db.execute(
          sql: """
            INSERT INTO tracks (
              id, session_id, revision, role, asset_reference,
              sample_rate_hz, channel_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
          arguments: [
            trackUUID.uuidString,
            sessionID.rawValue.uuidString,
            try Self.sqliteInt(inputRevision),
            SourceTrackRole.microphoneLocal.rawValue,
            trackReference,
            Int64(format.sampleRate),
            Int64(format.channels),
          ]
        )
        guard
          let row = try Row.fetchOne(
            db,
            sql: """
              SELECT session_id, role, asset_reference, sample_rate_hz,
                     channel_count
              FROM tracks WHERE id = ?
              """,
            arguments: [trackUUID.uuidString]
          )
        else {
          throw BestASRPersistenceError.processingCommitConflict
        }
        let storedSessionID: String = row["session_id"]
        let storedRole: String = row["role"]
        let storedReference: String = row["asset_reference"]
        let storedRate: Int64 = row["sample_rate_hz"]
        let storedChannels: Int64 = row["channel_count"]
        guard storedSessionID == sessionID.rawValue.uuidString,
          storedRole == SourceTrackRole.microphoneLocal.rawValue,
          storedReference == trackReference,
          storedRate == Int64(format.sampleRate),
          storedChannels == Int64(format.channels)
        else {
          throw BestASRPersistenceError.processingCommitConflict
        }
      }
      try db.execute(
        sql: """
          INSERT INTO session_speakers (
            id, session_id, revision, stable_ordinal
          ) VALUES (?, ?, ?, ?)
          ON CONFLICT(id) DO NOTHING
          """,
        arguments: [
          speakerID.rawValue.uuidString,
          sessionID.rawValue.uuidString,
          try Self.sqliteInt(revision.value),
          Int64(sessionSpeaker.stableOrdinal),
        ]
      )
      for occurrence in occurrences {
        try db.execute(
          sql: """
            INSERT INTO speaker_occurrences (
              id, session_id, session_speaker_id, revision,
              monotonic_start_ns, monotonic_end_ns,
              overlaps_another_speaker, association_status, person_id,
              confidence, evidence_revision
            ) VALUES (?, ?, ?, ?, ?, ?, 0, ?, NULL, NULL, ?)
            ON CONFLICT(id) DO NOTHING
            """,
          arguments: [
            occurrence.id.rawValue.uuidString,
            sessionID.rawValue.uuidString,
            speakerID.rawValue.uuidString,
            try Self.sqliteInt(occurrence.revision.value),
            try Self.sqliteInt(occurrence.monotonicStartNanoseconds),
            try Self.sqliteInt(occurrence.monotonicEndNanoseconds),
            PersonAssociationStatus.unknown.rawValue,
            try Self.sqliteInt(occurrence.association.evidenceRevision.value),
          ]
        )
        try db.execute(
          sql: """
            INSERT INTO speaker_occurrence_tracks (occurrence_id, track_id)
            VALUES (?, ?)
            ON CONFLICT(occurrence_id, track_id) DO NOTHING
            """,
          arguments: [
            occurrence.id.rawValue.uuidString,
            occurrence.trackIDs[0].rawValue.uuidString,
          ]
        )
      }
      try Self.insert(job: job, sessionID: sessionID, in: db)
    }
    guard let stored = try await loadSingleSpeakerWork(sessionID: sessionID),
      stored
        == DictationSpeakerWorkRecord(
          sessionSpeaker: sessionSpeaker,
          occurrences: occurrences,
          job: job
        )
    else {
      throw BestASRPersistenceError.processingCommitConflict
    }
    return stored
  }

  public func loadSingleSpeakerWork(
    sessionID: SessionID
  ) async throws -> DictationSpeakerWorkRecord? {
    let database = try requirePool()
    return try await database.read { db in
      guard
        let speakerRow = try Row.fetchOne(
          db,
          sql: """
            SELECT id, revision, stable_ordinal FROM session_speakers
            WHERE session_id = ? ORDER BY stable_ordinal LIMIT 1
            """,
          arguments: [sessionID.rawValue.uuidString]
        ),
        let jobRow = try Row.fetchOne(
          db,
          sql: """
            SELECT j.* FROM durable_jobs j
            JOIN dictation_job_sessions d ON d.job_id = j.id
            WHERE d.session_id = ? AND j.kind = ?
            ORDER BY j.input_revision DESC, j.id LIMIT 1
            """,
          arguments: [
            sessionID.rawValue.uuidString,
            DurableJobKind.speakerFinal.rawValue,
          ]
        )
      else { return nil }
      let speakerIDString: String = speakerRow["id"]
      guard let speakerUUID = UUID(uuidString: speakerIDString) else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      let speaker = SessionSpeaker(
        id: SessionSpeakerID(speakerUUID),
        sessionID: sessionID,
        revision: try Revision(UInt64(speakerRow["revision"] as Int64)),
        stableOrdinal: UInt32(speakerRow["stable_ordinal"] as Int64)
      )
      let occurrenceRows = try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM speaker_occurrences
          WHERE session_id = ? ORDER BY monotonic_start_ns, id
          """,
        arguments: [sessionID.rawValue.uuidString]
      )
      let occurrences = try occurrenceRows.map { row -> SpeakerOccurrence in
        let occurrenceIDString: String = row["id"]
        let rowSpeakerID: String = row["session_speaker_id"]
        guard let occurrenceUUID = UUID(uuidString: occurrenceIDString),
          rowSpeakerID == speakerIDString
        else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        let trackStrings = try String.fetchAll(
          db,
          sql: """
            SELECT track_id FROM speaker_occurrence_tracks
            WHERE occurrence_id = ? ORDER BY track_id
            """,
          arguments: [occurrenceIDString]
        )
        let trackIDs = try trackStrings.map { value -> TrackID in
          guard let uuid = UUID(uuidString: value) else {
            throw BestASRPersistenceError.storedDataCorrupt
          }
          return TrackID(uuid)
        }
        guard !trackIDs.isEmpty else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        let statusString: String = row["association_status"]
        guard let status = PersonAssociationStatus(rawValue: statusString) else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        let personString: String? = row["person_id"]
        let personID = try personString.map { value -> PersonID in
          guard let uuid = UUID(uuidString: value) else {
            throw BestASRPersistenceError.storedDataCorrupt
          }
          return PersonID(uuid)
        }
        let confidenceValue: Double? = row["confidence"]
        let confidence = try confidenceValue.map(Confidence.init)
        let association = try PersonAssociation(
          status: status,
          personID: personID,
          confidence: confidence,
          evidenceRevision: try Revision(
            UInt64(row["evidence_revision"] as Int64)
          )
        )
        return SpeakerOccurrence(
          id: SpeakerOccurrenceID(occurrenceUUID),
          sessionID: sessionID,
          sessionSpeakerID: speaker.id,
          revision: try Revision(UInt64(row["revision"] as Int64)),
          trackIDs: trackIDs,
          monotonicStartNanoseconds: UInt64(
            row["monotonic_start_ns"] as Int64
          ),
          monotonicEndNanoseconds: UInt64(
            row["monotonic_end_ns"] as Int64
          ),
          overlapsAnotherSpeaker: row["overlaps_another_speaker"] as Bool,
          association: association
        )
      }
      return DictationSpeakerWorkRecord(
        sessionSpeaker: speaker,
        occurrences: occurrences,
        job: try Self.durableJob(jobRow)
      )
    }
  }

  /// Commits the conservative "insufficient identity evidence" result. This
  /// intentionally touches only speaker/job history; the dictation snapshot,
  /// insertion reservation, and inserted label-free text remain immutable.
  @discardableResult
  public func completeSingleSpeakerWorkUnknown(
    sessionID: SessionID
  ) async throws -> DictationSpeakerWorkRecord {
    let database = try requirePool()
    try await database.write { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT j.id, j.revision, j.state FROM durable_jobs j
            JOIN dictation_job_sessions d ON d.job_id = j.id
            WHERE d.session_id = ? AND j.kind = ?
            ORDER BY j.input_revision DESC, j.id LIMIT 1
            """,
          arguments: [
            sessionID.rawValue.uuidString,
            DurableJobKind.speakerFinal.rawValue,
          ]
        )
      else {
        throw BestASRPersistenceError.missingSession
      }
      let stateValue: String = row["state"]
      if stateValue == DurableJobState.succeeded.rawValue { return }
      let revision: Int64 = row["revision"]
      guard revision > 0, revision < Int64.max else {
        throw BestASRPersistenceError.numericOverflow
      }
      let jobID: String = row["id"]
      try db.execute(
        sql: """
          UPDATE durable_jobs
          SET revision = ?, state = ?, error_category = ?,
              lease_owner = NULL, lease_expires_at = NULL
          WHERE id = ? AND revision = ?
          """,
        arguments: [
          revision + 1,
          DurableJobState.succeeded.rawValue,
          DurableJobErrorCategory.none.rawValue,
          jobID,
          revision,
        ]
      )
      guard db.changesCount == 1 else {
        throw BestASRPersistenceError.processingCommitConflict
      }
    }
    guard let result = try await loadSingleSpeakerWork(sessionID: sessionID),
      result.job.state == .succeeded,
      result.occurrences.allSatisfy({ $0.association.status == .unknown })
    else {
      throw BestASRPersistenceError.processingCommitConflict
    }
    return result
  }

  public func createDictionaryEntry(
    canonicalForm: String,
    spokenForms: [String]
  ) async throws -> DictionaryEntry {
    let now = Self.databaseDate(clock.wallTime())
    let entry = try DictionaryEntry(
      revision: Revision(1),
      canonicalForm: canonicalForm,
      spokenForms: spokenForms,
      enabled: true,
      createdAt: now,
      updatedAt: now
    )
    let spokenJSON = try dictionaryJSON(spokenForms)
    let database = try requirePool()
    return try await database.write { db in
      guard
        try !Self.hasLiveDictionaryCanonicalForm(
          canonicalForm,
          excluding: nil,
          in: db
        )
      else {
        throw BestASRPersistenceError.duplicateDictionaryEntry
      }
      try db.execute(
        sql: """
          INSERT INTO dictionary_entries (
            id, revision, canonical_form, spoken_forms_json, enabled,
            created_at, updated_at, tombstoned_at
          ) VALUES (?, ?, ?, ?, 1, ?, ?, NULL)
          """,
        arguments: [
          entry.id.rawValue.uuidString,
          1,
          entry.canonicalForm,
          spokenJSON,
          now.timeIntervalSince1970,
          now.timeIntervalSince1970,
        ]
      )
      try Self.invalidateCurrentDerivations(in: db)
      return entry
    }
  }

  public func allDictionaryEntries() async throws -> [DictionaryEntry] {
    let database = try requirePool()
    return try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM dictionary_entries
          WHERE tombstoned_at IS NULL
          ORDER BY canonical_form COLLATE NOCASE, id
          """
      ).map(Self.dictionaryEntry)
    }
  }

  /// Atomically merges an explicit local transfer by normalized canonical
  /// form. A malformed row or database conflict rolls back the whole import.
  public func importDictionaryEntries(
    _ imported: [DictionaryTransferEntry]
  ) async throws -> [DictionaryEntry] {
    guard imported.count <= 100_000 else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    var deduplicated: [String: DictionaryTransferEntry] = [:]
    for entry in imported {
      let key = entry.canonicalForm.precomposedStringWithCompatibilityMapping
        .lowercased()
      guard deduplicated[key] == nil else {
        throw BestASRPersistenceError.duplicateDictionaryEntry
      }
      deduplicated[key] = entry
    }
    let ordered = deduplicated.values.sorted {
      $0.canonicalForm.localizedCaseInsensitiveCompare($1.canonicalForm)
        == .orderedAscending
    }
    let now = Self.databaseDate(clock.wallTime())
    let database = try requirePool()
    return try await database.write { db in
      let current = try Row.fetchAll(
        db,
        sql: "SELECT * FROM dictionary_entries WHERE tombstoned_at IS NULL"
      ).map(Self.dictionaryEntry)
      var byKey = Dictionary(
        uniqueKeysWithValues: current.map {
          (
            $0.canonicalForm.precomposedStringWithCompatibilityMapping
              .lowercased(),
            $0
          )
        }
      )
      var results: [DictionaryEntry] = []
      results.reserveCapacity(ordered.count)
      for candidate in ordered {
        let key = candidate.canonicalForm
          .precomposedStringWithCompatibilityMapping.lowercased()
        if let existing = byKey[key] {
          let nextRevision = try Revision(existing.revision.value + 1)
          try db.execute(
            sql: """
              UPDATE dictionary_entries
              SET revision = ?, canonical_form = ?, spoken_forms_json = ?,
                  enabled = ?, updated_at = ?
              WHERE id = ? AND revision = ? AND tombstoned_at IS NULL
              """,
            arguments: [
              try Self.sqliteInt(nextRevision.value),
              candidate.canonicalForm,
              try Self.dictionaryJSONValue(candidate.spokenForms),
              candidate.enabled ? 1 : 0,
              now.timeIntervalSince1970,
              existing.id.rawValue.uuidString,
              try Self.sqliteInt(existing.revision.value),
            ]
          )
          guard db.changesCount == 1 else {
            throw BestASRPersistenceError.dictionaryRevisionConflict(
              current: existing.revision.value,
              expected: existing.revision.value
            )
          }
          let updated = try DictionaryEntry(
            id: existing.id,
            revision: nextRevision,
            canonicalForm: candidate.canonicalForm,
            spokenForms: candidate.spokenForms,
            enabled: candidate.enabled,
            createdAt: existing.createdAt,
            updatedAt: now
          )
          byKey[key] = updated
          results.append(updated)
        } else {
          let entry = try DictionaryEntry(
            revision: Revision(1),
            canonicalForm: candidate.canonicalForm,
            spokenForms: candidate.spokenForms,
            enabled: candidate.enabled,
            createdAt: now,
            updatedAt: now
          )
          try db.execute(
            sql: """
              INSERT INTO dictionary_entries (
                id, revision, canonical_form, spoken_forms_json, enabled,
                created_at, updated_at, tombstoned_at
              ) VALUES (?, 1, ?, ?, ?, ?, ?, NULL)
              """,
            arguments: [
              entry.id.rawValue.uuidString,
              entry.canonicalForm,
              try Self.dictionaryJSONValue(entry.spokenForms),
              entry.enabled ? 1 : 0,
              now.timeIntervalSince1970,
              now.timeIntervalSince1970,
            ]
          )
          byKey[key] = entry
          results.append(entry)
        }
      }
      if !results.isEmpty { try Self.invalidateCurrentDerivations(in: db) }
      return results
    }
  }

  public func dictionaryEntry(
    id: DictionaryEntryID
  ) async throws -> DictionaryEntry? {
    let database = try requirePool()
    return try await database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT * FROM dictionary_entries
            WHERE id = ? AND tombstoned_at IS NULL
            """,
          arguments: [id.rawValue.uuidString]
        )
      else { return nil }
      return try Self.dictionaryEntry(row)
    }
  }

  public func searchDictionaryEntries(
    query: String,
    includeDisabled: Bool,
    limit: Int
  ) async throws -> [DictionaryEntry] {
    try await searchDictionaryEntries(
      query: query, includeDisabled: includeDisabled, limit: limit, offset: 0
    )
  }

  public func searchDictionaryEntries(
    query: String,
    includeDisabled: Bool,
    limit: Int,
    offset: Int
  ) async throws -> [DictionaryEntry] {
    let boundedLimit = max(0, min(limit, 200))
    guard boundedLimit > 0 else { return [] }
    let boundedQuery = String(
      query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256)
    )
    let database = try requirePool()
    return try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM dictionary_entries
          WHERE tombstoned_at IS NULL
            AND (? = 1 OR enabled = 1)
            AND (
              ? = '' OR
              instr(lower(canonical_form), lower(?)) > 0 OR
              instr(lower(spoken_forms_json), lower(?)) > 0
            )
          ORDER BY canonical_form COLLATE NOCASE, id
          LIMIT ? OFFSET ?
          """,
        arguments: [
          includeDisabled ? 1 : 0,
          boundedQuery,
          boundedQuery,
          boundedQuery,
          boundedLimit,
          max(0, offset),
        ]
      )
      return try rows.map(Self.dictionaryEntry)
    }
  }

  public func updateDictionaryEntry(
    id: DictionaryEntryID,
    expectedRevision: Revision,
    canonicalForm: String,
    spokenForms: [String]
  ) async throws -> DictionaryEntry {
    try await mutateDictionaryEntry(
      id: id,
      expectedRevision: expectedRevision,
      mutation: .edit(
        canonicalForm: canonicalForm,
        spokenForms: spokenForms
      )
    )
  }

  public func setDictionaryEntryEnabled(
    id: DictionaryEntryID,
    expectedRevision: Revision,
    enabled: Bool
  ) async throws -> DictionaryEntry {
    try await mutateDictionaryEntry(
      id: id,
      expectedRevision: expectedRevision,
      mutation: .setEnabled(enabled)
    )
  }

  public func deleteDictionaryEntry(
    id: DictionaryEntryID,
    expectedRevision: Revision
  ) async throws -> DictionaryEntry {
    try await mutateDictionaryEntry(
      id: id,
      expectedRevision: expectedRevision,
      mutation: .delete
    )
  }

  public func dictionaryContext(
    maximumEntries: Int = 64,
    maximumUTF8Bytes: Int = 16_384
  ) async throws -> DictionaryContextProjection {
    let entryLimit = max(0, min(maximumEntries, 64))
    let byteLimit = max(0, min(maximumUTF8Bytes, 16_384))
    guard entryLimit > 0, byteLimit > 0 else {
      return try DictionaryContextProjection(entries: [])
    }
    let database = try requirePool()
    return try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM dictionary_entries
          WHERE enabled = 1 AND tombstoned_at IS NULL
          ORDER BY canonical_form COLLATE NOCASE, id
          LIMIT 256
          """
      )
      var selected: [DictionaryEntry] = []
      var usedBytes = 0
      for entry in try rows.map(Self.dictionaryEntry) {
        let entryBytes =
          entry.canonicalForm.utf8.count
          + entry.spokenForms.reduce(0) { $0 + $1.utf8.count }
        guard usedBytes + entryBytes <= byteLimit else { continue }
        selected.append(entry)
        usedBytes += entryBytes
        if selected.count == entryLimit { break }
      }
      return try DictionaryContextProjection(entries: selected)
    }
  }

  private func mutateDictionaryEntry(
    id: DictionaryEntryID,
    expectedRevision: Revision,
    mutation: DictionaryMutation
  ) async throws -> DictionaryEntry {
    let now = Self.databaseDate(clock.wallTime())
    let database = try requirePool()
    return try await database.write { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM dictionary_entries WHERE id = ?",
          arguments: [id.rawValue.uuidString]
        )
      else {
        throw BestASRPersistenceError.dictionaryEntryMissing
      }
      let current = try Self.dictionaryEntry(row)
      guard current.revision == expectedRevision else {
        throw BestASRPersistenceError.dictionaryRevisionConflict(
          current: current.revision.value,
          expected: expectedRevision.value
        )
      }
      if current.tombstonedAt != nil {
        if case .delete = mutation { return current }
        throw BestASRPersistenceError.dictionaryEntryMissing
      }
      guard current.revision.value < UInt64.max else {
        throw BestASRPersistenceError.numericOverflow
      }
      let revision = try Revision(current.revision.value + 1)
      let updated: DictionaryEntry
      switch mutation {
      case .delete:
        updated = try DictionaryEntry(
          id: current.id,
          revision: revision,
          canonicalForm: current.canonicalForm,
          spokenForms: current.spokenForms,
          enabled: false,
          createdAt: current.createdAt,
          updatedAt: now,
          tombstonedAt: now
        )
      case .edit(let canonicalForm, let spokenForms):
        guard
          try !Self.hasLiveDictionaryCanonicalForm(
            canonicalForm,
            excluding: current.id,
            in: db
          )
        else {
          throw BestASRPersistenceError.duplicateDictionaryEntry
        }
        updated = try DictionaryEntry(
          id: current.id,
          revision: revision,
          canonicalForm: canonicalForm,
          spokenForms: spokenForms,
          enabled: current.enabled,
          createdAt: current.createdAt,
          updatedAt: now
        )
      case .setEnabled(let enabled):
        updated = try DictionaryEntry(
          id: current.id,
          revision: revision,
          canonicalForm: current.canonicalForm,
          spokenForms: current.spokenForms,
          enabled: enabled,
          createdAt: current.createdAt,
          updatedAt: now
        )
      }
      try db.execute(
        sql: """
          UPDATE dictionary_entries
          SET revision = ?, canonical_form = ?, spoken_forms_json = ?,
              enabled = ?, updated_at = ?, tombstoned_at = ?
          WHERE id = ? AND revision = ?
          """,
        arguments: [
          try Self.sqliteInt(updated.revision.value),
          updated.canonicalForm,
          try Self.dictionaryJSONValue(updated.spokenForms),
          updated.enabled ? 1 : 0,
          updated.updatedAt.timeIntervalSince1970,
          updated.tombstonedAt?.timeIntervalSince1970,
          updated.id.rawValue.uuidString,
          try Self.sqliteInt(expectedRevision.value),
        ]
      )
      guard db.changesCount == 1 else {
        throw BestASRPersistenceError.dictionaryRevisionConflict(
          current: current.revision.value,
          expected: expectedRevision.value
        )
      }
      try Self.invalidateCurrentDerivations(in: db)
      return updated
    }
  }

  public func inspection() async throws -> BestASRPersistenceInspection {
    let database = try requirePool()
    let migrator = BestASRPersistenceSchema.migrator()
    return try await database.read { db in
      BestASRPersistenceInspection(
        userVersion: try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0,
        appliedMigrations: try migrator.appliedMigrations(db),
        tableNames: try String.fetchAll(
          db,
          sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        ),
        journalMode: (try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown")
          .lowercased(),
        foreignKeysEnabled: (try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0) == 1
      )
    }
  }

  /// Captures only portable user-domain rows. Model registry state, caches,
  /// indexes, migration bookkeeping, and logs are deliberately excluded.
  public func exportPortablePersistenceState() async throws
    -> PortablePersistenceState
  {
    let database = try requirePool()
    return try await database.read { db in
      let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
      guard version == BestASRPersistenceSchema.currentUserVersion else {
        throw BestASRPersistenceError.portableArchiveInvalidSchema
      }
      var tables: [PortableDatabaseTable] = []
      for tableName in Self.portableTableOrder {
        let columns = try db.columns(in: tableName).map(\.name)
        guard !columns.isEmpty else {
          throw BestASRPersistenceError.portableArchiveInvalidSchema
        }
        let rows = try Row.fetchAll(
          db,
          sql: "SELECT * FROM \(tableName.quotedDatabaseIdentifier) ORDER BY rowid"
        )
        tables.append(
          PortableDatabaseTable(
            name: tableName,
            columns: columns,
            rows: rows.map { row in
              row.databaseValues.map(PortableSQLiteValue.init)
            }
          )
        )
      }
      return PortablePersistenceState(schemaVersion: version, tables: tables)
    }
  }

  /// Merges a fully authenticated portable snapshot in one SQLite
  /// transaction. Stable-ID duplicates are accepted only when every stored
  /// value is identical; any divergent identity or unique-key collision rolls
  /// the entire import back.
  public func importPortablePersistenceState(
    _ inputState: PortablePersistenceState
  ) async throws {
    let state = try Self.upgradePortablePersistenceState(inputState)
    guard state.schemaVersion == BestASRPersistenceSchema.currentUserVersion,
      state.tables.map(\.name) == Self.portableTableOrder
    else { throw BestASRPersistenceError.portableArchiveInvalidSchema }
    let database = try requirePool()
    try await database.write { db in
      try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
      // Imported rows have unknown provenance (an archive may come from the
      // owner's real library), so an import turns the own-device organizer
      // link off first: nothing pending is sent, no imported session is ever
      // eligible, and restored decisions are only listed as not sent.
      try Self.revokeRemoteLinkRows(db)
      for table in state.tables {
        let liveColumns = try db.columns(in: table.name).map(\.name)
        guard table.columns == liveColumns,
          table.rows.allSatisfy({ $0.count == liveColumns.count })
        else { throw BestASRPersistenceError.portableArchiveInvalidSchema }
        let primaryKey = try db.primaryKey(table.name).columns
        let primaryIndexes = try primaryKey.map { column -> Int in
          guard let index = liveColumns.firstIndex(of: column) else {
            throw BestASRPersistenceError.portableArchiveInvalidSchema
          }
          return index
        }
        let whereSQL = primaryKey.map {
          "\($0.quotedDatabaseIdentifier) IS ?"
        }.joined(separator: " AND ")
        let insertSQL = """
          INSERT INTO \(table.name.quotedDatabaseIdentifier)
          (\(liveColumns.map(\.quotedDatabaseIdentifier).joined(separator: ", ")))
          VALUES (\(Array(repeating: "?", count: liveColumns.count).joined(separator: ", ")))
          """
        for portableRow in table.rows {
          let values = portableRow.map(\.databaseValue)
          let keyValues = primaryIndexes.map { values[$0] }
          if let existing = try Row.fetchOne(
            db,
            sql: "SELECT * FROM \(table.name.quotedDatabaseIdentifier) WHERE \(whereSQL)",
            arguments: StatementArguments(keyValues)
          ) {
            let existingValues = Array(
              existing.databaseValues.map(PortableSQLiteValue.init)
            )
            guard existingValues == portableRow else {
              throw BestASRPersistenceError.portableArchiveConflict
            }
            continue
          }
          do {
            try db.execute(
              sql: insertSQL,
              arguments: StatementArguments(values)
            )
          } catch {
            throw BestASRPersistenceError.portableArchiveConflict
          }
        }
      }
      let foreignKeyFailures = try Row.fetchAll(
        db,
        sql: "PRAGMA foreign_key_check"
      )
      guard foreignKeyFailures.isEmpty else {
        throw BestASRPersistenceError.portableArchiveInvalidSchema
      }
      try Self.markImportedRemoteDecisions(db)
    }
  }

  private nonisolated static func upgradePortablePersistenceState(
    _ state: PortablePersistenceState
  ) throws -> PortablePersistenceState {
    guard
      BestASRPersistenceSchema.supportsPortableImport(
        userVersion: state.schemaVersion
      )
    else { throw BestASRPersistenceError.portableArchiveInvalidSchema }
    if state.schemaVersion == BestASRPersistenceSchema.currentUserVersion {
      return state
    }
    let currentOrder = portableTableOrder
    let version = state.schemaVersion
    var tables = state.tables
    let names = tables.map(\.name)
    // Table set: v12 lacks source context and later tables, v13 lacks speaker
    // name evidence and later, v14/v15 lack event memory, v16-v18 lack the
    // remote-organizer decisions, and v19-v21 lack only the user-item details
    // (v20 and v21 changed only local, non-portable tables).
    switch version {
    case 12:
      guard names == Array(currentOrder.dropLast(11)) else {
        throw BestASRPersistenceError.portableArchiveInvalidSchema
      }
      tables.append(sourceContextPortableEmptyTable)
      tables.append(speakerNameEvidencePortableEmptyTable)
      tables.append(contentsOf: eventPortableEmptyTables)
    case 13:
      guard names == Array(currentOrder.dropLast(10)) else {
        throw BestASRPersistenceError.portableArchiveInvalidSchema
      }
      tables.append(speakerNameEvidencePortableEmptyTable)
      tables.append(contentsOf: eventPortableEmptyTables)
    case 14, 15:
      guard names == Array(currentOrder.dropLast(9)) else {
        throw BestASRPersistenceError.portableArchiveInvalidSchema
      }
      tables.append(contentsOf: eventPortableEmptyTables)
    case 16, 17, 18:
      guard names == Array(currentOrder.dropLast(2)) else {
        throw BestASRPersistenceError.portableArchiveInvalidSchema
      }
    case 19, 20, 21:
      guard names == Array(currentOrder.dropLast(1)) else {
        throw BestASRPersistenceError.portableArchiveInvalidSchema
      }
    case 22, 23:
      // v23 widened a portable table in place; v24 added only local tables.
      guard names == currentOrder else {
        throw BestASRPersistenceError.portableArchiveInvalidSchema
      }
    default:
      throw BestASRPersistenceError.portableArchiveInvalidSchema
    }
    if version <= 18 { tables.append(remoteOrganizerPortableEmptyTable) }
    if version <= 21 { tables.append(userItemDetailsPortableEmptyTable) }
    // Columns added by later migrations are appended at the end of the live
    // table, so older rows gain a trailing NULL in the same position.
    if version < 17 {
      tables = try appendingNullPortableColumn(
        "duration_ns", to: "session_source_assets", in: tables
      )
    }
    if version < 18 {
      tables = try appendingNullPortableColumn("spoken_mode", to: "sessions", in: tables)
    }
    if version < 23 {
      for column in ["uniform_type", "parent_session_id", "frame_ms"] {
        tables = try appendingNullPortableColumn(column, to: "user_item_details", in: tables)
      }
    }
    return PortablePersistenceState(
      schemaVersion: BestASRPersistenceSchema.currentUserVersion,
      tables: tables
    )
  }

  private nonisolated static func appendingNullPortableColumn(
    _ column: String, to tableName: String, in tables: [PortableDatabaseTable]
  ) throws -> [PortableDatabaseTable] {
    guard let index = tables.firstIndex(where: { $0.name == tableName }),
      !tables[index].columns.contains(column)
    else { throw BestASRPersistenceError.portableArchiveInvalidSchema }
    var result = tables
    let table = tables[index]
    result[index] = PortableDatabaseTable(
      name: table.name,
      columns: table.columns + [column],
      rows: table.rows.map { $0 + [.null] }
    )
    return result
  }

  private nonisolated static let sourceContextPortableEmptyTable = PortableDatabaseTable(
    name: "source_context_events",
    columns: [
      "id", "session_id", "revision", "adapter_id", "source_bundle_id",
      "meeting_title", "window_title", "participant_names_json",
      "active_speaker_name", "monotonic_ns", "reliability",
    ],
    rows: []
  )

  private nonisolated static let speakerNameEvidencePortableEmptyTable =
    PortableDatabaseTable(
      name: "speaker_name_evidence",
      columns: [
        "id", "session_id", "session_speaker_id", "person_id", "revision",
        "display_name", "source_kind", "source_context_ids_json",
        "occurrence_ids_json", "aligned_speech_ns", "reliability",
        "created_at",
      ],
      rows: []
    )

  public func checkpointAndClose() async throws {
    guard let database = pool else { return }
    _ = try await database.writeWithoutTransaction { db in
      try db.checkpoint(.truncate)
    }
    try database.close()
    pool = nil
  }

  func requirePool() throws -> DatabasePool {
    guard let pool else { throw BestASRPersistenceError.databaseAlreadyClosed }
    return pool
  }

  private nonisolated static let portableTableOrder = [
    "sessions",
    "session_metadata",
    "tracks",
    "audio_chunks",
    "timeline_events",
    "transcript_revisions",
    "durable_jobs",
    "session_speakers",
    "persons",
    "speaker_occurrences",
    "speaker_occurrence_tracks",
    "person_corrections",
    "change_log",
    "tombstones",
    "dictation_snapshots",
    "insertion_outcomes",
    "derived_text_revisions",
    "dictionary_entries",
    "dictation_job_sessions",
    "transcript_segments",
    "transcript_audio_ranges",
    "speaker_job_inputs",
    "session_speaker_embeddings",
    "person_embeddings",
    "rejected_person_matches",
    "session_source_assets",
    "local_text_documents",
    "person_edit_operations",
    "source_context_events",
    "speaker_name_evidence",
    "events",
    "event_sessions",
    "event_link_rejections",
    "event_people",
    "event_candidates",
    "event_text_documents",
    "event_edit_operations",
    "remote_organizer_decisions",
    "user_item_details",
  ]

  private nonisolated static let userItemDetailsPortableEmptyTable =
    PortableDatabaseTable(
      name: "user_item_details",
      columns: [
        "session_id", "revision", "item_kind", "captured_at", "source_origin",
        "extractor", "page_count", "pixel_width", "pixel_height",
        "original_asset_id", "normalized_asset_id", "created_at", "updated_at",
      ],
      rows: []
    )

  private nonisolated static let remoteOrganizerPortableEmptyTable =
    PortableDatabaseTable(
      name: "remote_organizer_decisions",
      columns: ["id", "payload_json", "created_at"],
      rows: []
    )

  private nonisolated static let eventPortableEmptyTables = [
    PortableDatabaseTable(
      name: "events",
      columns: [
        "id", "revision", "title", "notes", "start_at", "end_at",
        "title_is_user_edited", "confirmation_state", "created_at",
        "updated_at", "retired_at", "merged_into_event_id",
      ],
      rows: []
    ),
    PortableDatabaseTable(
      name: "event_sessions",
      columns: [
        "event_id", "session_id", "source", "confidence", "evidence_json",
        "created_at", "updated_at",
      ],
      rows: []
    ),
    PortableDatabaseTable(
      name: "event_link_rejections",
      columns: ["event_id", "session_id", "reason", "created_at"],
      rows: []
    ),
    PortableDatabaseTable(
      name: "event_people",
      columns: [
        "event_id", "person_id", "occurrence_count", "speech_duration_ns",
      ],
      rows: []
    ),
    PortableDatabaseTable(
      name: "event_candidates",
      columns: [
        "id", "session_id", "candidate_event_id", "proposed_title",
        "evidence_json", "state", "created_at", "updated_at",
      ],
      rows: []
    ),
    PortableDatabaseTable(
      name: "event_text_documents",
      columns: [
        "id", "event_id", "event_revision", "task_id",
        "model_artifact_id", "config_hash", "source_references_json",
        "result_json", "state", "created_at",
      ],
      rows: []
    ),
    PortableDatabaseTable(
      name: "event_edit_operations",
      columns: [
        "id", "kind", "inverse_json", "occurred_at", "reversed_at",
      ],
      rows: []
    ),
  ]

  private nonisolated func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return try encoder.encode(value)
  }

  private nonisolated func decode<T: Decodable>(
    _ type: T.Type,
    from data: Data
  ) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    do { return try decoder.decode(type, from: data) } catch {
      throw BestASRPersistenceError.storedDataCorrupt
    }
  }

  private nonisolated func dictionaryJSON(_ values: [String]) throws -> String {
    try Self.dictionaryJSONValue(values)
  }

  private func decodeSnapshot(_ data: Data) throws -> DictationSessionSnapshot {
    let snapshot = try decode(DictationSessionSnapshot.self, from: data)
    do { try snapshot.validate() } catch { throw BestASRPersistenceError.storedDataCorrupt }
    return snapshot
  }

  private static func domainState(for phase: DictationPhase) -> SessionState {
    switch phase {
    case .idle, .preparing:
      return .preparing
    case .recording:
      return .recording
    case .paused:
      return .paused
    case .finalizing, .recognizing, .polishing, .inserting, .cancelling:
      return .finalizing
    case .completed:
      return .completed
    case .cancelled:
      return .cancelled
    case .failedRecoverable:
      return .failedRecoverable
    }
  }

  private static func isEphemeral(_ phase: DictationPhase) -> Bool {
    switch phase {
    case .preparing, .recording, .paused, .cancelling:
      return true
    case .idle, .finalizing, .recognizing, .polishing, .inserting,
      .completed, .cancelled, .failedRecoverable:
      return false
    }
  }

  private static func commitSnapshot(
    _ snapshot: DictationSessionSnapshot,
    data: Data,
    updatedAt: Double,
    in db: Database
  ) throws {
    guard let sessionID = snapshot.sessionID,
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT control_revision, snapshot_json FROM dictation_snapshots
          WHERE session_id = ?
          """,
        arguments: [sessionID.rawValue.uuidString]
      )
    else {
      throw BestASRPersistenceError.missingSession
    }
    let current: Int64 = row["control_revision"]
    let currentData: Data = row["snapshot_json"]
    let proposed = try sqliteInt(snapshot.revision)
    if proposed == current, currentData == data { return }
    guard proposed > current else {
      throw BestASRPersistenceError.nonMonotonicRevision(
        current: UInt64(current),
        proposed: snapshot.revision
      )
    }
    try db.execute(
      sql: """
        UPDATE sessions SET revision = ?, state = ?, updated_at = ? WHERE id = ?
        """,
      arguments: [
        proposed,
        domainState(for: snapshot.phase).rawValue,
        updatedAt,
        sessionID.rawValue.uuidString,
      ]
    )
    try db.execute(
      sql: """
        UPDATE dictation_snapshots
        SET control_revision = ?, phase = ?, snapshot_json = ?,
            is_ephemeral = ?, updated_at = ?
        WHERE session_id = ?
        """,
      arguments: [
        proposed,
        snapshot.phase.rawValue,
        data,
        isEphemeral(snapshot.phase) ? 1 : 0,
        updatedAt,
        sessionID.rawValue.uuidString,
      ]
    )
  }

  private static func normalizedPersonAliases(
    _ values: [String],
    excluding displayName: String
  ) -> [String] {
    var seen = Set<String>()
    let excluded = displayName
      .precomposedStringWithCompatibilityMapping.lowercased()
    return values.compactMap { value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = trimmed.precomposedStringWithCompatibilityMapping.lowercased()
      guard !trimmed.isEmpty, trimmed.utf8.count <= 256,
        key != excluded, seen.insert(key).inserted
      else { return nil }
      return trimmed
    }.prefix(64).map { $0 }
  }

  private static func normalizedPlatformPersonName(_ value: String) -> String {
    value.precomposedStringWithCompatibilityMapping.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "zh_Hans")
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func uuidValues(_ values: [String]) throws -> [UUID] {
    try values.map { value in
      guard let uuid = UUID(uuidString: value) else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      return uuid
    }
  }

  private static func associationInverseRows(
    sessionSpeakerID: SessionSpeakerID,
    in db: Database
  ) throws -> [PersonAssociationRowInverse] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT id, person_id, association_status, confidence,
               evidence_revision
        FROM speaker_occurrences
        WHERE session_speaker_id = ?
        ORDER BY monotonic_start_ns, id
        """,
      arguments: [sessionSpeakerID.rawValue.uuidString]
    ).map { row in
      guard let occurrenceID = UUID(uuidString: row["id"] as String) else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      let personValue: String? = row["person_id"]
      let personID: UUID?
      if let personValue {
        guard let parsed = UUID(uuidString: personValue) else {
          throw BestASRPersistenceError.storedDataCorrupt
        }
        personID = parsed
      } else {
        personID = nil
      }
      let evidenceRevision: Int64 = row["evidence_revision"]
      guard evidenceRevision > 0 else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      return PersonAssociationRowInverse(
        occurrenceID: occurrenceID,
        personID: personID,
        associationStatus: row["association_status"],
        confidence: row["confidence"],
        evidenceRevision: evidenceRevision
      )
    }
  }

  private static func rejectedMatchInverseRows(
    sessionSpeakerID: SessionSpeakerID,
    in db: Database
  ) throws -> [RejectedPersonMatchRowInverse] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT * FROM rejected_person_matches
        WHERE session_speaker_id = ? ORDER BY id
        """,
      arguments: [sessionSpeakerID.rawValue.uuidString]
    ).map { row in
      guard
        let id = UUID(uuidString: row["id"] as String),
        let speakerID = UUID(uuidString: row["session_speaker_id"] as String),
        let candidateID = UUID(uuidString: row["candidate_person_id"] as String)
      else { throw BestASRPersistenceError.storedDataCorrupt }
      return RejectedPersonMatchRowInverse(
        id: id,
        sessionSpeakerID: speakerID,
        candidatePersonID: candidateID,
        embeddingSpaceID: row["embedding_space_id"],
        vectorData: row["vector_json"],
        createdAt: row["created_at"]
      )
    }
  }

  private static func recordPersonEdit(
    payload: PersonCorrectionPayload,
    inverse: PersonEditInverse,
    kind: String,
    entityID: UUID,
    originDeviceID: UUID,
    now: Date,
    in db: Database
  ) throws {
    let correctionID = PersonCorrectionID()
    let operationID = UUID()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payloadData = try encoder.encode(payload)
    let inverseData = try encoder.encode(inverse)
    let revision = max(1, Int64(now.timeIntervalSince1970 * 1_000_000))
    try db.execute(
      sql: """
        INSERT INTO person_corrections (
          id, revision, occurred_at, actor, payload_json,
          reverses_operation_id
        ) VALUES (?, ?, ?, ?, ?, NULL)
        """,
      arguments: [
        correctionID.rawValue.uuidString,
        revision,
        now.timeIntervalSince1970,
        PersonCorrectionActor.user.rawValue,
        String(decoding: payloadData, as: UTF8.self),
      ]
    )
    try db.execute(
      sql: """
        INSERT INTO person_edit_operations (
          id, correction_id, kind, inverse_json, occurred_at, reversed_at
        ) VALUES (?, ?, ?, ?, ?, NULL)
        """,
      arguments: [
        operationID.uuidString,
        correctionID.rawValue.uuidString,
        kind,
        inverseData,
        now.timeIntervalSince1970,
      ]
    )
    try insertPersonChange(
      entityID: entityID,
      operation: kind,
      payloadData: payloadData,
      correctionID: correctionID,
      revision: revision,
      originDeviceID: originDeviceID,
      now: now,
      in: db
    )
  }

  private static func insertPersonChange(
    entityID: UUID,
    operation: String,
    payloadData: Data,
    correctionID: PersonCorrectionID,
    revision: Int64,
    originDeviceID: UUID,
    now: Date,
    in db: Database
  ) throws {
    let digest = SHA256.hash(data: payloadData).map {
      String(format: "%02x", $0)
    }.joined()
    try db.execute(
      sql: """
        INSERT INTO change_log (
          id, entity_kind, entity_stable_id, revision, occurred_at,
          origin_device_id, operation, payload_digest,
          person_correction_id
        ) VALUES (?, 'person', ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        UUID().uuidString,
        entityID.uuidString,
        revision,
        now.timeIntervalSince1970,
        originDeviceID.uuidString,
        operation,
        digest,
        correctionID.rawValue.uuidString,
      ]
    )
  }

  private static func updateUUIDSet(
    table: String,
    column: String,
    value: String,
    ids: [UUID],
    in db: Database
  ) throws {
    guard !ids.isEmpty else { return }
    guard
      [
        "speaker_occurrences", "person_embeddings", "speaker_name_evidence",
      ].contains(table),
      column == "person_id"
    else { throw BestASRPersistenceError.invalidSnapshot }
    let placeholders = Array(repeating: "?", count: ids.count)
      .joined(separator: ",")
    try db.execute(
      sql: "UPDATE \(table) SET \(column) = ? WHERE id IN (\(placeholders))",
      arguments: StatementArguments([value] + ids.map(\.uuidString))
    )
  }

  private static func sqliteInt(_ value: UInt64) throws -> Int64 {
    guard value <= UInt64(Int64.max) else {
      throw BestASRPersistenceError.numericOverflow
    }
    return Int64(value)
  }

  private static func validateTranscript(
    _ transcript: DictationTranscriptResult
  ) throws {
    guard !transcript.modelArtifactID.isEmpty else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    guard let provenance = transcript.provenance else { return }
    guard
      provenance.parentRevisionID != transcript.revisionID,
      [.streaming, .sentence, .final, .userEdit].contains(provenance.kind),
      !provenance.languageHints.isEmpty,
      provenance.languageHints.count <= 8,
      provenance.languageHints.allSatisfy({ !$0.isEmpty && $0.count <= 32 }),
      !provenance.audioRanges.isEmpty,
      transcript.segmentIDs == provenance.segments.map(\.id),
      Set(transcript.segmentIDs).count == transcript.segmentIDs.count
    else {
      throw BestASRPersistenceError.invalidSnapshot
    }

    var previousRangeEndByTrack: [UUID: UInt64] = [:]
    var references = Set<String>()
    for range in provenance.audioRanges {
      guard
        range.monotonicStartNanoseconds < range.monotonicEndNanoseconds,
        range.sampleRateHertz > 0,
        range.channelCount > 0,
        safeAssetReference(range.assetReference),
        range.contentDigest.range(
          of: "^[0-9a-f]{64}$",
          options: .regularExpression
        ) != nil,
        references.insert(range.assetReference).inserted,
        previousRangeEndByTrack[range.trackID].map({
          range.monotonicStartNanoseconds >= $0
        }) ?? true
      else {
        throw BestASRPersistenceError.invalidSnapshot
      }
      previousRangeEndByTrack[range.trackID] = range.monotonicEndNanoseconds
    }

    var previousSegmentOrder: (start: UInt64, end: UInt64)?
    for segment in provenance.segments {
      let isStablyOrdered =
        previousSegmentOrder.map { previous in
          segment.monotonicStartNanoseconds > previous.start
            || (segment.monotonicStartNanoseconds == previous.start
              && segment.monotonicEndNanoseconds >= previous.end)
        } ?? true
      guard
        segment.monotonicStartNanoseconds < segment.monotonicEndNanoseconds,
        segment.confidence.map({ $0.isFinite && $0 >= 0 && $0 <= 1 }) ?? true,
        isStablyOrdered,
        audioRangesCover(
          start: segment.monotonicStartNanoseconds,
          end: segment.monotonicEndNanoseconds,
          ranges: provenance.audioRanges
        )
      else {
        throw BestASRPersistenceError.invalidSnapshot
      }
      previousSegmentOrder = (
        segment.monotonicStartNanoseconds,
        segment.monotonicEndNanoseconds
      )
    }
  }

  private static func joinTranscriptSegments(
    _ segments: [DictationTranscriptSegment]
  ) -> String {
    TranscriptTextJoiner.join(segments.map(\.text))
  }

  private static func audioRangesCover(
    start: UInt64,
    end: UInt64,
    ranges: [AudioRangeInput]
  ) -> Bool {
    guard start < end else { return false }
    let rangesByTrack = Dictionary(grouping: ranges, by: \.trackID)
    return rangesByTrack.values.contains { trackRanges in
      oneTrackCovers(
        start: start,
        end: end,
        ranges: trackRanges.sorted {
          if $0.monotonicStartNanoseconds != $1.monotonicStartNanoseconds {
            return $0.monotonicStartNanoseconds < $1.monotonicStartNanoseconds
          }
          return $0.assetReference < $1.assetReference
        }
      )
    }
  }

  private static func oneTrackCovers(
    start: UInt64,
    end: UInt64,
    ranges: [AudioRangeInput]
  ) -> Bool {
    guard
      let firstIndex = ranges.firstIndex(where: {
        start >= $0.monotonicStartNanoseconds
          && start < $0.monotonicEndNanoseconds
      })
    else { return false }

    var coveredEnd = ranges[firstIndex].monotonicEndNanoseconds
    if end <= coveredEnd { return true }
    for range in ranges.dropFirst(firstIndex + 1) {
      let tolerance = max(
        UInt64(1),
        2_000_000_000 / UInt64(max(1, range.sampleRateHertz))
      )
      let toleratedEnd =
        coveredEnd > UInt64.max - tolerance
        ? UInt64.max
        : coveredEnd + tolerance
      guard range.monotonicStartNanoseconds <= toleratedEnd else {
        return false
      }
      coveredEnd = max(coveredEnd, range.monotonicEndNanoseconds)
      if end <= coveredEnd { return true }
    }
    return false
  }

  private static func commitHistoryTranscriptRevision(
    _ commit: DictationTranscriptRevisionCommit,
    expectedInputRevision: Int64,
    in db: Database
  ) throws {
    try commitTranscriptRevision(commit, expectedInputRevision: expectedInputRevision, in: db)
    try db.execute(
      sql:
        "UPDATE derived_text_revisions SET state = 'stale' WHERE session_id = ? AND state = 'current'",
      arguments: [commit.sessionID.rawValue.uuidString]
    )
    try db.execute(
      sql:
        "UPDATE local_text_documents SET state = 'stale' WHERE session_id = ? AND state = 'current'",
      arguments: [commit.sessionID.rawValue.uuidString]
    )
    try db.execute(
      sql: """
        UPDATE event_text_documents SET state = 'stale'
        WHERE state = 'current' AND event_id IN (
          SELECT event_id FROM event_sessions WHERE session_id = ?
        )
        """,
      arguments: [commit.sessionID.rawValue.uuidString]
    )
  }

  private static func commitTranscriptRevision(
    _ commit: DictationTranscriptRevisionCommit,
    expectedInputRevision: Int64,
    in db: Database
  ) throws {
    let provenance = commit.transcript.provenance
    let parentID = provenance?.parentRevisionID?.rawValue.uuidString
    let kind = provenance?.kind ?? .final
    let languageData = try JSONEncoder().encode(provenance?.languageHints ?? [])
    let transcriptID = commit.transcript.revisionID.rawValue.uuidString
    try db.execute(
      sql: """
        INSERT INTO transcript_revisions (
          id, session_id, revision, parent_id, kind, content,
          model_artifact_id, config_hash, created_at, language_hints_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO NOTHING
        """,
      arguments: [
        transcriptID,
        commit.sessionID.rawValue.uuidString,
        expectedInputRevision,
        parentID,
        kind.rawValue,
        commit.transcript.text,
        commit.transcript.modelArtifactID,
        commit.configHash.value,
        commit.createdAt.timeIntervalSince1970,
        languageData,
      ]
    )
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT session_id, revision, parent_id, kind, content,
                 model_artifact_id, config_hash, created_at, language_hints_json
          FROM transcript_revisions WHERE id = ?
          """,
        arguments: [transcriptID]
      )
    else {
      throw BestASRPersistenceError.processingCommitConflict
    }
    let storedSessionID: String = row["session_id"]
    let storedRevision: Int64 = row["revision"]
    let storedParentID: String? = row["parent_id"]
    let storedKind: String = row["kind"]
    let storedContent: String = row["content"]
    let storedModel: String? = row["model_artifact_id"]
    let storedConfig: String? = row["config_hash"]
    let storedCreatedAt: Double = row["created_at"]
    let storedLanguageData: Data = row["language_hints_json"]
    guard
      storedSessionID == commit.sessionID.rawValue.uuidString,
      storedRevision == expectedInputRevision,
      storedParentID == parentID,
      storedKind == kind.rawValue,
      storedContent == commit.transcript.text,
      storedModel == commit.transcript.modelArtifactID,
      storedConfig == commit.configHash.value,
      storedCreatedAt == commit.createdAt.timeIntervalSince1970,
      storedLanguageData == languageData
    else {
      throw BestASRPersistenceError.processingCommitConflict
    }

    let segments = provenance?.segments ?? []
    for (ordinal, segment) in segments.enumerated() {
      try db.execute(
        sql: """
          INSERT INTO transcript_segments (
            transcript_id, segment_id, ordinal, monotonic_start_ns,
            monotonic_end_ns, text, confidence
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(transcript_id, segment_id) DO NOTHING
          """,
        arguments: [
          transcriptID,
          segment.id.uuidString,
          ordinal,
          try sqliteInt(segment.monotonicStartNanoseconds),
          try sqliteInt(segment.monotonicEndNanoseconds),
          segment.text,
          segment.confidence,
        ]
      )
    }
    let segmentRows = try Row.fetchAll(
      db,
      sql: """
        SELECT segment_id, ordinal, monotonic_start_ns, monotonic_end_ns,
               text, confidence
        FROM transcript_segments
        WHERE transcript_id = ? ORDER BY ordinal
        """,
      arguments: [transcriptID]
    )
    guard segmentRows.count == segments.count else {
      throw BestASRPersistenceError.processingCommitConflict
    }
    for (expectedOrdinal, pair) in zip(segmentRows, segments).enumerated() {
      let (row, segment) = pair
      let expectedStart = try sqliteInt(segment.monotonicStartNanoseconds)
      let expectedEnd = try sqliteInt(segment.monotonicEndNanoseconds)
      let segmentID: String = row["segment_id"]
      let ordinal: Int = row["ordinal"]
      let start: Int64 = row["monotonic_start_ns"]
      let end: Int64 = row["monotonic_end_ns"]
      let text: String = row["text"]
      let confidence: Double? = row["confidence"]
      guard
        segmentID == segment.id.uuidString,
        ordinal == expectedOrdinal,
        start == expectedStart,
        end == expectedEnd,
        text == segment.text,
        confidence == segment.confidence
      else {
        throw BestASRPersistenceError.processingCommitConflict
      }
    }

    let audioRanges = provenance?.audioRanges ?? []
    for (ordinal, range) in audioRanges.enumerated() {
      try db.execute(
        sql: """
          INSERT INTO transcript_audio_ranges (
            transcript_id, ordinal, source_id, track_id, asset_reference,
            digest, monotonic_start_ns, monotonic_end_ns,
            sample_rate_hz, channel_count
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(transcript_id, ordinal) DO NOTHING
          """,
        arguments: [
          transcriptID,
          ordinal,
          range.sourceID.uuidString,
          range.trackID.uuidString,
          range.assetReference,
          range.contentDigest,
          try sqliteInt(range.monotonicStartNanoseconds),
          try sqliteInt(range.monotonicEndNanoseconds),
          Int64(range.sampleRateHertz),
          Int64(range.channelCount),
        ]
      )
    }
    let audioRows = try Row.fetchAll(
      db,
      sql: """
        SELECT ordinal, source_id, track_id, asset_reference, digest,
               monotonic_start_ns, monotonic_end_ns,
               sample_rate_hz, channel_count
        FROM transcript_audio_ranges
        WHERE transcript_id = ? ORDER BY ordinal
        """,
      arguments: [transcriptID]
    )
    guard audioRows.count == audioRanges.count else {
      throw BestASRPersistenceError.processingCommitConflict
    }
    for (expectedOrdinal, pair) in zip(audioRows, audioRanges).enumerated() {
      let (row, range) = pair
      let expectedStart = try sqliteInt(range.monotonicStartNanoseconds)
      let expectedEnd = try sqliteInt(range.monotonicEndNanoseconds)
      let ordinal: Int = row["ordinal"]
      let sourceID: String = row["source_id"]
      let trackID: String = row["track_id"]
      let reference: String = row["asset_reference"]
      let digest: String = row["digest"]
      let start: Int64 = row["monotonic_start_ns"]
      let end: Int64 = row["monotonic_end_ns"]
      let sampleRate: Int64 = row["sample_rate_hz"]
      let channelCount: Int64 = row["channel_count"]
      guard
        ordinal == expectedOrdinal,
        sourceID == range.sourceID.uuidString,
        trackID == range.trackID.uuidString,
        reference == range.assetReference,
        digest == range.contentDigest,
        start == expectedStart,
        end == expectedEnd,
        sampleRate == Int64(range.sampleRateHertz),
        channelCount == Int64(range.channelCount)
      else {
        throw BestASRPersistenceError.processingCommitConflict
      }
    }
  }

  private static func safeAssetReference(_ value: String) -> Bool {
    !value.isEmpty
      && !value.hasPrefix("/")
      && !value.contains("..")
      && URL(string: value)?.scheme == nil
  }

  private static func assetReference(_ reference: PortableAssetReference) -> String {
    switch reference {
    case .relativePath(let path):
      return path
    case .contentAddressed(let digest):
      return "sha256-\(digest.value)"
    }
  }

  private static func dictionaryEntry(_ row: Row) throws -> DictionaryEntry {
    guard let uuid = UUID(uuidString: row["id"]) else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    let revisionValue: Int64 = row["revision"]
    let spokenJSON: String = row["spoken_forms_json"]
    guard revisionValue > 0, let spokenData = spokenJSON.data(using: .utf8) else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    let spokenForms: [String]
    do {
      spokenForms = try JSONDecoder().decode([String].self, from: spokenData)
    } catch {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    let enabledValue: Int = row["enabled"]
    let tombstoneValue: Double? = row["tombstoned_at"]
    do {
      return try DictionaryEntry(
        id: DictionaryEntryID(uuid),
        revision: Revision(UInt64(revisionValue)),
        canonicalForm: row["canonical_form"],
        spokenForms: spokenForms,
        enabled: enabledValue == 1,
        createdAt: Date(timeIntervalSince1970: row["created_at"]),
        updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
        tombstonedAt: tombstoneValue.map(Date.init(timeIntervalSince1970:))
      )
    } catch {
      throw BestASRPersistenceError.storedDataCorrupt
    }
  }

  private static func dictionaryJSONValue(_ values: [String]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(values)
    guard let value = String(data: data, encoding: .utf8) else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    return value
  }

  private static func databaseDate(_ value: Date) -> Date {
    Date(
      timeIntervalSince1970: (value.timeIntervalSince1970 * 1_000).rounded(.down) / 1_000
    )
  }

  private static func hasLiveDictionaryCanonicalForm(
    _ canonicalForm: String,
    excluding id: DictionaryEntryID?,
    in db: Database
  ) throws -> Bool {
    let excludedID = id?.rawValue.uuidString
    return try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(
          SELECT 1 FROM dictionary_entries
          WHERE tombstoned_at IS NULL
            AND canonical_form = ? COLLATE NOCASE
            AND (? IS NULL OR id <> ?)
        )
        """,
      arguments: [canonicalForm, excludedID, excludedID]
    ) ?? false
  }

  private static func invalidateCurrentDerivations(in db: Database) throws {
    try db.execute(
      sql: """
        UPDATE derived_text_revisions SET state = 'stale'
        WHERE state = 'current'
        """
    )
  }

  private static func derivedTextRecord(_ row: Row) throws
    -> DictationDerivedTextRecord
  {
    guard let id = UUID(uuidString: row["id"]),
      let sessionUUID = UUID(uuidString: row["session_id"]),
      let transcriptUUID = UUID(uuidString: row["source_transcript_id"]),
      let state = DictationDerivedTextState(rawValue: row["state"])
    else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    let sourceRevision: Int64 = row["source_revision"]
    return DictationDerivedTextRecord(
      id: id,
      sessionID: SessionID(sessionUUID),
      sourceTranscriptID: TranscriptRevisionID(transcriptUUID),
      sourceRevision: try Revision(UInt64(sourceRevision)),
      outputText: row["output_text"],
      modelArtifactID: row["model_artifact_id"],
      configHash: try SHA256Digest(row["config_hash"]),
      state: state,
      createdAt: Date(timeIntervalSince1970: row["created_at"])
    )
  }

  private static func persistedTranscriptRecord(
    _ row: Row,
    segmentRows: [Row],
    audioRows: [Row]
  ) throws
    -> DictationPersistedTranscriptRecord
  {
    guard let id = UUID(uuidString: row["id"]),
      let sessionUUID = UUID(uuidString: row["session_id"]),
      let kind = TranscriptRevisionKind(rawValue: row["kind"])
    else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    let revision: Int64 = row["revision"]
    guard revision > 0 else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    let configValue: String? = row["config_hash"]
    let parentValue: String? = row["parent_id"]
    let parentID: TranscriptRevisionID?
    if let parentValue {
      guard let parentUUID = UUID(uuidString: parentValue) else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      parentID = TranscriptRevisionID(parentUUID)
    } else {
      parentID = nil
    }
    let languageData: Data = row["language_hints_json"]
    let languageHints: [String]
    do {
      languageHints = try JSONDecoder().decode([String].self, from: languageData)
    } catch {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    let segments = try segmentRows.map { segmentRow in
      guard let segmentID = UUID(uuidString: segmentRow["segment_id"]) else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      let start: Int64 = segmentRow["monotonic_start_ns"]
      let end: Int64 = segmentRow["monotonic_end_ns"]
      guard start >= 0, end > start else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      return DictationTranscriptSegment(
        id: segmentID,
        monotonicStartNanoseconds: UInt64(start),
        monotonicEndNanoseconds: UInt64(end),
        text: segmentRow["text"],
        confidence: segmentRow["confidence"]
      )
    }
    let audioRanges = try audioRows.map { audioRow in
      guard
        let sourceID = UUID(uuidString: audioRow["source_id"]),
        let trackID = UUID(uuidString: audioRow["track_id"])
      else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      let start: Int64 = audioRow["monotonic_start_ns"]
      let end: Int64 = audioRow["monotonic_end_ns"]
      let sampleRate: Int64 = audioRow["sample_rate_hz"]
      let channelCount: Int64 = audioRow["channel_count"]
      guard
        start >= 0,
        end > start,
        sampleRate > 0,
        sampleRate <= Int64(UInt32.max),
        channelCount > 0,
        channelCount <= Int64(UInt16.max)
      else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      return AudioRangeInput(
        sourceID: sourceID,
        trackID: trackID,
        assetReference: audioRow["asset_reference"],
        contentDigest: audioRow["digest"],
        monotonicStartNanoseconds: UInt64(start),
        monotonicEndNanoseconds: UInt64(end),
        sampleRateHertz: UInt32(sampleRate),
        channelCount: UInt16(channelCount)
      )
    }
    return DictationPersistedTranscriptRecord(
      id: TranscriptRevisionID(id),
      sessionID: SessionID(sessionUUID),
      inputRevision: UInt64(revision),
      parentID: parentID,
      kind: kind,
      content: row["content"],
      modelArtifactID: row["model_artifact_id"],
      configHash: try configValue.map(SHA256Digest.init),
      languageHints: languageHints,
      audioRanges: audioRanges,
      segments: segments,
      createdAt: Date(timeIntervalSince1970: row["created_at"])
    )
  }

  private static func insert(
    job: DurableJob,
    sessionID: SessionID,
    in db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO durable_jobs (
          id, revision, kind, state, input_revision, model_artifact_id,
          config_hash, retry_count, error_category, lease_owner,
          lease_expires_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO NOTHING
        """,
      arguments: [
        job.id.rawValue.uuidString,
        try sqliteInt(job.revision.value),
        job.kind.rawValue,
        job.state.rawValue,
        try sqliteInt(job.inputRevision.value),
        job.modelArtifactID?.rawValue.uuidString,
        job.configHash.value,
        Int64(job.retryCount),
        job.errorCategory.rawValue,
        job.leaseOwner?.uuidString,
        job.leaseExpiresAt?.timeIntervalSince1970,
      ]
    )
    try db.execute(
      sql: """
        INSERT INTO dictation_job_sessions (job_id, session_id)
        VALUES (?, ?)
        ON CONFLICT(job_id) DO NOTHING
        """,
      arguments: [job.id.rawValue.uuidString, sessionID.rawValue.uuidString]
    )
    guard
      let stored = try Row.fetchOne(
        db,
        sql: """
          SELECT j.*, d.session_id FROM durable_jobs j
          JOIN dictation_job_sessions d ON d.job_id = j.id
          WHERE j.id = ?
          """,
        arguments: [job.id.rawValue.uuidString]
      ),
      try durableJob(stored) == job,
      stored["session_id"] as String == sessionID.rawValue.uuidString
    else {
      throw BestASRPersistenceError.processingCommitConflict
    }
  }

  private static func durableJob(_ row: Row) throws -> DurableJob {
    let idValue: String = row["id"]
    let revisionValue: Int64 = row["revision"]
    let inputRevisionValue: Int64 = row["input_revision"]
    let retryCountValue: Int64 = row["retry_count"]
    let modelValue: String? = row["model_artifact_id"]
    let leaseValue: String? = row["lease_owner"]
    guard let id = UUID(uuidString: idValue),
      revisionValue > 0,
      inputRevisionValue > 0,
      retryCountValue >= 0,
      retryCountValue <= Int64(UInt32.max),
      let kind = DurableJobKind(rawValue: row["kind"]),
      let state = DurableJobState(rawValue: row["state"]),
      let errorCategory = DurableJobErrorCategory(
        rawValue: row["error_category"]
      )
    else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    let modelArtifactID: ModelArtifactID?
    if let modelValue {
      guard let uuid = UUID(uuidString: modelValue) else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      modelArtifactID = ModelArtifactID(uuid)
    } else {
      modelArtifactID = nil
    }
    let leaseOwner: UUID?
    if let leaseValue {
      guard let uuid = UUID(uuidString: leaseValue) else {
        throw BestASRPersistenceError.storedDataCorrupt
      }
      leaseOwner = uuid
    } else {
      leaseOwner = nil
    }
    let leaseExpiry: Double? = row["lease_expires_at"]
    return DurableJob(
      id: DurableJobID(id),
      revision: try Revision(UInt64(revisionValue)),
      kind: kind,
      state: state,
      inputRevision: try Revision(UInt64(inputRevisionValue)),
      modelArtifactID: modelArtifactID,
      configHash: try SHA256Digest(row["config_hash"]),
      retryCount: UInt32(retryCountValue),
      errorCategory: errorCategory,
      leaseOwner: leaseOwner,
      leaseExpiresAt: leaseExpiry.map(Date.init(timeIntervalSince1970:))
    )
  }

  private static func synchronizeTimelineEvents(
    _ snapshot: DictationSessionSnapshot,
    in db: Database
  ) throws {
    guard let sessionID = snapshot.sessionID else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    for (index, marker) in snapshot.timeline.enumerated() {
      let kind: TimelineEventKind
      switch marker.kind {
      case .paused: kind = .pause
      case .resumed: kind = .resume
      case .started, .endRequested, .cancelRequested: continue
      }
      let duration: UInt64?
      if marker.kind == .paused,
        let closingMarker = snapshot.timeline.dropFirst(index + 1).first(where: {
          [.resumed, .endRequested, .cancelRequested].contains($0.kind)
        }),
        closingMarker.monotonicNanoseconds >= marker.monotonicNanoseconds
      {
        duration =
          closingMarker.monotonicNanoseconds
          - marker.monotonicNanoseconds
      } else {
        duration = nil
      }
      let eventID = deterministicUUID([
        "dictation-timeline-event-v1",
        sessionID.rawValue.uuidString.lowercased(),
        String(index),
        marker.kind.rawValue,
        String(marker.monotonicNanoseconds),
      ])
      try db.execute(
        sql: """
          INSERT INTO timeline_events (
            id, session_id, revision, kind, monotonic_ns, duration_ns
          ) VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET duration_ns = excluded.duration_ns
          WHERE timeline_events.session_id = excluded.session_id
          """,
        arguments: [
          eventID.uuidString,
          sessionID.rawValue.uuidString,
          try sqliteInt(UInt64(index + 1)),
          kind.rawValue,
          try sqliteInt(marker.monotonicNanoseconds),
          try duration.map(sqliteInt),
        ]
      )
    }
  }

  private static func normalizedSessionTitle(_ value: String) -> String? {
    let collapsed =
      value
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !collapsed.isEmpty else { return nil }
    let prefix = String(collapsed.prefix(72))
    return prefix.count < collapsed.count ? "\(prefix)…" : prefix
  }

  private static func deterministicUUID(_ components: [String]) -> UUID {
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

  private static func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
  }
}

/// One run of a session's recording after compaction, as the audio index and
/// the transcript provenance need to see it.
public struct CompactedAudioChunkRecord: Equatable, Sendable {
  public let trackID: TrackID
  public let sequence: UInt64
  public let assetReference: String
  public let monotonicStartNanoseconds: UInt64
  public let monotonicEndNanoseconds: UInt64
  public let frameCount: UInt32
  public let digest: String
  public let sampleRateHertz: UInt32
  public let channelCount: UInt16

  public init(
    trackID: TrackID,
    sequence: UInt64,
    assetReference: String,
    monotonicStartNanoseconds: UInt64,
    monotonicEndNanoseconds: UInt64,
    frameCount: UInt32,
    digest: String,
    sampleRateHertz: UInt32,
    channelCount: UInt16
  ) {
    self.trackID = trackID
    self.sequence = sequence
    self.assetReference = assetReference
    self.monotonicStartNanoseconds = monotonicStartNanoseconds
    self.monotonicEndNanoseconds = monotonicEndNanoseconds
    self.frameCount = frameCount
    self.digest = digest
    self.sampleRateHertz = sampleRateHertz
    self.channelCount = channelCount
  }
}
