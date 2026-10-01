import BestASRDomain
import BestASRRemoteOrganizer
import CoreImage
import CryptoKit
import Foundation
import MindloomLink
import XCTest

/// PHONE-CONTRACT §4 and §6 (Mac): pairing needs both host keys from the
/// Mac's known_hosts (ed25519/ECDSA only), installs the phone's key on the
/// organizing device and the relay with commands built from checked words
/// only, and the QR code carries a pairing code that MindloomLink decodes
/// back to the same payload. No network: a scripted runner stands in for
/// ssh, and the real `ssh -G` / `ssh-keygen -F` read synthetic files.
final class PhonePairingTests: XCTestCase {
  // MARK: - Synthetic host keys

  private static func ed25519HostKey() -> String {
    PairingPayload.openSSHPublicKey(Curve25519.Signing.PrivateKey().publicKey)
  }

  private static func ecdsaHostKey() -> String {
    let point = P256.Signing.PrivateKey().publicKey.x963Representation
    var blob = Data()
    for part in [Data("ecdsa-sha2-nistp256".utf8), Data("nistp256".utf8), point] {
      var length = UInt32(part.count).bigEndian
      blob.append(Data(bytes: &length, count: 4))
      blob.append(part)
    }
    return "ecdsa-sha2-nistp256 " + blob.base64EncodedString()
  }

  /// A syntactically valid RSA line the phone cannot verify.
  private static let rsaHostKey =
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQDExampleOnlyNotARealKeyxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

  // MARK: - ssh -G, ProxyJump, known_hosts

  func testSSHGOutputIsReadTheWaySSHReadsIt() throws {
    let host = try SSHResolvedHost.parse(
      sshG: """
        host sparkx
        user alice
        hostname 10.20.30.40
        port 22
        hostkeyalias none
        proxycommand none
        proxyjump bob@relay.example.test:2200
        userknownhostsfile /Users/example/.ssh/known_hosts /Users/example/.ssh/known_hosts2
        globalknownhostsfile /etc/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts2
        user ignored-second-value
        """)
    XCTAssertEqual(host.hostname, "10.20.30.40")
    XCTAssertEqual(host.user, "alice")
    XCTAssertEqual(host.port, 22)
    XCTAssertEqual(host.proxyJump, "bob@relay.example.test:2200")
    XCTAssertNil(host.proxyCommand)
    XCTAssertNil(host.hostKeyAlias)
    XCTAssertEqual(
      host.knownHostsFiles,
      [
        "/Users/example/.ssh/known_hosts", "/Users/example/.ssh/known_hosts2",
        "/etc/ssh/ssh_known_hosts", "/etc/ssh/ssh_known_hosts2",
      ])
    XCTAssertEqual(host.knownHostsName, "10.20.30.40")
    XCTAssertEqual(
      SSHResolvedHost(hostname: "spark.example.test", port: 2222, user: "a").knownHostsName,
      "[spark.example.test]:2222")
    XCTAssertEqual(
      SSHResolvedHost(hostname: "h", port: 2222, user: "a", hostKeyAlias: "sparky").knownHostsName,
      "sparky")
    XCTAssertThrowsError(try SSHResolvedHost.parse(sshG: "user a\nport 22\n"))
  }

  func testProxyJumpSpecs() throws {
    XCTAssertEqual(try SSHJumpSpec.parse("relay-box"), try SSHJumpSpec(host: "relay-box"))
    XCTAssertEqual(
      try SSHJumpSpec.parse("bob@Relay.Example.test:2200"),
      try SSHJumpSpec(host: "relay.example.test", user: "bob", port: 2200))
    XCTAssertEqual(
      try SSHJumpSpec.parse("ssh://bob@relay.example.test"),
      try SSHJumpSpec(host: "relay.example.test", user: "bob"))
    XCTAssertEqual(
      try SSHJumpSpec.parse("[fd00::1]:22"), try SSHJumpSpec(host: "fd00::1", port: 22))
    XCTAssertThrowsError(try SSHJumpSpec.parse("a,b")) {
      XCTAssertEqual($0 as? SSHJumpSpec.ParseError, .multipleHops)
    }
    for bad in ["-oProxyCommand=x", "bob@-x", "a b", "x;y", "h:99999", "h:port", "$(id)"] {
      XCTAssertThrowsError(try SSHJumpSpec.parse(bad), bad)
    }
  }

  func testKnownHostsPinEd25519ThenECDSAAndRefuseRSAOnly() throws {
    let ed = Self.ed25519HostKey()
    let ec = Self.ecdsaHostKey()
    let revoked = Self.ed25519HostKey()
    let output = """
      # Host 10.20.30.40 found: line 3
      10.20.30.40 \(Self.rsaHostKey)
      # Host 10.20.30.40 found: line 4
      10.20.30.40 \(ec)
      |1|hashedsalt=|hashedhost= \(ed) comment here
      @cert-authority *.example.test \(Self.ed25519HostKey())
      @revoked * \(revoked)
      10.20.30.40 \(revoked)
      """
    let keys = KnownHostKeys.keys(fromKeygenOutput: output)
    XCTAssertEqual(keys.map(\.openSSH), [ec, ed], "RSA, CA and revoked keys are never pinned")
    XCTAssertEqual(KnownHostKeys.preferred(keys)?.openSSH, ed)
    XCTAssertEqual(
      KnownHostKeys.preferred(KnownHostKeys.keys(fromKeygenOutput: "h \(ec)"))?.openSSH, ec)
    XCTAssertNil(
      KnownHostKeys.preferred(KnownHostKeys.keys(fromKeygenOutput: "h \(Self.rsaHostKey)")))
  }

  // MARK: - Command construction (no shell injection)

  func testCommandsAreBuiltFromCheckedWordsOnly() throws {
    let key = Curve25519.Signing.PrivateKey()
    let id = PhonePairingService.keyID(for: key.publicKey)
    XCTAssertTrue(id.hasPrefix("iphone-"))
    XCTAssertEqual(id.count, 19)
    XCTAssertTrue(PairingPayload.isValidKeyID(id))
    let line = PairingPayload.openSSHPublicKey(key.publicKey, comment: "mindloom-phone:\(id)")
    let base64 = String(line.split(separator: " ")[1])
    let inbox = PhoneLinkSSHCommand.defaultInboxCommand

    XCTAssertEqual(
      try PhoneLinkSSHCommand.authorizePhoneCommand(inboxCommand: inbox, keyID: id),
      "~/hack/organizer/spark/zhiji-inbox authorize-phone --key-id \(id) --pubkey -")
    XCTAssertEqual(
      try PhoneLinkSSHCommand.authorizePhoneStdin(authorizedKey: line, keyID: id),
      Data((line + "\n").utf8), "the key goes on stdin, not in the command")
    XCTAssertEqual(
      try PhoneLinkSSHCommand.revokePhoneCommand(inboxCommand: inbox, keyID: id),
      "~/hack/organizer/spark/zhiji-inbox revoke-phone --key-id \(id)")
    XCTAssertEqual(
      try PhoneLinkSSHCommand.relayAuthorizeCommand(
        keyID: id, sparkHost: "10.20.30.40", sparkPort: 22, publicKeyBase64: base64),
      "sh -s -- add \(id) 10.20.30.40 22 ssh-ed25519 \(base64)")
    XCTAssertEqual(
      try PhoneLinkSSHCommand.relayRevokeCommand(keyID: id), "sh -s -- remove \(id)")

    let destination = try SSHDestination(host: "sparkx")
    XCTAssertEqual(
      PhoneLinkSSHCommand.remoteArguments(destination, command: "true"),
      [
        "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ControlMaster=no",
        "-o", "ControlPath=none", "-o", "ControlPersist=no", "-o", "ForwardAgent=no", "-o",
        "ForwardX11=no", "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=20", "--",
        "sparkx", "true",
      ])
    XCTAssertEqual(
      PhoneLinkSSHCommand.remoteArguments(
        try SSHDestination(host: "relay.example.test", user: "bob", port: 2200), command: "true"
      ).suffix(7),
      ["-l", "bob", "-p", "2200", "--", "relay.example.test", "true"])
    XCTAssertEqual(
      PhoneLinkSSHCommand.resolveArguments(destination), ["-G", "--", "sparkx"])
    XCTAssertEqual(
      try PhoneLinkSSHCommand.knownHostsArguments(
        name: "[spark.example.test]:2222", file: "/tmp/kh"),
      ["-F", "[spark.example.test]:2222", "-f", "/tmp/kh"])

    // Anything that could become shell syntax or an ssh option is refused.
    let hostile = [
      "a;rm -rf ~", "$(id)", "`id`", "a b", "-oProxyCommand=x", "a|b", "a&b", "a'b", "a\"b",
      "a\nb", "a>b", "../x", "",
    ]
    for word in hostile {
      XCTAssertThrowsError(
        try PhoneLinkSSHCommand.authorizePhoneCommand(inboxCommand: inbox, keyID: word), word)
      XCTAssertThrowsError(
        try PhoneLinkSSHCommand.revokePhoneCommand(inboxCommand: inbox, keyID: word), word)
      XCTAssertThrowsError(try PhoneLinkSSHCommand.relayRevokeCommand(keyID: word), word)
      if !word.isEmpty {
        XCTAssertThrowsError(
          try PhoneLinkSSHCommand.authorizePhoneCommand(inboxCommand: "~/bin/\(word)", keyID: id),
          word)
      }
      XCTAssertThrowsError(
        try PhoneLinkSSHCommand.relayAuthorizeCommand(
          keyID: id, sparkHost: word, sparkPort: 22, publicKeyBase64: base64), word)
      XCTAssertThrowsError(
        try PhoneLinkSSHCommand.relayAuthorizeCommand(
          keyID: id, sparkHost: "h", sparkPort: 22, publicKeyBase64: word), word)
      XCTAssertThrowsError(try SSHDestination(host: word), word)
      XCTAssertThrowsError(try PhonePairingSettings(sparkHost: word), word)
    }
    XCTAssertThrowsError(try SSHDestination(host: "h", user: "-oops"))
    XCTAssertThrowsError(try SSHDestination(host: "h", port: 0))
    XCTAssertThrowsError(
      try PhoneLinkSSHCommand.relayAuthorizeCommand(
        keyID: id, sparkHost: "h", sparkPort: 70_000, publicKeyBase64: base64))
    XCTAssertThrowsError(
      try PhonePairingSettings(sparkHost: "sparkx", inboxCommand: "zhiji-inbox; id"))
    // Only exactly this phone's public key line may go on stdin.
    for bad in [
      line + "\nssh-ed25519 AAAA other", "ssh-rsa \(base64) mindloom-phone:\(id)",
      "ssh-ed25519 \(base64) mindloom-phone:other",
      "ssh-ed25519 \(base64)'; id; ' mindloom-phone:\(id)",
    ] {
      XCTAssertThrowsError(
        try PhoneLinkSSHCommand.authorizePhoneStdin(authorizedKey: bad, keyID: id))
    }
    XCTAssertThrowsError(
      try PhoneLinkSSHCommand.knownHostsArguments(name: "-oProxyCommand=x", file: "/tmp/kh"))
    XCTAssertThrowsError(try PhoneLinkSSHCommand.knownHostsArguments(name: "h", file: "relative"))
  }

  // MARK: - Pairing flow against a scripted ssh

  private struct Fixture {
    let runner: ScriptedRunner
    let sealKeys: MemoryPhoneSealKeyStore
    let sparkKey: String
    let relayKey: String
    let service: PhonePairingService
  }

  private func fixture(
    sparkKnown: [String]? = nil, relayKnown: [String]? = nil, proxyJump: String? = "relay-box",
    proxyCommand: String? = nil, failing: [String] = []
  ) throws -> Fixture {
    let sparkKey = Self.ed25519HostKey()
    let relayKey = Self.ecdsaHostKey()
    let knownHosts = try makeTemporaryDirectory().appendingPathComponent("known_hosts")
    try Data().write(to: knownHosts)
    let runner = ScriptedRunner()
    runner.respond(
      executable: PhoneLinkSSHCommand.sshPath, arguments: ["-G", "--", "sparkx"],
      output: """
        host sparkx
        user alice
        hostname 10.20.30.40
        port 22
        \(proxyJump.map { "proxyjump \($0)" } ?? "")
        \(proxyCommand.map { "proxycommand \($0)" } ?? "")
        userknownhostsfile \(knownHosts.path)
        """)
    runner.respond(
      executable: PhoneLinkSSHCommand.sshPath, arguments: ["-G", "--", "relay-box"],
      output: """
        host relay-box
        user bob
        hostname relay.example.test
        port 2200
        userknownhostsfile \(knownHosts.path)
        """)
    runner.respond(
      executable: PhoneLinkSSHCommand.keygenPath,
      arguments: ["-F", "10.20.30.40", "-f", knownHosts.path],
      output: (sparkKnown ?? [Self.rsaHostKey, sparkKey]).map { "10.20.30.40 \($0)" }
        .joined(separator: "\n"))
    runner.respond(
      executable: PhoneLinkSSHCommand.keygenPath,
      arguments: ["-F", "[relay.example.test]:2200", "-f", knownHosts.path],
      output: (relayKnown ?? [relayKey]).map { "[relay.example.test]:2200 \($0)" }
        .joined(separator: "\n"))
    runner.failRemote = failing
    let sealKeys = MemoryPhoneSealKeyStore()
    let service = PhonePairingService(
      settings: try PhonePairingSettings(sparkHost: "sparkx"), runner: runner, sealKeys: sealKeys)
    return Fixture(
      runner: runner, sealKeys: sealKeys, sparkKey: sparkKey, relayKey: relayKey, service: service)
  }

  func testPairingInstallsThePhoneKeyOnBothHostsAndTheCodeRoundTrips() async throws {
    let setup = try fixture()
    let pairedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let pairing = try await setup.service.pair(
      label: "虚构的 Mac\u{7}", replacing: nil, now: pairedAt)

    let payload = try PairingPayload.decode(text: pairing.code)
    XCTAssertEqual(payload.label, "虚构的 Mac")
    XCTAssertEqual(payload.spark.host, "10.20.30.40")
    XCTAssertEqual(payload.spark.user, "alice")
    XCTAssertEqual(payload.spark.port, 22)
    XCTAssertEqual(payload.spark.hostKey.openSSH, setup.sparkKey, "the ed25519 line, not RSA")
    XCTAssertEqual(payload.relay?.host, "relay.example.test")
    XCTAssertEqual(payload.relay?.port, 2200)
    XCTAssertEqual(payload.relay?.user, "bob")
    XCTAssertEqual(payload.relay?.hostKey.openSSH, setup.relayKey)
    XCTAssertEqual(payload.gate, "zhiji-inbox")
    XCTAssertEqual(payload.phoneKeyID, pairing.state.keyID)
    XCTAssertEqual(
      payload.macSealPublicKey, try XCTUnwrap(setup.sealKeys.stored).publicKey.rawRepresentation,
      "the phone seals to this library's seal key")
    XCTAssertEqual(
      PhonePairingService.keyID(for: payload.phoneSigningKey.publicKey), payload.phoneKeyID)

    XCTAssertEqual(pairing.state.keyID, payload.phoneKeyID)
    XCTAssertEqual(pairing.state.spark, try SSHDestination(host: "sparkx"))
    XCTAssertEqual(pairing.state.relay, try SSHDestination(host: "relay-box"))
    XCTAssertEqual(pairing.state.pairedAt, pairedAt)
    XCTAssertFalse(pairing.description.contains(pairing.code))

    // Exactly two installs, in order, over the Mac's own ssh.
    let remote = setup.runner.remoteCalls
    XCTAssertEqual(remote.map(\.destination), ["sparkx", "relay-box"])
    XCTAssertEqual(
      remote[0].command,
      "~/hack/organizer/spark/zhiji-inbox authorize-phone --key-id \(payload.phoneKeyID) --pubkey -"
    )
    XCTAssertEqual(remote[0].stdin, Data((payload.phoneAuthorizedKey + "\n").utf8))
    let publicBase64 = String(payload.phoneAuthorizedKey.split(separator: " ")[1])
    XCTAssertEqual(
      remote[1].command,
      "sh -s -- add \(payload.phoneKeyID) 10.20.30.40 22 ssh-ed25519 \(publicBase64)")
    XCTAssertEqual(remote[1].stdin, Data(PhoneRelayScript.source.utf8))
    XCTAssertEqual(remote[1].arguments.suffix(3), ["--", "relay-box", remote[1].command])

    // The phone's private key never reaches any command, argument or stdin.
    let secret = [payload.phoneKey.base64EncodedString(), pairing.code]
    for call in setup.runner.calls {
      for value in secret {
        XCTAssertFalse(call.arguments.joined(separator: " ").contains(value))
        XCTAssertFalse(String(decoding: call.stdin ?? Data(), as: UTF8.self).contains(value))
      }
    }

    // "断开 iPhone": both hosts, same key ID.
    try await setup.service.revoke(pairing.state)
    let revokes = setup.runner.remoteCalls.suffix(2)
    XCTAssertEqual(
      revokes.map(\.command),
      [
        "~/hack/organizer/spark/zhiji-inbox revoke-phone --key-id \(payload.phoneKeyID)",
        "sh -s -- remove \(payload.phoneKeyID)",
      ])
    XCTAssertEqual(revokes.last?.stdin, Data(PhoneRelayScript.source.utf8))
  }

  func testPairingNeedsBothHostKeysAndInstallsNothingWithoutThem() async throws {
    let cases: [(PhonePairingError, Fixture)] = [
      (.hostKeyMissing(.spark), try fixture(sparkKnown: [])),
      (.hostKeyMissing(.spark), try fixture(sparkKnown: [Self.rsaHostKey])),
      (.hostKeyMissing(.relay), try fixture(relayKnown: [])),
      (.hostKeyMissing(.relay), try fixture(relayKnown: [Self.rsaHostKey])),
      (.unsupportedProxy, try fixture(proxyJump: "a,b")),
      (.unsupportedProxy, try fixture(proxyJump: nil, proxyCommand: "nc %h %p")),
    ]
    for (expected, setup) in cases {
      do {
        _ = try await setup.service.pair(label: "Mac", replacing: nil)
        XCTFail("paired despite \(expected)")
      } catch {
        XCTAssertEqual(error as? PhonePairingError, expected)
      }
      XCTAssertEqual(setup.runner.remoteCalls.count, 0, "\(expected): nothing installed")
      XCTAssertNil(setup.sealKeys.stored, "\(expected): no seal key made either")
    }

    // Without a relay only the organizing device's key is needed.
    let direct = try fixture(proxyJump: nil)
    let pairing = try await direct.service.pair(label: nil, replacing: nil)
    let payload = try PairingPayload.decode(text: pairing.code)
    XCTAssertNil(payload.relay)
    XCTAssertEqual(payload.label, "Mac")
    XCTAssertEqual(direct.runner.remoteCalls.map(\.destination), ["sparkx"])
    XCTAssertNil(pairing.state.relay)
  }

  func testAFailedRelayInstallTakesBothLinesBackAndAFailedRevokeIsReported() async throws {
    let setup = try fixture(failing: ["sh -s -- add"])
    do {
      _ = try await setup.service.pair(label: "Mac", replacing: nil)
      XCTFail("paired without the relay")
    } catch {
      XCTAssertEqual(error as? PhonePairingError, .authorizeFailed(.relay))
    }
    let commands = setup.runner.remoteCalls.map(\.command)
    XCTAssertEqual(commands.count, 4)
    XCTAssertTrue(commands[0].contains("authorize-phone"))
    XCTAssertTrue(commands[1].hasPrefix("sh -s -- add "))
    XCTAssertTrue(commands[2].hasPrefix("sh -s -- remove "))
    XCTAssertTrue(commands[3].contains("revoke-phone"))

    // Re-pairing removes the previous phone first; if that fails, the new
    // key is not installed.
    let good = try fixture()
    let first = try await good.service.pair(label: "Mac", replacing: nil)
    good.runner.failRemote = ["revoke-phone"]
    let before = good.runner.remoteCalls.count
    do {
      _ = try await good.service.pair(label: "Mac", replacing: first.state)
      XCTFail("replaced a phone that could not be disconnected")
    } catch {
      XCTAssertEqual(error as? PhonePairingError, .previousNotRevoked(.spark))
    }
    let after = good.runner.remoteCalls.dropFirst(before).map(\.command)
    XCTAssertFalse(after.contains { $0.contains("authorize-phone") })
    XCTAssertTrue(
      after.contains("sh -s -- remove \(first.state.keyID)"), "the relay is still tried")
    do {
      try await good.service.revoke(first.state)
      XCTFail("a failed revoke must be reported")
    } catch {
      XCTAssertEqual(error as? PhonePairingError, .revokeFailed(.spark))
    }
    good.runner.failRemote = []
    let second = try await good.service.pair(label: "Mac", replacing: first.state)
    XCTAssertNotEqual(second.state.keyID, first.state.keyID)
    XCTAssertEqual(
      good.runner.remoteCalls.suffix(4).map(\.command).first,
      "~/hack/organizer/spark/zhiji-inbox revoke-phone --key-id \(first.state.keyID)")
  }

  // MARK: - QR code

  func testQRCodeCarriesThePairingCodeBackToMindloomLink() async throws {
    let setup = try fixture()
    let pairing = try await setup.service.pair(
      label: String(repeating: "长", count: 64), replacing: nil)
    let image = try XCTUnwrap(PhonePairingQRCode.image(for: pairing.code, scale: 6))
    XCTAssertEqual(image.width, image.height)
    let detector = try XCTUnwrap(
      CIDetector(
        ofType: CIDetectorTypeQRCode, context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
    let read = detector.features(in: CIImage(cgImage: image))
      .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    XCTAssertEqual(read, [pairing.code])
    let scanned = try PairingPayload.decode(text: try XCTUnwrap(read.first))
    XCTAssertEqual(scanned, try PairingPayload.decode(text: pairing.code))
    // What the phone will log in with is exactly what was installed.
    XCTAssertEqual(
      setup.runner.remoteCalls.first?.stdin, Data((scanned.phoneAuthorizedKey + "\n").utf8))
  }

  // MARK: - The real ssh -G and ssh-keygen -F, on synthetic files

  func testRealSSHConfigAndKnownHostsResolveWithoutAnyConnection() async throws {
    let directory = try makeTemporaryDirectory()
    let knownHosts = directory.appendingPathComponent("known_hosts")
    let sparkKey = Self.ed25519HostKey()
    let relayKey = Self.ed25519HostKey()
    try """
    [spark.example.test]:2222 \(Self.rsaHostKey)
    [spark.example.test]:2222 \(sparkKey)
    [relay.example.test]:2200 \(relayKey)
    other.example.test \(Self.ed25519HostKey())

    """.write(to: knownHosts, atomically: true, encoding: .utf8)
    let config = directory.appendingPathComponent("ssh_config")
    try """
    Host sparkx
      HostName Spark.Example.test
      User alice
      Port 2222
      ProxyJump bob@relay.example.test:2200
      UserKnownHostsFile \(knownHosts.path)
      GlobalKnownHostsFile /dev/null
    Host relay.example.test
      UserKnownHostsFile \(knownHosts.path)
      GlobalKnownHostsFile /dev/null

    """.write(to: config, atomically: true, encoding: .utf8)

    let real = ProcessPhoneLinkCommandRunner()
    let resolved = try await real.run(
      PhoneLinkSSHCommand.sshPath,
      PhoneLinkSSHCommand.resolveArguments(
        try SSHDestination(host: "sparkx"), configFile: config.path),
      stdin: nil, timeout: 15)
    XCTAssertEqual(resolved.status, 0)
    let spark = try SSHResolvedHost.parse(sshG: resolved.output)
    XCTAssertEqual(spark.hostname, "spark.example.test")
    XCTAssertEqual(spark.port, 2222)
    XCTAssertEqual(spark.user, "alice")
    XCTAssertEqual(spark.proxyJump, "bob@relay.example.test:2200")
    XCTAssertEqual(spark.knownHostsFiles.first, knownHosts.path)

    // The whole pairing with the real resolver and key lookup; only the two
    // remote installs are scripted.
    let runner = ScriptedRunner(passThroughLocal: true)
    let sealKeys = MemoryPhoneSealKeyStore()
    let service = PhonePairingService(
      settings: try PhonePairingSettings(sparkHost: "sparkx", sshConfigFile: config.path),
      runner: runner, sealKeys: sealKeys)
    let pairing = try await service.pair(label: "Mac", replacing: nil)
    let payload = try PairingPayload.decode(text: pairing.code)
    XCTAssertEqual(payload.spark.host, "spark.example.test")
    XCTAssertEqual(payload.spark.port, 2222)
    XCTAssertEqual(payload.spark.hostKey.openSSH, sparkKey)
    XCTAssertEqual(payload.relay?.host, "relay.example.test")
    XCTAssertEqual(payload.relay?.user, "bob")
    XCTAssertEqual(payload.relay?.port, 2200)
    XCTAssertEqual(payload.relay?.hostKey.openSSH, relayKey)
    XCTAssertEqual(
      pairing.state.relay, try SSHDestination(host: "relay.example.test", user: "bob", port: 2200))
    let remote = runner.remoteCalls
    XCTAssertEqual(remote.map(\.destination), ["sparkx", "relay.example.test"])
    XCTAssertEqual(remote[1].arguments.prefix(1), ["-T"])
    XCTAssertTrue(remote[1].arguments.contains("-F"), "tests read only the synthetic config")
    XCTAssertTrue(
      remote[1].command.hasPrefix("sh -s -- add \(payload.phoneKeyID) spark.example.test 2222 "),
      "the relay permits exactly the host string the phone will ask for")

    // A host whose key is not in known_hosts is refused, never learned.
    try """
    Host unknownx
      HostName nowhere.example.test
      User alice
      UserKnownHostsFile \(knownHosts.path)
      GlobalKnownHostsFile /dev/null

    """.write(to: config, atomically: true, encoding: .utf8)
    let unknown = PhonePairingService(
      settings: try PhonePairingSettings(sparkHost: "unknownx", sshConfigFile: config.path),
      runner: ScriptedRunner(passThroughLocal: true), sealKeys: MemoryPhoneSealKeyStore())
    do {
      _ = try await unknown.pair(label: "Mac", replacing: nil)
      XCTFail("paired with an unknown host")
    } catch {
      XCTAssertEqual(error as? PhonePairingError, .hostKeyMissing(.spark))
    }
  }

  func testTheRunnerFeedsStdinCapsOutputAndTimesOut() async throws {
    let runner = ProcessPhoneLinkCommandRunner()
    let echoed = try await runner.run("/bin/cat", [], stdin: Data("虚构 stdin\n".utf8), timeout: 10)
    XCTAssertEqual(echoed.status, 0)
    XCTAssertEqual(echoed.output, "虚构 stdin\n")
    let big = try await runner.run(
      "/bin/sh", ["-c", "head -c 300000 /dev/zero; echo err >&2; exit 3"], stdin: nil,
      timeout: 10)
    XCTAssertEqual(big.status, 3)
    XCTAssertEqual(big.stdout.count, ProcessPhoneLinkCommandRunner.outputLimit)
    XCTAssertEqual(String(decoding: big.stderr, as: UTF8.self), "err\n")
    // A child that stops reading stdin early does not kill this process.
    let closed = try await runner.run(
      "/bin/sh", ["-c", "exec 0<&-; exit 0"], stdin: Data(count: 1_000_000), timeout: 10)
    XCTAssertEqual(closed.status, 0)
    let started = Date()
    do {
      _ = try await runner.run("/bin/sleep", ["30"], stdin: nil, timeout: 0.5)
      XCTFail("no timeout")
    } catch {
      XCTAssertEqual(error as? PhoneLinkCommandError, .timedOut)
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
  }

  // MARK: - The relay helper, run here on a synthetic home

  func testTheRelayHelperIsThePinnedSparkCopyAndWorksWithTheMacsCommands() throws {
    XCTAssertEqual(PhoneRelayScript.sha256, PhoneRelayScript.sourceSHA256)
    let home = try makeTemporaryDirectory()
    let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
    try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
    let file = ssh.appendingPathComponent("authorized_keys")
    let other =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherLineKeptExactlyAsItWasxxxxxxxxxxxxxx me@laptop"
    try (other + "\n# a comment mindloom-phone:x\n").write(
      to: file, atomically: true, encoding: .utf8)

    let key = Curve25519.Signing.PrivateKey()
    let id = PhonePairingService.keyID(for: key.publicKey)
    let base64 = String(PairingPayload.openSSHPublicKey(key.publicKey).split(separator: " ")[1])
    // What the relay's sshd does with the Mac's command: `sh -c "<command>"`
    // with the script on stdin.
    func run(_ command: String) throws -> Int32 {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", command]
      process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
      let input = Pipe()
      process.standardInput = input
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      input.fileHandleForWriting.write(Data(PhoneRelayScript.source.utf8))
      try input.fileHandleForWriting.close()
      process.waitUntilExit()
      return process.terminationStatus
    }
    let add = try PhoneLinkSSHCommand.relayAuthorizeCommand(
      keyID: id, sparkHost: "spark.example.test", sparkPort: 2222, publicKeyBase64: base64)
    XCTAssertEqual(try run(add), 0)
    XCTAssertEqual(try run(add), 0, "idempotent")
    let expectedLine =
      #"restrict,port-forwarding,permitopen="spark.example.test:2222",permitlisten="127.0.0.1:1",command="false" ssh-ed25519 "#
      + base64 + " mindloom-phone:\(id)"
    XCTAssertEqual(
      try String(contentsOf: file, encoding: .utf8),
      other + "\n# a comment mindloom-phone:x\n" + expectedLine + "\n")
    XCTAssertEqual(try run(try PhoneLinkSSHCommand.relayRevokeCommand(keyID: id)), 0)
    XCTAssertEqual(
      try String(contentsOf: file, encoding: .utf8), other + "\n# a comment mindloom-phone:x\n",
      "every other line kept byte for byte")
    XCTAssertEqual(try run(try PhoneLinkSSHCommand.relayRevokeCommand(keyID: id)), 0)
  }

  // MARK: - Keys and state on the Mac

  func testSealKeyFileStoreIsForSyntheticRootsOnlyAndStaysPrivate() throws {
    let real = try makeTemporaryDirectory()
    let plain = try makeTemporaryDirectory()
    XCTAssertThrowsError(try FilePhoneSealKeyStore(dataRoot: plain, realLibraryRoot: real))
    XCTAssertThrowsError(try FilePhoneSealKeyStore(dataRoot: real, realLibraryRoot: real))
    let root = try makeTemporaryDirectory()
    FileManager.default.createFile(
      atPath: root.appendingPathComponent(RemoteOrganizerDataProvenance.syntheticMarkerFileName)
        .path, contents: Data())
    let store = try FilePhoneSealKeyStore(dataRoot: root, realLibraryRoot: real)
    XCTAssertNil(try store.load())
    let key = try store.loadOrCreate()
    XCTAssertEqual(try store.loadOrCreate().rawRepresentation, key.rawRepresentation, "kept")
    let path = root.appendingPathComponent(FilePhoneSealKeyStore.fileName).path
    let mode = try XCTUnwrap(
      try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    XCTAssertEqual(mode & 0o777, 0o600)
    try store.delete()
    XCTAssertNil(try store.load())
    try store.delete()
  }

  @MainActor
  func testPairingStateIsRememberedPerLibraryWithoutSecrets() throws {
    let state = try makeTemporaryDirectory()
    let root = try makeTemporaryDirectory()
    let file = PhonePairingStateFile(stateDirectory: state, dataRoot: root)
    XCTAssertNil(file.load())
    let paired = PhonePairingState(
      keyID: "iphone-0123456789ab", label: "虚构 Mac", spark: try SSHDestination(host: "sparkx"),
      inboxCommand: PhoneLinkSSHCommand.defaultInboxCommand,
      relay: try SSHDestination(host: "relay.example.test", user: "bob", port: 2200),
      pairedAt: Date(timeIntervalSince1970: 1_790_000_000))
    try file.save(paired)
    XCTAssertEqual(PhonePairingStateFile(stateDirectory: state, dataRoot: root).load(), paired)
    XCTAssertNil(
      PhonePairingStateFile(stateDirectory: state, dataRoot: try makeTemporaryDirectory()).load(),
      "per data root")
    let saved = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(atPath: state.path).first { $0.hasPrefix("phone-") })
    let attributes = try FileManager.default.attributesOfItem(
      atPath: state.appendingPathComponent(saved).path)
    XCTAssertEqual((attributes[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
    try file.clear()
    XCTAssertNil(file.load())
    try file.clear()
  }
}

/// A stand-in for ssh: answers `ssh -G` and `ssh-keygen -F` from a table
/// (or runs the real ones), records every call, and answers remote commands
/// with success unless one of `failRemote` is part of the command.
final class ScriptedRunner: PhoneLinkCommandRunning, @unchecked Sendable {
  struct Call {
    let executable: String
    let arguments: [String]
    let stdin: Data?

    /// For a remote call: the ssh destination and the remote command.
    var destination: String { arguments[arguments.count - 2] }
    var command: String { arguments[arguments.count - 1] }
  }

  private let lock = NSLock()
  private var responses: [[String]: String] = [:]
  private var _calls: [Call] = []
  private var _failRemote: [String] = []
  private let passThroughLocal: Bool

  init(passThroughLocal: Bool = false) {
    self.passThroughLocal = passThroughLocal
  }

  var calls: [Call] { lock.withLock { _calls } }
  var remoteCalls: [Call] { calls.filter { $0.arguments.first == "-T" } }
  var failRemote: [String] {
    get { lock.withLock { _failRemote } }
    set { lock.withLock { _failRemote = newValue } }
  }

  func respond(executable: String, arguments: [String], output: String) {
    lock.withLock { responses[[executable] + arguments] = output }
  }

  func run(_ executable: String, _ arguments: [String], stdin: Data?, timeout: TimeInterval)
    async throws -> PhoneLinkCommandResult
  {
    lock.withLock {
      _calls.append(Call(executable: executable, arguments: arguments, stdin: stdin))
    }
    if arguments.first == "-T" {
      let command = arguments.last ?? ""
      let fails = failRemote.contains { command.contains($0) }
      return PhoneLinkCommandResult(
        status: fails ? 1 : 0, stdout: Data(#"{"ok":true}"#.utf8))
    }
    if passThroughLocal {
      return try await ProcessPhoneLinkCommandRunner().run(
        executable, arguments, stdin: stdin, timeout: timeout)
    }
    guard let output = lock.withLock({ responses[[executable] + arguments] }) else {
      return PhoneLinkCommandResult(status: 1)
    }
    return PhoneLinkCommandResult(status: 0, stdout: Data(output.utf8))
  }
}
