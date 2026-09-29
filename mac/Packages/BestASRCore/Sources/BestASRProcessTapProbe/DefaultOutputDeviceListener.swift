import CoreAudio
import Foundation

final class DefaultOutputDeviceListener: @unchecked Sendable {
  private let condition = NSCondition()
  private let queue = DispatchQueue(
    label: "com.bestasr.spike.cap.default-output-listener"
  )
  private var observations: [(deviceID: AudioObjectID, timestamp: UInt64)] = []
  private var listenerBlock: AudioObjectPropertyListenerBlock?

  init() throws {
    var address = CoreAudioHAL.propertyAddress(
      selector: kAudioHardwarePropertyDefaultOutputDevice
    )
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self,
        let deviceID = try? CoreAudioHAL.defaultOutputDeviceID()
      else {
        return
      }
      condition.lock()
      observations.append(
        (deviceID: deviceID, timestamp: DispatchTime.now().uptimeNanoseconds)
      )
      condition.broadcast()
      condition.unlock()
    }
    listenerBlock = block
    try CoreAudioHAL.check(
      AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        queue,
        block
      ),
      operation: "listen-default-output"
    )
  }

  deinit {
    guard let listenerBlock else { return }
    var address = CoreAudioHAL.propertyAddress(
      selector: kAudioHardwarePropertyDefaultOutputDevice
    )
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      queue,
      listenerBlock
    )
  }

  func wait(
    for deviceID: AudioObjectID,
    timeout: TimeInterval
  ) -> UInt64? {
    let deadline = Date().addingTimeInterval(timeout)
    condition.lock()
    defer { condition.unlock() }
    while true {
      if let observation = observations.first(where: {
        $0.deviceID == deviceID
      }) {
        return observation.timestamp
      }
      guard condition.wait(until: deadline) else { return nil }
    }
  }

  var notificationCount: Int {
    condition.lock()
    defer { condition.unlock() }
    return observations.count
  }
}
