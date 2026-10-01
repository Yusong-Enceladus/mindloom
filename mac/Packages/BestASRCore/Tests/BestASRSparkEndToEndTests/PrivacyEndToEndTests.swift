import AppKit
import BestASRDomain
import BestASRIntake
import BestASRMemory
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import GRDB
import XCTest

/// Opt-in privacy check (contract v6 §8 E2E) against the owner's own
/// organizing device (Spark), on a fresh synthetic data root.
///
/// Five made-up items carry sentinel identifiers (phone, ID card, bank card,
/// email, password, verification code, API key) and a per-item plaintext
/// marker: a dictation, a pasted text, a PDF (text on the Mac), a chat
/// screenshot (redacted on the Mac, read on the Spark) and a spreadsheet
/// (bytes, read and masked on the Spark). The link runs through the real
/// controller, runtime, SSH forward and transport; a recording wrapper keeps
/// every request and answer in memory for the checks. Over a separate SSH
/// command a small Python program (sent on stdin, so nothing lands in argv or
/// on disk) scans every file of the Spark instance for each sentinel, marker
/// and key, and — with the library key, also on stdin — every decrypted row.
///
/// Steps: enable → items masked on the wire → no plaintext on the Spark's
/// disk (while the markers are in the decrypted rows) → originals restored on
/// the Mac → delete one item → purged on the Spark → link off → store locked →
/// link on (nothing re-sent) → "forget me" wipes the store and destroys the key
/// → link off → locked → the last store wiped over the API, files gone.
///
/// Skipped unless `BESTASR_E2E_SPARK_HOST`, `BESTASR_E2E_SPARK_SOCKET_PATH`,
/// `BESTASR_E2E_SPARK_TOKEN_PATH` and `BESTASR_E2E_SPARK_DATA_DIR` are set.
/// Also required: `BESTASR_E2E_SPARK_APP_DIR` (the organizer's code, for the
/// decrypted scan) and `BESTASR_E2E_SPARK_PYTHON` (its interpreter). Optional:
/// `BESTASR_E2E_SPARK_SCAN_DIRS` (more directories to scan, `:`-separated,
/// e.g. the organizer's log directory), `BESTASR_E2E_SPARK_WIDE_SCAN_DIRS`
/// (scanned only for this run's markers and keys, e.g. the whole instance
/// directory with its code), `BESTASR_E2E_KEEP_WORK=1`, `BESTASR_E2E_OUTPUT_DIR`,
/// `BESTASR_E2E_TIMEOUT_SECONDS` (default 600), `BESTASR_E2E_QUIET_SECONDS`
/// (default 40), `BESTASR_E2E_PURGE_SECONDS` (default 300: how long a deleted
/// item's text may take to leave re-briefed events).
@MainActor
final class PrivacyEndToEndTests: XCTestCase {
  typealias EndToEndError = SparkEndToEndTests.EndToEndError

  struct Remote: Sendable {
    let host: String
    let python: String
    let appDirectory: String
    let dataDirectory: String
    let scanDirectories: [String]
    /// Scanned only for this run's markers and keys (`BESTASR_E2E_SPARK_WIDE_SCAN_DIRS`).
    let wideDirectories: [String]
    let socket: String
    let token: String
  }

  static func remote(link: RemoteOrganizerLinkConfiguration) throws -> Remote {
    let environment = ProcessInfo.processInfo.environment
    func value(_ key: String) -> String? {
      let text = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return text.isEmpty ? nil : text
    }
    guard let data = value("BESTASR_E2E_SPARK_DATA_DIR") else {
      throw XCTSkip("Set BESTASR_E2E_SPARK_DATA_DIR (and _APP_DIR, _PYTHON) for the privacy check.")
    }
    guard let app = value("BESTASR_E2E_SPARK_APP_DIR"),
      let python = value("BESTASR_E2E_SPARK_PYTHON")
    else {
      throw EndToEndError("BESTASR_E2E_SPARK_APP_DIR and BESTASR_E2E_SPARK_PYTHON are required")
    }
    // The interpreter path goes into the remote command line: plain path only.
    guard
      python.unicodeScalars.allSatisfy({
        CharacterSet(charactersIn: "~/._-").contains($0)
          || ($0.isASCII && CharacterSet.alphanumerics.contains($0))
      })
    else { throw EndToEndError("BESTASR_E2E_SPARK_PYTHON must be a plain path") }
    func list(_ key: String) -> [String] {
      value(key)?.split(separator: ":").map(String.init) ?? []
    }
    return Remote(
      host: link.host, python: python, appDirectory: app, dataDirectory: data,
      scanDirectories: [data] + list("BESTASR_E2E_SPARK_SCAN_DIRS"),
      wideDirectories: list("BESTASR_E2E_SPARK_WIDE_SCAN_DIRS"), socket: link.remoteSocketPath,
      token: link.remoteTokenPath)
  }

  // MARK: - Synthetic content (every value is made up)

  struct Sentinel {
    let label: String
    let type: String
    let value: String
    /// Other spellings that must not leave either (compact, lower case).
    let variants: [String]
  }

  static let sentinels: [Sentinel] = [
    Sentinel(label: "phone", type: "phone", value: "13812345678", variants: []),
    Sentinel(
      label: "id_card", type: "id_card", value: "11010519491231002X",
      variants: ["11010519491231002x"]),
    Sentinel(
      label: "bank_card", type: "bank_card", value: "6222 0212 3456 7894",
      variants: ["6222021234567894"]),
    Sentinel(label: "email", type: "email", value: "zhang.san@example.com", variants: []),
    Sentinel(label: "password", type: "password", value: "Tr0ub4dor-3x", variants: ["Tr0ub4dor"]),
    Sentinel(label: "otp", type: "otp", value: "482913", variants: []),
    Sentinel(
      label: "api_key", type: "secret", value: "sk-proj-Ab3dEf6hIj9kLm2nOp5q", variants: []),
  ]
  /// A second phone number that appears only inside the spreadsheet: the Mac
  /// never sees it as text, so it can only ever be shown as `〔手机号〕`.
  static let sheetOnlyPhone = "13987654321"

  static func note(marker: String, intro: String) -> String {
    "\(marker) \(intro)：房东郑书恒的新手机号 13812345678，身份证 11010519491231002X，"
      + "押金退到卡号 6222 0212 3456 7894，邮箱 zhang.san@example.com，物业系统密码：Tr0ub4dor-3x，"
      + "验证码 482913，接口 key sk-proj-Ab3dEf6hIj9kLm2nOp5q。下周二下午三点在国贸见，押金 6000 元。"
  }

  struct Markers {
    let dictation: String
    let pasted: String
    let document: String
    let screenshot: String
    let sheet: String

    init() {
      let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
      let run = String((0..<10).map { _ in letters.randomElement()! })
      dictation = "ZJDICT" + run
      pasted = "ZJPASTE" + run
      document = "ZJDOC" + run
      screenshot = "ZJSHOT" + run
      sheet = "ZJSHEET" + run
    }

    var all: [(String, String)] {
      [
        ("marker_dictation", dictation), ("marker_pasted", pasted),
        ("marker_document", document), ("marker_screenshot", screenshot),
        ("marker_sheet", sheet),
      ]
    }
  }

  // MARK: - Recording transport

  /// Every exchange of every runtime, in order. Bodies stay in memory (the
  /// unlock body holds the key); only counts and paths are written out.
  final class ExchangeLog: @unchecked Sendable {
    struct Exchange: Sendable {
      let runtime: Int
      let method: String
      let path: String
      let body: Data?
      let status: Int?
      let response: Data?
      let at: Date
    }
    private let lock = NSLock()
    private var entries: [Exchange] = []
    private var runtimes = 0

    func nextRuntime() -> Int {
      lock.withLock {
        runtimes += 1
        return runtimes
      }
    }
    func append(_ exchange: Exchange) { lock.withLock { entries.append(exchange) } }
    var all: [Exchange] { lock.withLock { entries } }
  }

  final class RecordingTransport: RemoteOrganizerHTTPTransport, @unchecked Sendable {
    let inner = URLSessionRemoteOrganizerTransport()
    let log: ExchangeLog
    let runtime: Int

    init(log: ExchangeLog) {
      self.log = log
      runtime = log.nextRuntime()
    }

    func send(_ request: RemoteOrganizerHTTPRequest) async throws -> RemoteOrganizerHTTPResponse {
      do {
        let response = try await inner.send(request)
        log.append(
          .init(
            runtime: runtime, method: request.method, path: request.path, body: request.body,
            status: response.status, response: response.body, at: Date()))
        return response
      } catch {
        log.append(
          .init(
            runtime: runtime, method: request.method, path: request.path, body: request.body,
            status: nil, response: nil, at: Date()))
        throw error
      }
    }

    func cancelAll() { inner.cancelAll() }
  }

  // MARK: - The check

  struct Check: Codable {
    let name: String
    let passed: Bool
    let detail: String
  }

  private var checks: [Check] = []
  private var evidence: [String: Any] = [:]

  private func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
    let text = detail()
    checks.append(Check(name: name, passed: passed, detail: text))
    XCTAssertTrue(passed, "\(name): \(text)")
    print("privacy-e2e \(passed ? "PASS" : "FAIL") \(name) \(text)")
  }

  func testPrivacyContractOnOwnSpark() async throws {
    let settings = try SparkEndToEndTests.settings()
    let remote = try Self.remote(link: settings.link)
    setvbuf(stdout, nil, _IOLBF, 0)
    let environment = ProcessInfo.processInfo.environment
    let purgeWait =
      environment["BESTASR_E2E_PURGE_SECONDS"].flatMap(TimeInterval.init) ?? 300
    let fileManager = FileManager.default
    let started = Date()
    var timeline: [[String: Any]] = []
    func mark(_ step: String) {
      timeline.append(["step": step, "at_seconds": SparkEndToEndTests.seconds(started, Date())])
      print("privacy-e2e step \(step) at \(SparkEndToEndTests.seconds(started, Date())) s")
    }

    // The Spark instance must start clean: locked, no store.
    let initial = try await Self.probe(remote, calls: [("GET", "/v1/health", nil)])
    let initialHealth = initial.calls.first?.json ?? [:]
    guard initial.calls.first?.status == 200 else {
      throw EndToEndError("health unavailable: \(String(describing: initial.calls.first?.status))")
    }
    guard initialHealth["key_id"] is NSNull || initialHealth["key_id"] == nil else {
      throw EndToEndError(
        "the Spark instance already holds a store; wipe it before this check (synthetic only)")
    }
    evidence["initial_locked"] = initialHealth["locked"] as? Bool ?? false

    // A fresh synthetic data root and a real store.
    let work = fileManager.temporaryDirectory
      .appendingPathComponent("bestasr-privacy-e2e-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
    let keepWork = environment["BESTASR_E2E_KEEP_WORK"] == "1"
    defer { if !keepWork { try? fileManager.removeItem(at: work) } }
    if keepWork { print("privacy-e2e work directory kept: \(work.path)") }
    let root = try SparkEndToEndTests.makeSyntheticDataRoot(at: work.appendingPathComponent("root"))
    guard let realLibrary = BestASRDataRootSelection.ownerRealLibraryRoot() else {
      throw EndToEndError("owner library root unresolvable")
    }
    let databaseURL = root.appendingPathComponent("history.sqlite")
    let assetRoot = root.appendingPathComponent("assets", isDirectory: true)
    let store = try GRDBDictationStore(
      databaseURL: databaseURL, remoteItemTimeZone: SyntheticWeek.zone)
    let stateDirectory = work.appendingPathComponent("link-state", isDirectory: true)
    let intent = RemoteOrganizerLinkIntentFile(stateDirectory: stateDirectory, dataRoot: root)
    let keyStore = try FileOrganizerKeyStore(dataRoot: root, realLibraryRoot: realLibrary)
    let log = ExchangeLog()
    let link = settings.link
    let controller = RemoteOrganizerLinkController(
      repository: store, dataRoot: root, realLibraryRoot: realLibrary, intent: intent,
      keyStore: keyStore,
      cleanUpStaleTunnels: {
        _ = RemoteOrganizerTunnelRecordStore(directory: stateDirectory).cleanUpStale()
      },
      makeRuntime: { repository, keys, onUpdate in
        RemoteOrganizerRuntime(
          repository: repository,
          launcher: SSHRemoteOrganizerTunnelLauncher(
            configuration: link, stateDirectory: stateDirectory),
          http: RecordingTransport(log: log), keys: keys,
          itemAssetReader: RemoteOrganizerItemAssetReader(assetRoot: assetRoot),
          imageRedactor: VisionSendCopyRedactor(),
          fileSanitizer: FileSendCopySanitizer(),
          timing: RemoteOrganizerRuntime.Timing(pollInterval: .seconds(2)),
          onUpdate: onUpdate)
      })
    var statuses: [[String: Any]] = []
    controller.onChange = { status, _ in
      let name = SparkEndToEndTests.statusName(status)
      if (statuses.last?["status"] as? String) != name {
        statuses.append([
          "status": name, "at_seconds": SparkEndToEndTests.seconds(started, Date()),
        ])
      }
    }

    let markers = Markers()
    var failure: Error?
    var currentKeyID: String?

    do {
      XCTAssertEqual(controller.provenance, .allowed, "synthetic root must pass the guard")
      // The dictation's rows are written before the link runs (a second
      // writer on the library would contend with the link's own writes);
      // it becomes sendable through the capture path's grant below.
      let dictation = UUID()
      try await Self.seedCompletedDictation(
        databaseURL: databaseURL, id: dictation, at: Date().addingTimeInterval(-300),
        text: Self.note(marker: markers.dictation, intro: "口述记一下"))
      await controller.setEnabled(true)
      guard controller.isEnabled, let keys1 = try keyStore.load() else {
        throw EndToEndError(
          "link did not turn on: \(SparkEndToEndTests.statusName(controller.status))")
      }
      currentKeyID = keys1.keyID
      mark("enabled")

      // 1. Five items through the real intake (the dictation as the capture
      // path leaves it).
      try await store.markLiveCaptureRemoteEligible(sessionID: SessionID(dictation))
      let ids = try await Self.ingest(
        store: store, dictation: dictation, assetRoot: assetRoot, dataRoot: root,
        realLibrary: realLibrary, inbox: work.appendingPathComponent("inbox"), markers: markers)
      evidence["items_ingested"] = ids.all.count
      mark("ingested")

      // 2. Organized on the Spark and back on the Mac.
      let organized = try await Self.waitUntilPlaced(
        store: store, controller: controller, databaseURL: databaseURL, ids: ids.all.map(\.id),
        timeout: settings.timeout, quiet: settings.quiet)
      evidence["organize_seconds"] = organized.seconds
      evidence["placement"] = organized.placement.values.sorted()
      check(
        "every item organized on the Spark", organized.missing.isEmpty,
        "missing: \(organized.missing)")
      mark("organized")

      // 3. On the wire: placeholders only.
      try checkWire(log: log, keys: keys1, ids: ids, markers: markers)
      mark("wire checked")

      // 4. On the Spark's disk: nothing in plaintext; with the key, the
      // markers are there and the sentinels are not.
      let needles = Self.needles(markers: markers, keys: [keys1])
      let stats1 = try await Self.waitForStats(remote, access: keys1) { stats in
        (stats["blob_bytes"] as? Int) == 0 && (stats["items"] as? Int) == ids.all.count
      }
      evidence["stats_after_organizing"] = stats1
      check(
        "Spark holds the 5 items and no image/file bytes (read, then deleted)",
        (stats1["items"] as? Int) == ids.all.count && (stats1["blob_bytes"] as? Int) == 0,
        "\(stats1)")
      // Privacy review F1: the link token alone (a file on the Spark account)
      // reads nothing from the unlocked store.
      let tokenOnly = try await Self.probe(remote, calls: [("GET", "/v1/stats", nil)])
      check(
        "the link token without the key's access proof gets 403",
        tokenOnly.calls.first?.status == 403, "\(tokenOnly.calls.first?.status ?? -1)")
      let scan1 = try await Self.probe(remote, needles: needles, key: keys1)
      evidence["scan_after_organizing"] = scan1.summary
      check(
        "no sentinel, marker or key in any Spark file", scan1.rawHits.isEmpty,
        "files \(scan1.files.count), hits \(scan1.rawHits)")
      check("store is not a plaintext SQLite file", scan1.storeExists && !scan1.plaintextHeader)
      let decrypted1 = scan1.decrypted ?? [:]
      let sentinelLabels = Set(Self.sentinelNeedles().map(\.label))
      let decryptedSentinels = decrypted1.filter { sentinelLabels.contains($0.key) }
      check(
        "even decrypted, no sentinel is stored on the Spark", decryptedSentinels.isEmpty,
        "\(decryptedSentinels)")
      for label in ["marker_dictation", "marker_pasted", "marker_document", "marker_sheet"] {
        check(
          "positive control: \(label) is in the decrypted rows",
          (decrypted1[label]?.values.reduce(0, +) ?? 0) > 0, "\(decrypted1[label] ?? [:])")
      }
      evidence["screenshot_marker_decrypted_rows"] =
        decrypted1["marker_screenshot"]?.values.reduce(0, +) ?? 0
      mark("spark scanned")

      // 5. Shown on the Mac: originals where the Mac knows the value.
      try await checkUnmasked(
        store: store, databaseURL: databaseURL, controller: controller, log: log, ids: ids)
      mark("unmask checked")

      // 6. Delete the pasted item on the Mac: purged on the Spark.
      let deleted = ids.pasted
      try await store.deleteSessionRecordsExplicitly(sessionID: SessionID(deleted.uuid))
      let deletionSent = try await Self.waitUntil(timeout: 120) {
        guard
          log.all.contains(where: {
            $0.method == "DELETE" && $0.path == "/v1/items/\(deleted.id)" && $0.status == 200
          })
        else { return false }
        return try await store.pendingRemoteDeletions().isEmpty
      }
      check("deletion sent as DELETE /v1/items/{id} → 200", deletionSent)
      let deleteBodies = log.all.filter { $0.method == "DELETE" }.map { $0.body?.count ?? 0 }
      check("the deletion carries no content", deleteBodies.allSatisfy { $0 == 0 })
      mark("deletion sent")
      let purgeStart = Date()
      var scanDeleted = try await Self.probe(remote, needles: needles, key: keys1)
      while scanDeleted.decrypted?["marker_pasted"]?.isEmpty == false,
        Date().timeIntervalSince(purgeStart) < purgeWait
      {
        try await Task.sleep(for: .seconds(10))
        scanDeleted = try await Self.probe(remote, needles: needles, key: keys1)
      }
      evidence["purge_seconds"] = SparkEndToEndTests.seconds(purgeStart, Date())
      evidence["scan_after_delete"] = scanDeleted.summary
      check(
        "deleted item's text is gone from the Spark, even decrypted",
        scanDeleted.decrypted?["marker_pasted"] == nil,
        "\(scanDeleted.decrypted?["marker_pasted"] ?? [:])")
      check(
        "the other items stay",
        ["marker_dictation", "marker_document", "marker_sheet"].allSatisfy {
          (scanDeleted.decrypted?[$0]?.values.reduce(0, +) ?? 0) > 0
        })
      check(
        "still no plaintext in any Spark file after the delete", scanDeleted.rawHits.isEmpty,
        "\(scanDeleted.rawHits)")
      let stats2 = try await Self.waitForStats(remote, access: keys1) {
        ($0["items"] as? Int) == ids.all.count - 1
      }
      evidence["stats_after_delete"] = stats2
      check(
        "Spark stats count one item fewer", (stats2["items"] as? Int) == ids.all.count - 1,
        "\(stats2)")
      mark("purged")

      // 7. Turn the link off: the Spark store is locked.
      await controller.setEnabled(false)
      let lockCall = log.all.last { $0.path == "/v1/lock" }
      check("turning the link off sends POST /v1/lock → 200", lockCall?.status == 200)
      let off = try await Self.probe(
        remote, calls: [("GET", "/v1/health", nil), ("GET", "/v1/stats", nil)], needles: needles,
        key: nil)
      let offHealth = off.calls.first?.json ?? [:]
      evidence["health_after_off"] = Self.healthSummary(offHealth)
      check(
        "health says locked with this library's key",
        (offHealth["locked"] as? Bool) == true && (offHealth["key_id"] as? String) == keys1.keyID,
        "\(Self.healthSummary(offHealth))")
      check("data routes answer 423 while locked", off.calls.last?.status == 423)
      check("locked store: no plaintext in any file", off.rawHits.isEmpty, "\(off.rawHits)")
      mark("locked")

      // 8. A deletion made while the link is off waits on the Mac and is
      // the first thing sent after the next unlock.
      let deletedOff = ids.document
      try await store.deleteSessionRecordsExplicitly(sessionID: SessionID(deletedOff.uuid))
      let queuedOff = try await store.pendingRemoteDeletions()
      check("a deletion made while off is queued on the Mac", queuedOff == [deletedOff.id])

      // On again: unlock first, then the queued deletion, nothing sent again.
      let before = log.all.count
      await controller.setEnabled(true)
      let reconnected = try await Self.waitUntil(timeout: 90) {
        controller.status == .connected
          && log.all.dropFirst(before).contains { $0.path.hasPrefix("/v1/state") }
      }
      check("link reconnects and unlocks the same store", reconnected)
      try await Task.sleep(for: .seconds(6))
      let again = Array(log.all.dropFirst(before))
      let firstData = again.first { $0.path != "/v1/health" }
      check("the first data call after reconnecting is /v1/unlock", firstData?.path == "/v1/unlock")
      let afterUnlock = again.drop { $0.path != "/v1/unlock" }.dropFirst().first {
        $0.path != "/v1/health"
      }
      check(
        "the queued deletion is the first call after the unlock",
        afterUnlock?.method == "DELETE" && afterUnlock?.path == "/v1/items/\(deletedOff.id)"
          && afterUnlock?.status == 200,
        "\(afterUnlock?.method ?? "-") \(afterUnlock.map { $0.path.hasPrefix("/v1/items/") ? "/v1/items/{id}" : $0.path } ?? "-")"
      )
      let resent = again.filter { $0.path == "/v1/items" && $0.method == "POST" }.count
      check("nothing is sent again after reconnecting", resent == 0, "\(resent) item posts")
      check(
        "no deletion left queued after reconnecting",
        try await store.pendingRemoteDeletions().isEmpty)
      let scanOff = try await Self.probe(remote, needles: needles, key: keys1)
      evidence["scan_after_offline_delete"] = scanOff.summary
      check(
        "the item deleted while off is gone from the Spark, even decrypted",
        scanOff.decrypted?["marker_document"] == nil,
        "\(scanOff.decrypted?["marker_document"] ?? [:])")
      check(
        "the remaining items stay",
        ["marker_dictation", "marker_sheet"].allSatisfy {
          (scanOff.decrypted?[$0]?.values.reduce(0, +) ?? 0) > 0
        })
      check("no plaintext in any file", scanOff.rawHits.isEmpty, "\(scanOff.rawHits)")
      let stats3 = try await Self.waitForStats(remote, access: keys1) {
        ($0["items"] as? Int) == ids.all.count - 2
      }
      evidence["stats_after_offline_delete"] = stats3
      check(
        "Spark stats count two items fewer", (stats3["items"] as? Int) == ids.all.count - 2,
        "\(stats3)")
      mark("reconnected")

      // 9. "Forget me": wipe, key destroyed, a new key for an empty store.
      let forget = await controller.forgetOnOrganizer(.mine)
      check("forget answers forgotten", forget == .forgotten, "\(forget)")
      let wipeCall = log.all.last { $0.path == "/v1/wipe" }
      check("forget sends POST /v1/wipe → 200", wipeCall?.status == 200)
      let keys2 = try keyStore.load()
      check(
        "the old key is destroyed; a new one replaces it",
        keys2 != nil && keys2?.keyID != keys1.keyID)
      currentKeyID = keys2?.keyID
      let afterForget = (log.all.lastIndex { $0.path == "/v1/wipe" } ?? log.all.count - 1) + 1
      let newStore = try await Self.waitUntil(timeout: 90) {
        controller.status == .connected
          && log.all.dropFirst(afterForget).contains { $0.path.hasPrefix("/v1/state") }
      }
      check("the link goes on with the new key", newStore)
      try await Task.sleep(for: .seconds(6))
      let forgotten = try await Self.probe(
        remote, calls: [("GET", "/v1/health", nil), ("GET", "/v1/stats", nil)],
        needles: Self.needles(markers: markers, keys: [keys1] + (keys2.map { [$0] } ?? [])),
        key: nil, access: keys2)
      let forgottenHealth = forgotten.calls.first?.json ?? [:]
      let forgottenStats = forgotten.calls.last?.json ?? [:]
      evidence["health_after_forget"] = Self.healthSummary(forgottenHealth)
      evidence["stats_after_forget"] = forgottenStats
      check(
        "the Spark now holds only the new key's store",
        (forgottenHealth["key_id"] as? String) == keys2?.keyID
          && (forgottenHealth["key_id"] as? String) != keys1.keyID,
        "\(Self.healthSummary(forgottenHealth))")
      check("the new store is empty", (forgottenStats["items"] as? Int) == 0, "\(forgottenStats)")
      let resentAfterForget = log.all.dropFirst(afterForget).filter {
        $0.path == "/v1/items" && $0.method == "POST"
      }.count
      check("nothing re-sent after forgetting", resentAfterForget == 0, "\(resentAfterForget)")
      check(
        "after forgetting: no plaintext, marker or key in any file", forgotten.rawHits.isEmpty,
        "\(forgotten.rawHits)")
      let pending = try await store.pendingRemoteDeletions()
      check("no deletion left queued", pending.isEmpty)
      mark("forgotten")
    } catch {
      failure = error
      checks.append(Check(name: "run", passed: false, detail: String(describing: error)))
    }

    // 10. Off, locked; then the last store is wiped over the API while
    // locked and its files are gone. Runs even after a failure, so the Spark
    // instance ends clean.
    await controller.setEnabled(false)
    do {
      let locked = try await Self.probe(remote, calls: [("GET", "/v1/health", nil)])
      let health = locked.calls.first?.json ?? [:]
      evidence["health_after_final_off"] = Self.healthSummary(health)
      check("final link off: locked", (health["locked"] as? Bool) == true)
      let onDisk = health["key_id"] as? String
      if let currentKeyID, let onDisk {
        check("final lock is on the current key", onDisk == currentKeyID)
      }
      let wiped = try await Self.probe(
        remote,
        calls: [
          ("POST", "/v1/wipe", ["key_id": onDisk ?? currentKeyID ?? ""]),
          ("GET", "/v1/health", nil),
        ],
        needles: Self.needles(markers: markers, keys: []), key: nil)
      let after = wiped.calls.last?.json ?? [:]
      evidence["wipe_status"] = wiped.calls.first?.status ?? -1
      evidence["health_after_wipe"] = Self.healthSummary(after)
      evidence["data_dir_after_wipe"] = wiped.summary["data_dir_files"] ?? []
      check("wipe while locked → 200", wiped.calls.first?.status == 200)
      let storeFiles = wiped.files.keys.filter {
        let name = ($0 as NSString).lastPathComponent
        return name.hasPrefix("organizer.db") || name == "store.keyid"
      }
      check(
        "store files are gone (organizer.db, -wal, -shm, store.keyid)", storeFiles.isEmpty,
        "\(storeFiles)")
      check(
        "health after wipe: locked, no key",
        (after["locked"] as? Bool) == true && (after["key_id"] == nil || after["key_id"] is NSNull),
        "\(Self.healthSummary(after))")
      check("no marker in any file after the wipe", wiped.rawHits.isEmpty, "\(wiped.rawHits)")
    } catch {
      checks.append(Check(name: "final wipe", passed: false, detail: String(describing: error)))
      if failure == nil { failure = error }
    }
    mark("wiped")
    try? await store.checkpointAndClose()

    // Each link runtime's first request after the health check was the unlock.
    var firstDataCall: [Int: String] = [:]
    for exchange in log.all
    where exchange.path != "/v1/health" && firstDataCall[exchange.runtime] == nil {
      firstDataCall[exchange.runtime] = exchange.path
    }
    let unavailable = statuses.filter { ($0["status"] as? String) == "unavailable" }.count
    check("the link never dropped to unavailable", unavailable == 0, "\(unavailable) times")
    check(
      "each of the \(firstDataCall.count) link runtimes unlocked before any other call",
      firstDataCall.values.allSatisfy { $0 == "/v1/unlock" }, "\(firstDataCall)")

    // The summary: counts, paths and pass/fail only; no item content, no key.
    evidence["statuses"] = statuses
    // When each request left and how it was answered (paths without ids).
    evidence["exchange_timeline"] = log.all.map { exchange -> [String: Any] in
      var path = exchange.path
      if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
      if path.hasPrefix("/v1/items/") { path = "/v1/items/{id}" }
      return [
        "at_seconds": SparkEndToEndTests.seconds(started, exchange.at), "runtime": exchange.runtime,
        "request": "\(exchange.method) \(path)", "status": exchange.status ?? -1,
      ]
    }.filter { ($0["request"] as? String) != "GET /v1/state" }
    evidence["timeline"] = timeline
    evidence["requests"] = Self.requestCounts(log)
    evidence["elapsed_seconds"] = SparkEndToEndTests.seconds(started, Date())
    evidence["checks_passed"] = checks.filter(\.passed).count
    evidence["checks_failed"] = checks.filter { !$0.passed }.count
    evidence["checks"] = checks.map {
      ["name": $0.name, "passed": $0.passed, "detail": $0.detail] as [String: Any]
    }
    try fileManager.createDirectory(at: settings.output, withIntermediateDirectories: true)
    let summary = try JSONSerialization.data(
      withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
    try summary.write(
      to: settings.output.appendingPathComponent("privacy-e2e-summary.json"), options: .atomic)
    print("privacy-e2e output: \(settings.output.path)")
    print(
      "privacy-e2e checks: \(checks.filter(\.passed).count) passed, "
        + "\(checks.filter { !$0.passed }.count) failed")
    if let failure { throw failure }
  }

  // MARK: - Intake

  struct Ingested {
    struct Entry {
      let label: String
      let uuid: UUID
      var id: String { uuid.uuidString }
    }
    let dictation: Entry
    let pasted: Entry
    let document: Entry
    let screenshot: Entry
    let sheet: Entry
    var all: [Entry] { [dictation, pasted, document, screenshot, sheet] }
  }

  static func ingest(
    store: GRDBDictationStore, dictation: UUID, assetRoot: URL, dataRoot: URL,
    realLibrary: URL, inbox: URL, markers: Markers
  ) async throws -> Ingested {
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let policy = IntakePathPolicy { url in
      [realLibrary, dataRoot].contains {
        BestASRDataRootSelection.path(url, isWithinOrEqualTo: $0)
      }
    }
    // The App's own on-device reader: its reading stays on the Mac.
    let processor = IntakeProcessor(
      assetStore: IntakeAssetStore(assetRoot: assetRoot), pathPolicy: policy,
      imageReader: VisionImageTextReader())
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("bestASR.e2e.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let now = Date()

    func commit(
      _ candidate: IntakeCandidate, at date: Date, app: SyntheticWeek.App,
      origin: ItemSourceOrigin, label: String
    ) async throws -> Ingested.Entry {
      let outcome = processor.prepare(
        candidate, capturedAt: date, source: app.source, origin: origin)
      guard case .item(let draft) = outcome else {
        throw EndToEndError("\(label) was not taken in: \(outcome)")
      }
      do { try await store.createUserItem(draft) } catch {
        processor.assetStore.discard(sessionID: draft.id)
        throw error
      }
      processor.assetStore.commit(sessionID: draft.id)
      return .init(label: label, uuid: draft.id.rawValue)
    }

    pasteboard.clearContents()
    pasteboard.setString(note(marker: markers.pasted, intro: "郑书恒发来的续租信息"), forType: .string)
    let pasted = try await commit(
      try SparkEndToEndTests.readSingle(pasteboard), at: now.addingTimeInterval(-240),
      app: .weChat, origin: .previousFrontmost, label: "pasted")

    let pdf = inbox.appendingPathComponent("续租合同补充页.pdf")
    try SyntheticRendering.textPDF(
      title: "续租合同补充页",
      lines: [
        "续租合同补充页", "编号 \(markers.document)", "出租人：郑书恒  电话 13812345678",
        "身份证 11010519491231002X", "收款卡号 6222 0212 3456 7894", "邮箱 zhang.san@example.com",
        "网签密码：Tr0ub4dor-3x", "验证码 482913", "接口 key sk-proj-Ab3dEf6hIj9kLm2nOp5q",
        "押金 6000 元，2026 年 10 月 1 日起续租一年。",
      ]
    ).write(to: pdf, options: .atomic)
    let document = try await commit(
      .file(pdf), at: now.addingTimeInterval(-180), app: .finder, origin: .finder,
      label: "document")

    let png = try SyntheticRendering.chatScreenshotPNG(
      title: "郑书恒", clock: "10:30",
      bubbles: [
        .init(fromMe: false, sender: "郑书恒", text: "新号码 13812345678，有事打这个"),
        .init(fromMe: true, sender: "我", text: "身份证 11010519491231002X"),
        .init(fromMe: false, sender: "郑书恒", text: "押金退到卡号 6222 0212 3456 7894"),
        .init(fromMe: false, sender: "郑书恒", text: "邮箱 zhang.san@example.com"),
        .init(fromMe: true, sender: "我", text: "key sk-proj-Ab3dEf6hIj9kLm2nOp5q"),
        .init(fromMe: false, sender: "郑书恒", text: "周二下午三点国贸见 \(markers.screenshot)"),
      ])
    pasteboard.clearContents()
    let pasteItem = NSPasteboardItem()
    pasteItem.setData(png, forType: .png)
    pasteboard.writeObjects([pasteItem])
    let screenshot = try await commit(
      try SparkEndToEndTests.readSingle(pasteboard), at: now.addingTimeInterval(-120),
      app: .weChat, origin: .previousFrontmost, label: "screenshot")

    let sheetURL = inbox.appendingPathComponent("押金清单.xlsx")
    try writeSpreadsheet(
      to: sheetURL, work: inbox,
      rows: [
        ["项目", "内容"], ["联系电话", "13812345678"], ["备用电话", sheetOnlyPhone],
        ["收款卡号", "6222 0212 3456 7894"], ["邮箱", "zhang.san@example.com"],
        ["备注", "\(markers.sheet) 续租押金 6000 元"],
      ])
    let sheet = try await commit(
      .file(sheetURL), at: now.addingTimeInterval(-60), app: .finder, origin: .finder,
      label: "sheet")

    return Ingested(
      dictation: .init(label: "dictation", uuid: dictation), pasted: pasted, document: document,
      screenshot: screenshot, sheet: sheet)
  }

  /// A completed dictation with one final transcript, as the capture path
  /// leaves one (no audio on this Mac in this run; the transcript is the
  /// made-up note). Written while the link is off, so it is not yet
  /// sendable; `markLiveCaptureRemoteEligible` grants that.
  static func seedCompletedDictation(databaseURL: URL, id: UUID, at date: Date, text: String)
    async throws
  {
    var configuration = Configuration()
    configuration.busyMode = .timeout(10)
    let writer = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
    let created = date.timeIntervalSince1970
    let sessionID = id.uuidString
    try await writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions (
            id, revision, input_mode, state, source_audio_retention, created_at, updated_at
          ) VALUES (?, 1, 'dictation', 'completed', 'retained', ?, ?)
          """, arguments: [sessionID, created, created + 1])
      try db.execute(
        sql: """
          INSERT INTO dictation_snapshots (
            session_id, control_revision, phase, snapshot_json, is_ephemeral, updated_at
          ) VALUES (?, 1, 'completed', ?, 0, ?)
          """, arguments: [sessionID, Data("{}".utf8), created + 1])
      try db.execute(
        sql: """
          INSERT INTO transcript_revisions (id, session_id, revision, kind, content, created_at)
          VALUES (?, ?, 1, 'final', ?, ?)
          """, arguments: [UUID().uuidString, sessionID, text, created + 1])
    }
    try writer.close()
  }

  /// A minimal .xlsx (inline strings) zipped by the system `zip`.
  static func writeSpreadsheet(to url: URL, work: URL, rows: [[String]]) throws {
    let package = work.appendingPathComponent("xlsx-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: package) }
    func escape(_ text: String) -> String {
      text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    }
    let columns = ["A", "B", "C", "D"]
    var sheetRows = ""
    for (r, row) in rows.enumerated() {
      sheetRows += "<row r=\"\(r + 1)\">"
      for (c, cell) in row.enumerated() {
        sheetRows +=
          "<c r=\"\(columns[c])\(r + 1)\" t=\"inlineStr\"><is><t>\(escape(cell))</t></is></c>"
      }
      sheetRows += "</row>"
    }
    let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    let parts: [(String, String)] = [
      (
        "[Content_Types].xml",
        head
          + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
          + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
          + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
          + "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
          + "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
          + "</Types>"
      ),
      (
        "_rels/.rels",
        head
          + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
          + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
          + "</Relationships>"
      ),
      (
        "xl/workbook.xml",
        head
          + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
          + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
          + "<sheets><sheet name=\"押金\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
      ),
      (
        "xl/_rels/workbook.xml.rels",
        head
          + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
          + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
          + "</Relationships>"
      ),
      (
        "xl/worksheets/sheet1.xml",
        head
          + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
          + "<sheetData>\(sheetRows)</sheetData></worksheet>"
      ),
    ]
    for (path, text) in parts {
      let file = package.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: file, options: .atomic)
    }
    try? FileManager.default.removeItem(at: url)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = package
    process.arguments = ["-q", "-X", "-r", url.path] + parts.map(\.0)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw EndToEndError("zip failed") }
  }

  // MARK: - Waiting

  struct Placement {
    let placement: [String: String]
    let missing: [String]
    let seconds: Double
  }

  static func waitUntilPlaced(
    store: GRDBDictationStore, controller: RemoteOrganizerLinkController, databaseURL: URL,
    ids: [String], timeout: TimeInterval, quiet: TimeInterval
  ) async throws -> Placement {
    let started = Date()
    let deadline = started.addingTimeInterval(timeout)
    var lastCursor: Int64 = -1
    var lastChange = Date()
    var placement: [String: String] = [:]
    while Date() < deadline {
      try await Task.sleep(for: .seconds(2))
      switch controller.status {
      case .refused, .wrongKey, .unsupportedService, .keyUnavailable:
        throw EndToEndError("link: \(SparkEndToEndTests.statusName(controller.status))")
      default: break
      }
      let projection = try await store.remoteProjection()
      let all = SparkEndToEndTests.placement(projection)
      placement = all.filter { ids.contains($0.key) }
      let jobs = try SparkEndToEndTests.jobRows(databaseURL)
      if let parked = ids.first(where: { jobs[$0]?.state == "failed" }) {
        throw EndToEndError("\(parked) parked on the Mac: \(jobs[parked]?.errorCategory ?? "")")
      }
      if projection.cursor != lastCursor {
        lastCursor = projection.cursor
        lastChange = Date()
      }
      if placement.count == ids.count, Date().timeIntervalSince(lastChange) >= quiet {
        return Placement(
          placement: placement, missing: [], seconds: SparkEndToEndTests.seconds(started, Date()))
      }
    }
    return Placement(
      placement: placement, missing: ids.filter { placement[$0] == nil },
      seconds: SparkEndToEndTests.seconds(started, Date()))
  }

  static func waitUntil(
    timeout: TimeInterval, _ condition: @MainActor () async throws -> Bool
  ) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if try await condition() { return true }
      try await Task.sleep(for: .seconds(2))
    }
    return try await condition()
  }

  static func waitForStats(
    _ remote: Remote, access: OrganizerKeyMaterial?, timeout: TimeInterval = 120,
    _ done: ([String: Any]) -> Bool
  ) async throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(timeout)
    var stats: [String: Any] = [:]
    repeat {
      let result = try await probe(remote, calls: [("GET", "/v1/stats", nil)], access: access)
      stats = result.calls.first?.json ?? ["status": result.calls.first?.status ?? -1]
      if done(stats) { return stats }
      try await Task.sleep(for: .seconds(5))
    } while Date() < deadline
    return stats
  }

  // MARK: - Wire

  static func sentinelNeedles() -> [(label: String, value: String)] {
    var result: [(label: String, value: String)] = []
    for sentinel in sentinels {
      result.append((sentinel.label, sentinel.value))
      for (index, variant) in sentinel.variants.enumerated() {
        result.append(("\(sentinel.label)_\(index + 2)", variant))
      }
    }
    result.append(("phone_sheet_only", sheetOnlyPhone))
    return result
  }

  /// Every string a JSON value holds (keys excluded), with the given keys'
  /// values left out.
  static func strings(_ value: Any, skipping: Set<String> = []) -> [String] {
    switch value {
    case let text as String: return [text]
    case let array as [Any]: return array.flatMap { strings($0, skipping: skipping) }
    case let object as [String: Any]:
      return object.filter { !skipping.contains($0.key) }.flatMap {
        strings($0.value, skipping: skipping)
      }
    default: return []
    }
  }

  static let binaryFields: Set<String> = ["image_b64", "bytes_b64", "extra_images_b64"]

  private func checkWire(
    log: ExchangeLog, keys: OrganizerKeyMaterial, ids: Ingested, markers: Markers
  ) throws {
    let exchanges = log.all
    let masker = PrivacyMasker(keys: keys)
    var itemBodies: [String: [String: Any]] = [:]
    var leaked: [String] = []
    var keyElsewhere = 0
    for exchange in exchanges {
      guard let body = exchange.body, !body.isEmpty else { continue }
      if exchange.path == "/v1/unlock" { continue }
      if String(decoding: body, as: UTF8.self).contains(keys.libraryKeyHex) { keyElsewhere += 1 }
      guard let object = try? JSONSerialization.jsonObject(with: body) else { continue }
      let text = Self.strings(object, skipping: Self.binaryFields).joined(separator: "\n")
      for (label, value) in Self.sentinelNeedles() where text.contains(value) {
        leaked.append("\(exchange.method) \(exchange.path): \(label)")
      }
      if exchange.path == "/v1/items", let items = (object as? [String: Any])?["items"] as? [Any] {
        for case let item as [String: Any] in items {
          if let id = item["item_id"] as? String { itemBodies[id.uppercased()] = item }
        }
      }
    }
    check("no sentinel in any request's text fields", leaked.isEmpty, "\(leaked)")
    check("the key crosses only in /v1/unlock", keyElsewhere == 0, "\(keyElsewhere)")
    check(
      "every item was posted", ids.all.allSatisfy { itemBodies[$0.id] != nil },
      "\(ids.all.filter { itemBodies[$0.id] == nil }.map(\.label))")

    // Every text item carries one placeholder per sentinel, and its marker.
    let placeholders = Self.sentinels.map { masker.placeholder(type: $0.type, value: $0.value) }
    for (entry, marker) in [
      (ids.dictation, markers.dictation), (ids.pasted, markers.pasted),
      (ids.document, markers.document),
    ] {
      let fields =
        itemBodies[entry.id].map {
          Self.strings($0, skipping: Self.binaryFields).joined(separator: "\n")
        } ?? ""
      let missing = zip(Self.sentinels, placeholders).filter { !fields.contains($0.1) }.map {
        $0.0.label
      }
      check(
        "\(entry.label): every identifier left as its placeholder", missing.isEmpty,
        "missing \(missing)")
      check("\(entry.label): the marker (not an identifier) is sent as is", fields.contains(marker))
    }
    let first = exchanges.first { $0.path != "/v1/health" }
    check("the first data call is /v1/unlock", first?.path == "/v1/unlock", first?.path ?? "none")

    // The screenshot's send copy: Vision reads no identifier in it any more,
    // while the rest of the text survives.
    let reader = VisionImageTextReader()
    if let base64 = itemBodies[ids.screenshot.id]?["image_b64"] as? String,
      let image = Data(base64Encoded: base64)
    {
      // Vision on this Mac now and then fails a request outright (no text at
      // all); one more try tells that apart from a copy with nothing left.
      let read = reader.readText(imageData: image) ?? reader.readText(imageData: image) ?? ""
      let compact = read.replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "-", with: "").lowercased()
      let visible = Self.sentinels.filter { $0.label != "password" && $0.label != "otp" }
        .filter {
          compact.contains(
            $0.value.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
              .lowercased())
        }.map(\.label)
      let longDigits = read.replacingOccurrences(of: " ", with: "").split(whereSeparator: {
        !($0.isASCII && $0.isNumber)
      }).filter { $0.count >= 7 }.count
      check(
        "screenshot send copy: no identifier readable", visible.isEmpty && longDigits == 0,
        "visible \(visible), digit runs ≥7: \(longDigits)")
      check(
        "screenshot send copy: the rest of the text survives",
        read.contains("国贸") || read.contains(markers.screenshot), "\(read.count) chars read")
      evidence["screenshot_send_copy_bytes"] = image.count
      evidence["screenshot_send_copy_chars_read"] = read.count
    } else {
      check("screenshot was sent as an image", false)
    }
    let sheetFields =
      itemBodies[ids.sheet.id].map {
        Self.strings($0, skipping: Self.binaryFields).joined(separator: "\n")
      } ?? ""
    check(
      "spreadsheet goes as bytes (read on the Spark)",
      itemBodies[ids.sheet.id]?["bytes_b64"] is String && !sheetFields.contains(markers.sheet))
    evidence["wire_items_posted"] = itemBodies.count
    evidence["wire_requests"] = exchanges.count
  }

  // MARK: - Unmask

  private func checkUnmasked(
    store: GRDBDictationStore, databaseURL: URL, controller: RemoteOrganizerLinkController,
    log: ExchangeLog, ids: Ingested
  ) async throws {
    // A rename carrying a phone number: masked on the wire, stored masked on
    // the Spark, shown as typed on the Mac.
    let projection0 = try await store.remoteProjection()
    let eventID =
      projection0.events.first { $0.itemIDs.contains { $0.uppercased() == ids.dictation.id } }?
      .eventID ?? projection0.events.first?.eventID
    let typed = "给 13812345678 回电 · 续租"
    if let eventID {
      let decision = RemoteOrganizerDecision(kind: "rename_event", eventID: eventID, title: typed)
      try await controller.record(decision)
      let applied = try await Self.waitUntil(timeout: 120) {
        guard log.all.contains(where: { $0.path == "/v1/decisions" && $0.status == 200 })
        else { return false }
        let events = try await store.remoteProjection().events
        return events.first { $0.eventID == eventID }?.title == typed
      }
      check("rename delivered", applied)
      try await Task.sleep(for: .seconds(8))
    } else {
      check("an event to rename", false)
    }

    // What the Spark sent back: placeholders.
    var returned: Set<String> = []
    var returnedBySection: [String: Int] = [:]
    for exchange in log.all where exchange.path.hasPrefix("/v1/state") {
      guard let data = exchange.response, let object = try? JSONSerialization.jsonObject(with: data)
      else { continue }
      for text in Self.strings(object) {
        returned.formUnion(Self.tagged(text))
      }
      // Which parts of the state carried them (events, readings, persons, …).
      for (section, value) in (object as? [String: Any]) ?? [:] {
        let count = Self.strings(value).map { Self.tagged($0).count }.reduce(0, +)
        if count > 0 { returnedBySection[section, default: 0] += count }
      }
    }
    evidence["placeholders_returned_by_state_section"] = returnedBySection
    let known = try Self.maskMap(databaseURL)
    let knownReturned = returned.filter { known[$0]?.count == 1 }
    let unknownReturned = returned.subtracting(knownReturned)
    evidence["placeholders_returned"] = returned.count
    evidence["placeholders_returned_known"] = knownReturned.count
    evidence["placeholders_returned_unknown"] = unknownReturned.count
    check(
      "the Spark returned placeholders the Mac knows", !knownReturned.isEmpty,
      "\(returned.count) returned")

    // What the Mac shows and exports.
    let projection = try await store.remoteProjection()
    var shown = Self.mirrorStrings(projection)
    let shownPaths = Self.mirrorPaths(projection, path: "projection")
    let sources = projection.events.filter { !$0.deleted }.map(MemoryProjection.source)
    let records = try await store.memoryItemRecords(
      ids: MemoryProjection.sessionIDs(
        sources.flatMap(\.itemIDs) + projection.unfiled.map(\.itemID)))
    let formatter = EventPlainTextFormatter(timeZone: SyntheticWeek.zone)
    var exported = 0
    for event in projection.events {
      if let detail = MemoryProjection.sparkEventDetail(
        event.eventID, projection: projection, records: records)
      {
        shown.append(formatter.format(detail))
        exported += 1
      }
    }
    evidence["events_exported"] = exported
    let tagged = shown.flatMap { Self.tagged($0) }
    let taggedWhere = shownPaths.filter { !Self.tagged($0.1).isEmpty }.map {
      "\($0.0) (\(known[Self.tagged($0.1)[0]]?.count ?? 0) originals known)"
    }
    check(
      "no tagged placeholder is shown or exported on the Mac", tagged.isEmpty,
      "\(Set(tagged).count) distinct; in \(taggedWhere); exports \(tagged.count - taggedWhere.count)"
    )
    let restored = knownReturned.filter { placeholder in
      guard let original = known[placeholder]?.first else { return false }
      return shown.contains { $0.contains(original) }
    }
    check(
      "every known placeholder the Spark returned is shown as its original",
      restored.count == knownReturned.count, "\(restored.count)/\(knownReturned.count)")
    evidence["placeholders_restored"] = restored.count
    let sheetOnly = shown.contains { $0.contains(Self.sheetOnlyPhone) }
    check("a number the Mac never saw is not guessed", !sheetOnly)
    let untaggedShown = shown.contains { $0.contains("〔手机号〕") }
    evidence["untagged_phone_shown"] = untaggedShown
    if let eventID {
      let title = projection.events.first { $0.eventID == eventID }?.title
      check("the renamed title is shown as typed", title == typed)
      let stored = try Self.storedEventTitle(databaseURL: databaseURL, eventID: eventID)
      check(
        "the Spark holds the renamed title masked",
        stored.map { !$0.contains("13812345678") && $0.contains("〔手机号·") } ?? false)
    }
    let readingText = projection.readings[ids.sheet.id] ?? ""
    evidence["sheet_reading_chars"] = readingText.count
    let readingOK =
      readingText.contains("13812345678") && !readingText.contains(Self.sheetOnlyPhone)
      && Self.tagged(readingText).isEmpty
    // Synthetic content: shown only when the check fails.
    check(
      "spreadsheet reading: the known number is restored, the unknown one is untagged",
      readingOK,
      readingOK
        ? "\(readingText.count) chars"
        : "reading: \(readingText) | summary: \(projection.readingSummaries[ids.sheet.id] ?? "-")")
  }

  /// Placeholders that still carry their tag (`〔手机号·a1b2c3〕`); the
  /// untagged form (`〔手机号〕`) is what the Mac shows for a value it does
  /// not know.
  static func tagged(_ text: String) -> [String] {
    PrivacyUnmask.placeholders(in: text).filter { $0.contains("\u{00B7}") }
  }

  static func maskMap(_ databaseURL: URL) throws -> [String: Set<String>] {
    try withDatabase(databaseURL) { db in
      var result: [String: Set<String>] = [:]
      for row in try Row.fetchAll(
        db, sql: "SELECT DISTINCT placeholder, original FROM remote_mask_map")
      {
        result[row["placeholder"], default: []].insert(row["original"])
      }
      return result
    }
  }

  static func storedEventTitle(databaseURL: URL, eventID: String) throws -> String? {
    try withDatabase(databaseURL) { db in
      for data in try Data.fetchAll(db, sql: "SELECT payload_json FROM remote_organizer_events") {
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          (object["event_id"] as? String) == eventID
        {
          return object["title"] as? String
        }
      }
      return nil
    }
  }

  static func withDatabase<T>(_ url: URL, _ body: (Database) throws -> T) throws -> T {
    let queue = try SparkEndToEndTests.readOnlyQueue(url)
    defer { try? queue.close() }
    return try queue.read(body)
  }

  /// Like `mirrorStrings`, with the field path of each string.
  static func mirrorPaths(_ value: Any, path: String) -> [(String, String)] {
    if let text = value as? String { return [(path, text)] }
    var result: [(String, String)] = []
    for (index, child) in Mirror(reflecting: value).children.enumerated() {
      result += mirrorPaths(child.value, path: path + "." + (child.label ?? "\(index)"))
    }
    return result
  }

  /// Every `String` reachable in a value (struct fields, arrays, dictionary
  /// values and keys, optionals).
  static func mirrorStrings(_ value: Any) -> [String] {
    if let text = value as? String { return [text] }
    var result: [String] = []
    for child in Mirror(reflecting: value).children {
      result += mirrorStrings(child.value)
    }
    return result
  }

  // MARK: - The Spark over SSH

  struct Probe {
    struct Call {
      let status: Int
      let json: [String: Any]?
    }
    var calls: [Call] = []
    var files: [String: Int] = [:]
    var rawHits: [String: [String]] = [:]
    var decrypted: [String: [String: Int]]?
    var storeExists = false
    var plaintextHeader = false
    var decryptedRows = 0
    /// How the data directory's files are named in `files` (its basename).
    var dataPrefix = ""

    var summary: [String: Any] {
      var result: [String: Any] = [
        "files_scanned": files.count, "bytes_scanned": files.values.filter { $0 > 0 }.reduce(0, +),
        "unreadable_files": files.values.filter { $0 < 0 }.count,
        "data_dir_files": files.keys.filter { $0.hasPrefix(dataPrefix) }.sorted(),
        "plaintext_hits": rawHits,
        "store_exists": storeExists, "store_plaintext_header": plaintextHeader,
      ]
      if let decrypted {
        result["decrypted_rows_scanned"] = decryptedRows
        result["decrypted_hits"] = decrypted
      }
      return result
    }
  }

  static func needles(markers: Markers, keys: [OrganizerKeyMaterial]) -> [(
    label: String, bytes: Data
  )] {
    var result: [(label: String, bytes: Data)] = sentinelNeedles().map {
      (label: $0.label, bytes: Data($0.value.utf8))
    }
    result += markers.all.map { (label: $0.0, bytes: Data($0.1.utf8)) }
    for (index, key) in keys.enumerated() {
      result.append(("library_key_hex_\(index + 1)", Data(key.libraryKeyHex.utf8)))
      result.append(("library_key_raw_\(index + 1)", key.libraryKey))
      result.append(("store_key_raw_\(index + 1)", key.storeKey))
      result.append(
        ("store_key_hex_\(index + 1)", Data(OrganizerKeyMaterial.hex(key.storeKey).utf8)))
      result.append(("mask_key_raw_\(index + 1)", key.maskKey))
    }
    return result
  }

  /// Runs the probe program on the Spark: the listed API calls over the
  /// organizer's Unix socket (the token is read there, never sent from
  /// here), then — with needles — a scan of every file in the scan
  /// directories, and — with a key — of every decrypted row.
  static func probe(
    _ remote: Remote, calls: [(String, String, [String: String]?)] = [],
    needles: [(label: String, bytes: Data)] = [], key: OrganizerKeyMaterial? = nil,
    access: OrganizerKeyMaterial? = nil
  ) async throws -> Probe {
    var request: [String: Any] = [
      "socket": remote.socket, "token": remote.token, "data_dir": remote.dataDirectory,
      "scan_dirs": remote.scanDirectories, "wide_dirs": remote.wideDirectories,
      "app_dir": remote.appDirectory,
      "calls": calls.map { [$0.0, $0.1, $0.2.map { $0 as Any } ?? NSNull()] as [Any] },
      "scan": !needles.isEmpty,
      "needles": needles.map {
        ["label": $0.label, "hex": OrganizerKeyMaterial.hex($0.bytes)]
      },
    ]
    if let key { request["key_hex"] = key.libraryKeyHex }
    // Privacy review F1: a store the Mac unlocked answers data routes only with
    // the key-derived access proof (the link token alone gets 403).
    if let access { request["access"] = access.accessProof }
    let json = try JSONSerialization.data(withJSONObject: request)
    let script = probeScript.replacingOccurrences(
      of: "__REQUEST__", with: json.base64EncodedString())
    let host = remote.host
    let python = remote.python
    let (status, output, errors) = try await Task.detached {
      try runSSH(host: host, command: "\(python) -", input: Data(script.utf8))
    }.value
    guard status == 0,
      let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any]
    else {
      let message = String(decoding: errors.suffix(800), as: UTF8.self)
      throw EndToEndError("Spark probe failed (\(status)): \(message)")
    }
    var probe = Probe()
    probe.dataPrefix = (remote.dataDirectory as NSString).lastPathComponent + "/"
    for case let call as [String: Any] in object["calls"] as? [Any] ?? [] {
      probe.calls.append(
        .init(status: call["status"] as? Int ?? -1, json: call["json"] as? [String: Any]))
    }
    probe.files = object["files"] as? [String: Int] ?? [:]
    probe.rawHits = object["raw_hits"] as? [String: [String]] ?? [:]
    probe.storeExists = object["store_exists"] as? Bool ?? false
    probe.plaintextHeader = object["store_plaintext_header"] as? Bool ?? false
    if key != nil {
      if let error = object["decrypted_error"] as? String {
        throw EndToEndError("decrypted scan failed: \(error)")
      }
      probe.decrypted = object["decrypted_hits"] as? [String: [String: Int]] ?? [:]
      probe.decryptedRows = object["decrypted_rows"] as? Int ?? 0
    }
    return probe
  }

  nonisolated static func runSSH(host: String, command: String, input: Data) throws -> (
    Int32, Data, Data
  ) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = [
      "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-T", host, command,
    ]
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let errorData = LockedData()
    let errorHandle = stderr.fileHandleForReading
    let errorReader = Thread {
      errorData.set(errorHandle.readDataToEndOfFile())
    }
    errorReader.start()
    stdin.fileHandleForWriting.write(input)
    try stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    while !errorData.done { Thread.sleep(forTimeInterval: 0.01) }
    return (process.terminationStatus, output, errorData.value)
  }

  final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false
    func set(_ value: Data) {
      lock.withLock {
        data = value
        finished = true
      }
    }
    var done: Bool { lock.withLock { finished } }
    var value: Data { lock.withLock { data } }
  }

  static func healthSummary(_ health: [String: Any]) -> [String: Any] {
    [
      "ok": health["ok"] ?? NSNull(), "locked": health["locked"] ?? NSNull(),
      "key_id": health["key_id"] ?? NSNull(), "items": health["items"] ?? NSNull(),
    ]
  }

  static func requestCounts(_ log: ExchangeLog) -> [String: Int] {
    var counts: [String: Int] = [:]
    for exchange in log.all {
      var path = exchange.path
      if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
      if path.hasPrefix("/v1/items/") { path = "/v1/items/{id}" }
      counts[
        "\(exchange.method) \(path) \(exchange.status.map(String.init) ?? "error")", default: 0] +=
        1
    }
    return counts
  }

  /// The probe program (Python 3, run by the organizer's own interpreter).
  /// Its request arrives base64-encoded inside the program on stdin.
  static let probeScript = #"""
    import base64, http.client, json, os, socket, sys
    from pathlib import Path

    REQ = json.loads(base64.b64decode("__REQUEST__").decode("utf-8"))


    def expand(p):
        return os.path.abspath(os.path.expanduser(p))


    class UnixHTTPConnection(http.client.HTTPConnection):
        def __init__(self, path, timeout):
            super().__init__("localhost", timeout=timeout)
            self.unix_path = path

        def connect(self):
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(self.timeout)
            sock.connect(self.unix_path)
            self.sock = sock


    def call(method, path, body):
        with open(expand(REQ["token"]), "r", encoding="utf-8") as fh:
            token = fh.read().strip()
        conn = UnixHTTPConnection(expand(REQ["socket"]), 120)
        headers = {"Authorization": "Bearer " + token}
        if REQ.get("access"):
            headers["X-Mindloom-Access"] = REQ["access"]
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        try:
            conn.request(method, path, body=data, headers=headers)
            resp = conn.getresponse()
            raw = resp.read()
            status = resp.status
        finally:
            conn.close()
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except Exception:
            parsed = None
        return {"status": status, "json": parsed}


    out = {"calls": [call(m, p, b) for m, p, b in REQ.get("calls", [])]}
    needles = [(n["label"], bytes.fromhex(n["hex"])) for n in REQ.get("needles", [])]
    if REQ.get("scan"):
        files, raw_hits, seen = {}, {}, set()
        # The data and log directories are scanned for every needle; the wider
        # directories (the instance's code and environment, whose test files may
        # hold the shared synthetic sentinels) only for this run's markers and keys.
        unique = [(label, needle) for label, needle in needles
                  if label.startswith("marker_") or "_key_" in label]
        dirs = [(d, needles) for d in REQ.get("scan_dirs", [])]
        dirs += [(d, unique) for d in REQ.get("wide_dirs", [])]
        for d, wanted in dirs:
            root = expand(d)
            base = os.path.basename(root.rstrip("/"))
            for dirpath, _dirs, names in os.walk(root):
                for name in names:
                    p = os.path.join(dirpath, name)
                    if os.path.islink(p) or not os.path.isfile(p) or os.path.realpath(p) in seen:
                        continue
                    seen.add(os.path.realpath(p))
                    rel = os.path.join(base, os.path.relpath(p, root))
                    try:
                        with open(p, "rb") as fh:
                            blob = fh.read()
                    except OSError:
                        files[rel] = -1
                        continue
                    files[rel] = len(blob)
                    for label, needle in wanted:
                        if needle in blob:
                            raw_hits.setdefault(label, []).append(rel)
        out["files"] = files
        out["raw_hits"] = raw_hits
        store = os.path.join(expand(REQ["data_dir"]), "organizer.db")
        out["store_exists"] = os.path.exists(store)
        try:
            with open(store, "rb") as fh:
                out["store_plaintext_header"] = fh.read(16) == b"SQLite format 3\x00"
        except FileNotFoundError:
            out["store_plaintext_header"] = False
        if REQ.get("key_hex"):
            try:
                sys.path.insert(0, os.path.join(expand(REQ["app_dir"]), "spark"))
                from organizer import db as odb, keys as okeys
                key_id, store_key, _mask = okeys.derive_keys(bytes.fromhex(REQ["key_hex"]))
                dec, rows = {}, 0
                if os.path.exists(store):
                    conn = odb.connect(Path(store), store_key, readonly=True)
                    try:
                        tables = [r[0] for r in conn.execute(
                            "SELECT name FROM sqlite_master WHERE type='table'")]
                        for t in tables:
                            for row in conn.execute('SELECT * FROM "%s"' % t.replace('"', '""')):
                                rows += 1
                                for v in row:
                                    if v is None:
                                        continue
                                    b = v if isinstance(v, bytes) else str(v).encode("utf-8")
                                    for label, needle in needles:
                                        if needle in b:
                                            dec.setdefault(label, {}).setdefault(t, 0)
                                            dec[label][t] += 1
                    finally:
                        conn.close()
                out["decrypted_hits"] = dec
                out["decrypted_rows"] = rows
                out["decrypted_key_id"] = key_id
            except Exception as exc:
                out["decrypted_error"] = type(exc).__name__
    print(json.dumps(out, ensure_ascii=False))
    """#
}
