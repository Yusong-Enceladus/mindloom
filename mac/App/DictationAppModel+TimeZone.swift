import BestASRMemory
import Foundation
import MindloomIdentity
import MindloomLibrary
import OSLog

/// The product time zone (ALIGNMENT 根-13): stored in the library
/// (`library-settings.json`), so a demo root carries its own; changed in
/// Settings › 通用 › 时区.
extension DictationAppModel {
  /// A calendar that counts days in the product time zone.
  var productCalendar: Calendar { ProductTimeZone.calendar(productTimeZone) }

  /// What Settings › 通用 shows.
  var productTimeZoneChoices: [(id: String, label: String)] {
    ProductTimeZone.choices(current: productTimeZone, mac: Self.macTimeZone)
      .map { ($0.identifier, ProductTimeZone.label($0)) }
  }

  /// The Mac's own zone (System Settings), not the process's product zone.
  static var macTimeZone: TimeZone {
    let path = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/etc/localtime")) ?? ""
    if let range = path.range(of: "zoneinfo/"),
      let zone = ProductTimeZone.zone(String(path[range.upperBound...]))
    {
      return zone
    }
    return TimeZone(identifier: "UTC") ?? .current
  }

  /// Stores the zone in the library, makes it the product's (pages, 历史,
  /// search, agents) and redraws the pages; the process's own `TZ` follows
  /// at the next launch (review v12-B #14). Nothing changes when the library
  /// is not open.
  func setProductTimeZone(_ identifier: String) {
    guard let zone = ProductTimeZone.zone(identifier), zone != productTimeZone,
      let root = try? Self.applicationDataRoot()
    else { return }
    let file = LibrarySettingsFile(dataRoot: root)
    var settings = file.load()
    settings.timeZoneIdentifier = zone.identifier
    do {
      try file.save(settings)
    } catch {
      Logger(subsystem: MindloomIdentity.logSubsystem, category: "launch").error(
        "product time zone not saved")
      return
    }
    ProductTimeZone.applyWhileRunning(zone)
    SearchClock.setProductTimeZone(zone)
    productTimeZone = zone
  }
}
