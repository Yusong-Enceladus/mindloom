import AppKit
import BestASRCore
import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRPersistence
import Dispatch
import SwiftUI

// History: moved out of ContentView.swift without change.
extension ContentView {
  var historyDeletionIsPresented: Binding<Bool> {
    Binding(
      get: { pendingHistoryDeletion != nil },
      set: { if !$0 { pendingHistoryDeletion = nil } }
    )
  }

  var historyView: some View {
    Group {
      if model.history.detailPresented,
        let selected = model.history.historyItems.first(where: {
          $0.sessionID == model.history.selectedHistorySessionID
        })
      {
        historyDetailPage(selected)
      } else {
        historyListPage
      }
    }
    .background {
      HistoryPlaybackKeyboardHandler(
        isEnabled: historyFocusedField == nil && historyFilterField == nil
          && !model.playback.playbackTrackIDs.isEmpty
      ) { command in
        switch command {
        case .togglePlayback:
          model.toggleHistoryPlayback()
        case .seekBackward:
          model.seekHistoryPlayback(
            to: max(0, model.playback.playbackPosition - 15)
          )
        case .seekForward:
          model.seekHistoryPlayback(
            to: min(
              model.playback.playbackDuration,
              model.playback.playbackPosition + 15
            )
          )
        }
      }
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
    }
    .onChange(of: model.history.selectedHistorySessionID) { _, _ in
      editingHistoryTitleID = nil
      if historyFocusedField == .title { historyFocusedField = nil }
    }
    .onChange(of: model.history.searchNavigationQuery) { _, query in
      if !query.isEmpty {
        historyWorkspaceTab = .transcript
      }
    }
  }

  var historyListPage: some View {
    HStack(alignment: .top, spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("历史记录")
              .font(.system(size: 24, weight: .semibold))
            Spacer(minLength: 12)
            Text(model.history.listLoading ? "正在更新…" : model.history.historyStatusMessage)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .accessibilityIdentifier("bestASR.history.status")
          }
          SearchField(
            prompt: "搜索历史记录",
            text: $model.history.searchQuery,
            identifier: "bestASR.history.search",
            fillsWidth: true
          )
          .focused($historyFocusedField, equals: .search)
          .onSubmit { openFocusedHistoryResult() }

          HistoryFilterBar(
            history: model.history,
            presentedField: $historyFilterField,
            onReset: model.resetHistoryFilters
          )
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 12)

        Divider().padding(.horizontal, 28)
        historyResults
          .overlay(alignment: .top) {
            if !model.history.historyItems.isEmpty,
              (model.history.listLoading
                && model.history.presentedQuery != model.history.currentQuery)
                || model.history.listErrorMessage != nil
            {
              HStack(spacing: 8) {
                Text(
                  model.history.listErrorMessage == nil
                    ? "正在更新，暂时显示上次结果" : "更新失败，保留上次结果"
                )
                .font(.system(size: 12))
                if model.history.listErrorMessage != nil {
                  Button("重试") { model.applyHistoryFilters() }
                    .accessibilityIdentifier("bestASR.history.retryQuery")
                }
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
              .padding(.top, 8)
              .accessibilityIdentifier("bestASR.history.previousResults")
            }
          }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if let field = historyFilterField {
        Divider()
        HistoryFilterInspector(
          history: model.history,
          field: field,
          onClose: { historyFilterField = nil }
        )
        .frame(width: 220)
      }
    }
    .background {
      HistoryListKeyboardHandler(
        isEnabled: !model.history.detailPresented && historyFilterField == nil,
        hasQuery: !model.history.searchQuery.isEmpty
      ) { command in
        switch command {
        case .focusSearch: historyFocusedField = .search
        case .moveUp: moveHistoryFocus(by: -1)
        case .moveDown: moveHistoryFocus(by: 1)
        case .clearSearch:
          model.history.searchQuery = ""
          historyKeyboardIndex = nil
        }
      }
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
    }
    .onChange(of: [
      model.history.searchQuery, model.history.modeFilter,
      model.history.dateRangeFilter, model.history.statusFilter,
      model.history.sourceApplicationQuery,
    ]) { _, _ in
      historyKeyboardIndex = nil
      model.applyHistoryFilters()
    }
  }

  @ViewBuilder
  var historyResults: some View {
    if model.history.historyItems.isEmpty && model.history.listLoading {
      VStack(spacing: 10) {
        ProgressView().controlSize(.small)
        Text("正在读取记录…").foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("bestASR.history.loading")
    } else if model.history.historyItems.isEmpty, let error = model.history.listErrorMessage {
      VStack(spacing: 12) {
        Label("无法读取记录", systemImage: "exclamationmark.triangle")
        Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
        Button("重新载入") { model.applyHistoryFilters() }
          .accessibilityIdentifier("bestASR.history.retryQuery")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.history.historyItems.isEmpty {
      ContentUnavailableView(
        historyHasFilters ? "没有匹配的记录" : "还没有记录",
        systemImage: historyHasFilters ? "magnifyingglass" : "text.cursor",
        description: Text(
          historyHasFilters
            ? "换个关键词或放宽筛选条件。"
            : "在任何 App 里按住 \(model.hotkeys.startEndHotkeyBinding.isFunctionAlone ? "fn" : model.startEndShortcutTitle) 说话，结果会出现在这里。"
        )
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityIdentifier("bestASR.history.empty")
    } else {
      ScrollViewReader { scroller in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(historyDayGroups) { group in
              Section {
                ForEach(group.items) { item in
                  historyListRow(item, focused: historyKeyboardFocus == item.sessionID)
                    .id(item.sessionID)
                  Divider().padding(.leading, 78)
                }
              } header: {
                Text(historyDateTitle(group.date))
                  .font(.system(size: 12, weight: .semibold))
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 4)
                  .padding(.top, 18)
                  .padding(.bottom, 8)
              }
            }
            if !model.history.pagingExhausted && !model.history.listLoading {
              HStack(spacing: 8) {
                Spacer()
                if let error = model.history.pageErrorMessage {
                  Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                  Button("重试") { model.loadMoreHistoryItems() }
                    .accessibilityIdentifier("bestASR.history.retryPage")
                } else if model.history.pageLoading {
                  ProgressView().controlSize(.small)
                  Text("正在载入更早的记录")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                } else {
                  Button("载入更早的记录") { model.loadMoreHistoryItems() }
                    .onAppear { model.loadMoreHistoryItems() }
                }
                Spacer()
              }
              .frame(minHeight: 44)
              .accessibilityIdentifier("bestASR.history.loadMore")
            }
          }
          .padding(.horizontal, 28)
          .padding(.bottom, 28)
        }
        .accessibilityIdentifier("bestASR.history.list")
        .onChange(of: historyKeyboardIndex) { _, _ in
          guard let focus = historyKeyboardFocus else { return }
          withAnimation(.easeOut(duration: 0.12)) {
            scroller.scrollTo(focus, anchor: .center)
          }
        }
      }
    }
  }

  var historyHasFilters: Bool {
    hasActiveHistorySearch || model.history.modeFilter != "all"
      || model.history.dateRangeFilter != "all" || model.history.statusFilter != "all"
      || !model.history.sourceApplicationQuery.isEmpty || model.history.personFilterID != nil
      || model.history.eventFilterID != nil || model.history.durationFilter != "all"
      || model.history.hasSummaryOnly
  }

  @ViewBuilder
  func historyListRow(
    _ item: DictationHistoryItem,
    focused: Bool = false
  ) -> some View {
    let text =
      historySearchSnippet(for: item)
      ?? item.preferredText.flatMap { $0.isEmpty ? nil : $0 }
      ?? DictationAppModel.historyEmptyText(item)
    let hasText = item.preferredText?.isEmpty == false
    return HistoryListRow(
      item: item,
      text: text,
      highlight: hasActiveHistorySearch ? model.history.searchQuery : "",
      focused: focused,
      status: [.completed, .recovered].contains(item.status)
        || DictationAppModel.isSilentDictationFailure(code: item.failureCode)
        ? nil : model.historyStatusTitle(item),
      isPlaying: model.playback.playbackIsPlaying
        && model.history.selectedHistorySessionID == item.sessionID,
      onOpen: { openHistoryDetail(item) },
      onCopy: hasText ? { model.copyHistoryItem(item) } : nil,
      onPlay: item.sourceAudioRetained && item.inputMode != .userItem
        ? { model.playHistoryItem(item) } : nil,
      onChangeSource: item.inputMode == .userItem
        ? { model.changeItemSource(item, to: $0) } : nil
    )
  }

  /// Days newest first, each day's records newest first by start time.
  var historyDayGroups: [HistoryDateGroup] {
    Dictionary(grouping: model.history.historyItems) {
      Calendar.current.startOfDay(for: $0.createdAt)
    }
    .map {
      HistoryDateGroup(date: $0.key, items: $0.value.sorted { $0.createdAt > $1.createdAt })
    }
    .sorted { $0.date > $1.date }
  }

  func latestHistoryItem(
    for summary: EventSummary
  ) -> DictationHistoryItem? {
    let sessionIDs = Set(summary.sessionIDs)
    return model.history.eventAvailableHistoryItems
      .filter { sessionIDs.contains($0.sessionID) }
      .max { $0.createdAt < $1.createdAt }
  }

  var hasActiveHistorySearch: Bool {
    !model.history.searchQuery.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).isEmpty
  }

  /// The record the arrow keys are currently on.
  var historyKeyboardFocus: SessionID? {
    guard let index = historyKeyboardIndex,
      model.history.historyItems.indices.contains(index)
    else { return nil }
    return model.history.historyItems[index].sessionID
  }

  /// Moves the keyboard through the results in the order they are shown.
  func moveHistoryFocus(by offset: Int) {
    guard !model.history.historyItems.isEmpty else { return }
    let next = (historyKeyboardIndex ?? -1) + offset
    historyKeyboardIndex = min(max(0, next), model.history.historyItems.count - 1)
  }

  /// Return opens whichever result the keyboard is on, or the first one when
  /// the user has typed a query and pressed Return without looking down.
  func openFocusedHistoryResult() {
    if model.history.listLoading
      || (model.history.repository != nil
        && model.history.presentedQuery != model.history.currentQuery)
      || model.history.listErrorMessage != nil
    {
      historyKeyboardIndex = nil
      historyWorkspaceTab = .transcript
      historyFocusedField = nil
      model.openFirstHistorySearchResult()
      return
    }
    let index = historyKeyboardIndex ?? 0
    guard model.history.historyItems.indices.contains(index) else { return }
    openHistoryDetail(model.history.historyItems[index])
  }

  func historySearchSnippet(
    for item: DictationHistoryItem
  ) -> String? {
    guard hasActiveHistorySearch else { return nil }
    return DictationAppModel.historySearchSnippet(
      text: item.preferredText,
      query: model.history.searchQuery
    )
  }

  var activeHistorySegmentID: UUID? {
    guard !model.playback.playbackTrackIDs.isEmpty,
      let transcript = model.selectedHistoryTimestampedTranscript
    else { return nil }
    return transcript.segments.first(where: { segment in
      let start =
        model.historyPlaybackPosition(
          forMonotonicNanoseconds: segment.monotonicStartNanoseconds
        ) ?? -1
      let end =
        model.historyPlaybackPosition(
          forMonotonicNanoseconds: segment.monotonicEndNanoseconds
        ) ?? start
      return model.playback.playbackPosition >= start
        && model.playback.playbackPosition < max(start + 0.05, end)
    })?.id
  }

}
