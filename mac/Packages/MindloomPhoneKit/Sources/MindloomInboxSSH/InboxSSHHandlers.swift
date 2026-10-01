import Crypto
import Foundation
import MindloomPhoneKit
import NIOCore
import NIOSSH

// MARK: - Server (host) authentication: pinned key only

/// Accepts exactly the host key from the pairing and nothing else. There is
/// no trust-on-first-use and no known_hosts fallback.
final class PinnedHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
  let pinned: NIOSSHPublicKey
  let hop: InboxHop

  init(pinned: NIOSSHPublicKey, hop: InboxHop) {
    self.pinned = pinned
    self.hop = hop
  }

  func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>)
  {
    if hostKey == pinned {
      validationCompletePromise.succeed(())
    } else {
      validationCompletePromise.fail(
        InboxDeliveryError(
          .hostKeyMismatch, detail: "\(hop.rawValue): host key differs from the pairing"))
    }
  }
}

// MARK: - User authentication: the phone's ed25519 key, offered once

/// Offers the phone's key once. If the server refuses it, authentication
/// fails immediately instead of trying anything else (there is nothing else).
final class PhoneKeyAuthenticator: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
  private let username: String
  private let key: NIOSSHPrivateKey
  private let hop: InboxHop
  // Only touched on the connection's event loop.
  private var offered = false

  init(username: String, key: Curve25519.Signing.PrivateKey, hop: InboxHop) {
    self.username = username
    self.key = NIOSSHPrivateKey(ed25519Key: key)
    self.hop = hop
  }

  func nextAuthenticationType(
    availableMethods: NIOSSHAvailableUserAuthenticationMethods,
    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
  ) {
    guard !offered, availableMethods.contains(.publicKey) else {
      nextChallengePromise.fail(
        InboxDeliveryError(.authentication, detail: "\(hop.rawValue): phone key refused"))
      return
    }
    offered = true
    nextChallengePromise.succeed(
      NIOSSHUserAuthenticationOffer(
        username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
  }
}

// MARK: - Per-hop watcher

/// Sits after a `NIOSSHHandler` and turns what happens on that SSH
/// connection into one outcome: authenticated, or the first failure.
final class HopWatcher: ChannelInboundHandler, RemovableChannelHandler {
  typealias InboundIn = Any

  let hop: InboxHop
  let authenticated: EventLoopPromise<Void>
  private var failure: InboxDeliveryError?
  private var settled = false

  init(hop: InboxHop, authenticated: EventLoopPromise<Void>) {
    self.hop = hop
    self.authenticated = authenticated
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if event is UserAuthSuccessEvent, !settled {
      settled = true
      authenticated.succeed(())
    }
    context.fireUserInboundEventTriggered(event)
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    let mapped = InboxSSHErrors.map(error, hop: hop)
    if failure == nil { failure = mapped }
    settle(with: mapped)
    context.close(promise: nil)
  }

  func channelInactive(context: ChannelHandlerContext) {
    settle(
      with: failure ?? InboxDeliveryError(.network, detail: "\(hop.rawValue): connection closed"))
    context.fireChannelInactive()
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    settle(
      with: failure ?? InboxDeliveryError(.network, detail: "\(hop.rawValue): connection closed"))
  }

  private func settle(with error: InboxDeliveryError) {
    guard !settled else { return }
    settled = true
    authenticated.fail(error)
  }
}

// MARK: - Relay tunnel: SSH channel data <-> bytes

/// Unwraps a `direct-tcpip` child channel into plain bytes, so a second SSH
/// connection (to the Spark) can run inside it.
final class SSHChannelDataCodec: ChannelDuplexHandler, RemovableChannelHandler {
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
    let bytes = unwrapOutboundIn(data)
    context.write(
      wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bytes))), promise: promise)
  }
}

// MARK: - One exec: command, stdin, then collect the reply

struct ExecOutcome: Sendable {
  var exitStatus: Int?
  var stdout: ByteBuffer
  var stderr: ByteBuffer
  var stdoutTruncated: Bool
}

/// Runs one command on a session channel: sends `exec` (wanting a reply),
/// writes stdin once the server accepted it, half-closes, and collects the
/// bounded stdout/stderr and exit status until the server closes the channel.
final class ExecCollector: ChannelDuplexHandler {
  typealias InboundIn = SSHChannelData
  typealias InboundOut = Never
  typealias OutboundIn = Never
  typealias OutboundOut = SSHChannelData

  static let maximumStdout = 64 * 1024
  static let maximumStderr = 4 * 1024

  private let command: String
  private var stdin: ByteBuffer?
  private let result: EventLoopPromise<ExecOutcome>
  private var outcome = ExecOutcome(
    exitStatus: nil, stdout: ByteBuffer(), stderr: ByteBuffer(), stdoutTruncated: false)
  private var settled = false

  init(command: String, stdin: ByteBuffer, result: EventLoopPromise<ExecOutcome>) {
    self.command = command
    self.stdin = stdin
    self.result = result
  }

  func handlerAdded(context: ChannelHandlerContext) {
    // The server may close its side (EOF) before sending exit-status.
    context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure {
      [result] error in result.fail(InboxSSHErrors.map(error, hop: .spark))
    }
    if context.channel.isActive { sendExec(context: context) }
  }

  func channelActive(context: ChannelHandlerContext) {
    sendExec(context: context)
    context.fireChannelActive()
  }

  private var execSent = false

  private func sendExec(context: ChannelHandlerContext) {
    guard !execSent else { return }
    execSent = true
    let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
    let loopBound = NIOLoopBound(self, eventLoop: context.eventLoop)
    let contextBound = NIOLoopBound(context, eventLoop: context.eventLoop)
    context.triggerUserOutboundEvent(request).whenFailure { error in
      loopBound.value.fail(InboxSSHErrors.map(error, hop: .spark), context: contextBound.value)
    }
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    switch event {
    case is ChannelSuccessEvent:
      // The gate accepted the command: stream the wire, then EOF.
      guard let stdin else { return }
      self.stdin = nil
      context.write(
        wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(stdin))), promise: nil)
      context.close(mode: .output, promise: nil)
    case is ChannelFailureEvent:
      fail(InboxDeliveryError(.rejected, detail: "exec refused"), context: context)
    case let status as SSHChannelRequestEvent.ExitStatus:
      outcome.exitStatus = status.exitStatus
    default:
      context.fireUserInboundEventTriggered(event)
    }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let data = unwrapInboundIn(data)
    guard case .byteBuffer(var bytes) = data.data else { return }
    switch data.type {
    case .channel:
      let room = Self.maximumStdout - outcome.stdout.readableBytes
      if bytes.readableBytes > room { outcome.stdoutTruncated = true }
      if room > 0, let slice = bytes.readSlice(length: min(room, bytes.readableBytes)) {
        outcome.stdout.writeImmutableBuffer(slice)
      }
    case .stdErr:
      let room = Self.maximumStderr - outcome.stderr.readableBytes
      if room > 0, let slice = bytes.readSlice(length: min(room, bytes.readableBytes)) {
        outcome.stderr.writeImmutableBuffer(slice)
      }
    default:
      break
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    finish()
    context.fireChannelInactive()
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    finish()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    fail(InboxSSHErrors.map(error, hop: .spark), context: context)
  }

  private func finish() {
    guard !settled else { return }
    settled = true
    result.succeed(outcome)
  }

  private func fail(_ error: InboxDeliveryError, context: ChannelHandlerContext) {
    guard !settled else { return }
    settled = true
    result.fail(error)
    context.close(promise: nil)
  }
}

// MARK: - Error mapping

enum InboxSSHErrors {
  /// Maps anything thrown on a hop to a content-free delivery error.
  static func map(_ error: Error, hop: InboxHop) -> InboxDeliveryError {
    if let error = error as? InboxDeliveryError { return error }
    if let error = error as? NIOSSHError {
      switch error.type {
      case .channelSetupRejected:
        return InboxDeliveryError(.relayRefused, detail: "\(hop.rawValue): channel open refused")
      case .invalidHostKeyForKeyExchange, .invalidExchangeHashSignature:
        return InboxDeliveryError(
          .hostKeyMismatch, detail: "\(hop.rawValue): host key proof invalid")
      case .keyExchangeNegotiationFailure, .unsupportedVersion, .protocolViolation:
        return InboxDeliveryError(.protocolError, detail: "\(hop.rawValue): \(error.type)")
      default:
        return InboxDeliveryError(.network, detail: "\(hop.rawValue): \(error.type)")
      }
    }
    if let error = error as? ChannelError {
      switch error {
      case .connectTimeout:
        return InboxDeliveryError(.timeout, detail: "\(hop.rawValue): connect timeout")
      default:
        return InboxDeliveryError(.network, detail: "\(hop.rawValue): \(error)")
      }
    }
    return InboxDeliveryError(.network, detail: "\(hop.rawValue): \(type(of: error))")
  }
}
