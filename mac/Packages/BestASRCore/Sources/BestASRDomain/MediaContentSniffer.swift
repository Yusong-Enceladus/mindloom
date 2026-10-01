import Foundation

/// Recognizes audio and video by their first bytes, whatever the file is
/// called (privacy contract §5: audio or video is never sent as bytes).
/// Deterministic signature checks only; no decoder is run.
public enum MediaContentSniffer {
  /// How many leading bytes `isAudioOrVideo` looks at.
  public static let prefixLength = 256

  /// ISO base media brands that are still images (HEIF/AVIF, Canon CR3), not
  /// audio or video.
  static let imageBrands: Set<String> = [
    "heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1",
    "avif", "avis", "crx ", "jpeg", "jpgs", "avci",
  ]

  public static func isAudioOrVideo(_ data: Data) -> Bool {
    let bytes = [UInt8](data.prefix(prefixLength))
    func ascii(_ offset: Int, _ length: Int) -> String? {
      guard bytes.count >= offset + length else { return nil }
      return String(bytes: bytes[offset..<(offset + length)], encoding: .isoLatin1)
    }
    func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
      bytes.count >= offset + signature.count
        && Array(bytes[offset..<(offset + signature.count)]) == signature
    }
    // MP4, M4A, MOV, 3GP, …: an `ftyp` box whose brand is not an image.
    if ascii(4, 4) == "ftyp", let brand = ascii(8, 4) {
      return !imageBrands.contains(brand.lowercased())
    }
    // QuickTime without `ftyp`: a `moov`/`mdat`/`wide`/`free` atom first.
    if let atom = ascii(4, 4), ["moov", "mdat", "wide", "skip", "pnot"].contains(atom) {
      return true
    }
    if ascii(0, 4) == "RIFF", let form = ascii(8, 4) {
      return ["WAVE", "AVI ", "RMID", "CDXA", "AMV "].contains(form)
    }
    if ascii(0, 4) == "FORM", let form = ascii(8, 4) {
      return ["AIFF", "AIFC", "8SVX"].contains(form)
    }
    let signatures: [[UInt8]] = [
      Array("ID3".utf8),  // MP3 with an ID3 tag
      Array("OggS".utf8),  // Ogg Vorbis/Opus/Theora
      Array("fLaC".utf8),
      [0x1A, 0x45, 0xDF, 0xA3],  // Matroska / WebM
      [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11],  // ASF: WMA/WMV
      Array("FLV".utf8) + [0x01],
      Array("#!AMR".utf8),
      Array("caff".utf8),
      Array("MThd".utf8),  // MIDI
      [0x2E, 0x73, 0x6E, 0x64],  // Sun .au
      Array(".RMF".utf8),  // RealMedia
      Array("wvpk".utf8),
      Array("MAC ".utf8),
      Array("DSD ".utf8),
      [0x00, 0x00, 0x01, 0xBA],  // MPEG program stream
      [0x00, 0x00, 0x01, 0xB3],  // MPEG video
    ]
    if signatures.contains(where: { starts($0) }) { return true }
    // ADTS AAC (sync FFF, layer 00) or an MPEG audio Layer II/III frame
    // (sync 7FF, layer 10 or 01). Layer I is left out: its header is also
    // UTF-16 text's byte order mark (FF FE), and JPEG's FF D8 never matches.
    if bytes.count >= 3, bytes[0] == 0xFF {
      let second = bytes[1]
      if second & 0xF6 == 0xF0 { return true }
      let layer = second & 0x06
      if second & 0xE0 == 0xE0, layer == 0x02 || layer == 0x04, bytes[2] & 0xF0 != 0xF0 {
        return true
      }
    }
    // MPEG transport stream: sync bytes every 188.
    if bytes.count > 188, bytes[0] == 0x47, bytes[188] == 0x47 { return true }
    return false
  }
}
