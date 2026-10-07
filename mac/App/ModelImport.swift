import BestASRFluidRuntime
import BestASRMemoryUI
import BestASRModelManager
import BestASRRemoteOrganizer
import Foundation

// OWNER: mac-capture. Mindloom Preview's 「使用这台 Mac 上已装的识别模型」
// (Welcome step 1 and Settings › 入口): on the user's click only, the public
// model artifacts the bestASR library already installed are cloned into the
// preview's own data root (`InstalledModelImporter`: registry-listed
// artifacts under `models/` only — never personal models, never records —
// verified, nothing written in the source), through the runtime's own
// LocalModelManager. Other builds never offer it.

extension DictationAppModel {
  /// Offers the import while the preview has no recognition model yet.
  func refreshModelImportOffer() {
    guard MindloomBuild.isPreview else {
      CaptureState.shared.modelImportOffer = nil
      return
    }
    if models.modelRuntimeReady {
      CaptureState.shared.modelImportOffer = .ready
      return
    }
    // Until the launch's model check has finished (a first launch on a root
    // takes a minute or two): models already imported into this root (the
    // trial root comes with them, finish-ship) are not offered again. The
    // check's own answer replaces this (`publishASRReadiness`).
    if !models.modelDiscoveryComplete, Self.ownRootHasImportedSpeechModel() {
      CaptureState.shared.modelImportOffer = .ready
      return
    }
    if case .working? = CaptureState.shared.modelImportOffer { return }
    if case .failed? = CaptureState.shared.modelImportOffer { return }
    // Only whether the folder exists: nothing in it is read before the click.
    let models = BestASRDataRootSelection.ownerRealLibraryRoot()?
      .appendingPathComponent("models", isDirectory: true)
    let exists = models.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    CaptureState.shared.modelImportOffer = exists ? .offered : nil
  }

  /// The preview root's own `models/active` names the base speech model
  /// (a file check only; nothing is read).
  static func ownRootHasImportedSpeechModel() -> Bool {
    guard let root = try? applicationDataRoot() else { return false }
    let pointer = root.appendingPathComponent("models/active", isDirectory: true)
      .appendingPathComponent("\(FluidSenseVoicePinnedArtifact.artifactID).json")
    return FileManager.default.fileExists(atPath: pointer.path)
  }

  /// The user's click: clone, verify, activate, then look for the models.
  func importInstalledModels() {
    guard MindloomBuild.isPreview,
      let realLibrary = BestASRDataRootSelection.ownerRealLibraryRoot(),
      let dataRoot = try? Self.applicationDataRoot(),
      // The preview's own root, never the library it copies from.
      !BestASRDataRootSelection.path(dataRoot, isWithinOrEqualTo: realLibrary),
      // The runtime's own model manager (one actor for this root, so the
      // import and the runtime's activations never interleave) and its
      // registry.
      let runtime = localRuntime
    else {
      CaptureState.shared.modelImportOffer = .failed("未能准备拷贝。可以在“高级设置”中下载识别模型。")
      return
    }
    CaptureState.shared.modelImportOffer = .working
    let source = realLibrary.appendingPathComponent("models", isDirectory: true)
    let manager = runtime.modelManager
    let registry = runtime.modelRegistry
    Task { [weak self] in
      let outcome: InstalledModelImporter.Outcome? = await Task.detached(
        priority: .userInitiated
      ) {
        await InstalledModelImporter(source: source, registry: registry).importAll(into: manager)
      }.value
      guard let self else { return }
      await discoverInstalledModels()
      let taken = (outcome?.imported.count ?? 0) + (outcome?.alreadyActive.count ?? 0)
      if outcome == nil {
        CaptureState.shared.modelImportOffer = .failed("未能拷贝识别模型。可以在“高级设置”中下载。")
      } else if taken == 0 {
        CaptureState.shared.modelImportOffer = .failed("在这台 Mac 上找不到可用的识别模型。")
      } else if models.modelRuntimeReady {
        CaptureState.shared.modelImportOffer = .ready
      } else {
        CaptureState.shared.modelImportOffer = .failed("已拷贝，但识别模型不完整。可以在“高级设置”中补全。")
      }
    }
  }
}

#if MINDLOOM_PREVIEW
  /// Mindloom Preview only: `-MindloomImportModelsAndQuit [<report file>]`
  /// does what 「使用这台 Mac 上已装的识别模型」 does (the same
  /// `InstalledModelImporter`, into the same kind of `LocalModelManager` the
  /// runtime makes for the data root) before any window, and quits. Nothing
  /// else starts: no SwiftUI scene (so no Welcome, no main window, no menu
  /// bar item), no fn, no microphone, no database, no defaults written. Only
  /// a root marked synthetic (`SYNTHETIC_DATA_ROOT`) that is not inside the
  /// real library. The report lists the source paths read (the registry's
  /// pointers and the version folders they name) and, per artifact, what the
  /// root now holds: ids, versions, sizes; never anything personal.
  @MainActor
  enum HeadlessModelImport {
    static let argument = "-MindloomImportModelsAndQuit"

    /// Runs the import and exits when asked; false otherwise.
    static func runIfRequested() -> Bool {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: argument) else { return false }
      let next = index + 1 < arguments.count ? arguments[index + 1] : nil
      let reportURL = next.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
      var lines: [String] = []
      func say(_ line: String) {
        lines.append(line)
        print(line)
      }
      let code = run(say: say)
      if let reportURL {
        try? (lines.joined(separator: "\n") + "\n").write(
          to: reportURL, atomically: true, encoding: .utf8)
      }
      exit(code)
    }

    private final class Result: @unchecked Sendable {
      var outcome: InstalledModelImporter.Outcome?
      var active: [String] = []
    }

    private static func run(say: (String) -> Void) -> Int32 {
      guard let realLibrary = BestASRDataRootSelection.ownerRealLibraryRoot(),
        let dataRoot = try? DictationAppModel.applicationDataRoot()
      else {
        say("refused: no data root")
        return 2
      }
      guard !BestASRDataRootSelection.path(dataRoot, isWithinOrEqualTo: realLibrary),
        FileManager.default.fileExists(
          atPath: dataRoot.appendingPathComponent("SYNTHETIC_DATA_ROOT").path)
      else {
        say("refused: \(dataRoot.path) is not a synthetic root outside the library")
        return 2
      }
      let registry: ManagedModelRegistry
      let manager: LocalModelManager
      do {
        registry = try LocalDictationRuntime.bundledModelRegistry()
        manager = try LocalDictationRuntime.makeModelManager(
          applicationRoot: dataRoot, registry: registry)
      } catch {
        say("refused: registry or model manager: \(error)")
        return 2
      }
      let source = realLibrary.appendingPathComponent("models", isDirectory: true)
      let importer = InstalledModelImporter(source: source, registry: registry)
      say("data root: \(dataRoot.path)")
      say("source: \(source.path)")
      var seen = Set<String>()
      let ids = registry.models.map(\.id).filter { seen.insert($0).inserted }
      for id in ids {
        say("read pointer: \(source.path)/active/\(id).json")
      }
      for candidate in importer.candidates() {
        let files = registry.artifact(id: candidate.artifactID, version: candidate.version)?
          .files.count ?? 0
        say("read folder: \(candidate.directory.path) (\(files) registry files)")
      }
      let result = Result()
      let done = DispatchSemaphore(value: 0)
      Task.detached {
        result.outcome = await importer.importAll(into: manager)
        for id in ids {
          if let active = try? await manager.discoverActive(
            artifactID: id, healthCheck: FileSetModelHealthCheck())
          {
            result.active.append(
              "\(id) \(active.descriptor.version) \(active.descriptor.totalSizeBytes) bytes")
          } else {
            result.active.append("\(id) missing")
          }
        }
        done.signal()
      }
      done.wait()
      guard let outcome = result.outcome else {
        say("failed: no outcome")
        return 1
      }
      say("imported: \(outcome.imported.sorted().joined(separator: ", "))")
      say("already active: \(outcome.alreadyActive.sorted().joined(separator: ", "))")
      say("failed: \(outcome.failed.sorted().joined(separator: ", "))")
      for line in result.active { say("active: \(line)") }
      let taken = outcome.imported.count + outcome.alreadyActive.count
      return outcome.failed.isEmpty && taken > 0 ? 0 : 1
    }
  }
#endif
