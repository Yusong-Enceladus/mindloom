import Darwin
import Foundation
import MindloomAgentProtocol

/// The Chrome extension's native messaging host (V8 contract A6). Chrome
/// starts this helper with the extension's origin as its first argument and
/// sends length-prefixed JSON on stdin; each message becomes one owner
/// request (`mindloom/owner.browserAdd`) over the App's private socket, and
/// the App's answer goes back the same way. It holds nothing, fetches
/// nothing and logs no content. An origin other than our extension gets one
/// refusal and nothing is read or forwarded.
struct BrowserHostRunner {
  let socketPath: String?
  let origin: String

  static let replyTimeoutSeconds: Int32 = 60

  func run() -> Never {
    // Chrome starts a host in the host's own folder, which is inside the
    // signed App bundle. Work from the temporary folder instead, so nothing
    // (a debug build's coverage file, say) can ever land in the bundle.
    _ = FileManager.default.changeCurrentDirectoryPath(NSTemporaryDirectory())
    guard BrowserExtension.isAllowedOrigin(origin) else {
      log("refused a host launch for another extension")
      write(.failure(.origin, BrowserCopy.notOurExtension))
      exit(2)
    }
    var reader = NativeMessaging.FrameReader()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = read(STDIN_FILENO, &chunk, chunk.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { break }
      for message in reader.append(Data(chunk[0..<count])) {
        switch message {
        case .success(let value): write(handle(value))
        case .failure(.tooLarge): write(.failure(.tooLong, BrowserCopy.tooLong))
        case .failure: write(.failure(.malformed, BrowserCopy.malformed))
        }
      }
      // A frame over the limit leaves the stream out of step: stop.
      if reader.failed != nil { exit(2) }
    }
    exit(0)
  }

  func handle(_ message: JSONValue) -> BrowserReply {
    let request: BrowserAddRequest
    switch BrowserAddRequest.parse(message) {
    case .failure(.malformed): return .failure(.malformed, BrowserCopy.malformed)
    case .failure(.empty): return .failure(.empty, BrowserCopy.empty)
    case .failure(.tooLong): return .failure(.tooLong, BrowserCopy.tooLong)
    case .success(let parsed): request = parsed
    }
    let outcome = OwnerSocketCall.perform(
      socketPath: socketPath, method: OwnerChannel.browserAddMethod, params: request.params,
      timeoutSeconds: Self.replyTimeoutSeconds, log: log)
    switch outcome {
    case .notRunning, .noAnswer:
      return .failure(.notRunning, AgentCopy.notRunning)
    case .unreadable:
      return .failure(.refused, "织机的回答看不懂")
    case .reply(let reply):
      return BrowserReply(ok: true, message: reply.message, stored: reply.stored)
    case .error(let code, let message):
      switch code {
      case OwnerChannel.ErrorCode.disabled: return .failure(.disabled, message)
      case OwnerChannel.ErrorCode.notReady: return .failure(.notReady, message)
      default: return .failure(.refused, message)
      }
    }
  }

  private func write(_ reply: BrowserReply) {
    AgentSocketIO.writeAll(STDOUT_FILENO, NativeMessaging.frame(reply.json))
  }

  private func log(_ message: String) {
    // Chrome collects a host's stderr in its own log: never content.
    FileHandle.standardError.write(Data(("mindloom-mcp (Chrome): " + message + "\n").utf8))
  }
}
