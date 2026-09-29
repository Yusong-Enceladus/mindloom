import AppKit
import BestASRMemory
import SwiftUI
import XCTest

@testable import BestASRMemoryUI

/// A long cast must not widen the event page (the scale-lab thread pages with
/// about 15 people were pushed under the sidebar and cut off).
@MainActor
final class PeopleChipsTests: XCTestCase {
  private func people(_ count: Int) -> [MemoryPersonRef] {
    (0..<count).map { MemoryPersonRef(personID: "p\($0)", name: "同学\($0) Name\($0)") }
  }

  func testManyPeopleFitTheWidthOffered() {
    let chips = PeopleChips(people: people(15), actions: .inert, open: { _ in })
    let host = NSHostingController(rootView: chips.environment(\.zhijiSnapshot, true))
    for width in [300.0, 520.0, 700.0] {
      let size = host.sizeThatFits(in: CGSize(width: width, height: 200))
      XCTAssertLessThanOrEqual(size.width, width, "15 chips offered \(width) pt")
    }
  }

  func testChipCountsTryAllThenFewer() {
    XCTAssertEqual(PeopleChips.counts(3), [3, 2, 1, 0])
    XCTAssertEqual(PeopleChips.counts(15), [15, 8, 6, 5, 4, 3, 2, 1, 0])
    XCTAssertEqual(PeopleChips.counts(0), [0])
  }
}
