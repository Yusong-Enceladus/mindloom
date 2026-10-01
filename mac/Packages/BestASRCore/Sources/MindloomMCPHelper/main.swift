// mindloom-mcp: the MCP server an agent (Claude Code, Claude Desktop, Codex,
// Cursor …) starts over stdio; with a command (`add`, `due`) or under the
// name `mindloom`, the owner's own command line (OwnerCommandLineRunner);
// started by Chrome with an extension origin, the native messaging host of
// the Chrome extension 「收进织机」 (BrowserHostRunner).
// It holds no library data and no secret: it forwards each MCP message to
// the running 织机 App over a Unix socket in the data root's private folder
// and forwards the App's answers back
// (AGENT-CONTRACT §1). The App decides everything (consent, scope, masking,
// audit). While the App is not running, this helper answers the handshake
// and the tool list itself and every tool call returns
// "织机没有在运行，请先打开织机".
//
// The socket is used only when its folder (0700) and the socket (0600)
// belong to this user and the process listening on it is this user's
// (kernel peer credentials plus libproc), the same owner check the App
// applies to the helper.

import Darwin
import Foundation
import MindloomAgentProtocol

final class Bridge: @unchecked Sendable {
  private let socketPath: String?
  private let lock = NSLock()
  private let outputLock = NSLock()
  private var socket: Int32 = -1
  /// The client's own `initialize` params, replayed when the App appears
  /// (or comes back) during a session.
  private var initializeParams: JSONValue?
  private var clientInitialized = false
  /// Requests forwarded to the App and not answered yet: serialized id →
  /// (id, method).
  private var inFlight: [String: (id: JSONValue, method: String)] = [:]
  private var replayIDs: Set<String> = []
  private var replayCounter = 0

  init(socketPath: String?) {
    self.socketPath = socketPath
  }

  // MARK: Output

  private func emit(_ value: JSONValue) {
    outputLock.lock()
    defer { outputLock.unlock() }
    AgentSocketIO.writeAll(STDOUT_FILENO, Data((value.serialized + "\n").utf8))
  }

  private func log(_ message: String) {
    // stderr is where MCP clients collect a server's diagnostics. Never
    // content: only what happened to the connection.
    FileHandle.standardError.write(Data(("mindloom-mcp: " + message + "\n").utf8))
  }

  // MARK: Connection

  /// A verified connection to the App, or -1. A new connection first
  /// replays the client's earlier handshake unless `replay` is false (the
  /// message about to be forwarded is the handshake itself).
  private func connectedSocket(replay shouldReplay: Bool, replayInitialized: Bool) -> Int32 {
    lock.lock()
    let current = socket
    lock.unlock()
    if current >= 0 { return current }
    guard let socketPath, let descriptor = AgentSocketClient.connectVerified(socketPath, log: log)
    else {
      return -1
    }
    lock.lock()
    socket = descriptor
    let replay = shouldReplay ? initializeParams : nil
    let initialized = clientInitialized && replayInitialized
    lock.unlock()
    let reader = Thread { [weak self] in self?.readApp(descriptor) }
    reader.name = "mindloom-mcp.app-reader"
    reader.start()
    // The App starts a fresh session per connection: tell it who the
    // client is, as the client told us.
    if let replay {
      lock.lock()
      replayCounter += 1
      let id = JSONValue.string("mindloom-helper-replay-\(replayCounter)")
      replayIDs.insert(id.serialized)
      lock.unlock()
      _ = send(MCPMessage.request(id: id, method: "initialize", params: replay), to: descriptor)
      if initialized {
        _ = send(MCPMessage.notification(method: "notifications/initialized"), to: descriptor)
      }
    }
    return descriptor
  }

  private func send(_ value: JSONValue, to descriptor: Int32) -> Bool {
    AgentSocketIO.writeAll(descriptor, Data((value.serialized + "\n").utf8))
  }

  private func disconnect(_ descriptor: Int32) {
    lock.lock()
    guard socket == descriptor else {
      lock.unlock()
      return
    }
    socket = -1
    let pending = inFlight
    inFlight = [:]
    replayIDs = []
    lock.unlock()
    shutdown(descriptor, SHUT_RDWR)
    close(descriptor)
    // Whatever the App was working on is answered, so the agent never waits
    // for a reply that cannot come.
    for (_, request) in pending.sorted(by: { $0.key < $1.key }) {
      emit(AgentOfflineResponder.interruptedReply(id: request.id, method: request.method))
    }
  }

  // MARK: App → agent

  private func readApp(_ descriptor: Int32) {
    var buffer = AgentLineBuffer()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = read(descriptor, &chunk, chunk.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { break }
      for line in buffer.append(Data(chunk[0..<count])) {
        guard let value = try? JSONValue.parse(line) else { continue }
        if let id = value["id"], value["method"] == nil {
          let key = id.serialized
          lock.lock()
          let isReplay = replayIDs.remove(key) != nil
          if !isReplay { inFlight[key] = nil }
          lock.unlock()
          if isReplay { continue }
        }
        emit(value)
      }
    }
    disconnect(descriptor)
  }

  // MARK: Agent → App

  func handle(_ line: String) {
    let message = MCPMessage.decode(line)
    var isInitialize = false
    var isInitialized = false
    switch message {
    case .request(_, "initialize", _): isInitialize = true
    case .notification("notifications/initialized", _): isInitialized = true
    case .invalid:
      if let reply = AgentOfflineResponder.reply(to: message) { emit(reply) }
      return
    case .request(let id, let method, _) where OwnerChannel.isOwnerMethod(method):
      // The owner's command-line methods are never an agent's: not
      // forwarded, whatever the agent sends (V8 contract A3).
      emit(MCPMessage.error(id: id, code: MCPErrorCode.methodNotFound, message: "Method not found"))
      return
    case .notification(let method, _) where OwnerChannel.isOwnerMethod(method):
      return
    default: break
    }
    let descriptor = connectedSocket(replay: !isInitialize, replayInitialized: !isInitialized)
    lock.lock()
    if isInitialize, case .request(_, _, let params) = message {
      initializeParams = params ?? [:]
      clientInitialized = false
    }
    if isInitialized { clientInitialized = true }
    lock.unlock()
    if descriptor >= 0 {
      if case .request(let id, let method, _) = message {
        lock.lock()
        inFlight[id.serialized] = (id, method)
        lock.unlock()
      }
      if send(line.jsonLine, to: descriptor) { return }
      // The App went away between the check and the write: `disconnect`
      // answers what was in flight; a request registered after the reader
      // already disconnected is answered here.
      disconnect(descriptor)
      if case .request(let id, let method, _) = message {
        lock.lock()
        let stranded = inFlight.removeValue(forKey: id.serialized) != nil
        lock.unlock()
        if stranded { emit(AgentOfflineResponder.interruptedReply(id: id, method: method)) }
      }
      return
    }
    if let reply = AgentOfflineResponder.reply(to: message) { emit(reply) }
  }

  private func send(_ line: Data, to descriptor: Int32) -> Bool {
    AgentSocketIO.writeAll(descriptor, line)
  }

  func run() -> Never {
    var buffer = AgentLineBuffer()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = read(STDIN_FILENO, &chunk, chunk.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { break }
      for line in buffer.append(Data(chunk[0..<count])) { handle(line) }
    }
    lock.lock()
    let descriptor = socket
    lock.unlock()
    if descriptor >= 0 { close(descriptor) }
    exit(0)
  }
}

extension String {
  /// The line as the client sent it, newline-terminated.
  fileprivate var jsonLine: Data { Data((self + "\n").utf8) }
}

signal(SIGPIPE, SIG_IGN)
let environment = ProcessInfo.processInfo.environment
let socketPath = AgentSocketLocation.dataRoot(environment: environment).map {
  AgentSocketLocation.socketURL(dataRoot: $0).path
}
let arguments = CommandLine.arguments.dropFirst()
// Chrome starts a native messaging host with the calling extension's origin
// as the first argument (V8 contract A6). Any other origin is refused there.
if let origin = arguments.first, BrowserExtension.isHostLaunch(origin) {
  BrowserHostRunner(socketPath: socketPath, origin: origin).run()
}
// `mindloom add …` / `mindloom due`: the owner's own command line (V8
// contract A3), the same binary under a second name or with a command.
let invokedAsMindloom =
  CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent == "mindloom" } ?? false
if invokedAsMindloom || arguments.first.map(OwnerCommand.commands.contains) == true {
  OwnerCommandLineRunner(socketPath: socketPath).run(Array(arguments))
}
if arguments.contains("--version") {
  print("mindloom-mcp \(MCPServerInfo.version)")
  exit(0)
}
if arguments.contains("--check") {
  // For the docs' "is it connected?" step; says nothing about the library.
  if let socketPath, let descriptor = AgentSocketClient.connectVerified(socketPath, log: { _ in }) {
    close(descriptor)
    print("织机在运行，可以连接")
    exit(0)
  }
  print(AgentCopy.notRunning)
  exit(1)
}
if arguments.contains("--help") {
  print(
    """
    mindloom-mcp：织机的 MCP 服务（stdio）。由 Claude Code、Claude Desktop 等启动，不需要手动运行。
      --check    检查织机是否在运行
      --version  版本
    同一个程序也是你自己的命令行入口（需要在设置 → 入口里打开）：
      mindloom-mcp add "文字" / --file 路径 / 管道输入；mindloom-mcp due
      以 mindloom 的名字链接它之后：mindloom add …、mindloom due
    它也是 Chrome 扩展「收进织机」的本机连接程序，由 Chrome 启动（需要在设置 → 入口里打开「Chrome 扩展」）。
    环境变量 MINDLOOM_DATA_ROOT：开发版使用的另一个数据目录（绝对路径）。
    """)
  exit(0)
}
Bridge(socketPath: socketPath).run()
