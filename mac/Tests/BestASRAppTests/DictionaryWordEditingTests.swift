import BestASRDomain
import BestASRPersistence
import XCTest

@testable import bestASR

/// Settings › 口述 › 词典 and 「添加到词典…」 on a real store (review of 10-6):
/// the owner's library came from bestASR with 23 of 64 words off, and
/// recognition reads enabled words only. A word the owner edits or adds a
/// heard form to reaches dictation; its switch takes it out and puts it back.
final class DictionaryWordEditingTests: XCTestCase {
  private var root: URL!
  private var store: GRDBDictationStore!

  override func setUp() async throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    store = try GRDBDictationStore(databaseURL: root.appendingPathComponent("dictionary.sqlite"))
  }

  override func tearDown() async throws {
    try await store.checkpointAndClose()
    try? FileManager.default.removeItem(at: root)
  }

  private func inContext() async throws -> [String] {
    try await store.dictionaryContext().canonicalTerms
  }

  private func offWord(_ written: String, heard: [String] = []) async throws -> DictionaryEntry {
    let made = try await store.createDictionaryEntry(canonicalForm: written, spokenForms: heard)
    let off = try await store.setDictionaryEntryEnabled(
      id: made.id, expectedRevision: made.revision, enabled: false)
    XCTAssertFalse(off.enabled)
    return off
  }

  func testAnEditedWordThatWasOffReachesDictation() async throws {
    let word = try await offWord("穹顶研究院")
    let before = try await inContext()
    XCTAssertFalse(before.contains("穹顶研究院"))
    try await DictionaryWordEditing.save(
      id: word.id.rawValue, written: "穹顶研究院", heard: ["穹鼎研究院"], in: store)
    let after = try await inContext()
    XCTAssertTrue(after.contains("穹顶研究院"))
    let entry = try await store.dictionaryEntry(id: word.id)
    XCTAssertEqual(entry?.spokenForms, ["穹鼎研究院"])
    XCTAssertEqual(entry?.enabled, true)
  }

  func testAddingAHeardFormToAWordThatWasOffReachesDictation() async throws {
    let word = try await offWord("RoboPrior", heard: ["肉包"])
    try await DictionaryWordEditing.addHeard(heard: "罗博普瑞尔", written: "roboprior", in: store)
    let entry = try await store.dictionaryEntry(id: word.id)
    XCTAssertEqual(entry?.spokenForms, ["肉包", "罗博普瑞尔"])
    XCTAssertEqual(entry?.enabled, true)
    let context = try await inContext()
    XCTAssertTrue(context.contains("RoboPrior"))
    // The same form again changes nothing and still leaves it on.
    try await DictionaryWordEditing.addHeard(heard: "肉包", written: "RoboPrior", in: store)
    let again = try await store.dictionaryEntry(id: word.id)
    XCTAssertEqual(again?.spokenForms, ["肉包", "罗博普瑞尔"])
    XCTAssertEqual(again?.enabled, true)
  }

  func testTheSwitchTakesAWordOutAndPutsItBack() async throws {
    let word = try await store.createDictionaryEntry(canonicalForm: "SkillKnit", spokenForms: [])
    try await DictionaryWordEditing.setEnabled(id: word.id.rawValue, on: false, in: store)
    let off = try await inContext()
    XCTAssertFalse(off.contains("SkillKnit"))
    try await DictionaryWordEditing.setEnabled(id: word.id.rawValue, on: true, in: store)
    let on = try await inContext()
    XCTAssertTrue(on.contains("SkillKnit"))
  }

  func testAWordThatWentIsSaidToHaveChanged() async throws {
    do {
      try await DictionaryWordEditing.save(id: UUID(), written: "x", heard: [], in: store)
      XCTFail("a word that is not there cannot be saved")
    } catch let failure as DictionaryWordEditing.Failure {
      XCTAssertEqual(failure, .changed)
    }
  }
}
