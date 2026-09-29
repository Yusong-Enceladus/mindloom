import Foundation

public enum CaptureDiskState: String, Codable, Sendable {
  case available
  case hardStop
  case warning
}

public struct CaptureDiskSpaceDecision: Codable, Equatable, Sendable {
  public let state: CaptureDiskState
  public let availableBytes: UInt64
  public let warningThresholdBytes: UInt64
  public let hardStopThresholdBytes: UInt64

  public init(
    state: CaptureDiskState,
    availableBytes: UInt64,
    warningThresholdBytes: UInt64,
    hardStopThresholdBytes: UInt64
  ) {
    self.state = state
    self.availableBytes = availableBytes
    self.warningThresholdBytes = warningThresholdBytes
    self.hardStopThresholdBytes = hardStopThresholdBytes
  }
}

public struct CaptureDiskSpacePolicy: Codable, Equatable, Sendable {
  public let warningThresholdBytes: UInt64
  public let hardStopThresholdBytes: UInt64

  public init(
    warningThresholdBytes: UInt64 = 5 * 1_024 * 1_024 * 1_024,
    hardStopThresholdBytes: UInt64 = 1 * 1_024 * 1_024 * 1_024
  ) throws {
    guard hardStopThresholdBytes > 0,
      warningThresholdBytes > hardStopThresholdBytes
    else {
      throw ProductionAudioJournalError.invalidMetadata
    }
    self.warningThresholdBytes = warningThresholdBytes
    self.hardStopThresholdBytes = hardStopThresholdBytes
  }

  public func evaluate(availableBytes: UInt64) -> CaptureDiskSpaceDecision {
    let state: CaptureDiskState
    if availableBytes <= hardStopThresholdBytes {
      state = .hardStop
    } else if availableBytes <= warningThresholdBytes {
      state = .warning
    } else {
      state = .available
    }
    return CaptureDiskSpaceDecision(
      state: state,
      availableBytes: availableBytes,
      warningThresholdBytes: warningThresholdBytes,
      hardStopThresholdBytes: hardStopThresholdBytes
    )
  }
}

public struct VolumeDiskSpaceMonitor: Sendable {
  public init() {}

  public func availableBytes(at url: URL) throws -> UInt64 {
    let values = try url.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey]
    )
    guard let available = values.volumeAvailableCapacityForImportantUsage,
      available >= 0
    else {
      throw ProductionAudioJournalError.fileOperation("disk-capacity")
    }
    return UInt64(available)
  }
}
