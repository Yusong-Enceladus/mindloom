import AppKit
import BestASRDomain
import BestASRIntake
import BestASRMemory
import BestASRMemoryUI
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import SwiftUI
import XCTest

/// Opt-in end-to-end run of a whole synthetic scenario directory on the
/// owner's own organizing device: every item through the real intake at a
/// set pace, the guarded link until the Spark reports every sent item
/// processed and the pages are quiet, then the pages and a summary with
/// throughput and counts (no item contents).
///
/// Skipped unless `BESTASR_E2E_SPARK_HOST` (with `…_SOCKET_PATH` and
/// `…_TOKEN_PATH`) and `BESTASR_E2E_SCENARIO_DIR` are set. Optional:
/// - `BESTASR_E2E_PACE_SECONDS` (pause between items, default 0),
///   `BESTASR_E2E_LIMIT` (first N items in time order), `BESTASR_E2E_OUTPUT_DIR`;
/// - `BESTASR_E2E_TIMEOUT_SECONDS` (default 1800 here) bounds the wait;
///   `BESTASR_E2E_QUIET_SECONDS` (default 40) is how long the pages must stay
///   unchanged after the Spark finished; `BESTASR_E2E_PROBE_SECONDS` (default
///   10) how often the Spark is asked;
/// - `BESTASR_E2E_RENDER_EVENTS`: comma-separated ground-truth event IDs; each
///   is mapped to the organizer event holding most of its items and rendered
///   as `threads/thread-<id>-{light,dark}.png` (plus `-part-…` with a split
///   part expanded) with its 复制为文本 text in `threads/export-<id>.md`;
///   `BESTASR_E2E_THREAD_HEIGHT` (default 1600) is those pages' height;
/// - `BESTASR_E2E_HOME_CUTOFFS`: comma-separated days (`yyyy-MM-dd`); Home is
///   also rendered as `timelapse/home-<day>-{light,dark}.png` with only the
///   items captured by the end of that day (today's grouping and titles; the
///   status lines are left out because they may tell what came later);
/// - `BESTASR_E2E_RENDER_SCALE` (default 1, at most 3): pixels per point of
///   every rendered page (2 gives 2560 pixels wide);
/// - `BESTASR_E2E_RENDER_LENSES=1` (v7): Home in each lens as
///   `home-<lens>-{light,dark}.png`, and each matter of
///   `BESTASR_E2E_RENDER_EVENTS` in each lens as
///   `matter-<id>-<lens>-{light,dark}.png` (plus `-strands-knot` with the
///   evidence panel open on its latest knot with a quote), and the first Home
///   matter without a map as `matter-nomap-strands-…`; written to
///   `BESTASR_E2E_LENS_DIR` (default `<output>/lenses`), with
///   `lens-summary.json` (counts only) and the organizer's map, rope and
///   relation counts; `BESTASR_E2E_LENS_HEIGHT` (default 1100) is those
///   pages' height;
/// - `BESTASR_E2E_WORK_DIR`: keep the synthetic library and a ledger there;
///   a rerun with the same directory takes in only what is not there yet and
///   waits for the rest instead of sending new copies.
@MainActor
final class ScenarioEndToEndTests: XCTestCase {
  struct Tracked {
    let ref: String
    let kind: String
    let intakeKind: String
    let sourceApp: String
    let expectedEvents: [String]
    /// Upper-case local item ID.
    let id: String
    let ingestedAt: Date
  }

  func testScenarioDirectoryOrganizedOnOwnSpark() async throws {
    let environment = ProcessInfo.processInfo.environment
    func value(_ key: String) -> String? {
      let text = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return text.isEmpty ? nil : text
    }
    guard let directory = value("BESTASR_E2E_SCENARIO_DIR") else {
      throw XCTSkip("Set BESTASR_E2E_SCENARIO_DIR (and the Spark variables) to run a scenario.")
    }
    var settings = try SparkEndToEndTests.settings()
    if value("BESTASR_E2E_TIMEOUT_SECONDS") == nil {
      settings = SparkEndToEndTests.Settings(
        link: settings.link, output: settings.output, timeout: 1_800, quiet: settings.quiet)
    }
    let pace = value("BESTASR_E2E_PACE_SECONDS").flatMap(TimeInterval.init) ?? 0
    let limit = value("BESTASR_E2E_LIMIT").flatMap(Int.init)
    let probeInterval = value("BESTASR_E2E_PROBE_SECONDS").flatMap(TimeInterval.init) ?? 10
    let threadHeight = value("BESTASR_E2E_THREAD_HEIGHT").flatMap(Double.init) ?? 1_600
    let renderEvents = Self.list(value("BESTASR_E2E_RENDER_EVENTS"))
    let homeCutoffs = Self.list(value("BESTASR_E2E_HOME_CUTOFFS"))
    let scenario = try ScenarioDirectory(
      root: URL(fileURLWithPath: directory, isDirectory: true))
    let items = limit.map { Array(scenario.items.prefix($0)) } ?? scenario.items
    guard !items.isEmpty else { throw SparkEndToEndTests.EndToEndError("scenario has no items") }
    let itemsByRef = Dictionary(
      scenario.items.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })

    let fileManager = FileManager.default
    let started = Date()
    var errors: [String] = []
    let keptWork = value("BESTASR_E2E_WORK_DIR").map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    let work =
      keptWork
      ?? fileManager.temporaryDirectory
      .appendingPathComponent("bestasr-scenario-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
    defer { if keptWork == nil { try? fileManager.removeItem(at: work) } }
    let rootLocation = work.appendingPathComponent("root", isDirectory: true)
    let marker = rootLocation.appendingPathComponent(
      RemoteOrganizerDataProvenance.syntheticMarkerFileName)
    let root =
      fileManager.fileExists(atPath: marker.path)
      ? rootLocation.resolvingSymlinksInPath()
      : try SparkEndToEndTests.makeSyntheticDataRoot(at: rootLocation)
    var ledger = try keptWork.map {
      try ScenarioLedger(
        url: $0.appendingPathComponent("ledger.jsonl"), scenario: scenario.id)
    }
    guard let realLibrary = BestASRDataRootSelection.ownerRealLibraryRoot() else {
      throw SparkEndToEndTests.EndToEndError("owner library root unresolvable")
    }
    let databaseURL = root.appendingPathComponent("history.sqlite")
    let assetRoot = root.appendingPathComponent("assets", isDirectory: true)
    let zone = items.first.flatMap { Self.zone(of: $0) } ?? SyntheticWeek.zone
    let store = try GRDBDictationStore(databaseURL: databaseURL, remoteItemTimeZone: zone)
    let stateDirectory = work.appendingPathComponent("link-state", isDirectory: true)
    let intent = RemoteOrganizerLinkIntentFile(stateDirectory: stateDirectory, dataRoot: root)
    let link = settings.link
    // Synthetic roots keep the link key in a 0600 file inside the root.
    let controller = RemoteOrganizerLinkController(
      repository: store, dataRoot: root, realLibraryRoot: realLibrary, intent: intent,
      keyStore: try FileOrganizerKeyStore(dataRoot: root, realLibraryRoot: realLibrary),
      cleanUpStaleTunnels: {
        _ = RemoteOrganizerTunnelRecordStore(directory: stateDirectory).cleanUpStale()
      },
      makeRuntime: { repository, keys, onUpdate in
        RemoteOrganizerRuntime(
          repository: repository,
          launcher: SSHRemoteOrganizerTunnelLauncher(
            configuration: link, stateDirectory: stateDirectory),
          http: URLSessionRemoteOrganizerTransport(), keys: keys,
          itemAssetReader: RemoteOrganizerItemAssetReader(assetRoot: assetRoot),
          imageRedactor: VisionSendCopyRedactor(),
          fileSanitizer: FileSendCopySanitizer(),
          timing: RemoteOrganizerRuntime.Timing(pollInterval: .seconds(2)),
          onUpdate: onUpdate)
      })
    let probeState = work.appendingPathComponent("probe-state", isDirectory: true)
    _ = RemoteOrganizerTunnelRecordStore(directory: probeState).cleanUpStale()
    let probe = SparkProbe(link: link, stateDirectory: probeState)

    var summary = ScenarioSummary(scenario: scenario.id, host: link.host, pace: pace)
    var tracked: [Tracked] = []
    var failure: Error?
    do {
      // 0. A kept work directory: continue with what it already took in.
      let storeBefore = try await store.remoteLinkRecord()
      if let resumed = ledger, !resumed.entries.isEmpty {
        let jobs = try SparkEndToEndTests.jobRows(databaseURL)
        let plan = Self.resumePlan(
          resumed.entries, linkStillOn: storeBefore.enabledAt != nil, jobs: jobs,
          known: Set(itemsByRef.keys))
        for entry in plan.keep {
          guard let item = itemsByRef[entry.ref] else { continue }
          tracked.append(
            Tracked(
              ref: item.ref, kind: item.kind, intakeKind: scenario.intakeKind(item),
              sourceApp: item.sourceApp, expectedEvents: item.expectedEvents, id: entry.id,
              ingestedAt: entry.ingestedAt))
          if let organized = entry.organizedAt { summary.organizedAt[entry.id] = organized }
        }
        try ledger?.forget(plan.forget)
        summary.itemsResumed = tracked.count
        summary.itemsForgotten = plan.forget.count
      }

      XCTAssertEqual(controller.provenance, .allowed, "synthetic root must pass the guard")
      await controller.setEnabled(true)
      guard controller.isEnabled else {
        throw SparkEndToEndTests.EndToEndError(
          "link did not turn on: \(SparkEndToEndTests.statusName(controller.status))")
      }

      // 1. Every item not yet taken in, through the real intake, at the pace
      // asked for; what is already organized is noted as the run goes.
      let inbox = work.appendingPathComponent("inbox", isDirectory: true)
      try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
      let policy = IntakePathPolicy { url in
        [realLibrary, root].contains { BestASRDataRootSelection.path(url, isWithinOrEqualTo: $0) }
      }
      let processor = IntakeProcessor(
        assetStore: IntakeAssetStore(assetRoot: assetRoot), pathPolicy: policy, imageReader: nil)
      let pasteboard = NSPasteboard(name: NSPasteboard.Name("bestASR.e2e.\(UUID().uuidString)"))
      defer { pasteboard.releaseGlobally() }
      let already = Set(tracked.map(\.ref))
      var mediaSkipped: [String] = []
      defer {
        if !mediaSkipped.isEmpty {
          print("media items routed to the Mac import (not run here): \(mediaSkipped)")
        }
      }
      var lastLook = Date()
      var taken = 0
      for item in items where !already.contains(item.ref) {
        if taken > 0, pace > 0 { try await Task.sleep(for: .seconds(pace)) }
        taken += 1
        if Date().timeIntervalSince(lastLook) >= 2 {
          lastLook = Date()
          _ = try Self.observe(
            try await store.remoteProjection(), tracked: tracked, at: lastLook,
            summary: &summary, ledger: &ledger)
        }
        let candidate: IntakeCandidate
        let origin: ItemSourceOrigin
        do {
          switch try scenario.intake(item, inbox: inbox) {
          case .paste(let text):
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            candidate = try SparkEndToEndTests.readSingle(pasteboard)
            origin = .previousFrontmost
          case .pasteImage(let data):
            pasteboard.clearContents()
            let pasted = NSPasteboardItem()
            pasted.setData(data, forType: .png)
            pasteboard.writeObjects([pasted])
            candidate = try SparkEndToEndTests.readSingle(pasteboard)
            origin = .previousFrontmost
          case .drop(let url):
            candidate = .file(url)
            origin = .finder
          }
        } catch {
          errors.append("\(item.ref) not prepared: \(error)")
          continue
        }
        let outcome = processor.prepare(
          candidate, capturedAt: item.at, source: ScenarioDirectory.source(item.sourceApp),
          origin: origin)
        if case .media(let url) = outcome {
          // Audio and video are transcribed on the Mac by the import, which
          // the harness does not run (no ASR here); only noted.
          mediaSkipped.append("\(item.ref) (\(url.lastPathComponent))")
          continue
        }
        guard case .item(let draft) = outcome else {
          errors.append("\(item.ref) was not taken in: \(outcome)")
          continue
        }
        do {
          try await store.createUserItem(draft)
        } catch {
          processor.assetStore.discard(sessionID: draft.id)
          errors.append("\(item.ref) not stored: \(error)")
          continue
        }
        processor.assetStore.commit(sessionID: draft.id)
        let entry = Tracked(
          ref: item.ref, kind: item.kind, intakeKind: scenario.intakeKind(item),
          sourceApp: item.sourceApp, expectedEvents: item.expectedEvents,
          id: draft.id.rawValue.uuidString.uppercased(), ingestedAt: Date())
        try ledger?.recordIngested(ref: entry.ref, id: entry.id, at: entry.ingestedAt)
        tracked.append(entry)
      }
      summary.itemsInScenario = scenario.items.count
      summary.itemsIngested = tracked.count
      summary.itemsTakenInThisRun = tracked.count - summary.itemsResumed
      summary.ingestSeconds = SparkEndToEndTests.seconds(started, Date())

      // 2. Until the Spark has processed every sent item and the pages are quiet.
      let outcome = try await Self.waitUntilProcessed(
        store: store, controller: controller, databaseURL: databaseURL, tracked: tracked,
        settings: settings, probe: probe, probeInterval: probeInterval, started: started,
        errors: &errors, summary: &summary, ledger: &ledger)
      summary.settled = outcome.settled
      summary.timedOut = outcome.timedOut
      summary.serviceClock = controller.serviceClock
      if summary.waitMode == "spark_processed" {
        do {
          summary.describeSpark(try await probe.status(), tracked: tracked)
        } catch {
          errors.append("last look at the organizing device: \(error)")
        }
      }
      probe.close()
      let storeAfter = try await store.remoteLinkRecord().storeID
      if let before = storeBefore.storeID, let storeAfter, before != storeAfter {
        summary.storeChanged = true
        errors.append("the organizing device's store changed since the last run")
      }

      // 3. Pages and exports from the real projection.
      let remote = try await store.remoteProjection()
      let live = remote.events.filter { !$0.deleted }
      let sources = live.map(MemoryProjection.source)
      let records = try await store.memoryItemRecords(
        ids: MemoryProjection.sessionIDs(
          sources.flatMap(\.itemIDs) + remote.unfiled.map(\.itemID)))
      let model = MemoryReadModel(
        MemoryProjection(remote: remote, records: records, now: Date()))
      let screen = MemoryScreenState(
        mode: .spark, readModel: model, now: Date(), calendar: Self.calendar(zone),
        thumbnail: { path in
          guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            return nil
          }
          return NSImage(contentsOf: assetRoot.appendingPathComponent(path))
        })
      let snapshotDirectory = settings.output.appendingPathComponent(
        "scenario-snapshots", isDirectory: true)
      let exportDirectory = settings.output.appendingPathComponent(
        "scenario-export", isDirectory: true)
      let threadDirectory = settings.output.appendingPathComponent("threads", isDirectory: true)
      for directory in [snapshotDirectory, exportDirectory, threadDirectory] {
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      var scenes: [(String, MemoryNavigation)] = [("home", MemoryNavigation())]
      for (rank, entry) in model.home.prefix(3).enumerated() {
        scenes.append(("event-\(rank + 1)", MemoryNavigation(path: [.event(entry.eventID)])))
      }
      if let split = sources.first(where: { !$0.segments.isEmpty }),
        let detail = model.projection.event(id: split.eventID)
      {
        let parts = detail.items.filter { $0.segment != nil }.map(\.id)
        scenes.append(
          (
            "event-split",
            MemoryNavigation(path: [.event(split.eventID)], expandedItems: Set(parts))
          ))
      } else {
        errors.append("no event holds a part of a split item")
      }
      if let person = model.featuredPeople.first(where: \.isNamed)?.personID
        ?? model.home.first?.people.first(where: \.isNamed)?.personID
        ?? model.recentPeople.first(where: \.isNamed)?.personID
      {
        scenes.append(("person", MemoryNavigation(path: [.person(person)])))
      } else {
        errors.append("no person to show")
      }
      scenes.append(("unfiled", MemoryNavigation(path: [.unfiled])))
      for (name, navigation) in scenes {
        for dark in [false, true] {
          let file = "\(name)-\(dark ? "dark" : "light").png"
          try SparkEndToEndTests.render(screen, navigation: navigation, dark: dark)
            .write(to: snapshotDirectory.appendingPathComponent(file), options: .atomic)
          summary.snapshots.append(file)
        }
      }
      let formatter = EventPlainTextFormatter(timeZone: zone)
      for (rank, entry) in model.home.prefix(3).enumerated() {
        guard let detail = model.projection.event(id: entry.eventID) else { continue }
        let file = "\(rank + 1)-\(EventPlainTextFormatter.suggestedFilename(for: detail))"
        try Data(formatter.format(detail).utf8).write(
          to: exportDirectory.appendingPathComponent(file), options: .atomic)
        summary.exports.append(file)
      }

      // 4. The ground-truth threads asked for: the organizer event holding
      // most of each, its page, a split part expanded, and its text.
      let every = try await store.memoryItemRecords(
        ids: MemoryProjection.sessionIDs(tracked.map(\.id)))
      let texts = Dictionary(
        every.map { ($0.sessionID.rawValue.uuidString.uppercased(), $0.text) },
        uniquingKeysWith: { first, _ in first })
      let homeRank = Dictionary(
        uniqueKeysWithValues: model.home.enumerated().map { ($1.eventID, $0 + 1) })
      for truth in renderEvents {
        let members = tracked.filter { $0.expectedEvents.contains(truth) }.map { entry in
          ScenarioThreads.Member(
            ref: entry.ref, id: entry.id, text: texts[entry.id] ?? nil,
            quotes: itemsByRef[entry.ref].map {
              scenario.truthParts($0).filter { $0.event == truth }.map(\.quote)
            } ?? [])
        }
        let choice = ScenarioThreads.choose(
          truthEvent: truth, members: members, events: live, rank: homeRank)
        var thread = ScenarioSummary.Thread(
          truthEvent: truth, items: members.count,
          homeRank: choice.eventID.flatMap { homeRank[$0] },
          share: ScenarioSummary.rounded(choice.share * 100) / 100, holders: choice.holders)
        guard let eventID = choice.eventID, let event = live.first(where: { $0.eventID == eventID })
        else {
          errors.append(
            members.isEmpty
              ? "\(truth): no item taken in lists this event"
              : "\(truth): no organizer event holds its items")
          summary.threads.append(thread)
          continue
        }
        let name = ScenarioThreads.fileSafe(truth)
        var pages: [(String, MemoryNavigation)] = [
          ("thread-\(name)", MemoryNavigation(path: [.event(eventID)]))
        ]
        if let detail = model.projection.event(id: eventID) {
          let own = Set(members.map(\.id))
          let parts = detail.items.filter { $0.segment != nil }
          if let part = parts.first(where: { own.contains($0.itemID.uppercased()) }) ?? parts.first
          {
            pages.append(
              (
                "thread-\(name)-part",
                MemoryNavigation(path: [.event(eventID)], expandedItems: [part.id])
              ))
          }
        }
        for (base, navigation) in pages {
          for dark in [false, true] {
            let file = "\(base)-\(dark ? "dark" : "light").png"
            try SparkEndToEndTests.render(
              screen, navigation: navigation, dark: dark, height: threadHeight
            ).write(to: threadDirectory.appendingPathComponent(file), options: .atomic)
            thread.files.append(file)
          }
        }
        // Exactly what 复制为文本 copies: the App's detail for this event from
        // the records it references.
        let referenced = try await store.memoryItemRecords(
          ids: MemoryProjection.referencedSessionIDs([MemoryProjection.source(event)]))
        if let detail = MemoryProjection.sparkEventDetail(
          eventID, projection: remote, records: referenced)
        {
          let file = "export-\(name).md"
          try Data(formatter.format(detail).utf8).write(
            to: threadDirectory.appendingPathComponent(file), options: .atomic)
          thread.export = file
        } else {
          errors.append("\(truth): the event has no detail to export")
        }
        summary.threads.append(thread)
      }

      // 4b. v7: Home and the matters asked for, in every lens.
      if value("BESTASR_E2E_RENDER_LENSES") == "1" {
        let lensDirectory =
          value("BESTASR_E2E_LENS_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
          ?? settings.output.appendingPathComponent("lenses", isDirectory: true)
        try fileManager.createDirectory(at: lensDirectory, withIntermediateDirectories: true)
        let lensHeight = value("BESTASR_E2E_LENS_HEIGHT").flatMap(Double.init) ?? 1_100
        var pages: [(String, MemoryNavigation, CGFloat)] = MemoryHomeLens.allCases.map {
          ("home-\($0.rawValue)", MemoryNavigation(homeLens: $0), lensHeight)
        }
        var matters: [String: String] = [:]
        for truth in renderEvents {
          let members = tracked.filter { $0.expectedEvents.contains(truth) }.map { entry in
            ScenarioThreads.Member(
              ref: entry.ref, id: entry.id, text: texts[entry.id] ?? nil,
              quotes: itemsByRef[entry.ref].map {
                scenario.truthParts($0).filter { $0.event == truth }.map(\.quote)
              } ?? [])
          }
          let choice = ScenarioThreads.choose(
            truthEvent: truth, members: members, events: live, rank: homeRank)
          guard let eventID = choice.eventID else { continue }
          let name = ScenarioThreads.fileSafe(truth)
          matters[name] = eventID
          for lens in MemoryEventLens.allCases {
            pages.append(
              (
                "matter-\(name)-\(lens.rawValue)",
                MemoryNavigation(path: [.event(eventID)], eventLens: lens), lensHeight
              ))
          }
          let knot = live.first { $0.eventID == eventID }?.map?.knots
            .filter { !$0.quote.isEmpty }.max { ($0.date ?? "") < ($1.date ?? "") }
          if let knot {
            pages.append(
              (
                "matter-\(name)-strands-knot",
                MemoryNavigation(
                  path: [.event(eventID)], eventLens: .strands, focusedKnot: knot.id),
                lensHeight
              ))
          }
        }
        if let plain = model.home.first(where: { entry in
          live.first { $0.eventID == entry.eventID }?.map == nil && entry.itemCount >= 2
        }) {
          pages.append(
            (
              "matter-nomap-strands",
              MemoryNavigation(path: [.event(plain.eventID)], eventLens: .strands), 900
            ))
        }
        var lensFiles: [String] = []
        // Milliseconds, on this data: deriving the read model with and without
        // the v7 fields, and each light page drawn (at the render scale,
        // PNG encoding included), and Home without the v7 fields.
        var timings: [String: Double] = [:]
        func ms(_ body: () throws -> Void) rethrows -> Double {
          let start = Date()
          try body()
          return (Date().timeIntervalSince(start) * 10_000).rounded() / 10
        }
        let stripped = RemoteOrganizerProjection(
          cursor: remote.cursor,
          events: remote.events.map { event in
            var event = event
            event.map = nil
            event.facets = nil
            return event
          }, questions: remote.questions, persons: remote.persons, unfiled: remote.unfiled,
          readings: remote.readings, readingSummaries: remote.readingSummaries,
          readingFacts: remote.readingFacts)
        timings["derive_ms"] = ms {
          _ = MemoryReadModel(MemoryProjection(remote: remote, records: records, now: Date()))
        }
        var plainModel: MemoryReadModel?
        timings["derive_without_v7_ms"] = ms {
          plainModel = MemoryReadModel(
            MemoryProjection(remote: stripped, records: records, now: Date()))
        }
        if let plainModel {
          let plainScreen = MemoryScreenState(
            mode: .spark, readModel: plainModel, now: Date(), calendar: Self.calendar(zone),
            thumbnail: screen.thumbnail)
          timings["render_home-time-without-v7_ms"] = try ms {
            _ = try SparkEndToEndTests.render(
              plainScreen, navigation: MemoryNavigation(), dark: false, height: lensHeight)
          }
        }
        for (base, navigation, height) in pages {
          for dark in [false, true] {
            let file = "\(base)-\(dark ? "dark" : "light").png"
            var png = Data()
            let elapsed = try ms {
              png = try SparkEndToEndTests.render(
                screen, navigation: navigation, dark: dark, height: height)
            }
            if !dark { timings["render_\(base)_ms"] = elapsed }
            try png.write(to: lensDirectory.appendingPathComponent(file), options: .atomic)
            lensFiles.append(file)
          }
        }
        let lensSummary: [String: Any] = [
          "files": lensFiles, "matters": matters,
          "events_live": live.count, "maps": live.filter { $0.map != nil }.count,
          "ropes": remote.ropes.count, "crossings": remote.relations.filter(\.isCross).count,
          "blocks": remote.relations.filter(\.isBlocks).count,
          "home_bands": model.lenses.bands.count,
          "home_unroped": model.lenses.unroped.count,
          "ladder": Dictionary(
            uniqueKeysWithValues: model.lenses.rungs.map { ($0.kind.rawValue, $0.deadlines.count) }),
          "timings_ms": timings, "render_scale": Double(SparkEndToEndTests.renderScale),
        ]
        try JSONSerialization.data(
          withJSONObject: lensSummary, options: [.prettyPrinted, .sortedKeys]
        ).write(to: lensDirectory.appendingPathComponent("lens-summary.json"), options: .atomic)
        summary.snapshots.append(contentsOf: lensFiles.map { "lenses/\($0)" })
      }

      // 5. Home as it would have looked at the end of each day asked for:
      // only items captured by then, today's grouping and titles.
      if !homeCutoffs.isEmpty {
        let timelapseDirectory = settings.output.appendingPathComponent(
          "timelapse", isDirectory: true)
        try? fileManager.removeItem(at: timelapseDirectory)
        try fileManager.createDirectory(
          at: timelapseDirectory, withIntermediateDirectories: true)
        var capturedAt: [String: Date] = [:]
        for entry in tracked {
          if let item = itemsByRef[entry.ref] { capturedAt[entry.id] = item.at }
        }
        let calendar = Self.calendar(zone)
        for day in homeCutoffs {
          guard let end = Self.endOfDay(day, calendar: calendar) else {
            errors.append("home cut-off \(day) is not yyyy-MM-dd")
            continue
          }
          let cut = Self.projection(remote, capturedBy: end, capturedAt: capturedAt)
          let cutModel = MemoryReadModel(
            MemoryProjection(remote: cut, records: records, now: end))
          let cutScreen = MemoryScreenState(
            mode: .spark, readModel: cutModel, now: end, calendar: calendar,
            thumbnail: screen.thumbnail)
          for dark in [false, true] {
            let file = "home-\(day)-\(dark ? "dark" : "light").png"
            try SparkEndToEndTests.render(cutScreen, navigation: MemoryNavigation(), dark: dark)
              .write(to: timelapseDirectory.appendingPathComponent(file), options: .atomic)
            summary.snapshots.append("timelapse/\(file)")
          }
        }
      }

      let jobs = try SparkEndToEndTests.jobRows(databaseURL)
      summary.describe(
        remote: remote, home: model.home, tracked: tracked, jobs: jobs, model: model,
        texts: texts)
    } catch {
      failure = error
      errors.append("run: \(String(describing: error))")
    }

    probe.close()
    controller.revokeNow()
    // The lock and the end of the forward run after revokeNow returns; the
    // revocation check below must not race them (it saw a live tunnel).
    await controller.waitForRevocation()
    await controller.revokeStorage()
    do {
      summary.revocation = try await SparkEndToEndTests.revocationCheck(
        store: store, databaseURL: databaseURL, stateDirectory: stateDirectory, intent: intent)
    } catch {
      errors.append("revocation check: \(String(describing: error))")
    }
    summary.errors = errors
    summary.elapsedSeconds = SparkEndToEndTests.seconds(started, Date())
    try fileManager.createDirectory(at: settings.output, withIntermediateDirectories: true)
    try summary.encoded().write(
      to: settings.output.appendingPathComponent("scenario-summary.json"), options: .atomic)
    try? await store.checkpointAndClose()
    print("bestASR scenario output: \(settings.output.path)")
    if let keptWork { print("bestASR scenario work directory (kept): \(keptWork.path)") }

    if let failure { throw failure }
    let revocation = try XCTUnwrap(summary.revocation)
    XCTAssertFalse(revocation.linkEnabledAfter)
    XCTAssertEqual(revocation.pendingItemJobs, 0)
    XCTAssertEqual(revocation.activeTunnels, 0)
    XCTAssertEqual(
      summary.itemsIngested, Set(items.map(\.ref)).union(tracked.map(\.ref)).count,
      "every item is taken in")
    XCTAssertTrue(summary.settled, "the Spark organized every item in time")
  }

  /// The end (last second) of a `yyyy-MM-dd` day in the scenario's zone.
  static func endOfDay(_ day: String, calendar: Calendar) -> Date? {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
      let start = calendar.date(
        from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    else { return nil }
    return calendar.date(byAdding: .second, value: 86_399, to: start)
  }

  /// The projection with only items captured by `end`: events keep those
  /// items (and parts of them), an event left empty is dropped, status lines
  /// are blanked, questions are left out.
  static func projection(
    _ remote: RemoteOrganizerProjection, capturedBy end: Date, capturedAt: [String: Date]
  ) -> RemoteOrganizerProjection {
    func kept(_ id: String) -> Bool { (capturedAt[id.uppercased()] ?? .distantFuture) <= end }
    let events = remote.events.map { event -> RemoteOrganizerEvent in
      let itemIDs = event.itemIDs.filter(kept)
      let segments = event.segments.filter { kept($0.itemID) }
      // No status line or dated next step: they may tell what came later.
      return RemoteOrganizerEvent(
        eventID: event.eventID, title: event.title, titleUserEdited: event.titleUserEdited,
        importance: event.importance, startedAt: event.startedAt, updatedAt: event.updatedAt,
        itemIDs: itemIDs, personIDs: event.personIDs, pinned: event.pinned,
        deleted: event.deleted || (itemIDs.isEmpty && segments.isEmpty),
        provenance: event.provenance, handle: event.handle, anchor: event.anchor,
        segments: segments)
    }
    return RemoteOrganizerProjection(
      cursor: remote.cursor, events: events, questions: [], persons: remote.persons,
      unacceptedDecisions: [], unfiled: remote.unfiled.filter { kept($0.itemID) },
      readings: remote.readings, readingSummaries: remote.readingSummaries,
      readingFacts: remote.readingFacts)
  }

  static func list(_ value: String?) -> [String] {
    var seen = Set<String>()
    return (value ?? "").split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  /// What a rerun keeps from the ledger. While the link is still on (a run
  /// that was stopped) every item is kept: what was not delivered yet is
  /// still queued. After a finished run's revocation only delivered items are
  /// on the Spark; the others were dropped from the outbox for good and are
  /// taken in anew. Items the scenario no longer has are forgotten.
  static func resumePlan(
    _ entries: [ScenarioLedger.Entry], linkStillOn: Bool,
    jobs: [String: SparkEndToEndTests.JobRow], known: Set<String>
  ) -> (keep: [ScenarioLedger.Entry], forget: [String]) {
    var keep: [ScenarioLedger.Entry] = []
    var forget: [String] = []
    for entry in entries {
      if known.contains(entry.ref),
        linkStillOn || jobs[entry.id.uppercased()]?.deliveredRevision != nil
      {
        keep.append(entry)
      } else {
        forget.append(entry.ref)
      }
    }
    return (keep, forget)
  }

  /// Upper-case IDs of items in a live event (whole or in parts) or Unfiled.
  static func placedIDs(_ projection: RemoteOrganizerProjection) -> Set<String> {
    var ids = Set<String>()
    for event in projection.events where !event.deleted {
      for id in event.itemIDs { ids.insert(id.uppercased()) }
      for part in event.segments { ids.insert(part.itemID.uppercased()) }
    }
    for item in projection.unfiled { ids.insert(item.itemID.uppercased()) }
    return ids
  }

  /// Notes items first seen organized and questions asked; returns what is
  /// placed.
  static func observe(
    _ projection: RemoteOrganizerProjection, tracked: [Tracked], at now: Date,
    summary: inout ScenarioSummary, ledger: inout ScenarioLedger?
  ) throws -> Set<String> {
    let placed = placedIDs(projection)
    var organized: [(ref: String, at: Date)] = []
    for entry in tracked where summary.organizedAt[entry.id] == nil && placed.contains(entry.id) {
      summary.organizedAt[entry.id] = now
      organized.append((entry.ref, now))
    }
    for question in projection.questions { summary.questionIDs.insert(question.questionID) }
    try ledger?.recordOrganized(organized)
    return placed
  }

  /// Done when every item is sent (or parked), the Spark reports every sent
  /// item finished with nothing queued, every item is placed on the Mac (or
  /// failed on the Spark), and the pages have not changed for `quiet`
  /// seconds. If the Spark cannot be asked, only the last three hold.
  static func waitUntilProcessed(
    store: GRDBDictationStore, controller: RemoteOrganizerLinkController, databaseURL: URL,
    tracked: [Tracked], settings: SparkEndToEndTests.Settings, probe: SparkProbe,
    probeInterval: TimeInterval, started: Date, errors: inout [String],
    summary: inout ScenarioSummary, ledger: inout ScenarioLedger?,
    pollInterval: Duration = .seconds(2)
  ) async throws -> SparkEndToEndTests.WaitOutcome {
    let deadline = Date().addingTimeInterval(settings.timeout)
    var lastCursor: Int64 = -1
    var lastChange = Date()
    var parked = Set<String>()
    var asking = true
    var lastAsked = Date.distantPast
    var failures = 0
    var sparkDone = false
    var sparkFailed = Set<String>()
    summary.waitMode = "spark_processed"
    while Date() < deadline {
      try await Task.sleep(for: pollInterval)
      if case .refused(let verdict) = controller.status {
        errors.append("link refused: \(verdict)")
        return .init(settled: false, timedOut: false)
      }
      let projection = try await store.remoteProjection()
      let now = Date()
      let placed = try observe(
        projection, tracked: tracked, at: now, summary: &summary, ledger: &ledger)
      let jobs = try SparkEndToEndTests.jobRows(databaseURL)
      var sent: [String] = []
      var unsent = 0
      for entry in tracked {
        let job = jobs[entry.id]
        if job?.deliveredRevision != nil {
          sent.append(entry.id)
        } else if let job, job.state == "failed" {
          if parked.insert(entry.id).inserted {
            errors.append("\(entry.ref) parked on the Mac: \(job.errorCategory)")
          }
        } else {
          unsent += 1
        }
      }
      if projection.cursor != lastCursor {
        lastCursor = projection.cursor
        lastChange = now
      }
      if asking, unsent == 0, now.timeIntervalSince(lastAsked) >= probeInterval {
        lastAsked = now
        do {
          let status = try await probe.status()
          failures = 0
          sparkFailed = Set(sent.filter { status.jobs[$0]?.state == "failed" })
          let done = status.processedAll(sent)
          if done, !sparkDone, summary.spark.processedAtSeconds == nil {
            summary.spark.processedAtSeconds = SparkEndToEndTests.seconds(started, Date())
          }
          sparkDone = done
        } catch {
          failures += 1
          if failures >= 5 {
            errors.append(
              "the organizing device could not be asked (\(error)); waited for quiet pages only")
            probe.close()
            asking = false
            summary.waitMode = "quiet_only"
          }
        }
      }
      let unplaced = tracked.filter {
        !placed.contains($0.id) && !parked.contains($0.id) && !sparkFailed.contains($0.id)
      }.count
      if unsent == 0, unplaced == 0, !asking || sparkDone,
        now.timeIntervalSince(lastChange) >= settings.quiet
      {
        for id in sparkFailed.sorted() {
          errors.append("\(tracked.first { $0.id == id }?.ref ?? "unknown") failed on the Spark")
        }
        return .init(settled: parked.isEmpty && sparkFailed.isEmpty, timedOut: false)
      }
    }
    let missing = tracked.filter { summary.organizedAt[$0.id] == nil }.map(\.ref)
    if !missing.isEmpty {
      errors.append(
        "not organized in time (\(missing.count)): \(missing.prefix(40).joined(separator: ", "))")
    }
    if asking, !sparkDone {
      errors.append("the organizing device had not finished every sent item in time")
    }
    return .init(settled: missing.isEmpty && (!asking || sparkDone), timedOut: true)
  }

  /// Runs without a Spark: a tiny invented scenario is read and taken in
  /// the way the run takes items in (files dropped, text pasted).
  func testScenarioDirectoryItemsBecomeWhatAUserWouldPasteOrDrop() throws {
    let fileManager = FileManager.default
    let work = fileManager.temporaryDirectory
      .appendingPathComponent("bestasr-scenario-unit-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
      at: work.appendingPathComponent("assets"), withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: work) }
    let scenario = #"""
      {"scenario_id": "unit-mini", "people": [
         {"person_id": "p_a", "display_name": "甲乙丙", "is_owner": true},
         {"person_id": "p_b", "display_name": "丁戊"}],
       "items": [
         {"ref": "m1", "t": "2026-09-22T15:00:00+08:00", "kind": "meeting_online",
          "source_app": "腾讯会议", "events": ["ev_x", "ev_y"], "segments": [
            {"start_ms": 0, "end_ms": 4000, "person_id": "p_a", "text": "先说展位。"},
            {"start_ms": 65000, "end_ms": 70000, "person_id": "p_b", "text": "再说搬家。"}]},
         {"ref": "t1", "t": "2026-09-22T09:00:00+08:00", "kind": "text", "source_app": "微信",
          "text": "丁戊：明天见"},
         {"ref": "f1", "t": "2026-09-22T18:00:00+08:00", "kind": "transcript",
          "source_app": "飞书", "filename": "周会.txt",
          "text": "甲乙丙 00:00:01\n开始\n\n丁戊 00:00:05\n好\n\n甲乙丙 00:00:09\n结束"},
         {"ref": "bad", "kind": "text", "text": "no time"}]}
      """#
    try Data(scenario.utf8).write(to: work.appendingPathComponent("scenario.json"))
    let directory = try ScenarioDirectory(root: work)
    XCTAssertEqual(directory.items.map(\.ref), ["t1", "m1", "f1"], "time order; no time, no item")
    XCTAssertEqual(
      directory.items.map(directory.intakeKind), ["text", "transcript_file", "transcript_file"])
    let meeting = directory.meetingExport(directory.items[1])
    XCTAssertEqual(meeting, "甲乙丙(00:00:00):\n先说展位。\n\n丁戊(00:01:05):\n再说搬家。\n")
    XCTAssertEqual(MemoryTranscriptText.parse(meeting)?.format, .tencent)
    let inbox = work.appendingPathComponent("inbox", isDirectory: true)
    try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
    let processor = IntakeProcessor(
      assetStore: IntakeAssetStore(assetRoot: work.appendingPathComponent("lib-assets")),
      pathPolicy: .none, imageReader: nil)
    guard case .paste(let text) = try directory.intake(directory.items[0], inbox: inbox) else {
      return XCTFail("a text item is pasted")
    }
    XCTAssertEqual(text, "丁戊：明天见")
    for item in directory.items.dropFirst() {
      guard case .drop(let url) = try directory.intake(item, inbox: inbox) else {
        return XCTFail("\(item.ref) is dropped as a file")
      }
      let outcome = processor.prepare(
        .file(url), capturedAt: item.at, source: ScenarioDirectory.source(item.sourceApp),
        origin: .finder)
      guard case .item(let draft) = outcome else { return XCTFail("\(outcome)") }
      XCTAssertEqual(draft.kind, .document)
      XCTAssertEqual(draft.capturedAt, item.at)
      XCTAssertNotNil(MemoryTranscriptText.parse(draft.text), item.ref)
      processor.assetStore.discard(sessionID: draft.id)
    }
    XCTAssertEqual(ScenarioDirectory.source("腾讯会议")?.bundleID, "com.tencent.meeting")
    XCTAssertEqual(Self.zone(of: directory.items[0])?.secondsFromGMT(), 8 * 3_600)
  }

  static func zone(of item: ScenarioDirectory.Item) -> TimeZone? {
    guard let stamp = (item.raw["t"] ?? item.raw["captured_at"]) as? String,
      let match = stamp.range(of: #"([+-])(\d{2}):(\d{2})$"#, options: .regularExpression)
    else { return nil }
    let text = stamp[match]
    let sign = text.hasPrefix("-") ? -1 : 1
    let hours = Int(text.dropFirst().prefix(2)) ?? 0
    let minutes = Int(text.suffix(2)) ?? 0
    return TimeZone(secondsFromGMT: sign * (hours * 3_600 + minutes * 60))
  }

  static func calendar(_ zone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
  }
}

/// The scenario run's JSON summary: counts, throughput and grouping by the
/// scenario's expected events; never item text, titles or status lines.
struct ScenarioSummary: Encodable {
  struct Grouping: Encodable {
    let expectedEvent: String
    let items: Int
    /// Home ranks of the events holding its items.
    let events: [Int]
    let unfiled: Int
    let missing: Int
  }

  struct Split: Encodable {
    let ref: String
    let parts: Int
    let homeRanks: [Int]
  }

  /// A ground-truth event rendered on request (`BESTASR_E2E_RENDER_EVENTS`).
  struct Thread: Encodable {
    let truthEvent: String
    /// Items taken in that the scenario lists under it.
    let items: Int
    /// Home rank of the organizer event chosen for it; nil when none.
    let homeRank: Int?
    /// Its share of the truth event's items (split items by their parts).
    let share: Double
    /// Organizer events holding any of its items.
    let holders: Int
    var files: [String] = []
    var export: String?
  }

  /// What the organizing device reported at the end (for this run's items).
  struct Spark: Encodable {
    var processedAtSeconds: Double?
    var processedAll = false
    var queue: Int?
    var itemsOnSpark: Int?
    var eventsOnSpark: Int?
    var jobStates: [String: Int] = [:]
    var failedRefs: [String] = []
    var unfinishedRefs: [String] = []
    /// From the Spark queueing an item's job to finishing it (Spark clock).
    var enqueueToDoneP50Seconds: Double?
    var enqueueToDoneP90Seconds: Double?
  }

  let scenario: String
  let host: String
  let pace: Double
  var itemsInScenario = 0
  var itemsIngested = 0
  var itemsTakenInThisRun = 0
  /// Kept from an earlier run in the same work directory.
  var itemsResumed = 0
  /// Dropped from the ledger (never delivered before a revocation) and taken in anew.
  var itemsForgotten = 0
  var storeChanged = false
  var itemsSent = 0
  var ingestSeconds: Double = 0
  /// From the first item pasted to the last item first seen filed (in an
  /// event or Unfiled). `organize_seconds` is the same number.
  var firstPasteToLastFiledSeconds: Double = 0
  var organizeSeconds: Double = 0
  var itemsPerMinute: Double = 0
  /// Paste → first seen filed, per item (Mac wall clock, polled every 2 s).
  var pasteToFiledP50Seconds: Double?
  var pasteToFiledP90Seconds: Double?
  var medianOrganizedLatencySeconds: Double?
  var p90OrganizedLatencySeconds: Double?
  var byKind: [String: Int] = [:]
  var byIntakeKind: [String: Int] = [:]
  var bySourceApp: [String: Int] = [:]
  /// Characters of the items' text as sent (screenshots count 0).
  var totalCharacters = 0
  var eventCount = 0
  var unfiledCount = 0
  var personCount = 0
  var namedPersonCount = 0
  /// Open questions at the end.
  var questionCount = 0
  /// Distinct questions seen at any point of the run.
  var questionsAsked = 0
  /// Items the organizer split into more than one part.
  var itemsWithMultipleSegments = 0
  var splitItems: [Split] = []
  var grouping: [Grouping] = []
  var threads: [Thread] = []
  /// `spark_processed` (the Spark was asked) or `quiet_only`.
  var waitMode = ""
  var spark = Spark()
  var settled = false
  var timedOut = false
  var serviceClock: String?
  var elapsedSeconds: Double = 0
  var revocation: SparkEndToEndSummary.Revocation?
  var snapshots: [String] = []
  var exports: [String] = []
  var errors: [String] = []
  /// Upper-case item ID → when first seen placed; not encoded.
  var organizedAt: [String: Date] = [:]
  /// Not encoded.
  var questionIDs = Set<String>()

  enum CodingKeys: String, CodingKey {
    case scenario, host, pace, itemsInScenario, itemsIngested, itemsTakenInThisRun
    case itemsResumed, itemsForgotten, storeChanged, itemsSent, ingestSeconds
    case firstPasteToLastFiledSeconds, organizeSeconds, itemsPerMinute
    case pasteToFiledP50Seconds, pasteToFiledP90Seconds, medianOrganizedLatencySeconds
    case p90OrganizedLatencySeconds, byKind, byIntakeKind, bySourceApp, totalCharacters
    case eventCount, unfiledCount, personCount, namedPersonCount, questionCount, questionsAsked
    case itemsWithMultipleSegments, splitItems, grouping, threads, waitMode, spark, settled
    case timedOut, serviceClock, elapsedSeconds, revocation, snapshots, exports, errors
  }

  init(scenario: String, host: String, pace: Double) {
    self.scenario = scenario
    self.host = host
    self.pace = pace
  }

  mutating func describe(
    remote: RemoteOrganizerProjection, home: [MemoryHomeEntry],
    tracked: [ScenarioEndToEndTests.Tracked], jobs: [String: SparkEndToEndTests.JobRow],
    model: MemoryReadModel, texts: [String: String?]
  ) {
    itemsSent = tracked.filter { jobs[$0.id]?.deliveredRevision != nil }.count
    totalCharacters = tracked.reduce(0) { total, entry in
      guard let text = texts[entry.id] ?? nil, text != UserItemLimits.noTextLayerPlaceholder
      else { return total }
      return total + text.count
    }
    for entry in tracked {
      byKind[entry.kind, default: 0] += 1
      byIntakeKind[entry.intakeKind, default: 0] += 1
      bySourceApp[entry.sourceApp, default: 0] += 1
    }
    let latencies = tracked.compactMap { entry in
      organizedAt[entry.id].map { $0.timeIntervalSince(entry.ingestedAt) }
    }.sorted()
    if let p50 = Self.percentile(latencies, 50), let p90 = Self.percentile(latencies, 90) {
      pasteToFiledP50Seconds = Self.rounded(p50)
      pasteToFiledP90Seconds = Self.rounded(p90)
      medianOrganizedLatencySeconds = pasteToFiledP50Seconds
      p90OrganizedLatencySeconds = pasteToFiledP90Seconds
    }
    let ids = Set(tracked.map(\.id))
    if let first = tracked.map(\.ingestedAt).min(),
      let last = organizedAt.filter({ ids.contains($0.key) }).values.max()
    {
      organizeSeconds = Self.rounded(last.timeIntervalSince(first))
      firstPasteToLastFiledSeconds = organizeSeconds
      let filed = tracked.filter { organizedAt[$0.id] != nil }.count
      if organizeSeconds > 0 {
        itemsPerMinute = Self.rounded(Double(filed) / organizeSeconds * 60)
      }
    }
    let events = remote.events.filter { !$0.deleted }
    eventCount = events.count
    unfiledCount = remote.unfiled.count
    personCount = model.people.count
    namedPersonCount = model.people.filter(\.isNamed).count
    questionCount = remote.questions.count
    questionIDs.formUnion(remote.questions.map(\.questionID))
    questionsAsked = questionIDs.count
    let rank = Dictionary(uniqueKeysWithValues: home.enumerated().map { ($1.eventID, $0 + 1) })
    let refByID = Dictionary(uniqueKeysWithValues: tracked.map { ($0.id, $0.ref) })
    var placement: [String: [String]] = [:]
    var parts: [String: [Int]] = [:]
    var segmentIDs: [String: Set<String>] = [:]
    for event in events {
      let spot = "event:\(rank[event.eventID] ?? 0)"
      for id in event.itemIDs { placement[id.uppercased(), default: []].append(spot) }
      for part in event.segments {
        parts[part.itemID.uppercased(), default: []].append(rank[event.eventID] ?? 0)
        segmentIDs[part.itemID.uppercased(), default: []].insert(part.segID)
      }
    }
    itemsWithMultipleSegments = segmentIDs.values.filter { $0.count > 1 }.count
    for item in remote.unfiled where placement[item.itemID.uppercased()] == nil {
      placement[item.itemID.uppercased()] = ["unfiled:\(item.reason)"]
    }
    splitItems = parts.map { id, ranks in
      Split(ref: refByID[id] ?? "unknown", parts: ranks.count, homeRanks: ranks.sorted())
    }.sorted { $0.ref < $1.ref }
    var expected: [String: [ScenarioEndToEndTests.Tracked]] = [:]
    for entry in tracked {
      for event in entry.expectedEvents.isEmpty ? ["(none)"] : entry.expectedEvents {
        expected[event, default: []].append(entry)
      }
    }
    grouping = expected.keys.sorted().map { key in
      let spots = expected[key]!.flatMap { placement[$0.id] ?? ["missing"] }
      return Grouping(
        expectedEvent: key, items: expected[key]!.count,
        events: Set(spots.compactMap { $0.hasPrefix("event:") ? Int($0.dropFirst(6)) : nil })
          .sorted(),
        unfiled: spots.filter { $0.hasPrefix("unfiled:") }.count,
        missing: spots.filter { $0 == "missing" }.count)
    }
  }

  /// The organizing device's own account of this run's items.
  mutating func describeSpark(_ status: SparkProbe.Status, tracked: [ScenarioEndToEndTests.Tracked])
  {
    let sent = tracked.map(\.id)
    spark.processedAll = status.processedAll(sent)
    spark.queue = status.queue
    spark.itemsOnSpark = status.items
    spark.eventsOnSpark = status.events
    var states: [String: Int] = [:]
    var durations: [Double] = []
    for entry in tracked {
      guard let job = status.jobs[entry.id] else {
        states["absent", default: 0] += 1
        continue
      }
      states[job.state, default: 0] += 1
      if job.state == "failed" { spark.failedRefs.append(entry.ref) }
      if job.state == "done", let queued = job.enqueuedAt, let ended = job.runEnded,
        ended >= queued
      {
        durations.append(ended - queued)
      }
    }
    spark.jobStates = states
    spark.unfinishedRefs = Array(
      tracked.filter { status.jobs[$0.id]?.isFinished != true }.map(\.ref).prefix(40))
    durations.sort()
    spark.enqueueToDoneP50Seconds = Self.percentile(durations, 50).map(Self.rounded)
    spark.enqueueToDoneP90Seconds = Self.percentile(durations, 90).map(Self.rounded)
  }

  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  /// Nearest-rank on sorted values: p50 is the middle value, p90 the value
  /// 90 % of the way up.
  static func percentile(_ sorted: [Double], _ p: Int) -> Double? {
    guard !sorted.isEmpty else { return nil }
    return sorted[min(sorted.count - 1, sorted.count * p / 100)]
  }

  static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
