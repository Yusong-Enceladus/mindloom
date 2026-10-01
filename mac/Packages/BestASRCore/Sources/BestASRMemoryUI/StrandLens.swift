import BestASRDomain
import BestASRMemory
import SwiftUI

/// Colours of the threads of one matter: the main thread takes the matter's
/// lane colour on Home (so the zoom from Home keeps it), each strand the
/// next colour that is not the main thread's.
struct MatterColors {
  let main: Int

  init(eventID: String, state: MemoryScreenState) {
    main = Self.index(of: eventID, state: state)
  }

  func strand(_ index: Int) -> Int {
    var colors: [Int] = []
    var candidate = (main + 1) % 6
    while colors.count <= index {
      if candidate != main { colors.append(candidate) }
      candidate = (candidate + 1) % 6
    }
    return colors[index]
  }

  func color(_ strand: Int?, _ palette: ZhijiPalette) -> Color {
    palette.thread(strand.map(self.strand) ?? main)
  }

  /// A matter's colour: its Home lane's, else a stable one from its ID.
  static func index(of eventID: String, state: MemoryScreenState) -> Int {
    if let lane = state.looms[.twoWeeks]?.lanes.firstIndex(where: { $0.eventID == eventID }) {
      return lane
    }
    var hash: UInt32 = 2_166_136_261
    for byte in eventID.utf8 {
      hash ^= UInt32(byte)
      hash = hash &* 16_777_619
    }
    return Int(hash % 6)
  }
}

/// 线索 / 结构 / 网 / 文本, with what the chosen one shows.
struct MatterLensBar: View {
  @Environment(\.zhiji) private var palette
  @Binding var lens: MemoryEventLens

  var body: some View {
    HStack(spacing: 12) {
      ZhijiSegmented(
        options: [
          (MemoryEventLens.strands, ZhijiCopy.lensStrands), (.structure, ZhijiCopy.lensStructure),
          (.net, ZhijiCopy.lensNet), (.text, ZhijiCopy.lensText),
        ],
        selection: $lens, height: 26, fontSize: 13, horizontalPadding: 14
      )
      .accessibilityIdentifier("bestASR.memory.eventLens")
      Text(caption)
        .font(.zhiji(12))
        .foregroundStyle(palette.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
  }

  private var caption: String {
    switch lens {
    case .strands: ZhijiCopy.lensStrandsCaption
    case .structure: ZhijiCopy.lensStructureCaption
    case .net: ZhijiCopy.lensNetCaption
    case .text: ZhijiCopy.lensTextCaption
    }
  }
}

// MARK: - 线索

/// The 线索 lens: the status bar, the map with the evidence panel on its
/// right, the legend and one card per strand.
struct StrandLens: View {
  @Environment(\.zhiji) private var palette
  let eventID: String
  let detail: MemoryEventDetail
  let state: MemoryScreenState
  let actions: MemoryActions
  let morph: Namespace.ID
  @Binding var focused: String?
  let openRow: (String) -> Void
  let open: (MemoryRoute) -> Void
  @State private var hovered: String?

  static let panelWidth: CGFloat = 288

  var body: some View {
    if let projection = state.projection,
      let model = MemoryStrandModel(
        projection: projection, eventID: eventID, now: state.libraryNow,
        calendar: state.calendar)
    {
      let status = MemoryMatterStatus(
        model: model, statusLine: detail.statusIsFallback ? "" : detail.statusLine,
        facts: detail.statusFacts, projection: projection, calendar: state.calendar)
      let colors = MatterColors(eventID: eventID, state: state)
      VStack(alignment: .leading, spacing: 14) {
        MatterStatusBar(status: status, state: state, actions: actions, focus: focus, open: open)
        if !model.hasMap || model.stale {
          DraftingNote(stale: model.stale)
        }
        HStack(alignment: .top, spacing: 16) {
          GeometryReader { geometry in
            let layout = MemoryStrandLayout(
              model: model, width: geometry.size.width, calendar: state.calendar,
              touches: touches(model: model, projection: projection))
            StrandMapView(
              model: model, layout: layout, colors: colors, state: state, actions: actions,
              focused: $focused, hovered: $hovered, open: open)
          }
          .frame(height: mapHeight(model: model, projection: projection))
          .zhijiMorph("thread-\(eventID)", in: morph, isSource: false)
          EvidencePanel(
            model: model, status: status, state: state, colors: colors, focused: $focused,
            openRow: openRow
          )
          .frame(width: Self.panelWidth)
        }
        MapLegend()
        if !model.strands.isEmpty {
          StrandCards(model: model, colors: colors)
        }
      }
      .onAppear {
        if !model.hasMap { actions.requestMap(eventID) }
      }
    }
  }

  private func focus(_ knotID: String) { focused = knotID }

  /// The map's height does not depend on its width.
  private func mapHeight(model: MemoryStrandModel, projection: MemoryProjection) -> CGFloat {
    MemoryStrandLayout(
      model: model, width: 800, calendar: state.calendar,
      touches: touches(model: model, projection: projection)
    ).height
  }

  /// The matters it waits on or that wait on it, then the strongest
  /// crossings: at most four rows under the map.
  private func touches(model: MemoryStrandModel, projection: MemoryProjection)
    -> [MemoryStrandLayout.TouchInput]
  {
    let titles = Dictionary(
      projection.events.map { ($0.eventID, $0.title) }, uniquingKeysWith: { a, _ in a })
    var rows: [MemoryStrandLayout.TouchInput] = []
    for relation in projection.relations where relation.isBlocks {
      guard relation.a == eventID || relation.b == eventID else { continue }
      let other = relation.a == eventID ? relation.b : relation.a
      guard let title = titles[other] else { continue }
      let day =
        relation.itemID.flatMap { projection.records[$0.uppercased()]?.startedAt }
        .map { model.day(of: $0, calendar: state.calendar) } ?? model.today
      rows.append(
        .init(
          id: "blocks|\(relation.a)|\(relation.b)",
          label: relation.b == eventID ? ZhijiCopy.waitsOn : ZhijiCopy.waitedBy, title: title,
          day: day, waits: true))
    }
    let crossings = projection.relations.filter {
      $0.isCross && ($0.a == eventID || $0.b == eventID)
    }.sorted { ($0.count ?? 0, $1.a + $1.b) > ($1.count ?? 0, $0.a + $0.b) }
    let waiting = Set(rows.map { StrandMapView.pair($0.id) }.flatMap { [$0.0, $0.1] })
    for relation in crossings where rows.count < 4 {
      let other = relation.a == eventID ? relation.b : relation.a
      // A matter it waits on is shown once, as waiting.
      guard let title = titles[other], !waiting.contains(other) else { continue }
      let days = relation.itemIDs.compactMap { projection.records[$0.uppercased()]?.startedAt }
      let day = days.max().map { model.day(of: $0, calendar: state.calendar) } ?? model.today
      rows.append(
        .init(
          id: "cross|\(relation.a)|\(relation.b)", label: ZhijiCopy.crossed(relation.count ?? 0),
          title: title, day: min(day, model.today)))
    }
    return Array(rows.prefix(4))
  }
}

/// 正在整理线索…: the matter has no map yet (its facts are on one thread),
/// or a delete pruned the map and it is being drawn again.
struct DraftingNote: View {
  @Environment(\.zhiji) private var palette
  let stale: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "hourglass").font(.system(size: 12, weight: .medium))
        .foregroundStyle(palette.secondary)
        .accessibilityHidden(true)
      Text(stale ? ZhijiCopy.redrawing : ZhijiCopy.drafting)
        .font(.zhiji(12, .semibold))
        .foregroundStyle(palette.label)
      if !stale {
        Text(ZhijiCopy.draftingDetail).font(.zhiji(12)).foregroundStyle(palette.secondary)
      }
    }
    .padding(.horizontal, 12)
    .frame(height: 30)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("bestASR.memory.drafting")
  }
}

/// On top of the map: how it is going, the nearest flag and its countdown,
/// open promises and questions, and what it waits on.
struct MatterStatusBar: View {
  @Environment(\.zhiji) private var palette
  @Environment(\.zhijiSnapshot) private var snapshot
  let status: MemoryMatterStatus
  let state: MemoryScreenState
  let actions: MemoryActions
  let focus: (String) -> Void
  let open: (MemoryRoute) -> Void

  var body: some View {
    let tones = HomeTones(palette)
    FlowLayout(spacing: 8, lineSpacing: 8) {
      if let health = status.health {
        pill(tones.tint(health.level), dot: true) {
          Text(Self.word(health.level)).font(.zhiji(12, .semibold))
          if !health.reason.isEmpty {
            Text(health.reason).font(.zhiji(12)).lineLimit(1)
          }
        }
        .help(health.reason)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bestASR.memory.health")
      }
      if let flag = status.flag {
        Button {
          if let knot = flag.knotID { focus(knot) }
        } label: {
          pill(tones.tint(countdown: flag.daysAway), symbol: "flag.fill") {
            Text(Self.countdown(flag.daysAway)).font(.zhiji(12, .semibold))
            Text(flag.text).font(.zhiji(12)).lineLimit(1)
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          "\(ZhijiCopy.nextStep)，\(Self.countdown(flag.daysAway))，\(flag.text)"
        )
        .accessibilityIdentifier("bestASR.memory.flag")
      }
      if !status.commitments.isEmpty {
        Button {
          focus(status.commitments[0].knotID)
        } label: {
          pill(tones.blue, symbol: "hand.raised") {
            Text(ZhijiCopy.promises(status.commitments.count)).font(.zhiji(12, .semibold))
            Text(commitmentLine(status.commitments[0])).font(.zhiji(12)).lineLimit(1)
          }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bestASR.memory.promises")
      }
      if !status.questions.isEmpty {
        Button {
          focus(status.questions[0].id)
        } label: {
          pill(tones.amber, symbol: "questionmark") {
            Text(ZhijiCopy.openQuestions(status.questions.count)).font(.zhiji(12, .semibold))
            Text(status.questions[0].text).font(.zhiji(12)).lineLimit(1)
          }
        }
        .buttonStyle(.plain)
      }
      ForEach(Array((status.waitsOn + status.waitedBy).enumerated()), id: \.offset) { _, link in
        let waits = link.b != link.eventID
        waitPill(link, word: waits ? ZhijiCopy.waitsOn : ZhijiCopy.waitedBy, tones: tones)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bestASR.memory.statusBar")
  }

  @ViewBuilder
  private func waitPill(_ link: MemoryMatterStatus.Link, word: String, tones: HomeTones)
    -> some View
  {
    Button {
      open(.event(link.eventID))
    } label: {
      pill(tones.gray, symbol: "arrow.right") {
        Text(word).font(.zhiji(12, .semibold))
        Text(link.title).font(.zhiji(12)).lineLimit(1)
      }
    }
    .buttonStyle(.plain)
    .help(link.quote.map { "「\($0)」" } ?? "")
    .contextMenu {
      Button(ZhijiCopy.notWaiting) { actions.relation(.rejectBlocks(a: link.a, b: link.b)) }
    }
    .accessibilityLabel("\(word)，\(link.title)")
    .accessibilityAction(named: ZhijiCopy.notWaiting) {
      actions.relation(.rejectBlocks(a: link.a, b: link.b))
    }
  }

  private func commitmentLine(_ commitment: MemoryMatterStatus.Commitment) -> String {
    let who = commitment.who.map(\.name).prefix(2).joined(separator: "、")
    return who.isEmpty ? commitment.text : "\(who)：\(commitment.text)"
  }

  private func pill<Content: View>(
    _ tint: HomeTones.Tint, dot: Bool = false, symbol: String? = nil,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: 6) {
      if dot { Circle().fill(tint.mark).frame(width: 7, height: 7) }
      if let symbol {
        Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
          .accessibilityHidden(true)
      }
      content()
    }
    .foregroundStyle(tint.ink)
    .padding(.horizontal, 10)
    .frame(height: 26)
    .frame(maxWidth: 360, alignment: .leading)
    .fixedSize(horizontal: true, vertical: false)
    .background(tint.fill, in: Capsule())
    .contentShape(Capsule())
  }

  static func word(_ level: MemoryStrandModel.Health.Level) -> String {
    switch level {
    case .ok: ZhijiCopy.healthOK
    case .risk: ZhijiCopy.healthRisk
    case .stuck: ZhijiCopy.healthStuck
    }
  }

  static func countdown(_ days: Int) -> String {
    switch days {
    case 0: ZhijiCopy.dueTodayWord
    case 1: ZhijiCopy.dueTomorrowWord
    case let n where n > 1: ZhijiCopy.dueIn(n)
    default: ZhijiCopy.overdue(-days)
    }
  }
}

extension HomeTones {
  func tint(_ level: MemoryStrandModel.Health.Level) -> Tint {
    switch level {
    case .ok: green
    case .risk: amber
    case .stuck: red
    }
  }

  /// A flag's tint by how soon it is: today or tomorrow red, soon or just
  /// passed (not marked done) amber, later gray.
  func tint(countdown days: Int) -> Tint {
    if days < 0 { return amber }
    return days <= 1 ? red : (days <= MemoryLoom.soonDays ? amber : gray)
  }
}

// MARK: - The map

/// The strand map: the axis, threads, dots and knots drawn in one Canvas;
/// the knots' labels, the thread names and the touching matters as views on
/// top, so they read as text, take focus, and speak.
struct StrandMapView: View {
  @Environment(\.zhiji) private var palette
  let model: MemoryStrandModel
  let layout: MemoryStrandLayout
  let colors: MatterColors
  let state: MemoryScreenState
  let actions: MemoryActions
  @Binding var focused: String?
  @Binding var hovered: String?
  let open: (MemoryRoute) -> Void

  var body: some View {
    let tones = HomeTones(palette)
    ZStack(alignment: .topLeading) {
      StrandCanvas(
        model: model, layout: layout, colors: colors, tones: tones, focused: focused,
        hovered: hovered, calendar: state.calendar
      )
      .frame(width: layout.width, height: layout.height)
      .accessibilityHidden(true)
      ForEach(Array(layout.names.enumerated()), id: \.offset) { _, name in
        Text(name.text)
          .font(.zhiji(MemoryStrandLayout.nameFont, .semibold))
          .foregroundStyle(colors.color(name.strand, palette))
          .lineLimit(1)
          .fixedSize()
          .offset(x: name.frame.minX, y: name.frame.minY)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      ForEach(layout.labels) { label in
        KnotLabel(label: label, color: .clear, tones: tones)
          .frame(
            width: label.frame.width, height: label.frame.height,
            alignment: label.side == .above ? .bottomLeading : .topLeading
          )
          .offset(x: label.frame.minX, y: label.frame.minY)
          .onTapGesture { focused = label.id }
          .accessibilityHidden(true)
      }
      ForEach(layout.knots) { spot in
        if let knot = model.knot(spot.id) {
          Button {
            focused = focused == knot.id ? nil : knot.id
          } label: {
            Color.clear.frame(width: 24, height: 24).contentShape(Circle())
          }
          .buttonStyle(.plain)
          .offset(x: spot.center.x - 12, y: spot.center.y - 12)
          .onHover { inside in
            if inside { hovered = knot.id } else if hovered == knot.id { hovered = nil }
          }
          .accessibilityLabel(Self.spoken(knot, model: model, state: state))
          .accessibilityAddTraits(focused == knot.id ? [.isSelected] : [])
          .accessibilityHint(ZhijiCopy.pickAKnot)
          .accessibilityIdentifier("bestASR.memory.knot")
        }
      }
      ForEach(layout.touches) { row in
        touchChip(row, tones: tones)
      }
      if let id = hovered, id != focused, let knot = model.knot(id),
        let spot = layout.knots.first(where: { $0.id == id })
      {
        KnotTip(knot: knot, state: state)
          .offset(
            x: min(max(spot.center.x - 150, 4), max(layout.width - 304, 4)),
            y: spot.center.y + (spot.center.y > layout.height / 2 ? -150 : 18)
          )
          .allowsHitTesting(false)
      }
    }
    .frame(width: layout.width, height: layout.height, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.title)
    .accessibilityIdentifier("bestASR.memory.strandMap")
  }

  private func touchChip(_ row: MemoryStrandLayout.TouchRow, tones: HomeTones) -> some View {
    let (a, b) = Self.pair(row.id)
    return Button {
      if let other = [a, b].first(where: { $0 != model.eventID }) { open(.event(other)) }
    } label: {
      HStack(spacing: 0) {
        Text(row.label).font(.zhiji(12, .semibold)).foregroundStyle(palette.secondary)
        Text(" · " + row.title).font(.zhiji(12)).foregroundStyle(palette.label).lineLimit(1)
      }
      .padding(.horizontal, 10)
      .frame(width: row.chip.width, height: row.chip.height, alignment: .leading)
      .background(palette.isDark ? palette.surface : .white, in: Capsule())
      .overlay(Capsule().strokeBorder(tones.chipBorder))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .offset(x: row.chip.minX, y: row.chip.minY)
    .help(row.waits ? "" : ZhijiCopy.crossedDetail(Self.count(row.label)))
    .contextMenu {
      if row.waits {
        Button(ZhijiCopy.notWaiting) { actions.relation(.rejectBlocks(a: a, b: b)) }
      } else {
        Button(ZhijiCopy.hideCrossing) { actions.relation(.hideCrossing(a: a, b: b)) }
      }
    }
    .accessibilityLabel("\(row.label)，\(row.title)")
    .accessibilityIdentifier("bestASR.memory.touch")
  }

  /// "kind|a|b" → (a, b).
  static func pair(_ id: String) -> (String, String) {
    let parts = id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    return parts.count == 3 ? (parts[1], parts[2]) : ("", "")
  }

  static func count(_ label: String) -> Int {
    Int(label.filter(\.isNumber)) ?? 0
  }

  /// "完成，Twin-7电机修好恢复实验，9月1日，孟凡、韩策，2 条素材作证".
  static func spoken(
    _ knot: MemoryStrandModel.Knot, model: MemoryStrandModel, state: MemoryScreenState
  )
    -> String
  {
    var parts = [ZhijiCopy.knotState(knot.glyph.rawValue), knot.text]
    if let date = knot.date { parts.append(LoomPanel.monthDay(date, state.calendar)) }
    let names = knot.who.map(\.name)
    if !names.isEmpty { parts.append(names.joined(separator: "、")) }
    if let strand = knot.strand, model.strands.indices.contains(strand) {
      parts.append(model.strands[strand].name)
    }
    let sources = Set(knot.evidence.map(\.source)).map(KnotSourceTile.word).sorted()
    if !sources.isEmpty { parts.append(sources.joined(separator: "、")) }
    parts.append(ZhijiCopy.evidenceCount(knot.evidence.count))
    return parts.joined(separator: "，")
  }
}

/// A knot's words and, next to its line, the source tiles of its evidence
/// and the people it names.
struct KnotLabel: View {
  @Environment(\.zhiji) private var palette
  let label: MemoryStrandLayout.Label
  let color: Color
  let tones: HomeTones

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      if label.side == .above {
        words
        tiles
      } else {
        tiles
        words
      }
    }
  }

  private var words: some View {
    (Text(label.dayWord.isEmpty ? "" : label.dayWord + " ").font(.zhiji(12, .bold))
      .foregroundColor(tones.red.ink)
      + Text(label.text).font(.zhiji(12)).foregroundColor(palette.label))
      .lineLimit(1)
      .fixedSize()
  }

  private var tiles: some View {
    HStack(spacing: 3) {
      ForEach(Array(label.tiles.enumerated()), id: \.offset) { _, kind in
        KnotSourceTile(kind: kind, size: MemoryStrandLayout.tile)
      }
      if !label.people.isEmpty {
        HStack(spacing: 1) {
          ForEach(label.people, id: \.personID) { person in
            Avatar(person, size: 14, ring: palette.bg)
          }
        }
        .padding(.leading, 4)
      }
    }
    .frame(height: MemoryStrandLayout.tile)
  }
}

/// A source's small tile on a knot: 会议, 聊天, 手机, 口述, 截图, 文件.
struct KnotSourceTile: View {
  @Environment(\.zhiji) private var palette
  let kind: MemoryLoom.KnotKind
  var size: CGFloat = 14

  var body: some View {
    let ink = palette.sourceInk(Self.ink(kind))
    Image(systemName: Self.symbol(kind))
      .font(.system(size: size * 0.62, weight: .semibold))
      .foregroundStyle(ink)
      .frame(width: size, height: size)
      .background(ink.opacity(palette.isDark ? 0.22 : 0.14), in: RoundedRectangle(cornerRadius: 4))
      .accessibilityLabel(Self.word(kind))
  }

  static func symbol(_ kind: MemoryLoom.KnotKind) -> String {
    switch kind {
    case .meeting: "person.2.fill"
    case .chat: "bubble.left.fill"
    case .phone: "iphone"
    case .dictation: "mic.fill"
    case .image: "photo"
    case .file: "doc.fill"
    }
  }

  static func ink(_ kind: MemoryLoom.KnotKind) -> Color {
    switch kind {
    case .meeting: .hex(0xB5452F)
    case .chat: .hex(0x4F8A5B)
    case .phone: .hex(0x3F6FB5)
    case .dictation: .hex(0x3F6FB5)
    case .image: .hex(0x8E4A8C)
    case .file: .hex(0x6E6E73)
    }
  }

  static func word(_ kind: MemoryLoom.KnotKind) -> String {
    switch kind {
    case .meeting: "会议"
    case .chat: "聊天"
    case .phone: "手机"
    case .dictation: "口述"
    case .image: "截图"
    case .file: "文件"
    }
  }
}

/// The hover card of a knot: what it is, its words and the quote.
struct KnotTip: View {
  @Environment(\.zhiji) private var palette
  let knot: MemoryStrandModel.Knot
  let state: MemoryScreenState

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(KnotHeader.line(knot, state: state))
        .font(.zhiji(11, .semibold))
        .foregroundStyle(palette.secondary)
      Text(knot.text)
        .font(.zhiji(13, .semibold))
        .foregroundStyle(palette.label)
        .fixedSize(horizontal: false, vertical: true)
      if !knot.quote.isEmpty {
        Text("「\(knot.quote)」")
          .font(.zhiji(12))
          .foregroundStyle(palette.label)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(ZhijiCopy.evidenceCount(knot.evidence.count))
        .font(.zhiji(11))
        .foregroundStyle(palette.accent)
    }
    .padding(12)
    .frame(width: 300, alignment: .leading)
    .background(palette.isDark ? palette.surface : .white, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.separator))
    .shadow(color: .black.opacity(palette.isDark ? 0.4 : 0.10), radius: 8, y: 3)
  }
}

/// "完成 · 9月16日" / "计划、截止 · 9月19日" (the day from the evidence noted).
@MainActor
enum KnotHeader {
  static func line(_ knot: MemoryStrandModel.Knot, state: MemoryScreenState) -> String {
    var parts = [ZhijiCopy.knotKind(knot.kind), ZhijiCopy.knotState(knot.glyph.rawValue)]
    if parts[0] == parts[1] { parts.removeLast() }
    if let date = knot.date, knot.glyph != .question {
      parts.append(LoomPanel.monthDay(date, state.calendar, weekday: true))
    }
    return parts.joined(separator: " · ")
  }
}

/// Everything the map draws that is not text.
struct StrandCanvas: View {
  @Environment(\.zhiji) private var palette
  let model: MemoryStrandModel
  let layout: MemoryStrandLayout
  let colors: MatterColors
  let tones: HomeTones
  let focused: String?
  let hovered: String?
  let calendar: Calendar

  var body: some View {
    Canvas { context, size in
      drawAxis(&context, size)
      drawThreads(&context)
      drawTouches(&context)
      drawTicks(&context)
      drawLeaders(&context)
      drawKnots(&context)
    }
  }

  /// A thin line from a knot to its label when the label sits a tier out.
  private func drawLeaders(_ context: inout GraphicsContext) {
    for label in layout.labels where label.leader {
      guard let spot = layout.knots.first(where: { $0.id == label.id }) else { continue }
      let edgeY = label.side == .above ? label.frame.maxY : label.frame.minY
      let edgeX = min(max(spot.center.x, label.frame.minX + 6), label.frame.maxX - 6)
      var line = Path()
      line.move(to: spot.center)
      line.addLine(to: CGPoint(x: edgeX, y: edgeY))
      context.stroke(
        line, with: .color(palette.secondary.opacity(0.5)),
        style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
    }
  }

  private func drawAxis(_ context: inout GraphicsContext, _ size: CGSize) {
    let top = MemoryStrandLayout.axisTop
    let bottom = layout.lineBottom
    let future = CGRect(
      x: layout.xNow, y: top, width: max(size.width - 8 - layout.xNow, 0), height: bottom - top)
    context.fill(
      Path(roundedRect: future, cornerRadius: 10, style: .continuous), with: .color(tones.future))
    var grid = Path()
    for label in layout.axis {
      grid.move(to: CGPoint(x: label.x, y: top))
      grid.addLine(to: CGPoint(x: label.x, y: bottom))
      context.draw(
        Text(label.text).font(.zhiji(12)).monospacedDigit().foregroundColor(palette.secondary),
        at: CGPoint(x: label.x, y: 16), anchor: .center)
    }
    context.stroke(grid, with: .color(tones.grid), lineWidth: 1)
    var now = Path()
    now.move(to: CGPoint(x: layout.xNow, y: top - 2))
    now.addLine(to: CGPoint(x: layout.xNow, y: bottom))
    context.stroke(now, with: .color(tones.ink), lineWidth: 1.4)
    let parts = calendar.dateComponents([.month, .day], from: model.now)
    let word = "\(ZhijiCopy.nowLabel) \(parts.month ?? 0)/\(parts.day ?? 0)"
    let width = MemoryStrandLayout.textWidth(word, size: 12) + 16
    let pillX = min(max(layout.xNow - width / 2, 0), size.width - width)
    context.fill(
      Path(roundedRect: CGRect(x: pillX, y: 6, width: width, height: 20), cornerRadius: 10),
      with: .color(tones.ink))
    context.draw(
      Text(word).font(.zhiji(12, .semibold)).monospacedDigit().foregroundColor(tones.onInk),
      at: CGPoint(x: pillX + width / 2, y: 16), anchor: .center)
  }

  private func drawThreads(_ context: inout GraphicsContext) {
    let yMain = layout.yMain
    let main = colors.color(nil, palette)
    var line = Path()
    line.move(to: CGPoint(x: layout.mainStartX, y: yMain))
    line.addLine(to: CGPoint(x: layout.xNow, y: yMain))
    context.stroke(line, with: .color(main), style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
    if let future = layout.mainFutureX, future > layout.xNow {
      dotted(&context, from: layout.xNow, to: future, y: yMain, color: main, width: 2.4)
    }
    for path in layout.strands {
      let color = colors.color(path.index, palette)
      let run = path.startX - path.branchX
      var p = Path()
      p.move(to: CGPoint(x: path.branchX, y: yMain))
      p.addCurve(
        to: CGPoint(x: path.startX, y: path.y),
        control1: CGPoint(x: path.branchX + run * 0.55, y: yMain),
        control2: CGPoint(x: path.startX - run * 0.45, y: path.y))
      p.addLine(to: CGPoint(x: path.endX, y: path.y))
      if let rejoin = path.rejoinX, rejoin > path.endX {
        let back = rejoin - path.endX
        p.addCurve(
          to: CGPoint(x: rejoin, y: yMain),
          control1: CGPoint(x: path.endX + back * 0.45, y: path.y),
          control2: CGPoint(x: rejoin - back * 0.55, y: yMain))
      }
      context.stroke(
        p, with: .color(color),
        style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
      if let future = path.futureX, future > layout.xNow {
        dotted(&context, from: layout.xNow, to: future, y: path.y, color: color, width: 2)
      }
    }
  }

  private func dotted(
    _ context: inout GraphicsContext, from: CGFloat, to: CGFloat, y: CGFloat, color: Color,
    width: CGFloat
  ) {
    var path = Path()
    path.move(to: CGPoint(x: from, y: y))
    path.addLine(to: CGPoint(x: to, y: y))
    context.stroke(
      path, with: .color(color),
      style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [2, 5.5]))
  }

  /// The matters it touches: a dotted drop from the main thread to the row.
  private func drawTouches(_ context: inout GraphicsContext) {
    for row in layout.touches {
      var drop = Path()
      drop.move(to: CGPoint(x: row.touchX, y: layout.yMain + 5))
      drop.addLine(to: CGPoint(x: row.touchX, y: row.y - 4))
      context.stroke(
        drop, with: .color(palette.secondary.opacity(0.45)),
        style: StrokeStyle(lineWidth: 1.2, dash: row.waits ? [] : [1.5, 4]))
      let ring = Path(
        ellipseIn: CGRect(x: row.touchX - 3.6, y: layout.yMain - 3.6, width: 7.2, height: 7.2))
      context.fill(ring, with: .color(tones.page))
      context.stroke(ring, with: .color(palette.secondary), lineWidth: 1.4)
      let dot = Path(ellipseIn: CGRect(x: row.touchX - 3, y: row.y - 3, width: 6, height: 6))
      context.fill(dot, with: .color(palette.secondary))
    }
  }

  private func drawTicks(_ context: inout GraphicsContext) {
    for tick in layout.ticks {
      let r = tick.radius
      context.fill(
        Path(
          ellipseIn: CGRect(x: tick.center.x - r, y: tick.center.y - r, width: r * 2, height: r * 2)
        ),
        with: .color(colors.color(tick.strand, palette).opacity(palette.isDark ? 0.45 : 0.32)))
    }
  }

  private func drawKnots(_ context: inout GraphicsContext) {
    for spot in layout.knots {
      guard let knot = model.knot(spot.id) else { continue }
      let color = colors.color(spot.strand, palette)
      let c = spot.center
      if spot.id == focused || spot.id == hovered {
        let halo = Path(ellipseIn: CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26))
        context.fill(halo, with: .color(palette.accent.opacity(spot.id == focused ? 0.22 : 0.12)))
        if spot.id == focused {
          context.stroke(halo, with: .color(palette.accent), lineWidth: 1.5)
        }
      }
      KnotGlyphPainter.draw(
        knot.glyph, at: c, color: color, tones: tones, palette: palette, context: &context,
        daysAway: knot.day - model.today)
    }
  }
}

/// ● ◐ ⚑ ◆ ? drawn at a point.
enum KnotGlyphPainter {
  static func draw(
    _ glyph: MemoryKnotGlyph, at c: CGPoint, color: Color, tones: HomeTones,
    palette: ZhijiPalette, context: inout GraphicsContext, daysAway: Int, scale: CGFloat = 1
  ) {
    let card = tones.page
    switch glyph {
    case .done:
      let r = 6.3 * scale
      let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
      context.fill(circle, with: .color(color))
      context.stroke(circle, with: .color(card), lineWidth: 2 * scale)
    case .doing:
      let r = 6 * scale
      let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
      context.fill(circle, with: .color(card))
      context.stroke(circle, with: .color(color), lineWidth: 2 * scale)
      var half = Path()
      half.move(to: CGPoint(x: c.x, y: c.y - r))
      half.addArc(
        center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
      half.closeSubpath()
      context.fill(half, with: .color(color))
    case .planned:
      let tint = tones.tint(countdown: daysAway)
      let r = 7.5 * scale
      context.fill(
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
        with: .color(card))
      var pole = Path()
      pole.move(to: CGPoint(x: c.x - 3 * scale, y: c.y + 7 * scale))
      pole.addLine(to: CGPoint(x: c.x - 3 * scale, y: c.y - 8 * scale))
      context.stroke(
        pole, with: .color(tint.mark), style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
      var cloth = Path()
      cloth.move(to: CGPoint(x: c.x - 3 * scale, y: c.y - 8 * scale))
      cloth.addLine(to: CGPoint(x: c.x + 8 * scale, y: c.y - 3.5 * scale))
      cloth.addLine(to: CGPoint(x: c.x - 3 * scale, y: c.y + 1 * scale))
      cloth.closeSubpath()
      context.fill(cloth, with: .color(tint.mark))
    case .decision:
      let r = 7.5 * scale
      var diamond = Path()
      diamond.move(to: CGPoint(x: c.x, y: c.y - r))
      diamond.addLine(to: CGPoint(x: c.x + r, y: c.y))
      diamond.addLine(to: CGPoint(x: c.x, y: c.y + r))
      diamond.addLine(to: CGPoint(x: c.x - r, y: c.y))
      diamond.closeSubpath()
      context.fill(diamond, with: .color(color))
      context.stroke(diamond, with: .color(card), lineWidth: 1.6 * scale)
    case .question:
      let r = 7.5 * scale
      let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
      context.fill(circle, with: .color(tones.amber.fill))
      context.stroke(circle, with: .color(tones.amber.mark), lineWidth: 1.6 * scale)
      context.draw(
        Text("?").font(.system(size: 11 * scale, weight: .bold)).foregroundColor(tones.amber.ink),
        at: c, anchor: .center)
    }
  }
}

/// One glyph as a small view (legend, panel, tree).
struct KnotGlyphView: View {
  @Environment(\.zhiji) private var palette
  let glyph: MemoryKnotGlyph
  var color: Color? = nil
  var daysAway = 9
  var size: CGFloat = 18

  var body: some View {
    let tones = HomeTones(palette)
    Canvas { context, canvasSize in
      KnotGlyphPainter.draw(
        glyph, at: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2),
        color: color ?? palette.secondary, tones: tones, palette: palette, context: &context,
        daysAway: daysAway, scale: size / 18)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// The glyphs' meanings and the source tiles.
struct MapLegend: View {
  @Environment(\.zhiji) private var palette

  var body: some View {
    HStack(spacing: 14) {
      item(.done, ZhijiCopy.legendDone)
      item(.doing, ZhijiCopy.legendDoing)
      item(.planned, ZhijiCopy.legendPlanned)
      item(.decision, ZhijiCopy.legendDecision)
      item(.question, ZhijiCopy.legendQuestion)
      HStack(spacing: 3) {
        ForEach(
          [MemoryLoom.KnotKind.meeting, .chat, .phone, .dictation, .image, .file], id: \.self
        ) { kind in
          KnotSourceTile(kind: kind, size: 14)
        }
        Text(ZhijiCopy.legendSources).font(.zhiji(12)).foregroundStyle(palette.secondary)
          .padding(.leading, 4)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  private func item(_ glyph: MemoryKnotGlyph, _ word: String) -> some View {
    HStack(spacing: 4) {
      KnotGlyphView(glyph: glyph, color: palette.accent, size: 16)
      Text(word).font(.zhiji(12)).foregroundStyle(palette.secondary)
    }
  }
}

/// A card per strand: its name, how many items, closed or not, its summary.
struct StrandCards: View {
  @Environment(\.zhiji) private var palette
  let model: MemoryStrandModel
  let colors: MatterColors

  var body: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)],
      alignment: .leading, spacing: 14
    ) {
      ForEach(Array(model.strands.enumerated()), id: \.offset) { index, strand in
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            Circle().fill(colors.color(index, palette)).frame(width: 9, height: 9)
            Text(strand.name).font(.zhiji(14, .semibold)).foregroundStyle(palette.label)
              .lineLimit(1)
            Text(
              "· " + ZhijiCopy.strandItems(strand.itemCount)
                + (strand.closed ? " · " + ZhijiCopy.closedStrand : "")
            )
            .font(.zhiji(12)).foregroundStyle(palette.secondary)
          }
          if !strand.summary.isEmpty {
            Text(strand.summary)
              .font(.zhiji(13))
              .foregroundStyle(palette.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(palette.separator)
        )
        .accessibilityElement(children: .combine)
      }
    }
  }
}

// MARK: - Evidence panel

/// On the map's right: "now" (where it stands, the next step, what is open,
/// what was decided) until a knot is picked; then that knot, its quote in
/// its item, and every item it rests on (a click opens the item).
struct EvidencePanel: View {
  @Environment(\.zhiji) private var palette
  let model: MemoryStrandModel
  let status: MemoryMatterStatus
  let state: MemoryScreenState
  let colors: MatterColors
  @Binding var focused: String?
  let openRow: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let id = focused, let knot = model.knot(id) {
        knotView(knot)
      } else {
        nowView
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      palette.isDark ? palette.surface : .white,
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.separator)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bestASR.memory.evidence")
  }

  // "现在"

  private var nowView: some View {
    let day = LoomPanel.monthDay(model.now, state.calendar, weekday: true)
    return VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        Text(ZhijiCopy.nowHeader(day)).font(.zhiji(12, .semibold))
          .foregroundStyle(palette.secondary)
        if !status.statusLine.isEmpty {
          Text(status.statusLine).font(.zhiji(16, .semibold)).foregroundStyle(palette.label)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let health = status.health, health.level != .ok, !health.reason.isEmpty {
          Text(health.reason).font(.zhiji(12)).foregroundStyle(palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if let flag = status.flag {
        section(ZhijiCopy.nextStep) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(MatterStatusBar.countdown(flag.daysAway))
              .font(.zhiji(11, .semibold))
              .foregroundStyle(HomeTones(palette).tint(countdown: flag.daysAway).ink)
              .padding(.horizontal, 7)
              .frame(height: 20)
              .background(HomeTones(palette).tint(countdown: flag.daysAway).fill, in: Capsule())
            Text(flag.text).font(.zhiji(13)).foregroundStyle(palette.label)
              .fixedSize(horizontal: false, vertical: true)
          }
          Text(LoomPanel.monthDay(flag.date, state.calendar, weekday: true))
            .metaStyle(palette)
        }
      }
      let questions = model.allKnots.filter { $0.glyph == .question }
      if !questions.isEmpty {
        section(ZhijiCopy.stillOpen) { knotList(questions) }
      }
      let decisions = model.allKnots.filter { $0.glyph == .decision }.suffix(3)
      if !decisions.isEmpty {
        section(ZhijiCopy.decided) { knotList(Array(decisions)) }
      }
      if !status.commitments.isEmpty {
        section(ZhijiCopy.promised) {
          knotList(status.commitments.compactMap { model.knot($0.knotID) })
        }
      }
      if !model.allKnots.isEmpty {
        Text(ZhijiCopy.pickAKnot).font(.zhiji(12)).foregroundStyle(palette.tertiary)
      }
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.zhiji(12, .semibold)).foregroundStyle(palette.secondary)
      content()
    }
  }

  private func knotList(_ knots: [MemoryStrandModel.Knot]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(knots) { knot in
        Button {
          focused = knot.id
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            KnotGlyphView(
              glyph: knot.glyph, color: colors.color(knot.strand, palette),
              daysAway: knot.day - model.today, size: 14
            )
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(knot.text).font(.zhiji(13)).foregroundStyle(palette.label)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
            if let date = knot.date, knot.glyph != .question {
              Text(Self.shortDay(date, state.calendar)).metaStyle(palette)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(StrandMapView.spoken(knot, model: model, state: state))
      }
    }
  }

  // A knot

  private func knotView(_ knot: MemoryStrandModel.Knot) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 6) {
        KnotGlyphView(
          glyph: knot.glyph, color: colors.color(knot.strand, palette),
          daysAway: knot.day - model.today, size: 16)
        Text(KnotHeader.line(knot, state: state)).font(.zhiji(12, .semibold))
          .foregroundStyle(palette.secondary)
        Spacer(minLength: 4)
        Button {
          focused = nil
        } label: {
          Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.secondary)
            .frame(width: 22, height: 22)
            .background(palette.quietFill, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ZhijiCopy.collapse)
      }
      Text(knot.text).font(.zhiji(16, .semibold)).foregroundStyle(palette.label)
        .fixedSize(horizontal: false, vertical: true)
      if knot.dateIsInferred, knot.glyph != .question {
        Text(ZhijiCopy.dateFromEvidence).font(.zhiji(11)).foregroundStyle(palette.tertiary)
      }
      if !knot.who.isEmpty {
        HStack(spacing: 6) {
          ForEach(knot.who, id: \.personID) { person in
            HStack(spacing: 4) {
              Avatar(person, size: 18)
              Text(person.name).font(.zhiji(12)).foregroundStyle(palette.label)
            }
          }
        }
      }
      if let quote = quoteView(knot) { quote }
      Text(ZhijiCopy.evidenceCount(knot.evidence.count)).font(.zhiji(12, .semibold))
        .foregroundStyle(palette.secondary)
      VStack(alignment: .leading, spacing: 4) {
        ForEach(knot.evidence) { evidence in
          evidenceRow(evidence)
        }
      }
    }
  }

  private func quoteView(_ knot: MemoryStrandModel.Knot) -> AnyView? {
    guard !knot.quote.isEmpty else { return nil }
    let holder = knot.evidence.first(where: \.holdsQuote)
    let text = holder.flatMap { evidence -> String? in
      let item = state.projection?.item(evidence.itemID)
      return item?.record?.text ?? item?.reading?.body
    }
    let excerpt = text.flatMap { MemoryQuoteExcerpt.excerpt(of: knot.quote, in: $0) }
    return AnyView(
      VStack(alignment: .leading, spacing: 4) {
        Text(ZhijiCopy.theWords).font(.zhiji(11, .semibold)).foregroundStyle(palette.secondary)
        Group {
          if let excerpt {
            Text(excerpt.before).foregroundColor(palette.secondary)
              + Text(excerpt.quote).foregroundColor(palette.label).fontWeight(.semibold)
              + Text(excerpt.after).foregroundColor(palette.secondary)
          } else {
            Text("「\(knot.quote)」").foregroundColor(palette.label)
          }
        }
        .font(.zhiji(13))
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        HomeTones(palette).amber.fill.opacity(0.7), in: RoundedRectangle(cornerRadius: 8)
      )
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("bestASR.memory.quote"))
  }

  private func evidenceRow(_ evidence: MemoryStrandModel.Evidence) -> some View {
    Button {
      openRow(evidence.rowID)
    } label: {
      HStack(alignment: .top, spacing: 8) {
        KnotSourceTile(kind: evidence.source, size: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text(meta(evidence)).metaStyle(palette).lineLimit(1)
          Text(evidence.snippet).font(.zhiji(12)).foregroundStyle(palette.label)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 0)
      }
      .padding(6)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(ZhijiCopy.openSource)
    .accessibilityLabel("\(meta(evidence))，\(evidence.snippet)")
    .accessibilityHint(ZhijiCopy.openSource)
    .accessibilityIdentifier("bestASR.memory.evidenceItem")
  }

  private func meta(_ evidence: MemoryStrandModel.Evidence) -> String {
    var parts: [String] = []
    if let time = evidence.time {
      parts.append("\(Self.shortDay(time, state.calendar)) \(state.time(time))")
    }
    if !evidence.sourceLabel.isEmpty { parts.append(evidence.sourceLabel) }
    return parts.joined(separator: " · ")
  }

  static func shortDay(_ date: Date, _ calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.month, .day], from: date)
    return "\(parts.month ?? 0)/\(parts.day ?? 0)"
  }
}

// MARK: - Flow layout

/// Rows that wrap: each subview at its ideal size, left to right.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var line: CGFloat = 0
    var widest: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        y += line + lineSpacing
        x = 0
        line = 0
      }
      x += size.width + spacing
      line = max(line, size.height)
      widest = max(widest, x - spacing)
    }
    return CGSize(width: proposal.width ?? widest, height: subviews.isEmpty ? 0 : y + line)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var x = bounds.minX
    var y = bounds.minY
    var line: CGFloat = 0
    for view in subviews {
      let size = view.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        y += line + lineSpacing
        x = bounds.minX
        line = 0
      }
      view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      line = max(line, size.height)
    }
  }
}
