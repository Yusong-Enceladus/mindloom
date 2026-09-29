import BestASRPersistenceProbe
import Foundation

private enum CLIError: Error {
  case invalidArguments
  case probeFailed
}

private func evaluateSuccessful(
  name: String,
  attempt: PersistenceMigrationAttempt
) -> PersistenceProbeScenario {
  let passed =
    attempt.status == .pass
    && attempt.sourceFilePreserved
    && attempt.backupMatchesPreMigration
    && attempt.inspection.schemaVersion == 2
    && attempt.inspection.appliedMigrations
      == [
        PersistenceSchema.nMinusOneMigrationID,
        PersistenceSchema.currentMigrationID,
      ]
    && attempt.inspection.journalMode == "wal"
    && attempt.inspection.foreignKeysEnabled
    && attempt.inspection.sessionCount == 1
  return PersistenceProbeScenario(
    name: name,
    result: passed ? .pass : .fail,
    attempt: attempt
  )
}

private func evaluateInterrupted(
  attempt: PersistenceMigrationAttempt
) -> PersistenceProbeScenario {
  let passed =
    attempt.status == .fail
    && attempt.failureCategory?.contains("injectedInterruption") == true
    && attempt.sourceFilePreserved
    && attempt.backupMatchesPreMigration
    && attempt.inspection.schemaVersion == 1
    && attempt.inspection.appliedMigrations
      == [PersistenceSchema.nMinusOneMigrationID]
    && !attempt.inspection.tableNames.contains("speaker_occurrences")
    && attempt.inspection.sessionCount == 1
    && !attempt.recoveryInstructions.isEmpty
  return PersistenceProbeScenario(
    name: "interrupted-migration-rollback",
    result: passed ? .pass : .fail,
    attempt: attempt
  )
}

private func run(summaryURL: URL) throws {
  let fileManager = FileManager.default
  let fixtureRoot = fileManager.temporaryDirectory
    .appendingPathComponent("bestasr-migration-probe-\(UUID().uuidString)")
  defer {
    try? fileManager.removeItem(at: fixtureRoot)
  }
  try fileManager.createDirectory(
    at: fixtureRoot,
    withIntermediateDirectories: true
  )

  let probe = PersistenceMigrationProbe()
  let successURL = fixtureRoot.appendingPathComponent("success.sqlite")
  try probe.createNMinusOneFixture(at: successURL)
  let first = try probe.migrateToCurrent(at: successURL)
  let repeated = try probe.migrateToCurrent(at: successURL)

  let interruptedURL = fixtureRoot.appendingPathComponent("interrupted.sqlite")
  try probe.createNMinusOneFixture(at: interruptedURL)
  let interrupted = try probe.migrateToCurrent(
    at: interruptedURL,
    fault: .interruptAfterFirstCurrentTable
  )

  let report = PersistenceMigrationReport(
    runID: UUID(),
    scenarios: [
      evaluateSuccessful(name: "n-minus-one-to-current", attempt: first),
      evaluateSuccessful(name: "repeat-current-migration", attempt: repeated),
      evaluateInterrupted(attempt: interrupted),
    ]
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  try fileManager.createDirectory(
    at: summaryURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try encoder.encode(report).write(to: summaryURL, options: .atomic)

  guard report.status == .pass else {
    throw CLIError.probeFailed
  }
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard arguments.count == 2, arguments[0] == "--summary" else {
    throw CLIError.invalidArguments
  }
  try run(summaryURL: URL(fileURLWithPath: arguments[1]))
  print("persistence migration probe passed")
} catch {
  FileHandle.standardError.write(Data("persistence migration probe failed: \(error)\n".utf8))
  exit(1)
}
