import BestASRDomain
import Foundation
import GRDB

// v11 (mac-capture): two read-only queries the capture surfaces need. No
// schema change: they read existing tables.
extension GRDBDictationStore {
  /// The item that already holds a file with these bytes (the SHA-256 of a
  /// dropped or pasted original, or of an imported recording), oldest first;
  /// nil when none does. Drops are de-duplicated by content, never by name.
  public func existingCapture(withOriginalDigest digest: String) async throws -> SessionID? {
    let value = digest.lowercased()
    guard value.count == 64 else { return nil }
    let database = try requirePool()
    return try await database.read { db in
      let id = try String.fetchOne(
        db,
        sql: """
          SELECT a.session_id
          FROM session_source_assets a
          JOIN sessions s ON s.id = a.session_id
          WHERE a.digest = ? AND a.kind IN (?, ?)
          ORDER BY a.created_at, a.session_id
          LIMIT 1
          """,
        arguments: [
          value, RetainedSourceAssetKind.userProvidedOriginal.rawValue,
          RetainedSourceAssetKind.importedOriginal.rawValue,
        ])
      return id.flatMap(UUID.init(uuidString:)).map { SessionID($0) }
    }
  }

  /// Items waiting on this Mac for the DGX Spark (queued or being sent, not
  /// delivered): Home's 「{n} 条先放在这台 Mac」.
  public func undeliveredRemoteItemCount() async throws -> Int {
    let database = try requirePool()
    return try await database.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM remote_organizer_item_jobs j
          WHERE j.state IN ('queued', 'running')
            AND EXISTS (SELECT 1 FROM remote_organizer_eligible e WHERE e.session_id = j.item_id)
          """) ?? 0
    }
  }
}

extension GRDBDictationStore {
  /// Recordings whose original audio is still kept (dictations, meetings,
  /// imports; pasted or dragged items have none): what Settings' 「删除原始
  /// 录音…」 deletes after the user confirmed.
  ///
  /// Only finished ones: the session is `completed` and no recognition,
  /// finalization or speaker job for it is queued, running or failed (a
  /// failed one may be retried, and needs the audio). `unfinished` counts
  /// the kept recordings left out, so the App can say they stay.
  public func sessionsRetainingSourceAudio() async throws -> (
    finished: [SessionID], unfinished: Int
  ) {
    let database = try requirePool()
    return try await database.read { db in
      let open = [
        DurableJobState.queued, .running, .retryableFailed, .permanentFailed,
      ].map(\.rawValue)
      let all = try Row.fetchAll(
        db,
        sql: """
          SELECT s.id AS id,
            (s.state = ?
              AND NOT EXISTS (
                SELECT 1 FROM dictation_job_sessions d JOIN durable_jobs j ON j.id = d.job_id
                WHERE d.session_id = s.id AND j.state IN (?, ?, ?, ?))
              AND NOT EXISTS (
                SELECT 1 FROM speaker_job_inputs k JOIN durable_jobs j ON j.id = k.job_id
                WHERE k.session_id = s.id AND j.state IN (?, ?, ?, ?))
            ) AS done
          FROM sessions s
          WHERE s.source_audio_retention = ? AND s.input_mode != ?
          ORDER BY s.created_at, s.id
          """,
        arguments: StatementArguments(
          [SessionState.completed.rawValue] + open + open + [
            SourceAudioRetention.retainedUntilExplicitDeletion.rawValue,
            SessionInputMode.userItem.rawValue,
          ])
      )
      var finished: [SessionID] = []
      var unfinished = 0
      for row in all {
        guard let id = UUID(uuidString: row["id"] as String) else { continue }
        if (row["done"] as Bool?) == true {
          finished.append(SessionID(id))
        } else {
          unfinished += 1
        }
      }
      return (finished, unfinished)
    }
  }
}
