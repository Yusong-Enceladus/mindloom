import EventKit
import Foundation

/// 把下一步加到提醒事项 (V8 contract A5): one reminder, written only when the
/// owner clicks the button on a matter's 下一步. Never automatic; the
/// calendar entry never calls this.
public struct ReminderDraft: Equatable, Sendable {
  public let title: String
  /// The day the next step is due, when it has one.
  public let due: DateComponents?
  public let notes: String

  public init(title: String, due: DateComponents?, notes: String) {
    self.title = title
    self.due = due
    self.notes = notes
  }

  /// The reminder for a matter's next step: its text as the title, its day
  /// as the due date, and where it came from in the notes.
  public static func nextStep(
    text: String, day: Date?, matterTitle: String, calendar: Calendar = .current
  )
    -> ReminderDraft
  {
    let title = text.components(separatedBy: .newlines).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let due = day.map { calendar.dateComponents([.year, .month, .day], from: $0) }
    let matter = matterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return ReminderDraft(
      title: title.isEmpty ? "织机里的下一步" : title, due: due,
      notes: matter.isEmpty ? "来自织机" : "来自织机：\(matter)")
  }
}

public enum ReminderWriteResult: Equatable, Sendable {
  /// Added to a list kept on this Mac only.
  case added(list: String)
  /// Review V8R-18: there was no list on this Mac; added to a list that syncs
  /// (iCloud or another account), so its text leaves the Mac that way.
  case addedSynced(list: String, account: String)
  case denied
  case failed
}

/// Writes reminders. Separate from calendar reading on purpose.
public protocol RemindersWriting: Sendable {
  func add(_ draft: ReminderDraft) async -> ReminderWriteResult
}

/// EventKit: asks for the Reminders permission at the first click, then adds
/// the reminder to a list kept on this Mac when there is one (review V8R-18:
/// the default list is usually iCloud's); else to the default list, and the
/// result says it syncs.
public final class EventKitRemindersWriter: RemindersWriting, @unchecked Sendable {
  private let store = EKEventStore()

  public init() {}

  public func add(_ draft: ReminderDraft) async -> ReminderWriteResult {
    if EKEventStore.authorizationStatus(for: .reminder) != .fullAccess {
      guard (try? await store.requestFullAccessToReminders()) == true else { return .denied }
    }
    let local = store.calendars(for: .reminder).filter {
      $0.allowsContentModifications && $0.source?.sourceType == .local
    }
    let fallback = store.defaultCalendarForNewReminders()
    guard
      let list = ReminderListChoice.pick(
        default: fallback, local: local, isLocal: { $0.source?.sourceType == .local },
        title: \.title)
    else { return .failed }
    let reminder = EKReminder(eventStore: store)
    reminder.title = draft.title
    reminder.notes = draft.notes
    reminder.calendar = list
    if let due = draft.due { reminder.dueDateComponents = due }
    do {
      try store.save(reminder, commit: true)
      return list.source?.sourceType == .local
        ? .added(list: list.title)
        : .addedSynced(list: list.title, account: list.source?.title ?? "账户")
    } catch {
      return .failed
    }
  }
}

/// Which Reminders list a next step goes to (review V8R-18): the default list
/// when it is kept on this Mac, else the first list kept on this Mac, else
/// the default (which syncs; the result says so).
public enum ReminderListChoice {
  public static func pick<List>(
    default fallback: List?, local: [List], isLocal: (List) -> Bool, title: (List) -> String
  ) -> List? {
    if let fallback, isLocal(fallback) { return fallback }
    return local.filter(isLocal).sorted { title($0) < title($1) }.first ?? fallback
  }
}
