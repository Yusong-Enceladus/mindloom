import Foundation
import XCTest

@testable import BestASRPersistenceProbe

final class PersistenceMigrationProbeTests: XCTestCase {
  private struct SchemaFixture: Decodable {
    struct Version: Decodable {
      let userVersion: Int
      let appliedMigrations: [String]
      let tableNames: [String]
    }

    let schemaVersion: Int
    let nMinusOne: Version
    let current: Version
  }

  func testGeneratedSchemasMatchVersionedFixtureManifest() throws {
    let fixture = try makeFixture()
    let databaseURL = fixture.appendingPathComponent("schema.sqlite")
    let probe = PersistenceMigrationProbe()
    let fixtureData = try Data(
      contentsOf:
        repositoryRoot
        .appendingPathComponent("Tests/Fixtures/Persistence/schema-fixture.json")
    )
    let contract = try JSONDecoder().decode(SchemaFixture.self, from: fixtureData)

    XCTAssertEqual(contract.schemaVersion, 1)
    try probe.createNMinusOneFixture(at: databaseURL)
    let nMinusOne = try probe.inspect(databaseURL)
    XCTAssertEqual(nMinusOne.schemaVersion, contract.nMinusOne.userVersion)
    XCTAssertEqual(nMinusOne.appliedMigrations, contract.nMinusOne.appliedMigrations)
    XCTAssertEqual(nMinusOne.tableNames, contract.nMinusOne.tableNames)

    let current = try probe.migrateToCurrent(at: databaseURL).inspection
    XCTAssertEqual(current.schemaVersion, contract.current.userVersion)
    XCTAssertEqual(current.appliedMigrations, contract.current.appliedMigrations)
    XCTAssertEqual(current.tableNames, contract.current.tableNames)
  }

  func testNMinusOneMigrationUsesWALAndIsIdempotent() throws {
    let fixture = try makeFixture()
    let databaseURL = fixture.appendingPathComponent("store.sqlite")
    let probe = PersistenceMigrationProbe()
    try probe.createNMinusOneFixture(at: databaseURL)

    let nMinusOne = try probe.inspect(databaseURL)
    XCTAssertEqual(nMinusOne.schemaVersion, 1)
    XCTAssertEqual(
      nMinusOne.appliedMigrations,
      [PersistenceSchema.nMinusOneMigrationID]
    )
    XCTAssertEqual(nMinusOne.journalMode, "wal")
    XCTAssertTrue(nMinusOne.foreignKeysEnabled)
    XCTAssertEqual(nMinusOne.sessionCount, 1)

    let first = try probe.migrateToCurrent(at: databaseURL)
    let second = try probe.migrateToCurrent(at: databaseURL)

    for attempt in [first, second] {
      XCTAssertEqual(attempt.status, .pass)
      XCTAssertTrue(attempt.sourceFilePreserved)
      XCTAssertTrue(attempt.backupMatchesPreMigration)
      XCTAssertEqual(attempt.inspection.schemaVersion, 2)
      XCTAssertEqual(
        attempt.inspection.appliedMigrations,
        [
          PersistenceSchema.nMinusOneMigrationID,
          PersistenceSchema.currentMigrationID,
        ]
      )
      XCTAssertEqual(attempt.inspection.sessionCount, 1)
      XCTAssertEqual(attempt.inspection.journalMode, "wal")
      XCTAssertTrue(attempt.inspection.foreignKeysEnabled)
    }
    XCTAssertEqual(first.inspection.tableNames, second.inspection.tableNames)
    XCTAssertTrue(first.inspection.tableNames.contains("speaker_occurrences"))
    XCTAssertTrue(first.inspection.tableNames.contains("person_corrections"))
    XCTAssertTrue(first.inspection.tableNames.contains("change_log"))
    XCTAssertTrue(first.inspection.tableNames.contains("tombstones"))
  }

  func testInterruptedMigrationRollsBackAndPreservesRecoverableOriginal() throws {
    let fixture = try makeFixture()
    let databaseURL = fixture.appendingPathComponent("interrupted.sqlite")
    let recoveredURL = fixture.appendingPathComponent("recovered.sqlite")
    let probe = PersistenceMigrationProbe()
    try probe.createNMinusOneFixture(at: databaseURL)

    let attempt = try probe.migrateToCurrent(
      at: databaseURL,
      fault: .interruptAfterFirstCurrentTable
    )

    XCTAssertEqual(attempt.status, .fail)
    XCTAssertTrue(attempt.failureCategory?.contains("injectedInterruption") == true)
    XCTAssertTrue(attempt.sourceFilePreserved)
    XCTAssertTrue(attempt.backupMatchesPreMigration)
    XCTAssertEqual(attempt.inspection.schemaVersion, 1)
    XCTAssertEqual(
      attempt.inspection.appliedMigrations,
      [PersistenceSchema.nMinusOneMigrationID]
    )
    XCTAssertFalse(attempt.inspection.tableNames.contains("speaker_occurrences"))
    XCTAssertEqual(attempt.inspection.sessionCount, 1)
    XCTAssertFalse(attempt.recoveryInstructions.contains(fixture.path))
    XCTAssertTrue(attempt.recoveryInstructions.contains(attempt.backupFileName))

    let backupURL = databaseURL.appendingPathExtension("pre-v2.backup")
    try probe.restoreBackup(backupURL, to: recoveredURL)
    let recovered = try probe.inspect(recoveredURL)
    XCTAssertEqual(recovered.schemaVersion, 1)
    XCTAssertEqual(recovered.sessionCount, 1)
    XCTAssertEqual(
      recovered.appliedMigrations,
      [PersistenceSchema.nMinusOneMigrationID]
    )
  }

  func testSchemaRejectsAbsoluteAssetReferences() throws {
    let fixture = try makeFixture()
    let databaseURL = fixture.appendingPathComponent("constraints.sqlite")
    let probe = PersistenceMigrationProbe()
    try probe.createNMinusOneFixture(at: databaseURL)

    XCTAssertThrowsError(
      try executeFixtureSQL(
        databaseURL: databaseURL,
        sql: """
          INSERT INTO tracks (
            id, session_id, revision, role, asset_reference, sample_rate_hz, channel_count
          ) VALUES (
            '00000000-0000-4000-8000-000000000002',
            '00000000-0000-4000-8000-000000000001',
            1, 'microphoneLocal', '/Users/fixture/source.caf', 48000, 1
          );
          """
      )
    )
  }

  private func executeFixtureSQL(databaseURL: URL, sql: String) throws {
    try PersistenceSQLExecutor.execute(databaseURL: databaseURL, sql: sql)
  }

  private func makeFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-persistence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root
  }

  private var repositoryRoot: URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
      let marker = candidate.appendingPathComponent("PRODUCT_REQUIREMENTS.md")
      if FileManager.default.fileExists(atPath: marker.path) {
        return candidate
      }
      candidate.deleteLastPathComponent()
    }
    fatalError("Could not locate repository root from \(#filePath)")
  }
}
