import BestASRDomain
import BestASRPersistence
import Foundation

/// What Settings › 口述 › 词典 and 历史's 「添加到词典…」 do to the store
/// (review of 10-6). Recognition reads enabled words only
/// (`dictionaryContext`), and the owner's library came from bestASR with 23
/// of 64 words off: a word the owner edits, or adds a heard form to, is used
/// in dictation again, so 「已添加到词典」 is true. Each word's switch sets it
/// either way.
enum DictionaryWordEditing {
  enum Failure: Error, Equatable {
    /// The word changed or went since the list was read.
    case changed
  }

  /// Changes the word `id` (nil: adds one) to `written`, heard as `heard`,
  /// and turns it on.
  static func save(
    id: UUID?, written: String, heard: [String], in repository: any DictionaryManagementRepository
  ) async throws {
    guard let id else {
      _ = try await repository.createDictionaryEntry(canonicalForm: written, spokenForms: heard)
      return
    }
    guard
      let current = try await repository.allDictionaryEntries().first(where: {
        $0.id.rawValue == id
      })
    else { throw Failure.changed }
    let updated = try await repository.updateDictionaryEntry(
      id: current.id, expectedRevision: current.revision, canonicalForm: written,
      spokenForms: heard)
    try await turnOn(updated, in: repository)
  }

  /// 「添加到词典…」: the word as it should be written gains how it was heard
  /// (a new word when none is written that way), and is used in dictation.
  static func addHeard(
    heard: String, written: String, in repository: any DictionaryManagementRepository
  ) async throws {
    let all = try await repository.allDictionaryEntries()
    let heardForms = heard.isEmpty || heard == written ? [] : [heard]
    guard
      let existing = all.first(where: {
        $0.canonicalForm.compare(written, options: [.caseInsensitive, .widthInsensitive])
          == .orderedSame
      })
    else {
      _ = try await repository.createDictionaryEntry(
        canonicalForm: written, spokenForms: heardForms)
      return
    }
    var spoken = existing.spokenForms
    for form in heardForms
    where !spoken.contains(where: {
      $0.compare(form, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
    }) {
      spoken.append(form)
    }
    var entry = existing
    if spoken != existing.spokenForms {
      entry = try await repository.updateDictionaryEntry(
        id: existing.id, expectedRevision: existing.revision,
        canonicalForm: existing.canonicalForm, spokenForms: spoken)
    }
    try await turnOn(entry, in: repository)
  }

  /// A word's switch.
  static func setEnabled(
    id: UUID, on: Bool, in repository: any DictionaryManagementRepository
  ) async throws {
    guard
      let current = try await repository.allDictionaryEntries().first(where: {
        $0.id.rawValue == id
      })
    else { throw Failure.changed }
    guard current.enabled != on else { return }
    _ = try await repository.setDictionaryEntryEnabled(
      id: current.id, expectedRevision: current.revision, enabled: on)
  }

  private static func turnOn(
    _ entry: DictionaryEntry, in repository: any DictionaryManagementRepository
  ) async throws {
    guard !entry.enabled else { return }
    _ = try await repository.setDictionaryEntryEnabled(
      id: entry.id, expectedRevision: entry.revision, enabled: true)
  }
}
