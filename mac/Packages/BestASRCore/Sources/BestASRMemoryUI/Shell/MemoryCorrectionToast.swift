import BestASRMemory
import Foundation
import MindloomDesign

/// The toast a correction shows (MAC-SPEC §7.6), with the same ID as its
/// undo-window entry so hovering the toast holds the correction.
public enum MemoryCorrectionToast {
  /// - Parameters:
  ///   - titles: matter titles by event ID (for 「已移到「…」」).
  ///   - groups: group names by route ID.
  ///   - names: people's names by person ID (for 「已合并到「…」」).
  public static func toast(
    for correction: MemoryCorrection, id: UUID, titles: [String: String],
    groups: [String: String], names: [String: String] = [:]
  ) -> MemoryToast? {
    switch correction {
    case .moveItem(_, _, _, let to):
      return MemoryToast(
        "已移到“\(short(titles[to] ?? ""))”", icon: .symbol("arrow.up.right"), action: .undo,
        id: id)
    case .takeOut:
      return MemoryToast(
        "已将这件事移到首页的“最近添加”", icon: .symbol("tray.and.arrow.down"), action: .undo, id: id)
    case .newMatter(_, _, _, let title, let provisional):
      return MemoryToast(
        "已新建“\(short(title))”", icon: .symbol("plus"),
        action: .view(eventID: provisional, stepID: nil), id: id)
    case .markStep(_, _, let state, _):
      switch state {
      case .done?:
        return MemoryToast("已标记为完成", icon: .symbol("checkmark.circle"), action: .undo, id: id)
      case .settled?:
        return MemoryToast("已标记为已确定", icon: .symbol("checkmark.circle"), action: .undo, id: id)
      case nil:
        return nil
      }
    case .rename:
      return MemoryToast("已重新命名", icon: .symbol("pencil"), action: .undo, id: id)
    case .delete:
      return MemoryToast("已删除", icon: .symbol("trash"), action: .undo, id: id)
    case .group(_, let from, let to):
      let old = from.flatMap { groups[$0] }
      let new = to.flatMap { groups[$0] }
      let text: String
      switch (old, new) {
      case (let a?, let b?): text = "已从“\(a)”移到“\(b)”"
      case (nil, let b?): text = "已移到“\(b)”"
      case (let a?, nil): text = "已从“\(a)”中移除"
      case (nil, nil): return nil
      }
      return MemoryToast(text, icon: .symbol("folder"), action: .undo, id: id)
    case .pin:
      return nil
    case .namePerson(_, _, let to):
      return MemoryToast(
        "已重新命名为“\(short(to))”", icon: .symbol("pencil"), action: .undo, id: id)
    case .mergePerson(_, let into):
      let name = names[into] ?? names[into.uppercased()] ?? ""
      return MemoryToast(
        name.isEmpty ? "已合并" : "已合并到“\(short(name))”", icon: .symbol("person.2"),
        action: .undo, id: id)
    case .notPerson(_, _, let starts, _):
      return MemoryToast(
        "已分出 \(starts.count) 句，归为一个未命名的声音", icon: .symbol("person.crop.circle.badge.xmark"),
        action: .undo, id: id)
    }
  }

  /// A title in a toast: autospaced, cut at 15 characters with 「…」 when
  /// longer than 16 (§7.4.1).
  public static func short(_ title: String) -> String {
    let spaced = MLAutospace.apply(title)
    guard spaced.count > 16 else { return spaced }
    return String(spaced.prefix(15)) + "…"
  }
}
