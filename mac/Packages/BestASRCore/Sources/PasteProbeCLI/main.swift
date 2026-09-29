import AppKit
import BestASRDelivery
import Foundation

// Delivers one promised paste to whichever application is in front after a
// delay, and prints what the application did with it. This is how "does
// this app read the pasteboard when no field has the keyboard?" is answered
// per application, before a build ships, rather than by the user's next
// dictation.
//
//   swift run PasteProbeCLI --delay 5 --text "probe"
//
// The clipboard is left as the deliverer leaves it: restored when the paste
// landed, holding the probe text when it did not.

var delay: TimeInterval = 5
var text = "bestASR paste probe"
var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
  switch argument {
  case "--delay": delay = iterator.next().flatMap(Double.init) ?? delay
  case "--text": text = iterator.next() ?? text
  default: break
  }
}

Task { @MainActor in
  try? await Task.sleep(for: .seconds(delay))
  guard let front = NSWorkspace.shared.frontmostApplication else {
    print("no application in front")
    exit(1)
  }
  let target = DeliveryTarget(
    processIdentifier: front.processIdentifier, bundleIdentifier: front.bundleIdentifier)
  let reader = TargetReader()
  let before = reader.focusedText(in: target.processIdentifier)
  let focus = before.map { $0.exposesText ? "text" : "no-text" } ?? "none"
  print("front app=\(front.bundleIdentifier ?? "-") pid=\(front.processIdentifier) focus=\(focus)")
  let outcome = await TextDeliverer(reader: reader).deliver(text, to: target, observing: before)
  switch outcome {
  case .delivered(let evidence, let wait): print("outcome=delivered evidence=\(evidence.rawValue) wait_ms=\(wait)")
  case .kept(let reason): print("outcome=kept reason=\(reason.rawValue)")
  }
  exit(0)
}
RunLoop.main.run()
