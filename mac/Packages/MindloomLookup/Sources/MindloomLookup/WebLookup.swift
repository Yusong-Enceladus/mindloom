import Foundation

/// 「从网络补充信息」: what the organizer's "what is missing" step calls.
///
/// One gap in, new web source items out, attached under the original item
/// (the original is never changed). Order (WEBSEARCH §4.2): public
/// identifiers (arXiv, Crossref); the conference deadline table, downloaded
/// whole and matched here, plus the conference's official page; a public
/// place (OpenStreetMap) or a public name (Wikipedia); then general search
/// through the services the owner added keys for, one at a time, the next
/// one only when the previous could not answer. Every word that leaves is
/// built here from public parts and passes `OutboundCheck`; every request
/// goes through `LookupEgress` and appears in 「网络活动」 without content.
public actor WebLookup {
  public nonisolated let activity: NetworkActivityLog
  let egress: LookupEgress
  let folder: LookupFolder?
  let keys: any SearchKeyStore
  let limits: LookupLimits
  let cache: LookupCache
  let services: SearchServiceStates
  let now: @Sendable () -> Date
  let dryRun: Bool
  let allowsReaderService: Bool
  let lookupSwitch: LookupSwitch
  private var learned = PublicNameDirectory()
  private var directory = PublicNameDirectory.bundled
  private var table: [ConferenceTableSource.Conference]?
  private var tableFetchedAt: Date?

  /// Pages read from search results; the first two with relevant text are
  /// kept.
  public static let pagesPerSearch = 3
  public static let keptPagesPerSearch = 2
  public static let maximumPageBytes = 5 * 1024 * 1024
  /// The fixed public word a new key is checked with.
  public static let keyCheckTerms = "Apple"

  /// `dataRoot` nil keeps everything in memory (tests). `dryRun` builds and
  /// checks every request and records what would be sent, sending nothing.
  /// `allowsReaderService`: a page this device cannot read (it needs a
  /// script) may be read by `r.jina.ai` with Do Not Track, only when a
  /// search service or the deadline table listed it (never a link the
  /// owner collected).
  public init(
    dataRoot: URL?, keys: any SearchKeyStore, device: String,
    transport: any LookupTransport = URLSessionLookupTransport(),
    resolver: any HostResolver = SystemHostResolver(), dryRun: Bool = false,
    allowsReaderService: Bool = true, now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
      try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
  ) {
    let folder = dataRoot.map { LookupFolder(dataRoot: $0) }
    self.folder = folder
    self.keys = keys
    self.now = now
    self.dryRun = dryRun
    self.allowsReaderService = allowsReaderService
    let lookupSwitch = LookupSwitch(folder: folder)
    self.lookupSwitch = lookupSwitch
    let activity = folder.map { NetworkActivityLog(folder: $0, now: now) } ?? NetworkActivityLog(fileURL: nil, now: now)
    self.activity = activity
    egress = LookupEgress(
      transport: transport, resolver: resolver, activity: activity, device: device, dryRun: dryRun,
      gate: lookupSwitch, now: now, sleep: sleep)
    limits = LookupLimits(fileURL: folder?.ledgerURL, now: now)
    cache = LookupCache(folder: folder?.cacheURL, now: now)
    services = SearchServiceStates(fileURL: folder?.servicesURL, now: now)
  }

  // MARK: Settings

  public func settings() -> WebLookupSettings {
    lookupSwitch.settings()
  }

  /// Turning the switch off also cancels the requests in flight; every
  /// later request checks the switch first (`LookupEgress`).
  public func update(_ settings: WebLookupSettings) async throws {
    try lookupSwitch.save(settings)
    if !settings.enabled { await egress.cancelInFlight() }
  }

  public func setEnabled(_ enabled: Bool) async throws {
    var current = settings()
    current.enabled = enabled
    try await update(current)
  }

  /// A public name the organizer found in a public page the owner collected.
  /// Not learned (false) when it is or contains one of the owner's words, a
  /// blocked word, a contact, a secret, money, a date, a house number or a
  /// long number. Even when learned, it never overrides the owner's words
  /// later: only the bundled list and the conference table do.
  @discardableResult
  public func learn(
    publicName: String, kind: LookupSubjectKind, officialSite: String? = nil, privateTerms: PrivateTerms
  ) -> Bool {
    let check = OutboundCheck(
      privateTerms: privateTerms, publicNames: directory, blockedTerms: settings().blockedTerms)
    guard check.learnedNameRefusal(publicName) == nil else { return false }
    learned.add(publicName, kind: kind, officialSite: officialSite, source: .collectedPublicPage)
    directory.merge(learned)
    return true
  }

  public func publicNames() -> PublicNameDirectory { directory }

  // MARK: Keys

  /// Checks a pasted key with one fixed public query to the chosen service
  /// (a 「验证密钥」 line in 「网络活动」) and stores it unless the service
  /// refused it.
  ///
  /// Not stored when the service refused the key, or when the switch is off
  /// (`.notAdded`: nothing was sent). Stored otherwise; when the check could
  /// not tell (the service failed, was busy, could not be reached), the
  /// status says so while that skip lasts (5 minutes, 30 minutes, or as long
  /// as the service asked); after it the status is `.ready` (「可用」) although
  /// no request has confirmed the key yet: the first real lookup does.
  public func addKey(_ key: String, for service: SearchServiceID) async -> SearchServiceCondition {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard SearchServiceID.isPlausibleKey(key) else { return .badKey }
    guard settings().enabled else { return .notAdded }
    let condition = await verify(key: key, service: service)
    guard condition != .badKey, condition != .notAdded else { return condition }
    do {
      try keys.save(key, for: service)
    } catch {
      return .failing
    }
    await services.forget(service)
    await limits.forgiveFailures(service: service.rawValue)
    switch condition {
    case .quotaUsed: await services.note(service, key: key, failure: .quotaUsed)
    case .unreachable: await services.noteUnreachable(service)
    case .failing: await services.note(service, key: key, failure: .server)
    case .rateLimited: await services.note(service, key: key, failure: .rateLimited(retryAfter: nil))
    default: break
    }
    return condition
  }

  public func removeKey(_ service: SearchServiceID) async throws {
    try keys.remove(service)
    await services.forget(service)
    await limits.forgiveFailures(service: service.rawValue)
  }

  public func statuses() async -> [SearchServiceStatus] {
    var result: [SearchServiceStatus] = []
    for service in SearchServiceID.fallbackOrder {
      let key = keys.key(for: service)
      let condition = await services.condition(service, key: key)
      result.append(
        SearchServiceStatus(
          service: service, condition: condition,
          syncsAcrossDevices: key != nil && keys.syncsAcrossDevices(service)))
    }
    return result
  }

  func verify(key: String, service: SearchServiceID) async -> SearchServiceCondition {
    var request = SearchAdapter.request(service, terms: Self.keyCheckTerms, key: key)
    request.kind = .keyCheck
    switch await egress.fetch(request) {
    case .failure(.off), .failure(.cancelled), .failure(.dryRun): return .notAdded
    case .failure(.cannotConnect), .failure(.timedOut): return .unreachable
    case .failure: return .failing
    case .success(let response):
      switch SearchAdapter.interpret(service, status: response.status, headers: response.headers, body: response.body) {
      case .hits(let hits):
        if hits.isEmpty { await egress.amend(response.activityID, result: .nothingFound) }
        return .ready
      case .failure(let failure):
        await egress.amend(response.activityID, result: .failed)
        switch failure {
        case .badKey: return .badKey
        case .quotaUsed: return .quotaUsed
        case .rateLimited: return .rateLimited
        case .server, .malformed: return .failing
        }
      }
    }
  }

  // MARK: Looking up a gap

  /// A health matter sends nothing at all (`LookupRequest.healthRelated`),
  /// before any request, the conference table included.
  public func lookUp(_ request: LookupRequest, privateTerms: PrivateTerms) async -> LookupOutcome {
    let settings = self.settings()
    guard settings.enabled else { return .off }
    if request.healthRelated {
      await egress.recordRefusal(kind: .search, service: "search", host: nil, refusal: .health)
      return .refused(.health)
    }
    switch LookupRouting.route(for: request, healthRelated: request.healthRelated) {
    case .lookUp, .askPersonAndLookUp: break
    case .askPerson, .neither: return .noSource
    }
    let outcome = await run(request, privateTerms: privateTerms, settings: settings)
    if dryRun {
      let planned = await egress.takePlanned()
      if !planned.isEmpty { return .planned(planned) }
    }
    return outcome
  }

  /// Reads a link the owner collected (no search, no words sent; the page
  /// only, read on this device, never through a reader service). The
  /// address passes the same checks as words: the owner's names, words and
  /// blocked words never go out in it, nor do trackers' and signed links'
  /// parameters; an address with a query or an opaque identifier is read
  /// only after the owner saw it and tapped 「查找」 (`approval` is that
  /// address). Redirects are followed on the link's own site only; one to
  /// another site comes back as `.needsApproval` with the new address.
  public func read(
    link: URL, parentItemID: UUID, matterID: UUID? = nil, privateTerms: PrivateTerms, healthRelated: Bool,
    approval: LookupApproval? = nil
  ) async -> LookupOutcome {
    let settings = self.settings()
    guard settings.enabled else { return .off }
    if healthRelated {
      await egress.recordRefusal(kind: .page, service: "page", host: nil, refusal: .health)
      return .refused(.health)
    }
    let check = OutboundCheck(
      privateTerms: privateTerms, publicNames: directory, blockedTerms: settings.blockedTerms,
      blockedSites: settings.blockedSites)
    let target: URL
    switch check.check(collectedLink: link, approval: approval) {
    case .refuse(let refusal):
      await egress.recordRefusal(kind: .page, service: "page", host: link.host?.lowercased(), refusal: refusal)
      return .refused(refusal)
    case .needsApproval(let address):
      return .needsApproval(terms: address)
    case .read(let url):
      target = url
    }
    let attempt = await readPage(
      target, origin: .collectedLink, parentItemID: parentItemID, matterID: matterID, gap: nil, focus: [],
      check: check, officialSite: nil, readerService: false, fallbackTitle: nil)
    switch attempt {
    case .item(let item): return .found([item])
    case .refused(let refusal): return .refused(refusal)
    case .needsApproval(let address): return .needsApproval(terms: address)
    case .planned: return .planned(await egress.takePlanned())
    case .off: return .off
    case .cancelled: return .cancelled
    case .irrelevant, .failed: return .nothingFound
    }
  }

  static func isFinal(_ outcome: LookupOutcome) -> Bool {
    switch outcome {
    case .found, .needsApproval, .refused, .limited, .off, .planned, .cancelled: true
    case .nothingFound, .noSource: false
    }
  }

  /// The switch was turned off or the caller cancelled: stop here.
  private func interruption() -> LookupOutcome? {
    if !lookupSwitch.isOn { return .off }
    if Task.isCancelled { return .cancelled }
    return nil
  }

  private func run(_ request: LookupRequest, privateTerms: PrivateTerms, settings: WebLookupSettings) async
    -> LookupOutcome
  {
    // The table names several hundred public conferences; it is needed to
    // match a conference and to know whether an unknown venue is public.
    if let subject = request.subject, [.conference, .journal, .other].contains(subject.kind),
      subject.kind == .conference || !directory.contains(subject.name)
    {
      _ = await conferenceTable()
      if let stop = interruption() { return stop }
    }
    let check = OutboundCheck(
      privateTerms: privateTerms, publicNames: directory, blockedTerms: settings.blockedTerms,
      blockedSites: settings.blockedSites)
    var fallback = LookupOutcome.noSource

    if !request.identifiers.isEmpty {
      let result = await lookUpIdentifiers(request, check: check)
      if Self.isFinal(result) || request.subject == nil { return result }
      fallback = result
      if let stop = interruption() { return stop }
    }
    guard let subject = request.subject else { return fallback }

    let conferenceGaps: Set<LookupGap> = [.deadline, .callForPapers, .eventDates]
    if conferenceGaps.contains(request.gap), [.conference, .journal, .other].contains(subject.kind) {
      if let result = await lookUpConference(request, check: check) { return result }
      if let stop = interruption() { return stop }
    }
    if subject.kind == .place, [.address, .openingHours, .overview].contains(request.gap) {
      let result = await lookUpPlace(request, check: check)
      if Self.isFinal(result) { return result }
      if result == .nothingFound { fallback = .nothingFound }
      if let stop = interruption() { return stop }
    }
    if request.gap == .overview, subject.kind != .place {
      let result = await lookUpOverview(request, check: check)
      if Self.isFinal(result) { return result }
      if result == .nothingFound { fallback = .nothingFound }
      if let stop = interruption() { return stop }
    }
    let searched = await search(request, check: check)
    if searched == .noSource { return fallback }
    return searched
  }

  // MARK: Identifiers

  private func lookUpIdentifiers(_ request: LookupRequest, check: OutboundCheck) async -> LookupOutcome {
    var items: [WebSourceItem] = []
    var refusal: OutboundRefusal?
    var limit: LookupLimit?
    for identifier in request.identifiers.prefix(LookupLimits.perGap) {
      let source: PublicSourceID = {
        if case .arXiv = identifier { return .arXiv }
        return .crossref
      }()
      let value: String
      switch check.check(identifier: identifier) {
      case .failure(let reason):
        refusal = reason
        await egress.recordRefusal(kind: .publicSource, service: source.rawValue, host: nil, refusal: reason)
        continue
      case .success(let id):
        value = id
      }
      let egressRequest = source == .arXiv ? ArXivSource.request(id: value) : CrossrefSource.request(doi: value)
      let fetched = await fetchCached(
        egressRequest, cacheKey: "\(source.rawValue)|\(value)", keepFor: LookupCache.paper, request: request)
      let body: Data
      let retrievedAt: Date
      switch fetched {
      case .planned: return .planned(await egress.takePlanned())
      case .off: return .off
      case .cancelled: return .cancelled
      case .limited(let reason):
        limit = reason
        continue
      case .failed: continue
      case .body(let data, let date, _):
        body = data
        retrievedAt = date
      }
      let record = source == .arXiv ? ArXivSource.parse(body, id: value) : CrossrefSource.parse(body, doi: value)
      guard let record else {
        if case .body(_, _, let activityID?) = fetched { await egress.amend(activityID, result: .nothingFound) }
        continue
      }
      if let venue = record.venue, !venue.isEmpty, check.learnedNameRefusal(venue) == nil {
        learned.add(venue, kind: .journal, source: .publicRecord)
        directory.merge(learned)
      }
      items.append(
        WebSourceItem(
          parentItemID: request.parentItemID, matterID: request.matterID, gap: request.gap, title: record.title,
          requestedURL: egressRequest.url, finalURL: record.pageURL, retrievedAt: retrievedAt,
          retrievedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
          origin: .publicSource(source, query: value), reader: .structured(source), authority: .official,
          contentType: source == .arXiv ? "application/atom+xml" : "application/json", text: record.text,
          excerpt: Excerpts.select(from: record.text, focus: []), raw: body))
    }
    if !items.isEmpty { return .found(items) }
    if let refusal { return .refused(refusal) }
    if let limit { return .limited(limit) }
    return .nothingFound
  }

  // MARK: Conference table

  /// The table and when it was downloaded: a copy younger than a day, else
  /// a new download, else an older copy.
  private func conferenceTable() async -> [ConferenceTableSource.Conference]? {
    if let table, let tableFetchedAt, now().timeIntervalSince(tableFetchedAt) < LookupCache.table { return table }
    if let body = await cache.body("conference-table"), let stamp = await cache.body("conference-table-fetched"),
      let fetched = ISO8601DateFormatter().date(from: String(decoding: stamp, as: UTF8.self))
    {
      installTable(ConferenceTableSource.parse(body), fetchedAt: fetched)
      if table != nil { return table }
    }
    if interruption() != nil { return table }
    switch await egress.fetch(ConferenceTableSource.request()) {
    case .success(let response) where response.isSuccess && !response.truncated:
      let parsed = ConferenceTableSource.parse(response.body)
      if !parsed.isEmpty {
        await cache.store(response.body, for: "conference-table", keepFor: LookupCache.table)
        await cache.store(
          Data(ISO8601DateFormatter().string(from: response.retrievedAt).utf8), for: "conference-table-fetched",
          keepFor: 365 * 86_400)
        installTable(parsed, fetchedAt: response.retrievedAt)
        return table
      }
      await egress.amend(response.activityID, result: .failed)
    default:
      break
    }
    if let body = await cache.body("conference-table", stale: true) {
      let stamp = await cache.body("conference-table-fetched", stale: true)
      let fetched = stamp.flatMap { ISO8601DateFormatter().date(from: String(decoding: $0, as: UTF8.self)) }
      installTable(ConferenceTableSource.parse(body), fetchedAt: fetched ?? now())
    }
    return table
  }

  private func installTable(_ conferences: [ConferenceTableSource.Conference], fetchedAt: Date) {
    guard !conferences.isEmpty else { return }
    table = conferences
    tableFetchedAt = fetchedAt
    var names = PublicNameDirectory.bundled
    names.merge(ConferenceTableSource.names(conferences))
    names.merge(learned)
    directory = names
  }

  /// nil: the table does not list this conference (the caller goes on).
  private func lookUpConference(_ request: LookupRequest, check: OutboundCheck) async -> LookupOutcome? {
    guard let subject = request.subject, let table = await conferenceTable(),
      let match = ConferenceTableSource.match(table, name: subject.name, year: request.year, now: now())
    else { return nil }
    let (conference, edition) = match
    let text = ConferenceTableSource.text(conference, edition)
    var items = [
      WebSourceItem(
        parentItemID: request.parentItemID, matterID: request.matterID, gap: request.gap,
        title: "\(conference.title) \(edition.year)", requestedURL: ConferenceTableSource.url,
        finalURL: URL(string: "https://ccfddl.com/")!, retrievedAt: tableFetchedAt ?? now(),
        retrievedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
        origin: .publicSource(.conferenceTable, query: conference.title), reader: .structured(.conferenceTable),
        authority: .reference, contentType: "text/plain", text: text, excerpt: text, raw: Data(text.utf8))
    ]
    if let link = edition.link, let url = URL(string: link) {
      var focusRequest = request
      focusRequest.year = edition.year
      let attempt = await readPage(
        url, origin: .linkedFrom(.conferenceTable), parentItemID: request.parentItemID, matterID: request.matterID,
        gap: request.gap, focus: Excerpts.focus(for: focusRequest), check: check, officialSite: url.host,
        readerService: allowsReaderService, fallbackTitle: "\(conference.title) \(edition.year)")
      switch attempt {
      case .item(let item): items.append(item)
      case .planned: return .planned(await egress.takePlanned())
      case .off: return .off
      case .cancelled: return .cancelled
      default: break
      }
    }
    return .found(items)
  }

  // MARK: Names and places

  private func nameTerms(_ request: LookupRequest, check: OutboundCheck) -> OutboundVerdict {
    var nameRequest = request
    nameRequest.year = nil
    return check.terms(for: nameRequest, includePhrase: false)
  }

  private func lookUpPlace(_ request: LookupRequest, check: OutboundCheck) async -> LookupOutcome {
    let name: String
    switch nameTerms(request, check: check) {
    case .refuse(let reason):
      await egress.recordRefusal(kind: .publicSource, service: PublicSourceID.openStreetMap.rawValue, host: nil, refusal: reason)
      return .refused(reason)
    case .needsApproval(let terms):
      return request.approval == nil ? .needsApproval(terms: terms) : .noSource
    case .send(let terms):
      name = terms
    }
    let egressRequest = OpenStreetMapSource.request(name: name)
    switch await fetchCached(egressRequest, cacheKey: "nominatim|\(name)", keepFor: LookupCache.week, request: request) {
    case .planned: return .planned(await egress.takePlanned())
    case .off: return .off
    case .cancelled: return .cancelled
    case .limited(let reason): return .limited(reason)
    case .failed: return .nothingFound
    case .body(let body, let retrievedAt, let activityID):
      guard let place = OpenStreetMapSource.parse(body) else {
        if let activityID { await egress.amend(activityID, result: .nothingFound) }
        return .nothingFound
      }
      let text = place.text
      return .found([
        WebSourceItem(
          parentItemID: request.parentItemID, matterID: request.matterID, gap: request.gap, title: place.name,
          requestedURL: egressRequest.url, finalURL: place.pageURL, retrievedAt: retrievedAt,
          retrievedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
          origin: .publicSource(.openStreetMap, query: name), reader: .structured(.openStreetMap),
          authority: .reference, contentType: "application/json", text: text, excerpt: text, raw: body)
      ])
    }
  }

  private func lookUpOverview(_ request: LookupRequest, check: OutboundCheck) async -> LookupOutcome {
    let name: String
    switch nameTerms(request, check: check) {
    case .refuse(let reason):
      await egress.recordRefusal(kind: .publicSource, service: PublicSourceID.wikipedia.rawValue, host: nil, refusal: reason)
      return .refused(reason)
    case .needsApproval(let terms):
      return request.approval == nil ? .needsApproval(terms: terms) : .noSource
    case .send(let terms):
      name = terms
    }
    let chinese = OutboundCheck.containsHan(name)
    let egressRequest = WikipediaSource.request(name: name, chinese: chinese)
    let cacheKey = "wikipedia|\(chinese ? "zh" : "en")|\(name)"
    switch await fetchCached(egressRequest, cacheKey: cacheKey, keepFor: LookupCache.week, request: request) {
    case .planned: return .planned(await egress.takePlanned())
    case .off: return .off
    case .cancelled: return .cancelled
    case .limited(let reason): return .limited(reason)
    case .failed: return .nothingFound
    case .body(let body, let retrievedAt, let activityID):
      guard let summary = WikipediaSource.parse(body) else {
        if let activityID { await egress.amend(activityID, result: .nothingFound) }
        return .nothingFound
      }
      // Wikipedia's text is CC BY-SA 4.0: the item names it and links the page.
      let text = [summary.title, summary.description, summary.extract, "维基百科，CC BY-SA 4.0"].compactMap { $0 }
        .filter { !$0.isEmpty }.joined(separator: "\n")
      let cleaned = TextCleaner.clean(text)
      return .found([
        WebSourceItem(
          parentItemID: request.parentItemID, matterID: request.matterID, gap: request.gap, title: summary.title,
          requestedURL: egressRequest.url, finalURL: summary.pageURL, retrievedAt: retrievedAt,
          retrievedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
          origin: .publicSource(.wikipedia, query: name), reader: .structured(.wikipedia), authority: .reference,
          contentType: "application/json", text: cleaned, excerpt: cleaned, raw: body)
      ])
    }
  }

  // MARK: Search

  private func search(_ request: LookupRequest, check: OutboundCheck) async -> LookupOutcome {
    let terms: String
    switch check.terms(for: request) {
    case .refuse(let reason):
      await egress.recordRefusal(kind: .search, service: "search", host: nil, refusal: reason)
      return .refused(reason)
    case .needsApproval(let words):
      return request.approval == nil ? .needsApproval(terms: words) : .noSource
    case .send(let words):
      terms = words
    }
    let candidates = SearchServiceID.order(chineseFirst: OutboundCheck.containsHan(terms)).compactMap { service in
      keys.key(for: service).map { (service, $0) }
    }
    guard !candidates.isEmpty else { return .noSource }

    // The same words within a week: the results already found.
    if let cached = await cache.body("search|\(terms)"),
      let stored = try? JSONDecoder().decode(CachedSearch.self, from: cached)
    {
      if stored.hits.isEmpty { return .nothingFound }
      return await readResults(stored.hits, service: stored.service, terms: terms, request: request, check: check)
    }

    var emptyAnswers = 0
    var answered = false
    chain: for (service, key) in candidates {
      if let stop = interruption() { return stop }
      guard await services.usable(service, key: key) else { continue }
      if let limit = await limits.limit(for: request) { return answered ? .nothingFound : .limited(limit) }
      let result = await egress.fetch(SearchAdapter.request(service, terms: terms, key: key))
      let response: EgressResponse
      switch result {
      case .failure(.dryRun): return .planned(await egress.takePlanned())
      case .failure(.off): return .off
      case .failure(.cancelled):
        // The caller gave up: no service is to blame and nothing is counted.
        return .cancelled
      case .failure(.cannotConnect), .failure(.refused):
        // Nothing arrived anywhere: the next service, without counting it.
        await services.noteUnreachable(service)
        continue
      case .failure(.timedOut):
        await limits.record(request, service: service.rawValue, failed: true)
        await services.noteUnreachable(service)
        continue
      case .failure:
        // Sent, but no answer came back whole (a connection lost
        // mid-request, too many redirects): counted.
        await limits.record(request, service: service.rawValue, failed: true)
        await services.note(service, key: key, failure: .server)
        continue
      case .success(let value):
        response = value
      }
      switch SearchAdapter.interpret(service, status: response.status, headers: response.headers, body: response.body) {
      case .failure(let failure):
        await limits.record(request, service: service.rawValue, failed: true)
        await egress.amend(response.activityID, result: .failed)
        await services.note(service, key: key, failure: failure)
        continue
      case .hits(let hits):
        await limits.record(request, service: service.rawValue, failed: false)
        answered = true
        await services.noteAnswered(service)
        if hits.isEmpty {
          await egress.amend(response.activityID, result: .nothingFound)
          emptyAnswers += 1
          // No results: one more service at most.
          if emptyAnswers >= 2 { break chain }
          continue
        }
        if let data = try? JSONEncoder().encode(CachedSearch(service: service, hits: hits)) {
          await cache.store(data, for: "search|\(terms)", keepFor: LookupCache.week)
        }
        let outcome = await readResults(hits, service: service, terms: terms, request: request, check: check)
        if outcome == .nothingFound { await egress.amend(response.activityID, result: .nothingFound) }
        return outcome
      }
    }
    if emptyAnswers > 0, let data = try? JSONEncoder().encode(CachedSearch(service: candidates[0].0, hits: [])) {
      await cache.store(data, for: "search|\(terms)", keepFor: LookupCache.week)
    }
    return answered ? .nothingFound : .noSource
  }

  struct CachedSearch: Codable {
    var service: SearchServiceID
    var hits: [SearchHit]
  }

  /// Reads the best few results: the official site first, then sites of
  /// institutions, then the service's order.
  private func readResults(
    _ hits: [SearchHit], service: SearchServiceID, terms: String, request: LookupRequest, check: OutboundCheck
  ) async -> LookupOutcome {
    let site = officialSite(for: request)
    let ranked = hits.sorted { a, b in
      let left = (Self.isOfficial(a.url.host, site: site) ? 0 : 1, Self.isInstitution(a.url.host) ? 0 : 1, a.rank)
      let right = (Self.isOfficial(b.url.host, site: site) ? 0 : 1, Self.isInstitution(b.url.host) ? 0 : 1, b.rank)
      return left < right
    }
    var items: [WebSourceItem] = []
    let focus = Excerpts.focus(for: request)
    for hit in ranked.prefix(Self.pagesPerSearch) where items.count < Self.keptPagesPerSearch {
      let attempt = await readPage(
        hit.url, origin: .search(service: service, terms: terms, rank: hit.rank), parentItemID: request.parentItemID,
        matterID: request.matterID, gap: request.gap, focus: focus, check: check, officialSite: site,
        readerService: allowsReaderService, fallbackTitle: hit.title)
      switch attempt {
      case .item(let item): items.append(item)
      case .planned: return .planned(await egress.takePlanned())
      case .off: return items.isEmpty ? .off : .found(items)
      case .cancelled: return items.isEmpty ? .cancelled : .found(items)
      default: continue
      }
    }
    return items.isEmpty ? .nothingFound : .found(items)
  }

  private func officialSite(for request: LookupRequest) -> String? {
    if let site = request.officialSite, !site.isEmpty { return site }
    guard let name = request.subject?.name else { return nil }
    return directory.entry(for: name)?.officialSite
  }

  static func isOfficial(_ host: String?, site: String?) -> Bool {
    guard var host = host?.lowercased(), var site = site?.lowercased(), !site.isEmpty else { return false }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    if site.hasPrefix("www.") { site.removeFirst(4) }
    return host == site || host.hasSuffix("." + site)
  }

  static func isInstitution(_ host: String?) -> Bool {
    guard let host = host?.lowercased() else { return false }
    return [".edu", ".gov", ".org", ".edu.cn", ".gov.cn", ".org.cn", ".ac.cn", ".ac.uk", ".edu.sg", ".gov.sg"]
      .contains(where: { host.hasSuffix($0) })
  }

  // MARK: Fetching

  enum Fetched {
    case body(Data, retrievedAt: Date, activityID: UUID?)
    case limited(LookupLimit)
    case planned
    case off
    case cancelled
    case failed
  }

  /// A request that carries words: answered from the cache when the same
  /// words were sent recently (dated when they were fetched), otherwise
  /// within the limits.
  private func fetchCached(
    _ egressRequest: EgressRequest, cacheKey: String, keepFor seconds: TimeInterval, request: LookupRequest
  ) async -> Fetched {
    if let cached = await cache.entry(cacheKey) {
      return .body(cached.body, retrievedAt: cached.fetchedAt ?? now(), activityID: nil)
    }
    if let stop = interruption() { return stop == .off ? .off : .cancelled }
    if let limit = await limits.limit(for: request) { return .limited(limit) }
    switch await egress.fetch(egressRequest) {
    case .failure(.dryRun): return .planned
    case .failure(.off): return .off
    case .failure(.cancelled): return .cancelled
    case .failure(.cannotConnect), .failure(.refused): return .failed
    case .failure:
      await limits.record(request, service: egressRequest.service, failed: true)
      return .failed
    case .success(let response):
      guard response.isSuccess, !response.truncated else {
        await limits.record(request, service: egressRequest.service, failed: true)
        return .failed
      }
      await limits.record(request, service: egressRequest.service, failed: false)
      await cache.store(response.body, for: cacheKey, keepFor: seconds, fetchedAt: response.retrievedAt)
      return .body(response.body, retrievedAt: response.retrievedAt, activityID: response.activityID)
    }
  }

  enum PageAttempt {
    case item(WebSourceItem)
    /// Read, but nothing on it is about the gap.
    case irrelevant
    case refused(OutboundRefusal)
    /// A collected link redirected to another site: the owner sees this
    /// address first.
    case needsApproval(String)
    case planned
    case off
    case cancelled
    case failed
  }

  private func readPage(
    _ url: URL, origin: WebSourceOrigin, parentItemID: UUID, matterID: UUID?, gap: LookupGap?, focus: [String],
    check: OutboundCheck, officialSite: String?, readerService: Bool, fallbackTitle: String?
  ) async -> PageAttempt {
    let collected = origin == .collectedLink
    let request = EgressRequest(
      url: url, headers: ["Accept": "text/html,application/xhtml+xml,application/pdf;q=0.9,text/plain;q=0.8"],
      kind: .page, service: "page", maximumBytes: Self.maximumPageBytes, timeout: 20, followRedirects: true,
      sameSiteRedirectsOnly: collected)
    let response: EgressResponse
    switch await egress.fetch(request, addressCheck: check) {
    case .failure(.dryRun): return .planned
    case .failure(.off): return .off
    case .failure(.cancelled): return .cancelled
    case .failure(.refused(let reason)): return .refused(reason)
    case .failure(.offSiteRedirect(let next)):
      switch check.check(collectedLink: next, approval: nil) {
      case .refuse(let reason):
        await egress.recordRefusal(kind: .page, service: "page", host: next.host?.lowercased(), refusal: reason)
        return .refused(reason)
      case .needsApproval(let address): return .needsApproval(address)
      case .read(let clean): return .needsApproval(clean.absoluteString)
      }
    case .failure:
      return readerService
        ? await readThroughService(url, origin: origin, parentItemID: parentItemID, matterID: matterID, gap: gap, focus: focus, check: check, officialSite: officialSite, fallbackTitle: fallbackTitle)
        : .failed
    case .success(let value):
      response = value
    }
    // Read off this actor, within a time limit: a heavy or hostile page
    // never holds Settings or the switch.
    let page = response.isSuccess
      ? await PageReader.readConcurrently(response.body, contentType: response.headers["content-type"], focus: focus)
      : nil
    if Task.isCancelled { return .cancelled }
    guard let page, PageReader.isReadable(page.text) || (page.contentType != "text/html" && !page.text.isEmpty)
    else {
      if !response.isSuccess || page == nil { await egress.amend(response.activityID, result: .failed) }
      return readerService
        ? await readThroughService(url, origin: origin, parentItemID: parentItemID, matterID: matterID, gap: gap, focus: focus, check: check, officialSite: officialSite, fallbackTitle: fallbackTitle ?? page?.title)
        : .failed
    }
    // The excerpt is chosen from the text as it is stored, so every quoted
    // passage is in the stored text.
    let text = String(page.text.prefix(WebSourceItem.maximumTextCharacters))
    let excerpt = Excerpts.select(from: text, focus: focus)
    if excerpt.isEmpty {
      await egress.amend(response.activityID, result: .nothingFound)
      return .irrelevant
    }
    let title = page.title.isEmpty ? (fallbackTitle ?? response.finalURL.host ?? "") : page.title
    return .item(
      WebSourceItem(
        parentItemID: parentItemID, matterID: matterID, gap: gap, title: title, requestedURL: url,
        finalURL: response.finalURL, retrievedAt: response.retrievedAt,
        retrievedUptimeNanoseconds: response.uptimeNanoseconds, origin: origin,
        reader: .onDevice(extractor: page.extractor),
        authority: Self.isOfficial(response.finalURL.host, site: officialSite) ? .official : .other,
        contentType: page.contentType, text: text, excerpt: excerpt, raw: response.body))
  }

  /// `r.jina.ai` reads a page this device could not (it needs a script),
  /// with Do Not Track (Jina then neither caches nor logs it). Only for
  /// addresses a public index already lists.
  private func readThroughService(
    _ url: URL, origin: WebSourceOrigin, parentItemID: UUID, matterID: UUID?, gap: LookupGap?, focus: [String],
    check: OutboundCheck, officialSite: String?, fallbackTitle: String?
  ) async -> PageAttempt {
    guard allowsReaderService else { return .failed }
    if case .collectedLink = origin { return .failed }
    guard case .success(let target) = check.check(address: url),
      let readerURL = URL(string: "https://r.jina.ai/" + target.absoluteString)
    else { return .failed }
    let request = EgressRequest(
      url: readerURL, headers: ["DNT": "1", "X-Return-Format": "text", "Accept": "text/plain"],
      kind: .readerService, service: "jina", maximumBytes: Self.maximumPageBytes, timeout: 30)
    let response: EgressResponse
    switch await egress.fetch(request) {
    case .failure(.off): return .off
    case .failure(.cancelled): return .cancelled
    case .failure(.dryRun): return .planned
    case .failure: return .failed
    case .success(let value): response = value
    }
    guard response.isSuccess, let decoded = PageReader.decode(response.body, contentType: "text/plain; charset=utf-8")
    else { return .failed }
    let text = String(TextCleaner.clean(decoded).prefix(WebSourceItem.maximumTextCharacters))
    guard PageReader.isReadable(text) else {
      await egress.amend(response.activityID, result: .nothingFound)
      return .failed
    }
    let excerpt = Excerpts.select(from: text, focus: focus)
    if excerpt.isEmpty {
      await egress.amend(response.activityID, result: .nothingFound)
      return .irrelevant
    }
    return .item(
      WebSourceItem(
        parentItemID: parentItemID, matterID: matterID, gap: gap, title: fallbackTitle ?? target.host ?? "",
        requestedURL: url, finalURL: target, retrievedAt: response.retrievedAt,
        retrievedUptimeNanoseconds: response.uptimeNanoseconds, origin: origin,
        reader: .readerService(host: "r.jina.ai"),
        authority: Self.isOfficial(target.host, site: officialSite) ? .official : .other, contentType: "text/plain",
        text: text, excerpt: excerpt, raw: response.body))
  }
}

