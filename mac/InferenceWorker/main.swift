import BestASRInferenceXPCProtocol
import Darwin
@preconcurrency import Foundation

final class InferenceWorker: NSObject, InferenceWorkerXPCProtocol,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var cancelledJobIDs: Set<String> = []

  func healthCheck(
    _ clientProtocolVersion: Int,
    withReply reply: @escaping (InferenceXPCResponse) -> Void
  ) {
    let compatible = clientProtocolVersion == InferenceXPCContract.currentVersion
    reply(
      InferenceXPCResponse(
        jobID: "health",
        status: compatible ? "ready" : "rejected",
        resultDigest: "",
        errorCategory: compatible ? "none" : "incompatibleProtocol"
      )
    )
  }

  func run(
    _ request: InferenceXPCRequest,
    withReply reply: @escaping (InferenceXPCResponse) -> Void
  ) {
    guard request.protocolVersion == InferenceXPCContract.currentVersion else {
      reply(
        InferenceXPCResponse(
          jobID: request.jobID,
          status: "rejected",
          resultDigest: "",
          errorCategory: "incompatibleProtocol"
        )
      )
      return
    }
    if request.simulatedDelayMilliseconds > 0 {
      Thread.sleep(
        forTimeInterval: Double(request.simulatedDelayMilliseconds) / 1_000
      )
    }
    let workload = executeModelLoad(bytes: request.modelLoadBytes)
    let cancelled = lock.withLock { cancelledJobIDs.contains(request.jobID) }
    reply(
      InferenceXPCResponse(
        jobID: request.jobID,
        status: cancelled ? "cancelled" : "succeeded",
        resultDigest: cancelled ? "" : "sha256:\(request.idempotencyKey)",
        errorCategory: cancelled ? "cancelled" : "none",
        elapsedNanoseconds: workload.elapsedNanoseconds,
        residentBeforeBytes: workload.residentBeforeBytes,
        residentPeakBytes: workload.residentPeakBytes,
        residentAfterBytes: workload.residentAfterBytes
      )
    )
  }

  func cancel(
    _ jobID: String,
    withReply reply: @escaping (InferenceXPCResponse) -> Void
  ) {
    _ = lock.withLock { cancelledJobIDs.insert(jobID) }
    reply(
      InferenceXPCResponse(
        jobID: jobID,
        status: "cancelled",
        resultDigest: "",
        errorCategory: "cancelled"
      )
    )
  }

  func crashForProbe(withReply reply: @escaping () -> Void) {
    Darwin._exit(86)
  }

  private func executeModelLoad(bytes: Int) -> WorkloadMetrics {
    let before = currentResidentBytes()
    let start = DispatchTime.now().uptimeNanoseconds
    let peak: UInt64
    if bytes > 0 {
      peak = allocateAndTouch(bytes: bytes)
    } else {
      peak = before
    }
    malloc_zone_pressure_relief(nil, 0)
    let after = currentResidentBytes()
    return WorkloadMetrics(
      elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - start,
      residentBeforeBytes: before,
      residentPeakBytes: peak,
      residentAfterBytes: after
    )
  }

  private func allocateAndTouch(bytes: Int) -> UInt64 {
    var buffer = [UInt8](repeating: 0, count: bytes)
    for index in stride(from: 0, to: buffer.count, by: 4_096) {
      buffer[index] = UInt8(truncatingIfNeeded: index)
    }
    return withExtendedLifetime(buffer) {
      currentResidentBytes()
    }
  }
}

private struct WorkloadMetrics {
  let elapsedNanoseconds: UInt64
  let residentBeforeBytes: UInt64
  let residentPeakBytes: UInt64
  let residentAfterBytes: UInt64
}

private func currentResidentBytes() -> UInt64 {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(
    MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
  )
  let result = withUnsafeMutablePointer(to: &info) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(
        mach_task_self_,
        task_flavor_t(MACH_TASK_BASIC_INFO),
        $0,
        &count
      )
    }
  }
  guard result == KERN_SUCCESS else { return 0 }
  return UInt64(info.resident_size)
}

final class InferenceWorkerListenerDelegate: NSObject, NSXPCListenerDelegate,
  @unchecked Sendable
{
  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    connection.exportedInterface = InferenceXPCContract.interface()
    connection.exportedObject = InferenceWorker()
    connection.resume()
    return true
  }
}

let listener = NSXPCListener.service()
let delegate = InferenceWorkerListenerDelegate()
listener.delegate = delegate
listener.resume()
