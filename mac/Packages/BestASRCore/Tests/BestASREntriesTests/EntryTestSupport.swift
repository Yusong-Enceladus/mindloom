import BestASRDomain
import BestASREntries
import BestASRIntake
import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// A library store that keeps drafts in memory (the commit side of
/// `UserItemCommitting`).
actor RecordingItemStore: UserItemCommitting {
  private(set) var drafts: [UserItemDraft] = []

  struct Duplicate: Error {}

  func createUserItem(_ draft: UserItemDraft) async throws {
    guard !drafts.contains(where: { $0.id == draft.id }) else { throw Duplicate() }
    drafts.append(draft)
  }

  func existingSessionIDs(among candidates: [SessionID]) async throws -> Set<SessionID> {
    Set(candidates).intersection(drafts.map(\.id))
  }

  func remove(_ id: SessionID) {
    drafts.removeAll { $0.id == id }
  }
}

/// Records every HTTP(S) request any URL loading system in this process
/// starts, and lets none of them through. "Links are never fetched" means
/// this stays empty.
final class NetworkTripwire: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var seen: [URL] = []

  static var requests: [URL] { lock.withLock { seen } }

  static func arm() {
    lock.withLock { seen = [] }
    URLProtocol.registerClass(NetworkTripwire.self)
  }

  static func disarm() {
    URLProtocol.unregisterClass(NetworkTripwire.self)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    if let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
      lock.withLock { seen.append(url) }
      return true
    }
    return false
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
  }

  override func stopLoading() {}
}

extension XCTestCase {
  func makeTemporaryFolder(_ prefix: String = "mle") throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }

  func makeCommitter(root: URL, protected: URL? = nil) -> (EntryCommitter, RecordingItemStore) {
    let store = RecordingItemStore()
    let policy = IntakePathPolicy { url in
      guard let protected else { return false }
      return url.standardizedFileURL.path.hasPrefix(protected.standardizedFileURL.path)
    }
    let processor = IntakeProcessor(
      assetStore: IntakeAssetStore(assetRoot: root.appendingPathComponent("assets")),
      pathPolicy: policy)
    return (EntryCommitter(processor: processor, store: store), store)
  }

  /// A tiny real PNG.
  func pngData(width: Int = 4, height: Int = 4) throws -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }
}
