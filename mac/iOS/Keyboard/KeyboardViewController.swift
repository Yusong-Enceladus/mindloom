import MindloomPhoneKit
import SwiftUI
import UIKit

/// 织机键盘 (PHONE-CONTRACT §1–2). A keyboard extension cannot use the
/// microphone, so the mic key asks the app's voice session to listen and
/// inserts the final text it returns; each inserted final is sealed into
/// the outbox. Text typed with other keyboards is never seen.
final class KeyboardViewController: UIInputViewController {
  private var model: KeyboardModel!
  private var host: UIHostingController<KeyboardRootView>?

  override func viewDidLoad() {
    super.viewDidLoad()
    let model = KeyboardModel(input: self)
    self.model = model
    let host = UIHostingController(
      rootView: KeyboardRootView(model: model, globe: GlobeKey(controller: self)))
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
    let height = view.heightAnchor.constraint(equalToConstant: 272)
    height.priority = UILayoutPriority(999)
    height.isActive = true
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    model.appear()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    model.disappear()
  }

  override func textDidChange(_ textInput: (any UITextInput)?) {
    super.textDidChange(textInput)
    model.textChanged()
  }
}
