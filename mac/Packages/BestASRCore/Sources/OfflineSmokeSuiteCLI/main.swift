import BestASROfflineProbe
import Darwin
import Foundation

private enum CLIError: Error {
  case invalidArguments
  case probeFailed
}

private func verifyNetworkDenied() -> NetworkDenialProbeResult {
  let descriptor = socket(AF_INET, SOCK_STREAM, 0)
  if descriptor < 0 {
    let code = errno
    return NetworkDenialProbeResult(
      attempted: true,
      blocked: code == EPERM || code == EACCES,
      errorCode: code
    )
  }
  defer {
    close(descriptor)
  }

  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = in_port_t(9).bigEndian
  _ = "127.0.0.1".withCString {
    inet_pton(AF_INET, $0, &address.sin_addr)
  }
  let result = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  let code = result == 0 ? 0 : errno
  return NetworkDenialProbeResult(
    attempted: true,
    blocked: result != 0 && (code == EPERM || code == EACCES),
    errorCode: code
  )
}

private func run(summaryURL: URL) throws {
  let report = OfflineSmokeReport(
    runID: UUID(),
    networkDenialProbe: verifyNetworkDenied(),
    localResult: LocalOfflineSmokeSuite.run()
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  try FileManager.default.createDirectory(
    at: summaryURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try encoder.encode(report).write(to: summaryURL, options: .atomic)
  guard report.status == .pass else {
    throw CLIError.probeFailed
  }
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard arguments.count == 2, arguments[0] == "--summary" else {
    throw CLIError.invalidArguments
  }
  try run(summaryURL: URL(fileURLWithPath: arguments[1]))
  print("offline smoke suite passed")
} catch {
  FileHandle.standardError.write(Data("offline smoke suite failed: \(error)\n".utf8))
  exit(1)
}
