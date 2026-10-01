// MindloomAgentTestHost: the App's agent side on a synthetic data root, for
// the end-to-end test of the real `mindloom-mcp` helper (AGENT-CONTRACT §4).
// It runs the same socket server, service and library store the App runs;
// only the memory comes from a synthetic fixture file and the owner's
// answers come from a script on stdin instead of the consent sheet.
//
//   MindloomAgentTestHost --root <synthetic root> --fixture <fixture.json>
//                         [--consent-timeout-ms N]
//
// Refuses a root without the SYNTHETIC_DATA_ROOT marker or inside the
// owner's real library. Commands on stdin, one JSON object per line:
//   {"cmd":"consent","answer":"deny"|"none"|{"spaces":[…],"range":"all"|
//     {"ropes":[…]}|{"matters":[…]},"propose":bool,"duration":"once"|"today"|
//     "always","numbers":bool,"ask":bool}}      queue the next consent answer
//   {"cmd":"approve","answers":{"<matter id>":true|false}}  next approval
//   {"cmd":"grants"} {"cmd":"revoke","grant_id":"…"} {"cmd":"revoke_all"}
//   {"cmd":"proposals"} {"cmd":"reject","proposal_id":"…"} {"cmd":"quit"}
// Events and replies on stdout, one JSON object per line.

import BestASRAgentAccess
import BestASRDomain
import BestASRMemory
import BestASRPersistence
import BestASRRemoteOrganizer
import Darwin
import Foundation
import MindloomAgentProtocol

let output = NSLock()
@Sendable func emit(_ value: JSONValue) {
  output.withLock {
    FileHandle.standardOutput.write(Data((value.serialized + "\n").utf8))
  }
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data(("MindloomAgentTestHost: " + message + "\n").utf8))
  exit(2)
}

// MARK: - Arguments

var rootPath: String?
var fixturePath: String?
var consentTimeout = Duration.seconds(5)
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
  let flag = arguments.removeFirst()
  guard let value = arguments.first else { fail("missing value for \(flag)") }
  arguments.removeFirst()
  switch flag {
  case "--root": rootPath = value
  case "--fixture": fixturePath = value
  case "--consent-timeout-ms": consentTimeout = .milliseconds(Int(value) ?? 5_000)
  default: fail("unknown argument \(flag)")
  }
}
guard let rootPath, rootPath.hasPrefix("/"), let fixturePath else {
  fail("usage: --root <absolute synthetic root> --fixture <fixture.json>")
}
let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
guard let realLibrary = BestASRDataRootSelection.ownerRealLibraryRoot(),
  !BestASRDataRootSelection.path(root, isWithinOrEqualTo: realLibrary),
  !BestASRDataRootSelection.path(realLibrary, isWithinOrEqualTo: root),
  FileManager.default.fileExists(
    atPath: root.appendingPathComponent(RemoteOrganizerDataProvenance.syntheticMarkerFileName).path)
else { fail("refusing: not a synthetic data root") }

// MARK: - Fixture

struct Fixture {
  let snapshot: AgentMemorySnapshot
}

func loadFixture(_ path: String) throws -> Fixture {
  let data = try Data(contentsOf: URL(fileURLWithPath: path))
  let json = try JSONValue.parse(data)
  let formatter = ISO8601DateFormatter()
  func date(_ value: JSONValue?) -> Date? { value?.stringValue.flatMap(formatter.date(from:)) }
  let now = date(json["now"]) ?? Date()
  let timeZone = json["time_zone"]?.stringValue.flatMap(TimeZone.init(identifier:)) ?? .current
  var records: [MemoryItemRecord] = []
  var events: [MemoryEventSource] = []
  var spaceOfMatter: [String: String] = [:]
  for matter in json["matters"]?.arrayValue ?? [] {
    guard let id = matter["id"]?.stringValue else { continue }
    var itemIDs: [String] = []
    for item in matter["items"]?.arrayValue ?? [] {
      guard let itemID = item["id"]?.stringValue, let uuid = UUID(uuidString: itemID) else {
        continue
      }
      itemIDs.append(itemID)
      let at = date(item["at"]) ?? now
      let kind = item["kind"]?.stringValue ?? "text"
      let segments = (item["segments"]?.arrayValue ?? []).map { segment in
        MemoryItemRecord.Segment(
          startMilliseconds: segment["start_ms"]?.intValue ?? 0,
          endMilliseconds: segment["end_ms"]?.intValue ?? 0,
          personID: segment["person_id"]?.stringValue.flatMap(UUID.init(uuidString:)).map(
            PersonID.init),
          personName: segment["person_name"]?.stringValue,
          text: segment["text"]?.stringValue ?? "")
      }
      let isRecording = kind == "recording"
      records.append(
        MemoryItemRecord(
          sessionID: SessionID(uuid), inputMode: isRecording ? .roomMicrophone : .userItem,
          itemKind: isRecording ? nil : UserItemKind(rawValue: kind) ?? .text,
          title: item["title"]?.stringValue ?? "", startedAt: at, updatedAt: at,
          sourceBundleID: nil, sourceDisplayName: item["source"]?.stringValue,
          sourceIdentifier: nil,
          text: item["text"]?.stringValue ?? segments.map(\.text).joined(), segments: segments))
    }
    let facts = (matter["facts"]?.arrayValue ?? []).map { fact in
      MemoryStatusFact(
        remote: RemoteOrganizerEvent.StatusFact(
          text: fact["text"]?.stringValue ?? "",
          itemIDs: (fact["item_ids"]?.arrayValue ?? []).compactMap(\.stringValue),
          state: fact["state"]?.stringValue, date: fact["date"]?.stringValue,
          quote: fact["quote"]?.stringValue))
    }
    events.append(
      MemoryEventSource(
        eventID: id, origin: .spark, title: matter["title"]?.stringValue ?? "",
        statusLine: matter["status"]?.stringValue ?? "", pinned: false,
        updatedAt: date(matter["updated_at"]), itemIDs: itemIDs,
        personIDs: (matter["person_ids"]?.arrayValue ?? []).compactMap(\.stringValue),
        statusFacts: MemoryStatusFact.ordered(facts)))
    if let space = matter["space"]?.stringValue { spaceOfMatter[id] = space }
  }
  let personsData = (json["persons"] ?? .array([])).serializedData
  let persons = try JSONDecoder().decode([RemoteOrganizerPerson].self, from: personsData)
  let projection = MemoryProjection(
    events: events, records: records, persons: persons, now: now)
  let spaces = (json["spaces"]?.arrayValue ?? []).compactMap { space -> AgentSpace? in
    guard let id = space["id"]?.stringValue else { return nil }
    return AgentSpace(id: id, name: space["name"]?.stringValue ?? id)
  }
  let ropes = (json["ropes"]?.arrayValue ?? []).compactMap { rope -> AgentRope? in
    guard let id = rope["id"]?.stringValue else { return nil }
    return AgentRope(
      id: id, title: rope["title"]?.stringValue ?? id, parentID: rope["parent"]?.stringValue,
      matterIDs: (rope["matters"]?.arrayValue ?? []).compactMap(\.stringValue))
  }
  return Fixture(
    snapshot: AgentMemorySnapshot(
      projection: projection, spaces: spaces.isEmpty ? [.personal] : spaces, ropes: ropes,
      spaceOfMatter: spaceOfMatter, timeZone: timeZone))
}

struct FixtureMemory: AgentMemoryProviding {
  let fixture: Fixture
  func agentSnapshot() async -> AgentMemorySnapshot? { fixture.snapshot }
}

// MARK: - Scripted owner

actor ScriptedOwner: AgentConsentPresenting {
  private var consentAnswers: [AgentConsentAnswer?] = []
  private var consentWaiters: [CheckedContinuation<AgentConsentAnswer?, Never>] = []
  private var approvals: [[String: Bool]] = []
  private var approvalWaiters: [CheckedContinuation<[String: Bool], Never>] = []

  func queueConsent(_ answer: AgentConsentAnswer?) {
    if !consentWaiters.isEmpty {
      consentWaiters.removeFirst().resume(returning: answer)
    } else {
      consentAnswers.append(answer)
    }
  }

  func queueApproval(_ answers: [String: Bool]) {
    if !approvalWaiters.isEmpty {
      approvalWaiters.removeFirst().resume(returning: answers)
    } else {
      approvals.append(answers)
    }
  }

  func requestConsent(_ request: AgentConsentRequest) async -> AgentConsentAnswer? {
    emit([
      "event": "consent_requested", "client": .string(request.client.displayName),
      "client_name": .string(request.client.name), "client_path": .string(request.client.path),
      "client_key": .string(request.client.key),
      "spaces": .strings(request.options.spaces.map(\.id)),
      "matters": .int(Int64(request.options.matters.count)),
    ])
    if !consentAnswers.isEmpty { return consentAnswers.removeFirst() }
    return await withCheckedContinuation { consentWaiters.append($0) }
  }

  func approveMatters(_ request: AgentMatterApprovalRequest) async -> [String: Bool] {
    emit(["event": "approval_requested", "matters": .strings(request.matters.map(\.id))])
    if !approvals.isEmpty { return approvals.removeFirst() }
    return await withCheckedContinuation { approvalWaiters.append($0) }
  }

  func proposalArrived(_ proposal: AgentInboxProposal) async {
    emit(["event": "proposal", "proposal_id": .string(proposal.proposalID.uuidString.lowercased())])
  }

  func accessChanged() async {}
}

@Sendable func terms(_ value: JSONValue) -> AgentGrantTerms? {
  guard case .object = value else { return nil }
  var terms = AgentGrantTerms()
  if let spaces = value["spaces"]?.arrayValue {
    terms.spaces = Set(spaces.compactMap(\.stringValue).map(AgentSpaceID.normalized))
  }
  if let ropes = value["range"]?["ropes"]?.arrayValue {
    terms.range = .ropes(Set(ropes.compactMap(\.stringValue)))
  } else if let matters = value["range"]?["matters"]?.arrayValue {
    terms.range = .matters(Set(matters.compactMap(\.stringValue)))
  }
  terms.canPropose = value["propose"]?.boolValue ?? false
  terms.duration =
    value["duration"]?.stringValue.flatMap(AgentGrantDuration.init(rawValue:)) ?? .once
  terms.showNumbers = value["numbers"]?.boolValue ?? false
  terms.askForNewMatters = value["ask"]?.boolValue ?? false
  return terms
}

// MARK: - Run

let fixture: Fixture
do { fixture = try loadFixture(fixturePath) } catch { fail("fixture unreadable") }
let store: GRDBDictationStore
let secrets: FileAgentGrantSecretStore
do {
  store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("history.sqlite"))
  secrets = try FileAgentGrantSecretStore(dataRoot: root)
} catch { fail("library unavailable") }
let owner = ScriptedOwner()
let service = AgentAccessService(
  memory: FixtureMemory(fixture: fixture), records: store, secrets: secrets, consent: owner,
  configuration: .init(consentTimeout: consentTimeout, denialCooldown: 0),
  timeZone: fixture.snapshot.timeZone)
let server = AgentSocketServer(dataRoot: root, service: service)
do { try server.start() } catch { fail("socket unavailable: \(error)") }
emit(["event": "ready", "socket": .string(server.socketURL.path)])

signal(SIGPIPE, SIG_IGN)
let commands = Thread {
  while let line = readLine() {
    guard let command = try? JSONValue.parse(line), let name = command["cmd"]?.stringValue else {
      emit(["error": "bad command"])
      continue
    }
    let done = DispatchSemaphore(value: 0)
    Task {
      defer { done.signal() }
      switch name {
      case "consent":
        let answer = command["answer"] ?? .null
        if answer.stringValue == "deny" {
          await owner.queueConsent(.deny)
        } else if answer.stringValue == "none" || answer == .null {
          await owner.queueConsent(nil)
        } else if let terms = terms(answer) {
          await owner.queueConsent(.allow(terms))
        }
        emit(["ok": "consent"])
      case "approve":
        var answers: [String: Bool] = [:]
        for (key, value) in command["answers"]?.objectValue ?? [:] {
          answers[key] = value.boolValue ?? false
        }
        await owner.queueApproval(answers)
        emit(["ok": "approve"])
      case "grants":
        let grants = await service.grants()
        emit([
          "grants": .array(
            grants.map {
              [
                "grant_id": .string($0.grantID.uuidString.lowercased()),
                "client_key": .string($0.clientKey), "client": .string($0.clientName),
                "duration": .string($0.terms.duration.rawValue),
                "expires_at": $0.expiresAt.map { .double($0.timeIntervalSince1970) } ?? .null,
              ]
            })
        ])
      case "revoke":
        if let id = command["grant_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
          await service.revoke(id)
        }
        emit(["ok": "revoke"])
      case "revoke_all":
        for grant in await service.grants() { await service.revoke(grant.grantID) }
        emit(["ok": "revoke_all"])
      case "proposals":
        let proposals = (try? await store.agentProposals(includeDecided: true)) ?? []
        emit([
          "proposals": .array(
            proposals.map {
              [
                "proposal_id": .string($0.proposalID.uuidString.lowercased()),
                "state": .string($0.state.rawValue), "client": .string($0.clientName),
                "has_text": .bool(!$0.text.isEmpty),
              ]
            })
        ])
      case "reject":
        if let id = command["proposal_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
          try? await store.resolveAgentProposal(id, state: .rejected, itemID: nil, at: Date())
        }
        emit(["ok": "reject"])
      case "quit":
        server.stop()
        emit(["event": "stopped"])
        exit(0)
      default:
        emit(["error": "unknown command"])
      }
    }
    done.wait()
  }
  server.stop()
  exit(0)
}
commands.start()
dispatchMain()
