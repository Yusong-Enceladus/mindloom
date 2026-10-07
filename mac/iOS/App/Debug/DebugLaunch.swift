#if DEBUG
  import CoreImage.CIFilterBuiltins
  import CryptoKit
  import Foundation
  import ImageIO
  import MindloomDesign
  import MindloomInboxSSH
  import MindloomLink
  import MindloomPhoneKit
  import SwiftUI
  import UIKit
  import UniformTypeIdentifiers

  /// DEBUG builds only: launch arguments that put the app into each PHONE-SPEC state with
  /// synthetic data, for the screenshot harness (never compiled into Release).
  ///
  /// - `-MindloomScreen <state>`: a §4 state id (`home`, `home-offline`, `note-listen`,
  ///   `welcome-t0.3-rm`, `settings-disconnect`, …). It wipes the simulator app's own container
  ///   and seeds the prototype's nine synthetic items, a synthetic pairing (「小林的 MacBook Pro」,
  ///   since 9月18日) and the synthetic photos.
  /// - `-MindloomSeedPhotos <dir>`: where the synthetic photos are (default: the v9 prototype's
  ///   `assets/photos`, synthetic images).
  /// - `-MindloomDebugLoopbackDelivery`: an in-process Mac that accepts after 1.5 s.
  /// - `-MindloomDebugOffline`: no route to the Mac.
  enum DebugLaunch {
    static let arguments = ProcessInfo.processInfo.arguments

    static func value(_ flag: String) -> String? {
      guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        return nil
      }
      return arguments[index + 1]
    }

    /// The state id, its frozen time (`-t2.62`) and reduced motion (`-rm`).
    struct Screen {
      var base: String
      var time: Double?
      var reduced: Bool
    }

    static let screen: Screen? = {
      guard var raw = value("-MindloomScreen") else { return nil }
      var reduced = false
      if raw.hasSuffix("-rm") {
        reduced = true
        raw = String(raw.dropLast(3))
      }
      var time: Double?
      if let range = raw.range(of: "-t", options: .backwards),
        let t = Double(raw[range.upperBound...])
      {
        time = t
        raw = String(raw[..<range.lowerBound])
      }
      return Screen(base: raw, time: time, reduced: reduced)
    }()

    static var base: String { screen?.base ?? "" }

    /// The scripted talk: press at 0.30 s, release at 4.00 s (PHONE-SPEC §4).
    static let pressAt = 0.30
    static let releaseAt = 4.00

    static var isNote: Bool { base.hasPrefix("note-") }

    static var frozenTime: TimeInterval? {
      guard let screen else { return nil }
      if base == "welcome" { return screen.time ?? (screen.reduced ? 0.3 : 9) }
      if isNote {
        if let t = screen.time { return t }
        switch base {
        case "note-loosen": return 0.72
        case "note-saved": return 5.6
        default: return 2.62
        }
      }
      return nil
    }

    static var reduceMotion: Bool? { screen?.reduced == true ? true : nil }

    static var microphone: VoiceSessionModel.Microphone? {
      guard screen != nil else { return nil }
      switch base {
      case "home-nomic": return .denied
      case "permissions", "welcome", "pair", "pair-camera", "pair-found", "pair-paste":
        return .undetermined
      case "permissions-mic": return nil
      default: return .granted
      }
    }

    static var keyboard: (added: Bool, fullAccess: Bool)? {
      guard screen != nil else { return nil }
      switch base {
      case "permissions", "permissions-mic": return (false, false)
      case "settings-keyboard-off": return (true, false)
      default: return (true, true)
      }
    }

    static var syntheticCamera: Bool { base.hasPrefix("pair") }
    static var asksForCamera: Bool { base == "pair-camera" }
    static var opensDisconnectSheet: Bool { base == "settings-disconnect" }
    static var openPrivacyRow: Int? { base == "settings-privacy-open" ? 1 : nil }
    static var scrollOffset: CGFloat? {
      base == "home-expanded" || base == "home-scrolled" ? 470 : nil
    }
    static var pastedCode: String? { base == "pair-paste" ? pairingText : nil }

    /// Seeded item ids by prototype label (a1 … c2).
    nonisolated(unsafe) static var ids: [String: String] = [:]

    static func deliveryOpener() -> (any InboxSessionOpening)? {
      if autoTalk != nil { return DebugLoopbackOpener(delay: .milliseconds(1500)) }
      if screen != nil {
        switch base {
        case "home-offline", "settings-disconnect": return DebugOfflineOpener()
        default: return DebugLoopbackOpener(delay: .seconds(3600))
        }
      }
      if arguments.contains("-MindloomDebugOffline") { return DebugOfflineOpener() }
      if arguments.contains("-MindloomDebugLoopbackDelivery") {
        return DebugLoopbackOpener(delay: .milliseconds(1500))
      }
      return nil
    }

    // MARK: - Storage

    /// `-MindloomDebugStorageListing <path>` (relative to the app's home directory): after the
    /// storage migration, writes the relative paths and sizes under the storage root (the App
    /// Group) and under the old private Application Support to `<path>`. Names and sizes only,
    /// never contents. Xcode 27's devicectl lists only Library, Documents and tmp of an App Group
    /// container, so this is the only way to see `items/`, `outbox/` and `pairing.json` there.
    static func writeStorageListing(storage: PhoneAppGroup.StorageRoot) {
      guard let path = value("-MindloomDebugStorageListing") else { return }
      let fm = FileManager.default
      func lines(under root: URL?, label: String) -> [String] {
        guard let root else { return ["[\(label)] unavailable"] }
        var out = ["[\(label)]"]
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: keys) else {
          return out + ["  (not readable)"]
        }
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in walk {
          let relative = url.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "")
          if relative == "Library" || relative.hasPrefix("Library/") {
            if relative == "Library" { walk.skipDescendants() }
            continue
          }
          let values = try? url.resourceValues(forKeys: Set(keys))
          out.append(
            values?.isDirectory == true
              ? "  \(relative)/" : "  \(relative) \(values?.fileSize ?? -1)")
        }
        return out
      }
      let text =
        (lines(under: storage.url, label: storage.isShared ? "app group" : "private storage")
        + lines(under: PhoneAppGroup.privateApplicationSupport(), label: "old private storage"))
        .joined(separator: "\n") + "\n"
      let target = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent(path)
      try? fm.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? Data(text.utf8).write(to: target, options: .atomic)
    }

    /// With `-MindloomScreen`: start from an empty app (this simulator app's own container only).
    static func prepareStorage() {
      guard screen != nil, let root = try? PhoneAppGroup.storageRoot() else { return }
      let fm = FileManager.default
      for name in ["items", "outbox", "pairing.json", "keyboard.json"] {
        try? fm.removeItem(at: root.url.appendingPathComponent(name))
      }
      PhoneKeyKeychain().delete()
      if root.isShared {
        UserDefaults(suiteName: PhoneAppGroup.identifier)?.removePersistentDomain(
          forName: PhoneAppGroup.identifier)
      }
      UserDefaults.standard.removeObject(forKey: "app.welcome_done")
    }

    // MARK: - Seed

    static let macName = "小林的 MacBook Pro"
    static let macKey = Curve25519.KeyAgreement.PrivateKey()

    static let pairingText: String = {
      let hostLine = PairingPayload.openSSHPublicKey(Curve25519.Signing.PrivateKey().publicKey)
      let payload = try! PairingPayload(
        label: macName,
        spark: PairingEndpoint(
          host: "mac.example", port: 22, user: "mindloom",
          hostKey: SSHHostKey(openSSH: hostLine)!),
        relay: nil, phoneKey: Curve25519.Signing.PrivateKey().rawRepresentation,
        phoneKeyID: "phone-0918", macSealPublicKey: macKey.publicKey.rawRepresentation)
      return try! payload.encodedText()
    }()

    struct SeedItem {
      let label: String
      let day: Int
      let time: (Int, Int)
      let kind: PhoneItem.Kind
      let source: PhoneItem.Source
      var text: String? = nil
      var photos: [String] = []
      var link: (title: String, url: String, image: String)? = nil
    }

    static let items: [SeedItem] = [
      SeedItem(
        label: "a1", day: 0, time: (9, 41), kind: .text, source: .keyboard,
        text: "明天下午三点在三楼会议室开会，我带上季度预算表。"),
      SeedItem(
        label: "a2", day: 0, time: (9, 20), kind: .photos, source: .share,
        photos: ["whiteboard", "slide", "book"]),
      SeedItem(
        label: "a3", day: 0, time: (8, 55), kind: .link, source: .share,
        link: ("老旧小区改造的五个误区", "https://mp.weixin.qq.com/s/synthetic-demo", "building")),
      SeedItem(
        label: "a4", day: 0, time: (8, 31), kind: .text, source: .voice,
        text: "周五之前把中期考核报告初稿发给导师，顺便问一下推荐信的事。"),
      SeedItem(
        label: "b1", day: 1, time: (21, 14), kind: .photos, source: .share, photos: ["receipt"]),
      SeedItem(
        label: "b2", day: 1, time: (18, 2), kind: .text, source: .voice,
        text: "嘉禾的推荐信下周三前要交，先让他把草稿发我。远湖那边说协议盖章要走两周流程，数据可以先用，但论文里先别写合作方的名字，等批复下来再说。"),
      SeedItem(
        label: "b3", day: 1, time: (16, 40), kind: .text, source: .share,
        text: "读书会改到周四下午两点，地点不变。"),
      SeedItem(
        label: "c1", day: 3, time: (20, 15), kind: .text, source: .keyboard,
        text: "好的，周四读书会我讲 FlowFlow，幻灯片晚上发群里。"),
      SeedItem(
        label: "c2", day: 3, time: (18, 47), kind: .photos, source: .share,
        photos: ["sunset", "mountains"]),
    ]

    static func date(day: Int, _ time: (Int, Int)) -> Date {
      let calendar = Calendar.current
      let today = calendar.startOfDay(for: Date())
      let day = calendar.date(byAdding: .day, value: -day, to: today)!
      return calendar.date(bySettingHour: time.0, minute: time.1, second: 0, of: day)!
    }

    @MainActor
    static func seed(pairing: PairingModel, collector: PhoneItemCollector, settings: PhoneSettings) {
      guard screen != nil else { return }
      let fresh = ["welcome", "pair", "pair-camera", "pair-found", "pair-paste"]
      if fresh.contains(base) { return }
      let notPaired = base == "home-notpaired"
      if !notPaired {
        _ = try? pairing.pair(text: pairingText)
        settings.pairedAt = date(day: 14, (10, 0)).settingMonthDay(9, 18)
        settings.welcomeDone = true
      } else {
        settings.welcomeDone = true
      }
      if base.hasPrefix("permissions") || base == "home-empty" { return }
      var pending: Set<String> = []
      var list = items
      switch base {
      case "home-sending", "home-disconnected", "settings-disconnect": pending = ["a1", "a2"]
      case "home-offline": pending = ["o1", "a1", "a2"]
      case "home-notpaired": list = Array(items.prefix(2))
      case "home-menu": pending = ["a1"]
      default: break
      }
      if base == "home-offline" {
        list.insert(
          SeedItem(
            label: "o1", day: 0, time: (9, 44), kind: .text, source: .voice,
            text: "给爸妈的机票改到10月3日上午，记得问一下行李额度。"), at: 0)
      }
      if base == "note-saved" {
        list.insert(
          SeedItem(
            label: "n1", day: 0, time: (9, 41), kind: .text, source: .voice,
            text: "组会改到周三下午，记得提前订会议室。"),
          at: 0)
        pending = ["n1"]
      }
      let photos = value("-MindloomSeedPhotos") ?? "/Users/Shared/mindloom-demo/v9/phone/assets/photos"
      for seed in list.reversed() {
        // the new item at 9:41 is still the newest
        let at = date(day: seed.day, seed.time).addingTimeInterval(
          seed.label == "n1" || seed.label == "o1" ? 30 : 0)
        var item = PhoneItem(createdAt: at, kind: seed.kind, source: seed.source, text: seed.text)
        var payloads: [InboxItemPayload] = []
        switch seed.kind {
        case .text:
          payloads = [try! InboxItemPayload.text(seed.text!, source: seed.source.payloadSource, createdAt: at)]
        case .photos:
          item.photoCount = seed.photos.count
          for (index, name) in seed.photos.enumerated() {
            guard let jpeg = jpeg(at: "\(photos)/\(name).png", maxPixels: 1280) else { continue }
            try? collector.items.writePreview(jpeg, id: item.id, index: index)
            if let payload = try? InboxItemPayload.image(
              jpeg, mime: "image/jpeg", source: .share, createdAt: at)
            {
              payloads.append(payload)
            }
          }
        case .link:
          let link = seed.link!
          item.link = PhoneItem.Link(url: link.url, title: link.title)
          if let jpeg = jpeg(at: "\(photos)/\(link.image).png", maxPixels: 400) {
            try? collector.items.writePreview(jpeg, id: item.id, index: 0)
          }
          payloads = [
            try! InboxItemPayload.link(
              URL(string: link.url)!, title: link.title, source: .share, createdAt: at)
          ]
        case .file:
          break
        }
        guard !payloads.isEmpty, let saved = try? collector.collect(item, payloads: payloads, now: at)
        else { continue }
        ids[seed.label] = saved.id
        if !pending.contains(seed.label) {
          for entryID in saved.entryIDs {
            try? collector.outbox.markSent(id: entryID, at: at.addingTimeInterval(4))
          }
        }
      }
      settings.lastSentAt = date(day: 0, (9, 41))
      if base == "home-disconnected" {
        pairing.unpair()
        settings.disconnected = true
      }
    }

    /// A metadata-free JPEG of a synthetic image, at most `maxPixels` on its long side.
    static func jpeg(at path: String, maxPixels: Int) -> Data? {
      guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary)
      else { return nil }
      let data = NSMutableData()
      guard
        let dest = CGImageDestinationCreateWithData(
          data, UTType.jpeg.identifier as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImage(
        dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
      guard CGImageDestinationFinalize(dest) else { return nil }
      return data as Data
    }

    // MARK: - Apply

    @MainActor
    static func apply(to model: AppModel) {
      applyExtensionStates(to: model)
      guard screen != nil else { return }
      switch base {
      case "welcome":
        model.route = .welcome
      case "pair", "pair-camera", "pair-found", "pair-paste":
        model.route = .welcome
        model.pairFromFirstRun = true
        model.showsPair = true
      case "permissions", "permissions-mic", "permissions-done":
        model.route = .permissions
        if base == "permissions-mic" {
          Task {
            try? await Task.sleep(for: .seconds(0.8))
            await model.voice.requestMicrophone()
          }
        }
      case "bounce", "bounce-later":
        model.route = .home
        model.settings.bounceTipsShown = base == "bounce" ? 0 : 3
        model.open(URL(string: "mindloom://voice/start")!)
      default:
        model.route = .home
      }
      switch base {
      case "settings": model.navigationPath = [.settings]
      case "settings-autoend": model.navigationPath = [.settings, .autoEnd]
      case "settings-mac", "settings-disconnect": model.navigationPath = [.settings, .mac]
      case "settings-privacy", "settings-privacy-open": model.navigationPath = [.settings, .privacy]
      case "settings-keyboard", "settings-keyboard-off":
        model.navigationPath = [.settings, .keyboard]
      case "settings-about": model.navigationPath = [.settings, .about]
      default: break
      }
      if isNote {
        let t = frozenTime ?? 2.62
        let latched = base == "note-tap"
        let committed = t >= releaseAt + TalkController.commitDelay
        model.talk.debugFreeze(
          press: pressAt, release: t >= releaseAt && !latched ? releaseAt : nil, latched: latched,
          partial: t < 1.0 ? "" : "组会改到周三下午", committed: committed ? "组会改到周三下午，记得提前订会议室。" : nil,
          savedItemID: committed ? ids["n1"] : nil)
      }
    }

    /// `-MindloomDebugAutoTalk <after>,<hold>`: presses the speak bar `after` seconds after launch and
    /// lets go `hold` seconds later, through the real talk path (audio file, level, recognizer,
    /// commit, undo hold, delivery). For the recorded walkthrough.
    static var autoTalk: (after: Double, hold: Double)? {
      guard let raw = value("-MindloomDebugAutoTalk") else { return nil }
      let parts = raw.split(separator: ",").compactMap { Double($0) }
      guard parts.count == 2 else { return nil }
      return (parts[0], parts[1])
    }

    @MainActor
    static func runAutoTalk(_ talk: TalkController, bar: CGPoint) {
      guard let plan = autoTalk else { return }
      Task {
        try? await Task.sleep(for: .seconds(plan.after))
        talk.down(at: bar)
        try? await Task.sleep(for: .seconds(plan.hold))
        talk.up(at: bar)
      }
    }

    static var viewerLabel: String? { base == "viewer" ? "a2" : nil }
    static var expandedLabel: String? { base == "home-expanded" ? "b2" : nil }

    /// `-MindloomDebugKeyboard <kb-state|none>` and `-MindloomDebugShare <share-state|none>`: the
    /// keyboard and the share extension draw that PHONE-SPEC state with synthetic text and
    /// pictures (the keyboard on screen redraws at once).
    /// Without the argument the record is removed: a screenshot state never outlives the run that
    /// asked for it (and the extensions ignore one older than ten minutes).
    static func applyExtensionStates(to model: AppModel) {
      let records = model.voice.channel.records
      let keyboard = value("-MindloomDebugKeyboard")
      model.voice.channel.writeDebugKeyboardScreen(keyboard == "none" ? nil : keyboard)
      DarwinSignaling.shared.post(PhoneNames.signal("debug.keyboard"))
      if let share = value("-MindloomDebugShare"), share != "none" {
        try? records.write(
          Data("\(share)|\(Int(Date().timeIntervalSince1970))".utf8), as: "debug-share")
      } else {
        records.remove("debug-share")
      }
    }

    static func applyPair(lock: inout CGRect?, found: inout PairView.FoundCode?, paste: inout Bool) {
      switch base {
      case "pair-found":
        let top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }
          .first?.safeAreaInsets.top ?? 62
        let width = UIScreen.main.bounds.width
        lock = CGRect(x: width / 2 - 63, y: top + 259 - 63, width: 126, height: 126)
          .insetBy(dx: -9, dy: -9)
        found = PairView.FoundCode(text: pairingText, macName: macName)
      case "pair-paste":
        paste = true
      default:
        break
      }
    }
  }

  extension Date {
    fileprivate func settingMonthDay(_ month: Int, _ day: Int) -> Date {
      var c = Calendar.current.dateComponents([.year, .hour, .minute], from: self)
      c.month = month
      c.day = day
      return Calendar.current.date(from: c) ?? self
    }
  }

  extension TalkController {
    /// DEBUG: a scripted moment (press 0.30 s, release 4.00 s) for the frozen screenshots.
    func debugFreeze(
      press: TimeInterval, release: TimeInterval?, latched: Bool, partial: String,
      committed: String?, savedItemID: String?
    ) {
      listener.levelTrack = ListenerSynthetic.speechTrack()
      listener.press(at: press)
      if let release { listener.release(at: release) }
      debugSet(latched: latched, partial: partial, committed: committed, savedItemID: savedItemID)
    }
  }

  /// The camera view in the simulator (which has no camera): a synthetic scene with a Mac screen
  /// showing 「连接 iPhone」 and a synthetic QR code where the code is expected.
  struct DebugCameraBackdrop: View {
    let size: CGSize
    let top: CGFloat

    private static let qr: UIImage? = {
      let filter = CIFilter.qrCodeGenerator()
      filter.message = Data("mindloom://pair/MLP-4X7K-Q2RD-8HNW".utf8)
      filter.correctionLevel = "M"
      guard let output = filter.outputImage else { return nil }
      let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
      guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
      return UIImage(cgImage: cg)
    }()

    var body: some View {
      let cx = size.width / 2
      let cy = top + 259
      ZStack(alignment: .topLeading) {
        LinearGradient(
          colors: [Color(red: 0.24, green: 0.20, blue: 0.15), Color(red: 0.10, green: 0.08, blue: 0.06)],
          startPoint: .topLeading, endPoint: .bottomTrailing)
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(Color(red: 0.08, green: 0.07, blue: 0.06))
          .frame(width: size.width - 12, height: 380)
          .offset(x: 6, y: cy - 190)
          .blur(radius: 3)
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(
            LinearGradient(
              colors: [Color(white: 0.80), Color(white: 0.70)], startPoint: .top,
              endPoint: .bottom)
          )
          .frame(width: size.width - 40, height: 352)
          .offset(x: 20, y: cy - 176)
          .blur(radius: 1.5)
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(Color(white: 0.83))
          .frame(width: 174, height: 212)
          .offset(x: cx - 87, y: cy - 120)
        Text("连接 iPhone")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color(white: 0.15))
          .frame(width: 174)
          .offset(x: cx - 87, y: cy - 108)
        if let qr = Self.qr {
          Image(uiImage: qr)
            .interpolation(.none)
            .resizable()
            .frame(width: 126, height: 126)
            .offset(x: cx - 63, y: cy - 63)
        }
      }
      .frame(width: size.width, height: size.height)
      .allowsHitTesting(false)
    }
  }
#endif
