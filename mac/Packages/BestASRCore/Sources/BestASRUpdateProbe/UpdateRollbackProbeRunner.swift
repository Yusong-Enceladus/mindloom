import BestASRModelManagerProbe
import CryptoKit
import Foundation

public struct UpdateRollbackScenario: Codable, Equatable, Sendable {
  public let scenarioID: String
  public let status: String
  public let expectedFailure: String?
  public let observedFailure: String?
  public let appVersionBefore: String?
  public let appVersionAfter: String?
  public let modelVersionBefore: String?
  public let modelVersionAfter: String?
  public let appAndModelNamespacesSeparated: Bool
  public let userDataUnchanged: Bool
  public let sourceAudioPreserved: Bool
  public let stagingRemoved: Bool
}

public struct UpdateRollbackProbeReport: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let runID: UUID
  public let signingAlgorithm: String
  public let appPublicKeySHA256: String
  public let modelPublicKeySHA256: String
  public let scenarios: [UpdateRollbackScenario]
  public let finalAppVersion: String?
  public let finalModelVersion: String?
  public let sourceAudioPreserved: Bool
  public let userDataUnchanged: Bool
  public let conclusion: String
}

public enum UpdateRollbackProbeRunner {
  public static func run(summaryURL: URL) throws -> UpdateRollbackProbeReport {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-update-probe-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let appRoot = root.appendingPathComponent("app-store", isDirectory: true)
    let modelRoot = root.appendingPathComponent("model-store", isDirectory: true)
    let userDataRoot = root.appendingPathComponent("user-data", isDirectory: true)
    let sourceRoot = root.appendingPathComponent("sources", isDirectory: true)
    try FileManager.default.createDirectory(
      at: userDataRoot.appendingPathComponent("audio", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: sourceRoot,
      withIntermediateDirectories: true
    )
    try Data("opaque-history-fixture".utf8).write(
      to: userDataRoot.appendingPathComponent("history.store")
    )
    let sourceAudioURL =
      userDataRoot
      .appendingPathComponent("audio", isDirectory: true)
      .appendingPathComponent("session.pcm")
    try Data((0..<512).map { UInt8($0 % 251) }).write(to: sourceAudioURL)

    let appPrivateKey = try Curve25519.Signing.PrivateKey(
      rawRepresentation: Data((1...32).map(UInt8.init))
    )
    let modelPrivateKey = try Curve25519.Signing.PrivateKey(
      rawRepresentation: Data((33...64).map(UInt8.init))
    )
    let appKeyID = "app-update-fixture-v1"
    let modelKeyID = "model-update-fixture-v1"
    let appManager = AppUpdateManager(
      root: appRoot,
      trustedSigningKeys: [
        appKeyID: appPrivateKey.publicKey.rawRepresentation
      ]
    )
    let modelManager = ModelManagerProbe(root: modelRoot)
    let modelVerifier = ModelUpdateSignatureVerifier(
      trustedSigningKeys: [
        modelKeyID: modelPrivateKey.publicKey.rawRepresentation
      ]
    )

    let app100 = try writeSource(
      Data("signed app package 1.0.0".utf8),
      named: "app-1.0.0.pkg",
      under: sourceRoot
    )
    let app100Manifest = try signedAppManifest(
      version: "1.0.0",
      packageURL: app100,
      keyID: appKeyID,
      privateKey: appPrivateKey
    )
    let seededApp = appManager.stageVerifyAndActivate(
      manifest: app100Manifest,
      packageURL: app100
    )
    guard seededApp.status == .pass else {
      throw AppUpdateFailureCategory.fileSystem
    }

    let model100Source = try modelSource(
      bytes: Data("model weights 1.0.0".utf8),
      named: "model-1.0.0",
      under: sourceRoot
    )
    let model100Descriptor = try modelDescriptor(
      version: "1.0.0",
      source: model100Source
    )
    let model100Envelope = try signedModelEnvelope(
      descriptor: model100Descriptor,
      keyID: modelKeyID,
      privateKey: modelPrivateKey
    )
    try modelVerifier.verify(model100Envelope)
    let seededModel = modelManager.stageVerifyAndActivate(
      descriptor: model100Descriptor,
      sourceDirectory: model100Source,
      healthCheck: PassingModelHealthCheck()
    )
    guard seededModel.status == .pass else {
      throw ModelActivationFailureCategory.fileSystem
    }

    let baselineUserDataDigest = try directoryDigest(userDataRoot)
    let baselineSourceAudioDigest = try AppUpdateManager.sha256(of: sourceAudioURL)
    var scenarios: [UpdateRollbackScenario] = []

    let app110 = try writeSource(
      Data("signed app package 1.1.0".utf8),
      named: "app-1.1.0.pkg",
      under: sourceRoot
    )
    let app110Manifest = try signedAppManifest(
      version: "1.1.0",
      packageURL: app110,
      keyID: appKeyID,
      privateKey: appPrivateKey
    )
    let beforeApp110 = try appManager.activeVersion()
    let beforeModel110 = try modelManager.activeVersion(for: "fixture-model")
    let app110Attempt = appManager.stageVerifyAndActivate(
      manifest: app110Manifest,
      packageURL: app110
    )
    scenarios.append(
      try scenario(
        id: "signed-app-update-activates-with-last-known-good-retained",
        expectedFailure: nil,
        observedFailure: app110Attempt.failureCategory?.rawValue,
        appBefore: beforeApp110,
        appAfter: appManager.activeVersion(),
        modelBefore: beforeModel110,
        modelAfter: modelManager.activeVersion(for: "fixture-model"),
        baselineUserDataDigest: baselineUserDataDigest,
        currentUserDataDigest: directoryDigest(userDataRoot),
        baselineSourceAudioDigest: baselineSourceAudioDigest,
        currentSourceAudioDigest: AppUpdateManager.sha256(of: sourceAudioURL),
        stagingRemoved: app110Attempt.stagingRemoved,
        additionalPass: app110Attempt.status == .pass
          && FileManager.default.fileExists(
            atPath: appRoot.appendingPathComponent("versions/1.0.0").path
          )
      )
    )

    let app120 = try writeSource(
      Data("signed app package 1.2.0".utf8),
      named: "app-1.2.0.pkg",
      under: sourceRoot
    )
    let app120Manifest = try signedAppManifest(
      version: "1.2.0",
      packageURL: app120,
      keyID: appKeyID,
      privateKey: appPrivateKey
    )
    let badAppSignature = app120Manifest.replacingSignature(
      Data(repeating: 0, count: 64).base64EncodedString()
    )
    scenarios.append(
      try appFailureScenario(
        id: "tampered-app-signature-is-rejected",
        expected: .signatureMismatch,
        manager: appManager,
        modelManager: modelManager,
        manifest: badAppSignature,
        packageURL: app120,
        baselineUserDataDigest: baselineUserDataDigest,
        userDataRoot: userDataRoot,
        baselineSourceAudioDigest: baselineSourceAudioDigest,
        sourceAudioURL: sourceAudioURL
      )
    )
    scenarios.append(
      try appFailureScenario(
        id: "interrupted-app-download-preserves-active-version",
        expected: .interruptedDownload,
        manager: appManager,
        modelManager: modelManager,
        manifest: app120Manifest,
        packageURL: app120,
        faultPoint: .afterPartialStaging,
        baselineUserDataDigest: baselineUserDataDigest,
        userDataRoot: userDataRoot,
        baselineSourceAudioDigest: baselineSourceAudioDigest,
        sourceAudioURL: sourceAudioURL
      )
    )

    let app090 = try writeSource(
      Data("signed app package 0.9.0".utf8),
      named: "app-0.9.0.pkg",
      under: sourceRoot
    )
    let app090Manifest = try signedAppManifest(
      version: "0.9.0",
      packageURL: app090,
      keyID: appKeyID,
      privateKey: appPrivateKey
    )
    scenarios.append(
      try appFailureScenario(
        id: "app-version-downgrade-is-rejected",
        expected: .downgradeRejected,
        manager: appManager,
        modelManager: modelManager,
        manifest: app090Manifest,
        packageURL: app090,
        baselineUserDataDigest: baselineUserDataDigest,
        userDataRoot: userDataRoot,
        baselineSourceAudioDigest: baselineSourceAudioDigest,
        sourceAudioURL: sourceAudioURL
      )
    )
    scenarios.append(
      try appFailureScenario(
        id: "app-health-check-failure-rolls-back",
        expected: .healthCheckFailed,
        manager: appManager,
        modelManager: modelManager,
        manifest: app120Manifest,
        packageURL: app120,
        healthCheck: FailingAppUpdateHealthCheck(),
        baselineUserDataDigest: baselineUserDataDigest,
        userDataRoot: userDataRoot,
        baselineSourceAudioDigest: baselineSourceAudioDigest,
        sourceAudioURL: sourceAudioURL
      )
    )

    let model200Source = try modelSource(
      bytes: Data("model weights 2.0.0".utf8),
      named: "model-2.0.0",
      under: sourceRoot
    )
    let model200Descriptor = try modelDescriptor(
      version: "2.0.0",
      source: model200Source
    )
    let model200Envelope = try signedModelEnvelope(
      descriptor: model200Descriptor,
      keyID: modelKeyID,
      privateKey: modelPrivateKey
    )
    let badModelEnvelope = model200Envelope.replacingSignature(
      Data(repeating: 0, count: 64).base64EncodedString()
    )
    let beforeModelSignatureApp = try appManager.activeVersion()
    let beforeModelSignature = try modelManager.activeVersion(for: "fixture-model")
    var observedModelSignatureFailure: String?
    do {
      try modelVerifier.verify(badModelEnvelope)
    } catch let error as ModelUpdateEnvelopeError {
      observedModelSignatureFailure = error.rawValue
    }
    scenarios.append(
      try scenario(
        id: "tampered-model-signature-is-rejected-before-staging",
        expectedFailure: ModelUpdateEnvelopeError.signatureMismatch.rawValue,
        observedFailure: observedModelSignatureFailure,
        appBefore: beforeModelSignatureApp,
        appAfter: appManager.activeVersion(),
        modelBefore: beforeModelSignature,
        modelAfter: modelManager.activeVersion(for: "fixture-model"),
        baselineUserDataDigest: baselineUserDataDigest,
        currentUserDataDigest: directoryDigest(userDataRoot),
        baselineSourceAudioDigest: baselineSourceAudioDigest,
        currentSourceAudioDigest: AppUpdateManager.sha256(of: sourceAudioURL),
        stagingRemoved: true,
        additionalPass: observedModelSignatureFailure
          == ModelUpdateEnvelopeError.signatureMismatch.rawValue
      )
    )

    let validModelFile = model200Descriptor.files[0]
    let digestMismatchDescriptor = ModelArtifactDescriptor(
      artifactID: model200Descriptor.artifactID,
      version: model200Descriptor.version,
      files: [
        ModelFileDescriptor(
          relativePath: validModelFile.relativePath,
          sizeBytes: validModelFile.sizeBytes,
          sha256: String(repeating: "f", count: 64)
        )
      ]
    )
    scenarios.append(
      try modelFailureScenario(
        id: "model-digest-tamper-preserves-app-data-and-model",
        expected: .digestMismatch,
        appManager: appManager,
        modelManager: modelManager,
        descriptor: digestMismatchDescriptor,
        sourceDirectory: model200Source,
        baselineUserDataDigest: baselineUserDataDigest,
        userDataRoot: userDataRoot,
        baselineSourceAudioDigest: baselineSourceAudioDigest,
        sourceAudioURL: sourceAudioURL
      )
    )

    let partialDescriptor = ModelArtifactDescriptor(
      artifactID: "fixture-model",
      version: "2.0.0",
      files: [
        validModelFile,
        ModelFileDescriptor(
          relativePath: "missing.bin",
          sizeBytes: 10,
          sha256: String(repeating: "0", count: 64)
        ),
      ]
    )
    scenarios.append(
      try modelFailureScenario(
        id: "interrupted-model-download-preserves-app-data-and-model",
        expected: .partialDownload,
        appManager: appManager,
        modelManager: modelManager,
        descriptor: partialDescriptor,
        sourceDirectory: model200Source,
        baselineUserDataDigest: baselineUserDataDigest,
        userDataRoot: userDataRoot,
        baselineSourceAudioDigest: baselineSourceAudioDigest,
        sourceAudioURL: sourceAudioURL
      )
    )

    let model090Descriptor = try modelDescriptor(
      version: "0.9.0",
      source: model200Source
    )
    scenarios.append(
      try modelFailureScenario(
        id: "model-version-downgrade-is-rejected",
        expected: .downgradeRejected,
        appManager: appManager,
        modelManager: modelManager,
        descriptor: model090Descriptor,
        sourceDirectory: model200Source,
        baselineUserDataDigest: baselineUserDataDigest,
        userDataRoot: userDataRoot,
        baselineSourceAudioDigest: baselineSourceAudioDigest,
        sourceAudioURL: sourceAudioURL
      )
    )

    try modelVerifier.verify(model200Envelope)
    let beforeModelSuccessApp = try appManager.activeVersion()
    let beforeModelSuccess = try modelManager.activeVersion(for: "fixture-model")
    let model200Attempt = modelManager.stageVerifyAndActivate(
      descriptor: model200Descriptor,
      sourceDirectory: model200Source,
      healthCheck: PassingModelHealthCheck()
    )
    scenarios.append(
      try scenario(
        id: "signed-model-update-activates-with-app-and-data-unchanged",
        expectedFailure: nil,
        observedFailure: model200Attempt.failureCategory?.rawValue,
        appBefore: beforeModelSuccessApp,
        appAfter: appManager.activeVersion(),
        modelBefore: beforeModelSuccess,
        modelAfter: modelManager.activeVersion(for: "fixture-model"),
        baselineUserDataDigest: baselineUserDataDigest,
        currentUserDataDigest: directoryDigest(userDataRoot),
        baselineSourceAudioDigest: baselineSourceAudioDigest,
        currentSourceAudioDigest: AppUpdateManager.sha256(of: sourceAudioURL),
        stagingRemoved: model200Attempt.stagingRemoved,
        additionalPass: model200Attempt.status == .pass
          && FileManager.default.fileExists(
            atPath: modelRoot.appendingPathComponent(
              "versions/fixture-model/1.0.0"
            ).path
          )
      )
    )

    let finalUserDataDigest = try directoryDigest(userDataRoot)
    let finalSourceAudioDigest = try AppUpdateManager.sha256(of: sourceAudioURL)
    let conclusion =
      scenarios.allSatisfy { $0.status == "pass" }
        && finalUserDataDigest == baselineUserDataDigest
        && finalSourceAudioDigest == baselineSourceAudioDigest
      ? "pass" : "fail"
    let report = UpdateRollbackProbeReport(
      schemaVersion: 1,
      kind: "update-rollback-summary",
      runID: UUID(uuidString: "6b000000-0000-4000-8000-000000000001")!,
      signingAlgorithm: "Ed25519",
      appPublicKeySHA256: AppUpdateManager.sha256(
        appPrivateKey.publicKey.rawRepresentation
      ),
      modelPublicKeySHA256: AppUpdateManager.sha256(
        modelPrivateKey.publicKey.rawRepresentation
      ),
      scenarios: scenarios,
      finalAppVersion: try appManager.activeVersion(),
      finalModelVersion: try modelManager.activeVersion(for: "fixture-model"),
      sourceAudioPreserved: finalSourceAudioDigest == baselineSourceAudioDigest,
      userDataUnchanged: finalUserDataDigest == baselineUserDataDigest,
      conclusion: conclusion
    )
    try write(report, to: summaryURL)
    return report
  }

  private static func appFailureScenario(
    id: String,
    expected: AppUpdateFailureCategory,
    manager: AppUpdateManager,
    modelManager: ModelManagerProbe,
    manifest: AppUpdateManifest,
    packageURL: URL,
    faultPoint: AppUpdateFaultPoint = .none,
    healthCheck: any AppUpdateHealthChecking = PassingAppUpdateHealthCheck(),
    baselineUserDataDigest: String,
    userDataRoot: URL,
    baselineSourceAudioDigest: String,
    sourceAudioURL: URL
  ) throws -> UpdateRollbackScenario {
    let appBefore = try manager.activeVersion()
    let modelBefore = try modelManager.activeVersion(for: "fixture-model")
    let attempt = manager.stageVerifyAndActivate(
      manifest: manifest,
      packageURL: packageURL,
      faultPoint: faultPoint,
      healthCheck: healthCheck
    )
    return try scenario(
      id: id,
      expectedFailure: expected.rawValue,
      observedFailure: attempt.failureCategory?.rawValue,
      appBefore: appBefore,
      appAfter: manager.activeVersion(),
      modelBefore: modelBefore,
      modelAfter: modelManager.activeVersion(for: "fixture-model"),
      baselineUserDataDigest: baselineUserDataDigest,
      currentUserDataDigest: directoryDigest(userDataRoot),
      baselineSourceAudioDigest: baselineSourceAudioDigest,
      currentSourceAudioDigest: AppUpdateManager.sha256(of: sourceAudioURL),
      stagingRemoved: attempt.stagingRemoved,
      additionalPass: attempt.status == .fail
        && attempt.lastKnownGoodPreserved
    )
  }

  private static func modelFailureScenario(
    id: String,
    expected: ModelActivationFailureCategory,
    appManager: AppUpdateManager,
    modelManager: ModelManagerProbe,
    descriptor: ModelArtifactDescriptor,
    sourceDirectory: URL,
    baselineUserDataDigest: String,
    userDataRoot: URL,
    baselineSourceAudioDigest: String,
    sourceAudioURL: URL
  ) throws -> UpdateRollbackScenario {
    let appBefore = try appManager.activeVersion()
    let modelBefore = try modelManager.activeVersion(for: "fixture-model")
    let attempt = modelManager.stageVerifyAndActivate(
      descriptor: descriptor,
      sourceDirectory: sourceDirectory,
      healthCheck: PassingModelHealthCheck()
    )
    return try scenario(
      id: id,
      expectedFailure: expected.rawValue,
      observedFailure: attempt.failureCategory?.rawValue,
      appBefore: appBefore,
      appAfter: appManager.activeVersion(),
      modelBefore: modelBefore,
      modelAfter: modelManager.activeVersion(for: "fixture-model"),
      baselineUserDataDigest: baselineUserDataDigest,
      currentUserDataDigest: directoryDigest(userDataRoot),
      baselineSourceAudioDigest: baselineSourceAudioDigest,
      currentSourceAudioDigest: AppUpdateManager.sha256(of: sourceAudioURL),
      stagingRemoved: attempt.stagingRemoved,
      additionalPass: attempt.status == .fail
        && attempt.lastKnownGoodPreserved
    )
  }

  private static func scenario(
    id: String,
    expectedFailure: String?,
    observedFailure: String?,
    appBefore: String?,
    appAfter: String?,
    modelBefore: String?,
    modelAfter: String?,
    baselineUserDataDigest: String,
    currentUserDataDigest: String,
    baselineSourceAudioDigest: String,
    currentSourceAudioDigest: String,
    stagingRemoved: Bool,
    additionalPass: Bool
  ) throws -> UpdateRollbackScenario {
    let dataUnchanged = baselineUserDataDigest == currentUserDataDigest
    let sourceAudioPreserved =
      baselineSourceAudioDigest
      == currentSourceAudioDigest
    let namespacesSeparated = appBefore == appAfter || modelBefore == modelAfter
    let passes =
      expectedFailure == observedFailure
      && dataUnchanged
      && sourceAudioPreserved
      && namespacesSeparated
      && stagingRemoved
      && additionalPass
    return UpdateRollbackScenario(
      scenarioID: id,
      status: passes ? "pass" : "fail",
      expectedFailure: expectedFailure,
      observedFailure: observedFailure,
      appVersionBefore: appBefore,
      appVersionAfter: appAfter,
      modelVersionBefore: modelBefore,
      modelVersionAfter: modelAfter,
      appAndModelNamespacesSeparated: namespacesSeparated,
      userDataUnchanged: dataUnchanged,
      sourceAudioPreserved: sourceAudioPreserved,
      stagingRemoved: stagingRemoved
    )
  }

  private static func signedAppManifest(
    version: String,
    packageURL: URL,
    keyID: String,
    privateKey: Curve25519.Signing.PrivateKey
  ) throws -> AppUpdateManifest {
    let data = try Data(contentsOf: packageURL)
    let unsigned = AppUpdateManifest(
      version: version,
      minimumOS: "14.2.0",
      packageSizeBytes: data.count,
      packageSHA256: AppUpdateManager.sha256(data),
      signingKeyID: keyID,
      signatureBase64: Data().base64EncodedString()
    )
    let signature = try privateKey.signature(for: unsigned.signingPayload)
    return unsigned.replacingSignature(signature.base64EncodedString())
  }

  private static func signedModelEnvelope(
    descriptor: ModelArtifactDescriptor,
    keyID: String,
    privateKey: Curve25519.Signing.PrivateKey
  ) throws -> SignedModelUpdateEnvelope {
    let unsigned = SignedModelUpdateEnvelope(
      descriptor: descriptor,
      signingKeyID: keyID,
      signatureBase64: Data().base64EncodedString()
    )
    let signature = try privateKey.signature(for: unsigned.signingPayload)
    return unsigned.replacingSignature(signature.base64EncodedString())
  }

  private static func modelDescriptor(
    version: String,
    source: URL
  ) throws -> ModelArtifactDescriptor {
    let file = source.appendingPathComponent("weights.bin")
    let data = try Data(contentsOf: file)
    return ModelArtifactDescriptor(
      artifactID: "fixture-model",
      version: version,
      files: [
        ModelFileDescriptor(
          relativePath: "weights.bin",
          sizeBytes: data.count,
          sha256: AppUpdateManager.sha256(data)
        )
      ]
    )
  }

  private static func modelSource(
    bytes: Data,
    named name: String,
    under root: URL
  ) throws -> URL {
    let directory = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try bytes.write(to: directory.appendingPathComponent("weights.bin"))
    return directory
  }

  private static func writeSource(
    _ data: Data,
    named name: String,
    under root: URL
  ) throws -> URL {
    let url = root.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  private static func directoryDigest(_ root: URL) throws -> String {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      throw AppUpdateFailureCategory.fileSystem
    }
    let files = enumerator.compactMap { $0 as? URL }
      .filter {
        (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile)
          == true
      }
      .sorted { $0.path < $1.path }
    var hasher = SHA256()
    for file in files {
      let relative = file.path.replacingOccurrences(
        of: root.path + "/",
        with: ""
      )
      hasher.update(data: Data(relative.utf8))
      hasher.update(data: try Data(contentsOf: file))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func write<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    try data.write(to: url, options: .atomic)
  }
}
