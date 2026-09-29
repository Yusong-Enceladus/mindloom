import AppKit
import BestASRCore
import BestASRDictation
import BestASRDomain
import BestASRInference
import BestASRPersistence
import Dispatch
import SwiftUI

// HistoryDetail: moved out of ContentView.swift without change.
extension ContentView {
  func openHistoryDetail(_ item: DictationHistoryItem) {
    historyFocusedField = nil
    if model.history.selectedHistorySessionID != item.sessionID {
      editingHistorySegmentID = nil
      historySegmentEditDraft = ""
      showsInlinePersonCorrectionFeedback = false
    }
    historyWorkspaceTab = .transcript
    model.openHistorySearchResult(item)
  }

  func historyDetailPage(_ item: DictationHistoryItem) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        model.history.detailPresented = false
      } label: {
        Label("历史记录", systemImage: "chevron.backward")
          .font(.system(size: 13, weight: .medium))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 24)
      .padding(.top, 16)
      .padding(.bottom, 4)
      .accessibilityIdentifier("bestASR.history.back")
      if let origin = model.history.navigationOrigin {
        HStack(spacing: 10) {
          Button {
            model.clearHistoryNavigationOrigin()
            navigate(
              to: BestASRSection(rawValue: origin.kind.rawValue) ?? .history
            )
          } label: {
            Label(origin.returnTitle, systemImage: "chevron.backward")
              .lineLimit(1)
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("bestASR.history.returnToMemory")
          if origin.kind == .event,
            let candidate = model.activeEventReviewCandidate
          {
            Button("确认是同一事件") {
              model.acceptEventCandidate(candidate)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(
              "bestASR.history.eventCandidate.accept"
            )
            Button("不是同一事件") {
              model.dismissEventCandidate(candidate)
            }
            .accessibilityIdentifier(
              "bestASR.history.eventCandidate.dismiss"
            )
          }
          Spacer(minLength: 8)
          Text(
            model.activeEventReviewCandidate == nil
              ? model.history.detailStatusMessage
              : "正在审核事件线索；确认前不会改变任何关系"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 4)
        .background(
          Color.accentColor.opacity(0.10),
          in: RoundedRectangle(cornerRadius: 9)
        )
      }
      historySelectedDetail(item)
    }
  }

  func historySelectedDetail(_ item: DictationHistoryItem) -> some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .top, spacing: 14) {
          VStack(alignment: .leading, spacing: 5) {
            if editingHistoryTitleID == item.sessionID {
              historyTitleEditor(item)
            } else {
              Button {
                model.history.titleDraft = item.title
                editingHistoryTitleID = item.sessionID
                historyFocusedField = .title
              } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Text(item.title)
                    .font(.title2.bold())
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                  Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .buttonStyle(.plain)
              .help("重命名这条记录")
              .accessibilityLabel("重命名记录")
              .accessibilityIdentifier("bestASR.history.rename")
            }
            HStack(spacing: 8) {
              Label(
                historyModeTitle(item.inputMode), systemImage: historyModeSymbol(item.inputMode))
              Text(model.historyStatusTitle(item))
              if let duration = item.durationNanoseconds {
                Text(formatPlaybackTime(Double(duration) / 1_000_000_000))
                  .monospacedDigit()
                  .accessibilityIdentifier("bestASR.history.recordDuration")
              } else {
                Text("时长未知")
              }
              Text(item.updatedAt, format: .dateTime.month().day().hour().minute())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer(minLength: 10)
          if model.canRetryHistoryItem(item) {
            Button {
              model.retryHistoryItem(item)
            } label: {
              HStack(spacing: 5) {
                if model.history.retryingHistorySessionID == item.sessionID {
                  ProgressView().controlSize(.small)
                }
                Text(model.historyRetryTitle(item))
              }
            }
            .disabled(model.history.retryingHistorySessionID != nil)
            .help("使用已保留的原音继续本机处理，原音和已有版本不会被覆盖。")
            .accessibilityIdentifier("bestASR.history.recoverSelected")
          }
          if item.preferredText?.isEmpty == false {
            Button {
              model.copyHistoryItem(item)
            } label: {
              Label("复制", systemImage: "doc.on.doc")
            }
          }
          Button("删除…", role: .destructive) {
            pendingHistoryDeletion = item
          }
          .disabled(!model.canDeleteHistoryItem(item))
          .accessibilityIdentifier("bestASR.history.deleteSelected")
        }

        historyPlaybackDetails

        Picker("记录内容", selection: $historyWorkspaceTab) {
          ForEach(HistoryWorkspaceTab.allCases) { tab in
            Text(tab.title).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("bestASR.history.workspaceTabs")
      }
      .padding(18)

      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          Group {
            switch historyWorkspaceTab {
            case .transcript:
              historyTranscriptWorkspace(item)
            case .notes:
              historyNotesWorkspace
            case .memory:
              historyMemoryWorkspace(item)
            case .source:
              historySourceWorkspace(item)
            }
          }
          .padding(18)
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("bestASR.history.readingPane")
        .onChange(of: activeHistorySegmentID) { _, segmentID in
          guard followsHistoryPlayback, let segmentID
          else { return }
          withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(segmentID, anchor: .center)
          }
        }
        .onChange(of: model.history.locatedSegmentID) { _, segmentID in
          guard let segmentID else { return }
          withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(segmentID, anchor: .center)
          }
        }
      }
    }
  }

  func historyTranscriptWorkspace(
    _ item: DictationHistoryItem
  ) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      if model.history.selectedHistoryTranscripts.contains(where: { !$0.segments.isEmpty }) {
        speakerTranscriptDetails
      } else if let text = item.textIsPreview
        ? (model.selectedHistoryCurrentTranscript?.content ?? item.preferredText)
        : item.preferredText,
        !text.isEmpty
      {
        // A long item's list row holds only a preview; the selected
        // transcripts hold its full text.
        VStack(alignment: .leading, spacing: 8) {
          Text("当前文字").font(.headline)
          Text(text)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("bestASR.history.currentText")
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
      } else {
        ContentUnavailableView(
          "逐字稿尚未生成",
          systemImage: "text.badge.clock",
          description: Text(DictationAppModel.historyEmptyText(item))
        )
      }

      DisclosureGroup("整篇修改与重新处理") {
        VStack(alignment: .leading, spacing: 10) {
          Text("适合一次改很多内容。以前的文字仍可从“来源”找回，原音不会改变。")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextEditor(text: $model.history.transcriptEditDraft)
            .focused($historyFocusedField, equals: .transcript)
            .font(.body)
            .frame(minHeight: 150)
            .overlay {
              RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor))
            }
            .accessibilityIdentifier("bestASR.history.transcriptEditor")
          HStack {
            Button("保存整篇修改") { model.saveHistoryTranscriptEdit() }
              .buttonStyle(.borderedProminent)
              .disabled(model.history.reprocessingInProgress)
            // A pasted or dragged item has no audio to recognize again.
            if item.inputMode != .userItem {
              Button("从原音重新识别") { model.rerecognizeSelectedHistory() }
                .disabled(model.history.reprocessingInProgress)
                .accessibilityIdentifier("bestASR.history.rerecognize")
              Button("按当前词典重新整理") { model.repolishSelectedHistory() }
                .disabled(model.history.reprocessingInProgress)
                .accessibilityIdentifier("bestASR.history.repolish")
            }
            Button("放弃未保存修改") {
              model.discardUnsavedHistoryTranscriptEdit()
            }
            .disabled(model.history.reprocessingInProgress)
            if model.history.reprocessingInProgress {
              ProgressView().controlSize(.small)
            }
          }
          HStack {
            TextField("错误写法", text: $model.history.correctionOriginalDraft)
              .focused($historyFocusedField, equals: .correction)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            TextField("正确写法", text: $model.history.correctionReplacementDraft)
              .focused($historyFocusedField, equals: .correction)
            Button("加入词典") { model.addCorrectionToDictionary() }
          }
        }
        .padding(.top, 8)
      }

      if let raw = model.selectedHistoryRecognitionText,
        let final = model.selectedHistoryFinalText ?? model.selectedHistoryRawText,
        !raw.isEmpty, raw != final
      {
        Button {
          expandedHistoryRawSessionID =
            expandedHistoryRawSessionID == model.history.selectedHistorySessionID
            ? nil : model.history.selectedHistorySessionID
        } label: {
          Label(
            "查看原始识别",
            systemImage:
              expandedHistoryRawSessionID == model.history.selectedHistorySessionID
              ? "chevron.down" : "chevron.right"
          )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bestASR.history.rawDisclosure")
        .accessibilityValue(
          expandedHistoryRawSessionID == model.history.selectedHistorySessionID
            ? "展开" : "折叠"
        )

        if expandedHistoryRawSessionID == model.history.selectedHistorySessionID {
          VStack(alignment: .leading, spacing: 8) {
            Text(raw)
              .textSelection(.enabled)
              .accessibilityIdentifier("bestASR.history.rawText")
            HStack {
              Button("复制原始识别") {
                model.copyHistoryText(raw, label: "原始识别")
              }
              Button("恢复为当前文字") {
                model.restoreSelectedHistoryRawText()
              }
            }
          }
          .padding(.top, 8)
        }
      }

      Text(model.history.detailStatusMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("bestASR.history.detailStatus")
    }
  }

  func historyTitleEditor(_ item: DictationHistoryItem) -> some View {
    HStack(spacing: 7) {
      TextField("记录标题", text: $model.history.titleDraft)
        .focused($historyFocusedField, equals: .title)
        .textFieldStyle(.roundedBorder)
        .onSubmit { saveHistoryTitle(item) }
        .disabled(model.history.titleSaveInProgress)
        .accessibilityIdentifier("bestASR.history.title")
      Button {
        saveHistoryTitle(item)
      } label: {
        if model.history.titleSaveInProgress {
          ProgressView().controlSize(.small)
        } else {
          Text("保存")
        }
      }
      .disabled(
        model.history.titleSaveInProgress
          || model.history.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      )
      .accessibilityLabel("保存标题")
      .accessibilityIdentifier("bestASR.history.saveTitle")
      Button("取消") {
        model.history.titleDraft = item.title
        editingHistoryTitleID = nil
        historyFocusedField = nil
      }
      .disabled(model.history.titleSaveInProgress)
      .accessibilityIdentifier("bestASR.history.cancelTitle")
    }
    .controlSize(.small)
  }

  func saveHistoryTitle(_ item: DictationHistoryItem) {
    let submittedTitle = model.history.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    model.saveHistoryTitle { saved in
      guard saved, editingHistoryTitleID == item.sessionID,
        model.history.selectedHistorySessionID == item.sessionID,
        model.history.titleDraft.trimmingCharacters(in: .whitespacesAndNewlines) == submittedTitle
      else { return }
      editingHistoryTitleID = nil
      historyFocusedField = nil
    }
  }

  var historyNotesWorkspace: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        Text("把这条记录整理成可行动的信息")
          .font(.title3.bold())
        Text("所有结果在本机生成，并持续链接到逐字稿时间戳。")
          .foregroundStyle(.secondary)
      }

      HistoryNotesGenerationControls(
        isGenerating: model.history.generatingHistoryDocumentTaskID != nil
      ) { kind in
        switch kind {
        case .summary: model.generateHistorySummary()
        case .actions: model.generateHistoryActionItems()
        case .chapters: model.generateHistoryChapters()
        case .decisions: model.generateHistoryDecisions()
        }
      }

      let currentDocuments = model.history.selectedHistoryDocuments.filter {
        $0.state == .current
      }
      if currentDocuments.isEmpty {
        ContentUnavailableView(
          "还没有整理结果",
          systemImage: "text.badge.plus",
          description: Text("选择上方一种整理方式；逐字稿和原音不会被改写。")
        )
      } else {
        ForEach(currentDocuments) { document in
          historyDocumentCard(document)
        }
      }

      let staleDocuments = model.history.selectedHistoryDocuments.filter {
        $0.state == .stale
      }
      if !staleDocuments.isEmpty {
        DisclosureGroup("旧整理版本（\(staleDocuments.count)）") {
          VStack(alignment: .leading, spacing: 9) {
            ForEach(staleDocuments) { document in
              VStack(alignment: .leading, spacing: 5) {
                Text(DictationAppModel.localTextTaskTitle(document.taskID))
                  .font(.headline)
                Text(document.result.outputText)
                  .textSelection(.enabled)
                Text(document.createdAt, format: .dateTime.month().day().hour().minute())
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .padding(12)
              .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
          }
          .padding(.top, 8)
        }
      }

      Text(model.history.detailStatusMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("bestASR.history.detailStatus")
    }
  }

  func historyMemoryWorkspace(
    _ item: DictationHistoryItem
  ) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      speakerIdentityDetails

      let relatedEvents = model.events.summaries.filter {
        $0.sessionIDs.contains(item.sessionID)
      }
      GroupBox("相关事件") {
        VStack(alignment: .leading, spacing: 9) {
          if relatedEvents.isEmpty {
            Text("这条记录尚未归入事件。系统只会给出本机建议，确认前不会自动改变你的组织方式。")
              .foregroundStyle(.secondary)
          } else {
            ForEach(relatedEvents) { summary in
              Button {
                model.beginEditingEvent(summary)
                navigate(to: .events)
              } label: {
                HStack {
                  Label(summary.event.title, systemImage: "point.3.connected.trianglepath.dotted")
                  Spacer()
                  Text("\(summary.sessionIDs.count) 条记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
          Button("打开事件工作区") {
            navigate(to: .events)
            model.refreshEvents()
          }
        }
        .padding(.top, 4)
      }
    }
  }

  func historySourceWorkspace(
    _ item: DictationHistoryItem
  ) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("导出") {
        VStack(alignment: .leading, spacing: 10) {
          HistoryTextExportControls(isExporting: model.export.exportInProgress) { format in
            model.exportSelectedHistory(format)
          }
          Divider()
          HStack {
            Text("原音").font(.callout.weight(.medium))
            Spacer()
            Button(model.selectedHistorySourceAudioExportTitle) {
              model.exportSelectedHistorySourceAudio()
            }
            .disabled(
              model.export.exportInProgress
                || (model.history.selectedHistorySourceAssets.isEmpty
                  && model.playback.playbackTrackIDs.isEmpty)
            )
            .accessibilityIdentifier("bestASR.history.exportAudio")
            if model.export.exportInProgress {
              ProgressView().controlSize(.small)
            }
          }
          Text(model.export.exportStatusMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
          if model.playback.playbackDuration > 0 {
            DisclosureGroup("选择原音范围") {
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(
                    "\(formatPlaybackTime(model.export.exportSelectionStart)) – \(formatPlaybackTime(model.export.exportSelectionEnd))"
                  )
                  .font(.caption.monospacedDigit())
                  Spacer()
                  Button("全部") {
                    model.export.exportSelectionStart = 0
                    model.export.exportSelectionEnd = model.playback.playbackDuration
                  }
                  .buttonStyle(.link)
                }
                Slider(
                  value: Binding(
                    get: { model.export.exportSelectionStart },
                    set: {
                      model.export.exportSelectionStart = min(
                        $0,
                        max(0, model.export.exportSelectionEnd - 0.001)
                      )
                    }
                  ),
                  in: 0...max(0.001, model.playback.playbackDuration)
                )
                .accessibilityLabel("导出起点")
                Slider(
                  value: Binding(
                    get: { model.export.exportSelectionEnd },
                    set: {
                      model.export.exportSelectionEnd = max(
                        $0,
                        min(
                          model.playback.playbackDuration,
                          model.export.exportSelectionStart + 0.001
                        )
                      )
                    }
                  ),
                  in: 0...max(0.001, model.playback.playbackDuration)
                )
                .accessibilityLabel("导出终点")
              }
              .padding(.top, 6)
            }
          }
        }
        .padding(.top, 4)
      }

      if !model.history.selectedHistoryTranscripts.isEmpty {
        DisclosureGroup("逐字稿版本（\(model.history.selectedHistoryTranscripts.count)）") {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(model.history.selectedHistoryTranscripts, id: \.id) { transcript in
              VStack(alignment: .leading, spacing: 5) {
                HStack {
                  Text(transcriptVersionTitle(transcript.kind)).font(.caption.bold())
                  Spacer()
                  Text(transcript.createdAt, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  Button("恢复这个版本") {
                    model.restoreHistoryTranscriptRevision(transcript)
                    historyWorkspaceTab = .transcript
                  }
                  .buttonStyle(.link)
                  .disabled(model.history.reprocessingInProgress)
                  .accessibilityIdentifier(
                    "bestASR.history.restoreRevision.\(transcript.id.rawValue.uuidString)"
                  )
                }
                Text(transcript.content).textSelection(.enabled)
              }
              .padding(10)
              .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            }
          }
          .padding(.top, 8)
        }
      }

      if !model.history.selectedHistorySourceAssets.isEmpty {
        GroupBox("保留的原始文件") {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(model.history.selectedHistorySourceAssets) { asset in
              HStack {
                Label(asset.originalFilename, systemImage: "doc")
                Spacer()
                Text(
                  ByteCountFormatter.string(
                    fromByteCount: Int64(asset.sizeBytes), countStyle: .file
                  )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
              }
            }
          }
          .padding(.top, 4)
        }
      }

      sourceContextDetails
      historyTimelineDetails

      HStack {
        if item.inputMode == .userItem {
          Label("原件保留在本机 · 来源：\(item.sourceLabel)", systemImage: "lock.shield")
        } else {
          Label(
            item.sourceAudioRetained ? "原音保留在本机" : "原音已由用户删除",
            systemImage: item.sourceAudioRetained ? "lock.shield" : "waveform.slash"
          )
        }
      }
      .font(.callout)
    }
  }

  @ViewBuilder
  var historyPlaybackDetails: some View {
    if !model.playback.playbackTrackIDs.isEmpty {
      VStack(spacing: 9) {
        GeometryReader { proxy in
          Canvas { context, size in
            let samples = model.playback.waveformSamples
            let middle = size.height / 2
            if samples.isEmpty {
              var baseline = Path()
              baseline.move(to: CGPoint(x: 0, y: middle))
              baseline.addLine(to: CGPoint(x: size.width, y: middle))
              context.stroke(
                baseline,
                with: .color(.secondary.opacity(0.25)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 4])
              )
            } else {
              let step = size.width / CGFloat(max(1, samples.count))
              var path = Path()
              for (index, sample) in samples.enumerated() {
                let x = (CGFloat(index) + 0.5) * step
                let amplitude = max(1, CGFloat(sample) * middle * 0.82)
                path.move(to: CGPoint(x: x, y: middle - amplitude))
                path.addLine(to: CGPoint(x: x, y: middle + amplitude))
              }
              context.stroke(
                path,
                with: .color(.accentColor.opacity(0.72)),
                lineWidth: 1
              )
            }
            if model.playback.playbackDuration > 0 {
              let progress = min(
                1,
                model.playback.playbackPosition / model.playback.playbackDuration
              )
              var cursor = Path()
              cursor.move(to: CGPoint(x: size.width * progress, y: 0))
              cursor.addLine(to: CGPoint(x: size.width * progress, y: size.height))
              context.stroke(cursor, with: .color(.primary), lineWidth: 1.5)
            }
          }
          .contentShape(Rectangle())
          .gesture(
            DragGesture(minimumDistance: 0).onEnded { value in
              guard proxy.size.width > 0 else { return }
              let fraction = min(1, max(0, value.location.x / proxy.size.width))
              model.seekHistoryPlayback(to: model.playback.playbackDuration * fraction)
            }
          )
        }
        .frame(height: 46)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("原音波形")
        .accessibilityIdentifier("bestASR.history.waveform")
        .accessibilityValue(
          model.playback.waveformSamples.isEmpty ? "波形载入中" : "波形已载入"
        )

        HStack(spacing: 9) {
          Button {
            model.seekHistoryPlayback(
              to: max(0, model.playback.playbackPosition - 15)
            )
          } label: {
            Image(systemName: "gobackward.15")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("后退 15 秒")
          .accessibilityIdentifier("bestASR.history.seekBackward15")
          .help("后退 15 秒（⌘←）")

          Button {
            model.toggleHistoryPlayback()
          } label: {
            if model.playback.playbackOperationInProgress {
              ProgressView()
                .controlSize(.small)
                .frame(width: 29, height: 29)
            } else {
              Image(
                systemName: model.playback.playbackIsPlaying
                  ? "pause.circle.fill" : "play.circle.fill"
              )
              .font(.system(size: 29))
            }
          }
          .buttonStyle(.plain)
          .disabled(model.playback.playbackOperationInProgress)
          .accessibilityLabel(model.playback.playbackIsPlaying ? "暂停" : "播放")
          .accessibilityIdentifier("bestASR.history.playPause")
          .help(model.playback.playbackIsPlaying ? "暂停（空格）" : "播放（空格）")

          Button {
            model.seekHistoryPlayback(
              to: min(
                model.playback.playbackDuration,
                model.playback.playbackPosition + 15
              )
            )
          } label: {
            Image(systemName: "goforward.15")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("前进 15 秒")
          .accessibilityIdentifier("bestASR.history.seekForward15")
          .help("前进 15 秒（⌘→）")

          Text(formatPlaybackTime(model.playback.playbackPosition))
            .font(.caption.monospacedDigit())
            .accessibilityIdentifier("bestASR.history.playbackPosition")
          Slider(
            value: Binding(
              get: { model.playback.playbackPosition },
              set: { model.seekHistoryPlayback(to: $0) }
            ),
            in: 0...max(0.01, model.playback.playbackDuration)
          )
          .accessibilityIdentifier("bestASR.history.playbackSeek")
          Text(formatPlaybackTime(model.playback.playbackDuration))
            .font(.caption.monospacedDigit())
            .accessibilityIdentifier("bestASR.history.playbackDuration")

        }

        if model.playback.playbackTrackIDs.count > 1 {
          HStack(spacing: 10) {
            Text("音轨")
              .font(.caption)
              .foregroundStyle(.secondary)
            Picker(
              "播放音轨",
              selection: Binding(
                get: { model.playback.selectedHistoryPlaybackTrackID },
                set: { trackID in
                  guard trackID != model.playback.selectedHistoryPlaybackTrackID else { return }
                  model.selectHistoryPlaybackTrack(trackID)
                }
              )
            ) {
              ForEach(model.playback.playbackTrackIDs, id: \.self) { trackID in
                Text(model.historyPlaybackTrackTitle(trackID)).tag(trackID)
              }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.playback.playbackOperationInProgress)
            .accessibilityIdentifier("bestASR.history.playbackTrack")
          }
        }

        Text(model.playback.playbackStatusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("bestASR.history.playbackStatus")

        Text("空格播放或暂停 · ⌘← / ⌘→ 跳转 15 秒")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("bestASR.history.playbackShortcuts")
      }
      .padding(12)
      .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
    } else if !model.playback.playbackStatusMessage.isEmpty {
      Label(model.playback.playbackStatusMessage, systemImage: "waveform.slash")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  func historyDocumentCard(
    _ document: LocalTextDocumentRecord
  ) -> some View {
    let isEditing = editingHistoryDocuments.contains(document.id)
    return VStack(alignment: .leading, spacing: 9) {
      HStack {
        Label(
          DictationAppModel.localTextTaskTitle(document.taskID),
          systemImage: localTextDocumentSymbol(document.taskID)
        )
        .font(.headline)
        Text("可编辑")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Text(document.createdAt, format: .dateTime.month().day().hour().minute())
          .font(.caption)
          .foregroundStyle(.secondary)
        Button(isEditing ? "收起编辑" : "编辑") {
          if isEditing {
            editingHistoryDocuments.remove(document.id)
          } else {
            editingHistoryDocuments.insert(document.id)
          }
        }
        .accessibilityIdentifier("bestASR.history.document.edit.\(document.id)")
      }

      if isEditing {
        TextEditor(
          text: Binding(
            get: {
              model.history.documentTextDrafts[
                document.id,
                default: document.result.outputText
              ]
            },
            set: { model.history.documentTextDrafts[document.id] = $0 }
          )
        )
        .focused($historyFocusedField, equals: .document)
        .frame(minHeight: 62)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(Color(nsColor: .separatorColor))
        )
        .accessibilityIdentifier("bestASR.history.document.editor.\(document.id)")
      } else if let body = MemoryDocumentPresentation.distinctBody(
        document.result.outputText,
        itemTexts: document.result.structuredItems.map(\.text)
      ) {
        Text(body)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }

      ForEach(document.result.structuredItems, id: \.itemID) { item in
        HStack(alignment: .top, spacing: 8) {
          if item.kind == .actionItem {
            Button {
              model.toggleHistoryStructuredItemCompletion(item, in: document)
            } label: {
              Image(
                systemName: item.completedAt == nil
                  ? "circle" : "checkmark.circle.fill"
              )
            }
            .buttonStyle(.plain)
            .help(item.completedAt == nil ? "标记完成" : "恢复为未完成")
            .accessibilityLabel(
              "\(item.completedAt == nil ? "标记完成" : "恢复为未完成")：\(item.text)"
            )
          } else {
            Image(
              systemName: item.disposition == .cautious
                ? "exclamationmark.triangle" : "checkmark.circle"
            )
            .foregroundStyle(
              item.disposition == .cautious ? .orange : .secondary
            )
          }
          if let position = model.historySourcePlaybackPosition(
            segmentIDs: item.sourceSegmentIDs
          ) {
            Button(formatPlaybackTime(position)) {
              model.seekHistorySource(segmentIDs: item.sourceSegmentIDs)
            }
            .buttonStyle(.link)
          }
          VStack(alignment: .leading, spacing: 5) {
            if isEditing {
              TextField(
                "内容",
                text: Binding(
                  get: {
                    model.history.structuredItemTextDrafts[
                      item.itemID,
                      default: item.text
                    ]
                  },
                  set: {
                    model.history.structuredItemTextDrafts[item.itemID] = $0
                  }
                )
              )
              .focused($historyFocusedField, equals: .document)
              .strikethrough(item.completedAt != nil)
              if item.kind == .actionItem {
                HStack {
                  TextField(
                    "负责人（原文未说明则留空）",
                    text: Binding(
                      get: {
                        model.history.structuredItemOwnerDrafts[
                          item.itemID,
                          default: item.owner ?? ""
                        ]
                      },
                      set: {
                        model.history.structuredItemOwnerDrafts[item.itemID] = $0
                      }
                    )
                  )
                  .focused($historyFocusedField, equals: .document)
                  TextField(
                    "截止时间（原文未说明则留空）",
                    text: Binding(
                      get: {
                        model.history.structuredItemDueDateDrafts[
                          item.itemID,
                          default: item.dueDateText ?? ""
                        ]
                      },
                      set: {
                        model.history.structuredItemDueDateDrafts[item.itemID] = $0
                      }
                    )
                  )
                  .focused($historyFocusedField, equals: .document)
                }
                .font(.caption)
              }
            } else {
              Text(item.text)
                .strikethrough(item.completedAt != nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
              if let owner = item.owner, !owner.isEmpty {
                Text("负责人：\(owner)").foregroundStyle(.secondary)
              }
              if let due = item.dueDateText, !due.isEmpty {
                Text("截止：\(due)").foregroundStyle(.secondary)
              }
            }
          }
          Spacer()
          if isEditing {
            Button(role: .destructive) {
              pendingStructuredItemDeletion = PendingStructuredItemDeletion(
                item: item,
                document: document
              )
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("删除这条整理项；逐字稿和原音不会删除")
          }
        }
        .font(.caption)
      }

      if isEditing {
        HStack {
          Button("保存编辑为新版本") {
            model.saveHistoryDocumentEdit(document)
          }
          .buttonStyle(.borderedProminent)
          .disabled(model.history.reprocessingInProgress)
          Text("每条整理项都保留来源时间戳；编辑不会改写逐字稿。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
  }

  func saveHistoryTranscriptSegmentEdit(
    transcript: DictationPersistedTranscriptRecord,
    segment: DictationTranscriptSegment
  ) {
    model.saveHistoryTranscriptSegmentEdit(
      transcript: transcript,
      segment: segment,
      replacement: historySegmentEditDraft
    ) { saved in
      guard saved, editingHistorySegmentID == segment.id else { return }
      editingHistorySegmentID = nil
      historySegmentEditDraft = ""
      historyFocusedField = nil
    }
  }

  @ViewBuilder
  var sourceContextDetails: some View {
    if !model.history.selectedHistorySourceContexts.isEmpty {
      GroupBox("来源说明") {
        VStack(alignment: .leading, spacing: 9) {
          Text("这些信息只从本机会议界面读取，不改变录音边界。只有与远端音轨严格对齐的可靠“当前发言人”事件才可映射当前会话姓名；参会者名单不会用于猜测，人工确认始终优先。")
            .font(.caption)
            .foregroundStyle(.secondary)
          ForEach(model.history.selectedHistorySourceContexts) { context in
            HStack(alignment: .top, spacing: 10) {
              Button(
                model.historyPlaybackPosition(
                  forMonotonicNanoseconds: context.monotonicNanoseconds
                ).map(formatPlaybackTime) ?? "—"
              ) {
                model.seekHistoryPlayback(
                  toMonotonicNanoseconds: context.monotonicNanoseconds
                )
              }
              .buttonStyle(.link)
              VStack(alignment: .leading, spacing: 3) {
                Text(context.displayTitle ?? "来源界面更新")
                  .font(.callout.weight(.semibold))
                if !context.participantDisplayNames.isEmpty {
                  Text("参会者：\(context.participantDisplayNames.joined(separator: "、"))")
                    .font(.caption)
                    .textSelection(.enabled)
                }
                if let speaker = context.activeSpeakerDisplayName {
                  Text("当前发言：\(speaker)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
              Text(context.reliability == .reliable ? "明确界面字段" : "辅助说明")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(.top, 4)
      }
      .accessibilityIdentifier("bestASR.history.sourceContexts")
    }
  }

  func historyDateTitle(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "今天" }
    if calendar.isDateInYesterday(date) { return "昨天" }
    let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
    let weekday = ["日", "一", "二", "三", "四", "五", "六"][(parts.weekday ?? 1) - 1]
    let year =
      parts.year == calendar.component(.year, from: Date()) ? "" : "\(parts.year ?? 0) 年 "
    return "\(year)\(parts.month ?? 0) 月 \(parts.day ?? 0) 日 星期\(weekday)"
  }

  func transcriptVersionTitle(_ kind: TranscriptRevisionKind) -> String {
    switch kind {
    case .streaming: "实时草稿"
    case .sentence: "句末整理"
    case .final: "最终识别"
    case .userEdit: "人工校对"
    }
  }

  func historyModeTitle(_ mode: SessionInputMode) -> String {
    switch mode {
    case .dictation: "口述"
    case .roomMicrophone: "线下录音"
    case .systemAudio: "电脑内录"
    case .importedMedia: "文件导入"
    case .userItem: "收进来的内容"
    }
  }

  func historyModeSymbol(_ mode: SessionInputMode) -> String {
    switch mode {
    case .dictation: "waveform"
    case .roomMicrophone: "person.2"
    case .systemAudio: "desktopcomputer"
    case .importedMedia: "doc.badge.arrow.up"
    case .userItem: "tray.and.arrow.down"
    }
  }

  func historySymbol(_ status: DictationHistoryStatus) -> String {
    switch status {
    case .completed: "checkmark.circle"
    case .failed: "exclamationmark.triangle"
    case .processing: "clock"
    case .recovered: "arrow.clockwise.circle"
    }
  }
}

private enum HistoryNotesKind: String, CaseIterable, Identifiable {
  case summary
  case actions
  case chapters
  case decisions

  var id: Self { self }

  var title: String {
    switch self {
    case .summary: "摘要"
    case .actions: "待办"
    case .chapters: "章节"
    case .decisions: "结论"
    }
  }

  var actionIdentifier: String {
    switch self {
    case .summary: "bestASR.history.generateSummary"
    case .actions: "bestASR.history.generateActions"
    case .chapters: "bestASR.history.generateChapters"
    case .decisions: "bestASR.history.generateDecisions"
    }
  }
}

/// Choosing a kind never starts inference. Generation is one explicit action.
private struct HistoryNotesGenerationControls: View {
  let isGenerating: Bool
  let onGenerate: (HistoryNotesKind) -> Void
  @State private var kind = HistoryNotesKind.summary

  var body: some View {
    HStack(spacing: 12) {
      Picker("整理类型", selection: $kind) {
        ForEach(HistoryNotesKind.allCases) { option in
          Text(option.title).tag(option)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(maxWidth: 360)
      .accessibilityIdentifier("bestASR.history.notesKind")
      Button {
        onGenerate(kind)
      } label: {
        HStack(spacing: 6) {
          if isGenerating { ProgressView().controlSize(.small) }
          Text(isGenerating ? "正在整理…" : "生成整理")
        }
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier(kind.actionIdentifier)
      Spacer(minLength: 0)
    }
    .disabled(isGenerating)
  }
}

/// Format selection and exporting are separate, visible steps in the source tab.
private struct HistoryTextExportControls: View {
  let isExporting: Bool
  let onExport: (LocalHistoryExportFormat) -> Void
  @State private var format = LocalHistoryExportFormat.plainText

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("文字与字幕").font(.callout.weight(.medium))
      HStack(spacing: 12) {
        Picker("导出格式", selection: $format) {
          ForEach(LocalHistoryExportFormat.allCases, id: \.rawValue) { option in
            Text(option.displayName).tag(option)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("bestASR.history.exportFormat")
        Button("导出…") { onExport(format) }
          .accessibilityIdentifier("bestASR.history.exportText")
      }
      .disabled(isExporting)
    }
  }
}
