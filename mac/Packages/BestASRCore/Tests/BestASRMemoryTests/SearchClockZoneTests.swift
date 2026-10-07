import BestASRMemory
import XCTest

/// v12 integration (ALIGNMENT 根-13): 历史's day headers and search time
/// words count days in the library's product time zone, the one Home uses,
/// not a second fixed copy of it.
final class SearchClockZoneTests: XCTestCase {
  override func tearDown() {
    SearchClock.setProductTimeZone(SearchClock.defaultTimeZone)
    super.tearDown()
  }

  func testTheSearchClockFollowsTheProductTimeZone() throws {
    XCTAssertEqual(SearchClock.productTimeZone.identifier, "Asia/Singapore")
    XCTAssertEqual(SearchClock().calendar.timeZone.identifier, "Asia/Singapore")
    let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    SearchClock.setProductTimeZone(losAngeles)
    XCTAssertEqual(SearchClock.productTimeZone, losAngeles)
    XCTAssertEqual(SearchClock().calendar.timeZone, losAngeles)
    XCTAssertEqual(SearchClock.productCalendar.timeZone, losAngeles)
    // 今天 is a Los Angeles day: 2026-10-02 06:00 UTC is still 10-01 there.
    let now = Date(timeIntervalSince1970: 1_790_920_800)
    let today = try XCTUnwrap(
      SearchTimeWords.find(in: "今天", clock: SearchClock(now: now)).first)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = losAngeles
    XCTAssertEqual(calendar.component(.day, from: today.interval.start), 1)
    XCTAssertEqual(today.interval.duration, 86_400)
  }
}
