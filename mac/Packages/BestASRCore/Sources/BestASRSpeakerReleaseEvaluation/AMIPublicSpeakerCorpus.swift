import BestASRBenchmark
import CryptoKit
import Foundation

public enum SpeakerEvaluationSplit: String, Codable, Hashable, Sendable {
  case releaseHoldout = "release-holdout"
  case tuning
}

public enum SpeakerEvaluationEntryMode: String, Codable, CaseIterable, Hashable, Sendable {
  case dictation
  case importedMedia = "imported-media"
  case roomMicrophone = "room-microphone"
  case systemAudio = "system-audio"
}

public enum SpeakerIdentitySampleRole: String, Codable, Hashable, Sendable {
  case enrollment
  case query
}

public struct AMIArchiveArtifact: Codable, Equatable, Sendable {
  public let fileName: String
  public let url: String
  public let sizeBytes: UInt64
  public let sha256: String
}

public struct AMIAudioArtifact: Codable, Equatable, Sendable {
  public let meetingID: String
  public let signal: String
  public let fileName: String
  public let url: String
  public let sizeBytes: UInt64
  public let sha256: String
}

public struct AMISpeakerPlan: Codable, Equatable, Sendable {
  public let label: String
  public let expectedPersonID: String
  public let evidenceSufficient: Bool
  public let headsetSignal: String
}

public struct AMIMeetingPlan: Codable, Equatable, Sendable {
  public let meetingID: String
  public let split: SpeakerEvaluationSplit
  public let mixSignal: String
  public let arraySignal: String
  public let speakers: [AMISpeakerPlan]
}

public struct AMIPublicSpeakerEvaluationPlan: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let datasetID: String
  public let datasetVersion: String
  public let source: String
  public let license: String
  public let licenseNotice: String
  public let annotationArchive: AMIArchiveArtifact
  public let audioArtifacts: [AMIAudioArtifact]
  public let meetings: [AMIMeetingPlan]
  public let splitManifestIDs: [String: String]

  public static func decode(_ data: Data) throws -> Self {
    let plan: Self
    do {
      plan = try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw AMIPublicSpeakerEvaluationError.invalidPlan
    }
    try plan.validate()
    return plan
  }

  public func validate() throws {
    guard schemaVersion == 1,
      kind == "ami-public-speaker-evaluation-plan",
      datasetID == "ami-meeting-corpus",
      datasetVersion == "1.6.2",
      source == "https://groups.inf.ed.ac.uk/ami/",
      license == "CC-BY-4.0",
      licenseNotice == "Legal/AMI-Corpus-NOTICE-CC-BY-4.0.txt",
      Self.safeFileName(annotationArchive.fileName),
      Self.officialAMIURL(annotationArchive.url),
      annotationArchive.sizeBytes > 0,
      Self.digest(annotationArchive.sha256),
      !audioArtifacts.isEmpty,
      !meetings.isEmpty,
      splitManifestIDs.keys.sorted()
        == [
          SpeakerEvaluationSplit.releaseHoldout.rawValue,
          SpeakerEvaluationSplit.tuning.rawValue,
        ],
      splitManifestIDs.values.allSatisfy(Self.safeIdentifier)
    else {
      throw AMIPublicSpeakerEvaluationError.invalidPlan
    }

    var artifactFiles = Set<String>()
    var artifactKeys = Set<String>()
    for artifact in audioArtifacts {
      guard Self.safeIdentifier(artifact.meetingID),
        Self.safeSignal(artifact.signal),
        Self.safeFileName(artifact.fileName),
        artifact.fileName == "\(artifact.meetingID).\(artifact.signal).wav",
        Self.officialAMIURL(artifact.url),
        artifact.url.hasSuffix("/\(artifact.fileName)"),
        artifact.sizeBytes > 44,
        Self.digest(artifact.sha256),
        artifactFiles.insert(artifact.fileName).inserted,
        artifactKeys.insert("\(artifact.meetingID)\u{1f}\(artifact.signal)").inserted
      else {
        throw AMIPublicSpeakerEvaluationError.invalidPlan
      }
    }

    var meetingIDs = Set<String>()
    var sawTuning = false
    var sawHoldout = false
    for meeting in meetings {
      guard Self.safeIdentifier(meeting.meetingID),
        meetingIDs.insert(meeting.meetingID).inserted,
        (2...4).contains(meeting.speakers.count),
        Self.safeSignal(meeting.mixSignal),
        Self.safeSignal(meeting.arraySignal),
        artifactKeys.contains("\(meeting.meetingID)\u{1f}\(meeting.mixSignal)"),
        artifactKeys.contains("\(meeting.meetingID)\u{1f}\(meeting.arraySignal)")
      else {
        throw AMIPublicSpeakerEvaluationError.invalidPlan
      }
      sawTuning = sawTuning || meeting.split == .tuning
      sawHoldout = sawHoldout || meeting.split == .releaseHoldout
      let labels = Set(meeting.speakers.map(\.label))
      let people = Set(meeting.speakers.map(\.expectedPersonID))
      guard labels.count == meeting.speakers.count,
        people.count == meeting.speakers.count
      else {
        throw AMIPublicSpeakerEvaluationError.invalidPlan
      }
      for speaker in meeting.speakers {
        guard
          speaker.label.range(
            of: "^[A-D]$", options: .regularExpression
          ) != nil,
          Self.safeIdentifier(speaker.expectedPersonID),
          Self.safeSignal(speaker.headsetSignal),
          artifactKeys.contains(
            "\(meeting.meetingID)\u{1f}\(speaker.headsetSignal)"
          ),
          meeting.split != .tuning || speaker.evidenceSufficient
        else {
          throw AMIPublicSpeakerEvaluationError.invalidPlan
        }
      }
    }
    guard sawTuning, sawHoldout else {
      throw AMIPublicSpeakerEvaluationError.invalidPlan
    }
  }

  fileprivate func artifact(meetingID: String, signal: String) throws
    -> AMIAudioArtifact
  {
    guard
      let artifact = audioArtifacts.first(where: {
        $0.meetingID == meetingID && $0.signal == signal
      })
    else {
      throw AMIPublicSpeakerEvaluationError.invalidPlan
    }
    return artifact
  }

  fileprivate static func safeIdentifier(_ value: String) -> Bool {
    value.range(
      of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
      options: .regularExpression
    ) != nil
  }

  fileprivate static func safeSignal(_ value: String) -> Bool {
    value.range(
      of: "^[A-Za-z0-9][A-Za-z0-9-]{0,63}$",
      options: .regularExpression
    ) != nil
  }

  fileprivate static func safeFileName(_ value: String) -> Bool {
    !value.isEmpty
      && !value.hasPrefix(".")
      && !value.contains("/")
      && !value.contains("..")
      && URL(string: value)?.scheme == nil
  }

  fileprivate static func digest(_ value: String) -> Bool {
    value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
  }

  fileprivate static func officialAMIURL(_ value: String) -> Bool {
    guard let components = URLComponents(string: value) else { return false }
    return components.scheme == "https"
      && components.host == "groups.inf.ed.ac.uk"
      && components.user == nil
      && components.password == nil
      && components.query == nil
      && components.fragment == nil
      && components.path.hasPrefix("/ami/")
  }
}

public struct SpeakerPreparedAudioAsset: Codable, Equatable, Sendable {
  public let relativePath: String
  public let contentDigest: String
  public let sampleCount: Int
  public let durationNanoseconds: UInt64
}

public struct SpeakerDiarizationLocalSample: Codable, Equatable, Sendable {
  public let sampleUUID: UUID
  public let meetingID: String
  public let mode: SpeakerEvaluationEntryMode
  public let expectedSpeakerCount: Int
  public let audio: SpeakerPreparedAudioAsset
  public let reference: [SpeakerSegment]
}

public struct SpeakerIdentityLocalSample: Codable, Equatable, Sendable {
  public let sampleUUID: UUID
  public let sampleID: String
  public let expectedPersonID: String
  public let evidenceSufficient: Bool
  public let role: SpeakerIdentitySampleRole
  public let mode: SpeakerEvaluationEntryMode
  public let audio: SpeakerPreparedAudioAsset
}

public struct AMISpeakerLocalRun: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String
  public let split: SpeakerEvaluationSplit
  public let corpusManifestID: String
  public let corpusVersion: String
  public let datasetID: String
  public let datasetVersion: String
  public let license: String
  public let diarizationSamples: [SpeakerDiarizationLocalSample]
  public let identitySamples: [SpeakerIdentityLocalSample]

  public init(
    split: SpeakerEvaluationSplit,
    corpusManifestID: String,
    corpusVersion: String,
    datasetID: String,
    datasetVersion: String,
    license: String,
    diarizationSamples: [SpeakerDiarizationLocalSample],
    identitySamples: [SpeakerIdentityLocalSample]
  ) {
    schemaVersion = 1
    kind = "ami-speaker-local-run"
    self.split = split
    self.corpusManifestID = corpusManifestID
    self.corpusVersion = corpusVersion
    self.datasetID = datasetID
    self.datasetVersion = datasetVersion
    self.license = license
    self.diarizationSamples = diarizationSamples
    self.identitySamples = identitySamples
  }

  public static func decode(_ data: Data) throws -> Self {
    let run: Self
    do {
      run = try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw AMIPublicSpeakerEvaluationError.invalidLocalRun
    }
    try run.validate()
    return run
  }

  public func validate() throws {
    guard schemaVersion == 1,
      kind == "ami-speaker-local-run",
      AMIPublicSpeakerEvaluationPlan.safeIdentifier(corpusManifestID),
      !corpusVersion.isEmpty,
      datasetID == "ami-meeting-corpus",
      datasetVersion == "1.6.2",
      license == "CC-BY-4.0",
      !diarizationSamples.isEmpty,
      !identitySamples.isEmpty
    else {
      throw AMIPublicSpeakerEvaluationError.invalidLocalRun
    }
    let allUUIDs =
      diarizationSamples.map(\.sampleUUID)
      + identitySamples.map(\.sampleUUID)
    guard Set(allUUIDs).count == allUUIDs.count else {
      throw AMIPublicSpeakerEvaluationError.invalidLocalRun
    }
    for sample in diarizationSamples {
      guard sample.expectedSpeakerCount >= 1,
        !sample.reference.isEmpty
      else {
        throw AMIPublicSpeakerEvaluationError.invalidLocalRun
      }
      try Self.validate(sample.audio)
    }
    for sample in identitySamples {
      guard AMIPublicSpeakerEvaluationPlan.safeIdentifier(sample.sampleID),
        AMIPublicSpeakerEvaluationPlan.safeIdentifier(sample.expectedPersonID)
      else {
        throw AMIPublicSpeakerEvaluationError.invalidLocalRun
      }
      try Self.validate(sample.audio)
    }
    if split == .tuning {
      let enrollment = identitySamples.filter { $0.role == .enrollment }
      let grouped = Dictionary(grouping: enrollment, by: \.expectedPersonID)
      guard !grouped.isEmpty,
        grouped.values.allSatisfy({ $0.count >= 2 }),
        identitySamples.contains(where: { $0.role == .query })
      else {
        throw AMIPublicSpeakerEvaluationError.invalidLocalRun
      }
    } else {
      guard identitySamples.allSatisfy({ $0.role == .query }) else {
        throw AMIPublicSpeakerEvaluationError.invalidLocalRun
      }
    }
  }

  private static func validate(_ audio: SpeakerPreparedAudioAsset) throws {
    guard safeRelativePath(audio.relativePath),
      AMIPublicSpeakerEvaluationPlan.digest(audio.contentDigest),
      audio.sampleCount > 0,
      audio.durationNanoseconds > 0
    else {
      throw AMIPublicSpeakerEvaluationError.invalidLocalRun
    }
  }

  fileprivate static func safeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), URL(string: path)?.scheme == nil
    else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false)
      .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}

public enum AMIPublicSpeakerEvaluationError: Error, Equatable, Sendable {
  case artifactDigestMismatch(String)
  case artifactSizeMismatch(String)
  case insufficientCleanSpeech(String)
  case invalidAnnotation(String)
  case invalidAudio(String)
  case invalidLocalRun
  case invalidManifest
  case invalidPlan
  case rootsNotSeparated
  case unsafePath
}

public enum AMIPublicSpeakerCorpusPreparer {
  public static func prepare(
    planURL: URL,
    downloadsRoot: URL,
    annotationsRoot: URL,
    tuningRoot: URL,
    releaseHoldoutRoot: URL,
    tuningManifestTemplate: URL,
    releaseManifestTemplate: URL
  ) throws {
    let plan = try AMIPublicSpeakerEvaluationPlan.decode(
      Data(contentsOf: planURL)
    )
    let roots = try EvaluationRoots(
      tuning: tuningRoot,
      releaseHoldout: releaseHoldoutRoot
    )
    let downloads = try safeDirectory(downloadsRoot)
    let annotations = try safeDirectory(annotationsRoot)
    try verify(
      archive: plan.annotationArchive,
      under: downloads
    )
    for artifact in plan.audioArtifacts {
      try verify(artifact: artifact, under: downloads)
    }

    let tuningManifest = try loadAndValidateManifest(
      tuningManifestTemplate,
      plan: plan,
      split: .tuning
    )
    let releaseManifest = try loadAndValidateManifest(
      releaseManifestTemplate,
      plan: plan,
      split: .releaseHoldout
    )

    for (split, root, manifest, template) in [
      (SpeakerEvaluationSplit.tuning, roots.tuning, tuningManifest, tuningManifestTemplate),
      (
        SpeakerEvaluationSplit.releaseHoldout,
        roots.releaseHoldout,
        releaseManifest,
        releaseManifestTemplate
      ),
    ] {
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
      )
      let manifestDestination = root.appendingPathComponent("manifest.json")
      try Data(contentsOf: template).write(
        to: manifestDestination,
        options: .atomic
      )
      let run = try buildRun(
        plan: plan,
        split: split,
        corpusVersion: manifest.version,
        downloadsRoot: downloads,
        annotationsRoot: annotations,
        outputRoot: root
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(run).write(
        to: root.appendingPathComponent("local-run.json"),
        options: .atomic
      )
    }
  }

  private static func buildRun(
    plan: AMIPublicSpeakerEvaluationPlan,
    split: SpeakerEvaluationSplit,
    corpusVersion: String,
    downloadsRoot: URL,
    annotationsRoot: URL,
    outputRoot: URL
  ) throws -> AMISpeakerLocalRun {
    let meetings = plan.meetings.filter { $0.split == split }
    var diarizationSamples: [SpeakerDiarizationLocalSample] = []
    var identitySamples: [SpeakerIdentityLocalSample] = []
    let audioRoot = outputRoot.appendingPathComponent("audio", isDirectory: true)
    try FileManager.default.createDirectory(
      at: audioRoot,
      withIntermediateDirectories: true
    )

    for meeting in meetings {
      let segments = try loadSegments(
        meeting: meeting,
        annotationsRoot: annotationsRoot
      )
      let fullSignals: [(String, SpeakerEvaluationEntryMode)] = [
        (meeting.mixSignal, .systemAudio),
        (meeting.arraySignal, .roomMicrophone),
      ]
      for (signal, mode) in fullSignals {
        let artifact = try plan.artifact(
          meetingID: meeting.meetingID,
          signal: signal
        )
        let wave = try PCM16Wave(
          url: downloadsRoot.appendingPathComponent(artifact.fileName)
        )
        let relativePath = "audio/\(meeting.meetingID).\(signal).f32le"
        let prepared = try writeFloat32(
          wave: wave,
          startSample: 0,
          endSample: wave.sampleCount,
          relativePath: relativePath,
          outputRoot: outputRoot
        )
        let reference = segments.flatMap { label, values in
          values.compactMap { segment -> SpeakerSegment? in
            let start = min(segment.startNanoseconds, prepared.durationNanoseconds)
            let end = min(segment.endNanoseconds, prepared.durationNanoseconds)
            guard end > start else { return nil }
            return SpeakerSegment(
              speakerID: "\(meeting.meetingID)-\(label)",
              startNanoseconds: start,
              endNanoseconds: end
            )
          }
        }.sorted {
          if $0.startNanoseconds == $1.startNanoseconds {
            return $0.speakerID < $1.speakerID
          }
          return $0.startNanoseconds < $1.startNanoseconds
        }
        diarizationSamples.append(
          SpeakerDiarizationLocalSample(
            sampleUUID: deterministicUUID(
              "ami\u{1f}\(split.rawValue)\u{1f}\(meeting.meetingID)\u{1f}\(signal)\u{1f}diarization"
            ),
            meetingID: meeting.meetingID,
            mode: mode,
            expectedSpeakerCount: meeting.speakers.count,
            audio: prepared,
            reference: reference
          )
        )
      }

      for speaker in meeting.speakers {
        let identitySignals = [
          speaker.headsetSignal,
          meeting.arraySignal,
          meeting.mixSignal,
        ]
        var waves: [String: PCM16Wave] = [:]
        for signal in identitySignals {
          let artifact = try plan.artifact(
            meetingID: meeting.meetingID,
            signal: signal
          )
          waves[signal] = try PCM16Wave(
            url: downloadsRoot.appendingPathComponent(artifact.fileName)
          )
        }
        let requiredWindowCount = split == .tuning ? 3 : 1
        let windows = try cleanSpeechWindows(
          speakerLabel: speaker.label,
          segments: segments,
          requiredCount: requiredWindowCount,
          scoringWaves: identitySignals.compactMap { waves[$0] }
        )
        var recipes: [IdentityRecipe] = []
        if split == .tuning {
          recipes.append(
            IdentityRecipe(role: .enrollment, mode: .dictation, signal: speaker.headsetSignal)
          )
          recipes.append(
            IdentityRecipe(role: .enrollment, mode: .dictation, signal: speaker.headsetSignal)
          )
        }
        recipes.append(contentsOf: [
          IdentityRecipe(role: .query, mode: .dictation, signal: speaker.headsetSignal),
          IdentityRecipe(role: .query, mode: .roomMicrophone, signal: meeting.arraySignal),
          IdentityRecipe(role: .query, mode: .systemAudio, signal: meeting.mixSignal),
          IdentityRecipe(role: .query, mode: .importedMedia, signal: meeting.mixSignal),
        ])
        let windowIndices =
          split == .tuning
          ? [0, 1, 2, 2, 2, 2]
          : [0, 0, 0, 0]
        guard recipes.count == windowIndices.count else {
          throw AMIPublicSpeakerEvaluationError.invalidPlan
        }
        for (index, recipe) in recipes.enumerated() {
          let artifact = try plan.artifact(
            meetingID: meeting.meetingID,
            signal: recipe.signal
          )
          let wave: PCM16Wave
          if let cached = waves[recipe.signal] {
            wave = cached
          } else {
            let loaded = try PCM16Wave(
              url: downloadsRoot.appendingPathComponent(artifact.fileName)
            )
            waves[recipe.signal] = loaded
            wave = loaded
          }
          let window = windows[windowIndices[index]]
          let startSample = min(
            wave.sampleCount - 1,
            Int((Double(window.startNanoseconds) * 16_000 / 1_000_000_000).rounded())
          )
          let endSample = min(
            wave.sampleCount,
            Int((Double(window.endNanoseconds) * 16_000 / 1_000_000_000).rounded())
          )
          guard endSample > startSample else {
            throw AMIPublicSpeakerEvaluationError.invalidAudio(artifact.fileName)
          }
          let ordinal = String(format: "%02d", index + 1)
          let sampleID = [
            meeting.meetingID,
            speaker.label,
            recipe.role.rawValue,
            recipe.mode.rawValue,
            ordinal,
          ].joined(separator: "-")
          let relativePath = "audio/identity/\(sampleID).f32le"
          let prepared = try writeFloat32(
            wave: wave,
            startSample: startSample,
            endSample: endSample,
            relativePath: relativePath,
            outputRoot: outputRoot
          )
          identitySamples.append(
            SpeakerIdentityLocalSample(
              sampleUUID: deterministicUUID(
                "ami\u{1f}\(split.rawValue)\u{1f}\(sampleID)\u{1f}identity"
              ),
              sampleID: sampleID,
              expectedPersonID: speaker.expectedPersonID,
              evidenceSufficient: speaker.evidenceSufficient,
              role: recipe.role,
              mode: recipe.mode,
              audio: prepared
            )
          )
        }
      }
    }

    let run = AMISpeakerLocalRun(
      split: split,
      corpusManifestID: plan.splitManifestIDs[split.rawValue]!,
      corpusVersion: corpusVersion,
      datasetID: plan.datasetID,
      datasetVersion: plan.datasetVersion,
      license: plan.license,
      diarizationSamples: diarizationSamples.sorted {
        $0.sampleUUID.uuidString < $1.sampleUUID.uuidString
      },
      identitySamples: identitySamples.sorted { $0.sampleID < $1.sampleID }
    )
    try run.validate()
    return run
  }

  private static func loadAndValidateManifest(
    _ url: URL,
    plan: AMIPublicSpeakerEvaluationPlan,
    split: SpeakerEvaluationSplit
  ) throws -> CorpusManifest {
    let manifest: CorpusManifest
    do {
      manifest = try JSONDecoder().decode(
        CorpusManifest.self,
        from: Data(contentsOf: url)
      )
    } catch {
      throw AMIPublicSpeakerEvaluationError.invalidManifest
    }
    let expectedTier: CorpusTier = split == .tuning ? .public : .releaseHoldout
    let expectedArtifacts = plan.audioArtifacts.filter { artifact in
      plan.meetings.contains {
        $0.meetingID == artifact.meetingID && $0.split == split
      }
    }
    let references = Dictionary(
      uniqueKeysWithValues: manifest.samples.map {
        ($0.assetReference, $0.contentDigest)
      }
    )
    guard manifest.schemaVersion == 1,
      manifest.kind == "corpus-manifest",
      manifest.manifestID == plan.splitManifestIDs[split.rawValue],
      manifest.tier == expectedTier,
      manifest.releaseHoldout == (split == .releaseHoldout),
      !manifest.containsPrivateContent,
      manifest.samples.count == expectedArtifacts.count,
      expectedArtifacts.allSatisfy({ artifact in
        references[
          "external-corpus://ami-1.6.2/\(artifact.fileName)"
        ] == artifact.sha256
      })
    else {
      throw AMIPublicSpeakerEvaluationError.invalidManifest
    }
    return manifest
  }

  private static func verify(
    archive: AMIArchiveArtifact,
    under root: URL
  ) throws {
    try verifyFile(
      root.appendingPathComponent(archive.fileName),
      name: archive.fileName,
      expectedSize: archive.sizeBytes,
      expectedDigest: archive.sha256
    )
  }

  private static func verify(
    artifact: AMIAudioArtifact,
    under root: URL
  ) throws {
    try verifyFile(
      root.appendingPathComponent(artifact.fileName),
      name: artifact.fileName,
      expectedSize: artifact.sizeBytes,
      expectedDigest: artifact.sha256
    )
  }

  private static func verifyFile(
    _ url: URL,
    name: String,
    expectedSize: UInt64,
    expectedDigest: String
  ) throws {
    let values = try url.resourceValues(
      forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let fileSize = values.fileSize,
      fileSize >= 0,
      UInt64(fileSize) == expectedSize
    else {
      throw AMIPublicSpeakerEvaluationError.artifactSizeMismatch(name)
    }
    guard try sha256(url) == expectedDigest else {
      throw AMIPublicSpeakerEvaluationError.artifactDigestMismatch(name)
    }
  }

  private static func safeDirectory(_ url: URL) throws -> URL {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard resolved.isFileURL,
      resolved.path != "/",
      FileManager.default.fileExists(
        atPath: resolved.path,
        isDirectory: &isDirectory
      ),
      isDirectory.boolValue
    else {
      throw AMIPublicSpeakerEvaluationError.unsafePath
    }
    return resolved
  }

  private static func loadSegments(
    meeting: AMIMeetingPlan,
    annotationsRoot: URL
  ) throws -> [String: [AnnotatedSegment]] {
    var result: [String: [AnnotatedSegment]] = [:]
    for speaker in meeting.speakers {
      let file =
        annotationsRoot
        .appendingPathComponent("segments", isDirectory: true)
        .appendingPathComponent(
          "\(meeting.meetingID).\(speaker.label).segments.xml"
        )
      let parser = XMLParser(contentsOf: file)
      let delegate = SegmentXMLDelegate()
      parser?.delegate = delegate
      guard parser?.parse() == true, !delegate.segments.isEmpty else {
        throw AMIPublicSpeakerEvaluationError.invalidAnnotation(
          "\(meeting.meetingID)-\(speaker.label)"
        )
      }
      result[speaker.label] = delegate.segments.sorted {
        $0.startNanoseconds < $1.startNanoseconds
      }
    }
    return result
  }

  private static func cleanSpeechWindows(
    speakerLabel: String,
    segments: [String: [AnnotatedSegment]],
    requiredCount: Int,
    scoringWaves: [PCM16Wave]
  ) throws -> [AnnotatedSegment] {
    guard let own = segments[speakerLabel] else {
      throw AMIPublicSpeakerEvaluationError.invalidAnnotation(speakerLabel)
    }
    guard scoringWaves.count == 3 else {
      throw AMIPublicSpeakerEvaluationError.invalidAudio(speakerLabel)
    }
    let others = segments.filter { $0.key != speakerLabel }.flatMap { $0.value }
    let margin: UInt64 = 250_000_000
    let minimumDuration: UInt64 = 3_000_000_000
    let minimumWindow: UInt64 = 2_500_000_000
    let maximumWindow: UInt64 = 8_000_000_000
    let expandedOthers = others.map {
      AnnotatedSegment(
        startNanoseconds: $0.startNanoseconds > margin
          ? $0.startNanoseconds - margin : 0,
        endNanoseconds: $0.endNanoseconds + margin
      )
    }.sorted { $0.startNanoseconds < $1.startNanoseconds }
    var candidates: [AnnotatedSegment] = []
    for segment in own where segment.durationNanoseconds >= minimumDuration {
      let speechStart = segment.startNanoseconds + 150_000_000
      let speechEnd = segment.endNanoseconds - 150_000_000
      guard speechEnd > speechStart else { continue }
      var cursor = speechStart
      for exclusion in expandedOthers {
        if exclusion.endNanoseconds <= cursor { continue }
        if exclusion.startNanoseconds >= speechEnd { break }
        let cleanEnd = min(speechEnd, exclusion.startNanoseconds)
        if cleanEnd > cursor, cleanEnd - cursor >= minimumWindow {
          candidates.append(
            AnnotatedSegment(
              startNanoseconds: cursor,
              endNanoseconds: min(cleanEnd, cursor + maximumWindow)
            )
          )
        }
        cursor = max(cursor, min(speechEnd, exclusion.endNanoseconds))
        if cursor >= speechEnd { break }
      }
      if speechEnd > cursor, speechEnd - cursor >= minimumWindow {
        candidates.append(
          AnnotatedSegment(
            startNanoseconds: cursor,
            endNanoseconds: min(speechEnd, cursor + maximumWindow)
          )
        )
      }
    }
    let scored = candidates.compactMap { candidate -> (AnnotatedSegment, Double)? in
      let qualities = scoringWaves.map {
        signalQuality(window: candidate, wave: $0)
      }
      guard let near = qualities.first,
        near.rms >= 0.002,
        near.peak >= 0.01,
        near.activeRatio >= 0.015,
        qualities.dropFirst().allSatisfy({
          $0.rms >= 0.000_3 && $0.peak >= 0.002
        })
      else { return nil }
      let score =
        qualities.reduce(0.0) {
          $0 + log(max(0.000_001, $1.rms))
        } + log(Double(candidate.durationNanoseconds))
      return (candidate, score)
    }.sorted {
      if $0.1 == $1.1 {
        return $0.0.startNanoseconds < $1.0.startNanoseconds
      }
      return $0.1 > $1.1
    }
    var selected: [AnnotatedSegment] = []
    for (candidate, _) in scored {
      guard
        selected.allSatisfy({ existing in
          candidate.endNanoseconds + 1_000_000_000 <= existing.startNanoseconds
            || existing.endNanoseconds + 1_000_000_000 <= candidate.startNanoseconds
        })
      else { continue }
      selected.append(candidate)
      if selected.count == requiredCount { return selected }
    }
    throw AMIPublicSpeakerEvaluationError.insufficientCleanSpeech(speakerLabel)
  }

  private static func signalQuality(
    window: AnnotatedSegment,
    wave: PCM16Wave
  ) -> (rms: Double, peak: Double, activeRatio: Double) {
    let start = max(
      0,
      min(
        wave.sampleCount - 1,
        Int(
          (Double(window.startNanoseconds) * 16_000 / 1_000_000_000)
            .rounded()
        )
      )
    )
    let end = max(
      start + 1,
      min(
        wave.sampleCount,
        Int(
          (Double(window.endNanoseconds) * 16_000 / 1_000_000_000)
            .rounded()
        )
      )
    )
    var squareSum = 0.0
    var peak = 0.0
    var active = 0
    for index in start..<end {
      let value = abs(Double(wave.sample(at: index)) / 32_768)
      squareSum += value * value
      peak = max(peak, value)
      if value >= 0.01 { active += 1 }
    }
    let count = end - start
    return (
      sqrt(squareSum / Double(count)),
      peak,
      Double(active) / Double(count)
    )
  }

  private static func writeFloat32(
    wave: PCM16Wave,
    startSample: Int,
    endSample: Int,
    relativePath: String,
    outputRoot: URL
  ) throws -> SpeakerPreparedAudioAsset {
    guard AMISpeakerLocalRun.safeRelativePath(relativePath),
      startSample >= 0,
      endSample <= wave.sampleCount,
      endSample > startSample
    else {
      throw AMIPublicSpeakerEvaluationError.unsafePath
    }
    let destination = outputRoot.appendingPathComponent(relativePath)
    let parent = destination.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent,
      withIntermediateDirectories: true
    )
    let temporary = parent.appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
    )
    guard
      FileManager.default.createFile(
        atPath: temporary.path,
        contents: nil
      )
    else {
      throw AMIPublicSpeakerEvaluationError.invalidAudio(relativePath)
    }
    do {
      let handle = try FileHandle(forWritingTo: temporary)
      defer { try? handle.close() }
      var hasher = SHA256()
      let chunkSamples = 16_384
      var cursor = startSample
      while cursor < endSample {
        let count = min(chunkSamples, endSample - cursor)
        var words = [UInt32](repeating: 0, count: count)
        for index in 0..<count {
          let pcm = wave.sample(at: cursor + index)
          let value = Float(pcm) / 32_768
          words[index] = value.bitPattern.littleEndian
        }
        let data = words.withUnsafeBytes { Data($0) }
        hasher.update(data: data)
        try handle.write(contentsOf: data)
        cursor += count
      }
      try handle.synchronize()
      try handle.close()
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: temporary, to: destination)
      let sampleCount = endSample - startSample
      return SpeakerPreparedAudioAsset(
        relativePath: relativePath,
        contentDigest: hasher.finalize().map {
          String(format: "%02x", $0)
        }.joined(),
        sampleCount: sampleCount,
        durationNanoseconds: UInt64(
          (Double(sampleCount) * 1_000_000_000 / 16_000).rounded()
        )
      )
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  private static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func deterministicUUID(_ seed: String) -> UUID {
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      )
    )
  }
}

private struct EvaluationRoots {
  let tuning: URL
  let releaseHoldout: URL

  init(tuning: URL, releaseHoldout: URL) throws {
    let tuning = tuning.resolvingSymlinksInPath().standardizedFileURL
    let holdout = releaseHoldout.resolvingSymlinksInPath().standardizedFileURL
    guard tuning.isFileURL,
      holdout.isFileURL,
      tuning.path != "/",
      holdout.path != "/",
      tuning != holdout,
      !Self.descendant(tuning, of: holdout),
      !Self.descendant(holdout, of: tuning)
    else {
      throw AMIPublicSpeakerEvaluationError.rootsNotSeparated
    }
    self.tuning = tuning
    self.releaseHoldout = holdout
  }

  private static func descendant(_ candidate: URL, of root: URL) -> Bool {
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return candidate.path.hasPrefix(prefix)
  }
}

private struct AnnotatedSegment: Equatable {
  let startNanoseconds: UInt64
  let endNanoseconds: UInt64

  var durationNanoseconds: UInt64 { endNanoseconds - startNanoseconds }
}

private final class SegmentXMLDelegate: NSObject, XMLParserDelegate {
  private(set) var segments: [AnnotatedSegment] = []

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    guard elementName == "segment",
      let startValue = attributeDict["transcriber_start"],
      let endValue = attributeDict["transcriber_end"],
      let start = Double(startValue),
      let end = Double(endValue),
      start.isFinite,
      end.isFinite,
      start >= 0,
      end > start
    else { return }
    segments.append(
      AnnotatedSegment(
        startNanoseconds: UInt64((start * 1_000_000_000).rounded()),
        endNanoseconds: UInt64((end * 1_000_000_000).rounded())
      )
    )
  }
}

private struct IdentityRecipe {
  let role: SpeakerIdentitySampleRole
  let mode: SpeakerEvaluationEntryMode
  let signal: String
}

private struct PCM16Wave {
  let data: Data
  let payloadRange: Range<Int>
  let sampleCount: Int

  init(url: URL) throws {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count >= 44,
      Self.ascii(data, 0, 4) == "RIFF",
      Self.ascii(data, 8, 4) == "WAVE"
    else {
      throw AMIPublicSpeakerEvaluationError.invalidAudio(url.lastPathComponent)
    }
    var offset = 12
    var format: UInt16?
    var channels: UInt16?
    var sampleRate: UInt32?
    var bits: UInt16?
    var payload: Range<Int>?
    while offset + 8 <= data.count {
      let chunkID = Self.ascii(data, offset, 4)
      let chunkSize = Int(Self.uint32LE(data, offset + 4))
      let start = offset + 8
      guard chunkSize >= 0, start <= data.count - chunkSize else {
        throw AMIPublicSpeakerEvaluationError.invalidAudio(url.lastPathComponent)
      }
      let end = start + chunkSize
      if chunkID == "fmt " {
        guard chunkSize >= 16 else {
          throw AMIPublicSpeakerEvaluationError.invalidAudio(url.lastPathComponent)
        }
        format = Self.uint16LE(data, start)
        channels = Self.uint16LE(data, start + 2)
        sampleRate = Self.uint32LE(data, start + 4)
        bits = Self.uint16LE(data, start + 14)
      } else if chunkID == "data" {
        payload = start..<end
      }
      offset = end + (chunkSize % 2)
    }
    guard format == 1,
      channels == 1,
      sampleRate == 16_000,
      bits == 16,
      let payload,
      payload.count > 0,
      payload.count.isMultiple(of: 2)
    else {
      throw AMIPublicSpeakerEvaluationError.invalidAudio(url.lastPathComponent)
    }
    self.data = data
    payloadRange = payload
    sampleCount = payload.count / 2
  }

  func sample(at index: Int) -> Int16 {
    let offset = payloadRange.lowerBound + index * 2
    return Int16(bitPattern: Self.uint16LE(data, offset))
  }

  private static func ascii(_ data: Data, _ offset: Int, _ count: Int) -> String {
    String(decoding: data[offset..<(offset + count)], as: UTF8.self)
  }

  private static func uint16LE(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  private static func uint32LE(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset])
      | (UInt32(data[offset + 1]) << 8)
      | (UInt32(data[offset + 2]) << 16)
      | (UInt32(data[offset + 3]) << 24)
  }
}
