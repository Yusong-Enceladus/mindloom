import AppKit
import BestASRDomain
import BestASRIntake
import BestASRMemory
import BestASRMemoryUI
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import GRDB
import SwiftUI
import XCTest

/// Opt-in end-to-end run on the owner's own organizing device (Spark).
///
/// A fresh synthetic data root (made by `script/make_synthetic_data_root.sh`)
/// and a real store; the invented week of `SyntheticWeek` taken in through the
/// real intake (a private named pasteboard, `IntakePasteboardReader`,
/// `IntakeProcessor`, `createUserItem`, the staging commit); the guarded link
/// through `RemoteOrganizerLinkController` and the real SSH runtime until the
/// Spark has organized every item; the Home/Event/Person/Unfiled pages and the
/// event text export from the real projection; a JSON summary without item
/// contents; then revocation and a check that nothing is left to send.
///
/// Screenshots are not read on this Mac (no on-device inference in this run);
/// the organizing device reads them.
///
/// Skipped unless `BESTASR_E2E_SPARK_HOST` is set. Also required:
/// `BESTASR_E2E_SPARK_SOCKET_PATH`, `BESTASR_E2E_SPARK_TOKEN_PATH`. Optional:
/// `BESTASR_E2E_OUTPUT_DIR` (default: a new temporary directory),
/// `BESTASR_E2E_TIMEOUT_SECONDS` (default 600), `BESTASR_E2E_QUIET_SECONDS`
/// (default 40: how long the projection must stay unchanged after the last
/// item was organized, so status lines and ranking finish).
@MainActor
final class SparkEndToEndTests: XCTestCase {
  struct Settings {
    let link: RemoteOrganizerLinkConfiguration
    let output: URL
    let timeout: TimeInterval
    let quiet: TimeInterval
  }

  static func settings() throws -> Settings {
    let environment = ProcessInfo.processInfo.environment
    func value(_ key: String) -> String? {
      let text = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return text.isEmpty ? nil : text
    }
    guard let host = value("BESTASR_E2E_SPARK_HOST") else {
      throw XCTSkip(
        "Set BESTASR_E2E_SPARK_HOST, BESTASR_E2E_SPARK_SOCKET_PATH and "
          + "BESTASR_E2E_SPARK_TOKEN_PATH to run the end-to-end organizer test.")
    }
    guard let socket = value("BESTASR_E2E_SPARK_SOCKET_PATH"),
      let token = value("BESTASR_E2E_SPARK_TOKEN_PATH")
    else {
      throw EndToEndError(
        "BESTASR_E2E_SPARK_SOCKET_PATH and BESTASR_E2E_SPARK_TOKEN_PATH are required")
    }
    let output =
      value("BESTASR_E2E_OUTPUT_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("bestasr-e2e-output-\(UUID().uuidString)", isDirectory: true)
    return Settings(
      link: try RemoteOrganizerLinkConfiguration(
        host: host, remoteSocketPath: socket, remoteTokenPath: token),
      output: output,
      timeout: value("BESTASR_E2E_TIMEOUT_SECONDS").flatMap(TimeInterval.init) ?? 600,
      quiet: value("BESTASR_E2E_QUIET_SECONDS").flatMap(TimeInterval.init) ?? 40)
  }

  struct EndToEndError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  /// One ingested item: its local ID and timings (Mac wall clock).
  final class Tracked {
    let item: SyntheticWeek.Item
    let id: String
    let ingestedAt: Date
    var organizedAt: Date?

    init(item: SyntheticWeek.Item, id: String, ingestedAt: Date) {
      self.item = item
      self.id = id
      self.ingestedAt = ingestedAt
    }
  }

  struct JobRow {
    let state: String
    let errorCategory: String
    let retryCount: Int
    let deliveredAt: Double?
    let deliveredRevision: Int64?
  }

  func testSyntheticWeekOrganizedOnOwnSpark() async throws {
    if !(ProcessInfo.processInfo.environment["BESTASR_E2E_SCENARIO_DIR"] ?? "").isEmpty {
      throw XCTSkip("A scenario directory is set; ScenarioEndToEndTests runs it instead.")
    }
    let settings = try Self.settings()
    let fileManager = FileManager.default
    let started = Date()
    var errors: [String] = []
    var statuses: [SparkEndToEndSummary.StatusChange] = []

    // 1. A fresh synthetic data root, by the same script a demo uses.
    let work = fileManager.temporaryDirectory
      .appendingPathComponent("bestasr-e2e-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: work) }
    let root = try Self.makeSyntheticDataRoot(at: work.appendingPathComponent("root"))
    guard let realLibrary = BestASRDataRootSelection.ownerRealLibraryRoot() else {
      throw EndToEndError("owner library root unresolvable")
    }
    let databaseURL = root.appendingPathComponent("history.sqlite")
    let assetRoot = root.appendingPathComponent("assets", isDirectory: true)
    let store = try GRDBDictationStore(
      databaseURL: databaseURL, remoteItemTimeZone: SyntheticWeek.zone)

    // The link exactly as the App builds it, with its state kept in the work
    // directory instead of the App's support directory.
    let stateDirectory = work.appendingPathComponent("link-state", isDirectory: true)
    let intent = RemoteOrganizerLinkIntentFile(stateDirectory: stateDirectory, dataRoot: root)
    let link = settings.link
    let controller = RemoteOrganizerLinkController(
      repository: store, dataRoot: root, realLibraryRoot: realLibrary, intent: intent,
      cleanUpStaleTunnels: {
        _ = RemoteOrganizerTunnelRecordStore(directory: stateDirectory).cleanUpStale()
      },
      makeRuntime: { repository, onUpdate in
        RemoteOrganizerRuntime(
          repository: repository,
          launcher: SSHRemoteOrganizerTunnelLauncher(
            configuration: link, stateDirectory: stateDirectory),
          http: URLSessionRemoteOrganizerTransport(),
          itemAssetReader: RemoteOrganizerItemAssetReader(assetRoot: assetRoot),
          timing: RemoteOrganizerRuntime.Timing(pollInterval: .seconds(2)),
          onUpdate: onUpdate)
      })
    controller.onChange = { status, _ in
      let name = Self.statusName(status)
      if statuses.last?.status != name {
        statuses.append(.init(atSeconds: Self.seconds(started, Date()), status: name))
      }
    }

    var tracked: [Tracked] = []
    var summary = SparkEndToEndSummary(
      host: link.host, itemsIngested: 0, itemsSent: 0, timeZone: "+08:00")
    var snapshots: [String] = []
    var exports: [String] = []
    var failure: Error?

    do {
      XCTAssertEqual(controller.provenance, .allowed, "synthetic root must pass the guard")
      // Items taken in while the link is off are never sent, so the link is
      // turned on first, as a user would before pasting.
      await controller.setEnabled(true)
      guard controller.isEnabled else {
        throw EndToEndError("link did not turn on: \(Self.statusName(controller.status))")
      }

      // 2. The invented week through the real intake.
      tracked = try await Self.ingest(
        store: store, assetRoot: assetRoot, dataRoot: root, realLibrary: realLibrary,
        inbox: work.appendingPathComponent("inbox", isDirectory: true))
      summary.itemsIngested = tracked.count

      // 3. Run until the Spark has organized every item and is quiet.
      let outcome = try await Self.waitUntilOrganized(
        store: store, controller: controller, databaseURL: databaseURL, tracked: tracked,
        settings: settings, errors: &errors)
      summary.settled = outcome.settled
      summary.timedOut = outcome.timedOut
      summary.serviceClock = controller.serviceClock

      // 4. The pages and the export from the real projection.
      let remote = try await store.remoteProjection()
      summary.storeID = try await store.remoteLinkRecord().storeID
      let sources = remote.events.filter { !$0.deleted }.map(MemoryProjection.source)
      let records = try await store.memoryItemRecords(
        ids: MemoryProjection.sessionIDs(
          sources.flatMap(\.itemIDs) + remote.unfiled.map(\.itemID)))
      let now = Date()
      let memory = MemoryProjection(remote: remote, records: records, now: now)
      let screen = MemoryScreenState(
        mode: .spark, projection: memory, now: now, calendar: SyntheticWeek.calendar,
        thumbnail: { path in
          guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            return nil
          }
          return NSImage(contentsOf: assetRoot.appendingPathComponent(path))
        })
      let snapshotDirectory = settings.output.appendingPathComponent(
        "e2e-snapshots", isDirectory: true)
      let exportDirectory = settings.output.appendingPathComponent(
        "e2e-export", isDirectory: true)
      for directory in [snapshotDirectory, exportDirectory] {
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      var scenes: [(String, MemoryNavigation)] = [("home", MemoryNavigation())]
      if let top = screen.home.first {
        scenes.append(("event", MemoryNavigation(path: [.event(top.eventID)])))
      } else {
        errors.append("no event to show")
      }
      let personID =
        screen.home.first?.people.first(where: \.isNamed)?.personID
        ?? screen.people.first(where: \.isNamed)?.personID
        ?? screen.people.first?.personID
      if let personID {
        scenes.append(("person", MemoryNavigation(path: [.person(personID)])))
      } else {
        errors.append("no person to show")
      }
      scenes.append(("unfiled", MemoryNavigation(path: [.unfiled])))
      for (name, navigation) in scenes {
        for dark in [false, true] {
          let file = "\(name)-\(dark ? "dark" : "light").png"
          try Self.render(screen, navigation: navigation, dark: dark)
            .write(to: snapshotDirectory.appendingPathComponent(file), options: .atomic)
          snapshots.append(file)
        }
      }
      let formatter = EventPlainTextFormatter(timeZone: SyntheticWeek.zone)
      for (index, entry) in screen.home.prefix(2).enumerated() {
        guard
          let detail = MemoryProjection.sparkEventDetail(
            entry.eventID, projection: remote, records: records)
        else {
          errors.append("event \(index + 1) has no detail")
          continue
        }
        let file = "\(index + 1)-\(EventPlainTextFormatter.suggestedFilename(for: detail))"
        try Data(formatter.format(detail).utf8).write(
          to: exportDirectory.appendingPathComponent(file), options: .atomic)
        exports.append(file)
      }

      // 5. The summary's organizing part (no item contents).
      let jobs = try Self.jobRows(databaseURL)
      summary.itemsSent = jobs.values.filter { $0.deliveredRevision != nil }.count
      summary.describe(
        remote: remote, home: screen.home, tracked: tracked, jobs: jobs,
        personCount: screen.people.count,
        namedPersonCount: screen.people.filter(\.isNamed).count)
    } catch {
      failure = error
      errors.append("run: \(String(describing: error))")
    }

    // 6. Revoke and verify nothing is left to send.
    controller.revokeNow()
    await controller.revokeStorage()
    do {
      summary.revocation = try await Self.revocationCheck(
        store: store, databaseURL: databaseURL, stateDirectory: stateDirectory,
        intent: intent)
    } catch {
      errors.append("revocation check: \(String(describing: error))")
    }
    summary.statusChanges = statuses
    summary.errors = errors
    summary.snapshots = snapshots
    summary.exports = exports
    summary.elapsedSeconds = Self.seconds(started, Date())
    try fileManager.createDirectory(at: settings.output, withIntermediateDirectories: true)
    try summary.encoded().write(
      to: settings.output.appendingPathComponent("e2e-summary.json"), options: .atomic)
    try? await store.checkpointAndClose()
    print("bestASR e2e output: \(settings.output.path)")

    if let failure { throw failure }
    let revocation = try XCTUnwrap(summary.revocation)
    XCTAssertFalse(revocation.linkEnabledAfter)
    XCTAssertEqual(revocation.pendingItemJobs, 0)
    XCTAssertEqual(revocation.pendingDecisionJobs, 0)
    XCTAssertEqual(revocation.activeTunnels, 0)
    XCTAssertEqual(revocation.tunnelRecords, 0)
    XCTAssertTrue(revocation.intentCleared)
    XCTAssertEqual(summary.itemsIngested, SyntheticWeek.items.count)
    XCTAssertEqual(summary.itemsSent, SyntheticWeek.items.count, "every item reaches the Spark")
    XCTAssertTrue(summary.settled, "the Spark organized every item in time")
    XCTAssertFalse(summary.events.isEmpty)
    XCTAssertEqual(snapshots.count, 8)
    XCTAssertEqual(exports.count, 2)
  }

  // MARK: - Steps

  static func makeSyntheticDataRoot(at target: URL) throws -> URL {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let script = repository.appendingPathComponent("script/make_synthetic_data_root.sh")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path, target.path]
    process.standardOutput = FileHandle.nullDevice
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let message =
        String(
          data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      throw EndToEndError("make_synthetic_data_root.sh failed: \(message)")
    }
    let marker = target.appendingPathComponent(
      RemoteOrganizerDataProvenance.syntheticMarkerFileName)
    guard FileManager.default.fileExists(atPath: marker.path) else {
      throw EndToEndError("synthetic marker missing")
    }
    return URL(fileURLWithPath: target.path, isDirectory: true).resolvingSymlinksInPath()
  }

  /// What `DictationAppModel.receive` does for a paste or a drop: read the
  /// pasteboard (or take the dropped file), prepare off the store, commit the
  /// rows, then commit the staged files.
  static func ingest(
    store: GRDBDictationStore, assetRoot: URL, dataRoot: URL, realLibrary: URL, inbox: URL
  ) async throws -> [Tracked] {
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let policy = IntakePathPolicy { url in
      [realLibrary, dataRoot].contains {
        BestASRDataRootSelection.path(url, isWithinOrEqualTo: $0)
      }
    }
    // No image reader: nothing is recognized on this Mac in this run.
    let processor = IntakeProcessor(
      assetStore: IntakeAssetStore(assetRoot: assetRoot), pathPolicy: policy, imageReader: nil)
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("bestASR.e2e.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    var result: [Tracked] = []
    for item in SyntheticWeek.items {
      let candidate: IntakeCandidate
      let origin: ItemSourceOrigin
      switch item.content {
      case .pastedText(let text):
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        candidate = try readSingle(pasteboard)
        origin = .previousFrontmost
      case .pastedScreenshot(let title, let clock, let bubbles):
        let png = try SyntheticRendering.chatScreenshotPNG(
          title: title, clock: clock, bubbles: bubbles)
        pasteboard.clearContents()
        let pasteItem = NSPasteboardItem()
        pasteItem.setData(png, forType: .png)
        pasteboard.writeObjects([pasteItem])
        candidate = try readSingle(pasteboard)
        origin = .previousFrontmost
      case .droppedPDF(let filename, let lines):
        let file = inbox.appendingPathComponent(filename)
        try SyntheticRendering.textPDF(title: lines.first ?? filename, lines: lines)
          .write(to: file, options: .atomic)
        candidate = .file(file)
        origin = .finder
      }
      let outcome = processor.prepare(
        candidate, capturedAt: item.capturedAt, source: item.app.source, origin: origin)
      guard case .item(let draft) = outcome else {
        throw EndToEndError("\(item.label) was not taken in: \(outcome)")
      }
      do {
        try await store.createUserItem(draft)
      } catch {
        processor.assetStore.discard(sessionID: draft.id)
        throw error
      }
      processor.assetStore.commit(sessionID: draft.id)
      result.append(
        Tracked(item: item, id: draft.id.rawValue.uuidString.uppercased(), ingestedAt: Date()))
    }
    return result
  }

  static func readSingle(_ pasteboard: NSPasteboard) throws -> IntakeCandidate {
    switch IntakePasteboardReader(pasteboard: pasteboard).read() {
    case .candidates(let candidates) where candidates.count == 1:
      return candidates[0]
    case let other:
      throw EndToEndError("unexpected pasteboard reading: \(other)")
    }
  }

  struct WaitOutcome {
    let settled: Bool
    let timedOut: Bool
  }

  /// Polls the projection the runtime keeps up to date. Done when every item
  /// is in an event or Unfiled (or parked as unsendable, which is an error)
  /// and the projection has not changed for `settings.quiet` seconds.
  static func waitUntilOrganized(
    store: GRDBDictationStore, controller: RemoteOrganizerLinkController, databaseURL: URL,
    tracked: [Tracked], settings: Settings, errors: inout [String]
  ) async throws -> WaitOutcome {
    let deadline = Date().addingTimeInterval(settings.timeout)
    var lastCursor: Int64 = -1
    var lastChange = Date()
    var reportedParked = Set<String>()
    while Date() < deadline {
      try await Task.sleep(for: .seconds(2))
      if case .refused(let verdict) = controller.status {
        errors.append("link refused: \(verdict)")
        return WaitOutcome(settled: false, timedOut: false)
      }
      let projection = try await store.remoteProjection()
      let placed = Set(placement(projection).keys)
      let now = Date()
      for entry in tracked where entry.organizedAt == nil && placed.contains(entry.id) {
        entry.organizedAt = now
      }
      let jobs = try jobRows(databaseURL)
      var outstanding = 0
      for entry in tracked where !placed.contains(entry.id) {
        if let job = jobs[entry.id], job.state == "failed" {
          if reportedParked.insert(entry.id).inserted {
            errors.append("\(entry.item.label) parked on the Mac: \(job.errorCategory)")
          }
        } else {
          outstanding += 1
        }
      }
      if projection.cursor != lastCursor {
        lastCursor = projection.cursor
        lastChange = now
      }
      if outstanding == 0, now.timeIntervalSince(lastChange) >= settings.quiet {
        return WaitOutcome(settled: reportedParked.isEmpty, timedOut: false)
      }
    }
    let missing = tracked.filter { $0.organizedAt == nil }.map(\.item.label)
    if !missing.isEmpty {
      errors.append("not organized in time: \(missing.joined(separator: ", "))")
    }
    return WaitOutcome(settled: missing.isEmpty, timedOut: true)
  }

  /// Upper-case item ID → where it is: `event:<Home rank>` or `unfiled:<reason>`.
  static func placement(_ projection: RemoteOrganizerProjection) -> [String: String] {
    var result: [String: String] = [:]
    for (rank, event) in projection.events.enumerated() {
      for id in event.itemIDs { result[id.uppercased()] = "event:\(rank + 1)" }
    }
    for item in projection.unfiled where result[item.itemID.uppercased()] == nil {
      result[item.itemID.uppercased()] = "unfiled:\(item.reason)"
    }
    return result
  }

  static func readOnlyQueue(_ url: URL) throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.readonly = true
    configuration.busyMode = .timeout(10)
    return try DatabaseQueue(path: url.path, configuration: configuration)
  }

  static func jobRows(_ url: URL) throws -> [String: JobRow] {
    let queue = try readOnlyQueue(url)
    defer { try? queue.close() }
    return try queue.read { db in
      var rows: [String: JobRow] = [:]
      for row in try Row.fetchAll(
        db,
        sql: """
          SELECT item_id, state, error_category, retry_count, delivered_at, delivered_revision
          FROM remote_organizer_item_jobs
          """)
      {
        rows[(row["item_id"] as String).uppercased()] = JobRow(
          state: row["state"], errorCategory: row["error_category"],
          retryCount: row["retry_count"], deliveredAt: row["delivered_at"],
          deliveredRevision: row["delivered_revision"])
      }
      return rows
    }
  }

  static func revocationCheck(
    store: GRDBDictationStore, databaseURL: URL, stateDirectory: URL,
    intent: RemoteOrganizerLinkIntentFile
  ) async throws -> SparkEndToEndSummary.Revocation {
    let enabled = try await store.remoteLinkRecord().enabledAt != nil
    let queue = try readOnlyQueue(databaseURL)
    defer { try? queue.close() }
    let (items, decisions) = try await queue.read { db in
      (
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM remote_organizer_item_jobs
            WHERE state <> 'delivered' OR delivered_revision IS NULL
            """) ?? -1,
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM remote_organizer_decision_jobs
            WHERE state IN ('queued', 'running')
            """) ?? -1
      )
    }
    return SparkEndToEndSummary.Revocation(
      linkEnabledAfter: enabled, pendingItemJobs: items, pendingDecisionJobs: decisions,
      activeTunnels: RemoteOrganizerProcessRegistry.activeCount,
      tunnelRecords: RemoteOrganizerTunnelRecordStore(directory: stateDirectory).records().count,
      intentCleared: !intent.onRecorded)
  }

  /// `BESTASR_E2E_RENDER_SCALE`: pixels per point of a rendered page (1–3).
  static var renderScale: CGFloat {
    let value = ProcessInfo.processInfo.environment["BESTASR_E2E_RENDER_SCALE"]
    return CGFloat(min(max(value.flatMap(Double.init) ?? 1, 1), 3))
  }

  static func render(
    _ state: MemoryScreenState, navigation: MemoryNavigation, dark: Bool, height: CGFloat = 820
  ) throws -> Data {
    let view = ZhijiShell(navigation: .constant(navigation), state: state, actions: .inert)
      .frame(width: 1280, height: height)
      .environment(\.colorScheme, dark ? .dark : .light)
      .environment(\.zhijiSnapshot, true)
      .environment(\.locale, Locale(identifier: "zh-Hans"))
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = ProposedViewSize(width: 1280, height: height)
    renderer.scale = renderScale
    guard let image = renderer.cgImage,
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw EndToEndError("page did not render") }
    return png
  }

  static func statusName(_ status: RemoteOrganizerLinkController.Status) -> String {
    switch status {
    case .off: "off"
    case .refused(let verdict): "refused:\(verdict)"
    case .connecting: "connecting"
    case .connected: "connected"
    case .unavailable: "unavailable"
    case .storageUnavailable: "storage_unavailable"
    }
  }

  static func seconds(_ from: Date, _ to: Date) -> Double {
    (to.timeIntervalSince(from) * 10).rounded() / 10
  }
}
