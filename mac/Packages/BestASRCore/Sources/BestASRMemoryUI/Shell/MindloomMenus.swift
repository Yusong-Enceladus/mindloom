import AppKit
import MindloomDesign
import SwiftUI

// Menus in the window (MAC-SPEC §7.5): every item with its SF Symbol, and
// 「删除…」 / 「删除这个分组」 / 「退出这个共享空间」 in vermilion (icon too).
// macOS 27's AppKit hides menu item images unless an item asks for them
// (`NSMenuItem.preferredImageVisibility`), which SwiftUI's `.contextMenu` and
// `Menu` do not; `MindloomMenuStyle` asks for them on each window menu as it
// opens. The 原文 item's menu is built here directly (`MindloomRightClickMenu`),
// so its words can stay selectable.

/// The look of the window's menus (§7.5), applied as each one opens.
@MainActor
public enum MindloomMenuStyle {
  private static var observers: [NSObjectProtocol] = []
  /// Window menus open now (SwiftUI fills or rebuilds their items after
  /// tracking began, so items added or changed while open are styled too).
  private static var open: Set<ObjectIdentifier> = []

  /// Styles every window menu (context menus, 「⋯」 and 「+」 menus, their
  /// submenus) as it opens and while it is open, and the menu bar extra's
  /// menu (§3.2 lists its icons too: record.circle, arrow.clockwise …). The
  /// App menus in the menu bar (文件, 编辑 …) are left as macOS draws them.
  /// Call once at launch.
  public static func install() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    // Posted on the main thread, where menus track.
    observers.append(
      center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) {
        note in
        nonisolated(unsafe) let object = note.object
        MainActor.assumeIsolated {
          guard let menu = object as? NSMenu, !isInMainMenu(menu) else { return }
          open.insert(ObjectIdentifier(top(menu)))
          // While AppKit is still presenting the menu only the image
          // visibility may change (a new image here crashes the context
          // menu); anything else waits a turn.
          showImages(menu)
          if menu.items.contains(where: { needsPaint($0) || needsTemplate($0) }) {
            nonisolated(unsafe) let later = menu
            DispatchQueue.main.async { MainActor.assumeIsolated { style(later) } }
          }
        }
      })
    observers.append(
      center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) {
        note in
        nonisolated(unsafe) let object = note.object
        MainActor.assumeIsolated {
          guard let menu = object as? NSMenu, menu.supermenu == nil else { return }
          open.remove(ObjectIdentifier(menu))
        }
      })
    for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: nil) { note in
          nonisolated(unsafe) let object = note.object
          let index = note.userInfo?["NSMenuItemIndex"] as? Int
          MainActor.assumeIsolated {
            guard let menu = object as? NSMenu, let index, index >= 0, index < menu.numberOfItems
            else { return }
            let item = menu.items[index]
            guard top(menu) !== NSApp.mainMenu else { return }
            if open.contains(ObjectIdentifier(top(menu))) {
              // An open window menu changed: style the item after this pass.
              nonisolated(unsafe) let later = item
              nonisolated(unsafe) let font = menu.font
              DispatchQueue.main.async {
                MainActor.assumeIsolated { style(later, font: font) }
              }
            } else {
              // Being built (SwiftUI fills a context menu before it opens):
              // its icons and the destructive tint go in now.
              templateImage(item)
              if needsPaint(item) { paintDestructive(item, font: menu.font) }
            }
          }
        })
    }
  }

  private static func top(_ menu: NSMenu) -> NSMenu {
    var current = menu
    while let parent = current.supermenu { current = parent }
    return current
  }

  /// Whether `menu` is the menu bar or one of its submenus.
  static func isInMainMenu(_ menu: NSMenu) -> Bool {
    var current: NSMenu? = menu
    while let each = current {
      if each === NSApp.mainMenu { return true }
      current = each.supermenu
    }
    return false
  }

  /// Icons visible; destructive items in `--alert` (title and icon).
  public static func style(_ menu: NSMenu) {
    for item in menu.items { style(item, font: menu.font) }
  }

  /// One item; changes nothing already styled (each change posts
  /// `didChangeItem` again).
  /// Not while AppKit presents the menu (use `showImages` then).
  static func style(_ item: NSMenuItem, font: NSFont?) {
    guard !item.isSeparatorItem else { return }
    templateImage(item)
    showImage(item)
    if needsPaint(item) { paintDestructive(item, font: font) }
    if let submenu = item.submenu { style(submenu) }
  }

  private static func showImages(_ menu: NSMenu) {
    for item in menu.items {
      showImage(item)
      if let submenu = item.submenu { showImages(submenu) }
    }
  }

  /// The image shown, and drawn like the title (§7.5 icons are `--ink-2`;
  /// SwiftUI hands AppKit its label image already coloured with the accent).
  /// The image object itself is changed, never replaced: replacing it while
  /// AppKit presents the menu crashes.
  /// SwiftUI hands AppKit its label image already coloured with the accent;
  /// §7.5 icons are `--ink-2` like the title (white when highlighted), so the
  /// image is replaced by a template of its shape. Never while AppKit
  /// presents the menu (replacing an image then crashes).
  static func templateImage(_ item: NSMenuItem) {
    guard let image = item.image, !(image is TintedImage), !(image is TemplateImage),
      !isDestructive(item.title)
    else { return }
    let shape = TemplateImage(size: image.size, flipped: false) { rect in
      image.draw(in: rect)
      return true
    }
    shape.isTemplate = true
    item.image = shape
  }

  /// An item image redrawn as a template.
  final class TemplateImage: NSImage {}

  private static func showImage(_ item: NSMenuItem) {
    guard item.image != nil else { return }
    if #available(macOS 27.0, *), item.preferredImageVisibility != .visible {
      item.preferredImageVisibility = .visible
    }
  }

  static func needsTemplate(_ item: NSMenuItem) -> Bool {
    guard let image = item.image else { return false }
    return !isDestructive(item.title) && !(image is TemplateImage)
  }

  static func needsPaint(_ item: NSMenuItem) -> Bool {
    guard !item.isSeparatorItem, isDestructive(item.title) else { return false }
    return !isPainted(item) || (item.image != nil && !(item.image is TintedImage))
  }

  static func isPainted(_ item: NSMenuItem) -> Bool {
    guard let title = item.attributedTitle, title.length > 0 else { return false }
    return title.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil
  }

  /// The destructive items of §7.5, the group page's title menu and the
  /// space page's menu, by their exact titles: a group or space the user
  /// named 「删除旧数据」 is listed in menus too and is not destructive
  /// (review finish-ship).
  static let destructiveTitles: Set<String> = ["删除…", "删除分组", "退出共享空间"]

  public static func isDestructive(_ title: String) -> Bool {
    destructiveTitles.contains(title)
  }

  /// Each change posts `didChangeItem` synchronously (which comes back
  /// here), so only what is not painted yet is set.
  static func paintDestructive(_ item: NSMenuItem, font: NSFont?) {
    let color = MLColor.alert.platformColor
    if let image = item.image, !(image is TintedImage) { item.image = tinted(image, color) }
    if !isPainted(item) {
      item.attributedTitle = NSAttributedString(
        string: item.title,
        attributes: [
          .foregroundColor: color, .font: font ?? NSFont.menuFont(ofSize: 0),
        ])
    }
  }

  /// An item image already drawn in its colour.
  final class TintedImage: NSImage {}

  /// `image` drawn in `color` (a symbol through its palette; anything else,
  /// such as the bitmap SwiftUI hands AppKit, filled over its own alpha).
  static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = TintedImage(size: image.size, flipped: false) { rect in
      image.draw(in: rect)
      color.set()
      rect.fill(using: .sourceAtop)
      return true
    }
    out.isTemplate = false
    return out
  }
}

/// One item of an AppKit-built window menu.
public struct MindloomMenuEntry {
  public let title: String
  public let symbol: String?
  public let action: @MainActor () -> Void

  public init(_ title: String, symbol: String?, action: @escaping @MainActor () -> Void) {
    self.title = title
    self.symbol = symbol
    self.action = action
  }
}

/// A right-click (or control-click) anywhere on the view it covers opens
/// `sections` (a separator between sections). Every other click passes
/// through, so selectable text under it keeps its own selection by drag and
/// double-click. `open` follows the menu (the row's tint while it is open).
/// With `copySelection`, words selected under it (a drag or double-click
/// before the right-click) add 「复制所选」 first, which hands exactly the
/// selected words to `copySelection` (review finish-ship: 「复制」 copies the
/// whole item, which is not what someone who selected half a sentence wants).
struct MindloomRightClickMenu: NSViewRepresentable {
  let sections: [[MindloomMenuEntry]]
  var copySelection: (@MainActor (String) -> Void)? = nil
  let open: (Bool) -> Void

  func makeNSView(context: Context) -> CatcherView {
    let view = CatcherView()
    view.sections = sections
    view.copySelection = copySelection
    view.open = open
    return view
  }

  func updateNSView(_ view: CatcherView, context: Context) {
    view.sections = sections
    view.copySelection = copySelection
    view.open = open
  }

  final class CatcherView: NSView, NSMenuDelegate {
    var sections: [[MindloomMenuEntry]] = []
    var copySelection: (@MainActor (String) -> Void)?
    var open: (Bool) -> Void = { _ in }

    /// The words selected in the window, when the selection lies under this
    /// view (the item's words); nil otherwise. Read from the selection
    /// owner itself (a text view's range, its accessibility selection, or
    /// its services hook into a private pasteboard), so the general
    /// pasteboard is never touched here.
    func selectedWords() -> String? {
      guard let window, let responder = window.firstResponder as? NSView,
        responder !== self, !(responder is NSTextView && (responder as! NSTextView).isEditable)
      else { return nil }
      let mine = convert(bounds, to: nil)
      let theirs = responder.convert(responder.bounds, to: nil)
      // The selection's view must be the item's words (inside this item),
      // not the whole window's content.
      guard mine.intersects(theirs), theirs.height <= mine.height + 1 else { return nil }
      if let textView = responder as? NSTextView {
        let range = textView.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (textView.string as NSString).length
        else { return nil }
        return Self.nonEmpty((textView.string as NSString).substring(with: range))
      }
      // SwiftUI's selectable text (its text interaction view) tells its
      // selection to accessibility, not to the services hook.
      if let selected = Self.nonEmpty(responder.accessibilitySelectedText()) { return selected }
      guard let requestor = responder as? NSServicesMenuRequestor else { return nil }
      let board = NSPasteboard.withUniqueName()
      defer { board.releaseGlobally() }
      board.clearContents()
      guard requestor.writeSelection?(to: board, types: [.string]) == true else { return nil }
      return Self.nonEmpty(board.string(forType: .string))
    }

    static func nonEmpty(_ text: String?) -> String? {
      guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
      }
      return text
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      guard let event = NSApp.currentEvent, Self.isMenuClick(event) else { return nil }
      return super.hitTest(point)
    }

    static func isMenuClick(_ event: NSEvent) -> Bool {
      switch event.type {
      case .rightMouseDown, .rightMouseUp: true
      case .leftMouseDown, .leftMouseUp: event.modifierFlags.contains(.control)
      default: false
      }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
      let menu = NSMenu()
      menu.autoenablesItems = false
      menu.delegate = self
      var sections = sections
      if let copySelection, let words = selectedWords() {
        sections.insert(
          [MindloomMenuEntry("拷贝所选内容", symbol: "text.cursor") { copySelection(words) }], at: 0)
      }
      for (index, section) in sections.enumerated() {
        if index > 0 { menu.addItem(.separator()) }
        for entry in section {
          let item = NSMenuItem(title: entry.title, action: #selector(choose(_:)), keyEquivalent: "")
          item.target = self
          item.representedObject = Box(entry.action)
          if let symbol = entry.symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
          }
          menu.addItem(item)
        }
      }
      MindloomMenuStyle.style(menu)
      return menu
    }

    override func mouseDown(with event: NSEvent) {
      // Control-click: the menu, as a right-click.
      if event.modifierFlags.contains(.control), let menu = menu(for: event) {
        NSMenu.popUpContextMenu(menu, with: event, for: self)
      } else {
        super.mouseDown(with: event)
      }
    }

    @objc private func choose(_ sender: NSMenuItem) {
      (sender.representedObject as? Box)?.action()
    }

    func menuWillOpen(_ menu: NSMenu) { open(true) }
    func menuDidClose(_ menu: NSMenu) { open(false) }

    private final class Box {
      let action: @MainActor () -> Void
      init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    }
  }
}
