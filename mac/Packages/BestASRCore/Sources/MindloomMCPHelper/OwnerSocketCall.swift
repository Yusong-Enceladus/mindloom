import Darwin
import Foundation
import MindloomAgentProtocol

/// One owner request over the App's private socket and its answer: used by
/// the `mindloom` command line (A3) and the Chrome extension's native
/// messaging host (A6). The same folder, mode and peer checks as the MCP
/// helper; a fresh connection per request, so the connection's first line is
/// the owner request and the App treats it as the owner's, never an agent's.
enum OwnerSocketCall {
  enum Outcome: Equatable {
    /// No verified socket (the App is not running) or the write failed.
    case notRunning
    /// The App closed the connection or did not answer in time.
    case noAnswer
    /// An answer that is not an owner reply.
    case unreadable
    case reply(OwnerReply)
    case error(code: Int, message: String)
  }

  static func perform(
    socketPath: String?, method: String, params: JSONValue, timeoutSeconds: Int32,
    log: (String) -> Void
  ) -> Outcome {
    guard let socketPath, let descriptor = AgentSocketClient.connectVerified(socketPath, log: log)
    else { return .notRunning }
    defer { close(descriptor) }
    let request: JSONValue = MCPMessage.request(id: .int(1), method: method, params: params)
    guard AgentSocketIO.writeAll(descriptor, Data((request.serialized + "\n").utf8)) else {
      return .notRunning
    }
    guard let line = readLine(descriptor, timeoutSeconds: timeoutSeconds) else {
      return .noAnswer
    }
    switch MCPMessage.decode(line) {
    case .response(_, let result):
      guard let reply = OwnerReply(result: result) else { return .unreadable }
      return .reply(reply)
    case .errorResponse(_, let code, let message):
      return .error(code: code, message: message)
    default:
      return .unreadable
    }
  }

  private static func readLine(_ descriptor: Int32, timeoutSeconds: Int32) -> String? {
    var buffer = AgentLineBuffer()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
      var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let ready = poll(&poller, 1, 500)
      if ready < 0, errno == EINTR { continue }
      guard ready > 0 else { continue }
      let count = read(descriptor, &chunk, chunk.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { return nil }
      if let line = buffer.append(Data(chunk[0..<count])).first { return line }
    }
    return nil
  }
}
