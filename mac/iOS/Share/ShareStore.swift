import CryptoKit
import ImageIO
import Foundation
import MindloomInboxSSH
import MindloomLink
import MindloomPhoneKit
import UIKit
import os

/// Where the share extension keeps what it took (PHONE-SPEC §7.5, IOS-CODE-MAP §3b):
///
/// - **App Group** (the normal build): the shared item list and outbox; the app sends.
/// - **No App Group** (a free team's build): the extension's own container, sealed with the
///   pairing the app hands over through the shared keychain (`ShareHandoff`), sent by the
///   extension itself in the time iOS gives it; what is still on the phone is retried the next
///   time something is shared. Home learns about these items from the same handoff.
@MainActor
final class ShareStore {
  let collector: PhoneItemCollector
  private let handoff: ShareHandoff?
  private let log = Logger(subsystem: PhoneNames.shareLog, category: "share")

  private init(collector: PhoneItemCollector, handoff: ShareHandoff?) {
    self.collector = collector
    self.handoff = handoff
  }

  static func make() -> ShareStore? {
    if let group = PhoneAppGroup.containerURL() {
      // Read before the move clears it: the pairing the app handed over without the App Group.
      let handed = ShareHandoff.keychain()?.readPairing()
      migrateOwnStorage(to: group)
      if let shared = try? PhoneItemCollector.appGroup() {
        return ShareStore(collector: sealing(shared, handed: handed), handoff: nil)
      }
    }
    guard let handoff = ShareHandoff.keychain(),
      let base = try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { return nil }
    let root = PhoneAppGroup.privateShareDirectory(in: base)
    // This store is in use again: a later build with the App Group moves it once more.
    PhoneStorageMigration.forget(legacy: root, defaults: nil)
    guard let items = try? PhoneItemStore(root: root.appendingPathComponent("items")),
      let outbox = try? OutboxStore(root: root.appendingPathComponent("outbox"))
    else { return nil }
    let pairing = PairingRecordStore(file: root.appendingPathComponent("pairing.json"))
    if let handed = handoff.readPairing() {
      try? pairing.write(handed.record)
    } else {
      try? pairing.remove()
    }
    let collector = PhoneItemCollector(
      items: items, outbox: outbox, pairing: pairing, signaling: DarwinSignaling.shared)
    try? collector.sealAwaitingItems()
    return ShareStore(collector: collector, handoff: handoff)
  }

  /// With the App Group, shared before the app has run with it: the group has no pairing yet (the
  /// app moves its own on its next launch), but the app's pairing is still handed over in the
  /// keychain. Sealing with it now keeps the item from waiting for a pairing that already exists;
  /// the entries carry the same Mac key the app sends with.
  private static func sealing(_ shared: PhoneItemCollector, handed: (record: PairingRecord, phoneKey: Data)?)
    -> PhoneItemCollector
  {
    guard shared.pairing.read() == nil, let handed,
      let support = PhoneAppGroup.privateApplicationSupport()
    else { return shared }
    let pairing = PairingRecordStore(
      file: PhoneAppGroup.privateShareDirectory(in: support).appendingPathComponent("pairing.json"))
    guard (try? pairing.write(handed.record)) != nil else { return shared }
    return PhoneItemCollector(
      items: shared.items, outbox: shared.outbox, pairing: pairing, signaling: shared.signaling)
  }

  /// With the App Group: what a build without it kept in this extension's own container (items,
  /// previews, outbox) goes into the group once, so the app lists and sends it; the item list
  /// handed to the app through the keychain is then no longer needed (`PhoneStorageMigration`).
  private static func migrateOwnStorage(to group: URL) {
    guard
      let support = PhoneAppGroup.privateApplicationSupport(),
      case let legacy = PhoneAppGroup.privateShareDirectory(in: support),
      FileManager.default.fileExists(atPath: legacy.path),
      !PhoneStorageMigration.isDone(from: legacy)
    else { return }
    let log = Logger(subsystem: PhoneNames.shareLog, category: "storage")
    do {
      let report = try PhoneStorageMigration.migrateShare(from: legacy, to: group)
      log.notice(
        "share storage migrated: moved \(report.moved) replaced \(report.replaced) kept \(report.kept) failed \(report.failed)"
      )
      if report.failed == 0, let handoff = ShareHandoff.keychain() {
        handoff.records.remove("items")
        handoff.clearPairing()
      }
      if report.moved + report.replaced > 0 { DarwinSignaling.shared.post(PhoneSignal.outboxChanged) }
    } catch {
      log.error("share storage migration: \(String(describing: error), privacy: .public)")
    }
  }

  var isPaired: Bool { collector.pairing.read() != nil }
  /// True when this extension sends by itself (no App Group).
  var sendsItself: Bool { handoff != nil }

  /// Keeps one item with one part, held until `heldUntil` (the card's time, or the note).
  /// Returns the saved item, nil when it could not be kept.
  func keep(_ item: PhoneItem, payload: InboxItemPayload, preview: Data?, heldUntil: Date)
    -> PhoneItem?
  {
    do {
      let saved = try collector.collect(item, payloads: [payload], heldUntil: heldUntil)
      if let preview { try? collector.items.writePreview(preview, id: saved.id, index: 0) }
      return saved
    } catch {
      log.error("not kept: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  /// Adds one photo to the share's photo item (created by the first). Nil when it could not be
  /// kept.
  func append(
    _ payload: InboxItemPayload, to item: PhoneItem, preview: Data?, index: Int, heldUntil: Date
  ) -> PhoneItem? {
    do {
      let saved = try collector.append(payload, to: item, heldUntil: heldUntil)
      if let preview { try? collector.items.writePreview(preview, id: saved.id, index: index) }
      return saved
    } catch {
      log.error("photo not kept: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  /// Takes back what this share kept (a part of it failed: the card says so, and nothing half
  /// kept stays behind to be shared twice).
  func withdraw(_ ids: [String]) {
    for id in ids {
      if (try? collector.withdraw(id: id)) != true { collector.items.remove(id: id) }
    }
    publish()
  }

  /// Tells the app once the share's items are all written.
  func didKeep() {
    publish()
  }

  func hold(_ ids: [String], until: Date) {
    for id in ids { _ = try? collector.extendHold(id: id, until: until) }
  }

  func release(_ ids: [String]) {
    for id in ids { try? collector.release(id: id) }
    publish()
  }

  func attachNote(_ note: String, to id: String) {
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      let payload = try? InboxItemPayload.text(trimmed, source: .share, createdAt: Date())
    else { return }
    _ = try? collector.attachNote(id: id, note: trimmed, payload: payload)
    publish()
  }

  /// Without the App Group: sends what is queued, asking iOS for a little time after the card
  /// has gone.
  func sendWithExpiringActivity() async {
    guard let handoff, let handed = handoff.readPairing(),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: handed.phoneKey)
    else {
      publish()
      return
    }
    let outbox = collector.outbox
    let configuration = InboxSSHConfiguration(record: handed.record, phoneKey: key)
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      let once = ResumeOnce(done)
      ProcessInfo.processInfo.performExpiringActivity(withReason: "Mindloom") { expired in
        // Called once with `false` (time granted; block until finished), and possibly again with
        // `true` when the time runs out, or only with `true` when there is none.
        guard !expired else {
          once.resume()
          return
        }
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
          let deliverer = OutboxDeliverer(
            store: outbox, opener: InboxSSHSender(configuration: configuration))
          _ = await deliverer.deliverQueued()
          finished.signal()
        }
        _ = finished.wait(timeout: .now() + 25)
        once.resume()
      }
    }
    publish()
  }

  /// Tells the app: the shared list changed (App Group), or the handed-over items (keychain).
  private func publish() {
    if let handoff {
      let entries = collector.items.all().map { item in
        ShareHandoff.Entry(item: item, onPhone: collector.delivery(of: item).isOnPhone)
      }
      try? handoff.writeItems(entries)
      DarwinSignaling.shared.post(PhoneSignal.outboxChanged)
    }
  }
}

/// Resumes a continuation exactly once, from any thread.
final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?

  init(_ continuation: CheckedContinuation<Void, Never>) {
    self.continuation = continuation
  }

  func resume() {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume()
  }
}

#if DEBUG
  /// DEBUG: the prototype's synthetic pictures for the card's screenshot states (never the user's
  /// photos): the v9 asset folder, or drawn tiles when it is not reachable.
  enum ShareDebug {
    static let folder = "/Users/Shared/mindloom-demo/v9/phone/assets/photos"

    static func photos() -> [UIImage] {
      let loaded = ["whiteboard", "slide", "book"].compactMap(image(named:))
      return loaded.count == 3 ? loaded : drawn()
    }

    /// The link's preview (the prototype's building).
    static func linkImage() -> UIImage? { image(named: "building") ?? drawn().last }

    private static func image(named name: String) -> UIImage? {
      guard let source = CGImageSourceCreateWithURL(
        URL(fileURLWithPath: "\(folder)/\(name).png") as CFURL, nil),
        let cg = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary)
      else { return nil }
      return UIImage(cgImage: cg)
    }

    private static func drawn() -> [UIImage] {
      let palettes: [(UIColor, UIColor)] = [
        (UIColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1), UIColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 1)),
        (UIColor(red: 0.18, green: 0.2, blue: 0.24, alpha: 1), UIColor(red: 0.85, green: 0.86, blue: 0.9, alpha: 1)),
        (UIColor(red: 0.55, green: 0.42, blue: 0.3, alpha: 1), UIColor(red: 0.96, green: 0.94, blue: 0.88, alpha: 1)),
      ]
      return palettes.map { back, fore in
        UIGraphicsImageRenderer(size: CGSize(width: 138, height: 138)).image { context in
          back.setFill()
          context.fill(CGRect(x: 0, y: 0, width: 138, height: 138))
          fore.setFill()
          for row in 0..<6 {
            context.fill(CGRect(x: 18, y: 22 + row * 16, width: 60 + (row * 13) % 44, height: 6))
          }
        }
      }
    }
  }
#endif
