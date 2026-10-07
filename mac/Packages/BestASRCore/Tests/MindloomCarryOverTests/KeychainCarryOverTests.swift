import BestASRAgentAccess
import BestASRRemoteOrganizer
import Darwin
import Foundation
import MindloomAgentProtocol
import MindloomIdentity
import XCTest

@testable import MindloomCarryOver

/// The switch from bestASR to Mindloom (2026-10-06, a new identity): the
/// login-keychain items of the moved library are handed over by a helper
/// signed as bestASR, re-keyed to Mindloom's services and the moved library's
/// identity, never overwriting, never asking. The real signatures and the
/// real keychain are exercised by the switch's dry run on a temporary
/// keychain; these tests pin everything around them.
final class KeychainCarryOverTests: XCTestCase {
  private let old = String(repeating: "a", count: 32)
  private let new = String(repeating: "b", count: 32)
  private let other = String(repeating: "c", count: 32)
  private let space = "7d0f3a52-9c1e-4b5a-8f00-1234567890ab"
  private let grant = "0e7a3c9d-5b2f-4a61-9d8e-abcdefabcdef"

  private func value(_ byte: UInt8, _ count: Int = 32) -> Data {
    Data(repeating: byte, count: count)
  }

  // MARK: What is carried, and under which names

  func testEachKindNamesTheStoresServiceBeforeAndAfter() {
    typealias Kind = KeychainCarryOver.Kind
    XCTAssertEqual(Kind.organizerKey.service, KeychainOrganizerKeyStore.service)
    XCTAssertEqual(Kind.phoneSealKey.service, KeychainPhoneSealKeyStore.service)
    XCTAssertEqual(Kind.spaceKey.service, KeychainSpaceKeyStore.service)
    XCTAssertEqual(Kind.spaceDeviceKey.service, KeychainSpaceDeviceStore.service)
    XCTAssertEqual(Kind.memberAccess.service, KeychainMemberAccessStore.service)
    XCTAssertEqual(Kind.agentGrant.service, KeychainAgentGrantSecretStore.service)
    XCTAssertEqual(Kind.allCases.count, 6)
    for kind in Kind.allCases {
      XCTAssertEqual(kind.service, "app.mindloom." + kind.rawValue)
      XCTAssertEqual(kind.previousService, "com.bestasr." + kind.rawValue)
      XCTAssertTrue(kind.label.hasPrefix("Mindloom "))
    }
  }

  func testAccountsAreTheRootAndWhatFollowsIt() {
    typealias Kind = KeychainCarryOver.Kind
    XCTAssertEqual(Kind.organizerKey.suffix(ofAccount: old, root: old), "")
    XCTAssertNil(Kind.organizerKey.suffix(ofAccount: old + "x", root: old))
    XCTAssertEqual(Kind.spaceKey.suffix(ofAccount: old + "|" + space, root: old), "|" + space)
    XCTAssertNil(Kind.spaceKey.suffix(ofAccount: old, root: old))
    XCTAssertNil(Kind.spaceKey.suffix(ofAccount: old + "|" + space.uppercased(), root: old))
    XCTAssertNil(Kind.spaceKey.suffix(ofAccount: old + ":" + space, root: old))
    XCTAssertEqual(Kind.agentGrant.suffix(ofAccount: old + ":" + grant, root: old), ":" + grant)
    XCTAssertNil(Kind.agentGrant.suffix(ofAccount: other + ":" + grant, root: old))
    XCTAssertEqual(Kind.agentGrant.account(root: new, suffix: ":" + grant), new + ":" + grant)
  }

  /// The helper reads only the moved library's items, and counts (never asks
  /// for) the ones it cannot read.
  func testTheHelperCollectsOnlyTheMovedLibrarysItems() {
    typealias Kind = KeychainCarryOver.Kind
    let keychain = MemoryCarryOverKeychain()
    func put(_ kind: Kind, _ account: String, _ data: Data) {
      _ = keychain.add(service: kind.previousService, account: account, label: "", value: data)
    }
    put(.organizerKey, old, value(1))
    put(.phoneSealKey, old, value(2))
    put(.spaceKey, old + "|" + space, value(3, 80))
    put(.spaceDeviceKey, old, value(4, 120))
    put(.memberAccess, old, value(5, 300))
    put(.agentGrant, old + ":" + grant, value(6))
    // Another library's, a malformed account, Mindloom's own: not carried.
    put(.organizerKey, other, value(7))
    put(.spaceKey, old + "|NOT-A-SPACE", value(8))
    _ = keychain.add(service: Kind.organizerKey.service, account: old, label: "", value: value(9))
    // Made by another App: unreadable without asking.
    put(.agentGrant, old + ":" + grant.replacingOccurrences(of: "0", with: "1"), value(10))
    keychain.locked.insert(
      MemoryCarryOverKeychain.key(
        Kind.agentGrant.previousService, old + ":" + grant.replacingOccurrences(of: "0", with: "1"))
    )

    let collected = KeychainCarryOver.collect(oldRoot: old, keychain: keychain)
    XCTAssertEqual(collected.unreadable, 1)
    XCTAssertEqual(
      collected.items,
      [
        .init(kind: .organizerKey, suffix: "", value: value(1)),
        .init(kind: .phoneSealKey, suffix: "", value: value(2)),
        .init(kind: .spaceKey, suffix: "|" + space, value: value(3, 80)),
        .init(kind: .spaceDeviceKey, suffix: "", value: value(4, 120)),
        .init(kind: .memberAccess, suffix: "", value: value(5, 300)),
        .init(kind: .agentGrant, suffix: ":" + grant, value: value(6)),
      ])
  }

  /// Mindloom makes them again under its services and the moved library's
  /// identity; what it already has stays as it is; a failed add is counted.
  func testMindloomMakesThemAgainUnderItsOwnNames() throws {
    let offer = KeychainCarryOver.Offer(
      items: [
        .init(kind: .organizerKey, suffix: "", value: value(1)),
        .init(kind: .spaceKey, suffix: "|" + space, value: value(3)),
        .init(kind: .agentGrant, suffix: ":" + grant, value: value(6)),
      ], unreadable: 0, loginItemWasEnabled: false)
    try offer.validate()
    let keychain = MemoryCarryOverKeychain()
    _ = keychain.add(
      service: KeychainCarryOver.Kind.organizerKey.service, account: new, label: "",
      value: value(42))
    let made = KeychainCarryOver.receive(offer, newRoot: new, keychain: keychain)
    XCTAssertEqual(made.created, 2)
    XCTAssertEqual(made.existing, 1)
    XCTAssertEqual(made.failed, 0)
    XCTAssertEqual(
      keychain.read(service: KeychainOrganizerKeyStore.service, account: new), value(42))
    XCTAssertEqual(
      keychain.read(service: KeychainSpaceKeyStore.service, account: new + "|" + space), value(3))
    XCTAssertEqual(
      keychain.read(service: KeychainAgentGrantSecretStore.service, account: new + ":" + grant),
      value(6))
    // Nothing under bestASR's names.
    XCTAssertTrue(keychain.values.keys.allSatisfy { !$0.hasPrefix("com.bestasr.") })

    let refusing = MemoryCarryOverKeychain()
    refusing.failAdds = true
    XCTAssertEqual(KeychainCarryOver.receive(offer, newRoot: new, keychain: refusing).failed, 3)
  }

  func testAnOfferAnOwnersLibraryCannotHaveMadeIsRefused() {
    func offer(_ items: [KeychainCarryOver.Item]) -> KeychainCarryOver.Offer {
      .init(items: items, unreadable: 0, loginItemWasEnabled: false)
    }
    let good = KeychainCarryOver.Item(kind: .organizerKey, suffix: "", value: value(1))
    XCTAssertNoThrow(try offer([good]).validate())
    XCTAssertThrowsError(try offer([good, good]).validate())
    XCTAssertThrowsError(
      try offer([.init(kind: .organizerKey, suffix: "|x", value: value(1))]).validate())
    XCTAssertThrowsError(
      try offer([.init(kind: .organizerKey, suffix: "", value: Data())]).validate())
    XCTAssertThrowsError(
      try offer([
        .init(
          kind: .organizerKey, suffix: "",
          value: value(1, KeychainCarryOver.maximumValueBytes + 1))
      ]).validate())
    let json = #"{"version":3,"items":[],"unreadable":0,"loginItemWasEnabled":false}"#
    let future = try? JSONDecoder().decode(KeychainCarryOver.Offer.self, from: Data(json.utf8))
    XCTAssertThrowsError(try future?.validate()) {
      XCTAssertEqual($0 as? CarryOverError, .unsupportedVersion)
    }
  }

  func testFramesAreLengthPrefixedAndBounded() throws {
    let receipt = KeychainCarryOver.Receipt(
      created: 2, existing: 1, failed: 0, loginItemRegistered: true)
    let frame = try CarryOverFrame.encode(receipt)
    let length = try CarryOverFrame.length(of: frame.prefix(4))
    XCTAssertEqual(length, frame.count - 4)
    XCTAssertEqual(
      try CarryOverFrame.decode(KeychainCarryOver.Receipt.self, body: frame.dropFirst(4)), receipt)
    XCTAssertThrowsError(try CarryOverFrame.length(of: Data([0, 0, 0, 0])))
    XCTAssertThrowsError(try CarryOverFrame.length(of: Data([0xff, 0xff, 0xff, 0xff])))
    XCTAssertThrowsError(
      try CarryOverFrame.decode(KeychainCarryOver.Receipt.self, body: Data("x".utf8)))
  }

  // MARK: The channel

  private func folder() throws -> URL {
    // sun_path is short: a short folder in the temporary directory.
    let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("mco-\(UUID().uuidString.prefix(8))", isDirectory: true)
    addTeardownBlock { CarryOverChannel.remove(directory: url) }
    return url
  }

  /// The whole handover over a real socket, with the signature checks
  /// replaced by `admit`.
  private func handOver(
    _ offer: KeychainCarryOver.Offer, into keychain: MemoryCarryOverKeychain,
    helperAdmits: Bool = true, mindloomAdmits: Bool = true, registered: Bool = true,
    acceptsLibrary: @escaping (String?) -> Bool = { _ in true }
  ) throws -> (outcome: KeychainCarryOverReceiver.Outcome?, receipt: KeychainCarryOver.Receipt?) {
    let directory = try folder()
    let listener = try CarryOverChannel.listen(directory: directory)
    let received = Locked<KeychainCarryOver.Receipt?>(nil)
    let helperDone = expectation(description: "helper")
    let thread = Thread {
      defer { helperDone.fulfill() }
      guard
        let connection = try? CarryOverChannel.acceptVerified(
          listener, until: Date().addingTimeInterval(10), check: { _ in helperAdmits })
      else { return }
      defer { close(connection) }
      try? CarryOverChannel.send(offer, on: connection)
      received.set(try? CarryOverChannel.receive(KeychainCarryOver.Receipt.self, on: connection))
    }
    thread.start()
    defer { close(listener) }
    let outcome: KeychainCarryOverReceiver.Outcome?
    do {
      outcome = try KeychainCarryOverReceiver.run(
        socket: directory.appendingPathComponent(CarryOverChannel.socketName),
        check: { _ in mindloomAdmits }, acceptsLibrary: acceptsLibrary, newRoot: new,
        keychain: keychain, registerLoginItem: { registered })
    } catch {
      // Mindloom connected and then refused: the helper's side ends on its own.
      wait(for: [helperDone], timeout: 15)
      throw error
    }
    wait(for: [helperDone], timeout: 15)
    return (outcome, received.value)
  }

  func testTheHandoverOverAPrivateSocket() throws {
    let offer = KeychainCarryOver.Offer(
      items: [
        .init(kind: .phoneSealKey, suffix: "", value: value(2)),
        .init(kind: .spaceDeviceKey, suffix: "", value: value(4, 100)),
      ], unreadable: 1, loginItemWasEnabled: true)
    let keychain = MemoryCarryOverKeychain()
    let result = try handOver(offer, into: keychain)
    let outcome = try XCTUnwrap(result.outcome)
    XCTAssertEqual(outcome.offered, 2)
    XCTAssertEqual(outcome.created, 2)
    XCTAssertEqual(outcome.unreadable, 1)
    XCTAssertTrue(outcome.loginItemWasEnabled)
    XCTAssertTrue(outcome.loginItemRegistered)
    XCTAssertEqual(
      result.receipt,
      KeychainCarryOver.Receipt(created: 2, existing: 0, failed: 0, loginItemRegistered: true))
    XCTAssertEqual(
      keychain.read(service: KeychainPhoneSealKeyStore.service, account: new), value(2))
  }

  /// bestASR's 「登录时打开」 off: Mindloom is not asked to turn its own on.
  func testLoginItemOffIsLeftOff() throws {
    let offer = KeychainCarryOver.Offer(items: [], unreadable: 0, loginItemWasEnabled: false)
    let result = try handOver(offer, into: MemoryCarryOverKeychain(), registered: true)
    XCTAssertEqual(result.outcome?.loginItemRegistered, false)
    XCTAssertEqual(result.receipt?.loginItemRegistered, false)
  }

  /// A helper whose signature Mindloom does not accept gets nothing said and
  /// nothing made.
  func testARejectedHelperIsRefused() throws {
    let offer = KeychainCarryOver.Offer(
      items: [.init(kind: .organizerKey, suffix: "", value: value(1))], unreadable: 0,
      loginItemWasEnabled: true)
    let keychain = MemoryCarryOverKeychain()
    XCTAssertThrowsError(try handOver(offer, into: keychain, mindloomAdmits: false)) {
      XCTAssertEqual($0 as? CarryOverError, .peerRejected)
    }
    XCTAssertTrue(keychain.values.isEmpty)
  }

  /// An offer read for another folder than bestASR's beside the library
  /// Mindloom opened (a helper run by hand on any folder after the switch)
  /// is refused before anything is made, and the helper gets no receipt.
  func testAnOfferForAnotherFolderIsRefused() throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("mco-parent-\(UUID().uuidString)", isDirectory: true)
    let elsewhere = FileManager.default.temporaryDirectory
      .appendingPathComponent("mco-elsewhere-\(UUID().uuidString)", isDirectory: true)
    for folder in [parent, elsewhere] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    }
    let root = parent.appendingPathComponent("Mindloom", isDirectory: true)
    let accepts: (String?) -> Bool = {
      CarryOverSource.isPreviousLibrary(offered: $0, currentRoot: root)
    }
    let items: [KeychainCarryOver.Item] = [.init(kind: .organizerKey, suffix: "", value: value(1))]
    for library in [elsewhere.appendingPathComponent("bestASR").path, nil] {
      let keychain = MemoryCarryOverKeychain()
      let offer = KeychainCarryOver.Offer(
        items: items, unreadable: 0, loginItemWasEnabled: true, library: library)
      XCTAssertThrowsError(try handOver(offer, into: keychain, acceptsLibrary: accepts)) {
        XCTAssertEqual($0 as? CarryOverError, .otherLibrary)
      }
      XCTAssertTrue(keychain.values.isEmpty)
    }
    // bestASR's folder beside it: taken.
    let keychain = MemoryCarryOverKeychain()
    let offer = KeychainCarryOver.Offer(
      items: items, unreadable: 0, loginItemWasEnabled: false,
      library: parent.appendingPathComponent("bestASR").path)
    let result = try handOver(offer, into: keychain, acceptsLibrary: accepts)
    XCTAssertEqual(result.outcome?.created, 1)
  }

  func testThePreviousLibraryIsBestASRsFolderBesideTheOpenedOne() throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("mco-sibling-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("Mindloom", isDirectory: true)
    func accepts(_ path: String?) -> Bool {
      CarryOverSource.isPreviousLibrary(offered: path, currentRoot: root)
    }
    XCTAssertTrue(accepts(parent.appendingPathComponent("bestASR").path))
    // Another spelling of the same parent (a link, a different case).
    let link = FileManager.default.temporaryDirectory
      .appendingPathComponent("mco-link-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: parent)
    addTeardownBlock { try? FileManager.default.removeItem(at: link) }
    XCTAssertTrue(accepts(link.appendingPathComponent("bestasr").path))
    XCTAssertFalse(accepts(parent.appendingPathComponent("Mindloom").path))
    XCTAssertFalse(accepts(parent.appendingPathComponent("bestASR-copy").path))
    XCTAssertFalse(accepts(parent.appendingPathComponent("x/bestASR").path))
    XCTAssertFalse(accepts("bestASR"))
    XCTAssertFalse(accepts(nil))
  }

  func testNoHelperNoHandover() throws {
    let socket = try folder().appendingPathComponent(CarryOverChannel.socketName)
    XCTAssertNil(
      try KeychainCarryOverReceiver.run(
        socket: socket, check: { _ in true }, acceptsLibrary: { _ in true }, newRoot: new,
        keychain: MemoryCarryOverKeychain(), registerLoginItem: { true }))
  }

  /// The folder must be this user's and 0700: one another user could reach
  /// is refused by both sides.
  func testAnOpenFolderIsRefused() throws {
    let directory = try folder()
    XCTAssertEqual(mkdir(directory.path, 0o755), 0)
    chmod(directory.path, 0o755)
    XCTAssertThrowsError(try CarryOverChannel.listen(directory: directory)) {
      XCTAssertEqual($0 as? CarryOverError, .unsafeDirectory)
    }
    chmod(directory.path, 0o700)
    let listener = try CarryOverChannel.listen(directory: directory)
    defer { close(listener) }
    chmod(directory.path, 0o755)
    XCTAssertThrowsError(
      try CarryOverChannel.connectVerified(
        socket: directory.appendingPathComponent(CarryOverChannel.socketName), check: { _ in true })
    )
    chmod(directory.path, 0o700)
  }

  /// The real check: a peer that is not signed as the requirement says (this
  /// test process) is refused, from the kernel's audit token.
  func testTheSignatureCheckRefusesAProcessSignedOtherwise() throws {
    let directory = try folder()
    let listener = try CarryOverChannel.listen(directory: directory)
    defer { close(listener) }
    let client = try AgentSocketIO.connect(
      path: directory.appendingPathComponent(CarryOverChannel.socketName).path)
    defer { close(client) }
    let requirement = try XCTUnwrap(
      CarryOverChannel.requirement(
        identifier: MindloomIdentity.Previous.bundleID, team: "ABCDE12345"))
    XCTAssertEqual(
      requirement,
      #"identifier "com.bestasr.app" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#
    )
    XCTAssertFalse(CarryOverChannel.signatureCheck(requirement: requirement)(client))
    XCTAssertNil(CarryOverChannel.requirement(identifier: "x\" or true", team: "ABCDE12345"))
  }

  func testTheSocketLivesInTheUsersTemporaryFolderUnderTheReceiversName() throws {
    let temporary = try XCTUnwrap(CarryOverChannel.userTemporaryDirectory())
    XCTAssertTrue(temporary.path.hasPrefix("/"))
    let socket = CarryOverChannel.socketURL(
      receiver: MindloomIdentity.bundleID, temporaryDirectory: temporary)
    XCTAssertEqual(socket.deletingLastPathComponent().deletingLastPathComponent(), temporary)
    XCTAssertTrue(
      socket.deletingLastPathComponent().lastPathComponent.hasPrefix("mindloom-carry-over-"))
    XCTAssertEqual(socket.lastPathComponent, CarryOverChannel.socketName)
    XCTAssertLessThanOrEqual(socket.path.utf8.count, AgentSocketLocation.maximumPathBytes)
    // Each receiver has its own folder.
    XCTAssertNotEqual(
      CarryOverChannel.directory(
        receiver: "com.bestasr.mindloom.check.switch", temporaryDirectory: temporary),
      CarryOverChannel.directory(receiver: MindloomIdentity.bundleID, temporaryDirectory: temporary)
    )
  }

  /// Regression (dry run 2026-10-06): the folder was named after the
  /// receiver, so a verification identity's socket path (107 bytes) did not
  /// fit and the helper stopped with `pathTooLong`.
  func testALongReceiverStillGetsASocketThatFitsAndListens() throws {
    let temporary = try XCTUnwrap(CarryOverChannel.userTemporaryDirectory())
    for receiver in [
      "com.bestasr.mindloom.check.switch", String(repeating: "a", count: 255),
    ] {
      let socket = CarryOverChannel.socketURL(receiver: receiver, temporaryDirectory: temporary)
      XCTAssertLessThanOrEqual(
        socket.path.utf8.count, AgentSocketLocation.maximumPathBytes, receiver)
    }
    let receiver = "com.bestasr.mindloom.check.test-\(UUID().uuidString.lowercased())"
    let folder = CarryOverChannel.directory(receiver: receiver, temporaryDirectory: temporary)
    let listener = try CarryOverChannel.listen(directory: folder)
    defer {
      close(listener)
      CarryOverChannel.remove(directory: folder)
    }
    XCTAssertGreaterThanOrEqual(listener, 0)
  }

  // MARK: Who carries over from whom

  func testOnlyTheProductCarriesOverFromBestASR() {
    let arguments = ["/x/Mindloom"]
    XCTAssertEqual(
      CarryOverSource.previousIdentity(ownBundleID: "app.mindloom", arguments: arguments),
      "com.bestasr.app")
    XCTAssertNil(
      CarryOverSource.previousIdentity(ownBundleID: "app.mindloom.debug", arguments: arguments))
    XCTAssertNil(
      CarryOverSource.previousIdentity(
        ownBundleID: "com.bestasr.mindloom.preview", arguments: arguments))
    XCTAssertNil(CarryOverSource.previousIdentity(ownBundleID: nil, arguments: arguments))
    // A verification copy: only from another verification copy, named.
    let check = "com.bestasr.mindloom.check.switch"
    XCTAssertNil(CarryOverSource.previousIdentity(ownBundleID: check, arguments: arguments))
    XCTAssertEqual(
      CarryOverSource.previousIdentity(
        ownBundleID: check,
        arguments: arguments + ["-MindloomCarryOverFrom", "com.bestasr.mindloom.check.old"]),
      "com.bestasr.mindloom.check.old")
    for named in ["com.bestasr.app", "app.mindloom", check] {
      XCTAssertNil(
        CarryOverSource.previousIdentity(
          ownBundleID: check, arguments: arguments + ["-MindloomCarryOverFrom", named]), named)
    }
    // The product ignores the argument: always bestASR.
    XCTAssertEqual(
      CarryOverSource.previousIdentity(
        ownBundleID: "app.mindloom",
        arguments: arguments + ["-MindloomCarryOverFrom", "com.bestasr.mindloom.check.old"]),
      "com.bestasr.app")
  }

  func testOnlyAVerificationCopyIsGivenAKeychainFile() {
    let arguments = ["/x", "-MindloomCarryOverKeychain", "/tmp/dry.keychain-db"]
    XCTAssertEqual(
      CarryOverSource.keychainFile(
        ownBundleID: "com.bestasr.mindloom.check.switch", arguments: arguments)?
        .path, "/tmp/dry.keychain-db")
    XCTAssertNil(CarryOverSource.keychainFile(ownBundleID: "app.mindloom", arguments: arguments))
    XCTAssertNil(
      CarryOverSource.keychainFile(
        ownBundleID: "com.bestasr.mindloom.check.switch",
        arguments: ["/x", "-MindloomCarryOverKeychain", "relative.keychain-db"]))
  }

  /// A check-identity helper never reads the login keychain; only
  /// Mindloom's (or a check identity's) helper turns a login item off.
  func testWhichHelperMayDoWhat() {
    XCTAssertTrue(
      CarryOverSource.keychainFileRequired(helperIdentifier: "com.bestasr.mindloom.check.old"))
    XCTAssertFalse(CarryOverSource.keychainFileRequired(helperIdentifier: "com.bestasr.app"))
    XCTAssertTrue(CarryOverSource.mayUnregisterLoginItem(helperIdentifier: "app.mindloom"))
    XCTAssertTrue(
      CarryOverSource.mayUnregisterLoginItem(
        helperIdentifier: "com.bestasr.mindloom.check.switch"))
    XCTAssertFalse(CarryOverSource.mayUnregisterLoginItem(helperIdentifier: "com.bestasr.app"))
    XCTAssertFalse(CarryOverSource.mayUnregisterLoginItem(helperIdentifier: "app.mindloom.debug"))
  }

  func testBestASRsHelperHandsOverToMindloomOnly() {
    XCTAssertEqual(
      CarryOverSource.receiver(helperIdentifier: "com.bestasr.app", requested: nil), "app.mindloom")
    XCTAssertEqual(
      CarryOverSource.receiver(helperIdentifier: "com.bestasr.app", requested: "app.mindloom"),
      "app.mindloom")
    XCTAssertNil(
      CarryOverSource.receiver(
        helperIdentifier: "com.bestasr.app", requested: "com.bestasr.mindloom.check.switch"))
    XCTAssertNil(CarryOverSource.receiver(helperIdentifier: "app.mindloom", requested: nil))
    XCTAssertEqual(
      CarryOverSource.receiver(
        helperIdentifier: "com.bestasr.mindloom.check.old",
        requested: "com.bestasr.mindloom.check.switch"),
      "com.bestasr.mindloom.check.switch")
    XCTAssertNil(
      CarryOverSource.receiver(
        helperIdentifier: "com.bestasr.mindloom.check.old", requested: "app.mindloom"))
    XCTAssertNil(
      CarryOverSource.receiver(helperIdentifier: "com.bestasr.mindloom.check.old", requested: nil))
  }
}

/// A value shared with the helper's thread.
private final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value { lock.withLock { stored } }
  func set(_ value: Value) { lock.withLock { stored = value } }
}
