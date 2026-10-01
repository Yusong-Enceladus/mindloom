import BestASRAgentAccess
import BestASREntries
import Darwin
import Foundation
import MindloomAgentProtocol
import XCTest

/// V8 contract A6 end to end, in a real browser: the unpacked extension from
/// `integrations/chrome-extension` loaded into a headless Chromium with a
/// throw-away profile, the host manifest written by `BrowserHostManifest`
/// into that profile, the real helper started by the browser, the App's
/// socket server and the real intake path. Opt-in, because it starts a
/// browser: set `MINDLOOM_E2E_CHROME` to a Chromium executable (branded
/// Google Chrome no longer loads unpacked extensions from the command line).
/// The test drives the extension's own click handlers through the DevTools
/// protocol on the loopback interface; nothing else is contacted.
final class ChromeExtensionEndToEndTests: XCTestCase {
  private var browser: Process?
  private var profile: URL?

  override func tearDown() {
    if let browser, browser.isRunning {
      browser.terminate()
      browser.waitUntilExit()
    }
    if let profile { try? FileManager.default.removeItem(at: profile) }
    super.tearDown()
  }

  /// `MINDLOOM_E2E_EXTENSION` (e.g. the copy inside a built App), else the
  /// repository's folder.
  private var extensionFolder: URL {
    if let path = ProcessInfo.processInfo.environment["MINDLOOM_E2E_EXTENSION"] {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("integrations/chrome-extension", isDirectory: true)
  }

  func testTheExtensionHandsTheSelectionAndPageToTheAppThroughTheHelperAndNothingElse()
    async throws
  {
    guard let chromium = ProcessInfo.processInfo.environment["MINDLOOM_E2E_CHROME"] else {
      throw XCTSkip("set MINDLOOM_E2E_CHROME to a Chromium executable to run this test")
    }
    let helper = try mindloomHelperBinary()
    // Chrome starts the helper in its own folder (inside the App bundle for
    // the real App): nothing may appear there.
    let helperFolder = helper.deletingLastPathComponent()
    let besideHelper = Set(try FileManager.default.contentsOfDirectory(atPath: helperFolder.path))
    let root = try makeSyntheticRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let switches = BrowserSwitches()
    await switches.set([.browserExtension])
    let drafts = BrowserDrafts()
    let (server, consent, records) = try browserServer(
      root: root, owner: browserApp(switches, root: root, drafts: drafts))
    try server.start()
    defer { server.stop() }

    // A throw-away profile; Chromium looks for user-level hosts in
    // `<profile>/NativeMessagingHosts`, so the installer writes there.
    let profile = FileManager.default.temporaryDirectory
      .appendingPathComponent("ml-chromium-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    self.profile = profile
    let manifest = BrowserHostManifest(
      directory: profile.appendingPathComponent("NativeMessagingHosts", isDirectory: true))
    XCTAssertEqual(try manifest.install(helperPath: helper.path), .installed)

    // A loopback listener that must never see a connection from the extension.
    let tripwire = try LoopbackTripwire()
    defer { tripwire.close() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: chromium)
    process.arguments = [
      "--headless=new", "--user-data-dir=\(profile.path)", "--use-mock-keychain",
      "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
      "--disable-component-update", "--disable-sync", "--disable-features=Translate,MediaRouter",
      "--remote-debugging-port=0", "--load-extension=\(extensionFolder.path)", "about:blank",
    ]
    var environment = ProcessInfo.processInfo.environment
    // The helper the browser starts finds the synthetic library's socket.
    environment[AgentSocketLocation.dataRootEnvironmentKey] = root.path
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    browser = process

    let worker = try await serviceWorker(profile: profile)
    let devtools = DevTools(url: worker)
    defer { devtools.close() }
    // The worker is listed as soon as it starts; wait until its script ran.
    var loaded = JSONValue.null
    for _ in 0..<40 {
      loaded = try await devtools.evaluate("typeof globalThis.mindloom")
      if loaded == "object" { break }
      try await Task.sleep(for: .milliseconds(250))
    }
    let apis = try await devtools.evaluate(
      "[typeof chrome.contextMenus, typeof chrome.action, typeof chrome.scripting, typeof chrome.runtime.sendNativeMessage].join(',')"
    )
    XCTAssertEqual(loaded, "object", apis.serialized)

    // The context menu on a selection (Chrome hands the page in `info`).
    var reply = try await devtools.evaluate(
      """
      mindloom.handleMenuClick({menuItemId: "mindloom-selection", selectionText: "周三组会改到下午三点",
        pageUrl: "https://example.test/notes/7"}, {id: -1, title: "实验记录"})
      """)
    XCTAssertEqual(reply["ok"], true, reply.serialized)
    XCTAssertEqual(reply["message"]?.stringValue, "已收进来 · 来自 Chrome")
    // The button says so: a check mark, and the answer as its tooltip.
    var badge = try await devtools.evaluate(
      "Promise.all([chrome.action.getBadgeText({}), chrome.action.getTitle({})]).then(v => v.join('|'))"
    )
    XCTAssertEqual(badge.stringValue, "✓|已收进来 · 来自 Chrome")
    // The context menu on the page, and the toolbar button with no selection.
    reply = try await devtools.evaluate(
      """
      mindloom.handleMenuClick({menuItemId: "mindloom-page", pageUrl: "https://example.test/plan"},
        {id: -1, title: "十月计划"})
      """)
    XCTAssertEqual(reply["ok"], true, reply.serialized)
    reply = try await devtools.evaluate(
      #"mindloom.handleActionClick({id: -1, url: "https://example.test/paper", title: "论文初稿"})"#)
    XCTAssertEqual(reply["ok"], true, reply.serialized)
    // A browser page has no link to keep: refused in the extension itself.
    reply = try await devtools.evaluate(
      #"mindloom.handleActionClick({id: -1, url: "chrome://settings", title: "设置"})"#)
    XCTAssertEqual(reply["ok"], false)
    XCTAssertEqual(reply["reason"], "local")

    XCTAssertEqual(
      drafts.all.map(\.text),
      [
        "周三组会改到下午三点\n\n实验记录\nhttps://example.test/notes/7",
        "十月计划\nhttps://example.test/plan",
        "论文初稿\nhttps://example.test/paper",
      ])
    XCTAssertEqual(Set(drafts.all.compactMap(\.source?.name)), ["Chrome"])

    // Switched off in Settings: the extension says so; nothing is taken.
    await switches.set([.commandLine])
    reply = try await devtools.evaluate(
      #"mindloom.handleMenuClick({menuItemId: "mindloom-page", pageUrl: "https://example.test/x"}, {id: -1})"#
    )
    XCTAssertEqual(reply["ok"], false)
    XCTAssertEqual(reply["message"]?.stringValue, OwnerChannel.browserDisabledMessage)
    badge = try await devtools.evaluate(
      "Promise.all([chrome.action.getBadgeText({}), chrome.action.getTitle({})]).then(v => v.join('|'))"
    )
    XCTAssertEqual(badge.stringValue, "!|" + OwnerChannel.browserDisabledMessage)
    await switches.set([.browserExtension])

    // No network path: the extension's CSP blocks a connection even if code
    // tried one (the loopback listener sees nothing).
    let attempt = try await devtools.evaluate(
      "fetch('http://127.0.0.1:\(tripwire.port)/probe').then(() => 'fetched', e => 'blocked: ' + e.message)"
    )
    XCTAssertTrue(attempt.stringValue?.hasPrefix("blocked") == true, attempt.serialized)
    XCTAssertEqual(tripwire.connections, 0, "the extension reached the network")

    // A manifest that allows another extension: the browser refuses to start
    // the helper for ours.
    var foreign = BrowserHostManifest.content(helperPath: helper.path)
    if case .object(var object) = foreign {
      object["allowed_origins"] = .strings(["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"])
      foreign = .object(object)
    }
    try Data(foreign.serialized.utf8).write(to: manifest.fileURL)
    reply = try await devtools.evaluate(
      #"mindloom.handleMenuClick({menuItemId: "mindloom-page", pageUrl: "https://example.test/y"}, {id: -1})"#
    )
    XCTAssertEqual(reply["ok"], false)
    XCTAssertEqual(reply["reason"], "host")
    XCTAssertTrue(reply["message"]?.stringValue?.contains("重新连接") == true, reply.serialized)

    // Removed (the switch turned off): the extension says how to connect.
    XCTAssertEqual(try manifest.remove(), .removed)
    reply = try await devtools.evaluate(
      #"mindloom.handleMenuClick({menuItemId: "mindloom-page", pageUrl: "https://example.test/z"}, {id: -1})"#
    )
    XCTAssertEqual(reply["ok"], false)
    XCTAssertTrue(reply["message"]?.stringValue?.contains("设置 → 入口") == true, reply.serialized)

    XCTAssertEqual(drafts.all.count, 3, "nothing taken while off, forbidden or removed")
    XCTAssertEqual(
      Set(try FileManager.default.contentsOfDirectory(atPath: helperFolder.path)), besideHelper,
      "the helper left something in the folder Chrome started it in")
    let asked = await consent.consentRequests.count
    XCTAssertEqual(asked, 0)
    let audit = try await records.agentAudit(clientKey: nil, limit: 100)
    XCTAssertEqual(audit.count, 0)
  }

  /// The extension's service worker's DevTools address.
  private func serviceWorker(profile: URL) async throws -> URL {
    let portFile = profile.appendingPathComponent("DevToolsActivePort")
    let session = URLSession(configuration: .ephemeral)
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
      if let text = try? String(contentsOf: portFile, encoding: .utf8),
        let port = text.split(separator: "\n").first.flatMap({ Int($0) }),
        let list = URL(string: "http://127.0.0.1:\(port)/json/list"),
        let fetched = try? await session.data(from: list),
        let targets = try? JSONValue.parse(fetched.0).arrayValue
      {
        for target in targets
        where target["type"]?.stringValue == "service_worker"
          && target["url"]?.stringValue?.hasPrefix(BrowserExtension.origin) == true
        {
          if let address = target["webSocketDebuggerUrl"]?.stringValue.flatMap(URL.init(string:)) {
            return address
          }
        }
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw DevTools.Failure(description: "the browser did not start the extension in time")
  }
}

/// A minimal DevTools protocol client (Runtime.evaluate only).
private final class DevTools: @unchecked Sendable {
  private let task: URLSessionWebSocketTask
  private var nextID: Int64 = 0

  init(url: URL) {
    task = URLSession(configuration: .ephemeral).webSocketTask(with: url)
    task.resume()
  }

  func close() { task.cancel(with: .normalClosure, reason: nil) }

  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  /// The value of an expression (a promise is awaited).
  func evaluate(_ expression: String, timeout: Duration = .seconds(20)) async throws -> JSONValue {
    nextID += 1
    let id = nextID
    let request: JSONValue = [
      "id": .int(id), "method": "Runtime.evaluate",
      "params": [
        "expression": .string(expression), "awaitPromise": true, "returnByValue": true,
      ],
    ]
    try await task.send(.string(request.serialized))
    let task = self.task
    return try await withThrowingTaskGroup(of: JSONValue.self) { group in
      group.addTask {
        while true {
          guard case .string(let text) = try await task.receive(),
            let message = try? JSONValue.parse(text), message["id"]?.intValue == id
          else { continue }
          if let details = message["result"]?["exceptionDetails"] {
            throw Failure(description: details.serialized)
          }
          if let error = message["error"] { throw Failure(description: error.serialized) }
          return message["result"]?["result"]?["value"] ?? .null
        }
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        // Ends the pending receive, so the group can finish.
        task.cancel(with: .goingAway, reason: nil)
        throw Failure(description: "no answer from the browser in time")
      }
      let value = try await group.next()!
      group.cancelAll()
      return value
    }
  }
}

/// Counts TCP connections to a loopback port.
private final class LoopbackTripwire: @unchecked Sendable {
  let port: UInt16
  private let descriptor: Int32
  private let lock = NSLock()
  private var count = 0
  private var thread: Thread?

  init() throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard listener >= 0, bound == 0, listen(listener, 8) == 0 else {
      throw POSIXError(.EADDRNOTAVAIL)
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(listener, $0, &length)
      }
    }
    descriptor = listener
    port = UInt16(bigEndian: actual.sin_port)
    let thread = Thread { [weak self] in self?.acceptLoop() }
    self.thread = thread
    thread.start()
  }

  var connections: Int { lock.withLock { count } }

  private func acceptLoop() {
    while true {
      let client = accept(descriptor, nil, nil)
      guard client >= 0 else { return }
      lock.withLock { count += 1 }
      Darwin.close(client)
    }
  }

  func close() {
    shutdown(descriptor, SHUT_RDWR)
    Darwin.close(descriptor)
  }
}
