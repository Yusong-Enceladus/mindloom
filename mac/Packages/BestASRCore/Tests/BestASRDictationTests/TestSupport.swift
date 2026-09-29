import BestASRDictation
import BestASRDomain
import Foundation

func testUUID(_ value: UInt64) -> UUID {
  let suffix = String(format: "%012llx", value)
  return UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
}

func testDigest(_ character: Character = "a") throws -> SHA256Digest {
  try SHA256Digest(String(repeating: String(character), count: 64))
}

func testTarget() throws -> DictationTargetSnapshot {
  DictationTargetSnapshot(
      processIdentifier: 42, bundleIdentifier: "com.example.editor", isSecure: false)
}

struct FixedDictationClock: DictationClock {
  let value: UInt64
  func wallTime() -> Date { Date(timeIntervalSince1970: 1_753_286_400) }
  func monotonicNanoseconds() -> UInt64 { value }
}

actor CapturingDictationDiagnostics: DictationDiagnosticSink {
  private(set) var events: [DictationDiagnosticEvent] = []

  func record(_ event: DictationDiagnosticEvent) {
    events.append(event)
  }

  func snapshot() -> [DictationDiagnosticEvent] { events }
}
