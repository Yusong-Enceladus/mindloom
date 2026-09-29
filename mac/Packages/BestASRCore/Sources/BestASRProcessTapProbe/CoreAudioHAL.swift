import AppKit
import CoreAudio
import Darwin
import Foundation

public enum CoreAudioProbeError: Error, CustomStringConvertible {
  case invalidData(String)
  case osStatus(operation: String, status: OSStatus)
  case unavailable(String)

  public var description: String {
    switch self {
    case .invalidData(let detail):
      return "invalid-data:\(detail)"
    case .osStatus(let operation, let status):
      return "\(operation):\(Self.describe(status))"
    case .unavailable(let detail):
      return "unavailable:\(detail)"
    }
  }

  private static func describe(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes: [UInt8] = [
      UInt8((value >> 24) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff),
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
      return "\(status)(\(String(bytes: bytes, encoding: .ascii) ?? "????"))"
    }
    return String(status)
  }
}

public enum CoreAudioHAL {
  public static func audioProcesses() throws -> [AudioProcessSnapshot] {
    let processIDs = try objectIDArray(
      objectID: AudioObjectID(kAudioObjectSystemObject),
      selector: kAudioHardwarePropertyProcessObjectList
    )

    return processIDs.compactMap { objectID in
      do {
        let processID: Int32 = try scalar(
          objectID: objectID,
          selector: kAudioProcessPropertyPID
        )
        let bundleID =
          (try? string(
            objectID: objectID,
            selector: kAudioProcessPropertyBundleID
          )) ?? ""
        let running: UInt32 =
          (try? scalar(
            objectID: objectID,
            selector: kAudioProcessPropertyIsRunningOutput
          )) ?? 0
        let runningApplication = NSRunningApplication(
          processIdentifier: processID
        )
        let displayName =
          runningApplication?.localizedName
          ?? processName(processID)
          ?? (bundleID.isEmpty ? "Unknown" : bundleID)
        return AudioProcessSnapshot(
          objectID: objectID,
          processID: processID,
          parentProcessID: parentProcessID(processID),
          bundleID: bundleID,
          displayName: displayName,
          isRunningOutput: running != 0
        )
      } catch {
        return nil
      }
    }
  }

  public static func process(
    for processID: Int32,
    timeout: TimeInterval = 5
  ) throws -> AudioProcessSnapshot {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let process = try audioProcesses().first(where: {
        $0.processID == processID
      }) {
        return process
      }
      Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    throw CoreAudioProbeError.unavailable("audio-process-timeout")
  }

  public static func outputDevices() throws -> [AudioOutputDeviceSnapshot] {
    let defaultID = try defaultOutputDeviceID()
    let deviceIDs = try objectIDArray(
      objectID: AudioObjectID(kAudioObjectSystemObject),
      selector: kAudioHardwarePropertyDevices
    )

    return deviceIDs.compactMap { objectID in
      var address = propertyAddress(
        selector: kAudioDevicePropertyStreams,
        scope: kAudioDevicePropertyScopeOutput
      )
      var size: UInt32 = 0
      guard
        AudioObjectGetPropertyDataSize(
          objectID,
          &address,
          0,
          nil,
          &size
        ) == kAudioHardwareNoError, size > 0
      else {
        return nil
      }

      // Route selection needs neither labels nor UIDs. Do not request them:
      // they can be permission-restricted and the evidence intentionally
      // keeps hardware identity out of the persisted result.
      let uid = ""
      let name = ""
      let isAlive: UInt32? = try? scalar(
        objectID: objectID,
        selector: kAudioDevicePropertyDeviceIsAlive
      )
      // Some permission contexts do not expose this optional diagnostic.
      // Exclude only an endpoint that HAL explicitly reports as dead; the
      // live device list plus a nonempty output stream remains authoritative.
      if let isAlive, isAlive == 0 { return nil }
      let transport: UInt32
      do {
        transport = try scalar(
          objectID: objectID,
          selector: kAudioDevicePropertyTransportType
        )
      } catch {
        return nil
      }
      return AudioOutputDeviceSnapshot(
        objectID: objectID,
        uid: uid,
        name: name,
        transportType: transport,
        isDefaultOutput: objectID == defaultID
      )
    }
    .sorted { lhs, rhs in
      if lhs.isDefaultOutput != rhs.isDefaultOutput {
        return lhs.isDefaultOutput && !rhs.isDefaultOutput
      }
      if lhs.name == rhs.name {
        return lhs.objectID < rhs.objectID
      }
      return lhs.name < rhs.name
    }
  }

  public static func defaultOutputDeviceID() throws -> AudioObjectID {
    try scalar(
      objectID: AudioObjectID(kAudioObjectSystemObject),
      selector: kAudioHardwarePropertyDefaultOutputDevice
    )
  }

  public static func defaultOutputDeviceIsSettable() throws -> Bool {
    var address = propertyAddress(
      selector: kAudioHardwarePropertyDefaultOutputDevice
    )
    var isSettable = DarwinBoolean(false)
    try check(
      AudioObjectIsPropertySettable(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        &isSettable
      ),
      operation: "default-output-settable"
    )
    return isSettable.boolValue
  }

  public static func setDefaultOutputDeviceID(
    _ deviceID: AudioObjectID
  ) throws {
    var address = propertyAddress(
      selector: kAudioHardwarePropertyDefaultOutputDevice
    )
    var value = deviceID
    try check(
      AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        UInt32(MemoryLayout<AudioObjectID>.stride),
        &value
      ),
      operation: "set-default-output"
    )
  }

  public static func alternatePhysicalOutputDevice(
    from devices: [AudioOutputDeviceSnapshot],
    excluding deviceID: AudioObjectID
  ) -> AudioOutputDeviceSnapshot? {
    devices
      .filter {
        $0.objectID != deviceID
          && $0.transportType != kAudioDeviceTransportTypeAggregate
          && $0.transportType != kAudioDeviceTransportTypeVirtual
      }
      .sorted { $0.objectID < $1.objectID }
      .first
  }

  public static func tapCount() throws -> Int {
    try objectIDArray(
      objectID: AudioObjectID(kAudioObjectSystemObject),
      selector: kAudioHardwarePropertyTapList
    ).count
  }

  public static func aggregateDeviceCount() throws -> Int {
    try objectIDArray(
      objectID: AudioObjectID(kAudioObjectSystemObject),
      selector: kAudioHardwarePropertyDevices
    ).filter { objectID in
      let transport: UInt32? = try? scalar(
        objectID: objectID,
        selector: kAudioDevicePropertyTransportType
      )
      return transport == kAudioDeviceTransportTypeAggregate
    }.count
  }

  static func propertyAddress(
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: scope,
      mElement: element
    )
  }

  static func check(_ status: OSStatus, operation: String) throws {
    guard status == kAudioHardwareNoError else {
      throw CoreAudioProbeError.osStatus(
        operation: operation,
        status: status
      )
    }
  }

  static func scalar<T: BitwiseCopyable>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) throws -> T {
    var address = propertyAddress(selector: selector, scope: scope)
    var size = UInt32(MemoryLayout<T>.stride)
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: MemoryLayout<T>.stride,
      alignment: MemoryLayout<T>.alignment
    )
    storage.initializeMemory(
      as: UInt8.self,
      repeating: 0,
      count: MemoryLayout<T>.stride
    )
    defer { storage.deallocate() }
    try check(
      AudioObjectGetPropertyData(
        objectID,
        &address,
        0,
        nil,
        &size,
        storage
      ),
      operation: "get-\(selector)"
    )
    guard size == MemoryLayout<T>.stride else {
      throw CoreAudioProbeError.invalidData("scalar-size")
    }
    return storage.load(as: T.self)
  }

  static func string(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) throws -> String {
    var address = propertyAddress(selector: selector)
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.stride)
    try withUnsafeMutablePointer(to: &value) { pointer in
      try check(
        AudioObjectGetPropertyData(
          objectID,
          &address,
          0,
          nil,
          &size,
          pointer
        ),
        operation: "get-string-\(selector)"
      )
    }
    return value as String
  }

  static func objectIDArray(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
  ) throws -> [AudioObjectID] {
    var address = propertyAddress(selector: selector)
    var size: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(
        objectID,
        &address,
        0,
        nil,
        &size
      ),
      operation: "get-array-size-\(selector)"
    )
    guard size > 0 else { return [] }
    var values = [AudioObjectID](
      repeating: kAudioObjectUnknown,
      count: Int(size) / MemoryLayout<AudioObjectID>.stride
    )
    try check(
      AudioObjectGetPropertyData(
        objectID,
        &address,
        0,
        nil,
        &size,
        &values
      ),
      operation: "get-array-\(selector)"
    )
    return values
  }

  private static func parentProcessID(_ processID: Int32) -> Int32 {
    var info = kinfo_proc()
    var length = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
    guard sysctl(&mib, 4, &info, &length, nil, 0) == 0, length > 0 else {
      return 0
    }
    return info.kp_eproc.e_ppid
  }

  private static func processName(_ processID: Int32) -> String? {
    var info = kinfo_proc()
    var length = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
    guard sysctl(&mib, 4, &info, &length, nil, 0) == 0, length > 0 else {
      return nil
    }
    return withUnsafePointer(to: info.kp_proc.p_comm) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
        String(cString: $0)
      }
    }
  }
}
