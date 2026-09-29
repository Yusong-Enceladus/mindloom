import Foundation

public struct RemoteOrganizerHTTPRequest: Sendable, Equatable {
  public let method: String
  public let port: Int
  public let path: String
  public let body: Data?
  public let token: String
  public let timeout: TimeInterval

  public init(
    method: String, port: Int, path: String, body: Data?, token: String,
    timeout: TimeInterval
  ) {
    self.method = method
    self.port = port
    self.path = path
    self.body = body
    self.token = token
    self.timeout = timeout
  }
}

public struct RemoteOrganizerHTTPResponse: Sendable, Equatable {
  public let status: Int
  public let body: Data

  public init(status: Int, body: Data) {
    self.status = status
    self.body = body
  }
}

public protocol RemoteOrganizerHTTPTransport: AnyObject, Sendable {
  func send(_ request: RemoteOrganizerHTTPRequest) async throws -> RemoteOrganizerHTTPResponse
  /// Cancels every in-flight request; the transport is not reused afterwards.
  func cancelAll()
}

private final class RejectOrganizerRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public enum RemoteOrganizerHTTPError: Error, Equatable, Sendable {
  case notLoopback
  case invalidResponse
}

/// Loopback-only HTTP over the owner-checked forward. No cookies, cache,
/// proxies, or redirects; the link token is sent only in the Authorization
/// header and never logged.
///
/// Task creation and invalidation happen under one lock: once `cancelAll()`
/// has run, `send` throws instead of creating a task on the invalidated
/// session (which would raise an Objective-C exception and abort the app).
public final class URLSessionRemoteOrganizerTransport: RemoteOrganizerHTTPTransport,
  @unchecked Sendable
{
  private let session: URLSession
  private let delegate: RejectOrganizerRedirects
  private let lock = NSLock()
  private var invalidated = false
  private var live: [Int: URLSessionDataTask] = [:]

  public init() {
    let config = URLSessionConfiguration.ephemeral
    config.waitsForConnectivity = false
    config.timeoutIntervalForRequest = 30
    // A file item's upload (up to ~33 MB) may take longer than a request.
    config.timeoutIntervalForResource = 180
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    config.urlCredentialStorage = nil
    config.connectionProxyDictionary = [:]
    let delegate = RejectOrganizerRedirects()
    self.delegate = delegate
    session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
  }

  public static func urlRequest(for request: RemoteOrganizerHTTPRequest) throws -> URLRequest {
    guard request.path.hasPrefix("/v1/"),
      let url = URL(string: "http://127.0.0.1:\(request.port)\(request.path)"),
      url.host == "127.0.0.1", url.port == request.port
    else { throw RemoteOrganizerHTTPError.notLoopback }
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    urlRequest.timeoutInterval = request.timeout
    urlRequest.setValue("Bearer \(request.token)", forHTTPHeaderField: "Authorization")
    if request.body != nil {
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return urlRequest
  }

  public func send(
    _ request: RemoteOrganizerHTTPRequest
  ) async throws -> RemoteOrganizerHTTPResponse {
    let urlRequest = try Self.urlRequest(for: request)
    let box = TaskBox()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<RemoteOrganizerHTTPResponse, Error>) in
        lock.lock()
        guard !invalidated else {
          lock.unlock()
          continuation.resume(throwing: CancellationError())
          return
        }
        let task = session.dataTask(with: urlRequest) { [weak self] data, response, error in
          if let self, let id = box.identifier {
            self.lock.lock()
            self.live[id] = nil
            self.lock.unlock()
          }
          if let error {
            continuation.resume(throwing: error)
          } else if let response = response as? HTTPURLResponse {
            continuation.resume(
              returning: RemoteOrganizerHTTPResponse(
                status: response.statusCode, body: data ?? Data()))
          } else {
            continuation.resume(throwing: RemoteOrganizerHTTPError.invalidResponse)
          }
        }
        box.identifier = task.taskIdentifier
        box.task = task
        live[task.taskIdentifier] = task
        lock.unlock()
        task.resume()
      }
    } onCancel: {
      box.cancel()
    }
  }

  public func cancelAll() {
    lock.lock()
    invalidated = true
    let tasks = Array(live.values)
    live = [:]
    lock.unlock()
    for task in tasks { task.cancel() }
    session.invalidateAndCancel()
  }
}

/// The task of one `send`, reachable from its cancellation handler.
private final class TaskBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _task: URLSessionDataTask?
  private var _identifier: Int?
  private var cancelled = false

  var task: URLSessionDataTask? {
    get { lock.withLock { _task } }
    set {
      let cancelNow = lock.withLock {
        _task = newValue
        return cancelled
      }
      if cancelNow { newValue?.cancel() }
    }
  }

  var identifier: Int? {
    get { lock.withLock { _identifier } }
    set { lock.withLock { _identifier = newValue } }
  }

  func cancel() {
    let task = lock.withLock {
      cancelled = true
      return _task
    }
    task?.cancel()
  }
}
