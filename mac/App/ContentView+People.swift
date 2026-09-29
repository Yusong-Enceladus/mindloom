import AppKit
import BestASRCore
import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRPersistence
import Dispatch
import SwiftUI

// People: moved out of ContentView.swift without change.
extension ContentView {
  var peopleView: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("人物").font(.largeTitle.bold())
          Text("口述、当面录音、线上会议和导入的文件认的是同一批人。")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !model.people.personReviewCandidates.isEmpty {
          Label(
            "\(model.people.personReviewCandidates.count) 条待确认",
            systemImage: "person.crop.circle.badge.questionmark"
          )
          .font(.callout.weight(.medium))
          .foregroundStyle(.orange)
        }
        Menu {
          Button("重新检查人物匹配") {
            model.reevaluateAutomaticPersonMatches()
          }
          .accessibilityIdentifier("bestASR.people.reevaluate")
          Button("撤销最近修改") { model.undoLastPersonEdit() }
            .accessibilityIdentifier("bestASR.people.undo")
          Divider()
          Button("刷新") { model.refreshPeople() }
            .accessibilityIdentifier("bestASR.people.refresh")
        } label: {
          Label("更多", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("bestASR.people.more")
      }

      TextField("搜索人物名称或别名", text: $model.history.peopleSearchQuery)
        .textFieldStyle(.roundedBorder)
        .onChange(of: model.history.peopleSearchQuery) { _, _ in
          ensureVisiblePersonSelection()
        }
        .accessibilityIdentifier("bestASR.people.search")

      if !model.people.personReviewCandidates.isEmpty {
        ReviewDisclosure(
          title: "待确认人物线索（\(model.people.personReviewCandidates.count)）",
          expanded: $showsPersonReview,
          identifier: "bestASR.people.reviewQueue"
        ) {
          // No nested scroll area: the page already scrolls, and a 160-point
          // scroller inside a scrolling page traps the wheel and hides its
          // own contents from anything trying to reach them.
          VStack(alignment: .leading, spacing: 8) {
            ForEach(model.people.personReviewCandidates) { candidate in
                HStack(alignment: .center, spacing: 12) {
                  Image(systemName: "waveform.badge.person.crop")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 38, height: 38)
                    .background(.orange.opacity(0.10), in: Circle())
                  VStack(alignment: .leading, spacing: 4) {
                    Text(
                      "可能是 \(candidate.candidateDisplayName ?? "待命名人物")"
                    )
                    .font(.headline)
                    Text(
                      "\(model.personReviewCandidateSessionTitle(candidate)) · \(candidate.occurrenceCount) 段发言 · \(Self.personDuration(candidate.speechDurationNanoseconds))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text("先听对应原音，再确认或选择“不是这个人物”。")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer(minLength: 12)
                  Button("听原音并确认") {
                    model.openPersonReviewCandidate(candidate)
                  }
                  .buttonStyle(.borderedProminent)
                  .accessibilityIdentifier(
                    "bestASR.people.review.open.\(candidate.id.rawValue.uuidString)"
                  )
                }
                .padding(10)
                .background(
                  .orange.opacity(0.06),
                  in: RoundedRectangle(cornerRadius: 10)
                )
              }
          }
          .padding(.top, 8)
        }

      }

      HSplitView {
        ScrollView {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 170), spacing: 10)],
            spacing: 10
          ) {
            if model.filteredPersonSummaries.isEmpty {
              ContentUnavailableView(
                "还没有人物",
                systemImage: "person.2.slash",
                description: Text("完成含语音的记录后，人物会在这里统一出现。")
              )
              .padding(.top, 30)
            }
            ForEach(model.filteredPersonSummaries) { summary in
              Button {
                model.beginEditingPerson(summary)
              } label: {
                VStack(alignment: .leading, spacing: 10) {
                  HStack {
                    Image(systemName: "person.wave.2.fill")
                      .font(.title2)
                      .foregroundStyle(
                        model.people.selectedPersonID == summary.person.id
                          ? Color.accentColor : Color.secondary
                      )
                      .frame(width: 42, height: 42)
                      .background(
                        Color.accentColor.opacity(0.10),
                        in: Circle()
                      )
                    Spacer()
                    if model.people.selectedPersonID == summary.person.id {
                      Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                    }
                  }
                  Text(Self.personTitle(summary))
                    .font(.headline)
                    .lineLimit(1)
                  HStack(spacing: 6) {
                    Label(
                      "\(summary.sessionCount) 条记录",
                      systemImage: "rectangle.stack"
                    )
                    Text("·")
                    Text("\(summary.embeddingCount) 个声纹")
                  }
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  if summary.speechDurationNanoseconds > 0 {
                    Text(Self.personDuration(summary.speechDurationNanoseconds))
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  if let latest = summary.latestOccurrenceAt {
                    Label(
                      latest.formatted(date: .abbreviated, time: .omitted),
                      systemImage: "clock"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  }
                }
                .contentShape(Rectangle())
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
              }
              .buttonStyle(.plain)
              .background(
                model.people.selectedPersonID == summary.person.id
                  ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 13)
              )
              .accessibilityIdentifier(
                "bestASR.people.row.\(summary.person.id.rawValue.uuidString)"
              )
            }
          }
        }
        .frame(
          minWidth: 340,
          idealWidth: 430,
          maxHeight: .infinity,
          alignment: .top
        )

        GroupBox("人物详情") {
          ScrollView {
            VStack(alignment: .leading, spacing: 14) {
              if model.people.selectedPersonID == nil {
                ContentUnavailableView(
                  "选择一个人物",
                  systemImage: "person.crop.circle",
                  description: Text("在记录里确认是谁在说话后，人物会出现在这里。")
                )
                .accessibilityIdentifier("bestASR.people.selectionPlaceholder")
              } else {
                if let summary = model.selectedPersonSummary {
                  HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "person.wave.2.fill")
                      .font(.system(size: 30))
                      .foregroundStyle(.tint)
                      .frame(width: 54, height: 54)
                      .background(
                        Color.accentColor.opacity(0.11),
                        in: Circle()
                      )
                    VStack(alignment: .leading, spacing: 5) {
                      Text(Self.personTitle(summary))
                        .font(.title2.bold())
                      if !summary.person.aliases.isEmpty {
                        Text(summary.person.aliases.joined(separator: "、"))
                          .foregroundStyle(.secondary)
                      }
                    }
                  }
                  HStack(spacing: 18) {
                    Label("\(summary.sessionCount) 条记录", systemImage: "tray.full")
                    Label(
                      "\(summary.embeddingCount) 个本机声纹",
                      systemImage: "waveform.badge.person.crop"
                    )
                    Label(
                      Self.personDuration(summary.speechDurationNanoseconds),
                      systemImage: "waveform"
                    )
                    if let latest = summary.latestOccurrenceAt {
                      Label(
                        "最近 \(latest.formatted(date: .abbreviated, time: .shortened))",
                        systemImage: "clock"
                      )
                    }
                  }
                  .font(.caption)
                  .foregroundStyle(.secondary)
                }

                DisclosureGroup("编辑人物资料") {
                  VStack(alignment: .leading, spacing: 9) {
                    TextField("显示名称", text: $model.people.personNameDraft)
                      .textFieldStyle(.roundedBorder)
                      .accessibilityIdentifier("bestASR.people.name")
                    TextField("别名，用逗号分隔", text: $model.people.personAliasesDraft)
                      .textFieldStyle(.roundedBorder)
                      .accessibilityIdentifier("bestASR.people.aliases")
                    Button("保存") { model.savePersonDraft() }
                      .buttonStyle(.borderedProminent)
                      .disabled(
                        model.people.personNameDraft.trimmingCharacters(
                          in: .whitespacesAndNewlines
                        ).isEmpty
                      )
                      .accessibilityIdentifier("bestASR.people.save")
                  }
                  .padding(.top, 7)
                }

                if !model.selectedPersonRelatedEvents.isEmpty {
                  GroupBox("相关事件") {
                    ScrollView(.horizontal) {
                      HStack(spacing: 8) {
                        ForEach(model.selectedPersonRelatedEvents) { event in
                          Button(event.event.title) {
                            model.beginEditingEvent(event)
                            navigate(to: .events)
                          }
                          .buttonStyle(.bordered)
                        }
                      }
                    }
                  }
                }

                GroupBox("相关记录与出现时间线") {
                  if selectedPersonOccurrenceGroups.isEmpty {
                    Text("还没有可显示的出现记录")
                      .foregroundStyle(.secondary)
                      .padding(8)
                  } else {
                    ScrollView {
                      LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(selectedPersonOccurrenceGroups) { group in
                          HStack(alignment: .top, spacing: 10) {
                            Image(
                              systemName: group.item.map {
                                historyModeSymbol($0.inputMode)
                              } ?? "waveform"
                            )
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                            VStack(alignment: .leading, spacing: 4) {
                              Text(group.item?.title ?? "历史记录")
                                .font(.subheadline.weight(.medium))
                              let speechDuration = group.occurrences.reduce(UInt64(0)) {
                                $0
                                  + ($1.monotonicEndNanoseconds
                                    >= $1.monotonicStartNanoseconds
                                    ? $1.monotonicEndNanoseconds
                                      - $1.monotonicStartNanoseconds
                                    : 0)
                              }
                              Text(personOccurrenceDetail(group, duration: speechDuration))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                              if let preview = compactPreview(group.item?.preferredText) {
                                Text(preview)
                                  .font(.caption)
                                  .foregroundStyle(.secondary)
                                  .lineLimit(2)
                              }
                            }
                            Spacer()
                            Button("定位") {
                              guard let occurrence = group.occurrences.first else { return }
                              model.openPersonOccurrence(occurrence)
                            }
                            Button("播放第一段") {
                              guard let occurrence = group.occurrences.first else { return }
                              model.openPersonOccurrence(occurrence, play: true)
                            }
                            .disabled(group.item?.sourceAudioRetained != true)
                          }
                          .padding(.vertical, 5)
                        }
                      }
                    }
                    .frame(maxHeight: 220)
                  }
                }

                DisclosureGroup("管理人物") {
                  VStack(alignment: .leading, spacing: 10) {
                    Text("合并、删除声纹或解除身份关系不会删除任何历史、逐字稿或原音；合并可撤销。")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    Picker("要合并的人物", selection: $model.people.mergeTargetPersonID) {
                      Text("选择人物…").tag(Optional<PersonID>.none)
                      ForEach(
                        model.people.personSummaries.filter {
                          $0.person.id != model.people.selectedPersonID
                        }
                      ) { summary in
                        Text(Self.personTitle(summary))
                          .tag(Optional(summary.person.id))
                      }
                    }
                    Button("合并到当前人物") { model.mergeSelectedPerson() }
                      .disabled(model.people.mergeTargetPersonID == nil)

                    Divider()
                    Button("删除这个人物的本机声纹…", role: .destructive) {
                      confirmDeletePersonVoiceprints = true
                    }
                    .confirmationDialog(
                      "删除所选人物的声纹向量？",
                      isPresented: $confirmDeletePersonVoiceprints,
                      titleVisibility: .visible
                    ) {
                      Button("删除声纹向量", role: .destructive) {
                        model.deleteSelectedPersonVoiceprints()
                      }
                      Button("取消", role: .cancel) {}
                    } message: {
                      Text("人物名称、人工确认关系、原音和逐字稿会保留。")
                    }
                    Button("删除人物身份并解除全部关联…", role: .destructive) {
                      confirmDeletePersonIdentity = true
                    }
                    .confirmationDialog(
                      "删除这个人物身份？",
                      isPresented: $confirmDeletePersonIdentity,
                      titleVisibility: .visible
                    ) {
                      Button("删除身份与关联", role: .destructive) {
                        model.deleteSelectedPersonIdentity()
                      }
                      Button("取消", role: .cancel) {}
                    } message: {
                      if let summary = model.selectedPersonSummary {
                        Text(
                          "将删除 \(summary.embeddingCount) 份声纹特征，并解除 \(summary.sessionCount) 条记录中的人物关联；不会删除任何历史、逐字稿或原音。"
                        )
                      }
                    }
                  }
                  .padding(.top, 7)
                }
              }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
          }
          .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(
          minWidth: 320,
          maxWidth: .infinity,
          maxHeight: .infinity,
          alignment: .topLeading
        )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

      Text(model.people.peopleStatusMessage)
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("bestASR.people.status")
    }
    .padding(36)
    .navigationTitle("人物")
    .onAppear {
      model.refreshPeople()
      ensureVisiblePersonSelection()
    }
    .onChange(of: model.people.personSummaries.map(\.id)) { _, _ in
      ensureVisiblePersonSelection()
    }
  }

  func ensureVisiblePersonSelection() {
    let visible = model.filteredPersonSummaries
    guard let first = visible.first else { return }
    if !visible.contains(where: { $0.id == model.people.selectedPersonID }) {
      model.beginEditingPerson(first)
    }
  }

  var selectedPersonOccurrenceGroups: [PersonOccurrenceGroup] {
    let items = Dictionary(
      uniqueKeysWithValues: model.history.selectedPersonHistoryItems.map {
        ($0.sessionID, $0)
      }
    )
    return Dictionary(grouping: model.people.selectedPersonOccurrences, by: \.sessionID)
      .map { sessionID, occurrences in
        PersonOccurrenceGroup(
          sessionID: sessionID,
          item: items[sessionID],
          occurrences: occurrences.sorted {
            $0.monotonicStartNanoseconds < $1.monotonicStartNanoseconds
          }
        )
      }
      .sorted {
        ($0.item?.createdAt ?? .distantPast)
          > ($1.item?.createdAt ?? .distantPast)
      }
  }

  func personOccurrenceDetail(
    _ group: PersonOccurrenceGroup,
    duration: UInt64
  ) -> String {
    let date =
      group.item?.createdAt.formatted(
        date: .abbreviated,
        time: .shortened
      ) ?? "时间未知"
    return "\(date) · \(group.occurrences.count) 次发言 · \(Self.personDuration(duration))"
  }

  var speakerIdentityDetails: some View {
    GroupBox("谁在说话") {
      VStack(alignment: .leading, spacing: 10) {
        if model.people.selectedSessionSpeakers.isEmpty {
          ProgressView().controlSize(.small)
        } else {
          ForEach(model.people.selectedSessionSpeakers) { speaker in
            HStack(spacing: 10) {
              Label(
                Self.speakerDisplayTitle(
                  displayName: speaker.displayName,
                  personID: speaker.personID,
                  associationStatus: speaker.associationStatus,
                  stableOrdinal: speaker.stableOrdinal
                ),
                systemImage: speakerAssociationSymbol(speaker.associationStatus)
              )
              .frame(minWidth: 150, alignment: .leading)
              Text(
                "\(speaker.occurrenceCount) 段 · \(Int(Double(speaker.speechDurationNanoseconds) / 1_000_000_000)) 秒"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              Text(speakerAssociationTitle(speaker))
                .font(.caption)
                .foregroundStyle(
                  speaker.associationStatus == .candidate ? .orange : .secondary
                )
              Spacer()
              if speaker.personID == nil || speaker.associationStatus == .rejected {
                TextField(
                  "输入人物名称",
                  text: Binding(
                    get: { model.people.speakerNameDrafts[speaker.id] ?? "" },
                    set: { model.people.speakerNameDrafts[speaker.id] = $0 }
                  )
                )
                .focused($historyFocusedField, equals: .speaker)
                .frame(width: 150)
                Button("新建并确认") {
                  model.confirmSpeakerAsNewPerson(speaker)
                }
                if !model.people.personSummaries.isEmpty {
                  Menu("匹配已有人物") {
                    ForEach(
                      model.people.personSummaries.filter {
                        $0.person.id != speaker.personID
                      }
                    ) { person in
                      Button(Self.personTitle(person)) {
                        model.assignSpeaker(speaker, to: person)
                      }
                    }
                  }
                }
              } else {
                Menu("纠正关系") {
                  if [.automaticMatch, .candidate].contains(
                    speaker.associationStatus
                  ) {
                    Button("确认是 \(speaker.displayName ?? "这个人物")") {
                      model.confirmSpeakerCandidate(speaker)
                    }
                    Button("不是这个人物") {
                      model.rejectSpeakerPersonMatch(speaker)
                    }
                  }
                  Button("移除本次人物关联") {
                    model.clearSpeakerPersonAssociation(speaker)
                  }
                  if !model.people.personSummaries.isEmpty {
                    Divider()
                    ForEach(
                      model.people.personSummaries.filter {
                        $0.person.id != speaker.personID
                      }
                    ) { person in
                      Button("改为 \(Self.personTitle(person))") {
                        model.assignSpeaker(speaker, to: person)
                      }
                    }
                  }
                }
              }
            }
          }
          if model.selectedSessionOccurrences.contains(where: {
            $0.personID != nil
              && Self.hasActivePersonAssociation($0.associationStatus)
          }) {
            DisclosureGroup("拆分误归到同一人物的片段") {
              VStack(alignment: .leading, spacing: 7) {
                Text("选择属于同一个人物的片段，把它们拆成一个新人物；操作可在人物页撤销。")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                ForEach(
                  model.selectedSessionOccurrences.filter {
                    $0.personID != nil
                      && Self.hasActivePersonAssociation($0.associationStatus)
                  }
                ) { occurrence in
                  HStack {
                    Button {
                      model.toggleOccurrenceForSplit(occurrence)
                    } label: {
                      Image(
                        systemName: model.splitOccurrenceIDs.contains(occurrence.id)
                          ? "checkmark.square.fill" : "square"
                      )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                      "选择第 \(occurrence.stableOrdinal) 个声音在 \(model.historyPlaybackPosition(forMonotonicNanoseconds: occurrence.monotonicStartNanoseconds).map(formatPlaybackTime) ?? "未知时间") 的片段"
                    )
                    .accessibilityValue(
                      model.splitOccurrenceIDs.contains(occurrence.id) ? "已选择" : "未选择"
                    )
                    .accessibilityIdentifier(
                      "bestASR.history.splitOccurrence.\(occurrence.id.rawValue.uuidString)"
                    )
                    Text(
                      model.historyPlaybackPosition(
                        forMonotonicNanoseconds:
                          occurrence.monotonicStartNanoseconds
                      ).map(formatPlaybackTime) ?? "—"
                    )
                    .font(.caption.monospacedDigit())
                    Text(
                      Self.speakerDisplayTitle(
                        displayName: occurrence.personDisplayName,
                        personID: occurrence.personID,
                        associationStatus: occurrence.associationStatus,
                        stableOrdinal: occurrence.stableOrdinal
                      )
                    )
                    .font(.callout.weight(.medium))
                    Text("第 \(occurrence.stableOrdinal) 个声音")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    Spacer()
                    Button("播放这里") {
                      model.seekHistoryPlayback(
                        toMonotonicNanoseconds:
                          occurrence.monotonicStartNanoseconds
                      )
                      if !model.playback.playbackIsPlaying {
                        model.toggleHistoryPlayback()
                      }
                    }
                    .buttonStyle(.link)
                  }
                }
                HStack {
                  TextField("拆分后的人物名称", text: $model.people.splitPersonNameDraft)
                    .focused($historyFocusedField, equals: .personSplit)
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("bestASR.history.splitPersonName")
                  Button("拆分所选片段") { model.splitSelectedOccurrences() }
                    .disabled(
                      model.splitOccurrenceIDs.isEmpty
                        || model.people.splitPersonNameDraft.trimmingCharacters(
                          in: .whitespacesAndNewlines
                        ).isEmpty
                    )
                }
              }
              .padding(.top, 6)
            }
          }
        }
        Text(model.people.speakerIdentityStatusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("撤销最近一次人物修改") { model.undoLastPersonEdit() }
          .buttonStyle(.link)
      }
      .padding(.top, 4)
    }
  }

  var speakerTranscriptDetails: some View {
    GroupBox("按人分开的文字") {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Spacer()
          Toggle("播放时跟随", isOn: $followsHistoryPlayback)
            .toggleStyle(.checkbox)
            .font(.caption)
            .accessibilityIdentifier("bestASR.history.followPlayback")
        }
        LazyVStack(alignment: .leading, spacing: 8) {
          if let transcript = model.selectedHistoryTimestampedTranscript {
            if !model.canEditHistoryTranscriptSegments(transcript) {
              Text("当前文字做过整篇校对；如需逐段修改，请先从“来源”恢复带时间点的版本。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(transcript.segments, id: \.id) { segment in
              let occurrence = bestOccurrence(for: segment)
              let segmentStart =
                model.historyPlaybackPosition(
                  forMonotonicNanoseconds: segment.monotonicStartNanoseconds
                ) ?? -1
              let segmentEnd =
                model.historyPlaybackPosition(
                  forMonotonicNanoseconds: segment.monotonicEndNanoseconds
                ) ?? segmentStart
              let isPlayingSegment =
                model.playback.playbackPosition >= segmentStart
                && model.playback.playbackPosition < max(segmentStart + 0.05, segmentEnd)
              let isLocatedSegment =
                segmentStart < 0
                && model.history.locatedSegmentID == segment.id
              HStack(alignment: .top, spacing: 10) {
                Button(
                  segmentStart >= 0 ? formatPlaybackTime(segmentStart) : "—"
                ) {
                  model.playHistoryTranscriptSegment(segment)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier(
                  "bestASR.history.playSegment.\(segment.id.uuidString)"
                )
                .help("从这里播放")
                inlineSpeakerControl(occurrence)
                  .frame(width: 132, alignment: .leading)
                if editingHistorySegmentID == segment.id {
                  VStack(alignment: .leading, spacing: 7) {
                    TextField("校对这一段", text: $historySegmentEditDraft)
                      .focused($historyFocusedField, equals: .segment)
                      .textFieldStyle(.roundedBorder)
                      .onSubmit {
                        saveHistoryTranscriptSegmentEdit(
                          transcript: transcript,
                          segment: segment
                        )
                      }
                      .accessibilityIdentifier(
                        "bestASR.history.segmentEditor.\(segment.id.uuidString)"
                      )
                    HStack(spacing: 8) {
                      Button("保存") {
                        saveHistoryTranscriptSegmentEdit(
                          transcript: transcript,
                          segment: segment
                        )
                      }
                      .buttonStyle(.borderedProminent)
                      .accessibilityIdentifier(
                        "bestASR.history.saveSegment.\(segment.id.uuidString)"
                      )
                      .disabled(
                        historySegmentEditDraft.trimmingCharacters(
                          in: .whitespacesAndNewlines
                        ).isEmpty
                          || model.history.reprocessingInProgress
                      )
                      Button("取消") {
                        editingHistorySegmentID = nil
                        historySegmentEditDraft = ""
                        historyFocusedField = nil
                      }
                      .accessibilityIdentifier(
                        "bestASR.history.cancelSegment.\(segment.id.uuidString)"
                      )
                    }
                    .controlSize(.small)
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                  Text(segment.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                      TapGesture().onEnded {
                        model.locateHistoryTranscriptSegment(segment)
                      }
                    )
                    .help("单击定位原音；使用左侧时间开始播放")
                    .accessibilityIdentifier(
                      "bestASR.history.segment.\(segment.id.uuidString)"
                    )
                    .accessibilityAction(named: "定位对应原音") {
                      model.locateHistoryTranscriptSegment(segment)
                    }
                  if model.canEditHistoryTranscriptSegments(transcript) {
                    Button {
                      editingHistorySegmentID = segment.id
                      historySegmentEditDraft = segment.text
                      historyFocusedField = .segment
                    } label: {
                      Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .help("校对这一段；时间点和原音不变")
                    .accessibilityLabel("校对这一段")
                    .accessibilityIdentifier(
                      "bestASR.history.editSegment.\(segment.id.uuidString)"
                    )
                  }
                }
              }
              .id(segment.id)
              .padding(.horizontal, 9)
              .padding(.vertical, 7)
              .background(
                isPlayingSegment || isLocatedSegment
                  ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
              )
              .animation(
                .easeOut(duration: 0.15),
                value: isPlayingSegment || isLocatedSegment
              )
            }
          } else {
            Text("这条记录还没有带时间戳的逐字稿分段；原文和原音仍然保留。")
              .foregroundStyle(.secondary)
          }
        }
        if showsInlinePersonCorrectionFeedback,
          !model.people.speakerIdentityStatusMessage.isEmpty
        {
          HStack(spacing: 8) {
            Text(model.people.speakerIdentityStatusMessage)
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("bestASR.history.inlineSpeakerStatus")
            Spacer()
            Button("撤销人物修改") { model.undoLastPersonEdit() }
              .buttonStyle(.borderless)
              .accessibilityIdentifier("bestASR.history.inlineSpeakerUndo")
          }
        }
      }
      .padding(.top, 4)
    }
  }

  @ViewBuilder
  func inlineSpeakerControl(
    _ occurrence: SpeakerOccurrenceSummary?
  ) -> some View {
    if let occurrence,
      let speaker = model.people.selectedSessionSpeakers.first(where: {
        $0.id == occurrence.sessionSpeakerID
      })
    {
      let displayTitle = Self.speakerDisplayTitle(
        displayName: occurrence.personDisplayName,
        personID: occurrence.personID,
        associationStatus: occurrence.associationStatus,
        stableOrdinal: occurrence.stableOrdinal
      )
      Menu {
        if speaker.personID != nil,
          [.automaticMatch, .candidate].contains(speaker.associationStatus)
        {
          Button("确认是 \(speaker.displayName ?? "这个人物")") {
            showsInlinePersonCorrectionFeedback = true
            model.confirmSpeakerCandidate(speaker)
          }
          .accessibilityIdentifier(
            "bestASR.history.confirmSpeaker.\(speaker.id.rawValue.uuidString)"
          )
          Button("不是这个人物") {
            showsInlinePersonCorrectionFeedback = true
            model.rejectSpeakerPersonMatch(speaker)
          }
          .accessibilityIdentifier(
            "bestASR.history.rejectSpeaker.\(speaker.id.rawValue.uuidString)"
          )
        }
        ForEach(
          model.people.personSummaries.filter { $0.person.id != speaker.personID }
        ) { person in
          Button("改为 \(Self.personTitle(person))") {
            showsInlinePersonCorrectionFeedback = true
            model.assignSpeaker(speaker, to: person)
          }
          .accessibilityIdentifier(
            "bestASR.history.assignSpeaker.\(speaker.id.rawValue.uuidString).\(person.person.id.rawValue.uuidString)"
          )
        }
        if Self.hasActivePersonAssociation(speaker.associationStatus) {
          Button("清除本次人物关联") {
            showsInlinePersonCorrectionFeedback = true
            model.clearSpeakerPersonAssociation(speaker)
          }
          .accessibilityIdentifier(
            "bestASR.history.clearSpeaker.\(speaker.id.rawValue.uuidString)"
          )
        }
        Divider()
        Button("更多人物操作…") {
          historyWorkspaceTab = .memory
        }
      } label: {
        // A Menu built from a label view does not pass that view on as the
        // control's accessibility name: with the decorative person icon it
        // announced "account", and with a Text it announced nothing. The
        // string form names it, which is all this control is — a name you
        // can correct.
        Text(displayTitle)
      }
      .menuStyle(.borderlessButton)
      .font(.callout.weight(.semibold))
      .fixedSize()
      .accessibilityLabel(displayTitle)
      .help("纠正这一段是谁在说")
      .accessibilityIdentifier(
        "bestASR.history.inlineSpeaker.\(occurrence.id.rawValue.uuidString)"
      )
    } else {
      Text("还不知道是谁")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
    }
  }

  func bestOccurrence(
    for segment: DictationTranscriptSegment
  ) -> SpeakerOccurrenceSummary? {
    TranscriptSpeakerSelection.occurrence(
      for: segment,
      in: model.selectedSessionOccurrences
    )
  }

  func speakerAssociationTitle(
    _ speaker: SessionSpeakerSummary
  ) -> String {
    switch speaker.associationStatus {
    case .anonymousIdentity: return "跨记录保留为待命名人物"
    case .automaticMatch: return "系统自动匹配"
    case .candidate: return "建议匹配，等待确认"
    case .userConfirmed: return "已人工确认"
    case .rejected: return "已明确排除"
    case .unknown: return "未知人物"
    }
  }

  func speakerAssociationSymbol(
    _ status: PersonAssociationStatus
  ) -> String {
    switch status {
    case .userConfirmed, .automaticMatch:
      "person.crop.circle.fill.badge.checkmark"
    case .rejected:
      "person.crop.circle.badge.xmark"
    case .anonymousIdentity, .candidate, .unknown:
      "person.crop.circle.badge.questionmark"
    }
  }

  static func hasActivePersonAssociation(
    _ status: PersonAssociationStatus
  ) -> Bool {
    [.anonymousIdentity, .automaticMatch, .userConfirmed].contains(status)
  }

  static func speakerDisplayTitle(
    displayName: String?,
    personID: PersonID?,
    associationStatus: PersonAssociationStatus,
    stableOrdinal: UInt32
  ) -> String {
    TranscriptSpeakerSelection.displayTitle(
      displayName: displayName,
      personID: personID,
      associationStatus: associationStatus,
      stableOrdinal: stableOrdinal
    )
  }

  static func personTitle(_ summary: PersonSummary) -> String {
    summary.displayTitle
  }
}
