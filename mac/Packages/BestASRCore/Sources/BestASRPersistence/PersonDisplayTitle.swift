import Foundation

/// Shared presentation for repository projections and the native workspace.
/// A title is deliberately not an identity key: different people can have the
/// same name or creation time and must remain separate entries.
public enum PersonDisplayTitle {
  public static func formatted(displayName: String?, createdAt: Date) -> String {
    if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !name.isEmpty
    {
      return name
    }
    let date = createdAt.formatted(
      .dateTime.month().day().hour().minute().second()
        .locale(Locale(identifier: "zh_Hans_CN"))
    )
    return "待命名 · \(date)"
  }
}
