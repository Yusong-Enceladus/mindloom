import MindloomPhoneKit
import SwiftUI
import UIKit

/// The Mindloom keyboard (PHONE-SPEC §5.13): our 212 pt panel over the system's keyboard
/// backdrop. A keyboard extension cannot use the microphone, so the speak key asks the app's voice
/// session to listen; the live words go into the host field as marked text and the final replaces
/// them. Text typed with other keyboards is never seen.
final class KeyboardViewController: UIInputViewController {
  static let panelHeight: CGFloat = 212

  private var model: KeyboardModel!
  private var host: UIHostingController<KeyboardPanel>?
  private var heightConstraint: NSLayoutConstraint?

  override func viewDidLoad() {
    super.viewDidLoad()
    let model = KeyboardModel(input: self)
    self.model = model
    let host = UIHostingController(rootView: KeyboardPanel(model: model))
    host.view.backgroundColor = .clear
    host.view.translatesAutoresizingMaskIntoConstraints = false
    host.sizingOptions = []
    addChild(host)
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
    self.host = host
    // The punctuation keys' pop-ups rise above the panel, as the system keyboard's do.
    view.clipsToBounds = false
    host.view.clipsToBounds = false
    let height = view.heightAnchor.constraint(equalToConstant: Self.panelHeight)
    height.priority = UILayoutPriority(999)
    height.isActive = true
    heightConstraint = height
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    model.appear()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    model.disappear()
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    model.width = view.bounds.width > 0 ? view.bounds.width : model.width
  }

  override func textDidChange(_ textInput: (any UITextInput)?) {
    super.textDidChange(textInput)
    model.textChanged()
  }
}
