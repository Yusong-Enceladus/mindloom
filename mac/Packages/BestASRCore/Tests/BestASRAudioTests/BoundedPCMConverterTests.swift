import BestASRAudio
import BestASRDictation
import Foundation
import XCTest

final class BoundedPCMConverterTests: XCTestCase {
  func testStereo48kSineDownmixesToOrdered16kMonoWithoutMutatingSource() async throws {
    let converter = try BoundedPCMConverter(maximumBufferedSourceFrames: 1_000)
    let frames = 480
    var stereo: [Float] = []
    stereo.reserveCapacity(frames * 2)
    for frame in 0..<frames {
      let sample = sin(Float(frame) * 2 * .pi / 48)
      stereo.append(sample)
      stereo.append(sample * 0.5)
    }
    let source = floatData(stereo)
    let original = source
    let first = try await converter.convert(
      CapturedPCMChunk(
        sequence: 0,
        monotonicStartNanoseconds: 10,
        frameCount: UInt64(frames),
        sampleRateHertz: 48_000,
        channelCount: 2,
        encoding: .float32LittleEndian,
        interleaved: true,
        bytes: source
      )
    )

    XCTAssertEqual(source, original)
    XCTAssertEqual(first.sequence, 0)
    XCTAssertEqual(first.sampleRateHertz, 16_000)
    XCTAssertEqual(first.channelCount, 1)
    XCTAssertEqual(first.encoding, .float32LittleEndian)
    XCTAssertTrue(first.interleaved)
    XCTAssertEqual(first.frameCount, 160, accuracy: 1)
    XCTAssertEqual(first.bytes.count, Int(first.frameCount) * 4)
    let bufferedFrames = await converter.bufferedSourceFrameCount()
    XCTAssertLessThanOrEqual(bufferedFrames, 3)

    let second = try await converter.convert(
      CapturedPCMChunk(
        sequence: 1,
        monotonicStartNanoseconds: 20,
        frameCount: UInt64(frames),
        sampleRateHertz: 48_000,
        channelCount: 2,
        encoding: .float32LittleEndian,
        interleaved: true,
        bytes: source
      )
    )
    XCTAssertEqual(second.sequence, 1)
    XCTAssertGreaterThan(second.frameCount, 0)
  }

  func testInt16NoiseConvertsAndFrameMismatchFailsClosed() async throws {
    let converter = try BoundedPCMConverter(maximumBufferedSourceFrames: 100)
    let source = int16Data([0, 16_000, -16_000, 8_000, -8_000, 0])
    let converted = try await converter.convert(
      CapturedPCMChunk(
        sequence: 0,
        monotonicStartNanoseconds: 0,
        frameCount: 6,
        sampleRateHertz: 16_000,
        channelCount: 1,
        encoding: .int16LittleEndian,
        interleaved: true,
        bytes: source
      )
    )
    XCTAssertEqual(converted.frameCount, 5)
    XCTAssertFalse(converted.bytes.isEmpty)

    let mismatchConverter = try BoundedPCMConverter(maximumBufferedSourceFrames: 100)
    await assertThrowsConversionError(
      .frameCountMismatch(expectedSamples: 4, actualSamples: 2)
    ) {
      _ = try await mismatchConverter.convert(
        CapturedPCMChunk(
          sequence: 0,
          monotonicStartNanoseconds: 0,
          frameCount: 4,
          sampleRateHertz: 16_000,
          channelCount: 1,
          encoding: .int16LittleEndian,
          interleaved: true,
          bytes: int16Data([1, 2])
        )
      )
    }
  }

  func testFormatChangeRequiresExplicitReset() async throws {
    let converter = try BoundedPCMConverter(maximumBufferedSourceFrames: 100)
    _ = try await converter.convert(
      CapturedPCMChunk(
        sequence: 0,
        monotonicStartNanoseconds: 0,
        frameCount: 4,
        sampleRateHertz: 16_000,
        channelCount: 1,
        encoding: .float32LittleEndian,
        interleaved: true,
        bytes: floatData([0, 0.1, 0.2, 0.3])
      )
    )
    let changed = CapturedPCMChunk(
      sequence: 1,
      monotonicStartNanoseconds: 1,
      frameCount: 4,
      sampleRateHertz: 48_000,
      channelCount: 1,
      encoding: .float32LittleEndian,
      interleaved: true,
      bytes: floatData([0, 0.1, 0.2, 0.3])
    )
    await assertThrowsConversionError(.formatChanged) {
      _ = try await converter.convert(changed)
    }
    await converter.resetForFormatChange()
    let afterReset = try await converter.convert(changed)
    XCTAssertEqual(afterReset.sequence, 1)
  }

  func testCapacityAndNonInterleavedInputAreRejected() async throws {
    let converter = try BoundedPCMConverter(maximumBufferedSourceFrames: 4)
    await assertThrowsConversionError(
      .bufferCapacityExceeded(limit: 4, proposed: 5)
    ) {
      _ = try await converter.convert(
        CapturedPCMChunk(
          sequence: 0,
          monotonicStartNanoseconds: 0,
          frameCount: 5,
          sampleRateHertz: 16_000,
          channelCount: 1,
          encoding: .float32LittleEndian,
          interleaved: true,
          bytes: floatData([0, 0, 0, 0, 0])
        )
      )
    }

    let other = try BoundedPCMConverter(maximumBufferedSourceFrames: 10)
    await assertThrowsConversionError(.unsupportedNonInterleaved) {
      _ = try await other.convert(
        CapturedPCMChunk(
          sequence: 0,
          monotonicStartNanoseconds: 0,
          frameCount: 2,
          sampleRateHertz: 16_000,
          channelCount: 1,
          encoding: .float32LittleEndian,
          interleaved: false,
          bytes: floatData([0, 0])
        )
      )
    }
  }

  func testFiniteCoreAudioOvershootIsClampedWithoutMutatingSource() async throws {
    let converter = try BoundedPCMConverter(maximumBufferedSourceFrames: 100)
    let source = floatData([1.509_121_4, -1.022_748, 0.5, 0])
    let original = source

    let converted = try await converter.convert(
      CapturedPCMChunk(
        sequence: 0,
        monotonicStartNanoseconds: 0,
        frameCount: 4,
        sampleRateHertz: 16_000,
        channelCount: 1,
        encoding: .float32LittleEndian,
        interleaved: true,
        bytes: source
      )
    )

    XCTAssertEqual(source, original)
    XCTAssertEqual(floatSamples(converted.bytes), [1, -1, 0.5])
  }

  func testNonFiniteFloatInputFailsClosed() async throws {
    let converter = try BoundedPCMConverter(maximumBufferedSourceFrames: 100)
    await assertThrowsConversionError(.nonFiniteSample) {
      _ = try await converter.convert(
        CapturedPCMChunk(
          sequence: 0,
          monotonicStartNanoseconds: 0,
          frameCount: 3,
          sampleRateHertz: 16_000,
          channelCount: 1,
          encoding: .float32LittleEndian,
          interleaved: true,
          bytes: floatData([0, .nan, 0])
        )
      )
    }
  }
}

private func floatData(_ samples: [Float]) -> Data {
  var data = Data(capacity: samples.count * 4)
  for sample in samples {
    var bits = sample.bitPattern.littleEndian
    withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
  }
  return data
}

private func int16Data(_ samples: [Int16]) -> Data {
  var data = Data(capacity: samples.count * 2)
  for sample in samples {
    var bits = UInt16(bitPattern: sample).littleEndian
    withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
  }
  return data
}

private func floatSamples(_ data: Data) -> [Float] {
  data.withUnsafeBytes { rawBuffer in
    stride(from: 0, to: rawBuffer.count, by: 4).map { offset in
      let bits =
        UInt32(rawBuffer[offset])
        | (UInt32(rawBuffer[offset + 1]) << 8)
        | (UInt32(rawBuffer[offset + 2]) << 16)
        | (UInt32(rawBuffer[offset + 3]) << 24)
      return Float(bitPattern: bits)
    }
  }
}

private func assertThrowsConversionError(
  _ expected: PCMConversionError,
  operation: () async throws -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    try await operation()
    XCTFail("Expected \(expected)", file: file, line: line)
  } catch let error as PCMConversionError {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
  }
}
