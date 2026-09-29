import XCTest

@testable import bestASR

/// The dictionary's own behaviour, exercised without the app model: the
/// object needs no store for its drafts, and its parsing is a pure function.
@MainActor
final class DictionaryModelTests: XCTestCase {
  func testSpokenFormsSplitOnEitherCommaOrSemicolonAndDeduplicate() {
    // Case-insensitive duplicates collapse, and width variants are compared
    // after compatibility mapping, so the full-width ｂ is the same as b.
    XCTAssertEqual(DictionaryModel.spokenForms("a, b；c\n  A ,, ｂ"), ["a", "b", "c"])
  }

  func testSpokenFormsKeepsFirstSpellingOfADuplicate() {
    XCTAssertEqual(DictionaryModel.spokenForms("Foo, foo, FOO, bar"), ["Foo", "bar"])
    XCTAssertEqual(DictionaryModel.spokenForms(""), [])
  }

  func testACorrectionBecomesADraftEntry() {
    let dictionary = DictionaryModel()
    dictionary.editingDictionaryEntryID = nil
    dictionary.beginEntry(fromCorrection: " 阿尔法 ", corrected: " Alpha ")
    XCTAssertEqual(dictionary.canonicalDraft, "Alpha")
    XCTAssertEqual(dictionary.spokenFormsDraft, "阿尔法")
    XCTAssertNil(dictionary.editingDictionaryEntryID)
    XCTAssertFalse(dictionary.dictionaryStatusMessage.isEmpty)
  }

  func testANewEntryClearsTheDrafts() {
    let dictionary = DictionaryModel()
    dictionary.canonicalDraft = "x"
    dictionary.spokenFormsDraft = "y"
    dictionary.beginNewEntry()
    XCTAssertEqual(dictionary.canonicalDraft, "")
    XCTAssertEqual(dictionary.spokenFormsDraft, "")
  }

  func testSavingAnEmptyStandardFormIsRefusedWithoutAStore() {
    let dictionary = DictionaryModel()
    dictionary.canonicalDraft = "   "
    dictionary.saveDraft()
    XCTAssertEqual(dictionary.dictionaryStatusMessage, "标准写法不能为空")
    XCTAssertFalse(dictionary.saveInProgress)
  }
}
