import CryptoKit
import Foundation
import MindloomLink

// v8 contracts B and C on the member Mac: one member id per Mac on its
// Spark, the durable share outbox, meeting parts with their audio,
// snapshots, a member's further Macs, org admins and key escrow with the
// takeover, encrypted backups and restore, handover packs.

/// What one pass over a space's outbox did.
public struct SpaceOutboxFlush: Equatable, Sendable {
  /// Entry id → the item it shared (nil for another op).
  public var done: [String: String?] = [:]
  /// Entry id → why the Spark refused it for good.
  public var dropped: [String: String] = [:]
  /// Still waiting (the link is down, or the Spark said "later").
  public var pending: [String] = []
  public var linkDown = false
}

/// A handover pack as the Spark answers it (`GET …/handover-pack/{id}`);
/// every text is still masked (placeholders) until a member's Mac puts the
/// numbers back.
public struct SpaceHandoverPack: Equatable, Sendable {
  public let packID: String
  public let matterID: String?
  /// `queued`, `running`, `ready`, `failed`.
  public let status: String
  public let error: String?
  public let pack: SpaceJSON?
  public let markdown: String?
  public let sources: [String]

  public var isReady: Bool { status == "ready" && markdown != nil }

  public init(_ json: SpaceJSON) {
    packID = json["pack_id"]?.string ?? ""
    matterID = json["event_id"]?.string
    status = json["status"]?.string ?? "queued"
    error = json["error"]?.string
    pack = json["pack"]
    markdown = json["markdown"]?.string
    sources = (json["pack"]?["sources"]?.object?.keys).map { Array($0).sorted() } ?? []
  }
}

/// A member Mac's check of an audio part before it plays it (the Spark
/// cannot look inside; `space_member.audio_part_ok`): the sound is as long
/// as the part the signed op declares (±2 s), a part of the recording and
/// at most 15 minutes. Anything else is not played.
public enum SpaceAudioCheck {
  public static let toleranceMS = 2_000

  /// Review V8R-15: a part is at most 4/5 of its recording (being only 1 ms
  /// shorter used to count, which is a whole short meeting). The Spark and
  /// every receiving Mac hold the same rule.
  public static func isPart(lengthMS: Int, recordingMS: Int) -> Bool {
    lengthMS > 0 && lengthMS * 5 <= recordingMS * 4
  }

  public static func ok(durationMS: Int, segment: SpaceSegmentRef) -> Bool {
    guard let whole = segment.recordingMS else { return false }
    let length = segment.lengthMS
    return length <= SpaceEngine.maximumSegmentMS && isPart(lengthMS: length, recordingMS: whole)
      && abs(durationMS - length) <= toleranceMS
  }
}

extension SpaceEngine {
  // MARK: - One member id per Mac

  /// This Mac's member id on its Spark (v8: one device id is one member on
  /// the whole Spark). Made once; an enrolled Mac takes its access record's.
  public func memberIdentity() throws -> String {
    if let id = try states.identity() { return id }
    let existing = try states.states().filter { $0.membership == .active }.map(\.memberID)
    let id = existing.first ?? SpaceID.new()
    try states.setIdentity(id)
    return id
  }

  public func setMemberIdentity(_ memberID: String) throws {
    try states.setIdentity(memberID.lowercased())
  }

  // MARK: - The organization's signed log

  func refreshOrgRoster(_ state: inout SpaceLocalState, orgID: String, force: Bool) async {
    if !force, let at = orgFetchedAt[orgID], now().timeIntervalSince(at) < 300 { return }
    orgFetchedAt[orgID] = now()
    // Only an org admin's device can read it; a plain member keeps none.
    if let roster = await orgRoster(orgID, commitment: state.orgGenesis) {
      state.orgRoster = roster
    } else if orgLogRefused.contains(orgID.lowercased()) {
      // The Spark served an organization log this Mac cannot believe: none
      // of its devices is trusted for a takeover or an escrow wrap.
      state.orgRoster = nil
      state.warn("org_log_forked")
    }
  }

  /// The org's roster from its own signed log, fresh (nil: this device is
  /// not an org admin's, or the log does not continue what this Mac pinned).
  ///
  /// Review V8R-02: the log must start with the `org.create` this Mac pinned
  /// (when it created the organization, or the first time it read the log,
  /// checked against an org space's signed `owner.org_genesis` when given)
  /// and continue the chain of the ops it accepted before; anything else (a
  /// second `org.create`, a rewritten history) is refused, and no space key
  /// is ever wrapped to a device of such a log.
  public func orgRoster(_ orgID: String, commitment: String? = nil) async -> SpaceOrgRoster? {
    let id = orgID.lowercased()
    guard let entries = try? await client.orgLog(id) else { return nil }
    orgFetchedAt[id] = now()
    let sorted = entries.sorted { $0.seq < $1.seq }
    var pins = (try? states.orgPins()) ?? [:]
    var commitments = Set(
      ((try? states.states()) ?? []).filter { $0.orgID == id }.compactMap(\.orgGenesis))
    if let commitment { commitments.insert(commitment) }
    let next: SpaceOrgPin?
    if let pin = pins[id] {
      next = commitments.allSatisfy { $0 == pin.genesisHash } ? pin.advanced(by: sorted) : nil
    } else if let first = SpaceOrgPin.genesis(orgID: id, entries: sorted),
      commitments.allSatisfy({ $0 == first.genesisHash })
    {
      next = first.advanced(by: sorted)
    } else {
      next = nil
    }
    let roster = SpaceOrgRoster(orgID: id, entries: sorted)
    guard let next, !roster.admins.isEmpty else {
      orgLogRefused.insert(id)
      return nil
    }
    orgLogRefused.remove(id)
    pins[id] = next
    try? states.setOrgPins(pins)
    return roster
  }

  /// Whether the Spark's log of this organization was refused (V8R-02).
  public func orgLogForked(_ orgID: String) -> Bool { orgLogRefused.contains(orgID.lowercased()) }

  /// Escrow wraps of a new key (v8 B5): one for each active admin device of
  /// the organization, as its signed log names them, that gets no member
  /// wrap. Empty when this Mac cannot read the org's log (then the Spark
  /// says `escrow_required` if the policy needs more).
  func escrowWraps(
    orgID: String, key: Data, spaceID: String, epoch: Int, memberDevices: Set<String>
  ) async throws -> [SpaceJSON] {
    guard let org = await orgRoster(orgID) else { return [] }
    var out: [SpaceJSON] = []
    for (_, device) in org.escrowDevices where !memberDevices.contains(device.deviceID) {
      guard let seal = device.sealKey else { continue }
      out.append([
        "device_id": .string(device.deviceID), "epoch": SpaceJSON(epoch),
        "wrap": .string(
          try SpaceCrypto.wrapSpaceKey(
            key, to: seal, spaceID: spaceID, epoch: epoch, deviceID: device.deviceID)),
      ])
    }
    return out
  }

  // MARK: - Share (through the outbox, v8 C3)

  /// Shares items after the review list. Each item becomes an outbox entry
  /// first (its share key, revision, originals), then everything waiting is
  /// sent: per item a random data key, each original sealed and uploaded,
  /// then `item.share` with the member-visible fields under the data key and
  /// the data key under the current space key; then the optional matter
  /// package. Audio only as a meeting part (≤ 15 min, never the whole
  /// recording, one per recording); nothing that belongs to the body and
  /// habits ever goes. When the link is down the entries wait.
  public func share(
    _ spaceID: String, items: [SpaceOutgoingItem], package: SpacePackageRequest? = nil
  ) async throws -> SpaceShareReport {
    var state = try required(spaceID)
    guard state.membership == .active else { throw EngineError.notActive }
    guard state.can("share") else { throw EngineError.notAllowed("share") }
    guard !state.archived else { throw EngineError.notAllowed("archived") }
    if state.rotationPending || items.contains(where: { $0.snapshot != nil }),
      let synced = try? await sync(spaceID)
    {
      // A snapshot's sources must be items this Mac knows are in the space.
      state = synced
    }
    var report = SpaceShareReport()
    let id = state.spaceID
    var contents = try outbox.contents(id)
    let limits = state.limits ?? .standard
    // Parts of a recording this member has out (or waiting), by recording.
    var recordingSpans: [String: [(Int, Int)]] = [:]
    var audioParts: [String: String] = [:]
    for shared in state.activeItems where shared.contributor == state.memberID {
      if let segment = shared.segment {
        recordingSpans[segment.parentItemID, default: []].append((segment.startMS, segment.endMS))
        if shared.audioBlob != nil { audioParts[segment.parentItemID] = shared.itemID }
      }
    }
    for entry in contents.entries where entry.kind == .share {
      if let segment = entry.segment, let item = entry.itemID, state.items[item] == nil {
        recordingSpans[segment.parentItemID, default: []].append((segment.startMS, segment.endMS))
        if entry.originals.contains(where: { $0.role == "audio" }) {
          audioParts[segment.parentItemID] = item
        }
      }
    }
    var queuedItems: [String: String] = [:]
    for item in items {
      if let reason = Self.refusal(item) {
        report.refused[item.itemID] = reason
        continue
      }
      if let segment = item.segment {
        var spans = recordingSpans[segment.parentItemID] ?? []
        if state.items[item.itemID]?.segment == nil {
          spans.append((segment.startMS, segment.endMS))
        }
        guard Self.covered(spans) <= Self.maximumSegmentMS else {
          report.refused[item.itemID] = "recording_share_limit"
          continue
        }
        recordingSpans[segment.parentItemID] = spans
      }
      var originals = item.originals
      if item.hasAudio, let segment = item.segment {
        guard state.policy.segmentAudio, state.policy.originalsForMembers else {
          report.refused[item.itemID] = "audio_not_allowed"
          continue
        }
        if let other = audioParts[segment.parentItemID], other != item.itemID {
          report.refused[item.itemID] = "one_part_per_recording"
          continue
        }
        let audio = originals.first { $0.role == "audio" }?.data ?? Data()
        guard audio.count + 32 <= limits.audioCeiling(ms: segment.lengthMS) else {
          report.refused[item.itemID] = "audio_too_large"
          continue
        }
        audioParts[segment.parentItemID] = item.itemID
      }
      let previous = state.items[item.itemID]
      if let previous, !previous.isActive {
        report.refused[item.itemID] = "item_gone"
        continue
      }
      if let previous, previous.contributor != state.memberID {
        report.refused[item.itemID] = "forbidden"
        continue
      }
      if previous?.kind == "snapshot" || (previous != nil && item.kind == "snapshot") {
        // A snapshot is frozen: share a new one.
        report.refused[item.itemID] = "snapshot_frozen"
        continue
      }
      if !state.policy.originalsForMembers, !originals.isEmpty {
        report.originalsDropped += originals.count
        originals = []
      }
      let waiting = contents.entries.last { $0.kind == .share && $0.itemID == item.itemID }
      let revision = max(previous?.revision ?? 0, waiting?.revision ?? 0) + 1
      var snapshot = item.snapshot
      if let given = snapshot {
        // Only active items of this space, never the snapshot itself.
        let cites = given.cites.filter { $0 != item.itemID && state.items[$0]?.isActive == true }
        snapshot = SpaceSnapshotRef(
          matterID: given.matterID, packID: given.packID, asOf: given.asOf,
          cites: Array(cites.prefix(limits.snapshotCites)))
      }
      var entry = SpaceOutboxEntry(
        entryID: SpaceID.new(), kind: .share,
        label: item.fields.title ?? item.fields.filename ?? "素材", createdAt: now(),
        itemID: item.itemID, revision: revision, itemKind: item.kind, fields: item.fields,
        segment: item.segment, snapshot: snapshot, packageID: package?.packageID)
      for (index, original) in originals.enumerated() {
        let name = "\(entry.entryID)-o\(index)"
        try outbox.saveFile(original.data, name: name, space: id)
        entry.originals.append(.init(role: original.role, file: name))
      }
      contents.entries.append(entry)
      queuedItems[entry.entryID] = item.itemID
    }
    var packageEntry: String?
    if let package, !queuedItems.isEmpty || state.packages[package.packageID] != nil {
      var hints: SpaceJSON = ["facts": SpaceJSON(package.facts)]
      if let title = package.title { hints = hints.setting("title", .string(title)) }
      if let matter = package.matterID { hints = hints.setting("matter_id", .string(matter)) }
      let candidates =
        (state.packages[package.packageID]?.itemIDs ?? [])
        + items.map(\.itemID).filter { id in queuedItems.values.contains(id) }
      let entry = SpaceOutboxEntry(
        entryID: SpaceID.new(), kind: .op, label: package.title ?? "共享这件事", createdAt: now(),
        packageID: package.packageID, opType: "matter.share",
        body: [
          "package_id": .string(package.packageID), "item_ids": SpaceJSON(Self.unique(candidates)),
          "auto": .string(package.auto.rawValue),
        ], encPlain: hints)
      packageEntry = entry.entryID
      contents.entries.append(entry)
    }
    try outbox.save(contents, space: id)
    let flush = try await flushOutbox(id)
    for (entryID, itemID) in queuedItems {
      if let done = flush.done[entryID], done != nil {
        report.shared.append(itemID)
      } else if let code = flush.dropped[entryID] {
        report.refused[itemID] = code
      } else {
        report.queued.append(itemID)
      }
    }
    report.shared.sort()
    report.queued.sort()
    if let package, let packageEntry, flush.done[packageEntry] != nil {
      report.packageID = package.packageID
    }
    _ = try? await sync(id)
    return report
  }

  /// A frozen summary shared as a new item authored by this member (v8 C2):
  /// the text under its own data key; the plain body names only ids — the
  /// matter, the handover pack, and every item it quotes or draws on (when
  /// one of those leaves the space, the snapshot goes with it).
  public func shareSnapshot(
    _ spaceID: String, title: String, text: String, matterID: String?, packID: String? = nil,
    cites: [String], asOf: Date? = nil
  ) async throws -> (itemID: String, report: SpaceShareReport) {
    let itemID = SpaceID.new()
    var fields = SpaceItemFields(kind: "snapshot", title: title, text: text)
    fields.startedAt = SpaceTime.string(asOf ?? now())
    let item = SpaceOutgoingItem(
      itemID: itemID, kind: "snapshot", fields: fields,
      snapshot: SpaceSnapshotRef(
        matterID: matterID, packID: packID, asOf: SpaceTime.string(asOf ?? now()), cites: cites))
    return (itemID, try await share(spaceID, items: [item]))
  }

  /// What is still waiting in a space's outbox, and what was refused.
  public func outboxContents(_ spaceID: String) throws -> SpaceOutboxContents {
    try outbox.contents(spaceID.lowercased())
  }

  public func dismissOutboxFailures(_ spaceID: String) throws {
    var contents = try outbox.contents(spaceID.lowercased())
    contents.failures = []
    try outbox.save(contents, space: spaceID.lowercased())
  }

  /// Takes waiting shares out of a space's outbox (review V8R-04): every
  /// `.share` entry whose item, or whose recording (a part's parent), is in
  /// `itemIDs`, with its plain originals and sealed uploads on disk; matter
  /// packages waiting there forget those items. Returns the items whose share
  /// may already have reached the Spark (an attempt was made and its answer
  /// may have been lost): the caller withdraws those to be sure.
  @discardableResult
  func dropQueuedShares(_ spaceID: String, items itemIDs: Set<String>) throws -> Set<String> {
    let id = spaceID.lowercased()
    let ids = Set(itemIDs.map { $0.lowercased() })
    var contents = try outbox.contents(id)
    var dropped = Set<String>()
    var maybeSent = Set<String>()
    contents.entries.removeAll { entry in
      guard entry.kind == .share, let item = entry.itemID,
        ids.contains(item) || ids.contains(entry.segment?.parentItemID ?? "")
      else { return false }
      for file in entry.originals.map(\.file) + entry.uploads.map(\.file) {
        try? outbox.deleteFile(file, space: id)
      }
      dropped.insert(item)
      if entry.attempts > 0 { maybeSent.insert(item) }
      return true
    }
    guard !dropped.isEmpty else { return [] }
    for index in contents.entries.indices where contents.entries[index].opType == "matter.share" {
      guard let listed = contents.entries[index].body?["item_ids"]?.array else { continue }
      let kept = listed.compactMap(\.string).filter { !dropped.contains($0) }
      guard kept.count != listed.count else { continue }
      contents.entries[index].body = contents.entries[index].body?.setting(
        "item_ids", SpaceJSON(kept))
      contents.entries[index].wire = nil
      contents.entries[index].needsRemake = true
    }
    try outbox.save(contents, space: id)
    return maybeSent
  }

  /// The user takes back something still waiting to go (review V8R-04): the
  /// entry and its files leave the outbox; a share that may already have
  /// reached the Spark is withdrawn when the link is back.
  public func cancelOutboxEntry(_ spaceID: String, entryID: String) throws {
    let id = spaceID.lowercased()
    var contents = try outbox.contents(id)
    guard let entry = contents.entries.first(where: { $0.entryID == entryID.lowercased() }) else {
      return
    }
    if entry.kind == .share, let item = entry.itemID {
      let maybeSent = try dropQueuedShares(id, items: [item])
      if !maybeSent.isEmpty, var state = try states.load(id) {
        state.pendingDeletes = Array(Set(state.pendingDeletes ?? []).union(maybeSent)).sorted()
        try states.save(state)
      }
      return
    }
    contents.entries.removeAll { $0.entryID == entry.entryID }
    try outbox.save(contents, space: id)
  }

  /// Queues any other signed op (a withdraw, a delete) to go when the link is back.
  /// A withdraw or delete of an item whose share still waits here takes that
  /// share out instead of sending both (review V8R-04).
  @discardableResult
  public func enqueueOp(
    _ spaceID: String, type: String, body: SpaceJSON, encPlain: SpaceJSON? = nil, label: String
  ) throws -> String {
    let id = spaceID.lowercased()
    if ["item.withdraw", "item.delete"].contains(type), let item = body["item_id"]?.string {
      try dropQueuedShares(id, items: [item])
    }
    var contents = try outbox.contents(id)
    let entry = SpaceOutboxEntry(
      entryID: SpaceID.new(), kind: .op, label: label, createdAt: now(),
      itemID: body["item_id"]?.string, opType: type, body: body, encPlain: encPlain)
    contents.entries.append(entry)
    try outbox.save(contents, space: id)
    return entry.entryID
  }

  /// Sends what is waiting, in order. Each entry: (re)made if needed, its
  /// sealed originals uploaded, its op posted; then by the Spark's answer —
  /// done (also a remade op taken as the one it has), remade after a key
  /// sync, sent again later, or dropped and reported.
  @discardableResult
  public func flushOutbox(_ spaceID: String) async throws -> SpaceOutboxFlush {
    let id = spaceID.lowercased()
    var contents = try outbox.contents(id)
    var result = SpaceOutboxFlush()
    guard !contents.entries.isEmpty, var state = try states.load(id), state.membership == .active
    else { return result }
    var remade = Set<String>()
    var delivered = Set<String>()
    var index = 0
    func finish(_ entry: SpaceOutboxEntry) {
      for file in entry.originals.map(\.file) + entry.uploads.map(\.file) {
        try? outbox.deleteFile(file, space: id)
      }
    }
    while index < contents.entries.count {
      var entry = contents.entries[index]
      if entry.kind == .share || entry.opType == "matter.share",
        !(state.readmittedAfterRollback ?? []).isEmpty
      {
        // V8R-03: the Spark's log went back and let removed people in again;
        // nothing new goes under a key they hold until an admin's Mac has
        // removed them again with a new key.
        result.pending.append(entry.entryID)
        index += 1
        continue
      }
      do {
        if entry.needsRemake || entry.wire == nil {
          guard try make(&entry, state: state, delivered: delivered) else {
            contents.entries.remove(at: index)
            finish(entry)
            result.done[entry.entryID] = .some(nil)
            try outbox.save(contents, space: id)
            continue
          }
          contents.entries[index] = entry
          try outbox.save(contents, space: id)
        }
        var later = false
        for upload in entry.uploads.indices where !entry.uploads[upload].uploaded {
          guard let sealed = try outbox.file(entry.uploads[upload].file, space: id) else {
            throw EngineError.refused("upload_missing")
          }
          do {
            try await guarded(id) {
              try await self.client.putBlob(
                id, blobID: entry.uploads[upload].blobID, sealed: sealed)
            }
          } catch SpaceClientError.server(let error)
            where ["quota_exceeded", "busy", "unavailable"].contains(error.code)
          {
            entry.lastError = error.code
            later = true
            break
          }
          entry.uploads[upload].uploaded = true
          contents.entries[index] = entry
          try outbox.save(contents, space: id)
        }
        if later {
          contents.entries[index] = entry
          result.pending.append(entry.entryID)
          index += 1
          continue
        }
        guard let op = entry.wire?.op else { throw EngineError.refused("bad_op") }
        // Counted before it goes: an answer lost on the way still means the
        // Spark may have it (a later cancel or delete withdraws it, V8R-04).
        entry.attempts += 1
        contents.entries[index] = entry
        try outbox.save(contents, space: id)
        let answer = try await guarded(id) { try await self.client.submit(id, [op]) }
        guard var response = answer.results.first else { throw SpaceClientError.malformed }
        if ["item.withdraw", "item.delete"].contains(entry.opType ?? ""),
          ["unknown_item", "item_gone"].contains(response.error ?? "")
        {
          // Never reached the space, or already gone: nothing left to take back.
          response = SpaceOpResult(ok: true, error: nil)
        }
        switch response.outboxAction {
        case .done:
          contents.entries.remove(at: index)
          finish(entry)
          result.done[entry.entryID] = .some(entry.kind == .share ? entry.itemID : nil)
          if entry.kind == .share, let item = entry.itemID { delivered.insert(item) }
        case .remake where !remade.contains(entry.entryID):
          remade.insert(entry.entryID)
          state = try await sync(id)
          entry.needsRemake = true
          entry.lastError = response.error
          contents.entries[index] = entry
        case .remake, .later:
          entry.lastError = response.error
          if response.error == "unknown_blob" {
            for upload in entry.uploads.indices { entry.uploads[upload].uploaded = false }
          }
          if response.outboxAction == .remake { entry.needsRemake = true }
          contents.entries[index] = entry
          result.pending.append(entry.entryID)
          index += 1
        case .drop:
          contents.entries.remove(at: index)
          finish(entry)
          let code = response.error ?? "refused"
          contents.failures.append(
            SpaceOutboxFailure(entryID: entry.entryID, label: entry.label, code: code, at: now()))
          result.dropped[entry.entryID] = code
        }
        try outbox.save(contents, space: id)
      } catch SpaceClientError.transport {
        contents.entries[index] = entry
        try outbox.save(contents, space: id)
        result.linkDown = true
        result.pending += contents.entries[index...].map(\.entryID)
        return result
      } catch EngineError.refused(let code) {
        contents.entries.remove(at: index)
        finish(entry)
        contents.failures.append(
          SpaceOutboxFailure(entryID: entry.entryID, label: entry.label, code: code, at: now()))
        result.dropped[entry.entryID] = code
        try outbox.save(contents, space: id)
      }
    }
    return result
  }

  /// Makes (or remakes) an entry's signed op under the current key. A share
  /// gets a new data key and new uploads; its share key and revision stay.
  /// False when there is nothing left to send (an empty package).
  func make(_ entry: inout SpaceOutboxEntry, state: SpaceLocalState, delivered: Set<String> = [])
    throws -> Bool
  {
    let id = state.spaceID
    let key = try currentKey(state)
    switch entry.kind {
    case .share:
      guard let itemID = entry.itemID, let revision = entry.revision, let kind = entry.itemKind,
        let fields = entry.fields
      else { throw EngineError.refused("bad_entry") }
      let dataKey = SpaceCrypto.randomKey()
      for old in entry.uploads { try? outbox.deleteFile(old.file, space: id) }
      var uploads: [SpaceOutboxEntry.Upload] = []
      var blobs: [SpaceJSON] = []
      for (index, original) in entry.originals.enumerated() {
        guard let data = try outbox.file(original.file, space: id) else {
          throw EngineError.refused("original_missing")
        }
        let blobID = SpaceID.new()
        let sealed = try SpaceCrypto.sealBlob(
          data, dataKey: dataKey, spaceID: id, itemID: itemID, blobID: blobID)
        let name = "\(entry.entryID)-b\(index)"
        try outbox.saveFile(sealed, name: name, space: id)
        uploads.append(.init(blobID: blobID, role: original.role, file: name, uploaded: false))
        blobs.append(["blob_id": .string(blobID), "role": .string(original.role)])
      }
      var body: SpaceJSON = [
        "item_id": .string(itemID), "revision": SpaceJSON(revision), "kind": .string(kind),
        "blobs": .array(blobs), "share_key": .string(entry.entryID),
      ]
      if let segment = entry.segment { body = body.setting("segment", segment.json) }
      if let snapshot = entry.snapshot { body = body.setting("snapshot", snapshot.json) }
      if let package = entry.packageID { body = body.setting("package_id", .string(package)) }
      let enc = try SpaceCrypto.encryptItem(
        try JSONEncoder().encode(fields), dataKey: dataKey, spaceID: id, itemID: itemID,
        revision: revision)
      let wrapped = try SpaceCrypto.wrapItemKey(
        dataKey, spaceKey: key, spaceID: id, epoch: state.epoch, itemID: itemID)
      let op = try device.op(
        space: id, member: state.memberID, type: "item.share", body: body, epoch: state.epoch,
        enc: enc, wrappedDK: wrapped, createdAt: now())
      entry.uploads = uploads
      entry.wire = .init(op)
    case .op:
      guard let type = entry.opType, var body = entry.body else {
        throw EngineError.refused("bad_entry")
      }
      if type == "matter.share" {
        // Only items that are in the space as this member's.
        let ids = (body["item_ids"]?.array ?? []).compactMap(\.string).filter {
          delivered.contains($0)
            || (state.items[$0]?.isActive == true && state.items[$0]?.contributor == state.memberID)
        }
        guard !ids.isEmpty else { return false }
        body = body.setting("item_ids", SpaceJSON(ids))
      }
      let opID = SpaceID.new()
      var enc: String?
      if let plain = entry.encPlain {
        enc = try SpaceCrypto.encryptOp(plain.encoded(), spaceKey: key, spaceID: id, opID: opID)
      }
      let op = try device.op(
        space: id, member: state.memberID, type: type, body: body,
        epoch: enc == nil ? nil : state.epoch, enc: enc, opID: opID, createdAt: now())
      entry.wire = .init(op)
    }
    entry.needsRemake = false
    return true
  }

  // MARK: - Meeting parts with their audio (v8 C1)

  /// Opens an audio part another member shared: the original (fetched,
  /// opened, cached on this Mac until the item leaves) and the part the
  /// signed op declares. The caller decodes the duration and checks it with
  /// `SpaceAudioCheck.ok` before playing.
  public func audioPart(_ spaceID: String, itemID: String) async throws -> (
    audio: Data, segment: SpaceSegmentRef
  ) {
    let state = try required(spaceID)
    guard let item = state.items[itemID.lowercased()], item.isActive,
      let blob = item.audioBlob, let segment = item.segment
    else { throw EngineError.refused("no_audio") }
    return (try await original(spaceID, itemID: itemID, blob: blob), segment)
  }

  // MARK: - A member's further Macs (v8 C4)

  /// Spaces this device was added to by another Mac of its member
  /// (`device.add`) and that it does not know yet: taken in and synced.
  @discardableResult
  public func adoptSpaces() async throws -> [String] {
    let list = try await client.listSpaces()
    var adopted: [String] = []
    for entry in list.spaces where entry.status == "active" {
      if let known = try states.load(entry.spaceID), known.membership == .active { continue }
      let state = SpaceLocalState(
        spaceID: entry.spaceID, memberID: entry.memberID, name: "共享空间",
        ownerKind: SpaceOwnerKind(rawValue: entry.ownerKind) ?? .person, orgID: entry.orgID,
        policy: entry.ownerKind == "org" ? .org : .group,
        role: SpaceRole(rawValue: entry.role ?? "") ?? .read, membership: .active, spark: nil)
      try states.save(state)
      do {
        _ = try await sync(entry.spaceID)
        adopted.append(entry.spaceID)
      } catch {
        // Not readable yet (no signed wrap for this device): try again later.
        try? states.delete(entry.spaceID)
      }
    }
    return adopted
  }

  /// `device.add`: another Mac of this member gets the current key of the
  /// space, wrapped to it and signed into the log.
  public func addDevice(_ spaceID: String, device other: SpaceDevicePublic) async throws {
    let state = try await sync(spaceID)
    guard let seal = other.sealKey, other.signKey != nil else {
      throw SpaceCrypto.CryptoError.invalidKey
    }
    let wrap = try SpaceCrypto.wrapSpaceKey(
      currentKey(state), to: seal, spaceID: state.spaceID, epoch: state.epoch,
      deviceID: other.deviceID)
    _ = try ok(
      try await post(
        state, type: "device.add",
        body: [
          "device": other.json,
          "wraps": [
            [
              "device_id": .string(other.deviceID), "epoch": SpaceJSON(state.epoch),
              "wrap": .string(wrap),
            ]
          ],
        ]))
    _ = try await sync(spaceID)
  }

  /// `device.remove` of a lost or unpaired Mac: a new key to every other
  /// device, the old one linked under it (and escrowed in an org space).
  public func retireDevice(_ spaceID: String, deviceID: String) async throws {
    let state = try await sync(spaceID)
    let (body, newKey) = try await rotation(state, excluding: nil, excludingDevice: deviceID)
    let result = try ok(
      try await post(
        state, type: "device.remove", body: body.setting("device_id", .string(deviceID))))
    try keyStore.save(
      newKey, space: state.spaceID, epoch: result.effects?["epoch"]?.int ?? state.epoch + 1)
    _ = try await sync(spaceID)
  }

  // MARK: - Organizations (v8 B2 / B5 / C4)

  /// The organizations this device is in, as the Spark lists them.
  public func orgs() async throws -> [SpaceList.Org] { try await client.listSpaces().orgs }

  @discardableResult
  public func orgOp(_ orgID: String, type: String, body: SpaceJSON) async throws -> SpaceOpResult {
    let op = try device.orgOp(
      org: orgID.lowercased(), member: try memberIdentity(), type: type, body: body,
      createdAt: now())
    guard let result = try await client.orgOps(orgID.lowercased(), [op]).first else {
      throw SpaceClientError.malformed
    }
    guard result.ok else { throw EngineError.refused(result.error ?? "refused") }
    orgFetchedAt[orgID.lowercased()] = nil
    return result
  }

  /// `org.device_add`: another Mac of this admin becomes an org device.
  public func addOrgDevice(_ orgID: String, device other: SpaceDevicePublic) async throws {
    try await orgOp(orgID, type: "org.device_add", body: ["device": other.json])
  }

  /// `org.device_remove`: an org device is retired (never the signing one).
  public func retireOrgDevice(_ orgID: String, deviceID: String) async throws {
    try await orgOp(orgID, type: "org.device_remove", body: ["device_id": .string(deviceID)])
  }

  /// `org.admin_add` naming the member's own Mac (from a space's signed
  /// roster or `GET /v1/access/devices`), then the org spaces' current keys
  /// escrowed to it.
  public func addOrgAdmin(_ orgID: String, memberID: String, device admin: SpaceDevicePublic)
    async throws
  {
    try await orgOp(
      orgID, type: "org.admin_add",
      body: ["member_id": .string(memberID.lowercased()), "device": admin.json])
    for state in try states.states()
    where state.membership == .active && state.orgID == orgID.lowercased() {
      _ = try? await fillEscrow(state.spaceID)
    }
  }

  /// `org.policy`: how many org admins must be able to open each org space's key.
  public func setRecoveryAdmins(_ orgID: String, count: Int) async throws {
    guard (1...3).contains(count) else { throw EngineError.notAllowed("recovery_admins") }
    try await orgOp(orgID, type: "org.policy", body: ["recovery_admins": SpaceJSON(count)])
    for state in try states.states()
    where state.membership == .active && state.orgID == orgID.lowercased() {
      _ = try? await fillEscrow(state.spaceID)
    }
  }

  /// `escrow.wrap`: the current key wrapped to every org admin device the
  /// summary says lacks one — each checked against the org's own signed log
  /// (an admin device there with the same seal key); returns how many.
  @discardableResult
  public func fillEscrow(_ spaceID: String) async throws -> Int {
    let state = try await sync(spaceID)
    guard state.ownerKind == .org, let orgID = state.orgID,
      let missing = state.escrow?.missing, !missing.isEmpty, let org = await orgRoster(orgID)
    else { return 0 }
    let key = try currentKey(state)
    let memberDevices = state.roster?.activeDeviceIDs ?? []
    var wraps: [SpaceJSON] = []
    for want in missing where !memberDevices.contains(want.deviceID) {
      guard let device = org.device(member: want.memberID, device: want.deviceID),
        device.sealPub == want.sealPub, let seal = device.sealKey
      else { continue }
      wraps.append([
        "device_id": .string(device.deviceID), "epoch": SpaceJSON(state.epoch),
        "wrap": .string(
          try SpaceCrypto.wrapSpaceKey(
            key, to: seal, spaceID: state.spaceID, epoch: state.epoch, deviceID: device.deviceID)),
      ])
    }
    guard !wraps.isEmpty else { return 0 }
    _ = try ok(
      try await post(
        state, type: "escrow.wrap", body: ["epoch": SpaceJSON(state.epoch), "wraps": .array(wraps)]
      ))
    _ = try? await sync(spaceID)
    return wraps.count
  }

  /// The takeover after losing an admin (v8 B5): this org admin's device
  /// opens its escrow wrap of the space's current key, signs
  /// `space.recover` with its own keys and becomes an admin member. The key
  /// is believed only once it opens something a member signed at that
  /// epoch (the Spark could wrap a key of its own to this device).
  @discardableResult
  public func recover(orgID: String, spaceID: String, displayName: String) async throws
    -> SpaceLocalState
  {
    let id = spaceID.lowercased()
    let memberID = try memberIdentity()
    guard
      let escrow = try await client.orgEscrow(orgID.lowercased()).first(where: { $0.spaceID == id }
      ),
      let wrap = escrow.wrap
    else { throw EngineError.refused("no_escrow") }
    let key = try SpaceCrypto.unwrapSpaceKey(
      wrap, sealKey: device.sealKey, spaceID: id, epoch: escrow.epoch, deviceID: device.deviceID)
    let op = try device.op(
      space: id, member: memberID, type: "space.recover",
      body: ["device": device.publicRecord.json],
      createdAt: now())
    let result = try await submitOne(id, op)
    guard result.ok || result.duplicate == true else {
      throw EngineError.refused(result.error ?? "refused")
    }
    var state = (try? states.load(id)) ?? nil
    if state == nil || state?.membership != .active {
      state = SpaceLocalState(
        spaceID: id, memberID: memberID, name: "组织空间", ownerKind: .org, orgID: orgID.lowercased(),
        policy: .org, role: .admin, membership: .active, spark: nil)
    }
    state?.knownNames[memberID] = displayName
    try states.save(state!)
    try keyStore.save(key, space: id, epoch: escrow.epoch)
    var synced = try await sync(id)
    if !Self.keyOpensItems(epoch: escrow.epoch, state: synced) {
      // Nothing a member shared at that epoch opens: not the space's key.
      synced.warn("recovered_key_unverified")
      try states.save(synced)
      try keyStore.delete(id)
      throw EngineError.refused("recovered_key_unverified")
    }
    _ = try? await post(
      synced, type: "member.profile", body: [:], encPlain: ["display_name": .string(displayName)])
    return try await sync(id)
  }

  /// Whether a recovered key is the space's: an item a member shared under
  /// that epoch opened with it (or the space has none at that epoch yet).
  nonisolated static func keyOpensItems(epoch: Int, state: SpaceLocalState) -> Bool {
    let atEpoch = state.items.values.filter { $0.keyEpoch == epoch && $0.isActive }
    guard !atEpoch.isEmpty else { return true }
    return atEpoch.contains { $0.fields != nil }
  }

  /// A plain member confirms a takeover it could not check against the
  /// organization's log (after comparing the fingerprint out of band); the
  /// log is then read again from the start.
  public func confirmRecovery(_ spaceID: String, deviceID: String) async throws {
    var state = try required(spaceID)
    guard let pending = state.pendingRecoveries?.first(where: { $0.device.deviceID == deviceID })
    else { return }
    var trusted = state.trustedRecoveries ?? [:]
    trusted[deviceID] = pending.device.signPub
    state.trustedRecoveries = trusted
    state.resetForResync()
    try states.save(state)
    _ = try await sync(spaceID)
  }

  // MARK: - Backups (v8 B4)

  /// Pulls an encrypted backup of the space (an admin device signs) and
  /// checks the whole stream opens before handing it out. Review V8R-13: the
  /// key is this backup's own random key, lent to the Spark for this export
  /// only and kept sealed to the space's admin devices (and, in an org
  /// space, the org admins' escrow devices) in the receipt: a plain member,
  /// who holds the space key, cannot open it.
  public func backup(_ spaceID: String) async throws -> (stream: Data, receipt: SpaceBackupReceipt)
  {
    let state = try await sync(spaceID)
    guard state.role == .admin else { throw EngineError.notAllowed("backup") }
    let backupID = SpaceID.new()
    let key = SpaceCrypto.randomKey()
    var wraps: [String: String] = [
      device.deviceID: try SpaceBackup.wrapKey(
        key, to: device.sealPublicKey, spaceID: state.spaceID, backupID: backupID,
        deviceID: device.deviceID)
    ]
    let roster = state.roster ?? SpaceRoster()
    let admins = Set(state.activeMembers.filter { $0.role == .admin }.map(\.memberID))
    var recipients: [SpaceRoster.Device] = roster.members.filter {
      admins.contains($0.key) && $0.value.status == "active"
    }.flatMap { $0.value.devices.values.filter(\.active) }
    if state.ownerKind == .org, let orgID = state.orgID,
      let org = await orgRoster(orgID, commitment: state.orgGenesis)
    {
      recipients += org.escrowDevices.map(\.device)
    }
    for recipient in recipients where wraps[recipient.deviceID] == nil {
      guard let seal = recipient.sealKey else { continue }
      wraps[recipient.deviceID] = try SpaceBackup.wrapKey(
        key, to: seal, spaceID: state.spaceID, backupID: backupID, deviceID: recipient.deviceID)
    }
    let stream = try await guarded(state.spaceID) {
      try await self.client.backup(state.spaceID, backupID: backupID, epoch: state.epoch, key: key)
    }
    let contents = try SpaceBackup.open(stream, key: key)
    guard contents.header.spaceID == state.spaceID, contents.header.backupID == backupID else {
      throw SpaceBackup.BackupError.damaged("another backup")
    }
    let receipt = SpaceBackupReceipt(
      backupID: backupID, spaceID: state.spaceID, spaceName: nil, epoch: state.epoch,
      createdAt: now(), bytes: stream.count, sha256: SpaceCrypto.sha256Hex(stream),
      items: contents.activeItems.count, blobs: contents.blobIDs.count,
      fileName: SpaceBackupFiles.neutralName(backupID: backupID, at: now()), keyWraps: wraps)
    return (stream, receipt)
  }

  /// The key of a kept backup: this device's wrap in its receipt (V8R-13), or
  /// for a backup made before that, derived again from the epoch's space key.
  public func backupKey(_ stream: Data, keyWraps: [String: String]? = nil) throws -> Data {
    let (header, _) = try SpaceBackup.header(stream)
    if let keyWraps {
      guard let wrap = keyWraps[device.deviceID] else { throw EngineError.notAllowed("backup") }
      return try SpaceBackup.unwrapKey(
        wrap, sealKey: device.sealKey, spaceID: header.spaceID, backupID: header.backupID,
        deviceID: device.deviceID)
    }
    let key = try key(header.spaceID, epoch: header.epoch)
    return SpaceBackup.key(spaceKey: key, backupID: header.backupID)
  }

  /// Opens a backup this Mac kept.
  public func openBackup(_ stream: Data, keyWraps: [String: String]? = nil) throws
    -> SpaceBackup.Contents
  {
    try SpaceBackup.open(stream, key: try backupKey(stream, keyWraps: keyWraps))
  }

  /// Puts the space back from a backup (`replace` on this Spark, or `new`
  /// on a new or rebuilt one). Items active in the backup that this Mac's
  /// own log says were withdrawn or removed since are purged again. Then the
  /// log is read again from the start.
  @discardableResult
  public func restore(
    _ spaceID: String, stream: Data, mode: String = "replace", keyWraps: [String: String]? = nil
  ) async throws
    -> SpaceJSON
  {
    let id = spaceID.lowercased()
    let contents = try openBackup(stream, keyWraps: keyWraps)
    guard contents.header.spaceID == id else {
      throw SpaceBackup.BackupError.damaged("another space")
    }
    let state = try states.load(id)
    let purge = contents.activeItems.filter { item in
      guard let local = state?.items[item] else { return false }
      return !local.isActive
    }
    let key = try backupKey(stream, keyWraps: keyWraps)
    let answer = try await guarded(id) {
      try await self.client.restore(id, stream: stream, key: key, mode: mode, purge: purge)
    }
    guard answer["ok"]?.bool == true else {
      throw EngineError.refused(answer["error"]?.string ?? "bad_backup")
    }
    if var state {
      // The Spark keeps a log that already holds the backup's (it only fills
      // in data then, "applied": "fill"). When it replaced the log (its own
      // was shorter, or its owner forced a diverged one), this Mac reads the
      // log again from the start, compares with what it knew, and an admin's
      // Mac removes again whoever the new log let back in (V8R-03).
      if answer["applied"]?.string != "fill" {
        rosterBeforeReset[id] = state.roster
        state.resetForResync()
        try states.save(state)
      }
      _ = try? await sync(id)
      _ = try? await repairRollback(id)
    }
    return answer
  }

  /// Review V8R-03: after the Spark's log went back, this admin's Mac removes
  /// again (each with a new key) every member and device the shorter log
  /// admitted although this Mac had seen them removed. Returns how many.
  @discardableResult
  public func repairRollback(_ spaceID: String) async throws -> Int {
    var state = try await sync(spaceID)
    guard let back = state.readmittedAfterRollback, !back.isEmpty,
      state.can("remove_members")
    else { return 0 }
    var done = 0
    // Members first (their devices go with them), then any device left.
    for id in back
    where id != state.memberID && state.roster?.members[id]?.status == "active" {
      try await removeMember(spaceID, memberID: id)
      done += 1
      state = try await sync(spaceID)
    }
    for id in back
    where id != device.deviceID && state.roster?.activeDeviceIDs.contains(id) == true {
      try await retireDevice(spaceID, deviceID: id)
      done += 1
      state = try await sync(spaceID)
    }
    return done
  }

  // MARK: - Handover (v8 B3)

  /// Asks the space organizer for a handover pack of a matter (written by
  /// the Spark's model; every sentence cites its items). Needs the lease:
  /// organizing runs first. Returns the pack id, or nil with the reason.
  public func requestHandoverPack(
    _ spaceID: String, matterID: String, from: String?, to: String?
  ) async throws -> (packID: String?, reason: String?) {
    let state = try required(spaceID)
    let answer = try await guarded(state.spaceID) {
      try await self.client.requestHandoverPack(
        state.spaceID, matterID: matterID, from: from, to: to)
    }
    if answer["queued"]?.bool == true, let pack = answer["pack_id"]?.string { return (pack, nil) }
    return (nil, answer["reason"]?.string ?? answer["error"]?.string ?? "busy")
  }

  public func handoverPack(_ spaceID: String, packID: String) async throws -> SpaceHandoverPack {
    let state = try required(spaceID)
    return SpaceHandoverPack(
      try await guarded(state.spaceID) {
        try await self.client.handoverPack(state.spaceID, packID: packID)
      })
  }

  /// `matter.handover`: a matter's 负责人 goes to another member, with the
  /// handover pack's snapshot item when there is one.
  public func handover(
    _ spaceID: String, matterID: String, to memberID: String, packItemID: String?
  ) async throws {
    let state = try required(spaceID)
    var body: SpaceJSON = ["matter_id": .string(matterID), "to_member_id": .string(memberID)]
    if let packItemID { body = body.setting("pack_item_id", .string(packItemID.lowercased())) }
    _ = try ok(try await post(state, type: "matter.handover", body: body))
    _ = try await sync(spaceID)
  }

  /// This member's storage in a space (with the quota), as last synced.
  public func usage(_ spaceID: String) throws -> SpaceUsage? { try required(spaceID).usage }
}

/// File names of kept backups. Review V8R-13: `mindloom-<yyyyMMdd-HHmm>-<id
/// prefix>.mlbk` names no space (`fileName(spaceName:…)` is the old form).
public enum SpaceBackupFiles {
  public static func neutralName(backupID: String, at date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmm"
    return
      "mindloom-\(formatter.string(from: date))-\(backupID.prefix(8)).\(SpaceBackup.fileExtension)"
  }

  public static func fileName(spaceName: String, backupID: String, at date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmm"
    let safe = String(
      spaceName.unicodeScalars.map {
        CharacterSet.alphanumerics.contains($0) ? Character($0) : "-"
      }
    ).prefix(40)
    let name = safe.isEmpty ? "space" : String(safe)
    return
      "\(name)-\(formatter.string(from: date))-\(backupID.prefix(8)).\(SpaceBackup.fileExtension)"
  }
}
