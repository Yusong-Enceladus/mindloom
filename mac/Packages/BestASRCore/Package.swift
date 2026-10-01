// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "BestASRCore",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "BestASRCore", targets: ["BestASRCore"]),
    .library(name: "BestASRInference", targets: ["BestASRInference"]),
    .library(name: "BestASRDictation", targets: ["BestASRDictation"]),
    .library(name: "BestASRPersistence", targets: ["BestASRPersistence"]),
    .library(name: "BestASRAudioJournal", targets: ["BestASRAudioJournal"]),
    .library(name: "BestASRAudio", targets: ["BestASRAudio"]),
    .library(name: "BestASRMacAudio", targets: ["BestASRMacAudio"]),
    .library(name: "BestASRDelivery", targets: ["BestASRDelivery"]),
    .library(
      name: "BestASRMacPermissions",
      targets: ["BestASRMacPermissions"]
    ),
    .library(name: "BestASRMacUI", targets: ["BestASRMacUI"]),
    .library(name: "BestASRProcessing", targets: ["BestASRProcessing"]),
    .library(name: "BestASRRecognition", targets: ["BestASRRecognition"]),
    .library(
      name: "BestASRDictationFixtures",
      targets: ["BestASRDictationFixtures"]
    ),
    .library(
      name: "BestASRCandidateAdapters",
      targets: ["BestASRCandidateAdapters"]
    ),
    .library(
      name: "BestASRFluidRuntime",
      targets: ["BestASRFluidRuntime"]
    ),
    .library(name: "BestASRQwenRuntime", targets: ["BestASRQwenRuntime"]),
    .library(
      name: "BestASRModelManager",
      targets: ["BestASRModelManager"]
    ),
    .library(
      name: "BestASRAlphaEvaluation",
      targets: ["BestASRAlphaEvaluation"]
    ),
    .library(name: "BestASRBenchmark", targets: ["BestASRBenchmark"]),
    .library(
      name: "BestASRSpeakerEvidence",
      targets: ["BestASRSpeakerEvidence"]
    ),
    .library(
      name: "BestASRSpeakerReleaseEvaluation",
      targets: ["BestASRSpeakerReleaseEvaluation"]
    ),
    .library(name: "BestASREvidence", targets: ["BestASREvidence"]),
    .library(
      name: "BestASRModelManagerProbe",
      targets: ["BestASRModelManagerProbe"]
    ),
    .library(
      name: "BestASRUpdateProbe",
      targets: ["BestASRUpdateProbe"]
    ),
    .executable(
      name: "ModelManagerProbeCLI",
      targets: ["ModelManagerProbeCLI"]
    ),
    .library(
      name: "BestASROfflineProbe",
      targets: ["BestASROfflineProbe"]
    ),
    .library(name: "BestASRDomain", targets: ["BestASRDomain"]),
    .library(
      name: "BestASRRemoteOrganizer",
      targets: ["BestASRRemoteOrganizer"]
    ),
    .library(name: "BestASRIntake", targets: ["BestASRIntake"]),
    .library(name: "BestASRAgentAccess", targets: ["BestASRAgentAccess"]),
    .library(name: "MindloomAgentProtocol", targets: ["MindloomAgentProtocol"]),
    // The MCP helper bundled in the App (Contents/Helpers/mindloom-mcp) and a
    // synthetic-root harness for its end-to-end test (AGENT-CONTRACT §1, §4).
    .executable(name: "mindloom-mcp", targets: ["MindloomMCPHelper"]),
    .executable(name: "MindloomAgentTestHost", targets: ["MindloomAgentTestHost"]),
    .library(name: "BestASRMemory", targets: ["BestASRMemory"]),
    .library(name: "BestASRMemoryUI", targets: ["BestASRMemoryUI"]),
    .library(
      name: "BestASRSpeakerRouting",
      targets: ["BestASRSpeakerRouting"]
    ),
    .library(name: "BestASRLocalText", targets: ["BestASRLocalText"]),
    .library(
      name: "BestASRMLXRuntime",
      targets: ["BestASRMLXRuntime"]
    ),
    .library(
      name: "BestASRResourcePolicyProbe",
      targets: ["BestASRResourcePolicyProbe"]
    ),
    .library(
      name: "BestASRPersistenceProbe",
      targets: ["BestASRPersistenceProbe"]
    ),
    .executable(
      name: "PersistenceMigrationProbeCLI",
      targets: ["PersistenceMigrationProbeCLI"]
    ),
    .library(
      name: "BestASRMigrationProbe",
      targets: ["BestASRMigrationProbe"]
    ),
    .executable(
      name: "CrossRootMigrationProbeCLI",
      targets: ["CrossRootMigrationProbeCLI"]
    ),
    .library(
      name: "BestASRSecurityEnvelopeProbe",
      targets: ["BestASRSecurityEnvelopeProbe"]
    ),
    .library(
      name: "BestASRPortableArchiveProbe",
      targets: ["BestASRPortableArchiveProbe"]
    ),
    .library(
      name: "BestASRProcessTapProbe",
      targets: ["BestASRProcessTapProbe"]
    ),
    .library(
      name: "BestASRAudioTimelineProbe",
      targets: ["BestASRAudioTimelineProbe"]
    ),
    .library(
      name: "BestASRAudioJournalProbe",
      targets: ["BestASRAudioJournalProbe"]
    ),
    .library(
      name: "BestASRLongRecordingProbe",
      targets: ["BestASRLongRecordingProbe"]
    ),
    .library(
      name: "BestASRInferenceQueueProbe",
      targets: ["BestASRInferenceQueueProbe"]
    ),
    .library(
      name: "BestASRInferenceXPCProtocol",
      targets: ["BestASRInferenceXPCProtocol"]
    ),
    .executable(
      name: "PortableMigrationProbeCLI",
      targets: ["PortableMigrationProbeCLI"]
    ),
    .executable(
      name: "OfflineSmokeSuiteCLI",
      targets: ["OfflineSmokeSuiteCLI"]
    ),
    .executable(
      name: "AudioTimelineProbeCLI",
      targets: ["AudioTimelineProbeCLI"]
    ),
    .executable(
      name: "AudioJournalProbeCLI",
      targets: ["AudioJournalProbeCLI"]
    ),
    .executable(
      name: "LongRecordingProbeCLI",
      targets: ["LongRecordingProbeCLI"]
    ),
    .executable(
      name: "InferenceQueueProbeCLI",
      targets: ["InferenceQueueProbeCLI"]
    ),
    .executable(
      name: "CandidateAdapterProbeCLI",
      targets: ["CandidateAdapterProbeCLI"]
    ),
    .executable(
      name: "LLMFactualGateProbeCLI",
      targets: ["LLMFactualGateProbeCLI"]
    ),
    .executable(
      name: "SpeakerEvidenceCollatorCLI",
      targets: ["SpeakerEvidenceCollatorCLI"]
    ),
    .executable(
      name: "SpeakerIdentityEvaluatorCLI",
      targets: ["SpeakerIdentityEvaluatorCLI"]
    ),
    .executable(
      name: "PublicSpeakerEvalCLI",
      targets: ["PublicSpeakerEvalCLI"]
    ),
    .executable(
      name: "ResourcePolicyProbeCLI",
      targets: ["ResourcePolicyProbeCLI"]
    ),
    .executable(
      name: "UpdateRollbackProbeCLI",
      targets: ["UpdateRollbackProbeCLI"]
    ),
    .executable(
      name: "AXInsertionFixture",
      targets: ["AXInsertionFixture"]
    ),
    .executable(
      name: "PasteProbeCLI",
      targets: ["PasteProbeCLI"]
    ),
    .executable(
      name: "MicrophoneCaptureSmokeCLI",
      targets: ["MicrophoneCaptureSmokeCLI"]
    ),
    .executable(
      name: "DictationFixtureHarnessCLI",
      targets: ["DictationFixtureHarnessCLI"]
    ),
    .executable(
      name: "AlphaASREvalCLI",
      targets: ["AlphaASREvalCLI"]
    ),
    .executable(
      name: "InstalledModelDictationProbeCLI",
      targets: ["InstalledModelDictationProbeCLI"]
    ),
    .executable(
      name: "LocalTextModelProbeCLI",
      targets: ["LocalTextModelProbeCLI"]
    ),
    .executable(
      name: "SpokenModeProbeCLI",
      targets: ["SpokenModeProbeCLI"]
    ),
    .executable(
      name: "SpeakerRelinkCLI",
      targets: ["SpeakerRelinkCLI"]
    ),
    .executable(
      name: "SourceAudioCompactionCLI",
      targets: ["SourceAudioCompactionCLI"]
    ),
    .executable(
      name: "DictationEvalCLI",
      targets: ["DictationEvalCLI"]
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/groue/GRDB.swift.git",
      exact: "7.10.0"
    ),
    .package(
      url: "https://github.com/FluidInference/FluidAudio.git",
      revision: "19600a485baa4998812e4654b70d2bab8f2c9949"
    ),
    // Keep the transitive MLX runtime exact instead of accepting the
    // upstream package's up-to-next-minor range.
    .package(
      url: "https://github.com/ml-explore/mlx-swift.git",
      exact: "0.31.3"
    ),
    .package(
      url: "https://github.com/ml-explore/mlx-swift-lm.git",
      exact: "3.31.3"
    ),
    .package(
      url: "https://github.com/huggingface/swift-transformers.git",
      exact: "1.3.3"
    ),
    // Developer evaluation only; no production target links this SDK.
    .package(
      url: "https://github.com/argmaxinc/argmax-oss-swift.git",
      revision: "25c62997041c134b03ca82731ce2f6fd2cae1eb9"
    ),
    .package(
      url: "https://github.com/Blaizzy/mlx-audio-swift.git",
      revision: "cae704f53bc32a3d0b606823828fbc5bedaaf388"
    ),
    // In-repo, CryptoKit + Foundation only: the phone's sealed inbox entries
    // (`mlseal1`) and the pairing payload (`mlpair1`), shared with the iPhone
    // app (PHONE-CONTRACT §3–§4, ADR-0007).
    .package(path: "../MindloomLink"),
  ],
  targets: [
    .target(name: "BestASRCore"),
    .target(name: "BestASRInference"),
    .target(
      name: "BestASRDictation",
      dependencies: ["BestASRDomain", "BestASRInference"]
    ),
    .target(
      name: "BestASRPersistence",
      dependencies: [
        "BestASRDictation",
        "BestASRDomain",
        "BestASRInference",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .target(
      name: "BestASRAudioJournal",
      dependencies: [
        "BestASRAudio",
        "BestASRAudioJournalProbe",
        "BestASRDictation",
        "BestASRDomain",
        "BestASRInference",
      ]
    ),
    .target(
      name: "BestASRAudio",
      dependencies: ["BestASRDictation"]
    ),
    .target(
      name: "BestASRMacAudio",
      dependencies: [
        "BestASRDictation",
        "BestASRDomain",
        "BestASRProcessTapProbe",
      ],
      linkerSettings: [
        .linkedFramework("AVFoundation"),
        .linkedFramework("CoreAudio"),
      ]
    ),
    .target(
      name: "BestASRDelivery",
      dependencies: ["BestASRDictation"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ApplicationServices"),
      ]
    ),
    .target(
      name: "BestASRMacPermissions",
      dependencies: ["BestASRDictation"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("AVFoundation"),
      ]
    ),
    .target(
      name: "BestASRMacUI",
      dependencies: ["BestASRDictation"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("Carbon"),
      ]
    ),
    .target(
      name: "BestASRProcessing",
      dependencies: [
        "BestASRDictation",
        "BestASRDomain",
        "BestASRInference",
      ]
    ),
    .target(
      name: "BestASRRecognition",
      dependencies: [
        "BestASRDictation",
        "BestASRDomain",
        "BestASRInference",
      ]
    ),
    .target(
      name: "BestASRDictationFixtures",
      dependencies: [
        "BestASRAudioJournal",
        "BestASRDictation",
        "BestASRDomain",
        "BestASRInference",
        "BestASRPersistence",
        "BestASRProcessing",
      ]
    ),
    .target(
      name: "BestASRCandidateAdapters",
      dependencies: ["BestASRInference"]
    ),
    .target(
      name: "BestASRFluidRuntime",
      dependencies: [
        "BestASRCandidateAdapters",
        "BestASRInference",
        "BestASRModelManager",
        .product(name: "FluidAudio", package: "FluidAudio"),
      ]
    ),
    .target(name: "BestASRModelManager"),
    .target(
      name: "BestASRQwenRuntime",
      dependencies: [
        "BestASRCandidateAdapters",
        "BestASRFluidRuntime",
        "BestASRInference",
        "BestASRModelManager",
        "BestASRRecognition",
        .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
        .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "Hub", package: "swift-transformers"),
      ]
    ),
    .target(
      name: "BestASRAlphaEvaluation",
      dependencies: ["BestASRBenchmark"],
      linkerSettings: [.linkedFramework("AVFoundation")]
    ),
    .target(
      name: "BestASRBenchmark",
      dependencies: ["BestASRInference"]
    ),
    .target(
      name: "BestASRSpeakerEvidence",
      dependencies: ["BestASRBenchmark"]
    ),
    .target(
      name: "BestASRSpeakerReleaseEvaluation",
      dependencies: [
        "BestASRBenchmark",
        "BestASRFluidRuntime",
        "BestASRInference",
        "BestASRModelManager",
      ]
    ),
    .target(name: "BestASREvidence"),
    .target(name: "BestASRModelManagerProbe"),
    .target(
      name: "BestASRUpdateProbe",
      dependencies: ["BestASRModelManagerProbe"]
    ),
    .executableTarget(
      name: "ModelManagerProbeCLI",
      dependencies: ["BestASRModelManagerProbe"]
    ),
    .target(name: "BestASROfflineProbe"),
    .target(name: "BestASRDomain"),
    // Own-device organizer link (PRD §0.3): ssh forward, owner-checked
    // loopback HTTP, provenance guard. Apple frameworks only.
    .target(
      name: "BestASRRemoteOrganizer",
      dependencies: [
        "BestASRDomain",
        "BestASRMemory",
        .product(name: "MindloomLink", package: "MindloomLink"),
        .product(name: "MindloomSpaces", package: "MindloomLink"),
      ]
    ),
    // Paste/drag intake (PRD §0.3.2): pasteboard and file reading, local text
    // extraction (PDFKit, NSAttributedString, XMLDocument), image
    // normalization (ImageIO), on-device screenshot text reading (Vision),
    // and asset staging. Apple frameworks only; no network, no downloaded
    // model.
    .target(
      name: "BestASRIntake",
      dependencies: [
        "BestASRDomain",
        .product(name: "MindloomLink", package: "MindloomLink"),
      ],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ImageIO"),
        .linkedFramework("PDFKit"),
        .linkedFramework("UniformTypeIdentifiers"),
        .linkedFramework("Vision"),
      ]
    ),
    // UI-framework-agnostic read model for the Home, Event, and People pages
    // and the plain-text event export. Foundation only.
    // Agents reading 织机 (AGENT-CONTRACT): hand-rolled MCP (JSON-RPC 2.0 over
    // newline-delimited stdio / a Unix socket), Foundation only (ADR-0008).
    .target(name: "MindloomAgentProtocol"),
    .target(
      name: "BestASRAgentAccess",
      dependencies: [
        "BestASRDomain", "BestASRMemory", "BestASRRemoteOrganizer", "MindloomAgentProtocol",
      ]
    ),
    .executableTarget(
      name: "MindloomMCPHelper",
      dependencies: ["MindloomAgentProtocol"]
    ),
    .executableTarget(
      name: "MindloomAgentTestHost",
      dependencies: [
        "BestASRAgentAccess", "BestASRDomain", "BestASRMemory", "BestASRPersistence",
        "MindloomAgentProtocol",
      ]
    ),
    .target(
      name: "BestASRMemory",
      dependencies: ["BestASRDomain"]
    ),
    // The Home, Event, Person and Unfiled pages (SwiftUI). They read value
    // state (`MemoryScreenState`) and report corrections through
    // `MemoryActions`; no persistence, link, or model SDK is imported.
    .target(
      name: "BestASRMemoryUI",
      dependencies: [
        "BestASRDomain", "BestASRMemory",
        .product(name: "MindloomSpaces", package: "MindloomLink"),
      ]
    ),
    .target(
      name: "BestASRSpeakerRouting",
      dependencies: ["BestASRDomain"]
    ),
    .target(
      name: "BestASRLocalText",
      dependencies: ["BestASRDomain", "BestASRInference"]
    ),
    .target(
      name: "BestASRMLXRuntime",
      dependencies: [
        "BestASRDictation",
        "BestASRInference",
        "BestASRLocalText",
        "BestASRModelManager",
        "BestASRProcessing",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers"),
      ]
    ),
    .target(
      name: "BestASRResourcePolicyProbe",
      dependencies: ["BestASRAudioJournalProbe"]
    ),
    .target(
      name: "BestASRPersistenceProbe",
      dependencies: [
        "BestASRDomain",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .executableTarget(
      name: "PersistenceMigrationProbeCLI",
      dependencies: ["BestASRPersistenceProbe"]
    ),
    .target(
      name: "BestASRMigrationProbe",
      dependencies: ["BestASRDomain"]
    ),
    .executableTarget(
      name: "CrossRootMigrationProbeCLI",
      dependencies: ["BestASRDomain", "BestASRMigrationProbe"]
    ),
    .target(
      name: "BestASRSecurityEnvelopeProbe",
      linkerSettings: [.linkedFramework("Security")]
    ),
    .target(
      name: "BestASRPortableArchiveProbe",
      dependencies: [
        "BestASRDomain",
        "BestASRPersistence",
        "BestASRSecurityEnvelopeProbe",
      ]
    ),
    .target(
      name: "BestASRProcessTapRT",
      publicHeadersPath: "include",
      linkerSettings: [.linkedFramework("CoreAudio")]
    ),
    .target(
      name: "BestASRProcessTapProbe",
      dependencies: ["BestASRProcessTapRT"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("CoreAudio"),
      ]
    ),
    .target(
      name: "BestASRAudioTimelineProbe",
      dependencies: ["BestASRDomain"]
    ),
    .target(name: "BestASRAudioJournalProbe"),
    .target(
      name: "BestASRLongRecordingProbe",
      dependencies: ["BestASRAudioJournalProbe"]
    ),
    .target(
      name: "BestASRInferenceQueueProbe",
      dependencies: ["BestASRAudioJournalProbe"]
    ),
    .target(name: "BestASRInferenceXPCProtocol"),
    .executableTarget(
      name: "PortableMigrationProbeCLI",
      dependencies: [
        "BestASRDomain",
        "BestASRPortableArchiveProbe",
        "BestASRSecurityEnvelopeProbe",
      ]
    ),
    .executableTarget(
      name: "OfflineSmokeSuiteCLI",
      dependencies: ["BestASROfflineProbe"]
    ),
    .executableTarget(
      name: "AudioTimelineProbeCLI",
      dependencies: ["BestASRAudioTimelineProbe"]
    ),
    .executableTarget(
      name: "AudioJournalProbeCLI",
      dependencies: ["BestASRAudioJournalProbe"]
    ),
    .executableTarget(
      name: "LongRecordingProbeCLI",
      dependencies: ["BestASRLongRecordingProbe"]
    ),
    .executableTarget(
      name: "InferenceQueueProbeCLI",
      dependencies: ["BestASRInferenceQueueProbe"]
    ),
    .executableTarget(
      name: "CandidateAdapterProbeCLI",
      dependencies: ["BestASRCandidateAdapters"]
    ),
    .executableTarget(
      name: "LLMFactualGateProbeCLI",
      dependencies: ["BestASRBenchmark"]
    ),
    .executableTarget(
      name: "SpeakerEvidenceCollatorCLI",
      dependencies: ["BestASRSpeakerEvidence"]
    ),
    .executableTarget(
      name: "SpeakerIdentityEvaluatorCLI",
      dependencies: ["BestASRSpeakerEvidence"]
    ),
    .executableTarget(
      name: "PublicSpeakerEvalCLI",
      dependencies: [
        "BestASRBenchmark",
        "BestASRFluidRuntime",
        "BestASRModelManager",
        "BestASRSpeakerReleaseEvaluation",
      ]
    ),
    .executableTarget(
      name: "ResourcePolicyProbeCLI",
      dependencies: ["BestASRResourcePolicyProbe"]
    ),
    .executableTarget(
      name: "UpdateRollbackProbeCLI",
      dependencies: ["BestASRUpdateProbe"]
    ),
    .executableTarget(
      name: "AXInsertionFixture",
      linkerSettings: [.linkedFramework("AppKit")]
    ),
    .executableTarget(
      name: "PasteProbeCLI",
      dependencies: ["BestASRDelivery"]
    ),
    .executableTarget(
      name: "MicrophoneCaptureSmokeCLI",
      dependencies: ["BestASRDictation", "BestASRDomain", "BestASRMacAudio"]
    ),
    .executableTarget(
      name: "DictationFixtureHarnessCLI",
      dependencies: ["BestASRDictationFixtures"]
    ),
    .executableTarget(
      name: "AlphaASREvalCLI",
      dependencies: [
        "BestASRAlphaEvaluation",
        "BestASRFluidRuntime",
        "BestASRModelManager",
        "BestASRQwenRuntime",
        .product(name: "WhisperKit", package: "argmax-oss-swift"),
        .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
        .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "Hub", package: "swift-transformers"),
      ],
      linkerSettings: [.linkedFramework("AVFoundation")]
    ),
    .executableTarget(
      name: "InstalledModelDictationProbeCLI",
      dependencies: [
        "BestASRAudioJournal",
        "BestASRCandidateAdapters",
        "BestASRDictation",
        "BestASRDomain",
        "BestASRFluidRuntime",
        "BestASRInference",
        "BestASRMLXRuntime",
        "BestASRModelManager",
        "BestASRPersistence",
        "BestASRProcessing",
        "BestASRRecognition",
      ],
      linkerSettings: [.linkedFramework("AVFoundation")]
    ),
    .executableTarget(
      name: "LocalTextModelProbeCLI",
      dependencies: [
        "BestASRDictation",
        "BestASRInference",
        "BestASRMLXRuntime",
        "BestASRProcessing",
      ]
    ),
    .executableTarget(
      name: "SpokenModeProbeCLI",
      dependencies: [
        "BestASRInference",
        "BestASRMLXRuntime",
        "BestASRModelManager",
      ]
    ),
    .executableTarget(
      name: "SpeakerRelinkCLI",
      dependencies: [
        "BestASRDomain",
        "BestASRPersistence",
        "BestASRSpeakerRouting",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .executableTarget(
      name: "SourceAudioCompactionCLI",
      dependencies: [
        "BestASRAudioJournal",
        "BestASRDictation",
        "BestASRDomain",
        "BestASRPersistence",
      ]
    ),
    .executableTarget(
      name: "DictationEvalCLI",
      dependencies: [
        "BestASRAudioJournal",
        "BestASRCandidateAdapters",
        "BestASRDictation",
        "BestASRDomain",
        "BestASRFluidRuntime",
        "BestASRInference",
        "BestASRMLXRuntime",
        "BestASRModelManager",
        "BestASRProcessing",
        "BestASRQwenRuntime",
      ]
    ),
    .testTarget(
      name: "BestASRCoreTests",
      dependencies: ["BestASRCore", "BestASREvidence"]
    ),
    .testTarget(
      name: "BestASRInferenceTests",
      dependencies: ["BestASRInference"]
    ),
    .testTarget(
      name: "BestASRDictationTests",
      dependencies: [
        "BestASRAudioJournal",
        "BestASRDictation",
        "BestASRDomain",
        "BestASRInference",
        "BestASRPersistence",
      ]
    ),
    .testTarget(
      name: "BestASRRemoteOrganizerTests",
      dependencies: [
        "BestASRDomain",
        "BestASRIntake",
        "BestASRMemory",
        "BestASRPersistence",
        "BestASRRemoteOrganizer",
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "MindloomLink", package: "MindloomLink"),
        .product(name: "MindloomSpaces", package: "MindloomLink"),
        .product(name: "MindloomSpacesTestSupport", package: "MindloomLink"),
      ]
    ),
    .testTarget(
      name: "BestASRPersistenceTests",
      dependencies: [
        "BestASRAudioJournal",
        "BestASRDictation",
        "BestASRDomain",
        "BestASRInference",
        "BestASRMemory",
        "BestASRPersistence",
        "BestASRPersistenceProbe",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .testTarget(
      name: "BestASRAudioJournalTests",
      dependencies: [
        "BestASRAudioJournal",
        "BestASRAudioJournalProbe",
        "BestASRDictation",
        "BestASRDomain",
        "BestASRInference",
      ]
    ),
    .testTarget(
      name: "BestASRAudioTests",
      dependencies: ["BestASRAudio", "BestASRDictation"]
    ),
    .testTarget(
      name: "BestASRMacAudioTests",
      dependencies: ["BestASRDictation", "BestASRDomain", "BestASRMacAudio"]
    ),
    .testTarget(
      name: "BestASRDeliveryTests",
      dependencies: ["BestASRDelivery", "BestASRDictation", "BestASRDomain"]
    ),
    .testTarget(
      name: "BestASRMacPermissionsTests",
      dependencies: ["BestASRDictation", "BestASRMacPermissions"]
    ),
    .testTarget(
      name: "BestASRMacUITests",
      dependencies: ["BestASRDictation", "BestASRMacUI"]
    ),
    .testTarget(
      name: "BestASRProcessingTests",
      dependencies: [
        "BestASRDictation",
        "BestASRDictationFixtures",
        "BestASRDomain",
        "BestASRInference",
        "BestASRPersistence",
        "BestASRProcessing",
      ]
    ),
    .testTarget(
      name: "BestASRRecognitionTests",
      dependencies: [
        "BestASRAudioJournal",
        "BestASRDictation",
        "BestASRDomain",
        "BestASRInference",
        "BestASRRecognition",
      ]
    ),
    .testTarget(
      name: "BestASRCandidateAdaptersTests",
      dependencies: ["BestASRCandidateAdapters"]
    ),
    .testTarget(
      name: "BestASRFluidRuntimeTests",
      dependencies: [
        "BestASRBenchmark",
        "BestASRCandidateAdapters",
        "BestASRFluidRuntime",
        "BestASRInference",
        .product(name: "FluidAudio", package: "FluidAudio"),
      ]
    ),
    .testTarget(
      name: "BestASRModelManagerTests",
      dependencies: ["BestASRModelManager"]
    ),
    .testTarget(
      name: "BestASRQwenRuntimeTests",
      dependencies: [
        "BestASRQwenRuntime", "BestASRFluidRuntime", "BestASRInference",
        "BestASRCandidateAdapters", "BestASRRecognition",
        .product(name: "MLX", package: "mlx-swift"),
      ]
    ),
    .testTarget(
      name: "BestASRAlphaEvaluationTests",
      dependencies: ["BestASRAlphaEvaluation", "BestASRBenchmark"]
    ),
    .testTarget(
      name: "BestASRBenchmarkTests",
      dependencies: ["BestASRBenchmark", "BestASREvidence"]
    ),
    .testTarget(
      name: "BestASRSpeakerEvidenceTests",
      dependencies: ["BestASRSpeakerEvidence"]
    ),
    .testTarget(
      name: "BestASRSpeakerReleaseEvaluationTests",
      dependencies: [
        "BestASRBenchmark",
        "BestASRSpeakerReleaseEvaluation",
      ]
    ),
    .testTarget(
      name: "BestASREvidenceTests",
      dependencies: ["BestASREvidence", "BestASRAudioJournalProbe"]
    ),
    .testTarget(
      name: "BestASRModelManagerProbeTests",
      dependencies: ["BestASRModelManagerProbe"]
    ),
    .testTarget(
      name: "BestASRUpdateProbeTests",
      dependencies: ["BestASRModelManagerProbe", "BestASRUpdateProbe"]
    ),
    .testTarget(
      name: "BestASROfflineProbeTests",
      dependencies: ["BestASROfflineProbe"]
    ),
    .testTarget(
      name: "BestASRDomainTests",
      dependencies: ["BestASRDomain"],
      // The shared masking vectors (privacy contract §3), byte-identical to
      // `privacy/mask_vectors.json` and to the organizing device's copy.
      resources: [.copy("Resources/privacy")]
    ),
    .testTarget(
      name: "BestASRSpeakerRoutingTests",
      dependencies: ["BestASRSpeakerRouting"]
    ),
    .testTarget(
      name: "BestASRIntakeTests",
      dependencies: [
        "BestASRDomain", "BestASRIntake", "BestASRPersistence", "BestASRRemoteOrganizer",
      ]
    ),
    .testTarget(
      name: "BestASRAgentAccessTests",
      dependencies: [
        "BestASRAgentAccess", "BestASRDomain", "BestASRMemory", "BestASRPersistence",
        "MindloomAgentProtocol", "MindloomMCPHelper",
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .testTarget(
      name: "BestASRMemoryTests",
      dependencies: ["BestASRDomain", "BestASRMemory"]
    ),
    .testTarget(
      name: "BestASRMemoryUITests",
      dependencies: [
        "BestASRDomain", "BestASRMemory", "BestASRMemoryUI",
        .product(name: "MindloomSpaces", package: "MindloomLink"),
      ]
    ),
    // Opt-in end-to-end run on the owner's own Spark: a fresh synthetic data
    // root, the real intake, link, projection, pages and export. Skipped
    // unless BESTASR_E2E_SPARK_HOST (and the socket/token paths) are set.
    .testTarget(
      name: "BestASRSparkEndToEndTests",
      dependencies: [
        "BestASRDomain",
        "BestASRIntake",
        "BestASRMemory",
        "BestASRMemoryUI",
        "BestASRPersistence",
        "BestASRRemoteOrganizer",
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "MindloomLink", package: "MindloomLink"),
        .product(name: "MindloomSpaces", package: "MindloomLink"),
      ]
    ),
    .testTarget(
      name: "BestASRLocalTextTests",
      dependencies: ["BestASRLocalText"]
    ),
    .testTarget(
      name: "BestASRMLXRuntimeTests",
      dependencies: [
        "BestASRDictation",
        "BestASRDomain",
        "BestASRInference",
        "BestASRMLXRuntime",
      ]
    ),
    .testTarget(
      name: "BestASRResourcePolicyProbeTests",
      dependencies: ["BestASRResourcePolicyProbe"]
    ),
    .testTarget(
      name: "BestASRPersistenceProbeTests",
      dependencies: ["BestASRPersistenceProbe"]
    ),
    .testTarget(
      name: "BestASRMigrationProbeTests",
      dependencies: ["BestASRDomain", "BestASRMigrationProbe"]
    ),
    .testTarget(
      name: "BestASRSecurityEnvelopeProbeTests",
      dependencies: ["BestASRSecurityEnvelopeProbe"]
    ),
    .testTarget(
      name: "BestASRPortableArchiveProbeTests",
      dependencies: [
        "BestASRDomain",
        "BestASRPortableArchiveProbe",
        "BestASRSecurityEnvelopeProbe",
      ]
    ),
    .testTarget(
      name: "BestASRProcessTapProbeTests",
      dependencies: ["BestASRProcessTapProbe"]
    ),
    .testTarget(
      name: "BestASRAudioTimelineProbeTests",
      dependencies: ["BestASRAudioTimelineProbe"]
    ),
    .testTarget(
      name: "BestASRAudioJournalProbeTests",
      dependencies: ["BestASRAudioJournalProbe"]
    ),
    .testTarget(
      name: "BestASRLongRecordingProbeTests",
      dependencies: ["BestASRLongRecordingProbe"]
    ),
    .testTarget(
      name: "BestASRInferenceQueueProbeTests",
      dependencies: ["BestASRInferenceQueueProbe"]
    ),
    .testTarget(
      name: "BestASRInferenceXPCProtocolTests",
      dependencies: ["BestASRInferenceXPCProtocol"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
