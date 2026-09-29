import BestASRDomain
import Foundation

enum LocalDictionaryTransferError: Error, Sendable {
  case fileTooLarge
  case invalidEncoding
  case invalidFormat
  case invalidHeader
  case invalidBoolean
  case emptyDocument
}

enum LocalDictionaryTransferFormat: String, CaseIterable, Sendable {
  case csv
  case json
}

enum LocalDictionaryTransferCodec {
  private static let maximumBytes = 10 * 1_048_576

  static func decode(url: URL) throws -> [DictionaryTransferEntry] {
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw LocalDictionaryTransferError.invalidFormat
    }
    guard let size = values.fileSize, size > 0 else {
      throw LocalDictionaryTransferError.emptyDocument
    }
    guard size <= maximumBytes else {
      throw LocalDictionaryTransferError.fileTooLarge
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    switch url.pathExtension.lowercased() {
    case "json":
      let document = try JSONDecoder().decode(
        DictionaryTransferDocument.self,
        from: data
      )
      guard document.schemaVersion == 1 else {
        throw LocalDictionaryTransferError.invalidFormat
      }
      guard document.entries.count <= 100_000 else {
        throw LocalDictionaryTransferError.invalidFormat
      }
      // Codable synthesis does not invoke the domain's throwing memberwise
      // initializer, so rebuild every row to enforce the same bounds as UI and
      // CSV imports before anything reaches the database transaction.
      return try document.entries.map {
        try DictionaryTransferEntry(
          canonicalForm: $0.canonicalForm,
          spokenForms: $0.spokenForms,
          enabled: $0.enabled
        )
      }
    case "csv":
      return try decodeCSV(data)
    default:
      throw LocalDictionaryTransferError.invalidFormat
    }
  }

  static func encode(
    entries: [DictionaryEntry],
    format: LocalDictionaryTransferFormat
  ) throws -> Data {
    let transfer = try entries.map {
      try DictionaryTransferEntry(
        canonicalForm: $0.canonicalForm,
        spokenForms: $0.spokenForms,
        enabled: $0.enabled
      )
    }
    switch format {
    case .json:
      let document = try DictionaryTransferDocument(entries: transfer)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return try encoder.encode(document)
    case .csv:
      var rows = ["canonicalForm,spokenForms,enabled"]
      let arrayEncoder = JSONEncoder()
      arrayEncoder.outputFormatting = [.withoutEscapingSlashes]
      for entry in transfer {
        let spoken =
          String(
            data: try arrayEncoder.encode(entry.spokenForms),
            encoding: .utf8
          ) ?? "[]"
        rows.append(
          [
            csvCell(entry.canonicalForm),
            csvCell(spoken),
            entry.enabled ? "true" : "false",
          ].joined(separator: ","))
      }
      guard
        let data = (rows.joined(separator: "\r\n") + "\r\n")
          .data(using: .utf8)
      else {
        throw LocalDictionaryTransferError.invalidEncoding
      }
      return data
    }
  }

  private static func decodeCSV(_ data: Data) throws
    -> [DictionaryTransferEntry]
  {
    guard var text = String(data: data, encoding: .utf8) else {
      throw LocalDictionaryTransferError.invalidEncoding
    }
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
      throw LocalDictionaryTransferError.invalidFormat
    }
    let rows = try parseCSV(text)
    guard let header = rows.first else {
      throw LocalDictionaryTransferError.emptyDocument
    }
    let normalizedHeader = header.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    guard normalizedHeader == ["canonicalform", "spokenforms", "enabled"]
    else { throw LocalDictionaryTransferError.invalidHeader }
    let decoder = JSONDecoder()
    return try rows.dropFirst().enumerated().compactMap { _, row in
      if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
        return nil
      }
      guard row.count == 3 else {
        throw LocalDictionaryTransferError.invalidFormat
      }
      let canonical = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let spokenValue = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
      let spoken: [String]
      if spokenValue.isEmpty {
        spoken = []
      } else if let encoded = spokenValue.data(using: .utf8),
        let values = try? decoder.decode([String].self, from: encoded)
      {
        spoken = values
      } else {
        spoken = spokenValue.split(separator: "|").map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
      }
      let enabled: Bool
      switch row[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true", "1", "yes": enabled = true
      case "false", "0", "no": enabled = false
      default: throw LocalDictionaryTransferError.invalidBoolean
      }
      return try DictionaryTransferEntry(
        canonicalForm: canonical,
        spokenForms: spoken,
        enabled: enabled
      )
    }
  }

  private static func csvCell(_ value: String) -> String {
    guard
      value.contains(",") || value.contains("\"")
        || value.contains("\n") || value.contains("\r")
    else { return value }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  private static func parseCSV(_ text: String) throws -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      let next = text.index(after: index)
      if quoted {
        if character == "\"" {
          if next < text.endIndex, text[next] == "\"" {
            field.append("\"")
            index = text.index(after: next)
            continue
          }
          quoted = false
        } else {
          field.append(character)
        }
      } else {
        switch character {
        case "\"":
          guard field.isEmpty else {
            throw LocalDictionaryTransferError.invalidFormat
          }
          quoted = true
        case ",":
          row.append(field)
          field = ""
        // Swift reads CRLF as one Character, which is how exports end rows.
        case "\n", "\r\n":
          row.append(field)
          field = ""
          rows.append(row)
          row = []
        case "\r":
          if next >= text.endIndex || text[next] != "\n" {
            row.append(field)
            field = ""
            rows.append(row)
            row = []
          }
        default:
          field.append(character)
        }
      }
      index = next
    }
    guard !quoted else { throw LocalDictionaryTransferError.invalidFormat }
    if !field.isEmpty || !row.isEmpty {
      row.append(field)
      rows.append(row)
    }
    return rows
  }
}

actor LocalDictionaryTransferWorker {
  func decode(url: URL) throws -> [DictionaryTransferEntry] {
    try LocalDictionaryTransferCodec.decode(url: url)
  }

  func encode(
    entries: [DictionaryEntry],
    format: LocalDictionaryTransferFormat
  ) throws -> Data {
    try LocalDictionaryTransferCodec.encode(entries: entries, format: format)
  }
}
