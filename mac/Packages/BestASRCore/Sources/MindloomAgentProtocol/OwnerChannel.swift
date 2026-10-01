import Foundation

/// The owner's own channel on the App's private socket (V8 contract A3, and
/// A6 for the Chrome extension's native messaging host): the
/// `mindloom` command line (`mindloom add …`, `mindloom due`) reaches the
/// running App through the same socket, folder and peer check as the agent
/// helper, but it is the owner's intake, not an agent: what it adds is the
/// owner's own item, and it never touches agent grants or the audit list.
///
/// A connection is one or the other, decided by its first line: an owner
/// request opens an owner connection; anything else is an MCP session, in
/// which an owner method is "Method not found". The MCP helper never forwards
/// an owner method an agent sends it. The App answers owner calls only while
/// the owner has switched the command line on (Settings → 入口); off by
/// default, because a program running as the owner (an agent in a terminal
/// too) could use it, exactly as it could type into the owner's terminal.
public enum OwnerChannel {
  public static let methodPrefix = "mindloom/owner."
  public static let addMethod = "mindloom/owner.add"
  public static let dueMethod = "mindloom/owner.due"
  /// The Chrome extension 「收进织机」 through the native messaging host (V8
  /// contract A6): the owner's own intake too, behind its own switch.
  public static let browserAddMethod = "mindloom/owner.browserAdd"

  /// Errors the App answers with (JSON-RPC error codes).
  public enum ErrorCode {
    /// The command line is switched off in Settings → 入口.
    public static let disabled = -32010
    /// Nothing could be taken in (the message says why).
    public static let refused = -32011
    /// The library is not open yet.
    public static let notReady = -32012
  }

  public static func isOwnerMethod(_ method: String) -> Bool {
    method.hasPrefix(methodPrefix)
  }

  /// True when the line is a request (or notification) for an owner method.
  public static func isOwnerRequest(_ line: String) -> Bool {
    switch MCPMessage.decode(line) {
    case .request(_, let method, _), .notification(let method, _):
      isOwnerMethod(method)
    default:
      false
    }
  }

  public static let disabledMessage =
    "命令行入口没有打开：在织机的 设置 → 入口 里打开「命令行 mindloom」"
  public static let notReadyMessage = "织机的资料库还没有打开，请稍后再试"
  public static let browserDisabledMessage =
    "Chrome 扩展没有连上：在织机的 设置 → 入口 里打开「Chrome 扩展」"
}

/// `mindloom add`: text, files (absolute paths, read by the App under the same
/// file rules as a drop), or a link kept as text (never fetched).
public struct OwnerAddRequest: Equatable, Sendable {
  public var text: String?
  public var filePaths: [String]
  public var url: String?
  public var title: String?

  public init(
    text: String? = nil, filePaths: [String] = [], url: String? = nil, title: String? = nil
  ) {
    self.text = text
    self.filePaths = filePaths
    self.url = url
    self.title = title
  }

  public var isEmpty: Bool {
    (text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
      && filePaths.isEmpty
      && (url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }

  public var params: JSONValue {
    var object: [String: JSONValue] = [:]
    if let text { object["text"] = .string(text) }
    if !filePaths.isEmpty { object["files"] = .strings(filePaths) }
    if let url { object["url"] = .string(url) }
    if let title { object["title"] = .string(title) }
    return .object(object)
  }

  /// Nil for params that are not an add request (wrong types, relative paths).
  public init?(params: JSONValue?) {
    guard let object = params?.objectValue else { return nil }
    var files: [String] = []
    if let value = object["files"] {
      guard let array = value.arrayValue else { return nil }
      for entry in array {
        guard let path = entry.stringValue, path.hasPrefix("/") else { return nil }
        files.append(path)
      }
    }
    func string(_ key: String) -> String?? {
      guard let value = object[key] else { return .some(nil) }
      guard let text = value.stringValue else { return nil }
      return .some(text)
    }
    guard let text = string("text"), let url = string("url"), let title = string("title") else {
      return nil
    }
    self.init(text: text, filePaths: files, url: url, title: title)
  }
}

/// What the App answered, as the command line prints it.
public struct OwnerReply: Equatable, Sendable {
  public var message: String
  public var stored: Int
  /// `mindloom due`: one line per item.
  public var lines: [String]

  public init(message: String, stored: Int = 0, lines: [String] = []) {
    self.message = message
    self.stored = stored
    self.lines = lines
  }

  public var json: JSONValue {
    [
      "message": .string(message), "stored": .int(Int64(stored)), "lines": .strings(lines),
    ]
  }

  public init?(result: JSONValue?) {
    guard let result, let message = result["message"]?.stringValue else { return nil }
    self.init(
      message: message, stored: Int(result["stored"]?.intValue ?? 0),
      lines: result["lines"]?.arrayValue?.compactMap(\.stringValue) ?? [])
  }
}

/// The `mindloom` command line, parsed (pure, so it is tested without a
/// process).
public enum OwnerCommand: Equatable, Sendable {
  case add(OwnerAddRequest)
  case due(days: Int, json: Bool)
  case help

  public static let commands: Set<String> = ["add", "due", "help"]

  public enum ParseError: Error, Equatable, Sendable {
    case usage(String)
  }

  /// `arguments` without the program name. `readStandardInput` is called only
  /// for `mindloom add` with no text, file or link (text piped in).
  /// `workingDirectory` resolves relative file paths.
  public static func parse(
    _ arguments: [String], workingDirectory: String, readStandardInput: () -> String?
  ) -> Result<OwnerCommand, ParseError> {
    guard let command = arguments.first else { return .success(.help) }
    var rest = Array(arguments.dropFirst())
    switch command {
    case "help", "--help", "-h":
      return .success(.help)
    case "due":
      var days = 0
      var json = false
      while !rest.isEmpty {
        let flag = rest.removeFirst()
        switch flag {
        case "--json": json = true
        case "--days":
          guard let value = rest.first, let number = Int(value), (0...30).contains(number) else {
            return .failure(.usage("--days 需要 0 到 30 之间的数字"))
          }
          rest.removeFirst()
          days = number
        default:
          return .failure(.usage("不认识的参数：\(flag)"))
        }
      }
      return .success(.due(days: days, json: json))
    case "add":
      var request = OwnerAddRequest()
      var words: [String] = []
      var onlyText = false
      while !rest.isEmpty {
        let argument = rest.removeFirst()
        if onlyText {
          words.append(argument)
          continue
        }
        switch argument {
        case "--":
          onlyText = true
        case "--file", "-f":
          guard let path = rest.first, !path.isEmpty else {
            return .failure(.usage("--file 后面要跟文件路径"))
          }
          rest.removeFirst()
          request.filePaths.append(absolute(path, in: workingDirectory))
        case "--url":
          guard let url = rest.first, !url.isEmpty else {
            return .failure(.usage("--url 后面要跟链接"))
          }
          rest.removeFirst()
          request.url = url
        case "--title":
          guard let title = rest.first else { return .failure(.usage("--title 后面要跟标题")) }
          rest.removeFirst()
          request.title = title
        case "-":
          // An explicit "read standard input".
          guard let text = readStandardInput() else {
            return .failure(.usage("标准输入里没有文字"))
          }
          words.append(text)
        default:
          if argument.hasPrefix("--") { return .failure(.usage("不认识的参数：\(argument)")) }
          words.append(argument)
        }
      }
      if !words.isEmpty { request.text = words.joined(separator: " ") }
      if words.isEmpty, request.filePaths.isEmpty, request.url == nil,
        let piped = readStandardInput()
      {
        request.text = piped
      }
      guard !request.isEmpty else {
        return .failure(.usage("没有要收进来的内容：mindloom add \"文字\"、--file 路径，或者用管道输入"))
      }
      return .success(.add(request))
    default:
      return .failure(.usage("不认识的命令：\(command)"))
    }
  }

  static func absolute(_ path: String, in directory: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    let joined =
      expanded.hasPrefix("/") ? expanded : (directory as NSString).appendingPathComponent(expanded)
    return (joined as NSString).standardizingPath
  }

  public static let usage = """
    mindloom：把内容收进织机（你自己的入口，和粘贴、拖入一样）。
      mindloom add "一段文字"         收进一段文字
      mindloom add --file 路径        收进一个文件（可以写多个 --file）
      mindloom add --url 链接 [--title 标题]   收进一个链接（只记下链接，不会打开它）
      echo 文字 | mindloom add        从管道收进文字
      mindloom due [--days N] [--json]  看今天（或接下来 N 天）到期的事，只读
    需要先在织机的 设置 → 入口 里打开「命令行 mindloom」，并且织机在运行。
    """
}
