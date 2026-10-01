import Foundation

/// HTTP/1.1 over a byte stream (the gate's bridge on an SSH session's stdin
/// and stdout): one request at a time, keep-alive. Requests always carry
/// Content-Length (never chunked; the gate refuses Transfer-Encoding with
/// Content-Length together); responses may be Content-Length, chunked or
/// close-delimited. Pure, so the framing is tested without a process.
public enum HTTPBridgeCodec {
  public enum CodecError: Error, Equatable, Sendable {
    case malformed
    case tooLarge
  }

  /// The largest response this Mac reads into memory (a space backup).
  public static let maximumBody = 2 * 1024 * 1024 * 1024 - 1
  static let maximumHead = 64 * 1024

  public static func encode(
    method: String, target: String, headers: [(String, String)], body: Data?
  ) -> Data {
    var head = "\(method) \(target) HTTP/1.1\r\nHost: organizer\r\n"
    for (name, value) in headers {
      // Header injection is impossible by construction: no CR or LF passes.
      let cleanName = name.filter { !$0.isNewline && $0 != ":" }
      let cleanValue = value.filter { !$0.isNewline }
      head += "\(cleanName): \(cleanValue)\r\n"
    }
    if let body {
      head += "Content-Length: \(body.count)\r\n"
    } else if method == "POST" || method == "PUT" {
      head += "Content-Length: 0\r\n"
    }
    head += "\r\n"
    var out = Data(head.utf8)
    if let body { out.append(body) }
    return out
  }

  public struct Response: Equatable, Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    /// The peer closes after this response (`Connection: close` or a body
    /// that ran to the end of the stream).
    public let closes: Bool
  }

  /// Feed bytes as they arrive; `next()` hands out each complete response.
  public struct ResponseParser: Sendable {
    private var buffer = Data()
    private var head: (status: Int, headers: [String: String])?
    private var chunked = false
    private var length: Int?
    private var body = Data()
    private var eof = false

    public init() {}

    public mutating func feed(_ data: Data) { buffer.append(data) }

    /// The stream ended: a close-delimited body is complete now.
    public mutating func finish() { eof = true }

    public var hasPartialResponse: Bool { head != nil || !buffer.isEmpty }

    public mutating func next() throws -> Response? {
      if head == nil {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
          if buffer.count > maximumHead { throw CodecError.tooLarge }
          if eof, !buffer.isEmpty { throw CodecError.malformed }
          return nil
        }
        let text = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        buffer = Data(buffer[end.upperBound...])
        var lines = text.components(separatedBy: "\r\n")
        let status = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard status.count >= 2, status[0].hasPrefix("HTTP/1."), let code = Int(status[1]),
          (100...599).contains(code)
        else { throw CodecError.malformed }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
          guard let colon = line.firstIndex(of: ":") else { throw CodecError.malformed }
          let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
          let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
          headers[name] = value
        }
        chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
        if !chunked, let value = headers["content-length"] {
          guard let n = Int(value), n >= 0 else { throw CodecError.malformed }
          guard n <= maximumBody else { throw CodecError.tooLarge }
          length = n
        } else {
          length = nil
        }
        // 1xx, 204 and 304 have no body.
        if (100..<200).contains(code) || code == 204 || code == 304 { length = 0 }
        head = (code, headers)
        body = Data()
      }
      guard let current = head else { return nil }
      if chunked {
        while true {
          guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else {
            if eof { throw CodecError.malformed }
            return nil
          }
          let sizeLine = String(
            decoding: buffer[buffer.startIndex..<lineEnd.lowerBound], as: UTF8.self)
          guard let size = Int(sizeLine.split(separator: ";").first ?? "", radix: 16), size >= 0
          else { throw CodecError.malformed }
          if size == 0 {
            // Trailers end with an empty line.
            guard
              let trailerEnd = buffer.range(
                of: Data("\r\n\r\n".utf8), in: lineEnd.lowerBound..<buffer.endIndex)
            else {
              if eof { throw CodecError.malformed }
              return nil
            }
            buffer = Data(buffer[trailerEnd.upperBound...])
            return complete(current, closes: false)
          }
          let start = lineEnd.upperBound
          guard buffer.distance(from: start, to: buffer.endIndex) >= size + 2 else {
            if eof { throw CodecError.malformed }
            return nil
          }
          let dataEnd = buffer.index(start, offsetBy: size)
          guard body.count + size <= maximumBody else { throw CodecError.tooLarge }
          body.append(buffer[start..<dataEnd])
          guard buffer[dataEnd..<buffer.index(dataEnd, offsetBy: 2)] == Data("\r\n".utf8) else {
            throw CodecError.malformed
          }
          buffer = Data(buffer[buffer.index(dataEnd, offsetBy: 2)...])
        }
      }
      if let length {
        guard buffer.count >= length else {
          if eof { throw CodecError.malformed }
          return nil
        }
        body = Data(buffer.prefix(length))
        buffer = Data(buffer.dropFirst(length))
        return complete(current, closes: false)
      }
      // No length: the body runs to the end of the stream.
      guard eof else {
        if buffer.count > maximumBody { throw CodecError.tooLarge }
        return nil
      }
      body = buffer
      buffer = Data()
      return complete(current, closes: true)
    }

    private mutating func complete(
      _ current: (status: Int, headers: [String: String]), closes: Bool
    )
      -> Response
    {
      let close = closes || current.headers["connection"]?.lowercased() == "close"
      let response = Response(
        status: current.status, headers: current.headers, body: body, closes: close)
      head = nil
      length = nil
      chunked = false
      body = Data()
      return response
    }
  }
}
