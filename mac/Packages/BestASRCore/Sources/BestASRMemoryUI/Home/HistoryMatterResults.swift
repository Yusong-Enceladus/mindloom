import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: v12 restore. 历史's 事: one matter the query found (title and the
// line that matched, the hits lit), and the page 「还有 N 件」 opens with all
// of them (B7 设计 5, 8: a list never grows in place and pushes what is below
// it down; review v12-B #15). The back capsule returns to 历史 as it was.

/// One matter found by a query: its title and the line that matched.
struct HistoryMatterRow: View {
  @Environment(\.colorScheme) private var scheme
  let context: MindloomPageContext
  let hit: MemoryHistoryMatter
  let highlights: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HistoryHighlight.text(MLAutospace.apply(hit.title), highlights, scheme: scheme)
        .mlFont(\.headline).foregroundStyle(MLColor.ink)
        .fixedSize(horizontal: false, vertical: true)
      if !hit.why.isEmpty {
        FadingText(
          HistoryHighlight.text(MLAutospace.apply(hit.why), highlights, scheme: scheme),
          fade: 32.5
        )
        .mlFont(\.sub).foregroundStyle(MLColor.ink2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .modifier(HomeRowChrome())
    .padding(.horizontal, -12)
    .onTapGesture { context.navigator.openMatter(hit.eventID) }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { context.navigator.openMatter(hit.eventID) }
  }
}

/// Every matter a query found (「还有 N 件」 on 历史).
struct HistoryMatterResultsPage: View {
  @Environment(\.zhijiSnapshot) private var snapshot
  let context: MindloomPageContext
  let query: String

  private var history: MemoryHistoryState { context.state.history }
  /// The results are this query's (a relaunch or another query runs it again).
  private var current: Bool {
    history.query.trimmingCharacters(in: .whitespacesAndNewlines) == query
  }

  var body: some View {
    MindloomPageScroll(key: context.navigation.scrollKey, maxWidth: 760) {
      LazyVStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("包含“\(query)”的事")
            .mlFont(\.title)
            .foregroundStyle(MLColor.ink)
          if current, !history.matters.isEmpty {
            Text("\(history.matters.count) 件")
              .font(.system(size: 13)).monospacedDigit().foregroundStyle(MLColor.ink3)
          }
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .accessibilityAddTraits(.isHeader)
        if current {
          ForEach(history.matters) { hit in
            HistoryMatterRow(context: context, hit: hit, highlights: history.highlights)
          }
        } else {
          Color.clear.frame(height: 200)
        }
      }
    }
    .task(id: query) {
      guard !snapshot, !current else { return }
      context.actions.searchText(query)
    }
  }
}
