import Darwin
import Foundation

/// Which hosts the lookup may reach (WEBSEARCH §4.4): public internet hosts
/// only. Loopback, private, link-local, carrier-grade NAT (Tailscale uses
/// it), unique-local and multicast addresses are refused, and so are local
/// names (`.local`, single labels). 198.18.0.0/15 is allowed: proxies that
/// answer every name with a placeholder address from it (the "fake IP" mode
/// common in China) would otherwise make every page unreadable.
public enum HostPolicy {
  static let localSuffixes = [
    ".local", ".localhost", ".internal", ".lan", ".home", ".home.arpa", ".intranet", ".corp",
    ".private",
  ]

  /// True for a host name or literal address the lookup never contacts.
  public static func isPrivate(hostName: String) -> Bool {
    var host = hostName.lowercased()
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    while host.hasSuffix(".") { host.removeLast() }
    if host.isEmpty { return true }
    if let address = IPAddress(host) { return address.isPrivate }
    if host == "localhost" || localSuffixes.contains(where: { host.hasSuffix($0) }) { return true }
    // A single label ("intranet", "router") is a local name.
    if !host.contains(".") { return true }
    // Numeric forms getaddrinfo still accepts ("2130706433", "0x7f.1",
    // "127.1"): a last label without a letter, or in hex.
    let last = host.split(separator: ".").last.map(String.init) ?? host
    if last.allSatisfy(\.isNumber) || last.hasPrefix("0x") { return true }
    return false
  }
}

/// An IPv4 or IPv6 address, parsed with `inet_pton`.
public struct IPAddress: Hashable, Sendable {
  public let bytes: [UInt8]

  public init?(_ text: String) {
    var v4 = in_addr()
    if inet_pton(AF_INET, text, &v4) == 1 {
      bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }
      return
    }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, text, &v6) == 1 {
      bytes = withUnsafeBytes(of: v6) { Array($0) }
      return
    }
    return nil
  }

  init(bytes: [UInt8]) { self.bytes = bytes }

  public var isPrivate: Bool {
    if bytes.count == 4 { return Self.isPrivateV4(bytes) }
    guard bytes.count == 16 else { return true }
    // IPv4-mapped (::ffff:a.b.c.d) and NAT64 (64:ff9b::a.b.c.d) follow the
    // IPv4 rule.
    if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
      return Self.isPrivateV4(Array(bytes[12..<16]))
    }
    if Array(bytes[0..<12]) == [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0] {
      return Self.isPrivateV4(Array(bytes[12..<16]))
    }
    if bytes[0..<15].allSatisfy({ $0 == 0 }) { return true }  // :: and ::1
    if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }  // fe80::/10 link-local
    if bytes[0] & 0xFE == 0xFC { return true }  // fc00::/7 unique local
    if bytes[0] == 0xFF { return true }  // multicast
    if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 { return true }  // documentation
    return false
  }

  static func isPrivateV4(_ b: [UInt8]) -> Bool {
    switch (b[0], b[1]) {
    case (0, _), (10, _), (127, _): return true
    case (100, 64...127): return true  // carrier-grade NAT, Tailscale
    case (169, 254): return true
    case (172, 16...31): return true
    case (192, 168): return true
    case (192, 0) where b[2] == 0: return true
    case (198, 18...19): return false  // fake-IP proxies (benchmarking range)
    case (224...255, _): return true  // multicast, reserved, broadcast
    default: return false
    }
  }
}

/// Resolves a host before it is contacted, so a public name that points at
/// a private address is refused. Resolution failing is not a refusal: behind
/// a proxy the device may not resolve names itself.
public protocol HostResolver: Sendable {
  /// The addresses for `host`, or nil when it cannot be resolved here.
  func addresses(for host: String) async -> [IPAddress]?
}

/// `getaddrinfo` on a background queue.
public struct SystemHostResolver: HostResolver {
  public init() {}

  public func addresses(for host: String) async -> [IPAddress]? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: Self.resolve(host))
      }
    }
  }

  static func resolve(_ host: String) -> [IPAddress]? {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { return nil }
    defer { freeaddrinfo(first) }
    var addresses: [IPAddress] = []
    var cursor: UnsafeMutablePointer<addrinfo>? = first
    while let info = cursor {
      if let address = info.pointee.ai_addr {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
          address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            let raw = withUnsafeBytes(of: pointer.pointee.sin_addr.s_addr) { Array($0) }
            addresses.append(IPAddress(bytes: raw))
          }
        case AF_INET6:
          address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
            let raw = withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
            addresses.append(IPAddress(bytes: raw))
          }
        default: break
        }
      }
      cursor = info.pointee.ai_next
    }
    return addresses
  }
}
