import Foundation

// MARK: - Transport

public struct TransportReply: Sendable, Equatable {
  public var status: Int
  /// Header names in lower case.
  public var headers: [String: String]
  public var body: Data
  /// The body was cut at the size limit.
  public var truncated: Bool

  public init(status: Int, headers: [String: String] = [:], body: Data = Data(), truncated: Bool = false) {
    self.status = status
    self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
    self.body = body
    self.truncated = truncated
  }
}

public enum TransportFailure: Error, Sendable, Equatable {
  /// No response at all: the host could not be reached (the words did not
  /// arrive anywhere).
  case cannotConnect
  case timedOut
  case cancelled
  case other
}

/// Sends one request and returns one response, without following redirects
/// and without cookies, credentials or caches. Tests replace it with
/// recorded fixtures.
public protocol LookupTransport: Sendable {
  func perform(_ request: URLRequest, maximumBytes: Int, timeout: TimeInterval) async
    -> Result<TransportReply, TransportFailure>
}

/// The only `URLSession` in the lookup (a source scan in the tests keeps it
/// that way): an ephemeral session per request, no cookies, no credential
/// store, no cache, no redirects, a size limit and a time limit. The system
/// proxy applies as for any app.
public final class URLSessionLookupTransport: LookupTransport {
  public init() {}

  public func perform(_ request: URLRequest, maximumBytes: Int, timeout: TimeInterval) async
    -> Result<TransportReply, TransportFailure>
  {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = min(timeout, 10)
    configuration.timeoutIntervalForResource = timeout
    let collector = ResponseCollector(maximumBytes: maximumBytes)
    let session = URLSession(
      configuration: configuration, delegate: collector, delegateQueue: collector.queue)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        collector.start(session: session, request: request, continuation: continuation)
      }
    } onCancel: {
      collector.cancel()
    }
  }
}

/// Collects one response for `URLSessionLookupTransport`.
final class ResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  typealias Reply = Result<TransportReply, TransportFailure>

  let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    return queue
  }()
  private let lock = NSLock()
  private let maximumBytes: Int
  private var continuation: CheckedContinuation<Reply, Never>?
  private var task: URLSessionDataTask?
  private var response: HTTPURLResponse?
  private var data = Data()
  private var truncated = false
  private var cancelled = false

  init(maximumBytes: Int) {
    self.maximumBytes = maximumBytes
  }

  func start(session: URLSession, request: URLRequest, continuation: CheckedContinuation<Reply, Never>) {
    let task = session.dataTask(with: request)
    let alreadyCancelled = lock.withLock { () -> Bool in
      self.continuation = continuation
      self.task = task
      return cancelled
    }
    if alreadyCancelled {
      finish(.failure(.cancelled))
      session.invalidateAndCancel()
      return
    }
    task.resume()
  }

  func cancel() {
    let task = lock.withLock { () -> URLSessionDataTask? in
      cancelled = true
      return self.task
    }
    task?.cancel()
  }

  private func finish(_ reply: Reply) {
    let continuation = lock.withLock { () -> CheckedContinuation<Reply, Never>? in
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume(returning: reply)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    lock.withLock { self.response = response as? HTTPURLResponse }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let full = lock.withLock { () -> Bool in
      let room = maximumBytes - self.data.count
      if data.count > room {
        self.data.append(data.prefix(max(0, room)))
        truncated = true
        return true
      }
      self.data.append(data)
      return false
    }
    if full { dataTask.cancel() }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    // Redirects come back as responses; the egress checks the next address
    // before it follows.
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    // Server trust is checked by the system; no login of any kind is answered.
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let (response, data, truncated) = lock.withLock { (self.response, self.data, self.truncated) }
    session.finishTasksAndInvalidate()
    if let response, error == nil || truncated {
      var headers: [String: String] = [:]
      for (name, value) in response.allHeaderFields {
        if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
      }
      finish(.success(TransportReply(status: response.statusCode, headers: headers, body: data, truncated: truncated)))
      return
    }
    guard let error = error as? URLError else {
      finish(.failure(.other))
      return
    }
    finish(.failure(Self.failure(for: error.code)))
  }

  /// Only failures before the request could have been sent (no route, no
  /// name, no connection, no TLS session) are `cannotConnect`: nothing
  /// arrived anywhere. A connection lost mid-request may have delivered the
  /// request, so it counts as sent (`other`).
  static func failure(for code: URLError.Code) -> TransportFailure {
    switch code {
    case .timedOut:
      .timedOut
    case .cancelled:
      .cancelled
    case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
      .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
      .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
      .clientCertificateRequired, .internationalRoamingOff, .dataNotAllowed,
      .appTransportSecurityRequiresSecureConnection:
      .cannotConnect
    default:
      .other
    }
  }
}

// MARK: - The network exit

public struct EgressRequest: Sendable {
  public var url: URL
  public var method: String
  public var headers: [String: String]
  public var body: Data?
  public var kind: NetworkActivityKind
  public var service: String
  public var maximumBytes: Int
  public var timeout: TimeInterval
  /// Pages follow up to three redirects, each address checked again;
  /// service calls follow none.
  public var followRedirects: Bool
  /// A link the owner collected follows redirects on its own site only; a
  /// redirect elsewhere comes back as `EgressFailure.offSiteRedirect` and
  /// is not followed.
  public var sameSiteRedirectsOnly: Bool

  public init(
    url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
    kind: NetworkActivityKind, service: String, maximumBytes: Int = 1_048_576,
    timeout: TimeInterval = 15, followRedirects: Bool = false, sameSiteRedirectsOnly: Bool = false
  ) {
    self.url = url
    self.method = method
    self.headers = headers
    self.body = body
    self.kind = kind
    self.service = service
    self.maximumBytes = maximumBytes
    self.timeout = timeout
    self.followRedirects = followRedirects
    self.sameSiteRedirectsOnly = sameSiteRedirectsOnly
  }
}

public struct EgressResponse: Sendable {
  public var status: Int
  public var headers: [String: String]
  public var body: Data
  public var requestedURL: URL
  public var finalURL: URL
  public var truncated: Bool
  /// The record line of the last hop, to amend once the answer is read.
  public var activityID: UUID
  public var retrievedAt: Date
  public var uptimeNanoseconds: UInt64

  public var isSuccess: Bool { (200...299).contains(status) }
}

public enum EgressFailure: Error, Sendable, Equatable {
  case refused(OutboundRefusal)
  case cannotConnect
  case timedOut
  case cancelled
  case tooManyRedirects
  /// A collected link redirected to another site (not followed).
  case offSiteRedirect(URL)
  /// The dry run planned the request instead of sending it.
  case dryRun
  /// 「从网络补充信息」 is off (checked before every request and redirect).
  case off
  case other
}

/// The lookup's one network exit. Every request — search, public source,
/// page, reader service, key check — goes through `fetch`, which checks the
/// switch, checks the address (https, public host, resolved address), paces
/// each host, sends through the transport and writes one 「网络活动」 line
/// per hop. In a dry run it plans instead of sending, without resolving any
/// name (a DNS query would itself carry the host name out).
public actor LookupEgress {
  public static let maximumRedirects = 3

  let transport: any LookupTransport
  let resolver: any HostResolver
  let activity: NetworkActivityLog
  let device: String
  let userAgent: String
  let dryRun: Bool
  let now: @Sendable () -> Date
  let sleep: @Sendable (TimeInterval) async -> Void
  /// nil: no switch (a bare egress in tests).
  let gate: LookupSwitch?
  private var nextAllowed: [String: Date] = [:]
  private var inFlight: [UUID: Task<Result<TransportReply, TransportFailure>, Never>] = [:]
  public private(set) var planned: [PlannedRequest] = []

  /// The shortest gap between two requests to one host (each source's own
  /// rule: arXiv one request per three seconds, Nominatim one per second,
  /// Jina twenty per minute without a key).
  public static let minimumInterval: [String: TimeInterval] = [
    "export.arxiv.org": 3.1, "nominatim.openstreetmap.org": 1.1, "r.jina.ai": 3.1,
    "api.crossref.org": 0.25, "ccfddl.com": 1,
  ]

  public init(
    transport: any LookupTransport = URLSessionLookupTransport(),
    resolver: any HostResolver = SystemHostResolver(), activity: NetworkActivityLog,
    device: String, userAgent: String = LookupEgress.defaultUserAgent, dryRun: Bool = false,
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
      try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
  ) {
    self.init(
      transport: transport, resolver: resolver, activity: activity, device: device, userAgent: userAgent,
      dryRun: dryRun, gate: nil, now: now, sleep: sleep)
  }

  init(
    transport: any LookupTransport, resolver: any HostResolver, activity: NetworkActivityLog, device: String,
    userAgent: String = LookupEgress.defaultUserAgent, dryRun: Bool, gate: LookupSwitch?,
    now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async -> Void
  ) {
    self.transport = transport
    self.resolver = resolver
    self.activity = activity
    self.device = device
    self.userAgent = userAgent
    self.dryRun = dryRun
    self.gate = gate
    self.now = now
    self.sleep = sleep
  }

  var isOff: Bool { gate.map { !$0.isOn } ?? false }

  /// Cancels every request in flight (the switch was turned off).
  public func cancelInFlight() {
    for task in inFlight.values { task.cancel() }
  }

  /// Names the program, as Wikipedia and OpenStreetMap ask; no account, no
  /// device or user identifier.
  public static let defaultUserAgent = "Mindloom/1.0 (web lookup)"

  /// A line for a request the outbound check refused before any address
  /// was contacted.
  @discardableResult
  public func recordRefusal(
    kind: NetworkActivityKind, service: String, host: String?, refusal: OutboundRefusal
  ) async -> UUID {
    let entry = NetworkActivityEntry(
      time: now(), device: device, kind: kind, service: service, host: host, result: .notSent,
      refusal: refusal)
    await activity.append(entry)
    return entry.id
  }

  public func fetch(_ request: EgressRequest, addressCheck: OutboundCheck? = nil) async
    -> Result<EgressResponse, EgressFailure>
  {
    var url = request.url
    var hops = 0
    let site = request.url.host.map(OutboundCheck.site(of:))
    while true {
      if isOff { return .failure(.off) }
      if Task.isCancelled { return .failure(.cancelled) }
      if let addressCheck {
        switch addressCheck.check(address: url) {
        case .failure(let refusal):
          await recordRefusal(kind: request.kind, service: request.service, host: url.host?.lowercased(), refusal: refusal)
          return .failure(.refused(refusal))
        case .success(let clean):
          url = clean
        }
      }
      guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else {
        await recordRefusal(kind: request.kind, service: request.service, host: url.host?.lowercased(), refusal: .unsupportedAddress)
        return .failure(.refused(.unsupportedAddress))
      }
      if HostPolicy.isPrivate(hostName: host) {
        await recordRefusal(kind: request.kind, service: request.service, host: host, refusal: .privateAddress)
        return .failure(.refused(.privateAddress))
      }
      if dryRun {
        // Planned before any name is resolved: the dry run sends nothing,
        // not even a DNS query.
        planned.append(PlannedRequest(kind: request.kind, service: request.service, host: host))
        return .failure(.dryRun)
      }
      if let addresses = await resolver.addresses(for: host), addresses.contains(where: \.isPrivate) {
        await recordRefusal(kind: request.kind, service: request.service, host: host, refusal: .privateAddress)
        return .failure(.refused(.privateAddress))
      }
      await pace(host)
      // Pacing may have waited; the switch may have been turned off since.
      if isOff { return .failure(.off) }

      var urlRequest = URLRequest(url: url)
      urlRequest.httpMethod = hops == 0 ? request.method : "GET"
      urlRequest.httpShouldHandleCookies = false
      urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
      urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
      for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
      if hops == 0, let body = request.body { urlRequest.httpBody = body }
      let bytesSent =
        url.absoluteString.utf8.count + (urlRequest.httpBody?.count ?? 0)
        + (urlRequest.allHTTPHeaderFields ?? [:]).reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 4 }

      let started = DispatchTime.now().uptimeNanoseconds
      let time = now()
      let transport = self.transport
      let maximumBytes = request.maximumBytes
      let timeout = request.timeout
      let sending = urlRequest
      let id = UUID()
      let task = Task { await transport.perform(sending, maximumBytes: maximumBytes, timeout: timeout) }
      inFlight[id] = task
      let result = await withTaskCancellationHandler {
        await task.value
      } onCancel: {
        task.cancel()
      }
      inFlight[id] = nil
      let finished = DispatchTime.now().uptimeNanoseconds
      let duration = Int((finished - started) / 1_000_000)

      switch result {
      case .failure(let failure):
        await activity.append(
          NetworkActivityEntry(
            time: time, device: device, kind: request.kind, service: request.service, host: host,
            bytesSent: failure == .cannotConnect ? 0 : bytesSent, result: .failed,
            durationMilliseconds: duration))
        switch failure {
        case .cannotConnect: return .failure(.cannotConnect)
        case .timedOut: return .failure(.timedOut)
        case .cancelled: return .failure(isOff ? .off : .cancelled)
        case .other: return .failure(.other)
        }
      case .success(let reply):
        let isRedirect = (300...399).contains(reply.status) && reply.status != 304
        let entry = NetworkActivityEntry(
          time: time, device: device, kind: request.kind, service: request.service, host: host,
          bytesSent: bytesSent, bytesReceived: reply.body.count,
          result: (200...399).contains(reply.status) ? .found : .failed, status: reply.status,
          durationMilliseconds: duration)
        await activity.append(entry)
        if request.followRedirects, isRedirect, let location = reply.headers["location"],
          let next = URL(string: location, relativeTo: url)?.absoluteURL
        {
          if request.sameSiteRedirectsOnly, next.host.map(OutboundCheck.site(of:)) != site {
            return .failure(.offSiteRedirect(next))
          }
          hops += 1
          guard hops <= Self.maximumRedirects else { return .failure(.tooManyRedirects) }
          url = next
          continue
        }
        return .success(
          EgressResponse(
            status: reply.status, headers: reply.headers, body: reply.body, requestedURL: request.url,
            finalURL: url, truncated: reply.truncated, activityID: entry.id, retrievedAt: time,
            uptimeNanoseconds: finished))
      }
    }
  }

  /// The dry run's plan so far, cleared.
  public func takePlanned() -> [PlannedRequest] {
    defer { planned = [] }
    return planned
  }

  /// Amends a line once its answer is read.
  public func amend(_ id: UUID, result: NetworkActivityResult) async {
    await activity.amend(id, result: result)
  }

  private func pace(_ host: String) async {
    let interval = Self.minimumInterval[host] ?? 0
    guard interval > 0 else { return }
    let current = now()
    if let next = nextAllowed[host], next > current {
      nextAllowed[host] = next.addingTimeInterval(interval)
      await sleep(next.timeIntervalSince(current))
    } else {
      nextAllowed[host] = current.addingTimeInterval(interval)
    }
  }
}
