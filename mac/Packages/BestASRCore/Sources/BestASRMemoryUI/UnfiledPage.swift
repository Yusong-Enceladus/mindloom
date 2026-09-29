import BestASRMemory
import SwiftUI

/// Items in no event, by day, each with 放进… and 单独成一件事.
struct UnfiledPage: View {
  @Environment(\.zhiji) private var palette
  let state: MemoryScreenState
  let actions: MemoryActions
  let back: () -> Void
  @Binding var expanded: Set<String>

  var body: some View {
    VStack(spacing: 0) {
      BackBar(title: ZhijiCopy.back, action: back)
      ZhijiScroll {
        HStack {
          Spacer(minLength: 24)
          content.frame(maxWidth: ZhijiMetrics.column)
          Spacer(minLength: 24)
        }
      }
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(ZhijiCopy.unfiledTitle)
        .font(.zhiji(ZhijiMetrics.eventTitle, .semibold))
        .foregroundStyle(palette.label)
      if state.unfiled.isEmpty {
        Text(ZhijiCopy.unfiledEmpty).font(.zhiji(13)).foregroundStyle(palette.secondary)
      }
      ForEach(Array(days.enumerated()), id: \.offset) { _, day in
        VStack(alignment: .leading, spacing: 2) {
          if let date = day.day {
            Text(state.dayHeader(date))
              .font(.zhiji(12, .semibold))
              .foregroundStyle(palette.secondary)
              .padding(.bottom, 6)
          }
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(day.items) { item in
              HStack(alignment: .top, spacing: 8) {
                TimelineRow(
                  item: item, state: state, expanded: expanded.contains(item.itemID),
                  eventID: nil, actions: actions,
                  toggle: {
                    if expanded.contains(item.itemID) {
                      expanded.remove(item.itemID)
                    } else {
                      expanded.insert(item.itemID)
                    }
                  })
                FileButtons(itemID: item.itemID, state: state, actions: actions)
                  .padding(.top, 8)
              }
            }
          }
        }
      }
    }
    .padding(.top, 28)
    .padding(.bottom, 40)
  }

  /// Newest day first; in each day, time order.
  private var days: [MemoryDayGroup] {
    var groups: [MemoryDayGroup] = []
    for entry in state.unfiled {
      let day = entry.item.startedAt.map { state.calendar.startOfDay(for: $0) }
      if let index = groups.firstIndex(where: { $0.day == day }) {
        groups[index].items.append(entry.item)
      } else {
        groups.append(MemoryDayGroup(day: day, items: [entry.item]))
      }
    }
    return groups.map { group in
      var sorted = group
      sorted.items.sort { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
      return sorted
    }
  }
}

/// 放进… (a searchable list of every event) and 单独成一件事, as the same
/// quiet capsules in the App and in a snapshot.
private struct FileButtons: View {
  @Environment(\.zhiji) private var palette
  let itemID: String
  let state: MemoryScreenState
  let actions: MemoryActions
  @State private var picking = false

  var body: some View {
    HStack(spacing: 6) {
      Button {
        picking = true
      } label: {
        label(ZhijiCopy.fileInto)
      }
      .buttonStyle(.plain)
      .disabled(state.home.isEmpty)
      .popover(isPresented: $picking, arrowEdge: .bottom) {
        EventPicker(entries: state.home) { target in
          picking = false
          actions.moveItem(itemID, target, nil, nil)
        }
      }
      Button {
        actions.fileItemNewEvent(itemID)
      } label: {
        label(ZhijiCopy.ownEvent)
      }
      .buttonStyle(.plain)
    }
  }

  private func label(_ title: String) -> some View {
    Text(title)
      .font(.zhiji(12))
      .foregroundStyle(palette.label)
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(palette.selectionFill, in: Capsule())
  }
}
