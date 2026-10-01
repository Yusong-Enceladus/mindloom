import AppKit
import BestASRDomain
import BestASRIntake
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import GRDB
import MindloomLink
import MindloomSpaces
import XCTest

/// Opt-in end-to-end run of shared spaces (SPACES-CONTRACT §5 "E2E") with two
/// synthetic data roots — two Macs, each with its own library, device keys in
/// 0600 files of its synthetic root, and the production SSH forward and link
/// token reader — against one real Spark instance and its real model.
///
/// The matter is the lab demo's Twin-7 叠衣服真机实验 (scale-lab E04, all
/// synthetic): 林知远 (A) and 韩策 (B, the Twin-7 负责人) each have their own
/// version of it on their own Mac (`LabTwin7` says who holds what and why),
/// share it into one org space, and the space organizer assembles one matter
/// from both.
///
/// Skipped unless `BESTASR_E2E_SPACES_HOST`, `_SOCKET_PATH`, `_TOKEN_PATH`
/// and `_SCENARIO_DIR` (the scale-lab scenario directory) are set;
/// `BESTASR_E2E_SPACES_DATA_DIR` (the instance's data directory on the Spark,
/// relative to the SSH home or absolute; its sibling `logs` is scanned too
/// unless `BESTASR_E2E_SPACES_LOG_DIR` names another) adds the plaintext
/// scan, and `BESTASR_E2E_SPACES_EVIDENCE` a JSON summary (check names and
/// counts only).
@MainActor
final class SpacesEndToEndTests: XCTestCase {
  struct Live {
    let link: RemoteOrganizerLinkConfiguration
    let host: String
    let scenario: URL
    let dataDir: String?
    let logDir: String?
    let evidence: URL?
  }

  private func live() throws -> Live {
    let env = ProcessInfo.processInfo.environment
    guard let host = env["BESTASR_E2E_SPACES_HOST"],
      let socket = env["BESTASR_E2E_SPACES_SOCKET_PATH"],
      let token = env["BESTASR_E2E_SPACES_TOKEN_PATH"],
      let scenario = env["BESTASR_E2E_SPACES_SCENARIO_DIR"]
    else {
      throw XCTSkip(
        "Set BESTASR_E2E_SPACES_HOST, _SOCKET_PATH, _TOKEN_PATH and _SCENARIO_DIR to run.")
    }
    let dataDir = env["BESTASR_E2E_SPACES_DATA_DIR"]
    let logDir =
      env["BESTASR_E2E_SPACES_LOG_DIR"]
      ?? dataDir.map { ($0 as NSString).deletingLastPathComponent + "/logs" }
    return Live(
      link: try RemoteOrganizerLinkConfiguration(
        host: host, remoteSocketPath: socket, remoteTokenPath: token),
      host: host, scenario: URL(fileURLWithPath: scenario, isDirectory: true), dataDir: dataDir,
      logDir: logDir,
      evidence: env["BESTASR_E2E_SPACES_EVIDENCE"].map { URL(fileURLWithPath: $0) })
  }

  /// Which of the lab's Twin-7 items each member holds on their own Mac
  /// (refs into scale-lab `scenario.json`; every one is filed under E04 only).
  enum LabTwin7 {
    /// 林知远 (A): his own phone notes, the chats he pasted (with 孟凡,
    /// 许嘉禾, the B203 group), the Codex answer he asked for and his
    /// WeChat screenshot.
    static let aPasted = [
      "0817-08", "0819-11", "0824-31", "0827-11", "0831-19", "0901-38", "0911-32", "0914-18",
      "0916-53",
    ]
    /// His Fn dictations on the Mac (real dictation sessions: private
    /// until he ticks them in the review list).
    static let aDictated = ["0826-01", "0907-33"]
    /// The 9/2 group meeting's Twin-7 segment, recorded on his Mac.
    static let aRecorded = "0902-32"
    /// Pasted after B was removed (shared at the new epoch).
    static let aLater = "0915-21"
    /// 韩策 (B, Twin-7 负责人): the progress sheets he keeps, the chats he
    /// is in, and the Table 2 screenshot.
    static let bPasted = [
      "0821-40", "0823-05", "0826-27", "0830-15", "0831-12", "0906-13", "0910-09", "0910-49",
      "0915-24",
    ]
    /// The 9/9 group meeting recorded on his Mac: it also covers the TG-2
    /// gripper (E05) and the baselines (E06); only its Twin-7 parts are
    /// filed into his matter, so only they may leave.
    static let bRecorded = "0909-20"
    static let bFiledParts = [(9, 103), (455, 505)]
    /// B's own note (made up for this run, as the lab's supplier would be
    /// reached): it carries a phone number, so it starts unticked.
    static func bNote(phone: String) -> String {
      "Twin-7 左臂腕关节电机备件：锐拓智控钱卫国 \(phone)，说周五前到货，到了让孟工换上。"
    }
  }

  /// One spoken line of a recording: who, when (seconds from its start), what.
  struct Line: Sendable {
    let name: String
    let start: Int
    var end: Int
    let text: String
  }

  /// A 腾讯会议 export (`名字 Pinyin(HH:MM:SS):` then the words) as lines.
  static func lines(transcript: String) -> [Line] {
    var out: [Line] = []
    var current: (name: String, start: Int, words: [String])?
    func flush() {
      guard let line = current else { return }
      let text = line.words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
      if !text.isEmpty { out.append(Line(name: line.name, start: line.start, end: 0, text: text)) }
      current = nil
    }
    for raw in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
      let row = raw.trimmingCharacters(in: .whitespaces)
      if row.hasSuffix("):"), let open = row.lastIndex(of: "(") {
        let stamp = row[row.index(after: open)..<row.index(row.endIndex, offsetBy: -2)]
        let parts = stamp.split(separator: ":").compactMap { Int($0) }
        if parts.count == 3 {
          flush()
          let name = String(row[..<open]).split(separator: " ").first.map(String.init) ?? "发言人"
          current = (name, parts[0] * 3_600 + parts[1] * 60 + parts[2], [])
          continue
        }
      }
      if !row.isEmpty { current?.words.append(row) }
    }
    flush()
    for index in out.indices {
      out[index].end = index + 1 < out.count ? out[index + 1].start : out[index].start + 15
    }
    return out
  }

  /// Every request a Mac sends, kept for the payload scan.
  final class RecordingSpaceTransport: SpaceTransport, @unchecked Sendable {
    struct Sent: Sendable {
      let method: String
      let target: String
      let body: Data
    }

    private let inner: any SpaceTransport
    private let lock = NSLock()
    private var log: [Sent] = []

    init(_ inner: any SpaceTransport) { self.inner = inner }

    func send(_ request: SpaceHTTPRequest) async throws -> SpaceHTTPResponse {
      lock.withLock {
        log.append(
          Sent(method: request.method, target: request.target, body: request.body ?? Data()))
      }
      return try await inner.send(request)
    }

    var sent: [Sent] { lock.withLock { log } }
  }

  /// One simulated Mac: a synthetic root with a library, file-kept secrets
  /// (allowed only because the root is synthetic), and its own forward.
  struct Mac {
    let root: URL
    let assetRoot: URL
    let library: GRDBDictationStore
    let stores: SpaceStores
    let engine: SpaceEngine
    let link: SpaceLink
    let wire: RecordingSpaceTransport
  }

  /// The production forward: the port is used only while our own ssh child
  /// holds it; the token stays in memory.
  @MainActor
  final class SpaceLink {
    private let launcher: SSHRemoteOrganizerTunnelLauncher
    private var tunnel: (any RemoteOrganizerTunnelProcess)?
    private var token: String?

    init(_ link: RemoteOrganizerLinkConfiguration, state: URL) {
      launcher = SSHRemoteOrganizerTunnelLauncher(configuration: link, stateDirectory: state)
    }

    func endpoint() async throws -> (port: Int, token: String) {
      if let tunnel, tunnel.isRunning,
        launcher.listenerIsOwned(by: tunnel.processIdentifier, port: tunnel.localPort),
        let token
      {
        return (tunnel.localPort, token)
      }
      close()
      let port = try launcher.freeLoopbackPort()
      let process = try await launcher.launchForward(localPort: port)
      tunnel = process
      let deadline = Date().addingTimeInterval(30)
      while !launcher.listenerIsOwned(by: process.processIdentifier, port: port) {
        guard process.isRunning, Date() < deadline else { throw SpaceClientError.transport }
        try await Task.sleep(for: .milliseconds(200))
      }
      let fetched = try await launcher.fetchLinkToken()
      guard RemoteOrganizerSSHCommand.isValidLinkToken(fetched) else {
        throw SpaceClientError.transport
      }
      token = fetched
      return (port, fetched)
    }

    func close() {
      tunnel?.terminateAndWait()
      tunnel = nil
      token = nil
    }
  }

  private var macs: [Mac] = []
  private var real: URL?
  private static let zone = TimeZone(identifier: "Asia/Shanghai")!

  override func tearDown() async throws {
    for mac in macs {
      mac.link.close()
      try? await mac.library.checkpointAndClose()
      try? FileManager.default.removeItem(at: mac.root)
    }
    macs = []
    if let real { try? FileManager.default.removeItem(at: real) }
  }

  private func mac(_ name: String, live: Live, real: URL) throws -> Mac {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-spaces-e2e-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: root.appendingPathComponent(RemoteOrganizerDataProvenance.syntheticMarkerFileName)
        .path, contents: Data())
    let library = try GRDBDictationStore(
      databaseURL: root.appendingPathComponent("library.sqlite"), remoteItemTimeZone: Self.zone)
    let stores = try SpaceStores.synthetic(dataRoot: root, realLibraryRoot: real)
    let device = try stores.loadOrCreateDevice()
    let link = SpaceLink(live.link, state: root.appendingPathComponent("link-state"))
    let wire = RecordingSpaceTransport(LoopbackSpaceTransport { try await link.endpoint() })
    let engine = SpaceEngine(
      client: SpaceClient(transport: wire, device: device), states: stores.states,
      keys: stores.keys)
    let mac = Mac(
      root: root, assetRoot: root.appendingPathComponent("assets", isDirectory: true),
      library: library, stores: stores, engine: engine, link: link, wire: wire)
    macs.append(mac)
    return mac
  }

  // MARK: - Seeding the two libraries

  /// Pastes (or, for a screenshot, pastes the image of) a scenario item
  /// through the real intake, as the user would.
  private func paste(
    _ mac: Mac, _ item: ScenarioDirectory.Item, scenario: ScenarioDirectory, real: URL
  ) async throws -> SessionID {
    let inbox = mac.root.appendingPathComponent("inbox", isDirectory: true)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let pasted = NSPasteboard(name: NSPasteboard.Name("bestASR.e2e.\(UUID().uuidString)"))
    defer { pasted.releaseGlobally() }
    switch try scenario.intake(item, inbox: inbox) {
    case .paste(let text):
      pasted.clearContents()
      pasted.setString(text, forType: .string)
    case .pasteImage(let data):
      pasted.clearContents()
      let entry = NSPasteboardItem()
      entry.setData(data, forType: .png)
      pasted.writeObjects([entry])
    case .drop(let url):
      throw SparkEndToEndTests.EndToEndError(
        "\(item.ref) would be dropped (\(url.lastPathComponent))")
    }
    return try await takeIn(
      mac, SparkEndToEndTests.readSingle(pasted), at: item.at,
      source: ScenarioDirectory.source(item.sourceApp), real: real)
  }

  private func pasteText(_ mac: Mac, _ text: String, at: Date, app: String, real: URL)
    async throws -> SessionID
  {
    let pasted = NSPasteboard(name: NSPasteboard.Name("bestASR.e2e.\(UUID().uuidString)"))
    defer { pasted.releaseGlobally() }
    pasted.clearContents()
    pasted.setString(text, forType: .string)
    return try await takeIn(
      mac, SparkEndToEndTests.readSingle(pasted), at: at, source: ScenarioDirectory.source(app),
      real: real)
  }

  private func takeIn(
    _ mac: Mac, _ candidate: IntakeCandidate, at: Date, source: ItemSourceApplication?, real: URL
  ) async throws -> SessionID {
    let root = mac.root
    let policy = IntakePathPolicy { url in
      [real, root].contains { BestASRDataRootSelection.path(url, isWithinOrEqualTo: $0) }
    }
    let processor = IntakeProcessor(
      assetStore: IntakeAssetStore(assetRoot: mac.assetRoot), pathPolicy: policy,
      imageReader: nil)
    let outcome = processor.prepare(
      candidate, capturedAt: at, source: source, origin: .previousFrontmost)
    guard case .item(let draft) = outcome else {
      throw SparkEndToEndTests.EndToEndError("not taken in: \(outcome)")
    }
    do {
      try await mac.library.createUserItem(draft)
    } catch {
      processor.assetStore.discard(sessionID: draft.id)
      throw error
    }
    processor.assetStore.commit(sessionID: draft.id)
    return draft.id
  }

  private func database(_ mac: Mac) throws -> DatabaseQueue {
    try DatabaseQueue(path: mac.root.appendingPathComponent("library.sqlite").path)
  }

  /// A Fn dictation on this Mac: a real dictation session, inserted into an
  /// App whose window title must never leave.
  private func dictate(_ mac: Mac, _ text: String, at: Date, window: String) async throws
    -> SessionID
  {
    let id = SessionID(UUID())
    let sid = id.rawValue.uuidString
    let created = at.timeIntervalSince1970
    let queue = try database(mac)
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions (id, revision, input_mode, state, source_audio_retention,
            created_at, updated_at) VALUES (?, 1, 'dictation', 'completed', 'retained', ?, ?)
          """, arguments: [sid, created, created + 30])
      try db.execute(
        sql: """
          INSERT INTO dictation_snapshots (session_id, control_revision, phase, snapshot_json,
            is_ephemeral, updated_at) VALUES (?, 1, 'completed', ?, 0, ?)
          """, arguments: [sid, Data("{}".utf8), created + 30])
      try db.execute(
        sql: """
          INSERT INTO session_metadata (session_id, revision, title, title_is_user_edited,
            source_kind, source_display_name, source_bundle_id, recording_format,
            created_at, updated_at)
          VALUES (?, 1, ?, 0, 'dictation', '飞书', 'com.electron.lark',
                  'float32-pcm-journal', ?, ?)
          """, arguments: [sid, window, created, created + 30])
      try db.execute(
        sql: """
          INSERT INTO transcript_revisions (id, session_id, revision, kind, content, created_at)
          VALUES (?, ?, 1, 'final', ?, ?)
          """, arguments: [UUID().uuidString, sid, text, created + 30])
    }
    try queue.close()
    return id
  }

  /// A meeting recorded on this Mac's microphone, with people identified by
  /// their voices: names may go, the voiceprints (speaker and person
  /// embeddings) never.
  private func record(
    _ mac: Mac, _ lines: [Line], at: Date, window: String, voiceprint: String
  ) async throws -> SessionID {
    let id = SessionID(UUID())
    let sid = id.rawValue.uuidString
    let created = at.timeIntervalSince1970
    let ended = created + Double(lines.map(\.end).max() ?? 0)
    let base = lines.map(\.start).min() ?? 0
    let queue = try database(mac)
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions (id, revision, input_mode, state, source_audio_retention,
            created_at, updated_at)
          VALUES (?, 1, 'roomMicrophone', 'completed', 'retained', ?, ?)
          """, arguments: [sid, created, ended])
      try db.execute(
        sql: """
          INSERT INTO dictation_snapshots (session_id, control_revision, phase, snapshot_json,
            is_ephemeral, updated_at) VALUES (?, 1, 'completed', ?, 0, ?)
          """, arguments: [sid, Data("{}".utf8), ended])
      try db.execute(
        sql: """
          INSERT INTO session_metadata (session_id, revision, title, title_is_user_edited,
            source_kind, source_display_name, source_bundle_id, recording_format,
            created_at, updated_at)
          VALUES (?, 1, ?, 0, 'dictation', '腾讯会议', 'com.tencent.meeting',
                  'float32-pcm-journal', ?, ?)
          """, arguments: [sid, window, created, ended])
      let transcript = UUID().uuidString
      try db.execute(
        sql: """
          INSERT INTO transcript_revisions (id, session_id, revision, kind, content, created_at)
          VALUES (?, ?, 1, 'final', ?, ?)
          """,
        arguments: [transcript, sid, lines.map(\.text).joined(separator: "\n"), ended])
      var speakers: [String: (person: String, speaker: String)] = [:]
      for (index, line) in lines.enumerated() {
        let start = Int64(line.start - base) * 1_000_000_000
        let end = Int64(line.end - base) * 1_000_000_000
        try db.execute(
          sql: """
            INSERT INTO transcript_segments (transcript_id, segment_id, ordinal,
              monotonic_start_ns, monotonic_end_ns, text) VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [transcript, UUID().uuidString, index, start, end, line.text])
        let known = speakers[line.name]
        let person = known?.person ?? UUID().uuidString
        let speaker = known?.speaker ?? UUID().uuidString
        let occurrence = UUID().uuidString
        if known == nil {
          speakers[line.name] = (person, speaker)
          try db.execute(
            sql: """
              INSERT INTO persons (id, revision, display_name, aliases_json, created_at,
                updated_at) VALUES (?, 1, ?, '[]', 1000, 1000)
              """, arguments: [person, line.name])
          try db.execute(
            sql: """
              INSERT INTO session_speakers (id, session_id, revision, stable_ordinal)
              VALUES (?, ?, 1, ?)
              """, arguments: [speaker, sid, speakers.count])
          try db.execute(
            sql: """
              INSERT INTO session_speaker_embeddings (session_speaker_id, revision,
                embedding_space_id, vector_json, speech_duration_ns, signal_quality,
                model_artifact_key, created_at)
              VALUES (?, 1, 'synthetic-space', ?, 1000000000, 0.9, 'synthetic', 1000)
              """, arguments: [speaker, Data("[\"\(voiceprint)\"]".utf8)])
        }
        try db.execute(
          sql: """
            INSERT INTO speaker_occurrences (id, session_id, session_speaker_id, revision,
              monotonic_start_ns, monotonic_end_ns, overlaps_another_speaker,
              association_status, person_id, confidence, evidence_revision)
            VALUES (?, ?, ?, 1, ?, ?, 0, 'userConfirmed', ?, 1, 1)
            """, arguments: [occurrence, sid, speaker, start, end, person])
        if known == nil {
          try db.execute(
            sql: """
              INSERT INTO person_embeddings (id, person_id, revision, embedding_space_id,
                vector_json, speech_duration_ns, signal_quality, source_occurrence_id,
                created_at)
              VALUES (?, ?, 1, 'synthetic-space', ?, 1000000000, 0.9, ?, 1000)
              """,
            arguments: [
              UUID().uuidString, person, Data("[\"\(voiceprint)\"]".utf8), occurrence,
            ])
        }
      }
    }
    try queue.close()
    return id
  }

  /// The personal dictionary: a recognition hint for 吞七 → Twin-7, never shared.
  private func dictionary(_ mac: Mac, sentinel: String) async throws {
    let queue = try database(mac)
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO dictionary_entries (id, revision, canonical_form, spoken_forms_json,
            enabled, created_at, updated_at) VALUES (?, 1, ?, ?, 1, 1000, 1000)
          """,
        arguments: [UUID().uuidString, sentinel, "[\"吞七 \(sentinel)\"]"])
    }
    try queue.close()
  }

  /// The review-list entries a member's matter would send, read as the App
  /// reads them (`SpacesModel.entries(forMatter:)`): the shared content
  /// query, a screenshot's stored image as its original, a recording's
  /// filed parts.
  private func entries(
    _ mac: Mac, _ sessions: [(id: SessionID, parts: [SpaceShareContent.Part])], matter: String
  ) async throws -> [SpaceShareContent.Entry] {
    let records = try await mac.library.memoryItemRecords(ids: sessions.map(\.id))
    let byID = Dictionary(
      records.map { ($0.sessionID.rawValue.uuidString, $0) },
      uniquingKeysWith: { first, _ in first })
    var out: [SpaceShareContent.Entry] = []
    for session in sessions {
      let found = try await mac.library.spaceShareContent(sessionID: session.id)
      let content = try XCTUnwrap(found, "no shareable content for an item")
      let record = byID[session.id.rawValue.uuidString]
      var originals: [(role: String, data: Data)] = []
      if content.kind == "image", let path = record?.thumbnailAssetPath {
        originals.append(
          ("image", try Data(contentsOf: mac.assetRoot.appendingPathComponent(path))))
      }
      out += SpaceShareContent.entries(
        for: content, title: record?.titleIsUserEdited == true ? record?.title : nil,
        matterID: matter, parts: session.parts, reading: record?.localReading,
        originals: originals)
    }
    return out
  }

  /// Character ranges (Unicode scalars) of the lines filed into the matter,
  /// in the recording's text (its lines joined by newlines).
  static func parts(_ lines: [Line], filed: [(Int, Int)]) -> [SpaceShareContent.Part] {
    var offsets: [(start: Int, end: Int)] = []
    var cursor = 0
    for line in lines {
      let count = line.text.unicodeScalars.count
      offsets.append((cursor, cursor + count))
      cursor += count + 1
    }
    return filed.compactMap { from, to in
      let inside = lines.indices.filter { lines[$0].start >= from && lines[$0].start <= to }
      guard let first = inside.first, let last = inside.last else { return nil }
      return SpaceShareContent.Part(start: offsets[first].start, end: offsets[last].end)
    }
  }

  // MARK: - Scans

  /// Every text a request carries: the JSON's strings (escapes undone), and
  /// inside signed ops and join requests (base64url JSON) their strings too;
  /// a body that is not JSON (a sealed blob) as its bytes.
  static func texts(of body: Data) -> [String] {
    guard !body.isEmpty else { return [] }
    guard let json = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
    else { return [String(decoding: body, as: UTF8.self)] }
    var out: [String] = []
    func walk(_ value: Any, key: String?) {
      if let text = value as? String {
        out.append(text)
        if key == "op" || key == "request", let data = Base64URL.decode(text, allowPadding: true),
          let inner = try? JSONSerialization.jsonObject(with: data)
        {
          walk(inner, key: nil)
        }
      } else if let list = value as? [Any] {
        for element in list { walk(element, key: key) }
      } else if let object = value as? [String: Any] {
        for (name, element) in object { walk(element, key: name) }
      }
    }
    walk(json, key: nil)
    return out
  }

  /// Every text a member reads in a space: item fields, package hints, names.
  static func memberTexts(_ state: SpaceLocalState) -> [String] {
    var out = state.items.values.flatMap { $0.fields?.texts ?? [] }
    for package in state.packages.values {
      out += [package.title, package.matterID].compactMap { $0 }
      out += package.hints?["facts"]?.array?.compactMap(\.string) ?? []
    }
    out += state.members.compactMap(\.displayName) + [state.name]
    return out
  }

  private func ssh(_ host: String, _ command: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, command]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }

  /// Files under the instance's data and log directories holding each
  /// needle as plain bytes, and the space's stored blobs (all must be
  /// `MLB1` ciphertext). Needles travel base64-encoded, never in a log.
  private func sparkScan(
    _ live: Live, dataDir: String, spaceID: String, needles: [(label: String, text: String)]
  ) throws -> (hits: [String: Int], blobs: Int, sealed: Int) {
    let dirs = ([dataDir] + (live.logDir.map { [$0] } ?? [])).map { "'\($0)'" }
      .joined(separator: " ")
    var script = "set -u\n"
    for needle in needles {
      let encoded = Data(needle.text.utf8).base64EncodedString()
      script +=
        "n=\"$(printf %s \(encoded) | base64 -d)\"; "
        + "printf '%s\\t%s\\n' \(needle.label) \"$(grep -rlaF -- \"$n\" \(dirs) 2>/dev/null | wc -l)\"\n"
    }
    let blobs = "'\(dataDir)/spaces/\(spaceID)/blobs'"
    script += "printf 'blobs\\t%s\\n' \"$(ls \(blobs) 2>/dev/null | wc -l)\"\n"
    script +=
      "printf 'sealed\\t%s\\n' \"$(for f in \(blobs)/*; do [ -f \"$f\" ] && head -c 4 \"$f\" && echo; done | grep -c '^MLB1$')\"\n"
    let output = try ssh(live.host, "bash -c \(Self.quoted(script))")
    var values: [String: Int] = [:]
    for row in output.split(separator: "\n") {
      let cells = row.split(separator: "\t")
      if cells.count == 2, let value = Int(cells[1].trimmingCharacters(in: .whitespaces)) {
        values[String(cells[0])] = value
      }
    }
    var hits: [String: Int] = [:]
    for needle in needles { hits[needle.label] = values[needle.label] ?? -1 }
    return (hits, values["blobs"] ?? -1, values["sealed"] ?? -1)
  }

  static func quoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// `METHOD /v1/spaces/:id/route` for the request counts.
  static func route(_ sent: RecordingSpaceTransport.Sent) -> String {
    let path = sent.target.split(separator: "?").first.map(String.init) ?? sent.target
    let parts = path.split(separator: "/").map { part -> String in
      part.count == 36 && part.filter({ $0 == "-" }).count == 4 ? ":id" : String(part)
    }
    return "\(sent.method) /" + parts.joined(separator: "/")
  }

  // MARK: - The run

  func testTwoLabMembersShareTheirTwin7MatterOnARealSpark() async throws {
    let live = try live()
    let scenario = try ScenarioDirectory(root: live.scenario)
    let byRef = Dictionary(
      scenario.items.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
    /// A Twin-7 item of the lab; only B's recording also covers other matters.
    func item(_ ref: String, alsoOthers: Bool = false) throws -> ScenarioDirectory.Item {
      guard let found = byRef[ref],
        alsoOthers ? found.expectedEvents.contains("E04") : found.expectedEvents == ["E04"]
      else {
        throw SparkEndToEndTests.EndToEndError("\(ref) is not a Twin-7 (E04) item of scale-lab")
      }
      return found
    }
    let real = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestasr-spaces-e2e-real-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    self.real = real
    let started = Date()
    var timings: [String: Int] = [:]
    func lap(_ name: String) { timings[name] = Int(Date().timeIntervalSince(started)) }
    let marker = "E2E\(UUID().uuidString.prefix(6))"
    let voiceprint = "VOICEPRINT-\(marker)"
    let dictionarySentinel = "DICT-\(marker)"
    let window = "WINDOW-\(marker)"
    let phone = "13912345678"
    let aName = "林知远-\(marker)"
    let bName = "韩策-\(marker)"
    let spaceName = "EAI Lab 真机组-\(marker)"
    let a = try mac("a", live: live, real: real)
    let b = try mac("b", live: live, real: real)
    var checks: [(String, Bool)] = []
    var counts: [String: Int] = [:]
    func check(_ name: String, _ ok: Bool) { checks.append((name, ok)) }

    // 0. Each Mac holds its own version of the matter.
    var aSessions: [(id: SessionID, parts: [SpaceShareContent.Part])] = []
    var refs: [String: String] = [:]
    func note(_ id: SessionID, _ ref: String) { refs[id.rawValue.uuidString.lowercased()] = ref }
    for ref in LabTwin7.aPasted {
      aSessions.append((try await paste(a, try item(ref), scenario: scenario, real: real), []))
    }
    for ref in LabTwin7.aDictated {
      let source = try item(ref)
      aSessions.append(
        (try await dictate(a, source.text ?? "", at: source.at, window: window), []))
    }
    let aMeeting = try item(LabTwin7.aRecorded)
    let aLines = Self.lines(transcript: aMeeting.text ?? "")
    let aStart =
      (aMeeting.raw["meeting"] as? [String: Any])?["started_at"].flatMap { $0 as? String }
      .flatMap(ScenarioDirectory.date) ?? aMeeting.at
    aSessions.append(
      (
        try await record(
          a, aLines, at: aStart.addingTimeInterval(Double(aLines.first?.start ?? 0)),
          window: window, voiceprint: voiceprint), []
      ))
    try await dictionary(a, sentinel: dictionarySentinel)

    var bSessions: [(id: SessionID, parts: [SpaceShareContent.Part])] = []
    for ref in LabTwin7.bPasted {
      bSessions.append((try await paste(b, try item(ref), scenario: scenario, real: real), []))
    }
    let bMeeting = try item(LabTwin7.bRecorded, alsoOthers: true)
    let bLines = Self.lines(transcript: bMeeting.text ?? "")
    let bStart =
      (bMeeting.raw["meeting"] as? [String: Any])?["started_at"].flatMap { $0 as? String }
      .flatMap(ScenarioDirectory.date) ?? bMeeting.at
    let bParts = Self.parts(bLines, filed: LabTwin7.bFiledParts)
    bSessions.append(
      (
        try await record(
          b, bLines, at: bStart.addingTimeInterval(Double(bLines.first?.start ?? 0)),
          window: window, voiceprint: voiceprint), bParts
      ))
    let noteAt = try XCTUnwrap(ScenarioDirectory.date("2026-09-12T10:20:00+08:00"))
    let bNote = try await pasteText(
      b, LabTwin7.bNote(phone: phone), at: noteAt, app: "备忘录", real: real)
    bSessions.append((bNote, []))
    try await dictionary(b, sentinel: dictionarySentinel)
    let aRefs = LabTwin7.aPasted + LabTwin7.aDictated + [LabTwin7.aRecorded]
    for (session, ref) in zip(aSessions.map(\.id), aRefs) { note(session, ref) }
    let bRefs = LabTwin7.bPasted + [LabTwin7.bRecorded, "B-note"]
    for (session, ref) in zip(bSessions.map(\.id), bRefs) { note(session, ref) }
    let filed = Set(
      LabTwin7.bFiledParts.flatMap { from, to in
        bLines.filter { $0.start >= from && $0.start <= to }.map(\.text)
      })
    // Lines of B's recording about other matters: they never leave his Mac.
    let unfiledLines = bLines.map(\.text).filter { !filed.contains($0) && $0.count >= 8 }
    counts["recording_lines_b"] = bLines.count
    counts["recording_lines_b_unfiled"] = bLines.count - filed.count
    lap("seeded")

    // 1. A creates an org space and invites B; B joins; A approves.
    let hostKeys = try await a.engine.client.hostKeys()
    let hostKey = try XCTUnwrap(hostKeys.first { $0.hasPrefix("ssh-ed25519 ") })
    let endpoint = SpaceInviteCode.Endpoint(host: live.host, user: nil, hostKey: hostKey)
    let org = try await a.engine.createOrg()
    let space = try await a.engine.createSpace(
      name: spaceName, owner: .org, orgID: org.orgID, orgMemberID: org.memberID,
      displayName: aName, spark: endpoint)
    let spaceID = space.spaceID
    try await a.engine.setPolicy(spaceID, ["forks_allowed": true])
    let created = try await a.engine.sync(spaceID)
    check(
      "org space: owned by the lab, 24 h withdraw window, contributions kept",
      created.ownerKind == .org && created.policy.withdrawWindowHours == 24
        && created.policy.onLeave == "keep")
    let code = try SpaceInviteCode.decode(
      try await a.engine.invite(spaceID, role: .write, hostKey: hostKey, spark: endpoint)
        .encoded())
    check("the invite pins the Spark's host key", code.spark.hostKey == hostKey)
    _ = try await b.engine.join(code: code, displayName: bName, localHostKey: hostKey)
    let requests = try await a.engine.joinRequests(spaceID)
    let request = try XCTUnwrap(requests.first)
    let bFingerprint = await b.engine.device.fingerprint
    check(
      "B's sealed name opens on A and the fingerprints match",
      request.displayName == bName && request.fingerprint == bFingerprint)
    try await a.engine.approve(spaceID, request: request)
    let joined = try await b.engine.refreshJoin(spaceID)
    check("B joined as a contributor (贡献)", joined.membership == .active && joined.role == .write)
    lap("joined")

    // 2. Both share their version of the matter after the review list.
    let aEntries = try await entries(a, aSessions, matter: "E2")
    let bEntries = try await entries(b, bSessions, matter: "E5")
    counts["entries_a"] = aEntries.count
    counts["entries_b"] = bEntries.count
    var aReview = SpaceShareReview(candidates: aEntries.map(\.candidate))
    var bReview = SpaceShareReview(candidates: bEntries.map(\.candidate))
    let allEntries = aEntries + bEntries
    check(
      "review list: exactly the dictations, the items with numbers and the recording parts start unticked",
      allEntries.allSatisfy { entry in
        let ticked =
          aReview.ticked.contains(entry.candidate.id) || bReview.ticked.contains(entry.candidate.id)
        return ticked
          == (entry.item.kind != "dictation" && entry.candidate.numberLabels.isEmpty
            && entry.candidate.recordingID == nil)
      })
    check(
      "review list: A's two Fn dictations start unticked",
      aEntries.filter { $0.item.kind == "dictation" }.count == 2
        && aEntries.filter { $0.item.kind == "dictation" }.allSatisfy {
          !aReview.ticked.contains($0.candidate.id)
        })
    let noteEntry = try XCTUnwrap(
      bEntries.first { $0.candidate.sourceItemID == bNote.rawValue.uuidString.lowercased() })
    check(
      "review list: B's note with a phone number starts unticked (手机号)",
      !bReview.ticked.contains(noteEntry.candidate.id)
        && noteEntry.candidate.numberLabels.contains("手机号"))
    counts["entries_unticked_by_default"] =
      aEntries.count - aReview.ticked.count + bEntries.count - bReview.ticked.count
    // Each reads the unticked lines and ticks them: the whole matter goes, except that
    // a recording goes as one part the member picks (review V7-S5: ticking a second
    // part of the same recording unticks the first).
    for entry in aEntries where !aReview.ticked.contains(entry.candidate.id) {
      aReview.toggle(entry.candidate.id)
    }
    for entry in bEntries where !bReview.ticked.contains(entry.candidate.id) {
      bReview.toggle(entry.candidate.id)
    }
    let recordingsOf = { (entries: [SpaceShareContent.Entry]) in
      Set(entries.compactMap(\.candidate.recordingID))
    }
    check(
      "one part per recording is ticked (B filed two parts of one meeting)",
      aReview.selected.filter { $0.recordingID != nil }.count == recordingsOf(aEntries).count
        && bReview.selected.filter { $0.recordingID != nil }.count == recordingsOf(bEntries).count
        && aReview.selected.count == aEntries.count
          - (aEntries.filter { $0.candidate.recordingID != nil }.count
            - recordingsOf(aEntries).count)
        && bReview.selected.count == bEntries.count
          - (bEntries.filter { $0.candidate.recordingID != nil }.count
            - recordingsOf(bEntries).count)
    )
    let recordingParts = allEntries.filter { $0.item.kind == "audio_segment" }
    check(
      "recordings go as parts only (A 1 part, B 2 filed parts), each at most 15 min",
      allEntries.allSatisfy { !SpaceShareContent.recordingKinds.contains($0.item.kind) }
        && aEntries.filter { $0.item.kind == "audio_segment" }.count == 1
        && bEntries.filter { $0.item.kind == "audio_segment" }.count == 2
        && recordingParts.allSatisfy {
          guard let segment = $0.item.segment else { return false }
          return segment.endMS - segment.startMS <= SpaceEngine.maximumSegmentMS
        })
    let outgoingTexts = allEntries.flatMap { $0.item.fields.texts }
    check(
      "B's unfiled meeting lines are in no outgoing item",
      !unfiledLines.isEmpty
        && unfiledLines.allSatisfy { line in !outgoingTexts.contains { $0.contains(line) } })
    let aShare = try await a.engine.share(
      spaceID, items: aEntries.filter { aReview.ticked.contains($0.candidate.id) }.map(\.item),
      package: SpacePackageRequest(auto: .ask, matterID: "E2", title: "Twin-7 叠衣服真机实验"))
    let bShare = try await b.engine.share(
      spaceID, items: bEntries.filter { bReview.ticked.contains($0.candidate.id) }.map(\.item),
      package: SpacePackageRequest(auto: .ask, matterID: "E5", title: "Twin-7 表2 真机数据"))
    check(
      "both shared everything they ticked (no refusal)",
      aShare.refused.isEmpty && bShare.refused.isEmpty
        && aShare.shared.count == aReview.selected.count
        && bShare.shared.count == bReview.selected.count
        && aShare.packageID != nil && bShare.packageID != nil)
    let union = Set((aShare.shared + bShare.shared).map { $0.lowercased() })
    counts["shared_a"] = aShare.shared.count
    counts["shared_b"] = bShare.shared.count
    lap("shared")

    // Originals go to members end to end: each opens the other's screenshot.
    let aSynced = try await a.engine.sync(spaceID)
    let bSynced = try await b.engine.sync(spaceID)
    func screenshot(_ entries: [SpaceShareContent.Entry]) throws -> SpaceShareContent.Entry {
      try XCTUnwrap(entries.first { $0.item.kind == "image" })
    }
    let aShot = try screenshot(aEntries)
    let bShot = try screenshot(bEntries)
    let bShotOnA = try XCTUnwrap(aSynced.items[bShot.item.itemID])
    let aShotOnB = try XCTUnwrap(bSynced.items[aShot.item.itemID])
    let openedOnA = try await a.engine.original(
      spaceID, itemID: bShot.item.itemID, blob: try XCTUnwrap(bShotOnA.blobs.first))
    let openedOnB = try await b.engine.original(
      spaceID, itemID: aShot.item.itemID, blob: try XCTUnwrap(aShotOnB.blobs.first))
    check(
      "each member opens the other's screenshot original, byte for byte",
      openedOnA == bShot.item.originals.first?.data && openedOnB == aShot.item.originals.first?.data
    )
    check(
      "B reads A's dictations and A reads B's number as they are",
      bSynced.items.values.contains { $0.kind == "dictation" && $0.fields?.text != nil }
        && aSynced.items[noteEntry.item.itemID]?.fields?.text?.contains(phone) == true)

    // 3. The space organizer, leased by A, assembles one matter from both.
    let builder = SpaceOrganizerPayloads(imageRedactor: VisionSendCopyRedactor())
    struct Assembly {
      var eventID: String?
      var title = ""
      var covered = 0
      var members: Set<String> = []
      var events = 0
      var linked = false
      var busy = true
      /// Items outside the shared matter → the title of the matter they are in.
      var elsewhere: [String: String] = [:]
    }
    func assembly(_ state: SpaceLocalState?, aMember: String, bMember: String, ids: Set<String>)
      -> Assembly
    {
      var out = Assembly()
      guard let organizer = state?.organizer, let json = try? SpaceJSON.decode(organizer.state)
      else { return out }
      out.busy = organizer.busyQueue > 0 || organizer.busyBriefs > 0
      for event in json["events"]?.array ?? [] {
        guard event["deleted"]?.bool != true, event["merged_into"]?.string == nil,
          let eventID = event["event_id"]?.string
        else { continue }
        out.events += 1
        let items = Set((event["item_ids"]?.array ?? []).compactMap { $0.string?.lowercased() })
        let covered = ids.intersection(items).count
        guard covered > out.covered else { continue }
        let links = organizer.sameAs.filter { $0.eventID == eventID }
        out.eventID = eventID
        out.title = event["title"]?.string ?? ""
        out.covered = covered
        out.members = ids.intersection(items)
        out.linked =
          links.contains { $0.memberID == aMember && $0.matterID == "E2" }
          && links.contains { $0.memberID == bMember && $0.matterID == "E5" }
      }
      for event in json["events"]?.array ?? [] where event["event_id"]?.string != out.eventID {
        guard event["deleted"]?.bool != true, event["merged_into"]?.string == nil else { continue }
        for id in (event["item_ids"]?.array ?? []).compactMap({ $0.string?.lowercased() })
        where ids.contains(id) {
          out.elsewhere[id] = event["title"]?.string ?? ""
        }
      }
      return out
    }
    let aMember = aSynced.memberID
    let bMember = bSynced.memberID
    var assembled = Assembly()
    var quietSince: Date?
    let deadline = Date().addingTimeInterval(1_200)
    while Date() < deadline {
      let report = try await a.engine.organize(spaceID, builder: builder)
      counts["payloads_sent_by_a"] = (counts["payloads_sent_by_a"] ?? 0) + report.sent
      assembled = assembly(
        try await a.engine.state(spaceID), aMember: aMember, bMember: bMember, ids: union)
      if !assembled.busy {
        if assembled.covered == union.count, assembled.linked { break }
        // Quiet but not whole yet: give consolidation a few minutes.
        quietSince = quietSince ?? Date()
        if let quietSince, Date().timeIntervalSince(quietSince) > 240 { break }
      } else {
        quietSince = nil
      }
      try await Task.sleep(for: .seconds(10))
    }
    lap("assembled")
    counts["space_events"] = assembled.events
    counts["assembled_items"] = assembled.covered
    counts["union_items"] = union.count
    // Where the items outside the shared matter went (refs and titles only, all synthetic).
    let entryByID = Dictionary(
      allEntries.map { ($0.item.itemID, $0) }, uniquingKeysWith: { first, _ in first })
    let strays: [[String: String]] = union.subtracting(assembled.members).sorted().map { id in
      [
        "ref": entryByID[id].flatMap { refs[$0.candidate.sourceItemID] } ?? "?",
        "kind": entryByID[id]?.item.kind ?? "?",
        "by": aShare.shared.contains(id) ? "A" : "B",
        "in": assembled.elsewhere[id] ?? "unfiled",
      ]
    }
    check(
      "one shared matter holds the union of both members' items",
      assembled.eventID != nil && assembled.covered == union.count)
    check("the shared matter links back to A's E2 and B's E5 (同一件事)", assembled.linked)
    let aStateValue = try await a.engine.state(spaceID)
    let aState = try XCTUnwrap(aStateValue)
    let rawState = try XCTUnwrap(aState.organizer?.state)
    check(
      "the Spark's organizer state has placeholders, never the number",
      !String(decoding: rawState, as: UTF8.self).contains(phone))

    // The Mac's read model: what A sees, the badge, and B's side.
    let aView = SpaceProjectionBuilder.build(
      aState, maskKey: try await a.engine.maskKey(spaceID), timeZone: Self.zone)
    let aMine = aEntries.map { $0.item.itemID.uppercased() }
    let aBadge = SpaceOverlay.badges(personal: [("E2", aMine)], spaces: [(aState, aView)])["E2"]
    let bOnA = Set(bShare.shared.map { $0.uppercased() })
    check(
      "A's badge: 共享版更完整 · +N 条，来自 韩策 (N = B's items in the shared matter)",
      aBadge?.text.hasPrefix("共享版更完整 · +\(bOnA.count) 条，来自 ") == true
        && aBadge?.contributors == [bName]
        && Set((aBadge?.extraItemIDs ?? []).map { $0.uppercased() }) == bOnA)
    let shown = aView.projection.events.map { "\($0.title) \($0.statusLine)" }.joined()
    check("no placeholder left in what A sees", !shown.contains("〔"))
    if let eventID = assembled.eventID {
      counts["contribution_line_names"] =
        aView.contributionLine(eventID: eventID)?.components(separatedBy: " + ").count ?? 0
    }
    _ = try await b.engine.organize(spaceID, builder: builder)
    let bStateValue = try await b.engine.state(spaceID)
    let bState = try XCTUnwrap(bStateValue)
    let bView = SpaceProjectionBuilder.build(
      bState, maskKey: try await b.engine.maskKey(spaceID), timeZone: Self.zone)
    let bMine = bEntries.map { $0.item.itemID.uppercased() }
    let bBadge = SpaceOverlay.badges(personal: [("E5", bMine)], spaces: [(bState, bView)])["E5"]
    check(
      "B's badge names A's items (来自 林知远)",
      bBadge?.contributors == [aName]
        && Set((bBadge?.extraItemIDs ?? []).map { $0.uppercased() })
          == Set(aShare.shared.map { $0.uppercased() })
    )
    check(
      "B's view holds every shared item, numbers as they are",
      bView.records.contains { $0.text?.contains(phone) == true }
        && bView.records.count == union.count)
    let membersRead = Self.memberTexts(aState) + Self.memberTexts(bState)
    lap("read")

    // 4. B forks one of A's items, withdraws one of its own; A removes B.
    let aNoteID = try XCTUnwrap(aEntries.first?.item.itemID)
    try await b.engine.fork(spaceID, itemID: aNoteID)
    try await b.engine.recordForkCopy(spaceID, itemID: aNoteID, localID: "LOCAL-FORK")
    try await b.engine.withdraw(spaceID, itemID: noteEntry.item.itemID)
    let afterWithdraw = try await a.engine.sync(spaceID)
    check(
      "B's withdrawal within the window shows on A",
      afterWithdraw.items[noteEntry.item.itemID]?.status == .withdrawn
        && afterWithdraw.items[noteEntry.item.itemID]?.fields == nil)
    let shredded = try await a.engine.client.itemKeys(spaceID, itemIDs: [noteEntry.item.itemID])
    check(
      "crypto-shredding: the withdrawn item's data key is gone from the Spark",
      shredded.items.isEmpty)
    _ = try await a.engine.organize(spaceID, builder: builder)
    let afterPurge = assembly(
      try await a.engine.state(spaceID), aMember: aMember, bMember: bMember,
      ids: [noteEntry.item.itemID])
    check("the withdrawn item left the shared matter", afterPurge.covered == 0)
    let bEpoch1 = try XCTUnwrap(try b.stores.keys.keys(spaceID)[1])
    try await a.engine.removeMember(spaceID, memberID: bMember)
    lap("removed")

    // 5. Rotation: the next item is epoch 2 and B cannot read it.
    let later = try await paste(a, try item(LabTwin7.aLater), scenario: scenario, real: real)
    let laterEntries = try await entries(a, [(later, [])], matter: "E2")
    let laterShare = try await a.engine.share(spaceID, items: laterEntries.map(\.item))
    let next = try XCTUnwrap(laterShare.shared.first)
    let rotated = try await a.engine.sync(spaceID)
    check("the space key rotated to epoch 2", rotated.epoch == 2)
    let keyValue = try await a.engine.client.itemKeys(spaceID, itemIDs: [next])
    let key = try XCTUnwrap(keyValue.items.first)
    check("the item shared after the removal is at epoch 2", key.epoch == 2)
    check(
      "B's epoch-1 key cannot open it",
      (try? SpaceCrypto.unwrapItemKey(
        key.wrappedDK, spaceKey: bEpoch1, spaceID: spaceID, epoch: 2, itemID: next)) == nil)
    do {
      _ = try await b.engine.sync(spaceID)
      check("B is refused after the removal", false)
    } catch SpaceClientError.accessEnded {
      check("B is refused after the removal", true)
    }
    let bKeysLeft = try b.stores.keys.keys(spaceID)
    check(
      "B's copy of the space and its keys are deleted",
      try await b.engine.state(spaceID) == nil && bKeysLeft.isEmpty)
    check(
      "B's fork copy is handed back for deletion",
      await b.engine.takeForkCopiesToDelete() == ["LOCAL-FORK"])
    var bDenied = 0
    for attempt in 0..<3 {
      do {
        switch attempt {
        case 0: _ = try await b.engine.client.keys(spaceID)
        case 1: _ = try await b.engine.client.itemKeys(spaceID, itemIDs: [next])
        default:
          _ = try await b.engine.client.blob(
            spaceID, blobID: try XCTUnwrap(aShotOnB.blobs.first?.blobID))
        }
      } catch SpaceClientError.accessEnded {
        bDenied += 1
      } catch {}
    }
    check(
      "B's device gets no new key, no item key and no original (403 not_member)", bDenied == 3)
    let rewrapped = try await a.engine.rewrapStale(spaceID)
    let oldKeyValue = try await a.engine.client.itemKeys(spaceID, itemIDs: [aNoteID])
    let oldKey = try XCTUnwrap(oldKeyValue.items.first)
    check(
      "lazy re-wrap: old item keys move to epoch 2, out of reach of B's old key",
      rewrapped > 0 && oldKey.epoch == 2
        && (try? SpaceCrypto.unwrapItemKey(
          oldKey.wrappedDK, spaceKey: bEpoch1, spaceID: spaceID, epoch: 2, itemID: aNoteID))
          == nil
    )
    counts["rewrapped_item_keys"] = rewrapped
    let rekey = try await a.engine.organize(spaceID, builder: builder)
    check("the organizer store is re-keyed at the next lease", rekey.rekeyed)
    let afterRemoval = try await a.engine.sync(spaceID)
    let bStillThere = bShare.shared.filter { $0 != noteEntry.item.itemID }
    check(
      "B's other contributions stay in the space, attributed to B (org asset)",
      bStillThere.allSatisfy {
        afterRemoval.items[$0]?.isActive == true && afterRemoval.items[$0]?.contributor == bMember
      })
    // The new item joins the shared matter.
    var laterFiled = false
    let laterDeadline = Date().addingTimeInterval(300)
    while Date() < laterDeadline {
      _ = try await a.engine.organize(spaceID, builder: builder)
      let now = assembly(
        try await a.engine.state(spaceID), aMember: aMember, bMember: bMember,
        ids: union.union([next.lowercased()]).subtracting([noteEntry.item.itemID]))
      if !now.busy {
        laterFiled = now.covered == union.count
        break
      }
      try await Task.sleep(for: .seconds(10))
    }
    check("the item shared after the removal joins the same shared matter", laterFiled)
    await a.engine.lockOrganizer(spaceID)
    lap("rotated")

    // 6. Every payload either Mac sent, and everything members read.
    let sent = a.wire.sent + b.wire.sent
    let wireTexts = sent.flatMap { Self.texts(of: $0.body) }
    let organizerTexts = sent.filter { $0.target.hasSuffix("/organizer/items") }
      .flatMap { Self.texts(of: $0.body) }
    counts["requests"] = sent.count
    counts["request_bytes"] = sent.reduce(0) { $0 + $1.body.count }
    counts["organizer_payload_requests"] =
      sent.filter { $0.target.hasSuffix("/organizer/items") }
      .count
    for (label, needle) in [
      ("voiceprint", voiceprint), ("dictionary entry", dictionarySentinel),
      ("window title", window),
    ] {
      check(
        "no \(label) in any request either Mac sent",
        !wireTexts.contains { $0.contains(needle) })
      check(
        "no \(label) in anything a member decrypts", !membersRead.contains { $0.contains(needle) })
    }
    check(
      "the phone number never crosses the link in plain text",
      !wireTexts.contains { $0.contains(phone) })
    check(
      "the organizer received the number as a placeholder",
      organizerTexts.contains { $0.contains("〔手机号") })
    check(
      "B's unfiled meeting lines are in no request and nothing a member reads",
      unfiledLines.allSatisfy { line in
        !wireTexts.contains { $0.contains(line) } && !membersRead.contains { $0.contains(line) }
      })
    let uploads = sent.filter { $0.method == "PUT" && $0.target.contains("/blobs/") }
    let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])
    check(
      "every uploaded original is MLB1 ciphertext, never the image",
      uploads.count == 2
        && uploads.allSatisfy {
          $0.body.starts(with: Data("MLB1".utf8)) && $0.body.range(of: pngMagic) == nil
        })
    var routes: [String: Int] = [:]
    for request in sent { routes[Self.route(request), default: 0] += 1 }

    // 7. Nothing readable on the Spark.
    var sparkHits: [String: Int] = [:]
    if let dataDir = live.dataDir {
      let needles: [(label: String, text: String)] = [
        ("marker", marker), ("number", phone), ("dictionary", dictionarySentinel),
        ("voiceprint", voiceprint), ("window", window), ("space-name", spaceName),
        ("name-a", aName), ("name-b", bName), ("lab-words", "左臂腕关节电机"),
        ("lab-sheet", "叠衣服真机实验"), ("supplier", "锐拓智控"),
        ("unfiled-words", "EmbodiedEval-Lite"),
      ]
      let scan = try sparkScan(live, dataDir: dataDir, spaceID: spaceID, needles: needles)
      sparkHits = scan.hits
      for needle in needles {
        check("no \(needle.label) on the Spark (data and logs)", scan.hits[needle.label] == 0)
      }
      check(
        "every blob the Spark keeps for the space is MLB1 ciphertext",
        scan.blobs > 0 && scan.sealed == scan.blobs)
      counts["spark_blobs"] = scan.blobs
    }
    lap("done")

    let failed = checks.filter { !$0.1 }.map(\.0)
    let summary: [String: Any] = [
      "test": "spaces-e2e-lab-twin7", "checks": checks.count, "passed": checks.count - failed.count,
      "failed": failed, "names": checks.map(\.0), "seconds": timings, "counts": counts,
      "routes": routes, "spark_hits": sparkHits, "assembled_title": assembled.title,
      "strays": strays,
      "space_id": spaceID,
    ]
    if let evidence = live.evidence {
      try? FileManager.default.createDirectory(
        at: evidence.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted])
        .write(to: evidence)
    }
    for (name, ok) in checks { print("SPACES-E2E \(ok ? "pass" : "FAIL") \(name)") }
    print("SPACES-E2E \(checks.count - failed.count)/\(checks.count) checks pass")
    XCTAssertEqual(failed, [])
  }
}
