import Foundation

if CommandLine.arguments.contains("--crash-worker") {
  runSQLCipherCrashWorker()
}

let defaultSummary = "artifacts/evidence/SPIKE-SEC-001/summary.json"
let defaultMatrix = "artifacts/evidence/SPIKE-SEC-001/matrix.json"

func argumentValue(_ name: String, default fallback: String) -> String {
  guard let index = CommandLine.arguments.firstIndex(of: name),
    CommandLine.arguments.indices.contains(index + 1)
  else {
    return fallback
  }
  return CommandLine.arguments[index + 1]
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

do {
  let summaryPath = argumentValue("--summary", default: defaultSummary)
  let matrixPath = argumentValue("--matrix", default: defaultMatrix)
  let runID = UUID()
  let probeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
    "bestasr-security-probe-\(runID.uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(
    at: probeRoot,
    withIntermediateDirectories: true
  )
  defer { try? FileManager.default.removeItem(at: probeRoot) }

  let sqlCipherMatrix = SQLCipherMatrix(
    root: probeRoot.appendingPathComponent("sqlcipher", isDirectory: true)
  )
  try FileManager.default.createDirectory(
    at: sqlCipherMatrix.root,
    withIntermediateDirectories: true
  )
  let envelopeRoot = probeRoot.appendingPathComponent(
    "envelope",
    isDirectory: true
  )
  try FileManager.default.createDirectory(
    at: envelopeRoot,
    withIntermediateDirectories: true
  )
  let envelopeMatrix = EnvelopeMatrix(root: envelopeRoot)
  let scenarios = sqlCipherMatrix.run() + envelopeMatrix.run()

  let cipherVersion =
    scenarios
    .first { $0.scenarioID == "sqlcipher-encryption-at-rest" }?
    .metrics["cipherVersion"] ?? "unavailable"
  let matrixEvidence = SecurityProbeMatrixEvidence(
    schemaVersion: 1,
    kind: "security-storage-matrix",
    spikeID: "SPIKE-SEC-001",
    runID: runID,
    generatedAt: Date(),
    sqlCipherPackageVersion: "4.16.0 (runtime \(cipherVersion))",
    scenarios: scenarios
  )
  try writeJSON(matrixEvidence, to: matrixPath)

  let failed = scenarios.filter { $0.status == "fail" }
  let conclusion = failed.isEmpty ? "conditional" : "fail"
  let unmetCriteria: [String]
  if failed.isEmpty {
    unmetCriteria = [
      "GRDB 7.10.0 must be built and exercised against SQLCipher rather than system SQLite before ADR-0002 can be accepted.",
      "The 10,000-dictation plus 1,000-hour metadata FTS performance matrix remains pending.",
      "XPC access and signed/notarized app packaging with the SQLCipher XCFramework remain pending.",
    ]
  } else {
    unmetCriteria = failed.map { "Failed scenario: \($0.scenarioID)" }
  }
  let matrixEvidenceRef = "artifacts/evidence/SPIKE-SEC-001/matrix.json"
  let summary = SpikeSummary(
    schemaVersion: 1,
    kind: "spike-summary",
    spikeID: "SPIKE-SEC-001",
    runID: runID,
    question:
      "Do SQLCipher and CryptoKit/Keychain envelope designs preserve confidentiality, integrity, backup, migration, and crash recovery semantics?",
    environmentRef: "artifacts/evidence/environment/check-summary.json",
    criteria: SpikeCriteria(
      pass: [
        "Encrypted stores expose neither a plaintext SQLite header nor a synthetic content marker at rest.",
        "Correct keys restore data while wrong keys, tampering, and corruption fail closed.",
        "Backup, interrupted migration, atomic envelope replacement, and process-crash recovery preserve committed data without a silent reset.",
        "Keychain loss is reported explicitly and does not delete or replace encrypted data.",
      ],
      fail: [
        "Any wrong key, tampered payload, or corrupt database is accepted as valid.",
        "A failed migration, interrupted commit, or process crash loses committed source data or silently creates a new store.",
      ]
    ),
    commands: [["script/run_security_storage_probe.sh"]],
    matrix: scenarios.map {
      SpikeMatrixReference(
        scenarioID: $0.scenarioID,
        status: $0.status,
        evidenceRefs: [matrixEvidenceRef]
      )
    },
    conclusion: conclusion,
    unmetCriteria: unmetCriteria
  )
  try writeJSON(summary, to: summaryPath)

  if failed.isEmpty {
    print("SPIKE-SEC-001 matrix passed; conclusion remains conditional")
  } else {
    fputs("SPIKE-SEC-001 matrix failed\n", stderr)
    exit(1)
  }
} catch {
  fputs("security storage probe failed: \(String(describing: type(of: error)))\n", stderr)
  exit(1)
}
