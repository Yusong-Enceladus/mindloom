import Darwin
import Foundation
import MindloomAgentProtocol

/// `mindloom add …` / `mindloom due`: the owner's command line (V8 contract
/// A3). One request over the App's private socket (the same folder, mode and
/// peer checks as the MCP helper), one answer, printed. It holds nothing and
/// logs nothing; what it sends is what the owner typed or piped in, and a
/// file goes as its absolute path, read by the App under the drop rules.
struct OwnerCommandLineRunner {
  let socketPath: String?

  /// Text piped in is limited so the request stays one socket line.
  static let maximumStandardInputBytes = 6 * 1_024 * 1_024
  static let replyTimeoutSeconds: Int32 = 180

  enum ExitCode {
    static let ok: Int32 = 0
    static let notRunning: Int32 = 1
    static let refused: Int32 = 2
    static let disabled: Int32 = 3
    static let notReady: Int32 = 4
    static let usage: Int32 = 64
  }

  func run(_ arguments: [String]) -> Never {
    var inputTooLong = false
    let parsed = OwnerCommand.parse(
      arguments, workingDirectory: FileManager.default.currentDirectoryPath,
      readStandardInput: {
        let result = Self.readStandardInput()
        if case .tooLong = result { inputTooLong = true }
        if case .text(let text) = result { return text }
        return nil
      })
    if inputTooLong {
      Self.fail("管道输入的文字超过 6 MB；请存成文件后用 --file 收进来", code: ExitCode.usage)
    }
    switch parsed {
    case .failure(.usage(let message)):
      FileHandle.standardError.write(Data((message + "\n\n" + OwnerCommand.usage + "\n").utf8))
      exit(ExitCode.usage)
    case .success(.help):
      print(OwnerCommand.usage)
      exit(ExitCode.ok)
    case .success(.add(let request)):
      call(OwnerChannel.addMethod, params: request.params, json: false)
    case .success(.due(let days, let json)):
      call(OwnerChannel.dueMethod, params: ["days": .int(Int64(days))], json: json)
    }
  }

  enum StandardInput {
    case none
    case text(String)
    case tooLong
  }

  /// Piped text; nothing for an interactive terminal (it would wait forever).
  static func readStandardInput() -> StandardInput {
    guard isatty(STDIN_FILENO) == 0 else { return .none }
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = read(STDIN_FILENO, &chunk, chunk.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { break }
      data.append(contentsOf: chunk[0..<count])
      if data.count > maximumStandardInputBytes { return .tooLong }
    }
    let text = String(decoding: data, as: UTF8.self)
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .text(text)
  }

  private func call(_ method: String, params: JSONValue, json: Bool) -> Never {
    let outcome = OwnerSocketCall.perform(
      socketPath: socketPath, method: method, params: params,
      timeoutSeconds: Self.replyTimeoutSeconds,
      log: { FileHandle.standardError.write(Data(("mindloom: " + $0 + "\n").utf8)) })
    switch outcome {
    case .notRunning:
      Self.fail(AgentCopy.notRunning, code: ExitCode.notRunning)
    case .noAnswer:
      Self.fail("织机没有回答（可能已经退出）", code: ExitCode.notRunning)
    case .unreadable:
      Self.fail("织机的回答看不懂", code: ExitCode.refused)
    case .reply(let reply):
      if json {
        print(reply.json.serialized)
      } else {
        print(reply.message)
        for entry in reply.lines { print(entry) }
      }
      exit(ExitCode.ok)
    case .error(let code, let message):
      let exitCode: Int32 =
        switch code {
        case OwnerChannel.ErrorCode.disabled: ExitCode.disabled
        case OwnerChannel.ErrorCode.notReady: ExitCode.notReady
        default: ExitCode.refused
        }
      Self.fail(message, code: exitCode)
    }
  }

  private static func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("mindloom: " + message + "\n").utf8))
    exit(code)
  }
}
