import BestASRMemory
import MindloomDesign
import SwiftUI

// OWNER: mac-home. S1–S4 (MAC-SPEC §4.1–§4.4).

/// Home's input: which lens the toolbar picked.
public struct HomePageInput: Equatable, Sendable {
  public let lens: MemoryHomeLens

  public init(lens: MemoryHomeLens) { self.lens = lens }
}

/// Home (S1–S4): the date title 「9月20日 周日」, the offline line
/// (`state.link`), then the lens: 按时间 (`HomeTimeView`, with 「刚收进来」),
/// 按截止 (`HomeDeadlineView`), 按人 (`HomePeopleView`); or the empty state
/// (`HomeEmptyView`) when there is no matter yet.
public struct HomePage: View {
  let context: MindloomPageContext
  let input: HomePageInput

  public init(context: MindloomPageContext, input: HomePageInput) {
    self.context = context
    self.input = input
  }

  public var body: some View {
    let state = context.state
    MindloomPageScroll(key: context.navigation.scrollKey) {
      VStack(alignment: .leading, spacing: 0) {
        Text(MindloomDates.dayTitle(state.now, calendar: state.calendar))
          .mlFont(\.title)
          .foregroundStyle(MLColor.ink)
          .padding(.top, 10)
          .accessibilityAddTraits(.isHeader)
        if state.link.showsNotConnected {
          HomeOfflineLine(context: context)
        }
        if input.lens == .people {
          // People have a page before any matter holds them (a voice heard
          // here, the DGX Spark not connected yet).
          HomePeopleView(context: context)
        } else if state.digest?.matters.isEmpty ?? true {
          HomeEmptyView(context: context)
        } else {
          switch input.lens {
          case .time, .people:
            HomeTimeView(
              context: context,
              input: HomeListInput(
                matters: state.digest?.matters ?? [], showsCaptures: true,
                sharedBy: [:],
                selectedEventID: state.homeExtras.menuEventID))
          case .deadlines:
            HomeDeadlineView(context: context, input: HomeDeadlineInput(eventIDs: nil))
          }
        }
      }
    }
    .onAppear { context.actions.refresh() }
  }
}

/// A list of matters as 按时间 lays them out (Home, a group, a space).
public struct HomeListInput: Equatable, Sendable {
  /// The matters, in the organizer's order (the view groups and sorts).
  public let matters: [MatterDigest]
  /// Show 「刚收进来」 above the axis (Home only).
  public let showsCaptures: Bool
  /// Event ID → the member who shared it (row prefix 「{name}共享 · 」).
  public let sharedBy: [String: String]
  /// The row whose menu is open (tinted).
  public var selectedEventID: String?

  public init(
    matters: [MatterDigest], showsCaptures: Bool, sharedBy: [String: String],
    selectedEventID: String? = nil
  ) {
    self.matters = matters
    self.showsCaptures = showsCaptures
    self.sharedBy = sharedBy
    self.selectedEventID = selectedEventID
  }
}
