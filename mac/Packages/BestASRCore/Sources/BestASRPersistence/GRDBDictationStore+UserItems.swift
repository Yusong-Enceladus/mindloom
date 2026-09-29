import BestASRDictation
import BestASRDomain
import CryptoKit
import Foundation
import GRDB

/// Pasted or dragged items (PRD §0.3.2) stored as `userItem` sessions.
///
/// Why a session and not a separate item table: the organizer already uses
/// the SessionID as `item_id`, and the outbox, eligibility, change triggers,
/// event membership, full-text search, explicit deletion with tombstones, and
/// the portable archive all work per session. An item is one committed
/// `sessions` row with a `final` transcript revision holding its text, its
/// files in `session_source_assets`, and a `user_item_details` row for what a
/// recording does not have. A correction is a `userEdit` child revision; the
/// original text and file are never overwritten.
extension GRDBDictationStore {
  /// Commits one item in one transaction. Files named by the attachments
  /// must already be in the asset root; nothing here touches the filesystem.
  /// A capture made while the organizer link is on is eligible (same rule as
  /// a live recording) and is queued in the same transaction.
  public func createUserItem(_ draft: UserItemDraft) async throws {
    try Self.validate(draft)
    let id = draft.id.rawValue.uuidString
    let now = Date().timeIntervalSince1970
    let capturedAt = draft.capturedAt.timeIntervalSince1970
    let snapshot = DictationSessionSnapshot(
      sessionID: draft.id, revision: 1, phase: .completed
    )
    do { try snapshot.validate() } catch { throw BestASRPersistenceError.invalidSnapshot }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let snapshotData = try encoder.encode(snapshot)
    let original = draft.attachments.first { $0.role == .original }
    let normalized = draft.attachments.first { $0.role == .normalizedImage }
    let assetIDs = draft.attachments.map { _ in UUID().uuidString }
    let transcriptID = UUID().uuidString
    let database = try requirePool()
    do {
      try await database.write { db in
        try db.execute(
          sql: """
            INSERT INTO sessions (
              id, revision, input_mode, state, source_audio_retention,
              created_at, updated_at
            ) VALUES (?, 1, ?, 'completed', ?, ?, ?)
            """,
          arguments: [
            id, SessionInputMode.userItem.rawValue,
            SourceAudioRetention.retainedUntilExplicitDeletion.rawValue,
            capturedAt, now,
          ]
        )
        try Self.markRemoteEligibleIfLinkEnabled(db, sessionID: id, at: now)
        try db.execute(
          sql: """
            INSERT INTO session_metadata (
              session_id, revision, title, title_is_user_edited, source_kind,
              source_identifier, source_display_name, source_bundle_id,
              recording_format, created_at, updated_at
            ) VALUES (?, 1, ?, 0, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            id, draft.automaticTitle, SessionInputMode.userItem.rawValue,
            draft.originalFilename, draft.source?.name, draft.source?.bundleID,
            original?.mediaType ?? "text/plain", capturedAt, now,
          ]
        )
        try db.execute(
          sql: """
            INSERT INTO dictation_snapshots (
              session_id, control_revision, phase, snapshot_json,
              is_ephemeral, updated_at
            ) VALUES (?, 1, 'completed', ?, 0, ?)
            """,
          arguments: [id, snapshotData, capturedAt]
        )
        try db.execute(
          sql: """
            INSERT INTO transcript_revisions (
              id, session_id, revision, parent_id, kind, content,
              model_artifact_id, config_hash, created_at, language_hints_json
            ) VALUES (?, ?, 1, NULL, 'final', ?, NULL, ?, ?, ?)
            """,
          arguments: [
            transcriptID, id, draft.text, Self.extractorConfigHash(draft.extractor),
            capturedAt, Data("[]".utf8),
          ]
        )
        // A screenshot's on-device reading is a derived revision of the item's
        // (empty) source text: searchable and exportable, never the source.
        if let reading = draft.reading {
          try db.execute(
            sql: """
              INSERT INTO derived_text_revisions (
                id, session_id, source_transcript_id, source_revision,
                output_text, model_artifact_id, config_hash, state, created_at
              ) VALUES (?, ?, ?, 1, ?, ?, ?, 'current', ?)
              """,
            arguments: [
              UUID().uuidString, id, transcriptID, reading.text,
              Self.userItemReadingArtifactID, Self.extractorConfigHash(reading.reader),
              capturedAt,
            ]
          )
        }
        for (attachment, assetID) in zip(draft.attachments, assetIDs) {
          try db.execute(
            sql: """
              INSERT INTO session_source_assets (
                id, session_id, revision, kind, original_filename, media_type,
                asset_reference, digest, size_bytes, created_at, duration_ns
              ) VALUES (?, ?, 1, ?, ?, ?, ?, ?, ?, ?, NULL)
              """,
            arguments: [
              assetID, id, Self.assetKind(attachment.role).rawValue,
              attachment.originalFilename, attachment.mediaType,
              attachment.relativePath, attachment.digest.value,
              Int64(attachment.sizeBytes), now,
            ]
          )
        }
        let originalAssetID = original.flatMap { value in
          draft.attachments.firstIndex(of: value).map { assetIDs[$0] }
        }
        let normalizedAssetID = normalized.flatMap { value in
          draft.attachments.firstIndex(of: value).map { assetIDs[$0] }
        }
        try db.execute(
          sql: """
            INSERT INTO user_item_details (
              session_id, revision, item_kind, captured_at, source_origin,
              extractor, page_count, pixel_width, pixel_height,
              original_asset_id, normalized_asset_id, created_at, updated_at,
              uniform_type, parent_session_id, frame_ms
            ) VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            id, draft.kind.rawValue, capturedAt, draft.sourceOrigin.rawValue,
            draft.extractor, draft.pageCount, draft.pixelWidth, draft.pixelHeight,
            originalAssetID, normalizedAssetID, now, now, draft.uniformType,
            draft.parentSessionID?.rawValue.uuidString, draft.frameMilliseconds,
          ]
        )
        if try Self.remoteLinkEnabledAt(db) != nil,
          try Self.isRemoteEligible(db, sessionID: id)
        {
          try Self.insertRemoteItemJob(db, itemID: id, createdAt: capturedAt)
        }
      }
    } catch let error as DatabaseError
      where error.extendedResultCode == .SQLITE_CONSTRAINT_PRIMARYKEY
    {
      throw BestASRPersistenceError.duplicateSession
    }
  }

  /// The user changed where an item came from. Stored as a new metadata
  /// revision; the organizer trigger queues a new item revision when the
  /// item was already sent. Pass nil to clear the label.
  public func setItemSourceApplication(
    sessionID: SessionID, source: ItemSourceApplication?
  ) async throws {
    if let source {
      guard source.name.unicodeScalars.count <= 256,
        (source.bundleID?.utf8.count ?? 0) <= 1_024
      else { throw BestASRPersistenceError.invalidSnapshot }
    }
    let id = sessionID.rawValue.uuidString
    let database = try requirePool()
    try await database.write { db in
      guard
        try String.fetchOne(
          db, sql: "SELECT input_mode FROM sessions WHERE id = ?", arguments: [id]
        ) == SessionInputMode.userItem.rawValue
      else { throw BestASRPersistenceError.missingSession }
      let now = Date()
      let affectedEventIDs = try Self.eventIDsAffectedByIdentityChange(
        sessionValues: [id], in: db
      )
      try db.execute(
        sql: """
          UPDATE session_metadata
          SET revision = revision + 1, source_display_name = ?,
              source_bundle_id = ?, updated_at = ?
          WHERE session_id = ?
          """,
        arguments: [source?.name, source?.bundleID, now.timeIntervalSince1970, id]
      )
      guard db.changesCount == 1 else { throw BestASRPersistenceError.missingSession }
      try db.execute(
        sql: """
          UPDATE user_item_details
          SET revision = revision + 1, source_origin = 'user', updated_at = ?
          WHERE session_id = ?
          """,
        arguments: [now.timeIntervalSince1970, id]
      )
      try Self.refreshEventAggregates(eventIDs: affectedEventIDs, at: now, in: db)
    }
  }

  /// Item facts for one item, or nil when the session is not an item.
  public func userItemDetails(sessionID: SessionID) async throws -> UserItemDetails? {
    let database = try requirePool()
    return try await database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM user_item_details WHERE session_id = ?",
          arguments: [sessionID.rawValue.uuidString]
        ),
        let kind = UserItemKind(rawValue: row["item_kind"]),
        let origin = ItemSourceOrigin(rawValue: row["source_origin"])
      else { return nil }
      let revision: Int64 = row["revision"]
      return UserItemDetails(
        sessionID: sessionID, revision: UInt64(max(1, revision)), kind: kind,
        capturedAt: Date(timeIntervalSince1970: row["captured_at"]),
        sourceOrigin: origin, extractor: row["extractor"],
        pageCount: row["page_count"], pixelWidth: row["pixel_width"],
        pixelHeight: row["pixel_height"],
        originalAssetID: (row["original_asset_id"] as String?).flatMap(UUID.init(uuidString:)),
        normalizedAssetID: (row["normalized_asset_id"] as String?).flatMap(
          UUID.init(uuidString:))
      )
    }
  }

  /// Sessions among `candidates` that have a row. Used by the startup sweep
  /// so it removes only staging directories whose commit never happened.
  public func existingSessionIDs(among candidates: [SessionID]) async throws -> Set<SessionID> {
    guard !candidates.isEmpty else { return [] }
    let json = try Self.jsonIDs(candidates)
    let database = try requirePool()
    return try await database.read { db in
      Set(
        try String.fetchAll(
          db, sql: "SELECT id FROM sessions WHERE id IN (SELECT value FROM json_each(?))",
          arguments: [json]
        ).compactMap { UUID(uuidString: $0).map(SessionID.init) }
      )
    }
  }

  /// Local records for the memory read model and the event export, in the
  /// order of `ids`. IDs with no local row (deleted, or never on this Mac)
  /// are omitted.
  public func memoryItemRecords(ids: [SessionID]) async throws -> [MemoryItemRecord] {
    var seen = Set<SessionID>()
    let unique = ids.filter { seen.insert($0).inserted }
    guard !unique.isEmpty else { return [] }
    let json = try Self.jsonIDs(unique)
    let database = try requirePool()
    let records: [String: MemoryItemRecord] = try await database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          WITH \(Self.recordedAudioDurationsCTE)
          SELECT s.id, s.input_mode, s.created_at, s.updated_at,
                 s.source_audio_retention,
                 m.title, m.title_is_user_edited, m.source_bundle_id,
                 m.source_display_name, m.source_identifier,
                 m.updated_at AS metadata_updated_at,
                 d.item_kind, d.page_count, d.uniform_type, d.parent_session_id, d.frame_ms,
                 tr.id AS transcript_id, tr.content, tr.created_at AS text_updated_at,
                 -- The reading describes the image, so a later caption edit
                 -- of the item's text does not retire it.
                 (SELECT dt.output_text FROM derived_text_revisions dt
                  WHERE dt.session_id = s.id
                    AND dt.model_artifact_id = '\(Self.userItemReadingArtifactID)'
                  ORDER BY dt.created_at DESC, dt.id DESC LIMIT 1) AS local_reading,
                 rad.duration_ns,
                 (SELECT a.asset_reference FROM session_source_assets a
                  WHERE a.session_id = s.id AND a.kind = 'normalizedImage'
                  ORDER BY (a.id = d.normalized_asset_id) DESC, a.revision DESC, a.id
                  LIMIT 1) AS thumbnail_reference,
                 oa.asset_reference AS original_reference,
                 oa.media_type AS original_media_type,
                 oa.size_bytes AS original_size_bytes,
                 (EXISTS (SELECT 1 FROM audio_chunks c WHERE c.session_id = s.id)
                  OR EXISTS (SELECT 1 FROM session_source_assets a
                             WHERE a.session_id = s.id AND a.kind = 'importedOriginal'))
                   AS has_audio
          FROM sessions s
          LEFT JOIN session_metadata m ON m.session_id = s.id
          LEFT JOIN user_item_details d ON d.session_id = s.id
          LEFT JOIN recorded_audio_durations rad ON rad.session_id = s.id
          LEFT JOIN session_source_assets oa ON oa.id = (
            SELECT a.id FROM session_source_assets a
            WHERE a.session_id = s.id
              AND a.kind IN ('userProvidedOriginal', 'importedOriginal')
            ORDER BY a.revision DESC, a.id LIMIT 1
          )
          LEFT JOIN transcript_revisions tr ON tr.id = (
            SELECT id FROM transcript_revisions
            WHERE session_id = s.id AND kind IN ('final', 'userEdit')
            ORDER BY created_at DESC, revision DESC, id DESC LIMIT 1
          )
          WHERE s.id IN (SELECT value FROM json_each(?))
          """,
        arguments: [json]
      )
      var result: [String: MemoryItemRecord] = [:]
      for row in rows {
        let id: String = row["id"]
        guard let uuid = UUID(uuidString: id),
          let mode = SessionInputMode(rawValue: row["input_mode"])
        else { continue }
        let people = try Self.memoryPeople(db, sessionID: id)
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.name) })
        let transcriptID: String? = row["transcript_id"]
        let segments =
          try transcriptID.map {
            try Self.memorySegments(db, sessionID: id, transcriptID: $0, names: names)
          } ?? []
        let retained =
          (row["source_audio_retention"] as String)
          == SourceAudioRetention.retainedUntilExplicitDeletion.rawValue
        let duration: Int64? = row["duration_ns"]
        let updated =
          [
            row["updated_at"] as Double?, row["metadata_updated_at"] as Double?,
            row["text_updated_at"] as Double?,
          ].compactMap { $0 }.max() ?? (row["created_at"] as Double)
        var record = MemoryItemRecord(
          sessionID: SessionID(uuid), inputMode: mode,
          itemKind: (row["item_kind"] as String?).flatMap(UserItemKind.init(rawValue:)),
          title: (row["title"] as String?) ?? SourceLabel.fallback(for: mode),
          startedAt: Date(timeIntervalSince1970: row["created_at"]),
          updatedAt: Date(timeIntervalSince1970: updated),
          sourceBundleID: row["source_bundle_id"],
          sourceDisplayName: row["source_display_name"],
          sourceIdentifier: row["source_identifier"],
          text: row["content"],
          segments: segments, people: people,
          durationNanoseconds: duration.flatMap { $0 > 0 ? UInt64($0) : nil },
          playbackAvailable: retained && mode != .userItem && (row["has_audio"] as Bool),
          thumbnailAssetPath: row["thumbnail_reference"],
          originalAssetPath: row["original_reference"],
          pageCount: row["page_count"],
          localReading: mode == .userItem ? row["local_reading"] : nil,
          titleIsUserEdited: (row["title_is_user_edited"] as Bool?) ?? false
        )
        record.uniformType = row["uniform_type"]
        record.mediaType = row["original_media_type"]
        record.fileSizeBytes = row["original_size_bytes"]
        record.parentSessionID = (row["parent_session_id"] as String?)
          .flatMap(UUID.init(uuidString:)).map(SessionID.init)
        record.frameMilliseconds = row["frame_ms"]
        if mode == .importedMedia {
          record.keyframes = try Self.memoryKeyframes(db, parentSessionID: id)
        }
        result[id] = record
      }
      return result
    }
    return unique.compactMap { records[$0.rawValue.uuidString] }
  }

  // MARK: - Helpers

  /// `model_artifact_id` of a screenshot's on-device reading.
  nonisolated static let userItemReadingArtifactID = "local-item-reading"

  private nonisolated static func validate(_ draft: UserItemDraft) throws {
    let prefix = "sessions/\(draft.id.rawValue.uuidString.lowercased())/source/"
    let roles = draft.attachments.map(\.role)
    if let reading = draft.reading {
      guard draft.kind == .image, !reading.reader.isEmpty, reading.reader.utf8.count <= 128,
        reading.text.utf8.count <= UserItemLimits.maximumStoredTextBytes,
        !reading.text.unicodeScalars.contains(where: { $0.value == 0 }),
        !reading.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw BestASRPersistenceError.invalidSnapshot }
    }
    guard draft.text.utf8.count <= UserItemLimits.maximumStoredTextBytes,
      !draft.text.unicodeScalars.contains(where: { $0.value == 0 }),
      !draft.extractor.isEmpty, draft.extractor.utf8.count <= 128,
      (draft.originalFilename?.utf8.count ?? 0) <= 1_024,
      (draft.source?.name.unicodeScalars.count ?? 0) <= 256,
      (draft.source?.bundleID?.utf8.count ?? 0) <= 1_024,
      Set(roles).count == roles.count,
      draft.attachments.allSatisfy({
        $0.relativePath.hasPrefix(prefix) && !$0.relativePath.contains("..")
          && $0.sizeBytes > 0 && !$0.mediaType.isEmpty && !$0.originalFilename.isEmpty
          && $0.originalFilename.utf8.count <= 1_024
      })
    else { throw BestASRPersistenceError.invalidSnapshot }
    guard (draft.uniformType?.utf8.count ?? 1) <= 256, draft.uniformType?.isEmpty != true,
      (draft.frameMilliseconds ?? 0) >= 0,
      (draft.parentSessionID == nil) == (draft.frameMilliseconds == nil),
      draft.parentSessionID == nil || (draft.kind == .image && draft.parentSessionID != draft.id)
    else { throw BestASRPersistenceError.invalidSnapshot }
    switch draft.kind {
    case .image:
      // The organizer reads only the normalized copy.
      guard roles.contains(.normalizedImage) else {
        throw BestASRPersistenceError.invalidSnapshot
      }
    case .file:
      // The file itself is the item; the text is whatever this Mac read.
      guard roles == [.original], !(draft.originalFilename ?? "").isEmpty else {
        throw BestASRPersistenceError.invalidSnapshot
      }
    case .text, .document:
      // A scanned PDF (PDFKit, at least one page, no text layer) is the one
      // item kept with empty text; it keeps its original file.
      guard roles.allSatisfy({ $0 == .original }),
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || (draft.isScanWithoutTextLayer && roles.contains(.original))
      else { throw BestASRPersistenceError.invalidSnapshot }
    }
  }

  nonisolated static func assetKind(_ role: UserItemAttachmentRole) -> RetainedSourceAssetKind {
    switch role {
    case .original: .userProvidedOriginal
    case .normalizedImage: .normalizedImage
    case .animationFrame1: .animationFrame1
    case .animationFrame2: .animationFrame2
    case .animationFrame3: .animationFrame3
    }
  }

  /// `config_hash` of an item's text revision names the local extractor.
  nonisolated static func extractorConfigHash(_ extractor: String) -> String {
    SHA256.hash(data: Data(extractor.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private nonisolated static func jsonIDs(_ ids: [SessionID]) throws -> String {
    let data = try JSONEncoder().encode(ids.map { $0.rawValue.uuidString })
    guard let json = String(data: data, encoding: .utf8) else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    return json
  }

  /// The keyframes taken from a recording, in time order.
  private nonisolated static func memoryKeyframes(
    _ db: Database, parentSessionID: String
  ) throws -> [MemoryItemRecord.Keyframe] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT d.session_id, d.frame_ms,
          (SELECT a.asset_reference FROM session_source_assets a
           WHERE a.session_id = d.session_id AND a.kind = 'normalizedImage'
           ORDER BY a.revision DESC, a.id LIMIT 1) AS thumbnail_reference
        FROM user_item_details d
        JOIN sessions s ON s.id = d.session_id AND s.state = 'completed'
        WHERE d.parent_session_id = ?
        ORDER BY d.frame_ms, d.session_id
        """,
      arguments: [parentSessionID]
    ).compactMap { row in
      guard let uuid = UUID(uuidString: row["session_id"]) else { return nil }
      return MemoryItemRecord.Keyframe(
        sessionID: SessionID(uuid), frameMilliseconds: row["frame_ms"] ?? 0,
        thumbnailAssetPath: row["thumbnail_reference"])
    }
  }

  private nonisolated static func memoryPeople(
    _ db: Database, sessionID: String
  ) throws -> [MemoryItemRecord.Person] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT p.id, p.display_name, p.created_at, MIN(o.monotonic_start_ns) AS first_ns
        FROM speaker_occurrences o JOIN persons p ON p.id = o.person_id
        WHERE o.session_id = ? AND p.retired_at IS NULL
          AND o.association_status IN ('anonymousIdentity', 'automaticMatch', 'userConfirmed')
        GROUP BY p.id
        ORDER BY first_ns, p.id
        """,
      arguments: [sessionID]
    ).compactMap { row in
      guard let uuid = UUID(uuidString: row["id"]) else { return nil }
      // An unnamed person keeps an empty name here; the memory pages and the
      // export show "?" for them (people are names or "?").
      let name = (row["display_name"] as String?)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return MemoryItemRecord.Person(id: PersonID(uuid), name: name)
    }
  }

  private nonisolated static func memorySegments(
    _ db: Database, sessionID: String, transcriptID: String,
    names: [PersonID: String]
  ) throws -> [MemoryItemRecord.Segment] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT ts.monotonic_start_ns, ts.monotonic_end_ns, ts.text,
          (SELECT o.person_id FROM speaker_occurrences o
           WHERE o.session_id = ? AND o.person_id IS NOT NULL
             AND o.association_status IN (
               'anonymousIdentity', 'automaticMatch', 'userConfirmed'
             )
             AND o.monotonic_start_ns < ts.monotonic_end_ns
             AND o.monotonic_end_ns > ts.monotonic_start_ns
           ORDER BY min(o.monotonic_end_ns, ts.monotonic_end_ns)
                  - max(o.monotonic_start_ns, ts.monotonic_start_ns) DESC,
                    o.id LIMIT 1) AS person_id
        FROM transcript_segments ts
        WHERE ts.transcript_id = ?
        ORDER BY ts.ordinal
        """,
      arguments: [sessionID, transcriptID]
    )
    let base = rows.map { $0["monotonic_start_ns"] as Int64 }.min() ?? 0
    return rows.map { row in
      let person = (row["person_id"] as String?).flatMap(UUID.init(uuidString:)).map(
        PersonID.init)
      let start: Int64 = row["monotonic_start_ns"]
      let end: Int64 = row["monotonic_end_ns"]
      return MemoryItemRecord.Segment(
        startMilliseconds: max(0, (start - base) / 1_000_000),
        endMilliseconds: max(0, (end - base) / 1_000_000),
        personID: person, personName: person.flatMap { names[$0] }, text: row["text"],
        monotonicStartNanoseconds: UInt64(clamping: max(0, start)),
        monotonicEndNanoseconds: UInt64(clamping: max(0, end))
      )
    }
  }
}

/// The facts an item has that a recording does not.
public struct UserItemDetails: Equatable, Sendable {
  public let sessionID: SessionID
  public let revision: UInt64
  public let kind: UserItemKind
  public let capturedAt: Date
  public let sourceOrigin: ItemSourceOrigin
  public let extractor: String
  public let pageCount: Int?
  public let pixelWidth: Int?
  public let pixelHeight: Int?
  public let originalAssetID: UUID?
  public let normalizedAssetID: UUID?
}
