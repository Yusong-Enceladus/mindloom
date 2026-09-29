import BestASRMemory
import SwiftUI

/// A large circle, the name editable in place, yes/no review rows, and the
/// events they are in, newest first.
struct PersonPage: View {
  @Environment(\.zhiji) private var palette
  let personID: String
  let state: MemoryScreenState
  let actions: MemoryActions
  let back: () -> Void
  let open: (MemoryRoute) -> Void
  /// Opens a matter with these rows expanded (as Home's milestones do).
  var openAt: (_ eventID: String, _ rows: [String]) -> Void = { _, _ in }

  var body: some View {
    VStack(spacing: 0) {
      BackBar(title: ZhijiCopy.back, action: back)
      if let person = state.person(personID) {
        ZhijiScroll {
          HStack {
            Spacer(minLength: 24)
            content(person).frame(maxWidth: ZhijiMetrics.column)
            Spacer(minLength: 24)
          }
        }
      } else {
        Spacer()
      }
    }
  }

  private func content(_ person: MemoryPersonEntry) -> some View {
    VStack(alignment: .leading, spacing: 28) {
      HStack(spacing: 22) {
        Avatar(person, size: 96)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          InPlaceText(
            text: person.isNamed ? person.name : "",
            font: .zhiji(ZhijiMetrics.homeTitle, .bold), placeholder: ZhijiCopy.nameSomeone
          ) { actions.namePerson(person.personID, $0) }
          .accessibilityIdentifier("bestASR.memory.personName")
          Text(meta(person))
            .font(.zhiji(12))
            .monospacedDigit()
            .foregroundStyle(palette.secondary)
          if hasVoice(person) {
            Button {
              actions.playPersonSample(person.personID)
            } label: {
              HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.system(size: 9))
                Text(ZhijiCopy.listen).font(.zhiji(12))
              }
              .foregroundStyle(palette.label)
              .padding(.horizontal, 12)
              .frame(height: 28)
              .background(palette.surface, in: Capsule())
              .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
          }
        }
      }
      let reviews = state.personReviews[person.personID.uppercased()] ?? []
      if !reviews.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text(ZhijiCopy.reviewTitle)
            .font(.zhiji(13, .semibold))
            .foregroundStyle(palette.secondary)
          ForEach(reviews) { review in
            ReviewRow(review: review, actions: actions)
          }
        }
      }
      let quotes = state.projection.map { PersonQuotes.quotes(of: person, in: $0) } ?? []
      if !quotes.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          Text(ZhijiCopy.theirWords)
            .font(.zhiji(13, .semibold))
            .foregroundStyle(palette.secondary)
          PersonQuotesList(
            quotes: quotes, colorIndex: person.colorIndex, state: state, openAt: openAt)
        }
      }
      if !person.events.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          Text(ZhijiCopy.theirEvents)
            .font(.zhiji(13, .semibold))
            .foregroundStyle(palette.secondary)
          CompactEventGrid(entries: newestFirst(person.events), state: state, open: open)
        }
      }
    }
    .padding(.top, 36)
    .padding(.bottom, 40)
  }

  private func meta(_ person: MemoryPersonEntry) -> String {
    var parts = [ZhijiCopy.appearsIn(person.events.count)]
    if let seen = person.lastSeen { parts.append(ZhijiCopy.lastSeen(state.day(seen))) }
    return parts.joined(separator: " · ")
  }

  /// A recording where they speak is held on this Mac.
  private func hasVoice(_ person: MemoryPersonEntry) -> Bool {
    guard let projection = state.projection else { return false }
    return person.events.contains { entry in
      (projection.event(id: entry.eventID)?.items ?? []).contains { item in
        item.playbackAvailable
          && (item.record?.people.contains {
            $0.id.rawValue.uuidString.caseInsensitiveCompare(person.personID) == .orderedSame
          } ?? false)
      }
    }
  }

  private func newestFirst(_ entries: [MemoryHomeEntry]) -> [MemoryHomeEntry] {
    entries.enumerated().sorted {
      let left = $0.element.span?.end ?? $0.element.lastUpdate ?? .distantPast
      let right = $1.element.span?.end ?? $1.element.lastUpdate ?? .distantPast
      return left != right ? left > right : $0.offset < $1.offset
    }.map(\.element)
  }
}

/// "这段声音是王姐吗？" with a play button and 是 / 不是.
struct ReviewRow: View {
  @Environment(\.zhiji) private var palette
  let review: MemoryPersonReview
  let actions: MemoryActions

  var body: some View {
    HStack(spacing: 12) {
      if let itemID = review.itemID {
        Button {
          // Their own stretch of the recording, not its start.
          if let start = review.startNanoseconds, let end = review.endNanoseconds {
            actions.playRange(itemID, start, end)
          } else {
            actions.play(itemID)
          }
        } label: {
          Image(systemName: "play.fill")
            .font(.system(size: 10))
            .foregroundStyle(palette.label)
            .frame(width: 32, height: 32)
            .background(palette.isDark ? palette.bg : .white, in: Circle())
            .overlay(Circle().strokeBorder(palette.separator.opacity(0.8)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ZhijiCopy.play)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(review.prompt).font(.zhiji(13)).foregroundStyle(palette.label)
        if !review.meta.isEmpty {
          Text(review.meta).metaStyle(palette).lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      YesNoButtons { actions.answerReview(review, $0) }
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

/// Two columns of compact cards (84×64 cover).
struct CompactEventGrid: View {
  let entries: [MemoryHomeEntry]
  let state: MemoryScreenState
  let open: (MemoryRoute) -> Void

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
      alignment: .leading, spacing: 16
    ) {
      ForEach(entries) { entry in
        CompactEventCard(entry: entry, state: state) { open(.event(entry.eventID)) }
      }
    }
  }
}

struct CompactEventCard: View {
  @Environment(\.zhiji) private var palette
  let entry: MemoryHomeEntry
  let state: MemoryScreenState
  let open: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      CardCover(entry: entry, state: state, height: 64, radius: ZhijiMetrics.visualRadius, compact: true)
        .frame(width: 84)
      VStack(alignment: .leading, spacing: 3) {
        Text(entry.title).font(.zhiji(14, .semibold)).foregroundStyle(palette.label).lineLimit(1)
        if let status = entry.realStatus {
          Text(status)
            .font(.zhiji(12))
            .foregroundStyle(palette.label)
            .lineLimit(1)
        }
        Text(entry.metaLine(state)).metaStyle(palette)
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .overlay(
      RoundedRectangle(cornerRadius: ZhijiMetrics.cardRadius, style: .continuous)
        .strokeBorder(palette.separator.opacity(0.8))
    )
    .zhijiActivatable(open)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(entry.accessibilitySummary(state))
    .accessibilityAddTraits(.isButton)
  }
}

/// 人物: everyone seen in an event, most recent first. Laid out like Home:
/// the 56 pt header bar, then a 26 pt title and the grid.
struct PeopleIndexPage: View {
  @Environment(\.zhiji) private var palette
  let state: MemoryScreenState
  let actions: MemoryActions
  let open: (MemoryRoute) -> Void

  var body: some View {
    VStack(spacing: 0) {
      Color.clear.pageHeader(palette, horizontalPadding: 32)
      ZhijiScroll {
        VStack(alignment: .leading, spacing: 22) {
          Text(ZhijiCopy.peopleTitle)
            .font(.zhiji(ZhijiMetrics.homeTitle, .bold))
            .foregroundStyle(palette.label)
          if !state.isLoaded {
            EmptyView()
          } else if state.recentPeople.isEmpty {
            Text(ZhijiCopy.noPeople).font(.zhiji(13)).foregroundStyle(palette.secondary)
          } else {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 84), spacing: 12)], alignment: .leading,
              spacing: 22
            ) {
              ForEach(state.recentPeople) { person in
                Button {
                  open(.person(person.personID))
                } label: {
                  VStack(spacing: 6) {
                    Avatar(person, size: 56)
                      .accessibilityHidden(true)
                    Text(person.isNamed ? person.name : ZhijiCopy.nameSomeone)
                      .font(.zhiji(12))
                      .foregroundStyle(person.isNamed ? palette.label : palette.secondary)
                      .lineLimit(1)
                  }
                  .frame(width: 84)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(person.isNamed ? "" : ZhijiCopy.appearsIn(person.events.count))
              }
            }
          }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .onAppear { actions.refresh() }
  }
}
