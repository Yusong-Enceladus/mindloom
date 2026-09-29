import BestASRInference

public enum QwenASRPinnedArtifact {
  public static let candidateID = "qwen3-asr-aligned-final"
  public static let artifactID = "qwen3-asr-1.7b-8bit-a8379a2e"
  public static let sourceRevision = "a8379a2e2f9e313c9292cdf1af4055ab56d50d55"
  public static let treeSHA256 = "78e581bde728363d93dc3afc5e3b2bceae0acc2ee65805bb94d9f61e43a3edd1"
  public static let runtimeRevision = "cae704f53bc32a3d0b606823828fbc5bedaaf388"
  public static let pipelineRevision = "qwen-native-final-v2-digital-silence-natural-phrases"
  public static let totalSizeBytes: UInt64 = 2_467_857_511
  public static let maximumSamples = 30 * 16_000

  public static let descriptor = ModelArtifactDescriptor(
    artifactID: artifactID, version: sourceRevision, sha256: treeSHA256,
    runtimeID: InferenceRuntimeID("mlx-audio.qwen3-asr"),
    capabilities: [.asrBatch, .asrMultilingual, .asrRevisioned, .asrTimestamps],
    minimumOS: InferenceOSVersion(major: 14, minor: 2),
    supportedArchitectures: ["arm64"], minimumUnifiedMemoryBytes: 17_179_869_184,
    licenseIdentifier: "Apache-2.0", networkRequired: false,
    metadata: [
      "runtimeRevision": runtimeRevision,
      "pipelineRevision": pipelineRevision,
      "sourceRevision": sourceRevision,
      "alignmentArtifactID": QwenAlignmentPinnedArtifact.artifactID,
      "alignmentRevision": QwenAlignmentPinnedArtifact.sourceRevision,
      "alignmentTreeSHA256": QwenAlignmentPinnedArtifact.treeSHA256,
      "alignmentQuantizationMilliseconds": "80",
      "selectionScope": "local-tuning-integration; release-holdout-and-minimum-device-pending",
    ]
  )
}

public enum QwenAlignmentPinnedArtifact {
  public static let artifactID = "qwen3-forced-aligner-0.6b-8bit-0e1a68e9"
  public static let sourceRevision = "0e1a68e91d815300c7c9754b2a7639378b23db15"
  public static let treeSHA256 = "8826e6c77a767e8370966e821357f96167fec399b67c829ae1c5efb9185d374e"
  public static let totalSizeBytes: UInt64 = 1_276_474_460
  public static let quantizationSeconds = 0.08
}
