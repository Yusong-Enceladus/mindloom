import BestASRDomain
import BestASRIntake
import BestASRMemory
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation
import MindloomTencentMeeting
import Security

/// Developer probe for the Tencent Meeting entry (ENTRY-013): runs the
/// App's own pass (`TencentMeetingSync`) with a given tmeet and login state
/// into a scratch library — one marked `SYNTHETIC_DATA_ROOT`, or a folder in
/// the private evaluation folder `~/.mindloom-private-eval` (0700) —
/// never the owner's real library, and prints counts only (no titles, names
/// or words).
///
///     TencentMeetingProbeCLI --tmeet <tmeet> --tmeet-state <dir> --root <synthetic root>
///       [--pass full|light|status|login|login-url|verify] [--budget N] [--days N]
///
/// The key goes to tmeet on descriptor 3, as the App does: for a synthetic
/// root its test key file; for a folder in the private evaluation folder a
/// Keychain item this probe makes for that folder (the same kind the App
/// keeps, service `app.mindloom.tencent-meeting`, account = the folder's
/// identity hash). tmeet's own system Keychain entry is never used (any
/// program of this user can read it). `login` starts `auth login
/// --no-browser`, prints Tencent's authorization address for the developer
/// to open and waits for it to be allowed; `login-url` checks the address
/// and stops at once (no login is made).
@main
struct TencentMeetingProbeCLI {
  struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  static func main() async {
    do {
      try await run(Array(CommandLine.arguments.dropFirst()))
    } catch {
      FileHandle.standardError.write(Data("error: \(error)\n".utf8))
      exit(2)
    }
  }

  static func run(_ arguments: [String]) async throws {
    func value(_ name: String) -> String? {
      arguments.firstIndex(of: name).flatMap {
        arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
      }
    }
    guard let tmeet = value("--tmeet"), let tmeetState = value("--tmeet-state"),
      let rootPath = value("--root")
    else { throw Failure("usage: --tmeet <path> --tmeet-state <dir> --root <synthetic root>") }
    let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
    try checkRoot(root)
    let masterKey: TmeetEnvironment.MasterKey
    if let keyStore = try? SyntheticTencentMeetingKeyStore(dataRoot: root) {
      masterKey = .descriptor({ try keyStore.existingOrNewKey() })
    } else {
      let keyStore = KeychainTencentMeetingKeyStore(dataRoot: root)
      masterKey = .descriptor({ try keyStore.existingOrNewKey() })
    }
    // A tmeet built outside the App (no App seal to check it against); the
    // key handed to it is the synthetic root's or this run's own.
    let environment = TmeetEnvironment(
      executable: URL(fileURLWithPath: tmeet),
      stateDirectory: URL(fileURLWithPath: tmeetState, isDirectory: true), masterKey: masterKey,
      helperCheck: .unchecked)
    let runner = TmeetProcessRunner(environment: environment)
    let pass = value("--pass") ?? "full"

    if pass == "login" {
      let result = await runner.login(
        onLine: { line in
          if let url = TencentMeetingLoginOutput.authorizationURL(in: line) {
            print("open: \(url.absoluteString)")
          }
        }, cancellation: TencentMeetingCancellation())
      print("login: outcome=\(TencentMeetingLoginOutput.outcome(result, cancelled: false))")
      return
    }

    if pass == "login-url" {
      let cancellation = TencentMeetingCancellation()
      let found = Found()
      let result = await runner.login(
        onLine: { line in
          if TencentMeetingLoginOutput.authorizationURL(in: line) != nil {
            found.set()
            cancellation.cancel()
          }
        }, cancellation: cancellation)
      let outcome = TencentMeetingLoginOutput.outcome(
        result, cancelled: cancellation.isCancelled && !found.isSet)
      print("login-url: address_recognized=\(found.isSet) outcome=\(outcome)")
      return
    }

    if pass == "status" {
      let result = await runner.run(.authStatus, timeout: .seconds(60))
      if let failure = TencentMeetingOutput.failure(result) {
        print(
          "status: failure=\(failure.failure.rawValue) code=\(failure.code.map(String.init) ?? "-")"
        )
        return
      }
      let status = TencentMeetingAuthStatus.parse(String(decoding: result.stdout, as: UTF8.self))
      let now = Date()
      func hours(_ date: Date?) -> String {
        date.map { String(format: "%.1f", $0.timeIntervalSince(now) / 3_600) } ?? "-"
      }
      print(
        "status: logged_in=\(status.loggedIn) has_name=\(status.userName != nil) "
          + "access_hours_left=\(hours(status.accessTokenExpires)) "
          + "refresh_hours_left=\(hours(status.refreshTokenExpires))")
      return
    }

    let store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
    if pass == "verify" {
      try await verify(root: root, store: store)
      return
    }
    let assets = IntakeAssetStore(
      assetRoot: root.appendingPathComponent("assets", isDirectory: true))
    let writer = TencentMeetingLibraryWriter(assetStore: assets, store: store)
    let stateFile = root.appendingPathComponent("entries/state-tencentMeeting.json")
    try FileManager.default.createDirectory(
      at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var state =
      (try? Data(contentsOf: stateFile)).flatMap {
        try? decoder.decode(TencentMeetingState.self, from: $0)
      }
      ?? TencentMeetingState()
    if state.connectedAt == nil {
      state.connectedAt = Date()
      state.backfill = .add
    }
    var configuration = TencentMeetingSync.Configuration(
      tmeetVersion: value("--tmeet-version") ?? "probe")
    if let budget = value("--budget").flatMap(Int.init) { configuration.dailyBudget = budget }
    if let days = value("--days").flatMap(Int.init) { configuration.windowDays = days }
    let sync = TencentMeetingSync(
      state: state, runner: runner, writer: writer, configuration: configuration
    ) { state in
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      if let data = try? encoder.encode(state) {
        try? data.write(to: stateFile, options: [.atomic])
        chmod(stateFile.path, 0o600)
      }
    }
    let started = Date()
    let report = await sync.pass(pass == "light" ? .light : .full)
    let after = await sync.snapshot
    var byStatus: [String: Int] = [:]
    for job in after.recordings.values { byStatus[job.status.rawValue, default: 0] += 1 }
    var byType: [String: Int] = [:]
    for job in after.recordings.values { byType[job.type.rawValue, default: 0] += 1 }
    let line = TencentMeetingStatus.line(state: after, helperAvailable: true)
    print(
      """
      pass: kind=\(report.kind.rawValue) seconds=\(String(format: "%.1f", Date().timeIntervalSince(started)))
      calls: \(report.calls) requests: \(report.requests) (today \(after.requestsToday)/\(configuration.dailyBudget))
      listed: \(report.listed) listed_in_full: \(report.listedInFull) truncated_meetings: \(report.truncatedMeetings)
      fetched: \(report.fetched) added: \(report.added) unchanged: \(report.unchanged) no_content: \(report.noContent)
      covered: \(report.covered) needs_permission: \(report.needsPermission) generating: \(report.generating) not_added: \(report.notAdded)
      failure: \(report.failure?.rawValue ?? "none")
      jobs_by_status: \(byStatus.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
      jobs_by_type: \(byType.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
      speakers: \(after.people.count) owner_ids: \(after.ownerUserIDs.count) multi_recording_speakers: \(after.people.values.filter { $0.recordings > 1 }.count)
      status_line_is_problem: \(line.isProblem)
      """)
  }
}

/// The items the entry added, read back the way Mindloom reads them:
/// the source line, the transcript reader, the source file. Counts only.
func verify(root: URL, store: GRDBDictationStore) async throws {
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let stateFile = root.appendingPathComponent("entries/state-tencentMeeting.json")
  let state = try decoder.decode(TencentMeetingState.self, from: Data(contentsOf: stateFile))
  let ids = state.recordings.values.flatMap(\.itemIDs).compactMap { UUID(uuidString: $0) }
    .map { SessionID($0) }
  let records = try await store.memoryItemRecords(ids: ids)
  var lines: [String: Int] = [:]
  var parsed = 0
  var turns = 0
  var tencentFormat = 0
  var sources = 0
  var sourceParagraphs = 0
  for record in records {
    lines[MemoryItemSource.words(record).line, default: 0] += 1
    if let transcript = MemoryTranscriptText.parse(record.text ?? "") {
      parsed += 1
      turns += transcript.turns.count
      if transcript.format == .tencent { tencentFormat += 1 }
    }
  }
  let assets = IntakeAssetStore(assetRoot: root.appendingPathComponent("assets", isDirectory: true))
  var documents: [TencentMeetingSourceDocument] = []
  for id in ids {
    let file = assets.sessionDirectory(id).appendingPathComponent("source/original.json")
    if let data = try? Data(contentsOf: file), let source = TencentMeetingSourceDocument.parse(data)
    {
      sources += 1
      sourceParagraphs += source.paragraphs.count
      documents.append(source)
    }
  }
  print(
    "verify: items=\(records.count) of \(ids.count) source_lines=\(lines.map { "\($0.value)" }.joined(separator: ",")) "
      + "meeting_record_line=\(lines["会议记录 · 腾讯会议"] ?? 0) parsed=\(parsed) tencent_format=\(tencentFormat) "
      + "turns=\(turns) source_files=\(sources) source_paragraphs=\(sourceParagraphs)")
  speakerCheck(documents, state: state)
}

/// The speaker names as the entry writes them now, from the stored source
/// files alone (no tmeet call): each user number learned in the order the
/// entry fetches (newest recording first), then every transcript written
/// again. Counts only: one name per number across meetings, no name shared
/// by two numbers, every rewritten text read as Tencent's format.
func speakerCheck(_ documents: [TencentMeetingSourceDocument], state: TencentMeetingState) {
  let start: (TencentMeetingSourceDocument) -> Date = {
    state.recordings[$0.recordFileID]?.start ?? .distantPast
  }
  let ordered = documents.sorted { start($0) > start($1) }
  var people: [String: TencentMeetingSpeaker] = [:]
  for document in ordered {
    TencentMeetingSpeakers.learn(document.paragraphs, at: start(document), people: &people)
  }
  let owners = Set(state.ownerUserIDs)
  let labels = TencentMeetingSpeakers.labels(people)
  var namesByNumber: [String: Set<String>] = [:]
  var numbersByName: [String: Set<String>] = [:]
  var perMeetingNamesByNumber: [String: Set<String>] = [:]
  var perMeetingNumbersByName: [String: Set<String>] = [:]
  var readable = 0
  for document in ordered {
    let paragraphs = document.paragraphs.filter { !$0.text.isEmpty }
    let names = TencentMeetingTranscriptText.speakerNames(
      paragraphs, ownerUserIDs: owners, labels: labels)
    // The same text written per meeting only (no fixed names), for comparison.
    let perMeeting = TencentMeetingTranscriptText.speakerNames(paragraphs, ownerUserIDs: owners)
    for paragraph in paragraphs {
      guard let number = paragraph.speakerUserID, let name = names["id:" + number] else { continue }
      namesByNumber[number, default: []].insert(name)
      numbersByName[name, default: []].insert(number)
      if let old = perMeeting["id:" + number] {
        perMeetingNamesByNumber[number, default: []].insert(old)
        perMeetingNumbersByName[old, default: []].insert(number)
      }
    }
    let text = TencentMeetingTranscriptText.readable(
      title: "示例", paragraphs: paragraphs, ownerUserIDs: owners, labels: labels)
    if MemoryTranscriptText.parse(text)?.format == .tencent { readable += 1 }
  }
  let displayNames = people.values.filter { Set($0.names).count > 1 }.count
  print(
    "speakers: numbers=\(namesByNumber.count) labelled=\(labels.count) owner_numbers=\(owners.count) "
      + "in_2_or_more_recordings=\(people.values.filter { $0.recordings > 1 }.count) "
      + "numbers_with_changed_display_name=\(displayNames) "
      + "labels_with_suffix=\(labels.values.filter { $0.range(of: #" \d+$"#, options: .regularExpression) != nil }.count) "
      + "numbers_with_more_than_one_name=\(namesByNumber.values.filter { $0.count > 1 }.count) "
      + "names_shared_by_numbers=\(numbersByName.filter { $0.key != TencentMeetingTranscriptText.ownerName && $0.value.count > 1 }.count) "
      + "rewritten_tencent_format=\(readable) of \(ordered.count)")
  let me = TencentMeetingTranscriptText.ownerName
  print(
    "per_meeting_names_only: "
      + "numbers_with_more_than_one_name=\(perMeetingNamesByNumber.values.filter { $0.count > 1 }.count) "
      + "names_shared_by_numbers=\(perMeetingNumbersByName.filter { $0.key != me && $0.value.count > 1 }.count)"
  )
}

/// A scratch library: never inside the owner's real library; marked
/// synthetic, or inside the private evaluation folder (0700).
func checkRoot(_ root: URL) throws {
  guard let real = BestASRDataRootSelection.ownerRealLibraryRoot(),
    !BestASRDataRootSelection.path(root, isWithinOrEqualTo: real)
  else {
    throw TencentMeetingProbeCLI.Failure("refusing the real library (or no real library path)")
  }
  let marked = FileManager.default.fileExists(
    atPath: root.appendingPathComponent(RemoteOrganizerDataProvenance.syntheticMarkerFileName).path)
  let privateFolder = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".mindloom-private-eval", isDirectory: true).resolvingSymlinksInPath()
  let inPrivate =
    BestASRDataRootSelection.path(root, isWithinOrEqualTo: privateFolder)
    && root.path != privateFolder.path
  guard marked || inPrivate else {
    throw TencentMeetingProbeCLI.Failure(
      "refusing a root that is neither marked synthetic nor in ~/.mindloom-private-eval")
  }
  if inPrivate {
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    chmod(root.path, 0o700)
  }
}

final class Found: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func set() { lock.withLock { value = true } }
  var isSet: Bool { lock.withLock { value } }
}
