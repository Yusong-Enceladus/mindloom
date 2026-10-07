import Foundation
import XCTest

@testable import MindloomLookup

/// Recorded answers by host and path: the tests never touch the network.
final class FakeTransport: LookupTransport, @unchecked Sendable {
  struct Sent: Sendable {
    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data?
  }

  typealias Responder = @Sendable (URLRequest) -> Result<TransportReply, TransportFailure>

  private let lock = NSLock()
  private var routes: [(match: @Sendable (URL) -> Bool, respond: Responder)] = []
  private var log: [Sent] = []

  var sent: [Sent] { lock.withLock { log } }
  var hosts: [String] { sent.compactMap { $0.url.host } }

  func on(host: String, path: String? = nil, _ respond: @escaping Responder) {
    let match: @Sendable (URL) -> Bool = { url in
      url.host == host && (path.map { url.path.hasPrefix($0) } ?? true)
    }
    lock.withLock { routes.insert((match, respond), at: 0) }
  }

  func on(host: String, path: String? = nil, status: Int = 200, headers: [String: String] = [:], body: Data) {
    on(host: host, path: path) { _ in .success(TransportReply(status: status, headers: headers, body: body)) }
  }

  func on(host: String, path: String? = nil, failure: TransportFailure) {
    on(host: host, path: path) { _ in .failure(failure) }
  }

  func perform(_ request: URLRequest, maximumBytes: Int, timeout: TimeInterval) async
    -> Result<TransportReply, TransportFailure>
  {
    let responder = lock.withLock { () -> Responder? in
      log.append(
        Sent(
          url: request.url!, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:],
          body: request.httpBody))
      return routes.first(where: { $0.match(request.url!) })?.respond
    }
    guard let responder else { return .failure(.cannotConnect) }
    switch responder(request) {
    case .success(var reply):
      if reply.body.count > maximumBytes {
        reply.body = reply.body.prefix(maximumBytes)
        reply.truncated = true
      }
      return .success(reply)
    case .failure(let failure):
      return .failure(failure)
    }
  }
}

/// Answers every name with a public address unless told otherwise, and
/// remembers which names it was asked for.
final class FakeResolver: HostResolver, @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [String: [String]] = [:]
  private var asked: [String] = []

  var queries: [String] { lock.withLock { asked } }

  func answer(_ host: String, _ addresses: [String]) {
    lock.withLock { answers[host] = addresses }
  }

  func addresses(for host: String) async -> [IPAddress]? {
    let answer = lock.withLock { () -> [String] in
      asked.append(host)
      return answers[host] ?? ["93.184.216.34"]
    }
    return answer.compactMap(IPAddress.init)
  }
}

struct HoldTimeout: Error {}

/// Holds requests to some hosts until the task is cancelled (as
/// `URLSessionLookupTransport` does, answering `.cancelled`); everything else
/// goes to `base`.
final class SuspendingTransport: LookupTransport, @unchecked Sendable {
  let base: FakeTransport
  private let lock = NSLock()
  private var held: Set<String>
  private var heldCount = 0

  init(base: FakeTransport, holding hosts: Set<String>) {
    self.base = base
    held = hosts
  }

  var holdCount: Int { lock.withLock { heldCount } }

  func release() { lock.withLock { held = [] } }

  func perform(_ request: URLRequest, maximumBytes: Int, timeout: TimeInterval) async
    -> Result<TransportReply, TransportFailure>
  {
    let hold = lock.withLock { () -> Bool in
      guard let host = request.url?.host, held.contains(host) else { return false }
      heldCount += 1
      return true
    }
    guard hold else { return await base.perform(request, maximumBytes: maximumBytes, timeout: timeout) }
    let started = Date()
    while !Task.isCancelled, Date().timeIntervalSince(started) < 20 {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return .failure(Task.isCancelled ? .cancelled : .timedOut)
  }

  /// Waits until a held request arrives.
  func waitForHold(_ count: Int = 1) async throws {
    let started = Date()
    while holdCount < count {
      guard Date().timeIntervalSince(started) < 10 else { throw HoldTimeout() }
      try await Task.sleep(nanoseconds: 2_000_000)
    }
  }
}

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date
  private(set) var slept: [TimeInterval] = []

  init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
    current = start
  }

  var now: Date { lock.withLock { current } }

  func advance(_ seconds: TimeInterval) {
    lock.withLock { current = current.addingTimeInterval(seconds) }
  }

  func sleep(_ seconds: TimeInterval) {
    lock.withLock {
      slept.append(seconds)
      current = current.addingTimeInterval(seconds)
    }
  }
}

enum Fixture {
  static func data(_ path: String) -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(path)", withExtension: nil)!
    return try! Data(contentsOf: url)
  }

  static func text(_ path: String) -> String {
    String(decoding: data(path), as: UTF8.self)
  }
}

func makeLookup(
  transport: FakeTransport, resolver: FakeResolver = FakeResolver(), keys: [SearchServiceID: String] = [:],
  clock: TestClock = TestClock(), dataRoot: URL? = nil, enabled: Bool = true, dryRun: Bool = false,
  readerService: Bool = true
) async -> WebLookup {
  let lookup = WebLookup(
    dataRoot: dataRoot, keys: InMemorySearchKeyStore(keys), device: "Mac", transport: transport,
    resolver: resolver, dryRun: dryRun, allowsReaderService: readerService, now: { clock.now },
    sleep: { clock.sleep($0) })
  if enabled { try? await lookup.setEnabled(true) }
  return lookup
}

func temporaryFolder() -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("mindloom-lookup-tests-\(UUID().uuidString)", isDirectory: true)
  try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

let matterA = UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!
let itemA = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!

func request(
  _ gap: LookupGap, _ kind: LookupSubjectKind = .conference, _ name: String? = "EXCONF", year: Int? = 2026,
  matter: UUID = matterA, identifiers: [PublicIdentifier] = [], approval: LookupApproval? = nil,
  site: String? = nil, health: Bool = false
) -> LookupRequest {
  LookupRequest(
    matterID: matter, parentItemID: itemA, gap: gap, subject: name.map { LookupSubject(kind: kind, name: $0) },
    year: year, officialSite: site, identifiers: identifiers, approval: approval, healthRelated: health)
}

func bodyJSON(_ sent: FakeTransport.Sent) -> [String: Any] {
  guard let body = sent.body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
    return [:]
  }
  return object
}
