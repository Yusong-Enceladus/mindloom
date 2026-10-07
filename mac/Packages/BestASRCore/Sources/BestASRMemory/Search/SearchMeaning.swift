import Accelerate
import Foundation

// v12 search (ALIGNMENT 查-3, 查-6; B4 §3.2b, §3.2d): finding records by
// meaning, next to the character search. A record's text is cut into short
// pieces, each piece becomes a vector on this Mac, and a query's vector is
// compared with all of them. The two searches are combined by rank (RRF);
// records that hold every typed word stay ahead of records found only by
// meaning, so a word typed as written is never pushed out (B4 §3.1).
//
// No model SDK here: the vectors come from a `MeaningEmbedding` the App
// injects (an MLX model, a test double).

/// Which side of a search a text is on.
public enum MeaningTextRole: Sendable {
  /// The words typed into the search field (an agent's question).
  case query
  /// A piece of a record.
  case document
}

/// Turns text into unit vectors that lie near each other when the meaning
/// is near. Implementations own their model's memory and threads.
public protocol MeaningEmbedding: Sendable {
  /// Names the model and everything that shapes its vectors (revision,
  /// prompts, dimension). Stored with the index: a change rebuilds it.
  var modelVersion: String { get }
  /// Length of every vector.
  var dimension: Int { get }
  /// One unit vector per text, in order.
  func embed(_ texts: [String], role: MeaningTextRole) async throws -> [[Float]]
  /// Drops the model from memory; the next call loads it again.
  func release() async
}

/// A piece of a record that gets one vector.
public struct MeaningChunk: Equatable, Sendable {
  /// What is embedded.
  public let text: String
  /// Where it starts in the record's text (characters).
  public let start: Int
  public let length: Int

  public init(text: String, start: Int, length: Int) {
    self.text = text
    self.start = start
    self.length = length
  }
}

/// Cuts a record's text into pieces of about one paragraph: a dictation is
/// one piece; a meeting or a document is cut at sentence ends, each piece
/// starting with the last sentence of the one before so a thought that
/// spans the cut is still whole in one of them.
public enum MeaningChunker {
  /// Characters per piece, at most (a sentence longer than this is cut).
  public static let pieceCharacters = 240
  /// A record yields at most this many pieces (about 48,000 characters);
  /// beyond that the character search still finds every word.
  public static let maximumPieces = 200

  public static func chunks(
    of text: String, size: Int = pieceCharacters, maximum: Int = maximumPieces
  ) -> [MeaningChunk] {
    let characters = Array(text)
    guard !characters.isEmpty else { return [] }
    // Sentences: up to and including an end mark or a line break.
    var sentences: [(start: Int, end: Int)] = []
    var start = 0
    for index in characters.indices where endsSentence(characters[index]) {
      if index + 1 > start { sentences.append((start, index + 1)) }
      start = index + 1
    }
    if start < characters.count { sentences.append((start, characters.count)) }
    // Long sentences are cut to `size`.
    var pieces: [(start: Int, end: Int)] = []
    for sentence in sentences {
      var at = sentence.start
      while sentence.end - at > size {
        pieces.append((at, at + size))
        at += size
      }
      pieces.append((at, sentence.end))
    }
    var chunks: [MeaningChunk] = []
    var index = 0
    while index < pieces.count, chunks.count < maximum {
      let first = index
      var end = pieces[index].end
      index += 1
      while index < pieces.count, pieces[index].end - pieces[first].start <= size {
        end = pieces[index].end
        index += 1
      }
      let begin = pieces[first].start
      let raw = String(characters[begin..<end])
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if hasContent(trimmed) {
        chunks.append(MeaningChunk(text: trimmed, start: begin, length: end - begin))
      }
      // The next piece starts with this one's last sentence (when that
      // still leaves room to move on).
      if index < pieces.count, index - first > 1,
        pieces[index].end - pieces[index - 1].start <= size
      {
        index -= 1
      }
    }
    return chunks
  }

  static func endsSentence(_ character: Character) -> Bool {
    character.isNewline || "。！？!?；;…".contains(character)
  }

  /// At least one letter, digit or Han character.
  static func hasContent(_ text: String) -> Bool {
    text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
  }
}

/// Vectors held for search: one row per piece, unit length, compared by
/// dot product (cosine) with Accelerate.
public struct MeaningMatrix: Sendable {
  public let dimension: Int
  /// Row-major, `count × dimension`.
  public let values: [Float]
  /// The record each row belongs to (an index into `owners`).
  public let rowOwner: [Int32]
  public let owners: [String]

  public var count: Int { rowOwner.count }

  public init(dimension: Int, values: [Float], rowOwner: [Int32], owners: [String]) {
    precondition(values.count == rowOwner.count * dimension)
    self.dimension = dimension
    self.values = values
    self.rowOwner = rowOwner
    self.owners = owners
  }

  /// The similarity of every row to `query` (a unit vector).
  public func similarities(_ query: [Float]) -> [Float] {
    guard count > 0, query.count == dimension else { return [] }
    var out = [Float](repeating: 0, count: count)
    values.withUnsafeBufferPointer { matrix in
      query.withUnsafeBufferPointer { vector in
        out.withUnsafeMutableBufferPointer { result in
          vDSP_mmul(
            matrix.baseAddress!, 1, vector.baseAddress!, 1, result.baseAddress!, 1,
            vDSP_Length(count), 1, vDSP_Length(dimension))
        }
      }
    }
    return out
  }

  /// Records by their best piece, most similar first: (owner, similarity,
  /// row of the best piece).
  public func best(
    _ query: [Float], allowed: ((String) -> Bool)? = nil, floor: Float = -1, limit: Int = 100
  ) -> [(owner: String, similarity: Float, row: Int)] {
    let scores = similarities(query)
    guard !scores.isEmpty else { return [] }
    var bestScore = [Float](repeating: -.infinity, count: owners.count)
    var bestRow = [Int](repeating: -1, count: owners.count)
    for (row, score) in scores.enumerated() {
      let owner = Int(rowOwner[row])
      if score > bestScore[owner] {
        bestScore[owner] = score
        bestRow[owner] = row
      }
    }
    var found: [(owner: String, similarity: Float, row: Int)] = []
    for owner in owners.indices where bestRow[owner] >= 0 && bestScore[owner] >= floor {
      let id = owners[owner]
      if let allowed, !allowed(id) { continue }
      found.append((id, bestScore[owner], bestRow[owner]))
    }
    found.sort {
      $0.similarity != $1.similarity ? $0.similarity > $1.similarity : $0.owner < $1.owner
    }
    return Array(found.prefix(limit))
  }

  /// A vector scaled to unit length (zero stays zero).
  public static func normalized(_ vector: [Float]) -> [Float] {
    var norm: Float = 0
    vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
    norm = norm.squareRoot()
    guard norm > 0 else { return vector }
    return vector.map { $0 / norm }
  }

  // MARK: - Storage (16-bit floats, little endian)

  /// A vector as 16-bit floats (half the bytes; similarity changes in the
  /// fourth decimal).
  public static func pack(_ vector: [Float]) -> Data {
    var source = vector
    var out = [UInt16](repeating: 0, count: vector.count)
    source.withUnsafeMutableBufferPointer { input in
      out.withUnsafeMutableBufferPointer { output in
        var from = vImage_Buffer(
          data: input.baseAddress, height: 1, width: vImagePixelCount(vector.count),
          rowBytes: vector.count * MemoryLayout<Float>.size)
        var to = vImage_Buffer(
          data: output.baseAddress, height: 1, width: vImagePixelCount(vector.count),
          rowBytes: vector.count * MemoryLayout<UInt16>.size)
        _ = vImageConvert_PlanarFtoPlanar16F(&from, &to, 0)
      }
    }
    return out.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  /// The vector `pack` stored; nil when the bytes do not hold `dimension`
  /// values.
  public static func unpack(_ data: Data, dimension: Int) -> [Float]? {
    guard data.count == dimension * MemoryLayout<UInt16>.size else { return nil }
    var halves = [UInt16](repeating: 0, count: dimension)
    _ = halves.withUnsafeMutableBytes { data.copyBytes(to: $0) }
    var out = [Float](repeating: 0, count: dimension)
    halves.withUnsafeMutableBufferPointer { input in
      out.withUnsafeMutableBufferPointer { output in
        var from = vImage_Buffer(
          data: input.baseAddress, height: 1, width: vImagePixelCount(dimension),
          rowBytes: dimension * MemoryLayout<UInt16>.size)
        var to = vImage_Buffer(
          data: output.baseAddress, height: 1, width: vImagePixelCount(dimension),
          rowBytes: dimension * MemoryLayout<Float>.size)
        _ = vImageConvert_Planar16FtoPlanarF(&from, &to, 0)
      }
    }
    return out
  }
}

/// What a query asks by meaning: its words without the time and source
/// conditions (「上周 微信」 says when and where, not what). People's names
/// stay: a record that talks about someone is near a query that names them.
public enum MeaningQueryText {
  public static func text(_ query: SearchQuery) -> String {
    var text = query.raw
    for chip in query.chips {
      switch chip.kind {
      case .time, .source: text = SearchQueryParser.removing(chip, from: text)
      case .person: continue
      }
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Whether the query has anything to look for by meaning.
  public static func asksMeaning(_ query: SearchQuery) -> Bool {
    !query.units.isEmpty && MeaningChunker.hasContent(text(query))
  }
}

/// Combines the character search's ranking with the meaning search's
/// (B4 §3.2d): reciprocal rank fusion, k = 60, over the first `depth` of
/// each. With `wholeMatchesFirst`, three tiers, each ordered by the fused
/// score: records that hold every typed word; then records the meaning
/// search found; then records that only hold some of the words (the list's
/// 「以下结果包含其中部分词」 stays one run at the end).
public enum MeaningFusion {
  public struct Policy: Equatable, Sendable {
    public var k: Double
    public var lexicalWeight: Double
    public var meaningWeight: Double
    /// How far down each list counts.
    public var depth: Int
    /// Records holding every word stay ahead of everything else.
    public var wholeMatchesFirst: Bool

    public init(
      k: Double = 60, lexicalWeight: Double = 1, meaningWeight: Double = 1, depth: Int = 100,
      wholeMatchesFirst: Bool = true
    ) {
      self.k = k
      self.lexicalWeight = lexicalWeight
      self.meaningWeight = meaningWeight
      self.depth = depth
      self.wholeMatchesFirst = wholeMatchesFirst
    }

    public static let standard = Policy()
  }

  /// One record of the character search, in its order.
  public struct Lexical: Equatable, Sendable {
    public let id: String
    /// Holds only some of the words.
    public let partial: Bool

    public init(id: String, partial: Bool) {
      self.id = id
      self.partial = partial
    }
  }

  /// One record of the meaning search, in its order.
  public struct Meaning: Equatable, Sendable {
    public let id: String
    public let similarity: Float

    public init(id: String, similarity: Float) {
      self.id = id
      self.similarity = similarity
    }
  }

  public struct Fused: Equatable, Sendable {
    public let id: String
    /// Found by the character search holding only some words, and not by
    /// meaning (shown as 「只包含其中一部分」).
    public let partial: Bool
    /// Found only by meaning.
    public let meaningOnly: Bool
    public let score: Double
  }

  public static func fuse(
    lexical: [Lexical], meaning: [Meaning], policy: Policy = .standard
  ) -> [Fused] {
    var score: [String: Double] = [:]
    var order: [String] = []
    var whole: Set<String> = []
    var lexicalPartial: [String: Bool] = [:]
    for (rank, hit) in lexical.enumerated() {
      if lexicalPartial[hit.id] == nil {
        lexicalPartial[hit.id] = hit.partial
        order.append(hit.id)
      }
      if !hit.partial { whole.insert(hit.id) }
      if rank < policy.depth {
        score[hit.id, default: 0] += policy.lexicalWeight / (policy.k + Double(rank + 1))
      }
    }
    var byMeaning: Set<String> = []
    for (rank, hit) in meaning.prefix(policy.depth).enumerated()
    where byMeaning.insert(hit.id).inserted {
      if lexicalPartial[hit.id] == nil { order.append(hit.id) }
      score[hit.id, default: 0] += policy.meaningWeight / (policy.k + Double(rank + 1))
    }
    // Stable: equal scores keep the character search's order, then the
    // meaning search's.
    let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    let fused = order.map { id in
      Fused(
        id: id, partial: (lexicalPartial[id] ?? false) && !byMeaning.contains(id),
        meaningOnly: lexicalPartial[id] == nil, score: score[id] ?? 0)
    }
    func tier(_ item: Fused) -> Int {
      guard policy.wholeMatchesFirst else { return 0 }
      if whole.contains(item.id) { return 0 }
      return byMeaning.contains(item.id) ? 1 : 2
    }
    return fused.sorted { a, b in
      let ta = tier(a)
      let tb = tier(b)
      if ta != tb { return ta < tb }
      if a.score != b.score { return a.score > b.score }
      return position[a.id]! < position[b.id]!
    }
  }
}
