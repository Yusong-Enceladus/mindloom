import BestASRDomain
import BestASRMemory
import Foundation
import MindloomDesign

// OWNER: mac-home. The v11 in-memory search (MAC-SPEC §4.11): 人 (up to 4) ·
// 事情 (up to 8) · 原文 (up to 10) over the projection's records. v12 replaced
// it on screen with the 历史 page (`HistoryPage`, the record search index);
// `norm`, `cut` and `hit` are still shared.

struct HomeSearchResults: Equatable {
  struct Person: Equatable, Identifiable {
    let person: MemoryPersonEntry
    /// Their first two matters, autospaced, joined by 「 · 」.
    let matters: String
    var id: String { person.personID }
  }

  struct Matter: Equatable, Identifiable {
    let matter: MatterDigest
    /// The line that matched (organizer text, autospaced unless it is the
    /// people list).
    let why: String
    var id: String { matter.eventID }
  }

  struct Text: Equatable, Identifiable {
    let itemID: String
    /// nil: a waiting capture (「刚收进来」).
    let eventID: String?
    let matterTitle: String?
    let time: Date
    let symbol: String
    let source: String
    /// The line (speaker prefixed), cut to start about 20 characters before
    /// the hit when longer than 90.
    let line: String
    /// The line was cut before its start: its first 2.5 em fade in (§2.3:
    /// never a 「…」).
    var cutBefore = false
    var id: String { itemID + "|" + (eventID ?? "") }
  }

  var people: [Person] = []
  var matters: [Matter] = []
  var texts: [Text] = []

  var isEmpty: Bool { people.isEmpty && matters.isEmpty && texts.isEmpty }
}

enum HomeSearch {
  /// Whitespace (U+2005 included) removed, lower-cased.
  static func norm(_ s: String) -> String {
    String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
      .lowercased()
  }

  static func results(_ query: String, state: MemoryScreenState) -> HomeSearchResults {
    let n = norm(query)
    var out = HomeSearchResults()
    guard !n.isEmpty, let digest = state.digest else { return out }
    // 人
    for person in state.recentPeople.isEmpty ? state.people : state.recentPeople
    where person.isNamed && norm(person.name).contains(n) {
      let titles = person.events.prefix(2).compactMap { digest.matter($0.eventID)?.title ?? $0.title }
      out.people.append(
        .init(person: person, matters: titles.map(MLAutospace.apply).joined(separator: " · ")))
      if out.people.count >= 4 { break }
    }
    // 事情
    for matter in digest.matters {
      // As the prototype's data: at most six people per matter.
      let people = Array(matter.people.map(\.name).prefix(6))
      let all =
        matter.title + matter.status + matter.steps.map(\.text).joined()
        + matter.parts.map(\.name).joined() + people.joined()
      guard norm(all).contains(n) else { continue }
      let why: String
      if norm(matter.title + matter.status).contains(n) {
        why = MLAutospace.apply(matter.status)
      } else if let step = matter.steps.first(where: { norm($0.text).contains(n) }) {
        why = MLAutospace.apply(step.text)
      } else if let part = matter.parts.first(where: { norm($0.name).contains(n) }) {
        why = MLAutospace.apply(part.name)
      } else {
        why = people.joined(separator: "、")
      }
      out.matters.append(.init(matter: matter, why: why))
      if out.matters.count >= 8 { break }
    }
    // 原文
    var seen = Set<String>()
    for capture in state.waitingCaptures where norm(capture.firstLine).contains(n) {
      seen.insert(capture.id.uppercased())
      out.texts.append(
        .init(
          itemID: capture.id, eventID: nil, matterTitle: nil, time: capture.capturedAt,
          symbol: capture.symbol, source: capture.kind, line: cut(capture.firstLine, n),
          cutBefore: isCut(capture.firstLine, n)))
    }
    let records = state.projection?.records ?? [:]
    outer: for matter in digest.matters {
      let items = matter.itemIDs.compactMap { id in records[id.uppercased()] ?? records[id] }
        .sorted { $0.startedAt > $1.startedAt }
      for record in items {
        guard out.texts.count < 200 else { break outer }
        let id = record.sessionID.rawValue.uuidString.uppercased()
        guard !seen.contains(id), let text = record.text ?? record.localReading else { continue }
        guard norm(text).contains(n) else { continue }
        let lines = MemoryQuoteLines.lines(text)
        guard
          let line = lines.first(where: { norm(($0.speaker ?? "") + $0.words).contains(n) })
        else { continue }
        seen.insert(id)
        let speaker = line.speaker.map { name in
          state.ownerNameSet.contains(name) ? "我" : name
        }
        let words = record.inputMode == .dictation ? MemoryQuoteLines.punctuated(line.words) : line.words
        let full = (speaker.map { $0 + "：" } ?? "") + words
        let source = MemoryItemSource.words(record)
        out.texts.append(
          .init(
            itemID: id, eventID: matter.eventID, matterTitle: matter.title, time: record.startedAt,
            symbol: source.symbol, source: source.word, line: cut(full, n),
            cutBefore: isCut(full, n)))
      }
    }
    // Newest first (§4.11), the waiting captures before everything else.
    out.texts = out.texts.enumerated().sorted { a, b in
      let aw = a.element.eventID == nil
      let bw = b.element.eventID == nil
      if aw != bw { return aw }
      if a.element.time != b.element.time { return a.element.time > b.element.time }
      return a.offset < b.offset
    }.prefix(10).map(\.element)
    return out
  }

  /// A long line starts about 20 characters before the hit (§4.11).
  static func cut(_ line: String, _ n: String) -> String {
    let chars = Array(line)
    guard chars.count > 90 else { return line }
    let flat = norm(line)
    guard let hit = flat.range(of: n) else { return line }
    let at = flat.distance(from: flat.startIndex, to: hit.lowerBound)
    guard at > 30 else { return line }
    // Map the position in the flattened text back to the line.
    var count = 0
    var index = 0
    for (i, ch) in chars.enumerated() where !ch.isWhitespace {
      if count == at {
        index = i
        break
      }
      count += 1
    }
    var start = max(0, min(index - 20, chars.count - 90))
    // Never start on the punctuation of the cut (live-mac: 「，但报价单…」);
    // the view fades the first 2.5 em in to say the line goes on before.
    while start < index, chars[start].isWhitespace || chars[start].isPunctuation {
      start += 1
    }
    return start == 0 ? line : String(chars[start...])
  }

  /// Whether `cut` drops the start of the line.
  static func isCut(_ line: String, _ n: String) -> Bool {
    cut(line, n).count < line.count
  }

  /// Ranges of `query` in `text` ignoring whitespace and case (one hit).
  static func hit(_ query: String, in text: String) -> Range<String.Index>? {
    let n = norm(query)
    guard !n.isEmpty else { return nil }
    var map: [String.Index] = []
    var flat = ""
    for index in text.indices where !text[index].isWhitespace {
      map.append(index)
      flat += text[index].lowercased()
    }
    guard let found = flat.range(of: n) else { return nil }
    let a = flat.distance(from: flat.startIndex, to: found.lowerBound)
    let b = flat.distance(from: flat.startIndex, to: found.upperBound) - 1
    guard a < map.count, b < map.count, a <= b else { return nil }
    return map[a]..<text.index(after: map[b])
  }
}

extension MemoryScreenState {
  /// The owner's spellings (for 「我：」 in search lines): the organizer's
  /// owner persons with their aliases.
  var ownerNameSet: Set<String> {
    guard let projection else { return [] }
    let owners = projection.persons.filter {
      projection.ownerPersonIDs.contains($0.personID.uppercased())
    }
    return Set(owners.flatMap { [$0.displayName].compactMap { $0 } + $0.aliases })
  }
}
