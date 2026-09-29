import BestASRDomain
import Foundation
import XCTest

@testable import BestASRSpeakerRouting

final class SpeakerRoutingTests: XCTestCase {
  func testPairedFixturesUseOneGlobalPersonSpaceAcrossEveryInputMode() throws {
    let suite = try loadSuite()
    let policy = try SpeakerRoutingPolicy.contractProbe()
    let paired = suite.scenarios.filter { $0.scenarioID.hasPrefix("paired-") }
    var results: [SpeakerRoutingResult] = []

    for (index, scenario) in paired.enumerated() {
      let result = try UnifiedSpeakerRouter.route(
        try makeRequest(scenario: scenario, index: index),
        policy: policy
      )
      results.append(result)
      XCTAssertEqual(result.sessionSpeakers.count, 1)
      XCTAssertEqual(result.occurrences.count, 1)
      XCTAssertEqual(result.occurrences.first?.association.status, .automaticMatch)
      XCTAssertEqual(result.history.referencedPersonIDs, [suite.sharedPersonID])
    }

    // Every audio entry point; a pasted or dragged item has no speakers.
    XCTAssertEqual(
      Set(results.map(\.inputMode)),
      Set(SessionInputMode.allCases.filter { $0 != .userItem }))
    XCTAssertTrue(
      results.allSatisfy {
        $0.history.occurrences.first?.association.personID == suite.sharedPersonID
      }
    )
    let encoded = try XCTUnwrap(
      String(data: JSONEncoder().encode(results), encoding: .utf8)
    )
    XCTAssertFalse(encoded.contains("DictationPerson"))
    XCTAssertFalse(encoded.contains("ImportPerson"))
    XCTAssertFalse(encoded.contains("rowID"))
  }

  func testDictationOneTwoThreePeopleRapidTurnsAndInsufficientEvidence() throws {
    let suite = try loadSuite()
    let policy = try SpeakerRoutingPolicy.contractProbe()

    for (index, scenario) in suite.scenarios.enumerated() {
      let result = try UnifiedSpeakerRouter.route(
        try makeRequest(scenario: scenario, index: index),
        policy: policy
      )
      let statuses = result.occurrences.map(\.association.status)
      XCTAssertEqual(result.sessionSpeakers.count, scenario.speakerCount, scenario.scenarioID)
      XCTAssertEqual(result.occurrences.count, scenario.turnCount, scenario.scenarioID)
      XCTAssertEqual(
        statuses.filter { $0 == .automaticMatch }.count,
        scenario.expectedAutomatic,
        scenario.scenarioID
      )
      XCTAssertEqual(
        statuses.filter { $0 == .candidate }.count,
        scenario.expectedCandidate,
        scenario.scenarioID
      )
      XCTAssertEqual(
        statuses.filter { $0 == .unknown }.count,
        scenario.expectedUnknown,
        scenario.scenarioID
      )
      XCTAssertEqual(result.history.occurrences, result.occurrences)
    }

    let rapid = try XCTUnwrap(
      suite.scenarios.first {
        $0.scenarioID == "dictation-two-person-rapid-alternation"
      }
    )
    let rapidResult = try UnifiedSpeakerRouter.route(
      try makeRequest(scenario: rapid, index: 50),
      policy: policy
    )
    let alternatingOrdinals = rapidResult.occurrences.map { occurrence in
      rapidResult.sessionSpeakers.first {
        $0.id == occurrence.sessionSpeakerID
      }?.stableOrdinal
    }
    XCTAssertEqual(alternatingOrdinals, [0, 1, 0, 1, 0, 1])

    let insufficient = suite.scenarios.filter {
      $0.scenarioID.contains("insufficient")
    }
    XCTAssertEqual(insufficient.count, 4)
    for (index, scenario) in insufficient.enumerated() {
      let result = try UnifiedSpeakerRouter.route(
        try makeRequest(scenario: scenario, index: 60 + index),
        policy: policy
      )
      let occurrence = try XCTUnwrap(result.occurrences.first)
      XCTAssertEqual(occurrence.association.status, .unknown)
      XCTAssertNil(occurrence.association.personID)
      XCTAssertEqual(
        result.history.sessionSpeakers.first?.id,
        occurrence.sessionSpeakerID,
        "unknown identity must remain stable through SessionSpeaker"
      )
    }
  }

  func testWrongSourceRolesAreRejectedForEveryMode() throws {
    let suite = try loadSuite()
    let policy = try SpeakerRoutingPolicy.contractProbe()
    let cases: [(SessionInputMode, SourceTrackRole)] = [
      (.dictation, .systemRemote),
      (.roomMicrophone, .importedSource),
      (.systemAudio, .roomMicrophone),
      (.importedMedia, .microphoneLocal),
    ]

    for (index, pair) in cases.enumerated() {
      let base = try XCTUnwrap(
        suite.scenarios.first { $0.inputMode == pair.0 }
      )
      XCTAssertThrowsError(
        try UnifiedSpeakerRouter.route(
          try makeRequest(
            scenario: base,
            index: 80 + index,
            overrideRole: pair.1
          ),
          policy: policy
        )
      ) { error in
        XCTAssertEqual(
          error as? SpeakerRoutingError,
          .sourceRoleNotAllowed(pair.0, pair.1)
        )
      }
    }
  }

  func testDefaultDictationInsertionIsPlainNonblockingAndIdempotent() throws {
    let suite = try loadSuite()
    let scenario = try XCTUnwrap(
      suite.scenarios.first { $0.scenarioID == "dictation-three-person" }
    )
    let request = try makeRequest(scenario: scenario, index: 90)
    let result = try UnifiedSpeakerRouter.route(
      request,
      policy: try SpeakerRoutingPolicy.contractProbe()
    )
    let transcript = TranscriptRevision(
      id: TranscriptRevisionID(uuid(9_001)),
      sessionID: request.session.id,
      revision: try Revision(2),
      parentID: nil,
      kind: .final,
      content: "纯文字 plain text",
      modelArtifactID: nil,
      configHash: nil,
      createdAt: Date(timeIntervalSince1970: 1)
    )

    let firstProjection = DefaultDictationInsertionRenderer.render(
      session: request.session,
      transcript: transcript
    )
    let secondProjection = DefaultDictationInsertionRenderer.render(
      session: request.session,
      transcript: transcript
    )
    let command = try XCTUnwrap(firstProjection.commands.first)
    var durableInsertionKeys = Set<String>()
    for projection in [firstProjection, secondProjection] {
      for item in projection.commands {
        durableInsertionKeys.insert(item.idempotencyKey)
      }
    }

    XCTAssertEqual(firstProjection.commands.count, 1)
    XCTAssertEqual(command.text, transcript.content)
    XCTAssertFalse(command.speakerLabelsIncluded)
    XCTAssertFalse(command.waitsForSpeakerResolution)
    XCTAssertEqual(durableInsertionKeys.count, 1)
    XCTAssertEqual(result.history.sessionSpeakers.count, 3)
    XCTAssertEqual(result.history.occurrences.count, 3)
    XCTAssertEqual(
      Set(result.history.occurrences.map(\.id)),
      Set(result.occurrences.map(\.id))
    )
  }

  private func makeRequest(
    scenario: SpeakerRoutingFixtureScenario,
    index: Int,
    overrideRole: SourceTrackRole? = nil
  ) throws -> SpeakerRoutingRequest {
    let sessionID = SessionID(uuid(UInt64(10_000 + index)))
    let trackID = TrackID(uuid(UInt64(20_000 + index)))
    let revision = try Revision(1)
    let session = Session(
      id: sessionID,
      revision: revision,
      inputMode: scenario.inputMode,
      state: .completed,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 2)
    )
    let track = SourceTrack(
      id: trackID,
      sessionID: sessionID,
      revision: revision,
      role: overrideRole ?? scenario.trackRole,
      assetReference: try PortableAssetReference(
        relativePath: "sessions/fixture-\(index)/source.caf"
      ),
      sampleRateHertz: 16_000,
      channelCount: 1
    )

    var turnsBySpeaker = Array(
      repeating: [SpeakerTurnEvidence](),
      count: scenario.speakerCount
    )
    for turnIndex in 0..<scenario.turnCount {
      let speakerIndex =
        scenario.pattern == .rapid
        ? turnIndex % scenario.speakerCount
        : min(turnIndex, scenario.speakerCount - 1)
      let step: UInt64 = scenario.pattern == .rapid ? 500_000_000 : 1_000_000_000
      let start = UInt64(turnIndex) * step
      let duration: UInt64 = scenario.pattern == .short ? 100_000_000 : step
      let disposition = scenario.matchDispositions[speakerIndex]
      let match: PersonMatchEvidence?
      switch disposition {
      case .sharedAutomatic:
        match = PersonMatchEvidence(
          personID: try loadSuite().sharedPersonID,
          confidence: try Confidence(0.97)
        )
      case .automatic:
        match = PersonMatchEvidence(
          personID: PersonID(uuid(UInt64(30_000 + index * 10 + speakerIndex))),
          confidence: try Confidence(0.97)
        )
      case .candidate:
        match = PersonMatchEvidence(
          personID: PersonID(uuid(UInt64(30_000 + index * 10 + speakerIndex))),
          confidence: try Confidence(0.80)
        )
      case .none:
        match = nil
      }
      turnsBySpeaker[speakerIndex].append(
        SpeakerTurnEvidence(
          occurrenceID: SpeakerOccurrenceID(
            uuid(UInt64(40_000 + index * 100 + turnIndex))
          ),
          trackIDs: [trackID],
          monotonicStartNanoseconds: start,
          monotonicEndNanoseconds: start + duration,
          overlapsAnotherSpeaker: scenario.pattern == .overlap,
          isBackgroundSpeech: scenario.pattern == .background,
          signalQuality: try Confidence(
            scenario.pattern == .lowQuality ? 0.40 : 0.95
          ),
          personMatch: match
        )
      )
    }
    let clusters = turnsBySpeaker.enumerated().map { speakerIndex, turns in
      SpeakerClusterEvidence(
        sessionSpeakerID: SessionSpeakerID(
          uuid(UInt64(50_000 + index * 10 + speakerIndex))
        ),
        stableOrdinal: UInt32(speakerIndex),
        turns: turns
      )
    }
    return SpeakerRoutingRequest(
      session: session,
      tracks: [track],
      evidenceRevision: revision,
      clusters: clusters
    )
  }

  private func loadSuite() throws -> SpeakerRoutingFixtureSuite {
    let data = try Data(
      contentsOf: repositoryRoot.appendingPathComponent(
        "Tests/Fixtures/SpeakerRouting/paired-routing.json"
      )
    )
    let suite = try JSONDecoder().decode(SpeakerRoutingFixtureSuite.self, from: data)
    XCTAssertEqual(suite.schemaVersion, 1)
    XCTAssertEqual(suite.kind, "speaker-routing-fixtures")
    return suite
  }

  private func uuid(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", value))!
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

private struct SpeakerRoutingFixtureSuite: Codable {
  let schemaVersion: Int
  let kind: String
  let sharedPersonID: PersonID
  let scenarios: [SpeakerRoutingFixtureScenario]
}

private struct SpeakerRoutingFixtureScenario: Codable {
  let scenarioID: String
  let inputMode: SessionInputMode
  let trackRole: SourceTrackRole
  let speakerCount: Int
  let turnCount: Int
  let pattern: SpeakerFixturePattern
  let matchDispositions: [SpeakerFixtureMatchDisposition]
  let expectedAutomatic: Int
  let expectedCandidate: Int
  let expectedUnknown: Int
}

private enum SpeakerFixturePattern: String, Codable {
  case background
  case lowQuality = "low-quality"
  case overlap
  case rapid
  case short
  case standard
}

private enum SpeakerFixtureMatchDisposition: String, Codable {
  case automatic
  case candidate
  case none
  case sharedAutomatic = "shared-automatic"
}
