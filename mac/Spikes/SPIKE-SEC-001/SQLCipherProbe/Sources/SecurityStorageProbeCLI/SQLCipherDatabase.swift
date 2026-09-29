import Foundation
import SQLCipher

enum SQLCipherProbeError: Error, Sendable {
  case backupFailed(Int32)
  case closeFailed(Int32)
  case corruptionNotDetected
  case crashWorkerFailed(Int32)
  case expectedFailureMissing
  case invalidColumn
  case invariantFailed(String)
  case openFailed(Int32)
  case sqlite(Int32, String)
}

final class SQLCipherDatabase {
  private(set) var handle: OpaquePointer?

  init(url: URL, key: Data, create: Bool = true) throws {
    var database: OpaquePointer?
    var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    if create {
      flags |= SQLITE_OPEN_CREATE
    }
    let status = sqlite3_open_v2(url.path, &database, flags, nil)
    guard status == SQLITE_OK, let database else {
      if let database {
        sqlite3_close_v2(database)
      }
      throw SQLCipherProbeError.openFailed(status)
    }
    handle = database
    let keyStatus = key.withUnsafeBytes { bytes in
      sqlite3_key(database, bytes.baseAddress, Int32(bytes.count))
    }
    guard keyStatus == SQLITE_OK else {
      sqlite3_close_v2(database)
      handle = nil
      throw SQLCipherProbeError.sqlite(keyStatus, "key")
    }
    do {
      try execute("PRAGMA cipher_memory_security = ON")
      _ = try scalarInt("SELECT count(*) FROM sqlite_schema")
    } catch {
      sqlite3_close_v2(database)
      handle = nil
      throw error
    }
  }

  deinit {
    if let handle {
      sqlite3_close_v2(handle)
    }
  }

  func close() throws {
    guard let handle else { return }
    let status = sqlite3_close_v2(handle)
    guard status == SQLITE_OK else {
      throw SQLCipherProbeError.closeFailed(status)
    }
    self.handle = nil
  }

  func execute(_ sql: String) throws {
    guard let handle else {
      throw SQLCipherProbeError.invariantFailed("database-closed")
    }
    let status = sqlite3_exec(handle, sql, nil, nil, nil)
    guard status == SQLITE_OK else {
      throw SQLCipherProbeError.sqlite(status, "execute")
    }
  }

  func scalarInt(_ sql: String) throws -> Int64 {
    guard let handle else {
      throw SQLCipherProbeError.invariantFailed("database-closed")
    }
    var statement: OpaquePointer?
    let prepareStatus = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard prepareStatus == SQLITE_OK, let statement else {
      throw SQLCipherProbeError.sqlite(prepareStatus, "prepare-int")
    }
    defer { sqlite3_finalize(statement) }
    let stepStatus = sqlite3_step(statement)
    guard stepStatus == SQLITE_ROW else {
      throw SQLCipherProbeError.sqlite(stepStatus, "step-int")
    }
    return sqlite3_column_int64(statement, 0)
  }

  func scalarText(_ sql: String) throws -> String {
    let rows = try textRows(sql)
    guard let first = rows.first else {
      throw SQLCipherProbeError.invalidColumn
    }
    return first
  }

  func textRows(_ sql: String) throws -> [String] {
    guard let handle else {
      throw SQLCipherProbeError.invariantFailed("database-closed")
    }
    var statement: OpaquePointer?
    let prepareStatus = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
    guard prepareStatus == SQLITE_OK, let statement else {
      throw SQLCipherProbeError.sqlite(prepareStatus, "prepare-text")
    }
    defer { sqlite3_finalize(statement) }
    var rows: [String] = []
    while true {
      let stepStatus = sqlite3_step(statement)
      if stepStatus == SQLITE_DONE {
        return rows
      }
      guard stepStatus == SQLITE_ROW else {
        throw SQLCipherProbeError.sqlite(stepStatus, "step-text")
      }
      guard let bytes = sqlite3_column_text(statement, 0) else {
        rows.append("")
        continue
      }
      rows.append(String(cString: bytes))
    }
  }

  func backup(to destination: SQLCipherDatabase) throws {
    guard let sourceHandle = handle,
      let destinationHandle = destination.handle,
      let backup = sqlite3_backup_init(
        destinationHandle,
        "main",
        sourceHandle,
        "main"
      )
    else {
      throw SQLCipherProbeError.backupFailed(
        destination.handle.map(sqlite3_errcode) ?? SQLITE_MISUSE
      )
    }
    let stepStatus = sqlite3_backup_step(backup, -1)
    let finishStatus = sqlite3_backup_finish(backup)
    guard stepStatus == SQLITE_DONE, finishStatus == SQLITE_OK else {
      throw SQLCipherProbeError.backupFailed(
        stepStatus == SQLITE_DONE ? finishStatus : stepStatus
      )
    }
  }

  func cipherIntegrityIsClean() throws -> Bool {
    let rows = try textRows("PRAGMA cipher_integrity_check")
    return rows.isEmpty || rows == ["ok"]
  }
}

func require(_ condition: Bool, _ label: String) throws {
  guard condition else {
    throw SQLCipherProbeError.invariantFailed(label)
  }
}
