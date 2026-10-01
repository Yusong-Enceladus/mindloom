import Foundation
import MindloomSpaces

/// One simulated member Mac: its own device keys, space keys and local
/// state, talking to a (fake or real) Spark.
public struct TestMac: Sendable {
  public let name: String
  public let engine: SpaceEngine
  public let states: MemorySpaceStateStore
  public let keys: MemorySpaceKeyStore

  public init(_ name: String, spark: FakeSpaceSpark) {
    self.name = name
    states = MemorySpaceStateStore()
    keys = MemorySpaceKeyStore()
    let device = SpaceDeviceKeys.generate()
    engine = SpaceEngine(
      client: SpaceClient(transport: spark, device: device, now: { spark.now }), states: states,
      keys: keys, now: { spark.now })
  }
}
