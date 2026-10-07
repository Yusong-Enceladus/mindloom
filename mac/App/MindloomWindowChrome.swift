import AppKit
import SwiftUI

/// The window chrome of the prototype (MAC-SPEC §3.3, §9, §10; live-mac): no
/// title bar band. The content runs under a transparent title bar to the
/// window's top edge, and the system's traffic lights sit at the
/// prototype's place, (20, 18) from the window's top-left corner, inside
/// the inset sidebar card. Without this a hidden-title-bar SwiftUI window
/// keeps a ~30 pt empty band above the content and the lights at (7, 6).
struct MindloomWindowChrome: NSViewRepresentable {
  /// Where the close button's circle starts, from the window's top-left.
  var lights = CGPoint(x: 20, y: 18)
  /// Told the height the title bar takes from the content (`MindloomFixedWindow`).
  var onTitleBar: ((CGFloat) -> Void)?

  func makeNSView(context: Context) -> ChromeView {
    let view = ChromeView()
    view.lights = lights
    view.onTitleBar = onTitleBar
    return view
  }

  func updateNSView(_ view: ChromeView, context: Context) {
    view.lights = lights
    view.onTitleBar = onTitleBar
    view.apply()
  }

  final class ChromeView: NSView {
    var lights = CGPoint(x: 20, y: 18)
    var onTitleBar: ((CGFloat) -> Void)?
    private var reportedTitleBar: CGFloat = -1
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
      guard let window else { return }
      let names: [Notification.Name] = [
        NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
        NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification,
      ]
      for name in names {
        observers.append(
          NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
          })
      }
      apply()
      // AppKit lays the title bar out once more after the first display.
      DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    func apply() {
      guard let window else { return }
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      if !window.styleMask.contains(.fullSizeContentView) {
        window.styleMask.insert(.fullSizeContentView)
      }
      let titleInset = window.frame.height - window.contentLayoutRect.height
      if titleInset != reportedTitleBar, let onTitleBar {
        reportedTitleBar = titleInset
        DispatchQueue.main.async { onTitleBar(titleInset) }
      }
      guard !window.styleMask.contains(.fullScreen),
        let close = window.standardWindowButton(.closeButton),
        let titlebar = close.superview,
        let container = titlebar.superview,
        let frame = container.superview
      else { return }
      let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
      // The circle is 12 pt inside a button of the system's size.
      let size = close.frame.size
      let inset = CGPoint(x: (size.width - 12) / 2, y: (size.height - 12) / 2)
      let height = max(container.frame.height, lights.y - inset.y + size.height + 6)
      if container.frame.height != height || container.frame.maxY != frame.bounds.maxY {
        container.frame = NSRect(
          x: container.frame.minX, y: frame.bounds.height - height,
          width: container.frame.width, height: height)
        titlebar.frame = container.bounds
      }
      let top = lights.y - inset.y
      for (index, type) in buttons.enumerated() {
        guard let button = window.standardWindowButton(type) else { continue }
        let x = lights.x - inset.x + CGFloat(index) * 20
        let y = titlebar.isFlipped ? top : titlebar.bounds.height - top - size.height
        if button.frame.origin != CGPoint(x: x, y: y) {
          button.setFrameOrigin(CGPoint(x: x, y: y))
        }
      }
    }
  }
}

extension View {
  /// The prototype's chrome for a Mindloom window (`MindloomWindowChrome`).
  func mindloomWindowChrome(lights: CGPoint = CGPoint(x: 20, y: 18)) -> some View {
    ignoresSafeArea(.container, edges: .top)
      .background(MindloomWindowChrome(lights: lights))
  }
}

/// A fixed-size window (Welcome, 680 × 600) whose content runs under the
/// transparent title bar: the window is exactly `size`, not `size` plus the
/// title bar's height (which left a 28 pt strip under Welcome).
struct MindloomFixedWindow<Content: View>: View {
  let size: CGSize
  @ViewBuilder let content: Content
  @State private var titleBar: CGFloat = 0

  var body: some View {
    content
      .frame(width: size.width, height: size.height)
      .padding(.top, -titleBar)
      .background(MindloomWindowChrome(onTitleBar: { titleBar = $0 }))
  }
}

/// Calls `shown` when its window comes on screen: when the view joins a
/// window, and each time the window turns visible again after being fully
/// hidden (closed and reopened, minimized, on another Space, covered by other
/// windows). Never while the window stays visible: the sidebar's tagline is
/// picked here and must not change under the reader's eyes (docs/TAGLINES.md).
struct WindowShownMonitor: NSViewRepresentable {
  var shown: @MainActor () -> Void

  func makeNSView(context: Context) -> MonitorView {
    let view = MonitorView()
    view.shown = shown
    return view
  }

  func updateNSView(_ view: MonitorView, context: Context) {
    view.shown = shown
  }

  final class MonitorView: NSView {
    var shown: (@MainActor () -> Void)?
    private var observer: NSObjectProtocol?
    private var visible = false

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
      guard let window else {
        visible = false
        return
      }
      visible = window.occlusionState.contains(.visible)
      report()
      observer = NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.occlusionChanged() }
      }
    }

    private func occlusionChanged() {
      guard let window else { return }
      let now = window.occlusionState.contains(.visible)
      defer { visible = now }
      if now, !visible { report() }
    }

    /// Outside SwiftUI's update of the view that holds the monitor.
    private func report() {
      DispatchQueue.main.async { [weak self] in self?.shown?() }
    }
  }
}
