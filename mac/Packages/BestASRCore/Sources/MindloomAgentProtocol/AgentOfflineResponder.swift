import Foundation

/// What the helper answers by itself while the App is not running
/// (AGENT-CONTRACT §1): the handshake and the tool list work, so the agent
/// can see what Mindloom offers to read (the change tools are listed only
/// to a grant that may change, which only the App knows), and every tool
/// call returns "Mindloom 没有在运行，请先打开 Mindloom". Nothing from the
/// library is known here, so `resources/list` is an empty list (no grant can
/// be checked: nothing is listed before a grant). An error there would also
/// make Claude Code retry it three times at every start.
public enum AgentOfflineResponder {
  /// The reply to one message, or nil for a notification.
  public static func reply(to message: MCPMessage) -> JSONValue? {
    switch message {
    case .request(let id, let method, let params):
      return reply(id: id, method: method, params: params)
    case .invalid(let id, let code, let text):
      return MCPMessage.error(id: id, code: code, message: text)
    case .notification, .response, .errorResponse:
      return nil
    }
  }

  public static func reply(id: JSONValue, method: String, params: JSONValue?) -> JSONValue {
    switch method {
    case "initialize":
      return MCPMessage.result(
        id: id,
        MCPServerInfo.initializeResult(requestedVersion: params?["protocolVersion"]?.stringValue))
    case "ping":
      return MCPMessage.result(id: id, [:])
    case "tools/list":
      return MCPMessage.result(id: id, AgentTool.listResult(includingChanges: false))
    case "tools/call":
      return MCPMessage.result(id: id, notRunningToolResult)
    case "resources/templates/list":
      return MCPMessage.result(id: id, AgentResource.templatesResult)
    case "resources/list":
      return MCPMessage.result(id: id, emptyResourceList)
    case "resources/read":
      return notRunningError(id: id)
    default:
      return MCPMessage.error(
        id: id, code: MCPErrorCode.methodNotFound, message: "Method not found")
    }
  }

  /// The reply while the owner has 允许其他 App 读 off: the handshake and the
  /// read tools' list work, every call says the switch is off.
  public static func switchedOffReply(to message: MCPMessage) -> JSONValue? {
    guard case .request(let id, let method, _) = message else { return reply(to: message) }
    switch method {
    case "tools/call":
      return MCPMessage.result(
        id: id,
        AgentToolResult.make(
          text: AgentCopy.switchedOff,
          data: ["error": "switched_off", "message": .string(AgentCopy.switchedOff)],
          isError: true))
    case "resources/list":
      return MCPMessage.result(id: id, emptyResourceList)
    case "resources/read":
      return MCPMessage.error(id: id, code: MCPErrorCode.notAllowed, message: AgentCopy.switchedOff)
    default:
      return reply(to: message)
    }
  }

  /// `resources/list` when nothing may be listed.
  public static let emptyResourceList: JSONValue = ["resources": []]

  /// A tool error the agent reads (`isError`), in plain Chinese. Its data
  /// (no library text) always rides along in `_meta`.
  public static var notRunningToolResult: JSONValue {
    AgentToolResult.make(
      text: AgentCopy.notRunning,
      data: ["error": "not_running", "message": .string(AgentCopy.notRunning)], isError: true)
  }

  public static func notRunningError(id: JSONValue?) -> JSONValue {
    MCPMessage.error(id: id, code: MCPErrorCode.notRunning, message: AgentCopy.notRunning)
  }

  /// The reply for a request the App took but never answered (it quit or
  /// the connection broke mid-call).
  public static func interruptedReply(id: JSONValue, method: String) -> JSONValue {
    method == "tools/call"
      ? MCPMessage.result(id: id, notRunningToolResult) : notRunningError(id: id)
  }
}
