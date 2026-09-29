import AVFoundation
import BestASRDictation
import BestASRDomain
import CryptoKit
import XCTest

@testable import bestASR

/// Recordings are stored as 16-bit since compaction, so this is the read that
/// every playback now depends on. It also pins the refusal to play bytes that
/// do not match the digest the index recorded.
@MainActor
final class LocalSessionAudioPlayerDecodeTests: XCTestCase {
  private func descriptor(_ encoding: PCMEncoding) -> CaptureTrackDescriptor {
    CaptureTrackDescriptor(
      role: .microphoneLocal,
      deviceUID: "decode-fixture",
      sampleRateHertz: 16_000,
      channelCount: 1,
      encoding: encoding,
      interleaved: true
    )
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func testSixteenBitSamplesComeBackAsTheFloatsTheyEncoded() throws {
    let samples: [Int16] = [0, 16_384, -16_384, 32_767, -32_768]
    var data = Data()
    for sample in samples {
      withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
    }

    let buffer = try LocalSessionAudioPlayer.decoded(
      data, descriptor: descriptor(.int16LittleEndian),
      expectedDigest: digest(data), frameOffset: 0)

    XCTAssertEqual(buffer.frameLength, 5)
    XCTAssertEqual(buffer.format.sampleRate, 16_000)
    let channel = try XCTUnwrap(buffer.floatChannelData)[0]
    XCTAssertEqual(channel[0], 0, accuracy: 0.0001)
    XCTAssertEqual(channel[1], 0.5, accuracy: 0.0001)
    XCTAssertEqual(channel[2], -0.5, accuracy: 0.0001)
    XCTAssertEqual(channel[3], 1, accuracy: 0.0001)
    XCTAssertEqual(channel[4], -1, accuracy: 0.0001)
  }

  func testPlaybackStartsPartWayThroughAtSixteenBit() throws {
    var data = Data()
    for sample in Int16(0)..<Int16(100) {
      withUnsafeBytes(of: (sample * 300).littleEndian) { data.append(contentsOf: $0) }
    }

    let buffer = try LocalSessionAudioPlayer.decoded(
      data, descriptor: descriptor(.int16LittleEndian),
      expectedDigest: digest(data), frameOffset: 40)

    XCTAssertEqual(buffer.frameLength, 60)
    let channel = try XCTUnwrap(buffer.floatChannelData)[0]
    XCTAssertEqual(channel[0], Float(40 * 300) / 32_768, accuracy: 0.0001)
  }

  func testBytesThatDoNotMatchTheIndexAreNotPlayed() {
    let data = Data([0, 0, 1, 0])

    XCTAssertThrowsError(
      try LocalSessionAudioPlayer.decoded(
        data, descriptor: descriptor(.int16LittleEndian),
        expectedDigest: String(repeating: "a", count: 64), frameOffset: 0)
    ) { error in
      XCTAssertEqual(error as? LocalSessionAudioPlayerError, .sourceMissing)
    }
  }

  func testFloatRecordingsStillRead() throws {
    let samples: [Float] = [0, 0.25, -0.75]
    let data = samples.withUnsafeBytes { Data($0) }

    let buffer = try LocalSessionAudioPlayer.decoded(
      data, descriptor: descriptor(.float32LittleEndian),
      expectedDigest: digest(data), frameOffset: 0)

    XCTAssertEqual(buffer.frameLength, 3)
    let channel = try XCTUnwrap(buffer.floatChannelData)[0]
    XCTAssertEqual(channel[1], 0.25, accuracy: 0.0001)
    XCTAssertEqual(channel[2], -0.75, accuracy: 0.0001)
  }
}
