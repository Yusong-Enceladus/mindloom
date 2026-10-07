// mindloom-carry-over: the switch's one-shot keychain helper (2026-10-06).
//
// Built into its own little bundle and signed with bestASR's identifier
// (`com.bestasr.app`) and certificate by script/build_carry_over_helper.sh, so
// it satisfies the access lists of the login-keychain items bestASR's builds
// made and reads them without a password prompt (any read that would ask
// fails instead). It reads the items of one library, waits on a private
// socket for Mindloom (`app.mindloom`, the same team, checked from the
// kernel's audit token), hands them over in memory and exits. With
// `--login-item`, it also reads whether bestASR's 「登录时打开」 is on and, once
// Mindloom has turned its own on, removes bestASR's.
//
// The secrets never go into arguments, the environment, files or logs; the
// output is counts only. The offer names the library folder it was read
// for, and Mindloom takes it only when that is bestASR's folder beside the
// library it opened. A verification copy signed with a check identifier
// hands over only to another check identity, and only from the keychain
// file it is given (never the login keychain).
//
//   mindloom-carry-over [--library <bestASR's library folder>] [--receiver <bundle id>]
//                       [--keychain <keychain file>] [--wait <seconds>] [--login-item]
//   mindloom-carry-over --unregister-login-item
//
// The second form is the rollback's: a copy signed as Mindloom (`app.mindloom`,
// the same certificate; a check identity in a dry run) turns that identity's
// 「登录时打开」 off, so the Mindloom kept in the backup folder does not open
// at the next login. It reads and sends nothing.
//
// Exit: 0 handed over (or nothing to hand over; the login item is off), 3 some
// items not made, 4 Mindloom did not come, 64 usage, 66 no library, 69 not
// signed, 70 other.

import Darwin
import Foundation
import MindloomCarryOver
import MindloomIdentity
import ServiceManagement

func say(_ line: String) {
  FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func stop(_ code: Int32, _ line: String) -> Never {
  FileHandle.standardError.write(Data(("mindloom-carry-over: " + line + "\n").utf8))
  exit(code)
}

func statusName(_ status: SMAppService.Status) -> String {
  switch status {
  case .enabled: "enabled"
  case .requiresApproval: "requires-approval"
  case .notRegistered: "not-registered"
  case .notFound: "not-found"
  @unknown default: "unknown"
  }
}

var options: [String: String] = [:]
var flags: Set<String> = []
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
  switch argument {
  case "--library", "--receiver", "--keychain", "--wait":
    guard let value = arguments.popFirst(), options[argument] == nil else {
      stop(64, "\(argument) needs one value")
    }
    options[argument] = value
  case "--login-item", "--unregister-login-item":
    flags.insert(argument)
  default:
    stop(64, "unknown argument \(argument)")
  }
}

guard let signature = CarryOverChannel.ownSignature() else {
  stop(69, "not signed with a team")
}

if flags.contains("--unregister-login-item") {
  guard options.isEmpty, flags.count == 1 else {
    stop(64, "--unregister-login-item takes no other argument")
  }
  guard CarryOverSource.mayUnregisterLoginItem(helperIdentifier: signature.identifier) else {
    stop(64, "a helper signed as \(signature.identifier) does not turn login items off")
  }
  let before = SMAppService.mainApp.status
  if before == .enabled || before == .requiresApproval {
    try? SMAppService.mainApp.unregister()
  }
  let after = SMAppService.mainApp.status
  let on = after == .enabled || after == .requiresApproval
  say("login-item before=\(statusName(before)) after=\(statusName(after))")
  exit(on ? 70 : 0)
}

guard
  let receiver = CarryOverSource.receiver(
    helperIdentifier: signature.identifier, requested: options["--receiver"])
else {
  stop(64, "a helper signed as \(signature.identifier) hands over to no such App")
}
let isProduct = signature.identifier == MindloomIdentity.Previous.bundleID
if isProduct, options["--keychain"] != nil {
  stop(64, "--keychain is for verification copies only")
}
// A verification copy never reads the login keychain (review of 10-6).
if CarryOverSource.keychainFileRequired(helperIdentifier: signature.identifier),
  options["--keychain"] == nil
{
  stop(64, "a helper signed as \(signature.identifier) needs --keychain <keychain file>")
}
let library: URL
if let path = options["--library"] {
  guard path.hasPrefix("/") else { stop(64, "--library needs a full path") }
  library = URL(fileURLWithPath: path, isDirectory: true)
} else if isProduct, let home = getpwuid(getuid())?.pointee.pw_dir {
  library = URL(fileURLWithPath: String(cString: home), isDirectory: true)
    .appendingPathComponent("Library/Application Support", isDirectory: true)
    .appendingPathComponent(MindloomIdentity.Previous.libraryFolderName, isDirectory: true)
} else {
  stop(64, "--library is required")
}
var entry = stat()
guard lstat(library.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFDIR else {
  stop(66, "no library folder at \(library.path)")
}
let wait = Double(options["--wait"] ?? "1800") ?? 1800
guard wait > 0, wait <= 24 * 3600 else { stop(64, "--wait is in seconds, at most a day") }

let keychain: SystemCarryOverKeychain
do {
  keychain = try SystemCarryOverKeychain(
    file: options["--keychain"].map { URL(fileURLWithPath: $0) })
} catch {
  stop(70, "keychain unavailable (\(error))")
}

// The library's identity now, while its folder is still where it was.
let oldRoot = LibraryRootIdentity.hash(of: library)
let collected = KeychainCarryOver.collect(oldRoot: oldRoot, keychain: keychain)
let loginItemWasEnabled = flags.contains("--login-item") && SMAppService.mainApp.status == .enabled
let offer = KeychainCarryOver.Offer(
  items: collected.items, unreadable: collected.unreadable,
  loginItemWasEnabled: loginItemWasEnabled, library: library.standardizedFileURL.path)

guard let temporary = CarryOverChannel.userTemporaryDirectory(),
  let requirement = CarryOverChannel.requirement(identifier: receiver, team: signature.team)
else { stop(70, "no temporary folder") }
let folder = CarryOverChannel.directory(receiver: receiver, temporaryDirectory: temporary)
let listener: Int32
do { listener = try CarryOverChannel.listen(directory: folder) } catch {
  stop(70, "cannot listen (\(error))")
}
signal(SIGPIPE, SIG_IGN)
say(
  "ready items=\(offer.items.count) unreadable=\(offer.unreadable) login-item=\(loginItemWasEnabled ? "on" : "off") receiver=\(receiver)"
)

let connection: Int32
do {
  connection = try CarryOverChannel.acceptVerified(
    listener, until: Date().addingTimeInterval(wait),
    check: CarryOverChannel.signatureCheck(requirement: requirement))
} catch {
  close(listener)
  CarryOverChannel.remove(directory: folder)
  say("timed out: \(receiver) did not connect")
  exit(4)
}
close(listener)
CarryOverChannel.remove(directory: folder)

let receipt: KeychainCarryOver.Receipt
do {
  try CarryOverChannel.send(offer, on: connection)
  receipt = try CarryOverChannel.receive(KeychainCarryOver.Receipt.self, on: connection)
} catch {
  close(connection)
  stop(70, "handover broke off (\(error))")
}
close(connection)

var loginItem = loginItemWasEnabled ? "kept" : "off"
if loginItemWasEnabled, receipt.loginItemRegistered {
  // Mindloom's own item is on: bestASR's goes, so only one App opens at login.
  try? SMAppService.mainApp.unregister()
  loginItem = SMAppService.mainApp.status == .enabled ? "both" : "moved"
}
say(
  "done offered=\(offer.items.count) created=\(receipt.created) existing=\(receipt.existing) failed=\(receipt.failed) unreadable=\(offer.unreadable) login-item=\(loginItem)"
)
exit(receipt.failed == 0 ? 0 : 3)
