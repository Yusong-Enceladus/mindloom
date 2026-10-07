import BestASRDomain
import Foundation

/// Fetches the owner's Tencent Meeting transcripts into the library (ARCH
/// v3 §6, PRD ENTRY-013). One pass:
///
/// 1. On a full pass, `auth status` at most once a day: the login holds,
///    its end, the account's name.
/// 2. `record list` over the window: the recordings this account made or
///    owns (nearly all in meetings it hosted). On a full pass also `meeting
///    list-ended` (the meetings it created or joined, up to five recordings
///    each with their permission): recordings of meetings others host come
///    only from here. A meeting listed with fewer recordings than Tencent
///    counts is listed in full with `meeting get` (once a day, at once when
///    its count grows or one of its recordings is due).
/// 3. Each recording's job is updated from the listings: a finished,
///    viewable recording is fetched once; again only when its listing
///    fingerprint changes; `can_apply` and password ones are listed for the
///    owner; a cloud recording that the same meeting's text transcription
///    already covers is not fetched (one meeting, one transcript).
/// 4. Transcripts are fetched page by page (`--pid`), newest first, and
///    added as 「会议记录 · 腾讯会议」 items; the job is saved after each.
///    One that keeps failing is tried again once a day while it is in the
///    window and shown in Settings.
///
/// Requests to Tencent are counted per day (`dailyBudget`, with a share
/// kept for transcripts that listings may not use); Tencent's own limit
/// (500246) pauses everything until the next day. Nothing here touches an
/// item after it was added: a changed transcript becomes a new item, and
/// not even that when the owner deleted the earlier one.
public actor TencentMeetingSync {
  public struct Configuration: Sendable {
    /// Recordings of the last 30 days (meetings created or joined).
    public var windowDays = 30
    /// A light pass looks at the last two days.
    public var lightWindowDays = 2
    /// Requests to Tencent per local day (`TencentMeetingCommand.requests`;
    /// Tencent publishes no limit).
    public var dailyBudget = 150
    /// The part of `dailyBudget` only transcript pages may use, so the
    /// day's listings never leave nothing for the day's meetings.
    public var transcriptReserve = 50
    public var maximumListPages = 5
    public var maximumTranscriptPages = 60
    /// `auth status` on a full pass when the last check is older.
    public var statusCheckInterval: TimeInterval = 20 * 3_600
    /// Waits before fetching a recording again (attempt 1, 2, …).
    public var retryDelays: [TimeInterval] = [300, 900, 1_800, 3_600, 7_200, 14_400]
    /// After `maximumAttempts`: tried again this often while in the window.
    public var failedRetryInterval: TimeInterval = 24 * 3_600
    /// Network failures and server errors in a row on one recording that
    /// count as one attempt (each stops the pass and costs it nothing).
    public var transientFailuresPerAttempt = 3
    /// A meeting `list-ended` lists only part of is listed in full again
    /// after this long.
    public var fullListingInterval: TimeInterval = 24 * 3_600
    public var commandTimeout: Duration = .seconds(120)
    /// A text transcription covers a cloud recording of the same meeting
    /// when it spans this share of it.
    public var coverage = 0.9
    public var tmeetVersion: String

    public init(tmeetVersion: String) {
      self.tmeetVersion = tmeetVersion
    }
  }

  public enum PassKind: String, Sendable {
    /// Both listings over the window: catches up what was missed.
    case full
    /// `record list` over the last two days.
    case light
  }

  /// What asked for a pass (`kind(for:state:now:)` decides which, if any).
  public enum Trigger: Sendable {
    /// The check every 90 minutes while the Mac is awake.
    case regular
    /// The App started.
    case launch
    /// The Mac woke.
    case wake
    /// 「现在检查」.
    case checkNow
    /// The owner just connected.
    case connected
    /// The owner answered 「添加」 to the first question.
    case answered
  }

  /// A regular check this soon after the last pass is left out.
  public static let minimumGap: TimeInterval = 10 * 60
  /// A wake or a launch this soon after the last pass checks nothing (the
  /// regular check comes anyway).
  public static let wakeGap: TimeInterval = 30 * 60
  /// A pass is a full one when the last full one is older than this.
  public static let fullPassAge: TimeInterval = 3 * 3_600

  /// Which pass a trigger gets: nil when the last pass was too recent. A
  /// full pass at most every three hours unless the owner asked for one,
  /// so waking the Mac many times a day costs a light listing at most every
  /// half hour and never the day's budget.
  public static func kind(for trigger: Trigger, state: TencentMeetingState, now: Date)
    -> PassKind?
  {
    func within(_ date: Date?, _ interval: TimeInterval) -> Bool {
      date.map { (0..<interval).contains(now.timeIntervalSince($0)) } ?? false
    }
    let fullDue = !within(state.lastFullPass, fullPassAge)
    switch trigger {
    case .connected, .answered:
      return .full
    case .checkNow:
      return within(state.lastFullPass, minimumGap) ? .light : .full
    case .regular:
      return within(state.lastPass, minimumGap) ? nil : fullDue ? .full : .light
    case .launch, .wake:
      return within(state.lastPass, wakeGap) ? nil : fullDue ? .full : .light
    }
  }

  /// What a pass did (counts only).
  public struct Report: Equatable, Sendable {
    public var kind: PassKind
    public var added = 0
    /// tmeet commands run.
    public var calls = 0
    /// Requests to Tencent they made (`TencentMeetingCommand.requests`).
    public var requests = 0
    public var listed = 0
    /// Meetings listed in full with `meeting get`.
    public var listedInFull = 0
    public var fetched = 0
    public var unchanged = 0
    public var noContent = 0
    public var covered = 0
    public var generating = 0
    public var needsPermission = 0
    /// Recordings still not added after every attempt (tried again daily).
    public var notAdded = 0
    /// Recordings from before the connection, waiting for the first answer.
    public var waitingForAnswer = 0
    /// Meetings in the window Tencent counts more recordings for than any
    /// listing gave.
    public var truncatedMeetings = 0
    public var failure: TencentMeetingFailure?

    public init(kind: PassKind) { self.kind = kind }
  }

  public let configuration: Configuration
  private let runner: any TencentMeetingRunning
  private let writer: any TencentMeetingItemWriting
  private let save: @Sendable (TencentMeetingState) -> Void
  private let calendar: Calendar
  private var state: TencentMeetingState
  private var running = false

  public init(
    state: TencentMeetingState, runner: any TencentMeetingRunning,
    writer: any TencentMeetingItemWriting, configuration: Configuration,
    calendar: Calendar = .current, save: @escaping @Sendable (TencentMeetingState) -> Void
  ) {
    self.state = state
    self.runner = runner
    self.writer = writer
    self.configuration = configuration
    self.calendar = calendar
    self.save = save
  }

  public var snapshot: TencentMeetingState { state }

  // MARK: Connection

  /// The owner allowed the login on this Mac. A first connection asks
  /// whether to add earlier recordings; a reconnection keeps the answer.
  public func connected(at now: Date) {
    state.connectedAt = state.connectedAt ?? now
    state.lastFailure = nil
    state.lastStatusCheck = nil
    state.pausedUntil = nil
    persist()
  }

  /// The owner's answer to 「添加过去 30 天的会议转写？」.
  public func answerBackfill(add: Bool, now: Date) {
    state.backfill = add ? .add : .skip(before: state.connectedAt ?? now)
    for (id, job) in state.recordings
    where [.pending, .waiting, .covered].contains(job.status) && skippedByAnswer(job) {
      state.recordings[id]?.status = .skipped
      state.recordings[id]?.coveredBy = nil
    }
    persist()
  }

  /// The login was removed (the entry switched off). What was added and
  /// which recordings were seen stay, so nothing is added twice and
  /// nothing the owner deleted comes back.
  public func disconnected() {
    state.connectedAt = nil
    state.accountName = nil
    state.accessTokenExpires = nil
    state.refreshTokenExpires = nil
    state.lastStatusCheck = nil
    state.refreshExtendsLogin = nil
    state.lastFailure = nil
    state.pausedUntil = nil
    persist()
  }

  // MARK: A pass

  public func pass(_ kind: PassKind, now: Date = Date()) async -> Report {
    var report = Report(kind: kind)
    guard !running else { return report }
    running = true
    defer { running = false }
    state.roll(to: Self.dayKey(now, calendar: calendar))
    if let paused = state.pausedUntil, paused > now {
      report.failure = .rateLimited
      return report
    }
    state.pausedUntil = nil
    state.lastPass = now

    if kind == .full,
      state.lastStatusCheck.map({ now.timeIntervalSince($0) >= configuration.statusCheckInterval })
        ?? true
    {
      if let failure = await checkLogin(now: now, report: &report) {
        return finish(report, failure: failure, now: now)
      }
    }

    let windowStart =
      calendar.date(
        byAdding: .day,
        value: -(kind == .full ? configuration.windowDays : configuration.lightWindowDays),
        to: now) ?? now
    var recordings: [String: TencentMeetingRecording] = [:]
    var listingFailure: TencentMeetingFailure?
    var sources: [TencentMeetingListingSource] = [.recordList]
    if kind == .full { sources.append(.meetingListEnded) }
    for source in sources {
      let listed = await list(source, start: windowStart, end: now, report: &report)
      if let failure = listed.failure, failure.stopsPass {
        return finish(report, failure: failure, now: now)
      }
      merge(listed.recordings, into: &recordings)
      if let failure = listed.failure {
        // A listing Mindloom could not read: what was read is used, but
        // the pass is not a success.
        listingFailure = listingFailure ?? failure
      }
      if source == .meetingListEnded,
        let failure = await listInFull(
          listed.counts, windowStart: windowStart, now: now, recordings: &recordings,
          report: &report)
      {
        return finish(report, failure: failure, now: now)
      }
    }
    report.listed = recordings.count
    for recording in recordings.values { update(recording) }
    applyCoverage()
    detectOwner()
    persist()

    var attempted: Set<String> = []
    while let id = nextDue(now: now, excluding: attempted) {
      attempted.insert(id)
      guard let recording = recordings[id] else { continue }
      if let failure = await fetch(recording, now: now, report: &report) {
        persist()
        return finish(report, failure: failure, now: now)
      }
      applyCoverage()
      persist()
    }
    return finish(report, failure: listingFailure, now: now)
  }

  // MARK: Login

  private func checkLogin(now: Date, report: inout Report) async -> TencentMeetingFailure? {
    guard spend(.authStatus, &report) else { return .rateLimited }
    let result = await runner.run(.authStatus, timeout: configuration.commandTimeout)
    if let failure = TencentMeetingOutput.failure(result) {
      // Anything but a refused login or a stopped pass: checked again on
      // the next full pass; the listings go on.
      return failure.failure.stopsPass ? failure.failure : nil
    }
    let status = TencentMeetingAuthStatus.parse(String(decoding: result.stdout, as: UTF8.self))
    guard status.loggedIn else { return .notConnected }
    if let name = status.userName { state.accountName = name }
    if let previous = state.refreshTokenExpires, let current = status.refreshTokenExpires,
      let previousAccess = state.accessTokenExpires, let access = status.accessTokenExpires,
      access > previousAccess
    {
      // The access token was renewed since the last check: did the login's
      // end move with it?
      state.refreshExtendsLogin = current.timeIntervalSince(previous) > 3_600
    }
    state.accessTokenExpires = status.accessTokenExpires
    state.refreshTokenExpires = status.refreshTokenExpires
    state.lastStatusCheck = now
    detectOwner()
    return nil
  }

  // MARK: Listings

  private struct Listed {
    var recordings: [TencentMeetingRecording] = []
    var counts: [TencentMeetingRecordCount] = []
    /// Why the listing stopped early, if it did.
    var failure: TencentMeetingFailure?
  }

  private func list(
    _ source: TencentMeetingListingSource, start: Date, end: Date, report: inout Report
  ) async -> Listed {
    var listed = Listed()
    var token: String?
    for _ in 0..<configuration.maximumListPages {
      let command: TencentMeetingCommand =
        source == .recordList
        ? .recordList(start: start, end: end, pageToken: token)
        : .meetingListEnded(start: start, end: end, pageToken: token)
      guard spend(command, &report) else {
        listed.failure = .rateLimited
        return listed
      }
      let result = await runner.run(command, timeout: configuration.commandTimeout)
      switch TencentMeetingOutput.data(result) {
      case .failure(let failed):
        listed.failure = failed.failure
        return listed
      case .success(let data):
        let page =
          source == .recordList
          ? TencentMeetingListingParser.recordList(data)
          : TencentMeetingListingParser.meetingListEnded(data)
        listed.recordings += page.recordings
        listed.counts += page.counts
        guard let next = page.nextPageToken, next != token else { return listed }
        token = next
      }
    }
    return listed
  }

  private func merge(
    _ found: [TencentMeetingRecording], into recordings: inout [String: TencentMeetingRecording]
  ) {
    for recording in found {
      if var known = recordings[recording.recordFileID] {
        known.merge(recording)
        recordings[recording.recordFileID] = known
      } else {
        recordings[recording.recordFileID] = recording
      }
    }
  }

  /// `list-ended` gives at most five recordings per meeting: a meeting it
  /// listed only part of is listed in full with `meeting get` when it never
  /// was, a day has passed, Tencent counts more recordings than then, or a
  /// recording only `meeting get` lists is due. Recordings before the
  /// window are left out. Returns a failure that stops the pass; anything
  /// else leaves that meeting for the next pass.
  private func listInFull(
    _ counts: [TencentMeetingRecordCount], windowStart: Date, now: Date,
    recordings: inout [String: TencentMeetingRecording], report: inout Report
  ) async -> TencentMeetingFailure? {
    // Per meeting number (a recurring meeting's occurrences share one).
    var meetings: [String: TencentMeetingMeetingRecords] = [:]
    for count in counts {
      var meeting =
        meetings[count.meetingID]
        ?? TencentMeetingMeetingRecords(start: count.start, total: 0, listed: 0)
      meeting.total = max(meeting.total, count.total)
      meeting.listed += count.listed
      if let start = count.start { meeting.start = min(meeting.start ?? start, start) }
      meetings[count.meetingID] = meeting
    }
    for (id, meeting) in meetings.sorted(by: { $0.key < $1.key }) {
      guard meeting.isIncomplete else {
        state.recordCounts[id] = nil
        continue
      }
      let known = state.recordCounts[id]
      let due =
        known?.fullyListedAt.map { now.timeIntervalSince($0) >= configuration.fullListingInterval }
        ?? true
      let grew = meeting.total > (known?.total ?? 0)
      guard due || grew || hasDueRecordingListedOnlyInFull(meetingID: id, now: now) else {
        continue
      }
      if known?.fullyListedAt == nil { state.recordCounts[id] = meeting }
      let command = TencentMeetingCommand.meetingGet(meetingID: id)
      // Listings within their share only; what is left waits for a pass
      // with budget (nothing stops for it).
      guard spend(command, &report) else { break }
      let result = await runner.run(command, timeout: configuration.commandTimeout)
      switch TencentMeetingOutput.data(result) {
      case .failure(let failed):
        if failed.failure.stopsPass { return failed.failure }
      case .success(let data):
        let page = TencentMeetingListingParser.meetingGet(data)
        let inWindow = page.recordings.filter { ($0.start ?? now) >= windowStart }
        merge(inWindow, into: &recordings)
        report.listedInFull += 1
        let total = page.counts.map(\.total).max() ?? meeting.total
        let listed = page.counts.map(\.listed).reduce(0, +)
        state.recordCounts[id] = TencentMeetingMeetingRecords(
          start: meeting.start, total: max(total, listed), listed: listed, fullyListedAt: now)
      }
    }
    // Meetings long out of the window are forgotten.
    let forget = calendar.date(byAdding: .day, value: -1, to: windowStart) ?? windowStart
    state.recordCounts = state.recordCounts.filter {
      ($0.value.start ?? $0.value.fullyListedAt ?? now) >= forget
    }
    return nil
  }

  /// A recording of this meeting that only `meeting get` has listed and
  /// that is waiting for Tencent or due to be fetched.
  private func hasDueRecordingListedOnlyInFull(meetingID: String, now: Date) -> Bool {
    state.recordings.values.contains { job in
      job.meetingID == meetingID
        && job.fingerprints.keys.allSatisfy {
          $0 == TencentMeetingListingSource.meetingGet.rawValue
        }
        && (job.status == .waiting
          || ([.pending, .failed].contains(job.status) && (job.nextAttempt ?? now) <= now))
    }
  }

  // MARK: Jobs

  private func update(_ recording: TencentMeetingRecording) {
    let id = recording.recordFileID
    let isNew = state.recordings[id] == nil
    var job =
      state.recordings[id]
      ?? TencentMeetingRecordingJob(
        meetingID: recording.meetingID, type: recording.type, title: recording.title,
        permission: recording.permission, status: .pending)
    // Written by another version with a status this one does not know.
    guard job.status != .unrecognized else { return }
    job.meetingID = recording.meetingID
    job.subMeetingID = recording.subMeetingID ?? job.subMeetingID
    if recording.type != .other { job.type = recording.type }
    job.title = recording.title
    job.start = recording.start ?? job.start
    job.end = recording.end ?? job.end
    if recording.permission != .unknown { job.permission = recording.permission }
    job.pageURL = recording.pageURL?.absoluteString ?? job.pageURL
    job.hostUserID = recording.hostUserID ?? job.hostUserID
    let changed = recording.fingerprints.contains { source, value in
      job.fingerprints[source.rawValue].map { $0 != value } ?? false
    }
    for (source, value) in recording.fingerprints { job.fingerprints[source.rawValue] = value }

    if job.status == .imported || job.status == .skipped {
      // Added already, or left out by the owner: only a change of the
      // transcript at Tencent brings an imported one back.
      if job.status == .imported, changed, recording.isFetchable { reopen(&job) }
    } else if !recording.isReady {
      job.status = .waiting
    } else {
      switch recording.permission {
      case .canApply, .passwordRequired:
        job.status = .needsPermission
      case .closed, .deleted:
        job.status = .unavailable
      case .unknown:
        if isNew { job.status = .unavailable }
      case .canView:
        switch job.status {
        case .noContent, .failed, .covered:
          if changed { reopen(&job) }
        case .waiting, .needsPermission, .unavailable:
          // Finished, shared with the account, or open again. (A refusal
          // while fetching never makes a viewable recording 「申请查看」.)
          reopen(&job)
        case .pending, .imported, .skipped, .unrecognized:
          break
        }
      }
    }
    if job.status == .pending, skippedByAnswer(job) { job.status = .skipped }
    state.recordings[id] = job
  }

  private func reopen(_ job: inout TencentMeetingRecordingJob) {
    job.status = .pending
    job.attempts = 0
    job.transientFailures = 0
    job.nextAttempt = nil
    job.coveredBy = nil
  }

  /// One meeting, one transcript: a pending (or failed) recording is
  /// covered when a recording of the other kind of the same meeting, added
  /// or about to be (a text transcription is fetched before a cloud
  /// recording), spans `coverage` of it. A covered one is fetched after all
  /// when the one covering it turns out empty, unavailable or failed.
  private func applyCoverage() {
    for (id, job) in state.recordings where job.status == .covered {
      let cover = job.coveredBy.flatMap { state.recordings[$0] }
      if cover == nil || ![.imported, .pending].contains(cover!.status) {
        // Decided before writing: reading the state inside the write to
        // `state.recordings[id]` is an exclusivity violation (a crash).
        let status: TencentMeetingRecordingJob.Status = skippedByAnswer(job) ? .skipped : .pending
        state.recordings[id]?.status = status
        state.recordings[id]?.coveredBy = nil
      }
    }
    // A failed one is covered too, so its daily try stops once the other
    // kind of the same meeting is added.
    for (id, job) in state.recordings where job.status == .pending || job.status == .failed {
      let siblings = state.recordings.filter { otherID, other in
        otherID != id && other.meetingID == job.meetingID && other.type != job.type
          && other.type != .other && job.type != .other
          && Self.share(of: job, coveredBy: other) >= configuration.coverage
      }
      let cover =
        siblings.first { $0.value.status == .imported }
        ?? siblings.first {
          $0.value.status == .pending && $0.value.type == .textTranscription
            && job.type == .cloudRecording
        }
      if let cover {
        state.recordings[id]?.status = .covered
        state.recordings[id]?.coveredBy = cover.key
      }
    }
  }

  /// How much of `job`'s time `other` spans (0 when either has no times).
  static func share(of job: TencentMeetingRecordingJob, coveredBy other: TencentMeetingRecordingJob)
    -> Double
  {
    guard let start = job.start, let end = job.end, end > start, let otherStart = other.start,
      let otherEnd = other.end, otherEnd > otherStart
    else { return 0 }
    let overlap = min(end, otherEnd).timeIntervalSince(max(start, otherStart))
    return max(0, overlap) / end.timeIntervalSince(start)
  }

  /// Left out by the owner's answer 「不添加」 to the first question.
  private func skippedByAnswer(_ job: TencentMeetingRecordingJob) -> Bool {
    guard case .skip(let before) = state.backfill else { return false }
    return Self.isBefore(job, before)
  }

  static func isBefore(_ job: TencentMeetingRecordingJob, _ cutoff: Date) -> Bool {
    (job.end ?? job.start ?? .distantPast) < cutoff
  }

  /// Within the last `windowDays` (by its start).
  private func inWindow(_ job: TencentMeetingRecordingJob, now: Date) -> Bool {
    let start =
      calendar.date(byAdding: .day, value: -configuration.windowDays, to: now) ?? now
    return (job.start ?? job.end ?? .distantPast) >= start
  }

  /// The next recording to fetch: pending and due, or failed and due for
  /// its daily try while in the window; not waiting for the first answer;
  /// the newest first.
  private func nextDue(now: Date, excluding attempted: Set<String>) -> String? {
    state.recordings.filter { id, job in
      guard !attempted.contains(id), !waitsForAnswer(job),
        job.nextAttempt.map({ $0 <= now }) ?? true
      else { return false }
      return job.status == .pending || (job.status == .failed && inWindow(job, now: now))
    }
    .sorted { ($0.value.start ?? .distantPast, $0.key) > ($1.value.start ?? .distantPast, $1.key) }
    .first?.key
  }

  private func waitsForAnswer(_ job: TencentMeetingRecordingJob) -> Bool {
    guard case .notAsked = state.backfill else { return false }
    guard let connectedAt = state.connectedAt else { return true }
    return Self.isBefore(job, connectedAt)
  }

  // MARK: Fetching

  /// Fetches one recording's transcript and adds it. Returns a failure that
  /// stops the pass; anything else is the job's own.
  private func fetch(_ recording: TencentMeetingRecording, now: Date, report: inout Report) async
    -> TencentMeetingFailure?
  {
    let id = recording.recordFileID
    guard var job = state.recordings[id] else { return nil }

    // A run cut short after adding the item and before saving the job.
    if job.itemIDs.isEmpty {
      let first = TencentMeetingItem.id(recordFileID: id, version: 0, digest: nil)
      if await writer.existing([first]).contains(first) {
        job.itemIDs = [first.rawValue.uuidString]
        job.status = .imported
        state.recordings[id] = job
        return nil
      }
    }

    var pages: [Data] = []
    var parsed: [TencentMeetingTranscriptPage] = []
    var seen: Set<Int> = []
    var pid: String?
    for _ in 0..<configuration.maximumTranscriptPages {
      let command = TencentMeetingCommand.transcriptGet(
        recordFileID: id, meetingID: recording.meetingID, pid: pid,
        limit: TencentMeetingCommand.transcriptPageSize)
      guard spend(command, &report) else { return .rateLimited }
      let result = await runner.run(command, timeout: configuration.commandTimeout)
      var failure = TencentMeetingFailureReport(.unreadable)
      var read: TencentMeetingTranscriptPage?
      switch TencentMeetingOutput.data(result) {
      case .failure(let failed):
        failure = failed
      case .success(let data):
        if let coded = TencentMeetingOutput.dataFailure(data) {
          failure = coded
        } else {
          read = TencentMeetingTranscriptParser.page(data)
        }
      }
      guard let page = read else {
        if failure.failure.stopsPass {
          if failure.failure == .network || failure.failure == .timedOut {
            recordTransient(failure, on: &job, now: now, report: &report)
            state.recordings[id] = job
          }
          return failure.failure
        }
        record(failure, on: &job, now: now, report: &report)
        state.recordings[id] = job
        return nil
      }
      let fresh = page.paragraphs.filter { !seen.contains($0.pid) }
      pages.append(result.stdout)
      parsed.append(page)
      seen.formUnion(fresh.map(\.pid))
      // `--pid` is where the next page starts in Tencent's own order (that
      // paragraph included), which is not always by number: a page can end
      // 399, 398. So the next page starts at the last paragraph given, and
      // the one repeated is merged by its number.
      guard page.more, let last = page.paragraphs.last?.pid, !fresh.isEmpty else {
        return await add(
          recording, job: job, pages: pages, parsed: parsed, now: now, report: &report)
      }
      pid = String(last)
    }
    return await add(recording, job: job, pages: pages, parsed: parsed, now: now, report: &report)
  }

  private func add(
    _ recording: TencentMeetingRecording, job original: TencentMeetingRecordingJob, pages: [Data],
    parsed: [TencentMeetingTranscriptPage], now: Date, report: inout Report
  ) async -> TencentMeetingFailure? {
    var job = original
    let id = recording.recordFileID
    report.fetched += 1
    job.fetchedAt = now
    job.tmeetVersion = configuration.tmeetVersion
    job.transientFailures = 0
    let paragraphs = TencentMeetingTranscriptParser.merged(parsed).filter { !$0.text.isEmpty }
    guard !paragraphs.isEmpty else {
      job.status = .noContent
      job.lastError = .noContent
      report.noContent += 1
      state.recordings[id] = job
      return nil
    }
    let digest = TencentMeetingTranscriptParser.digest(paragraphs)
    job.paragraphs = paragraphs.count
    if !job.itemIDs.isEmpty {
      // Fetched again because the listing changed.
      let unchanged = job.contentDigest == nil || job.contentDigest == digest
      let ids = job.itemIDs.compactMap { UUID(uuidString: $0).map { SessionID($0) } }
      let kept = await writer.existing(ids)
      if unchanged || kept.isEmpty {
        // The same words; or the owner deleted what was added: that stands.
        job.contentDigest = job.contentDigest ?? digest
        job.status = .imported
        job.attempts = 0
        report.unchanged += 1
        state.recordings[id] = job
        return nil
      }
    }
    learnSpeakers(paragraphs, at: recording.start ?? job.start ?? now)
    let itemID = TencentMeetingItem.id(
      recordFileID: id, version: job.itemIDs.count, digest: digest)
    let text = TencentMeetingTranscriptText.readable(
      title: job.title, paragraphs: paragraphs, ownerUserIDs: Set(state.ownerUserIDs),
      labels: TencentMeetingSpeakers.labels(state.people))
    guard
      let source = TencentMeetingSourceDocument.encode(
        recording: recording, pages: pages, fetchedAt: now,
        tmeetVersion: configuration.tmeetVersion)
    else {
      record(TencentMeetingFailureReport(.unreadable), on: &job, now: now, report: &report)
      state.recordings[id] = job
      return nil
    }
    let item = TencentMeetingItem(
      id: itemID, capturedAt: recording.start ?? job.start ?? now, text: text, source: source)
    do {
      try await writer.add(item)
      report.added += 1
      state.addedToday += 1
    } catch TencentMeetingWriteError.alreadyThere {
      // Added by an earlier run.
    } catch {
      record(TencentMeetingFailureReport(.other), on: &job, now: now, report: &report)
      state.recordings[id] = job
      return nil
    }
    job.itemIDs.append(itemID.rawValue.uuidString)
    job.contentDigest = digest
    job.status = .imported
    job.attempts = 0
    job.nextAttempt = nil
    job.lastError = nil
    job.lastErrorCode = nil
    state.recordings[id] = job
    return nil
  }

  /// A recording's own failure: wait and retry; after `maximumAttempts`,
  /// once a day while it is in the window (or at once when it changes).
  private func record(
    _ failure: TencentMeetingFailureReport, on job: inout TencentMeetingRecordingJob, now: Date,
    report: inout Report
  ) {
    job.lastError = failure.failure
    job.lastErrorCode = failure.code
    job.transientFailures = 0
    switch failure.failure {
    case .noContent:
      job.status = .noContent
      report.noContent += 1
    case .noPermission where job.permission == .canApply || job.permission == .passwordRequired:
      job.status = .needsPermission
    default:
      // Including a refusal of a recording the listing says the account
      // may view: retried like any other failure, never shown as 「申请查看」.
      countAttempt(on: &job, now: now, generating: failure.failure == .generating, report: &report)
    }
  }

  private func countAttempt(
    on job: inout TencentMeetingRecordingJob, now: Date, generating: Bool, report: inout Report
  ) {
    job.attempts += 1
    if generating { report.generating += 1 }
    if job.attempts >= TencentMeetingRecordingJob.maximumAttempts {
      job.status = .failed
      job.nextAttempt = now.addingTimeInterval(configuration.failedRetryInterval)
    } else {
      job.status = .pending
      let delays = configuration.retryDelays
      job.nextAttempt = now.addingTimeInterval(delays[min(job.attempts - 1, delays.count - 1)])
    }
  }

  /// No network or a server error while fetching it: the pass stops and
  /// the recording keeps its place; only so many in a row count as one
  /// attempt (one whose transcript always fails this way cannot hold every
  /// pass up).
  private func recordTransient(
    _ failure: TencentMeetingFailureReport, on job: inout TencentMeetingRecordingJob, now: Date,
    report: inout Report
  ) {
    job.lastError = failure.failure
    job.lastErrorCode = failure.code
    job.transientFailures += 1
    if job.transientFailures >= configuration.transientFailuresPerAttempt {
      job.transientFailures = 0
      countAttempt(on: &job, now: now, generating: false, report: &report)
    }
  }

  // MARK: People

  /// Every speaker by user number: the names used, in how many recordings,
  /// the name it is written under. Then which of them is the account itself.
  private func learnSpeakers(_ paragraphs: [TencentMeetingParagraph], at date: Date) {
    TencentMeetingSpeakers.learn(paragraphs, at: date, people: &state.people)
    detectOwner()
  }

  /// Which user number is the account (written 「我」), by number first:
  ///
  /// 1. A host of the account's own recordings (`record list`'s
  ///    `host_user_id`, the same numbers as the speakers') that speaks
  ///    under the account's name.
  /// 2. The host of more than half of those meetings, while the account's
  ///    name is unknown or that number has not spoken yet.
  /// 3. The only number speaking under the account's name; when two do,
  ///    none (nobody is written 「我」).
  /// 4. Otherwise the number known so far stays — unless it was taken from
  ///    the host alone and has since spoken under other names only.
  private func detectOwner() {
    let name = state.accountName?.trimmingCharacters(in: .whitespaces)
    let accountName = (name?.isEmpty ?? true) ? nil : name
    var meetingsByHost: [String: Set<String>] = [:]
    for job in state.recordings.values {
      if let host = job.hostUserID { meetingsByHost[host, default: []].insert(job.meetingID) }
    }
    let hosted = meetingsByHost.mapValues(\.count)
    let meetings = meetingsByHost.values.reduce(into: Set<String>()) { $0.formUnion($1) }.count
    let named: Set<String> =
      accountName.map { name in Set(state.people.filter { $0.value.names.contains(name) }.keys) }
      ?? []
    func choose(_ id: String, _ evidence: TencentMeetingState.OwnerEvidence) {
      state.ownerUserIDs = [id]
      state.ownerEvidence = evidence
    }
    if let confirmed = named.filter({ hosted[$0] != nil })
      .max(by: { (hosted[$0] ?? 0, $1) < (hosted[$1] ?? 0, $0) })
    {
      return choose(confirmed, .hostAndName)
    }
    if let top = hosted.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
      top.value * 2 > meetings, accountName == nil || state.people[top.key] == nil
    {
      return choose(top.key, .host)
    }
    if named.count == 1, let only = named.first { return choose(only, .name) }
    if named.count > 1 {
      state.ownerUserIDs = []
      state.ownerEvidence = nil
      return
    }
    if state.ownerEvidence == .host, let accountName, let known = state.ownerUserIDs.first,
      let speaker = state.people[known], !speaker.names.contains(accountName)
    {
      state.ownerUserIDs = []
      state.ownerEvidence = nil
    }
  }

  // MARK: Budget and finish

  /// Counts a command's requests against the day's budget; listings stop
  /// short of the share kept for transcripts.
  private func spend(_ command: TencentMeetingCommand, _ report: inout Report) -> Bool {
    let limit =
      command.isListing
      ? configuration.dailyBudget - configuration.transcriptReserve : configuration.dailyBudget
    guard state.requestsToday + command.requests <= limit else { return false }
    state.requestsToday += command.requests
    report.calls += 1
    report.requests += command.requests
    return true
  }

  /// The counts of what waits (a snapshot of all jobs, not this pass's).
  private func tally(_ report: inout Report, now: Date) {
    for job in state.recordings.values {
      switch job.status {
      case .covered: report.covered += 1
      case .needsPermission: report.needsPermission += 1
      case .failed where inWindow(job, now: now): report.notAdded += 1
      case .pending where waitsForAnswer(job): report.waitingForAnswer += 1
      default: break
      }
    }
    let windowStart =
      calendar.date(byAdding: .day, value: -configuration.windowDays, to: now) ?? now
    report.truncatedMeetings =
      state.recordCounts.values.filter {
        $0.isIncomplete && ($0.start ?? now) >= windowStart
      }.count
  }

  private func finish(_ report: Report, failure: TencentMeetingFailure?, now: Date) -> Report {
    var report = report
    report.failure = failure
    tally(&report, now: now)
    state.lastFailure = failure
    if failure == nil {
      state.lastSuccess = now
      if report.kind == .full { state.lastFullPass = now }
    }
    if failure == .rateLimited {
      state.pausedUntil = calendar.nextDate(
        after: now, matching: DateComponents(hour: 0, minute: 5), matchingPolicy: .nextTime)
    }
    persist()
    return report
  }

  private func persist() { save(state) }

  static func dayKey(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }
}
