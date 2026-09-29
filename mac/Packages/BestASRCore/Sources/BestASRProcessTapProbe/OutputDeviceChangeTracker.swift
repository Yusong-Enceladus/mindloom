import Foundation

public struct OutputDeviceChangeTracker: Sendable {
  private var lastDeviceID: UInt32?

  public init() {}

  public mutating func observe(
    deviceID: UInt32,
    monotonicNanoseconds: UInt64
  ) -> ProcessTapLifecycleEvent? {
    defer { lastDeviceID = deviceID }
    guard let lastDeviceID, lastDeviceID != deviceID else {
      return nil
    }
    return ProcessTapLifecycleEvent(
      kind: .deviceChanged,
      monotonicNanoseconds: monotonicNanoseconds,
      detail: "default-output-object-changed"
    )
  }
}
