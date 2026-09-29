import BestASRInference
import XCTest

@testable import BestASRMLXRuntime

/// 翻译 and 指令 call the model directly rather than through a
/// `LocalTextTaskID`, because the task pipeline accepts a candidate only when
/// it is a subsequence of the input — deletion only — and both of these
/// replace the text by construction. That makes their own bounds the only
/// thing standing between the model and the user's document.
final class MLXSpokenModeTests: XCTestCase {
  func testAnInstructionAboutHighlightedTextCarriesBoth() async throws {
    let generator = SpokenModeStubGenerator(output: "Shorter version.")
    let runtime = MLXLocalTextRuntime(generator: generator)

    _ = try await runtime.follow(
      instruction: "把它改短一点", on: "This is a long paragraph that says very little.")

    let call = await generator.lastCall
    let sent = try XCTUnwrap(call)
    XCTAssertTrue(sent.prompt.contains("<selection>"))
    XCTAssertTrue(sent.prompt.contains("This is a long paragraph"))
    XCTAssertTrue(sent.prompt.contains("<instruction>"))
    XCTAssertTrue(sent.prompt.contains("把它改短一点"))
    XCTAssertTrue(sent.instructions.contains("highlighted"))
    XCTAssertTrue(
      sent.prompt.hasSuffix("/no_think"),
      "Asking for non-thinking mode turned a 2.1 s answer into 180 ms"
    )
  }

  /// A question with one right answer never reaches the model.
  func testAComputableQuestionIsComputedNotGenerated() async throws {
    let generator = SpokenModeStubGenerator(output: "四百五十五")
    let runtime = MLXLocalTextRuntime(generator: generator)

    let answer = try await runtime.follow(instruction: "十七乘以二十三等于多少", on: nil)

    XCTAssertEqual(answer, "391")
    let calls = await generator.calls
    XCTAssertEqual(calls, 0, "The model is not consulted about arithmetic")
  }

  func testAnInstructionAboutASelectionIsNeverTreatedAsArithmetic() async throws {
    let generator = SpokenModeStubGenerator(output: "改好的文字")
    let runtime = MLXLocalTextRuntime(generator: generator)

    // The selection is what the instruction acts on; a number inside it must
    // not turn the request into a sum.
    _ = try await runtime.follow(instruction: "把这段改短一点", on: "十七乘以二十三")

    let calls = await generator.calls
    XCTAssertEqual(calls, 1)
  }

  /// With nothing highlighted the instruction stands alone, and the model is
  /// told to answer rather than to edit — there is nothing to edit.
  func testAnInstructionWithNothingHighlightedIsSentAlone() async throws {
    let generator = SpokenModeStubGenerator(output: "42")
    let runtime = MLXLocalTextRuntime(generator: generator)

    // Not a computable question — those never reach the model at all.
    _ = try await runtime.follow(instruction: "写一句话回复说我明天没空", on: nil)

    let call = await generator.lastCall
    let sent = try XCTUnwrap(call)
    XCTAssertTrue(sent.prompt.hasPrefix("写一句话回复说我明天没空"))
    XCTAssertFalse(sent.prompt.contains("<selection>"))
    XCTAssertTrue(sent.instructions.contains("answer"))
  }

  /// An empty answer must fail rather than be delivered: a rewrite that came
  /// back blank would otherwise replace the user's selection with nothing,
  /// which reads as the app having silently eaten it.
  func testAnEmptyAnswerFailsInsteadOfBeingDelivered() async {
    let runtime = MLXLocalTextRuntime(
      generator: SpokenModeStubGenerator(output: "   \n  "))
    do {
      _ = try await runtime.follow(instruction: "改短一点", on: "说点什么")
      XCTFail("expected an output bounds failure")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.code, "mlx-local-text-command-output-bounds")
    } catch {
      XCTFail("unexpected error \(error)")
    }
  }

  func testBlankAndOversizedRequestsNeverReachTheModel() async {
    let generator = SpokenModeStubGenerator(output: "x")
    let runtime = MLXLocalTextRuntime(generator: generator)
    for source in ["   ", String(repeating: "字", count: 20_000)] {
      do {
        _ = try await runtime.follow(instruction: source, on: nil)
        XCTFail("expected a bounds failure")
      } catch let error as InferenceEngineError {
        XCTAssertEqual(error.code, "mlx-local-text-command-bounds")
      } catch {
        XCTFail("unexpected error \(error)")
      }
    }
    let calls = await generator.calls
    XCTAssertEqual(calls, 0)
  }

  /// The model once answered "翻译成英文" with "Use non-thinking mode." —
  /// the sentence that used to be appended to every prompt. Such an answer
  /// is a failure, not a result to write into the user's document.
  func testAnAnswerThatEchoesTheModeSwitchFails() async {
    let runtime = MLXLocalTextRuntime(
      generator: SpokenModeStubGenerator(output: "Use non-thinking mode."))
    do {
      _ = try await runtime.follow(instruction: "翻译成英文", on: nil)
      XCTFail("expected an output bounds failure")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.code, "mlx-local-text-command-output-bounds")
    } catch {
      XCTFail("unexpected error \(error)")
    }
  }

  func testAnAnswerThatOverrunsItsBudgetFailsRetryably() async {
    let runtime = MLXLocalTextRuntime(
      generator: SpokenModeStubGenerator(output: "慢", delayNanoseconds: 400_000_000),
      policy: MLXLocalTextRuntimePolicy(generationTimeoutMilliseconds: 20)
    )
    do {
      _ = try await runtime.follow(instruction: "写一段话", on: nil)
      XCTFail("expected a timeout")
    } catch let error as InferenceEngineError {
      XCTAssertEqual(error.code, "mlx-local-text-command-timeout")
      XCTAssertTrue(error.retryable)
    } catch {
      XCTFail("unexpected error \(error)")
    }
  }

  func testAnEmptyThinkingPrefixIsRemovedFromAnAnswer() async throws {
    let runtime = MLXLocalTextRuntime(
      generator: SpokenModeStubGenerator(output: "<think>\n\n</think>\n\nBerlin"))
    let text = try await runtime.follow(instruction: "德国首都是哪里", on: nil)
    XCTAssertEqual(text, "Berlin")
  }

  /// Both shapes below came off the installed weights with non-thinking mode
  /// asked for. The task pipeline refuses either, because its output feeds a
  /// strict parser; free text keeps the answer, since a model that reasoned
  /// first has still answered and refusing it would report a failure while
  /// holding the result.
  func testReasoningIsDroppedWhetherOrNotTheModelClosesIt() {
    XCTAssertEqual(
      MLXLocalTextRuntime.strippingThinking(
        from: "<think>\nLet me work through this.\n</think>\nThe answer."
      ).trimmingCharacters(in: .whitespacesAndNewlines),
      "The answer."
    )
    // Seen on short inputs: the block is opened and the answer given inside it.
    XCTAssertEqual(
      MLXLocalTextRuntime.strippingThinking(from: "<think>\n\nWe'll run it once.")
        .trimmingCharacters(in: .whitespacesAndNewlines),
      "We'll run it once."
    )
    XCTAssertEqual(
      MLXLocalTextRuntime.strippingThinking(from: "No envelope at all."),
      "No envelope at all."
    )
  }
}

private actor SpokenModeStubGenerator: MLXTextGenerating {
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
