import BestASRMemoryUI
import BestASRRemoteOrganizer
import Foundation
import MindloomLookup

/// 设置 › 设备与隐私 › 从网络补充信息 (PRD LOOKUP-001–003, SETUP-003): the
/// switch (in the library's private `lookup` folder, off by default), the
/// search keys (Keychain, never in the library), and 「网络活动」. `lookup`
/// is what the organizer's "what is missing" step calls.
@MainActor
final class WebLookupModel: ObservableObject {
  @Published private(set) var state = SettingsWebLookup()
  private(set) var lookup: WebLookup?
  var timeZone: TimeZone = .current

  /// The record names the device; no user or machine name.
  static let deviceLabel = "Mac"

  func configure(dataRoot: URL) {
    guard lookup == nil else { return }
    // The owner's Keychain item is reached only from the owner's own library in the
    // shipped identity; a synthetic root or a check or Preview build uses a file in
    // that root, or memory, so verification never reads, replaces or deletes it.
    let ownersLibrary = BestASRDataRootSelection.ownerRealLibraryRoot().map {
      BestASRDataRootSelection.path(dataRoot, isWithinOrEqualTo: $0)
    } ?? true
    let keys = SearchKeyStores.make(
      dataRoot: dataRoot, isOwnersLibrary: ownersLibrary, bundleIdentifier: Bundle.main.bundleIdentifier)
    lookup = WebLookup(dataRoot: dataRoot, keys: keys, device: Self.deviceLabel)
    state.choices = SearchServiceID.fallbackOrder.map {
      SettingsWebLookup.Choice(id: $0.rawValue, name: $0.displayName, signUpURL: $0.signUpURL)
    }
    refresh()
  }

  func refresh() {
    guard let lookup else { return }
    Task { [weak self] in
      let settings = await lookup.settings()
      let statuses = await lookup.statuses()
      let entries = await lookup.activity.entries(since: Date().addingTimeInterval(-90 * 86_400))
      self?.apply(enabled: settings.enabled, statuses: statuses, entries: entries)
    }
  }

  func setEnabled(_ on: Bool) {
    guard let lookup else { return }
    state.enabled = on
    Task { [weak self] in
      try? await lookup.setEnabled(on)
      self?.refresh()
    }
  }

  func addKey(service id: String, key: String) {
    guard let lookup, let service = SearchServiceID(rawValue: id) else { return }
    state.keyCheck = .checking
    Task { [weak self] in
      let condition = await lookup.addKey(key, for: service)
      let stored = await lookup.statuses().first { $0.service == service }?.condition != .notAdded
      guard let self else { return }
      if condition == .badKey {
        state.keyCheck = .failed("\(service.displayName) 无法验证这个密钥。请检查后重新粘贴。")
      } else if !stored {
        state.keyCheck = .failed("无法储存密钥。请稍后再试。")
      } else {
        state.keyCheck = .added
      }
      refresh()
    }
  }

  func removeKey(service id: String) {
    guard let lookup, let service = SearchServiceID(rawValue: id) else { return }
    Task { [weak self] in
      try? await lookup.removeKey(service)
      self?.refresh()
    }
  }

  func likelyService(forKey key: String) -> String? {
    SearchServiceID.likelyService(forKey: key)?.rawValue
  }

  func clearActivity() {
    guard let lookup else { return }
    Task { [weak self] in
      await lookup.activity.removeAll()
      self?.refresh()
    }
  }

  private func apply(
    enabled: Bool, statuses: [SearchServiceStatus], entries: [NetworkActivityEntry]
  ) {
    state.enabled = enabled
    state.services = statuses.filter { $0.condition != .notAdded }.map { status in
      SettingsWebLookup.Service(
        id: status.service.rawValue, name: status.service.displayName,
        status: Self.statusText(status.condition),
        isProblem: status.condition != .ready,
        detail: status.syncsAcrossDevices ? "在你的设备之间同步" : "储存在这台 Mac 上",
        syncsAcrossDevices: status.syncsAcrossDevices)
    }
    let weekAgo = Date().addingTimeInterval(-7 * 86_400)
    let week = entries.filter { $0.time >= weekAgo }
    let notSent = week.filter { $0.result == .notSent }.count
    if week.isEmpty {
      state.summary = "最近 7 天没有连接"
    } else {
      state.summary = "最近 7 天连接 \(week.count - notSent) 次" + (notSent > 0 ? "，\(notSent) 次未发送" : "")
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_Hans")
    formatter.timeZone = timeZone
    formatter.dateFormat = "M月d日 HH:mm"
    state.activity = entries.prefix(500).map { entry in
      SettingsWebLookup.Activity(
        id: entry.id, time: formatter.string(from: entry.time),
        what: Self.kindText(entry.kind)
          + (Self.serviceText(entry.service).map { " · " + $0 } ?? ""),
        host: entry.host ?? "未发送到任何服务器", result: Self.resultText(entry),
        size: entry.result == .notSent
          ? "—"
          : ByteCountFormatter.string(
            fromByteCount: Int64(entry.bytesSent + entry.bytesReceived), countStyle: .file),
        notSent: entry.result == .notSent)
    }
  }

  static func statusText(_ condition: SearchServiceCondition) -> String {
    switch condition {
    case .notAdded: "未添加"
    case .ready: "可用"
    case .badKey: "密钥无效"
    case .quotaUsed: "额度已用完"
    case .unreachable: "无法连接"
    case .rateLimited: "请求过多"
    case .failing: "暂时无法使用"
    }
  }

  static func kindText(_ kind: NetworkActivityKind) -> String {
    switch kind {
    case .search: "搜索"
    case .publicSource: "公开资料"
    case .conferenceTable: "会议日期表"
    case .page: "网页"
    case .readerService: "网页读取服务"
    case .keyCheck: "验证密钥"
    }
  }

  static func serviceText(_ service: String) -> String? {
    if let search = SearchServiceID(rawValue: service) { return search.displayName }
    switch service {
    case PublicSourceID.arXiv.rawValue: return "arXiv"
    case PublicSourceID.crossref.rawValue: return "Crossref"
    case PublicSourceID.conferenceTable.rawValue: return "ccf-deadlines"
    case PublicSourceID.wikipedia.rawValue: return "维基百科"
    case PublicSourceID.openStreetMap.rawValue: return "OpenStreetMap"
    case "jina": return "Jina Reader"
    default: return nil
    }
  }

  static func resultText(_ entry: NetworkActivityEntry) -> String {
    switch entry.result {
    case .found:
      switch entry.kind {
      case .search, .publicSource: "已找到"
      case .keyCheck: "已验证"
      default: "已读取"
      }
    case .nothingFound: "未找到"
    case .notSent: "未发送"
    case .failed: "失败"
    }
  }
}
