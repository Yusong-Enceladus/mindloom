import BestASRAgentAccess
import BestASRDomain
import BestASREntries
import CryptoKit
import Darwin
import Foundation
import MindloomAgentProtocol
import XCTest

/// V8 contract A6: the Chrome extension 「收进织机」. Chrome's framing, the
/// request the host accepts, the host manifest Settings writes and removes,
/// the items the App makes (same intake path, source Chrome, links never
/// fetched), separate switches, and the extension itself: no network path,
/// and its fixed ID is the only origin the host manifest allows.
final class BrowserEntryTests: XCTestCase {
  // MARK: Framing

  /// A frame built by hand, the way Chrome writes one: a 4-byte length in
  /// the machine's byte order (little endian on every Mac), then UTF-8 JSON.
  private func chromeFrame(_ json: String) -> Data {
    let payload = Data(json.utf8)
    var length = UInt32(payload.count).littleEndian
    var data = Data(bytes: &length, count: 4)
    data.append(payload)
    return data
  }

  func testFramesAreChromesLengthPrefixedJSON() throws {
    let frame = NativeMessaging.frame(["ok": true])
    XCTAssertEqual(Array(frame.prefix(4)), [11, 0, 0, 0])
    XCTAssertEqual(String(decoding: frame.dropFirst(4), as: UTF8.self), #"{"ok":true}"#)

    // Two messages in one chunk, then one delivered a byte at a time.
    var reader = NativeMessaging.FrameReader()
    let both = chromeFrame(#"{"n":1}"#) + chromeFrame(#"{"n":2,"t":"选中的文字"}"#)
    XCTAssertEqual(reader.append(both).map { try? $0.get() }, [["n": 1], ["n": 2, "t": "选中的文字"]])
    var pieces: [Result<JSONValue, NativeMessaging.FrameError>] = []
    for byte in chromeFrame(#"{"n":3}"#) { pieces += reader.append(Data([byte])) }
    XCTAssertEqual(pieces.map { try? $0.get() }, [["n": 3]])
    XCTAssertFalse(reader.endedInsideFrame)

    // Not JSON: that message is refused, the stream stays in step.
    XCTAssertEqual(
      reader.append(chromeFrame("not json") + chromeFrame(#"{"n":4}"#)).map { try? $0.get() },
      [nil, ["n": 4]])

    // Cut off inside a frame.
    _ = reader.append(chromeFrame(#"{"n":5}"#).prefix(6))
    XCTAssertTrue(reader.endedInsideFrame)

    // A length over the limit stops the reader: nothing after it is read.
    var guarded = NativeMessaging.FrameReader()
    var huge = UInt32(NativeMessaging.maximumIncomingBytes + 1).littleEndian
    let header = Data(bytes: &huge, count: 4)
    let results = guarded.append(header + chromeFrame(#"{"n":6}"#))
    XCTAssertEqual(results.count, 1)
    guard case .failure(.tooLarge) = results[0] else { return XCTFail("expected tooLarge") }
    XCTAssertEqual(guarded.append(chromeFrame(#"{"n":7}"#)).count, 0)

    // A reply too large for Chrome (over 1 MB) is replaced by a short refusal.
    let big = NativeMessaging.frame(["message": .string(String(repeating: "字", count: 400_000))])
    XCTAssertLessThan(big.count, 200)
    XCTAssertEqual(BrowserReply(json: try JSONValue.parse(big.dropFirst(4)))?.ok, false)
  }

  func testTheHostAcceptsOnlyWellFormedAddRequests() {
    let selection: JSONValue = [
      "type": "add", "kind": "selection", "text": "第一段\n第二段", "url": " https://example.test/a ",
      "title": "页面",
    ]
    XCTAssertEqual(
      try BrowserAddRequest.parse(selection).get(),
      BrowserAddRequest(
        kind: .selection, text: "第一段\n第二段", url: "https://example.test/a", title: "页面"))
    // Unknown type or kind, wrong field types.
    for bad: JSONValue in [
      ["type": "fetch", "kind": "page", "url": "https://example.test"],
      ["type": "add", "kind": "screenshot", "url": "https://example.test"],
      ["type": "add", "kind": "page", "url": 7],
      ["type": "add", "kind": "selection", "text": ["a"]],
      "add",
    ] {
      XCTAssertEqual(BrowserAddRequest.parse(bad), .failure(.malformed), bad.serialized)
    }
    // Nothing to take.
    XCTAssertEqual(
      BrowserAddRequest.parse(["type": "add", "kind": "selection", "text": "  \n"]),
      .failure(.empty))
    XCTAssertEqual(
      BrowserAddRequest.parse(["type": "add", "kind": "page", "title": "只有标题"]), .failure(.empty))
    // Too long.
    XCTAssertEqual(
      BrowserAddRequest.parse([
        "type": "add", "kind": "selection",
        "text": .string(String(repeating: "a", count: BrowserAddRequest.maximumTextBytes + 1)),
      ]), .failure(.tooLong))
    // The App reads the same request back from the socket params.
    let request = BrowserAddRequest(kind: .link, text: "链接文字", url: "https://example.test/l")
    XCTAssertEqual(BrowserAddRequest(params: request.params), request)
    XCTAssertNil(BrowserAddRequest(params: ["kind": "video"]))
    XCTAssertNil(BrowserAddRequest(params: nil))
  }

  // MARK: Host manifest

  private func chromeFolders() throws -> (root: URL, hosts: URL, helper: URL) {
    let root = try makeTemporaryFolder("mlb")
    let chrome = root.appendingPathComponent("Google/Chrome", isDirectory: true)
    try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
    let helper = root.appendingPathComponent("织机.app/Contents/Helpers/mindloom-mcp")
    try FileManager.default.createDirectory(
      at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: helper)
    chmod(helper.path, 0o755)
    return (root, chrome.appendingPathComponent("NativeMessagingHosts", isDirectory: true), helper)
  }

  private func fileState(_ url: URL) -> (inode: UInt64, modified: timespec, mode: mode_t)? {
    var entry = stat()
    guard lstat(url.path, &entry) == 0 else { return nil }
    return (UInt64(entry.st_ino), entry.st_mtimespec, entry.st_mode & 0o777)
  }

  func testTheHostManifestIsInstalledAndRemovedIdempotently() throws {
    let (_, hosts, helper) = try chromeFolders()
    let manifest = BrowserHostManifest(directory: hosts)
    XCTAssertEqual(manifest.status(helperPath: helper.path), .absent)
    // Another program's manifest in the same folder is never touched.
    try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
    let neighbour = hosts.appendingPathComponent("com.example.other.json")
    let neighbourBytes = Data(#"{"name":"com.example.other","path":"/bin/false"}"#.utf8)
    try neighbourBytes.write(to: neighbour)

    XCTAssertEqual(try manifest.install(helperPath: helper.path), .installed)
    let written = try Data(contentsOf: manifest.fileURL)
    let value = try JSONValue.parse(written)
    XCTAssertEqual(value["name"]?.stringValue, "com.bestasr.mindloom")
    XCTAssertEqual(value["path"]?.stringValue, helper.path)
    XCTAssertEqual(value["type"]?.stringValue, "stdio")
    XCTAssertEqual(
      value["allowed_origins"], .strings(["chrome-extension://mhpochidiepnikgedmjbpnoknbkjidpa/"]))
    XCTAssertEqual(manifest.fileURL.lastPathComponent, "com.bestasr.mindloom.json")
    let first = try XCTUnwrap(fileState(manifest.fileURL))
    XCTAssertEqual(first.mode, 0o644, "Chrome must be able to read it")
    XCTAssertEqual(manifest.status(helperPath: helper.path), .installed)

    // Again: nothing is written.
    XCTAssertEqual(try manifest.install(helperPath: helper.path), .unchanged)
    let second = try XCTUnwrap(fileState(manifest.fileURL))
    XCTAssertEqual(second.inode, first.inode)
    XCTAssertEqual(second.modified.tv_sec, first.modified.tv_sec)
    XCTAssertEqual(second.modified.tv_nsec, first.modified.tv_nsec)
    XCTAssertEqual(try Data(contentsOf: manifest.fileURL), written)

    // The App moved: the old manifest is for another helper until re-installed.
    let moved = helper.deletingLastPathComponent().appendingPathComponent("moved-mindloom-mcp")
    try FileManager.default.copyItem(at: helper, to: moved)
    XCTAssertEqual(manifest.status(helperPath: moved.path), .otherHelper(helper.path))
    XCTAssertEqual(try manifest.install(helperPath: moved.path), .installed)
    XCTAssertEqual(manifest.status(helperPath: moved.path), .installed)

    // Removing twice: removed, then nothing to remove; the folder and the
    // neighbour stay exactly as they were, and no temporary file is left.
    XCTAssertEqual(try manifest.remove(), .removed)
    XCTAssertEqual(try manifest.remove(), .absent)
    XCTAssertEqual(manifest.status(helperPath: moved.path), .absent)
    XCTAssertEqual(try Data(contentsOf: neighbour), neighbourBytes)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: hosts.path), ["com.example.other.json"])
  }

  func testTheHostManifestNeedsChromeAndTheHelperAndNeverFollowsALink() throws {
    let (root, hosts, helper) = try chromeFolders()
    // No Chrome folder for this user: nothing is created anywhere.
    let elsewhere = root.appendingPathComponent("Chromium/NativeMessagingHosts", isDirectory: true)
    let missingChrome = BrowserHostManifest(directory: elsewhere)
    XCTAssertThrowsError(try missingChrome.install(helperPath: helper.path)) { error in
      XCTAssertEqual(error as? BrowserHostManifest.ManifestError, .browserMissing)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: elsewhere.deletingLastPathComponent().path))

    let manifest = BrowserHostManifest(directory: hosts)
    // A helper that is missing, not executable, or not an absolute path.
    for path in [root.appendingPathComponent("nope").path, "relative/mindloom-mcp"] {
      XCTAssertThrowsError(try manifest.install(helperPath: path)) {
        XCTAssertEqual($0 as? BrowserHostManifest.ManifestError, .helperMissing)
      }
    }
    let plain = root.appendingPathComponent("plain")
    try Data("x".utf8).write(to: plain)
    XCTAssertThrowsError(try manifest.install(helperPath: plain.path))

    // A link by our name is replaced, never written through.
    try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("target.json")
    try Data("keep".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: manifest.fileURL, withDestinationURL: target)
    XCTAssertEqual(try manifest.install(helperPath: helper.path), .installed)
    XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    XCTAssertEqual(manifest.status(helperPath: helper.path), .installed)

    // A folder by our name is left alone.
    XCTAssertEqual(try manifest.remove(), .removed)
    try FileManager.default.createDirectory(
      at: manifest.fileURL, withIntermediateDirectories: false)
    XCTAssertThrowsError(try manifest.install(helperPath: helper.path)) {
      XCTAssertEqual($0 as? BrowserHostManifest.ManifestError, .notAFile)
    }
    XCTAssertThrowsError(try manifest.remove())
    XCTAssertEqual(manifest.status(helperPath: helper.path), .unreadable)
  }

  // MARK: Items

  func testBrowserItemsKeepSourceAndPageAndLinksAreNeverFetched() async throws {
    let root = try makeTemporaryFolder()
    let (committer, store) = makeCommitter(root: root)
    NetworkTripwire.arm()
    defer { NetworkTripwire.disarm() }
    let now = Date(timeIntervalSince1970: 1_790_200_000)
    var items = HandEntries.browser(
      BrowserAddRequest(
        kind: .selection, text: "  周三组会改到下午三点\n带上 Twin-7 的曲线  ",
        url: "https://example.test/notes/7", title: "实验记录"), at: now)
    items += HandEntries.browser(
      BrowserAddRequest(kind: .selection, text: "没有链接的选中文字"), at: now)
    items += HandEntries.browser(
      BrowserAddRequest(kind: .page, url: "https://example.test/plan", title: "十月计划"), at: now)
    items += HandEntries.browser(
      BrowserAddRequest(kind: .link, text: "数据集说明", url: "https://example.test/data.zip"),
      at: now)
    XCTAssertEqual(HandEntries.browser(BrowserAddRequest(kind: .page), at: now), [])
    XCTAssertEqual(HandEntries.browser(BrowserAddRequest(kind: .selection, text: " "), at: now), [])

    let summary = await committer.commit(items)
    XCTAssertEqual(summary.storedCount, 4)
    XCTAssertEqual(NetworkTripwire.requests, [], "links are kept as text, never fetched")
    let drafts = await store.drafts
    XCTAssertEqual(Set(drafts.map(\.source?.name)), ["Chrome"])
    for draft in drafts {
      XCTAssertEqual(draft.capturedAt.timeIntervalSince(now), 0, accuracy: 1)
    }
    XCTAssertEqual(
      drafts.map(\.text),
      [
        "周三组会改到下午三点\n带上 Twin-7 的曲线\n\n实验记录\nhttps://example.test/notes/7",
        "没有链接的选中文字",
        "十月计划\nhttps://example.test/plan",
        "数据集说明\nhttps://example.test/data.zip",
      ])
    XCTAssertEqual(
      drafts.map(\.extractor),
      [
        EntryExtractor.browserSelection, EntryExtractor.browserSelection,
        EntryExtractor.browserPage, EntryExtractor.browserLink,
      ])
    XCTAssertEqual(Set(drafts.map(\.kind)), [.text])
    XCTAssertEqual(
      summary.confirmation(source: EntrySource.named(EntrySource.browser)),
      "已收进来 4 条 · 来自 Chrome")
  }

  // MARK: Switches

  func testTheBrowserAndTheCommandLineHaveSeparateSwitches() async throws {
    actor Taken {
      var browser: [BrowserAddRequest] = []
      var commandLine = 0
      func note(_ request: BrowserAddRequest) { browser.append(request) }
      func noteCommandLine() { commandLine += 1 }
    }
    let taken = Taken()
    func channel(on: Set<EntryKind>) -> OwnerEntryChannel {
      OwnerEntryChannel(
        isEnabled: { on.contains($0) },
        add: { _ in
          await taken.noteCommandLine()
          return .reply(OwnerReply(message: "ok", stored: 1))
        },
        due: { _ in .reply(OwnerReply(message: "ok")) },
        browserAdd: { request in
          await taken.note(request)
          return .reply(OwnerReply(message: "已收进来 · 来自 Chrome", stored: 1))
        })
    }
    let peer = AgentConnectionPeer(pid: getpid(), uid: getuid(), clientExecutablePath: nil)
    let browserParams = BrowserAddRequest(kind: .page, url: "https://example.test").params
    let cliParams = OwnerAddRequest(text: "一句话").params

    // Only the command line on: the browser is refused with its own words.
    var reply = await channel(on: [.commandLine]).handleOwner(
      id: 1, method: OwnerChannel.browserAddMethod, params: browserParams, peer: peer)
    XCTAssertEqual(reply["error"]?["code"]?.intValue, Int64(OwnerChannel.ErrorCode.disabled))
    XCTAssertEqual(reply["error"]?["message"]?.stringValue, OwnerChannel.browserDisabledMessage)
    // Only the browser on: the command line is refused.
    reply = await channel(on: [.browserExtension]).handleOwner(
      id: 2, method: OwnerChannel.addMethod, params: cliParams, peer: peer)
    XCTAssertEqual(reply["error"]?["message"]?.stringValue, OwnerChannel.disabledMessage)
    reply = await channel(on: [.browserExtension]).handleOwner(
      id: 3, method: OwnerChannel.dueMethod, params: nil, peer: peer)
    XCTAssertEqual(reply["error"]?["code"]?.intValue, Int64(OwnerChannel.ErrorCode.disabled))
    // On: taken; malformed params never reach the App.
    reply = await channel(on: [.browserExtension]).handleOwner(
      id: 4, method: OwnerChannel.browserAddMethod, params: browserParams, peer: peer)
    XCTAssertEqual(reply["result"]?["stored"]?.intValue, 1)
    reply = await channel(on: [.browserExtension]).handleOwner(
      id: 5, method: OwnerChannel.browserAddMethod, params: ["kind": "page"], peer: peer)
    XCTAssertEqual(reply["error"]?["code"]?.intValue, Int64(MCPErrorCode.invalidParams))
    reply = await channel(on: Set(EntryKind.allCases)).handleOwner(
      id: 6, method: "mindloom/owner.somethingElse", params: nil, peer: peer)
    XCTAssertEqual(reply["error"]?["code"]?.intValue, Int64(MCPErrorCode.methodNotFound))
    let browser = await taken.browser
    let commandLine = await taken.commandLine
    XCTAssertEqual(browser.count, 1)
    XCTAssertEqual(commandLine, 0)

    // Off until the owner installs the connection from Settings; not a
    // background entry (it takes only what the owner clicks).
    XCTAssertFalse(EntrySettings.defaults.isOn(.browserExtension))
    XCTAssertFalse(EntryKind.browserExtension.capturesInBackground)
    XCTAssertTrue(EntryKind.browserExtension.detail.contains("不会打开"))
    XCTAssertTrue(EntryKind.browserExtension.detail.contains("不联网"))
  }

  // MARK: The extension itself

  private var extensionFolder: URL {
    // Tests/BestASREntriesTests/<file> → the repository root.
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("integrations/chrome-extension", isDirectory: true)
  }

  func testTheExtensionHasNoNetworkPathAndItsIDIsTheHostsOnlyOrigin() throws {
    let folder = extensionFolder
    let manifest = try JSONValue.parse(
      Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    XCTAssertEqual(manifest["manifest_version"]?.intValue, 3)

    // The ID Chrome derives from the manifest's public key: the first 128
    // bits of its SHA-256, as letters a–p.
    let key = try XCTUnwrap(manifest["key"]?.stringValue.flatMap { Data(base64Encoded: $0) })
    let id = SHA256.hash(data: key).prefix(16).flatMap { [$0 >> 4, $0 & 0x0F] }
      .map { String(UnicodeScalar(UInt8(ascii: "a") + $0)) }.joined()
    XCTAssertEqual(id, BrowserExtension.extensionID)
    XCTAssertEqual(BrowserExtension.origin, "chrome-extension://\(id)/")
    XCTAssertTrue(BrowserExtension.isAllowedOrigin("chrome-extension://\(id)/"))
    XCTAssertFalse(BrowserExtension.isAllowedOrigin("chrome-extension://\(id)"))
    XCTAssertFalse(
      BrowserExtension.isAllowedOrigin("chrome-extension://abcdefghijklmnopabcdefghijklmnop/"))

    // Exactly these permissions; no host access, nothing that runs on pages
    // by itself, nothing other extensions or pages can call.
    XCTAssertEqual(
      Set(manifest["permissions"]?.arrayValue?.compactMap(\.stringValue) ?? []),
      ["activeTab", "contextMenus", "nativeMessaging", "scripting"])
    for absent in [
      "host_permissions", "optional_host_permissions", "optional_permissions", "content_scripts",
      "externally_connectable", "web_accessible_resources", "update_url", "oauth2",
    ] {
      XCTAssertNil(manifest[absent], "\(absent) must not be in the manifest")
    }
    let csp = try XCTUnwrap(manifest["content_security_policy"]?["extension_pages"]?.stringValue)
    XCTAssertTrue(csp.contains("connect-src 'none'"), csp)
    XCTAssertTrue(csp.contains("script-src 'self'"), csp)

    // Only these kinds of files; no network or code-loading API anywhere.
    let files = try XCTUnwrap(FileManager.default.enumerator(atPath: folder.path)).compactMap {
      $0 as? String
    }
    var scripts: [String: String] = [:]
    for file in files {
      let url = folder.appendingPathComponent(file)
      var isDirectory: ObjCBool = false
      _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      if isDirectory.boolValue { continue }
      XCTAssertTrue(["js", "json", "png", "md"].contains(url.pathExtension), file)
      if url.pathExtension == "js" { scripts[file] = try String(contentsOf: url, encoding: .utf8) }
    }
    XCTAssertEqual(Set(scripts.keys), ["background.js"])
    for (file, source) in scripts {
      for forbidden in [
        "fetch(", "XMLHttpRequest", "WebSocket", "EventSource", "sendBeacon", "importScripts",
        "http://", "https://", "eval(", "new Function", "chrome.storage", "localStorage",
        "connectNative", "chrome.downloads", "chrome.cookies", "chrome.history",
      ] {
        XCTAssertFalse(source.contains(forbidden), "\(file) contains \(forbidden)")
      }
      // The host it asks Chrome for is the one the App installs.
      XCTAssertTrue(source.contains(#"const HOST = "\#(BrowserExtension.hostName)";"#), file)
      XCTAssertTrue(source.contains("sendNativeMessage(HOST"), file)
    }
  }
}
