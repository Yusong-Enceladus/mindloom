import BestASRDomain
import BestASRMemory
import Foundation

/// What the Mindloom pages show from the DGX Spark (v11 live-mac).
///
/// The library keeps the last pulled organizer state (events, people,
/// questions, the unfiled list, readings, the cursor) with the user's own
/// decisions laid over it. That mirror is shown whether or not the link is
/// on: with the link off (or no DGX Spark named at all) Home shows what was
/// last organized, offline; with the link on it shows the live projection as
/// soon as the link has one, and the mirror until then. Turning the link off
/// stops sending; it does not hide what was already organized. Only
/// forgetting the store on the DGX Spark empties the mirror.
///
/// The App and the regression tests go through these same functions, so a
/// real-shaped library (a clone of the preview root) is checked the way the
/// App reads it.
public enum RemoteOrganizerMirror {
  /// The mirror stored in the library, or nil when it holds nothing pulled
  /// (no event, no unfiled item, no person and cursor 0) or cannot be read.
  public static func stored(in repository: any RemoteOrganizerRepository) async
    -> RemoteOrganizerProjection?
  {
    guard let projection = try? await repository.remoteProjection() else { return nil }
    return isEmpty(projection) ? nil : projection
  }

  public static func isEmpty(_ projection: RemoteOrganizerProjection) -> Bool {
    projection.events.isEmpty && projection.unfiled.isEmpty && projection.persons.isEmpty
      && projection.cursor == 0
  }

  /// The projection the pages show: the live link's while it has one, else
  /// the stored mirror.
  public static func shown(
    live: RemoteOrganizerProjection?, stored: RemoteOrganizerProjection?
  ) -> RemoteOrganizerProjection? {
    live ?? stored
  }

  /// The local records the pages need for a projection: every item a shown
  /// matter holds and every unfiled item, each once.
  public static func recordIDs(_ remote: RemoteOrganizerProjection) -> [SessionID] {
    let sources = remote.events.filter { !$0.deleted }.map(MemoryProjection.source)
    return MemoryProjection.sessionIDs(sources.flatMap(\.itemIDs) + remote.unfiled.map(\.itemID))
  }

  /// The memory projection the pages derive from (Home, matter pages,
  /// search, people), built the way the App builds it.
  public static func memoryProjection(
    _ remote: RemoteOrganizerProjection, records: [MemoryItemRecord], now: Date,
    ownerPersonIDs: Set<String>, localPeople: [MemoryLocalPerson] = []
  ) -> MemoryProjection {
    MemoryProjection(
      remote: remote, records: records, now: now, ownerPersonIDs: ownerPersonIDs,
      localPeople: localPeople)
  }
}
