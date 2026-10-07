import BestASRMemory
import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MindloomIdentity
import os

import struct CryptoKit.SHA256

/// How one embedding model is run: its pooling, the words put before a
/// query and before a record's piece, how long a piece may be, and how many
/// of its dimensions are kept. Everything here shapes the vectors, so all of
/// it is part of `modelVersion` (a change rebuilds the index).
public struct MLXMeaningRecipe: Equatable, Sendable {
  public enum Pooling: String, Equatable, Sendable {
    /// Average of the tokens (E5).
    case mean
    /// The first token's hidden state, without a pooler head (BGE).
    case cls
    /// The last real token (Qwen3-Embedding, right padding, causal).
    case last
  }

  public let name: String
  public let revision: String
  public let pooling: Pooling
  public let queryPrefix: String
  public let documentPrefix: String
  /// The model's own vector length.
  public let nativeDimension: Int
  /// Kept dimensions (Matryoshka models can be cut), then re-normalized.
  public let dimension: Int
  public let maximumTokens: Int
  /// Position IDs start here (2 for XLM-RoBERTa models).
  public let positionOffset: Int
  /// Make sure the text ends with the end-of-text token (Qwen3-Embedding).
  public let endsWithEOS: Bool

  public init(
    name: String, revision: String, pooling: Pooling, queryPrefix: String, documentPrefix: String,
    nativeDimension: Int, dimension: Int? = nil, maximumTokens: Int = 512, positionOffset: Int = 0,
    endsWithEOS: Bool = false
  ) {
    self.name = name
    self.revision = revision
    self.pooling = pooling
    self.queryPrefix = queryPrefix
    self.documentPrefix = documentPrefix
    self.nativeDimension = nativeDimension
    self.dimension = min(dimension ?? nativeDimension, nativeDimension)
    self.maximumTokens = maximumTokens
    self.positionOffset = positionOffset
    self.endsWithEOS = endsWithEOS
  }

  public var modelVersion: String {
    let prompts = SHA256.hash(data: Data((queryPrefix + "\u{1F}" + documentPrefix).utf8))
      .prefix(6).map { String(format: "%02x", $0) }.joined()
    return
      "\(name)@\(revision.prefix(12))/\(pooling.rawValue)/p\(prompts)/t\(maximumTokens)/d\(dimension)"
  }

  /// The words Qwen3-Embedding puts before a query (its model card: an
  /// instruction for the task, in English).
  public static let qwenSearchInstruction =
    "Instruct: Given a search query, retrieve the user's own notes, dictations and meeting records that it refers to\nQuery:"

  public static func qwen3Embedding(
    name: String, revision: String, dimension: Int = 1024,
    instruction: String = MLXMeaningRecipe.qwenSearchInstruction
  ) -> Self {
    Self(
      name: name, revision: revision, pooling: .last, queryPrefix: instruction,
      documentPrefix: "", nativeDimension: 1024, dimension: dimension, maximumTokens: 512,
      endsWithEOS: true)
  }

  public static func multilingualE5(name: String, revision: String, dimension: Int) -> Self {
    Self(
      name: name, revision: revision, pooling: .mean, queryPrefix: "query: ",
      documentPrefix: "passage: ", nativeDimension: dimension, maximumTokens: 512,
      positionOffset: 2)
  }

  public static func bgeChinese(name: String, revision: String, dimension: Int) -> Self {
    Self(
      name: name, revision: revision, pooling: .cls,
      queryPrefix: "为这个句子生成表示以用于检索相关文章：", documentPrefix: "",
      nativeDimension: dimension, maximumTokens: 512)
  }
}

/// A `MeaningEmbedding` backed by an MLX embedding model in a verified local
/// directory (no downloader on this path; the App gets the directory from
/// `LocalModelManager` after every file was checked). The model loads on
/// first use and stays until `release()`; all MLX work runs on one serial
/// queue of its own, at utility priority, so it never holds the threads
/// dictation needs.
public actor MLXMeaningEmbedder: MeaningEmbedding {
  public nonisolated let recipe: MLXMeaningRecipe
  public nonisolated var modelVersion: String { recipe.modelVersion }
  public nonisolated var dimension: Int { recipe.dimension }

  private let computeQueue = DispatchSerialQueue(
    label: MindloomIdentity.queueLabel("meaning-embedder"), qos: .utility)

  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    computeQueue.asUnownedSerialExecutor()
  }

  private let directory: URL
  private var context: EmbedderModelContext? {
    didSet {
      let isSet = context != nil
      loaded.withLock { $0 = isSet }
    }
  }
  /// Whether the model is in memory, readable without waiting for the
  /// model's queue (a search asks before every keystroke's query).
  private nonisolated let loaded = OSAllocatedUnfairLock(initialState: false)
  /// Tokens per forward pass, at most (batch × padded length).
  private let tokenBudget: Int

  public init(verifiedModelDirectory: URL, recipe: MLXMeaningRecipe, tokenBudget: Int = 4_096) {
    self.directory = verifiedModelDirectory.resolvingSymlinksInPath().standardizedFileURL
    self.recipe = recipe
    self.tokenBudget = max(recipe.maximumTokens, tokenBudget)
  }

  public nonisolated var isLoaded: Bool { loaded.withLock { $0 } }

  public func release() {
    context = nil
    Memory.clearCache()
  }

  public func prepare() async throws {
    if context != nil { return }
    var isDirectory: ObjCBool = false
    guard directory.isFileURL, directory.path != "/",
      FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw MLXMeaningEmbedderError.modelDirectoryMissing }
    context = try await EmbedderModelFactory.shared.load(
      from: directory, using: TransformersTokenizerLoader())
  }

  public func embed(_ texts: [String], role: MeaningTextRole) async throws -> [[Float]] {
    guard !texts.isEmpty else { return [] }
    try await prepare()
    guard let context else { throw MLXMeaningEmbedderError.modelDirectoryMissing }
    let prefix = role == .query ? recipe.queryPrefix : recipe.documentPrefix
    let eos = context.tokenizer.eosToken.flatMap { context.tokenizer.convertTokenToId($0) }
    let encoded: [[Int]] = texts.map { text in
      var ids = context.tokenizer.encode(text: prefix + text, addSpecialTokens: true)
      if recipe.endsWithEOS, let eos, ids.last != eos { ids.append(eos) }
      if ids.count > recipe.maximumTokens {
        // Keep the end marker (BERT's [SEP], Qwen's end of text).
        let last = ids.last!
        ids = Array(ids.prefix(recipe.maximumTokens - 1)) + [last]
      }
      return ids
    }
    // Similar lengths together, so little is padded.
    let order = encoded.indices.sorted { encoded[$0].count < encoded[$1].count }
    var out = [[Float]](repeating: [], count: texts.count)
    var start = 0
    while start < order.count {
      try Task.checkCancellation()
      var end = start + 1
      while end < order.count, encoded[order[end]].count * (end - start + 1) <= tokenBudget {
        end += 1
      }
      let batch = Array(order[start..<end])
      let vectors = run(batch.map { encoded[$0] }, context: context, pad: eos ?? 0)
      for (slot, vector) in zip(batch, vectors) { out[slot] = vector }
      start = end
    }
    return out
  }

  private func run(_ batch: [[Int]], context: EmbedderModelContext, pad: Int) -> [[Float]] {
    let length = batch.map(\.count).max() ?? 1
    var flat: [Int32] = []
    var maskValues: [Int32] = []
    flat.reserveCapacity(batch.count * length)
    for ids in batch {
      flat += ids.map(Int32.init)
      flat += [Int32](repeating: Int32(pad), count: length - ids.count)
      maskValues += [Int32](repeating: 1, count: ids.count)
      maskValues += [Int32](repeating: 0, count: length - ids.count)
    }
    let inputs = MLXArray(flat, [batch.count, length])
    let mask = MLXArray(maskValues, [batch.count, length])
    let positions =
      recipe.positionOffset > 0
      ? broadcast(
        MLXArray.arange(recipe.positionOffset, recipe.positionOffset + length),
        to: [batch.count, length]) : nil
    let output = context.model(
      inputs, positionIds: positions, tokenTypeIds: MLXArray.zeros(like: inputs),
      attentionMask: mask)
    guard let hidden = output.hiddenStates else { return batch.map { _ in [] } }
    let pooled: MLXArray
    switch recipe.pooling {
    case .mean:
      let weights = mask.asType(hidden.dtype).expandedDimensions(axes: [-1])
      pooled = sum(hidden * weights, axis: 1) / sum(weights, axis: 1)
    case .cls:
      pooled = hidden[0..., 0, 0...]
    case .last:
      let last = maximum(sum(mask, axis: -1) - MLXArray(Int32(1)), MLXArray(Int32(0)))
      pooled = squeezed(
        takeAlong(hidden, last.expandedDimensions(axes: [1, 2]), axis: 1), axis: 1)
    }
    var kept = pooled.asType(.float32)
    if recipe.dimension < recipe.nativeDimension {
      kept = kept[0..., 0..<recipe.dimension]
    }
    let norms = sqrt(sum(kept * kept, axis: -1, keepDims: true))
    kept = kept / maximum(norms, MLXArray(Float(1e-12)))
    eval(kept)
    let values = kept.asArray(Float.self)
    let width = recipe.dimension
    return (0..<batch.count).map { row in Array(values[(row * width)..<((row + 1) * width)]) }
  }
}

public enum MLXMeaningEmbedderError: Error, Equatable {
  case modelDirectoryMissing
}
