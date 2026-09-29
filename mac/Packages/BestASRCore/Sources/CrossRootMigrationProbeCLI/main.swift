import BestASRDomain
import BestASRMigrationProbe
import Foundation

private enum CLIError: Error {
  case invalidArguments
  case probeFailed
}

private func uuid(_ value: UInt64) -> UUID {
  UUID(
    uuidString: String(
      format: "00000000-0000-4000-8000-%012llx",
      value
    )
  )!
}

private func write(_ data: Data, to url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try data.write(to: url)
}

private func run(summaryURL: URL) throws {
  let fileManager = FileManager.default
  let fixtureRoot = fileManager.temporaryDirectory
    .appendingPathComponent("bestasr-cross-root-probe-\(UUID().uuidString)")
  defer {
    try? fileManager.removeItem(at: fixtureRoot)
  }
  let sourceRoot = fixtureRoot.appendingPathComponent("root-a", isDirectory: true)
  let packageRoot = fixtureRoot.appendingPathComponent("package", isDirectory: true)
  let destinationRoot = fixtureRoot.appendingPathComponent("root-b", isDirectory: true)
  try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

  let audioBytes = Data("synthetic source audio bytes".utf8)
  let modelBytes = Data("synthetic model artifact bytes".utf8)
  let audioDigest = try SHA256Digest(CrossRootFixtureTransfer.sha256(audioBytes))
  let modelDigest = try SHA256Digest(CrossRootFixtureTransfer.sha256(modelBytes))
  let audioReference = try PortableAssetReference(
    relativePath: "sessions/fixture/source.caf"
  )
  let modelReference = PortableAssetReference(contentDigest: modelDigest)
  try write(
    audioBytes,
    to: CrossRootFixtureTransfer.resolvedURL(
      for: audioReference,
      root: sourceRoot
    )
  )
  try write(
    modelBytes,
    to: CrossRootFixtureTransfer.resolvedURL(
      for: modelReference,
      root: sourceRoot
    )
  )

  let revision = try Revision(1)
  let sessionID = SessionID(uuid(1))
  let trackID = TrackID(uuid(2))
  let modelID = ModelArtifactID(uuid(3))
  let fixedDate = Date(timeIntervalSince1970: 1_753_286_400)
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
        assetReference: audioReference,
        sampleRateHertz: 48_000,
        channelCount: 1
      )
    ],
    chunks: [
      AudioChunk(
        id: ChunkID(uuid(4)),
        sessionID: sessionID,
        trackID: trackID,
        revision: revision,
        sequence: 0,
        monotonicStartNanoseconds: 1,
        frameCount: 48_000,
        contentDigest: audioDigest,
        assetReference: audioReference
      )
    ],
    timelineEvents: [],
    transcriptRevisions: [],
    durableJobs: [],
    modelArtifacts: [
      ModelArtifact(
        id: modelID,
        revision: revision,
        registryKey: "fixture-model",
        version: "1.0.0",
        capability: .asr,
        digest: modelDigest,
        directoryReference: modelReference,
        licenseIdentifier: "fixture-license",
        state: .active
      )
    ],
    sessionSpeakers: [],
    speakerOccurrences: [],
    persons: [],
    personCorrections: [],
    changeLog: [],
    tombstones: []
  )

  let manifest = try CrossRootFixtureTransfer.exportFixture(
    snapshot: snapshot,
    sourceRoot: sourceRoot,
    packageRoot: packageRoot
  )
  let imported = try CrossRootFixtureTransfer.importFixture(
    packageRoot: packageRoot,
    destinationRoot: destinationRoot
  )

  var identicalCount = 0
  for reference in [audioReference, modelReference] {
    let sourceData = try Data(
      contentsOf: CrossRootFixtureTransfer.resolvedURL(
        for: reference,
        root: sourceRoot
      )
    )
    let destinationData = try Data(
      contentsOf: CrossRootFixtureTransfer.resolvedURL(
        for: reference,
        root: destinationRoot
      )
    )
    if sourceData == destinationData {
      identicalCount += 1
    }
  }
  let manifestText = try String(
    contentsOf: packageRoot.appendingPathComponent("manifest.json"),
    encoding: .utf8
  )
  let absolutePathCount =
    manifestText.contains(sourceRoot.path)
      || manifestText.contains(destinationRoot.path)
      || manifestText.contains("/Users/")
    ? 1 : 0
  let stableUUIDs =
    imported.sessions.map(\.id) == snapshot.sessions.map(\.id)
    && imported.tracks.map(\.id) == snapshot.tracks.map(\.id)
    && imported.modelArtifacts.map(\.id) == snapshot.modelArtifacts.map(\.id)
  let referencesPreserved =
    imported.tracks.map(\.assetReference) == snapshot.tracks.map(\.assetReference)
    && imported.modelArtifacts.map(\.directoryReference)
      == snapshot.modelArtifacts.map(\.directoryReference)
  let passed =
    sourceRoot.path != destinationRoot.path
    && imported == snapshot
    && stableUUIDs
    && referencesPreserved
    && identicalCount == manifest.assets.count
    && absolutePathCount == 0
  let result = CrossRootRoundTripResult(
    runID: UUID(),
    status: passed ? "pass" : "fail",
    distinctRoots: sourceRoot.path != destinationRoot.path,
    stableUUIDsPreserved: stableUUIDs,
    relationshipsPreserved: imported == snapshot,
    relativeReferencesPreserved: referencesPreserved,
    byteIdenticalAssetCount: identicalCount,
    absolutePathsRecorded: absolutePathCount
  )

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  try fileManager.createDirectory(
    at: summaryURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try encoder.encode(result).write(to: summaryURL, options: .atomic)
  guard passed else {
    throw CLIError.probeFailed
  }
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard arguments.count == 2, arguments[0] == "--summary" else {
    throw CLIError.invalidArguments
  }
  try run(summaryURL: URL(fileURLWithPath: arguments[1]))
  print("cross-root migration probe passed")
} catch {
  FileHandle.standardError.write(Data("cross-root migration probe failed: \(error)\n".utf8))
  exit(1)
}
