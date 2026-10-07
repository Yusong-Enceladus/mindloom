import BestASRAgentAccess
import BestASREntries
import Foundation
import MindloomAgentProtocol
import MindloomShareDrop
import XCTest

/// v12 F10 (AGENT-IO M6): a side door whose sender Mindloom cannot check is
/// labelled 「本机其他程序」, never with the name the sender gave; the Chrome
/// extension is 「Chrome」 only when Chrome's signature started the helper.
final class SideDoorSourceTests: XCTestCase {
  func testUncheckedSendersAreAnotherProgramOnThisMac() {
    let claimed = ShareDropEntry(
      createdAt: Date(), sourceBundleID: "com.tencent.xinWeChat", sourceName: "微信",
      parts: [.text("看起来像微信")])
    XCTAssertEqual(EntrySource.share(claimed)?.name, "本机其他程序")
    XCTAssertNil(EntrySource.share(claimed)?.bundleID)
    XCTAssertEqual(EntrySource.services?.name, "本机其他程序")
    XCTAssertEqual(
      EntrySource.browser(BrowserAddRequest(kind: .page, url: "https://example.test"))?.name,
      "本机其他程序")
  }

  func testChromeIsKnownByGooglesSignatureOnly() {
    for signer in [
      "team:EQHXZ8M8AV:com.google.Chrome", "team:EQHXZ8M8AV:com.google.Chrome.beta",
      "team:EQHXZ8M8AV:com.google.Chrome.canary",
    ] {
      XCTAssertTrue(BrowserExtension.isChrome(signer: signer), signer)
    }
    for signer in [
      nil, "team:EQHXZ8M8AV:com.google.Chromefake", "team:ABCDE12345:com.google.Chrome",
      "apple:com.google.Chrome", "team:EQHXZ8M8AV:com.google.drivefs",
    ] {
      XCTAssertFalse(BrowserExtension.isChrome(signer: signer), signer ?? "nil")
    }
  }

  func testTheOwnerChannelSetsChromeFromThePeerNeverFromTheRequest() async {
    final class Seen: @unchecked Sendable {
      let lock = NSLock()
      var requests: [BrowserAddRequest] = []
    }
    let seen = Seen()
    let channel = OwnerEntryChannel(
      isEnabled: { _ in true }, add: { _ in .notReady }, due: { _ in .notReady },
      browserAdd: { request in
        seen.lock.withLock { seen.requests.append(request) }
        return .reply(OwnerReply(message: "ok", stored: 1))
      })
    var params = BrowserAddRequest(kind: .page, url: "https://example.test").params
    // A request that claims it came from Chrome is not believed.
    params = .object((params.objectValue ?? [:]).merging(["startedByChrome": true]) { $1 })
    let script = AgentConnectionPeer(pid: 1, uid: getuid(), clientExecutablePath: "/tmp/x")
    let chrome = AgentConnectionPeer(
      pid: 2, uid: getuid(),
      clientExecutablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      clientSigner: "team:EQHXZ8M8AV:com.google.Chrome")
    _ = await channel.handleOwner(
      id: 1, method: OwnerChannel.browserAddMethod, params: params, peer: script)
    _ = await channel.handleOwner(
      id: 2, method: OwnerChannel.browserAddMethod, params: params, peer: chrome)
    XCTAssertEqual(seen.requests.map(\.startedByChrome), [false, true])
  }
}
