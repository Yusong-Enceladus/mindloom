import Foundation
import MindloomLink
import UniformTypeIdentifiers
import XCTest

@testable import MindloomPhoneIntake

/// The share sheet's `NSExtensionItem`s as apps hand them over.
final class ShareItemLoaderTests: XCTestCase {
  private var work: URL!
  private var loader: ShareItemLoader!

  override func setUpWithError() throws {
    work = try makeWorkDirectory()
    loader = ShareItemLoader(workDirectory: work.appendingPathComponent("copies"))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: work)
  }

  private func item(_ providers: [NSItemProvider], title: String? = nil, text: String? = nil)
    -> NSExtensionItem
  {
    let item = NSExtensionItem()
    item.attachments = providers
    item.attributedTitle = title.map { NSAttributedString(string: $0) }
    item.attributedContentText = text.map { NSAttributedString(string: $0) }
    return item
  }

  func testPlainText() async {
    let provider = NSItemProvider(
      item: "合成：记得带合同" as NSString, typeIdentifier: UTType.plainText.identifier)
    let inputs = await loader.inputs(from: [item([provider])])
    XCTAssertEqual(inputs, [.text("合成：记得带合同")])
  }

  func testWebPageFromABrowserIsALinkWithItsTitle() async {
    let url = URL(string: "https://unreachable.invalid/post/42")!
    let provider = NSItemProvider(object: url as NSURL)
    let inputs = await loader.inputs(from: [item([provider], title: "合成：一篇长文")])
    XCTAssertEqual(inputs, [.link(url, title: "合成：一篇长文")])
  }

  func testTextOnlyItemWithoutAttachments() async {
    let inputs = await loader.inputs(from: [item([], text: "合成：只有正文")])
    XCTAssertEqual(inputs, [.text("合成：只有正文")])
  }

  func testVideoIsRefusedWithoutLoadingIt() async {
    let provider = NSItemProvider()
    provider.suggestedName = "合成的视频"
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.quickTimeMovie.identifier, visibility: .all
    ) { _ in
      XCTFail("the video's bytes must never be requested")
      return nil
    }
    let inputs = await loader.inputs(from: [item([provider])])
    XCTAssertEqual(inputs, [.audioOrVideo(name: "合成的视频")])
  }

  func testAudioFileIsRefused() async throws {
    let url = work.appendingPathComponent("会议.m4a")
    try Data("x".utf8).write(to: url)
    let provider = try XCTUnwrap(NSItemProvider(contentsOf: url))
    let inputs = await loader.inputs(from: [item([provider])])
    XCTAssertEqual(inputs.count, 1)
    guard case .audioOrVideo = inputs.first else {
      return XCTFail("expected a refusal, got \(inputs)")
    }
  }

  func testImageFileIsCopiedIntoTheWorkDirectory() async throws {
    let url = work.appendingPathComponent("photo.jpg")
    try makePhoto().write(to: url)
    let provider = try XCTUnwrap(NSItemProvider(contentsOf: url))
    provider.suggestedName = "photo"
    let inputs = await loader.inputs(from: [item([provider])])
    guard case .image(let file) = inputs.first else {
      return XCTFail("expected an image, got \(inputs)")
    }
    XCTAssertTrue(file.url.path.hasPrefix(loader.workDirectory.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    let converted = try ShareItemConverter().convert(.image(file)).get()
    XCTAssertEqual(converted.payload.mime, "image/jpeg")
    XCTAssertEqual(converted.payload.filename, "photo.jpg")
    loader.removeCopies()
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
  }

  func testUnnamedFileStillGetsASafeName() async throws {
    let url = work.appendingPathComponent("report.pdf")
    try Data("%PDF-1.7\n%%EOF".utf8).write(to: url)
    let provider = try XCTUnwrap(NSItemProvider(contentsOf: url))
    provider.suggestedName = nil
    let inputs = await loader.inputs(from: [item([provider])])
    guard case .file(let file) = inputs.first else {
      return XCTFail("expected a file, got \(inputs)")
    }
    let name = try ShareItemConverter().convert(.file(file)).get().payload.filename ?? ""
    XCTAssertTrue(name.hasSuffix(".pdf"), name)
    XCTAssertNoThrow(try InboxItemPayload.validateFilename(name))
  }

  func testDocumentFileIsAFile() async throws {
    let url = work.appendingPathComponent("合成的报告.pdf")
    try Data("%PDF-1.7\n%%EOF".utf8).write(to: url)
    let provider = try XCTUnwrap(NSItemProvider(contentsOf: url))
    // The share sheet names what it hands over; the file's own name is the
    // fallback where the provider exposes its file URL (macOS).
    provider.suggestedName = "合成的报告"
    let inputs = await loader.inputs(from: [item([provider])])
    guard case .file(let file) = inputs.first else {
      return XCTFail("expected a file, got \(inputs)")
    }
    let converted = try ShareItemConverter().convert(.file(file)).get()
    XCTAssertEqual(converted.kind, .file)
    XCTAssertEqual(converted.payload.filename, "合成的报告.pdf")
  }

  func testImageInMemoryIsWrittenOut() async throws {
    let data = try makePhoto(type: .png)
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.png.identifier, visibility: .all
    ) { completion in
      completion(data, nil)
      return nil
    }
    let inputs = await loader.inputs(from: [item([provider])])
    guard case .image(let file) = inputs.first else {
      return XCTFail("expected an image, got \(inputs)")
    }
    XCTAssertEqual(try Data(contentsOf: file.url), data)
  }

  func testSeveralItemsKeepTheirOrder() async {
    let text = NSItemProvider(item: "第一" as NSString, typeIdentifier: UTType.plainText.identifier)
    let link = NSItemProvider(object: URL(string: "https://unreachable.invalid/2")! as NSURL)
    let inputs = await loader.inputs(from: [item([text, link])])
    XCTAssertEqual(inputs.count, 2)
    XCTAssertEqual(inputs.first, .text("第一"))
  }
}
