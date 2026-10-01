import Foundation

/// What the helper answers by itself while the App is not running
/// (AGENT-CONTRACT §1): the handshake and the tool list work, so the agent
/// can see what 织机 offers, and every tool call returns
/// "织机没有在运行，请先打开织机". Nothing from the library is known here.
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
      return MCPMessage.result(id: id, AgentTool.listResult)
    case "tools/call":
      return MCPMessage.result(id: id, notRunningToolResult)
    case "resources/templates/list":
      return MCPMessage.result(id: id, AgentResource.templatesResult)
    case "resources/list", "resources/read":
      return notRunningError(id: id)
    default:
      return MCPMessage.error(
        id: id, code: MCPErrorCode.methodNotFound, message: "Method not found")
    }
  }

  /// A tool error the agent reads (`isError`), in plain Chinese.
  public static var notRunningToolResult: JSONValue {
    [
      "content": [["type": "text", "text": .string(AgentCopy.notRunning)]],
      "structuredContent": ["error": "not_running", "message": .string(AgentCopy.notRunning)],
      "isError": true,
    ]
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
