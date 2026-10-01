import BestASRMemory
import BestASRMemoryUI
import SwiftUI

/// Shared spaces on the memory pages: the switcher above Home, the bar
/// under a matter, the sheets, and the page state and corrections of the
/// chosen scope (a space's matters are edited through proposals, never
/// through the personal organizer).
extension ContentView {
  var spacesActions: SpacesActions {
    let navigation = $memoryNavigation
    return spaces.actions { scope, eventID in
      var next = MemoryNavigation(tab: .home, homeMode: .events)
      if let eventID { next.path = [.event(eventID)] }
      navigation.wrappedValue = next
      _ = scope
    }
  }

  /// The switcher and the space line, then whatever Home showed before.
  func spacesHomeAccessory(_ existing: AnyView?) -> AnyView? {
    AnyView(
      VStack(alignment: .leading, spacing: 16) {
        SpaceSwitcherBar(state: spaces.screen, actions: spacesActions)
        if let existing { existing }
      }
      .frame(maxWidth: 900, alignment: .leading)
    )
  }

  func spacesEventAccessory(_ eventID: String) -> AnyView? {
    guard SpaceMatterBar.shows(eventID: eventID, state: spaces.screen) else { return nil }
    return AnyView(SpaceMatterBar(eventID: eventID, state: spaces.screen, actions: spacesActions))
  }

  /// The page state of the scope (我的 is the personal state as it is).
  func spacesScopedState(_ personal: MemoryScreenState) -> MemoryScreenState {
    spaces.memoryState(personal: personal)
  }

  /// In a space, corrections go to the space (a rename is a proposal, or a
  /// direct edit for maintainers); nothing reaches the personal organizer.
  /// In 全部, a space's matter is read-only and mine behave as in 我的.
  func spacesScopedActions(_ personal: MemoryActions) -> MemoryActions {
    let scope = spaces.screen.scope
    let model = spaces
    switch scope {
    case .mine:
      return personal
    case .space:
      var actions = MemoryActions.inert
      actions.renameEvent = { model.renameInSpace(eventID: $0, title: $1) }
      actions.copyText = { model.copySpaceText($0) }
      actions.refresh = { model.rebuild() }
      actions.stop = personal.stop
      // The owner's own Reminders, on the owner's click (V8 contract A5).
      actions.addToReminders = personal.addToReminders
      return actions
    case .all:
      let shared = model.spaceEventsInAll
      var actions = personal
      let rename = personal.renameEvent
      actions.renameEvent = { id, title in
        shared[id] != nil ? model.renameInSpace(eventID: id, title: title) : rename(id, title)
      }
      let copy = personal.copyText
      actions.copyText = { id in shared[id] == nil ? copy(id) : model.copySpaceText(id) }
      for keyPath in [\MemoryActions.featureLess, \MemoryActions.exportText] {
        let original = personal[keyPath: keyPath]
        actions[keyPath: keyPath] = { id in if shared[id] == nil { original(id) } }
      }
      let pin = personal.pin
      actions.pin = { id, value in if shared[id] == nil { pin(id, value) } }
      let remove = personal.removeItem
      actions.removeItem = { event, item, seg in
        if shared[event] == nil { remove(event, item, seg) }
      }
      let move = personal.moveItem
      actions.moveItem = { item, to, from, seg in
        if shared[to] == nil, from.map({ shared[$0] == nil }) ?? true { move(item, to, from, seg) }
      }
      return actions
    }
  }
}
