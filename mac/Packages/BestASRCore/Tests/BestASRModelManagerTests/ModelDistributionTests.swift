import CryptoKit
import Foundation
import XCTest

@testable import BestASRModelManager

final class ModelDistributionCoordinatorTests: XCTestCase {
  func testDistributionStateRoundTripsWithoutUserContent() throws {
    let state = ModelDistributionState(
      artifactID: "fixture-model",
      version: String(repeating: "1", count: 40),
      phase: .downloading,
      completedBytes: 4,
      totalBytes: 10,
      currentFile: "weights.bin"
    )
    let data = try JSONEncoder().encode(state)
    XCTAssertEqual(try JSONDecoder().decode(ModelDistributionState.self, from: data), state)
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(text.contains("transcript"))
    XCTAssertFalse(text.contains("dictionary"))
    XCTAssertFalse(text.contains("audio"))
  }

  func testCoordinatorDownloadsVerifiesActivatesAndRelaunchesOffline() async throws {
    let fixture = try DistributionFixture()
    let transport = FixtureDownloadTransport(payloads: fixture.payloads)
    let manager = try LocalModelManager(
      rootDirectory: fixture.modelRoot,
      registry: fixture.registry
    )
    let coordinator = try ModelDistributionCoordinator(
      rootDirectory: fixture.downloadRoot,
      registry: fixture.registry,
      manager: manager,
      transport: transport
    )
    let stateRecorder = LockedStateRecorder()
    let result = try await coordinator.install(
      artifactID: fixture.artifact.id,
      healthCheck: DistributionPassingHealthCheck()
    ) { state in
      stateRecorder.record(state.phase)
    }

    let states = stateRecorder.snapshot()
    XCTAssertEqual(result.disposition, .activated)
    XCTAssertTrue(states.contains(.downloading))
    XCTAssertTrue(states.contains(.verifying))
    XCTAssertTrue(states.contains(.warming))
    XCTAssertEqual(states.last, .ready)
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, fixture.artifact.files.count)

    let reopened = try LocalModelManager(
      rootDirectory: fixture.modelRoot,
      registry: fixture.registry
    )
    let active = try await reopened.discoverActive(
      artifactID: fixture.artifact.id,
      healthCheck: DistributionPassingHealthCheck()
    )
    XCTAssertEqual(active.descriptor, fixture.artifact)
  }

  func testInterruptedTransferPersistsResumeAndRetriesOnlyAffectedFile() async throws {
    let fixture = try DistributionFixture()
    let transport = FixtureDownloadTransport(
      payloads: fixture.payloads,
      failFirstPath: fixture.artifact.files[1].relativePath
    )
    let manager = try LocalModelManager(
      rootDirectory: fixture.modelRoot,
      registry: fixture.registry
    )
    let first = try ModelDistributionCoordinator(
      rootDirectory: fixture.downloadRoot,
      registry: fixture.registry,
      manager: manager,
      transport: transport
    )
    do {
      _ = try await first.install(
        artifactID: fixture.artifact.id,
        healthCheck: DistributionPassingHealthCheck()
      )
      XCTFail("Expected interruption")
    } catch let error as ModelDistributionError {
      XCTAssertEqual(error.category, .network)
      XCTAssertTrue(error.retryable)
    }

    let reopened = try ModelDistributionCoordinator(
      rootDirectory: fixture.downloadRoot,
      registry: fixture.registry,
      manager: manager,
      transport: transport
    )
    _ = try await reopened.install(
      artifactID: fixture.artifact.id,
      healthCheck: DistributionPassingHealthCheck()
    )
    let firstFileCount = await transport.count(
      for: fixture.artifact.files[0].relativePath
    )
    let secondFileCount = await transport.count(
      for: fixture.artifact.files[1].relativePath
    )
    let resumeObserved = await transport.sawResumeData()
    XCTAssertEqual(
      firstFileCount,
      1,
      "the verified first file must not download again"
    )
    XCTAssertEqual(
      secondFileCount,
      2
    )
    XCTAssertTrue(resumeObserved)
  }

  func testDigestFailureNeverCreatesActivePointer() async throws {
    let fixture = try DistributionFixture(corruptLastPayload: true)
    let transport = FixtureDownloadTransport(payloads: fixture.payloads)
    let manager = try LocalModelManager(
      rootDirectory: fixture.modelRoot,
      registry: fixture.registry
    )
    let coordinator = try ModelDistributionCoordinator(
      rootDirectory: fixture.downloadRoot,
      registry: fixture.registry,
      manager: manager,
      transport: transport
    )
    do {
      _ = try await coordinator.install(
        artifactID: fixture.artifact.id,
        healthCheck: DistributionPassingHealthCheck()
      )
      XCTFail("Expected integrity failure")
    } catch let error as ModelDistributionError {
      XCTAssertEqual(error.category, .integrity)
    }
    do {
      _ = try await manager.discoverActive(
        artifactID: fixture.artifact.id,
        healthCheck: DistributionPassingHealthCheck()
      )
      XCTFail("Partial candidate must not become active")
    } catch let error as ModelManagerError {
      XCTAssertEqual(error.category, .missingModel)
    }
  }

  func testCorruptReceiptIsIgnoredAndRebuiltSafely() async throws {
    let fixture = try DistributionFixture()
    let receipt = fixture.downloadRoot
      .appendingPathComponent(fixture.artifact.id, isDirectory: true)
      .appendingPathComponent(fixture.artifact.version, isDirectory: true)
      .appendingPathComponent("download-receipt.json")
    try FileManager.default.createDirectory(
      at: receipt.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("not-json".utf8).write(to: receipt)
    let transport = FixtureDownloadTransport(payloads: fixture.payloads)
    let manager = try LocalModelManager(
      rootDirectory: fixture.modelRoot,
      registry: fixture.registry
    )
    let coordinator = try ModelDistributionCoordinator(
      rootDirectory: fixture.downloadRoot,
      registry: fixture.registry,
      manager: manager,
      transport: transport
    )

    _ = try await coordinator.install(
      artifactID: fixture.artifact.id,
      healthCheck: DistributionPassingHealthCheck()
    )

    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, fixture.artifact.files.count)
  }

  func testHealthFailurePreservesPreviouslyActiveArtifact() async throws {
    let fixture = try DistributionFixture()
    let manager = try LocalModelManager(
      rootDirectory: fixture.modelRoot,
      registry: fixture.registry
    )
    let first = try ModelDistributionCoordinator(
      rootDirectory: fixture.downloadRoot,
      registry: fixture.registry,
      manager: manager,
      transport: FixtureDownloadTransport(payloads: fixture.payloads)
    )
    _ = try await first.install(
      artifactID: fixture.artifact.id,
      healthCheck: DistributionPassingHealthCheck()
    )

    let retry = try ModelDistributionCoordinator(
      rootDirectory: fixture.downloadRoot.appendingPathComponent("retry"),
      registry: fixture.registry,
      manager: manager,
      transport: FixtureDownloadTransport(payloads: fixture.payloads)
    )
    do {
      _ = try await retry.install(
        artifactID: fixture.artifact.id,
        healthCheck: DistributionFailingHealthCheck()
      )
      XCTFail("Expected health failure")
    } catch let error as ModelDistributionError {
      XCTAssertEqual(error.category, .fileSystem)
    }

    let active = try await manager.discoverActive(
      artifactID: fixture.artifact.id,
      healthCheck: DistributionPassingHealthCheck()
    )
    XCTAssertEqual(active.descriptor, fixture.artifact)
  }

  func testCancellationPublishesRetryableStateWithoutActivation() async throws {
    let fixture = try DistributionFixture()
    let transport = CancellationDownloadTransport()
    let manager = try LocalModelManager(
      rootDirectory: fixture.modelRoot,
      registry: fixture.registry
    )
    let coordinator = try ModelDistributionCoordinator(
      rootDirectory: fixture.downloadRoot,
      registry: fixture.registry,
      manager: manager,
      transport: transport
    )
    let task = Task {
      try await coordinator.install(
        artifactID: fixture.artifact.id,
        healthCheck: DistributionPassingHealthCheck()
      )
    }
    while await transport.requestCount() == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch let error as ModelDistributionError {
      XCTAssertEqual(error.category, .cancelled)
      XCTAssertTrue(error.retryable)
    }
    let state = await coordinator.currentState(artifactID: fixture.artifact.id)
    XCTAssertEqual(state?.phase, .retryableFailure)
  }

  func testConcurrentInstallForSameArtifactIsRejected() async throws {
    let fixture = try DistributionFixture()
    let transport = CancellationDownloadTransport()
    let manager = try LocalModelManager(
      rootDirectory: fixture.modelRoot,
      registry: fixture.registry
    )
    let coordinator = try ModelDistributionCoordinator(
      rootDirectory: fixture.downloadRoot,
      registry: fixture.registry,
      manager: manager,
      transport: transport
    )
    let first = Task {
      try await coordinator.install(
        artifactID: fixture.artifact.id,
        healthCheck: DistributionPassingHealthCheck()
      )
    }
    while await transport.requestCount() == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    do {
      _ = try await coordinator.install(
        artifactID: fixture.artifact.id,
        healthCheck: DistributionPassingHealthCheck()
      )
      XCTFail("Expected concurrent install rejection")
    } catch let error as ModelDistributionError {
      XCTAssertEqual(error.code, "model-install-already-running")
      XCTAssertTrue(error.retryable)
    }
    first.cancel()
    _ = try? await first.value
  }
}

final class ModelDownloadTransportTests: XCTestCase {
  override func tearDown() {
    DistributionURLProtocol.setHandler(nil)
    super.tearDown()
  }

  func testProductionTransportDownloadsOnlyHTTPSWithoutCookies() async throws {
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-transport-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: destination) }
    let recorder = LockedRequestRecorder()
    DistributionURLProtocol.setHandler { request in
      recorder.record(request)
      return .success(Data("fixture".utf8))
    }
    let transport = URLSessionModelDownloadTransport(
      protocolClasses: [DistributionURLProtocol.self]
    )

    let result = try await transport.download(
      ModelDownloadRequest(
        sourceURL: URL(string: "https://models.example/resolve/revision/file.bin")!,
        destinationURL: destination,
        resumeData: nil
      ),
      progress: { _, _ in }
    )

    XCTAssertEqual(result.downloadedBytes, 7)
    XCTAssertEqual(try Data(contentsOf: destination), Data("fixture".utf8))
    let request = try XCTUnwrap(recorder.snapshot())
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertNil(request.httpBody)
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
  }

  func testProductionTransportRejectsInsecureSourceBeforeRequest() async throws {
    let transport = URLSessionModelDownloadTransport(
      protocolClasses: [DistributionURLProtocol.self]
    )
    do {
      _ = try await transport.download(
        ModelDownloadRequest(
          sourceURL: URL(string: "http://models.example/file.bin")!,
          destinationURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString),
          resumeData: nil
        ),
        progress: { _, _ in }
      )
      XCTFail("Expected insecure source rejection")
    } catch let error as ModelDownloadTransportError {
      XCTAssertEqual(error.code, "model-download-insecure-source")
      XCTAssertFalse(error.retryable)
    }
  }

  func testProductionTransportRejectsHTTPRedirect() async throws {
    DistributionURLProtocol.setHandler { _ in
      .redirect(URL(string: "http://insecure.example/file.bin")!)
    }
    let transport = URLSessionModelDownloadTransport(
      protocolClasses: [DistributionURLProtocol.self]
    )
    do {
      _ = try await transport.download(
        ModelDownloadRequest(
          sourceURL: URL(string: "https://models.example/file.bin")!,
          destinationURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString),
          resumeData: nil
        ),
        progress: { _, _ in }
      )
      XCTFail("Expected insecure redirect rejection")
    } catch let error as ModelDownloadTransportError {
      XCTAssertEqual(error.code, "model-download-insecure-redirect")
      XCTAssertFalse(error.retryable)
    }
  }
}

private final class LockedStateRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [ModelDistributionPhase] = []

  func record(_ value: ModelDistributionPhase) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }

  func snapshot() -> [ModelDistributionPhase] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

private actor FixtureDownloadTransport: ModelDownloadTransport {
  private let payloads: [String: Data]
  private let failFirstPath: String?
  private var failed = false
  private var counts: [String: Int] = [:]
  private var resumeObserved = false

  init(payloads: [String: Data], failFirstPath: String? = nil) {
    self.payloads = payloads
    self.failFirstPath = failFirstPath
  }

  func download(
    _ request: ModelDownloadRequest,
    progress: @escaping @Sendable (UInt64, UInt64?) -> Void
  ) async throws -> ModelDownloadResult {
    let marker = "/resolve/"
    let path = request.sourceURL.path
    let suffix = try XCTUnwrap(path.range(of: marker)).upperBound
    let afterRevision = path[suffix...]
    let relativePath = afterRevision.split(separator: "/").dropFirst().joined(separator: "/")
    counts[relativePath, default: 0] += 1
    if request.resumeData != nil { resumeObserved = true }
    if relativePath == failFirstPath, !failed {
      failed = true
      throw ModelDownloadTransportError(
        code: "fixture-interruption",
        retryable: true,
        resumeData: Data("fixture-resume".utf8)
      )
    }
    let data = try XCTUnwrap(payloads[relativePath])
    try FileManager.default.createDirectory(
      at: request.destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: request.destinationURL, options: .atomic)
    progress(UInt64(data.count), UInt64(data.count))
    return ModelDownloadResult(downloadedBytes: UInt64(data.count))
  }

  func requestCount() -> Int { counts.values.reduce(0, +) }
  func count(for path: String) -> Int { counts[path, default: 0] }
  func sawResumeData() -> Bool { resumeObserved }
}

private actor CancellationDownloadTransport: ModelDownloadTransport {
  private var requests = 0
  func download(
    _ request: ModelDownloadRequest,
    progress: @escaping @Sendable (UInt64, UInt64?) -> Void
  ) async throws -> ModelDownloadResult {
    requests += 1
    try await Task.sleep(for: .seconds(30))
    return ModelDownloadResult(downloadedBytes: 0)
  }
  func requestCount() -> Int { requests }
}

private struct DistributionPassingHealthCheck: ManagedModelHealthChecking {
  func check(modelDirectory: URL) async throws {}
}

private struct DistributionFailingHealthCheck: ManagedModelHealthChecking {
  struct Failure: Error {}
  func check(modelDirectory: URL) async throws { throw Failure() }
}

private final class LockedRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var request: URLRequest?
  func record(_ request: URLRequest) {
    lock.lock()
    self.request = request
    lock.unlock()
  }
  func snapshot() -> URLRequest? {
    lock.lock()
    defer { lock.unlock() }
    return request
  }
}

private final class DistributionURLProtocol: URLProtocol, @unchecked Sendable {
  enum Response: Sendable {
    case success(Data)
    case redirect(URL)
  }
  typealias Handler = @Sendable (URLRequest) -> Response
  private static let lock = NSLock()
  nonisolated(unsafe) private static var handler: Handler?

  static func setHandler(_ handler: Handler?) {
    lock.lock()
    self.handler = handler
    lock.unlock()
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    let handler = Self.handler
    Self.lock.unlock()
    guard let handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    switch handler(request) {
    case .success(let data):
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": String(data.count)]
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    case .redirect(let url):
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: ["Location": url.absoluteString]
      )!
      client?.urlProtocol(
        self,
        wasRedirectedTo: URLRequest(url: url),
        redirectResponse: response
      )
      client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
  }

  override func stopLoading() {}
}

private struct DistributionFixture {
  let root: URL
  let modelRoot: URL
  let downloadRoot: URL
  let artifact: ManagedModelArtifact
  let registry: ManagedModelRegistry
  let payloads: [String: Data]

  init(corruptLastPayload: Bool = false) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-model-distribution-\(UUID().uuidString)",
      isDirectory: true
    )
    modelRoot = root.appendingPathComponent("models", isDirectory: true)
    downloadRoot = root.appendingPathComponent("downloads", isDirectory: true)
    let revision = String(repeating: "1", count: 40)
    let goodPayloads = [
      "weights.bin": Data("fixture weights".utf8),
      "nested/vocab.json": Data("{\"fixture\":true}".utf8),
    ]
    let files = goodPayloads.keys.sorted().map { path in
      let data = goodPayloads[path]!
      return ManagedModelFile(
        relativePath: path,
        sizeBytes: UInt64(data.count),
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      )
    }
    artifact = ManagedModelArtifact(
      id: "fixture-model",
      exactVersion: revision,
      activationSequence: 1,
      downloadBaseURL: "https://huggingface.co/bestasr/fixture/resolve/\(revision)",
      sourceRevision: revision,
      treeSHA256: String(repeating: "a", count: 64),
      license: "LicenseRef-Fixture",
      licenseFile: "Legal/fixture.txt",
      licenseSHA256: String(repeating: "b", count: 64),
      totalSizeBytes: files.reduce(0) { $0 + $1.sizeBytes },
      files: files
    )
    registry = ManagedModelRegistry(
      schemaVersion: 1,
      models: [artifact],
      selectionStatus: "fixture"
    )
    var served = goodPayloads
    if corruptLastPayload, let path = files.last?.relativePath {
      served[path] = Data(repeating: 0, count: Int(files.last!.sizeBytes))
    }
    payloads = served
  }
}
