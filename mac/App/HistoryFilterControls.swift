import BestASRPersistence
import SwiftUI

enum HistoryFilterField: String, CaseIterable, Identifiable {
  case mode, source, date, status

  var id: String { rawValue }
  var title: String {
    switch self {
    case .mode: "类型"
    case .source: "来源 App"
    case .date: "日期"
    case .status: "状态"
    }
  }

  var options: [(value: String, title: String)] {
    switch self {
    case .mode:
      [
        ("all", "全部类型"), ("dictation", "口述"), ("roomMicrophone", "线下录音"),
        ("systemAudio", "电脑内录"), ("importedMedia", "文件导入"),
      ]
    case .date:
      [("all", "全部时间"), ("today", "今天"), ("7-days", "最近 7 天"), ("30-days", "最近 30 天")]
    case .status:
      [
        ("all", "全部状态"), ("completed", "已完成"), ("processing", "处理中"),
        ("recoverable", "可恢复"), ("failed", "失败"),
      ]
    case .source: []
    }
  }

  @MainActor
  func value(in history: HistoryModel) -> String {
    switch self {
    case .mode: history.modeFilter
    case .source: history.sourceApplicationQuery
    case .date: history.dateRangeFilter
    case .status: history.statusFilter
    }
  }

  @MainActor
  func select(_ value: String, in history: HistoryModel) {
    switch self {
    case .mode: history.modeFilter = value
    case .source: history.sourceApplicationQuery = value
    case .date: history.dateRangeFilter = value
    case .status: history.statusFilter = value
    }
  }

  @MainActor
  func selectionTitle(in history: HistoryModel) -> String {
    let selected = value(in: history)
    if self == .source {
      if selected.isEmpty { return "全部 App" }
      return history.sourceApplications.first { $0.id == selected }?.title ?? "所选 App"
    }
    return options.first { $0.value == selected }?.title ?? title
  }

  @MainActor
  func isActive(in history: HistoryModel) -> Bool {
    value(in: history) != (self == .source ? "" : "all")
  }
}

/// Each condition keeps the same position and width as its value changes.
struct HistoryFilterBar: View {
  @ObservedObject var history: HistoryModel
  @Binding var presentedField: HistoryFilterField?
  let onReset: () -> Void

  private var hasConditions: Bool {
    HistoryFilterField.allCases.contains { $0.isActive(in: history) }
      || !history.searchQuery.isEmpty || history.personFilterID != nil
      || history.eventFilterID != nil || history.durationFilter != "all"
      || history.hasSummaryOnly
  }

  var body: some View {
    HStack(spacing: 6) {
      ForEach(HistoryFilterField.allCases) { field in
        Button {
          presentedField = presentedField == field ? nil : field
        } label: {
          HStack(spacing: 5) {
            Text(field.selectionTitle(in: history))
              .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal.decrease")
              .font(.system(size: 10))
              .foregroundStyle(.secondary)
          }
          .font(.system(size: 12, weight: field.isActive(in: history) ? .semibold : .regular))
          .padding(.horizontal, 9)
          .frame(maxWidth: .infinity)
          .frame(height: 30)
          .background(
            field.isActive(in: history) || presentedField == field
              ? BestASRPalette.accent.opacity(0.10) : BestASRPalette.quietFill,
            in: RoundedRectangle(cornerRadius: 7)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(field.title)：\(field.selectionTitle(in: history))")
        .accessibilityAddTraits(presentedField == field ? .isSelected : [])
        .accessibilityIdentifier("bestASR.history.filter.\(field.rawValue)")
        .help("筛选\(field.title)")
      }
      Button(action: onReset) {
        Image(systemName: "arrow.counterclockwise")
          .frame(width: 28, height: 30)
      }
      .buttonStyle(.plain)
      .disabled(!hasConditions)
      .help("清除搜索和筛选")
      .accessibilityLabel("清除搜索和筛选")
      .accessibilityIdentifier("bestASR.history.resetFilters")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bestASR.history.filters")
  }
}

/// A page region, not a popover: choosing a condition never dismisses or moves its options.
struct HistoryFilterInspector: View {
  @ObservedObject var history: HistoryModel
  let field: HistoryFilterField
  let onClose: () -> Void
  @State private var sourceSearch = ""

  private var applications: [DictationHistorySourceApplication] {
    let query = sourceSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    return history.sourceApplications.filter {
      query.isEmpty || $0.title.localizedStandardContains(query)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(field.title).font(.system(size: 14, weight: .semibold))
        Spacer()
        Button(action: onClose) {
          Image(systemName: "xmark").frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("收起筛选")
        .accessibilityLabel("收起筛选")
        .accessibilityIdentifier("bestASR.history.closeFilters")
      }
      if field == .source {
        SearchField(
          prompt: "查找 App", text: $sourceSearch,
          identifier: "bestASR.history.sourceSearch", fillsWidth: true
        )
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 3) {
          if field == .source {
            option("全部 App", value: "")
            ForEach(applications) { app in
              option(app.title, value: app.bundleIdentifier, count: app.sessionCount)
            }
            if applications.isEmpty && !sourceSearch.isEmpty {
              Text("没有匹配的 App")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            }
          } else {
            ForEach(field.options, id: \.value) { choice in
              option(choice.title, value: choice.value)
            }
          }
        }
      }
      .accessibilityIdentifier("bestASR.history.filterOptions")
    }
    .padding(16)
    .padding(.top, 16)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(BestASRPalette.quietFill.opacity(0.4))
    .onChange(of: field) { _, _ in sourceSearch = "" }
    .onExitCommand(perform: onClose)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bestASR.history.filterInspector")
  }

  private func option(_ title: String, value: String, count: Int? = nil) -> some View {
    let selected = field.value(in: history) == value
    return Button {
      field.select(value, in: history)
    } label: {
      HStack(spacing: 8) {
        Text(title).lineLimit(1)
        Spacer(minLength: 2)
        if let count {
          Text(count.formatted()).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .semibold))
          .opacity(selected ? 1 : 0)
          .frame(width: 12)
      }
      .font(.system(size: 12))
      .padding(.horizontal, 10)
      .frame(height: 32)
      .contentShape(Rectangle())
      .background(
        selected ? BestASRPalette.accent.opacity(0.12) : .clear,
        in: RoundedRectangle(cornerRadius: 7)
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier(
      "bestASR.history.option.\(field.rawValue).\(value.isEmpty ? "all" : value)")
  }
}
