import BestASRDomain
import BestASRMemory
import BestASRRemoteOrganizer
import Foundation
import MindloomLink
import MindloomSpaces
import MindloomSpacesTestSupport
import XCTest

/// v8 on the Mac with real audio and real masking: a meeting part's audio is
/// cut to exactly the part (pauses as silence), encoded and checked the way
/// members check it; the whole recording is refused; a handover pack's
/// placeholders are put back with the space's mask key before it is shown,
/// exported or shared.
final class SpaceInfraMacTests: XCTestCase {
  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "space-infra-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  /// A recording of 40 s in two chunks at 48 kHz with a 5 s pause between
  /// them (a sine, so the encoder has something to encode).
  private func recording(start: UInt64) -> [SpaceAudioPart.Chunk] {
    func tone(_ seconds: Int) -> [Float] {
      (0..<(48_000 * seconds)).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000) * 0.3) }
    }
    return [
      .init(startNS: start, endNS: start + 20_000_000_000, sampleRate: 48_000, mono: tone(20)),
      .init(
        startNS: start + 25_000_000_000, endNS: start + 40_000_000_000, sampleRate: 48_000,
        mono: tone(15)),
    ]
  }

  func testAPartIsCutToItsOwnLengthWithPausesAsSilenceAndPassesTheMembersCheck() throws {
    let start: UInt64 = 7_000_000_000
    let chunks = recording(start: start)
    // 15 s → 30 s crosses the pause (20–25 s).
    let segment = SpaceSegmentRef(
      parentItemID: SpaceID.new(), startMS: 15_000, endMS: 30_000, recordingMS: 40_000)
    let samples = try SpaceAudioPart.cut(
      chunks, startNS: start + 15_000_000_000, endNS: start + 30_000_000_000)
    XCTAssertEqual(samples.count, 15 * SpaceAudioPart.sampleRate)
    // The pause is silence, the tone is not.
    let pause = samples[(6 * 16_000)..<(9 * 16_000)]
    XCTAssertTrue(pause.allSatisfy { $0 == 0 })
    XCTAssertGreaterThan(samples[(1 * 16_000)..<(2 * 16_000)].map(abs).max() ?? 0, 0.2)
    let audio = try SpaceAudioPart.make(
      chunks, recordingStartNS: start, segment: segment, directory: scratch)
    XCTAssertGreaterThan(audio.count, 1_000)
    XCTAssertLessThan(audio.count, SpaceLimits.standard.audioCeiling(ms: segment.lengthMS))
    let length = try SpaceAudioPart.durationMS(of: audio, directory: scratch)
    XCTAssertTrue(SpaceAudioCheck.ok(durationMS: length, segment: segment), "\(length) ms")
    // Nothing is left in the scratch folder.
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
  }

  func testTheWholeRecordingOrAnEmptyPartIsNeverMade() throws {
    let start: UInt64 = 1_000_000_000
    let chunks = recording(start: start)
    let whole = SpaceSegmentRef(
      parentItemID: SpaceID.new(), startMS: 0, endMS: 40_000, recordingMS: 40_000)
    XCTAssertThrowsError(
      try SpaceAudioPart.make(chunks, recordingStartNS: start, segment: whole, directory: scratch))
    let noLength = SpaceSegmentRef(parentItemID: SpaceID.new(), startMS: 0, endMS: 10_000)
    XCTAssertThrowsError(
      try SpaceAudioPart.make(
        chunks, recordingStartNS: start, segment: noLength, directory: scratch))
    // A part where no audio was kept.
    XCTAssertThrowsError(
      try SpaceAudioPart.cut(
        chunks, startNS: start + 100_000_000_000, endNS: start + 110_000_000_000))
  }

  func testAHandoverPackIsShownWithTheNumbersPutBackAndItsSourcesKept() throws {
    let maskKey = Data(repeating: 7, count: 32)
    let masker = try PrivacyMasker(maskKey: maskKey)
    let text = "合成：采购单周五前寄出，联系人电话 13812345678"
    let masked = masker.maskWithSpans(text).text
    XCTAssertFalse(masked.contains("13812345678"))
    var state = SpaceLocalState(
      spaceID: SpaceID.new(), memberID: SpaceID.new(), name: "交接", ownerKind: .person, orgID: nil,
      policy: .group, role: .admin, membership: .active, spark: nil)
    let item = SpaceID.new()
    state.items[item] = SpaceSharedItem(
      itemID: item, contributor: state.memberID, kind: "text", revision: 1, shareSeq: 2,
      firstSharedAt: Date(), updatedAt: Date(),
      fields: SpaceItemFields(kind: "text", title: "采购", text: text), blobs: [], segment: nil,
      packageID: nil, status: .active, keyEpoch: 1)
    let pack = SpaceHandoverPack(
      [
        "pack_id": "p1", "event_id": "ev-1", "status": "ready",
        "markdown": .string("# 交接包\n- \(masked)"),
        "pack": ["sources": .object([item: ["kind": "text"], SpaceID.new(): ["kind": "text"]])],
      ])
    let view = SpaceHandoverView(pack, state: state, maskKey: maskKey)
    XCTAssertTrue(view.isReady)
    XCTAssertTrue(view.markdown?.contains("13812345678") == true)
    XCTAssertEqual(view.sources, [item], "only sources that are in the space")
    XCTAssertTrue(SpaceHandoverView.fileName(title: "Twin-7", date: Date()).hasSuffix(".md"))
  }
}
