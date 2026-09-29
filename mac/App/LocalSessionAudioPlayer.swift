import AVFoundation
import BestASRDictation
import BestASRInference
import CryptoKit
import Foundation

enum LocalSessionAudioPlayerError: Error, Equatable, Sendable {
  case invalidAudio
  case sourceMissing
  case unsupportedFormat
}

actor LocalSessionAudioPlayer {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private var ranges: [AudioRangeInput] = []
  private var descriptor: CaptureTrackDescriptor?
  private var assetRoot: URL?
  private var nextRangeIndex = 0
  private var initialFrameOffset = 0
  private var durationSeconds = 0.0
  private var positionAtLastStart = 0.0
  private var startedAtNanoseconds: UInt64?
  private var playing = false
  private var generation = UUID()
  private var lastFailure: LocalSessionAudioPlayerError?

  init() {
    engine.attach(node)
  }

  func load(
    ranges: [AudioRangeInput],
    descriptor: CaptureTrackDescriptor,
    assetRoot: URL,
    positionSeconds: Double = 0
  ) throws -> Double {
    stopInternal()
    let ordered = ranges.sorted {
      $0.monotonicStartNanoseconds < $1.monotonicStartNanoseconds
    }
    guard !ordered.isEmpty,
      descriptor.sampleRateHertz > 0,
      descriptor.channelCount > 0,
      descriptor.interleaved,
      ordered.allSatisfy({
        $0.trackID == descriptor.id.rawValue
          && $0.sampleRateHertz == descriptor.sampleRateHertz
          && $0.channelCount == descriptor.channelCount
          && $0.monotonicEndNanoseconds > $0.monotonicStartNanoseconds
      })
    else { throw LocalSessionAudioPlayerError.invalidAudio }
    guard
      descriptor.encoding == .float32LittleEndian
        || descriptor.encoding == .int16LittleEndian
    else { throw LocalSessionAudioPlayerError.unsupportedFormat }
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(descriptor.sampleRateHertz),
        channels: AVAudioChannelCount(descriptor.channelCount),
        interleaved: false
      )
    else { throw LocalSessionAudioPlayerError.unsupportedFormat }
    engine.disconnectNodeOutput(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    engine.prepare()
    self.ranges = ordered
    self.descriptor = descriptor
    self.assetRoot = assetRoot
    lastFailure = nil
    durationSeconds = ordered.reduce(0) {
      $0 + Double($1.monotonicEndNanoseconds - $1.monotonicStartNanoseconds)
        / 1_000_000_000
    }
    try configurePosition(min(max(0, positionSeconds), durationSeconds))
    return durationSeconds
  }

  func play() throws {
    guard !ranges.isEmpty, assetRoot != nil, descriptor != nil else {
      throw LocalSessionAudioPlayerError.invalidAudio
    }
    if playing { return }
    if positionAtLastStart >= durationSeconds {
      try configurePosition(0)
    }
    lastFailure = nil
    do {
      playing = true
      startedAtNanoseconds = nil
      if !node.isPlaying {
        // Keep two authenticated chunks queued. Scheduling only after the
        // preceding buffer has finished leaves an audible gap while the actor
        // maps, hashes, and converts the next file.
        let prebufferLimit = min(ranges.count, nextRangeIndex + 2)
        while nextRangeIndex < prebufferLimit {
          try scheduleNext(generation: generation)
        }
        // Queue real audio before starting the graph. Some output routes start
        // an empty graph successfully but do not wake the player node when the
        // first buffer is attached afterwards, leaving the UI "playing" in
        // silence.
        if !engine.isRunning { try engine.start() }
        node.play()
      } else {
        if !engine.isRunning { try engine.start() }
        node.play()
      }
      // The visible timeline starts when the output node starts, not while
      // source chunks are still being authenticated and converted.
      startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
    } catch let failure as LocalSessionAudioPlayerError {
      failPlayback(failure)
      throw failure
    } catch {
      failPlayback(.invalidAudio)
      throw error
    }
  }

  func pause() {
    guard playing else { return }
    let position = currentPosition()
    node.stop()
    generation = UUID()
    positionAtLastStart = position
    startedAtNanoseconds = nil
    playing = false
    try? configurePosition(position)
  }

  func seek(to seconds: Double) throws {
    let wasPlaying = playing
    stopNodeOnly()
    try configurePosition(min(max(0, seconds), durationSeconds))
    if wasPlaying { try play() }
  }

  func stop() {
    stopInternal()
    ranges = []
    descriptor = nil
    assetRoot = nil
    durationSeconds = 0
    lastFailure = nil
  }

  func state() -> (
    position: Double,
    duration: Double,
    isPlaying: Bool,
    failure: LocalSessionAudioPlayerError?
  ) {
    if playing, currentPosition() + 0.05 < durationSeconds,
      !engine.isRunning || !node.isPlaying
    {
      // Output-device changes can stop AVAudioEngine without invalidating the
      // retained source. Resume from the last audible position instead of
      // letting the timeline advance silently.
      let resumePosition = currentPosition()
      stopNodeOnly()
      do {
        try configurePosition(resumePosition)
        try play()
      } catch let failure as LocalSessionAudioPlayerError {
        failPlayback(failure)
      } catch {
        failPlayback(.invalidAudio)
      }
    }
    return (currentPosition(), durationSeconds, playing, lastFailure)
  }

  private func configurePosition(_ seconds: Double) throws {
    positionAtLastStart = seconds
    startedAtNanoseconds = nil
    nextRangeIndex = 0
    initialFrameOffset = 0
    var remaining = seconds
    for (index, range) in ranges.enumerated() {
      let rangeDuration =
        Double(
          range.monotonicEndNanoseconds - range.monotonicStartNanoseconds
        ) / 1_000_000_000
      if remaining < rangeDuration {
        nextRangeIndex = index
        guard let descriptor else {
          throw LocalSessionAudioPlayerError.invalidAudio
        }
        initialFrameOffset = Int(
          (remaining * Double(descriptor.sampleRateHertz)).rounded(.down)
        )
        return
      }
      remaining -= rangeDuration
    }
    nextRangeIndex = ranges.count
  }


  /// One stored chunk as playable samples.
  ///
  /// Recordings are kept as 16-bit now (`SourceAudioCompaction`), so this is
  /// the only place that reads them back: it refuses anything whose bytes do
  /// not match the digest the index recorded, and it is a function so that
  /// both encodings can be tested without an audio device.
  static func decoded(
    _ data: Data,
    descriptor: CaptureTrackDescriptor,
    expectedDigest: String,
    frameOffset requestedOffset: Int
  ) throws -> AVAudioPCMBuffer {
    let digest = SHA256.hash(data: data).map {
      String(format: "%02x", $0)
    }.joined()
    let bytesPerSample = descriptor.encoding == .float32LittleEndian ? 4 : 2
    let bytesPerFrame = bytesPerSample * Int(descriptor.channelCount)
    guard digest == expectedDigest.lowercased(), bytesPerFrame > 0,
      data.count.isMultiple(of: bytesPerFrame)
    else {
      throw LocalSessionAudioPlayerError.sourceMissing
    }
    let totalFrames = data.count / bytesPerFrame
    let frameOffset = min(requestedOffset, totalFrames)
    let playableFrames = totalFrames - frameOffset
    guard playableFrames > 0,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(descriptor.sampleRateHertz),
        channels: AVAudioChannelCount(descriptor.channelCount),
        interleaved: false
      ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(playableFrames)
      ),
      let destinations = buffer.floatChannelData
    else { throw LocalSessionAudioPlayerError.invalidAudio }
    var invalidSample = false
    data.withUnsafeBytes { raw in
      for outputFrame in 0..<playableFrames {
        let sourceFrame = frameOffset + outputFrame
        for channel in 0..<Int(descriptor.channelCount) {
          let sampleIndex = sourceFrame * Int(descriptor.channelCount) + channel
          let value: Float
          switch descriptor.encoding {
          case .float32LittleEndian:
            let bits = raw.loadUnaligned(
              fromByteOffset: sampleIndex * 4,
              as: UInt32.self
            ).littleEndian
            value = Float(bitPattern: bits)
          case .int16LittleEndian:
            let bits = raw.loadUnaligned(
              fromByteOffset: sampleIndex * 2,
              as: UInt16.self
            ).littleEndian
            value = Float(Int16(bitPattern: bits)) / 32_768
          }
          if value.isFinite {
            destinations[channel][outputFrame] = value
          } else {
            invalidSample = true
            destinations[channel][outputFrame] = 0
          }
        }
      }
    }
    guard !invalidSample else {
      throw LocalSessionAudioPlayerError.invalidAudio
    }
    buffer.frameLength = AVAudioFrameCount(playableFrames)
    return buffer
  }

  private func scheduleNext(generation expectedGeneration: UUID) throws {
    guard expectedGeneration == generation, playing,
      nextRangeIndex < ranges.count,
      let assetRoot,
      let descriptor
    else { return }
    let range = ranges[nextRangeIndex]
    let sourceURL = assetRoot.appendingPathComponent(range.assetReference)
    guard
      sourceURL.standardizedFileURL.path.hasPrefix(
        assetRoot.standardizedFileURL.path + "/"
      )
    else { throw LocalSessionAudioPlayerError.sourceMissing }
    let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
    let buffer = try Self.decoded(
      data,
      descriptor: descriptor,
      expectedDigest: range.contentDigest,
      frameOffset: initialFrameOffset
    )
    nextRangeIndex += 1
    initialFrameOffset = 0
    let isLast = nextRangeIndex == ranges.count
    node.scheduleBuffer(
      buffer,
      completionCallbackType: isLast ? .dataPlayedBack : .dataConsumed
    ) {
      [weak self] _ in
      guard let self else { return }
      Task {
        await self.bufferCompleted(
          isLast: isLast,
          generation: expectedGeneration
        )
      }
    }
  }

  private func bufferCompleted(isLast: Bool, generation expectedGeneration: UUID) {
    guard expectedGeneration == generation, playing else { return }
    if isLast {
      // AVAudioPlayerNode can stay "playing" after its last buffer. Reset its
      // queue and render clock so the next Play actually schedules new audio.
      stopNodeOnly()
      positionAtLastStart = durationSeconds
      return
    }
    do {
      try scheduleNext(generation: expectedGeneration)
    } catch let error as LocalSessionAudioPlayerError {
      failPlayback(error)
    } catch {
      failPlayback(.invalidAudio)
    }
  }

  private func failPlayback(_ failure: LocalSessionAudioPlayerError) {
    let position = currentPosition()
    node.stop()
    generation = UUID()
    positionAtLastStart = position
    startedAtNanoseconds = nil
    playing = false
    lastFailure = failure
    try? configurePosition(position)
  }

  private func currentPosition() -> Double {
    guard playing, let startedAtNanoseconds else {
      return min(durationSeconds, positionAtLastStart)
    }
    if node.isPlaying,
      let nodeTime = node.lastRenderTime,
      let playerTime = node.playerTime(forNodeTime: nodeTime),
      playerTime.sampleRate > 0
    {
      let rendered = max(
        0,
        Double(playerTime.sampleTime) / playerTime.sampleRate
      )
      return min(durationSeconds, positionAtLastStart + rendered)
    }
    let now = DispatchTime.now().uptimeNanoseconds
    let elapsed =
      now >= startedAtNanoseconds
      ? Double(now - startedAtNanoseconds) / 1_000_000_000 : 0
    return min(durationSeconds, positionAtLastStart + elapsed)
  }

  private func stopNodeOnly() {
    node.stop()
    generation = UUID()
    startedAtNanoseconds = nil
    playing = false
  }

  private func stopInternal() {
    stopNodeOnly()
    engine.stop()
    positionAtLastStart = 0
    nextRangeIndex = 0
    initialFrameOffset = 0
  }
}

actor LocalWaveformSampler {
  func sample(
    ranges: [AudioRangeInput],
    descriptor: CaptureTrackDescriptor,
    assetRoot: URL,
    binCount: Int = 240
  ) throws -> [Float] {
    let ordered = ranges.sorted {
      $0.monotonicStartNanoseconds < $1.monotonicStartNanoseconds
    }
    guard !ordered.isEmpty, binCount > 0, descriptor.interleaved,
      descriptor.sampleRateHertz > 0, descriptor.channelCount > 0,
      ordered.allSatisfy({
        $0.trackID == descriptor.id.rawValue
          && $0.sampleRateHertz == descriptor.sampleRateHertz
          && $0.channelCount == descriptor.channelCount
      })
    else { return [] }
    let bytesPerSample = descriptor.encoding == .float32LittleEndian ? 4 : 2
    let bytesPerFrame = bytesPerSample * Int(descriptor.channelCount)
    let expectedFrameCounts = ordered.map { range in
      UInt64(
        max(
          0,
          Int64(range.monotonicEndNanoseconds - range.monotonicStartNanoseconds)
            * Int64(range.sampleRateHertz) / 1_000_000_000
        )
      )
    }
    let totalFrames = expectedFrameCounts.reduce(0, +)
    guard totalFrames > 0 else { return [] }
    // A multi-hour capture can contain tens of thousands of authenticated
    // journal chunks. The waveform is a visual overview, not source evidence:
    // sample at most four chunks per output bin and at most sixteen frames per
    // bin within each selected chunk. Playback still authenticates every chunk
    // immediately before it is scheduled.
    let rangeBudget = max(1, binCount * 4)
    let selectedRangeIndices: Set<Int>
    if ordered.count <= rangeBudget {
      selectedRangeIndices = Set(ordered.indices)
    } else {
      selectedRangeIndices = Set(
        (0..<rangeBudget).map { index in
          Int(
            (Double(index) * Double(ordered.count - 1)
              / Double(rangeBudget - 1)).rounded()
          )
        })
    }
    var peaks = [Float](repeating: 0, count: binCount)
    var globalFrame: UInt64 = 0
    for (rangeIndex, range) in ordered.enumerated() {
      let expectedFrameCount = expectedFrameCounts[rangeIndex]
      guard selectedRangeIndices.contains(rangeIndex) else {
        globalFrame += expectedFrameCount
        continue
      }
      let url = assetRoot.appendingPathComponent(range.assetReference)
      guard
        url.standardizedFileURL.path.hasPrefix(
          assetRoot.standardizedFileURL.path + "/"
        )
      else { throw LocalSessionAudioPlayerError.sourceMissing }
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      guard bytesPerFrame > 0, data.count.isMultiple(of: bytesPerFrame) else {
        throw LocalSessionAudioPlayerError.invalidAudio
      }
      let digest = SHA256.hash(data: data).map {
        String(format: "%02x", $0)
      }.joined()
      guard digest == range.contentDigest.lowercased() else {
        throw LocalSessionAudioPlayerError.sourceMissing
      }
      data.withUnsafeBytes { raw in
        guard raw.baseAddress != nil else { return }
        let frameCount = data.count / bytesPerFrame
        let frameStride = max(1, frameCount / max(1, binCount * 16))
        for frame in stride(from: 0, to: frameCount, by: frameStride) {
          var value: Float = 0
          for channel in 0..<Int(descriptor.channelCount) {
            let sampleIndex = frame * Int(descriptor.channelCount) + channel
            let sample: Float
            switch descriptor.encoding {
            case .float32LittleEndian:
              let bits = raw.loadUnaligned(
                fromByteOffset: sampleIndex * 4,
                as: UInt32.self
              ).littleEndian
              sample = Float(bitPattern: bits)
            case .int16LittleEndian:
              let bits = raw.loadUnaligned(
                fromByteOffset: sampleIndex * 2,
                as: UInt16.self
              ).littleEndian
              sample = Float(Int16(bitPattern: bits)) / 32_768
            }
            value = max(value, sample.isFinite ? abs(sample) : 0)
          }
          let bin = min(
            binCount - 1,
            Int((globalFrame + UInt64(frame)) * UInt64(binCount) / totalFrames)
          )
          peaks[bin] = max(peaks[bin], value.isFinite ? value : 0)
        }
      }
      globalFrame += expectedFrameCount
    }
    let maximum = peaks.max() ?? 0
    guard maximum > 0 else { return peaks }
    return peaks.map { min(1, $0 / maximum) }
  }
}
