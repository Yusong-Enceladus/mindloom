import BestASRDomain
import XCTest

@testable import BestASRMemory

/// Meetings and imports must not regress (v12 1C, ALIGNMENT 收2-2, 收2-5,
/// 收2-6): v11 called every imported recording 「视频」, and a meeting that
/// recorded the microphone alone looked like any other.
final class MeetingItemWordsTests: XCTestCase {
  private func record(
    _ mode: SessionInputMode, itemKind: UserItemKind? = nil, filename: String? = nil,
    mediaType: String? = nil, app: String? = nil, text: String? = nil,
    keyframes: Int = 0
  ) -> MemoryItemRecord {
    var record = MemoryItemRecord(
      sessionID: SessionID(), inputMode: mode, itemKind: itemKind, title: "t",
      startedAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
      sourceBundleID: nil, sourceDisplayName: app ?? filename, sourceIdentifier: filename,
      text: text)
    record.mediaType = mediaType
    record.keyframes = (0..<keyframes).map {
      MemoryItemRecord.Keyframe(
        sessionID: SessionID(), frameMilliseconds: Int64($0) * 1000, thumbnailAssetPath: nil)
    }
    return record
  }

  /// An imported recording is 「录音」, a video 「视频」.
  func testImportedAudioIsARecordingAndVideoIsAVideo() {
    for (name, type) in [
      ("周会.m4a", "audio/mp4"), ("访谈.mp3", "audio/mpeg"), ("讲座.wav", nil), ("课.flac", nil),
    ] {
      let words = MemoryItemSource.words(record(.importedMedia, filename: name, mediaType: type))
      XCTAssertEqual(words.word, "录音", name)
      XCTAssertEqual(words.symbol, "waveform", name)
    }
    for (name, type) in [("组会录像.mov", "video/quicktime"), ("答辩.mp4", nil), ("x.webm", nil)] {
      let words = MemoryItemSource.words(record(.importedMedia, filename: name, mediaType: type))
      XCTAssertEqual(words.word, "视频", name)
      XCTAssertEqual(words.symbol, "video", name)
    }
    // The media type outranks the name; frames taken from it make it a video.
    XCTAssertEqual(MemoryMediaKind.of(filename: "a.mp4", mediaType: "audio/mp4"), .audio)
    XCTAssertEqual(MemoryMediaKind.of(filename: "a.m4a", mediaType: "video/mp4"), .video)
    XCTAssertEqual(MemoryMediaKind.of(filename: nil, mediaType: nil, hasFrames: true), .video)
    XCTAssertEqual(MemoryMediaKind.of(filename: nil, mediaType: nil), .audio)
    XCTAssertEqual(
      MemoryMediaKind.of(record(.importedMedia, filename: "noext", keyframes: 2)), .video)
  }

  /// 开始记录会议 without 屏幕与系统录音 recorded the microphone alone: its
  /// item says 「只录了麦克风」. The computer's sound is a plain 会议.
  func testAMicrophoneOnlyMeetingSaysSo() {
    let room = MemoryItemSource.words(record(.roomMicrophone))
    XCTAssertEqual(room.line, "会议 · 仅录制了麦克风")
    XCTAssertEqual(room.symbol, "person.3")
    XCTAssertEqual(room.sameCaptureLead, "同一场会还讲到")
    XCTAssertEqual(MemoryItemSource.words(record(.systemAudio)).line, "会议")
  }

  /// 收进会议记录…: the export's format names its App on the item.
  func testATranscriptNamesItsApp() {
    let tencent = """
      周会

      林知夏(00:00:05):
      这周先把三组数据跑完。

      高原(00:01:10):
      好，我周五给结果。
      """
    let feishu = """
      林知夏 00:00:05
      这周先把三组数据跑完。
      高原 00:01:10
      好，我周五给结果。
      """
    let zoom = """
      [00:00:05] 林知夏: 这周先把三组数据跑完。
      [00:01:10] 高原: 好，我周五给结果。
      """
    let vtt = """
      WEBVTT

      00:00:05.000 --> 00:00:09.000
      <v 林知夏>这周先把三组数据跑完。

      00:01:10.000 --> 00:01:14.000
      <v 高原>好，我周五给结果。
      """
    XCTAssertEqual(MemoryTranscriptText.parse(tencent)?.format.meetingApp, "腾讯会议")
    XCTAssertEqual(MemoryTranscriptText.parse(feishu)?.format.meetingApp, "飞书妙记")
    XCTAssertEqual(MemoryTranscriptText.parse(zoom)?.format.meetingApp, "Zoom")
    XCTAssertEqual(MemoryTranscriptText.parse(vtt)?.format, .subtitles)
    XCTAssertNil(MemoryTranscriptText.parse(vtt)?.format.meetingApp)
    // Each App's name is one the source words read as a meeting App.
    for app in ["腾讯会议", "飞书妙记", "Zoom"] {
      let words = MemoryItemSource.words(
        record(.userItem, itemKind: .document, app: app, text: tencent))
      XCTAssertEqual(words.line, "会议记录 · \(app)")
    }
    // A subtitle file names no App: still a 会议记录 by its turns, a docx
    // too (a file item whose text is the document's).
    XCTAssertEqual(
      MemoryItemSource.words(record(.userItem, itemKind: .document, text: vtt)).line, "会议记录")
    XCTAssertEqual(
      MemoryItemSource.words(record(.userItem, itemKind: .file, filename: "周会.docx", text: tencent))
        .line, "会议记录")
  }
}
