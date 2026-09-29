import BestASRDictation
import BestASRDomain
import BestASRProcessing
import XCTest

@testable import bestASR

final class PersonalDictationCleanupTests: XCTestCase {
  private func request(_ text: String) -> DictationPolishRequest {
    DictationPolishRequest(
      sessionID: SessionID(),
      transcript: DictationTranscriptResult(
        revisionID: TranscriptRevisionID(), segmentIDs: [], text: text,
        modelArtifactID: "fixture"),
      dictionaryTerms: [],
      targetBundleIdentifier: nil)
  }

  func testFaithfulCleanupIsInsertedAndCreditedToThePersonalModel() async throws {
    let cleaned = "这个方案我们可以先跑一遍，然后再看看结果，再决定要不要调参数。"
    let generator = StubCleanupGenerator(output: cleaned)
    let adapter = PersonalDictationCleanupAdapter(
      service: PersonalDictationCleanupService(generator: generator),
      revision: "personal-cleanup:2026-09-19")
    let result = try await adapter.polish(
      request("嗯，这个这个方案我们可以先跑一遍，然后然后再看看结果，再决定要不要调参数"))
    XCTAssertEqual(result.text, cleaned)
    XCTAssertEqual(result.disposition, .model)
    XCTAssertEqual(result.modelArtifactID, "personal-cleanup:2026-09-19")
  }

  func testARewritingModelFallsBackToTheRuleCleanedTranscript() async throws {
    let raw = "嗯，我们先把虚构样机的效果测一下，再决定要不要改配色"
    let adapter = PersonalDictationCleanupAdapter(
      service: PersonalDictationCleanupService(
        generator: StubCleanupGenerator(output: "我们先把虚构问题的整体效果测一下，再决定要不要改设计。")),
      revision: "personal-cleanup:2026-09-19")
    let result = try await adapter.polish(request(raw))
    XCTAssertEqual(result.text, DictationTextCleanup.apply(raw))
    XCTAssertEqual(result.disposition, .punctuationOnlyFallback)
    XCTAssertNil(result.modelArtifactID)
  }

  func testAFailingModelStillInsertsTheRuleCleanedTranscript() async throws {
    let adapter = PersonalDictationCleanupAdapter(
      service: PersonalDictationCleanupService(generator: StubCleanupGenerator(failing: true)),
      revision: "personal-cleanup:2026-09-19")
    let raw = "嗯，随便说两句，看看这个模型在失败的时候会怎么处理这段文字"
    let result = try await adapter.polish(request(raw))
    XCTAssertEqual(result.text, DictationTextCleanup.apply(raw))
    XCTAssertEqual(result.disposition, .punctuationOnlyFallback)
  }

  func testTextCleanedUpAtAPauseIsNotGeneratedAgainAtRelease() async throws {
    let generator = StubCleanupGenerator(output: "这句话已经整理过了。")
    let service = PersonalDictationCleanupService(generator: generator)
    let raw = "嗯，这句话已经整理过了"
    await service.precompute(raw)
    let first = await service.cleanUp(raw)
    let second = await service.cleanUp(raw)
    XCTAssertEqual(first, "这句话已经整理过了。")
    XCTAssertEqual(second, first)
    let calls = await generator.calls
    XCTAssertEqual(calls, 1)
  }

  func testAShortDictationIsNotDelayedByTheModelUnlessAPauseAlreadyCleanedIt() async throws {
    let generator = StubCleanupGenerator(output: "短句。")
    let service = PersonalDictationCleanupService(generator: generator)
    let adapter = PersonalDictationCleanupAdapter(
      service: service, revision: "personal-cleanup:2026-09-19")
    let short = "嗯，短句"
    let first = try await adapter.polish(request(short))
    XCTAssertEqual(first.disposition, .punctuationOnlyFallback)
    let callsBeforePause = await generator.calls
    XCTAssertEqual(callsBeforePause, 0)

    await service.precompute(short)
    _ = await service.cleanUp(short)
    let second = try await adapter.polish(request(short))
    XCTAssertEqual(second.text, "短句。")
    XCTAssertEqual(second.disposition, .model)
  }

  func testTheModelIsLoadedOnceWhileTheUserIsStillSpeaking() async throws {
    let generator = StubCleanupGenerator(output: "整理好的文字。")
    let service = PersonalDictationCleanupService(generator: generator)
    await service.warmUp()
    await service.warmUp()
    for _ in 0..<20 where await generator.prepareCalls == 0 {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let prepared = await generator.prepareCalls
    XCTAssertEqual(prepared, 1)
  }

  func testReleasingDropsTheModelAndEverythingItProduced() async throws {
    let generator = StubCleanupGenerator(output: "整理好的文字。")
    let service = PersonalDictationCleanupService(generator: generator)
    let raw = "嗯，这段话已经整理过了，留着给下一次用"
    _ = await service.cleanUp(raw)
    await service.release()
    for _ in 0..<20 where await generator.releaseCalls == 0 {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    let released = await generator.releaseCalls
    XCTAssertEqual(released, 1)
    // The cached answer is gone with the model, so it is produced again.
    _ = await service.cleanUp(raw)
    let calls = await generator.calls
    XCTAssertEqual(calls, 2)
  }

  func testAnEmptyTranscriptIsKeptAsIs() async throws {
    let adapter = PersonalDictationCleanupAdapter(
      service: PersonalDictationCleanupService(generator: StubCleanupGenerator(output: "x")),
      revision: "personal-cleanup:2026-09-19")
    let result = try await adapter.polish(request("   "))
    XCTAssertEqual(result.text, "   ")
    XCTAssertEqual(result.disposition, .rawTranscriptFallback)
  }

  func testAModelDirectoryCountsAsInstalledOnlyWhenItIsComplete() throws {
    let root = URL(
      fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
    ).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let directory = root.appendingPathComponent(
      PersonalDictationCleanupModel.relativePath, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertNil(PersonalDictationCleanupModel.installedDirectory(applicationSupport: root))
    for name in ["config.json", "tokenizer.json", "model.safetensors"] {
      try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
    }
    let found = PersonalDictationCleanupModel.installedDirectory(applicationSupport: root)
    XCTAssertEqual(found?.lastPathComponent, "current")
    XCTAssertEqual(
      PersonalDictationCleanupModel.revision(of: directory), "personal-cleanup:current")
  }
}

private actor StubCleanupGenerator: DictationCleanupGenerating {
  private let output: String
  private let failing: Bool
  private(set) var calls = 0
  private(set) var prepareCalls = 0
  private(set) var releaseCalls = 0

  init(output: String = "", failing: Bool = false) {
    self.output = output
    self.failing = failing
  }

  func prepareModel() async throws { prepareCalls += 1 }

  func releaseModel() async { releaseCalls += 1 }

  func cleanUp(_: String) async throws -> String {
    calls += 1
    if failing { throw CancellationError() }
    return output
  }
}
