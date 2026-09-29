import BestASRDomain
import XCTest

final class UserItemTests: XCTestCase {
  func testAutomaticTitle() {
    XCTAssertEqual(
      UserItemTitle.automatic(kind: .text, text: "\n  第一行  \n第二行", filename: nil), "第一行")
    let long = String(repeating: "字", count: 45)
    XCTAssertEqual(
      UserItemTitle.automatic(kind: .text, text: long, filename: nil),
      String(repeating: "字", count: 40) + "…")
    XCTAssertEqual(UserItemTitle.automatic(kind: .image, text: "", filename: nil), "截图")
    XCTAssertEqual(
      UserItemTitle.automatic(kind: .image, text: "", filename: "屏幕快照.png"), "屏幕快照.png")
    XCTAssertEqual(
      UserItemTitle.automatic(kind: .document, text: "   ", filename: "议程.pdf"), "议程.pdf")
    XCTAssertEqual(UserItemTitle.automatic(kind: .document, text: "", filename: nil), "文档")
  }

  func testSourceApplicationNeedsANameOrBundle() {
    XCTAssertNil(ItemSourceApplication(bundleID: " ", name: nil))
    XCTAssertEqual(
      ItemSourceApplication(bundleID: "com.tencent.xinWeChat", name: nil)?.name, "xinWeChat")
    XCTAssertEqual(ItemSourceApplication(bundleID: nil, name: " 微信 ")?.name, "微信")
  }

  func testSourceLabelNeverUsesAFilename() {
    XCTAssertEqual(
      SourceLabel.label(inputMode: .importedMedia, bundleID: nil, displayName: "会议.m4a"),
      "导入媒体")
    XCTAssertEqual(
      SourceLabel.label(
        inputMode: .importedMedia, bundleID: "com.apple.finder", displayName: "访达"), "访达")
    XCTAssertEqual(
      SourceLabel.label(
        inputMode: .dictation, bundleID: "com.apple.Notes", displayName: "com.apple.Notes"),
      "Notes")
    XCTAssertEqual(
      SourceLabel.label(inputMode: .userItem, bundleID: nil, displayName: nil), "未知来源")
    XCTAssertEqual(
      SourceLabel.label(inputMode: .roomMicrophone, bundleID: nil, displayName: "内建麦克风"),
      "线下录音")
  }
}
