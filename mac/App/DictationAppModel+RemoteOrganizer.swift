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
    "未设置 DGX Spark 地址，无法连接"

  /// The user's own Spark, as an ssh host name or alias. There is no built-in
  /// host: nil until the user writes the preference (in demo mode, until the
  /// demo root's profile names one).
  static func configuredRemoteOrganizerHost() -> String? {
    remoteOrganizerHost(preference: LibraryIdentity.organizerHost)
  }

  nonisolated static func remoteOrganizerHost(preference: String?) -> String? {
    let host = (preference ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return host.isEmpty ? nil : host
  }

  /// Called once the durable library is open, with the exact root the store
  /// was opened on.
  func configureRemoteOrganizer(repository: GRDBDictationStore, dataRoot: URL) {
    guard remoteOrganizer == nil else { return }
    // What was organized before is shown at once, link or no link (offline
    // mirror; `RemoteOrganizerMirror`). The live projection replaces it once
    // the link has one. Corrections a crash left held are sent once the
    // mirror says where they go (DGX Spark decisions or the local organizer).
    Task { [weak self] in
      await self?.reloadRemoteMirrorNow(repository: repository)
      self?.memoryCorrections.replayLeftovers()
    }
    guard let realLibrary = BestASRDataRootSelection.ownerRealLibraryRoot(),
      let stateDirectory = try? Self.remoteOrganizerStateDirectory()
    else {
      events.remoteStatusMessage = "无法读取 DGX Spark 连接状态，未发送内容"
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
        remoteSocketPath: LibraryIdentity.organizerSocketPath(
          default: RemoteOrganizerLinkConfiguration.defaultRemoteSocketPath),
        remoteTokenPath: LibraryIdentity.organizerTokenPath(
          default: RemoteOrganizerLinkConfiguration.defaultRemoteTokenPath)
      )
    } catch {
      // Fail closed: the toggle shows off, so the library must be off too, or
      // a later launch with a valid configuration would send the backlog.
      try? intent.clearOn()
      Task { try? await repository.revokeRemoteLink() }
      events.remoteStatusMessage = "DGX Spark 连接设置无效，已关闭连接；使用这台 Mac 整理"
      return
    }
    let repositoryForInbox = repository
    let controller = RemoteOrganizerLinkController(
      repository: repository,
      dataRoot: dataRoot,
      realLibraryRoot: realLibrary,
      intent: intent,
      // The library's link key lives in the login Keychain, this Mac only
      // (privacy contract §1); it reaches the organizing device only in
      // memory, through the user's own SSH forward.
      // (Demo mode on a marked synthetic root: the root's key file.)
      keyStore: MindloomBuild.organizerKeyStore(dataRoot: dataRoot),
      cleanUpStaleTunnels: {
        _ = RemoteOrganizerTunnelRecordStore(directory: stateDirectory).cleanUpStale()
      },
      makeRuntime: { [weak self] repository, keys, onUpdate in
        RemoteOrganizerRuntime(
          repository: repository,
          launcher: SSHRemoteOrganizerTunnelLauncher(
            configuration: configuration, stateDirectory: stateDirectory
          ),
          http: URLSessionRemoteOrganizerTransport(),
          keys: keys,
          // Image items are read from this provenance-checked root only.
          itemAssetReader: RemoteOrganizerItemAssetReader(
            assetRoot: dataRoot.appendingPathComponent("assets", isDirectory: true)
          ),
          // What leaves is the redacted copy: numbers read on this Mac are
          // painted over first (contract §4).
          imageRedactor: VisionSendCopyRedactor(),
          // A file's bytes leave as a send copy: pictures in it redacted,
          // recordings in it emptied (privacy review F3).
          fileSanitizer: FileSendCopySanitizer(),
          // What the phone sent to the organizing device comes in through
          // the same intake as a paste; sealed entries are opened here with
          // this library's phone seal key (PHONE-CONTRACT §5).
          // v11 Settings › 入口 「iPhone 键盘和分享」 off: what the phone sends
          // stays on the DGX Spark. Checked on every delivery, so the switch
          // applies at once, not when the link next connects (fix-mac).
          inbox: self?.remoteInboxIngestor(store: repositoryForInbox, dataRoot: dataRoot)
            .map { PhoneEntrySwitch(base: $0) },
          onUpdate: onUpdate
        ).withInboxDiscardHandler { [weak self] reason in
          self?.phoneInboxDiscarded(reason)
        }
      }
    )
    controller.onChange = { [weak self] status, projection in
      self?.applyRemoteOrganizerChange(status: status, projection: projection)
    }
    remoteOrganizer = controller
    RemoteOrganizerQuitLock.controller = controller
    configurePhoneLink(host: host, dataRoot: dataRoot, stateDirectory: stateDirectory)
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
        : "资料库尚未打开，DGX Spark 连接保持关闭"
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

  /// "让整理设备忘掉我的内容" (the contract's "让 Spark 忘掉我的内容"; pages
  /// say 整理设备, never Spark) or, when the organizing device holds another
  /// key's store, "让整理设备忘掉旧内容", after the user confirmed.
  func forgetRemoteOrganizerContent() {
    guard let controller = remoteOrganizer, controller.canForget else {
      events.remoteStatusMessage = "连接 DGX Spark 后才能删除其中的内容"
      return
    }
    let target: RemoteOrganizerLinkController.ForgetTarget
    if case .wrongKey(let other?) = controller.status {
      target = .otherKey(other)
    } else {
      target = .mine
    }
    remoteOrganizerForgetting = true
    Task { [weak self] in
      let outcome = await controller.forgetOnOrganizer(target)
      guard let self else { return }
      remoteOrganizerForgetting = false
      switch outcome {
      case .forgotten:
        events.remoteStatusMessage =
          target == .mine
          ? "已删除 DGX Spark 上你的内容，旧密钥已销毁；之后发送新的或更改过的记录"
          : "已删除 DGX Spark 上的旧内容；现在使用这台 Mac 的密钥整理"
      case .notConnected:
        events.remoteStatusMessage = "DGX Spark 未连接，其中的内容未删除"
      case .refused:
        events.remoteStatusMessage = "DGX Spark 未确认删除，你的内容保持不变。请稍后再试。"
      case .storageUnavailable:
        events.remoteStatusMessage = "已删除 DGX Spark 上的内容，但这台 Mac 未能记录此操作。请重新连接。"
      case .keyNotDestroyed:
        events.remoteStatusMessage = "已删除 DGX Spark 上的内容，但未能销毁这台 Mac 上的旧密钥。连接已暂停，旧密钥已停用。"
      }
    }
  }

  /// The phone entry's inbox behind Settings › 入口 「iPhone 键盘和分享」: while
  /// it is off, nothing is taken in and each entry stays on the DGX Spark
  /// (the pull stops at the first one and tries again on the next poll).
  struct PhoneEntrySwitch: RemoteOrganizerInboxIngesting {
    struct Off: Error {}
    let base: IntakeInboxIngestor
    // `DictationAppModel.iphoneEntryKey` (read off the main actor).
    static let key = "preferences.v11.iphone-entry"

    func ingest(_ entry: RemoteOrganizerInboxEntry) async throws -> RemoteOrganizerInboxOutcome {
      let on = UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
      guard on else { throw Off() }
      return try await base.ingest(entry)
    }
  }

  /// The phone entry's inbox, taken in like a paste (nil until intake is
  /// configured). Sealed entries open with this library's phone seal key
  /// from the Keychain. After each new item the lists refresh.
  func remoteInboxIngestor(store: GRDBDictationStore, dataRoot: URL) -> IntakeInboxIngestor? {
    guard let processor = intakeProcessor else { return nil }
    let ready = intakeReady
    let sealKeys = KeychainPhoneSealKeyStore(dataRoot: dataRoot)
    return IntakeInboxIngestor(
      processor: processor, store: store,
      sealKey: { try sealKeys.load() },
      ready: { await ready?.value },
      committed: { [weak self] _ in
        // Settings › iPhone: 「最近一次送来 21:58」.
        await MainActor.run { CaptureState.shared.recordPhoneDelivery() }
        await self?.refreshHistoryItems(preserveStatus: true, organizeEvents: true)
      })
  }

  func enqueueRemoteSessionIfEnabled(_ sessionID: SessionID) async {
    guard let controller = remoteOrganizer, controller.isEnabled else { return }
    do {
      try await controller.enqueueCompletedSession(sessionID)
    } catch {
      events.remoteStatusMessage = "暂时无法读取待发送的整理内容；本机记录已保留"
    }
  }

  func recordRemoteDecision(_ decision: RemoteOrganizerDecision) {
    guard let controller = remoteOrganizer, controller.isEnabled else {
      // The offline mirror is shown: kept and applied here, never sent
      // unless the user retries it with the link on.
      if events.remoteProjection != nil, decision.isWellFormed {
        Task { [weak self] in await self?.recordOfflineDecision(decision) }
      }
      return
    }
    guard decision.isWellFormed else {
      events.remoteStatusMessage =
        switch decision.kind {
        case "rename_event": "标题需为 1–\(RemoteOrganizerDecision.maximumTitleScalars) 个字"
        case "rename_rope": "名称需为 1–\(Self.maximumTitleLength) 个字"
        default: "此次整理修改不完整，未保存"
        }
      return
    }
    Task { [weak self] in
      do { try await controller.record(decision) } catch {
        self?.events.remoteStatusMessage = "未能保存此次整理修改。请重试。"
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
        self?.events.remoteStatusMessage = "未能重新发送。请稍后再试。"
      }
    }
  }

  func discardRemoteDecision(_ issue: RemoteOrganizerDecisionIssue) {
    guard let controller = remoteOrganizer else { return }
    Task { [weak self] in
      do { try await controller.discardDecision(issue.decisionID) } catch {
        self?.events.remoteStatusMessage = "未能放弃此次修改。请稍后再试。"
      }
    }
  }

  /// Welcome's DGX Spark card can connect: a Spark is named (the link
  /// exists) and this library may be sent from here (during development, a
  /// root marked synthetic only). Otherwise Welcome leaves the card out
  /// rather than offer 连接 that cannot work (review of 10-6).
  var remoteOrganizerCanConnect: Bool {
    guard remoteOrganizer != nil, let root = try? Self.applicationDataRoot(),
      let realLibrary = BestASRDataRootSelection.ownerRealLibraryRoot()
    else { return false }
    return RemoteOrganizerDataProvenance.verdict(dataRoot: root, realLibraryRoot: realLibrary)
      == .allowed
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
      events.remoteStatusMessage = "导入归档后已关闭 DGX Spark 连接；导入的内容暂未发送"
    }
  }

  private func applyRemoteOrganizerChange(
    status: RemoteOrganizerLinkController.Status,
    projection: RemoteOrganizerProjection?
  ) {
    let title = Self.remoteOrganizerStatusTitle(status)
    if events.remoteStatusMessage != title { events.remoteStatusMessage = title }
    if remoteOrganizerLinkStatus != status { remoteOrganizerLinkStatus = status }
    if let projection {
      if events.remoteProjection != projection {
        events.remoteProjection = projection
        if status == .connected { remoteOrganizerLastPull = Date() }
      }
    } else {
      // Off, revoked or not pulled yet: the library's mirror (nil once the
      // DGX Spark forgot the store), never an empty Home in between.
      reloadRemoteMirror()
    }
    let clock = status == .connected ? remoteOrganizer?.serviceClock : nil
    if events.remoteServiceClock != clock { events.remoteServiceClock = clock }
    let canForget = remoteOrganizer?.canForget ?? false
    if remoteOrganizerCanForget != canForget { remoteOrganizerCanForget = canForget }
    let holdsOtherKey: Bool
    if case .wrongKey = status { holdsOtherKey = true } else { holdsOtherKey = false }
    if remoteOrganizerHoldsOtherKey != holdsOtherKey {
      remoteOrganizerHoldsOtherKey = holdsOtherKey
    }
    if let controller = remoteOrganizer, remoteOrganizerEnabled != controller.isEnabled {
      remoteOrganizerEnabled = controller.isEnabled
    }
  }

  /// The longest name the organizer takes for a renamed grouping.
  static var maximumTitleLength: Int { RemoteOrganizerDecision.maximumRopeTitleScalars }

  static func remoteOrganizerStatusTitle(
    _ status: RemoteOrganizerLinkController.Status
  ) -> String {
    switch status {
    case .off: "已关闭；使用这台 Mac 整理"
    case .connecting: "正在连接你的 DGX Spark"
    case .connected: "已连接你的 DGX Spark"
    case .unavailable: "DGX Spark 暂时不可用；待发送的内容保存在这台 Mac 上，恢复后自动发送"
    case .storageUnavailable: "暂时无法读取连接状态，未发送内容"
    case .wrongKey: "DGX Spark 上的内容属于另一个密钥，未发送内容"
    case .unsupportedService: "DGX Spark 无法加密储存内容，未发送内容"
    case .keyUnavailable: "这台 Mac 暂时无法保存，未发送内容"
    case .refused(.refusedRealLibrary):
      "开发阶段不从真实资料库发送内容。如需试用，请以演示方式打开演示资料库"
    case .refused(.refusedNotSynthetic):
      "当前资料库没有合成数据标记；开发阶段不发送内容"
    case .refused(.refusedLinkedStore):
      "合成资料库的数据库或资源指向其他位置；开发阶段不发送内容"
    case .refused(.allowed): "已关闭；使用这台 Mac 整理"
    }
  }

  static func remoteDecisionKindTitle(_ kind: String) -> String {
    switch kind {
    case "rename_event": "更改标题"
    case "remove_item": "移出条目"
    case "move_item": "移动条目"
    case "same_event": "确认同一件事"
    case "same_person": "确认同一个人"
    case "name_person": "给人物命名"
    case "pin_event": "置顶"
    case "feature_less": "减少推荐"
    case "delete_event": "删除这件事"
    case "confirm_rope": "确认分组"
    case "reject_rope": "移出分组"
    case "rename_rope": "重新命名"
    case "move_to_rope": "移动事"
    case "reject_relation": "移除等待"
    case "hide_crossing": "隐藏相关"
    default: "整理修改"
    }
  }

  static func remoteDecisionIssueTitle(_ issue: RemoteOrganizerDecisionIssue) -> String {
    let kind = remoteDecisionKindTitle(issue.kind)
    switch issue.state {
    case .deliveryUnknown:
      return "\(kind)：关闭连接时正在发送，可能已送达。请重试以确认"
    case .notSent:
      switch issue.errorCategory {
      case "imported": return "\(kind)：从归档导入，未发送"
      case "store_reset": return "\(kind)：DGX Spark 已重置，这项修改对应的内容已不在 DGX Spark 上"
      default: return "\(kind)：连接关闭时未发送"
      }
    case .rejected:
      let reason =
        switch issue.errorCategory {
        case "corrupt": "本机记录无法读取"
        case "rejected": "DGX Spark 拒绝了这次修改"
        case "store_reset": "DGX Spark 已重置"
        default:
          issue.errorCategory.hasPrefix("client:") ? "DGX Spark 不接受这个内容" : "发送失败"
        }
      if let detail = issue.reason, !detail.isEmpty {
        return "DGX Spark 未接受：\(kind)（\(reason)：\(detail)）"
      }
      return "DGX Spark 未接受：\(kind)（\(reason)）"
    }
  }

  /// Records of launched ssh forwards, outside every library so that any
  /// launch can end an orphan left by a crash of another launch.
  static func remoteOrganizerStateDirectory() throws -> URL {
    // Each build, and demo mode, keeps its own (link-on files, ssh tunnel
    // records and the iPhone pairing never sit beside the product's).
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true
    ).appendingPathComponent(MindloomBuild.organizerLinkStateFolderName(), isDirectory: true)
  }
}

extension DictationAppModel {
  /// 重新连接 (Home's offline line, the menu bar extra, Settings): turns the
  /// link on when it is off, else asks the running link to try again now.
  func reconnectRemoteOrganizer() {
    guard let controller = remoteOrganizer else { return }
    if controller.isEnabled {
      controller.resumeAfterSleep()
    } else {
      Task { await controller.setEnabled(true) }
    }
  }

  /// Records a decision and returns once it is durable in the library (the
  /// undo window's commit; `recordRemoteDecision` does not wait).
  func recordRemoteDecisionAndWait(_ decision: RemoteOrganizerDecision) async {
    guard decision.isWellFormed else { return }
    guard let controller = remoteOrganizer, controller.isEnabled else {
      await recordOfflineDecision(decision)
      return
    }
    do { try await controller.record(decision) } catch {
      events.remoteStatusMessage = "未能保存这次修改；请重试"
    }
  }

  /// A correction while the offline mirror is shown (link off, or no DGX
  /// Spark named): the library keeps it and the mirror shows it applied; it
  /// is not sent unless the user retries it once the link is on
  /// (`enqueueRemoteDecision`).
  func recordOfflineDecision(_ decision: RemoteOrganizerDecision) async {
    guard let repository, events.remoteProjection != nil else { return }
    do {
      try await repository.enqueueRemoteDecision(decision)
    } catch {
      events.remoteStatusMessage = "未能保存这次修改；请重试"
      return
    }
    await reloadRemoteMirrorNow(repository: repository)
  }

  /// Shows the live projection, else the library's mirror (`RemoteOrganizerMirror`).
  func reloadRemoteMirror(repository: GRDBDictationStore? = nil) {
    guard let repository = repository ?? self.repository else { return }
    Task { [weak self] in await self?.reloadRemoteMirrorNow(repository: repository) }
  }

  func reloadRemoteMirrorNow(repository: GRDBDictationStore) async {
    let stored = await RemoteOrganizerMirror.stored(in: repository)
    // Read after the await: a live projection that arrived meanwhile wins.
    let shown = RemoteOrganizerMirror.shown(live: remoteOrganizer?.projection, stored: stored)
    if events.remoteProjection != shown { events.remoteProjection = shown }
  }
}
