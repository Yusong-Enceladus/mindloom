import CryptoKit
@preconcurrency import AVFoundation
import MindloomDesign
import MindloomLink
import SwiftUI
import UIKit

/// Pairing with the Mac (PHONE-SPEC §5.2): the live camera with yellow brackets that search, then
/// lock onto the Mac's code; the found sheet 「连接 {Mac}？」; or 「改用配对码」 to paste the code.
struct PairView: View {
  @Environment(AppModel.self) private var model
  /// The appearance outside the camera (the sheets follow it; the camera itself is dark).
  let scheme: ColorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var lock: CGRect?
  @State private var found: FoundCode?
  @State private var showsPaste = false
  @State private var cameraAllowed = PairView.cameraStatus()
  @State private var scanning = true
  /// Why the last 连接 did not work (kept on the found sheet).
  @State private var confirmError: String?

  struct FoundCode: Identifiable {
    let text: String
    let macName: String
    var id: String { text }
  }

  var body: some View {
    GeometryReader { proxy in
      let insets = proxy.safeAreaInsets
      let size = CGSize(
        width: proxy.size.width, height: proxy.size.height + insets.top + insets.bottom)
      ZStack(alignment: .topLeading) {
        Color.black
        camera(size: size, top: insets.top)
        Brackets(searching: searchRect(size: size, top: insets.top), locked: lock)
          .animation(reduceMotion ? .easeOut(duration: 0.2) : MLMotion.springSmooth, value: lock)
        closeButton.padding(.leading, 16).padding(.top, insets.top + 4)
        VStack {
          Spacer()
          bottomCard(bottom: insets.bottom)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
      }
      .frame(width: size.width, height: size.height)
      .ignoresSafeArea()
    }
    .preferredColorScheme(.dark)
    .sheet(item: $found) { code in
      FoundSheet(macName: code.macName, error: confirmError) {
        confirm(code.text)
      } cancel: {
        found = nil
        lock = nil
        scanning = true
        confirmError = nil
      }
      .environment(\.colorScheme, scheme)
      .preferredColorScheme(scheme)
    }
    .sheet(isPresented: $showsPaste) {
      PasteSheet { text in
        showsPaste = false
        Task {
          try? await Task.sleep(for: .seconds(0.4))
          found = FoundCode(text: text, macName: Self.macName(text) ?? "Mac")
        }
      }
      .environment(\.colorScheme, scheme)
      .preferredColorScheme(scheme)
    }
    .task { await askForCamera() }
    .onAppear {
      if let code = model.pendingPairCode, let name = Self.macName(code) {
        model.pendingPairCode = nil
        scanning = false
        found = FoundCode(text: code, macName: name)
      }
      #if DEBUG
        DebugLaunch.applyPair(lock: &lock, found: &found, paste: &showsPaste)
      #endif
    }
  }

  private func searchRect(size: CGSize, top: CGFloat) -> CGRect {
    // the 248 square around where the code is expected (centre 201, 313 at 402 × 874, sb 54)
    CGRect(x: size.width / 2 - 124, y: top + 259 - 124, width: 248, height: 248)
  }

  @ViewBuilder
  private func camera(size: CGSize, top: CGFloat) -> some View {
    #if DEBUG
      if DebugLaunch.syntheticCamera {
        DebugCameraBackdrop(size: size, top: top)
      } else {
        liveCamera
      }
    #else
      liveCamera
    #endif
  }

  @ViewBuilder
  private var liveCamera: some View {
    if cameraAllowed == .authorized {
      QRCameraView(active: scanning) { text, bounds in
        guard scanning, let name = Self.macName(text) else { return }
        scanning = false
        lock = bounds.insetBy(dx: -9, dy: -9)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
          try? await Task.sleep(for: .seconds(0.6))
          found = FoundCode(text: Self.pairingText(text), macName: name)
        }
      }
    }
  }

  private var closeButton: some View {
    Button {
      model.closePairing()
    } label: {
      Image(systemName: "xmark")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .glassEffect(
      .regular.tint(Color(red: 40 / 255, green: 38 / 255, blue: 35 / 255).opacity(0.45))
        .interactive(), in: Circle()
    )
    .accessibilityLabel("关闭")
  }

  private func bottomCard(bottom: CGFloat) -> some View {
    VStack(spacing: 0) {
      Text("扫描 Mac 上的二维码")
        .font(PhoneTitleFont.font(20))
        .foregroundStyle(.white)
        .frame(height: 26)
      BodyText(
        text: "在 Mac 上的 Mindloom 中打开\n“设置”>“设备与隐私”>“连接 iPhone”。", size: 15, lineHeight: 21,
        color: MLColor(fixed: MLRGBA(255, 255, 255, 0.74)), alignment: .center
      )
      .padding(.top, 6)
      .padding(.bottom, 16)
      BlockButton("改用配对码", kind: .onDark) { showsPaste = true }
    }
    .padding(EdgeInsets(top: 22, leading: 24, bottom: max(16, bottom - 6), trailing: 24))
    .frame(maxWidth: .infinity)
    .glassEffect(
      .regular.tint(Color(red: 28 / 255, green: 26 / 255, blue: 23 / 255).opacity(0.62)),
      in: RoundedRectangle(cornerRadius: 38, style: .continuous))
  }

  private func confirm(_ text: String) {
    do {
      try model.confirmPairing(text)
      confirmError = nil
      found = nil
    } catch {
      // Say why on the sheet (a keychain that refuses the key, a code that no longer decodes).
      confirmError = PairingModel.message(for: error)
    }
  }

  private func askForCamera() async {
    #if DEBUG
      if DebugLaunch.syntheticCamera && !DebugLaunch.asksForCamera { return }
    #endif
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .notDetermined:
      let granted = await AVCaptureDevice.requestAccess(for: .video)
      cameraAllowed = granted ? .authorized : .denied
      // 不允许 → the paste sheet opens directly.
      if !granted { showsPaste = true }
    case .authorized:
      cameraAllowed = .authorized
    default:
      cameraAllowed = .denied
      showsPaste = true
    }
  }

  static func cameraStatus() -> AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .video)
  }

  /// `mlpair1.…` itself, or `mindloom://pair/mlpair1.…`.
  static func pairingText(_ scanned: String) -> String {
    let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("mindloom://pair/") {
      return String(trimmed.dropFirst("mindloom://pair/".count))
    }
    return trimmed
  }

  /// The Mac's name from a valid code, nil for anything else.
  static func macName(_ scanned: String) -> String? {
    try? PairingPayload.decode(text: pairingText(scanned)).label
  }
}

/// Four yellow corners: searching (34 pt corners at 70 %) around the expected area, or locked
/// (24 pt at 100 %) tight around the code.
struct Brackets: View {
  let searching: CGRect
  let locked: CGRect?

  var body: some View {
    let rect = locked ?? searching
    let corner: CGFloat = locked == nil ? 34 : 24
    BracketShape(corner: corner)
      .stroke(
        Color(red: 1, green: 0xD6 / 255, blue: 0x0A / 255),
        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
      )
      .frame(width: rect.width, height: rect.height)
      .offset(x: rect.minX, y: rect.minY)
      .opacity(locked == nil ? 0.7 : 1)
      .allowsHitTesting(false)
  }
}

struct BracketShape: Shape {
  var corner: CGFloat
  var radius: CGFloat = 12

  var animatableData: CGFloat {
    get { corner }
    set { corner = newValue }
  }

  func path(in rect: CGRect) -> Path {
    var p = Path()
    let r = min(radius, corner)
    let c = corner
    // top left
    p.move(to: CGPoint(x: rect.minX, y: rect.minY + c))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
    p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: rect.origin)
    p.addLine(to: CGPoint(x: rect.minX + c, y: rect.minY))
    // top right
    p.move(to: CGPoint(x: rect.maxX - c, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
    p.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + c))
    // bottom right
    p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
    p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
    p.addQuadCurve(
      to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
    // bottom left
    p.move(to: CGPoint(x: rect.minX + c, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
    p.addQuadCurve(
      to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
    p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - c))
    return p
  }
}

/// 「连接 小林的 MacBook Pro？」: a solid sheet with the laptop, the sentence, 连接 and 取消.
struct FoundSheet: View {
  let macName: String
  var error: String? = nil
  let connect: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      Image(systemName: "laptopcomputer")
        .font(.system(size: 31, weight: .thin))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(MLColor.ink2)
        .frame(height: 40)
        .padding(.top, 18)
      TrimmedTitle(text: "连接 \(macName)？")
        .padding(.top, 8)
        .padding(.horizontal, 8)
      BodyText(
        text: "之后你在 iPhone 上口述和分享的内容\n会发送到这台 Mac。", size: 15, lineHeight: 21,
        color: .ink2, alignment: .center
      )
      .fixedSize(horizontal: false, vertical: true)
      .padding(EdgeInsets(top: 6, leading: 8, bottom: error == nil ? 22 : 8, trailing: 8))
      if let error {
        Text(error)
          .font(.system(size: 13))
          .foregroundStyle(MLColor.alert)
          .multilineTextAlignment(.center)
          .padding(.bottom, 14)
      }
      BlockButton("连接", action: connect)
      BlockButton("取消", kind: .neutral, action: cancel)
        .padding(.top, 10)
    }
    .fittedSheet(estimate: 292)
    .presentationDragIndicator(.visible)
    .presentationBackground(MLColor.surface)
    .presentationCornerRadius(38)
  }
}

/// 「粘贴配对码」: the field with 粘贴, and 连接 once there is a code.
struct PasteSheet: View {
  let onCode: (String) -> Void
  @State private var code = ""
  @State private var error: String?

  /// What the field shows: the code's short form once a whole code is in; typing or pasting into
  /// the field replaces it, deleting from the short form clears it.
  private var displayBinding: Binding<String> {
    Binding(
      get: { PairingCodeDisplay.short(code) ?? code },
      set: { new in
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == PairingCodeDisplay.short(code) { return }
        if PairingCodeDisplay.short(code) != nil, !trimmed.contains("mlpair") {
          code = ""
        } else {
          code = trimmed
        }
        error = nil
      })
  }

  var body: some View {
    VStack(spacing: 0) {
      Text("粘贴配对码")
        .font(PhoneTitleFont.font(20))
        .foregroundStyle(MLColor.ink)
        .frame(height: 26)
        .padding(.top, 26)
      BodyText(
        text: "在 Mac 上点按“拷贝配对码”，然后返回这里。", size: 15, lineHeight: 21, color: .ink2,
        alignment: .center
      )
      .padding(EdgeInsets(top: 6, leading: 8, bottom: 22, trailing: 8))
      HStack(spacing: 8) {
        // The code is long (a sealed payload); the field shows its short, grouped form and keeps
        // the whole code in `code` (never cut with 「…」, PHONE-SPEC §6.0).
        TextField(
          "", text: displayBinding,
          prompt: Text("配对码").foregroundStyle(MLColor.ink3)
        )
        .font(.system(size: 17).monospacedDigit())
        .tracking(0.34)
        .foregroundStyle(MLColor.ink)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .lineLimit(1)
        TintedPasteButton { text in
          code = text.trimmingCharacters(in: .whitespacesAndNewlines)
          error = nil
        }
        .frame(width: 66, height: 36)
      }
      .padding(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
      .frame(height: 52)
      .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MLColor.surface))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(MLColor.rule2, lineWidth: 0.5))
      if let error {
        Text(error)
          .font(.system(size: 13))
          .foregroundStyle(MLColor.alert)
          .padding(.top, 8)
      }
      BlockButton("连接") {
        let text = PairView.pairingText(code)
        do {
          _ = try PairingPayload.decode(text: text)
          onCode(text)
        } catch {
          self.error = PairingModel.message(for: error)
        }
      }
      .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .padding(.top, 16)
    }
    .fittedSheet(estimate: 252)
    .presentationDragIndicator(.visible)
    .presentationBackground(MLColor.surface)
    .presentationCornerRadius(38)
    .onAppear {
      #if DEBUG
        if let filled = DebugLaunch.pastedCode { code = filled }
      #endif
    }
  }
}

/// The live camera: aspect fill, QR metadata only; reports each code with its bounds in view
/// coordinates. Nothing is recorded or saved.
struct QRCameraView: UIViewControllerRepresentable {
  let active: Bool
  let onCode: (String, CGRect) -> Void

  func makeUIViewController(context: Context) -> QRCameraController {
    let controller = QRCameraController()
    controller.onCode = onCode
    return controller
  }

  func updateUIViewController(_ controller: QRCameraController, context: Context) {
    controller.onCode = onCode
    controller.active = active
  }
}

final class QRCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  var onCode: ((String, CGRect) -> Void)?
  var active = true
  private let session = AVCaptureSession()
  private var preview: AVCaptureVideoPreviewLayer?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    configure()
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
    // The delegate queue is the main queue.
    nonisolated(unsafe) let objects = metadataObjects
    MainActor.assumeIsolated {
      guard active, let preview else { return }
      for object in objects {
        guard let code = object as? AVMetadataMachineReadableCodeObject,
          let text = code.stringValue,
          let transformed = preview.transformedMetadataObject(for: code)
        else { continue }
        onCode?(text, transformed.bounds)
        return
      }
    }
  }
}

/// The short form of a pairing code for the paste field: 「MLP-」 and three groups of four from
/// the code's digest (letters and digits that cannot be confused). The whole code stays in state.
enum PairingCodeDisplay {
  private static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

  static func short(_ code: String) -> String? {
    let text = PairView.pairingText(code)
    guard text.hasPrefix("mlpair"), text.count > 24 else { return nil }
    let digest = Array(SHA256.hash(data: Data(text.utf8)))
    let symbols = digest.prefix(12).map { alphabet[Int($0) % alphabet.count] }
    let groups = stride(from: 0, to: 12, by: 4).map { String(symbols[$0..<$0 + 4]) }
    return "MLP-" + groups.joined(separator: "-")
  }
}

/// 「粘贴」 as the system paste control (no paste prompt) in the tinted small style: `accent` on
/// `accentTint` (opaque over `surface`, as the paste control needs solid colours).
struct TintedPasteButton: UIViewRepresentable {
  let onPaste: (String) -> Void

  func makeUIView(context: Context) -> PasteTargetView {
    let view = PasteTargetView()
    view.onPaste = onPaste
    return view
  }

  func updateUIView(_ view: PasteTargetView, context: Context) {
    view.onPaste = onPaste
  }

  final class PasteTargetView: UIView {
    var onPaste: ((String) -> Void)?

    override init(frame: CGRect) {
      super.init(frame: frame)
      pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
      let configuration = UIPasteControl.Configuration()
      configuration.displayMode = .labelOnly
      configuration.cornerStyle = .capsule
      configuration.baseForegroundColor = MLColor.accent.platformColor
      configuration.baseBackgroundColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
          ? UIColor(red: 54 / 255, green: 56 / 255, blue: 60 / 255, alpha: 1)
          : UIColor(red: 235 / 255, green: 238 / 255, blue: 243 / 255, alpha: 1)
      }
      let control = UIPasteControl(configuration: configuration)
      control.target = self
      control.translatesAutoresizingMaskIntoConstraints = false
      addSubview(control)
      NSLayoutConstraint.activate([
        control.leadingAnchor.constraint(equalTo: leadingAnchor),
        control.trailingAnchor.constraint(equalTo: trailingAnchor),
        control.topAnchor.constraint(equalTo: topAnchor),
        control.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }

    required init?(coder: NSCoder) { nil }

    override func paste(itemProviders: [NSItemProvider]) {
      guard let provider = itemProviders.first, provider.canLoadObject(ofClass: NSString.self)
      else { return }
      _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
        guard let text = object as? String else { return }
        DispatchQueue.main.async { self?.onPaste?(text) }
      }
    }
  }
}
