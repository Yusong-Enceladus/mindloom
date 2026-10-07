import Foundation
import Security
import XCTest

@testable import MindloomTencentMeeting

/// The process boundary: a fake tmeet (a shell script) records what it was
/// given — its environment, its open descriptors and the key on descriptor
/// 3 — so the real `posix_spawn` path is exercised without Tencent.
final class TencentMeetingRunnerTests: XCTestCase {
  var folder: URL!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("tmeet-runner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
  }

  /// A fake tmeet: writes its arguments, environment, open descriptors and
  /// what descriptor 3 holds into `report`, then behaves per `$1 $2`.
  func fakeTmeet() throws -> URL {
    let script = folder.appendingPathComponent("tmeet")
    let report = folder.appendingPathComponent("report")
    try """
    #!/bin/sh
    {
      echo "args:$*"
      /usr/bin/env | /usr/bin/sort | /usr/bin/sed 's/^/env:/'
      for fd in 3 4 5 6 7 8 9; do
        if { true <&$fd; } 2>/dev/null; then echo "open:$fd"; fi
      done
      if [ -n "$TMEET_MASTER_KEY_FD" ]; then echo "key:$(/bin/cat <&3)"; fi
    } > '\(report.path)'
    case "$1 $2" in
      "auth status") printf 'Logged in\\n  UserName:  合成\\n'; exit 0 ;;
      "auth login")
        echo "authorize url: https://meeting.tencent.com/marketplace/tencentmeeting-cli-auth.html?code=SYNTHETICcode_0123456789"
        exec /bin/sleep 30 ;;
      "record list") echo '{"trace_id":"t","message":"success","data":{"record_meetings":[]}}'; exit 0 ;;
      "record transcript-get") echo 'Error: network error, please retry later' >&2; exit 1 ;;
      "meeting list-ended") exec /bin/sleep 30 ;;
    esac
    exit 3
    """.write(to: script, atomically: true, encoding: .utf8)
    chmod(script.path, 0o755)
    return script
  }

  func report() throws -> [String] {
    try String(contentsOf: folder.appendingPathComponent("report"), encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  func runner(key: Data = Data(repeating: 7, count: 32)) throws -> TmeetProcessRunner {
    TmeetProcessRunner(
      environment: TmeetEnvironment(
        executable: try fakeTmeet(), stateDirectory: folder.appendingPathComponent("state"),
        masterKey: .descriptor({ key }), helperCheck: .unchecked))
  }

  func testTmeetGetsAFixedEnvironmentAndTheKeyOnDescriptorThreeOnly() async throws {
    setenv("TMEET_AGENT", "should-not-pass", 1)
    setenv("HTTPS_PROXY", "http://127.0.0.1:1", 1)
    defer {
      unsetenv("TMEET_AGENT")
      unsetenv("HTTPS_PROXY")
    }
    let key = Data((0..<32).map { UInt8($0) })
    let keyed = try runner(key: key)
    let result = await keyed.run(.authStatus, timeout: .seconds(20))
    XCTAssertEqual(result.exitStatus, 0)
    XCTAssertEqual(
      TencentMeetingAuthStatus.parse(String(decoding: result.stdout, as: UTF8.self)).userName, "合成")
    let lines = try report()
    XCTAssertEqual(lines.first, "args:auth status")
    let variables = Set(
      lines.filter { $0.hasPrefix("env:") }.map { String($0.dropFirst(4).prefix { $0 != "=" }) })
    // /usr/bin/env itself adds nothing; the shell may add PWD, SHLVL, _.
    XCTAssertEqual(
      variables.subtracting(["PWD", "SHLVL", "_", "OLDPWD"]),
      [
        "PATH", "HOME", "TMPDIR", "LANG", "TMEET_CLI_CONFIG_DIR", "TMEET_CLI_DATA_DIR",
        "TMEET_MASTER_KEY_FD",
      ])
    XCTAssertTrue(lines.contains("env:TMEET_MASTER_KEY_FD=3"))
    XCTAssertTrue(
      lines.contains("env:TMEET_CLI_DATA_DIR=" + folder.appendingPathComponent("state/data").path))
    XCTAssertEqual(lines.filter { $0.hasPrefix("open:") }, ["open:3"])
    XCTAssertTrue(lines.contains("key:" + key.base64EncodedString()))
    // The state folders are the owner's, 0700.
    for name in ["state", "state/config", "state/data"] {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: folder.appendingPathComponent(name).path)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700, name)
    }
  }

  func testWithoutAKeyNothingStartsAndTheSystemKeychainModeSendsNone() async throws {
    let missing = TmeetProcessRunner(
      environment: TmeetEnvironment(
        executable: try fakeTmeet(), stateDirectory: folder.appendingPathComponent("state"),
        masterKey: .descriptor({ throw TencentMeetingKeyError.keychain(errSecAuthFailed) }),
        helperCheck: .unchecked))
    let refused = await missing.run(.authStatus, timeout: .seconds(20))
    XCTAssertTrue(refused.launchFailed)
    // Reported as the key, not as a missing helper (which says to reinstall).
    XCTAssertEqual(refused.launchFailure, .key)
    XCTAssertEqual(TencentMeetingOutput.failure(refused)?.failure, .keyUnavailable)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: folder.appendingPathComponent("report").path))

    let system = TmeetProcessRunner(
      environment: TmeetEnvironment(
        executable: try fakeTmeet(), stateDirectory: folder.appendingPathComponent("state"),
        masterKey: .tmeetSystemKeychain, helperCheck: .unchecked))
    _ = await system.run(.authStatus, timeout: .seconds(20))
    let lines = try report()
    XCTAssertFalse(lines.contains { $0.hasPrefix("env:TMEET_MASTER_KEY_FD") })
    XCTAssertEqual(lines.filter { $0.hasPrefix("open:") }, [])
  }

  /// A file put where the helper is: the check refuses it, the key is never
  /// read, nothing starts and nothing gets descriptor 3.
  func testASubstitutedHelperNeverGetsTheKey() async throws {
    let asked = Found()
    let checked = Found()
    let runner = TmeetProcessRunner(
      environment: TmeetEnvironment(
        executable: try fakeTmeet(), stateDirectory: folder.appendingPathComponent("state"),
        masterKey: .descriptor({
          asked.set()
          return Data(repeating: 7, count: 32)
        }),
        helperCheck: TencentMeetingHelperCheck { _ in
          checked.set()
          return false
        }))
    let result = await runner.run(.authStatus, timeout: .seconds(20))
    XCTAssertTrue(checked.isSet)
    XCTAssertEqual(result.launchFailure, .helper)
    XCTAssertEqual(TencentMeetingOutput.failure(result)?.failure, .helperMissing)
    XCTAssertFalse(asked.isSet, "the key was read for a helper that failed its check")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: folder.appendingPathComponent("report").path),
      "the substituted helper ran")
    let login = await runner.login(onLine: { _ in }, cancellation: TencentMeetingCancellation())
    XCTAssertEqual(login.launchFailure, .helper)
    XCTAssertFalse(asked.isSet)
  }

  func testOutputErrorsAndTimeoutsAreReported() async throws {
    let runner = try runner()
    let list = await runner.run(
      .recordList(start: Fixture.now.addingTimeInterval(-60), end: Fixture.now, pageToken: nil),
      timeout: .seconds(20))
    guard case .success(let data) = TencentMeetingOutput.data(list) else {
      return XCTFail("\(list)")
    }
    XCTAssertEqual(TencentMeetingListingParser.recordList(data).recordings, [])

    let failed = await runner.run(
      .transcriptGet(recordFileID: "1", meetingID: nil, pid: nil, limit: 100), timeout: .seconds(20)
    )
    XCTAssertEqual(failed.exitStatus, 1)
    XCTAssertEqual(TencentMeetingOutput.failure(failed)?.failure, .network)

    let started = Date()
    let slow = await runner.run(
      .meetingListEnded(
        start: Fixture.now.addingTimeInterval(-60), end: Fixture.now, pageToken: nil),
      timeout: .seconds(1))
    XCTAssertTrue(slow.timedOut)
    XCTAssertEqual(slow.exitStatus, -1)
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)

    // A command whose values are not in their format never starts.
    let bad = await runner.run(
      .transcriptGet(recordFileID: "1; true", meetingID: nil, pid: nil, limit: 100),
      timeout: .seconds(5))
    XCTAssertTrue(bad.launchFailed)
  }

  func testLoginHandsOverTheAddressAndStopsWhenCancelled() async throws {
    let runner = try runner()
    let cancellation = TencentMeetingCancellation()
    let seen = Found()
    let started = Date()
    let result = await runner.login(
      onLine: { line in
        if TencentMeetingLoginOutput.authorizationURL(in: line) != nil {
          seen.set()
          cancellation.cancel()
        }
      }, cancellation: cancellation)
    XCTAssertTrue(seen.isSet)
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    XCTAssertEqual(
      TencentMeetingLoginOutput.outcome(result, cancelled: cancellation.isCancelled), .cancelled)
    XCTAssertFalse(result.timedOut)
    XCTAssertEqual(try report().first, "args:auth login --no-browser")
  }
}

final class Found: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func set() { lock.withLock { value = true } }
  var isSet: Bool { lock.withLock { value } }
}
