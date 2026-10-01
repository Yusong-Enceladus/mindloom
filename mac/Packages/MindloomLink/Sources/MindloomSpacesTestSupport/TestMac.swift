import Foundation
import MindloomSpaces

/// One simulated member Mac: its own device keys, space keys and local
/// state, talking to a (fake or real) Spark.
public struct TestMac: Sendable {
  public let name: String
  public let engine: SpaceEngine
  public let states: MemorySpaceStateStore
  public let keys: MemorySpaceKeyStore
  public let outbox: any SpaceOutboxStore
  public let device: SpaceDeviceKeys

  public init(_ name: String, spark: FakeSpaceSpark) {
    self.init(name, spark: spark, transport: spark)
  }

  /// A Mac with its own transport (a member's credential, as the gate's
  /// bridge adds it), keys and outbox.
  public init(
    _ name: String, spark: FakeSpaceSpark, transport: any SpaceTransport,
    device: SpaceDeviceKeys = .generate(), states: MemorySpaceStateStore = MemorySpaceStateStore(),
    keys: MemorySpaceKeyStore = MemorySpaceKeyStore(),
    outbox: any SpaceOutboxStore = MemorySpaceOutboxStore()
  ) {
    self.name = name
    self.states = states
    self.keys = keys
    self.outbox = outbox
    self.device = device
    engine = SpaceEngine(
      client: SpaceClient(transport: transport, device: device, now: { spark.now }), states: states,
      keys: keys, outbox: outbox, now: { spark.now })
  }

  /// The access routes as this Mac reaches them.
  public func accessClient(_ transport: any SpaceTransport, spark: FakeSpaceSpark) -> AccessClient {
    AccessClient(client: SpaceClient(transport: transport, device: device, now: { spark.now }))
  }
}
