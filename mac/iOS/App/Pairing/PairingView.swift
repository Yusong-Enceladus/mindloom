@preconcurrency import AVFoundation
import MindloomLink
import SwiftUI
import UIKit

/// First run: connect this phone to the Mac by scanning the QR code from
/// 「连接 iPhone」 or pasting the pairing text (PHONE-CONTRACT §4).
struct PairingView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  var allowsLater: Bool

  @State private var scanning = false
  @State private var error: String?
  @State private var paired: String?

  var body: some View {
    ZStack {
      Loom.page.ignoresSafeArea()
      if let paired {
        success(paired)
      } else {
        content
      }
    }
    .sheet(isPresented: $scanning) {
      ScannerSheet { text in
        scanning = false
        accept(text)
      }
    }
  }

  private var content: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 24)
      Image("Mark")
        .resizable()
        .interpolation(.high)
        .frame(width: 96, height: 96)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .accessibilityHidden(true)
      Text("把织机接到你的 Mac")
        .font(.loom(26, .semibold))
        .foregroundStyle(Loom.ink)
        .padding(.top, 22)
      Text("在手机上说的话、分享的东西，会锁好后交给你的 Mac 整理。")
        .font(.loom(15))
        .foregroundStyle(Loom.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 8)
        .padding(.horizontal, 12)

      LoomCard(padding: 18) {
        VStack(alignment: .leading, spacing: 10) {
          Step(number: 1, text: "在 Mac 上打开织机：设置 → Spark 连接")
          Step(number: 2, text: "点「连接 iPhone」，屏幕上会出现一个二维码")
          Step(number: 3, text: "用下面的按钮扫码；或在 Mac 上点「复制配对码」，再到这里粘贴")
        }
      }
      .padding(.top, 26)

      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.loom(14))
          .foregroundStyle(Loom.red)
          .padding(.top, 14)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 24)

      VStack(spacing: 12) {
        Button {
          error = nil
          scanning = true
        } label: {
          Label("扫描二维码", systemImage: "qrcode.viewfinder")
        }
        .buttonStyle(LoomPrimaryButtonStyle())

        PasteButton(payloadType: String.self) { strings in
          guard let text = strings.first else { return }
          Task { @MainActor in accept(text) }
        }
        .buttonBorderShape(.capsule)
        .labelStyle(.titleAndIcon)
        .controlSize(.large)
        .tint(Loom.accent)
        .accessibilityLabel("粘贴配对码")

        if allowsLater {
          Button("以后再说") { model.deferPairing() }
            .font(.loom(15))
            .foregroundStyle(Loom.secondary)
            .padding(.top, 4)
        }
      }
      .padding(.bottom, 12)
    }
    .padding(.horizontal, 24)
  }

  private func success(_ label: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 64))
        .foregroundStyle(Loom.green)
        .symbolEffect(.bounce, value: paired)
      Text("已连接").font(.loom(26, .semibold)).foregroundStyle(Loom.ink)
      Text(label).font(.loom(17)).foregroundStyle(Loom.secondary)
      Text("从现在起，织机键盘说的话和「收进织机」分享的东西，都会锁好后送到这台 Mac。")
        .font(.loom(14))
        .foregroundStyle(Loom.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
      Button("好") {
        model.showsPairing = false
        dismiss()
      }
      .buttonStyle(LoomPrimaryButtonStyle())
      .padding(.horizontal, 24)
      .padding(.top, 16)
    }
  }

  private func accept(_ text: String) {
    do {
      let record = try model.pairing.pair(text: text)
      error = nil
      withAnimation(.spring(duration: 0.4)) { paired = record.label }
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      Task { await model.delivery.deliver() }
    } catch {
      self.error = PairingModel.message(for: error)
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
  }
}

/// The camera sheet. Scans QR codes only and hands over the first
/// `mlpair1.` text; nothing is recorded or saved.
struct ScannerSheet: View {
  let onCode: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var denied = false
  @State private var noCamera = AVCaptureDevice.default(for: .video) == nil

  var body: some View {
    NavigationStack {
      ZStack {
        Color.black.ignoresSafeArea()
        if noCamera || denied {
          VStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.system(size: 36)).foregroundStyle(
              .white.opacity(0.7))
            Text(noCamera ? "这台设备没有相机" : "织机没有相机权限")
              .font(.loom(17, .semibold)).foregroundStyle(.white)
            Text(noCamera ? "请在 Mac 上点「复制配对码」，再回来粘贴。" : "请在设置里允许织机使用相机，或改用粘贴配对码。")
              .font(.loom(14)).foregroundStyle(.white.opacity(0.7))
              .multilineTextAlignment(.center)
              .padding(.horizontal, 32)
          }
        } else {
          QRScannerView(onCode: onCode, onDenied: { denied = true })
            .ignoresSafeArea()
          RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(.white.opacity(0.9), lineWidth: 3)
            .frame(width: 250, height: 250)
          VStack {
            Spacer()
            Text("对准 Mac 上的配对二维码")
              .font(.loom(15, .medium))
              .foregroundStyle(.white)
              .padding(.horizontal, 16)
              .padding(.vertical, 10)
              .background(.black.opacity(0.45), in: Capsule())
              .padding(.bottom, 48)
          }
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("取消") { dismiss() }.foregroundStyle(.white)
        }
      }
    }
  }
}

struct QRScannerView: UIViewControllerRepresentable {
  let onCode: (String) -> Void
  let onDenied: () -> Void

  func makeUIViewController(context: Context) -> QRScannerController {
    let controller = QRScannerController()
    controller.onCode = onCode
    controller.onDenied = onDenied
    return controller
  }

  func updateUIViewController(_ controller: QRScannerController, context: Context) {}
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  var onCode: ((String) -> Void)?
  var onDenied: (() -> Void)?
  private let session = AVCaptureSession()
  private var preview: AVCaptureVideoPreviewLayer?
  private var delivered = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    Task { @MainActor in
      let allowed: Bool
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized: allowed = true
      case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
      default: allowed = false
      }
      guard allowed else {
        onDenied?()
        return
      }
      configure()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview?.frame = view.bounds
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    let session = session
    DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
  }

  private func configure() {
    guard let camera = AVCaptureDevice.default(for: .video),
      let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input)
    else { return }
    session.addInput(input)
    let output = AVCaptureMetadataOutput()
    guard session.canAddOutput(output) else { return }
    session.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: .main)
    output.metadataObjectTypes = [.qr]
    let layer = AVCaptureVideoPreviewLayer(session: session)
    layer.videoGravity = .resizeAspectFill
    layer.frame = view.bounds
    view.layer.addSublayer(layer)
    preview = layer
    let session = session
    DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
  }

  nonisolated func metadataOutput(
    _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    let texts = metadataObjects.compactMap {
      ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue
    }
    MainActor.assumeIsolated {
      guard !delivered, let code = texts.first(where: { $0.hasPrefix(PairingPayload.prefix) })
      else {
        return
      }
      delivered = true
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      onCode?(code)
    }
  }
}
