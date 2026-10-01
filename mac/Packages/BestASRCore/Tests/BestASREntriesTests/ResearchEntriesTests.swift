import BestASRDomain
import BestASREntries
import BestASRIntake
import Foundation
import XCTest

/// V8 contract A7: Git commits become items with subject, body, changed file
/// names and counts, never file contents; Zotero's local API (127.0.0.1
/// only) gives new items, notes and annotations with a citation.
final class ResearchEntriesTests: XCTestCase {
  // MARK: Git

  private struct Repo {
    let url: URL
    let git: URL

    @discardableResult
    func run(_ arguments: [String], environment extra: [String: String] = [:]) throws -> String {
      let process = Process()
      process.executableURL = git
      process.arguments = ["-C", url.path] + arguments
      var environment = [
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "HOME": url.path,
        "GIT_AUTHOR_NAME": "张三", "GIT_AUTHOR_EMAIL": "zhangsan@example.invalid",
        "GIT_COMMITTER_NAME": "张三", "GIT_COMMITTER_EMAIL": "zhangsan@example.invalid",
      ]
      environment.merge(extra) { $1 }
      process.environment = environment
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw NSError(domain: "git", code: Int(process.terminationStatus))
      }
      return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ path: String, _ text: String) throws {
      let file = url.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: file)
    }
  }

  private func makeRepo() throws -> (Repo, GitRunner) {
    guard let runner = GitRunner.locate() else { throw XCTSkip("no git on this Mac") }
    let folder = try makeTemporaryFolder("paper")
    let repo = Repo(url: folder, git: runner.executable)
    try repo.run(["init", "-q", "-b", "main"])
    try repo.write("main.tex", "\\section{Intro}")
    try repo.run(["add", "."])
    try repo.run(["commit", "-q", "-m", "初稿框架"])
    return (repo, runner)
  }

  func testNewCommitsBecomeItemsWithNamesAndCountsButNeverContents() async throws {
    let (repo, runner) = try makeRepo()
    let watched = WatchedRepository(path: repo.url.path, branches: ["main"])
    var state = GitWatchState()
    let now = Date()
    // First look: only where the branch is.
    XCTAssertEqual(GitWatch.plan([watched], runner: runner, state: &state, now: now).items, [])

    let sentinel = "SENTINEL-CONTENT-7f3a 机密实验数据 13800138000"
    try repo.write("sections/method.tex", sentinel)
    try repo.write("main.tex", "\\section{Intro}\n\(sentinel)")
    try repo.write("data/results.csv", sentinel)
    try repo.run(["add", "."])
    try repo.run(["commit", "-q", "-m", "写方法部分", "-m", "补了实验设置；等王老师的数据"])
    try repo.run(["rm", "-q", "data/results.csv"])
    try repo.run(["commit", "-q", "-m", "删掉临时结果"])
    // Prove no file object is needed: remove every blob from the object
    // store. Reading the history still works; reading contents could not.
    let blobs = try repo.run(["rev-list", "--objects", "--all"]).split(separator: "\n")
      .map { String($0.split(separator: " ").first ?? "") }
      .filter { (try? repo.run(["cat-file", "-t", $0])) == "blob" }
    XCTAssertFalse(blobs.isEmpty)
    for blob in blobs {
      let object = repo.url.appendingPathComponent(
        ".git/objects/\(blob.prefix(2))/\(blob.dropFirst(2))")
      try FileManager.default.removeItem(at: object)
    }
    XCTAssertThrowsError(try repo.run(["cat-file", "-p", blobs[0]]))

    let (items, problems) = GitWatch.plan(
      [watched], runner: runner, state: &state, now: now,
      timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    XCTAssertEqual(problems, [])
    XCTAssertEqual(items.count, 2)
    let texts = items.compactMap { item -> String? in
      if case .text(let text, let extractor) = item.candidate, extractor == EntryExtractor.gitCommit
      {
        return text
      }
      return nil
    }
    XCTAssertEqual(texts.count, 2)
    for text in texts {
      XCTAssertFalse(text.contains("SENTINEL"), "file contents must never be read")
      XCTAssertFalse(text.contains("13800138000"))
      XCTAssertFalse(text.contains("example.invalid"), "author e-mail is never taken")
    }
    XCTAssertTrue(
      texts[0].hasPrefix("Git 提交：写方法部分\n仓库：\(repo.url.lastPathComponent) · 分支：main · 提交 "))
    XCTAssertTrue(texts[0].contains("作者：张三"))
    XCTAssertTrue(texts[0].contains("补了实验设置；等王老师的数据"))
    XCTAssertTrue(texts[0].contains("改动：3 个文件（新增 2，修改 1）"))
    XCTAssertTrue(texts[0].contains("A  sections/method.tex"))
    XCTAssertTrue(texts[0].contains("M  main.tex"))
    XCTAssertTrue(texts[1].contains("改动：1 个文件（删除 1）"))
    XCTAssertEqual(items[0].source?.name, "Git · \(repo.url.lastPathComponent)")

    // Taken once: nothing new on the next look, and the IDs are stable.
    XCTAssertEqual(GitWatch.plan([watched], runner: runner, state: &state, now: now).items, [])
    let root = try makeTemporaryFolder()
    let (committer, _) = makeCommitter(root: root)
    let first = await committer.commit(items)
    let again = await committer.commit(items)
    XCTAssertEqual(first.storedCount, 2)
    XCTAssertEqual(again.alreadyTaken.count, 2)
  }

  func testOtherBranchesAndRewrittenHistory() throws {
    let (repo, runner) = try makeRepo()
    let watched = WatchedRepository(path: repo.url.path)  // the checked-out branch
    var state = GitWatchState()
    _ = GitWatch.plan([watched], runner: runner, state: &state, now: Date())
    try repo.run(["checkout", "-q", "-b", "experiment"])
    try repo.write("notes.md", "x")
    try repo.run(["add", "."])
    try repo.run(["commit", "-q", "-m", "试验分支"])
    try repo.run(["checkout", "-q", "main"])
    // A branch nobody chose is not read.
    XCTAssertEqual(GitWatch.plan([watched], runner: runner, state: &state, now: Date()).items, [])
    XCTAssertEqual(Set(runner.branches(in: repo.url)), ["main", "experiment"])
    // An unsafe branch name is never passed to git.
    let odd = WatchedRepository(path: repo.url.path, branches: ["--output=/tmp/x"])
    let result = GitWatch.plan([odd], runner: runner, state: &state, now: Date())
    XCTAssertEqual(result.items, [])
    XCTAssertEqual(result.problems.count, 1)
    XCTAssertFalse(GitBranch.isSafeName("a..b"))
    XCTAssertTrue(GitBranch.isSafeName("feature/v8-入口"))
    // Only history commands can be run at all.
    XCTAssertThrowsError(try runner.run(["cat-file", "-p", "HEAD:main.tex"], in: repo.url))
    XCTAssertThrowsError(try runner.run(["diff", "HEAD~1"], in: repo.url))
  }

  // MARK: Zotero

  private actor FakeZotero: ZoteroTransport {
    var version = 100
    var items = Data("[]".utf8)
    var single: [String: Data] = [:]
    var requests: [(String, [URLQueryItem])] = []
    var available = true

    func set(version: Int, items: Data, single: [String: Data]) {
      self.version = version
      self.items = items
      self.single = single
    }

    func setAvailable(_ value: Bool) { available = value }

    func get(_ path: String, query: [URLQueryItem]) async throws -> ZoteroResponse {
      requests.append((path, query))
      guard available else { throw ZoteroLoopbackTransport.TransportError.unavailable }
      if let key = path.split(separator: "/").last.map(String.init), let item = single[key] {
        return ZoteroResponse(status: 200, body: item, libraryVersion: version)
      }
      return ZoteroResponse(status: 200, body: items, libraryVersion: version)
    }
  }

  private func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value)
  }

  private func zoteroItem(_ key: String, _ data: [String: Any]) -> [String: Any] {
    var data = data
    data["key"] = key
    return ["key": key, "version": 101, "data": data]
  }

  func testZoteroItemsNotesAndAnnotationsWithCitations() async throws {
    let zotero = FakeZotero()
    var state = ZoteroWatchState()
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    // First look: only the library version.
    let first = await ZoteroWatch.pass(transport: zotero, state: &state, now: now)
    XCTAssertEqual(first, .items([]))
    XCTAssertEqual(state.libraryVersion, 100)

    let paper = zoteroItem(
      "ABCD2345",
      [
        "itemType": "journalArticle", "title": "Learning to Fold Cloth",
        "creators": [
          ["creatorType": "author", "firstName": "San", "lastName": "Zhang"],
          ["creatorType": "author", "firstName": "Si", "lastName": "Li"],
        ],
        "date": "2025-03", "publicationTitle": "Robotics Letters", "DOI": "10.1000/xyz",
        "abstractNote": "We fold.", "tags": [["tag": "叠衣"]], "dateAdded": "2026-09-20T08:00:00Z",
      ])
    let attachment = zoteroItem(
      "PDFA2345", ["itemType": "attachment", "parentItem": "ABCD2345", "title": "Full Text PDF"])
    let note = zoteroItem(
      "NOTE2345",
      [
        "itemType": "note", "parentItem": "ABCD2345",
        "note": "<p>第三节的实验&amp;数据<br/>可以复现</p>", "dateAdded": "2026-09-20T09:00:00Z",
      ])
    let annotation = zoteroItem(
      "ANNO2345",
      [
        "itemType": "annotation", "parentItem": "PDFA2345", "annotationType": "highlight",
        "annotationText": "success rate of 92%", "annotationComment": "和我们的 Twin-7 对比",
        "annotationPageLabel": "4", "dateAdded": "2026-09-20T10:00:00Z",
      ])
    await zotero.set(
      version: 104, items: try json([paper, attachment, note, annotation]),
      single: ["ABCD2345": try json(paper), "PDFA2345": try json(attachment)])
    guard
      case .items(let items) = await ZoteroWatch.pass(transport: zotero, state: &state, now: now)
    else { return XCTFail("Zotero was available") }
    XCTAssertEqual(state.libraryVersion, 104)
    XCTAssertEqual(items.count, 3, "the attachment itself is skipped")
    let texts = items.compactMap { item -> String? in
      if case .text(let text, _) = item.candidate { return text }
      return nil
    }
    XCTAssertEqual(
      texts[0],
      """
      Zotero 文献：Learning to Fold Cloth
      标签：叠衣
      摘要：We fold.
      引用：Zhang & Li (2025). Learning to Fold Cloth. Robotics Letters. https://doi.org/10.1000/xyz
      """)
    XCTAssertEqual(
      texts[1],
      "Zotero 笔记（Learning to Fold Cloth）：\n第三节的实验&数据\n可以复现\n引用：Zhang & Li (2025). Learning to Fold Cloth. Robotics Letters. https://doi.org/10.1000/xyz"
    )
    XCTAssertTrue(
      texts[2].hasPrefix(
        "Zotero 批注（Learning to Fold Cloth 第 4 页）：\n「success rate of 92%」\n和我们的 Twin-7 对比\n引用：Zhang & Li (2025)"
      ))
    XCTAssertEqual(Set(items.compactMap(\.source?.name)), ["Zotero"])
    // Since the last version, from the loopback API only.
    let requests = await zotero.requests
    XCTAssertTrue(requests.allSatisfy { $0.0.hasPrefix("/api/users/0/items") })
    XCTAssertTrue(requests.contains { $0.1.contains(URLQueryItem(name: "since", value: "100")) })
    // A changed item is not taken again.
    await zotero.set(version: 105, items: try json([paper]), single: [:])
    let later = await ZoteroWatch.pass(transport: zotero, state: &state, now: now)
    XCTAssertEqual(later, .items([]))
    // Zotero closed (or its local API off): nothing taken, nothing lost.
    await zotero.setAvailable(false)
    let closed = await ZoteroWatch.pass(transport: zotero, state: &state, now: now)
    XCTAssertEqual(closed, .unavailable)
    XCTAssertEqual(state.libraryVersion, 105)
  }

  func testTheZoteroTransportOnlyEverAddressesThisMac() {
    let request = ZoteroLoopbackTransport.request(
      "/api/users/0/items", query: [.init(name: "since", value: "3")])
    XCTAssertEqual(request?.url?.absoluteString, "http://127.0.0.1:23119/api/users/0/items?since=3")
    XCTAssertEqual(request?.value(forHTTPHeaderField: "Zotero-API-Version"), "3")
    for bad in [
      "https://example.org/api/", "//example.org/api/x", "/api/../x", "/connector/ping",
      "api/users",
    ] {
      XCTAssertNil(ZoteroLoopbackTransport.request(bad, query: []), bad)
    }
  }
}
