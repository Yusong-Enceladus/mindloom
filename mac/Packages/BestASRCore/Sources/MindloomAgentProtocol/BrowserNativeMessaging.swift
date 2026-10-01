import Darwin
import Foundation

/// The Chrome extension 「收进织机」 (V8 contract A6) and the one way it can
/// reach the App: Chrome's native messaging, with the bundled helper as the
/// host. Chrome starts the helper with the extension's origin as its first
/// argument and talks to it over stdio, each message a 4-byte length in the
/// machine's byte order followed by that many bytes of UTF-8 JSON. The helper
/// forwards one owner request per message over the App's private socket.
/// There is no network path anywhere: the extension has no host permission
/// and its pages may not connect anywhere (CSP `connect-src 'none'`).
public enum BrowserExtension {
  /// The extension's ID, fixed by the public key in its manifest (`key`), so
  /// the unpacked extension has the same ID on every Mac.
  public static let extensionID = "mhpochidiepnikgedmjbpnoknbkjidpa"
  /// The only origin the host answers (the host manifest's `allowed_origins`).
  public static let origin = "chrome-extension://\(extensionID)/"
  /// The native messaging host name (the manifest file's name and `name`).
  public static let hostName = "com.bestasr.mindloom"
  /// The source label of everything the extension hands in.
  public static let sourceName = "Chrome"

  /// True when `argument` is how Chrome starts a native messaging host (an
  /// extension origin as the first argument), whichever extension it is.
  public static func isHostLaunch(_ argument: String?) -> Bool {
    argument?.hasPrefix("chrome-extension://") == true
  }

  /// Only our extension; Chrome checks `allowed_origins` too, the helper
  /// checks again so an unexpected caller gets nothing forwarded.
  public static func isAllowedOrigin(_ origin: String) -> Bool {
    origin == Self.origin
  }
}

/// Chrome's native messaging framing.
public enum NativeMessaging {
  /// The largest message the host accepts from the extension; the extension
  /// stops well before (a million characters of selection).
  public static let maximumIncomingBytes = 4 * 1_024 * 1_024
  /// Chrome refuses a host message larger than 1 MB.
  public static let maximumOutgoingBytes = 1_024 * 1_024

  public enum FrameError: Error, Equatable, Sendable {
    /// The announced length is over the limit.
    case tooLarge(UInt32)
    /// The stream ended inside a frame.
    case truncated
    /// The frame is not UTF-8 JSON.
    case notJSON
  }

  /// One message as Chrome expects it: the length in native byte order (little
  /// endian on every Mac), then the JSON.
  public static func frame(_ value: JSONValue) -> Data {
    var payload = value.serializedData
    if payload.count > maximumOutgoingBytes {
      payload =
        JSONValue.object([
          "ok": false, "reason": "tooLarge", "message": "回答太长，没能送回浏览器",
        ]).serializedData
    }
    var length = UInt32(payload.count)
    var data = Data(bytes: &length, count: 4)
    data.append(payload)
    return data
  }

  /// Splits a byte stream into messages (pure, for tests and the host).
  public struct FrameReader: Sendable {
    private var pending = Data()
    public private(set) var failed: FrameError?

    public init() {}

    /// The complete messages in what arrived so far; after a framing error
    /// nothing more is returned.
    public mutating func append(_ data: Data) -> [Result<JSONValue, FrameError>] {
      guard failed == nil else { return [] }
      pending.append(data)
      var messages: [Result<JSONValue, FrameError>] = []
      while pending.count >= 4 {
        let length = pending.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard length <= UInt32(maximumIncomingBytes) else {
          failed = .tooLarge(length)
          pending.removeAll()
          messages.append(.failure(.tooLarge(length)))
          return messages
        }
        guard pending.count >= 4 + Int(length) else { break }
        let start = pending.startIndex + 4
        let body = pending[start..<(start + Int(length))]
        pending.removeSubrange(pending.startIndex..<(start + Int(length)))
        if let value = try? JSONValue.parse(Data(body)) {
          messages.append(.success(value))
        } else {
          messages.append(.failure(.notJSON))
        }
      }
      return messages
    }

    /// Call at end of stream: bytes left over are a cut-off frame.
    public var endedInsideFrame: Bool { failed == nil && !pending.isEmpty }
  }
}

/// What the extension sends: the selection, the page link or a link on the
/// page. Links are text: nothing is ever fetched.
public struct BrowserAddRequest: Equatable, Sendable {
  public enum Kind: String, Sendable, CaseIterable {
    case selection
    case page
    case link
  }

  public static let version = 1
  /// Selected text longer than this is refused (the extension stops at a
  /// million characters; this bounds the bytes).
  public static let maximumTextBytes = 3 * 1_024 * 1_024
  public static let maximumFieldBytes = 64 * 1_024

  public var kind: Kind
  public var text: String?
  public var url: String?
  public var title: String?

  public init(kind: Kind, text: String? = nil, url: String? = nil, title: String? = nil) {
    self.kind = kind
    self.text = text
    self.url = url
    self.title = title
  }

  public enum Problem: Error, Equatable, Sendable {
    case malformed
    case empty
    case tooLong
  }

  /// The extension's message, checked: known kind, string fields, sizes,
  /// something to take (a selection needs text, a page or link needs a link).
  public static func parse(_ message: JSONValue) -> Result<BrowserAddRequest, Problem> {
    guard let object = message.objectValue,
      object["type"]?.stringValue == "add",
      let kindName = object["kind"]?.stringValue, let kind = Kind(rawValue: kindName)
    else { return .failure(.malformed) }
    func field(_ key: String) -> String?? {
      guard let value = object[key], value != .null else { return .some(nil) }
      guard let text = value.stringValue else { return nil }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return .some(trimmed.isEmpty ? nil : text)
    }
    guard let text = field("text"), let url = field("url"), let title = field("title") else {
      return .failure(.malformed)
    }
    if (text?.utf8.count ?? 0) > maximumTextBytes { return .failure(.tooLong) }
    if (url?.utf8.count ?? 0) > maximumFieldBytes || (title?.utf8.count ?? 0) > maximumFieldBytes {
      return .failure(.tooLong)
    }
    let request = BrowserAddRequest(
      kind: kind, text: text, url: url?.trimmingCharacters(in: .whitespacesAndNewlines),
      title: title?.trimmingCharacters(in: .whitespacesAndNewlines))
    switch kind {
    case .selection: guard request.text != nil else { return .failure(.empty) }
    case .page, .link: guard request.url != nil else { return .failure(.empty) }
    }
    return .success(request)
  }

  /// The owner request's params over the socket.
  public var params: JSONValue {
    var object: [String: JSONValue] = ["kind": .string(kind.rawValue)]
    if let text { object["text"] = .string(text) }
    if let url { object["url"] = .string(url) }
    if let title { object["title"] = .string(title) }
    return .object(object)
  }

  /// The App's reading of the params (nil when they are not a request).
  public init?(params: JSONValue?) {
    guard let params, case .success(let request) = Self.parse(params.merging(type: "add"))
    else { return nil }
    self = request
  }
}

extension JSONValue {
  fileprivate func merging(type: String) -> JSONValue {
    guard var object = objectValue else { return self }
    object["type"] = .string(type)
    return .object(object)
  }
}

/// The host's answer to the extension.
public struct BrowserReply: Equatable, Sendable {
  public enum Reason: String, Sendable {
    /// The extension is not ours.
    case origin
    /// The message is not a request the host understands.
    case malformed
    case empty
    case tooLong
    /// The App is not running.
    case notRunning
    /// The owner has not switched the browser entry on.
    case disabled
    /// The library is not open yet.
    case notReady
    /// The App took nothing (the message says why).
    case refused
  }

  public var ok: Bool
  public var reason: Reason?
  public var message: String
  public var stored: Int

  public init(ok: Bool, reason: Reason? = nil, message: String, stored: Int = 0) {
    self.ok = ok
    self.reason = reason
    self.message = message
    self.stored = stored
  }

  public static func failure(_ reason: Reason, _ message: String) -> BrowserReply {
    BrowserReply(ok: false, reason: reason, message: message)
  }

  public var json: JSONValue {
    var object: [String: JSONValue] = [
      "ok": .bool(ok), "message": .string(message), "stored": .int(Int64(stored)),
    ]
    if let reason { object["reason"] = .string(reason.rawValue) }
    return .object(object)
  }

  public init?(json: JSONValue) {
    guard let ok = json["ok"]?.boolValue, let message = json["message"]?.stringValue else {
      return nil
    }
    self.init(
      ok: ok, reason: json["reason"]?.stringValue.flatMap(Reason.init(rawValue:)),
      message: message, stored: Int(json["stored"]?.intValue ?? 0))
  }
}

/// Plain Chinese for the extension to show.
public enum BrowserCopy {
  public static let notOurExtension = "这个扩展不是织机的「收进织机」，没有收任何内容"
  public static let malformed = "看不懂浏览器发来的内容，没有收进来"
  public static let empty = "没有选中文字，也没有链接，没有收进来"
  public static let tooLong = "选中的文字太长，请分几次收"
}
