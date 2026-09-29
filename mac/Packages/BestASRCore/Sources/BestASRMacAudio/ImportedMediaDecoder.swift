import AVFoundation
import AudioToolbox
import BestASRDictation
import BestASRDomain
import CoreMedia
import Foundation

public enum ImportedMediaDecoderError: Error, Equatable, Sendable {
  case emptyMedia
  case unsupportedAudioFormat
}

public struct ImportedMediaDecodeProgress: Equatable, Sendable {
  public let decodedFrames: UInt64
  public let totalFrames: UInt64

  public var fractionCompleted: Double {
    guard totalFrames > 0 else { return 0 }
    return min(1, Double(decodedFrames) / Double(totalFrames))
  }

  public init(decodedFrames: UInt64, totalFrames: UInt64) {
    self.decodedFrames = decodedFrames
    self.totalFrames = totalFrames
  }
}

public struct ImportedMediaInspection: Equatable, Sendable {
  public let descriptor: MicrophoneCaptureDescriptor
  public let totalFrames: UInt64
  public let durationNanoseconds: UInt64

  public init(
    descriptor: MicrophoneCaptureDescriptor,
    totalFrames: UInt64,
    durationNanoseconds: UInt64
  ) {
    self.descriptor = descriptor
    self.totalFrames = totalFrames
    self.durationNanoseconds = durationNanoseconds
  }
}

/// Decodes media through the system AVFoundation stack as fast as the machine
/// permits. No helper process, command-line runtime, or network access is used.
public actor AVFoundationImportedMediaDecoder {
  public typealias ChunkHandler = @Sendable (CapturedPCMChunk) async throws -> Void
  public typealias ProgressHandler = @Sendable (ImportedMediaDecodeProgress) -> Void

  private let framesPerChunk: AVAudioFrameCount

  public init(framesPerChunk: AVAudioFrameCount = 8_192) {
    self.framesPerChunk = max(1_024, framesPerChunk)
  }

  public func inspect(url: URL, sessionID: SessionID) async throws
    -> ImportedMediaInspection
  {
    if let file = try? AVAudioFile(forReading: url),
      let inspection = try? Self.inspect(
        file: file,
        sessionID: sessionID
      )
    {
      return inspection
    }
    return try await inspectAsset(url: url, sessionID: sessionID)
  }

  public func decode(
    url: URL,
    sessionID: SessionID,
    startingFrame: UInt64 = 0,
    startingSequence: UInt64 = 0,
    onChunk: @escaping ChunkHandler,
    onProgress: @escaping ProgressHandler
  ) async throws -> MicrophoneCaptureDescriptor {
    if let file = try? AVAudioFile(forReading: url) {
      do {
        return try await decodeAudioFile(
          file,
          sessionID: sessionID,
          startingFrame: startingFrame,
          startingSequence: startingSequence,
          onChunk: onChunk,
          onProgress: onProgress
        )
      } catch ImportedMediaDecoderError.unsupportedAudioFormat {
        // Some video/container files can be opened as AVAudioFile but still
        // require the AVAssetReader path to expose their audio track.
      }
    }
    return try await decodeAsset(
      url: url,
      sessionID: sessionID,
      startingFrame: startingFrame,
      startingSequence: startingSequence,
      onChunk: onChunk,
      onProgress: onProgress
    )
  }

  private func decodeAudioFile(
    _ file: AVAudioFile,
    sessionID: SessionID,
    startingFrame: UInt64,
    startingSequence: UInt64,
    onChunk: @escaping ChunkHandler,
    onProgress: @escaping ProgressHandler
  ) async throws -> MicrophoneCaptureDescriptor {
    let format = file.processingFormat
    guard
      format.commonFormat == .pcmFormatFloat32,
      !format.isInterleaved,
      format.sampleRate > 0,
      format.channelCount > 0,
      format.channelCount <= UInt32(UInt16.max),
      file.length > 0
    else { throw ImportedMediaDecoderError.unsupportedAudioFormat }
    let totalFrames = UInt64(file.length)
    guard startingFrame <= totalFrames,
      startingSequence <= UInt64(Int64.max)
    else { throw ImportedMediaDecoderError.unsupportedAudioFormat }
    file.framePosition = AVAudioFramePosition(startingFrame)
    let trackID = TrackID(sessionID.rawValue)
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: framesPerChunk
      )
    else { throw ImportedMediaDecoderError.unsupportedAudioFormat }

    var sequence = startingSequence
    var decodedFrames = startingFrame
    while decodedFrames < totalFrames {
      try Task.checkCancellation()
      buffer.frameLength = 0
      try file.read(into: buffer, frameCount: framesPerChunk)
      guard buffer.frameLength > 0 else { break }
      guard let channels = buffer.floatChannelData else {
        throw ImportedMediaDecoderError.unsupportedAudioFormat
      }
      let frameCount = Int(buffer.frameLength)
      let channelCount = Int(format.channelCount)
      var bytes = Data(capacity: frameCount * channelCount * 4)
      for frame in 0..<frameCount {
        for channel in 0..<channelCount {
          let bits = channels[channel][frame].bitPattern.littleEndian
          withUnsafeBytes(of: bits) { bytes.append(contentsOf: $0) }
        }
      }
      let startNanoseconds = UInt64(
        (Double(decodedFrames) * 1_000_000_000 / format.sampleRate).rounded()
      )
      let chunk = CapturedPCMChunk(
        trackID: trackID,
        sequence: sequence,
        monotonicStartNanoseconds: startNanoseconds,
        frameCount: UInt64(frameCount),
        sampleRateHertz: UInt32(format.sampleRate.rounded()),
        channelCount: UInt16(format.channelCount),
        encoding: .float32LittleEndian,
        interleaved: true,
        bytes: bytes
      )
      try await onChunk(chunk)
      sequence += 1
      decodedFrames += UInt64(frameCount)
      onProgress(
        ImportedMediaDecodeProgress(
          decodedFrames: decodedFrames,
          totalFrames: totalFrames
        )
      )
      await Task.yield()
    }
    guard decodedFrames > 0 else { throw ImportedMediaDecoderError.emptyMedia }
    return try Self.inspect(file: file, sessionID: sessionID).descriptor
  }

  private func inspectAsset(
    url: URL,
    sessionID: SessionID
  ) async throws -> ImportedMediaInspection {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first
    else { throw ImportedMediaDecoderError.unsupportedAudioFormat }
    let description = try await Self.assetDescription(asset: asset, track: track)
    return ImportedMediaInspection(
      descriptor: Self.descriptor(
        sessionID: sessionID,
        sampleRateHertz: description.sampleRateHertz,
        channelCount: description.channelCount
      ),
      totalFrames: description.totalFrames,
      durationNanoseconds: description.durationNanoseconds
    )
  }

  private func decodeAsset(
    url: URL,
    sessionID: SessionID,
    startingFrame: UInt64,
    startingSequence: UInt64,
    onChunk: @escaping ChunkHandler,
    onProgress: @escaping ProgressHandler
  ) async throws -> MicrophoneCaptureDescriptor {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first
    else { throw ImportedMediaDecoderError.unsupportedAudioFormat }
    let description = try await Self.assetDescription(asset: asset, track: track)
    let reader = try AVAssetReader(asset: asset)
    guard startingFrame <= description.totalFrames else {
      throw ImportedMediaDecoderError.unsupportedAudioFormat
    }
    if startingFrame > 0 {
      let start = CMTime(
        value: Int64(startingFrame),
        timescale: CMTimeScale(description.sampleRateHertz)
      )
      reader.timeRange = CMTimeRange(start: start, end: .positiveInfinity)
    }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
      AVSampleRateKey: Double(description.sampleRateHertz),
      AVNumberOfChannelsKey: Int(description.channelCount),
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw ImportedMediaDecoderError.unsupportedAudioFormat
    }
    reader.add(output)
    guard reader.startReading() else {
      throw ImportedMediaDecoderError.unsupportedAudioFormat
    }
    let trackID = TrackID(sessionID.rawValue)
    var sequence = startingSequence
    var decodedFrames = startingFrame
    while reader.status == .reading {
      try Task.checkCancellation()
      guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
      let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
      guard frameCount > 0 else { continue }
      let bytes = try Self.interleavedFloatBytes(
        sampleBuffer: sampleBuffer,
        frameCount: frameCount,
        channelCount: Int(description.channelCount)
      )
      let startNanoseconds = UInt64(
        (Double(decodedFrames) * 1_000_000_000
          / Double(description.sampleRateHertz)).rounded()
      )
      try await onChunk(
        CapturedPCMChunk(
          trackID: trackID,
          sequence: sequence,
          monotonicStartNanoseconds: startNanoseconds,
          frameCount: UInt64(frameCount),
          sampleRateHertz: description.sampleRateHertz,
          channelCount: description.channelCount,
          encoding: .float32LittleEndian,
          interleaved: true,
          bytes: bytes
        )
      )
      decodedFrames += UInt64(frameCount)
      sequence += 1
      onProgress(
        ImportedMediaDecodeProgress(
          decodedFrames: decodedFrames,
          totalFrames: max(decodedFrames, description.totalFrames)
        )
      )
      await Task.yield()
    }
    guard reader.status == .completed, decodedFrames > 0 else {
      if Task.isCancelled { throw CancellationError() }
      throw ImportedMediaDecoderError.unsupportedAudioFormat
    }
    return Self.descriptor(
      sessionID: sessionID,
      sampleRateHertz: description.sampleRateHertz,
      channelCount: description.channelCount
    )
  }

  private struct AssetDescription {
    let sampleRateHertz: UInt32
    let channelCount: UInt16
    let totalFrames: UInt64
    let durationNanoseconds: UInt64
  }

  private static func assetDescription(
    asset: AVURLAsset,
    track: AVAssetTrack
  ) async throws -> AssetDescription {
    let descriptions = try await track.load(.formatDescriptions)
    guard let description = descriptions.first,
      let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
      basic.pointee.mSampleRate > 0,
      basic.pointee.mChannelsPerFrame > 0,
      basic.pointee.mChannelsPerFrame <= UInt32(UInt16.max)
    else { throw ImportedMediaDecoderError.unsupportedAudioFormat }
    let duration = try await asset.load(.duration)
    let seconds = CMTimeGetSeconds(duration)
    guard seconds.isFinite, seconds > 0 else {
      throw ImportedMediaDecoderError.emptyMedia
    }
    let rate = UInt32(basic.pointee.mSampleRate.rounded())
    let frames = UInt64((seconds * Double(rate)).rounded(.up))
    return AssetDescription(
      sampleRateHertz: rate,
      channelCount: UInt16(basic.pointee.mChannelsPerFrame),
      totalFrames: frames,
      durationNanoseconds: UInt64((seconds * 1_000_000_000).rounded())
    )
  }

  private static func inspect(
    file: AVAudioFile,
    sessionID: SessionID
  ) throws -> ImportedMediaInspection {
    let format = file.processingFormat
    guard format.commonFormat == .pcmFormatFloat32,
      !format.isInterleaved,
      format.sampleRate > 0,
      format.channelCount > 0,
      format.channelCount <= UInt32(UInt16.max),
      file.length > 0
    else { throw ImportedMediaDecoderError.unsupportedAudioFormat }
    let totalFrames = UInt64(file.length)
    let rate = UInt32(format.sampleRate.rounded())
    return ImportedMediaInspection(
      descriptor: descriptor(
        sessionID: sessionID,
        sampleRateHertz: rate,
        channelCount: UInt16(format.channelCount)
      ),
      totalFrames: totalFrames,
      durationNanoseconds: UInt64(
        (Double(totalFrames) * 1_000_000_000 / format.sampleRate).rounded()
      )
    )
  }

  private static func descriptor(
    sessionID: SessionID,
    sampleRateHertz: UInt32,
    channelCount: UInt16
  ) -> MicrophoneCaptureDescriptor {
    let trackID = TrackID(sessionID.rawValue)
    return MicrophoneCaptureDescriptor(
      sessionID: sessionID,
      deviceUID: "imported-media",
      sampleRateHertz: sampleRateHertz,
      channelCount: channelCount,
      encoding: .float32LittleEndian,
      interleaved: true,
      tracks: [
        CaptureTrackDescriptor(
          id: trackID,
          role: .importedSource,
          deviceUID: "imported-media",
          sampleRateHertz: sampleRateHertz,
          channelCount: channelCount,
          encoding: .float32LittleEndian,
          interleaved: true
        )
      ]
    )
  }

  private static func interleavedFloatBytes(
    sampleBuffer: CMSampleBuffer,
    frameCount: Int,
    channelCount: Int
  ) throws -> Data {
    var requiredSize = 0
    let sizingStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &requiredSize,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: nil
    )
    guard sizingStatus == noErr, requiredSize >= MemoryLayout<AudioBufferList>.size
    else { throw ImportedMediaDecoderError.unsupportedAudioFormat }
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: requiredSize,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { storage.deallocate() }
    let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
    var retainedBlock: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: list,
      bufferListSize: requiredSize,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: &retainedBlock
    )
    guard status == noErr else {
      throw ImportedMediaDecoderError.unsupportedAudioFormat
    }
    let buffers = UnsafeMutableAudioBufferListPointer(list)
    let expectedBytes = frameCount * channelCount * MemoryLayout<Float>.size
    guard buffers.count == 1,
      Int(buffers[0].mNumberChannels) == channelCount,
      Int(buffers[0].mDataByteSize) == expectedBytes,
      let pointer = buffers[0].mData
    else { throw ImportedMediaDecoderError.unsupportedAudioFormat }
    return Data(bytes: pointer, count: expectedBytes)
  }
}
