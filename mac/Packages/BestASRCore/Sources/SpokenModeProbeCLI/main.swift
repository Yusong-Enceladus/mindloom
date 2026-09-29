import BestASRInference
import BestASRMLXRuntime
import BestASRModelManager
import Foundation

/// Measures 翻译 and 指令 on the model that is actually installed.
///
/// Both modes sit between a finished dictation and the insertion that
/// delivers it, so their cost is paid with the user waiting and their output
/// goes straight into someone else's document. Neither is something to take on
/// trust from a unit test with a stub generator: this runs the real weights
/// and prints what came back, with the milliseconds it took.
///
/// The sentences are the probe's own. No history, no transcript and no
/// selected text is read.
///
/// Usage: SpokenModeProbeCLI --models <application-support>/bestASR/models
@main
enum SpokenModeProbeCLI {
  static func main() async {
    do { try await run(Arguments(CommandLine.arguments.dropFirst())) } catch {
      FileHandle.standardError.write(Data("error: \(error)\n".utf8))
      exit(1)
    }
  }

  struct Arguments {
    var models: URL
    var registry: URL
    /// Which pinned text model to load: "selected" (the one the App uses),
    /// "large" or "small", so a candidate can be measured before it is adopted.
    var artifact: MLXLocalTextArtifact

    init(_ arguments: some Sequence<String>) {
      var models: URL?
      var registry: URL?
      var artifact = MLXLocalTextArtifact.qwen3Selected
      var iterator = arguments.makeIterator()
      while let argument = iterator.next() {
        switch argument {
        case "--models": models = iterator.next().map { URL(fileURLWithPath: $0) }
        case "--registry": registry = iterator.next().map { URL(fileURLWithPath: $0) }
        case "--artifact":
          switch iterator.next() {
          case "large": artifact = .qwen3Large
          case "small": artifact = .qwen3Small
          default: artifact = .qwen3Selected
          }
        default: continue
        }
      }
      guard let models, let registry else {
        FileHandle.standardError.write(
          Data("usage: --models dir --registry model-artifacts.json [--artifact selected|large|small]\n".utf8))
        exit(64)
      }
      self.models = models
      self.registry = registry
      self.artifact = artifact
    }
  }

  struct Case {
    let title: String
    let run: (MLXLocalTextRuntime) async throws -> String
  }

  static func run(_ arguments: Arguments) async throws {
    let manager = try LocalModelManager(
      rootDirectory: arguments.models,
      registry: try ManagedModelRegistry.decode(Data(contentsOf: arguments.registry))
    )
    let loadStarted = ContinuousClock.now
    let runtime = try await MLXLocalTextRuntimeFactory.makeRuntime(
      modelManager: manager,
      artifact: arguments.artifact,
      prepare: true
    )
    print("\(arguments.artifact.artifactID) load \(milliseconds(since: loadStarted)) ms")

    // Translation is the system engine's job now and is not measured here.
    // What remains is what the local model is actually asked to do: rewrite,
    // answer, and write — the jobs a general prompt has to carry unclamped.
    let cases: [Case] = [
      Case(title: "command/rewrite") { runtime in
        try await runtime.follow(
          instruction: "把这段改得更简短一点",
          on: "I wanted to reach out and let you know that I have gone ahead and "
            + "completed the task that we discussed during our meeting yesterday."
        )
      },
      Case(title: "command/rewrite-zh") { runtime in
        try await runtime.follow(
          instruction: "改成更正式的说法", on: "这事儿我明天弄完，你别急")
      },
      Case(title: "command/answer-unit") { runtime in
        try await runtime.follow(instruction: "一英里等于多少公里", on: nil)
      },
      Case(title: "command/answer-fact") { runtime in
        try await runtime.follow(instruction: "澳大利亚的首都是哪里", on: nil)
      },
      Case(title: "command/answer-arith") { runtime in
        try await runtime.follow(instruction: "十七乘以二十三等于多少", on: nil)
      },
      Case(title: "command/write") { runtime in
        try await runtime.follow(
          instruction: "写一句话回复说我明天上午没空，改到下午两点", on: nil)
      },
      Case(title: "command/rewrite-en-tone") { runtime in
        try await runtime.follow(
          instruction: "改得更礼貌一些",
          on: "Send me the report by tonight. I don't want to hear excuses."
        )
      },
      Case(title: "command/summarize") { runtime in
        try await runtime.follow(
          instruction: "总结一下这段在说什么",
          on: "We tried the new build on three machines. Two inserted text fine; "
            + "on the third the paste went nowhere and the capsule still showed a "
            + "checkmark, so the words were lost. The log had focus=lost each time."
        )
      },
      Case(title: "command/write-en") { runtime in
        try await runtime.follow(
          instruction: "write a one-line reply saying I'll review the PR after lunch", on: nil)
      },
    ]

    for probe in cases {
      let started = ContinuousClock.now
      do {
        let output = try await probe.run(runtime)
        print("\(probe.title) \(milliseconds(since: started)) ms")
        print("  \(output.replacingOccurrences(of: "\n", with: "\n  "))")
      } catch {
        print("\(probe.title) \(milliseconds(since: started)) ms FAILED \(error)")
      }
    }
    await runtime.release()
  }

  static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    Int((ContinuousClock.now - start).components.attoseconds / 1_000_000_000_000_000)
      + Int((ContinuousClock.now - start).components.seconds) * 1_000
  }
}
