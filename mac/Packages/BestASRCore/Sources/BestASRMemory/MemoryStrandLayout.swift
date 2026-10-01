import CoreGraphics
import Foundation

/// Where everything of the 线索 map goes for a given width (the prototype's
/// grammar): the time axis with a label a week, the "now" line and the
/// future zone after it; the main thread; each strand on its own line,
/// splitting off the main thread before its first day and, once closed,
/// rejoining it after its last; the items as dots on their line and day;
/// the knots; each knot's label (its words, its evidence's source tiles and
/// people) above or below its line wherever it does not touch another; and
/// rows under the map for the matters this one touches.
///
/// Pure and deterministic: the same model, width and calendar give the
/// same layout.
public struct MemoryStrandLayout: Equatable, Sendable {
  public enum Side: Equatable, Sendable {
    case above
    case below
  }

  public struct StrandPath: Equatable, Sendable {
    public let index: Int
    public let y: CGFloat
    /// Where it leaves the main thread, and where its own line starts.
    public let branchX: CGFloat
    public let startX: CGFloat
    /// Where its own line ends: its last day, or "now" while open.
    public let endX: CGFloat
    /// Where it joins the main thread again; nil while open.
    public let rejoinX: CGFloat?
    /// The dotted run to its last planned knot after today.
    public let futureX: CGFloat?
  }

  public struct KnotSpot: Equatable, Identifiable, Sendable {
    public let id: String
    public let center: CGPoint
    /// The strand, or nil for the main thread.
    public let strand: Int?
  }

  public struct Label: Equatable, Identifiable, Sendable {
    /// The knot's ID.
    public let id: String
    public let frame: CGRect
    public let side: Side
    /// 今天 / 明天 / 9/26 for a planned knot, else empty.
    public let dayWord: String
    public let text: String
    public let tiles: [MemoryLoom.KnotKind]
    public let people: [MemoryPersonRef]
    /// One tier further out than usual: a thin line leads to its knot.
    public let leader: Bool
  }

  /// A thread's name beside it ("… · 主线", "… · 已了结").
  public struct Name: Equatable, Sendable {
    public let strand: Int?
    public let text: String
    public let frame: CGRect
  }

  /// The items of one line on one day.
  public struct Tick: Equatable, Sendable {
    public let strand: Int?
    public let center: CGPoint
    public let radius: CGFloat
    public let count: Int
  }

  public struct AxisLabel: Equatable, Sendable {
    public let x: CGFloat
    public let text: String
  }

  /// Another matter this one touches, as a row under the map.
  public struct TouchInput: Equatable, Sendable {
    public let id: String
    /// 在等 / 被它等 / 交叉 3 次.
    public let label: String
    public let title: String
    /// The axis day where they touch (a shared item, or the statement).
    public let day: Int
    public let waits: Bool

    public init(id: String, label: String, title: String, day: Int, waits: Bool = false) {
      self.id = id
      self.label = label
      self.title = title
      self.day = day
      self.waits = waits
    }
  }

  public struct TouchRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let title: String
    public let y: CGFloat
    public let touchX: CGFloat
    public let chip: CGRect
    public let waits: Bool
  }

  public let width: CGFloat
  public let height: CGFloat
  public let dayWidth: CGFloat
  /// Where day 0's half-day starts (after room for early branches).
  public let plotLeft: CGFloat
  public let yMain: CGFloat
  public let xNow: CGFloat
  /// The bottom of the plotted lines (the "now" line and the future zone).
  public let lineBottom: CGFloat
  public let axis: [AxisLabel]
  public let mainStartX: CGFloat
  public let mainFutureX: CGFloat?
  public let strands: [StrandPath]
  public let ticks: [Tick]
  public let knots: [KnotSpot]
  public let labels: [Label]
  public let names: [Name]
  public let touches: [TouchRow]

  public static let left: CGFloat = 22
  public static let right: CGFloat = 30
  public static let axisTop: CGFloat = 30
  /// Space between two strand lines.
  public static let spacing: CGFloat = 88
  /// Strands alternate above and below the main thread, nearest first.
  public static let slots: [Int] = [-1, 1, -2, 2, -3, 3, -4, 4]
  public static let labelFont: CGFloat = 12
  public static let nameFont: CGFloat = 12.5
  public static let tile: CGFloat = 14
  public static let touchRowHeight: CGFloat = 34
  /// Longest label before it is cut, and the shorter try when it does not fit.
  static let labelWidths: [CGFloat] = [156, 96]
  /// How much further out the second tier of labels is.
  static let tierStep: CGFloat = 34
  /// Knots of one line on one day stand this far apart (glyphs are 15 wide).
  public static let sameDayStep: CGFloat = 16

  public init(
    model: MemoryStrandModel, width: CGFloat, calendar: Calendar,
    touches: [TouchInput] = []
  ) {
    let width = max(width, 320)
    self.width = width
    let slots = model.strands.indices.map { Self.slots[$0 % Self.slots.count] }
    // Room on the left for a strand that splits off near the axis's start:
    // its branch curve never leaves the map.
    let days = CGFloat(max(model.totalDays, 1))
    let baseDay = (width - Self.left - Self.right) / days
    let room =
      model.strands.indices.map { index in
        Self.run(slot: slots[index], dayWidth: baseDay)
          - (CGFloat(model.strands[index].firstDay) + 0.5) * baseDay
      }.max() ?? 0
    let left = Self.left + max(0, room + 4)
    plotLeft = left
    let dayWidth = (width - left - Self.right) / days
    self.dayWidth = dayWidth
    func x(_ day: Int) -> CGFloat { left + (CGFloat(day) + 0.5) * dayWidth }

    let up = CGFloat(max(0, slots.map { -$0 }.max() ?? 0))
    let down = CGFloat(max(0, slots.max() ?? 0))
    let yMain = Self.axisTop + 76 + up * Self.spacing
    self.yMain = yMain
    func lineY(_ strand: Int?) -> CGFloat {
      guard let strand else { return yMain }
      return yMain + CGFloat(slots[strand]) * Self.spacing
    }
    let lineBottom = yMain + down * Self.spacing + 80
    self.lineBottom = lineBottom
    let xNow = x(model.today)
    self.xNow = xNow

    // Axis: a label a week (every other week when days are narrow), none
    // next to "now".
    let step = dayWidth * 7 >= 38 ? 7 : 14
    var axis: [AxisLabel] = []
    for day in 0..<model.totalDays {
      let date = model.date(ofDay: day, calendar: calendar)
      guard calendar.component(.weekday, from: date) == 2,
        (day / 7) % (step / 7) == 0 || step == 7,
        abs(day - model.today) > 2
      else { continue }
      let parts = calendar.dateComponents([.month, .day], from: date)
      axis.append(AxisLabel(x: x(day), text: "\(parts.month ?? 0)/\(parts.day ?? 0)"))
    }
    self.axis = axis

    // Occupied stretches per line and side, so labels never touch.
    var taken: [String: [(CGFloat, CGFloat)]] = [:]
    func key(_ strand: Int?, _ side: Side) -> String {
      "\(strand.map(String.init) ?? "m")\(side == .above ? "u" : "d")"
    }
    func place(_ strand: Int?, _ side: Side, _ x0: CGFloat, _ x1: CGFloat) -> Bool {
      let list = taken[key(strand, side), default: []]
      if list.contains(where: { x0 < $0.1 + 6 && x1 > $0.0 - 6 }) { return false }
      taken[key(strand, side), default: []].append((x0, x1))
      return true
    }

    // Strands.
    var paths: [StrandPath] = []
    var names: [Name] = []
    var earliest = x(model.mainItemDays.keys.min() ?? model.today)
    for (index, strand) in model.strands.enumerated() {
      let y = lineY(index)
      let run = Self.run(slot: slots[index], dayWidth: dayWidth)
      let a = x(strand.firstDay)
      let b = max(x(min(strand.lastDay, model.today)), a + 4)
      let branch = a - run
      earliest = min(earliest, branch)
      let open = !strand.closed
      let rejoin: CGFloat? = open ? nil : max(min(b + run, xNow), b)
      let future = strand.knots.map(\.day).filter { $0 > model.today }.max().map(x)
      paths.append(
        StrandPath(
          index: index, y: y, branchX: branch, startX: a, endX: open ? max(b, xNow) : b,
          rejoinX: rejoin, futureX: open ? future : nil))
      let text = strand.name + (strand.closed ? " · 已了结" : "")
      let side: Side = slots[index] < 0 ? .above : .below
      let nx = max(a - 4, 6)
      let w = Self.textWidth(text, size: Self.nameFont)
      _ = place(index, side, nx, nx + w)
      names.append(
        Name(
          strand: index, text: text,
          frame: CGRect(x: nx, y: side == .above ? y - 42 : y + 24, width: w, height: 18)))
    }
    paths.sort { $0.index < $1.index }
    strands = paths
    let mainStart = max(earliest - 4, 4)
    mainStartX = mainStart
    let mainFuture = model.mainKnots.map(\.day).filter { $0 > model.today }.max()
    mainFutureX = mainFuture.map(x)
    do {
      let text = Self.fit(model.title, width: 190, size: Self.nameFont) + " · 主线"
      let w = Self.textWidth(text, size: Self.nameFont)
      // Under the main thread, clear of the curves of strands splitting off
      // below it.
      var nx = max(x(model.mainItemDays.keys.min() ?? model.today) + 10, mainStart + 4)
      for _ in 0..<3 {
        for path in paths where slots[path.index] > 0 {
          if path.branchX < nx + w, path.startX > nx - 4 { nx = max(nx, path.startX + 6) }
        }
      }
      _ = place(nil, .below, nx, nx + w)
      names.insert(
        Name(strand: nil, text: text, frame: CGRect(x: nx, y: yMain + 24, width: w, height: 18)),
        at: 0)
    }
    self.names = names

    // Item dots.
    var ticks: [Tick] = []
    func addTicks(_ days: [Int: Int], _ strand: Int?) {
      for day in days.keys.sorted() {
        let count = days[day] ?? 0
        ticks.append(
          Tick(
            strand: strand, center: CGPoint(x: x(day), y: lineY(strand)),
            radius: 2 + CGFloat(Double(count).squareRoot()) * 1.3, count: count))
      }
    }
    addTicks(model.mainItemDays, nil)
    for (index, strand) in model.strands.enumerated() { addTicks(strand.itemDays, index) }
    self.ticks = ticks

    // Knots, a little apart when several share a line and day.
    var spots: [KnotSpot] = []
    let lines: [(Int?, [MemoryStrandModel.Knot])] =
      [(nil, model.mainKnots)] + model.strands.enumerated().map { ($0.offset, $0.element.knots) }
    for (strand, knots) in lines {
      var seen: [Int: Int] = [:]
      for knot in knots {
        let offset = seen[knot.day, default: 0]
        seen[knot.day] = offset + 1
        spots.append(
          KnotSpot(
            id: knot.id,
            center: CGPoint(x: x(knot.day) + CGFloat(offset) * Self.sameDayStep, y: lineY(strand)),
            strand: strand))
      }
    }
    knots = spots

    // Labels: what matters most first (plans, decisions, questions, then the
    // latest), each where it touches nothing: its line's preferred side, the
    // other side, centred on its knot or starting or ending there, cut
    // shorter, and last one tier further out (with a leader to its knot).
    var obstacles = names.map(\.frame)
    let mainEnd = max(xNow, mainFutureX ?? xNow)
    obstacles.append(CGRect(x: mainStart, y: yMain - 5, width: mainEnd - mainStart, height: 10))
    for path in paths {
      let end = max(path.endX, path.futureX ?? path.endX, path.rejoinX ?? path.endX)
      obstacles.append(
        CGRect(x: path.startX, y: path.y - 5, width: max(end - path.startX, 1), height: 10))
    }
    obstacles += spots.map { CGRect(x: $0.center.x - 8, y: $0.center.y - 8, width: 16, height: 16) }
    let byID = Dictionary(
      model.allKnots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    func rank(_ knot: MemoryStrandModel.Knot) -> Int {
      switch knot.glyph {
      case .planned: 0
      case .decision, .question: 1
      default: 2
      }
    }
    let order = spots.compactMap { spot in byID[spot.id].map { (spot, $0) } }.sorted {
      (rank($0.1), -$0.1.day, $0.1.id) < (rank($1.1), -$1.1.day, $1.1.id)
    }
    let top = Self.axisTop
    let bottom = lineBottom
    var labels: [Label] = []
    for (spot, knot) in order {
      let y = spot.center.y
      let kx = spot.center.x
      let preferred: [Side] =
        spot.strand.map { slots[$0] < 0 ? [.above, .below] : [.below, .above] } ?? [.below, .above]
      let word =
        knot.glyph == .planned && !knot.dateIsInferred
        ? Self.dayWord(knot, model, calendar, text: knot.text) : ""
      let tiles = Array(knot.evidence.prefix(4).map(\.source))
      let people = Array(knot.who.prefix(2))
      let rowWidth =
        CGFloat(tiles.count) * (Self.tile + 3) + CGFloat(people.count) * 15
        + (people.isEmpty ? 0 : 4)
      let full = word.isEmpty ? knot.text : word + " " + knot.text
      var placed: Label?
      search: for tier in 0..<2 {
        for side in preferred {
          for limit in Self.labelWidths {
            let fitted = Self.fit(full, width: limit, size: Self.labelFont)
            let w = max(Self.textWidth(fitted, size: Self.labelFont), rowWidth)
            let lift = CGFloat(tier) * Self.tierStep
            let y0 = side == .above ? y - 42 - lift : y + 9 + lift
            for x0 in [kx - w / 2, kx - 8, kx - w + 8] {
              let clamped = min(max(4, x0), width - 4 - w)
              let rect = CGRect(x: clamped, y: y0, width: w, height: 33)
              guard rect.minY >= top, rect.maxY <= bottom,
                !obstacles.contains(where: { $0.insetBy(dx: -4, dy: 0).intersects(rect) })
              else { continue }
              let text =
                word.isEmpty ? fitted : String(fitted.dropFirst(min(word.count + 1, fitted.count)))
              placed = Label(
                id: knot.id, frame: rect, side: side, dayWord: word, text: text, tiles: tiles,
                people: people, leader: tier > 0)
              break search
            }
          }
        }
      }
      guard let placed else { continue }
      obstacles.append(placed.frame)
      labels.append(placed)
    }
    // Drawn in the knots' order.
    let position = Dictionary(
      spots.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    self.labels = labels.sorted { (position[$0.id] ?? 0) < (position[$1.id] ?? 0) }

    // The matters it touches, a row each under the lines.
    var rows: [TouchRow] = []
    for (index, touch) in touches.enumerated() {
      let y = lineBottom + 22 + CGFloat(index) * Self.touchRowHeight
      let tx = x(min(max(touch.day, 0), model.totalDays - 1))
      let words = touch.label + " · " + touch.title
      let w = Self.textWidth(words, size: Self.labelFont) + 22
      var cx = tx + 10
      if cx + w > width - 6 { cx = max(6, tx - w - 10) }
      rows.append(
        TouchRow(
          id: touch.id, label: touch.label, title: touch.title, y: y, touchX: tx,
          chip: CGRect(x: cx, y: y - 11, width: w, height: 22), waits: touch.waits))
    }
    self.touches = rows
    height =
      lineBottom + (rows.isEmpty ? 8 : 22 + CGFloat(rows.count) * Self.touchRowHeight)
  }

  /// 今天 / 明天 / 后天, else "9/26".
  /// A date the text already says is not said again ("9/19 9/19跑…").
  static func dayWord(
    _ knot: MemoryStrandModel.Knot, _ model: MemoryStrandModel, _ calendar: Calendar,
    text: String = ""
  ) -> String {
    switch knot.day - model.today {
    case 0: return "今天"
    case 1: return "明天"
    case 2: return "后天"
    default:
      let date = knot.date ?? model.date(ofDay: knot.day, calendar: calendar)
      let parts = calendar.dateComponents([.year, .month, .day], from: date)
      if MemoryStatusFact.text(text, mentions: parts) { return "" }
      return "\(parts.month ?? 0)/\(parts.day ?? 0)"
    }
  }

  /// Estimated width: CJK one em, Latin and digits a bit over half.
  public static func textWidth(_ text: String, size: CGFloat) -> CGFloat {
    text.reduce(0) { width, c in
      let wide = c.unicodeScalars.first.map { $0.value >= 0x2E80 } ?? true
      return width + (wide ? size : size * 0.6)
    }
  }

  /// The text when it fits `width`, else its start and "…".
  public static func fit(_ text: String, width: CGFloat, size: CGFloat) -> String {
    guard textWidth(text, size: size) > width else { return text }
    var result = ""
    for c in text {
      let next = result + String(c)
      if textWidth(next, size: size) + size > width { break }
      result = next
    }
    return result + "…"
  }

  /// The x of an axis day.
  public func x(_ day: Int) -> CGFloat { plotLeft + (CGFloat(day) + 0.5) * dayWidth }

  /// How far before its first day a strand leaves the main thread.
  static func run(slot: Int, dayWidth: CGFloat) -> CGFloat {
    max(26 + CGFloat(abs(slot)) * spacing * 0.28, dayWidth * 0.8)
  }

  /// The knot under a point (within 11 pt), nearest first.
  public func knot(at point: CGPoint) -> String? {
    knots.map { ($0.id, hypot($0.center.x - point.x, $0.center.y - point.y)) }
      .filter { $0.1 <= 11 }.min { $0.1 < $1.1 }?.0
  }
}
