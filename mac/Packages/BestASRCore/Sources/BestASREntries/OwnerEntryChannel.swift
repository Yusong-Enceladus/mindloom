import BestASRAgentAccess
import Foundation
import MindloomAgentProtocol

/// What the App did with one command-line or browser request.
public enum OwnerOutcome: Equatable, Sendable {
  case reply(OwnerReply)
  /// Nothing was taken in; the message says why.
  case refused(String)
  /// The library is not open yet.
  case notReady
}

/// The App's side of `mindloom add` / `mindloom due` (V8 contract A3) and of
/// the Chrome extension's native messaging host (A6): checks that the owner
/// switched that entry on, reads the request, and hands it to the App. It is
/// the owner's own intake: no agent grant, no audit row, no consent sheet.
/// Requests arrive only over the private socket, after the socket server's
/// owner check. Each entry has its own switch: the command line being on
/// never lets a browser request in, and the other way round.
public struct OwnerEntryChannel: OwnerChannelHandling {
  public let isEnabled: @Sendable (EntryKind) async -> Bool
  public let add: @Sendable (OwnerAddRequest) async -> OwnerOutcome
  public let due: @Sendable (_ days: Int) async -> OwnerOutcome
  public let browserAdd: @Sendable (BrowserAddRequest) async -> OwnerOutcome

  public init(
    isEnabled: @escaping @Sendable (EntryKind) async -> Bool,
    add: @escaping @Sendable (OwnerAddRequest) async -> OwnerOutcome,
    due: @escaping @Sendable (Int) async -> OwnerOutcome,
    browserAdd: @escaping @Sendable (BrowserAddRequest) async -> OwnerOutcome = { _ in .notReady }
  ) {
    self.isEnabled = isEnabled
    self.add = add
    self.due = due
    self.browserAdd = browserAdd
  }

  /// The entry whose switch decides a method.
  public static func entry(for method: String) -> EntryKind? {
    switch method {
    case OwnerChannel.addMethod, OwnerChannel.dueMethod: .commandLine
    case OwnerChannel.browserAddMethod: .browserExtension
    default: nil
    }
  }

  public func handleOwner(
    id: JSONValue, method: String, params: JSONValue?, peer: AgentConnectionPeer
  ) async -> JSONValue {
    guard let entry = Self.entry(for: method) else {
      return MCPMessage.error(
        id: id, code: MCPErrorCode.methodNotFound, message: "Method not found")
    }
    guard await isEnabled(entry) else {
      return MCPMessage.error(
        id: id, code: OwnerChannel.ErrorCode.disabled,
        message: entry == .browserExtension
          ? OwnerChannel.browserDisabledMessage : OwnerChannel.disabledMessage)
    }
    let outcome: OwnerOutcome
    switch method {
    case OwnerChannel.addMethod:
      guard let request = OwnerAddRequest(params: params), !request.isEmpty else {
        return MCPMessage.error(
          id: id, code: MCPErrorCode.invalidParams, message: "没有要收进来的内容")
      }
      outcome = await add(request)
    case OwnerChannel.dueMethod:
      let days = Int(params?["days"]?.intValue ?? 0)
      outcome = await due(min(max(days, 0), 30))
    case OwnerChannel.browserAddMethod:
      guard let request = BrowserAddRequest(params: params) else {
        return MCPMessage.error(
          id: id, code: MCPErrorCode.invalidParams, message: BrowserCopy.malformed)
      }
      outcome = await browserAdd(request)
    default:
      return MCPMessage.error(
        id: id, code: MCPErrorCode.methodNotFound, message: "Method not found")
    }
    switch outcome {
    case .reply(let reply):
      return MCPMessage.result(id: id, reply.json)
    case .refused(let message):
      return MCPMessage.error(id: id, code: OwnerChannel.ErrorCode.refused, message: message)
    case .notReady:
      return MCPMessage.error(
        id: id, code: OwnerChannel.ErrorCode.notReady, message: OwnerChannel.notReadyMessage)
    }
  }
}
