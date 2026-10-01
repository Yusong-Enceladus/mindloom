import BestASRDomain
import BestASRMemory
import SwiftUI

// MARK: - 结构

/// The 结构 lens: what the matter holds, as a tree. 进展 by strand, then
/// 决定, 下一步, 问题, 人 and 材料; a leaf opens its knot on the 线索 map.
struct StructureLens: View {
  @Environment(\.zhiji) private var palette
  let eventID: String
  let detail: MemoryEventDetail
  let state: MemoryScreenState
  let showKnot: (String) -> Void

  var body: some View {
    if let projection = state.projection,
      let model = MemoryStrandModel(
        projection: projection, eventID: eventID, now: state.libraryNow,
        calendar: state.calendar)
    {
      let colors = MatterColors(eventID: eventID, state: state)
      VStack(alignment: .leading, spacing: 0) {
        root(model)
        branch(ZhijiCopy.branchProgress, ZhijiCopy.branchProgressDetail) {
          progress(model, colors)
        }
        let decisions = model.allKnots.filter { $0.glyph == .decision }
        if !decisions.isEmpty {
          branch(ZhijiCopy.branchDecisions, ZhijiCopy.mattersCount(decisions.count)) {
            leaves(decisions, model: model, colors: colors)
          }
        }
        let next = model.allKnots.filter { $0.glyph == .planned }
        if !next.isEmpty {
          branch(ZhijiCopy.branchNext, ZhijiCopy.mattersCount(next.count)) {
            leaves(next, model: model, colors: colors)
          }
        }
        let questions = model.allKnots.filter { $0.glyph == .question }
        if !questions.isEmpty {
          branch(ZhijiCopy.branchQuestions, ZhijiCopy.stillOpen) {
            leaves(questions, model: model, colors: colors)
          }
        }
        let people = peopleCounts(model)
        if !people.isEmpty {
          branch(ZhijiCopy.branchPeople, ZhijiCopy.branchPeopleDetail) {
            FlowLayout(spacing: 8, lineSpacing: 8) {
              ForEach(Array(people.enumerated()), id: \.offset) { _, pair in
                let (person, count) = pair
                leafBox {
                  HStack(spacing: 5) {
                    Avatar(person, size: 18)
                    Text(person.isNamed ? person.name : ZhijiCopy.nameSomeone)
                      .font(.zhiji(13)).foregroundStyle(palette.label)
                    if count > 0 { Text("\(count)").metaStyle(palette) }
                  }
                }
              }
            }
          }
        }
        let materials = materialCounts(model, projection: projection)
        if !materials.isEmpty {
          branch(ZhijiCopy.branchMaterials, ZhijiCopy.branchMaterialsDetail) {
            FlowLayout(spacing: 8, lineSpacing: 8) {
              ForEach(Array(materials.enumerated()), id: \.offset) { _, pair in
                let (kind, count) = pair
                leafBox {
                  HStack(spacing: 5) {
                    KnotSourceTile(kind: kind, size: 16)
                    Text(KnotSourceTile.word(kind)).font(.zhiji(13)).foregroundStyle(palette.label)
                    Text("\(count)").metaStyle(palette)
                  }
                }
              }
            }
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("bestASR.memory.structure")
    }
  }

  private func root(_ model: MemoryStrandModel) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(detail.title).font(.zhiji(17, .semibold)).foregroundStyle(palette.label)
      if !detail.statusLine.isEmpty, !detail.statusIsFallback {
        Text(detail.statusLine).font(.zhiji(13)).foregroundStyle(palette.secondary)
      }
      // The same count as the page header (a record held in parts is a
      // row per part).
      Text(
        ZhijiCopy.itemCount(detail.items.count)
          + (model.strands.isEmpty ? "" : " · " + ZhijiCopy.strandCount(model.strands.count))
      )
      .metaStyle(palette)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding(.bottom, 8)
  }

  /// One branch: its name on the left, its leaves on the right, joined to
  /// the root by a line.
  private func branch<Content: View>(
    _ name: String, _ detailText: String, @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 2) {
        Text(name).font(.zhiji(14, .semibold)).foregroundStyle(palette.label)
        Text(detailText).font(.zhiji(11)).foregroundStyle(palette.secondary)
      }
      .frame(width: 88, alignment: .leading)
      content().frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 12)
    .padding(.leading, 16)
    .overlay(alignment: .leading) {
      Rectangle().fill(palette.separator).frame(width: 2)
    }
    .accessibilityElement(children: .contain)
  }

  private func progress(_ model: MemoryStrandModel, _ colors: MatterColors) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      let main = model.mainKnots.filter { $0.glyph != .question && $0.glyph != .decision }
      if !main.isEmpty {
        strandGroup(
          name: ZhijiCopy.mainThread, count: model.mainItemCount, color: colors.color(nil, palette),
          knots: main, model: model, colors: colors)
      }
      ForEach(Array(model.strands.enumerated()), id: \.offset) { index, strand in
        strandGroup(
          name: strand.name + (strand.closed ? " · " + ZhijiCopy.closedStrand : ""),
          count: strand.itemCount, color: colors.color(index, palette),
          knots: strand.knots.filter { $0.glyph != .question && $0.glyph != .decision },
          model: model, colors: colors)
      }
    }
  }

  private func strandGroup(
    name: String, count: Int, color: Color, knots: [MemoryStrandModel.Knot],
    model: MemoryStrandModel, colors: MatterColors
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 4)
        Text(name).font(.zhiji(13, .semibold)).foregroundStyle(palette.label)
        Text("· " + ZhijiCopy.strandItems(count)).metaStyle(palette)
      }
      if !knots.isEmpty { leaves(knots, model: model, colors: colors) }
    }
  }

  private func leaves(
    _ knots: [MemoryStrandModel.Knot], model: MemoryStrandModel, colors: MatterColors
  ) -> some View {
    FlowLayout(spacing: 8, lineSpacing: 8) {
      ForEach(knots) { knot in
        Button {
          showKnot(knot.id)
        } label: {
          leafBox {
            HStack(spacing: 5) {
              KnotGlyphView(
                glyph: knot.glyph, color: colors.color(knot.strand, palette),
                daysAway: knot.day - model.today, size: 15)
              Text(knot.text).font(.zhiji(13)).foregroundStyle(palette.label).lineLimit(1)
              if let date = knot.date, knot.glyph != .question {
                Text(EvidencePanel.shortDay(date, state.calendar)).metaStyle(palette)
              }
            }
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(StrandMapView.spoken(knot, model: model, state: state))
        .accessibilityIdentifier("bestASR.memory.leaf")
      }
    }
  }

  private func leafBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .padding(.horizontal, 10)
      .frame(height: 28)
      .frame(maxWidth: 420, alignment: .leading)
      .fixedSize(horizontal: true, vertical: false)
      .background(palette.isDark ? palette.surface : .white, in: Capsule())
      .overlay(Capsule().strokeBorder(palette.separator))
      .contentShape(Capsule())
  }

  /// The event's people, each with how many knots name them.
  private func peopleCounts(_ model: MemoryStrandModel) -> [(MemoryPersonRef, Int)] {
    var counts: [String: Int] = [:]
    for knot in model.allKnots {
      for person in knot.who { counts[person.name, default: 0] += 1 }
    }
    return detail.shownPeople.prefix(12).map { ($0, counts[$0.name] ?? 0) }
  }

  /// The items by where they came from, the most first.
  private func materialCounts(_ model: MemoryStrandModel, projection: MemoryProjection)
    -> [(MemoryLoom.KnotKind, Int)]
  {
    var counts: [MemoryLoom.KnotKind: Int] = [:]
    for item in detail.items {
      guard let record = item.record, !record.isKeyframe else { continue }
      counts[MemoryHomeKinds.kind(record), default: 0] += 1
    }
    return counts.sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }
      .map { ($0.key, $0.value) }
  }
}

/// A record's source kind as the map's tiles show it.
enum MemoryHomeKinds {
  static func kind(_ record: MemoryItemRecord) -> MemoryLoom.KnotKind {
    MemoryLoom.sourceKind(record)
  }
}

// MARK: - 网

/// The 网 lens: the matter's neighbourhood (one and two hops): matters it
/// crosses (shared items), what it waits on and what waits on it, its rope
/// and the rope's other matters. Under the picture, the same relations as a
/// list, each with the way to say it is wrong.
struct NetLens: View {
  @Environment(\.zhiji) private var palette
  let eventID: String
  let state: MemoryScreenState
  let actions: MemoryActions
  let open: (MemoryRoute) -> Void

  static let height: CGFloat = 520

  var body: some View {
    if let projection = state.projection {
      let net = MemoryMatterNet(projection: projection, eventID: eventID)
      VStack(alignment: .leading, spacing: 16) {
        if net.isEmpty {
          Text(ZhijiCopy.noRelations).font(.zhiji(13)).foregroundStyle(palette.secondary)
            .padding(.vertical, 24)
        } else {
          GeometryReader { geometry in
            NetGraph(
              net: net, size: CGSize(width: geometry.size.width, height: Self.height),
              state: state, open: open)
          }
          .frame(height: Self.height)
          .background(
            palette.isDark ? palette.surface.opacity(0.5) : .hex(0xFBFAF7),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.separator))
          NetLegend()
          RelationList(
            eventID: eventID, net: net, projection: projection, state: state, actions: actions,
            open: open)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("bestASR.memory.net")
    }
  }
}

/// The picture: edges in a Canvas, nodes as chips on top.
struct NetGraph: View {
  @Environment(\.zhiji) private var palette
  let net: MemoryMatterNet
  let size: CGSize
  let state: MemoryScreenState
  let open: (MemoryRoute) -> Void

  var body: some View {
    let positions = placed()
    ZStack(alignment: .topLeading) {
      Canvas { context, _ in
        for edge in net.edges {
          guard let a = positions[edge.from], let b = positions[edge.to] else { continue }
          draw(edge, from: a, to: b, context: &context)
        }
      }
      .frame(width: size.width, height: size.height)
      .accessibilityHidden(true)
      ForEach(net.nodes) { node in
        let p = positions[node.id] ?? .zero
        nodeChip(node)
          .fixedSize()
          .position(x: p.x, y: p.y)
      }
    }
    .frame(width: size.width, height: size.height)
  }

  /// The ring positions, then chips that would overlap pushed apart (up and
  /// down; the matter itself never moves) and kept inside the picture.
  /// Deterministic.
  private func placed() -> [String: CGPoint] {
    var points = net.nodes.map(point)
    let sizes = net.nodes.map { chipSize($0.id) }
    for _ in 0..<60 {
      var moved = false
      for i in points.indices {
        for j in points.indices where j > i {
          let dx = points[j].x - points[i].x
          let dy = points[j].y - points[i].y
          let overlapX = sizes[i].width + sizes[j].width + 10 - abs(dx)
          let overlapY = sizes[i].height + sizes[j].height + 8 - abs(dy)
          guard overlapX > 0, overlapY > 0 else { continue }
          let direction: CGFloat = abs(dy) < 0.5 ? (j % 2 == 0 ? 1 : -1) : (dy > 0 ? 1 : -1)
          if net.nodes[i].kind == .center {
            points[j].y += direction * overlapY
          } else if net.nodes[j].kind == .center {
            points[i].y -= direction * overlapY
          } else {
            points[i].y -= direction * (overlapY / 2 + 0.5)
            points[j].y += direction * (overlapY / 2 + 0.5)
          }
          moved = true
        }
      }
      for k in points.indices {
        points[k].x = min(max(points[k].x, 8 + sizes[k].width), size.width - 8 - sizes[k].width)
        points[k].y = min(max(points[k].y, 8 + sizes[k].height), size.height - 8 - sizes[k].height)
      }
      if !moved { break }
    }
    return Dictionary(
      zip(net.nodes.map(\.id), points).map { ($0, $1) }, uniquingKeysWith: { a, _ in a })
  }

  /// Half the size of a node's chip, as `nodeChip` draws it.
  private func chipSize(_ id: String) -> CGSize {
    guard let node = net.nodes.first(where: { $0.id == id }) else {
      return CGSize(width: 40, height: 12)
    }
    let center = node.kind == .center
    let title = MemoryStrandLayout.fit(node.title, width: 190, size: 12.5)
    let text = MemoryStrandLayout.textWidth(title, size: center ? 14 : 12.5)
    let width = text + (center ? 28 : 20) + 14 + (node.kind == .rope ? 20 : 0)
    return CGSize(width: width / 2, height: (center ? 32 : 26) / 2)
  }

  private func point(_ node: MemoryMatterNet.Node) -> CGPoint {
    let rx = max((size.width / 2 - 110) / MemoryMatterNet.outerRadius, 60)
    let ry = max((size.height / 2 - 34) / MemoryMatterNet.outerRadius, 40)
    return CGPoint(x: size.width / 2 + node.x * rx, y: size.height / 2 + node.y * ry)
  }

  @ViewBuilder
  private func nodeChip(_ node: MemoryMatterNet.Node) -> some View {
    let color = palette.thread(MatterColors.index(of: node.id, state: state))
    let title = MemoryStrandLayout.fit(node.title, width: 190, size: 12.5)
    switch node.kind {
    case .rope:
      HStack(spacing: 5) {
        Text(ZhijiCopy.ropeWord).font(.zhiji(11, .semibold)).foregroundStyle(palette.onAccent)
          .padding(.horizontal, 5).frame(height: 16)
          .background(palette.secondary, in: RoundedRectangle(cornerRadius: 4))
        Text(title).font(.zhiji(12.5, .semibold)).foregroundStyle(palette.label)
      }
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(palette.isDark ? palette.surface : .white, in: RoundedRectangle(cornerRadius: 7))
      .overlay(
        RoundedRectangle(cornerRadius: 7)
          .strokeBorder(
            palette.secondary,
            style: StrokeStyle(lineWidth: 1.2, dash: node.proposed ? [4, 3] : []))
      )
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(ZhijiCopy.ropeWord)，\(node.title)")
    case .center, .matter:
      let center = node.kind == .center
      Button {
        if !center { open(.event(node.id)) }
      } label: {
        HStack(spacing: 6) {
          Circle().fill(color).frame(width: 8, height: 8)
          Text(title).font(.zhiji(center ? 14 : 12.5, center ? .semibold : .regular))
            .foregroundStyle(palette.label)
        }
        .padding(.horizontal, center ? 14 : 10)
        .frame(height: center ? 32 : 24)
        .background(
          center
            ? color.opacity(palette.isDark ? 0.30 : 0.16)
            : (palette.isDark ? palette.surface : .white),
          in: Capsule()
        )
        .overlay(
          Capsule().strokeBorder(center ? color : palette.separator, lineWidth: center ? 1.6 : 1)
        )
        .opacity(node.hop == 2 ? 0.8 : 1)
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(node.title)
      .accessibilityIdentifier("bestASR.memory.netNode")
    }
  }

  private func draw(
    _ edge: MemoryMatterNet.Edge, from a: CGPoint, to b: CGPoint, context: inout GraphicsContext
  ) {
    let ink = palette.secondary
    var path = Path()
    path.move(to: a)
    // Crossings bow one way and waiting the other, so two edges between the
    // same matters stay apart; a matter's rope is a straight line.
    let bow: CGFloat =
      switch edge.kind {
      case .cross: -14
      case .blocks: 26
      case .ply: 0
      }
    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + bow)
    path.addQuadCurve(to: b, control: mid)
    switch edge.kind {
    case .cross(let count):
      context.stroke(
        path, with: .color(ink.opacity(0.75)),
        style: StrokeStyle(
          lineWidth: 1.4 + min(CGFloat(count), 30) / 15, lineCap: .round, dash: [1.5, 4.5]))
      let label = CGPoint(x: (a.x + 2 * mid.x + b.x) / 4, y: (a.y + 2 * mid.y + b.y) / 4)
      let text = "\(count)"
      let w = MemoryStrandLayout.textWidth(text, size: 11) + 10
      context.fill(
        Path(
          roundedRect: CGRect(x: label.x - w / 2, y: label.y - 9, width: w, height: 18),
          cornerRadius: 9),
        with: .color(palette.isDark ? palette.surface : .white))
      context.draw(
        Text(text).font(.zhiji(11, .semibold)).monospacedDigit().foregroundColor(ink),
        at: label, anchor: .center)
    case .blocks:
      context.stroke(path, with: .color(palette.label.opacity(0.8)), lineWidth: 1.8)
      // The arrow ends at the edge of the chip it points at.
      let angle = atan2(b.y - mid.y, b.x - mid.x)
      let half = chipSize(edge.to)
      let reach = min(
        abs(cos(angle)) > 0.001 ? half.width / abs(cos(angle)) : .infinity,
        abs(sin(angle)) > 0.001 ? half.height / abs(sin(angle)) : .infinity)
      let tip = CGPoint(x: b.x - cos(angle) * (reach + 3), y: b.y - sin(angle) * (reach + 3))
      var head = Path()
      head.move(to: CGPoint(x: tip.x - cos(angle - 0.45) * 9, y: tip.y - sin(angle - 0.45) * 9))
      head.addLine(to: tip)
      head.addLine(to: CGPoint(x: tip.x - cos(angle + 0.45) * 9, y: tip.y - sin(angle + 0.45) * 9))
      context.stroke(
        head, with: .color(palette.label.opacity(0.8)),
        style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
    case .ply:
      context.stroke(
        path, with: .color(ink.opacity(0.55)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
    }
  }
}

/// What the lines mean.
struct NetLegend: View {
  @Environment(\.zhiji) private var palette

  var body: some View {
    HStack(spacing: 16) {
      item(dash: [1.5, 4], width: 1.8, ZhijiCopy.crossLegend)
      item(dash: [], width: 1.8, ZhijiCopy.blocksLegend, arrow: true)
      item(dash: [], width: 2.6, ZhijiCopy.sameRope)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }

  private func item(dash: [CGFloat], width: CGFloat, _ word: String, arrow: Bool = false)
    -> some View
  {
    HStack(spacing: 6) {
      Canvas { context, size in
        var path = Path()
        path.move(to: CGPoint(x: 1, y: size.height / 2))
        path.addLine(to: CGPoint(x: size.width - 1, y: size.height / 2))
        context.stroke(
          path, with: .color(palette.secondary),
          style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
        if arrow {
          var head = Path()
          head.move(to: CGPoint(x: size.width - 7, y: size.height / 2 - 4))
          head.addLine(to: CGPoint(x: size.width - 1, y: size.height / 2))
          head.addLine(to: CGPoint(x: size.width - 7, y: size.height / 2 + 4))
          context.stroke(head, with: .color(palette.secondary), lineWidth: 1.6)
        }
      }
      .frame(width: 26, height: 12)
      Text(word).font(.zhiji(12)).foregroundStyle(palette.secondary)
    }
  }
}

/// The relations of the matter as rows: 在等 / 被它等 / 交叉 N 次 / 同一根绳,
/// each with its way to say it is wrong.
struct RelationList: View {
  @Environment(\.zhiji) private var palette
  let eventID: String
  let net: MemoryMatterNet
  let projection: MemoryProjection
  let state: MemoryScreenState
  let actions: MemoryActions
  let open: (MemoryRoute) -> Void

  var body: some View {
    let titles = Dictionary(
      projection.events.map { ($0.eventID, $0.title) }, uniquingKeysWith: { a, _ in a })
    VStack(alignment: .leading, spacing: 0) {
      if let rope = MemoryMatterNet.ropeIndex(projection.ropes)[eventID] {
        row(
          word: ZhijiCopy.sameRope, title: ZhijiCopy.ropeLabel(rope.title, proposed: rope.proposed),
          detail: rope.reason, target: nil
        ) {
          if rope.proposed {
            CapsuleButton(title: ZhijiCopy.confirmRope, height: 24, fontSize: 12) {
              actions.relation(.confirmRope(rope.id))
            }
            CapsuleButton(title: ZhijiCopy.rejectRope, height: 24, fontSize: 12) {
              actions.relation(.rejectRope(rope.id))
            }
          }
        }
      }
      ForEach(Array(relations.enumerated()), id: \.offset) { _, relation in
        let other = relation.a == eventID ? relation.b : relation.a
        if let title = titles[other] {
          if relation.isBlocks {
            let waits = relation.b == eventID
            row(
              word: waits ? ZhijiCopy.waitsOn : ZhijiCopy.waitedBy, title: title,
              detail: relation.quote.map { "「\($0)」" } ?? "", target: other
            ) {
              CapsuleButton(title: ZhijiCopy.notWaiting, height: 24, fontSize: 12) {
                actions.relation(.rejectBlocks(a: relation.a, b: relation.b))
              }
            }
          } else {
            row(
              word: ZhijiCopy.crossed(relation.count ?? 0), title: title,
              detail: ZhijiCopy.crossedDetail(relation.count ?? 0), target: other
            ) {
              CapsuleButton(title: ZhijiCopy.hideCrossing, height: 24, fontSize: 12) {
                actions.relation(.hideCrossing(a: relation.a, b: relation.b))
              }
            }
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bestASR.memory.relations")
  }

  /// Blocks edges first, then crossings by strength (at most ten).
  private var relations: [RemoteOrganizerRelation] {
    let own = projection.relations.filter { $0.a == eventID || $0.b == eventID }
    let blocks = own.filter(\.isBlocks)
    let crossings = own.filter(\.isCross).sorted {
      ($0.count ?? 0, $1.a + $1.b) > ($1.count ?? 0, $0.a + $0.b)
    }
    return Array((blocks + crossings).prefix(10))
  }

  private func row<Trailing: View>(
    word: String, title: String, detail: String, target: String?,
    @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Text(word).font(.zhiji(12, .semibold)).foregroundStyle(palette.secondary)
        .frame(width: 76, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        if let target {
          Button(title) { open(.event(target)) }
            .buttonStyle(.plain)
            .font(.zhiji(13, .semibold))
            .foregroundStyle(palette.accent)
        } else {
          Text(title).font(.zhiji(13, .semibold)).foregroundStyle(palette.label)
        }
        if !detail.isEmpty {
          Text(detail).font(.zhiji(12)).foregroundStyle(palette.secondary).lineLimit(2)
        }
      }
      Spacer(minLength: 8)
      trailing()
    }
    .padding(.vertical, 10)
    .overlay(alignment: .bottom) {
      Rectangle().fill(palette.separator.opacity(0.7)).frame(height: 1)
    }
    .accessibilityElement(children: .contain)
  }
}
