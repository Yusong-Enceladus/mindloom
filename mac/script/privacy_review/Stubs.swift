import Foundation
public protocol RemoteOrganizerImageRedacting: Sendable {
  func redactedSendCopy(of data: Data, mediaType: String) throws -> Data
}
public enum UserItemLimits {
  public static let maximumSendableImageBytes = 12 * 1_024 * 1_024
  public static let normalizedImageLongSide = 2_560
  public static let maximumExtraAnimationFrames = 3
}
