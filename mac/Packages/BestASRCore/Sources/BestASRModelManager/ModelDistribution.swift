import Foundation

public enum ModelDistributionPhase: String, Codable, Equatable, Sendable {
  case consentRequired
  case downloading
  case verifying
  case warming
  case ready
  case retryableFailure
  case incompatible
}

public struct ModelDistributionState: Codable, Equatable, Sendable {
  public let artifactID: String
  public let version: String
  public let phase: ModelDistributionPhase
  public let completedBytes: UInt64
  public let totalBytes: UInt64
  public let currentFile: String?
  public let errorCode: String?

  public init(
    artifactID: String,
    version: String,
    phase: ModelDistributionPhase,
    completedBytes: UInt64,
    totalBytes: UInt64,
    currentFile: String? = nil,
    errorCode: String? = nil
  ) {
    self.artifactID = artifactID
    self.version = version
    self.phase = phase
    self.completedBytes = min(completedBytes, totalBytes)
    self.totalBytes = totalBytes
    self.currentFile = currentFile
    self.errorCode = errorCode
  }

  public var fractionCompleted: Double {
    guard totalBytes > 0 else { return 0 }
    return Double(completedBytes) / Double(totalBytes)
  }
}

public enum ModelDistributionFailureCategory: String, Codable, Sendable {
  case cancelled
  case fileSystem
  case integrity
  case invalidCatalog
  case network
  case security
}

public struct ModelDistributionError: Error, Codable, Equatable, Sendable {
  public let category: ModelDistributionFailureCategory
  public let code: String
  public let retryable: Bool

  public init(
    _ category: ModelDistributionFailureCategory,
    code: String,
    retryable: Bool
  ) {
    self.category = category
    self.code = code
    self.retryable = retryable
  }
}

public struct ModelDownloadRequest: Sendable {
  public let sourceURL: URL
  public let destinationURL: URL
  public let resumeData: Data?

  public init(sourceURL: URL, destinationURL: URL, resumeData: Data?) {
    self.sourceURL = sourceURL
    self.destinationURL = destinationURL
    self.resumeData = resumeData
  }
}

public struct ModelDownloadResult: Equatable, Sendable {
  public let downloadedBytes: UInt64

  public init(downloadedBytes: UInt64) {
    self.downloadedBytes = downloadedBytes
  }
}

public struct ModelDownloadTransportError: Error, @unchecked Sendable {
  public let code: String
  public let retryable: Bool
  public let resumeData: Data?

  public init(code: String, retryable: Bool, resumeData: Data? = nil) {
    self.code = code
    self.retryable = retryable
    self.resumeData = resumeData
  }
}

public protocol ModelDownloadTransport: Sendable {
  func download(
    _ request: ModelDownloadRequest,
    progress: @escaping @Sendable (_ written: UInt64, _ expected: UInt64?) -> Void
  ) async throws -> ModelDownloadResult
}

/// URLSession is confined to model distribution. Requests contain only a
/// catalog-pinned public URL and standard HTTP metadata.
public final class URLSessionModelDownloadTransport: ModelDownloadTransport,
  @unchecked Sendable
{
  private let protocolClasses: [AnyClass]?

  public init(protocolClasses: [AnyClass]? = nil) {
    self.protocolClasses = protocolClasses
  }

  public func download(
    _ request: ModelDownloadRequest,
    progress: @escaping @Sendable (UInt64, UInt64?) -> Void
  ) async throws -> ModelDownloadResult {
    guard request.sourceURL.scheme?.lowercased() == "https" else {
      throw ModelDownloadTransportError(
        code: "model-download-insecure-source",
        retryable: false
      )
    }
    let operation = DownloadOperation(
      request: request,
      protocolClasses: protocolClasses,
      progress: progress
    )
    return try await withTaskCancellationHandler {
      try await operation.run()
    } onCancel: {
      operation.cancel()
    }
  }
}

private final class DownloadOperation: NSObject, URLSessionDownloadDelegate,
  URLSessionTaskDelegate, @unchecked Sendable
{
  private let request: ModelDownloadRequest
  private let protocolClasses: [AnyClass]?
  private let progress: @Sendable (UInt64, UInt64?) -> Void
  private let lock = NSLock()
  private var continuation: CheckedContinuation<ModelDownloadResult, Error>?
  private var session: URLSession?
  private var task: URLSessionDownloadTask?
  private var movedBytes: UInt64?
  private var terminalError: Error?
  private var producedResumeData: Data?
  private var cancellationRequested = false

  init(
    request: ModelDownloadRequest,
    protocolClasses: [AnyClass]?,
    progress: @escaping @Sendable (UInt64, UInt64?) -> Void
  ) {
    self.request = request
    self.protocolClasses = protocolClasses
    self.progress = progress
  }

  func run() async throws -> ModelDownloadResult {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      self.continuation = continuation
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCache = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.httpShouldSetCookies = false
      configuration.httpCookieAcceptPolicy = .never
      if let protocolClasses {
        configuration.protocolClasses = protocolClasses
      }
      let session = URLSession(
        configuration: configuration,
        delegate: self,
        delegateQueue: nil
      )
      self.session = session
      let task: URLSessionDownloadTask
      if let resumeData = request.resumeData, !resumeData.isEmpty {
        task = session.downloadTask(withResumeData: resumeData)
      } else {
        var urlRequest = URLRequest(url: request.sourceURL)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = 120
        task = session.downloadTask(with: urlRequest)
      }
      self.task = task
      let cancellationRequested = self.cancellationRequested
      lock.unlock()
      if cancellationRequested {
        cancel(task)
      } else {
        task.resume()
      }
    }
  }

  func cancel() {
    lock.lock()
    cancellationRequested = true
    let task = self.task
    lock.unlock()
    if let task {
      cancel(task)
    }
  }

  private func cancel(_ task: URLSessionDownloadTask) {
    task.cancel(byProducingResumeData: { [weak self] data in
      guard let self else { return }
      self.lock.lock()
      self.producedResumeData = data
      self.lock.unlock()
    })
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard request.url?.scheme?.lowercased() == "https" else {
      terminalError = ModelDownloadTransportError(
        code: "model-download-insecure-redirect",
        retryable: false
      )
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    progress(
      UInt64(max(0, totalBytesWritten)),
      totalBytesExpectedToWrite > 0 ? UInt64(totalBytesExpectedToWrite) : nil
    )
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    do {
      guard
        let response = downloadTask.response as? HTTPURLResponse,
        (200...299).contains(response.statusCode),
        response.url?.scheme?.lowercased() == "https"
      else {
        throw ModelDownloadTransportError(
          code: "model-download-http-response",
          retryable: true
        )
      }
      let manager = FileManager.default
      try manager.createDirectory(
        at: request.destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if manager.fileExists(atPath: request.destinationURL.path) {
        try manager.removeItem(at: request.destinationURL)
      }
      try manager.moveItem(at: location, to: request.destinationURL)
      let values = try request.destinationURL.resourceValues(forKeys: [.fileSizeKey])
      movedBytes = UInt64(values.fileSize ?? 0)
    } catch {
      terminalError = error
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    let result: Result<ModelDownloadResult, Error>
    if let terminalError {
      result = .failure(terminalError)
    } else if let error {
      let nsError = error as NSError
      lock.lock()
      let producedResumeData = self.producedResumeData
      lock.unlock()
      let resumeData =
        producedResumeData
        ?? nsError.userInfo["NSURLSessionDownloadTaskResumeData"] as? Data
      result = .failure(
        ModelDownloadTransportError(
          code: nsError.code == NSURLErrorCancelled
            ? "model-download-cancelled"
            : "model-download-network-failed",
          retryable: true,
          resumeData: resumeData
        )
      )
    } else if let movedBytes {
      result = .success(ModelDownloadResult(downloadedBytes: movedBytes))
    } else {
      result = .failure(
        ModelDownloadTransportError(
          code: "model-download-missing-output",
          retryable: true
        )
      )
    }
    finish(result)
  }

  private func finish(_ result: Result<ModelDownloadResult, Error>) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    let session = self.session
    self.session = nil
    self.task = nil
    lock.unlock()
    session?.finishTasksAndInvalidate()
    continuation?.resume(with: result)
  }
}

private struct ModelDistributionReceipt: Codable, Equatable {
  let schemaVersion: Int
  let artifactID: String
  let version: String
  var completedFiles: Set<String>
  var resumeDataByFile: [String: Data]
}

public actor ModelDistributionCoordinator {
  public typealias StateHandler = @Sendable (ModelDistributionState) -> Void

  private let rootDirectory: URL
  private let registry: ManagedModelRegistry
  private let manager: LocalModelManager
  private let transport: any ModelDownloadTransport
  private let fileManager: FileManager
  private var stateByArtifact: [String: ModelDistributionState] = [:]
  private var installingArtifacts: Set<String> = []

  public init(
    rootDirectory: URL,
    registry: ManagedModelRegistry,
    manager: LocalModelManager,
    transport: any ModelDownloadTransport = URLSessionModelDownloadTransport(),
    fileManager: FileManager = .default
  ) throws {
    guard rootDirectory.path != "/" else {
      throw ModelDistributionError(
        .fileSystem,
        code: "model-download-root-too-broad",
        retryable: false
      )
    }
    try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    self.rootDirectory = rootDirectory.standardizedFileURL
    self.registry = registry
    self.manager = manager
    self.transport = transport
    self.fileManager = fileManager
  }

  public func consentState(artifactID: String) throws -> ModelDistributionState {
    let artifact = try descriptor(artifactID)
    let state = ModelDistributionState(
      artifactID: artifact.id,
      version: artifact.version,
      phase: .consentRequired,
      completedBytes: 0,
      totalBytes: artifact.totalSizeBytes
    )
    stateByArtifact[artifactID] = state
    return state
  }

  public func currentState(artifactID: String) -> ModelDistributionState? {
    stateByArtifact[artifactID]
  }

  @discardableResult
  public func install(
    artifactID: String,
    healthCheck: any ManagedModelHealthChecking,
    onState: @escaping StateHandler = { _ in }
  ) async throws -> ModelActivationResult {
    let artifact = try descriptor(artifactID)
    guard installingArtifacts.insert(artifactID).inserted else {
      throw ModelDistributionError(
        .fileSystem,
        code: "model-install-already-running",
        retryable: true
      )
    }
    defer { installingArtifacts.remove(artifactID) }
    let staging = stagingDirectory(for: artifact)
    let receiptURL = staging.appendingPathComponent("download-receipt.json")
    do {
      try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
      var receipt = loadReceipt(at: receiptURL, artifact: artifact)
      receipt = try repairReceipt(receipt, artifact: artifact, staging: staging)
      try persist(receipt, to: receiptURL)
      var baseCompleted = artifact.files.reduce(UInt64(0)) { total, file in
        receipt.completedFiles.contains(file.relativePath)
          ? total + file.sizeBytes : total
      }

      for file in artifact.files where !receipt.completedFiles.contains(file.relativePath) {
        try Task.checkCancellation()
        let completedBeforeFile = baseCompleted
        let destination = staging.appendingPathComponent(file.relativePath)
        let source = try sourceURL(artifact: artifact, file: file)
        publish(
          ModelDistributionState(
            artifactID: artifact.id,
            version: artifact.version,
            phase: .downloading,
            completedBytes: baseCompleted,
            totalBytes: artifact.totalSizeBytes,
            currentFile: file.relativePath
          ),
          onState
        )
        do {
          _ = try await transport.download(
            ModelDownloadRequest(
              sourceURL: source,
              destinationURL: destination,
              resumeData: receipt.resumeDataByFile[file.relativePath]
            )
          ) { written, _ in
            onState(
              ModelDistributionState(
                artifactID: artifact.id,
                version: artifact.version,
                phase: .downloading,
                completedBytes: min(
                  artifact.totalSizeBytes,
                  completedBeforeFile + min(written, file.sizeBytes)
                ),
                totalBytes: artifact.totalSizeBytes,
                currentFile: file.relativePath
              )
            )
          }
        } catch let error as ModelDownloadTransportError {
          if let resumeData = error.resumeData, !resumeData.isEmpty {
            receipt.resumeDataByFile[file.relativePath] = resumeData
            try? persist(receipt, to: receiptURL)
          }
          throw ModelDistributionError(
            error.code == "model-download-insecure-redirect" ? .security : .network,
            code: error.code,
            retryable: error.retryable
          )
        }
        try verify(destination, expected: file)
        receipt.completedFiles.insert(file.relativePath)
        receipt.resumeDataByFile[file.relativePath] = nil
        try persist(receipt, to: receiptURL)
        baseCompleted += file.sizeBytes
      }

      publish(
        ModelDistributionState(
          artifactID: artifact.id,
          version: artifact.version,
          phase: .verifying,
          completedBytes: artifact.totalSizeBytes,
          totalBytes: artifact.totalSizeBytes
        ),
        onState
      )
      for file in artifact.files {
        try verify(staging.appendingPathComponent(file.relativePath), expected: file)
      }
      publish(
        ModelDistributionState(
          artifactID: artifact.id,
          version: artifact.version,
          phase: .warming,
          completedBytes: artifact.totalSizeBytes,
          totalBytes: artifact.totalSizeBytes
        ),
        onState
      )
      let activation = try await manager.activate(
        artifactID: artifact.id,
        version: artifact.version,
        from: staging,
        healthCheck: healthCheck
      )
      try? removeCompletedStaging(staging)
      publish(
        ModelDistributionState(
          artifactID: artifact.id,
          version: artifact.version,
          phase: .ready,
          completedBytes: artifact.totalSizeBytes,
          totalBytes: artifact.totalSizeBytes
        ),
        onState
      )
      return activation
    } catch is CancellationError {
      let error = ModelDistributionError(
        .cancelled,
        code: "model-download-cancelled",
        retryable: true
      )
      publishFailure(error, artifact: artifact, onState)
      throw error
    } catch let error as ModelDistributionError {
      publishFailure(error, artifact: artifact, onState)
      throw error
    } catch let error as ModelManagerError {
      let mapped = ModelDistributionError(
        [.digestMismatch, .sizeMismatch, .invalidManifest, .unsafePath]
          .contains(error.category) ? .integrity : .fileSystem,
        code: error.code,
        retryable: error.retryable
      )
      publishFailure(mapped, artifact: artifact, onState)
      throw mapped
    } catch {
      let mapped = ModelDistributionError(
        .fileSystem,
        code: "model-distribution-failed",
        retryable: true
      )
      publishFailure(mapped, artifact: artifact, onState)
      throw mapped
    }
  }

  private func descriptor(_ artifactID: String) throws -> ManagedModelArtifact {
    guard let artifact = registry.artifact(id: artifactID) else {
      throw ModelDistributionError(
        .invalidCatalog,
        code: "model-artifact-not-registered",
        retryable: false
      )
    }
    return artifact
  }

  private func sourceURL(
    artifact: ManagedModelArtifact,
    file: ManagedModelFile
  ) throws -> URL {
    guard let base = URL(string: artifact.downloadBaseURL) else {
      throw ModelDistributionError(
        .invalidCatalog,
        code: "model-download-source-invalid",
        retryable: false
      )
    }
    let result = file.relativePath.split(separator: "/").reduce(base) {
      $0.appendingPathComponent(String($1), isDirectory: false)
    }
    guard result.scheme?.lowercased() == "https", result.host == base.host else {
      throw ModelDistributionError(
        .security,
        code: "model-download-source-escaped",
        retryable: false
      )
    }
    return result
  }

  private func stagingDirectory(for artifact: ManagedModelArtifact) -> URL {
    rootDirectory
      .appendingPathComponent(artifact.id, isDirectory: true)
      .appendingPathComponent(artifact.version, isDirectory: true)
  }

  private func loadReceipt(
    at url: URL,
    artifact: ManagedModelArtifact
  ) -> ModelDistributionReceipt {
    guard
      let data = try? Data(contentsOf: url),
      let receipt = try? JSONDecoder().decode(ModelDistributionReceipt.self, from: data),
      receipt.schemaVersion == 1,
      receipt.artifactID == artifact.id,
      receipt.version == artifact.version
    else {
      return ModelDistributionReceipt(
        schemaVersion: 1,
        artifactID: artifact.id,
        version: artifact.version,
        completedFiles: [],
        resumeDataByFile: [:]
      )
    }
    return receipt
  }

  private func repairReceipt(
    _ original: ModelDistributionReceipt,
    artifact: ManagedModelArtifact,
    staging: URL
  ) throws -> ModelDistributionReceipt {
    var receipt = original
    let declared = Set(artifact.files.map(\.relativePath))
    receipt.completedFiles.formIntersection(declared)
    receipt.resumeDataByFile = receipt.resumeDataByFile.filter {
      declared.contains($0.key) && !$0.value.isEmpty
    }
    for file in artifact.files where receipt.completedFiles.contains(file.relativePath) {
      if (try? verify(staging.appendingPathComponent(file.relativePath), expected: file)) == nil {
        receipt.completedFiles.remove(file.relativePath)
      }
    }
    return receipt
  }

  private func verify(_ url: URL, expected: ManagedModelFile) throws {
    guard
      let values = try? url.resourceValues(
        forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
      ),
      values.isRegularFile == true,
      values.isSymbolicLink != true,
      let size = values.fileSize,
      size >= 0,
      UInt64(size) == expected.sizeBytes
    else {
      throw ModelDistributionError(
        .integrity,
        code: "model-download-size-mismatch",
        retryable: true
      )
    }
    guard try LocalModelManager.sha256(of: url) == expected.sha256 else {
      throw ModelDistributionError(
        .integrity,
        code: "model-download-digest-mismatch",
        retryable: true
      )
    }
  }

  private func persist(_ receipt: ModelDistributionReceipt, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(receipt).write(to: url, options: .atomic)
  }

  private func removeCompletedStaging(_ staging: URL) throws {
    let safeRoot = rootDirectory.standardizedFileURL.path + "/"
    guard staging.standardizedFileURL.path.hasPrefix(safeRoot) else {
      throw ModelDistributionError(
        .fileSystem,
        code: "model-download-cleanup-unsafe",
        retryable: false
      )
    }
    if fileManager.fileExists(atPath: staging.path) {
      try fileManager.removeItem(at: staging)
    }
  }

  private func publish(
    _ state: ModelDistributionState,
    _ handler: StateHandler
  ) {
    stateByArtifact[state.artifactID] = state
    handler(state)
  }

  private func publishFailure(
    _ error: ModelDistributionError,
    artifact: ManagedModelArtifact,
    _ handler: StateHandler
  ) {
    publish(
      ModelDistributionState(
        artifactID: artifact.id,
        version: artifact.version,
        phase: error.retryable ? .retryableFailure : .incompatible,
        completedBytes: 0,
        totalBytes: artifact.totalSizeBytes,
        errorCode: error.code
      ),
      handler
    )
  }
}
