import CryptoKit
import Darwin
import Foundation
import MindloomAgentProtocol
import Security

/// Who is asking (AGENT-CONTRACT §2): the MCP `clientInfo` name the agent
/// sends, plus what the App reads from the kernel about the process that
/// started the helper (the helper's parent), never from anything the agent
/// says: its executable, its code-signing identity, and for an interpreter
/// (node, bun, deno, python) the script it runs.
///
/// Review finding V7-A3: a name and a path alone are not an identity — any
/// process of the same user can send "claude-code" from the same place. So
/// version folders are folded (`…/versions/*`, an agent that updates itself
/// stays the same client) only when the parent is signed by a developer team
/// or by Apple, whose signature an impostor cannot make; the team and
/// signing identifier are part of the identity. An unsigned or ad hoc signed
/// parent is identified by its exact path (and script), so a binary dropped
/// next to the real one is a new client the owner is asked about.
public struct AgentClientIdentity: Equatable, Hashable, Sendable {
  public let name: String
  public let title: String?
  public let path: String
  /// `team:<team id>:<signing id>`, `apple:<signing id>`, or nil (unsigned,
  /// ad hoc, or a signature that does not check out).
  public let signer: String?
  /// The script an interpreter parent runs, when there is one.
  public let script: String?
  /// Who signed it, as its certificate names the developer (「Anthropic PBC」),
  /// for the owner's eyes only: never part of the key.
  public let signerName: String?
  /// The executable exactly as the kernel reported it (version folders not
  /// folded), for the owner's eyes only: never part of the key.
  public let executable: String

  public init(
    name: String, title: String? = nil, path: String, signer: String? = nil,
    script: String? = nil, signerName: String? = nil
  ) {
    self.name = Self.clean(name, limit: 80).isEmpty ? "unknown" : Self.clean(name, limit: 80)
    let cleanedTitle = title.map { Self.clean($0, limit: 80) }
    self.title = (cleanedTitle?.isEmpty ?? true) ? nil : cleanedTitle
    let signed = signer.map { Self.clean($0, limit: 200) }.flatMap { $0.isEmpty ? nil : $0 }
    self.signer = signed
    self.path = signed == nil ? Self.exactPath(path) : Self.stablePath(path)
    self.script = script.map { Self.clean($0, limit: 1_024) }.flatMap { $0.isEmpty ? nil : $0 }
    self.signerName = signerName.map { Self.clean($0, limit: 120) }.flatMap {
      $0.isEmpty ? nil : $0
    }
    self.executable = Self.exactPath(path)
  }

  /// Stable per client: `SHA-256("mindloom-agent-client-v2\n" + name + "\n"
  /// + path + "\n" + signer + "\n" + script)`, first 32 hex characters.
  public var key: String {
    let text = "mindloom-agent-client-v2\n\(name)\n\(path)\n\(signer ?? "-")\n\(script ?? "-")"
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  /// How the owner sees who signed the program, in plain words:
  /// 「Anthropic PBC 签名的程序」, 「Apple 签名的程序」, 「没有开发者签名的程序」.
  public var signerLabel: String {
    guard let signer else { return "没有开发者签名的程序" }
    let parts = signer.split(separator: ":", maxSplits: 2).map(String.init)
    if parts.first == "apple" { return "Apple 签名的程序" }
    if let signerName { return "\(signerName) 签名的程序" }
    if parts.count == 3 { return "开发者（团队 \(parts[1])）签名的程序" }
    return "有开发者签名的程序"
  }

  /// Where the program is, with the home folder written 「~」.
  public var shownPath: String {
    let home = NSHomeDirectory()
    var path = script.map { executable + " " + $0 } ?? executable
    if path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
    return path
  }

  /// One line for the consent card and Settings: who signed it and where it
  /// is (「Anthropic PBC 签名的程序 · ~/.local/share/claude/versions/2.1.3/claude」).
  public var whoLine: String { signerLabel + " · " + shownPath }

  /// How the owner sees it: well-known clients by their product name.
  public var displayName: String {
    if let known = Self.knownNames[name.lowercased()] { return known }
    return title ?? name
  }

  public static let knownNames: [String: String] = [
    "claude-code": "Claude Code",
    "claude-ai": "Claude Desktop",
    "claude-desktop": "Claude Desktop",
    "codex-mcp-client": "Codex",
    "codex": "Codex",
    "cursor-vscode": "Cursor",
    "cursor": "Cursor",
  ]

  /// The path as it is (control characters dropped), for an unsigned parent.
  public static func exactPath(_ raw: String) -> String {
    let trimmed = clean(raw, limit: 1_024)
    return trimmed.isEmpty ? "unknown" : trimmed
  }

  /// Version-looking path components (`2.1.260`, `v20.11.1`, `22.1.0_1`)
  /// become `*` (only for a signed parent).
  public static func stablePath(_ raw: String) -> String {
    let trimmed = clean(raw, limit: 1_024)
    guard trimmed.hasPrefix("/") else { return trimmed.isEmpty ? "unknown" : trimmed }
    let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map {
      component -> String in
      let text = String(component)
      return text.range(of: #"^v?\d+(\.\d+)+([-+_.][A-Za-z0-9.]+)?$"#, options: .regularExpression)
        != nil ? "*" : text
    }
    return components.joined(separator: "/")
  }

  static func clean(_ value: String, limit: Int) -> String {
    let scalars = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
      .prefix(limit).description
  }
}

/// The kernel's view of one helper connection.
public struct AgentConnectionPeer: Equatable, Sendable {
  /// The helper process.
  public let pid: pid_t
  public let uid: uid_t
  /// The executable of the helper's parent (the agent), when readable.
  public let clientExecutablePath: String?
  /// The parent's code-signing identity (see `AgentClientIdentity.signer`).
  public let clientSigner: String?
  /// The script an interpreter parent runs.
  public let clientScript: String?
  /// The developer named by the parent's signing certificate.
  public let clientSignerName: String?

  public init(
    pid: pid_t, uid: uid_t, clientExecutablePath: String?, clientSigner: String? = nil,
    clientScript: String? = nil, clientSignerName: String? = nil
  ) {
    self.pid = pid
    self.uid = uid
    self.clientExecutablePath = clientExecutablePath
    self.clientSigner = clientSigner
    self.clientScript = clientScript
    self.clientSignerName = clientSignerName
  }

  /// Reads the peer of an accepted socket: kernel credentials, then libproc
  /// for the helper's parent, its executable, its signature and its script.
  public static func inspect(_ descriptor: Int32) -> AgentConnectionPeer? {
    guard let peer = AgentPeer.of(descriptor) else { return nil }
    let parent = AgentProcessInspector.parentPID(peer.pid).flatMap { $0 > 1 ? $0 : nil }
    let path = parent.flatMap { AgentProcessInspector.executablePath($0) }
    let signature = parent.flatMap(AgentCodeSigning.signature(pid:))
    return AgentConnectionPeer(
      pid: peer.pid, uid: peer.uid, clientExecutablePath: path,
      clientSigner: signature?.signer,
      clientScript: parent.flatMap { pid in
        path.flatMap { AgentCodeSigning.script(pid: pid, executable: $0) }
      },
      clientSignerName: signature?.name)
  }
}

/// What the kernel and the code signature say about the agent process.
public enum AgentCodeSigning {
  /// `team:<team id>:<signing id>` for a valid Developer ID or App Store
  /// signature, `apple:<signing id>` for Apple's own, nil otherwise (no
  /// signature, ad hoc, or one that does not check out).
  public static func signer(pid: pid_t) -> String? { signature(pid: pid)?.signer }

  /// The signer (as `signer(pid:)`) and the developer its certificate names.
  public static func signature(pid: pid_t) -> (signer: String, name: String?)? {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
      let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess
    else { return nil }
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
      let dictionary = info as? [String: Any],
      let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
    else { return nil }
    if let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
      let leaf = (dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
      let summary = leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? }
      return ("team:\(team):\(identifier)", summary.flatMap { developerName($0, team: team) })
    }
    var requirement: SecRequirement?
    if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement)
      == errSecSuccess, let requirement,
      SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    {
      return ("apple:\(identifier)", "Apple")
    }
    return nil
  }

  /// 「Developer ID Application: Anthropic PBC (ANTHRTEAM1)」 → 「Anthropic PBC」.
  public static func developerName(_ summary: String, team: String) -> String? {
    var name = summary
    if let colon = name.range(of: ": ") { name = String(name[colon.upperBound...]) }
    let suffix = " (\(team))"
    if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
    name = name.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
  }

  static let interpreters = ["node", "bun", "deno"]

  /// For an interpreter parent, the first argument that is not an option
  /// (the script it runs); nil for anything else.
  public static func script(pid: pid_t, executable: String) -> String? {
    let base = URL(fileURLWithPath: executable).lastPathComponent
    guard interpreters.contains(base) || base.hasPrefix("python") else { return nil }
    guard let arguments = arguments(pid: pid) else { return nil }
    return arguments.dropFirst().first { !$0.hasPrefix("-") }
  }

  /// A process's arguments from `KERN_PROCARGS2` (same user only).
  public static func arguments(pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
    let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
    var index = 4
    while index < size, buffer[index] != 0 { index += 1 }  // the exec path
    while index < size, buffer[index] == 0 { index += 1 }
    var out: [String] = []
    while out.count < argc, index < size {
      let start = index
      while index < size, buffer[index] != 0 { index += 1 }
      out.append(String(decoding: buffer[start..<index], as: UTF8.self))
      index += 1
    }
    return out
  }
}
