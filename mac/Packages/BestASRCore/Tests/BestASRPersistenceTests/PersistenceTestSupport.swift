import BestASRDictation
import BestASRDomain
import Foundation

func persistenceUUID(_ value: UInt64) -> UUID {
  UUID(
    uuidString: String(
      format: "00000000-0000-4000-8000-%012llx",
      value
    )
  )!
}

func persistenceDigest(_ character: Character = "a") throws -> SHA256Digest {
  try SHA256Digest(String(repeating: String(character), count: 64))
}

func persistenceTarget() throws -> DictationTargetSnapshot {
  DictationTargetSnapshot(
      processIdentifier: 99, bundleIdentifier: "com.example.fixture", isSecure: false)
}

func preparingSnapshot(
  sessionID: SessionID,
  revision: UInt64 = 1
) throws -> DictationSessionSnapshot {
  DictationSessionSnapshot(
    sessionID: sessionID,
    revision: revision,
    phase: .preparing,
    target: try persistenceTarget(),
    timeline: [
      DictationTimelineMarker(kind: .started, monotonicNanoseconds: 10)
    ]
  )
}

func persistenceTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
