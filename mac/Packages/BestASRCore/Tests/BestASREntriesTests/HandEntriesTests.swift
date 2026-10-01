import BestASRDomain
import BestASREntries
import BestASRIntake
import Foundation
import MindloomAgentProtocol
import MindloomShareDrop
import XCTest

/// V8 contract A1–A3: the share extension's drop folder, the Services menu,
/// Shortcuts and the command line all reach the same intake rules as a paste
/// or a drop, keep their source and time, and never fetch a link.
final class HandEntriesTests: XCTestCase {
  // MARK: Share drop folder

  func testAShareIsWrittenWholeThenTakenInWithItsSourceAndTime() async throws {
    let root = try makeTemporaryFolder()
    let dropbox = ShareDropbox.inLibrary(root)
    // Closed until the App opens it: the extension says sharing is off.
    XCTAssertFalse(dropbox.isOpen)
    XCTAssertThrowsError(try dropbox.write(ShareDropEntry(parts: [.text("x")]))) {
      XCTAssertEqual($0 as? ShareDropbox.DropError, .closed)
    }
    XCTAssertTrue(dropbox.prepareFolder())
    var folder = stat()
    XCTAssertEqual(lstat(dropbox.directory.path, &folder), 0)
    XCTAssertEqual(folder.st_mode & 0o777, 0o700)

    let file = root.appendingPathComponent("notes.txt")
    try Data("组会纪要：周五交初稿".utf8).write(to: file)
    let shared = Date(timeIntervalSince1970: 1_790_000_000)
    let png = try pngData()
    let entry = ShareDropEntry(
      createdAt: shared, sourceBundleID: "com.apple.Safari", sourceName: "Safari",
      parts: [
        .text("选中的一段话"), .link("https://example.org/paper?id=7", title: "一篇论文"),
        .file(file.path), .data(name: "picture.png", type: "public.png"),
      ])
    try dropbox.write(entry, data: ["picture.png": png])
    var json = stat()
    XCTAssertEqual(
      lstat(dropbox.directory.appendingPathComponent("\(entry.id).json").path, &json), 0)
    XCTAssertEqual(json.st_mode & 0o777, 0o600)

    let (pending, malformed) = dropbox.pending()
    XCTAssertEqual(malformed, 0)
    XCTAssertEqual(pending.map(\.entry), [entry])

    NetworkTripwire.arm()
    defer { NetworkTripwire.disarm() }
    let (items, refused) = HandEntries.items(from: try XCTUnwrap(pending.first))
    XCTAssertEqual(refused, [])
    XCTAssertEqual(items.count, 4)
    let (committer, store) = makeCommitter(root: root)
    let summary = await committer.commit(items)
    dropbox.remove(try XCTUnwrap(pending.first))
    XCTAssertEqual(summary.storedCount, 4)
    XCTAssertEqual(summary.rejected, [])
    XCTAssertEqual(NetworkTripwire.requests, [], "a shared link must never be fetched")

    let drafts = await store.drafts
    XCTAssertEqual(Set(drafts.compactMap(\.source?.name)), ["Safari"])
    XCTAssertEqual(Set(drafts.compactMap(\.source?.bundleID)), ["com.apple.Safari"])
    for draft in drafts {
      XCTAssertEqual(
        draft.capturedAt.timeIntervalSince1970, shared.timeIntervalSince1970, accuracy: 1)
    }
    XCTAssertEqual(
      drafts.map(\.kind), [.text, .text, .document, .image])
    XCTAssertEqual(drafts[0].extractor, EntryExtractor.shareText)
    XCTAssertEqual(drafts[1].text, "一篇论文\nhttps://example.org/paper?id=7")
    XCTAssertEqual(drafts[1].extractor, EntryExtractor.shareLink)
    XCTAssertTrue(drafts[2].text.contains("周五交初稿"))
    XCTAssertEqual(dropbox.pending().entries, [])
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: dropbox.directory.appendingPathComponent(entry.id).path))
  }

  func testBrokenOrHalfWrittenSharesAreNeverTakenIn() throws {
    let root = try makeTemporaryFolder()
    let dropbox = ShareDropbox.inLibrary(root)
    XCTAssertTrue(dropbox.prepareFolder())
    // A share still being written (temporary name) is not read, nor removed.
    let partial = dropbox.directory.appendingPathComponent(
      ".\(UUID().uuidString.lowercased()).json.tmp")
    try Data("{".utf8).write(to: partial)
    // A JSON under a name that is not its ID, a data part escaping its
    // folder, a relative file path, and garbage: removed and counted.
    let id = UUID().uuidString.lowercased()
    var moved = ShareDropEntry(id: id, parts: [.text("x")])
    moved.id = UUID().uuidString.lowercased()
    let encoder = JSONEncoder()
    try encoder.encode(moved).write(to: dropbox.directory.appendingPathComponent("\(id).json"))
    let escape = ShareDropEntry(parts: [.data(name: "../../secret", type: nil)])
    try encoder.encode(escape).write(
      to: dropbox.directory.appendingPathComponent("\(escape.id).json"))
    let relative = ShareDropEntry(parts: [.file("notes.txt")])
    try encoder.encode(relative).write(
      to: dropbox.directory.appendingPathComponent("\(relative.id).json"))
    try Data("not json".utf8).write(
      to: dropbox.directory.appendingPathComponent("\(UUID().uuidString.lowercased()).json"))

    let (pending, malformed) = dropbox.pending()
    XCTAssertEqual(pending, [])
    XCTAssertEqual(malformed, 4)
    XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    // Writing refuses the same shapes up front.
    XCTAssertThrowsError(try dropbox.write(escape, data: ["../../secret": Data()]))
    XCTAssertThrowsError(
      try dropbox.write(ShareDropEntry(parts: [.data(name: "a.bin", type: nil)])))
    XCTAssertThrowsError(
      try dropbox.write(
        ShareDropEntry(parts: [.data(name: "big.bin", type: nil)]),
        data: ["big.bin": Data(count: ShareDropbox.maximumDataBytes + 1)])
    ) { XCTAssertEqual($0 as? ShareDropbox.DropError, .tooLarge) }
    // Switching sharing off removes the folder.
    dropbox.removeFolder()
    XCTAssertFalse(dropbox.isOpen)
  }

  func testSharedAudioBytesAreRefusedButASharedAudioFileIsQueuedForImport() async throws {
    let root = try makeTemporaryFolder()
    let dropbox = ShareDropbox.inLibrary(root)
    XCTAssertTrue(dropbox.prepareFolder())
    // An "m4a" by its first bytes (ftyp M4A).
    var audio = Data([0, 0, 0, 0x20]) + Data("ftypM4A ".utf8)
    audio += Data(count: 64)
    let audioFile = root.appendingPathComponent("voice.m4a")
    try audio.write(to: audioFile)
    let entry = ShareDropEntry(
      sourceName: "访达",
      parts: [.data(name: "clip.m4a", type: "public.mpeg-4-audio"), .file(audioFile.path)])
    try dropbox.write(entry, data: ["clip.m4a": audio])
    let pending = try XCTUnwrap(dropbox.pending().entries.first)
    let (items, refused) = HandEntries.items(from: pending)
    XCTAssertEqual(refused, [])
    let (committer, store) = makeCommitter(root: root)
    let summary = await committer.commit(items)
    let drafts = await store.drafts
    // The bytes have no file of their own to import later: refused, not sent.
    XCTAssertTrue(summary.rejected.contains("音视频请在访达里分享文件，或拖进织机导入"))
    // The file goes to the import pipeline, like a drop.
    XCTAssertEqual(summary.media.map(\.lastPathComponent), ["voice.m4a"])
    XCTAssertTrue(
      drafts.allSatisfy { $0.extractor == UserItemLimits.localOnlyExtractor || $0.kind != .file })
  }

  // MARK: Services, Shortcuts, command line

  func testServicesShortcutsAndCommandLineUseTheSameRulesAndNeverFetchLinks() async throws {
    let root = try makeTemporaryFolder()
    let (committer, store) = makeCommitter(root: root)
    NetworkTripwire.arm()
    defer { NetworkTripwire.disarm() }
    let now = Date(timeIntervalSince1970: 1_790_100_000)
    let safari = ItemSourceApplication(bundleID: "com.apple.Safari", name: "Safari")
    var items = HandEntries.servicesText("选中的文字 https://example.org/x", source: safari, at: now)
    XCTAssertEqual(HandEntries.servicesText("   \n", source: safari, at: now), [])
    items += try HandEntries.shortcut(
      text: "快捷指令里的话", url: "https://example.org/shared", file: nil, at: now)
    let pdfLike = root.appendingPathComponent("plan.md")
    try Data("# 计划\n十月三日交稿".utf8).write(to: pdfLike)
    let cli = HandEntries.commandLine(
      OwnerAddRequest(
        text: "终端里收进来的", filePaths: [pdfLike.path], url: "https://example.org/cli",
        title: "参考"), at: now)
    XCTAssertEqual(cli.refused, [])
    items += cli.items
    // A file path that is not absolute is never opened.
    XCTAssertEqual(
      HandEntries.commandLine(OwnerAddRequest(filePaths: ["relative/path"]), at: now).refused,
      ["只收本机文件，未收进来"])
    // The processor refuses a web URL as a "file" before reading anything.
    items.append(
      EntryIntakeItem(
        candidate: .file(URL(string: "https://example.org/movie.mp4")!), source: nil,
        capturedAt: now))

    let summary = await committer.commit(items)
    XCTAssertEqual(summary.storedCount, 6)
    XCTAssertEqual(summary.rejected, ["只收本机文件，链接未收进来"])
    XCTAssertEqual(NetworkTripwire.requests, [], "links are kept as text, never fetched")
    let drafts = await store.drafts
    XCTAssertEqual(
      drafts.map(\.source?.name),
      ["Safari", "快捷指令", "快捷指令", "命令行", "命令行", "命令行"])
    XCTAssertEqual(
      Array(drafts.map(\.extractor).prefix(5)),
      [
        EntryExtractor.servicesText, EntryExtractor.shortcutText, EntryExtractor.shortcutLink,
        EntryExtractor.commandLineText, EntryExtractor.commandLineLink,
      ])
    XCTAssertEqual(drafts[5].kind, .document)
    XCTAssertEqual(drafts[2].text, "https://example.org/shared")
    XCTAssertEqual(drafts[4].text, "参考\nhttps://example.org/cli")
    XCTAssertEqual(drafts[5].originalFilename, "plan.md")
    XCTAssertEqual(
      summary.confirmation(source: EntrySource.named("命令行")), "已收进来 6 条 · 来自 命令行；只收本机文件，链接未收进来")
  }

  func testAShortcutFileIsTakenByTheFileRulesAndItsScratchCopyRemoved() async throws {
    let root = try makeTemporaryFolder()
    let (committer, store) = makeCommitter(root: root)
    let items = try HandEntries.shortcut(
      text: nil, url: nil,
      file: (Data("第一行\n第二行".utf8), "../../会议记录.txt", "public.plain-text"), at: Date())
    let scratch = try XCTUnwrap(items.first?.scratch)
    XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path))
    let summary = await committer.commit(items)
    XCTAssertEqual(summary.storedCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    let firstDraft = await store.drafts.first
    let draft = try XCTUnwrap(firstDraft)
    // The name lost its folders; the text was read on this Mac.
    XCTAssertEqual(draft.originalFilename, "会议记录.txt")
    XCTAssertTrue(draft.text.contains("第二行"))
    // Image bytes go the image path (normalized, read here, redacted when sent).
    let png = try HandEntries.shortcut(
      text: nil, url: nil, file: (try pngData(), "photo", nil), at: Date())
    XCTAssertNil(png.first?.scratch)
    let pictures = await committer.commit(png)
    XCTAssertEqual(pictures.storedCount, 1)
    let kinds = await store.drafts.map(\.kind)
    XCTAssertEqual(kinds.last, .image)
  }

  func testFilesInsideTheLibraryAreRefusedFromEveryEntry() async throws {
    let root = try makeTemporaryFolder()
    let library = root.appendingPathComponent("library", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    let inside = library.appendingPathComponent("history-export.txt")
    try Data("内部".utf8).write(to: inside)
    let (committer, store) = makeCommitter(root: root, protected: library)
    let cli = HandEntries.commandLine(OwnerAddRequest(filePaths: [inside.path]), at: Date())
    let summary = await committer.commit(cli.items)
    XCTAssertEqual(summary.storedCount, 0)
    XCTAssertEqual(summary.rejected, [IntakeProcessor.protectedFileMessage])
    let count = await store.drafts.count
    XCTAssertEqual(count, 0)
  }

  // MARK: Command line parsing

  func testCommandLineParsing() {
    func parse(_ arguments: [String], stdin: String? = nil) -> Result<
      OwnerCommand, OwnerCommand.ParseError
    > {
      OwnerCommand.parse(
        arguments, workingDirectory: "/Users/someone/work", readStandardInput: { stdin })
    }
    XCTAssertEqual(
      try parse(["add", "下午", "三点", "组会"]).get(), .add(OwnerAddRequest(text: "下午 三点 组会")))
    XCTAssertEqual(
      try parse(["add", "--file", "notes/a.pdf", "-f", "~/b.txt"]).get(),
      .add(
        OwnerAddRequest(
          filePaths: [
            "/Users/someone/work/notes/a.pdf",
            (("~/b.txt" as NSString).expandingTildeInPath as NSString).standardizingPath,
          ])))
    XCTAssertEqual(
      try parse(["add"], stdin: "从管道来的\n").get(), .add(OwnerAddRequest(text: "从管道来的\n")))
    XCTAssertEqual(
      try parse(["add", "--url", "https://example.org", "--title", "标题"]).get(),
      .add(OwnerAddRequest(url: "https://example.org", title: "标题")))
    XCTAssertEqual(try parse(["add", "--", "--file"]).get(), .add(OwnerAddRequest(text: "--file")))
    XCTAssertEqual(try parse(["due"]).get(), .due(days: 0, json: false))
    XCTAssertEqual(try parse(["due", "--days", "7", "--json"]).get(), .due(days: 7, json: true))
    XCTAssertEqual(try parse([]).get(), .help)
    for bad in [
      ["add"], ["add", "--file"], ["due", "--days", "99"], ["delete"], ["add", "--force"],
    ] {
      guard case .failure = parse(bad) else { return XCTFail("\(bad) should be refused") }
    }
    // The request survives the wire.
    let request = OwnerAddRequest(text: "a", filePaths: ["/x/y"], url: "https://e.org", title: "t")
    XCTAssertEqual(OwnerAddRequest(params: request.params), request)
    XCTAssertNil(OwnerAddRequest(params: ["files": ["relative"]]))
    XCTAssertNil(OwnerAddRequest(params: ["text": 7]))
    XCTAssertTrue(
      OwnerChannel.isOwnerRequest(#"{"jsonrpc":"2.0","id":1,"method":"mindloom/owner.add"}"#))
    XCTAssertFalse(OwnerChannel.isOwnerRequest(#"{"jsonrpc":"2.0","id":1,"method":"tools/call"}"#))
  }

  func testStableIDsPerEntryKey() {
    XCTAssertEqual(
      EntryIdentity.itemID(.calendar, key: "event@1"),
      EntryIdentity.itemID(.calendar, key: "event@1"))
    XCTAssertNotEqual(
      EntryIdentity.itemID(.calendar, key: "event@1"), EntryIdentity.itemID(.git, key: "event@1"))
    XCTAssertNotEqual(
      EntryIdentity.itemID(.calendar, key: "event@1"),
      EntryIdentity.itemID(.calendar, key: "event@2"))
  }
}
