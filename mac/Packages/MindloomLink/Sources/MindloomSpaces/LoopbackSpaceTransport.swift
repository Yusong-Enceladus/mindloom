import Foundation

/// HTTP to the Spark's space routes over a loopback port that the user's own
/// SSH forward holds. Only `127.0.0.1` is ever contacted; no cookies, cache,
/// proxies or redirects; the link token goes only into the Authorization
/// header and is never logged. `ready` is asked before every request (the
/// App checks the port still belongs to its own ssh child).
public final class LoopbackSpaceTransport: SpaceTransport, @unchecked Sendable {
  public typealias Endpoint = (port: Int, token: String)

  private let session: URLSession
  private let endpoint: @Sendable () async throws -> Endpoint
  private let timeout: TimeInterval

  public init(
    timeout: TimeInterval = 60, endpoint: @escaping @Sendable () async throws -> Endpoint
  ) {
    let config = URLSessionConfiguration.ephemeral
    config.waitsForConnectivity = false
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = 300
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    config.urlCredentialStorage = nil
    config.connectionProxyDictionary = [:]
    session = URLSession(
      configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    self.endpoint = endpoint
    self.timeout = timeout
  }

  deinit { session.invalidateAndCancel() }

  public func send(_ request: SpaceHTTPRequest) async throws -> SpaceHTTPResponse {
    let (port, token) = try await endpoint()
    guard request.target.hasPrefix("/v1/"),
      let url = URL(string: "http://127.0.0.1:\(port)\(request.target)"), url.host == "127.0.0.1"
    else { throw SpaceClientError.transport }
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    urlRequest.timeoutInterval = timeout
    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let contentType = request.contentType {
      urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
    }
    for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
    let (data, response) = try await session.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse else { throw SpaceClientError.transport }
    return SpaceHTTPResponse(status: http.statusCode, body: data)
  }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
