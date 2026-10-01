import AppKit
import BestASRDomain
import BestASRIntake
import BestASRPersistence
import BestASRRemoteOrganizer
import CryptoKit
import Foundation
import GRDB
import ImageIO
import MindloomLink
import XCTest

/// Opt-in phone path check (PHONE-CONTRACT §6 E2E) against the owner's own
/// organizing device (Spark) and its relay, with the iPhone app running in
/// the iOS simulator. Synthetic data only.
///
/// 1. A fresh synthetic data root; the link on (unlock), as the App requires
///    for "连接 iPhone".
/// 2. Pairing through the real `PhonePairingService` over the Mac's own ssh:
///    `ssh -G` resolves the route (ProxyJump relay), `ssh-keygen -F` pins the
///    ed25519 host keys, the phone key is installed on the Spark (forced
///    `zhiji-inbox gate`) and on the relay (port forward to the Spark's port
///    22 only). Both `authorized_keys` files are checked: exactly one new line
///    with the contract's options, every other line unchanged.
/// 3. The link off (the store locks): the phone must deliver without the Mac.
/// 4. The pairing code goes to the simulator's pasteboard (`xcrun simctl
///    pbcopy`); it is never written to disk or printed. Then the test waits
///    while the app is paired by paste and shares a text, an image and one
///    keyboard dictation, each with a plaintext marker.
/// 5. The Spark inbox holds only `mlseal1.` blobs; no marker or identifier is
///    in any file of the instance.
/// 6. The link on: the runtime pulls the inbox, opens each entry with this
///    Mac's seal key into a user item (source `iPhone 键盘` / `iPhone 分享`,
///    time = the phone's `created_at`), commits and acknowledges; the inbox
///    is empty. The items are masked and organized like any other item.
/// 7. Link off, the store wiped (the instance ends as found), then "断开
///    iPhone": both key lines gone, both files byte-identical to the start.
///
/// Skipped unless `BESTASR_E2E_PHONE_INBOX_COMMAND` (absolute path of
/// `zhiji-inbox` on the Spark) is set, plus everything
/// `PrivacyEndToEndTests` needs (`BESTASR_E2E_SPARK_HOST`, `_SOCKET_PATH`,
/// `_TOKEN_PATH`, `_DATA_DIR`, `_APP_DIR`, `_PYTHON`). Also required:
/// `BESTASR_E2E_PHONE_SIMULATOR` (the simulator's UDID) and
/// `BESTASR_E2E_PHONE_MARKERS` (`keyboard=…,share_text=…,image_meta=…,
/// image_pixels=…`, capital letters only: the markers the driver puts into
/// the dictation, the shared text, the image's metadata and the image's
/// pixels). Optional: `BESTASR_E2E_PHONE_WAIT_SECONDS` (default 1800),
/// `BESTASR_E2E_PHONE_AFTER_UNPAIR_SECONDS` (default 0: after unpairing, wait
/// this long for one more item from the phone and check both hosts refuse it),
/// `BESTASR_E2E_PHONE_LABEL` (default "E2E 测试 Mac"), and the Spark test's
/// `BESTASR_E2E_OUTPUT_DIR`, `BESTASR_E2E_TIMEOUT_SECONDS`,
/// `BESTASR_E2E_QUIET_SECONDS`, `BESTASR_E2E_SPARK_SCAN_DIRS`,
/// `BESTASR_E2E_SPARK_WIDE_SCAN_DIRS`, `BESTASR_E2E_KEEP_WORK`.
@MainActor
final class PhoneEndToEndTests: XCTestCase {
  typealias EndToEndError = SparkEndToEndTests.EndToEndError
  typealias Remote = PrivacyEndToEndTests.Remote

  /// A made-up phone number the driver puts into the dictation, the shared
  /// text and the image: it must leave the Mac only as a placeholder.
  static let phoneNumber = "13812345678"
  static let expectedEntries = 3

  struct PhoneSettings {
    static let markerLabels = ["keyboard", "share_text", "image_meta", "image_pixels"]

    let inboxCommand: String
    let simulator: String
    let markers: [String: String]
    let wait: TimeInterval
    let label: String
    /// After unpairing, how long to wait for one more item from the phone
    /// (0: skip that check).
    let afterUnpairWait: TimeInterval
  }

  static func phoneSettings() throws -> PhoneSettings {
    let environment = ProcessInfo.processInfo.environment
    func value(_ key: String) -> String? {
      let text = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return text.isEmpty ? nil : text
    }
    guard let command = value("BESTASR_E2E_PHONE_INBOX_COMMAND") else {
      throw XCTSkip(
        "Set BESTASR_E2E_PHONE_INBOX_COMMAND (and the phone variables) for the phone check.")
    }
    guard command.hasPrefix("/"), PhoneLinkSSHCommand.isSafeCommandPath(command) else {
      throw EndToEndError("BESTASR_E2E_PHONE_INBOX_COMMAND must be a plain absolute path")
    }
    guard let simulator = value("BESTASR_E2E_PHONE_SIMULATOR"), UUID(uuidString: simulator) != nil
    else { throw EndToEndError("BESTASR_E2E_PHONE_SIMULATOR must be the simulator's UDID") }
    var markers: [String: String] = [:]
    for pair in (value("BESTASR_E2E_PHONE_MARKERS") ?? "").split(separator: ",") {
      let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2, parts[1].count >= 8,
        parts[1].unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) })
      else {
        throw EndToEndError("BESTASR_E2E_PHONE_MARKERS: \(parts.first ?? "") is not LABEL=LETTERS")
      }
      markers[parts[0]] = parts[1]
    }
    guard Set(markers.keys) == Set(PhoneSettings.markerLabels) else {
      throw EndToEndError("BESTASR_E2E_PHONE_MARKERS needs \(PhoneSettings.markerLabels)")
    }
    return PhoneSettings(
      inboxCommand: command, simulator: simulator, markers: markers,
      wait: value("BESTASR_E2E_PHONE_WAIT_SECONDS").flatMap(TimeInterval.init) ?? 1800,
      label: value("BESTASR_E2E_PHONE_LABEL") ?? "E2E 测试 Mac",
      afterUnpairWait: value("BESTASR_E2E_PHONE_AFTER_UNPAIR_SECONDS").flatMap(TimeInterval.init)
        ?? 0)
  }

  // MARK: - Checks

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
    print("phone-e2e \(passed ? "PASS" : "FAIL") \(name) \(text)")
  }

  // MARK: - The run

  func testPhonePairingAndSealedIngestOnOwnSpark() async throws {
    let phone = try Self.phoneSettings()
    let settings = try SparkEndToEndTests.settings()
    let remote = try PrivacyEndToEndTests.remote(link: settings.link)
    setvbuf(stdout, nil, _IOLBF, 0)
    let fileManager = FileManager.default
    let started = Date()
    var timeline: [[String: Any]] = []
    func mark(_ step: String) {
      timeline.append(["step": step, "at_seconds": SparkEndToEndTests.seconds(started, Date())])
      print("phone-e2e step \(step) at \(SparkEndToEndTests.seconds(started, Date())) s")
    }

    // 0. The Spark instance starts clean: no store, empty inbox, no phone
    // keys on either host.
    let initial = try await PrivacyEndToEndTests.probe(remote, calls: [("GET", "/v1/health", nil)])
    let initialHealth = initial.calls.first?.json ?? [:]
    guard initial.calls.first?.status == 200 else {
      throw EndToEndError("health unavailable: \(String(describing: initial.calls.first?.status))")
    }
    guard initialHealth["key_id"] is NSNull || initialHealth["key_id"] == nil,
      (initialHealth["inbox_pending"] as? Int) == 0
    else {
      throw EndToEndError(
        "the Spark instance is not clean (store or pending inbox entries); synthetic only")
    }
    let hosts = try await Self.hosts(sparkAlias: settings.link.host)
    evidence["relay_configured"] = hosts.relay != nil
    let baseSpark = try await Self.keyFile(hosts.spark, keyID: nil)
    var baseRelay: KeyFile?
    if let relay = hosts.relay { baseRelay = try await Self.keyFile(relay, keyID: nil) }
    guard baseSpark.phoneLines == 0, (baseRelay?.phoneLines ?? 0) == 0 else {
      throw EndToEndError("a phone key line is already installed; unpair it first")
    }
    evidence["authorized_keys_lines_before"] = [
      "spark": baseSpark.lineCount, "relay": baseRelay?.lineCount ?? -1,
    ]
    mark("clean start")

    // 1. A fresh synthetic root, a real store and the link as the App builds
    // it, with this library's phone seal key in a 0600 file inside the root
    // (synthetic roots only) and the real inbox ingestor.
    let work = fileManager.temporaryDirectory
      .appendingPathComponent("bestasr-phone-e2e-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
    let keepWork = ProcessInfo.processInfo.environment["BESTASR_E2E_KEEP_WORK"] == "1"
    defer { if !keepWork { try? fileManager.removeItem(at: work) } }
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
    let sealKeys = try FilePhoneSealKeyStore(dataRoot: root, realLibraryRoot: realLibrary)
    let policy = IntakePathPolicy { url in
      [realLibrary, root].contains { BestASRDataRootSelection.path(url, isWithinOrEqualTo: $0) }
    }
    let processor = IntakeProcessor(
      assetStore: IntakeAssetStore(assetRoot: assetRoot), pathPolicy: policy,
      imageReader: VisionImageTextReader())
    let ingestor = IntakeInboxIngestor(
      processor: processor, store: store, sealKey: { try sealKeys.load() })
    let log = PrivacyEndToEndTests.ExchangeLog()
    let link = settings.link
    var discarded: [String] = []
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
          http: PrivacyEndToEndTests.RecordingTransport(log: log), keys: keys,
          itemAssetReader: RemoteOrganizerItemAssetReader(assetRoot: assetRoot),
          imageRedactor: VisionSendCopyRedactor(), fileSanitizer: FileSendCopySanitizer(),
          inbox: ingestor,
          timing: RemoteOrganizerRuntime.Timing(pollInterval: .seconds(2)),
          onUpdate: onUpdate
        ).withInboxDiscardHandler { reason in discarded.append(reason.rawValue) }
      })
    var statuses: [[String: Any]] = []
    controller.onChange = { status, _ in
      let name = SparkEndToEndTests.statusName(status)
      if (statuses.last?["status"] as? String) != name {
        statuses.append(["status": name, "at_seconds": SparkEndToEndTests.seconds(started, Date())])
      }
    }
    let stateFile = PhonePairingStateFile(stateDirectory: stateDirectory, dataRoot: root)
    let service = PhonePairingService(
      settings: try PhonePairingSettings(sparkHost: link.host, inboxCommand: phone.inboxCommand),
      runner: ProcessPhoneLinkCommandRunner(), sealKeys: sealKeys)

    var paired: PhonePairingState?
    var currentKeyID: String?
    var failure: Error?
    let markers = phone.markers

    do {
      XCTAssertEqual(controller.provenance, .allowed, "synthetic root must pass the guard")
      // 2. The link on ("连接 iPhone" is offered only then).
      await controller.setEnabled(true)
      guard controller.isEnabled, let keys = try keyStore.load() else {
        throw EndToEndError(
          "link did not turn on: \(SparkEndToEndTests.statusName(controller.status))")
      }
      currentKeyID = keys.keyID
      let connected = try await PrivacyEndToEndTests.waitUntil(timeout: 90) {
        controller.status == .connected
      }
      check("the link connects and unlocks the Spark store", connected)
      mark("link on")

      // 3. "连接 iPhone".
      let pairingStarted = Date()
      let pairing = try await service.pair(label: phone.label, replacing: nil)
      paired = pairing.state
      try stateFile.save(pairing.state)
      evidence["pairing_seconds"] = SparkEndToEndTests.seconds(pairingStarted, Date())
      let payload = try PairingPayload.decode(text: pairing.code)
      let sealKey = try XCTUnwrap(try sealKeys.load())
      try checkPairing(
        payload: payload, state: pairing.state, sealKey: sealKey, hosts: hosts,
        inboxCommand: phone.inboxCommand)
      // The phone's private key exists only in the code: no file of this
      // Mac's root or link state holds it (raw or base64).
      let secretHits = Self.filesContaining(
        [payload.phoneKey, Data(payload.phoneKey.base64EncodedString().utf8)], under: work)
      check(
        "the phone's private key is in no file on the Mac (root, link state, pairing state)",
        secretHits.isEmpty, "\(secretHits.count) files")
      // The pairing is remembered. Its time goes through JSON as seconds
      // since 1970, which is not always the same Double back (about half of
      // the time one unit in the last place off), so it is compared to 1 ms.
      let remembered = stateFile.load()
      check(
        "the Mac remembers the pairing (key id, hosts, inbox command, time)",
        remembered.map {
          $0.keyID == pairing.state.keyID && $0.label == pairing.state.label
            && $0.spark == pairing.state.spark && $0.relay == pairing.state.relay
            && $0.inboxCommand == pairing.state.inboxCommand
            && abs($0.pairedAt.timeIntervalSince(pairing.state.pairedAt)) < 0.001
        } ?? false)
      let sparkAfterPair = try await Self.keyFile(hosts.spark, keyID: pairing.state.keyID)
      var relayAfterPair: KeyFile?
      if let relay = hosts.relay {
        relayAfterPair = try await Self.keyFile(relay, keyID: pairing.state.keyID)
      }
      checkInstalledLines(
        spark: sparkAfterPair, relay: relayAfterPair, baseSpark: baseSpark, baseRelay: baseRelay,
        payload: payload, inboxCommand: phone.inboxCommand)
      let phonesListed = try await Self.listPhones(hosts.spark, command: phone.inboxCommand)
      check(
        "list-phones on the Spark shows the phone as restricted to the gate",
        phonesListed.contains {
          ($0["key_id"] as? String) == pairing.state.keyID
            && ($0["restricted"] as? Bool) == true && ($0["type"] as? String) == "ssh-ed25519"
        }, "\(phonesListed.count) phones")
      mark("paired")

      // 4. The Mac goes away: link off, the store locks. The phone must
      // still be able to drop sealed entries into the inbox.
      await controller.setEnabled(false)
      let lockCall = log.all.last { $0.path == "/v1/lock" }
      check("turning the link off sends POST /v1/lock → 200", lockCall?.status == 200)

      // 5. The code to the simulator (paste), then wait for the phone.
      try Self.simulatorPasteboard(phone.simulator, text: pairing.code)
      mark("code on the simulator pasteboard")
      print(
        "phone-e2e READY: paste the pairing code in the app, then share the text and the image "
          + "and dictate once; waiting up to \(Int(phone.wait)) s for \(Self.expectedEntries) "
          + "sealed entries")
      let waitStarted = Date()
      var lastPending = -1
      var pendingNow = 0
      while Date().timeIntervalSince(waitStarted) < phone.wait {
        let health = try await PrivacyEndToEndTests.probe(
          remote, calls: [("GET", "/v1/health", nil)])
        pendingNow = health.calls.first?.json?["inbox_pending"] as? Int ?? -1
        if pendingNow != lastPending {
          print(
            "phone-e2e inbox_pending \(pendingNow) at \(SparkEndToEndTests.seconds(started, Date())) s"
          )
          timeline.append([
            "step": "inbox_pending \(pendingNow)",
            "at_seconds": SparkEndToEndTests.seconds(started, Date()),
          ])
          lastPending = pendingNow
        }
        if pendingNow >= Self.expectedEntries { break }
        try await Task.sleep(for: .seconds(3))
      }
      // The code (with the phone's private key) leaves the pasteboard.
      try? Self.simulatorPasteboard(phone.simulator, text: "")
      evidence["phone_wait_seconds"] = SparkEndToEndTests.seconds(waitStarted, Date())
      guard pendingNow >= Self.expectedEntries else {
        throw EndToEndError("only \(pendingNow) entries arrived from the phone")
      }
      // A late fourth entry would be a surprise; give it a moment to show.
      try await Task.sleep(for: .seconds(5))
      mark("entries arrived")

      // 6. What waits on the Spark: sealed blobs only; opened here (test
      // side) only to learn what the phone sent, for the checks below.
      let inbox = try await Self.inboxRows(remote, withBlobs: true)
      let pending = inbox.filter { !$0.acked }
      let expected = try checkSealedInbox(
        pending: pending, sealKey: sealKey, markers: markers, pairedAt: pairingStarted)
      let needles = Self.needles(markers: markers)
      let scanWaiting = try await PrivacyEndToEndTests.probe(remote, needles: needles, key: nil)
      evidence["scan_while_waiting"] = scanWaiting.summary
      check(
        "while waiting: no marker or phone number in any file of the Spark instance",
        scanWaiting.rawHits.isEmpty && !scanWaiting.files.isEmpty,
        "files \(scanWaiting.files.count), hits \(scanWaiting.rawHits)")
      check(
        "while waiting: the Spark store stays locked and encrypted (no plaintext header)",
        !scanWaiting.plaintextHeader)
      mark("inbox checked")

      // 7. The Mac comes back: the runtime opens the entries into items,
      // commits, then acknowledges; the inbox empties.
      let before = log.all.count
      await controller.setEnabled(true)
      let sessionIDs = expected.map(\.sessionID)
      let taken = try await PrivacyEndToEndTests.waitUntil(timeout: 240) {
        let health = try await PrivacyEndToEndTests.probe(
          remote, calls: [("GET", "/v1/health", nil)])
        guard (health.calls.first?.json?["inbox_pending"] as? Int) == 0 else { return false }
        return try Self.existingSessions(databaseURL, ids: sessionIDs).count == sessionIDs.count
      }
      check("the Mac takes every phone entry in and the Spark inbox is empty", taken)
      let exchanges = Array(log.all.dropFirst(before))
      let acks = exchanges.filter {
        $0.method == "POST" && $0.path.hasPrefix("/v1/inbox/") && $0.path.hasSuffix("/ack")
      }
      check(
        "each entry acknowledged once the item was committed (POST /v1/inbox/{id}/ack → 200)",
        Set(acks.filter { $0.status == 200 }.map(\.path))
          == Set(expected.map { "/v1/inbox/\($0.inboxID)/ack" }),
        "\(acks.count) acks")
      check("no entry was dropped as unopenable or unusable", discarded.isEmpty, "\(discarded)")
      evidence["inbox_requests"] = exchanges.filter { $0.path.hasPrefix("/v1/inbox") }.count
      try checkItems(
        databaseURL: databaseURL, assetRoot: assetRoot, expected: expected, markers: markers)
      let afterAck = try await Self.inboxRows(remote, withBlobs: false)
      let ours = afterAck.filter { row in expected.contains { $0.inboxID == row.inboxID } }
      check(
        "after the ack the Spark keeps only content-free rows (blob gone) for these entries",
        ours.count == expected.count && ours.allSatisfy { $0.acked && $0.blobNull },
        "\(ours.map { "acked=\($0.acked) blob_null=\($0.blobNull)" })")
      mark("taken in")

      // 8. From here they are ordinary items: masked on the wire and
      // organized on the Spark.
      let organized = try await PrivacyEndToEndTests.waitUntilPlaced(
        store: store, controller: controller, databaseURL: databaseURL,
        ids: sessionIDs.map(\.rawValue.uuidString), timeout: settings.timeout,
        quiet: settings.quiet)
      evidence["organize_seconds"] = organized.seconds
      evidence["placement"] = organized.placement.values.sorted()
      check(
        "every phone item is organized on the Spark", organized.missing.isEmpty,
        "missing \(organized.missing.count)")
      try checkWire(log: log, keys: keys, expected: expected, markers: markers)
      mark("organized")

      let afterOrganize = try await PrivacyEndToEndTests.probe(
        remote,
        needles: needles
          + PrivacyEndToEndTests.needles(
            markers: PrivacyEndToEndTests.Markers(), keys: [keys]
          ).filter { $0.label.contains("_key_") }, key: keys)
      evidence["scan_after_organizing"] = afterOrganize.summary
      check(
        "after organizing: no marker, phone number or key in any Spark file",
        afterOrganize.rawHits.isEmpty, "\(afterOrganize.rawHits)")
      check(
        "the store is not a plaintext SQLite file",
        afterOrganize.storeExists && !afterOrganize.plaintextHeader)
      let decrypted = afterOrganize.decrypted ?? [:]
      check(
        "even decrypted, the phone number is not stored on the Spark (masked)",
        decrypted["phone_number"] == nil, "\(decrypted["phone_number"] ?? [:])")
      for label in ["marker_keyboard", "marker_share_text"] {
        check(
          "positive control: \(label) is in the decrypted rows",
          (decrypted[label]?.values.reduce(0, +) ?? 0) > 0, "\(decrypted[label] ?? [:])")
      }
      check(
        "the image's metadata marker never reached the Spark, even decrypted",
        decrypted["marker_image_meta"] == nil)
      evidence["image_pixels_marker_decrypted_rows"] =
        decrypted["marker_image_pixels"]?.values.reduce(0, +) ?? 0
      mark("spark scanned")
    } catch {
      failure = error
      checks.append(Check(name: "run", passed: false, detail: String(describing: error)))
      print("phone-e2e FAIL run \(error)")
    }

    // 9. Always: the code off the pasteboard; link off (locked); the store
    // wiped over the API, so the instance ends as found.
    try? Self.simulatorPasteboard(phone.simulator, text: "")
    await controller.setEnabled(false)
    do {
      let locked = try await PrivacyEndToEndTests.probe(remote, calls: [("GET", "/v1/health", nil)])
      let onDisk = locked.calls.first?.json?["key_id"] as? String
      if onDisk != nil || currentKeyID != nil {
        let wiped = try await PrivacyEndToEndTests.probe(
          remote,
          calls: [
            ("POST", "/v1/wipe", ["key_id": onDisk ?? currentKeyID ?? ""]),
            ("GET", "/v1/health", nil),
          ])
        let after = wiped.calls.last?.json ?? [:]
        evidence["health_after_wipe"] = PrivacyEndToEndTests.healthSummary(after)
        check(
          "final: store wiped while locked; health locked, no key, inbox empty",
          wiped.calls.first?.status == 200 && (after["locked"] as? Bool) == true
            && (after["key_id"] == nil || after["key_id"] is NSNull)
            && (after["inbox_pending"] as? Int) == 0,
          "\(PrivacyEndToEndTests.healthSummary(after)) pending \(after["inbox_pending"] ?? "-")")
      }
    } catch {
      checks.append(Check(name: "final wipe", passed: false, detail: String(describing: error)))
      if failure == nil { failure = error }
    }

    // 10. "断开 iPhone": both key lines gone, both files as they were.
    var unpairedAt: Date?
    if let state = paired ?? stateFile.load() {
      do {
        try await service.revoke(state)
        unpairedAt = Date()
        try stateFile.clear()
        let sparkAfter = try await Self.keyFile(hosts.spark, keyID: state.keyID)
        var relayAfter: KeyFile?
        if let relay = hosts.relay {
          relayAfter = try await Self.keyFile(relay, keyID: state.keyID)
        }
        check(
          "unpair: no mindloom-phone line left on the Spark; file byte-identical to the start",
          sparkAfter.phoneLines == 0 && sparkAfter.lines.isEmpty && sparkAfter.sha == baseSpark.sha,
          "phones \(sparkAfter.phoneLines), same \(sparkAfter.sha == baseSpark.sha)")
        if let relayAfter, let baseRelay {
          check(
            "unpair: no mindloom-phone line left on the relay; file byte-identical to the start",
            relayAfter.phoneLines == 0 && relayAfter.lines.isEmpty
              && relayAfter.sha == baseRelay.sha,
            "phones \(relayAfter.phoneLines), same \(relayAfter.sha == baseRelay.sha)")
        }
        let phonesAfter = try await Self.listPhones(hosts.spark, command: phone.inboxCommand)
        check(
          "unpair: list-phones no longer shows the phone",
          !phonesAfter.contains { ($0["key_id"] as? String) == state.keyID })
        check("unpair: the Mac forgets the phone", stateFile.load() == nil)
      } catch {
        checks.append(Check(name: "unpair", passed: false, detail: String(describing: error)))
        if failure == nil { failure = error }
      }
    }
    mark("unpaired")

    // 11. Optional: the phone, still holding the old pairing, tries once
    // more; both hosts refuse its key and nothing reaches the inbox.
    if let unpairedAt, phone.afterUnpairWait > 0 {
      do {
        print(
          "phone-e2e UNPAIRED: make one more item on the phone; waiting up to "
            + "\(Int(phone.afterUnpairWait)) s for its refused attempt")
        let refused = try await Self.waitForRefusedAttempt(
          simulator: phone.simulator, after: unpairedAt, timeout: phone.afterUnpairWait)
        check(
          "after unpair the phone's next send is refused (its key no longer opens the relay)",
          refused.map { ["authentication", "relayRefused"].contains($0.error) } ?? false,
          refused.map { "last_error \($0.error), attempts \($0.attempts)" } ?? "no attempt seen")
        let health = try await PrivacyEndToEndTests.probe(
          remote, calls: [("GET", "/v1/health", nil)])
        let rows = try await Self.inboxRows(remote, withBlobs: false)
        check(
          "after unpair nothing new reached the Spark inbox",
          (health.calls.first?.json?["inbox_pending"] as? Int) == 0
            && !rows.contains { $0.inboxID == refused?.entryID },
          "pending \(health.calls.first?.json?["inbox_pending"] ?? "-")")
        evidence["after_unpair_refusal"] = refused?.error ?? "none"
      } catch {
        checks.append(
          Check(name: "after unpair", passed: false, detail: String(describing: error)))
        if failure == nil { failure = error }
      }
      mark("refused after unpair")
    }
    try? await store.checkpointAndClose()

    let unavailable = statuses.filter { ($0["status"] as? String) == "unavailable" }.count
    evidence["link_unavailable_times"] = unavailable
    evidence["statuses"] = statuses
    evidence["timeline"] = timeline
    evidence["requests"] = PrivacyEndToEndTests.requestCounts(log).reduce(into: [String: Int]()) {
      var key = $1.key
      if key.contains("/v1/inbox/") {
        key = key.replacingOccurrences(
          of: #"/v1/inbox/[^ ]+/ack"#, with: "/v1/inbox/{id}/ack", options: .regularExpression)
      }
      $0[key, default: 0] += $1.value
    }
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
      to: settings.output.appendingPathComponent("phone-e2e-summary.json"), options: .atomic)
    print("phone-e2e output: \(settings.output.path)")
    print(
      "phone-e2e checks: \(checks.filter(\.passed).count) passed, "
        + "\(checks.filter { !$0.passed }.count) failed")
    if let failure { throw failure }
  }

  // MARK: - Pairing checks

  private func checkPairing(
    payload: PairingPayload, state: PhonePairingState, sealKey: Curve25519.KeyAgreement.PrivateKey,
    hosts: Hosts, inboxCommand: String
  ) throws {
    check(
      "pairing code decodes (mlpair1.) with this Mac's seal key and the installed key id",
      payload.phoneKeyID == state.keyID
        && payload.macSealPublicKey == sealKey.publicKey.rawRepresentation
        && payload.phoneKeyID.hasPrefix("iphone-"))
    check(
      "the Spark's host key is pinned from known_hosts as ed25519 (never RSA)",
      payload.spark.hostKey.type == "ssh-ed25519", payload.spark.hostKey.type)
    check(
      "the relay is in the code exactly when the Mac's ssh uses a ProxyJump",
      (payload.relay != nil) == (hosts.relay != nil))
    if let relay = payload.relay {
      check(
        "the relay's host key is pinned as ed25519 or ECDSA",
        ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"]
          .contains(relay.hostKey.type), relay.hostKey.type)
    }
    check("the gate word is zhiji-inbox", payload.gate == "zhiji-inbox", payload.gate)
    check(
      "the Mac remembers the inbox command it installed with", state.inboxCommand == inboxCommand)
    evidence["pairing"] = [
      "key_id_prefix": String(payload.phoneKeyID.prefix(7)),
      "spark_host_key_type": payload.spark.hostKey.type,
      "relay_host_key_type": payload.relay?.hostKey.type ?? "none",
      "label": payload.label,
    ]
  }

  private func checkInstalledLines(
    spark: KeyFile, relay: KeyFile?, baseSpark: KeyFile, baseRelay: KeyFile?,
    payload: PairingPayload, inboxCommand: String
  ) {
    let publicKey = String(payload.phoneAuthorizedKey.split(separator: " ")[1])
    let sparkLine = spark.lines.first.map(Self.splitAuthorizedLine)
    check(
      "Spark: exactly one line for this phone",
      spark.lines.count == 1 && spark.phoneLines == 1, "\(spark.lines.count)")
    check(
      "Spark: the line forces zhiji-inbox gate and restricts everything else",
      sparkLine?.options == "command=\"\(inboxCommand) gate\",restrict",
      sparkLine?.options ?? "none")
    check(
      "Spark: the line holds the phone's ed25519 public key and its marker",
      sparkLine?.type == "ssh-ed25519" && sparkLine?.key == publicKey
        && sparkLine?.comment == "mindloom-phone:\(payload.phoneKeyID)")
    check(
      "Spark: every other line is unchanged", spark.rest == baseSpark.rest,
      "lines \(baseSpark.lineCount) → \(spark.lineCount)")
    guard let relay, let baseRelay else { return }
    let relayLine = relay.lines.first.map(Self.splitAuthorizedLine)
    let expectedOptions =
      "restrict,port-forwarding,permitopen=\"\(payload.spark.host):\(payload.spark.port)\","
      + "permitlisten=\"127.0.0.1:1\",command=\"false\""
    check(
      "relay: exactly one line for this phone", relay.lines.count == 1 && relay.phoneLines == 1,
      "\(relay.lines.count)")
    check(
      "relay: the line allows only a forward to the Spark's ssh port (no shell, no -R)",
      relayLine?.options == expectedOptions,
      relayLine?.options == expectedOptions ? "exact" : (relayLine == nil ? "none" : "differs"))
    check(
      "relay: the line holds the phone's ed25519 public key and its marker",
      relayLine?.type == "ssh-ed25519" && relayLine?.key == publicKey
        && relayLine?.comment == "mindloom-phone:\(payload.phoneKeyID)")
    check(
      "relay: every other line is unchanged", relay.rest == baseRelay.rest,
      "lines \(baseRelay.lineCount) → \(relay.lineCount)")
  }

  struct AuthorizedLine {
    let options: String
    let type: String
    let key: String
    let comment: String
  }

  /// Options may hold quoted spaces (`command="… gate"`): the last three
  /// words are the type, the key and the comment.
  static func splitAuthorizedLine(_ line: String) -> AuthorizedLine {
    let words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard words.count >= 4 else {
      return AuthorizedLine(options: "", type: "", key: "", comment: "")
    }
    return AuthorizedLine(
      options: words.dropLast(3).joined(separator: " "), type: words[words.count - 3],
      key: words[words.count - 2], comment: words[words.count - 1])
  }

  // MARK: - The sealed inbox

  /// One entry the phone sent, as this test learned it by opening the blob.
  struct Expected {
    let label: String
    let inboxID: String
    let payload: InboxItemPayload
    let createdAt: Date
    let receivedAt: String
    var sessionID: SessionID {
      RemoteOrganizerInboxEntry(
        inboxID: inboxID, source: "", kind: .sealed, text: nil, imageData: nil,
        receivedAt: Date()
      ).sessionID
    }
  }

  private func checkSealedInbox(
    pending: [InboxRow], sealKey: Curve25519.KeyAgreement.PrivateKey, markers: [String: String],
    pairedAt: Date
  ) throws -> [Expected] {
    evidence["inbox_pending_rows"] = pending.count
    evidence["inbox_blob_chars"] = pending.map(\.blobChars)
    check(
      "the Spark inbox holds exactly the \(Self.expectedEntries) entries the phone sent",
      pending.count == Self.expectedEntries, "\(pending.count)")
    check(
      "every waiting entry is kind sealed, source sealed, with no text or image column",
      pending.allSatisfy {
        $0.kind == "sealed" && $0.source == "sealed" && $0.textNull && $0.imageNull
      }, "\(pending.map { "\($0.kind)/\($0.source)" })")
    check(
      "every waiting blob is an mlseal1. wire string",
      pending.allSatisfy {
        $0.blobPrefix == "mlseal1." && ($0.blob?.hasPrefix("mlseal1.") ?? false)
      })
    check(
      "every inbox id is the phone's lowercase UUID, stored as sent",
      pending.allSatisfy { EntryID.isValid($0.inboxID) && $0.inboxID == $0.inboxID.lowercased() })

    var expected: [Expected] = []
    var unopened = 0
    for row in pending {
      guard let blob = row.blob,
        let plaintext = try? MindloomSeal.open(blob, entryID: row.inboxID, with: sealKey),
        let payload = try? InboxItemPayload.decode(plaintext), let created = payload.createdDate
      else {
        unopened += 1
        continue
      }
      let text = payload.text ?? ""
      let label: String
      switch (payload.kind, payload.source) {
      case (.text, .keyboard) where text.contains(markers["keyboard"]!): label = "keyboard"
      case (.text, .share) where text.contains(markers["share_text"]!): label = "share_text"
      case (.image, .share): label = "image"
      default: label = "unexpected:\(payload.kind.rawValue)/\(payload.source.rawValue)"
      }
      expected.append(
        Expected(
          label: label, inboxID: row.inboxID, payload: payload, createdAt: created,
          receivedAt: row.receivedAt))
    }
    check("every blob opens with this Mac's seal key (test side)", unopened == 0, "\(unopened)")
    check(
      "the phone sent one keyboard dictation, one shared text and one shared image",
      expected.map(\.label).sorted() == ["image", "keyboard", "share_text"],
      "\(expected.map(\.label).sorted())")
    // A sealed blob is not its plaintext: no marker survives in the wire.
    let wires = pending.compactMap(\.blob).joined()
    check(
      "no marker is readable in the sealed blobs",
      markers.values.allSatisfy { !wires.contains($0) } && !wires.contains(Self.phoneNumber))
    // Wrong key and wrong id do not open (the seal binds the entry id).
    if let first = pending.first, let blob = first.blob {
      let other = Curve25519.KeyAgreement.PrivateKey()
      let wrongKey = (try? MindloomSeal.open(blob, entryID: first.inboxID, with: other)) == nil
      let wrongID = (try? MindloomSeal.open(blob, entryID: EntryID.make(), with: sealKey)) == nil
      check(
        "a waiting blob does not open with another key or under another id", wrongKey && wrongID)
    }
    // Times: made on the phone after pairing, before the Spark received them.
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoPlain = ISO8601DateFormatter()
    var deltas: [String: Double] = [:]
    var ordered = true
    for entry in expected {
      let received = iso.date(from: entry.receivedAt) ?? isoPlain.date(from: entry.receivedAt)
      if let received {
        let delta = received.timeIntervalSince(entry.createdAt)
        deltas[entry.label] = (delta * 1000).rounded() / 1000
        // The Spark's clock may be a little off the Mac's.
        if delta < -5 { ordered = false }
      } else {
        ordered = false
      }
      if entry.createdAt < pairedAt.addingTimeInterval(-5) { ordered = false }
    }
    evidence["received_minus_created_seconds"] = deltas
    check(
      "each entry was made on the phone after pairing and before the Spark received it",
      ordered && deltas.count == expected.count, "\(deltas)")
    // The shared image left the phone without its metadata.
    if let image = expected.first(where: { $0.label == "image" }), let bytes = image.payload.bytes {
      let properties =
        CGImageSourceCreateWithData(bytes as CFData, nil).flatMap {
          CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        } ?? [:]
      let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
      let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
      let noMeta =
        properties[kCGImagePropertyGPSDictionary] == nil
        && tiff[kCGImagePropertyTIFFImageDescription] == nil
        && exif[kCGImagePropertyExifUserComment] == nil
        && !String(decoding: bytes, as: UTF8.self).contains(markers["image_meta"]!)
      check(
        "the shared image was re-encoded on the phone: no GPS, no description, no metadata marker",
        noMeta, "mime \(image.payload.mime ?? "-"), \(bytes.count) bytes")
      evidence["image_payload"] = ["mime": image.payload.mime ?? "-", "bytes": bytes.count]
    }
    return expected
  }

  // MARK: - The items on the Mac

  private func checkItems(
    databaseURL: URL, assetRoot: URL, expected: [Expected], markers: [String: String]
  ) throws {
    let queue = try SparkEndToEndTests.readOnlyQueue(databaseURL)
    defer { try? queue.close() }
    var summary: [[String: Any]] = []
    for entry in expected {
      let id = entry.sessionID.rawValue.uuidString
      let row = try queue.read { db in
        try Row.fetchOne(
          db,
          sql: """
            SELECT s.input_mode, s.created_at, m.source_display_name, m.source_bundle_id
            FROM sessions s JOIN session_metadata m ON m.session_id = s.id WHERE s.id = ?
            """, arguments: [id])
      }
      guard let row else {
        check("\(entry.label): a user item exists", false)
        continue
      }
      let createdAt: Double = row["created_at"]
      let source: String? = row["source_display_name"]
      let mode: String = row["input_mode"]
      check(
        "\(entry.label): a user item whose source is \(entry.payload.source.rawValue)",
        mode == "userItem" && source == entry.payload.source.rawValue,
        "\(mode) / \(source ?? "nil")")
      check(
        "\(entry.label): its time is the phone's created_at (to the millisecond)",
        abs(createdAt - entry.createdAt.timeIntervalSince1970) < 0.002,
        "Δ \(createdAt - entry.createdAt.timeIntervalSince1970) s")
      let text = try queue.read { db in
        try String.fetchOne(
          db,
          sql: "SELECT content FROM transcript_revisions WHERE session_id = ? AND kind = 'final'",
          arguments: [id])
      }
      switch entry.label {
      case "keyboard", "share_text":
        check(
          "\(entry.label): the item's text is what the phone sealed (marker included)",
          text == entry.payload.text && (text ?? "").contains(markers[entry.label]!))
      case "image":
        let assets = try queue.read { db in
          try Row.fetchAll(
            db,
            sql:
              "SELECT kind, media_type, asset_reference, size_bytes FROM session_source_assets WHERE session_id = ?",
            arguments: [id])
        }
        var clean = !assets.isEmpty
        var bytesTotal = 0
        for asset in assets {
          let reference: String = asset["asset_reference"]
          guard let data = try? Data(contentsOf: assetRoot.appendingPathComponent(reference)) else {
            clean = false
            continue
          }
          bytesTotal += data.count
          let properties =
            CGImageSourceCreateWithData(data as CFData, nil).flatMap {
              CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
            } ?? [:]
          if properties[kCGImagePropertyGPSDictionary] != nil
            || String(decoding: data, as: UTF8.self).contains(markers["image_meta"]!)
          {
            clean = false
          }
        }
        check(
          "image: stored on the Mac through the image path, without location or metadata marker",
          clean, "\(assets.count) assets, \(bytesTotal) bytes")
        let reading = try queue.read { db in
          try String.fetchOne(
            db,
            sql:
              "SELECT output_text FROM derived_text_revisions WHERE session_id = ? AND state = 'current'",
            arguments: [id])
        }
        check(
          "image: the Mac's own on-device reading sees the pixels (marker readable)",
          (reading ?? "").replacingOccurrences(of: " ", with: "").contains(
            markers["image_pixels"]!), "\((reading ?? "").count) chars read")
      default:
        check("\(entry.label): expected kind", false)
      }
      summary.append([
        "label": entry.label, "source": source ?? "-", "kind": entry.payload.kind.rawValue,
        "created_at": entry.payload.createdAt,
      ])
    }
    evidence["items"] = summary
  }

  static func existingSessions(_ databaseURL: URL, ids: [SessionID]) throws -> Set<String> {
    let queue = try SparkEndToEndTests.readOnlyQueue(databaseURL)
    defer { try? queue.close() }
    return try queue.read { db in
      Set(
        try String.fetchAll(
          db,
          sql:
            "SELECT id FROM sessions WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
          arguments: StatementArguments(ids.map(\.rawValue.uuidString))))
    }
  }

  // MARK: - The wire

  private func checkWire(
    log: PrivacyEndToEndTests.ExchangeLog, keys: OrganizerKeyMaterial, expected: [Expected],
    markers: [String: String]
  ) throws {
    let masker = PrivacyMasker(keys: keys)
    let placeholder = masker.placeholder(type: "phone", value: Self.phoneNumber)
    var bodies: [String: [String: Any]] = [:]
    var sealedOnWire = 0
    var numberOnWire = 0
    for exchange in log.all {
      guard let body = exchange.body, !body.isEmpty, exchange.path != "/v1/unlock" else { continue }
      if String(decoding: body, as: UTF8.self).contains(MindloomSeal.wirePrefix) {
        sealedOnWire += 1
      }
      guard let object = try? JSONSerialization.jsonObject(with: body) else { continue }
      let text = PrivacyEndToEndTests.strings(object, skipping: PrivacyEndToEndTests.binaryFields)
        .joined(separator: "\n")
      if text.contains(Self.phoneNumber) { numberOnWire += 1 }
      if exchange.path == "/v1/items", let items = (object as? [String: Any])?["items"] as? [Any] {
        for case let item as [String: Any] in items {
          if let id = item["item_id"] as? String { bodies[id.uppercased()] = item }
        }
      }
    }
    check("no request carries an mlseal1. blob (opened on the Mac only)", sealedOnWire == 0)
    check("the phone number never crosses the link in a text field", numberOnWire == 0)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for entry in expected {
      guard let body = bodies[entry.sessionID.rawValue.uuidString] else {
        check("\(entry.label): posted to the Spark for organizing", false)
        continue
      }
      let source = (body["source_app"] as? [String: Any])?["name"] as? String
      let startedAt = (body["started_at"] as? String).flatMap(formatter.date(from:))
      check(
        "\(entry.label): sent for organizing as \(entry.payload.source.rawValue) at its phone time",
        source == entry.payload.source.rawValue
          && abs((startedAt?.timeIntervalSince1970 ?? 0) - entry.createdAt.timeIntervalSince1970)
            < 0.002,
        "\(source ?? "nil")")
      let fields = PrivacyEndToEndTests.strings(body, skipping: PrivacyEndToEndTests.binaryFields)
        .joined(separator: "\n")
      switch entry.label {
      case "keyboard", "share_text":
        check(
          "\(entry.label): masked on the wire (placeholder, marker kept)",
          fields.contains(placeholder) && fields.contains(markers[entry.label]!)
            && !fields.contains(Self.phoneNumber))
      case "image":
        guard let base64 = body["image_b64"] as? String, let image = Data(base64Encoded: base64)
        else {
          check("image: sent as an image", false)
          continue
        }
        let read = VisionImageTextReader().readText(imageData: image) ?? ""
        let compact = read.replacingOccurrences(of: " ", with: "")
        let longDigits = compact.split(whereSeparator: { !($0.isASCII && $0.isNumber) })
          .filter { $0.count >= 7 }.count
        check(
          "image: the send copy has the number painted over, the rest survives",
          !compact.contains(Self.phoneNumber) && longDigits == 0
            && compact.contains(markers["image_pixels"]!),
          "\(read.count) chars read, digit runs ≥7: \(longDigits)")
        evidence["image_send_copy_bytes"] = image.count
      default:
        break
      }
    }
    evidence["wire_items_posted"] = bodies.count
  }

  // MARK: - Remote helpers

  struct Hosts {
    let spark: String
    let relay: String?
  }

  /// The Spark alias and its ProxyJump relay, as the Mac's ssh resolves them.
  static func hosts(sparkAlias: String) async throws -> Hosts {
    let result = try await ProcessPhoneLinkCommandRunner().run(
      PhoneLinkSSHCommand.sshPath,
      PhoneLinkSSHCommand.resolveArguments(try SSHDestination(host: sparkAlias)), stdin: nil,
      timeout: 15)
    let resolved = try SSHResolvedHost.parse(sshG: result.output)
    guard let jump = resolved.proxyJump else { return Hosts(spark: sparkAlias, relay: nil) }
    let spec = try SSHJumpSpec.parse(jump)
    guard spec.port == nil else { throw EndToEndError("a relay with a port is not supported here") }
    return Hosts(spark: sparkAlias, relay: spec.user.map { "\($0)@\(spec.host)" } ?? spec.host)
  }

  struct KeyFile {
    let sha: String
    let lineCount: Int
    let phoneLines: Int
    /// The lines for the asked key id (they hold only public keys).
    let lines: [String]
    /// SHA-256 of every other line.
    let rest: String
  }

  /// `~/.ssh/authorized_keys` on a host: its hash, how many phone lines it
  /// has, the line(s) for one key id and a hash of everything else.
  static func keyFile(_ host: String, keyID: String?) async throws -> KeyFile {
    let id = keyID ?? "none"
    guard PairingPayload.isValidKeyID(id) else { throw EndToEndError("bad key id") }
    let script = """
      f="$HOME/.ssh/authorized_keys"
      echo "sha $(sha256sum < "$f" | cut -d' ' -f1)"
      echo "count $(wc -l < "$f" | tr -d ' ')"
      echo "phones $(grep -c 'mindloom-phone:' "$f" || true)"
      awk -v c="mindloom-phone:\(id)" '$NF == c { print "line " $0 }' "$f"
      echo "rest $(awk -v c="mindloom-phone:\(id)" '$NF != c' "$f" | sha256sum | cut -d' ' -f1)"
      """
    let (status, output, errors) = try await Task.detached {
      try PrivacyEndToEndTests.runSSH(host: host, command: "sh -s", input: Data(script.utf8))
    }.value
    guard status == 0 else {
      throw EndToEndError(
        "authorized_keys check on \(host) failed (\(status)): "
          + String(decoding: errors.suffix(300), as: UTF8.self))
    }
    var sha = ""
    var rest = ""
    var count = -1
    var phones = -1
    var lines: [String] = []
    for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
      if line.hasPrefix("sha ") { sha = String(line.dropFirst(4)) }
      if line.hasPrefix("rest ") { rest = String(line.dropFirst(5)) }
      if line.hasPrefix("count ") { count = Int(line.dropFirst(6)) ?? -1 }
      if line.hasPrefix("phones ") { phones = Int(line.dropFirst(7)) ?? -1 }
      if line.hasPrefix("line ") { lines.append(String(line.dropFirst(5))) }
    }
    guard sha.count == 64, rest.count == 64, phones >= 0 else {
      throw EndToEndError("authorized_keys check on \(host): unreadable answer")
    }
    return KeyFile(sha: sha, lineCount: count, phoneLines: phones, lines: lines, rest: rest)
  }

  static func listPhones(_ host: String, command: String) async throws -> [[String: Any]] {
    let (status, output, _) = try await Task.detached {
      try PrivacyEndToEndTests.runSSH(host: host, command: "\(command) list-phones", input: Data())
    }.value
    guard status == 0,
      let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
      let phones = object["phones"] as? [[String: Any]]
    else { throw EndToEndError("list-phones failed (\(status))") }
    return phones
  }

  /// Puts text on the simulator's pasteboard (`xcrun simctl pbcopy`). The
  /// pairing code goes only through this pipe.
  nonisolated static func simulatorPasteboard(_ udid: String, text: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "pbcopy", udid]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    input.fileHandleForWriting.write(Data(text.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw EndToEndError("simctl pbcopy failed") }
  }

  /// Regular files under `directory` that contain any of `needles`.
  static func filesContaining(_ needles: [Data], under directory: URL) -> [String] {
    var hits: [String] = []
    let enumerator = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = enumerator?.nextObject() as? URL {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
        let data = try? Data(contentsOf: url)
      else { continue }
      if needles.contains(where: { !$0.isEmpty && data.range(of: $0) != nil }) {
        hits.append(url.lastPathComponent)
      }
    }
    return hits
  }

  struct RefusedAttempt {
    let entryID: String
    let error: String
    let attempts: Int
  }

  /// Watches the simulator app's outbox (App Group, `outbox/queued`) for an
  /// entry made after `date` whose delivery was tried and failed. Only the
  /// entry's state fields are read.
  static func waitForRefusedAttempt(simulator: String, after date: Date, timeout: TimeInterval)
    async throws -> RefusedAttempt?
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
      "simctl", "get_app_container", simulator, "com.bestasr.phone", "group.com.bestasr.phone",
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, path.hasPrefix("/") else {
      throw EndToEndError("the simulator app's App Group container was not found")
    }
    let queued = URL(fileURLWithPath: path).appendingPathComponent("outbox/queued")
    let since = Int64(date.timeIntervalSince1970 * 1000)
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let files =
        (try? FileManager.default.contentsOfDirectory(
          at: queued, includingPropertiesForKeys: nil)) ?? []
      for file in files where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file),
          let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let created = (entry["created_at_ms"] as? NSNumber)?.int64Value, created > since,
          let attempts = entry["attempts"] as? Int, attempts > 0,
          let error = entry["last_error"] as? String, let id = entry["entry_id"] as? String
        else { continue }
        return RefusedAttempt(entryID: id, error: error, attempts: attempts)
      }
      try await Task.sleep(for: .seconds(2))
    } while Date() < deadline
    return nil
  }

  static func needles(markers: [String: String]) -> [(label: String, bytes: Data)] {
    markers.sorted { $0.key < $1.key }.map {
      (label: "marker_\($0.key)", bytes: Data($0.value.utf8))
    }
      + [(label: "phone_number", bytes: Data(phoneNumber.utf8))]
  }

  struct InboxRow {
    let inboxID: String
    let source: String
    let kind: String
    let textNull: Bool
    let imageNull: Bool
    let blobNull: Bool
    let blobChars: Int
    let blobPrefix: String?
    let receivedAt: String
    let acked: Bool
    let blob: String?
  }

  /// Every row of the Spark's `inbox.db`, read-only; with `withBlobs`, the
  /// waiting blobs too (sealed: only this Mac can open them).
  static func inboxRows(_ remote: Remote, withBlobs: Bool) async throws -> [InboxRow] {
    let request: [String: Any] = ["data_dir": remote.dataDirectory, "with_blobs": withBlobs]
    let json = try JSONSerialization.data(withJSONObject: request)
    let script = inboxScript.replacingOccurrences(
      of: "__REQUEST__", with: json.base64EncodedString())
    let host = remote.host
    let python = remote.python
    let (status, output, errors) = try await Task.detached {
      try PrivacyEndToEndTests.runSSH(host: host, command: "\(python) -", input: Data(script.utf8))
    }.value
    guard status == 0,
      let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
      let rows = object["rows"] as? [[String: Any]]
    else {
      throw EndToEndError(
        "inbox probe failed (\(status)): " + String(decoding: errors.suffix(500), as: UTF8.self))
    }
    return rows.map {
      InboxRow(
        inboxID: $0["inbox_id"] as? String ?? "", source: $0["source"] as? String ?? "",
        kind: $0["kind"] as? String ?? "", textNull: $0["text_null"] as? Bool ?? false,
        imageNull: $0["image_null"] as? Bool ?? false, blobNull: $0["blob_null"] as? Bool ?? false,
        blobChars: $0["blob_chars"] as? Int ?? 0, blobPrefix: $0["blob_prefix"] as? String,
        receivedAt: $0["received_at"] as? String ?? "", acked: $0["acked"] as? Bool ?? false,
        blob: $0["blob"] as? String)
    }
  }

  static let inboxScript = #"""
    import base64, json, os, sqlite3

    REQ = json.loads(base64.b64decode("__REQUEST__").decode("utf-8"))
    path = os.path.join(os.path.abspath(os.path.expanduser(REQ["data_dir"])), "inbox.db")
    conn = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=10)
    rows = []
    try:
        for r in conn.execute(
                "SELECT inbox_id, source, kind, text, image, blob, received_at, acked FROM inbox ORDER BY seq"):
            inbox_id, source, kind, text, image, blob, received_at, acked = r
            row = {"inbox_id": inbox_id, "source": source, "kind": kind,
                   "text_null": text is None, "image_null": image is None, "blob_null": blob is None,
                   "blob_chars": len(blob) if blob is not None else 0,
                   "blob_prefix": blob[:8] if isinstance(blob, str) else None,
                   "received_at": received_at, "acked": bool(acked)}
            if REQ.get("with_blobs") and isinstance(blob, str) and not acked:
                row["blob"] = blob
            rows.append(row)
    finally:
        conn.close()
    print(json.dumps({"rows": rows}))
    """#
}
