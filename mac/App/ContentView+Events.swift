import AppKit
import BestASRCore
import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRPersistence
import Dispatch
import SwiftUI

// Events: moved out of ContentView.swift without change.
extension ContentView {
  /// With the Spark link on, the page shows only the Spark projection; the
  /// local organizer's list returns as the fallback when the link is off.
  var eventsView: some View {
    Group {
      if model.remoteOrganizerEnabled {
        sparkEventsView
      } else {
        localEventsView
      }
    }
  }

  var localEventsView: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("事件").font(.largeTitle.bold())
          Text("把不同来源的语音按真实事情组织起来，并保留每条原始证据。")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("新事件") {
          creatingEvent = true
          model.beginNewEvent()
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("bestASR.events.new")
        Menu {
          Button("重新整理") { model.refreshEvents() }
            .disabled(model.events.organizationInProgress)
            .accessibilityIdentifier("bestASR.events.refresh")
          Button("撤销最近修改") { model.undoLastEventEdit() }
            .accessibilityIdentifier("bestASR.events.undo")
        } label: {
          Label("更多", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("bestASR.events.more")
      }

      HStack(spacing: 10) {
        TextField("搜索事件、人物、记录或语义内容", text: $model.history.eventSearchQuery)
          .textFieldStyle(.roundedBorder)
          .onSubmit { model.applyEventSearch() }
          .onChange(of: model.history.eventSearchQuery) { _, _ in
            model.applyEventSearch()
          }
          .accessibilityIdentifier("bestASR.events.search")
      }
      Text(model.events.eventStatusMessage)
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("bestASR.events.status")

      if !model.events.candidates.isEmpty {
        ReviewDisclosure(
          title: "待确认事件线索（\(model.events.candidates.count)）",
          expanded: $showsEventReview,
          identifier: "bestASR.events.reviewQueue"
        ) {
          VStack(alignment: .leading, spacing: 9) {
            Text("系统只提出本机线索，不会替你强制归类。先听来源原音，再确认是不是同一件事。")
              .font(.caption)
              .foregroundStyle(.secondary)
            // No nested scroll area inside a page that already scrolls.
            VStack(alignment: .leading, spacing: 8) {
              ForEach(model.events.candidates) { candidate in
                  let destinationTitle = model.eventCandidateDestinationTitle(candidate)
                  let sourceItem = model.history.eventAvailableHistoryItems.first {
                    $0.sessionID == candidate.sessionID
                  }
                  HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                      Text(destinationTitle)
                        .font(.headline)
                        .lineLimit(2)
                        .accessibilityLabel(destinationTitle)
                        .accessibilityIdentifier("bestASR.events.candidate.title")
                      Text(
                        candidate.candidateEventID == nil
                          ? "建议建立新事件" : "建议归入已有事件"
                      )
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      if let preview = eventCandidatePreview(candidate) {
                        Text(preview)
                          .font(.caption)
                          .foregroundStyle(.secondary)
                          .lineLimit(2)
                      }
                      if let sourceItem {
                        Label(
                          "\(historyModeTitle(sourceItem.inputMode)) · \(sourceItem.createdAt.formatted(date: .abbreviated, time: .shortened))",
                          systemImage: "waveform"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                      }
                      Text(eventCandidateReason(candidate))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(spacing: 7) {
                      Button("听原音并判断") {
                        model.openEventCandidateSource(candidate)
                      }
                      .buttonStyle(.borderedProminent)
                      .accessibilityIdentifier(
                        "bestASR.events.candidate.open.\(candidate.id.rawValue.uuidString)"
                      )
                      Menu("更多") {
                        Button("忽略这条线索") {
                          model.dismissEventCandidate(candidate)
                        }
                        .accessibilityIdentifier(
                          "bestASR.events.candidate.dismiss.\(candidate.id.rawValue.uuidString)"
                        )
                      }
                    }
                  }
                  .padding(10)
                  .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                  .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
              }
            }
          }
          .padding(.top, 8)
        }

      }

      if model.filteredEventSummaries.isEmpty,
        model.events.selectedEventID == nil, creatingEvent
      {
        GroupBox("建立事件") {
          eventCreationForm
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("bestASR.events.fullWidthCreate")
      } else if model.filteredEventSummaries.isEmpty,
        model.events.selectedEventID == nil, !creatingEvent
      {
        VStack(spacing: 14) {
          ContentUnavailableView(
            "还没有事件",
            systemImage: "point.3.connected.trianglepath.dotted",
            description: Text("确认上方建议，或手动选择历史记录建立事件。")
          )
          Button("建立第一个事件") {
            creatingEvent = true
            model.beginNewEvent()
          }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("bestASR.events.emptyCreate")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("bestASR.events.emptyState")
      } else {
        HSplitView {
          ScrollView {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 190), spacing: 10)],
              spacing: 10
            ) {
              if model.filteredEventSummaries.isEmpty {
                ContentUnavailableView(
                  "还没有事件",
                  systemImage: "point.3.connected.trianglepath.dotted",
                  description: Text("确认上方建议，或手动选择历史记录建立事件。")
                )
                .padding(.top, 30)
              }
              ForEach(model.filteredEventSummaries) { summary in
                Button {
                  creatingEvent = false
                  model.beginEditingEvent(summary)
                } label: {
                  VStack(alignment: .leading, spacing: 10) {
                    HStack {
                      Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.title3)
                        .foregroundStyle(.tint)
                      Text(summary.event.title)
                        .font(.headline)
                        .lineLimit(1)
                      Spacer()
                      if summary.event.confirmationState == .userConfirmed {
                        Image(systemName: "checkmark.seal")
                          .foregroundStyle(.secondary)
                          .help("已由用户确认")
                      }
                      Text("\(summary.sessionIDs.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Text(
                      summary.event.startAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                      )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if !summary.personDisplayNames.isEmpty {
                      Label(
                        summary.personDisplayNames.joined(separator: "、"),
                        systemImage: "person.2"
                      )
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                    }
                    if let latest = latestHistoryItem(for: summary) {
                      Label(latest.title, systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                  }
                  .padding(14)
                  .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                  model.events.selectedEventID == summary.id
                    ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04),
                  in: RoundedRectangle(cornerRadius: 13)
                )
                .accessibilityIdentifier("bestASR.events.row.\(summary.id.rawValue.uuidString)")
              }
            }
          }
          .frame(
            minWidth: 360,
            idealWidth: 450,
            maxHeight: .infinity,
            alignment: .top
          )

          GroupBox(
            creatingEvent
              ? "建立事件"
              : (model.events.selectedEventID == nil ? "事件" : "事件详情")
          ) {
            if let selected = model.selectedEventSummary {
              ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                  HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                      .font(.system(size: 30))
                      .foregroundStyle(.tint)
                      .frame(width: 52, height: 52)
                      .background(
                        Color.accentColor.opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 14)
                      )
                    VStack(alignment: .leading, spacing: 5) {
                      Text(selected.event.title)
                        .font(.title2.bold())
                      Text(
                        "\(selected.sessionIDs.count) 条记录 · \(selected.event.startAt.formatted(date: .abbreviated, time: .omitted)) 至 \(selected.event.endAt.formatted(date: .abbreviated, time: .omitted))"
                      )
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      if !selected.event.notes.isEmpty {
                        Text(selected.event.notes)
                          .foregroundStyle(.secondary)
                      }
                    }
                    Spacer()
                    Menu("复制这件事") {
                      Button("复制为文本") { model.copySelectedLocalEventText() }
                      Button("导出为文本…") { model.exportSelectedLocalEventText() }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("bestASR.events.export")
                  }

                  DisclosureGroup("编辑名称与备注") {
                    VStack(alignment: .leading, spacing: 9) {
                      TextField("事件名称", text: $model.events.titleDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("bestASR.events.name")
                      TextField(
                        "备注（不会改写原始逐字稿）",
                        text: $model.events.notesDraft,
                        axis: .vertical
                      )
                      .textFieldStyle(.roundedBorder)
                      .lineLimit(2...6)
                      Button("保存") { model.saveEventDraft() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("bestASR.events.save")
                    }
                    .padding(.top, 7)
                  }

                  if !selected.personIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                      Text("相关人物").font(.headline)
                      ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                          ForEach(
                            Array(zip(selected.personIDs, selected.personDisplayNames)), id: \.0
                          ) {
                            personID, displayName in
                            Button(displayName) { model.openEventPerson(personID) }
                              .buttonStyle(.bordered)
                          }
                        }
                      }
                    }
                  }

                  GroupBox("事件主题与整理") {
                    VStack(alignment: .leading, spacing: 10) {
                      Menu {
                        Button("事件摘要") {
                          model.generateEventDocument(.structuredSummary)
                        }
                        Button("主题演变") {
                          model.generateEventDocument(.chapters)
                        }
                        Button("结论") {
                          model.generateEventDocument(.decisions)
                        }
                        Button("待办") {
                          model.generateEventDocument(.actionItems)
                        }
                      } label: {
                        Label("生成事件整理", systemImage: "wand.and.stars")
                      }
                      .buttonStyle(.borderedProminent)
                      .disabled(model.events.generatingEventDocumentTaskID != nil)
                      if model.events.generatingEventDocumentTaskID != nil {
                        HStack {
                          ProgressView().controlSize(.small)
                          Text("正在本机整理…")
                            .foregroundStyle(.secondary)
                        }
                      }
                      ForEach(
                        model.events.textDocuments.filter { $0.state == .current }
                      ) { document in
                        eventDocumentCard(document)
                      }
                      let staleCount = model.events.textDocuments.filter {
                        $0.state == .stale
                      }.count
                      if staleCount > 0 {
                        Text("保留 \(staleCount) 个旧整理版本；事件关系变化后不会把旧结果冒充当前结论。")
                          .font(.caption)
                          .foregroundStyle(.secondary)
                      }
                    }
                    .padding(.top, 4)
                  }

                  GroupBox("事件时间线与来源记录") {
                    if model.history.selectedEventHistoryItems.isEmpty {
                      Text("这个事件还没有记录")
                        .foregroundStyle(.secondary)
                        .padding(8)
                    } else {
                      LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.history.selectedEventHistoryItems) { item in
                          HStack(alignment: .top, spacing: 10) {
                            Image(systemName: historyModeSymbol(item.inputMode))
                              .foregroundStyle(.secondary)
                              .frame(width: 18)
                            VStack(alignment: .leading, spacing: 4) {
                              Text(item.title).lineLimit(1)
                              Text(
                                "\(historyModeTitle(item.inputMode)) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))"
                              )
                              .font(.caption)
                              .foregroundStyle(.secondary)
                              SourceChip(label: item.sourceLabel)
                              if let preview = compactPreview(item.preferredText) {
                                Text(preview)
                                  .font(.caption)
                                  .foregroundStyle(.secondary)
                                  .lineLimit(2)
                              }
                            }
                            Spacer()
                            Button("打开原音与逐字稿") {
                              model.openEventHistoryItem(item)
                            }
                            .accessibilityIdentifier(
                              "bestASR.events.timeline.open.\(item.sessionID.rawValue.uuidString)"
                            )
                          }
                          .padding(.vertical, 4)
                        }
                      }
                    }
                  }
                  .accessibilityIdentifier("bestASR.events.timeline")

                  DisclosureGroup("管理事件分组") {
                    VStack(alignment: .leading, spacing: 10) {
                      Text("勾选事件中的记录后，可以拆分、移出或移动；所有操作都保留原音和逐字稿，并可撤销最近一次修改。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                      ForEach(model.history.selectedEventHistoryItems) { item in
                        Toggle(
                          isOn: Binding(
                            get: { model.events.sessionSelection.contains(item.sessionID) },
                            set: { _ in model.toggleEventSessionSelection(item.sessionID) }
                          )
                        ) {
                          Text(item.title).lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier(
                          "bestASR.events.selectSource.\(item.sessionID.rawValue.uuidString)"
                        )
                      }

                      if !model.linkableHistoryItemsForSelectedEvent.isEmpty {
                        HStack {
                          Picker("关联记录", selection: $model.events.addSessionID) {
                            Text("选择历史记录…").tag(Optional<SessionID>.none)
                            ForEach(model.linkableHistoryItemsForSelectedEvent) { item in
                              Text(item.title).tag(Optional(item.sessionID))
                            }
                          }
                          Button("关联") { model.linkSelectedHistoryToEvent() }
                            .disabled(model.events.addSessionID == nil)
                        }
                      }

                      TextField("拆分后的新事件名称", text: $model.events.newEventTitleDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("bestASR.events.splitName")
                      HStack {
                        Button("拆成新事件") {
                          model.splitSelectedEventSessions()
                        }
                        Button("从当前事件移出") {
                          model.removeSelectedSessionsFromEvent()
                        }
                      }
                      .disabled(model.events.sessionSelection.isEmpty)

                      Picker("移动到", selection: $model.events.moveTargetEventID) {
                        Text("选择目标事件…").tag(Optional<EventID>.none)
                        ForEach(model.events.summaries.filter { $0.id != selected.id }) {
                          Text($0.event.title).tag(Optional($0.id))
                        }
                      }
                      Button("移动所选记录") { model.moveSelectedEventSessions() }
                        .disabled(
                          model.events.sessionSelection.isEmpty
                            || model.events.moveTargetEventID == nil
                        )

                      Picker("合并事件", selection: $model.events.mergeTargetEventID) {
                        Text("选择事件…").tag(Optional<EventID>.none)
                        ForEach(model.events.summaries.filter { $0.id != selected.id }) {
                          Text($0.event.title).tag(Optional($0.id))
                        }
                      }
                      Button("合并到当前事件") { model.mergeSelectedEvent() }
                        .disabled(model.events.mergeTargetEventID == nil)

                      Divider()
                      Button("删除事件关系…", role: .destructive) {
                        confirmRetireEvent = true
                      }
                    }
                    .padding(.top, 7)
                  }
                }
                .padding(6)
              }
            } else if creatingEvent {
              eventCreationForm
                .padding(6)
            } else {
              ContentUnavailableView(
                "选择一个事件",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("从左侧选择事件查看时间线、人物、来源和整理结果。")
              )
              .accessibilityIdentifier("bestASR.events.selectionPlaceholder")
            }
          }
          .frame(
            minWidth: 340,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
          )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
    }
    .padding(32)
    .navigationTitle("事件")
    .onAppear { ensureVisibleEventSelection() }
    .onChange(of: model.events.selectedEventID) { _, selectedEventID in
      if selectedEventID != nil { creatingEvent = false }
    }
    .onChange(of: model.filteredEventSummaries.map(\.id)) { _, _ in
      ensureVisibleEventSelection()
    }
  }

  func ensureVisibleEventSelection() {
    guard !creatingEvent, let first = model.filteredEventSummaries.first else {
      return
    }
    if !model.filteredEventSummaries.contains(where: {
      $0.id == model.events.selectedEventID
    }) {
      model.beginEditingEvent(first)
    }
  }

  var eventCreationForm: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("事件名称", text: $model.events.newEventTitleDraft)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("bestASR.events.createTitle")
      Text("可以先建立空事件，也可以勾选未归类记录。所有原音、逐字稿和人物证据仍各自保留。")
        .font(.caption)
        .foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 7) {
          ForEach(model.unassignedEventHistoryItems) { item in
            Toggle(
              isOn: Binding(
                get: { model.events.sessionSelection.contains(item.sessionID) },
                set: { _ in model.toggleEventSessionSelection(item.sessionID) }
              )
            ) {
              VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .toggleStyle(.checkbox)
          }
        }
      }
      HStack {
        Button("建立事件") { model.createEventFromSelection() }
          .buttonStyle(.borderedProminent)
          .disabled(
            model.events.newEventTitleDraft.trimmingCharacters(
              in: .whitespacesAndNewlines
            ).isEmpty
          )
          .accessibilityIdentifier("bestASR.events.createConfirm")
        Button("取消") { creatingEvent = false }
          .accessibilityIdentifier("bestASR.events.createCancel")
      }
    }
  }

  func eventCandidateReason(_ candidate: EventCandidate) -> String {
    var reasons: [String] = []
    if candidate.evidence.semanticScore >= 0.55 { reasons.append("内容相近") }
    if candidate.evidence.peopleScore >= 0.45 { reasons.append("出现相同人物") }
    if candidate.evidence.temporalScore >= 0.45 { reasons.append("时间接近") }
    if candidate.evidence.sourceScore >= 0.45 { reasons.append("来源相同") }
    return reasons.isEmpty
      ? "线索还不够明确，需要你确认"
      : "因为" + reasons.joined(separator: "、")
  }

  func eventCandidatePreview(
    _ candidate: EventCandidate
  ) -> String? {
    let item = model.history.eventAvailableHistoryItems.first {
      $0.sessionID == candidate.sessionID
    }
    return compactPreview(item?.preferredText)
  }

  func eventDocumentCard(
    _ document: EventTextDocumentRecord
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(DictationAppModel.localTextTaskTitle(document.taskID))
          .font(.headline)
        Text("跨 \(document.sourceReferences.count) 条来源记录")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }
      if let body = MemoryDocumentPresentation.distinctBody(
        document.result.outputText,
        itemTexts: document.result.structuredItems.map(\.text)
      ) {
        Text(body)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }

      ForEach(document.result.structuredItems, id: \.itemID) { item in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(
            systemName: item.disposition == .cautious
              ? "exclamationmark.triangle" : "checkmark.circle"
          )
          .foregroundStyle(item.disposition == .cautious ? .orange : .secondary)
          Text(item.text)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button("来源") {
            model.openEventDocumentSource(
              document,
              segmentIDs: item.sourceSegmentIDs
            )
          }
          .buttonStyle(.link)
          .accessibilityIdentifier(
            "bestASR.events.document.source.\(document.id).\(item.itemID)"
          )
        }
        .font(.caption)
      }

      DisclosureGroup("来源与编辑") {
        VStack(alignment: .leading, spacing: 9) {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(document.sourceReferences, id: \.transcriptRevisionID) {
              reference in
              Button(
                model.history.selectedEventHistoryItems.first(where: {
                  $0.sessionID == reference.sessionID
                })?.title ?? "查看来源记录"
              ) {
                model.openEventDocumentSource(
                  document,
                  segmentIDs: reference.segmentIDs
                )
              }
              .buttonStyle(.link)
            }
          }
          TextEditor(
            text: Binding(
              get: {
                model.events.documentTextDrafts[
                  document.id,
                  default: document.result.outputText
                ]
              },
              set: { model.events.documentTextDrafts[document.id] = $0 }
            )
          )
          .frame(minHeight: 90)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(Color(nsColor: .separatorColor))
          )
          Button("保存为新版本") { model.saveEventDocumentEdit(document) }
            .disabled(model.events.generatingEventDocumentTaskID != nil)
        }
        .padding(.top, 6)
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
  }

  var historyTimelineDetails: some View {
    GroupBox("录制时间线") {
      VStack(alignment: .leading, spacing: 7) {
        if model.history.selectedHistoryTimelineEvents.isEmpty {
          Text("这条记录没有暂停、设备切换或音源中断事件。")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.history.selectedHistoryTimelineEvents, id: \.id) { event in
            HStack(spacing: 9) {
              Image(systemName: timelineEventSymbol(event.kind))
                .foregroundStyle(
                  event.kind == .gap ? Color.orange : Color.secondary
                )
              Button(
                model.historyPlaybackPosition(
                  forMonotonicNanoseconds: event.monotonicNanoseconds
                ).map(formatPlaybackTime) ?? "—"
              ) {
                model.playHistoryPlayback(
                  toMonotonicNanoseconds: event.monotonicNanoseconds
                )
              }
              .buttonStyle(.link)
              Text(timelineEventTitle(event.kind))
              if let duration = event.durationNanoseconds, duration > 0 {
                Text("· \(formatPlaybackTime(Double(duration) / 1_000_000_000))")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
              Spacer()
            }
          }
        }
      }
      .padding(.top, 4)
    }
  }

  func timelineEventTitle(_ kind: TimelineEventKind) -> String {
    switch kind {
    case .deviceChanged: "录音设备已切换"
    case .gap: "录音出现缺口"
    case .pause: "已暂停"
    case .resume: "已继续"
    case .sourceChanged: "电脑音源已切换"
    }
  }

  func timelineEventSymbol(_ kind: TimelineEventKind) -> String {
    switch kind {
    case .deviceChanged: "mic.badge.plus"
    case .gap: "exclamationmark.triangle"
    case .pause: "pause.circle"
    case .resume: "play.circle"
    case .sourceChanged: "speaker.wave.2.circle"
    }
  }
}

extension ContentView {
  fileprivate var sparkEventsView: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("事件").font(.largeTitle.bold())
        Text("由你的整理设备整理；每条来源记录和你的修改都先保存在这台 Mac 上。")
          .foregroundStyle(.secondary)
      }
      // The page's only scroll area.
      ScrollView {
        remoteOrganizerSection
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .padding(32)
    .navigationTitle("事件")
  }

  fileprivate var remoteOrganizerSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(model.events.remoteStatusMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
      if let projection = model.events.remoteProjection {
        if !projection.unacceptedDecisions.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("整理设备未接受").font(.headline)
            ForEach(projection.unacceptedDecisions) { issue in
              HStack {
                Text(DictationAppModel.remoteDecisionIssueTitle(issue))
                  .font(.callout)
                Spacer()
                Button(issue.state == .deliveryUnknown ? "确认送达" : "重试") {
                  model.retryRemoteDecision(issue)
                }
                // One the Spark may already have applied cannot be discarded.
                if issue.state != .deliveryUnknown {
                  Button("放弃") { model.discardRemoteDecision(issue) }
                }
              }
            }
          }
          .accessibilityIdentifier("bestASR.events.spark.unaccepted")
        }
        if !projection.questions.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("待确认").font(.headline)
            ForEach(projection.questions) { question in
              HStack {
                Text(question.promptZH)
                Spacer()
                Button("是") { model.answerRemoteQuestion(question, yes: true) }
                Button("否") { model.answerRemoteQuestion(question, yes: false) }
              }
            }
          }
        }
        if projection.events.isEmpty {
          Text("还没有整理设备的结果；开启后开始的记录完成后会在这里出现。")
            .foregroundStyle(.secondary)
        } else {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 240), spacing: 10)],
            spacing: 10
          ) {
            ForEach(projection.events) { event in
              RemoteOrganizerEventCard(event: event, model: model)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("bestASR.events.spark")
  }
}

private struct RemoteOrganizerEventCard: View {
  let event: RemoteOrganizerEvent
  @ObservedObject var model: DictationAppModel
  @State private var renaming = false
  @State private var titleDraft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(event.title).font(.headline).lineLimit(2)
        Spacer()
        if event.pinned { Image(systemName: "pin.fill").foregroundStyle(.tint) }
      }
      Text(event.statusLine.isEmpty ? "正在整理进度" : event.statusLine)
        .font(.callout)
        .lineLimit(3)
      Text("\(event.itemIDs.count) 条来源记录")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Button(event.pinned ? "取消置顶" : "置顶") {
          model.recordRemoteDecision(
            .init(kind: "pin_event", eventID: event.eventID, pinned: !event.pinned)
          )
        }
        Button("改标题") {
          titleDraft = event.title
          renaming = true
        }
        Menu("更多") {
          Button("复制这件事") { model.copyRemoteEventText(event) }
          Button("导出为文本…") { model.exportRemoteEventText(event) }
          Divider()
          Button("减少推荐") {
            model.recordRemoteDecision(
              .init(kind: "feature_less", eventID: event.eventID)
            )
          }
          Button("删除事件", role: .destructive) {
            model.recordRemoteDecision(
              .init(kind: "delete_event", eventID: event.eventID)
            )
          }
        }
      }
      .controlSize(.small)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    .alert("修改事件标题", isPresented: $renaming) {
      TextField("标题", text: $titleDraft)
      Button("保存") {
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        model.recordRemoteDecision(
          .init(kind: "rename_event", eventID: event.eventID, title: title)
        )
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("最多 \(RemoteOrganizerDecision.maximumTitleScalars) 个字；超出时不会保存。")
    }
  }
}
