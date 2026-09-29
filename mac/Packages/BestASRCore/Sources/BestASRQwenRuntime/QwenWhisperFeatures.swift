import Foundation
import MLX
import MLXAudioCore

/// Log-mel features computed the way Qwen3-ASR's WhisperFeatureExtractor
/// computed them in training: periodic Hann window, reflect-padded STFT,
/// Slaney-scale and Slaney-normalized filters up to 8 kHz, the last frame
/// dropped, log10 clamped to 8 below the clip maximum, then (x + 4) / 4.
///
/// The SDK's `preprocessAudio` builds HTK-scale filters with a symmetric
/// window and keeps the last frame, so every band the model hears is shifted
/// from what it learned. Recognition uses these features instead.
public enum QwenWhisperFeatures {
  public static let sampleRate = 16_000
  public static let fftSize = 400
  public static let hopLength = 160

  static let periodicHann: [Float] = (0..<fftSize).map {
    0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(fftSize))
  }

  /// `[1, melBins, frames]` features, an all-ones `[1, frames]` mask, and the
  /// number of audio tokens the encoder produces for them.
  public static func extract(_ samples: [Float], melBins: Int) -> (
    features: MLXArray, mask: MLXArray, audioTokens: Int
  ) {
    // Reflect padding needs more than one window; pad a tiny clip with silence.
    let audio =
      samples.count > fftSize
      ? samples : samples + [Float](repeating: 0, count: fftSize + 1 - samples.count)
    let spectrum = stft(
      audio: MLXArray(audio), window: MLXArray(periodicHann), nFft: fftSize,
      hopLength: hopLength, padMode: .reflect)
    let frames = spectrum.dim(0) - 1
    let power = MLX.abs(spectrum[0..<frames, 0...]).square()
    let filters = melFilters(
      sampleRate: sampleRate, nFft: fftSize, nMels: melBins, fMin: 0,
      fMax: Float(sampleRate) / 2, norm: "slaney", melScale: .slaney)
    var logMel = MLX.log10(MLX.maximum(MLX.matmul(power, filters), MLXArray(Float(1e-10))))
    logMel = MLX.maximum(logMel, logMel.max() - MLXArray(Float(8)))
    logMel = (logMel + MLXArray(Float(4))) / MLXArray(Float(4))
    let features = logMel.transposed(1, 0).expandedDimensions(axis: 0)
    return (features, MLX.ones([1, frames]).asType(.int32), audioTokens(frames: frames))
  }

  /// Qwen3-ASR's `_get_feat_extract_output_lengths` with Python floor division.
  public static func audioTokens(frames: Int) -> Int {
    func floorDiv(_ a: Int, _ b: Int) -> Int { Int((Double(a) / Double(b)).rounded(.down)) }
    let feat = floorDiv(frames % 100 - 1, 2) + 1
    return floorDiv(floorDiv(feat - 1, 2) + 1 - 1, 2) + 1 + (frames / 100) * 13
  }
}
