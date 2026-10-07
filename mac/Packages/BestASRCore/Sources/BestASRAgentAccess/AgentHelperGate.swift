import Darwin
import Foundation
import MindloomAgentProtocol
import Security

/// Who may talk to the App's socket at all (v12 F8; AGENT-IO N2): only the
/// `mindloom-mcp` helper bundled with this App. The owner check (a process of
/// this user) still runs first; this gate then reads the peer's code signature
/// from the kernel and checks it against the bundled helper's:
///
/// - When this App and its helper are signed by a developer team, the peer
///   must carry the helper's signing identifier and be signed by that same
///   team (`anchor apple generic`, the team in the leaf certificate).
/// - When they are signed ad hoc (Debug and check builds), the peer must be
///   exactly the bundled helper's code (its code directory hash).
///
/// So another program of this user (an agent's other MCP servers, a script)
/// cannot open a session by connecting directly and borrow a grant. A program
/// that runs the helper itself still can; the helper then reports that
/// program as the client, so the owner is asked about it by its own name and
/// signature. This identifies; it is not a wall against this user's programs
/// (the library files are this user's too, AGENT-IO N1).
public struct AgentHelperGate: Sendable, CustomStringConvertible {
  enum Rule: Sendable, Equatable {
    /// Tests and the synthetic test host only.
    case anyProcessOfThisUser
    /// A code requirement in Apple's requirement language.
    case requirement(String)
    /// The helper could not be found or read: nobody gets in.
    case nobody
  }

  let rule: Rule

  /// Every process of this user (the owner check alone). Never the App's.
  public static let anyProcessOfThisUser = AgentHelperGate(rule: .anyProcessOfThisUser)

  /// Only the helper at `helper` (normally `Contents/Helpers/mindloom-mcp`).
  public static func bundled(helper: URL, appTeam: String? = ownTeam()) -> AgentHelperGate {
    guard let signature = staticSignature(helper) else { return AgentHelperGate(rule: .nobody) }
    if let team = signature.team, let appTeam, team == appTeam,
      Self.isPlain(signature.identifier), Self.isPlain(team)
    {
      return AgentHelperGate(
        rule: .requirement(
          "identifier \"\(signature.identifier)\" and anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(team)\""))
    }
    guard let cdhash = signature.cdhash, !cdhash.isEmpty else {
      return AgentHelperGate(rule: .nobody)
    }
    return AgentHelperGate(rule: .requirement("cdhash H\"\(cdhash.hexString)\""))
  }

  public var description: String {
    switch rule {
    case .anyProcessOfThisUser: "any process of this user"
    case .requirement(let text): text
    case .nobody: "nobody (the helper is missing or unsigned)"
    }
  }

  /// True when the connected peer is the bundled helper.
  public func admits(_ peer: AgentPeer) -> Bool {
    switch rule {
    case .anyProcessOfThisUser:
      return true
    case .nobody:
      return false
    case .requirement(let text):
      var requirement: SecRequirement?
      guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
        let requirement, let code = Self.guestCode(peer)
      else { return false }
      return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
  }

  /// The running peer's code: by its audit token when the kernel gave one
  /// (not reusable like a process ID), else by its process ID.
  static func guestCode(_ peer: AgentPeer) -> SecCode? {
    var code: SecCode?
    let attributes: CFDictionary
    if let token = peer.auditToken {
      attributes = [kSecGuestAttributeAudit: token as NSData] as CFDictionary
    } else {
      attributes = [kSecGuestAttributePid: NSNumber(value: peer.pid)] as CFDictionary
    }
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else {
      return nil
    }
    return code
  }

  struct StaticSignature {
    let identifier: String
    let team: String?
    let cdhash: Data?
  }

  /// The signing identifier, team and code directory hash of a file on disk.
  static func staticSignature(_ url: URL) -> StaticSignature? {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
      SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
    else { return nil }
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        == errSecSuccess,
      let dictionary = info as? [String: Any],
      let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
    else { return nil }
    let team = (dictionary[kSecCodeInfoTeamIdentifier as String] as? String).flatMap {
      $0.isEmpty ? nil : $0
    }
    return StaticSignature(
      identifier: identifier, team: team,
      cdhash: dictionary[kSecCodeInfoUnique as String] as? Data)
  }

  /// This process's own team (nil when ad hoc or unsigned).
  public static func ownTeam() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
      let dictionary = info as? [String: Any],
      let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
    else { return nil }
    return team
  }

  /// Safe inside a quoted requirement string.
  static func isPlain(_ text: String) -> Bool {
    !text.isEmpty
      && text.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_"
      }
  }
}

extension Data {
  fileprivate var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
