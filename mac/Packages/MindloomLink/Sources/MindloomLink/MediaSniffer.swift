import Foundation

/// Recognizes images and audio/video by their first bytes and names. The share
/// extension refuses audio and video by content type; this is the second
/// check, so a mislabeled recording is still refused (PHONE-CONTRACT §0.5).
enum MediaSniffer {
  /// The MIME type of a JPEG, PNG or HEIC image, or nil.
  static func imageType(of bytes: Data) -> String? {
    let head = [UInt8](bytes.prefix(16))
    if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
    if let brand = isoBrand(head), ["heic", "heix", "heim", "heis", "mif1", "msf1"].contains(brand)
    {
      return "image/heic"
    }
    return nil
  }

  static func isAudioOrVideo(_ bytes: Data) -> Bool {
    let head = [UInt8](bytes.prefix(16))
    guard head.count >= 4 else { return false }
    if let brand = isoBrand(head) {
      // ISO base media: MP4, M4A, MOV, 3GP… but not HEIF/AVIF still images.
      let stills: Set<String> = ["heic", "heix", "heim", "heis", "mif1", "msf1", "avif", "avis"]
      return !stills.contains(brand)
    }
    if head.starts(with: Array("RIFF".utf8)), head.count >= 12 {
      let form = String(decoding: head[8..<12], as: UTF8.self)
      return ["WAVE", "AVI ", "RMID"].contains(form)
    }
    if head.starts(with: Array("FORM".utf8)), head.count >= 12 {
      let form = String(decoding: head[8..<12], as: UTF8.self)
      return form == "AIFF" || form == "AIFC"
    }
    let signatures: [[UInt8]] = [
      Array("ID3".utf8),  // MP3 with ID3 tag
      Array("OggS".utf8),  // Ogg / Opus / Vorbis
      Array("fLaC".utf8),  // FLAC
      Array("#!AMR".utf8),  // AMR
      Array("caff".utf8),  // Core Audio Format
      [0x1A, 0x45, 0xDF, 0xA3],  // Matroska / WebM
      [0x30, 0x26, 0xB2, 0x75],  // ASF / WMA / WMV
      [0x00, 0x00, 0x01, 0xBA],  // MPEG program stream
      [0x00, 0x00, 0x01, 0xB3],  // MPEG video
      Array(".snd".utf8),  // Sun/NeXT audio
    ]
    if signatures.contains(where: { head.starts(with: $0) }) { return true }
    // MPEG audio without a tag: an 11-bit frame sync followed by a valid
    // header. 0xFFFE is a UTF-16LE byte-order mark, not audio.
    guard head[0] == 0xFF, head[1] & 0xE0 == 0xE0, head[1] != 0xFE else { return false }
    let version = (head[1] >> 3) & 0x03
    let layer = (head[1] >> 1) & 0x03
    if layer == 0 {
      // AAC ADTS (layer bits 00): sampling index 13…15 is reserved.
      return head[1] & 0xF6 == 0xF0 && (head[2] >> 2) & 0x0F < 13
    }
    // MP1/2/3: version 01 is reserved, bitrate 1111 is invalid, rate 11 reserved.
    return version != 0x01 && head[2] >> 4 != 0x0F && (head[2] >> 2) & 0x03 != 0x03
  }

  static let audioVideoExtensions: Set<String> = [
    "aac", "ac3", "aif", "aifc", "aiff", "amr", "ape", "au", "avi", "caf", "dts", "flac", "flv",
    "m2ts", "m3u8", "m4a", "m4b", "m4p", "m4r", "m4v", "mid", "midi", "mka", "mkv", "mov", "mp2",
    "mp3", "mp4", "mpeg", "mpg", "mts", "oga", "ogg", "ogv", "opus", "qt", "ra", "rm", "rmvb",
    "snd", "spx", "ts", "vob", "wav", "weba", "webm", "wma", "wmv", "3g2", "3gp", "3gpp",
  ]

  static func isAudioOrVideoFilename(_ name: String) -> Bool {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
    return audioVideoExtensions.contains(name[name.index(after: dot)...].lowercased())
  }

  /// The major brand of an ISO base media file (`....ftypXXXX`), or nil.
  private static func isoBrand(_ head: [UInt8]) -> String? {
    guard head.count >= 12, Array(head[4..<8]) == Array("ftyp".utf8) else { return nil }
    return String(decoding: head[8..<12], as: UTF8.self).lowercased()
  }
}
