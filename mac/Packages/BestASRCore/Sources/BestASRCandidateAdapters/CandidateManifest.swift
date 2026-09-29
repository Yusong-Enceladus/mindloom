import BestASRInference
import Foundation

public enum CandidateAdapterKind: String, Codable, CaseIterable, Sendable {
  case fluidSenseVoice = "fluid-sensevoice"
  case sherpaOnnx = "sherpa-onnx"
  case whisperKit = "whisperkit"
}

public enum CandidateProbeScope: String, Codable, Sendable {
  case contractFixtureOnly = "contract-fixture-only"
}

public enum CandidateRuntimeNetworkPolicy: String, Codable, Sendable {
  case implicitDownloadsAllowed = "implicit-downloads-allowed"
  case modelManagerVerifiedArtifactsOnly = "model-manager-verified-artifacts-only"
}

public struct CandidateUpstreamRuntime: Codable, Equatable, Sendable {
  public let name: String
  public let exactVersion: String
  public let revision: String
  public let source: String
  public let license: String

  public init(
    name: String,
    exactVersion: String,
    revision: String,
    source: String,
    license: String
  ) {
    self.name = name
    self.exactVersion = exactVersion
    self.revision = revision
    self.source = source
    self.license = license
  }
}

public struct CandidateSupportingArtifactEvidence: Codable, Equatable, Sendable {
  public let artifactID: String
  public let revision: String
  public let treeSHA256: String
  public let fileCount: Int
  public let totalSizeBytes: UInt64
}

public struct CandidateRealModelEvidence: Codable, Equatable, Sendable {
  public let artifactID: String
  public let treeSHA256: String
  public let fileCount: Int
  public let totalSizeBytes: UInt64
  public let benchmarkResultPath: String
  public let benchmarkResultSHA256: String
  public let networkDenied: Bool
  public let executionProvider: String
  public let supportingArtifacts: [CandidateSupportingArtifactEvidence]
}

public struct CandidateAlphaEvidence: Codable, Equatable, Sendable {
  public let benchmarkResultPath: String
  public let benchmarkResultSHA256: String
  public let decisionPath: String
  public let decisionSHA256: String
  public let corpusManifestPath: String
  public let corpusManifestSHA256: String
  public let corpusManifestID: String
  public let corpusVersion: String
  public let sampleCount: Int
  public let networkDenied: Bool
}

public struct CandidateProbeArtifact: Codable, Equatable, Sendable {
  public let artifactID: String
  public let version: String
  public let relativePath: String
  public let sha256: String
  public let digestScope: CandidateProbeScope
  public let modelSource: String
  public let modelRevision: String
  public let modelLicense: String
  public let realModelArtifactStatus: String
  public let realModelEvidence: CandidateRealModelEvidence

  public init(
    artifactID: String,
    version: String,
    relativePath: String,
    sha256: String,
    digestScope: CandidateProbeScope,
    modelSource: String,
    modelRevision: String,
    modelLicense: String,
    realModelArtifactStatus: String,
    realModelEvidence: CandidateRealModelEvidence
  ) {
    self.artifactID = artifactID
    self.version = version
    self.relativePath = relativePath
    self.sha256 = sha256
    self.digestScope = digestScope
    self.modelSource = modelSource
    self.modelRevision = modelRevision
    self.modelLicense = modelLicense
    self.realModelArtifactStatus = realModelArtifactStatus
    self.realModelEvidence = realModelEvidence
  }
}

public struct ASRCandidateRecord: Codable, Equatable, Sendable {
  public let candidateID: String
  public let adapterKind: CandidateAdapterKind
  public let runtimeID: String
  public let upstreamRuntime: CandidateUpstreamRuntime
  public let probeArtifact: CandidateProbeArtifact
  public let capabilities: [String]
  public let minimumOS: InferenceOSVersion
  public let supportedArchitectures: [String]
  public let minimumUnifiedMemoryBytes: UInt64
  public let networkPolicy: CandidateRuntimeNetworkPolicy
  public let alphaDefault: Bool
  public let alphaEvidence: CandidateAlphaEvidence?
  public let releaseEligible: Bool

  public init(
    candidateID: String,
    adapterKind: CandidateAdapterKind,
    runtimeID: String,
    upstreamRuntime: CandidateUpstreamRuntime,
    probeArtifact: CandidateProbeArtifact,
    capabilities: [String],
    minimumOS: InferenceOSVersion,
    supportedArchitectures: [String],
    minimumUnifiedMemoryBytes: UInt64,
    networkPolicy: CandidateRuntimeNetworkPolicy,
    releaseEligible: Bool,
    alphaDefault: Bool = false,
    alphaEvidence: CandidateAlphaEvidence? = nil
  ) {
    self.candidateID = candidateID
    self.adapterKind = adapterKind
    self.runtimeID = runtimeID
    self.upstreamRuntime = upstreamRuntime
    self.probeArtifact = probeArtifact
    self.capabilities = capabilities
    self.minimumOS = minimumOS
    self.supportedArchitectures = supportedArchitectures
    self.minimumUnifiedMemoryBytes = minimumUnifiedMemoryBytes
    self.networkPolicy = networkPolicy
    self.alphaDefault = alphaDefault
    self.alphaEvidence = alphaEvidence
    self.releaseEligible = releaseEligible
  }

  public var modelArtifactDescriptor: ModelArtifactDescriptor {
    ModelArtifactDescriptor(
      artifactID: probeArtifact.artifactID,
      version: probeArtifact.version,
      sha256: probeArtifact.sha256,
      runtimeID: InferenceRuntimeID(runtimeID),
      capabilities: capabilities.map { InferenceCapability($0) },
      minimumOS: minimumOS,
      supportedArchitectures: supportedArchitectures,
      minimumUnifiedMemoryBytes: minimumUnifiedMemoryBytes,
      licenseIdentifier: probeArtifact.modelLicense,
      networkRequired: false,
      metadata: [
        "adapterKind": adapterKind.rawValue,
        "candidateID": candidateID,
        "digestScope": probeArtifact.digestScope.rawValue,
        "modelRevision": probeArtifact.modelRevision,
        "realModelArtifactID": probeArtifact.realModelEvidence.artifactID,
        "realModelArtifactStatus": probeArtifact.realModelArtifactStatus,
        "realModelTreeSHA256": probeArtifact.realModelEvidence.treeSHA256,
        "runtimeRevision": upstreamRuntime.revision,
        "runtimeVersion": upstreamRuntime.exactVersion,
      ]
    )
  }
}

public enum CandidateManifestError: Error, Equatable, Sendable {
  case duplicateAdapterKind(String)
  case duplicateCandidateID(String)
  case invalidCandidate(String)
  case invalidKind
  case invalidSchemaVersion(Int)
  case missingRequiredAdapter(String)
}

public struct ASRCandidateManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let selectionStatus: String
  public let candidates: [ASRCandidateRecord]

  public init(
    schemaVersion: Int,
    kind: String,
    selectionStatus: String,
    candidates: [ASRCandidateRecord]
  ) throws {
    self.schemaVersion = schemaVersion
    self.kind = kind
    self.selectionStatus = selectionStatus
    self.candidates = candidates
    try validate()
  }

  public static func decode(_ data: Data) throws -> Self {
    let decoded = try JSONDecoder().decode(Self.self, from: data)
    try decoded.validate()
    return decoded
  }

  public func validate() throws {
    guard schemaVersion == 1 else {
      throw CandidateManifestError.invalidSchemaVersion(schemaVersion)
    }
    guard kind == "asr-candidate-registry", !selectionStatus.isEmpty else {
      throw CandidateManifestError.invalidKind
    }

    var candidateIDs = Set<String>()
    var adapterKinds = Set<CandidateAdapterKind>()
    for candidate in candidates {
      guard candidateIDs.insert(candidate.candidateID).inserted else {
        throw CandidateManifestError.duplicateCandidateID(candidate.candidateID)
      }
      guard adapterKinds.insert(candidate.adapterKind).inserted else {
        throw CandidateManifestError.duplicateAdapterKind(
          candidate.adapterKind.rawValue
        )
      }
      guard Self.isValid(candidate) else {
        throw CandidateManifestError.invalidCandidate(candidate.candidateID)
      }
    }

    for required in CandidateAdapterKind.allCases where !adapterKinds.contains(required) {
      throw CandidateManifestError.missingRequiredAdapter(required.rawValue)
    }
    let alphaDefaults = candidates.filter(\.alphaDefault)
    guard selectionStatus == "alpha-default-selected-from-local-corpus",
      alphaDefaults.count == 1,
      alphaDefaults.first?.alphaEvidence != nil
    else {
      throw CandidateManifestError.invalidKind
    }
  }

  private static func isValid(_ candidate: ASRCandidateRecord) -> Bool {
    let requiredCapabilities: Set<String> = [
      InferenceCapability.asrBatch.rawValue,
      InferenceCapability.asrContextTerms.rawValue,
      InferenceCapability.asrMultilingual.rawValue,
      InferenceCapability.asrRevisioned.rawValue,
      InferenceCapability.asrStreaming.rawValue,
      InferenceCapability.asrTimestamps.rawValue,
    ]
    let digestPattern = /^[0-9a-f]{64}$/
    let revisionPattern = /^[0-9a-f]{40}$/
    let realModelEvidence = candidate.probeArtifact.realModelEvidence
    let sourceIsHTTPS =
      candidate.upstreamRuntime.source.hasPrefix("https://")
      && candidate.probeArtifact.modelSource.hasPrefix("https://")
    let alphaEvidenceValid: Bool
    if candidate.alphaDefault, let alpha = candidate.alphaEvidence {
      alphaEvidenceValid =
        safeEvidencePath(alpha.benchmarkResultPath, prefix: "artifacts/evidence/")
        && alpha.benchmarkResultSHA256.wholeMatch(of: digestPattern) != nil
        && safeEvidencePath(alpha.decisionPath, prefix: "artifacts/evidence/")
        && alpha.decisionSHA256.wholeMatch(of: digestPattern) != nil
        && safeEvidencePath(alpha.corpusManifestPath, prefix: "Corpus/")
        && alpha.corpusManifestSHA256.wholeMatch(of: digestPattern) != nil
        && !alpha.corpusManifestID.isEmpty
        && !alpha.corpusVersion.isEmpty
        && alpha.sampleCount > 0
        && alpha.networkDenied
    } else {
      alphaEvidenceValid = !candidate.alphaDefault && candidate.alphaEvidence == nil
    }

    return !candidate.candidateID.isEmpty
      && !candidate.runtimeID.isEmpty
      && !candidate.upstreamRuntime.name.isEmpty
      && !candidate.upstreamRuntime.exactVersion.isEmpty
      && candidate.upstreamRuntime.revision.wholeMatch(of: revisionPattern) != nil
      && !candidate.upstreamRuntime.license.isEmpty
      && sourceIsHTTPS
      && !candidate.probeArtifact.artifactID.isEmpty
      && !candidate.probeArtifact.version.isEmpty
      && !candidate.probeArtifact.relativePath.hasPrefix("/")
      && candidate.probeArtifact.sha256.wholeMatch(of: digestPattern) != nil
      && candidate.probeArtifact.digestScope == .contractFixtureOnly
      && !candidate.probeArtifact.modelRevision.isEmpty
      && !candidate.probeArtifact.modelLicense.isEmpty
      && candidate.probeArtifact.realModelArtifactStatus
        == "recommended-memory-smoke-complete-release-matrix-pending"
      && !realModelEvidence.artifactID.isEmpty
      && realModelEvidence.treeSHA256.wholeMatch(of: digestPattern) != nil
      && realModelEvidence.fileCount > 0
      && realModelEvidence.totalSizeBytes > 0
      && realModelEvidence.benchmarkResultPath
        .hasPrefix("artifacts/evidence/SPIKE-ASR-001/")
      && !realModelEvidence.benchmarkResultPath.hasPrefix("/")
      && realModelEvidence.benchmarkResultSHA256
        .wholeMatch(of: digestPattern) != nil
      && realModelEvidence.networkDenied
      && !realModelEvidence.executionProvider.isEmpty
      && realModelEvidence.supportingArtifacts.allSatisfy {
        !$0.artifactID.isEmpty
          && !$0.revision.isEmpty
          && $0.treeSHA256.wholeMatch(of: digestPattern) != nil
          && $0.fileCount > 0
          && $0.totalSizeBytes > 0
      }
      && requiredCapabilities.isSubset(of: Set(candidate.capabilities))
      && candidate.supportedArchitectures.contains("arm64")
      && candidate.minimumUnifiedMemoryBytes >= 16 * 1_024 * 1_024 * 1_024
      && candidate.networkPolicy == .modelManagerVerifiedArtifactsOnly
      && alphaEvidenceValid
      && !candidate.releaseEligible
  }

  private static func safeEvidencePath(_ path: String, prefix: String) -> Bool {
    path.hasPrefix(prefix)
      && !path.hasPrefix("/")
      && !path.split(separator: "/", omittingEmptySubsequences: false)
        .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
  }
}
