import BestASRDomain
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import XCTest

/// Opt-in live smoke on the owner's Spark over a real SSH forward. It uses a
/// temporary synthetic library with one fabricated dictation and never opens
/// the normal bestASR library. Skipped unless the opt-in file exists; the
/// file's content is the Spark's ssh host name or alias.
@MainActor
final class RemoteOrganizerLiveSmokeTests: XCTestCase {
  func testSyntheticItemThroughOwnedSSHTunnel() async throws {
    let optInFile = "/tmp/bestasr-spark-synthetic-smoke.enabled"
    guard
      let host = try? String(contentsOfFile: optInFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !host.isEmpty
    else {
      throw XCTSkip(
        "Write the Spark's ssh host into the local opt-in file for the own-device smoke")
    }
    let library = try SyntheticOrganizerLibrary()
    let stateDirectory = library.root.appendingPathComponent("tunnels", isDirectory: true)
    try await library.store.enableRemoteLink(at: Date(timeIntervalSince1970: 0))
    let id = UUID()
    try await library.seedCompletedSession(
      id, createdAt: Date().timeIntervalSince1970,
      text: "虚构测试：周六为星河咖啡馆确认招牌设计。"
    )
    let launcher = SSHRemoteOrganizerTunnelLauncher(
      configuration: try RemoteOrganizerLinkConfiguration(host: host),
      stateDirectory: stateDirectory
    )
    let runtime = RemoteOrganizerRuntime(
      repository: library.store, launcher: launcher,
      http: URLSessionRemoteOrganizerTransport(), keys: testOrganizerKeys
    ) { _, _ in }
    runtime.start()
    var found = false
    for _ in 0..<90 {
      try await Task.sleep(for: .seconds(1))
      let projection = try await library.store.remoteProjection()
      if projection.events.contains(where: { $0.itemIDs.contains(id.uuidString) }) {
        found = true
        break
      }
    }
    runtime.stop()
    XCTAssertEqual(RemoteOrganizerProcessRegistry.activeCount, 0, "tunnel left running")
    XCTAssertTrue(
      RemoteOrganizerTunnelRecordStore(directory: stateDirectory).records().isEmpty
    )
    XCTAssertTrue(found, "synthetic item did not reach the Spark projection")
    await library.close()
  }
}
