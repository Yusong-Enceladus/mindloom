import BestASRDomain
import Foundation

/// A check build's pre-approval (v12 phase B end-to-end check): the first
/// consent request from this client is answered with these terms, without a
/// card on the owner's screen. The App honours it only in a build that is
/// not Release, launched with `-MindloomNoArm`, on a synthetic library, and
/// reads it from the launch arguments alone, never from saved preferences
/// (a `defaults write` would outlive the run; review v12-B #13). The client
/// is matched by the program the kernel reports (`path`, and the script an
/// interpreter runs, when given), not only by the name it gives itself. It is
/// never stored, and the grant it makes is an ordinary grant (secret,
/// audited calls, 停止允许).
///
/// Spec: `client=<mcp name>;path=<executable>;script=<path>;range=all|
/// matters:<id>,<id>;spaces=<id>,…;change=0|1;duration=once|today|always;
/// numbers=0|1` (`client` and `path` required).
public struct AgentPreapproval: Equatable, Sendable {
  public static let launchArgument = "MindloomAgentTestGrant"

  public let clientName: String
  /// The client's executable, exactly as the kernel reports it.
  public let path: String
  /// The script an interpreter client runs, when it must match too.
  public let script: String?
  public let terms: AgentGrantTerms

  public init(clientName: String, path: String, script: String? = nil, terms: AgentGrantTerms) {
    self.clientName = clientName
    self.path = path
    self.script = script
    self.terms = terms
  }

  /// The spec after `-MindloomAgentTestGrant`, read from the launch
  /// arguments only, when it is given exactly once.
  public static func launchSpec(arguments: [String]) -> String? {
    let mentions = arguments.indices.dropFirst().filter {
      arguments[$0].range(of: launchArgument, options: .caseInsensitive) != nil
    }
    guard mentions.count == 1, let index = mentions.first,
      arguments[index] == "-" + launchArgument, index + 1 < arguments.count,
      !arguments[index + 1].hasPrefix("-")
    else { return nil }
    return arguments[index + 1]
  }

  public static func parse(_ spec: String) -> AgentPreapproval? {
    var fields: [String: String] = [:]
    for part in spec.split(separator: ";") {
      let pair = part.split(separator: "=", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard pair.count == 2, !pair[0].isEmpty else { return nil }
      fields[pair[0]] = pair[1]
    }
    guard let client = fields["client"], !client.isEmpty,
      let path = fields["path"], path.hasPrefix("/")
    else { return nil }
    var terms = AgentGrantTerms()
    switch fields["range"] ?? "all" {
    case "all": terms.range = .all
    case let value where value.hasPrefix("matters:"):
      let ids = value.dropFirst("matters:".count).split(separator: ",").map(String.init)
      guard !ids.isEmpty else { return nil }
      terms.range = .matters(Set(ids))
    default: return nil
    }
    var spaces: Set<String> = [AgentSpaceID.personal]
    for id in (fields["spaces"] ?? "").split(separator: ",") {
      spaces.insert(AgentSpaceID.normalized(String(id)))
    }
    terms.spaces = spaces
    terms.canChange = fields["change"] == "1"
    guard let duration = AgentGrantDuration(rawValue: fields["duration"] ?? "once") else {
      return nil
    }
    terms.duration = duration
    terms.showNumbers = fields["numbers"] == "1"
    return AgentPreapproval(
      clientName: client, path: path, script: fields["script"].flatMap { $0.isEmpty ? nil : $0 },
      terms: terms)
  }

  /// The terms for this request, when it comes from that program under that
  /// name (and running that script, when one is named).
  public func answer(_ request: AgentConsentRequest) -> AgentGrantTerms? {
    let client = request.client
    guard client.name == clientName, client.executable == path || client.path == path,
      script == nil || client.script == script
    else { return nil }
    return terms
  }
}
