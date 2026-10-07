import BestASRMemory
import Foundation
import XCTest

@testable import MindloomTencentMeeting

/// tmeet's output read the way Mindloom reads it (synthetic fixtures in
/// tmeet v1.0.18's shape).
final class TencentMeetingParsingTests: XCTestCase {
  // MARK: Commands

  func testOnlyTheReadingCommandsCanBeExpressed() {
    let commands: [TencentMeetingCommand] = [
      .authLogin, .authStatus, .meetingGet(meetingID: "8000000000000000002"),
      .recordList(start: Fixture.now.addingTimeInterval(-86_400), end: Fixture.now, pageToken: nil),
      .meetingListEnded(
        start: Fixture.now.addingTimeInterval(-86_400), end: Fixture.now, pageToken: "abc"),
      .transcriptGet(recordFileID: "123", meetingID: "456", pid: "7", limit: 100),
    ]
    for command in commands {
      let arguments = try! XCTUnwrap(command.arguments)
      XCTAssertTrue(
        TencentMeetingCommand.allowedPaths.contains(Array(arguments.prefix(2))), "\(arguments)")
      XCTAssertEqual(Array(arguments.prefix(2)), command.path)
    }
    // Nothing that creates, changes or cancels a meeting, applies for
    // access, uploads logs or listens for events.
    let forbidden = [
      "create", "update", "cancel", "delete", "kick", "permission-apply-commit",
      "permission-apply-prepare", "tshoot", "feedback", "event", "control", "contact",
    ]
    for path in TencentMeetingCommand.allowedPaths {
      XCTAssertTrue(path.allSatisfy { !forbidden.contains($0) }, "\(path)")
    }
    XCTAssertEqual(TencentMeetingCommand.allowedPaths.count, 6)
    XCTAssertFalse(TencentMeetingCommand.allowedPaths.contains(["auth", "logout"]))
    XCTAssertEqual(TencentMeetingCommand.authLogin.arguments, ["auth", "login", "--no-browser"])
    XCTAssertEqual(
      TencentMeetingCommand.meetingGet(meetingID: "8000000000000000002").arguments,
      ["meeting", "get", "--meeting-id", "8000000000000000002", "--format", "json"])
    // What each costs in requests to Tencent (tmeet v1.0.18's source).
    XCTAssertEqual(TencentMeetingCommand.authLogin.requests, 0)
    XCTAssertEqual(
      TencentMeetingCommand.meetingListEnded(
        start: Fixture.now.addingTimeInterval(-60), end: Fixture.now, pageToken: nil
      ).requests, 3)
    XCTAssertEqual(TencentMeetingCommand.meetingGet(meetingID: "1").requests, 4)
    XCTAssertTrue(TencentMeetingCommand.meetingGet(meetingID: "1").isListing)
    XCTAssertFalse(
      TencentMeetingCommand.transcriptGet(recordFileID: "1", meetingID: nil, pid: nil, limit: 1)
        .isListing)
  }

  func testArgumentsTakeOnlyNumbersAndTokensInTheirFormat() {
    let start = Fixture.now.addingTimeInterval(-3_600)
    XCTAssertNil(
      TencentMeetingCommand.transcriptGet(
        recordFileID: "12; rm", meetingID: nil, pid: nil, limit: 100
      ).arguments)
    XCTAssertNil(
      TencentMeetingCommand.transcriptGet(
        recordFileID: "--format", meetingID: nil, pid: nil, limit: 100
      ).arguments)
    XCTAssertNil(
      TencentMeetingCommand.transcriptGet(recordFileID: "1", meetingID: "x", pid: nil, limit: 100)
        .arguments)
    XCTAssertNil(
      TencentMeetingCommand.transcriptGet(recordFileID: "1", meetingID: nil, pid: "-1", limit: 100)
        .arguments)
    XCTAssertNil(
      TencentMeetingCommand.transcriptGet(recordFileID: "1", meetingID: nil, pid: nil, limit: 0)
        .arguments)
    XCTAssertNil(
      TencentMeetingCommand.recordList(start: Fixture.now, end: start, pageToken: nil).arguments)
    XCTAssertNil(TencentMeetingCommand.meetingGet(meetingID: "8; rm").arguments)
    XCTAssertNil(TencentMeetingCommand.meetingGet(meetingID: "--format").arguments)
    XCTAssertNil(
      TencentMeetingCommand.recordList(start: start, end: Fixture.now, pageToken: "a b").arguments)
    XCTAssertNil(
      TencentMeetingCommand.recordList(start: start, end: Fixture.now, pageToken: "--x\n").arguments
    )
    let arguments = TencentMeetingCommand.transcriptGet(
      recordFileID: "6000000000000000012", meetingID: "8000000000000000001", pid: "3", limit: 100
    ).arguments
    XCTAssertEqual(
      arguments,
      [
        "record", "transcript-get", "--record-file-id", "6000000000000000012", "--meeting-id",
        "8000000000000000001", "--pid", "3", "--limit", "100", "--format", "json",
      ])
  }

  /// The Swift side names the tmeet it expects; the build makes that one.
  func testTheHelperVersionMatchesTheVendoredBuild() throws {
    var repository = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    while repository.path != "/",
      !FileManager.default.fileExists(
        atPath: repository.appendingPathComponent("PRODUCT_REQUIREMENTS.md").path)
    {
      repository.deleteLastPathComponent()
    }
    let version = try String(
      contentsOf: repository.appendingPathComponent("third_party/tencentmeeting-cli/VERSION"),
      encoding: .utf8)
    XCTAssertEqual(
      version.trimmingCharacters(in: .whitespacesAndNewlines), TencentMeetingHelper.version)
  }

  // MARK: Errors and status

  func testFailuresAreReadFromTencentsCodesAndTmeetsMessages() {
    func failure(_ name: String) -> TencentMeetingFailure? {
      TencentMeetingOutput.failure(Fixture.error(name))?.failure
    }
    XCTAssertEqual(failure("error-30002.txt"), .noContent)
    XCTAssertEqual(failure("error-30003.txt"), .generating)
    XCTAssertEqual(failure("error-500246.txt"), .rateLimited)
    XCTAssertEqual(failure("error-500284.txt"), .accountNotAvailable)
    XCTAssertEqual(failure("error-token.txt"), .notConnected)
    XCTAssertEqual(failure("error-network.txt"), .network)
    XCTAssertEqual(TencentMeetingOutput.failure(Fixture.error("error-30002.txt"))?.code, 30_002)
    XCTAssertNil(TencentMeetingOutput.failure(Fixture.ok("record-list-p1.json")))
    XCTAssertEqual(TencentMeetingOutput.failure(.notLaunched(.helper))?.failure, .helperMissing)
    // The key not read is not a missing helper.
    XCTAssertEqual(TencentMeetingOutput.failure(.notLaunched(.key))?.failure, .keyUnavailable)
    // Server errors without Tencent's own code pass like the network:
    // tmeet's refresh (no body), a gateway page; a 403 is a refusal.
    XCTAssertEqual(failure("error-502.txt"), .network)
    XCTAssertEqual(failure("error-503.txt"), .network)
    XCTAssertEqual(TencentMeetingOutput.failure(Fixture.error("error-502.txt"))?.code, 502)
    XCTAssertEqual(failure("error-403.txt"), .noPermission)
    XCTAssertEqual(
      TencentMeetingOutput.failure(
        TencentMeetingRunResult(
          exitStatus: 1, stdout: Data(),
          stderr: Data("Error: request failed, http status:429, business err: , trace:x".utf8)))?
        .failure, .network)
    // A server error with a code Tencent did not document stays the
    // recording's own.
    XCTAssertEqual(
      TencentMeetingOutput.failure(
        TencentMeetingRunResult(
          exitStatus: 1, stdout: Data(),
          stderr: Data(
            #"Error: request failed, http status:500, business err: {"error_info":{"error_code":99999}}, trace:x"#
              .utf8)))?.failure, .other)
    XCTAssertEqual(
      TencentMeetingOutput.failure(
        TencentMeetingRunResult(exitStatus: -1, stdout: Data(), stderr: Data(), timedOut: true))?
        .failure, .timedOut)
    // A success that carries Tencent's own code.
    XCTAssertEqual(TencentMeetingOutput.dataFailure(["code": 30_003])?.failure, .generating)
    XCTAssertEqual(TencentMeetingOutput.dataFailure(["code": 108_030_002])?.failure, .noContent)
    XCTAssertNil(TencentMeetingOutput.dataFailure(["code": 0, "minutes": [:]]))
    XCTAssertNil(TencentMeetingOutput.dataFailure(Fixture.dataObject("transcript-21.json")))
    // Success with something that is not tmeet's envelope.
    guard
      case .failure(let report) = TencentMeetingOutput.data(
        TencentMeetingRunResult(exitStatus: 0, stdout: Data("not json".utf8), stderr: Data()))
    else { return XCTFail("read as data") }
    XCTAssertEqual(report.failure, .unreadable)
  }

  func testAuthStatusGivesTheLoginsTwoEndsAndTheName() {
    let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    let status = TencentMeetingAuthStatus.parse(Fixture.text("auth-status.txt"), timeZone: shanghai)
    XCTAssertTrue(status.loggedIn)
    XCTAssertEqual(status.userName, "林示例")
    let formatter = ISO8601DateFormatter()
    XCTAssertEqual(status.refreshTokenExpires, formatter.date(from: "2026-11-04T15:10:26Z"))
    XCTAssertEqual(status.accessTokenExpires, formatter.date(from: "2026-10-05T22:10:26Z"))
    XCTAssertFalse(
      TencentMeetingAuthStatus.parse(
        "Not logged in. Please use 'tmeet auth login' to authenticate."
      ).loggedIn)
    XCTAssertFalse(
      TencentMeetingAuthStatus.parse(
        "  Session has expired. Please use 'tmeet auth login' to re-authenticate.\nLogged in"
      ).loggedIn)
  }

  func testTheLoginAddressIsTencentsOwnPageAndNothingElse() {
    let line = Fixture.text("login-output.txt").split(separator: "\n").first {
      $0.contains("authorize url")
    }!
    XCTAssertEqual(
      TencentMeetingLoginOutput.authorizationURL(in: String(line))?.absoluteString,
      "https://meeting.tencent.com/marketplace/tencentmeeting-cli-auth.html?code=SYNTHETICcode_0123456789"
    )
    for bad in [
      "authorize url: http://meeting.tencent.com/marketplace/tencentmeeting-cli-auth.html?code=SYNTHETICcode_01",
      "authorize url: https://meeting.tencent.com.example.com/marketplace/tencentmeeting-cli-auth.html?code=SYNTHETICcode_01",
      "authorize url: https://meeting.tencent.com/other.html?code=SYNTHETICcode_01",
      "authorize url: https://meeting.tencent.com/marketplace/tencentmeeting-cli-auth.html?code=SYNTHETICcode_01&next=https://x",
      "authorize url: https://user@meeting.tencent.com/marketplace/tencentmeeting-cli-auth.html?code=SYNTHETICcode_01",
      "authorize url: https://meeting.tencent.com/marketplace/tencentmeeting-cli-auth.html?code=<script>",
      "waiting for authorization...",
    ] {
      XCTAssertNil(TencentMeetingLoginOutput.authorizationURL(in: bad), bad)
    }
    func outcome(_ out: String, _ status: Int32 = 1, timedOut: Bool = false)
      -> TencentMeetingLoginOutput.Outcome
    {
      TencentMeetingLoginOutput.outcome(
        TencentMeetingRunResult(
          exitStatus: status, stdout: Data(out.utf8), stderr: Data(), timedOut: timedOut),
        cancelled: false)
    }
    XCTAssertEqual(
      outcome("Login successful. Start managing your meetings using tmeet.", 0), .connected)
    XCTAssertEqual(
      outcome("Error: user has been login, please use 'tmeet cmd [flags]' to use"),
      .alreadyConnected)
    XCTAssertEqual(
      outcome("Error: authorization timeout, please try 'tmeet auth login' again"), .expired)
    XCTAssertEqual(outcome("", timedOut: true), .expired)
    XCTAssertEqual(outcome("Error: get auth_code failed, please try later"), .network)
  }

  // MARK: Listings

  func testRecordListGivesViewableRecordingsWithTheirTimesAndReadiness() {
    let first = TencentMeetingListingParser.recordList(Fixture.dataObject("record-list-p1.json"))
    XCTAssertEqual(first.recordings.count, 3)
    XCTAssertEqual(first.nextPageToken, "page-two_token=")
    let cloud = first.recordings[0]
    XCTAssertEqual(cloud.recordFileID, "6000000000000000011")
    XCTAssertEqual(cloud.meetingID, "8000000000000000001")
    XCTAssertEqual(cloud.type, .cloudRecording)
    XCTAssertTrue(cloud.isFetchable)
    XCTAssertEqual(cloud.permission, .canView)
    XCTAssertEqual(cloud.hostUserID, "10000000000000000000001")
    XCTAssertEqual(cloud.duration, 39 * 60 + 30)
    XCTAssertEqual(first.recordings[1].type, .textTranscription)
    let second = TencentMeetingListingParser.recordList(Fixture.dataObject("record-list-p2.json"))
    XCTAssertNil(second.nextPageToken)
    XCTAssertFalse(second.recordings[0].isReady)
  }

  func testListEndedGivesEveryRecordingWithItsPermission() {
    let page = TencentMeetingListingParser.meetingListEnded(Fixture.dataObject("list-ended.json"))
    let byID = Dictionary(uniqueKeysWithValues: page.recordings.map { ($0.recordFileID, $0) })
    XCTAssertEqual(byID.count, 6)
    XCTAssertEqual(byID["6000000000000000051"]?.permission, .canApply)
    XCTAssertEqual(byID["6000000000000000052"]?.permission, .passwordRequired)
    XCTAssertEqual(byID["6000000000000000061"]?.permission, .closed)
    XCTAssertEqual(byID["6000000000000000011"]?.subMeetingID, "5000000001")
    XCTAssertEqual(byID["6000000000000000011"]?.recurring, true)
    XCTAssertEqual(byID["6000000000000000011"]?.meetingSubject, "示例周会")
    XCTAssertEqual(
      byID["6000000000000000051"]?.pageURL?.absoluteString,
      "https://meeting.tencent.com/crm/AAAA0051")
    XCTAssertEqual(byID["6000000000000000011"]?.duration, 39 * 60 + 30)
    // Two meetings list fewer recordings than they have (2 of 3, 1 of 5).
    XCTAssertEqual(page.truncatedMeetings, 2)
    XCTAssertEqual(
      page.counts.first { $0.meetingID == "8000000000000000002" },
      TencentMeetingRecordCount(
        meetingID: "8000000000000000002", subMeetingID: nil,
        start: ISO8601DateFormatter().date(from: "2026-09-30T02:00:00Z"), total: 5, listed: 1))
    XCTAssertNil(TencentMeetingListingParser.pageURL("https://evil.example/crm/x"))
    XCTAssertNil(TencentMeetingListingParser.pageURL("http://meeting.tencent.com/crm/x"))
  }

  /// `meeting get` prints the same meeting object with every recording;
  /// Tencent may still count some it keeps back.
  func testMeetingGetListsTheMeetingsOtherRecordings() {
    let page = TencentMeetingListingParser.meetingGet(Fixture.dataObject("meeting-get-2.json"))
    XCTAssertEqual(
      page.recordings.map(\.recordFileID), ["6000000000000000021", "6000000000000000022"])
    let cloud = page.recordings[1]
    XCTAssertEqual(cloud.type, .cloudRecording)
    XCTAssertEqual(cloud.permission, .canView)
    XCTAssertTrue(cloud.isFetchable)
    XCTAssertEqual(cloud.meetingSubject, "示例讨论")
    XCTAssertEqual(cloud.duration, 25 * 60)
    XCTAssertEqual(Set(cloud.fingerprints.keys), [.meetingGet])
    XCTAssertNil(page.nextPageToken)
    XCTAssertEqual(page.counts.map(\.total), [5])
    XCTAssertEqual(page.counts.map(\.listed), [2])
    XCTAssertEqual(page.truncatedMeetings, 1)
    let all = TencentMeetingListingParser.meetingGet(Fixture.dataObject("meeting-get-5.json"))
    XCTAssertEqual(all.truncatedMeetings, 0)
    XCTAssertEqual(all.recordings.map(\.permission), [.canApply, .passwordRequired, .closed])
  }

  func testTheSameFileFromBothListingsMergesAndViewingWins() {
    var fromList = TencentMeetingListingParser.meetingListEnded(
      Fixture.dataObject("list-ended.json")
    )
    .recordings.first { $0.recordFileID == "6000000000000000011" }!
    let fromRecords = TencentMeetingListingParser.recordList(
      Fixture.dataObject("record-list-p1.json")
    )
    .recordings[0]
    fromList.permission = .canApply
    fromList.merge(fromRecords)
    XCTAssertEqual(fromList.permission, .canView)
    XCTAssertEqual(fromList.hostUserID, "10000000000000000000001")
    XCTAssertEqual(Set(fromList.fingerprints.keys), [.recordList, .meetingListEnded])
    XCTAssertEqual(Set(fromList.listings.keys), [.recordList, .meetingListEnded])
  }

  // MARK: Transcripts

  func testTranscriptPagesMergeByParagraphNumber() {
    let first = TencentMeetingTranscriptParser.page(Fixture.dataObject("transcript-12-p1.json"))!
    let second = TencentMeetingTranscriptParser.page(Fixture.dataObject("transcript-12-p2.json"))!
    XCTAssertTrue(first.more)
    XCTAssertFalse(second.more)
    let paragraphs = TencentMeetingTranscriptParser.merged([first, second])
    XCTAssertEqual(paragraphs.map(\.pid), [0, 1, 2, 3, 4])
    XCTAssertEqual(paragraphs[0].text, "大家好，今天先看进度。")
    XCTAssertEqual(paragraphs[2].text, "我这边还差一个 review。")
    XCTAssertEqual(paragraphs[0].startMilliseconds, 5_000)
    XCTAssertEqual(paragraphs[4].startMilliseconds, 3_672_000)
    XCTAssertEqual(paragraphs[2].speakerUserID, "10000000000000000000002")
    XCTAssertEqual(paragraphs[2].speakerName, "周样本")
    XCTAssertEqual(
      TencentMeetingTranscriptParser.digest(paragraphs),
      TencentMeetingTranscriptParser.digest(TencentMeetingTranscriptParser.merged([second, first])))
  }

  func testReadableTextIsTencentsExportFormatWithTheOwnerAsMe() throws {
    let paragraphs = TencentMeetingTranscriptParser.merged([
      TencentMeetingTranscriptParser.page(Fixture.dataObject("transcript-12-p1.json"))!,
      TencentMeetingTranscriptParser.page(Fixture.dataObject("transcript-12-p2.json"))!,
    ])
    let text = TencentMeetingTranscriptText.readable(
      title: "示例周会", paragraphs: paragraphs, ownerUserIDs: ["10000000000000000000001"])
    XCTAssertEqual(
      text,
      """
      示例周会

      我(00:00:05):
      大家好，今天先看进度。
      上周的事情都完成了。

      周样本(00:00:41):
      我这边还差一个 review。

      周样本 2(00:01:11):
      我也叫这个名字。

      我(01:01:12):
      那就这样。

      """)
    let transcript = try XCTUnwrap(MemoryTranscriptText.parse(text))
    XCTAssertEqual(transcript.format, .tencent)
    XCTAssertEqual(transcript.format.meetingApp, "腾讯会议")
    XCTAssertEqual(transcript.turns.map(\.speaker), ["我", "周样本", "周样本 2", "我"])
    XCTAssertEqual(transcript.turns.map(\.time), ["00:00:05", "00:00:41", "00:01:11", "01:01:12"])
  }

  func testTitlesAndNamesNeverBreakTheTurns() throws {
    XCTAssertTrue(MemoryTranscriptText.startsTurn("示例(14:00)"))
    XCTAssertEqual(TencentMeetingTranscriptText.titleLine("示例(14:00)"), "会议：示例(14:00)")
    XCTAssertEqual(TencentMeetingTranscriptText.titleLine("组会(10:00): 第一次"), "会议：组会(10:00): 第一次")
    XCTAssertEqual(TencentMeetingTranscriptText.titleLine("示例周会"), "示例周会")
    XCTAssertEqual(TencentMeetingTranscriptText.cleanName("张三(学生)"), "张三 学生")
    XCTAssertEqual(TencentMeetingTranscriptText.cleanName("2026级 同学"), "用户 2026级 同学")
    XCTAssertEqual(TencentMeetingTranscriptText.cleanName("一二三四五六七八九十"), "一二三四五六七八")
    let paragraphs = [
      TencentMeetingParagraph(
        pid: 0, startMilliseconds: 0, endMilliseconds: 1_000, speakerUserID: "1",
        speakerName: "张三(学生)：", text: "第一句。"),
      TencentMeetingParagraph(
        pid: 1, startMilliseconds: 1_000, endMilliseconds: 2_000, speakerUserID: nil,
        speakerName: "", text: "第二句。"),
      TencentMeetingParagraph(
        pid: 2, startMilliseconds: 2_000, endMilliseconds: 3_000, speakerUserID: "3",
        speakerName: "我", text: "第三句。"),
    ]
    let text = TencentMeetingTranscriptText.readable(
      title: "组会(10:00):", paragraphs: paragraphs, ownerUserIDs: [])
    let transcript = try XCTUnwrap(MemoryTranscriptText.parse(text))
    XCTAssertEqual(transcript.turns.map(\.speaker), ["张三 学生", "发言人 1", "发言人 2"])
  }

  // MARK: Source file

  func testSourceFileKeepsEveryPageByteForByteAndReadsBack() throws {
    let pages = [Fixture.data("transcript-12-p1.json"), Fixture.data("transcript-12-p2.json")]
    var recording = TencentMeetingListingParser.recordList(
      Fixture.dataObject("record-list-p1.json")
    )
    .recordings[1]
    recording.merge(
      TencentMeetingListingParser.meetingListEnded(Fixture.dataObject("list-ended.json")).recordings
        .first { $0.recordFileID == recording.recordFileID }!)
    let source = try XCTUnwrap(
      TencentMeetingSourceDocument.encode(
        recording: recording, pages: pages, fetchedAt: Fixture.now, tmeetVersion: "test"))
    for page in pages {
      let trimmed = Data(
        String(decoding: page, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
      XCTAssertNotNil(source.range(of: trimmed), "a page was changed")
    }
    let parsed = try XCTUnwrap(TencentMeetingSourceDocument.parse(source))
    XCTAssertEqual(parsed.recordFileID, "6000000000000000012")
    XCTAssertEqual(parsed.meetingID, "8000000000000000001")
    XCTAssertEqual(parsed.paragraphs.count, 5)
    XCTAssertEqual(Set(parsed.listings.keys), [.recordList, .meetingListEnded])
    XCTAssertEqual(parsed.fetchedAt, Fixture.now)
    XCTAssertNil(
      TencentMeetingSourceDocument.encode(
        recording: recording, pages: [Data("not json".utf8)], fetchedAt: Fixture.now,
        tmeetVersion: "test"))
  }
}
