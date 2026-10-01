import Crypto
import Foundation
import MindloomLink
import NIOCore
import NIOPosix
import NIOSSH

/// Shared server-side event loops for the in-process SSH servers.
let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

/// A thread-safe box for what the servers observed.
final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  func read<T>(_ body: (Value) -> T) -> T { lock.withLock { body(value) } }
  func change<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

/// Allows exactly one public key for one user, like the `authorized_keys`
/// line the Mac installs for the phone.
final class SingleKeyAuthorizer: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
  let user: String
  let key: NIOSSHPublicKey
  let attempts: Locked<Int>

  init(user: String, key: NIOSSHPublicKey, attempts: Locked<Int>) {
    self.user = user
    self.key = key
    self.attempts = attempts
  }

  var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }

  func requestReceived(
    request: NIOSSHUserAuthenticationRequest,
    responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
  ) {
    attempts.change { $0 += 1 }
    guard request.username == user, case .publicKey(let offered) = request.request,
      offered.publicKey == key
    else {
      responsePromise.succeed(.failure)
      return
    }
    responsePromise.succeed(.success)
  }
}

// MARK: - The Spark: an SSH server running a fake `zhiji-inbox gate`

/// Emulates the Spark's forced command `zhiji-inbox gate` for the phone key:
/// only `… add --sealed --id <uuid> [--json]` is allowed, stdin must be an
/// `mlseal1.` wire, and the blob is stored without being read.
final class FakeSpark: @unchecked Sendable {
  enum Behaviour: Sendable {
    case normal
    /// The current Spark's reply shape: `inbox_id` instead of `id`.
    case legacyReply
    /// `{"ok":false,"error":"too_large"}`, exit 1.
    case rejectEntries
    /// The forced command refuses to run (channel request failure).
    case refuseExec
    /// Prints something that is not JSON, exit 0.
    case garbage
    /// Answers for a different id.
    case wrongID
    /// Never answers.
    case hang
  }

  struct Observed {
    var commands: [String] = []
    var blobs: [String: String] = [:]
    var connections = 0
  }

  let hostKey: NIOSSHPrivateKey
  let user: String
  let phoneKey: NIOSSHPublicKey
  let behaviour: Locked<Behaviour>
  let observed = Locked(Observed())
  let authAttempts = Locked(0)
  private var channel: (any Channel)?

  init(
    hostKey: Curve25519.Signing.PrivateKey, user: String, phoneKey: Curve25519.Signing.PublicKey,
    behaviour: Behaviour = .normal
  ) {
    self.hostKey = NIOSSHPrivateKey(ed25519Key: hostKey)
    self.user = user
    self.phoneKey = try! NIOSSHPublicKey(
      openSSHPublicKey: PairingPayload.openSSHPublicKey(phoneKey))
    self.behaviour = Locked(behaviour)
  }

  var port: Int { channel?.localAddress?.port ?? 0 }

  func start() async throws {
    let hostKey = self.hostKey
    let authorizer = SingleKeyAuthorizer(user: user, key: phoneKey, attempts: authAttempts)
    let spark = self
    channel = try await ServerBootstrap(group: serverGroup)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        spark.observed.change { $0.connections += 1 }
        return channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            NIOSSHHandler(
              role: .server(
                .init(
                  hostKeys: [hostKey], userAuthDelegate: authorizer, globalRequestDelegate: nil,
                  banner: nil)),
              allocator: channel.allocator,
              inboundChildChannelInitializer: { child, type in
                guard case .session = type else {
                  return child.eventLoop.makeFailedFuture(ChannelError.operationUnsupported)
                }
                return child.eventLoop.makeCompletedFuture {
                  try child.pipeline.syncOperations.addHandler(GateHandler(spark: spark))
                }
              }))
        }
      }
      .bind(host: "127.0.0.1", port: 0).get()
  }

  func stop() async {
    try? await channel?.close().get()
  }

  var blobs: [String: String] { observed.read { $0.blobs } }
  var commands: [String] { observed.read { $0.commands } }
  var connections: Int { observed.read { $0.connections } }

  /// What the gate answers, as the Spark's `zhiji-inbox gate` would.
  fileprivate func handle(command: String, stdin: String) -> (stdout: String, exit: Int)? {
    observed.change { $0.commands.append(command) }
    let words = command.split(separator: " ").map(String.init)
    guard words.count >= 5, words[0].hasSuffix("zhiji-inbox"), words[1] == "add",
      words.contains("--sealed"), let idIndex = words.firstIndex(of: "--id"),
      idIndex + 1 < words.count, EntryID.isValid(words[idIndex + 1]),
      Set(words[2...]).isSubset(of: ["--sealed", "--id", words[idIndex + 1], "--json"])
    else { return ("", 1) }
    let id = words[idIndex + 1]
    guard stdin.hasPrefix("mlseal1.") else { return (#"{"ok":false,"error":"not_sealed"}"#, 1) }

    switch behaviour.read({ $0 }) {
    case .hang:
      return nil
    case .garbage:
      return ("已收进织机\n", 0)
    case .rejectEntries:
      return (#"{"ok":false,"error":"too_large"}"# + "\n", 1)
    case .wrongID:
      return (#"{"ok":true,"id":"\#(EntryID.make())"}"# + "\n", 0)
    case .refuseExec:
      return ("", 1)
    case .normal, .legacyReply:
      let duplicate = observed.change { observed -> Bool in
        if observed.blobs[id] != nil { return true }
        observed.blobs[id] = stdin
        return false
      }
      let key = behaviour.read({ $0 }) == .legacyReply ? "inbox_id" : "id"
      return (#"{"ok":true,"\#(key)":"\#(id)","duplicate":\#(duplicate)}"# + "\n", 0)
    }
  }

  fileprivate var refusesExec: Bool { behaviour.read { $0 } == .refuseExec }
}

/// One exec on the fake Spark: reply to the request, read stdin to EOF, answer.
private final class GateHandler: ChannelDuplexHandler {
  typealias InboundIn = SSHChannelData
  typealias InboundOut = Never
  typealias OutboundIn = Never
  typealias OutboundOut = SSHChannelData

  let spark: FakeSpark
  var command: String?
  var stdin = ByteBuffer()

  init(spark: FakeSpark) { self.spark = spark }

  func handlerAdded(context: ChannelHandlerContext) {
    _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    switch event {
    case let exec as SSHChannelRequestEvent.ExecRequest:
      command = exec.command
      if spark.refusesExec {
        _ = spark.handle(command: exec.command, stdin: "mlseal1.")
        if exec.wantReply { context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
        return
      }
      if exec.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
    case ChannelEvent.inputClosed:
      guard let command else {
        context.close(promise: nil)
        return
      }
      guard let answer = spark.handle(command: command, stdin: String(buffer: stdin)) else {
        return
      }
      var out = context.channel.allocator.buffer(capacity: answer.stdout.utf8.count)
      out.writeString(answer.stdout)
      context.write(
        wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(out))), promise: nil)
      if answer.exit != 0 {
        var err = context.channel.allocator.buffer(capacity: 64)
        err.writeString("zhiji-inbox: refused\n")
        context.write(
          wrapOutboundOut(SSHChannelData(type: .stdErr, data: .byteBuffer(err))), promise: nil)
      }
      context.flush()
      context.triggerUserOutboundEvent(
        SSHChannelRequestEvent.ExitStatus(exitStatus: answer.exit), promise: nil)
      context.close(promise: nil)
    default:
      context.fireUserInboundEventTriggered(event)
    }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let data = unwrapInboundIn(data)
    guard case .channel = data.type, case .byteBuffer(var bytes) = data.data else { return }
    stdin.writeBuffer(&bytes)
  }
}

// MARK: - The relay: forwards direct-tcpip to one permitted target only

/// Emulates the relay's `restrict,port-forwarding,permitopen="<spark>:<port>"`
/// line: no sessions, and forwarding only to the permitted host and port.
final class FakeRelay: @unchecked Sendable {
  let hostKey: NIOSSHPrivateKey
  let user: String
  let phoneKey: NIOSSHPublicKey
  let permitHost: String
  let permitPort: Locked<Int>
  let requestedTargets = Locked([String]())
  let sessionRequests = Locked(0)
  let authAttempts = Locked(0)
  private var channel: (any Channel)?

  init(
    hostKey: Curve25519.Signing.PrivateKey, user: String, phoneKey: Curve25519.Signing.PublicKey,
    permitHost: String, permitPort: Int
  ) {
    self.hostKey = NIOSSHPrivateKey(ed25519Key: hostKey)
    self.user = user
    self.phoneKey = try! NIOSSHPublicKey(
      openSSHPublicKey: PairingPayload.openSSHPublicKey(phoneKey))
    self.permitHost = permitHost
    self.permitPort = Locked(permitPort)
  }

  var port: Int { channel?.localAddress?.port ?? 0 }

  func start() async throws {
    let hostKey = self.hostKey
    let authorizer = SingleKeyAuthorizer(user: user, key: phoneKey, attempts: authAttempts)
    let relay = self
    channel = try await ServerBootstrap(group: serverGroup)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            NIOSSHHandler(
              role: .server(
                .init(
                  hostKeys: [hostKey], userAuthDelegate: authorizer, globalRequestDelegate: nil,
                  banner: nil)),
              allocator: channel.allocator,
              inboundChildChannelInitializer: { child, type in relay.initialize(child, type) }))
        }
      }
      .bind(host: "127.0.0.1", port: 0).get()
  }

  func stop() async {
    try? await channel?.close().get()
  }

  private func initialize(_ child: any Channel, _ type: SSHChannelType) -> EventLoopFuture<Void> {
    guard case .directTCPIP(let target) = type else {
      sessionRequests.change { $0 += 1 }
      return child.eventLoop.makeFailedFuture(ChannelError.operationUnsupported)
    }
    requestedTargets.change { $0.append("\(target.targetHost):\(target.targetPort)") }
    guard target.targetHost == permitHost, target.targetPort == permitPort.read({ $0 }) else {
      return child.eventLoop.makeFailedFuture(ChannelError.operationUnsupported)
    }
    let (toSpark, toPhone) = Glue.pair()
    let loopBound = NIOLoopBound(toSpark, eventLoop: child.eventLoop)
    return child.eventLoop.makeCompletedFuture {
      try child.pipeline.syncOperations.addHandlers(RelayDataCodec(), toPhone)
    }.flatMap {
      ClientBootstrap(group: child.eventLoop)
        .channelInitializer { upstream in
          upstream.eventLoop.makeCompletedFuture {
            try upstream.pipeline.syncOperations.addHandler(loopBound.value)
          }
        }
        .connect(host: target.targetHost, port: target.targetPort)
        .map { _ in () }
    }
  }
}

private final class RelayDataCodec: ChannelDuplexHandler {
  typealias InboundIn = SSHChannelData
  typealias InboundOut = ByteBuffer
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = SSHChannelData

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let data = unwrapInboundIn(data)
    guard case .channel = data.type, case .byteBuffer(let bytes) = data.data else { return }
    context.fireChannelRead(wrapInboundOut(bytes))
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    context.write(
      wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))),
      promise: promise)
  }
}

/// Pipes bytes between two channels on the same event loop.
private final class Glue: ChannelDuplexHandler {
  typealias InboundIn = ByteBuffer
  typealias OutboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer

  private var partner: Glue?
  private var context: ChannelHandlerContext?
  private var pending: [ByteBuffer] = []

  static func pair() -> (Glue, Glue) {
    let first = Glue()
    let second = Glue()
    first.partner = second
    second.partner = first
    return (first, second)
  }

  func handlerAdded(context: ChannelHandlerContext) {
    self.context = context
    for buffer in pending { context.write(wrapOutboundOut(buffer), promise: nil) }
    if !pending.isEmpty { context.flush() }
    pending = []
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    self.context = nil
    partner = nil
  }

  private func deliver(_ buffer: ByteBuffer) {
    guard let context else {
      pending.append(buffer)
      return
    }
    context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    partner?.deliver(unwrapInboundIn(data))
  }

  func channelInactive(context: ChannelHandlerContext) {
    partner?.context?.close(promise: nil)
    context.fireChannelInactive()
  }
}
