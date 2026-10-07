import Foundation

/// Who answers a gap (MATTER-MINIMUM §5; PRD EVENT-012): facts a person
/// decides go to the person, facts with a public identity go to the web.
public enum LookupRoute: String, Codable, Sendable {
  /// Only the owner can answer.
  case askPerson
  /// A public source can answer.
  case lookUp
  /// A missing deadline is always asked of the owner. When it belongs to a
  /// public event, the public date is also looked up and attached as its own
  /// source, shown beside the owner's answer, never in place of it.
  case askPersonAndLookUp
  /// Neither: nothing to ask and nothing public to look up.
  case neither
}

public enum LookupRouting {
  /// Subjects whose deadlines are published (a conference, a journal's call,
  /// a public notice).
  static let publicDeadlineKinds: Set<LookupSubjectKind> = [.conference, .journal, .publicNotice]

  /// The route for one gap. `healthRelated`: a matter about health is never
  /// looked up (MATTER-MINIMUM §5, §8.2), whatever the gap.
  public static func route(for request: LookupRequest, healthRelated: Bool = false) -> LookupRoute {
    let publicName = request.subject.map { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
    switch request.gap {
    case .deadline:
      guard !healthRelated, publicName, let kind = request.subject?.kind,
        publicDeadlineKinds.contains(kind)
      else { return .askPerson }
      return .askPersonAndLookUp
    case .paperInfo:
      if healthRelated { return .neither }
      return publicName || !request.identifiers.isEmpty ? .lookUp : .neither
    case .callForPapers, .eventDates, .address, .openingHours, .specification, .price,
      .publicNotice, .overview:
      if healthRelated { return .neither }
      return publicName ? .lookUp : .neither
    }
  }
}
