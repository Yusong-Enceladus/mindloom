import BestASRSecurityEnvelopeProbe
import CryptoKit
import Foundation

enum EnvelopeMatrixError: Error, Sendable {
  case expectedFailureMissing(String)
  case missingPrerequisite(String)
}

final class EnvelopeMatrix {
  private let root: URL
  private let keychainURL: URL
  private let envelopeURL: URL
  private let envelopeBackupURL: URL
  private let service = "local.bestasr.security-probe"
  private let account = "synthetic-master-key"
  private let marker = Data("probe_envelope_marker_8c42".utf8)

  private var keychain: TemporaryKeychainStore?
  private var masterKeyData: Data?
  private var envelope: EncryptedEnvelope?

  init(root: URL) {
    self.root = root
    keychainURL = root.appendingPathComponent("probe.keychain-db")
    envelopeURL = root.appendingPathComponent("asset.envelope")
    envelopeBackupURL = root.appendingPathComponent("asset-backup.envelope")
  }

  deinit {
    try? keychain?.destroy()
  }

  func run() -> [ProbeScenarioDetail] {
    [
      runScenario("cryptokit-keychain-envelope-roundtrip", createAndRoundTrip),
      runScenario("cryptokit-wrong-key-and-tamper", verifyWrongKeyAndTamper),
      runScenario("cryptokit-backup-and-atomic-recovery", verifyBackupAndAtomicity),
      runScenario("keychain-loss-is-explicit", verifyKeychainLoss),
    ]
  }

  private func createAndRoundTrip() throws -> [String: String] {
    let store = try TemporaryKeychainStore(
      url: keychainURL,
      password: "probe-\(UUID().uuidString)"
    )
    keychain = store
    let masterKey = EnvelopeCrypto.makeMasterKey()
    let keyData = EnvelopeCrypto.keyData(masterKey)
    try store.store(keyData, service: service, account: account)
    let loadedKeyData = try store.load(service: service, account: account)
    guard loadedKeyData == keyData else {
      throw EnvelopeMatrixError.missingPrerequisite("keychain-roundtrip")
    }
    masterKeyData = keyData

    var plaintext = Data(repeating: 0x5a, count: 256 * 1_024)
    plaintext.replaceSubrange(1_024..<(1_024 + marker.count), with: marker)
    let encrypted = try EnvelopeCrypto.encrypt(
      plaintext,
      masterKey: EnvelopeCrypto.key(from: loadedKeyData),
      purpose: .asset
    )
    envelope = encrypted
    try AtomicEnvelopeFile.commit(encrypted, to: envelopeURL)
    let encoded = try Data(contentsOf: envelopeURL)
    guard encoded.range(of: marker) == nil else {
      throw EnvelopeMatrixError.missingPrerequisite("plaintext-visible")
    }
    let restored = try EnvelopeCrypto.decrypt(
      AtomicEnvelopeFile.read(from: envelopeURL),
      masterKey: EnvelopeCrypto.key(from: loadedKeyData)
    )
    guard restored == plaintext else {
      throw EnvelopeMatrixError.missingPrerequisite("payload-mismatch")
    }
    return [
      "encryptedBytes": String(encoded.count),
      "keychainRoundTrip": "pass",
      "plaintextMarkerVisible": "false",
      "restoredBytes": String(restored.count),
    ]
  }

  private func verifyWrongKeyAndTamper() throws -> [String: String] {
    guard let envelope, let masterKeyData else {
      throw EnvelopeMatrixError.missingPrerequisite("envelope")
    }
    var wrongKeyRejected = false
    do {
      _ = try EnvelopeCrypto.decrypt(
        envelope,
        masterKey: EnvelopeCrypto.makeMasterKey()
      )
    } catch {
      wrongKeyRejected = true
    }
    guard wrongKeyRejected else {
      throw EnvelopeMatrixError.expectedFailureMissing("wrong-key")
    }

    var tamperedBytes = envelope.sealedPayload
    tamperedBytes[tamperedBytes.index(before: tamperedBytes.endIndex)] ^= 0x01
    let tampered = EncryptedEnvelope(
      keyIdentifier: envelope.keyIdentifier,
      purpose: envelope.purpose,
      wrappedDataKey: envelope.wrappedDataKey,
      sealedPayload: tamperedBytes
    )
    var tamperRejected = false
    do {
      _ = try EnvelopeCrypto.decrypt(
        tampered,
        masterKey: EnvelopeCrypto.key(from: masterKeyData)
      )
    } catch {
      tamperRejected = true
    }
    guard tamperRejected else {
      throw EnvelopeMatrixError.expectedFailureMissing("tamper")
    }
    return [
      "tamperRejected": "true",
      "wrongKeyRejected": "true",
    ]
  }

  private func verifyBackupAndAtomicity() throws -> [String: String] {
    guard let envelope, let masterKeyData else {
      throw EnvelopeMatrixError.missingPrerequisite("envelope")
    }
    try FileManager.default.copyItem(at: envelopeURL, to: envelopeBackupURL)
    let backup = try AtomicEnvelopeFile.read(from: envelopeBackupURL)
    let backupPlaintext = try EnvelopeCrypto.decrypt(
      backup,
      masterKey: EnvelopeCrypto.key(from: masterKeyData)
    )
    guard backupPlaintext.range(of: marker) != nil else {
      throw EnvelopeMatrixError.missingPrerequisite("backup-roundtrip")
    }

    let replacement = try EnvelopeCrypto.encrypt(
      Data("replacement_probe_payload".utf8),
      masterKey: EnvelopeCrypto.key(from: masterKeyData),
      purpose: .asset,
      keyIdentifier: envelope.keyIdentifier
    )
    var faultRejected = false
    do {
      try AtomicEnvelopeFile.commit(
        replacement,
        to: envelopeURL,
        fault: .beforeCommit
      )
    } catch AtomicEnvelopeFileError.injectedBeforeCommit {
      faultRejected = true
    }
    guard faultRejected,
      try AtomicEnvelopeFile.read(from: envelopeURL) == envelope
    else {
      throw EnvelopeMatrixError.missingPrerequisite("atomic-preservation")
    }
    let stagingCount = try FileManager.default.contentsOfDirectory(
      atPath: root.path
    ).filter { $0.hasSuffix(".envelope-staging") }.count
    guard stagingCount == 0 else {
      throw EnvelopeMatrixError.missingPrerequisite("staging-cleanup")
    }
    return [
      "backupRoundTrip": "pass",
      "faultBeforeCommitRejected": "true",
      "stagingFilesRemaining": "0",
    ]
  }

  private func verifyKeychainLoss() throws -> [String: String] {
    guard let keychain, let masterKeyData else {
      throw EnvelopeMatrixError.missingPrerequisite("keychain")
    }
    let envelopeBefore = try Data(contentsOf: envelopeURL)
    guard try keychain.delete(service: service, account: account) else {
      throw EnvelopeMatrixError.missingPrerequisite("keychain-delete")
    }
    var missingReported = false
    do {
      _ = try keychain.load(service: service, account: account)
    } catch KeychainProbeError.keyMissing {
      missingReported = true
    }
    guard missingReported else {
      throw EnvelopeMatrixError.expectedFailureMissing("keychain-loss")
    }
    guard try Data(contentsOf: envelopeURL) == envelopeBefore else {
      throw EnvelopeMatrixError.missingPrerequisite("encrypted-data-mutated")
    }

    var decryptWithoutStoredKeyRejected = false
    do {
      _ = try EnvelopeCrypto.decrypt(
        AtomicEnvelopeFile.read(from: envelopeURL),
        masterKey: EnvelopeCrypto.makeMasterKey()
      )
    } catch {
      decryptWithoutStoredKeyRejected = true
    }
    guard decryptWithoutStoredKeyRejected else {
      throw EnvelopeMatrixError.expectedFailureMissing("lost-key-decrypt")
    }
    _ = masterKeyData
    return [
      "encryptedDataPreserved": "true",
      "keyMissingReported": "true",
      "silentReset": "false",
    ]
  }
}
