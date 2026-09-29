import Foundation

struct AppUpdateCheckResult: Equatable, Sendable {
  let currentVersion: String
  let latestVersion: String
  let releasePageURL: URL

  var updateAvailable: Bool {
    Self.compare(latestVersion, currentVersion) == .orderedDescending
  }

  private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let left = components(lhs)
    let right = components(rhs)
    let count = max(left.count, right.count)
    for index in 0..<count {
      let leftValue = index < left.count ? left[index] : 0
      let rightValue = index < right.count ? right[index] : 0
      if leftValue < rightValue { return .orderedAscending }
      if leftValue > rightValue { return .orderedDescending }
    }
    return .orderedSame
  }

  private static func components(_ value: String) -> [UInt64] {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let version =
      trimmed.first?.lowercased() == "v"
      ? String(trimmed.dropFirst()) : trimmed
    return version.split(separator: ".").map { component in
      let digits = component.prefix(while: { $0.isNumber })
      return UInt64(digits) ?? 0
    }
  }
}

enum AppUpdateCheckError: Error, Equatable, Sendable {
  case invalidResponse
  case invalidRelease
  case networkUnavailable
}

/// Checks only the public GitHub release metadata for this source repository.
/// The ephemeral session has no cookies, cache, credentials, analytics, or
/// user-content fields. Installation remains an explicit hand-off to the
/// notarized release page so macOS Gatekeeper stays in the trust path.
///
/// Nothing is contacted unless the user asks: automatic checks are off until
/// turned on in Settings, and "检查更新" is a manual action.
actor AppUpdateChecker {
  /// The one public repository whose releases this app trusts. Change it
  /// here and nowhere else.
  static let repositorySlug = "Yusong-Enceladus/mindloom"
  static let automaticChecksPreferenceKey = "preferences.automatic-app-update-checks"
  static let automaticChecksEnabledByDefault = false

  static let latestReleaseEndpoint = URL(
    string: "https://api.github.com/repos/\(repositorySlug)/releases/latest"
  )!

  /// Only a release page of `repositorySlug` on github.com is ever offered.
  static func isOfficialReleasePage(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https"
      && url.host?.lowercased() == "github.com"
      && url.path.hasPrefix("/\(repositorySlug)/releases/")
  }

  private struct ReleaseMetadata: Decodable {
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case htmlURL = "html_url"
      case draft
      case prerelease
    }
  }

  func check(currentVersion: String) async throws -> AppUpdateCheckResult {
    var request = URLRequest(url: Self.latestReleaseEndpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpAdditionalHeaders = [
      "User-Agent": "bestASR-app-update-check"
    ]
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw AppUpdateCheckError.networkUnavailable
    }
    guard let http = response as? HTTPURLResponse,
      http.url?.scheme?.lowercased() == "https",
      (200...299).contains(http.statusCode),
      data.count <= 1_048_576
    else { throw AppUpdateCheckError.invalidResponse }
    let release: ReleaseMetadata
    do { release = try JSONDecoder().decode(ReleaseMetadata.self, from: data) } catch {
      throw AppUpdateCheckError.invalidResponse
    }
    guard !release.draft, !release.prerelease,
      Self.isOfficialReleasePage(release.htmlURL)
    else { throw AppUpdateCheckError.invalidRelease }
    return AppUpdateCheckResult(
      currentVersion: currentVersion,
      latestVersion: release.tagName,
      releasePageURL: release.htmlURL
    )
  }
}
