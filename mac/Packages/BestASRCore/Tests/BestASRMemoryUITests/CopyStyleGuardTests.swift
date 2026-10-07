import Foundation
import MindloomDesign
import XCTest

/// docs/UI-COPY.md §6 on every user-facing string of both platforms: the
/// same literals `VocabularyGuardTests` reads (plus multi-line literals, which
/// also get its word list), the usage descriptions and names in the
/// Info.plists and `App/InfoPlist.xcstrings`, and the strings of the
/// extensions and plugins under `integrations/` (their JSON manifests and
/// JavaScript, and the `description:` lines of the Claude Code plugin's
/// skill and commands).
///
/// - Mindloom is the name; 织机 only in About (and the brand lockups that draw
///   it only when asked).
/// - No reassurance: say what it does (不会、从不、只在、安全… as promises).
/// - Not colloquial: Apple's own zh-Hans system wording (也可以改、东西、看看…).
/// - No internal terms (SSH, ProxyJump, known_hosts, 组件…).
/// - System Settings names as macOS 27 writes them (设备控制和数据访问 for the
///   permission that was 辅助功能 — 无障碍 is another pane, 隐私与安全,
///   录屏与系统录音), “系统设置” always in quotes, a path written
///   “系统设置”>“键盘” (never 系统设置 → 键盘), and “” quotes, never 「」.
/// - 仅录制 / 仅保存 / 仅用于 only where a person reviewed it (`reviewedScope`):
///   stating a scope is fine, a promise with one character changed is not.
///
/// Any hit fails; fix the string (the guide says what to write instead).
final class CopyStyleGuardTests: XCTestCase {
  struct Hit: Hashable, Comparable {
    let file: String
    let line: Int
    let rule: String
    let literal: String

    var text: String { "\(file):\(line)\t\(rule)\t\(literal)" }
    static func < (a: Hit, b: Hit) -> Bool { a.text < b.text }
  }

  /// Files whose CJK literals are not shown to people, with the reason.
  static let notUserVisible: [(path: String, reason: String)] = [
    (
      "Packages/MindloomDesign/Sources/MindloomDesign/Text/TextRules.swift",
      "the checker's own word lists"
    ),
    (
      "Packages/MindloomDesign/Sources/MindloomDesign/Brand/TitleCinch.swift",
      "the film title card, not in the Apps"
    ),
    (
      "Packages/BestASRCore/Sources/BestASRProcessing/ProtectedFactValidator.swift",
      "a negation regex"
    ),
    (
      "Packages/BestASRCore/Sources/BestASRProcessing/SpokenInstructionIntent.swift",
      "words a spoken command is parsed by"
    ),
    ("Packages/MindloomLink/Sources/MindloomSpacesTestSupport/", "test fakes"),
    (
      "Packages/MindloomLookup/Sources/MindloomLookup/OutboundPatterns.swift",
      "the patterns and word lists outgoing lookup words are refused by"
    ),
    (
      "Packages/BestASRCore/Sources/BestASRMemoryUI/Shell/MindloomSurfaces.swift",
      "the design catalog's state notes"
    ),
    (
      "Packages/BestASRCore/Sources/BestASRMemoryUI/PersonQuotes.swift",
      "greeting words a quote is filtered by"
    ),
    (
      "Packages/BestASRCore/Sources/BestASRMemoryUI/Avatar.swift",
      "name prefixes an avatar is drawn from"
    ),
    ("Packages/BestASRCore/Sources/BestASRMemory/Search/", "words a search query is parsed by"),
    (
      "Packages/BestASRCore/Sources/BestASRMemory/MatterTexts.swift",
      "patterns a matter's text is parsed by"
    ),
    (
      "Packages/BestASRCore/Sources/BestASRDomain/PrivacyMask.swift",
      "number patterns and placeholders"
    ),
    (
      "Packages/BestASRCore/Sources/BestASREntries/ZoteroEntry.swift",
      "the imported item's own text"
    ),
    ("Packages/BestASRCore/Sources/BestASRMLXRuntime/", "prompts for the local model"),
    (
      "Packages/BestASRCore/Sources/MindloomAgentProtocol/MCPMessage.swift",
      "instructions for an agent's model"
    ),
    (
      "Packages/BestASRCore/Sources/MindloomAgentProtocol/AgentTools.swift",
      "tool schemas for an agent's model"
    ),
    (
      "Packages/BestASRCore/Sources/BestASRAgentAccess/AgentReader.swift",
      "text an agent's model reads"
    ),
    ("Packages/BestASRCore/Sources/SearchEvalCLI/", "a developer tool"),
    ("Packages/BestASRCore/Sources/SpokenModeProbeCLI/", "a developer tool"),
    ("App/LiveShots.swift", "the preview's synthetic verification walk"),
    (
      "Packages/BestASRCore/Sources/BestASRRemoteOrganizer/PhoneRelayScript.swift",
      "a byte-pinned shell script run on the relay host; its comments are not shown"
    ),
    ("App/LocalEventOrganizer.swift", "topic stop words"),
    ("iOS/App/Debug/", "synthetic debug states"),
    ("iOS/App/Model/TextRules.swift", "filler words a dictation is cleaned by"),
  ]

  /// Where 织机 may appear: About on both platforms, the brand lockups (they
  /// draw it only with `showsZhiji`), the agent instructions (so an agent
  /// knows the owner's word: the Claude Code skill, which also says to
  /// answer with Mindloom), and keyboard names recorded by older builds.
  static let nameAllowed = [
    "integrations/claude-code-plugin/skills/mindloom/SKILL.md",
    "Packages/BestASRCore/Sources/BestASRMemoryUI/Capture/SettingsWindowView.swift",
    "iOS/App/Views/Settings/SettingsViews.swift",
    "Packages/MindloomDesign/Sources/MindloomDesign/Brand/Wordmark.swift",
    "Packages/MindloomDesign/Sources/MindloomDesign/Brand/WelcomeCinch.swift",
    "Packages/MindloomDesign/Sources/MindloomDesign/Brand/MindloomWelcomeCinch.swift",
    "Packages/BestASRCore/Sources/BestASRMemory/MemoryItemSource.swift",
  ]

  static let promises = [
    "不会", "从不", "永不", "永远不", "决不", "放心", "担心", "只在", "只会", "只用", "只发", "只送", "只留",
    "只存", "只给", "只记", "只从", "只看到", "只连", "只读：", "只读，", "只保存", "只保留", "只录", "只收",
    "只把", "只有你的", "不上传", "不离开", "不连接网络", "不联网", "不连网",
    // A guarantee the App's own 16 kHz rewrite makes untrue (review 10-6 S12).
    "由你删除", "只由你",
  ]
  static let colloquial = [
    "也可以改", "吧", "呢", "啦", "哦", "呀", "嘛", "东西", "看看", "一下", "忘掉", "没连上", "连不上", "连上",
    "打不开", "看不懂", "没看懂", "没能", "弄", "搞", "啥", "咋", "起个名", "删掉", "去掉", "以后再说", "去设置",
    "留着", "不见了", "装好", "收进", "收好", "复制",
  ]
  static let technical = [
    "SSH", "ssh ", "ProxyJump", "known_hosts", "组件", "XPC", "tools/call", "defaults write",
    "stderr", "launchd",
  ]
  /// System Settings names macOS 27 does not use for what Mindloom means.
  /// The permission Mindloom needs to type into other Apps is
  /// 「设备控制和数据访问」 under 「隐私与安全」 (SecurityPrivacyExtension,
  /// key ACCESSIBILITY); 「无障碍」 is the VoiceOver pane, and 「辅助功能」 the
  /// old name (review 10-5c C1).
  static let wrongSystemNames = ["无障碍", "辅助功能", "隐私与安全性", "屏幕与系统音频录制", "屏幕录制"]

  /// Words that state a scope and can also be a promise with one character
  /// changed (只录 → 仅录制). Each place was read; new ones must be.
  static let scopeWords = ["仅录制", "仅保存", "仅用于"]
  static let reviewedScope: [(file: String, literal: String, reason: String)] = [
    (
      "App/ContentView+Dictionary.swift", "仅保存词典内容",
      "what an export of the dictionary contains"
    ),
    ("App/DictationSettingsView.swift", "仅用于高级本机部署", "who needs this setting"),
    (
      "App/SpacesModel.swift", "此空间仅保存文字",
      "the shared space's rule, said when originals were left out"
    ),
    (
      "Packages/BestASRCore/Sources/BestASRMemory/MemoryItemSource.swift", "仅录制了麦克风",
      "what a meeting recording holds"
    ),
    (
      "Packages/BestASRCore/Sources/BestASRMemoryUI/Capture/MenuBarExtraContent.swift",
      "仅录制麦克风", "what the recording in progress holds"
    ),
    (
      "Packages/BestASRCore/Sources/BestASRMemoryUI/Spaces/SpaceRefusalWords.swift", "此空间仅保存文字",
      "the shared space's rule, said when a share is refused"
    ),
  ]

  /// Every rule `text` breaks in `file`.
  static func rules(broken text: String, in file: String) -> [String] {
    var out: [String] = []
    if text.contains("织机"), !nameAllowed.contains(file) { out.append("name 织机") }
    // 织机 as a second name in brackets: a model reading it answers with
    // both (review 10-5d R7). Where 织机 may appear, it is the owner's
    // other word, said as such.
    if text.range(of: #"Mindloom\s*[（(]\s*织机"#, options: .regularExpression) != nil {
      out.append("name Mindloom（织机）")
    }
    // “系统设置” is the app's name, in quotes; a path is “系统设置”>“键盘”
    // (review 10-5d R11).
    if text.range(of: "(?<!“)系统设置|系统设置(?!”)", options: .regularExpression) != nil {
      out.append("system name 系统设置 without quotes")
    }
    if text.contains("→"), text.contains("设置") { out.append("path →") }
    for word in promises where text.contains(word) { out.append("promise \(word)") }
    if text.range(of: "(?<!拒)绝不", options: .regularExpression) != nil { out.append("promise 绝不") }
    if text.replacingOccurrences(of: "隐私与安全", with: "").contains("安全") { out.append("promise 安全") }
    for word in colloquial where text.contains(word) { out.append("colloquial \(word)") }
    for word in technical where text.contains(word) { out.append("technical \(word)") }
    for word in wrongSystemNames where text.contains(word) { out.append("system name \(word)") }
    for word in scopeWords where text.contains(word) {
      let reviewed = reviewedScope.contains { $0.file == file && text.contains($0.literal) }
      if !reviewed { out.append("review \(word)") }
    }
    // A character set listing both brackets (a pattern, not words) is not a quote.
    if (text.contains("「") || text.contains("」")) && !text.contains("「」") { out.append("quote 「」") }
    return out
  }

  static func scanSources() throws -> [Hit] {
    let root = VocabularyGuardTests.repositoryRoot
    var hits: [Hit] = []
    for folder in VocabularyGuardTests.folders {
      let base = root.appendingPathComponent(folder)
      guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
      else { continue }
      for case let url as URL in walker where url.pathExtension == "swift" {
        let relative = String(url.path.dropFirst(root.path.count + 1))
        if relative.contains("/Tests/")
          || notUserVisible.contains(where: { relative.hasPrefix($0.path) })
        {
          continue
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        var inMultiline = false
        var previous = ""
        for (index, raw) in source.split(separator: "\n", omittingEmptySubsequences: false)
          .enumerated()
        {
          let line = String(raw)
          defer { previous = line }
          let trimmed = line.trimmingCharacters(in: .whitespaces)
          if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
          // A list of characters (line breaking, sets), not words: the line
          // above says `// copy-guard: characters`, and only literals with no
          // letters in them are let through (review 10-5c C5).
          let characterList = previous.contains("copy-guard: characters")
          if line.components(separatedBy: "\"\"\"").count % 2 == 0 {
            inMultiline.toggle()
            continue
          }
          let texts = inMultiline ? [line] : VocabularyGuardTests.literals(in: line)
          for text in texts
          where text.unicodeScalars.contains(where: { (0x3000...0x9FFF).contains($0.value) }) {
            if characterList, Self.isCharacterList(text) { continue }
            var broken = rules(broken: text, in: relative)
            // `VocabularyGuardTests` reads one-line literals only; a
            // multi-line one gets its word list here (review 10-5c C5).
            if inMultiline { broken += Self.vocabulary(text) }
            for rule in broken {
              hits.append(Hit(file: relative, line: index + 1, rule: rule, literal: text))
            }
          }
        }
      }
    }
    return hits.sorted()
  }

  /// A literal of punctuation only (no letters, no ideographs): what the
  /// `copy-guard: characters` mark lets through.
  static func isCharacterList(_ literal: String) -> Bool {
    !literal.unicodeScalars.contains { CharacterSet.letters.contains($0) }
  }

  /// `MLVocabulary`'s banned and avoided words in `text`.
  static func vocabulary(_ text: String) -> [String] {
    guard text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else {
      return []
    }
    return MLVocabulary.check(text).map { "vocabulary \($0.word)" }
  }

  /// The strings the extensions and plugins under `integrations/` show: every
  /// string value of their JSON manifests and every string literal of their
  /// JavaScript (review 10-5c C2: the Chrome extension and the Claude Desktop
  /// extension still said 收进织机, 也可以改, 遮住, 不联网).
  static func scanIntegrations() throws -> [String] {
    let root = VocabularyGuardTests.repositoryRoot
    let base = root.appendingPathComponent("integrations")
    guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
    else { return ["integrations/ is missing"] }
    var problems: [String] = []
    var files = 0
    func check(_ text: String, _ location: String) {
      guard text.unicodeScalars.contains(where: { (0x3000...0x9FFF).contains($0.value) }) else {
        return
      }
      for rule in rules(broken: text, in: location) + vocabulary(text) {
        problems.append("\(location)\t\(rule)\t\(text)")
      }
    }
    func walk(_ value: Any, _ location: String) {
      if let text = value as? String { check(text, location) }
      if let array = value as? [Any] { for element in array { walk(element, location) } }
      if let dictionary = value as? [String: Any] {
        for (key, element) in dictionary {
          walk(key, location)
          walk(element, location)
        }
      }
    }
    var descriptions = 0
    for case let url as URL in walker {
      let relative = String(url.path.dropFirst(root.path.count + 1))
      switch url.pathExtension {
      case "md":
        // A skill's or a command's `description:` line: what Claude Code
        // shows in its “/” menu, and what its model reads to pick the skill
        // (review 10-5d R7). The rest of the file is instructions for the
        // model.
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        where line.hasPrefix("description:") {
          descriptions += 1
          let text = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
          check(text, relative)
          // Where the owner's other word appears, Mindloom comes first and
          // the model is told to answer with Mindloom.
          if text.contains("织机") {
            let mindloom = text.range(of: "Mindloom")?.lowerBound
            let zhiji = text.range(of: "织机")?.lowerBound
            if mindloom == nil || zhiji.map({ mindloom! > $0 }) == true {
              problems.append("\(relative)\tname Mindloom first\t\(text)")
            }
            if !text.contains("回答主人时写 Mindloom") {
              problems.append("\(relative)\tsay to answer with Mindloom\t\(text)")
            }
          }
        }
      case "json":
        files += 1
        walk(try JSONSerialization.jsonObject(with: Data(contentsOf: url)), relative)
      case "js":
        files += 1
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
          let trimmed = line.trimmingCharacters(in: .whitespaces)
          if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
          for text in javaScriptLiterals(in: String(line)) { check(text, relative) }
        }
      default:
        continue
      }
    }
    if files == 0 { problems.append("no manifests or scripts found under integrations/") }
    if descriptions < 3 {
      problems.append("the plugin's skill and command descriptions were not found")
    }
    return problems.sorted()
  }

  /// The string literals on a line of JavaScript ("…", '…' or `…`); a `//`
  /// outside a literal ends the line.
  static func javaScriptLiterals(in line: String) -> [String] {
    var out: [String] = []
    var quote: Character?
    var current = ""
    var escaped = false
    var previous: Character = " "
    for character in line {
      if let open = quote {
        if escaped {
          current.append(character)
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == open {
          out.append(current)
          current = ""
          quote = nil
        } else {
          current.append(character)
        }
      } else if character == "\"" || character == "'" || character == "`" {
        quote = character
      } else if character == "/", previous == "/" {
        break
      }
      previous = character
    }
    return out
  }

  func testTheExtensionsAndPluginsFollowTheCopyRules() throws {
    let problems = try Self.scanIntegrations()
    XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
  }

  func testNoUserFacingStringBreaksTheCopyRules() throws {
    let hits = try Self.scanSources()
    XCTAssertEqual(
      hits.map(\.text), [],
      "UI copy rules (docs/UI-COPY.md §6):\n" + hits.map(\.text).joined(separator: "\n"))
  }

  /// The Info.plist names and usage descriptions, and their zh-Hans
  /// translations, follow the same rules; the English ones make no promises.
  func testNamesAndUsageDescriptionsSayWhatTheyDo() throws {
    let root = VocabularyGuardTests.repositoryRoot
    let plists = [
      "App/Info.plist", "App/Info-Preview.plist", "ShareExtension/Info.plist", "iOS/App/Info.plist",
      "iOS/Keyboard/Info.plist", "iOS/Share/Info.plist", "iOS/LiveActivity/Info.plist",
      "iOS/Watch/Info.plist", "iOS/WatchWidgets/Info.plist",
    ]
    var problems: [String] = []
    var usageCount = 0
    func check(_ text: String, _ location: String) {
      for rule in Self.rules(broken: text, in: location) {
        problems.append("\(location)\t\(rule)\t\(text)")
      }
      if text.range(
        of: #"\b(never|only|safe|safely|secure)\b"#,
        options: [.regularExpression, .caseInsensitive]) != nil
      {
        problems.append("\(location)\tpromise (English)\t\(text)")
      }
    }
    func walk(_ value: Any, _ location: String) {
      if let text = value as? String { check(text, location) }
      if let array = value as? [Any] { for element in array { walk(element, location) } }
      if let dictionary = value as? [String: Any] {
        for element in dictionary.values { walk(element, location) }
      }
    }
    for path in plists {
      let data = try Data(contentsOf: root.appendingPathComponent(path))
      let plist = try XCTUnwrap(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], path)
      for (key, value) in plist
      where key.hasSuffix("UsageDescription") || key == "CFBundleDisplayName"
        || key == "CFBundleName"
        || key == "NSServices"
      {
        if key.hasSuffix("UsageDescription") { usageCount += 1 }
        walk(value, "\(path) \(key)")
      }
    }
    let catalog = try JSONSerialization.jsonObject(
      with: Data(contentsOf: root.appendingPathComponent("App/InfoPlist.xcstrings")))
    let strings = try XCTUnwrap((catalog as? [String: Any])?["strings"] as? [String: Any])
    for (key, entry) in strings {
      walk(entry, "App/InfoPlist.xcstrings \(key)")
    }
    // Every Mac usage description has a zh-Hans translation.
    let mac = try XCTUnwrap(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: root.appendingPathComponent("App/Info.plist")), format: nil)
        as? [String: Any])
    for key in mac.keys where key.hasSuffix("UsageDescription") {
      let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any]
      XCTAssertNotNil(localizations?["zh-Hans"], "\(key) has no zh-Hans translation")
    }
    XCTAssertGreaterThanOrEqual(usageCount, 8)
    XCTAssertEqual(problems.sorted(), [], problems.sorted().joined(separator: "\n"))
  }

  /// Regression (review 10-5c C4): the stacked lockup drew 「织机」 unless told
  /// not to, so a new use on Welcome would have brought the name back. It
  /// draws it only when asked (About).
  @MainActor
  func testTheBrandLockupDrawsZhijiOnlyWhenAsked() {
    XCTAssertFalse(MindloomStackedLockup().showsZhiji)
    XCTAssertTrue(MindloomStackedLockup(showsZhiji: true).showsZhiji)
  }

  /// The checker itself: what it refuses and what it lets through.
  func testTheRulesKnowWhatTheyRefuse() {
    let file = "App/Example.swift"
    XCTAssertEqual(Self.rules(broken: "也可以改", in: file), ["colloquial 也可以改"])
    XCTAssertTrue(Self.rules(broken: "录音不会上传", in: file).contains("promise 不会"))
    XCTAssertTrue(Self.rules(broken: "声音只留在这台 Mac", in: file).contains("promise 只留"))
    XCTAssertTrue(Self.rules(broken: "原音已安全保存", in: file).contains("promise 安全"))
    XCTAssertTrue(Self.rules(broken: "收进织机", in: file).contains("name 织机"))
    XCTAssertEqual(Self.rules(broken: "织机", in: Self.nameAllowed[0]), [])
    XCTAssertTrue(
      Self.rules(broken: "SSH 设置里的 ProxyJump", in: file).contains("technical ProxyJump"))
    XCTAssertTrue(Self.rules(broken: "识别组件", in: file).contains("technical 组件"))
    XCTAssertTrue(Self.rules(broken: "系统设置 → 隐私与安全性 → 辅助功能", in: file).contains("system name 辅助功能"))
    // Review 10-5c C1: 无障碍 is the VoiceOver pane, not the permission.
    XCTAssertTrue(Self.rules(broken: "无障碍权限未开启", in: file).contains("system name 无障碍"))
    XCTAssertEqual(
      Self.rules(broken: "请在“系统设置”>“隐私与安全”>“设备控制和数据访问”中允许 Mindloom。", in: file), [])
    // Review 10-5c C3: a scope word needs a review.
    XCTAssertEqual(Self.rules(broken: "Mindloom 仅录制声音。", in: file), ["review 仅录制"])
    XCTAssertEqual(
      Self.rules(broken: "此空间仅保存文字", in: "App/SpacesModel.swift"), [],
      "a reviewed place passes")
    // Review 10-5c C5: the character-list mark covers punctuation only, and
    // a multi-line literal gets the word list.
    XCTAssertTrue(Self.isCharacterList(#""，。、；""#))
    XCTAssertTrue(Self.isCharacterList(#""（「『《【""#))
    XCTAssertFalse(Self.isCharacterList(#""请按「确定」""#))
    XCTAssertEqual(Self.vocabulary("按绳分组"), ["vocabulary 绳"])
    XCTAssertEqual(Self.vocabulary("plain"), [])
    // The JavaScript reader.
    XCTAssertEqual(
      Self.javaScriptLiterals(in: #"  title: "收进织机", x: 'a\'b', // "注释""#),
      ["收进织机", "a'b"])
    XCTAssertTrue(Self.rules(broken: "选「连接 Mac」", in: file).contains("quote 「」"))
    XCTAssertTrue(Self.rules(broken: "DGX Spark 没连上", in: file).contains("colloquial 没连上"))
    XCTAssertTrue(Self.rules(broken: "已复制", in: file).contains("colloquial 复制"))
    // Review 10-5d R7: 织机 as a bracketed second name.
    XCTAssertTrue(
      Self.rules(broken: "从 Mindloom（织机）取来", in: Self.nameAllowed[0])
        .contains("name Mindloom（织机）"))
    XCTAssertEqual(
      Self.rules(broken: "主人也可能叫它“织机”；回答主人时写 Mindloom。", in: Self.nameAllowed[0]), [])
    // Review 10-5d R11: “系统设置” in quotes, and no arrow paths.
    XCTAssertTrue(
      Self.rules(broken: "打开系统设置", in: file).contains("system name 系统设置 without quotes"))
    XCTAssertTrue(
      Self.rules(broken: "请在 系统设置 → 键盘 把…", in: file).contains("path →"))
    XCTAssertTrue(
      Self.rules(broken: "请在系统提示或系统设置中允许 Mindloom", in: file)
        .contains("system name 系统设置 without quotes"))
    XCTAssertEqual(
      Self.rules(broken: "请在“系统设置”>“键盘”中将“按下🌐︎键时”设为“不执行任何操作”。", in: file), [])
    XCTAssertEqual(Self.rules(broken: "打开“系统设置”", in: file), [])
    XCTAssertEqual(Self.rules(broken: "正在准备 英语 → 中文 翻译", in: file), [], "not a path")
    // Apple's own words pass.
    for fine in [
      "允许更改", "只读", "已拷贝", "请在“系统设置”>“隐私与安全”>“麦克风”中允许 Mindloom。", "人工确认和拒绝不保存",
      "未连接", "无法连接 DGX Spark。请稍后再试。", "关于 Mindloom",
    ] {
      XCTAssertEqual(Self.rules(broken: fine, in: file), [], fine)
    }
  }
}
