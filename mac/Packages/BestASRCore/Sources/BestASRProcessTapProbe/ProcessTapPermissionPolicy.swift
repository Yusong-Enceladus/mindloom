import Foundation

public enum ProcessTapPermissionDecision: String, Codable, Sendable {
  case authorized
  case denied
}

public enum ProcessTapPermissionPolicyError: Error, Equatable {
  case denied
}

public enum ProcessTapPermissionPolicy {
  public static func requireAuthorized(
    _ decision: ProcessTapPermissionDecision
  ) throws {
    guard decision == .authorized else {
      throw ProcessTapPermissionPolicyError.denied
    }
  }
}
