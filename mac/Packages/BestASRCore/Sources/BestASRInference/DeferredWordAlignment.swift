import CryptoKit
import Foundation

/// Dictation's word timings arrive after the recognizer has left memory
/// (ALIGNMENT recommendation 1, adopted 2026-10-06; DICTATION_ARCHITECTURE
/// §15.7).
///
/// The recognizer (2.35 GB) and the aligner (1.22 GB) together are 3.58 GB
/// of weights, over the 3.5 GB dictation budget on their own. So dictation
/// asks the recognizer for text only (`ASRRecognitionContext
/// .deferWordAlignment`): each recognizer window comes back as one segment
/// spanning the whole window, and its sentences are timed later, by the
/// aligner alone, once the recognizer has been released (or when the user
/// asks for them in History).
///
/// Such a segment is marked by its ID alone, so the mark needs no schema of
/// its own and survives every copy of the row: it is a UUID of version 8
/// (RFC 9562's custom version). Every other segment ID in the library is a
/// version 4 or version 5 UUID. Once its sentences are timed the segment is
/// replaced by them, whose IDs are version 5, and the mark is gone.
public enum DeferredWordAlignment {
  /// The ID of a window segment whose word timings are still to come;
  /// deterministic in `seed`.
  public static func pendingSegmentID(seed: String) -> UUID {
    uuid(seed: "deferred-word-alignment-pending|" + seed, version: 0x80)
  }

  /// Whether `id` marks a window segment whose word timings are still to
  /// come.
  public static func isPending(_ id: UUID) -> Bool {
    id.uuid.6 & 0xf0 == 0x80
  }

  /// The ID of the `ordinal`th timed sentence that replaces the pending
  /// segment `pending`; deterministic, so aligning the same window twice
  /// writes the same rows.
  public static func sentenceID(
    replacing pending: UUID, ordinal: Int, startNanoseconds: UInt64, endNanoseconds: UInt64,
    text: String
  ) -> UUID {
    uuid(
      seed: [
        "deferred-word-alignment-sentence", pending.uuidString.lowercased(), String(ordinal),
        String(startNanoseconds), String(endNanoseconds), text,
      ].joined(separator: "\u{1f}"),
      version: 0x50)
  }

  private static func uuid(seed: String, version: UInt8) -> UUID {
    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | version
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}
