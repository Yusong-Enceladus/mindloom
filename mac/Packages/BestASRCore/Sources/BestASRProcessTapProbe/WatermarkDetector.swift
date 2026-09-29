import Foundation

public enum WatermarkDetector {
  public static func measure(
    samples: [Float],
    sampleRate: Double,
    frequency: Double,
    threshold: Double = 0.015
  ) -> WatermarkMeasurement {
    guard samples.count >= 128, sampleRate > 0, frequency > 0 else {
      return WatermarkMeasurement(
        frequency: frequency,
        amplitude: 0,
        detected: false
      )
    }

    let mean =
      samples.reduce(0.0) { $0 + Double($1) }
      / Double(samples.count)
    let omega = 2 * Double.pi * frequency / sampleRate
    var real = 0.0
    var imaginary = 0.0
    for (index, sample) in samples.enumerated() {
      let centered = Double(sample) - mean
      let angle = omega * Double(index)
      real += centered * cos(angle)
      imaginary -= centered * sin(angle)
    }
    let amplitude = 2 * hypot(real, imaginary) / Double(samples.count)
    return WatermarkMeasurement(
      frequency: frequency,
      amplitude: amplitude,
      detected: amplitude >= threshold
    )
  }

  public static func rootMeanSquare(_ samples: [Float]) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(0.0) { partial, sample in
      partial + Double(sample) * Double(sample)
    }
    return sqrt(sum / Double(samples.count))
  }
}
