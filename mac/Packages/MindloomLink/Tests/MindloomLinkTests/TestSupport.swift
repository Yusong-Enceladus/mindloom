import CryptoKit
import Foundation
import XCTest

extension Data {
  init(hex: String) {
    var bytes = [UInt8]()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      bytes.append(UInt8(hex[index..<next], radix: 16)!)
      index = next
    }
    self.init(bytes)
  }

  var hex: String { map { String(format: "%02x", $0) }.joined() }
}

struct SealVectorFile: Decodable {
  struct Vector: Decodable {
    let name: String
    let entryId: String
    let macPrivHex: String
    let macPubHex: String
    let ephPrivHex: String
    let ephPubHex: String
    let nonceHex: String
    let plaintextHex: String
    let wire: String
  }

  struct Failure: Decodable {
    let name: String
    let entryId: String
    let macPrivHex: String
    let wire: String
    let expect: String
  }

  let format: String
  let hkdfInfo: String
  let aadPrefix: String
  let vectors: [Vector]
  let openFailures: [Failure]

  static func load() throws -> SealVectorFile {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "seal_vectors", withExtension: "json"))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(SealVectorFile.self, from: Data(contentsOf: url))
  }
}

func assertThrows<E: Error & Equatable>(
  _ expected: E, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> some Any
) {
  do {
    _ = try body()
    XCTFail("expected \(expected), nothing was thrown", file: file, line: line)
  } catch let error as E {
    XCTAssertEqual(error, expected, file: file, line: line)
  } catch {
    XCTFail("expected \(expected), got \(error)", file: file, line: line)
  }
}

let shanghai = TimeZone(identifier: "Asia/Shanghai")!
/// 2026-09-30 09:15:02.500 +08:00
let fixedDate = Date(timeIntervalSince1970: 1_790_730_902.5)
