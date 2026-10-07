import BestASRAgentAccess
import Foundation
import MindloomAgentProtocol
import XCTest

final class AgentProtocolTests: XCTestCase {
  func testJSONKeepsIDsAndStaysOnOneLine() throws {
    let value = try JSONValue.parse(
      #"{"jsonrpc":"2.0","id":7,"method":"x","params":{"a":true,"b":1.5,"c":"甲\n乙"}}"#)
    XCTAssertEqual(value["id"], .int(7))
    XCTAssertEqual(value["params"]?["a"], .bool(true))
    XCTAssertEqual(value["params"]?["b"], .double(1.5))
    let line = value.serialized
    XCTAssertFalse(line.contains("\n"))
    XCTAssertTrue(line.contains(#""id":7"#))
    XCTAssertTrue(line.contains("甲\\n乙"))
    XCTAssertEqual(try JSONValue.parse(line), value)
    XCTAssertEqual(JSONValue.string("a\u{2028}b").serialized, "\"a" + "\\" + "u2028b\"")
    XCTAssertEqual(JSONValue.double(3).serialized, "3")
  }

  func testMessagesDecode() {
    XCTAssertEqual(
      MCPMessage.decode(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#),
      .request(id: "a", method: "ping", params: nil))
    XCTAssertEqual(
      MCPMessage.decode(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#),
      .notification(method: "notifications/initialized", params: nil))
    guard case .invalid(_, let code, _) = MCPMessage.decode("not json") else {
      return XCTFail("parse error expected")
    }
    XCTAssertEqual(code, MCPErrorCode.parseError)
    guard case .invalid(_, let missing, _) = MCPMessage.decode(#"{"id":1,"method":"ping"}"#) else {
      return XCTFail("invalid request expected")
    }
    XCTAssertEqual(missing, MCPErrorCode.invalidRequest)
    guard case .invalid = MCPMessage.decode(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#) else {
      return XCTFail("batches are not accepted")
    }
    guard case .invalid = MCPMessage.decode(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#) else {
      return XCTFail("a null id is not a request")
    }
  }

  func testLineBufferSplitsAndJoins() {
    var buffer = AgentLineBuffer()
    XCTAssertEqual(buffer.append(Data("{\"a\":1}\r\n{\"b\"".utf8)), [#"{"a":1}"#])
    XCTAssertEqual(buffer.append(Data(":2}\n\n".utf8)), [#"{"b":2}"#])
    XCTAssertEqual(buffer.append(Data("x".utf8)), [])
  }

  func testTheHelperAloneSaysTheAppIsNotRunning() throws {
    let initialize = try XCTUnwrap(
      AgentOfflineResponder.reply(
        to: MCPMessage.decode(
          #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#
        )))
    XCTAssertEqual(initialize["result"]?["protocolVersion"], "2025-03-26")
    XCTAssertEqual(initialize["result"]?["serverInfo"]?["title"], "Mindloom")
    let tools = try XCTUnwrap(
      AgentOfflineResponder.reply(
        to: MCPMessage.decode(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)))
    XCTAssertEqual(tools["result"]?["tools"]?.arrayValue?.count, 6)
    let call = try XCTUnwrap(
      AgentOfflineResponder.reply(
        to: MCPMessage.decode(
          #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_matter","arguments":{"id":"x"}}}"#
        )))
    XCTAssertEqual(call["result"]?["isError"], true)
    XCTAssertEqual(
      call["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue,
      "Mindloom 未运行。请先打开 Mindloom。")
    let read = try XCTUnwrap(
      AgentOfflineResponder.reply(
        to: MCPMessage.decode(
          #"{"jsonrpc":"2.0","id":4,"method":"resources/read","params":{"uri":"mindloom://matter/x"}}"#
        )))
    XCTAssertEqual(read["error"]?["code"]?.intValue, Int64(MCPErrorCode.notRunning))
    XCTAssertEqual(read["error"]?["message"]?.stringValue, AgentCopy.notRunning)
    XCTAssertNil(
      AgentOfflineResponder.reply(
        to: MCPMessage.decode(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)))
    XCTAssertEqual(
      AgentOfflineResponder.interruptedReply(id: 9, method: "tools/call")["result"]?["isError"],
      true)
  }

  /// The schemas an agent sees are the ones reviewed in the repository.
  func testToolSchemasMatchTheRepositoryCopy() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let file = root.appendingPathComponent("schemas/agent/mindloom-mcp-tools.json")
    if ProcessInfo.processInfo.environment["MINDLOOM_WRITE_AGENT_SCHEMA"] == "1" {
      // Regenerates the reviewed copy after a deliberate change to the tools.
      let object = try JSONSerialization.jsonObject(with: AgentTool.catalog.serializedData)
      try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      ).write(to: file)
    }
    XCTAssertEqual(try JSONValue.parse(Data(contentsOf: file)), AgentTool.catalog)
    for tool in AgentTool.allCases {
      XCTAssertEqual(tool.inputSchema["additionalProperties"], false, tool.rawValue)
      XCTAssertEqual(tool.annotations["readOnlyHint"], .bool(!tool.isChange))
      XCTAssertEqual(tool.annotations["destructiveHint"], false)
    }
    // v12: reads, and four changes; nothing that deletes, shares, exports,
    // records or changes settings (ALIGNMENT 用-7).
    XCTAssertEqual(
      AgentTool.allCases.filter(\.isChange).map(\.rawValue),
      ["add_note", "move_item", "rename_matter", "mark_step"])
    for word in ["delete", "share", "export", "record", "setting", "grant", "inbox"] {
      XCTAssertFalse(AgentTool.allCases.contains { $0.rawValue.contains(word) }, word)
    }
  }

  func testClientIdentityFoldsVersionFoldersOnlyForASignedParent() {
    let signer = "team:TESTTEAM01:com.anthropic.claude-code"
    let a = AgentClientIdentity(
      name: "claude-code", path: "/Users/u/.local/share/claude/versions/2.1.260", signer: signer)
    let b = AgentClientIdentity(
      name: "claude-code", path: "/Users/u/.local/share/claude/versions/2.2.0", signer: signer)
    XCTAssertEqual(a.path, "/Users/u/.local/share/claude/versions/*")
    XCTAssertEqual(a.key, b.key)
    XCTAssertEqual(a.displayName, "Claude Code")
    XCTAssertEqual(a.signerLabel, "开发者（团队 TESTTEAM01）签名的程序")
    // Unsigned (or ad hoc): the exact path, and the script an interpreter runs (V7-A3).
    let unsigned = AgentClientIdentity(
      name: "claude-code", path: "/Users/u/.local/share/claude/versions/9.9.9")
    XCTAssertEqual(unsigned.path, "/Users/u/.local/share/claude/versions/9.9.9")
    XCTAssertNotEqual(unsigned.key, a.key)
    let otherTeam = AgentClientIdentity(
      name: "claude-code", path: "/Users/u/.local/share/claude/versions/2.2.0",
      signer: "team:OTHERTEAM9:com.example.tool")
    XCTAssertNotEqual(otherTeam.key, a.key)
    let node = AgentClientIdentity(
      name: "x", path: "/Users/u/.nvm/versions/node/v20.11.1/bin/node",
      script: "/Users/u/.nvm/versions/node/v20.11.1/lib/node_modules/@x/cli.js")
    XCTAssertEqual(node.path, "/Users/u/.nvm/versions/node/v20.11.1/bin/node")
    let otherScript = AgentClientIdentity(
      name: "x", path: node.path, script: "/Users/u/Projects/evil.js")
    XCTAssertNotEqual(node.key, otherScript.key)
    let other = AgentClientIdentity(name: "claude-code", path: "/tmp/claude")
    XCTAssertNotEqual(a.key, other.key)
    let renamed = AgentClientIdentity(name: "codex-mcp-client", path: a.path)
    XCTAssertNotEqual(a.key, renamed.key)
    XCTAssertEqual(renamed.displayName, "Codex")
    XCTAssertEqual(AgentClientIdentity(name: "evil\u{0007}\nname", path: "").name, "evilname")
  }

  func testResourceURIs() {
    XCTAssertEqual(AgentResource.matterID(from: "mindloom://matter/E-1"), "E-1")
    XCTAssertNil(AgentResource.matterID(from: "mindloom://matter/"))
    XCTAssertNil(AgentResource.matterID(from: "mindloom://matter/a/b"))
    XCTAssertNil(AgentResource.matterID(from: "file:///etc/passwd"))
  }
}
