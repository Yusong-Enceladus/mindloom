import BestASRInference
@testable import BestASRMLXRuntime
import XCTest

final class MLXDictationCleanupTests: XCTestCase {
  func testTheDictationIsSentAsTheUserTurnWithTheTrainedSystemMessage() async throws {
    let generator = CleanupStubGenerator(output: "这个方案可以先跑一遍，然后再看结果。")
    let runtime = MLXLocalTextRuntime(generator: generator)
    let raw = "嗯，这个这个方案可以先跑一遍，然后然后再看结果"
    let text = try await runtime.cleanUpDictation(raw)
    XCTAssertEqual(text, "这个方案可以先跑一遍，然后再看结果。")
    let sent = await generator.lastCall
    // Anything but the dictation itself would not match how the model was
    // fine-tuned, so no task wrapper, context block or /no_think suffix.
    XCTAssertEqual(sent?.prompt, raw)
    XCTAssertEqual(sent?.instructions, MLXLocalTextRuntime.dictationCleanupInstructions)
  }

  func testAnEmptyThinkingPrefixIsRemoved() async throws {
    let runtime = MLXLocalTextRuntime(
      generator: CleanupStubGenerator(output: "<think>\n\n</think>\n\n整理后的文字"))
    let text = try await runtime.cleanUpDictation("整理后的文字")
    XCTAssertEqual(text, "整理后的文字")
  }

  func testBlankOrOversizedDictationsAreRejectedBeforeTheModelRuns() async {
    let generator = CleanupStubGenerator(output: "x")
    let runtime = MLXLocalTextRuntime(generator: generator)
    for raw in ["   ", String(repeating: "字", count: 20_000)] {
      do {
        _ = try await runtime.cleanUpDictation(raw)
        XCTFail("expected a bounds failure")
      } catch let error as InferenceEngineError {
        XCTAssertEqual(error.code, "mlx-local-text-cleanup-bounds")
      } catch {
        XCTFail("unexpected error \(error)")
      }
    }
    let calls = await generator.calls
    XCTAssertEqual(calls, 0)
  }

  func testGenerationThatOverrunsItsBudgetFailsRetryably() async {
    let policy = MLXLocalTextRuntimePolicy(generationTimeoutMilliseconds: 20)
    let runtime = MLXLocalTextRuntime(
      generator: CleanupStubGenerator(output: "慢", delayNanoseconds: 400_000_000),
      policy: policy)
    do {
      _ = try await runtime.cleanUpDictation("说得有点长")
      XCTFail("expected a timeout")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.code, "mlx-local-text-cleanup-timeout")
      XCTAssertTrue(error.retryable)
    } catch {
      XCTFail("unexpected error \(error)")
    }
  }
}

private actor CleanupStubGenerator: MLXTextGenerating {
  struct Call: Sendable {
    let prompt: String
    let instructions: String
  }

  let output: String
  let delayNanoseconds: UInt64
  private(set) var lastCall: Call?
  private(set) var calls = 0

  init(output: String, delayNanoseconds: UInt64 = 0) {
    self.output = output
    self.delayNanoseconds = delayNanoseconds
  }

  func prepare() {}

  func release() {}

  func generate(
    prompt: String,
    instructions: String,
    policy _: MLXLocalTextRuntimePolicy
  ) async throws -> String {
    calls += 1
    lastCall = Call(prompt: prompt, instructions: instructions)
    if delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: delayNanoseconds)
    }
    return output
  }
}

/// Loads a real personal cleanup model when one is installed. Set
/// BESTASR_PERSONAL_CLEANUP_MODEL to its directory to run it; the suite skips
/// it otherwise, so CI never needs the model.
final class MLXDictationCleanupModelTests: XCTestCase {
  func testTheInstalledModelLoadsAndCleansUpADictation() async throws {
    guard let path = ProcessInfo.processInfo.environment["BESTASR_PERSONAL_CLEANUP_MODEL"]
    else {
      throw XCTSkip("set BESTASR_PERSONAL_CLEANUP_MODEL to the model directory to run this")
    }
    let runtime = MLXLocalTextRuntime(
      verifiedModelDirectory: URL(fileURLWithPath: path, isDirectory: true))
    let loadStarted = ContinuousClock.now
    try await runtime.prepare()
    let generateStarted = ContinuousClock.now
    let text = try await runtime.cleanUpDictation(
      "嗯，这个这个方案我们可以先跑一遍，然后然后再看看结果，再决定要不要调参数")
    let firstDone = ContinuousClock.now
    // The first generation also compiles GPU kernels; the App pays that once.
    let warm = try await runtime.cleanUpDictation(
      "然后然后我们再看一下第二句话，嗯，它的速度大概是多少，这句话稍微长一点点")
    let now = ContinuousClock.now
    print(
      "load \(loadStarted.duration(to: generateStarted)) first "
        + "\(generateStarted.duration(to: firstDone)) warm \(firstDone.duration(to: now)) "
        + "characters \(text.count)/\(warm.count)")
    XCTAssertFalse(text.isEmpty)
    XCTAssertFalse(text.contains("<|"))
    XCTAssertNotNil(text.range(of: "方案"))
  }
}
