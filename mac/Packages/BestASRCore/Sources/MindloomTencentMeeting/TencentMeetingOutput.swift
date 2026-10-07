import Foundation

/// Why a tmeet run did not give what was asked. Stored with a recording's
/// fetch job (error category) and turned into the one status line in
/// Settings; never into a message on Home.
public enum TencentMeetingFailure: String, Codable, Equatable, Error, Sendable {
  /// No login, or Tencent refused it (expired, revoked): connect again.
  case notConnected
  /// No network, or Tencent's servers did not answer or answered with a
  /// server error (5xx, or 429 without Tencent's limit code): try again
  /// later.
  case network
  /// Tencent's call limit for the day (500246): wait until tomorrow.
  case rateLimited
  /// This account's edition cannot use tmeet (500284).
  case accountNotAvailable
  /// The transcript is still being made (30003): try again later.
  case generating
  /// The recording has no transcript text (30002).
  case noContent
  /// The account may not view this recording (any more).
  case noPermission
  /// The bundled tmeet is missing, could not start, or is not the one
  /// sealed into the App.
  case helperMissing
  /// The login's key could not be read from this Mac (access refused or
  /// the Keychain locked): try again, allowing access.
  case keyUnavailable
  case timedOut
  /// The output was not what tmeet prints.
  case unreadable
  case other

  /// Failures that stop the whole pass (every further call would fail too).
  public var stopsPass: Bool {
    switch self {
    case .notConnected, .network, .rateLimited, .accountNotAvailable, .helperMissing,
      .keyUnavailable, .timedOut:
      true
    default: false
    }
  }
}

/// Reads what tmeet printed: the JSON envelope on success
/// (`{"trace_id", "message", "data"}`), otherwise `Error: …` on standard
/// error with Tencent's `error_info` when the server answered.
public enum TencentMeetingOutput {
  /// The `data` object of a successful run, or the failure.
  public static func data(_ result: TencentMeetingRunResult) -> Result<
    [String: Any], TencentMeetingFailureReport
  > {
    if let failure = failure(result) { return .failure(failure) }
    guard let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
      let data = object["data"] as? [String: Any]
    else { return .failure(TencentMeetingFailureReport(.unreadable)) }
    return .success(data)
  }

  /// Nil when the run succeeded (exit 0).
  public static func failure(_ result: TencentMeetingRunResult) -> TencentMeetingFailureReport? {
    switch result.launchFailure {
    case .key?: return TencentMeetingFailureReport(.keyUnavailable)
    case .helper?: return TencentMeetingFailureReport(.helperMissing)
    case nil: break
    }
    if result.timedOut { return TencentMeetingFailureReport(.timedOut) }
    if result.exitStatus == 0 { return nil }
    let text = String(decoding: result.stderr + result.stdout, as: UTF8.self)
    let codes = businessCodes(text)
    let lower = text.lowercased()
    for code in codes {
      switch code % 1_000_000 {
      case 500_246: return TencentMeetingFailureReport(.rateLimited, code: code)
      case 500_284: return TencentMeetingFailureReport(.accountNotAvailable, code: code)
      case 30_003: return TencentMeetingFailureReport(.generating, code: code)
      case 30_002: return TencentMeetingFailureReport(.noContent, code: code)
      case 190_303, 10_006: return TencentMeetingFailureReport(.notConnected, code: code)
      default: continue
      }
    }
    let notConnected = [
      "user config is empty", "user identity expired", "your token has been expired",
      "refresh token failed", "get user config unknown error", "parse user config error",
    ]
    if notConnected.contains(where: { lower.contains($0) }) {
      return TencentMeetingFailureReport(.notConnected, code: codes.first)
    }
    if lower.contains("network error") {
      return TencentMeetingFailureReport(.network, code: codes.first)
    }
    let status = httpStatus(text)
    if status == 403 {
      return TencentMeetingFailureReport(.noPermission, code: codes.first)
    }
    // A server error or a bare 429 without one of Tencent's codes (a
    // gateway's answer; tmeet's own token refresh prints these as
    // "request failed, http status:502"): passing, like the network. With
    // a code Tencent did not document it stays the recording's own.
    if let status, codes.isEmpty, status == 429 || (500...599).contains(status) {
      return TencentMeetingFailureReport(.network, code: status)
    }
    return TencentMeetingFailureReport(.other, code: codes.first ?? status)
  }

  /// A transcript answer that came back as success but carries Tencent's
  /// own non-zero `code` (read like the same code in an error).
  public static func dataFailure(_ data: [String: Any]) -> TencentMeetingFailureReport? {
    guard let code = TencentMeetingListingParser.integer(data["code"]), code != 0 else {
      return nil
    }
    switch code % 1_000_000 {
    case 30_003: return TencentMeetingFailureReport(.generating, code: code)
    case 30_002: return TencentMeetingFailureReport(.noContent, code: code)
    case 500_246: return TencentMeetingFailureReport(.rateLimited, code: code)
    case 500_284: return TencentMeetingFailureReport(.accountNotAvailable, code: code)
    default: return TencentMeetingFailureReport(.other, code: code)
    }
  }

  /// Tencent's `error_code` / `new_error_code` values in an error text.
  static func businessCodes(_ text: String) -> [Int] {
    let pattern = try! NSRegularExpression(pattern: #""(?:new_)?error_code"\s*:\s*(\d{1,12})"#)
    let range = NSRange(text.startIndex..., in: text)
    return pattern.matches(in: text, range: range).compactMap { match in
      Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
    }
  }

  static func httpStatus(_ text: String) -> Int? {
    let pattern = try! NSRegularExpression(pattern: #"http status:\s*(\d{3})"#)
    let range = NSRange(text.startIndex..., in: text)
    guard let match = pattern.firstMatch(in: text, range: range),
      let found = Range(match.range(at: 1), in: text)
    else { return nil }
    return Int(text[found])
  }
}

/// A failure and Tencent's code when there was one (kept for diagnosis; no
/// content).
public struct TencentMeetingFailureReport: Error, Equatable, Sendable {
  public let failure: TencentMeetingFailure
  public let code: Int?

  public init(_ failure: TencentMeetingFailure, code: Int? = nil) {
    self.failure = failure
    self.code = code
  }
}

/// `tmeet auth status`, read for the login's state and its two expiry
/// times. The account's name is kept on this Mac only, to tell which
/// speaker is the owner.
public struct TencentMeetingAuthStatus: Equatable, Sendable {
  public var loggedIn: Bool
  public var userName: String?
  public var accessTokenExpires: Date?
  public var refreshTokenExpires: Date?

  public init(
    loggedIn: Bool, userName: String? = nil, accessTokenExpires: Date? = nil,
    refreshTokenExpires: Date? = nil
  ) {
    self.loggedIn = loggedIn
    self.userName = userName
    self.accessTokenExpires = accessTokenExpires
    self.refreshTokenExpires = refreshTokenExpires
  }

  /// Parses the status text; tmeet prints times in this Mac's time zone as
  /// `2006-01-02 15:04:05`.
  public static func parse(_ text: String, timeZone: TimeZone = .current)
    -> TencentMeetingAuthStatus
  {
    let lines = text.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    let loggedIn =
      lines.contains("Logged in") && !lines.contains(where: { $0.hasPrefix("Session has expired") })
    var status = TencentMeetingAuthStatus(loggedIn: loggedIn)
    for line in lines {
      if line.hasPrefix("UserName:") {
        let name = line.dropFirst("UserName:".count).trimmingCharacters(in: .whitespaces)
        status.userName = name.isEmpty ? nil : name
      } else if line.hasPrefix("AccessToken:") {
        status.accessTokenExpires = expiry(line, timeZone: timeZone)
      } else if line.hasPrefix("RefreshToken:") {
        status.refreshTokenExpires = expiry(line, timeZone: timeZone)
      }
    }
    return status
  }

  /// "valid (expires at 2026-11-04 23:10:26, remaining …)" or
  /// "expired (at 2026-11-04 23:10:26)".
  static func expiry(_ line: String, timeZone: TimeZone) -> Date? {
    let pattern = try! NSRegularExpression(
      pattern: #"(?:expires at|at) (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})"#)
    let range = NSRange(line.startIndex..., in: line)
    guard let match = pattern.firstMatch(in: line, range: range),
      let found = Range(match.range(at: 1), in: line)
    else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.date(from: String(line[found]))
  }
}

/// What `auth login --no-browser` said.
public enum TencentMeetingLoginOutput {
  /// The authorization page tmeet printed, when it is Tencent's
  /// (`https://meeting.tencent.com/marketplace/tencentmeeting-cli-auth.html?code=…`).
  public static func authorizationURL(in line: String) -> URL? {
    guard let range = line.range(of: "authorize url:") else { return nil }
    let text = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    guard let components = URLComponents(string: text), components.scheme == "https",
      components.host == "meeting.tencent.com", components.port == nil,
      components.user == nil, components.password == nil,
      components.path == "/marketplace/tencentmeeting-cli-auth.html",
      let items = components.queryItems, items.count == 1, items[0].name == "code",
      let code = items[0].value, (8...256).contains(code.utf8.count),
      code.utf8.allSatisfy({ byte in
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
          || (0x61...0x7A).contains(byte) || byte == 0x2D || byte == 0x5F
      }),
      components.fragment == nil
    else { return nil }
    return components.url
  }

  public enum Outcome: Equatable, Sendable {
    case connected
    /// The login on this Mac still holds; nothing was asked.
    case alreadyConnected
    /// Five minutes passed without the owner allowing it.
    case expired
    case cancelled
    case network
    case failed
  }

  public static func outcome(_ result: TencentMeetingRunResult, cancelled: Bool) -> Outcome {
    if cancelled { return .cancelled }
    let text = String(decoding: result.stdout + result.stderr, as: UTF8.self).lowercased()
    if result.exitStatus == 0, text.contains("login successful") { return .connected }
    if text.contains("user has been login") { return .alreadyConnected }
    if result.timedOut || text.contains("authorization timeout") { return .expired }
    if text.contains("network error") || text.contains("get auth_code failed") { return .network }
    return .failed
  }
}
