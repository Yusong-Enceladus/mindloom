import AppKit
import BestASRDomain
import BestASRIntake
import BestASRRemoteOrganizer
import Combine
import Foundation
import SystemConfiguration

/// The paired iPhone as the settings page shows it (PHONE-CONTRACT §4–§5).
@MainActor
final class PhoneLinkModel: ObservableObject {
  /// The paired phone; nil when none.
  @Published var paired: PhonePairingState?
  /// The pairing code while its window is open. It holds the phone's
  /// private key: kept in memory only, dropped when the window closes.
  @Published var pairingCode: String?
  @Published var working = false
  @Published var statusMessage: String?
  /// "N 条手机内容无法打开（配对已更换）" and friends.
  @Published var droppedNotices: [String] = []

  var service: PhonePairingService?
  var stateFile: PhonePairingStateFile?

  func refreshDropped() {
    let counts = stateFile?.droppedCounts() ?? [:]
    droppedNotices = [RemoteOrganizerInboxDiscard.cannotOpen, .unusable].compactMap { reason in
      counts[reason].map { PhoneInboxDropNotice.text(reason, count: $0) }
    }
  }
}

/// "连接 iPhone" / "断开 iPhone" and the sealed phone inbox. The pairing and
/// sealing logic lives in BestASRRemoteOrganizer and BestASRIntake; this
/// file only maps it to the settings page.
extension DictationAppModel {
  /// Where `zhiji-inbox` lives on the organizing device (one safe path).
  static let phoneInboxCommandPreferenceKey = "preferences.spark-organizer-inbox-command"

  /// Called with the organizing device's validated ssh alias once the link
  /// is configured for this data root.
  func configurePhoneLink(host: String, dataRoot: URL, stateDirectory: URL) {
    let stateFile = PhonePairingStateFile(stateDirectory: stateDirectory, dataRoot: dataRoot)
    phoneLink.stateFile = stateFile
    phoneLink.paired = stateFile.load()
    phoneLink.refreshDropped()
    do {
      let settings = try PhonePairingSettings(
        sparkHost: host,
        inboxCommand: LocalPreferenceStore.string(
          Self.phoneInboxCommandPreferenceKey,
          default: PhoneLinkSSHCommand.defaultInboxCommand))
      phoneLink.service = PhonePairingService(
        settings: settings, runner: ProcessPhoneLinkCommandRunner(),
        // The seal key sits next to the link key in the login Keychain.
        sealKeys: KeychainPhoneSealKeyStore(dataRoot: dataRoot))
    } catch {
      phoneLink.service = nil
      phoneLink.statusMessage = "iPhone 的连接设置无效，无法连接 iPhone"
    }
  }

  /// "连接 iPhone" is offered only while the link is on.
  var canConnectIPhone: Bool {
    remoteOrganizerEnabled && phoneLink.service != nil && !phoneLink.working
  }

  func connectIPhone() {
    guard remoteOrganizerEnabled else {
      phoneLink.statusMessage = "先打开上面的整理设备链路，再连接 iPhone"
      return
    }
    guard let service = phoneLink.service, !phoneLink.working else { return }
    let previous = phoneLink.paired
    // The Mac's name as set in System Settings; `Host.current()` can wait on
    // the network.
    let label = SCDynamicStoreCopyComputerName(nil, nil) as String?
    phoneLink.working = true
    phoneLink.statusMessage = "正在连接 iPhone…"
    Task { [weak self] in
      do {
        let pairing = try await service.pair(label: label, replacing: previous)
        guard let self else { return }
        do {
          try phoneLink.stateFile?.save(pairing.state)
        } catch {
          // A key this Mac cannot remember could never be removed: take it
          // back now instead of showing the code.
          try? await service.revoke(pairing.state)
          if previous != nil { try? phoneLink.stateFile?.clear() }
          phoneLink.paired = nil
          phoneLink.statusMessage = "这台 Mac 记不下配对信息；没有连接 iPhone"
          phoneLink.working = false
          return
        }
        phoneLink.paired = pairing.state
        phoneLink.pairingCode = pairing.code
        phoneLink.statusMessage = nil
        phoneLink.working = false
      } catch {
        guard let self else { return }
        if previous != nil, case PhonePairingError.authorizeFailed = error {
          // The previous phone was already disconnected before the new key
          // failed to install.
          try? phoneLink.stateFile?.clear()
          phoneLink.paired = nil
        }
        phoneLink.statusMessage = Self.phonePairingMessage(error)
        phoneLink.working = false
      }
    }
  }

  /// "复制配对码": the code on the pasteboard, marked concealed so clipboard
  /// managers do not keep it and marked as bestASR's own so ⌘V here does not
  /// take it in.
  func copyPhonePairingCode() {
    guard let code = phoneLink.pairingCode else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(code, forType: .string)
    item.setData(Data(), forType: IntakePasteboardMarks.concealed)
    item.setData(Data(), forType: IntakePasteboardMarks.ownOrigin)
    pasteboard.writeObjects([item])
    phoneLink.statusMessage = "配对码已复制；在 iPhone 的织机里粘贴"
  }

  /// Closes the pairing code window; the code (and the phone's private key
  /// in it) is forgotten.
  func finishPhonePairingCode() {
    phoneLink.pairingCode = nil
  }

  func disconnectIPhone() {
    guard let state = phoneLink.paired, let service = phoneLink.service, !phoneLink.working
    else { return }
    phoneLink.working = true
    phoneLink.statusMessage = "正在断开 iPhone…"
    Task { [weak self] in
      do {
        try await service.revoke(state)
        guard let self else { return }
        try? phoneLink.stateFile?.clear()
        phoneLink.paired = nil
        phoneLink.pairingCode = nil
        phoneLink.statusMessage = "已断开 iPhone；它的钥匙已从整理设备上删除"
      } catch {
        self?.phoneLink.statusMessage = Self.phonePairingMessage(error)
      }
      self?.phoneLink.working = false
    }
  }

  /// A sealed phone entry was dropped after the organizing device deleted it.
  func phoneInboxDiscarded(_ reason: RemoteOrganizerInboxDiscard) {
    phoneLink.stateFile?.recordDropped(reason)
    phoneLink.refreshDropped()
  }

  func dismissPhoneDropNotices() {
    phoneLink.stateFile?.clearDropped()
    phoneLink.refreshDropped()
  }

  static func phonePairingMessage(_ error: any Error) -> String {
    guard let error = error as? PhonePairingError else { return "没有连接 iPhone；请稍后再试" }
    switch error {
    case .invalidConfiguration:
      return "iPhone 的连接设置无效，无法连接 iPhone"
    case .sshConfigUnreadable(.spark):
      return "读不到这台 Mac 连整理设备的 SSH 设置"
    case .sshConfigUnreadable(.relay):
      return "读不到这台 Mac 连中转主机的 SSH 设置"
    case .unsupportedProxy:
      return "SSH 设置里的中转方式手机用不了（只支持一层 ProxyJump）"
    case .invalidEndpoint:
      return "整理设备的主机名或用户名不能交给手机使用"
    case .hostKeyMissing(.spark):
      return "known_hosts 里没有整理设备的 ed25519 或 ECDSA 钥匙；先用 ssh 连一次再配对"
    case .hostKeyMissing(.relay):
      return "known_hosts 里没有中转主机的 ed25519 或 ECDSA 钥匙；先用 ssh 连一次再配对"
    case .sealKeyUnavailable:
      return "钥匙串暂不可用；没有连接 iPhone"
    case .previousNotRevoked:
      return "之前那台 iPhone 的钥匙没能删除，新的没有装上；请稍后再试"
    case .authorizeFailed(.spark):
      return "没能把 iPhone 的钥匙装到整理设备上；请确认链路能连上"
    case .authorizeFailed(.relay):
      return "没能把 iPhone 的钥匙装到中转主机上；整理设备上的也已撤回"
    case .revokeFailed(.spark):
      return "未能断开：整理设备暂时连不上；iPhone 的钥匙仍然有效，请稍后再试"
    case .revokeFailed(.relay):
      return "未能断开：中转主机暂时连不上；iPhone 的钥匙仍然有效，请稍后再试"
    }
  }
}
