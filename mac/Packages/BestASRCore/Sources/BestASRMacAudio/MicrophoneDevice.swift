import AVFoundation
import AudioToolbox
import BestASRDictation
import CoreAudio
import Foundation

public struct MicrophoneDeviceInfo: Codable, Equatable, Hashable, Identifiable, Sendable {
  public let deviceID: UInt32
  public let uid: String
  public let name: String
  public let transportType: UInt32
  public let isBuiltIn: Bool
  public var id: String { uid }

  public init(
    deviceID: UInt32,
    uid: String,
    name: String,
    transportType: UInt32,
    isBuiltIn: Bool
  ) {
    self.deviceID = deviceID
    self.uid = uid
    self.name = name
    self.transportType = transportType
    self.isBuiltIn = isBuiltIn
  }
}

public enum MicrophoneDeviceCatalog {
  public static func defaultDevice() throws -> MicrophoneDeviceInfo {
    try SystemDefaultInputDeviceProvider().currentDefaultInput()
  }

  public static func devices() throws -> [MicrophoneDeviceInfo] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var byteCount: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &byteCount
      ) == noErr
    else {
      throw MacMicrophoneCaptureError.deviceMetadataUnavailable
    }
    var deviceIDs = [AudioDeviceID](
      repeating: kAudioObjectUnknown,
      count: Int(byteCount) / MemoryLayout<AudioDeviceID>.stride
    )
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &byteCount,
        &deviceIDs
      ) == noErr
    else {
      throw MacMicrophoneCaptureError.deviceMetadataUnavailable
    }
    let defaultDevice = try? SystemDefaultInputDeviceProvider()
      .currentDefaultInput().deviceID
    return deviceIDs.compactMap { deviceID in
      guard hasInputStreams(deviceID) else { return nil }
      guard
        let uid = try? stringProperty(
          deviceID: deviceID,
          selector: kAudioDevicePropertyDeviceUID
        ),
        let name = try? stringProperty(
          deviceID: deviceID,
          selector: kAudioObjectPropertyName
        ),
        let transport = try? uint32Property(
          deviceID: deviceID,
          selector: kAudioDevicePropertyTransportType
        )
      else { return nil }
      return MicrophoneDeviceInfo(
        deviceID: deviceID,
        uid: uid,
        name: defaultDevice == deviceID ? "\(name)（默认）" : name,
        transportType: transport,
        isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn
      )
    }
    .sorted { lhs, rhs in
      if lhs.deviceID == defaultDevice { return true }
      if rhs.deviceID == defaultDevice { return false }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }

  public static func device(uid: String?) throws -> MicrophoneDeviceInfo {
    guard let uid, !uid.isEmpty else {
      return try SystemDefaultInputDeviceProvider().currentDefaultInput()
    }
    guard let device = try devices().first(where: { $0.uid == uid }) else {
      throw MacMicrophoneCaptureError.noDefaultInputDevice
    }
    return device
  }

  static func select(
    deviceID: AudioDeviceID,
    for inputNode: AVAudioInputNode
  ) throws {
    guard let audioUnit = inputNode.audioUnit else {
      throw MacMicrophoneCaptureError.deviceMetadataUnavailable
    }
    var selected = deviceID
    let status = AudioUnitSetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &selected,
      UInt32(MemoryLayout<AudioDeviceID>.stride)
    )
    guard status == noErr else {
      throw MacMicrophoneCaptureError.deviceMetadataUnavailable
    }
  }

  private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(
      deviceID,
      &address,
      0,
      nil,
      &size
    ) == noErr && size > 0
  }

  private static func stringProperty(
    deviceID: AudioDeviceID,
    selector: AudioObjectPropertySelector
  ) throws -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.stride)
    guard
      AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &size,
        &value
      ) == noErr
    else {
      throw MacMicrophoneCaptureError.deviceMetadataUnavailable
    }
    return value as String
  }

  private static func uint32Property(
    deviceID: AudioDeviceID,
    selector: AudioObjectPropertySelector
  ) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.stride)
    guard
      AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &size,
        &value
      ) == noErr
    else {
      throw MacMicrophoneCaptureError.deviceMetadataUnavailable
    }
    return value
  }
}

protocol DefaultInputDeviceProviding: Sendable {
  func currentDefaultInput() throws -> MicrophoneDeviceInfo
}

struct SystemDefaultInputDeviceProvider: DefaultInputDeviceProviding {
  func currentDefaultInput() throws -> MicrophoneDeviceInfo {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else {
      throw MacMicrophoneCaptureError.noDefaultInputDevice
    }
    let uid = try stringProperty(
      deviceID: deviceID,
      selector: kAudioDevicePropertyDeviceUID
    )
    let name = try stringProperty(
      deviceID: deviceID,
      selector: kAudioObjectPropertyName
    )
    let transport = try uint32Property(
      deviceID: deviceID,
      selector: kAudioDevicePropertyTransportType
    )
    return MicrophoneDeviceInfo(
      deviceID: deviceID,
      uid: uid,
      name: name,
      transportType: transport,
      isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn
    )
  }

  private func stringProperty(
    deviceID: AudioDeviceID,
    selector: AudioObjectPropertySelector
  ) throws -> String {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var unmanagedValue: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      &unmanagedValue
    )
    guard status == noErr, let unmanagedValue else {
      throw MacMicrophoneCaptureError.deviceMetadataUnavailable
    }
    return unmanagedValue.takeUnretainedValue() as String
  }

  private func uint32Property(
    deviceID: AudioDeviceID,
    selector: AudioObjectPropertySelector
  ) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &size,
      &value
    )
    guard status == noErr else {
      throw MacMicrophoneCaptureError.deviceMetadataUnavailable
    }
    return value
  }
}
