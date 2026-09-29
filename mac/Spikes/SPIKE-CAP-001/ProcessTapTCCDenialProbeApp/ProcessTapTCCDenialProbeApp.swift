import AppKit
import BestASRProcessTapProbe
import CoreAudio
import Darwin
import Foundation

@main
struct ProcessTapTCCDenialProbeApp {
  static func main() {
    let application = NSApplication.shared
    let delegate = ProcessTapTCCDenialApplicationDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
  }
}

private final class ProcessTapTCCDenialApplicationDelegate: NSObject,
  NSApplicationDelegate, @unchecked Sendable
{
  private static let observationURL = URL(
    fileURLWithPath: "/private/tmp/bestasr-process-tap-tcc-denial.json"
  )

  private var window: NSWindow?
  private var beginButton: NSButton?
  private var statusLabel: NSTextField?
  private var worker: Thread?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "bestASR — 真实系统音频拒绝验证"
    window.center()

    let instructions = NSTextField(wrappingLabelWithString: """
      这一步只播放本地合成水印，不读取或保存任何用户音频。

      点击“开始”后，macOS 会在首次录制时询问“系统音频录制”权限。请在系统弹窗中选择“不允许”；若此前已经拒绝，系统不会重复弹窗。探针会确认水印音频内容不可读取，且临时 Process Tap 和 aggregate device 均已清理、没有残留。
      """)
    instructions.frame = NSRect(x: 28, y: 104, width: 504, height: 118)

    let statusLabel = NSTextField(labelWithString: "尚未触发权限请求。")
    statusLabel.frame = NSRect(x: 28, y: 68, width: 504, height: 22)
    statusLabel.textColor = .secondaryLabelColor

    let beginButton = NSButton(
      title: "开始拒绝验证",
      target: self,
      action: #selector(beginProbe)
    )
    beginButton.bezelStyle = .rounded
    beginButton.frame = NSRect(x: 388, y: 22, width: 144, height: 32)
    beginButton.keyEquivalent = "\r"

    window.contentView?.addSubview(instructions)
    window.contentView?.addSubview(statusLabel)
    window.contentView?.addSubview(beginButton)
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)

    self.window = window
    self.statusLabel = statusLabel
    self.beginButton = beginButton
  }

  @objc private func beginProbe() {
    beginButton?.isEnabled = false
    statusLabel?.stringValue = "正在验证；若系统询问权限，请选择“不允许”…"

    let worker = Thread { [weak self] in
      self?.runProbe()
    }
    worker.name = "bestASR TCC denial probe"
    self.worker = worker
    worker.start()
  }

  private func runProbe() {
    let evidence = Self.observeDenial()
    do {
      try Self.write(evidence, to: Self.observationURL)
    } catch {
      updateUI(
        message: "无法写入临时证据；请关闭窗口并回到 Codex。",
        succeeded: false
      )
      return
    }

    if evidence.denialObserved && evidence.status == "conditional" {
      updateUI(
        message: "已观察到拒绝，且无 HAL 对象泄漏。请回到 Codex 回复“已点不允许”。",
        succeeded: true
      )
    } else {
      updateUI(
        message: "未观察到安全拒绝；证据已失败关闭。请回到 Codex 查看详情。",
        succeeded: false
      )
    }
  }

  private func updateUI(message: String, succeeded: Bool) {
    DispatchQueue.main.async { [weak self] in
      self?.statusLabel?.stringValue = message
      self?.statusLabel?.textColor =
        succeeded ? .systemGreen : .systemRed
      self?.beginButton?.title = "验证已结束"
    }
  }

  private static func observeDenial() -> ProcessTapTCCDenialEvidence {
    try? FileManager.default.removeItem(at: observationURL)

    let runID = UUID()
    let bundleIdentifier =
      Bundle.main.bundleIdentifier
      ?? "missing-probe-bundle-identifier"
    let beforeTapCount = (try? CoreAudioHAL.tapCount()) ?? -1
    let beforeAggregateCount =
      (try? CoreAudioHAL.aggregateDeviceCount()) ?? -1
    var afterTapCount = beforeTapCount
    var afterAggregateCount = beforeAggregateCount
    var tapCreated = false
    var createTapStatus = Int32.min
    var captureStarted = false
    var startCaptureStatus = Int32.min
    var callbackCount: UInt64 = 0
    var frameCount = 0
    var capturedRMS = 0.0
    var capturedWatermarkAmplitude = 0.0
    var watermarkDetected = false
    var audioContentSuppressed = false
    var failureCategory = "probe-did-not-reach-tap-creation"

    let player = Process()
    player.executableURL = syntheticPlayerURL()
    player.arguments = [
      "--frequency", "18300",
      "--amplitude", "0.02",
      "--lead-in", "0",
      "--duration", "300",
    ]
    player.standardOutput = FileHandle.nullDevice
    player.standardError = FileHandle.nullDevice

    do {
      try player.run()
      defer {
        if player.isRunning {
          player.terminate()
        }
        player.waitUntilExit()
      }

      let source = try CoreAudioHAL.process(
        for: player.processIdentifier,
        timeout: 8
      )
      do {
        let session = try ProcessTapCaptureSession(
          processObjectIDs: [source.objectID],
          maximumDuration: 1
        )
        tapCreated = true
        createTapStatus = kAudioHardwareNoError
        defer { session.close() }

        do {
          try session.start()
          captureStarted = true
          startCaptureStatus = kAudioHardwareNoError
          Thread.sleep(forTimeInterval: 1.0)
          let snapshot = session.finish()
          callbackCount = snapshot.callbackCount
          frameCount = snapshot.frameCount
          capturedRMS = WatermarkDetector.rootMeanSquare(snapshot.samples)
          let watermark = WatermarkDetector.measure(
            samples: snapshot.samples,
            sampleRate: snapshot.sampleRate,
            frequency: 18_300
          )
          capturedWatermarkAmplitude = watermark.amplitude
          watermarkDetected = watermark.detected
          audioContentSuppressed =
            callbackCount > 0
            && frameCount >= 128
            && capturedRMS <= 0.000_001
            && capturedWatermarkAmplitude < 0.001
            && !watermarkDetected
          failureCategory = audioContentSuppressed
            ? "audio-content-suppressed-awaiting-operator-confirmation"
            : "audio-content-accessible-permission-was-not-denied"
        } catch CoreAudioProbeError.osStatus(let operation, let status)
          where operation == "start-tap-io"
        {
          startCaptureStatus = status
          audioContentSuppressed = true
          failureCategory =
            "start-tap-io-rejected-awaiting-operator-confirmation"
        } catch {
          failureCategory = "unexpected-capture-start-error"
        }
      } catch CoreAudioProbeError.osStatus(let operation, let status)
        where operation == "create-process-tap"
      {
        createTapStatus = status
        failureCategory =
          "create-process-tap-rejected-before-recording"
      } catch {
        failureCategory = "unexpected-tap-creation-error"
      }
    } catch {
      failureCategory = "synthetic-source-launch-or-discovery-failed"
    }

    Thread.sleep(forTimeInterval: 0.25)
    afterTapCount = (try? CoreAudioHAL.tapCount()) ?? -1
    afterAggregateCount =
      (try? CoreAudioHAL.aggregateDeviceCount()) ?? -1
    let deniedBeforeIOStart =
      !captureStarted
      && startCaptureStatus != Int32.min
      && startCaptureStatus != kAudioHardwareNoError
      && audioContentSuppressed
    let deniedByContentSuppression =
      captureStarted
      && startCaptureStatus == kAudioHardwareNoError
      && callbackCount > 0
      && frameCount >= 128
      && capturedRMS <= 0.000_001
      && capturedWatermarkAmplitude < 0.001
      && audioContentSuppressed
      && !watermarkDetected
    let denialObserved =
      tapCreated
      && createTapStatus == kAudioHardwareNoError
      && (deniedBeforeIOStart || deniedByContentSuppression)
      && beforeTapCount >= 0
      && beforeTapCount == afterTapCount
      && beforeAggregateCount >= 0
      && beforeAggregateCount == afterAggregateCount
    let status = denialObserved ? "conditional" : "fail"

    return ProcessTapTCCDenialEvidence(
      runID: runID,
      generatedAt: Date(),
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      hardwareArchitecture: architecture,
      probeBundleIdentifier: bundleIdentifier,
      status: status,
      denialObserved: denialObserved,
      operatorConfirmedDenial: false,
      tapCreated: tapCreated,
      createTapStatus: createTapStatus,
      captureStarted: captureStarted,
      startCaptureStatus: startCaptureStatus,
      callbackCount: callbackCount,
      frameCount: frameCount,
      capturedRMS: capturedRMS,
      capturedWatermarkAmplitude: capturedWatermarkAmplitude,
      watermarkDetected: watermarkDetected,
      audioContentSuppressed: audioContentSuppressed,
      tapCountBefore: beforeTapCount,
      tapCountAfter: afterTapCount,
      aggregateDeviceCountBefore: beforeAggregateCount,
      aggregateDeviceCountAfter: afterAggregateCount,
      syntheticSourceOnly: true,
      sourceAudioPersisted: false,
      failureCategory: failureCategory
    )
  }

  private static func syntheticPlayerURL() -> URL {
    Bundle.main.bundleURL
      .deletingLastPathComponent()
      .appendingPathComponent("SelectedWatermarkPlayer.app")
      .appendingPathComponent("Contents/MacOS/SelectedWatermarkPlayer")
  }

  private static func write<T: Encodable>(
    _ value: T,
    to url: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [
      .prettyPrinted,
      .sortedKeys,
      .withoutEscapingSlashes,
    ]
    try encoder.encode(value).write(to: url, options: .atomic)
  }

  private static var architecture: String {
    #if arch(arm64)
      return "arm64"
    #else
      return "unsupported"
    #endif
  }
}
