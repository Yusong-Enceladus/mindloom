import BestASRDomain
import BestASRIntake
import BestASRPersistence
import BestASRRemoteOrganizer
import Foundation

/// Glue between the app model and the own-device organizer link. The link
/// logic (provenance guard, tunnel, outbox, revocation) lives in the
/// BestASRRemoteOrganizer package module; this file only maps it to UI state.
extension DictationAppModel {
  static let remoteOrganizerHostPreferenceKey = "preferences.spark-organizer-host"
  static let remoteOrganizerHostMissingMessage =
    "未设置整理设备主机；用 defaults write 写入 preferences.spark-organizer-host 后重新打开 App"

  /// The user's own Spark, as an ssh host name or alias. There is no built-in
  /// host: nil until the user writes the preference.
  static func configuredRemoteOrganizerHost() -> String? {
    remoteOrganizerHost(
      preference: LocalPreferenceStore.defaults.string(forKey: remoteOrganizerHostPreferenceKey)
    )
  }

  nonisolated static func remoteOrganizerHost(preference: String?) -> String? {
    let host = (preference ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return host.isEmpty ? nil : host
  }

  /// Called once the durable library is open, with the exact root the store
  /// was opened on.
  func configureRemoteOrganizer(repository: GRDBDictationStore, dataRoot: URL) {
    guard remoteOrganizer == nil else { return }
    guard let realLibrary = BestASRDataRootSelection.ownerRealLibraryRoot(),
      let stateDirectory = try? Self.remoteOrganizerStateDirectory()
    else {
      events.remoteStatusMessage = "整理设备链路状态目录不可用；未发送任何内容"
      Task { try? await repository.revokeRemoteLink() }
      return
    }
    let intent = RemoteOrganizerLinkIntentFile(stateDirectory: stateDirectory, dataRoot: dataRoot)
    guard let host = Self.configuredRemoteOrganizerHost() else {
      // No organizer device named: the link cannot exist, so it is off, the
      // same fail-closed state as an invalid configuration.
      try? intent.clearOn()
      Task { try? await repository.revokeRemoteLink() }
      events.remoteStatusMessage = Self.remoteOrganizerHostMissingMessage
      return
    }
    let configuration: RemoteOrganizerLinkConfiguration
    do {
      configuration = try RemoteOrganizerLinkConfiguration(
        host: host,
        remoteSocketPath: LocalPreferenceStore.string(
          "preferences.spark-organizer-socket-path",
          default: RemoteOrganizerLinkConfiguration.defaultRemoteSocketPath
        ),
        remoteTokenPath: LocalPreferenceStore.string(
          "preferences.spark-organizer-token-path",
          default: RemoteOrganizerLinkConfiguration.defaultRemoteTokenPath
        )
      )
    } catch {
      // Fail closed: the toggle shows off, so the library must be off too, or
      // a later launch with a valid configuration would send the backlog.
      try? intent.clearOn()
      Task { try? await repository.revokeRemoteLink() }
      events.remoteStatusMessage = "整理设备链路配置无效，已关闭；使用这台 Mac 整理"
      return
    }
    let repositoryForInbox = repository
    let controller = RemoteOrganizerLinkController(
      repository: repository,
      dataRoot: dataRoot,
      realLibraryRoot: realLibrary,
      intent: intent,
      cleanUpStaleTunnels: {
        _ = RemoteOrganizerTunnelRecordStore(directory: stateDirectory).cleanUpStale()
      },
      makeRuntime: { [weak self] repository, onUpdate in
        RemoteOrganizerRuntime(
          repository: repository,
          launcher: SSHRemoteOrganizerTunnelLauncher(
            configuration: configuration, stateDirectory: stateDirectory
          ),
          http: URLSessionRemoteOrganizerTransport(),
          // Image items are read from this provenance-checked root only.
          itemAssetReader: RemoteOrganizerItemAssetReader(
            assetRoot: dataRoot.appendingPathComponent("assets", isDirectory: true)
          ),
          // What the phone sent to the organizing device comes in through
          // the same intake as a paste, with its source "iPhone".
          inbox: self?.remoteInboxIngestor(store: repositoryForInbox),
          onUpdate: onUpdate
        )
      }
    )
    controller.onChange = { [weak self] status, projection in
      self?.applyRemoteOrganizerChange(status: status, projection: projection)
    }
    remoteOrganizer = controller
    Task { [weak self] in
      await controller.restoreOnLaunch()
      self?.remoteOrganizerEnabled = controller.isEnabled
    }
  }

  func setRemoteOrganizerEnabled(_ enabled: Bool) {
    guard let controller = remoteOrganizer else {
      remoteOrganizerEnabled = false
      if let stateDirectory = try? Self.remoteOrganizerStateDirectory() {
        RemoteOrganizerTunnelRecordStore(directory: stateDirectory).cleanUpStale()
      }
      events.remoteStatusMessage =
        Self.configuredRemoteOrganizerHost() == nil
        ? Self.remoteOrganizerHostMissingMessage
        : "资料库尚未打开；整理设备链路保持关闭"
      return
    }
    guard enabled else {
      // Synchronous revocation first: after this line nothing is sent and no
      // late status can turn the toggle back on. Only the library write waits.
      controller.revokeNow()
      remoteOrganizerEnabled = false
      Task { await controller.revokeStorage() }
      return
    }
    // Reflect the request immediately; the controller settles the final
    // state (it refuses a library that may not be sent).
    remoteOrganizerEnabled = true
    Task { [weak self] in
      await controller.setEnabled(true)
      self?.remoteOrganizerEnabled = controller.isEnabled
    }
  }

  /// The phone entry's inbox, taken in like a paste (nil until intake is
  /// configured). After each new item the lists refresh.
  func remoteInboxIngestor(store: GRDBDictationStore) -> IntakeInboxIngestor? {
    guard let processor = intakeProcessor else { return nil }
    let ready = intakeReady
    return IntakeInboxIngestor(
      processor: processor, store: store,
      ready: { await ready?.value },
      committed: { [weak self] _ in
        await self?.refreshHistoryItems(preserveStatus: true, organizeEvents: true)
      })
  }

  func enqueueRemoteSessionIfEnabled(_ sessionID: SessionID) async {
    guard let controller = remoteOrganizer, controller.isEnabled else { return }
    do {
      try await controller.enqueueCompletedSession(sessionID)
    } catch {
      events.remoteStatusMessage = "整理待发队列暂不可用；本机记录已保留"
    }
  }

  func recordRemoteDecision(_ decision: RemoteOrganizerDecision) {
    guard let controller = remoteOrganizer, controller.isEnabled else { return }
    guard decision.isWellFormed else {
      events.remoteStatusMessage =
        decision.kind == "rename_event"
        ? "标题需为 1–\(RemoteOrganizerDecision.maximumTitleScalars) 个字"
        : "这次整理修改不完整，未保存"
      return
    }
    Task { [weak self] in
      do { try await controller.record(decision) } catch {
        self?.events.remoteStatusMessage = "未能保存这次整理修改；请重试"
      }
    }
  }

  func answerRemoteQuestion(_ question: RemoteOrganizerQuestion, yes: Bool) {
    recordRemoteDecision(
      .init(
        kind: question.kind, questionID: question.questionID,
        a: question.a, b: question.b, answer: yes
      )
    )
  }

  func retryRemoteDecision(_ issue: RemoteOrganizerDecisionIssue) {
    guard let controller = remoteOrganizer else { return }
    Task { [weak self] in
      do { try await controller.retryDecision(issue.decisionID) } catch {
        self?.events.remoteStatusMessage = "未能重新发送；请稍后再试"
      }
    }
  }

  func discardRemoteDecision(_ issue: RemoteOrganizerDecisionIssue) {
    guard let controller = remoteOrganizer else { return }
    Task { [weak self] in
      do { try await controller.discardDecision(issue.decisionID) } catch {
        self?.events.remoteStatusMessage = "未能放弃这次修改；请稍后再试"
      }
    }
  }

  /// During development a root marked as synthetic is the only library that
  /// may be sent, so it never takes a portable archive of unknown provenance.
  var remoteOrganizerRefusesArchiveImport: Bool {
    guard !RemoteOrganizerDataProvenance.productReleaseAllowsOwnLibrary else { return false }
    guard let root = try? Self.applicationDataRoot() else { return true }
    let marker = root.appendingPathComponent(
      RemoteOrganizerDataProvenance.syntheticMarkerFileName
    )
    return (try? FileManager.default.attributesOfItem(atPath: marker.path)) != nil
  }

  func remoteOrganizerArchiveImported() async {
    guard let controller = remoteOrganizer else { return }
    if await controller.archiveImported() {
      remoteOrganizerEnabled = false
      Task { await controller.revokeStorage() }
      events.remoteStatusMessage = "导入归档后已关闭整理设备链路；导入的内容不会自动发送"
    }
  }

  private func applyRemoteOrganizerChange(
    status: RemoteOrganizerLinkController.Status,
    projection: RemoteOrganizerProjection?
  ) {
    let title = Self.remoteOrganizerStatusTitle(status)
    if events.remoteStatusMessage != title { events.remoteStatusMessage = title }
    if events.remoteProjection != projection {
      events.remoteProjection = projection
    }
    let clock = status == .connected ? remoteOrganizer?.serviceClock : nil
    if events.remoteServiceClock != clock { events.remoteServiceClock = clock }
    if let controller = remoteOrganizer, remoteOrganizerEnabled != controller.isEnabled {
      remoteOrganizerEnabled = controller.isEnabled
    }
  }

  static func remoteOrganizerStatusTitle(
    _ status: RemoteOrganizerLinkController.Status
  ) -> String {
    switch status {
    case .off: "已关闭；使用这台 Mac 整理"
    case .connecting: "正在连接你的整理设备"
    case .connected: "已连接你的整理设备"
    case .unavailable: "整理设备暂时不可用；待发内容保存在 Mac，恢复后自动补发"
    case .storageUnavailable: "整理链路状态暂不可读；未发送任何内容"
    case .refused(.refusedRealLibrary):
      "开发阶段不从你的真实资料库发送；请用合成演示资料库启动（-BestASRDataRoot）"
    case .refused(.refusedNotSynthetic):
      "当前资料库没有合成数据标记；开发阶段不发送"
    case .refused(.refusedLinkedStore):
      "合成资料库的数据库或资产是指向别处的链接；开发阶段不发送"
    case .refused(.allowed): "已关闭；使用这台 Mac 整理"
    }
  }

  static func remoteDecisionKindTitle(_ kind: String) -> String {
    switch kind {
    case "rename_event": "改标题"
    case "remove_item": "移出条目"
    case "move_item": "移动条目"
    case "same_event": "确认同一件事"
    case "same_person": "确认同一个人"
    case "name_person": "给人物命名"
    case "pin_event": "置顶"
    case "feature_less": "减少推荐"
    case "delete_event": "删除事件"
    default: "整理修改"
    }
  }

  static func remoteDecisionIssueTitle(_ issue: RemoteOrganizerDecisionIssue) -> String {
    let kind = remoteDecisionKindTitle(issue.kind)
    switch issue.state {
    case .deliveryUnknown:
      return "\(kind)：关闭链路时正在发送，可能已送达；重试以确认"
    case .notSent:
      switch issue.errorCategory {
      case "imported": return "\(kind)：从归档导入，未发送"
      case "store_reset": return "\(kind)：整理设备已重置，这项修改对应的内容已不在整理设备上"
      default: return "\(kind)：链路关闭时未发送"
      }
    case .rejected:
      let reason =
        switch issue.errorCategory {
        case "corrupt": "本机记录无法读取"
        case "rejected": "整理设备拒绝了这次修改"
        case "store_reset": "整理设备已重置"
        default:
          issue.errorCategory.hasPrefix("client:") ? "整理设备不接受这个内容" : "发送失败"
        }
      if let detail = issue.reason, !detail.isEmpty {
        return "整理设备未接受：\(kind)（\(reason)：\(detail)）"
      }
      return "整理设备未接受：\(kind)（\(reason)）"
    }
  }

  /// Records of launched ssh forwards, outside every library so that any
  /// launch can end an orphan left by a crash of another launch.
  static func remoteOrganizerStateDirectory() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    ).appendingPathComponent("bestASR-organizer-link", isDirectory: true)
  }
}
