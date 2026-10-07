import BestASRMemory
import BestASRMemoryUI
import SwiftUI

/// Shared spaces on the Mindloom pages (v11): the sidebar's 共享 rows open a
/// space's page; the space's own library is built when its page is shown
/// (`followSpaceScope`); the sheets are the v8 ones (`SpaceSheetHost`).
/// mac-capture owns the space page and the sharing sheets.
extension ContentView {
  var spacesActions: SpacesActions {
    let navigation = $memoryNavigation
    return spaces.actions { scope, eventID in
      var next = MemoryNavigation()
      if case .space(let id) = scope { next.root = .space(id) }
      if let eventID { next.path = [.matter(eventID)] }
      navigation.wrappedValue = next
    }
  }

  /// The space whose page is shown is the spaces model's scope (its matters
  /// are read from the space's own library); elsewhere it is 我的.
  func followSpaceScope(_ root: MindloomRoot) {
    if case .space(let id) = root {
      spaces.setScope(.space(id))
    } else {
      spaces.setScope(.mine)
    }
  }
}
