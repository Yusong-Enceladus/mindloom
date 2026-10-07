import Foundation

/// What a request was for.
public enum NetworkActivityKind: String, Codable, Sendable, CaseIterable {
  /// A search service (Brave, Tavily …).
  case search
  /// A keyless public source (arXiv, Crossref, Wikipedia, OpenStreetMap).
  case publicSource
  /// The whole conference deadline table, downloaded and matched here.
  case conferenceTable
  /// A web page read on this device.
  case page
  /// A reader service read a page the device could not.
  case readerService
  /// One fixed public query when a search key is added.
  case keyCheck
}

public enum NetworkActivityResult: String, Codable, Sendable, CaseIterable {
  case found
  case nothingFound
  /// Refused by the outbound check; nothing left the device.
  case notSent
  case failed
}

/// One line of 「网络活动」: when, which device, what for, which service and
/// host, how many bytes each way, and the result. Never the words sent, a
/// path or any content (an Apple-style privacy report: who was contacted).
public struct NetworkActivityEntry: Codable, Sendable, Identifiable, Equatable {
  public var id: UUID
  public var time: Date
  public var device: String
  public var kind: NetworkActivityKind
  /// The service ("brave", "arxiv", "page" …).
  public var service: String
  /// The host contacted (or that would have been, for `notSent`).
  public var host: String?
  public var bytesSent: Int
  public var bytesReceived: Int
  public var result: NetworkActivityResult
  /// The HTTP status, when there was a response.
  public var status: Int?
  /// The rule that refused it (a category only).
  public var refusal: OutboundRefusal?
  public var durationMilliseconds: Int

  public init(
    id: UUID = UUID(), time: Date, device: String, kind: NetworkActivityKind, service: String,
    host: String?, bytesSent: Int = 0, bytesReceived: Int = 0, result: NetworkActivityResult,
    status: Int? = nil, refusal: OutboundRefusal? = nil, durationMilliseconds: Int = 0
  ) {
    self.id = id
    self.time = time
    self.device = device
    self.kind = kind
    self.service = service
    self.host = host
    self.bytesSent = bytesSent
    self.bytesReceived = bytesReceived
    self.result = result
    self.status = status
    self.refusal = refusal
    self.durationMilliseconds = durationMilliseconds
  }
}

/// The record behind 「网络活动」: every request the lookup made or refused,
/// one line each, in the library's private lookup folder (or in memory).
/// The only network exit (`LookupEgress`) writes it. Kept for 90 days.
public actor NetworkActivityLog {
  public static let keptDays = 90
  static let maximumFileBytes = 4 * 1024 * 1024

  private let fileURL: URL?
  private var entries: [NetworkActivityEntry] = []
  private var loaded = false
  private let now: @Sendable () -> Date

  /// `fileURL` nil keeps the record in memory (tests, the dry run).
  public init(fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
    self.fileURL = fileURL
    self.now = now
  }

  public init(folder: LookupFolder, now: @escaping @Sendable () -> Date = { Date() }) {
    self.init(fileURL: folder.activityURL, now: now)
  }

  private struct Amendment: Codable {
    var amend: UUID
    var result: NetworkActivityResult
  }

  private func load() {
    guard !loaded else { return }
    loaded = true
    guard let fileURL, let data = PrivateFiles.read(fileURL, maximumBytes: Self.maximumFileBytes * 2)
    else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var byID: [UUID: Int] = [:]
    for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
      if let entry = try? decoder.decode(NetworkActivityEntry.self, from: Data(line)) {
        byID[entry.id] = entries.count
        entries.append(entry)
      } else if let amendment = try? decoder.decode(Amendment.self, from: Data(line)),
        let index = byID[amendment.amend]
      {
        entries[index].result = amendment.result
      }
    }
    let cutoff = now().addingTimeInterval(-Double(Self.keptDays) * 86_400)
    if entries.contains(where: { $0.time < cutoff }) || data.count > Self.maximumFileBytes {
      entries.removeAll { $0.time < cutoff }
      if entries.count > 20_000 { entries.removeFirst(entries.count - 20_000) }
      rewrite()
    }
  }

  private func rewrite() {
    guard let fileURL else { return }
    var data = Data()
    for entry in entries { data.append(Self.line(entry) ?? Data()) }
    try? PrivateFiles.write(data, to: fileURL)
  }

  static func line<Value: Encodable>(_ value: Value) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard var data = try? encoder.encode(value) else { return nil }
    data.append(UInt8(ascii: "\n"))
    return data
  }

  public func append(_ entry: NetworkActivityEntry) {
    load()
    entries.append(entry)
    if let fileURL, let line = Self.line(entry) { try? PrivateFiles.append(line, to: fileURL) }
  }

  /// Sets an entry's result after its answer was read (a search that came
  /// back empty is `nothingFound`).
  public func amend(_ id: UUID, result: NetworkActivityResult) {
    load()
    guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].result != result
    else { return }
    entries[index].result = result
    if let fileURL, let line = Self.line(Amendment(amend: id, result: result)) {
      try? PrivateFiles.append(line, to: fileURL)
    }
  }

  /// Newest first.
  public func entries(since date: Date? = nil) -> [NetworkActivityEntry] {
    load()
    let kept = date.map { cutoff in entries.filter { $0.time >= cutoff } } ?? entries
    return kept.reversed()
  }

  /// 「删除记录」.
  public func removeAll() {
    load()
    entries.removeAll()
    rewrite()
  }
}
