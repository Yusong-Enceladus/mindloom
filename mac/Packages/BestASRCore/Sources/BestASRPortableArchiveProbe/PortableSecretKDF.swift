import CryptoKit
import Foundation

public enum PortableSecretKDF {
  public static func deriveKeyData(
    secret: Data,
    salt: Data,
    iterations: UInt32
  ) throws -> Data {
    guard !secret.isEmpty, !salt.isEmpty, iterations > 0 else {
      throw PortableArchiveError.invalidSecret
    }
    let hmacKey = SymmetricKey(data: secret)
    var block = salt
    block.append(contentsOf: [0, 0, 0, 1])
    var previous = Data(
      HMAC<SHA256>.authenticationCode(for: block, using: hmacKey)
    )
    var result = previous
    if iterations > 1 {
      for _ in 2...iterations {
        previous = Data(
          HMAC<SHA256>.authenticationCode(for: previous, using: hmacKey)
        )
        for index in result.indices {
          result[index] ^= previous[index]
        }
      }
    }
    return result
  }
}
