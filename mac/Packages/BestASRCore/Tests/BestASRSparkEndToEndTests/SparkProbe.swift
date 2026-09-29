import BestASRRemoteOrganizer
import Foundation

/// Asks the organizing device what it has processed, so a run ends when the
/// Spark itself reports every sent item done instead of only after a quiet
/// spell. It uses a forward of its own, made exactly as the link's (the same
/// launcher, with its records in its own state directory) and the link token
/// held in memory only; it reads `/v1/health` and `/v1/debug/jobs` and sends
/// nothing.
@MainActor
final class SparkProbe {
  /// One job row: the newest revision of an item on the Spark.
  struct Job: Equatable {
    let revision: Int
    let state: String
    let errorCategory: String?
    let enqueuedAt: Double?
    let runEnded: Double?

    /// `queued` and `running` are still to be processed; `done`, `failed`
    /// and `superseded` are finished.
    var isFinished: Bool { !["queued", "running"].contains(state) }
  }

  struct Status: Equatable {
    /// Jobs queued or running on the Spark (split parts included).
    let queue: Int
    let items: Int?
    let events: Int?
    let storeID: String?
    /// Upper-case item ID → its newest job.
    let jobs: [String: Job]

    /// The sent items the Spark has not finished (or never received).
    func unfinished(_ ids: [String]) -> [String] {
      ids.filter { jobs[$0.uppercased()]?.isFinished != true }
    }

    /// Everything sent is finished and nothing else is waiting.
    func processedAll(_ ids: [String]) -> Bool {
      queue == 0 && unfinished(ids).isEmpty
    }
  }

  struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  private let launcher: any RemoteOrganizerTunnelLauncher
  private let http: any RemoteOrganizerHTTPTransport
  private let readyTimeout: TimeInterval
  private var tunnel: (any RemoteOrganizerTunnelProcess)?
  /// Held in memory only; never written, logged or passed to a process.
  private var token: String?

  init(
    launcher: any RemoteOrganizerTunnelLauncher, http: any RemoteOrganizerHTTPTransport,
    readyTimeout: TimeInterval = 20
  ) {
    self.launcher = launcher
    self.http = http
    self.readyTimeout = readyTimeout
  }

  /// The probe for a run: its own SSH forward, records in `stateDirectory`.
  convenience init(link: RemoteOrganizerLinkConfiguration, stateDirectory: URL) {
    self.init(
      launcher: SSHRemoteOrganizerTunnelLauncher(
        configuration: link, stateDirectory: stateDirectory),
      http: URLSessionRemoteOrganizerTransport())
  }

  func status() async throws -> Status {
    let health = try await get("/v1/health", timeout: 10)
    let listing = try await get("/v1/debug/jobs", timeout: 40)
    return try Self.status(health: health, jobs: listing)
  }

  /// Ends the forward (before the run's revocation check counts tunnels).
  func close() {
    tunnel?.terminateAndWait()
    tunnel = nil
    token = nil
  }

  static func status(health: Data, jobs: Data) throws -> Status {
    guard let object = try JSONSerialization.jsonObject(with: health) as? [String: Any],
      let queue = (object["queue"] as? NSNumber)?.intValue
    else { throw ProbeError("health has no queue") }
    guard let listing = try JSONSerialization.jsonObject(with: jobs) as? [String: Any],
      let rows = listing["jobs"] as? [[String: Any]]
    else { throw ProbeError("jobs listing has no jobs") }
    var newest: [String: Job] = [:]
    for row in rows {
      guard let id = row["item_id"] as? String, let state = row["state"] as? String else {
        continue
      }
      let job = Job(
        revision: (row["revision"] as? NSNumber)?.intValue ?? 0, state: state,
        errorCategory: row["error_category"] as? String,
        enqueuedAt: (row["enqueued_at"] as? NSNumber)?.doubleValue,
        runEnded: (row["run_ended"] as? NSNumber)?.doubleValue)
      let key = id.uppercased()
      if let known = newest[key], known.revision > job.revision { continue }
      newest[key] = job
    }
    return Status(
      queue: queue, items: (object["items"] as? NSNumber)?.intValue,
      events: (object["events"] as? NSNumber)?.intValue, storeID: object["store_id"] as? String,
      jobs: newest)
  }

  private func get(_ path: String, timeout: TimeInterval) async throws -> Data {
    let (port, token) = try await connect()
    let response: RemoteOrganizerHTTPResponse
    do {
      response = try await http.send(
        RemoteOrganizerHTTPRequest(
          method: "GET", port: port, path: path, body: nil, token: token, timeout: timeout))
    } catch {
      // The forward may have dropped; the next call makes a new one.
      close()
      throw ProbeError("\(path) not reached")
    }
    if response.status == 401 { self.token = nil }
    guard (200..<300).contains(response.status) else {
      throw ProbeError("\(path) answered \(response.status)")
    }
    return response.body
  }

  private func connect() async throws -> (port: Int, token: String) {
    if let tunnel, tunnel.isRunning,
      launcher.listenerIsOwned(by: tunnel.processIdentifier, port: tunnel.localPort)
    {
      return (tunnel.localPort, try await linkToken())
    }
    close()
    let port = try launcher.freeLoopbackPort()
    let process = try await launcher.launchForward(localPort: port)
    tunnel = process
    let deadline = Date().addingTimeInterval(readyTimeout)
    while !launcher.listenerIsOwned(by: process.processIdentifier, port: port) {
      guard process.isRunning, Date() < deadline else {
        close()
        throw ProbeError("forward not ready")
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    return (port, try await linkToken())
  }

  private func linkToken() async throws -> String {
    if let token { return token }
    let fetched = try await launcher.fetchLinkToken()
    guard RemoteOrganizerSSHCommand.isValidLinkToken(fetched) else {
      throw ProbeError("link token unusable")
    }
    token = fetched
    return fetched
  }
}
