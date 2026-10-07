import MindloomDesign
import SwiftUI

// OWNER: v12 storage. 通用 › 储存空间 (ALIGNMENT 收3-5): what the library
// takes by kind, what each recent month added, and the disk's free space,
// with a line when it is short (`LibraryStorageReport.isLow`).

/// Settings › 通用 › 储存空间, filled by the App.
public struct SettingsStorage: Equatable, Sendable {
  public struct Row: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let bytes: Int64

    public init(id: String, title: String, bytes: Int64) {
      self.id = id
      self.title = title
      self.bytes = bytes
    }
  }

  public struct Month: Identifiable, Equatable, Sendable {
    /// 「2026-09」.
    public let id: String
    /// 「9月」.
    public let label: String
    public let bytes: Int64

    public init(id: String, label: String, bytes: Int64) {
      self.id = id
      self.label = label
      self.bytes = bytes
    }
  }

  public var rows: [Row]
  /// Oldest first, ending with this month.
  public var months: [Month]
  public var availableBytes: Int64
  public var capacityBytes: Int64
  /// Free space is short (`LibraryStorageReport.isLow`: under a tenth of the
  /// disk and under 20 GB).
  public var lowDisk: Bool

  public init(
    rows: [Row], months: [Month], availableBytes: Int64, capacityBytes: Int64,
    lowDisk: Bool = false
  ) {
    self.rows = rows
    self.months = months
    self.availableBytes = availableBytes
    self.capacityBytes = capacityBytes
    self.lowDisk = lowDisk
  }

  public var totalBytes: Int64 { rows.reduce(0) { $0 + $1.bytes } }

  public static func bytes(_ value: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    return formatter.string(fromByteCount: max(0, value))
  }

  /// 「38.2 GB（8%）」.
  public var availableLine: String {
    guard capacityBytes > 0 else { return Self.bytes(availableBytes) }
    let percent = Int((Double(availableBytes) / Double(capacityBytes) * 100).rounded(.down))
    return "\(Self.bytes(availableBytes))（\(percent)%）"
  }
}

struct SettingsStorageGroup: View {
  let storage: SettingsStorage?

  var body: some View {
    SettingsGroup("储存空间", footer: footer) {
      if let storage {
        ForEach(Array(storage.rows.enumerated()), id: \.element.id) { index, row in
          if index > 0 { SettingsSeparator() }
          SettingsRow(nil, row.title, minHeight: 36) {
            Text(SettingsStorage.bytes(row.bytes)).mlFont(\.control)
              .foregroundStyle(MLColor.ink2).monospacedDigit()
          }
          .accessibilityElement(children: .combine)
        }
        SettingsSeparator()
        SettingsRow(nil, "每月新增", detail: monthsDetail(storage), minHeight: 36) {
          MonthBars(months: storage.months)
            .frame(width: 168, height: 34)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        SettingsSeparator()
        SettingsRow(nil, "可用空间", minHeight: 36) {
          Text(storage.availableLine).mlFont(\.control)
            .foregroundStyle(storage.lowDisk ? MLColor.alert : MLColor.ink2).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
      } else {
        SettingsRow(nil, "正在计算…", minHeight: 36) { EmptyView() }
      }
    }
  }

  /// What happens to recordings, stated plainly (docs/UI-COPY.md §1.2, §3;
  /// review 10-6 S12): Mindloom itself replaces the as-captured meeting audio
  /// with its 16 kHz copy, so no line says the user alone removes it.
  private var footer: String {
    let kept =
      "会议和电脑声音在识别完成后以 16 kHz 保存；满 30 天的录音压缩保存，仍可回放和重新识别。录音一直保留到你删除。"
    if storage?.lowDisk == true {
      return "可用空间不足。删除不需要的录音或文件可以释放空间。" + kept
    }
    return kept
  }

  /// 「9月 1.2 GB」 for this month, with the average of the months before.
  private func monthsDetail(_ storage: SettingsStorage) -> String? {
    guard let current = storage.months.last else { return nil }
    let earlier = storage.months.dropLast()
    var line = "\(current.label) \(SettingsStorage.bytes(current.bytes))"
    if !earlier.isEmpty {
      let average = earlier.reduce(Int64(0)) { $0 + $1.bytes } / Int64(earlier.count)
      line += " · 前 \(earlier.count) 个月平均 \(SettingsStorage.bytes(average))"
    }
    return line
  }
}

/// One bar per month, the current month last, labelled underneath.
private struct MonthBars: View {
  let months: [SettingsStorage.Month]

  var body: some View {
    let peak = max(1, months.map(\.bytes).max() ?? 1)
    HStack(alignment: .bottom, spacing: 6) {
      ForEach(Array(months.enumerated()), id: \.element.id) { index, month in
        VStack(spacing: 2) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(
              index == months.count - 1
                ? AnyShapeStyle(MLColor.accent) : AnyShapeStyle(MLColor.ink3.opacity(0.55))
            )
            .frame(height: max(2, 20 * CGFloat(month.bytes) / CGFloat(peak)))
          Text(month.label).font(.system(size: 9)).foregroundStyle(MLColor.ink3)
            .lineLimit(1).fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
      }
    }
  }
}
