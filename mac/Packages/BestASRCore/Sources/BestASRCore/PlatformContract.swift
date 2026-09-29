import Foundation

/// Compile-time product constraints shared by the app, tools, and probes.
public enum PlatformContract: Sendable {
  public static let minimumMacOS = OperatingSystemVersion(
    majorVersion: 14,
    minorVersion: 2,
    patchVersion: 0
  )

  public static let supportedArchitecture = "arm64"
  public static let minimumUnifiedMemoryBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024
  public static let productTelemetryEnabledByDefault = false
}

public struct WorkspaceIdentity: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let product: String
  public let minimumMacOS: String
  public let architecture: String
  public let swiftLanguageMode: String

  public init(
    schemaVersion: Int = 1,
    product: String = "bestASR",
    minimumMacOS: String = "14.2",
    architecture: String = PlatformContract.supportedArchitecture,
    swiftLanguageMode: String = "6"
  ) {
    self.schemaVersion = schemaVersion
    self.product = product
    self.minimumMacOS = minimumMacOS
    self.architecture = architecture
    self.swiftLanguageMode = swiftLanguageMode
  }
}
