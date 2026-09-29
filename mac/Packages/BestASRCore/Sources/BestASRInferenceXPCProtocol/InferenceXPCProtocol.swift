@preconcurrency import Foundation

public enum InferenceXPCContract {
  public static let currentVersion = 1
  public static let serviceName = "com.bestasr.app.inference-worker"

  public static func interface() -> NSXPCInterface {
    NSXPCInterface(with: InferenceWorkerXPCProtocol.self)
  }
}

@objc public protocol InferenceWorkerXPCProtocol {
  func healthCheck(
    _ clientProtocolVersion: Int,
    withReply reply: @escaping (InferenceXPCResponse) -> Void
  )

  func run(
    _ request: InferenceXPCRequest,
    withReply reply: @escaping (InferenceXPCResponse) -> Void
  )

  func cancel(
    _ jobID: String,
    withReply reply: @escaping (InferenceXPCResponse) -> Void
  )

  func crashForProbe(withReply reply: @escaping () -> Void)
}

public final class InferenceXPCRequest: NSObject, NSSecureCoding,
  @unchecked Sendable
{
  public static var supportsSecureCoding: Bool { true }

  public let protocolVersion: Int
  public let jobID: String
  public let idempotencyKey: String
  public let inputRevision: UInt64
  public let modelVersion: String
  public let configHash: String
  public let audioRangeDigest: String
  public let simulatedDelayMilliseconds: Int
  public let modelLoadBytes: Int

  public init(
    protocolVersion: Int = InferenceXPCContract.currentVersion,
    jobID: String,
    idempotencyKey: String,
    inputRevision: UInt64,
    modelVersion: String,
    configHash: String,
    audioRangeDigest: String,
    simulatedDelayMilliseconds: Int = 0,
    modelLoadBytes: Int = 0
  ) {
    self.protocolVersion = protocolVersion
    self.jobID = jobID
    self.idempotencyKey = idempotencyKey
    self.inputRevision = inputRevision
    self.modelVersion = modelVersion
    self.configHash = configHash
    self.audioRangeDigest = audioRangeDigest
    self.simulatedDelayMilliseconds = simulatedDelayMilliseconds
    self.modelLoadBytes = modelLoadBytes
    super.init()
  }

  public required init?(coder: NSCoder) {
    protocolVersion = coder.decodeInteger(forKey: "protocolVersion")
    guard
      let jobID = coder.decodeObject(
        of: NSString.self,
        forKey: "jobID"
      ) as String?,
      let idempotencyKey = coder.decodeObject(
        of: NSString.self,
        forKey: "idempotencyKey"
      ) as String?,
      let modelVersion = coder.decodeObject(
        of: NSString.self,
        forKey: "modelVersion"
      ) as String?,
      let configHash = coder.decodeObject(
        of: NSString.self,
        forKey: "configHash"
      ) as String?,
      let audioRangeDigest = coder.decodeObject(
        of: NSString.self,
        forKey: "audioRangeDigest"
      ) as String?
    else { return nil }
    self.jobID = jobID
    self.idempotencyKey = idempotencyKey
    inputRevision = UInt64(bitPattern: coder.decodeInt64(forKey: "inputRevision"))
    self.modelVersion = modelVersion
    self.configHash = configHash
    self.audioRangeDigest = audioRangeDigest
    simulatedDelayMilliseconds = coder.decodeInteger(
      forKey: "simulatedDelayMilliseconds"
    )
    modelLoadBytes = coder.decodeInteger(forKey: "modelLoadBytes")
    super.init()
  }

  public func encode(with coder: NSCoder) {
    coder.encode(protocolVersion, forKey: "protocolVersion")
    coder.encode(jobID as NSString, forKey: "jobID")
    coder.encode(idempotencyKey as NSString, forKey: "idempotencyKey")
    coder.encode(Int64(bitPattern: inputRevision), forKey: "inputRevision")
    coder.encode(modelVersion as NSString, forKey: "modelVersion")
    coder.encode(configHash as NSString, forKey: "configHash")
    coder.encode(audioRangeDigest as NSString, forKey: "audioRangeDigest")
    coder.encode(
      simulatedDelayMilliseconds,
      forKey: "simulatedDelayMilliseconds"
    )
    coder.encode(modelLoadBytes, forKey: "modelLoadBytes")
  }
}

public final class InferenceXPCResponse: NSObject, NSSecureCoding,
  @unchecked Sendable
{
  public static var supportsSecureCoding: Bool { true }

  public let protocolVersion: Int
  public let jobID: String
  public let status: String
  public let resultDigest: String
  public let errorCategory: String
  public let elapsedNanoseconds: UInt64
  public let residentBeforeBytes: UInt64
  public let residentPeakBytes: UInt64
  public let residentAfterBytes: UInt64

  public init(
    protocolVersion: Int = InferenceXPCContract.currentVersion,
    jobID: String,
    status: String,
    resultDigest: String,
    errorCategory: String,
    elapsedNanoseconds: UInt64 = 0,
    residentBeforeBytes: UInt64 = 0,
    residentPeakBytes: UInt64 = 0,
    residentAfterBytes: UInt64 = 0
  ) {
    self.protocolVersion = protocolVersion
    self.jobID = jobID
    self.status = status
    self.resultDigest = resultDigest
    self.errorCategory = errorCategory
    self.elapsedNanoseconds = elapsedNanoseconds
    self.residentBeforeBytes = residentBeforeBytes
    self.residentPeakBytes = residentPeakBytes
    self.residentAfterBytes = residentAfterBytes
    super.init()
  }

  public required init?(coder: NSCoder) {
    protocolVersion = coder.decodeInteger(forKey: "protocolVersion")
    guard
      let jobID = coder.decodeObject(of: NSString.self, forKey: "jobID")
        as String?,
      let status = coder.decodeObject(of: NSString.self, forKey: "status")
        as String?,
      let resultDigest = coder.decodeObject(
        of: NSString.self,
        forKey: "resultDigest"
      ) as String?,
      let errorCategory = coder.decodeObject(
        of: NSString.self,
        forKey: "errorCategory"
      ) as String?
    else { return nil }
    self.jobID = jobID
    self.status = status
    self.resultDigest = resultDigest
    self.errorCategory = errorCategory
    elapsedNanoseconds = UInt64(
      bitPattern: coder.decodeInt64(forKey: "elapsedNanoseconds")
    )
    residentBeforeBytes = UInt64(
      bitPattern: coder.decodeInt64(forKey: "residentBeforeBytes")
    )
    residentPeakBytes = UInt64(
      bitPattern: coder.decodeInt64(forKey: "residentPeakBytes")
    )
    residentAfterBytes = UInt64(
      bitPattern: coder.decodeInt64(forKey: "residentAfterBytes")
    )
    super.init()
  }

  public func encode(with coder: NSCoder) {
    coder.encode(protocolVersion, forKey: "protocolVersion")
    coder.encode(jobID as NSString, forKey: "jobID")
    coder.encode(status as NSString, forKey: "status")
    coder.encode(resultDigest as NSString, forKey: "resultDigest")
    coder.encode(errorCategory as NSString, forKey: "errorCategory")
    coder.encode(
      Int64(bitPattern: elapsedNanoseconds),
      forKey: "elapsedNanoseconds"
    )
    coder.encode(
      Int64(bitPattern: residentBeforeBytes),
      forKey: "residentBeforeBytes"
    )
    coder.encode(
      Int64(bitPattern: residentPeakBytes),
      forKey: "residentPeakBytes"
    )
    coder.encode(
      Int64(bitPattern: residentAfterBytes),
      forKey: "residentAfterBytes"
    )
  }
}
