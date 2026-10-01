import BestASRDomain
import CryptoKit
import Foundation
import GRDB

/// Local side of the own-device organizer link (PRD §0.3.7/§0.3.8).
///
/// Item jobs hold one row per session with a monotonic target revision. The
/// payload is rebuilt from the session's current committed content whenever a
/// send is claimed, so an edit, restore, re-recognition, speaker correction, or
/// person rename made before delivery is what leaves the Mac. Only sessions
/// recorded as eligible when their capture started (link enabled) are ever
/// tracked. Decisions are immutable source rows delivered strictly in local
/// commit order; a retry re-issues one at the end of that order.
extension GRDBDictationStore: RemoteOrganizerRepository {
  private nonisolated static let leaseSeconds: TimeInterval = 60
  private nonisolated static let maximumReasonLength = 200
  /// Unchanged or unsendable jobs looked at per claim transaction, so one
  /// claim never holds the single writer for long (capture commits wait on it).
  private nonisolated static let maximumSkipsPerClaim = 32

  // MARK: - Link lifecycle

  public func remoteLinkRecord() async throws -> RemoteOrganizerLinkRecord {
    let database = try requirePool()
    return try await database.read { db in
      RemoteOrganizerLinkRecord(
        enabledAt: try Self.remoteLinkEnabledAt(db),
        storeID: try Self.remoteMeta(db, "store_id")
      )
    }
  }

  public func enableRemoteLink(at date: Date) async throws {
    let database = try requirePool()
    try await database.write { db in
      // Nothing cancelled at a revoke is queued again: records already on the
      // Spark are sent again only when they change after this point (then
      // with their current content), and only captures started from now on
      // become eligible.
      if try Self.remoteLinkEnabledAt(db) == nil {
        try Self.setRemoteMeta(db, "link_enabled_at", String(date.timeIntervalSince1970))
      }
    }
  }

  public func revokeRemoteLink() async throws {
    let database = try requirePool()
    try await database.write { db in try Self.revokeRemoteLinkRows(db) }
  }

  /// Revocation in the caller's transaction (also used by portable import).
  nonisolated static func revokeRemoteLinkRows(_ db: Database) throws {
    try db.execute(sql: "DELETE FROM remote_organizer_meta WHERE key = 'link_enabled_at'")
    // An item whose send was attempted but never confirmed may be on the
    // organizing device: remember that (content-free), so deleting it later
    // still sends the deletion (privacy review F14).
    try db.execute(
      sql: """
        INSERT INTO remote_organizer_meta (key, value)
        SELECT ? || item_id, CAST(? AS TEXT) FROM remote_organizer_item_jobs
        WHERE delivered_revision IS NULL AND attempted_revision IS NOT NULL
        ON CONFLICT(key) DO NOTHING
        """,
      arguments: [maybeOnOrganizerMetaPrefix, Date().timeIntervalSince1970])
    // Never-delivered items are forgotten together with their eligibility, so
    // they are never sent automatically, not even after re-enabling.
    try db.execute(
      sql: "DELETE FROM remote_organizer_item_jobs WHERE delivered_revision IS NULL"
    )
    // Pending updates of delivered items are cancelled: re-enabling does not
    // send them. Attempted revision numbers stay burned, and a change made
    // after re-enabling sends the then-current content as a new revision.
    try db.execute(
      sql: """
        UPDATE remote_organizer_item_jobs
        SET state = 'delivered', lease_expires_at = NULL, not_before = 0,
            retry_count = 0, error_category = 'none'
        WHERE state <> 'delivered'
        """
    )
    try db.execute(
      sql: """
        DELETE FROM remote_organizer_eligible
        WHERE session_id NOT IN (SELECT item_id FROM remote_organizer_item_jobs)
        """
    )
    // A decision that was in flight (or already attempted) may have been
    // applied by the Spark: it is marked delivery-unknown, not "not sent".
    try db.execute(
      sql: """
        UPDATE remote_organizer_decision_jobs
        SET error_category = CASE
              WHEN state = 'running' OR retry_count > 0 THEN 'in_flight' ELSE 'revoked'
            END,
            state = 'cancelled', lease_expires_at = NULL, error_reason = NULL
        WHERE state IN ('queued', 'running')
        """
    )
  }

  /// The live capture path's explicit grant, right after it created the
  /// session (`DictationCaptureCoordinator`, the in-app media import). A
  /// session created any other way (the Typeless history import, archive
  /// import) never becomes eligible.
  public func markLiveCaptureRemoteEligible(sessionID: SessionID) async throws {
    let id = sessionID.rawValue.uuidString
    let database = try requirePool()
    try await database.write { db in
      guard
        let mode = try String.fetchOne(
          db, sql: "SELECT input_mode FROM sessions WHERE id = ?", arguments: [id])
      else { throw BestASRPersistenceError.missingSession }
      // Items are granted inside `createUserItem`'s own transaction.
      guard mode != SessionInputMode.userItem.rawValue else { return }
      try Self.markRemoteEligibleIfLinkEnabled(
        db, sessionID: id, at: Date().timeIntervalSince1970)
    }
  }

  /// Records eligibility in the caller's transaction, only if the link is
  /// enabled right now. Callers: `markLiveCaptureRemoteEligible` and
  /// `createUserItem`.
  nonisolated static func markRemoteEligibleIfLinkEnabled(
    _ db: Database, sessionID: String, at date: Double
  ) throws {
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO remote_organizer_eligible (session_id, eligible_at)
        SELECT ?, ?
        WHERE EXISTS (SELECT 1 FROM remote_organizer_meta WHERE key = 'link_enabled_at')
        """,
      arguments: [sessionID, date]
    )
  }

  /// Portable import: restored decisions get visible, never-sent jobs. They
  /// are listed as not sent and leave the Mac only if the user retries one.
  nonisolated static func markImportedRemoteDecisions(_ db: Database) throws {
    try insertJobsForOrphanDecisions(db, linkEnabled: false, category: "imported")
  }

  // MARK: - Items

  public func enqueueRemoteSession(sessionID: SessionID) async throws -> Bool {
    let database = try requirePool()
    let id = sessionID.rawValue.uuidString
    return try await database.write { db in
      guard try Self.remoteLinkEnabledAt(db) != nil,
        try Self.isRemoteEligible(db, sessionID: id),
        let createdAt = try Self.completedSessionCreatedAt(db, sessionID: id)
      else { return false }
      if try Self.remoteItemJobExists(db, itemID: id) {
        try Self.markRemoteItemChanged(db, itemID: id)
        return true
      }
      try Self.insertRemoteItemJob(db, itemID: id, createdAt: createdAt)
      return true
    }
  }

  public func reconcileRemoteItems() async throws -> Int {
    let database = try requirePool()
    return try await database.write { db in
      guard try Self.remoteLinkEnabledAt(db) != nil else { return 0 }
      // Eligibility was recorded when each capture started with the link on;
      // imported rows and captures made while the link was off never have it.
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT s.id, s.created_at
          FROM sessions s
          JOIN remote_organizer_eligible e ON e.session_id = s.id
          JOIN dictation_snapshots ds ON ds.session_id = s.id
          WHERE s.state = 'completed' AND ds.phase = 'completed'
            AND NOT EXISTS (
              SELECT 1 FROM remote_organizer_item_jobs j WHERE j.item_id = s.id
            )
          ORDER BY s.created_at, s.id
          """
      )
      for row in rows {
        try Self.insertRemoteItemJob(db, itemID: row["id"], createdAt: row["created_at"])
      }
      return rows.count
    }
  }

  public func claimNextRemoteItem(now: Date = Date()) async throws
    -> RemoteOrganizerItemDelivery?
  {
    let database = try requirePool()
    let nowValue = now.timeIntervalSince1970
    let timeZone = remoteItemTimeZone
    return try await database.write { db in
      guard try Self.remoteLinkEnabledAt(db) != nil else { return nil }
      for _ in 0..<Self.maximumSkipsPerClaim {
        guard
          let row = try Row.fetchOne(
            db,
            sql: """
              SELECT j.item_id, j.target_revision, j.change_seq, j.attempted_revision,
                     j.attempted_sha256, j.delivered_revision, j.delivered_sha256,
                     j.retry_count
              FROM remote_organizer_item_jobs j
              WHERE ((j.state = 'queued' AND j.not_before <= ?)
                 OR (j.state = 'running' AND j.lease_expires_at <= ?))
                AND EXISTS (
                  SELECT 1 FROM remote_organizer_eligible e WHERE e.session_id = j.item_id
                )
              ORDER BY j.created_at, j.item_id
              LIMIT 1
              """,
            arguments: [nowValue, nowValue]
          )
        else { return nil }
        let itemID: String = row["item_id"]
        guard let itemUUID = UUID(uuidString: itemID),
          let content = try Self.remoteItemContent(db, itemID: itemID, timeZone: timeZone)
        else {
          // Emptied, oversized, or otherwise not sendable right now. The row
          // (with its burned revision numbers) stays, parked until the next
          // change to the session queues it again; only explicit deletion
          // removes it.
          try db.execute(
            sql: """
              UPDATE remote_organizer_item_jobs
              SET state = 'failed', error_category = 'unsendable',
                  lease_expires_at = NULL, retry_count = 0, updated_at = ?
              WHERE item_id = ?
              """,
            arguments: [nowValue, itemID]
          )
          continue
        }
        let digest = try Self.remoteDigest(Self.remoteJSON(content.withRevision(0)))
        var target: Int64 = row["target_revision"]
        let deliveredRevision: Int64? = row["delivered_revision"]
        let deliveredDigest: String? = row["delivered_sha256"]
        if deliveredRevision == target, deliveredDigest == digest {
          // Unchanged since the Spark acknowledged this revision.
          try db.execute(
            sql: """
              UPDATE remote_organizer_item_jobs
              SET state = 'delivered', lease_expires_at = NULL, updated_at = ?
              WHERE item_id = ?
              """,
            arguments: [nowValue, itemID]
          )
          continue
        }
        let attemptedRevision: Int64? = row["attempted_revision"]
        let attemptedDigest: String? = row["attempted_sha256"]
        if let attemptedRevision, attemptedRevision >= target,
          attemptedDigest != digest
        {
          // The Spark may already hold different content under this revision;
          // a same-revision resend would be dropped as a duplicate.
          target = attemptedRevision + 1
        }
        let changeSequence: Int64 = row["change_seq"]
        try db.execute(
          sql: """
            UPDATE remote_organizer_item_jobs
            SET target_revision = ?, state = 'running', lease_expires_at = ?,
                claimed_change_seq = ?, attempted_revision = ?,
                attempted_sha256 = ?, error_category = 'none', updated_at = ?
            WHERE item_id = ?
            """,
          arguments: [
            target, now.addingTimeInterval(Self.leaseSeconds).timeIntervalSince1970,
            changeSequence, target, digest, nowValue, itemID,
          ]
        )
        return RemoteOrganizerItemDelivery(
          itemID: itemUUID, revision: target,
          payload: try Self.remoteJSON(content.withRevision(target)),
          contentSHA256: digest, claimedChangeSequence: changeSequence,
          retryCount: row["retry_count"]
        )
      }
      // Bounded work per transaction; the rest is looked at by the next claim.
      return nil
    }
  }

  public func markRemoteItemDelivered(_ delivery: RemoteOrganizerItemDelivery) async throws {
    let database = try requirePool()
    let now = Date().timeIntervalSince1970
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE remote_organizer_item_jobs
          SET delivered_revision = ?, delivered_sha256 = ?, delivered_at = ?,
              lease_expires_at = NULL, retry_count = 0, error_category = 'none',
              not_before = 0, updated_at = ?,
              state = CASE WHEN change_seq > ? THEN 'queued' ELSE 'delivered' END
          WHERE item_id = ? AND state = 'running' AND attempted_revision = ?
          """,
        arguments: [
          delivery.revision, delivery.contentSHA256, now, now,
          delivery.claimedChangeSequence, delivery.itemID.uuidString,
          delivery.revision,
        ]
      )
    }
  }

  public func markRemoteItemFailed(
    _ delivery: RemoteOrganizerItemDelivery, category: String, retryAt: Date?
  ) async throws {
    let database = try requirePool()
    let now = Date().timeIntervalSince1970
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE remote_organizer_item_jobs
          SET state = CASE
                WHEN ? THEN 'queued'
                WHEN change_seq > ? THEN 'queued'
                ELSE 'failed'
              END,
              retry_count = retry_count + 1, error_category = ?,
              not_before = ?, lease_expires_at = NULL, updated_at = ?
          WHERE item_id = ? AND state = 'running'
          """,
        arguments: [
          retryAt != nil, delivery.claimedChangeSequence, category,
          retryAt?.timeIntervalSince1970 ?? 0, now, delivery.itemID.uuidString,
        ]
      )
    }
  }

  // MARK: - Decisions

  public func enqueueRemoteDecision(_ decision: RemoteOrganizerDecision) async throws {
    guard decision.isWellFormed,
      decision.questionID == nil
        || (decision.kind == "same_event" || decision.kind == "same_person")
    else { throw BestASRPersistenceError.invalidSnapshot }
    let jobKind: RemoteOrganizerDecisionJobKind =
      decision.questionID == nil ? .decision : .question
    let payload = try Self.remoteJSON(decision)
    let database = try requirePool()
    try await database.write { db in
      if let existing = try Data.fetchOne(
        db,
        sql: "SELECT payload_json FROM remote_organizer_decisions WHERE id = ?",
        arguments: [decision.decisionID.uuidString]
      ) {
        guard existing == payload else {
          throw BestASRPersistenceError.processingCommitConflict
        }
        return
      }
      // A decision recorded while the link is off is kept and shown, but it
      // is never sent unless the user retries it.
      let linkEnabled = try Self.remoteLinkEnabledAt(db) != nil
      try Self.insertDecision(
        db, decision, payload: payload, jobKind: jobKind,
        state: linkEnabled ? "queued" : "cancelled",
        category: linkEnabled ? "none" : "revoked"
      )
    }
  }

  /// Appends a decision at the end of the local commit order (never before an
  /// existing one, even if the wall clock moved backwards) with its job, tied
  /// to the Spark store the user was looking at.
  private nonisolated static func insertDecision(
    _ db: Database, _ decision: RemoteOrganizerDecision, payload: Data,
    jobKind: RemoteOrganizerDecisionJobKind, state: String, category: String
  ) throws {
    let latest =
      try Double.fetchOne(db, sql: "SELECT MAX(created_at) FROM remote_organizer_decisions")
      ?? 0
    let createdAt = max(Date().timeIntervalSince1970, latest)
    try db.execute(
      sql: """
        INSERT INTO remote_organizer_decisions (id, payload_json, created_at)
        VALUES (?, ?, ?)
        """,
      arguments: [decision.decisionID.uuidString, payload, createdAt]
    )
    try db.execute(
      sql: """
        INSERT INTO remote_organizer_decision_jobs (
          decision_id, kind, state, error_category, created_at, store_id
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        decision.decisionID.uuidString, jobKind.rawValue, state, category, createdAt,
        try remoteMeta(db, "store_id"),
      ]
    )
  }

  public func recoverRemoteDecisionsToOutbox() async throws -> Int {
    let database = try requirePool()
    return try await database.write { db in
      let linkEnabled = try Self.remoteLinkEnabledAt(db) != nil
      return try Self.insertJobsForOrphanDecisions(
        db, linkEnabled: linkEnabled, category: linkEnabled ? "none" : "revoked"
      )
    }
  }

  /// Adds jobs for decision rows that have none, in their stored order.
  /// Undecodable rows are quarantined as rejected ("corrupt") so they never
  /// stop recovery.
  @discardableResult
  private nonisolated static func insertJobsForOrphanDecisions(
    _ db: Database, linkEnabled: Bool, category: String
  ) throws -> Int {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT d.id, d.payload_json, d.created_at
        FROM remote_organizer_decisions d
        LEFT JOIN remote_organizer_decision_jobs j ON j.decision_id = d.id
        WHERE j.decision_id IS NULL
        ORDER BY d.created_at, d.rowid
        """
    )
    let storeID = try remoteMeta(db, "store_id")
    for row in rows {
      let id: String = row["id"]
      let payload: Data? = row["payload_json"]
      let decision = payload.flatMap {
        try? JSONDecoder().decode(RemoteOrganizerDecision.self, from: $0)
      }
      let sendable =
        decision.map { $0.decisionID.uuidString == id && $0.isWellFormed } ?? false
      let state = !sendable ? "failed" : linkEnabled ? "queued" : "cancelled"
      try db.execute(
        sql: """
          INSERT INTO remote_organizer_decision_jobs (
            decision_id, kind, state, error_category, created_at, store_id
          ) VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          id, decision?.questionID == nil ? "decision" : "question",
          state, sendable ? category : "corrupt", row["created_at"] as Double, storeID,
        ]
      )
    }
    return rows.count
  }

  public func resetRemoteLeases() async throws {
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE remote_organizer_item_jobs
          SET state = 'queued', lease_expires_at = NULL WHERE state = 'running'
          """
      )
      try db.execute(
        sql: """
          UPDATE remote_organizer_decision_jobs
          SET state = 'queued', lease_expires_at = NULL WHERE state = 'running'
          """
      )
    }
  }

  public func claimNextRemoteDecision(now: Date = Date()) async throws
    -> RemoteOrganizerDecisionDelivery?
  {
    let database = try requirePool()
    let nowValue = now.timeIntervalSince1970
    return try await database.write { db in
      guard try Self.remoteLinkEnabledAt(db) != nil else { return nil }
      while true {
        // Strict local commit order: only the earliest undelivered decision
        // may be sent. While it is in flight or backing off, later ones wait.
        guard
          let row = try Row.fetchOne(
            db,
            sql: """
              SELECT j.decision_id, j.kind, j.state, j.not_before,
                     j.lease_expires_at, j.retry_count, d.payload_json
              FROM remote_organizer_decision_jobs j
              LEFT JOIN remote_organizer_decisions d ON d.id = j.decision_id
              WHERE j.state IN ('queued', 'running')
              ORDER BY j.created_at, COALESCE(d.rowid, 0), j.decision_id
              LIMIT 1
              """
          )
        else { return nil }
        let id: String = row["decision_id"]
        let state: String = row["state"]
        if state == "queued", (row["not_before"] as Double) > nowValue { return nil }
        if state == "running" {
          let lease: Double? = row["lease_expires_at"]
          guard let lease, lease <= nowValue else { return nil }
        }
        let payload: Data? = row["payload_json"]
        guard
          let decision = payload.flatMap({
            try? JSONDecoder().decode(RemoteOrganizerDecision.self, from: $0)
          }),
          decision.decisionID.uuidString == id,
          let kind = RemoteOrganizerDecisionJobKind(rawValue: row["kind"])
        else {
          try db.execute(
            sql: """
              UPDATE remote_organizer_decision_jobs
              SET state = 'failed', error_category = 'corrupt',
                  lease_expires_at = NULL
              WHERE decision_id = ?
              """,
            arguments: [id]
          )
          continue
        }
        try db.execute(
          sql: """
            UPDATE remote_organizer_decision_jobs
            SET state = 'running', lease_expires_at = ?, error_category = 'none',
                error_reason = NULL
            WHERE decision_id = ?
            """,
          arguments: [
            now.addingTimeInterval(Self.leaseSeconds).timeIntervalSince1970, id,
          ]
        )
        return RemoteOrganizerDecisionDelivery(
          decision: decision, kind: kind, retryCount: row["retry_count"]
        )
      }
    }
  }

  public func markRemoteDecisionDelivered(id: UUID) async throws {
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE remote_organizer_decision_jobs
          SET state = 'delivered', lease_expires_at = NULL, delivered_at = ?,
              error_category = 'none', error_reason = NULL
          WHERE decision_id = ? AND state = 'running'
          """,
        arguments: [Date().timeIntervalSince1970, id.uuidString]
      )
    }
  }

  public func markRemoteDecisionFailed(
    id: UUID, category: String, reason: String?, retryAt: Date?
  ) async throws {
    let database = try requirePool()
    let boundedReason = reason.map { String($0.prefix(Self.maximumReasonLength)) }
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE remote_organizer_decision_jobs
          SET state = ?, retry_count = retry_count + 1, error_category = ?,
              error_reason = ?, not_before = ?, lease_expires_at = NULL
          WHERE decision_id = ? AND state = 'running'
          """,
        arguments: [
          retryAt == nil ? "failed" : "queued", category, boundedReason,
          retryAt?.timeIntervalSince1970 ?? 0, id.uuidString,
        ]
      )
    }
  }

  public func retryRemoteDecision(id: UUID) async throws {
    let database = try requirePool()
    try await database.write { db in
      guard try Self.remoteLinkEnabledAt(db) != nil else {
        throw BestASRPersistenceError.invalidSnapshot
      }
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT j.state, j.error_category, d.payload_json
            FROM remote_organizer_decision_jobs j
            JOIN remote_organizer_decisions d ON d.id = j.decision_id
            WHERE j.decision_id = ?
            """,
          arguments: [id.uuidString]
        ),
        ["failed", "cancelled"].contains(row["state"] as String)
      else { return }
      // A delivery-unknown decision ("确认送达") is re-issued the same way as a
      // rejected or unsent one: the Spark may already have applied it at its
      // old position, but resending it under its old ID at that position would
      // let the Spark apply it after corrections delivered since (a pin
      // re-applied after a later unpin) while the overlay replays it before
      // them. Re-issued at the end, the Spark and the overlay both end with
      // it; a possible duplicate is harmless because every decision kind sets
      // a state (pin, title, membership, merge) rather than toggling one.
      let payload: Data = row["payload_json"]
      guard
        let decision = try? JSONDecoder().decode(RemoteOrganizerDecision.self, from: payload),
        decision.decisionID == id, decision.isWellFormed
      else { throw BestASRPersistenceError.storedDataCorrupt }
      // The Spark keeps a receipt per decision ID and would replay the old
      // rejection, so the correction is re-issued under a new ID, as a plain
      // decision (never a second question answer), at the end of the commit
      // order so the local overlay applies it in the order it is sent.
      let reissued = decision.reissued()
      try db.execute(
        sql: "DELETE FROM remote_organizer_decision_jobs WHERE decision_id = ?",
        arguments: [id.uuidString]
      )
      try db.execute(
        sql: "DELETE FROM remote_organizer_decisions WHERE id = ?",
        arguments: [id.uuidString]
      )
      try Self.insertDecision(
        db, reissued, payload: try Self.remoteJSON(reissued), jobKind: .decision,
        state: "queued", category: "none"
      )
    }
  }

  public func discardRemoteDecision(id: UUID) async throws {
    let database = try requirePool()
    try await database.write { db in
      // Only a decision the Spark certainly did not take can be discarded; a
      // delivered, in-flight, or delivery-unknown one may be permanent there.
      try db.execute(
        sql: """
          DELETE FROM remote_organizer_decision_jobs
          WHERE decision_id = ? AND state IN ('failed', 'cancelled')
            AND error_category <> 'in_flight'
          """,
        arguments: [id.uuidString]
      )
      guard db.changesCount > 0 else { return }
      try db.execute(
        sql: "DELETE FROM remote_organizer_decisions WHERE id = ?",
        arguments: [id.uuidString]
      )
      try db.execute(
        sql: "DELETE FROM remote_mask_map WHERE owner_id = ?", arguments: [id.uuidString])
    }
  }

  // MARK: - Projection

  public func remoteCursor() async throws -> Int64 {
    let database = try requirePool()
    return try await database.read { db in try Self.remoteStoredCursor(db) }
  }

  public func observeRemoteStoreID(_ storeID: String) async throws -> Bool {
    let database = try requirePool()
    return try await database.write { db in
      try Self.applyRemoteStoreIdentity(db, storeID: storeID)
    }
  }

  public func applyRemoteState(_ state: RemoteOrganizerState) async throws -> Bool {
    guard state.cursor >= 0 else { throw BestASRPersistenceError.invalidSnapshot }
    let database = try requirePool()
    return try await database.write { db in
      if let storeID = state.storeID,
        try Self.applyRemoteStoreIdentity(db, storeID: storeID)
      {
        return true
      }
      guard state.cursor >= (try Self.remoteStoredCursor(db)) else {
        // A cursor that moves backwards means the Spark's store was recreated
        // (an older service that does not report its store identity).
        try Self.resetRemoteMirror(db, newStoreID: nil)
        return true
      }
      for event in state.events {
        try db.execute(
          sql: """
            INSERT INTO remote_organizer_events (event_id, payload_json)
            VALUES (?, ?)
            ON CONFLICT(event_id) DO UPDATE SET payload_json = excluded.payload_json
            """,
          arguments: [event.eventID, try Self.remoteJSON(event)]
        )
      }
      for person in state.persons {
        try db.execute(
          sql: """
            INSERT INTO remote_organizer_persons (person_id, payload_json)
            VALUES (?, ?)
            ON CONFLICT(person_id) DO UPDATE SET payload_json = excluded.payload_json
            """,
          arguments: [person.personID, try Self.remoteJSON(person)]
        )
      }
      // The service returns the complete open-question set on every pull.
      try db.execute(sql: "DELETE FROM remote_organizer_questions")
      for question in state.questions {
        try db.execute(
          sql: """
            INSERT INTO remote_organizer_questions (question_id, payload_json)
            VALUES (?, ?)
            """,
          arguments: [question.questionID, try Self.remoteJSON(question)]
        )
      }
      // Also the complete set on every pull; an older service omits it.
      try Self.setRemoteMeta(
        db, Self.unfiledMetaKey,
        String(decoding: try Self.remoteJSON(state.unfiled ?? []), as: UTF8.self))
      if let readings = state.readings, !readings.isEmpty {
        try Self.mergeRemoteReadings(db, readings)
      }
      try Self.setRemoteMeta(db, "cursor", String(state.cursor))
      return false
    }
  }

  public func remoteProjection() async throws -> RemoteOrganizerProjection {
    let database = try requirePool()
    return try await database.read { db in
      let cursor = try Self.remoteStoredCursor(db)
      let eventData = try Data.fetchAll(
        db, sql: "SELECT payload_json FROM remote_organizer_events"
      )
      let personData = try Data.fetchAll(
        db, sql: "SELECT payload_json FROM remote_organizer_persons"
      )
      let questionData = try Data.fetchAll(
        db, sql: "SELECT payload_json FROM remote_organizer_questions"
      )
      // Every stored user decision stays in effect locally whatever its
      // delivery state; one the Spark did not take is also listed as an issue
      // until the user retries or discards it.
      let decisionRows = try Row.fetchAll(
        db,
        sql: """
          SELECT d.id, d.payload_json, j.state, j.error_category, j.error_reason
          FROM remote_organizer_decisions d
          LEFT JOIN remote_organizer_decision_jobs j ON j.decision_id = d.id
          ORDER BY d.created_at, d.rowid
          """
      )
      let personScopedKinds: Set<String> = ["name_person", "same_person"]
      // What the organizing device wrote carries placeholders; the Mac shows
      // and exports the originals (contract §3).
      let unmask = try Self.remoteUnmasker(db)
      let offsets = try Self.remoteMaskOffsets(db)
      var events = try eventData.map {
        try JSONDecoder().decode(RemoteOrganizerEvent.self, from: $0)
          .unmasked(unmask, offsets: { offsets[$0] })
      }
      var persons = try personData.map {
        try JSONDecoder().decode(RemoteOrganizerPerson.self, from: $0).unmasked(unmask)
      }
      var questions = try questionData.map {
        try JSONDecoder().decode(RemoteOrganizerQuestion.self, from: $0).unmasked(unmask)
      }
      var decisions: [RemoteOrganizerDecision] = []
      var issues: [RemoteOrganizerDecisionIssue] = []
      for row in decisionRows {
        let payload: Data = row["payload_json"]
        let state: String? = row["state"]
        let category = (row["error_category"] as String?) ?? "none"
        let decision = try? JSONDecoder().decode(
          RemoteOrganizerDecision.self, from: payload
        )
        // A correction about an event, item, or question of a Spark store that
        // was since reset no longer applies to what the Spark shows.
        if let decision,
          category != "store_reset" || personScopedKinds.contains(decision.kind)
        {
          decisions.append(decision)
        }
        let issueState: RemoteOrganizerDecisionIssue.State? =
          switch (state, category) {
          case ("failed"?, _): .rejected
          case ("cancelled"?, "in_flight"): .deliveryUnknown
          case ("cancelled"?, _): .notSent
          default: nil
          }
        if let issueState, let id = UUID(uuidString: row["id"]) {
          issues.append(
            RemoteOrganizerDecisionIssue(
              decisionID: id, kind: decision?.kind ?? "unknown", state: issueState,
              errorCategory: category,
              reason: row["error_reason"]
            )
          )
        }
      }
      let answered = Set(decisions.compactMap(\.questionID))
      questions.removeAll { answered.contains($0.questionID) }
      var unfiled =
        try Self.remoteMeta(db, Self.unfiledMetaKey).flatMap {
          try? JSONDecoder().decode([RemoteOrganizerUnfiledItem].self, from: Data($0.utf8))
        } ?? []
      var provisional: [String: RemoteOrganizerEvent] = [:]
      for decision in decisions where decision.kind == "file_item_new_event" {
        guard let itemID = decision.itemID, let eventID = decision.newEventID else { continue }
        provisional[eventID.lowercased()] = try Self.provisionalEvent(
          db, eventID: eventID.lowercased(), itemID: itemID)
      }
      let heldItems = Set(events.filter { !$0.itemIDs.isEmpty }.map(\.eventID))
      Self.applyLocalRemoteDecisions(
        decisions, events: &events, persons: &persons, unfiled: &unfiled,
        provisionalEvents: provisional)
      // An event the user's own corrections emptied is gone for them now;
      // the Spark retires it on its next brief.
      events = events.filter {
        !$0.deleted && !($0.itemIDs.isEmpty && heldItems.contains($0.eventID))
      }.sorted {
        if $0.pinned != $1.pinned { return $0.pinned }
        if $0.importance != $1.importance { return $0.importance > $1.importance }
        return ($0.updatedAt ?? "") > ($1.updatedAt ?? "")
      }
      let current = try Self.currentRemoteReadings(db).mapValues { $0.unmasked(unmask) }
      return RemoteOrganizerProjection(
        cursor: cursor, events: events, questions: questions,
        persons: persons.sorted { $0.personID < $1.personID },
        unacceptedDecisions: issues, unfiled: unfiled,
        readings: current.mapValues(\.text),
        readingSummaries: current.compactMapValues(\.summary),
        readingFacts: current.compactMapValues(\.facts)
      )
    }
  }

  // MARK: - Privacy (contract v6)

  public func recordRemoteMasks(_ record: RemoteOrganizerMaskRecord) async throws {
    let database = try requirePool()
    let now = Date().timeIntervalSince1970
    let offsets = try record.textOffsets.map { try Self.remoteJSON($0) }
    try await database.write { db in
      // The latest send of this item or decision replaces what it masked.
      try db.execute(
        sql: "DELETE FROM remote_mask_map WHERE owner_id = ?", arguments: [record.ownerID])
      for entry in record.entries {
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO remote_mask_map
              (owner_id, placeholder, original, mask_type, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
          arguments: [record.ownerID, entry.placeholder, entry.original, entry.type, now])
      }
      guard let offsets else { return }
      if record.textOffsets?.isEmpty == false {
        try db.execute(
          sql: """
            INSERT INTO remote_mask_offsets (item_id, revision, offsets_json) VALUES (?, ?, ?)
            ON CONFLICT(item_id) DO UPDATE SET
              revision = excluded.revision, offsets_json = excluded.offsets_json
            """,
          arguments: [
            record.ownerID.uppercased(), record.revision ?? 0,
            String(decoding: offsets, as: UTF8.self),
          ])
      } else {
        try db.execute(
          sql: "DELETE FROM remote_mask_offsets WHERE item_id = ?",
          arguments: [record.ownerID.uppercased()])
      }
    }
  }

  public func claimNextRemoteDeletion(now: Date = Date()) async throws -> String? {
    let database = try requirePool()
    return try await database.read { db in
      guard try Self.remoteLinkEnabledAt(db) != nil else { return nil }
      return try String.fetchOne(
        db,
        sql: """
          SELECT item_id FROM remote_pending_deletions WHERE not_before <= ?
          ORDER BY queued_at, item_id LIMIT 1
          """,
        arguments: [now.timeIntervalSince1970])
    }
  }

  public func markRemoteDeletionSent(itemID: String) async throws {
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: "DELETE FROM remote_pending_deletions WHERE item_id = ?", arguments: [itemID])
    }
  }

  public func markRemoteDeletionFailed(itemID: String, retryAt: Date) async throws {
    let database = try requirePool()
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE remote_pending_deletions
          SET not_before = ?, retry_count = retry_count + 1 WHERE item_id = ?
          """,
        arguments: [retryAt.timeIntervalSince1970, itemID])
    }
  }

  /// Deletions still waiting to be sent (for status and tests).
  public func pendingRemoteDeletions() async throws -> [String] {
    let database = try requirePool()
    return try await database.read { db in
      try String.fetchAll(
        db, sql: "SELECT item_id FROM remote_pending_deletions ORDER BY queued_at, item_id")
    }
  }

  public func forgetRemoteStore() async throws {
    let database = try requirePool()
    let now = Date().timeIntervalSince1970
    try await database.write { db in
      // The organizing device holds nothing of this library any more.
      try db.execute(sql: "DELETE FROM remote_organizer_events")
      try db.execute(sql: "DELETE FROM remote_organizer_persons")
      try db.execute(sql: "DELETE FROM remote_organizer_questions")
      try db.execute(
        sql: "DELETE FROM remote_organizer_meta WHERE key IN (?, ?, 'store_id')",
        arguments: [Self.unfiledMetaKey, Self.readingsMetaKey])
      try Self.setRemoteMeta(db, "cursor", "0")
      // Nothing counts as delivered, so a store reset does not queue it again
      // and no deletion is sent for it; a later change sends it anew. A job
      // parked or waiting stays so.
      try db.execute(
        sql: """
          UPDATE remote_organizer_item_jobs
          SET delivered_revision = NULL, delivered_sha256 = NULL, delivered_at = NULL,
              attempted_revision = NULL, attempted_sha256 = NULL,
              state = CASE state WHEN 'running' THEN 'queued' ELSE state END,
              lease_expires_at = NULL, updated_at = ?
          """,
        arguments: [now])
      try db.execute(sql: "DELETE FROM remote_pending_deletions")
      try db.execute(
        sql: "DELETE FROM remote_organizer_meta WHERE key LIKE ? || '%'",
        arguments: [Self.maybeOnOrganizerMetaPrefix])
      try db.execute(sql: "DELETE FROM remote_mask_map")
      try db.execute(sql: "DELETE FROM remote_mask_offsets")
      // Corrections were about the forgotten content: pending ones are not
      // sent, and those about its events and items leave the local overlay.
      // A person's name stays in effect here (person IDs are the same in
      // every store) but is not sent again by itself.
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT j.decision_id, j.state, d.payload_json
          FROM remote_organizer_decision_jobs j
          JOIN remote_organizer_decisions d ON d.id = j.decision_id
          """)
      for row in rows {
        let state: String = row["state"]
        let payload: Data = row["payload_json"]
        let personScoped =
          (try? JSONDecoder().decode(RemoteOrganizerDecision.self, from: payload))?
          .isPersonScoped ?? false
        guard !personScoped || ["queued", "running"].contains(state) else { continue }
        try db.execute(
          sql: """
            UPDATE remote_organizer_decision_jobs
            SET state = CASE WHEN state IN ('queued', 'running') THEN 'cancelled' ELSE state END,
                error_category = 'store_reset', lease_expires_at = NULL, error_reason = NULL
            WHERE decision_id = ?
            """,
          arguments: [row["decision_id"] as String])
      }
    }
  }

  /// A user deletion in the caller's transaction: queues the deletion on the
  /// organizing device when the item may be there (it was sent at least
  /// once), and drops what its sends masked.
  nonisolated static func queueRemoteDeletion(_ db: Database, itemID: String, at date: Double)
    throws
  {
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO remote_pending_deletions (item_id, queued_at)
        SELECT item_id, ? FROM remote_organizer_item_jobs
        WHERE item_id = ? AND (delivered_revision IS NOT NULL OR attempted_revision IS NOT NULL)
        """,
      arguments: [date, itemID])
    // An item whose unconfirmed send was dropped by a revocation or an archive
    // import (privacy review F14).
    let maybeKey = maybeOnOrganizerMetaPrefix + itemID
    if try Bool.fetchOne(
      db, sql: "SELECT 1 FROM remote_organizer_meta WHERE key = ?", arguments: [maybeKey]) == true
    {
      try db.execute(
        sql: "INSERT OR IGNORE INTO remote_pending_deletions (item_id, queued_at) VALUES (?, ?)",
        arguments: [itemID, date])
      try db.execute(sql: "DELETE FROM remote_organizer_meta WHERE key = ?", arguments: [maybeKey])
    }
    try db.execute(sql: "DELETE FROM remote_mask_map WHERE owner_id = ?", arguments: [itemID])
    try db.execute(
      sql: "DELETE FROM remote_mask_offsets WHERE item_id = ?", arguments: [itemID.uppercased()])
  }

  /// Resolves a placeholder to the one original it stands for in this
  /// library; one that stands for none, or (a 24-bit tag collision) for
  /// several, is shown without its tag.
  private nonisolated static func remoteUnmasker(_ db: Database) throws -> (String) -> String {
    var originals: [String: Set<String>] = [:]
    for row in try Row.fetchAll(
      db, sql: "SELECT DISTINCT placeholder, original FROM remote_mask_map")
    {
      originals[row["placeholder"], default: []].insert(row["original"])
    }
    return { text in
      PrivacyUnmask.unmask(text) { placeholder in
        guard let values = originals[placeholder], values.count == 1 else { return nil }
        return values.first
      }
    }
  }

  private nonisolated static func remoteMaskOffsets(_ db: Database) throws
    -> [String: [PrivacyMaskOffset]]
  {
    var result: [String: [PrivacyMaskOffset]] = [:]
    for row in try Row.fetchAll(db, sql: "SELECT item_id, offsets_json FROM remote_mask_offsets") {
      let json: String = row["offsets_json"]
      if let offsets = try? JSONDecoder().decode([PrivacyMaskOffset].self, from: Data(json.utf8)) {
        result[(row["item_id"] as String).uppercased()] = offsets
      }
    }
    return result
  }

  // MARK: - Helpers

  /// Content of a completed session as the Spark may see it: final/user-edit
  /// text, segments with person IDs, person display names, and App source.
  /// No capture asset, dictionary, embedding, or window title is read.
  private nonisolated static func remoteItemContent(
    _ db: Database, itemID: String, timeZone: TimeZone = .current
  ) throws -> RemoteOrganizerItem? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT s.input_mode, s.created_at,
                 m.source_bundle_id, m.source_display_name, m.source_identifier,
                 tr.id AS transcript_id, tr.content, uid.item_kind,
                 uid.uniform_type, uid.parent_session_id, uid.frame_ms,
                 uid.original_asset_id, uid.normalized_asset_id, uid.extractor
          FROM sessions s
          JOIN dictation_snapshots ds ON ds.session_id = s.id
          LEFT JOIN session_metadata m ON m.session_id = s.id
          LEFT JOIN user_item_details uid ON uid.session_id = s.id
          JOIN transcript_revisions tr ON tr.id = (
            SELECT id FROM transcript_revisions
            WHERE session_id = s.id AND kind IN ('final', 'userEdit')
            ORDER BY created_at DESC, revision DESC, id DESC LIMIT 1
          )
          WHERE s.id = ? AND s.state = 'completed' AND ds.phase = 'completed'
          """,
        arguments: [itemID]
      ),
      let itemUUID = UUID(uuidString: itemID)
    else { return nil }
    var text: String = row["content"]
    let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if text.unicodeScalars.count > UserItemLimits.maximumSendableTextScalars {
      // A file's own text is only a hint next to the file: cut, not refused.
      guard (row["item_kind"] as String?) == UserItemKind.file.rawValue else { return nil }
      text = clampedScalars(text, to: UserItemLimits.maximumSendableTextScalars) ?? ""
    }
    if (row["input_mode"] as String) == SessionInputMode.userItem.rawValue {
      return try userItemContent(
        db, itemID: itemID, itemUUID: itemUUID, row: row, text: text, hasText: hasText,
        timeZone: timeZone
      )
    }
    guard hasText else { return nil }
    let kind: String
    let sourceName: String
    switch row["input_mode"] as String {
    case "dictation":
      kind = "dictation"
      sourceName = "口述"
    case "roomMicrophone":
      kind = "meeting_offline"
      sourceName = "线下录音"
    case "systemAudio":
      kind = "meeting_online"
      sourceName = "电脑内录"
    case "importedMedia":
      kind = "imported_media"
      sourceName = "导入媒体"
    default: return nil
    }
    let transcriptID: String = row["transcript_id"]
    let segmentRows = try Row.fetchAll(
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
      arguments: [itemID, transcriptID]
    )
    let baseNS = segmentRows.map { $0["monotonic_start_ns"] as Int64 }.min() ?? 0
    let segments: [RemoteOrganizerItem.Segment] = segmentRows.map { segment in
      let startNS: Int64 = segment["monotonic_start_ns"]
      let endNS: Int64 = segment["monotonic_end_ns"]
      return .init(
        startMS: max(0, (startNS - baseNS) / 1_000_000),
        endMS: max(0, (endNS - baseNS) / 1_000_000),
        personID: segment["person_id"], text: segment["text"]
      )
    }
    // People come from the session's accepted speaker assignments, not from
    // the segments: a whole-text edit has no segments but keeps its people.
    let personRows = try Row.fetchAll(
      db,
      sql: """
        SELECT o.person_id, p.display_name, p.retired_at
        FROM (
          SELECT DISTINCT person_id FROM speaker_occurrences
          WHERE session_id = ? AND person_id IS NOT NULL
            AND association_status IN (
              'anonymousIdentity', 'automaticMatch', 'userConfirmed'
            )
        ) o
        LEFT JOIN persons p ON p.id = o.person_id
        ORDER BY o.person_id
        """,
      arguments: [itemID]
    )
    let persons: [RemoteOrganizerItem.Person] = personRows.compactMap { person in
      let id: String = person["person_id"]
      guard id.unicodeScalars.count <= remotePersonIDScalars else { return nil }
      let retired = !(person["retired_at"] as DatabaseValue).isNull
      let name =
        retired ? nil : clampedScalars(person["display_name"], to: remoteDisplayNameScalars)
      return RemoteOrganizerItem.Person(personID: id, displayName: name)
    }
    // The local UTC offset, not `Z`: the organizer reads 今天/明天, the capture
    // day and its daily question budget from the item's own offset.
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    dateFormatter.timeZone = timeZone
    let createdAt: Double = row["created_at"]
    let sourceDisplayName: String? = row["source_display_name"]
    let sourceBundleID: String? = row["source_bundle_id"]
    // An import names an App only when intake recorded its bundle ID; older
    // imports stored the filename in the display-name field, which never leaves.
    let sourceIsApp =
      kind == "dictation" || kind == "meeting_online"
      || (kind == "imported_media" && !(sourceBundleID ?? "").isEmpty)
    let appName =
      sourceIsApp
      ? sourceDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    // Service limits count Unicode scalars; a bundle ID over the limit is left
    // out rather than truncated into a different ID.
    let bundleID =
      sourceIsApp && (sourceBundleID?.unicodeScalars.count ?? 0) <= remoteSourceScalars
      ? sourceBundleID : nil
    return RemoteOrganizerItem(
      itemID: itemUUID, revision: 0, kind: kind,
      sourceApp: .init(
        bundleID: bundleID,
        name: clampedScalars(
          (appName?.isEmpty == false ? appName : nil) ?? sourceName, to: remoteSourceScalars
        ) ?? sourceName),
      startedAt: dateFormatter.string(from: Date(timeIntervalSince1970: createdAt)),
      endedAt: nil,
      text: text, segments: segments.isEmpty ? nil : segments,
      persons: persons.isEmpty ? nil : persons,
      sha256: remoteDigest(Data(text.utf8))
    )
  }

  /// A pasted or dragged item: kind text/image/document/file, its App label,
  /// the committed text, and for an image a reference to its normalized copy
  /// (and an animation's further frames) that the runtime replaces with the
  /// bytes at send time (reading 12 MB inside this write transaction would
  /// hold the only writer). A document sends only its text. A file sends its
  /// name, type and size, the text this Mac read, and a reference to the
  /// original (at most 25 MiB); a larger file goes as kind `text` with that
  /// text and the file facts, or stays here when this Mac read no text. A
  /// video keyframe names its recording and position.
  private nonisolated static func userItemContent(
    _ db: Database, itemID: String, itemUUID: UUID, row: Row, text: String, hasText: Bool,
    timeZone: TimeZone
  ) throws -> RemoteOrganizerItem? {
    guard let kindValue: String = row["item_kind"],
      let kind = UserItemKind(rawValue: kindValue),
      // Kept only on this Mac (audio or video, archives, unreadable
      // binaries; contract §5): never sent, whatever else it has.
      (row["extractor"] as String?) != UserItemLimits.localOnlyExtractor
    else { return nil }
    var imageAsset: RemoteOrganizerImageAsset?
    var extraImageAssets: [RemoteOrganizerImageAsset]?
    var fileAsset: RemoteOrganizerImageAsset?
    var wireKind = kind.rawValue
    var file: (name: String, uti: String?, mime: String, size: Int64)?
    let digest: String
    switch kind {
    case .text:
      guard hasText else { return nil }
      digest = remoteDigest(Data(text.utf8))
    case .document:
      // A scanned PDF with no text layer is kept locally and parked.
      guard hasText,
        text.trimmingCharacters(in: .whitespacesAndNewlines)
          != UserItemLimits.noTextLayerPlaceholder
      else { return nil }
      digest = remoteDigest(Data(text.utf8))
    case .file:
      guard let originalID: String = row["original_asset_id"],
        let asset = try Row.fetchOne(
          db,
          sql: """
            SELECT id, asset_reference, digest, size_bytes, media_type, original_filename
            FROM session_source_assets WHERE id = ? AND session_id = ?
            """,
          arguments: [originalID, itemID]
        )
      else { return nil }
      let size: Int64 = asset["size_bytes"]
      let fileDigest: String = asset["digest"]
      let filename =
        clampedScalars(row["source_identifier"], to: remoteFilenameScalars)
        ?? clampedScalars(asset["original_filename"], to: remoteFilenameScalars) ?? "file"
      let uti: String? = row["uniform_type"]
      file = (
        filename, uti.flatMap { $0.unicodeScalars.count <= 256 ? $0 : nil },
        asset["media_type"], size
      )
      if size > 0, size <= UserItemLimits.maximumSendableFileBytes {
        fileAsset = RemoteOrganizerImageAsset(
          assetID: asset["id"], relativePath: asset["asset_reference"], sha256: fileDigest,
          sizeBytes: size, mediaType: asset["media_type"])
      } else if hasText {
        // Too large to send whole: its text goes, with what the file is.
        wireKind = UserItemKind.text.rawValue
      } else {
        return nil
      }
      digest = fileDigest
    case .image:
      let assets = try Row.fetchAll(
        db,
        sql: """
          SELECT id, kind, asset_reference, digest, size_bytes, media_type
          FROM session_source_assets
          WHERE session_id = ?
            AND kind IN ('normalizedImage', 'animationFrame1', 'animationFrame2',
                         'animationFrame3')
          ORDER BY revision DESC, id
          """,
        arguments: [itemID]
      )
      func sendable(_ asset: Row) -> RemoteOrganizerImageAsset? {
        let size: Int64 = asset["size_bytes"]
        let mediaType: String = asset["media_type"]
        guard size > 0, size <= Int64(UserItemLimits.maximumSendableImageBytes),
          mediaType == "image/png" || mediaType == "image/jpeg"
        else { return nil }
        return RemoteOrganizerImageAsset(
          assetID: asset["id"], relativePath: asset["asset_reference"],
          sha256: asset["digest"], sizeBytes: size, mediaType: mediaType)
      }
      let normalizedID: String? = row["normalized_asset_id"]
      let normalized = assets.filter { ($0["kind"] as String) == "normalizedImage" }
      guard
        let main =
          (normalized.first { ($0["id"] as String) == normalizedID }
          ?? normalized.first).flatMap(sendable)
      else { return nil }
      imageAsset = main
      let frames = ["animationFrame1", "animationFrame2", "animationFrame3"].compactMap { name in
        assets.first { ($0["kind"] as String) == name }.flatMap(sendable)
      }
      extraImageAssets = frames.isEmpty ? nil : frames
      // The frames are part of what was sent: a change to them is a change.
      digest =
        frames.isEmpty
        ? main.sha256 : remoteDigest(Data(([main] + frames).map(\.sha256).joined().utf8))
    }
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    dateFormatter.timeZone = timeZone
    let createdAt: Double = row["created_at"]
    let startedAt = dateFormatter.string(from: Date(timeIntervalSince1970: createdAt))
    let sourceBundleID: String? = row["source_bundle_id"]
    let bundleID =
      (sourceBundleID?.unicodeScalars.count ?? 0) <= remoteSourceScalars ? sourceBundleID : nil
    let bundleName = bundleID?.split(separator: ".").last.map(String.init)
    let name =
      clampedScalars(row["source_display_name"], to: remoteSourceScalars)
      ?? clampedScalars(bundleName, to: remoteSourceScalars)
      ?? SourceLabel.fallback(for: .userItem)
    let parent = (row["parent_session_id"] as String?).flatMap(UUID.init(uuidString:))
    let isFile = file != nil
    return RemoteOrganizerItem(
      itemID: itemUUID, revision: 0, kind: wireKind,
      sourceApp: .init(bundleID: bundleID?.isEmpty == true ? nil : bundleID, name: name),
      startedAt: startedAt, endedAt: nil,
      // A file's own text is its local text; the organizer reads the file.
      text: hasText && (!isFile || fileAsset == nil) ? text : nil,
      segments: nil, persons: nil, imageAsset: imageAsset, sha256: digest,
      filename: file?.name, uniformType: file?.uti, mediaType: file?.mime,
      sizeBytes: file?.size, fileAsset: fileAsset,
      localText: isFile && fileAsset != nil && hasText ? text : nil,
      capturedAt: isFile || parent != nil ? startedAt : nil,
      parentItemID: parent.map { $0.uuidString },
      frameMilliseconds: parent == nil ? nil : (row["frame_ms"] as Int64?),
      extraImageAssets: extraImageAssets
    )
  }

  /// Longest filename sent (the service's limit, in Unicode scalars).
  nonisolated static let remoteFilenameScalars = 255

  private nonisolated static func completedSessionCreatedAt(
    _ db: Database, sessionID: String
  ) throws -> Double? {
    try Double.fetchOne(
      db,
      sql: """
        SELECT s.created_at FROM sessions s
        JOIN dictation_snapshots ds ON ds.session_id = s.id
        WHERE s.id = ? AND s.state = 'completed' AND ds.phase = 'completed'
        """,
      arguments: [sessionID]
    )
  }

  private nonisolated static func remoteItemJobExists(
    _ db: Database, itemID: String
  ) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: "SELECT EXISTS (SELECT 1 FROM remote_organizer_item_jobs WHERE item_id = ?)",
      arguments: [itemID]
    ) ?? false
  }

  nonisolated static func isRemoteEligible(
    _ db: Database, sessionID: String
  ) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: "SELECT EXISTS (SELECT 1 FROM remote_organizer_eligible WHERE session_id = ?)",
      arguments: [sessionID]
    ) ?? false
  }

  /// Starts tracking an eligible session. One that cannot be sent right now
  /// (for example a silent take with no text) is tracked as parked, so the
  /// sweep does not rebuild its content on every poll; its next change queues it.
  nonisolated static func insertRemoteItemJob(
    _ db: Database, itemID: String, createdAt: Double
  ) throws {
    let sendable = try remoteItemContent(db, itemID: itemID) != nil
    let revision =
      try Int64.fetchOne(
        db,
        sql: """
          SELECT MAX(revision) FROM transcript_revisions
          WHERE session_id = ? AND kind IN ('final', 'userEdit')
          """,
        arguments: [itemID]
      ) ?? 1
    try db.execute(
      sql: """
        INSERT INTO remote_organizer_item_jobs (
          item_id, target_revision, state, error_category, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        itemID, max(1, revision), sendable ? "queued" : "failed",
        sendable ? "none" : "unsendable", createdAt, Date().timeIntervalSince1970,
      ]
    )
  }

  private nonisolated static let remotePersonIDScalars = 128
  private nonisolated static let remoteDisplayNameScalars =
    RemoteOrganizerDecision.maximumDisplayNameScalars
  private nonisolated static let remoteSourceScalars = 256

  /// Trimmed and cut to the service's limit, which counts Unicode scalars
  /// (not grapheme clusters or UTF-8 bytes). Empty becomes nil.
  private nonisolated static func clampedScalars(_ value: String?, to limit: Int) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return nil }
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: trimmed.unicodeScalars.prefix(limit))
    return String(scalars)
  }

  private nonisolated static func markRemoteItemChanged(
    _ db: Database, itemID: String
  ) throws {
    try db.execute(
      sql: """
        UPDATE remote_organizer_item_jobs
        SET change_seq = change_seq + 1,
            state = CASE state WHEN 'running' THEN 'running' ELSE 'queued' END,
            retry_count = CASE state WHEN 'failed' THEN 0 ELSE retry_count END,
            not_before = 0, updated_at = ?
        WHERE item_id = ?
        """,
      arguments: [Date().timeIntervalSince1970, itemID]
    )
  }

  /// Returns true when the Spark's store identity changed and the local
  /// mirror was reset. A first sighting resets only if something was already
  /// mirrored or delivered, because that could have come from another store.
  private nonisolated static func applyRemoteStoreIdentity(
    _ db: Database, storeID: String
  ) throws -> Bool {
    let trimmed = storeID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 128 else {
      throw BestASRPersistenceError.invalidSnapshot
    }
    let stored = try remoteMeta(db, "store_id")
    if stored == trimmed { return false }
    let hadState =
      try remoteStoredCursor(db) > 0
      || (try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS (
            SELECT 1 FROM remote_organizer_item_jobs
            WHERE delivered_revision IS NOT NULL
          ) OR EXISTS (SELECT 1 FROM remote_organizer_events)
          """
      ) ?? false)
    try setRemoteMeta(db, "store_id", trimmed)
    guard stored != nil || hadState else {
      // First store ever seen: decisions made before it was known belong to it.
      try db.execute(
        sql: "UPDATE remote_organizer_decision_jobs SET store_id = ? WHERE store_id IS NULL",
        arguments: [trimmed]
      )
      return false
    }
    try resetRemoteMirror(db, newStoreID: trimmed)
    return true
  }

  /// The Spark lost what it had: clear the mirror, pull from cursor 0, send
  /// the latest revision of every item it had acknowledged again, and re-seed
  /// the corrections about people (their IDs are the same in every store) in
  /// their original order. Corrections about the old store's events, items,
  /// or questions cannot apply to the new store: pending ones are cancelled
  /// and all of them leave the local overlay (category `store_reset`).
  private nonisolated static func resetRemoteMirror(
    _ db: Database, newStoreID: String?
  ) throws {
    try db.execute(sql: "DELETE FROM remote_organizer_events")
    try db.execute(sql: "DELETE FROM remote_organizer_persons")
    try db.execute(sql: "DELETE FROM remote_organizer_questions")
    try db.execute(
      sql: "DELETE FROM remote_organizer_meta WHERE key IN (?, ?)",
      arguments: [unfiledMetaKey, readingsMetaKey])
    try setRemoteMeta(db, "cursor", "0")
    try db.execute(
      sql: """
        UPDATE remote_organizer_item_jobs
        SET delivered_revision = NULL, delivered_sha256 = NULL,
            delivered_at = NULL, change_seq = change_seq + 1,
            state = CASE state WHEN 'running' THEN 'running' ELSE 'queued' END,
            not_before = 0, retry_count = 0, updated_at = ?
        WHERE delivered_revision IS NOT NULL
        """,
      arguments: [Date().timeIntervalSince1970]
    )
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT j.decision_id, j.state, d.payload_json
        FROM remote_organizer_decision_jobs j
        JOIN remote_organizer_decisions d ON d.id = j.decision_id
        WHERE j.store_id IS NULL OR j.store_id IS NOT ?
        """,
      arguments: [newStoreID]
    )
    for row in rows {
      let id: String = row["decision_id"]
      let state: String = row["state"]
      let payload: Data = row["payload_json"]
      let personScoped =
        (try? JSONDecoder().decode(RemoteOrganizerDecision.self, from: payload))?
        .isPersonScoped ?? false
      if personScoped {
        guard ["delivered", "queued", "running"].contains(state) else { continue }
        // Sent again as a plain decision: the new store has no such question.
        try db.execute(
          sql: """
            UPDATE remote_organizer_decision_jobs
            SET state = 'queued', kind = 'decision', not_before = 0, retry_count = 0,
                lease_expires_at = NULL, error_category = 'none', error_reason = NULL,
                store_id = ?
            WHERE decision_id = ?
            """,
          arguments: [newStoreID, id]
        )
      } else {
        try db.execute(
          sql: """
            UPDATE remote_organizer_decision_jobs
            SET state = CASE WHEN state IN ('queued', 'running') THEN 'cancelled' ELSE state END,
                error_category = 'store_reset', lease_expires_at = NULL,
                store_id = COALESCE(store_id, '')
            WHERE decision_id = ?
            """,
          arguments: [id]
        )
      }
    }
  }

  nonisolated static func remoteLinkEnabledAt(_ db: Database) throws -> Date? {
    guard let value = try remoteMeta(db, "link_enabled_at") else { return nil }
    guard let seconds = Double(value), seconds.isFinite else {
      throw BestASRPersistenceError.storedDataCorrupt
    }
    return Date(timeIntervalSince1970: seconds)
  }

  private nonisolated static func remoteStoredCursor(_ db: Database) throws -> Int64 {
    guard let value = try remoteMeta(db, "cursor"), let cursor = Int64(value),
      cursor >= 0
    else { throw BestASRPersistenceError.storedDataCorrupt }
    return cursor
  }

  private nonisolated static func remoteMeta(_ db: Database, _ key: String) throws -> String? {
    try String.fetchOne(
      db, sql: "SELECT value FROM remote_organizer_meta WHERE key = ?", arguments: [key]
    )
  }

  /// `remote_organizer_meta` key prefix of an item whose send was attempted
  /// but never confirmed when a revocation or an archive import dropped its
  /// job (the item may be on the organizing device).
  nonisolated static let maybeOnOrganizerMetaPrefix = "maybe_on_organizer:"

  private nonisolated static func setRemoteMeta(
    _ db: Database, _ key: String, _ value: String
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO remote_organizer_meta (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
      arguments: [key, value]
    )
  }

  nonisolated static let unfiledMetaKey = "unfiled_json"
  nonisolated static let readingsMetaKey = "readings_json"

  private nonisolated static func storedRemoteReadings(
    _ db: Database
  ) throws -> [String: RemoteOrganizerItemReading] {
    guard let json = try remoteMeta(db, readingsMetaKey) else { return [:] }
    return
      (try? JSONDecoder().decode(
        [String: RemoteOrganizerItemReading].self, from: Data(json.utf8))) ?? [:]
  }

  private nonisolated static func storeRemoteReadings(
    _ db: Database, _ readings: [String: RemoteOrganizerItemReading]
  ) throws {
    if readings.isEmpty {
      try db.execute(
        sql: "DELETE FROM remote_organizer_meta WHERE key = ?", arguments: [readingsMetaKey])
    } else {
      try setRemoteMeta(
        db, readingsMetaKey, String(decoding: try remoteJSON(readings), as: UTF8.self))
    }
  }

  /// Delivered revision per item (upper-case ID) the Mac still tracks.
  private nonisolated static func deliveredRevisions(_ db: Database) throws -> [String: Int64] {
    var result: [String: Int64] = [:]
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT item_id, delivered_revision FROM remote_organizer_item_jobs
        WHERE delivered_revision IS NOT NULL
        """)
    {
      let itemID: String = row["item_id"]
      result[itemID.uppercased()] = row["delivered_revision"]
    }
    return result
  }

  /// Keeps the newest reading per item, and only for items this Mac sent and
  /// still holds (a deleted item's job is gone, and so is its reading).
  private nonisolated static func mergeRemoteReadings(
    _ db: Database, _ incoming: [RemoteOrganizerItemReading]
  ) throws {
    let delivered = try deliveredRevisions(db)
    var readings = try storedRemoteReadings(db).filter { delivered[$0.key] != nil }
    for reading in incoming {
      let key = reading.itemID.uppercased()
      guard delivered[key] != nil else { continue }
      if let held = readings[key], held.revision > reading.revision { continue }
      readings[key] = RemoteOrganizerItemReading(
        itemID: key, revision: reading.revision, text: reading.text, summary: reading.summary,
        facts: reading.facts)
    }
    try storeRemoteReadings(db, readings)
  }

  /// Readings made from the revision of each item this Mac last delivered;
  /// one read from an older or newer revision is not shown.
  private nonisolated static func currentRemoteReadings(
    _ db: Database
  ) throws -> [String: RemoteOrganizerItemReading] {
    let stored = try storedRemoteReadings(db)
    guard !stored.isEmpty else { return [:] }
    let delivered = try deliveredRevisions(db)
    return stored.filter { delivered[$0.key] == $0.value.revision }
  }

  /// A user-deleted item's reading goes with it (called in the deletion's
  /// transaction).
  nonisolated static func dropRemoteReading(_ db: Database, itemID: String) throws {
    var readings = try storedRemoteReadings(db)
    guard readings.removeValue(forKey: itemID.uppercased()) != nil else { return }
    try storeRemoteReadings(db, readings)
  }

  /// A new event the user made from one item (`file_item_new_event`), shown
  /// until the Spark returns an event under the same ID: titled from the
  /// item's first line, dated at the item's capture time.
  private nonisolated static func provisionalEvent(
    _ db: Database, eventID: String, itemID: String
  ) throws -> RemoteOrganizerEvent {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT s.created_at, m.title,
          (SELECT content FROM transcript_revisions
           WHERE session_id = s.id AND kind IN ('final', 'userEdit')
           ORDER BY created_at DESC, revision DESC, id DESC LIMIT 1) AS content
        FROM sessions s
        LEFT JOIN session_metadata m ON m.session_id = s.id
        WHERE s.id = ? COLLATE NOCASE
        ORDER BY m.revision DESC LIMIT 1
        """,
      arguments: [itemID]
    )
    let text: String = row?["content"] ?? ""
    let firstLine =
      text.split(whereSeparator: \.isNewline)
      .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty }
    let metadataTitle = (row?["title"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
    var title = firstLine ?? metadataTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "一件事"
    if title.unicodeScalars.count > RemoteOrganizerDecision.maximumTitleScalars {
      title = String(
        String.UnicodeScalarView(
          title.unicodeScalars.prefix(RemoteOrganizerDecision.maximumTitleScalars)))
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let stamp = (row?["created_at"] as Double?).map {
      formatter.string(from: Date(timeIntervalSince1970: $0))
    }
    return RemoteOrganizerEvent(
      eventID: eventID, title: title, startedAt: stamp, updatedAt: stamp, itemIDs: [itemID])
  }

  /// Replays the user's decisions, in commit order, over the pulled state.
  /// Item IDs compare case-insensitively (the Spark may lower-case them).
  nonisolated static func applyLocalRemoteDecisions(
    _ decisions: [RemoteOrganizerDecision],
    events: inout [RemoteOrganizerEvent],
    persons: inout [RemoteOrganizerPerson],
    unfiled: inout [RemoteOrganizerUnfiledItem],
    provisionalEvents: [String: RemoteOrganizerEvent] = [:]
  ) {
    func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
    /// Takes the item (all of its parts) out of one event.
    func take(_ itemID: String, from index: Int) {
      events[index].itemIDs.removeAll { same($0, itemID) }
      events[index].segments.removeAll { same($0.itemID, itemID) }
    }
    func removeEverywhere(_ itemID: String) {
      for index in events.indices { take(itemID, from: index) }
    }
    /// Takes one part of an item out of one event; the item leaves the event
    /// with its last part. An event holding the item whole gives it up whole
    /// only when `wholeToo` (a removal from that very event). Returns the
    /// part when the event had it.
    @discardableResult
    func takeSegment(
      _ itemID: String, _ segID: String, from index: Int, wholeToo: Bool = false
    ) -> RemoteOrganizerEvent.Segment? {
      guard events[index].itemIDs.contains(where: { same($0, itemID) }) else { return nil }
      let parts = events[index].segments.filter { same($0.itemID, itemID) }
      guard !parts.isEmpty else {
        if wholeToo { take(itemID, from: index) }
        return nil
      }
      let part = parts.first { $0.segID == segID }
      guard let part else { return nil }
      events[index].segments.removeAll { same($0.itemID, itemID) && $0.segID == segID }
      if parts.count == 1 { events[index].itemIDs.removeAll { same($0, itemID) } }
      return part
    }
    func unfile(_ itemID: String, reason: String) {
      unfiled.removeAll { same($0.itemID, itemID) }
      unfiled.append(RemoteOrganizerUnfiledItem(itemID: itemID, reason: reason))
    }
    func leaveUnfiled(_ itemID: String) { unfiled.removeAll { same($0.itemID, itemID) } }
    func inAnyEvent(_ itemID: String) -> Bool {
      events.contains { !$0.deleted && $0.itemIDs.contains { same($0, itemID) } }
    }
    // A placement (move, file as a new event, Yes to "is this item part of
    // …") is replayed only while it is the user's latest word on that item
    // (or on that part of it).
    // Once a later decision took the item out again, the Spark may have
    // placed it somewhere new, and the pulled placement is trusted instead
    // of dragging the item back to where the older decision put it.
    let pulledEventIDs = Set(events.map(\.eventID))
    func placementItem(_ decision: RemoteOrganizerDecision) -> (item: String, places: Bool)? {
      let part = decision.segID.map { "#" + $0 } ?? ""
      switch decision.kind {
      case "move_item", "file_item_new_event":
        return decision.itemID.map { ($0.uppercased() + part, true) }
      case "remove_item", "unfile_item":
        return decision.itemID.map { ($0.uppercased() + part, false) }
      case "same_event":
        guard let a = decision.a, !pulledEventIDs.contains(a) else { return nil }
        return (a.uppercased(), decision.answer == true)
      default:
        return nil
      }
    }
    var lastAboutItem: [String: Int] = [:]
    for (index, decision) in decisions.enumerated() {
      if let about = placementItem(decision) { lastAboutItem[about.item] = index }
    }
    for (index, decision) in decisions.enumerated() {
      if let about = placementItem(decision), about.places, lastAboutItem[about.item] != index {
        continue
      }
      switch decision.kind {
      case "rename_event":
        if let index = events.firstIndex(where: { $0.eventID == decision.eventID }),
          let title = decision.title
        {
          events[index].title = title
        }
      case "remove_item":
        // The item waits in Unfiled; it never becomes a one-item event by itself.
        if let index = events.firstIndex(where: { $0.eventID == decision.eventID }),
          let itemID = decision.itemID
        {
          if let segID = decision.segID {
            takeSegment(itemID, segID, from: index, wholeToo: true)
          } else {
            take(itemID, from: index)
          }
          if !inAnyEvent(itemID) { unfile(itemID, reason: "removed_by_user") }
        }
      case "unfile_item":
        if let itemID = decision.itemID {
          if let segID = decision.segID {
            for index in events.indices { takeSegment(itemID, segID, from: index) }
            if !inAnyEvent(itemID) { unfile(itemID, reason: "user") }
          } else {
            removeEverywhere(itemID)
            unfile(itemID, reason: "user")
          }
        }
      case "file_item_new_event":
        guard let itemID = decision.itemID else { continue }
        removeEverywhere(itemID)
        leaveUnfiled(itemID)
        guard let newID = decision.newEventID?.lowercased() else { continue }
        if let index = events.firstIndex(where: { same($0.eventID, newID) }) {
          events[index].itemIDs.append(itemID)
        } else if let provisional = provisionalEvents[newID] {
          events.append(provisional)
        } else {
          events.append(RemoteOrganizerEvent(eventID: newID, title: "一件事", itemIDs: [itemID]))
        }
      case "move_item":
        guard let itemID = decision.itemID,
          let target = events.firstIndex(where: { $0.eventID == decision.toEventID })
        else { continue }
        if let segID = decision.segID {
          // One part moves; the item's other parts stay where they are.
          var moved: RemoteOrganizerEvent.Segment?
          for index in events.indices where index != target {
            moved = takeSegment(itemID, segID, from: index) ?? moved
          }
          guard let moved else { continue }
          let holdsWhole =
            events[target].itemIDs.contains { same($0, itemID) }
            && !events[target].segments.contains { same($0.itemID, itemID) }
          if !events[target].itemIDs.contains(where: { same($0, itemID) }) {
            events[target].itemIDs.append(itemID)
          }
          if !holdsWhole,
            !events[target].segments.contains(where: {
              same($0.itemID, itemID) && $0.segID == segID
            })
          {
            events[target].segments.append(moved)
          }
          leaveUnfiled(itemID)
        } else {
          removeEverywhere(itemID)
          events[target].itemIDs.append(itemID)
          leaveUnfiled(itemID)
        }
      case "pin_event":
        if let index = events.firstIndex(where: { $0.eventID == decision.eventID }),
          let pinned = decision.pinned
        {
          events[index].pinned = pinned
        }
      case "feature_less":
        if let index = events.firstIndex(where: { $0.eventID == decision.eventID }) {
          events[index].importance = min(events[index].importance, 0.2)
        }
      case "delete_event":
        if let index = events.firstIndex(where: { $0.eventID == decision.eventID }) {
          events[index].deleted = true
        }
      case "name_person":
        if let index = persons.firstIndex(where: { $0.personID == decision.personID }) {
          persons[index].displayName = decision.displayName
        }
      case "same_person":
        guard decision.answer == true, let a = decision.a, let b = decision.b else {
          continue
        }
        mergeRemotePersons(a, b, persons: &persons)
      case "same_event":
        guard let a = decision.a, let b = decision.b else { continue }
        if let aIndex = events.firstIndex(where: { $0.eventID == a }),
          let bIndex = events.firstIndex(where: { $0.eventID == b })
        {
          // Two fragments of one matter: Yes merges b into a.
          if decision.answer == true {
            let original = Set(events[aIndex].itemIDs.map { $0.uppercased() })
            let wholeInA = Set(
              events[aIndex].itemIDs.map { $0.uppercased() }.filter { id in
                !events[aIndex].segments.contains { $0.itemID.uppercased() == id }
              })
            events[aIndex].itemIDs += events[bIndex].itemIDs.filter {
              !original.contains($0.uppercased())
            }
            // Parts of b join a, unless a already holds that item whole.
            for part in events[bIndex].segments
            where !wholeInA.contains(part.itemID.uppercased())
              && !events[aIndex].segments.contains(where: {
                same($0.itemID, part.itemID) && $0.segID == part.segID
              })
            {
              events[aIndex].segments.append(part)
            }
            events[bIndex].deleted = true
          }
        } else if let eventIndex = events.firstIndex(where: { $0.eventID == b }) {
          if decision.answer == true {
            // Into b (or kept there, locked).
            removeEverywhere(a)
            events[eventIndex].itemIDs.append(a)
            leaveUnfiled(a)
          } else if events[eventIndex].itemIDs.contains(where: { same($0, a) }) {
            // Asked about an item already in b: No takes it out; it waits in
            // Unfiled unless the Spark places it elsewhere.
            take(a, from: eventIndex)
            if !inAnyEvent(a) { unfile(a, reason: "removed_by_user") }
          }
        }
      default:
        break
      }
    }
    // An item filed into an event is not also Unfiled.
    unfiled.removeAll { inAnyEvent($0.itemID) }
  }

  /// Same rule as the service: follow both people to their canonical person;
  /// a voice-origin person stays canonical, otherwise `a` does. Never creates
  /// a `mergedInto` cycle, including when the Spark already merged them.
  private nonisolated static func mergeRemotePersons(
    _ a: String, _ b: String, persons: inout [RemoteOrganizerPerson]
  ) {
    func canonical(_ id: String) -> String {
      var current = id
      var seen: Set<String> = [current]
      while let next = persons.first(where: { $0.personID == current })?.mergedInto,
        !seen.contains(next)
      {
        seen.insert(next)
        current = next
      }
      return current
    }
    let ca = canonical(a)
    let cb = canonical(b)
    guard ca != cb,
      let aIndex = persons.firstIndex(where: { $0.personID == ca }),
      let bIndex = persons.firstIndex(where: { $0.personID == cb })
    else { return }
    if persons[aIndex].origin != "voice", persons[bIndex].origin == "voice" {
      persons[aIndex].mergedInto = cb
    } else {
      persons[bIndex].mergedInto = ca
    }
  }

  private nonisolated static func remoteJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private nonisolated static func remoteDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

extension GRDBDictationStore: UserItemCommitting {}
