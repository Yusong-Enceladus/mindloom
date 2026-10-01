import Crypto
import Foundation
import MindloomLink
import MindloomPhoneKit
import NIOCore
import NIOSSH

/// Which SSH hop something happened on.
public enum InboxHop: String, Sendable {
  case relay
  case spark
}

/// Everything the phone needs to reach the Spark's inbox gate: the pinned
/// endpoints from the pairing and the phone's ed25519 key (PHONE-CONTRACT §4).
public struct InboxSSHConfiguration: Sendable {
  public var spark: PairingEndpoint
  public var relay: PairingEndpoint?
  public var gate: String
  public var phoneKey: Curve25519.Signing.PrivateKey
  /// TCP connect, per hop.
  public var connectTimeout: TimeAmount = .seconds(15)
  /// SSH handshake and authentication, per hop.
  public var handshakeTimeout: TimeAmount = .seconds(20)
  /// One `add`, plus `commandTimeoutPerMiB` for each MiB of wire.
  public var commandTimeout: TimeAmount = .seconds(30)
  public var commandTimeoutPerMiB: TimeAmount = .seconds(2)

  public init(
    spark: PairingEndpoint, relay: PairingEndpoint?, gate: String,
    phoneKey: Curve25519.Signing.PrivateKey
  ) {
    self.spark = spark
    self.relay = relay
    self.gate = gate
    self.phoneKey = phoneKey
  }

  public init(pairing: PairingPayload) {
    self.init(
      spark: pairing.spark, relay: pairing.relay, gate: pairing.gate,
      phoneKey: pairing.phoneSigningKey)
  }

  /// From the App Group record plus the key read from the Keychain.
  public init(record: PairingRecord, phoneKey: Curve25519.Signing.PrivateKey) {
    self.init(spark: record.spark, relay: record.relay, gate: record.gate, phoneKey: phoneKey)
  }

  /// The exact command the gate sees as `SSH_ORIGINAL_COMMAND`. Both words
  /// that vary are validated (a safe gate path, a lowercase UUID), so nothing
  /// here can carry shell syntax. `--json` makes the reply machine-readable;
  /// the gate allows it (§5).
  public func addCommand(entryID: String) throws -> String {
    guard EntryID.isValid(entryID) else { throw InboxDeliveryErrorFactory.invalidEntryID }
    guard PairingPayload.isValidGate(gate) else { throw InboxDeliveryErrorFactory.invalidGate }
    return "\(gate) add --sealed --id \(entryID) --json"
  }

  func pinnedKey(for hop: InboxHop) throws -> NIOSSHPublicKey {
    let endpoint = hop == .relay ? relay! : spark
    do {
      return try NIOSSHPublicKey(openSSHPublicKey: endpoint.hostKey.openSSH)
    } catch {
      throw InboxDeliveryErrorFactory.unusableHostKey(hop)
    }
  }
}

enum InboxDeliveryErrorFactory {
  static let invalidEntryID = InboxDeliveryError(.rejected, detail: "invalid entry id")
  static let invalidGate = InboxDeliveryError(.notPaired, detail: "invalid gate")
  static func unusableHostKey(_ hop: InboxHop) -> InboxDeliveryError {
    InboxDeliveryError(.hostKeyMismatch, detail: "\(hop.rawValue): pinned key unusable")
  }
}
