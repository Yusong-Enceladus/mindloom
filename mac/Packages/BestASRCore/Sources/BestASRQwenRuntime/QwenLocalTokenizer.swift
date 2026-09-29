import BestASRInference
import Foundation
import Hub
import Tokenizers

public enum QwenLocalTokenizer {
  /// Same Qwen2 BPE recipe as the pinned upstream generator. NSString keys
  /// preserve byte-distinct vocabulary entries when constructing Hub.Config.
  /// No tokenizer/model cache is written and no Hub client is created.
  public static func load(from modelDirectory: URL) throws -> any Tokenizer {
    guard modelDirectory.isFileURL else {
      throw qwenFailure(.invalidRequest, "qwen-tokenizer-local-files-required", false)
    }
    let configuration = try jsonObject("tokenizer_config.json", in: modelDirectory)
    let vocabulary = try jsonObject("vocab.json", in: modelDirectory)
    let merges = try String(
      contentsOf: modelDirectory.appendingPathComponent("merges.txt"),
      encoding: .utf8
    ).components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }
    guard let decoder = configuration["added_tokens_decoder"] as? [NSString: Any]
    else { throw qwenFailure(.incompatibleArtifact, "qwen-tokenizer-invalid", false) }
    let added: [(Int, [NSString: Any])] = try decoder.map { key, value in
      guard let id = Int(key as String), let token = value as? [NSString: Any],
        let content = token["content"] as? String
      else { throw qwenFailure(.incompatibleArtifact, "qwen-tokenizer-invalid", false) }
      return (
        id,
        [
          "id": id, "content": content,
          "single_word": token["single_word"] as? Bool ?? false,
          "lstrip": token["lstrip"] as? Bool ?? false,
          "rstrip": token["rstrip"] as? Bool ?? false,
          "normalized": token["normalized"] as? Bool ?? false,
          "special": token["special"] as? Bool ?? false,
        ]
      )
    }
    let pattern =
      #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
    let data: [NSString: Any] = [
      "version": "1.0", "truncation": NSNull(), "padding": NSNull(),
      "added_tokens": added.sorted { $0.0 < $1.0 }.map(\.1),
      "normalizer": ["type": "NFC"],
      "pre_tokenizer": [
        "type": "Sequence",
        "pretokenizers": [
          [
            "type": "Split", "pattern": ["Regex": pattern],
            "behavior": "Isolated", "invert": false,
          ] as [String: Any],
          [
            "type": "ByteLevel", "add_prefix_space": false,
            "trim_offsets": true, "use_regex": false,
          ] as [String: Any],
        ],
      ],
      "post_processor": NSNull(),
      "decoder": [
        "type": "ByteLevel", "add_prefix_space": true,
        "trim_offsets": true, "use_regex": true,
      ] as [String: Any],
      "model": [
        "type": "BPE", "dropout": NSNull(), "unk_token": NSNull(),
        "continuing_subword_prefix": "", "end_of_word_suffix": "",
        "fuse_unk": false, "byte_fallback": false,
        "vocab": vocabulary, "merges": merges,
      ],
    ]
    return try AutoTokenizer.from(
      tokenizerConfig: Config(configuration), tokenizerData: Config(data)
    )
  }

  private static func jsonObject(_ filename: String, in modelDirectory: URL) throws -> [NSString:
    Any]
  {
    let value = try JSONSerialization.jsonObject(
      with: Data(contentsOf: modelDirectory.appendingPathComponent(filename))
    )
    guard let object = value as? [NSString: Any] else {
      throw qwenFailure(.incompatibleArtifact, "qwen-tokenizer-invalid", false)
    }
    return object
  }
}
