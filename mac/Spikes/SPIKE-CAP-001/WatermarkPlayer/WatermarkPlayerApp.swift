import AVFoundation
import Foundation

@main
struct WatermarkPlayerApp {
  static func main() {
    do {
      let arguments = Arguments(CommandLine.arguments)
      try play(arguments)
    } catch {
      fputs("watermark player failed: \(String(describing: error))\n", stderr)
      exit(1)
    }
  }

  private static func play(_ arguments: Arguments) throws {
    let sampleRate = 48_000.0
    let format = try require(
      AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: 1
      )
    )
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)

    if arguments.leadIn > 0 {
      let silence = try makeBuffer(
        frequency: 0,
        amplitude: 0,
        duration: arguments.leadIn,
        format: format
      )
      player.scheduleBuffer(silence)
    }
    let tone = try makeBuffer(
      frequency: arguments.frequency,
      amplitude: arguments.amplitude,
      duration: arguments.duration,
      format: format
    )
    player.scheduleBuffer(tone)

    try engine.start()
    player.play()

    var helper: Process?
    if let helperFrequency = arguments.helperFrequency {
      Thread.sleep(forTimeInterval: arguments.helperDelay)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      process.arguments = [
        "--frequency", String(helperFrequency),
        "--amplitude", String(arguments.amplitude),
        "--lead-in", "0.2",
        "--duration", String(arguments.helperDuration),
      ]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      helper = process
    }

    let parentEnd = arguments.leadIn + arguments.duration
    let helperEnd =
      arguments.helperFrequency == nil
      ? 0
      : arguments.helperDelay + 0.2 + arguments.helperDuration
    let elapsedBeforeFinalWait =
      arguments.helperFrequency == nil
      ? 0
      : arguments.helperDelay
    Thread.sleep(
      forTimeInterval: max(parentEnd, helperEnd) - elapsedBeforeFinalWait
    )
    helper?.waitUntilExit()
    player.stop()
    engine.stop()
  }

  private static func makeBuffer(
    frequency: Double,
    amplitude: Double,
    duration: TimeInterval,
    format: AVAudioFormat
  ) throws -> AVAudioPCMBuffer {
    let frameCount = AVAudioFrameCount(
      max(1, Int((format.sampleRate * duration).rounded()))
    )
    let buffer = try require(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    )
    buffer.frameLength = frameCount
    let channel = try require(buffer.floatChannelData?[0])
    for frame in 0..<Int(frameCount) {
      let phase = 2 * Double.pi * frequency * Double(frame) / format.sampleRate
      channel[frame] = Float(amplitude * sin(phase))
    }
    return buffer
  }

  private static func require<T>(_ value: T?) throws -> T {
    guard let value else {
      throw PlayerError.invalidAudioBuffer
    }
    return value
  }
}

private enum PlayerError: Error {
  case invalidAudioBuffer
}

private struct Arguments {
  let frequency: Double
  let amplitude: Double
  let leadIn: TimeInterval
  let duration: TimeInterval
  let helperFrequency: Double?
  let helperDelay: TimeInterval
  let helperDuration: TimeInterval

  init(_ arguments: [String]) {
    frequency = Self.value("--frequency", in: arguments) ?? 18_300
    amplitude = Self.value("--amplitude", in: arguments) ?? 0.03
    leadIn = Self.value("--lead-in", in: arguments) ?? 1
    duration = Self.value("--duration", in: arguments) ?? 3
    helperFrequency = Self.value("--helper-frequency", in: arguments)
    helperDelay = Self.value("--helper-delay", in: arguments) ?? 1.5
    helperDuration = Self.value("--helper-duration", in: arguments) ?? 2.5
  }

  private static func value(
    _ name: String,
    in arguments: [String]
  ) -> Double? {
    guard let index = arguments.firstIndex(of: name),
      arguments.indices.contains(index + 1)
    else {
      return nil
    }
    return Double(arguments[index + 1])
  }
}
