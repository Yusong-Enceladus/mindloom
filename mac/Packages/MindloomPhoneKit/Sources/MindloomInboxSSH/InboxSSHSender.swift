import Crypto
import Foundation
import MindloomLink
import MindloomPhoneKit
import NIOCore
import NIOSSH
import NIOTransportServices

/// Delivers sealed outbox entries to the Spark's `zhiji-inbox gate` over SSH
/// (PHONE-CONTRACT §4, §5):
///
/// - Connects with Network.framework (NIO Transport Services), which on iOS
///   brings up cellular and VPN-on-demand where BSD sockets would not.
/// - With a relay, opens a `direct-tcpip` channel through it to the Spark's
///   host and port (the only thing the relay lets the phone key do) and runs
///   a second, end-to-end SSH connection inside it. The relay sees only that
///   encrypted stream.
/// - Every hop's host key must equal the key pinned in the pairing, or the
///   connection is dropped before authentication and nothing is sent.
/// - Authenticates with the phone's ed25519 key only.
/// - Runs `zhiji-inbox add --sealed --id <entry_id> --json` with the wire on
///   stdin and accepts `{"ok":true,"id":…}`; a duplicate id is success.
public struct InboxSSHSender: InboxSessionOpening {
  public let configuration: InboxSSHConfiguration
  private let group: any EventLoopGroup

  public init(
    configuration: InboxSSHConfiguration, group: any EventLoopGroup = NIOTSEventLoopGroup.singleton
  ) {
    self.configuration = configuration
    self.group = group
  }

  public func openSession() async throws -> any InboxSession {
    try await InboxSSHConnection.open(configuration: configuration, group: group)
  }
}

/// One connected, authenticated path to the Spark.
final class InboxSSHConnection: InboxSession {
  private let configuration: InboxSSHConfiguration
  /// The TCP connection to the first hop.
  private let root: any Channel
  /// The channel whose pipeline holds the Spark's `NIOSSHHandler`: `root`
  /// without a relay, the `direct-tcpip` child channel with one.
  private let sparkChannel: any Channel

  private init(configuration: InboxSSHConfiguration, root: any Channel, sparkChannel: any Channel) {
    self.configuration = configuration
    self.root = root
    self.sparkChannel = sparkChannel
  }

  static func open(configuration: InboxSSHConfiguration, group: any EventLoopGroup) async throws
    -> InboxSSHConnection
  {
    let firstHop: InboxHop = configuration.relay == nil ? .spark : .relay
    let firstEndpoint = configuration.relay ?? configuration.spark
    let firstClient = try clientConfiguration(configuration, hop: firstHop)
    let loop = group.next()
    let firstAuthenticated = loop.makePromise(of: Void.self)

    let root: any Channel
    do {
      root = try await makeBootstrap(group: loop, timeout: configuration.connectTimeout)
        .channelInitializer { channel in
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandlers(
              NIOSSHHandler(
                role: .client(firstClient.make()), allocator: channel.allocator,
                inboundChildChannelInitializer: nil),
              HopWatcher(hop: firstHop, authenticated: firstAuthenticated))
          }
        }
        .connect(host: firstEndpoint.host, port: firstEndpoint.port)
        .get()
    } catch {
      firstAuthenticated.fail(InboxSSHErrors.map(error, hop: firstHop))
      throw InboxSSHErrors.map(error, hop: firstHop)
    }

    do {
      try await withDeadline(configuration.handshakeTimeout, closing: root, hop: firstHop) {
        try await firstAuthenticated.futureResult.get()
      }
      guard configuration.relay != nil else {
        return InboxSSHConnection(configuration: configuration, root: root, sparkChannel: root)
      }
      let tunnel = try await openSparkThroughRelay(configuration: configuration, relayChannel: root)
      return InboxSSHConnection(configuration: configuration, root: root, sparkChannel: tunnel)
    } catch {
      root.close(promise: nil)
      throw InboxSSHErrors.map(error, hop: firstHop)
    }
  }

  /// Opens `direct-tcpip` to the Spark through the authenticated relay and
  /// completes a second SSH handshake (with the Spark's pinned key) inside.
  private static func openSparkThroughRelay(
    configuration: InboxSSHConfiguration, relayChannel: any Channel
  ) async throws -> any Channel {
    let sparkClient = try clientConfiguration(configuration, hop: .spark)
    let loop = relayChannel.eventLoop
    let sparkAuthenticated = loop.makePromise(of: Void.self)
    let childPromise = loop.makePromise(of: (any Channel).self)
    let target = SSHChannelType.DirectTCPIP(
      targetHost: configuration.spark.host, targetPort: configuration.spark.port,
      originatorAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 0))

    try await loop.submit {
      do {
        let relaySSH = try relayChannel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
        relaySSH.createChannel(childPromise, channelType: .directTCPIP(target)) { child, _ in
          child.eventLoop.makeCompletedFuture {
            try child.pipeline.syncOperations.addHandlers(
              SSHChannelDataCodec(),
              NIOSSHHandler(
                role: .client(sparkClient.make()), allocator: child.allocator,
                inboundChildChannelInitializer: nil),
              HopWatcher(hop: .spark, authenticated: sparkAuthenticated))
          }
        }
      } catch {
        // Never leave a promise unfulfilled.
        childPromise.fail(error)
        sparkAuthenticated.fail(error)
        throw error
      }
    }.get()

    let child: any Channel
    do {
      child = try await withDeadline(
        configuration.handshakeTimeout, closing: relayChannel, hop: .relay
      ) {
        try await childPromise.futureResult.get()
      }
    } catch {
      // A refused channel open (NIOSSHError.channelSetupRejected) maps to
      // `.relayRefused`: the relay would not forward to the Spark.
      let mapped = InboxSSHErrors.map(error, hop: .relay)
      sparkAuthenticated.fail(mapped)
      throw mapped
    }
    try await withDeadline(configuration.handshakeTimeout, closing: relayChannel, hop: .spark) {
      try await sparkAuthenticated.futureResult.get()
    }
    return child
  }

  // MARK: - InboxSession

  func add(entryID: String, wire: String) async throws -> InboxAddReceipt {
    let command = try configuration.addCommand(entryID: entryID)
    guard wire.hasPrefix(MindloomSeal.wirePrefix), wire.utf8.count <= MindloomSeal.maximumWireBytes
    else {
      throw InboxDeliveryError(.rejected, detail: "not a sealed wire")
    }
    let loop = sparkChannel.eventLoop
    let result = loop.makePromise(of: ExecOutcome.self)
    let stdin = ByteBuffer(string: wire)
    let sparkChannel = self.sparkChannel

    do {
      try await loop.submit {
        let opened = loop.makePromise(of: (any Channel).self)
        opened.futureResult.whenFailure { error in
          result.fail(InboxSSHErrors.map(error, hop: .spark))
        }
        do {
          let sparkSSH = try sparkChannel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
          sparkSSH.createChannel(opened, channelType: .session) { channel, _ in
            channel.eventLoop.makeCompletedFuture {
              try channel.pipeline.syncOperations.addHandler(
                ExecCollector(command: command, stdin: stdin, result: result))
            }
          }
        } catch {
          opened.fail(error)
          throw error
        }
      }.get()
    } catch {
      throw InboxSSHErrors.map(error, hop: .spark)
    }

    let mebibytes = Int64(wire.utf8.count / (1024 * 1024))
    let timeout =
      configuration.commandTimeout
      + .nanoseconds(configuration.commandTimeoutPerMiB.nanoseconds * mebibytes)
    let outcome = try await withDeadline(timeout, closing: root, hop: .spark) {
      try await result.futureResult.get()
    }
    return try InboxGateReply.receipt(from: outcome, entryID: entryID)
  }

  func close() async {
    try? await root.close().get()
  }

  // MARK: - Helpers

  /// A client configuration factory: delegates are created per connection.
  struct ClientConfigurationFactory: Sendable {
    let user: String
    let pinned: NIOSSHPublicKey
    let key: Curve25519.Signing.PrivateKey
    let hop: InboxHop

    func make() -> SSHClientConfiguration {
      SSHClientConfiguration(
        userAuthDelegate: PhoneKeyAuthenticator(username: user, key: key, hop: hop),
        serverAuthDelegate: PinnedHostKeyValidator(pinned: pinned, hop: hop))
    }
  }

  static func clientConfiguration(_ configuration: InboxSSHConfiguration, hop: InboxHop) throws
    -> ClientConfigurationFactory
  {
    let endpoint = hop == .relay ? configuration.relay! : configuration.spark
    return ClientConfigurationFactory(
      user: endpoint.user, pinned: try configuration.pinnedKey(for: hop),
      key: configuration.phoneKey, hop: hop)
  }

  static func makeBootstrap(group: any EventLoopGroup, timeout: TimeAmount) throws
    -> NIOTSConnectionBootstrap
  {
    guard let bootstrap = NIOTSConnectionBootstrap(validatingGroup: group) else {
      throw InboxDeliveryError(.network, detail: "not a Network.framework event loop")
    }
    // Fail fast when there is no path (offline, refused) instead of waiting
    // in Network.framework's `.waiting` state until the timeout: the outbox
    // keeps the entry and the next trigger tries again.
    return bootstrap.connectTimeout(timeout)
      .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
  }
}

/// Waits for `operation`; if `timeout` passes first, closes `channel` (which
/// fails every pending promise on it) and throws a timeout.
func withDeadline<T: Sendable>(
  _ timeout: TimeAmount, closing channel: any Channel, hop: InboxHop,
  _ operation: @Sendable () async throws -> T
) async throws -> T {
  let timedOut = TimeoutFlag()
  let scheduled = channel.eventLoop.scheduleTask(in: timeout) {
    timedOut.set()
    channel.close(promise: nil)
  }
  defer { scheduled.cancel() }
  do {
    return try await operation()
  } catch {
    if timedOut.isSet { throw InboxDeliveryError(.timeout, detail: "\(hop.rawValue): timed out") }
    throw error
  }
}

final class TimeoutFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func set() { lock.withLock { value = true } }
  var isSet: Bool { lock.withLock { value } }
}

/// Parses what the gate printed for `add --sealed --json`.
enum InboxGateReply {
  static func receipt(from outcome: ExecOutcome, entryID: String) throws -> InboxAddReceipt {
    let stdout = String(buffer: outcome.stdout)
    let reply = stdout.split(whereSeparator: \.isNewline).reversed().lazy
      .compactMap { line -> [String: Any]? in
        guard let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8) else {
          return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      }
      .first

    guard let reply else {
      if let status = outcome.exitStatus, status != 0 {
        throw InboxDeliveryError(.rejected, detail: "exit \(status): \(shortStderr(outcome))")
      }
      throw InboxDeliveryError(.protocolError, detail: "no JSON reply")
    }
    let ok = reply["ok"] as? Bool ?? false
    let replyID = (reply["id"] as? String) ?? (reply["inbox_id"] as? String)
    if let replyID, replyID.lowercased() != entryID {
      throw InboxDeliveryError(.protocolError, detail: "reply for another id")
    }
    if ok {
      guard outcome.exitStatus == nil || outcome.exitStatus == 0 else {
        throw InboxDeliveryError(.protocolError, detail: "ok with exit \(outcome.exitStatus!)")
      }
      return InboxAddReceipt(entryID: entryID, duplicate: reply["duplicate"] as? Bool ?? false)
    }
    let error = (reply["error"] as? String ?? "").lowercased()
    if ["duplicate", "duplicate_id", "exists", "already_exists"].contains(error) {
      return InboxAddReceipt(entryID: entryID, duplicate: true)
    }
    // The Spark's organizer is down or restarting (exit 2): nothing is wrong
    // with the entry, so it is a transient failure, retried like a dropped
    // network, never a rejection.
    if error == "unavailable" {
      throw InboxDeliveryError(.network, detail: "gate: organizer unavailable")
    }
    throw InboxDeliveryError(.rejected, detail: "gate: \(error.prefix(80))")
  }

  private static func shortStderr(_ outcome: ExecOutcome) -> String {
    String(String(buffer: outcome.stderr).prefix(160))
  }
}
