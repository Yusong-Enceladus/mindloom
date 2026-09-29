import BestASRDomain
import BestASRPersistence
import CryptoKit
import Foundation
import NaturalLanguage

struct LocalAutomaticEventLink: Equatable, Sendable {
  let sessionID: SessionID
  let eventID: EventID
  let evidence: EventLinkEvidence
}

struct LocalEventOrganizationResult: Equatable, Sendable {
  let automaticLinks: [LocalAutomaticEventLink]
  let candidates: [EventCandidate]
}

/// Converts local session evidence into conservative event proposals. All text
/// stays in this process and is evaluated with Apple's on-device Natural
/// Language embeddings; a deterministic lexical fallback keeps the feature
/// usable when a language embedding is unavailable.
actor LocalEventOrganizer {
  static let modelIdentifier = "apple-natural-language-event-v2-source-anchors"

  private static let genericEventTitles: Set<String> = [
    "口述", "线下录音", "电脑内录", "导入文件", "本地记录",
  ]
  private static let chineseTopicStopWords: Set<String> = [
    "一个", "一些", "一下", "不是", "东西", "但是", "为什么", "为了", "主要",
    "什么", "他们", "以及", "你们", "其实", "关于", "可能", "可以", "哪个",
    "哪些", "因为", "如何", "如果", "就是", "已经", "希望", "应该", "怎么",
    "我们", "所以", "所有", "比较", "然后", "现在", "用户", "的话", "这个",
    "这些", "进行", "还是", "那个", "那些", "需要", "非常", "问题", "想要",
    "想", "要", "觉得", "感觉", "尝试", "开始", "出在", "相关", "方面", "讨论",
    "一下子", "那么", "这么", "还有", "没有", "自己", "能够", "会有", "其他",
    "好的", "谢谢", "明白", "继续", "今天", "明天", "昨天",
  ]
  private static let englishTopicStopWords: Set<String> = [
    "a", "about", "after", "again", "all", "also", "an", "and", "any", "are",
    "as", "at", "be", "because", "been", "before", "but", "by", "can", "could",
    "did", "do", "does", "for", "from", "had", "has", "have", "how", "i", "if",
    "in", "into", "is", "it", "just", "like", "maybe", "more", "my", "need", "of",
    "on", "or", "our", "really", "should", "so", "some", "that", "the", "their",
    "them", "then", "there", "these", "they", "this", "those", "to", "try", "up",
    "us", "want", "was", "we", "were", "what", "when", "where", "which", "who",
    "why", "will", "with", "would", "you", "your",
    "okay", "thanks", "today", "tomorrow", "yesterday",
  ]

  private struct NewEventClusterSeed {
    let proposedTitle: String
    let evidence: EventLinkEvidence
  }

  private struct SemanticRepresentation {
    let tokens: Set<String>
    let topicTerms: Set<String>
    let chineseVector: [Double]?
    let englishVector: [Double]?
  }

  func organize(
    sessions: [EventOrganizationSession],
    events: [EventSummary],
    now: Date = Date()
  ) -> LocalEventOrganizationResult {
    let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionID, $0) })
    let semanticsBySessionID = Dictionary(
      uniqueKeysWithValues: sessions.map {
        let source = $0.semanticText.isEmpty ? $0.title : $0.semanticText
        return ($0.sessionID, Self.semanticRepresentation(source))
      })
    let membersByEvent = Dictionary(
      uniqueKeysWithValues: events.map { event in
        (
          event.id,
          event.sessionIDs.compactMap { byID[$0] }
        )
      })
    let newEventClusterSeeds = Self.newEventClusterSeeds(
      sessions: sessions,
      semanticsBySessionID: semanticsBySessionID,
      now: now
    )
    var automaticLinks: [LocalAutomaticEventLink] = []
    var candidates: [EventCandidate] = []

    for session in sessions {
      guard let sessionSemantics = semanticsBySessionID[session.sessionID] else {
        continue
      }
      let scored = events.compactMap { event -> (EventSummary, EventLinkEvidence)? in
        guard !session.currentEventIDs.contains(event.id),
          !session.rejectedEventIDs.contains(event.id)
        else { return nil }
        let members = membersByEvent[event.id] ?? []
        guard !members.isEmpty else { return nil }
        // A title, a generic short utterance, or an uncalibrated embedding
        // cosine is not enough to propose that two recordings are one event.
        // Require corroborating topic anchors in retained source content.
        let supportedMembers = members.compactMap { member -> Double? in
          guard let representation = semanticsBySessionID[member.sessionID],
            Self.hasTopicEvidence(sessionSemantics, representation)
          else { return nil }
          return Self.semanticSimilarity(sessionSemantics, representation)
        }
        guard let semantic = supportedMembers.max() else { return nil }
        let people = Self.jaccard(
          session.personIDs,
          Set(members.flatMap(\.personIDs))
        )
        let temporal = Self.temporalScore(
          date: session.createdAt,
          start: event.event.startAt,
          end: event.event.endAt
        )
        let source = members.map { Self.sourceScore(session, $0) }.max() ?? 0
        let aggregate = min(
          1,
          0.65 * semantic + 0.15 * people + 0.15 * temporal + 0.05 * source
        )
        return (
          event,
          EventLinkEvidence(
            semanticScore: semantic,
            temporalScore: temporal,
            peopleScore: people,
            sourceScore: source,
            aggregateScore: aggregate,
            modelIdentifier: Self.modelIdentifier,
            evaluatedAt: now
          )
        )
      }.sorted { $0.1.aggregateScore > $1.1.aggregateScore }

      if let best = scored.first,
        best.1.aggregateScore >= 0.94,
        best.1.semanticScore >= 0.90,
        best.1.peopleScore >= 0.5
          || best.1.sourceScore == 1
          || best.1.temporalScore == 1
      {
        automaticLinks.append(
          LocalAutomaticEventLink(
            sessionID: session.sessionID,
            eventID: best.0.id,
            evidence: best.1
          )
        )
        continue
      }

      let candidateEvent = scored.first.flatMap { pair in
        pair.1.aggregateScore >= 0.62 && pair.1.semanticScore >= 0.52
          ? pair : nil
      }
      guard candidateEvent != nil || newEventClusterSeeds[session.sessionID] != nil else {
        continue
      }
      let newEventSeed = newEventClusterSeeds[session.sessionID]
      let evidence = candidateEvent?.1 ?? newEventSeed!.evidence
      let targetID = candidateEvent?.0.id
      candidates.append(
        EventCandidate(
          id: EventCandidateID(
            Self.deterministicUUID(
              "event-candidate-v1|\(session.sessionID.rawValue.uuidString.lowercased())|\(targetID?.rawValue.uuidString.lowercased() ?? "new")"
            )
          ),
          sessionID: session.sessionID,
          candidateEventID: targetID,
          proposedTitle: targetID == nil
            ? newEventSeed!.proposedTitle
            : candidateEvent!.0.event.title,
          evidence: evidence,
          createdAt: now,
          updatedAt: now
        )
      )
    }
    return LocalEventOrganizationResult(
      automaticLinks: automaticLinks,
      candidates: candidates
    )
  }

  /// A new event is suggested only when at least two unassigned recordings
  /// form a corroborated semantic cluster. A single unrelated recording is
  /// still searchable in Library, but it does not create review noise merely
  /// because it has not been put into an event yet.
  private static func newEventClusterSeeds(
    sessions: [EventOrganizationSession],
    semanticsBySessionID: [SessionID: SemanticRepresentation],
    now: Date
  ) -> [SessionID: NewEventClusterSeed] {
    let unassigned = sessions.filter(\.currentEventIDs.isEmpty).sorted {
      if $0.createdAt == $1.createdAt {
        return $0.sessionID.rawValue.uuidString < $1.sessionID.rawValue.uuidString
      }
      return $0.createdAt < $1.createdAt
    }
    guard unassigned.count >= 2 else { return [:] }

    var adjacency: [SessionID: [(sessionID: SessionID, evidence: EventLinkEvidence)]] =
      [:]
    let maximumPairDistance: TimeInterval = 30 * 24 * 60 * 60
    for leftIndex in unassigned.indices {
      let left = unassigned[leftIndex]
      guard let leftSemantics = semanticsBySessionID[left.sessionID] else { continue }
      var rightIndex = leftIndex + 1
      while rightIndex < unassigned.endIndex {
        let right = unassigned[rightIndex]
        if right.createdAt.timeIntervalSince(left.createdAt) > maximumPairDistance {
          break
        }
        defer { rightIndex += 1 }
        guard let rightSemantics = semanticsBySessionID[right.sessionID],
          hasTopicEvidence(leftSemantics, rightSemantics)
        else { continue }
        let evidence = relationshipEvidence(
          left,
          leftSemantics: leftSemantics,
          right,
          rightSemantics: rightSemantics,
          now: now
        )
        let corroborated =
          evidence.peopleScore >= 0.5
          || evidence.sourceScore >= 0.85
          || evidence.temporalScore >= 0.65
        guard evidence.semanticScore >= 0.58,
          evidence.aggregateScore >= 0.66,
          corroborated
        else { continue }
        adjacency[left.sessionID, default: []].append((right.sessionID, evidence))
        adjacency[right.sessionID, default: []].append((left.sessionID, evidence))
      }
    }

    var visited: Set<SessionID> = []
    var seeds: [SessionID: NewEventClusterSeed] = [:]
    let sessionByID = Dictionary(
      uniqueKeysWithValues: unassigned.map { ($0.sessionID, $0) }
    )
    for session in unassigned where !visited.contains(session.sessionID) {
      var component: [SessionID] = []
      var queue = [session.sessionID]
      visited.insert(session.sessionID)
      while let current = queue.popLast() {
        component.append(current)
        for neighbor in adjacency[current, default: []].map(\.sessionID)
        where visited.insert(neighbor).inserted {
          queue.append(neighbor)
        }
      }
      guard component.count >= 2,
        let seedID = component.min(by: {
          $0.rawValue.uuidString < $1.rawValue.uuidString
        })
      else { continue }
      let strongestEvidence = adjacency[seedID, default: []]
        .filter { component.contains($0.sessionID) }
        .max(by: { $0.evidence.aggregateScore < $1.evidence.aggregateScore })?
        .evidence
      guard let strongestEvidence else { continue }
      let titleSource = component.compactMap { sessionByID[$0] }.min {
        $0.createdAt < $1.createdAt
      }
      guard let titleSource else { continue }
      let relatedSessions = component.compactMap { sessionByID[$0] }
      seeds[seedID] = NewEventClusterSeed(
        proposedTitle: proposedTitle(
          for: titleSource,
          relatedSessions: relatedSessions
        ),
        evidence: strongestEvidence
      )
    }
    return seeds
  }

  private static func relationshipEvidence(
    _ left: EventOrganizationSession,
    leftSemantics: SemanticRepresentation,
    _ right: EventOrganizationSession,
    rightSemantics: SemanticRepresentation,
    now: Date
  ) -> EventLinkEvidence {
    let semantic = semanticSimilarity(leftSemantics, rightSemantics)
    let people = jaccard(left.personIDs, right.personIDs)
    let temporal = temporalScore(
      date: left.createdAt,
      start: min(right.createdAt, right.updatedAt),
      end: max(right.createdAt, right.updatedAt)
    )
    let source = sourceScore(left, right)
    return EventLinkEvidence(
      semanticScore: semantic,
      temporalScore: temporal,
      peopleScore: people,
      sourceScore: source,
      aggregateScore: min(
        1,
        0.65 * semantic + 0.15 * people + 0.15 * temporal + 0.05 * source
      ),
      modelIdentifier: modelIdentifier,
      evaluatedAt: now
    )
  }

  private static func semanticRepresentation(
    _ text: String
  ) -> SemanticRepresentation {
    let normalized = normalizedText(text)
    guard !normalized.isEmpty else {
      return SemanticRepresentation(
        tokens: [],
        topicTerms: [],
        chineseVector: nil,
        englishVector: nil
      )
    }
    let hasHan = containsHan(normalized)
    let hasLatin = normalized.unicodeScalars.contains {
      (0x0041...0x005A).contains($0.value)
        || (0x0061...0x007A).contains($0.value)
    }
    return SemanticRepresentation(
      tokens: tokens(normalized),
      topicTerms: Set(topicTokens(normalized).map(normalizedText)),
      chineseVector: hasHan
        ? pooledEmbedding(normalized, language: .simplifiedChinese) : nil,
      englishVector: hasLatin || !hasHan
        ? pooledEmbedding(normalized, language: .english) : nil
    )
  }

  /// Every semantic chunk contributes to a mean vector. This keeps long
  /// recordings from being classified solely from their opening paragraph.
  /// Apple's sentence embeddings are backed by on-demand linguistic assets,
  /// and every `sentenceEmbedding(for:)` goes back to the asset framework to
  /// find them. Organizing history called it once per chunk per session —
  /// thousands of times — and the asset lookups it triggered emitted around
  /// nineteen thousand log lines per ten minutes, which buried this app's own
  /// diagnostics in `log show` and made two insertion failures much harder to
  /// diagnose than they needed to be. The model is immutable once loaded, so
  /// it is loaded once per language.
  private final class EmbeddingCache: @unchecked Sendable {
    private let lock = NSLock()
    private var byLanguage: [String: NLEmbedding] = [:]

    func embedding(for language: NLLanguage) -> NLEmbedding? {
      lock.lock()
      defer { lock.unlock() }
      if let cached = byLanguage[language.rawValue] { return cached }
      guard let loaded = NLEmbedding.sentenceEmbedding(for: language) else {
        return nil
      }
      byLanguage[language.rawValue] = loaded
      return loaded
    }
  }

  private static let embeddingCache = EmbeddingCache()

  private static func sentenceEmbedding(for language: NLLanguage) -> NLEmbedding? {
    embeddingCache.embedding(for: language)
  }

  private static func pooledEmbedding(
    _ text: String,
    language: NLLanguage
  ) -> [Double]? {
    guard let embedding = sentenceEmbedding(for: language) else {
      return nil
    }
    var total: [Double] = []
    var vectorCount = 0
    for chunk in semanticChunks(text, maximumCharacters: 1_000) {
      guard let vector = embedding.vector(for: chunk), !vector.isEmpty else {
        continue
      }
      if total.isEmpty { total = Array(repeating: 0, count: vector.count) }
      guard total.count == vector.count else { continue }
      for index in vector.indices { total[index] += vector[index] }
      vectorCount += 1
    }
    guard vectorCount > 0 else { return nil }
    for index in total.indices { total[index] /= Double(vectorCount) }
    let norm = total.reduce(0) { $0 + $1 * $1 }.squareRoot()
    guard norm > 0 else { return nil }
    return total.map { $0 / norm }
  }

  private static func semanticChunks(
    _ text: String,
    maximumCharacters: Int
  ) -> [String] {
    guard maximumCharacters > 0, !text.isEmpty else { return [] }
    var result: [String] = []
    var current = ""
    var currentCount = 0
    current.reserveCapacity(maximumCharacters)
    for character in text {
      if currentCount >= maximumCharacters {
        result.append(current)
        current = ""
        currentCount = 0
      }
      current.append(character)
      currentCount += 1
    }
    if !current.isEmpty { result.append(current) }
    return result
  }

  private static func semanticSimilarity(
    _ left: SemanticRepresentation,
    _ right: SemanticRepresentation
  ) -> Double {
    guard !left.tokens.isEmpty, !right.tokens.isEmpty else { return 0 }
    let lexical = lexicalSimilarity(left.tokens, right.tokens)
    let vectorScores = [
      cosineSimilarity(left.chineseVector, right.chineseVector),
      cosineSimilarity(left.englishVector, right.englishVector),
    ].compactMap { $0 }
    return min(1, max(lexical, vectorScores.max() ?? 0))
  }

  private static func hasTopicEvidence(
    _ left: SemanticRepresentation,
    _ right: SemanticRepresentation
  ) -> Bool {
    left.topicTerms.intersection(right.topicTerms).count >= 2
  }

  private static func cosineSimilarity(
    _ left: [Double]?,
    _ right: [Double]?
  ) -> Double? {
    guard let left, let right, left.count == right.count, !left.isEmpty else {
      return nil
    }
    var dot = 0.0
    for index in left.indices { dot += left[index] * right[index] }
    return max(0, dot)
  }

  private static func lexicalSimilarity(
    _ leftTokens: Set<String>,
    _ rightTokens: Set<String>
  ) -> Double {
    let intersection = leftTokens.intersection(rightTokens).count
    let union = leftTokens.union(rightTokens).count
    return union == 0 ? 0 : Double(intersection) / Double(union)
  }

  private static func tokens(_ text: String) -> Set<String> {
    if containsHan(text) {
      let characters = Array(text.filter { !$0.isWhitespace && !$0.isPunctuation })
      guard characters.count >= 2 else { return Set([String(characters)]) }
      return Set(
        (0..<(characters.count - 1)).map {
          String(characters[$0...($0 + 1)])
        })
    }
    return Set(
      text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map { String($0).lowercased() }
        .filter { $0.count > 1 }
    )
  }

  private static func normalizedText(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func containsHan(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      (0x3400...0x9FFF).contains(scalar.value)
    }
  }

  private static func temporalScore(date: Date, start: Date, end: Date) -> Double {
    if (start...end).contains(date) { return 1 }
    let distance = min(abs(date.timeIntervalSince(start)), abs(date.timeIntervalSince(end)))
    return switch distance {
    case ..<(24 * 60 * 60): 1
    case ..<(7 * 24 * 60 * 60): 0.65
    case ..<(30 * 24 * 60 * 60): 0.25
    default: 0
    }
  }

  private static func sourceScore(
    _ left: EventOrganizationSession,
    _ right: EventOrganizationSession
  ) -> Double {
    if let leftSource = left.sourceIdentifier, !leftSource.isEmpty,
      leftSource == right.sourceIdentifier
    {
      return 1
    }
    if let leftBundle = left.sourceBundleIdentifier, !leftBundle.isEmpty,
      leftBundle == right.sourceBundleIdentifier
    {
      return 0.85
    }
    return left.inputMode == right.inputMode ? 0.4 : 0
  }

  private static func jaccard<T: Hashable>(_ left: Set<T>, _ right: Set<T>) -> Double {
    guard !left.isEmpty, !right.isEmpty else { return 0 }
    return Double(left.intersection(right).count) / Double(left.union(right).count)
  }

  static func proposedTitle(
    for session: EventOrganizationSession,
    relatedSessions: [EventOrganizationSession] = []
  ) -> String {
    let title = normalizedDisplayTitle(session.title)
    if isConciseEventTitle(title) { return title }

    let sessions = ([session] + relatedSessions)
      .reduce(into: [SessionID: EventOrganizationSession]()) {
        $0[$1.sessionID] = $1
      }
      .values
      .sorted {
        if $0.createdAt == $1.createdAt {
          return $0.sessionID.rawValue.uuidString < $1.sessionID.rawValue.uuidString
        }
        return $0.createdAt < $1.createdAt
      }
    if let topic = extractedTopicTitle(from: sessions) { return topic }
    return fallbackEventTitle(for: session)
  }

  private static func isConciseEventTitle(_ title: String) -> Bool {
    guard !title.isEmpty, !genericEventTitles.contains(title) else { return false }
    guard title.rangeOfCharacter(from: CharacterSet(charactersIn: "。！？!?\n")) == nil
    else { return false }
    if containsHan(title) {
      guard title.count <= 24, !title.contains("，") else { return false }
      let conversationalMarkers = [
        "我想", "我觉得", "我们", "这个", "那个", "就是", "然后", "怎么", "但是",
        "所以", "一下", "问题是", "主要是",
      ]
      return conversationalMarkers.filter(title.contains).count < 2
    }
    let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    return title.count <= 72 && words.count <= 10
  }

  private static func extractedTopicTitle(
    from sessions: [EventOrganizationSession]
  ) -> String? {
    guard !sessions.isEmpty else { return nil }
    var displayByToken: [String: String] = [:]
    var firstOrder: [String: Int] = [:]
    var documentFrequency: [String: Int] = [:]
    var totalFrequency: [String: Int] = [:]
    var order = 0
    var containsChinese = false

    for session in sessions {
      let source = session.semanticText.isEmpty ? session.title : session.semanticText
      let tokens = topicTokens(String(source.prefix(1_600)))
      var seenInDocument: Set<String> = []
      for display in tokens {
        let normalized = normalizedText(display)
        guard !normalized.isEmpty else { continue }
        containsChinese = containsChinese || containsHan(display)
        if displayByToken[normalized] == nil {
          displayByToken[normalized] = display
        }
        if firstOrder[normalized] == nil {
          firstOrder[normalized] = order
        }
        totalFrequency[normalized, default: 0] += 1
        if seenInDocument.insert(normalized).inserted {
          documentFrequency[normalized, default: 0] += 1
        }
        order += 1
      }
    }

    let ranked = displayByToken.keys.sorted { left, right in
      let leftDocumentCount = documentFrequency[left, default: 0]
      let rightDocumentCount = documentFrequency[right, default: 0]
      if leftDocumentCount != rightDocumentCount {
        return leftDocumentCount > rightDocumentCount
      }
      let leftTotal = totalFrequency[left, default: 0]
      let rightTotal = totalFrequency[right, default: 0]
      if leftTotal != rightTotal { return leftTotal > rightTotal }
      return firstOrder[left, default: .max] < firstOrder[right, default: .max]
    }
    let maximumTokenCount = containsChinese ? 6 : 7
    let selected = ranked.prefix(maximumTokenCount).sorted {
      firstOrder[$0, default: .max] < firstOrder[$1, default: .max]
    }
    var parts: [String] = []
    var characterCount = 0
    let maximumCharacters = containsChinese ? 18 : 64
    for token in selected.compactMap({ displayByToken[$0] }) {
      let separatorCount = containsChinese || parts.isEmpty ? 0 : 1
      guard characterCount + separatorCount + token.count <= maximumCharacters else {
        continue
      }
      parts.append(token)
      characterCount += separatorCount + token.count
    }
    guard parts.count >= 2 else { return nil }
    return parts.joined(separator: containsChinese ? "" : " ")
  }

  private static func topicTokens(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    let chinese = containsHan(text)
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    tokenizer.setLanguage(chinese ? .simplifiedChinese : .english)
    var result: [String] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      let display = String(text[range]).trimmingCharacters(
        in: .whitespacesAndNewlines.union(.punctuationCharacters)
      )
      let normalized = normalizedText(display)
      guard !normalized.isEmpty else { return true }
      if containsHan(display) {
        guard display.count > 1, !chineseTopicStopWords.contains(normalized) else {
          return true
        }
      } else {
        guard display.count > 1, !englishTopicStopWords.contains(normalized) else {
          return true
        }
      }
      result.append(display)
      return true
    }
    return result
  }

  private static func normalizedDisplayTitle(_ title: String) -> String {
    title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func fallbackEventTitle(
    for session: EventOrganizationSession
  ) -> String {
    let mode =
      switch session.inputMode {
      case "dictation": "口述"
      case "roomMicrophone": "现场录音"
      case "systemAudio": "电脑内录"
      case "fileImport": "文件内容"
      // Pasted or dragged text, screenshots, and documents are organized as
      // text sources; their content is data, never an instruction.
      case "userItem": "收进来的内容"
      default: "语音记录"
      }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.dateFormat = "M月d日"
    return "\(formatter.string(from: session.createdAt))\(mode)"
  }

  private static func deterministicUUID(_ value: String) -> UUID {
    let digest = SHA256.hash(data: Data(value.utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}
