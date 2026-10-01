import BestASRDomain
import CoreGraphics
import CoreImage
import CryptoKit
import Darwin
import Foundation
import MindloomLink

/// Which SSH hop a pairing step is about.
public enum PhonePairingHop: String, Codable, Equatable, Sendable {
  /// The organizing device itself.
  case spark
  /// The relay (`ProxyJump`) the Mac's ssh goes through to reach it.
  case relay
}

public enum PhonePairingError: Error, Equatable, Sendable {
  /// The organizing device's ssh alias or the inbox command is not safe.
  case invalidConfiguration
  /// `ssh -G` could not resolve the host from the Mac's ssh configuration.
  case sshConfigUnreadable(PhonePairingHop)
  /// A `ProxyCommand`, several jump hosts, or a relay behind another relay:
  /// the phone cannot reproduce that route.
  case unsupportedProxy
  /// The resolved host name, port or login name cannot go to the phone.
  case invalidEndpoint(PhonePairingHop)
  /// No ed25519/ECDSA host key for this hop in the Mac's known_hosts. Pairing
  /// is refused: the phone never trusts a key it is shown the first time.
  case hostKeyMissing(PhonePairingHop)
  /// The seal key store (Keychain) cannot be read or written.
  case sealKeyUnavailable
  /// Pairing again first removes the previous phone's key; that failed.
  case previousNotRevoked(PhonePairingHop)
  case authorizeFailed(PhonePairingHop)
  case revokeFailed(PhonePairingHop)
}

/// What the Mac remembers about the paired phone: its key ID and where the
/// key was installed, so "断开 iPhone" can remove it. Nothing secret: the
/// phone's private key exists only in the pairing code shown to the user.
public struct PhonePairingState: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let keyID: String
  public let label: String
  /// The Mac's own ssh destination for the organizing device.
  public let spark: SSHDestination
  public let inboxCommand: String
  /// The Mac's own ssh destination for the relay, when there is one.
  public let relay: SSHDestination?
  public let pairedAt: Date

  enum CodingKeys: String, CodingKey {
    case version, label, spark, relay
    case keyID = "key_id"
    case inboxCommand = "inbox_command"
    case pairedAt = "paired_at"
  }

  public init(
    keyID: String, label: String, spark: SSHDestination, inboxCommand: String,
    relay: SSHDestination?, pairedAt: Date
  ) {
    version = Self.currentVersion
    self.keyID = keyID
    self.label = label
    self.spark = spark
    self.inboxCommand = inboxCommand
    self.relay = relay
    self.pairedAt = pairedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .version)
    keyID = try container.decode(String.self, forKey: .keyID)
    label = try container.decode(String.self, forKey: .label)
    spark = try container.decode(SSHDestination.self, forKey: .spark)
    inboxCommand = try container.decode(String.self, forKey: .inboxCommand)
    relay = try container.decodeIfPresent(SSHDestination.self, forKey: .relay)
    pairedAt = try container.decode(Date.self, forKey: .pairedAt)
    guard version == Self.currentVersion, PairingPayload.isValidKeyID(keyID),
      PhoneLinkSSHCommand.isSafeCommandPath(inboxCommand)
    else { throw PhonePairingError.invalidConfiguration }
  }
}

/// A new pairing: the state to remember, and the code for the phone.
public struct PhonePairing: Sendable, CustomStringConvertible {
  public let state: PhonePairingState
  /// `mlpair1.…`, shown as a QR code and copied by "复制配对码". It holds the
  /// phone's private key: kept in memory while shown, never written or
  /// logged by this Mac.
  public let code: String

  public var description: String { "PhonePairing(key_id: \(state.keyID), code: <redacted>)" }
}

/// Where pairing works: the organizing device's ssh alias (the link
/// configuration's host) and the path of `zhiji-inbox` there.
public struct PhonePairingSettings: Equatable, Sendable {
  public let spark: SSHDestination
  public let inboxCommand: String
  /// Tests only: an ssh configuration file (`ssh -F`) instead of the user's.
  public let sshConfigFile: String?

  public init(
    sparkHost: String, inboxCommand: String = PhoneLinkSSHCommand.defaultInboxCommand,
    sshConfigFile: String? = nil
  ) throws {
    guard PhoneLinkSSHCommand.isSafeCommandPath(inboxCommand),
      let spark = try? SSHDestination(host: sparkHost)
    else { throw PhonePairingError.invalidConfiguration }
    self.spark = spark
    self.inboxCommand = inboxCommand
    self.sshConfigFile = sshConfigFile
  }
}

/// "连接 iPhone" and "断开 iPhone" (PHONE-CONTRACT §4): resolves how the Mac's
/// own ssh reaches the organizing device (and its relay), pins their host
/// keys from known_hosts, makes the phone's ed25519 key, installs it on the
/// organizing device (restricted to `zhiji-inbox gate`) and on the relay
/// (forwarding to that one host and port only), and builds the pairing code.
/// All remote work runs over the Mac's own SSH with the link's hardening
/// (batch mode, strict host key checking, no forwarding).
public struct PhonePairingService: Sendable {
  public let settings: PhonePairingSettings
  public let runner: any PhoneLinkCommandRunning
  public let sealKeys: any PhoneSealKeyStore
  public let relayScript: String
  public let remoteTimeout: TimeInterval
  public let localTimeout: TimeInterval

  public init(
    settings: PhonePairingSettings, runner: any PhoneLinkCommandRunning,
    sealKeys: any PhoneSealKeyStore, relayScript: String = PhoneRelayScript.source,
    remoteTimeout: TimeInterval = 60, localTimeout: TimeInterval = 15
  ) {
    self.settings = settings
    self.runner = runner
    self.sealKeys = sealKeys
    self.relayScript = relayScript
    self.remoteTimeout = remoteTimeout
    self.localTimeout = localTimeout
  }

  /// The phone key's ID: `iphone-` + the first 12 hex characters of SHA-256
  /// over the raw public key.
  public static func keyID(for publicKey: Curve25519.Signing.PublicKey) -> String {
    let digest = SHA256.hash(data: publicKey.rawRepresentation)
    return "iphone-" + digest.map { String(format: "%02x", $0) }.joined().prefix(12)
  }

  /// The Mac's name as the phone shows it: no control characters, at most
  /// 64 characters, "Mac" when empty.
  public static func label(_ name: String?) -> String {
    let cleaned = String(
      String.UnicodeScalarView(
        (name ?? "").unicodeScalars.filter { $0.properties.generalCategory != .control })
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "Mac" : String(cleaned.prefix(64))
  }

  /// Makes a new pairing. Nothing is installed anywhere until every check
  /// passed (both host keys found, the code built); a previous pairing is
  /// removed first; if the relay step fails the organizing device's new line
  /// is removed again.
  public func pair(label: String?, replacing previous: PhonePairingState?, now: Date = Date())
    async throws -> PhonePairing
  {
    let spark = try await resolve(settings.spark, hop: .spark)
    var relayDestination: SSHDestination?
    var relay: SSHResolvedHost?
    if let jump = spark.proxyJump {
      guard let spec = try? SSHJumpSpec.parse(jump) else {
        throw PhonePairingError.unsupportedProxy
      }
      let destination = SSHDestination(spec)
      let resolved = try await resolve(destination, hop: .relay)
      guard resolved.proxyJump == nil, resolved.proxyCommand == nil else {
        throw PhonePairingError.unsupportedProxy
      }
      relayDestination = destination
      relay = resolved
    } else if spark.proxyCommand != nil {
      throw PhonePairingError.unsupportedProxy
    }

    let sparkKey = try await hostKey(for: spark, hop: .spark)
    var relayEndpoint: PairingEndpoint?
    if let relay {
      let relayKey = try await hostKey(for: relay, hop: .relay)
      do {
        relayEndpoint = try PairingEndpoint(
          host: relay.hostname, port: relay.port, user: relay.user, hostKey: relayKey)
      } catch { throw PhonePairingError.invalidEndpoint(.relay) }
    }
    let sparkEndpoint: PairingEndpoint
    do {
      sparkEndpoint = try PairingEndpoint(
        host: spark.hostname, port: spark.port, user: spark.user, hostKey: sparkKey)
    } catch { throw PhonePairingError.invalidEndpoint(.spark) }

    let seal: Curve25519.KeyAgreement.PrivateKey
    do { seal = try sealKeys.loadOrCreate() } catch { throw PhonePairingError.sealKeyUnavailable }
    let phoneKey = Curve25519.Signing.PrivateKey()
    let keyID = Self.keyID(for: phoneKey.publicKey)
    let payload = try PairingPayload(
      label: Self.label(label), spark: sparkEndpoint, relay: relayEndpoint,
      phoneKey: phoneKey.rawRepresentation, phoneKeyID: keyID,
      macSealPublicKey: seal.publicKey.rawRepresentation)
    let code = try payload.encodedText()
    let state = PhonePairingState(
      keyID: keyID, label: payload.label, spark: settings.spark,
      inboxCommand: settings.inboxCommand, relay: relayDestination, pairedAt: now)

    if let previous {
      do { try await revoke(previous) } catch PhonePairingError.revokeFailed(let hop) {
        throw PhonePairingError.previousNotRevoked(hop)
      }
    }
    do {
      try await runRemote(
        settings.spark,
        PhoneLinkSSHCommand.authorizePhoneCommand(
          inboxCommand: settings.inboxCommand, keyID: keyID),
        stdin: PhoneLinkSSHCommand.authorizePhoneStdin(
          authorizedKey: payload.phoneAuthorizedKey, keyID: keyID))
    } catch {
      // A timeout may have left the line in place: take it back (idempotent).
      try? await revokeSpark(state)
      throw PhonePairingError.authorizeFailed(.spark)
    }
    if let relayDestination {
      do {
        let publicKey = String(payload.phoneAuthorizedKey.split(separator: " ")[1])
        try await runRemote(
          relayDestination,
          PhoneLinkSSHCommand.relayAuthorizeCommand(
            keyID: keyID, sparkHost: spark.hostname, sparkPort: spark.port,
            publicKeyBase64: publicKey),
          stdin: Data(relayScript.utf8))
      } catch {
        // Do not leave a key the phone will never get on either host (a
        // timeout may have come after the relay's write; both are idempotent).
        try? await runRemote(
          relayDestination, PhoneLinkSSHCommand.relayRevokeCommand(keyID: keyID),
          stdin: Data(relayScript.utf8))
        try? await revokeSpark(state)
        throw PhonePairingError.authorizeFailed(.relay)
      }
    }
    return PhonePairing(state: state, code: code)
  }

  /// "断开 iPhone": removes the phone's key from the organizing device and
  /// from the relay. Both are tried; any failure throws (the caller keeps
  /// the state so the user can try again). Idempotent on both hosts.
  public func revoke(_ state: PhonePairingState) async throws {
    var failed: PhonePairingHop?
    do { try await revokeSpark(state) } catch { failed = .spark }
    if let relay = state.relay {
      do {
        try await runRemote(
          relay, PhoneLinkSSHCommand.relayRevokeCommand(keyID: state.keyID),
          stdin: Data(relayScript.utf8))
      } catch { failed = failed ?? .relay }
    }
    if let failed { throw PhonePairingError.revokeFailed(failed) }
  }

  private func revokeSpark(_ state: PhonePairingState) async throws {
    try await runRemote(
      state.spark,
      PhoneLinkSSHCommand.revokePhoneCommand(
        inboxCommand: state.inboxCommand, keyID: state.keyID),
      stdin: nil)
  }

  private func runRemote(_ destination: SSHDestination, _ command: String, stdin: Data?)
    async throws
  {
    let result = try await runner.run(
      PhoneLinkSSHCommand.sshPath,
      PhoneLinkSSHCommand.remoteArguments(
        destination, command: command, configFile: settings.sshConfigFile),
      stdin: stdin, timeout: remoteTimeout)
    guard result.status == 0 else { throw PhoneLinkCommandError.exited(result.status) }
  }

  func resolve(_ destination: SSHDestination, hop: PhonePairingHop) async throws
    -> SSHResolvedHost
  {
    let result: PhoneLinkCommandResult
    do {
      result = try await runner.run(
        PhoneLinkSSHCommand.sshPath,
        PhoneLinkSSHCommand.resolveArguments(destination, configFile: settings.sshConfigFile),
        stdin: nil, timeout: localTimeout)
    } catch { throw PhonePairingError.sshConfigUnreadable(hop) }
    guard result.status == 0, let host = try? SSHResolvedHost.parse(sshG: result.output) else {
      throw PhonePairingError.sshConfigUnreadable(hop)
    }
    guard PhoneLinkSSHCommand.isSafeHost(host.hostname), PairingEndpoint.isValidUser(host.user),
      (1...65_535).contains(host.port)
    else { throw PhonePairingError.invalidEndpoint(hop) }
    return host
  }

  /// The pinned key: looked up by the name ssh itself checks, in the files
  /// ssh itself checks, ed25519 preferred. RSA-only hosts are refused.
  func hostKey(for host: SSHResolvedHost, hop: PhonePairingHop) async throws -> SSHHostKey {
    var found: [SSHHostKey] = []
    for file in host.knownHostsFiles {
      let path =
        file.hasPrefix("~/")
        ? NSHomeDirectory() + String(file.dropFirst(1)) : file
      guard path.hasPrefix("/"), FileManager.default.isReadableFile(atPath: path),
        let arguments = try? PhoneLinkSSHCommand.knownHostsArguments(
          name: host.knownHostsName, file: path)
      else { continue }
      guard
        let result = try? await runner.run(
          PhoneLinkSSHCommand.keygenPath, arguments, stdin: nil, timeout: localTimeout),
        result.status == 0
      else { continue }
      for key in KnownHostKeys.keys(fromKeygenOutput: result.output) where !found.contains(key) {
        found.append(key)
      }
    }
    guard let key = KnownHostKeys.preferred(found) else {
      throw PhonePairingError.hostKeyMissing(hop)
    }
    return key
  }
}

/// The paired phone as this Mac remembers it, per data root, in the link's
/// state directory (outside every library): `phone-<root identity>.json`,
/// 0600. Also the count of phone entries that could not be taken in.
@MainActor
public final class PhonePairingStateFile {
  private let url: URL
  private let droppedURL: URL

  public init(stateDirectory: URL, dataRoot: URL) {
    let identity = OrganizerDataRootIdentity.hash(of: dataRoot)
    url = stateDirectory.appendingPathComponent("phone-\(identity).json")
    droppedURL = stateDirectory.appendingPathComponent("phone-dropped-\(identity).json")
  }

  public func load() -> PhonePairingState? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try? decoder.decode(PhonePairingState.self, from: data)
  }

  public func save(_ state: PhonePairingState) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    try write(try encoder.encode(state), to: url)
  }

  public func clear() throws {
    guard unlink(url.path) == 0 || errno == ENOENT else { throw CocoaError(.fileWriteUnknown) }
  }

  /// Entries dropped since the user last dismissed the notice, by reason.
  public func droppedCounts() -> [RemoteOrganizerInboxDiscard: Int] {
    guard let data = try? Data(contentsOf: droppedURL),
      let raw = try? JSONDecoder().decode([String: Int].self, from: data)
    else { return [:] }
    var counts: [RemoteOrganizerInboxDiscard: Int] = [:]
    for (key, value) in raw {
      if let reason = RemoteOrganizerInboxDiscard(rawValue: key), value > 0 {
        counts[reason] = value
      }
    }
    return counts
  }

  @discardableResult
  public func recordDropped(_ reason: RemoteOrganizerInboxDiscard) -> [RemoteOrganizerInboxDiscard:
    Int]
  {
    var counts = droppedCounts()
    counts[reason, default: 0] += 1
    let raw = Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) })
    if let data = try? JSONEncoder().encode(raw) { try? write(data, to: droppedURL) }
    return counts
  }

  public func clearDropped() {
    unlink(droppedURL.path)
  }

  private func write(_ data: Data, to target: URL) throws {
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try data.write(to: target, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
  }
}

/// The visible status for phone entries that were dropped
/// (PHONE-CONTRACT §5.4).
public enum PhoneInboxDropNotice {
  public static func text(_ reason: RemoteOrganizerInboxDiscard, count: Int) -> String {
    switch reason {
    case .cannotOpen: "\(count) 条手机内容无法打开（配对已更换）"
    case .unusable: "\(count) 条手机内容无法收进来"
    }
  }
}

/// The pairing code as a QR code (CoreImage `CIQRCodeGenerator`, error
/// correction M), `scale` pixels per module, on white with a four-module
/// quiet zone, so any phone camera reads it from a screen.
public enum PhonePairingQRCode {
  public static func image(for text: String, scale: Int = 8) -> CGImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let code = filter.outputImage, scale > 0 else { return nil }
    let factor = CGFloat(scale)
    let scaled = code.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
    let margin = 4 * factor
    let canvas = scaled.extent.insetBy(dx: -margin, dy: -margin)
    let composed = scaled.composited(over: CIImage(color: .white).cropped(to: canvas))
    let context = CIContext(options: [.useSoftwareRenderer: true])
    return context.createCGImage(composed, from: canvas)
  }
}

extension RemoteOrganizerRuntime {
  /// Sets `onInboxDiscarded` and returns the runtime (for a factory closure).
  @discardableResult
  public func withInboxDiscardHandler(
    _ handler: @escaping (RemoteOrganizerInboxDiscard) -> Void
  ) -> RemoteOrganizerRuntime {
    onInboxDiscarded = handler
    return self
  }
}
