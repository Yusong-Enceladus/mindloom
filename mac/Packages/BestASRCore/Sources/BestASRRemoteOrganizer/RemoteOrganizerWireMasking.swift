import BestASRDomain
import CryptoKit
import Foundation

/// Masks every text field an item or a decision sends (privacy contract §3):
/// item text, segment text, a user item's text, a document's text, a file's
/// local text, a person's display name, the source label, and the file name.
/// What is kept for organizing — names, dates, amounts, places — is left as
/// it is by the rules themselves. Each field stays within the service's
/// limit without ever cutting a placeholder in half.
public struct RemoteOrganizerWireMasking: Sendable {
  public let masker: PrivacyMasker

  public init(keys: OrganizerKeyMaterial) {
    masker = PrivacyMasker(keys: keys)
  }

  public init(masker: PrivacyMasker) {
    self.masker = masker
  }

  /// Service limits in Unicode scalars (`schemas.py`).
  static let textLimit = UserItemLimits.maximumSendableTextScalars
  static let displayNameLimit = RemoteOrganizerDecision.maximumDisplayNameScalars
  static let sourceNameLimit = 256
  static let filenameLimit = 255
  static let titleLimit = RemoteOrganizerDecision.maximumTitleScalars

  /// The item as it crosses the link and what its placeholders stand for.
  /// `sha256` replaces the stored digest when given (images: the digest of
  /// the redacted copy); for text kinds it is the digest of the masked text.
  public func mask(_ item: RemoteOrganizerItem, sha256 override: String? = nil) -> (
    item: RemoteOrganizerItem, record: RemoteOrganizerMaskRecord
  ) {
    var entries = Set<RemoteOrganizerMaskRecord.Entry>()
    func masked(_ value: String?, limit: Int) -> String? {
      guard let value else { return nil }
      let (text, spans) = masker.maskWithSpans(value)
      for span in spans {
        entries.insert(
          .init(placeholder: span.placeholder, original: span.original, type: span.type))
      }
      return Self.clamp(text, to: limit)
    }
    var textOffsets: [PrivacyMaskOffset] = []
    var text: String?
    if let original = item.text {
      let (value, spans) = masker.maskWithSpans(original)
      for span in spans {
        entries.insert(
          .init(placeholder: span.placeholder, original: span.original, type: span.type))
      }
      textOffsets = PrivacyMaskOffset.offsets(original: original, spans: spans)
      text = Self.clamp(value, to: Self.textLimit)
    }
    let segments = item.segments?.map {
      RemoteOrganizerItem.Segment(
        startMS: $0.startMS, endMS: $0.endMS, personID: $0.personID,
        text: masked($0.text, limit: Self.textLimit) ?? "")
    }
    let persons = item.persons?.map {
      RemoteOrganizerItem.Person(
        personID: $0.personID, displayName: masked($0.displayName, limit: Self.displayNameLimit))
    }
    let sourceName = masked(item.sourceApp.name, limit: Self.sourceNameLimit) ?? item.sourceApp.name
    let filename = masked(item.filename, limit: Self.filenameLimit)
    let localText = masked(item.localText, limit: Self.textLimit)
    let digest: String
    if let override {
      digest = override
    } else if item.kind == "image" || item.fileAsset != nil {
      // A file's digest names the bytes that are sent; an image's, the copy
      // that is sent.
      digest = item.sha256
    } else {
      // Text, and a file too large to send that goes as its text: the digest
      // of the masked text, never of the original bytes, which would let the
      // organizing device recognize the file (privacy review F16).
      digest = Self.hex(SHA256.hash(data: Data((text ?? "").utf8)))
    }
    let wire = item.withWireText(
      text: text, segments: segments, persons: persons, sourceName: sourceName,
      filename: filename, localText: localText, sha256: digest)
    return (
      wire,
      RemoteOrganizerMaskRecord(
        ownerID: item.itemID.uuidString, entries: Self.sorted(entries), textOffsets: textOffsets,
        revision: item.revision)
    )
  }

  /// A decision's free text (a title, a person's name) as it crosses the link.
  public func mask(_ decision: RemoteOrganizerDecision) -> (
    decision: RemoteOrganizerDecision, record: RemoteOrganizerMaskRecord
  ) {
    var entries = Set<RemoteOrganizerMaskRecord.Entry>()
    func masked(_ value: String?, limit: Int) -> String? {
      guard let value else { return nil }
      let (text, spans) = masker.maskWithSpans(value)
      for span in spans {
        entries.insert(
          .init(placeholder: span.placeholder, original: span.original, type: span.type))
      }
      return Self.clamp(text, to: limit)
    }
    let wire = decision.withWireText(
      title: masked(decision.title, limit: Self.titleLimit),
      displayName: masked(decision.displayName, limit: Self.displayNameLimit))
    return (
      wire,
      RemoteOrganizerMaskRecord(
        ownerID: decision.decisionID.uuidString, entries: Self.sorted(entries))
    )
  }

  /// At most `limit` Unicode scalars; a placeholder the cut would split is
  /// left out whole.
  static func clamp(_ value: String, to limit: Int) -> String {
    let scalars = value.unicodeScalars
    guard scalars.count > limit else { return value }
    var kept = Array(scalars.prefix(limit))
    if let open = kept.lastIndex(of: "\u{3014}"), !kept[open...].contains("\u{3015}") {
      kept.removeSubrange(open...)
    }
    var view = String.UnicodeScalarView()
    view.append(contentsOf: kept)
    return String(view)
  }

  static func sorted(_ entries: Set<RemoteOrganizerMaskRecord.Entry>) -> [RemoteOrganizerMaskRecord
    .Entry]
  {
    entries.sorted { ($0.placeholder, $0.original) < ($1.placeholder, $1.original) }
  }

  static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
