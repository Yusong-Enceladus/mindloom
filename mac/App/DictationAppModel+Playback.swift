import AppKit
import BestASRAudioJournal
import BestASRDictation
import BestASRDomain
import BestASRFluidRuntime
import BestASRInference
import BestASRDelivery
import BestASRMLXRuntime
import BestASRMacAudio
import BestASRMacPermissions
import BestASRMacUI
import BestASRModelManager
import BestASRPersistence
import BestASRPortableArchiveProbe
import BestASRProcessing
import BestASRQwenRuntime
import Combine
import CoreGraphics
import CryptoKit
import Foundation
import OSLog
import ServiceManagement
import UniformTypeIdentifiers



// Playback: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  func selectHistoryPlaybackTrack(_ trackID: String) {
    guard playback.playbackTrackIDs.contains(trackID) else { return }
    stopHistoryPlayback(resetSelection: false)
    playback.selectedHistoryPlaybackTrackID = trackID
    playback.playbackStatusMessage = "已切换音轨"
    updateHistoryPlaybackDurationForSelectedTrack()
    loadHistoryWaveform()
  }

  func historyPlaybackTrackTitle(_ trackID: String) -> String {
    switch playback.playbackTrackRoles[trackID] {
    case .importedSource: "导入原文件"
    case .microphoneLocal: "本机麦克风"
    case .roomMicrophone: "会议室麦克风"
    case .systemRemote: "系统 / 对方声音"
    case nil: "原音轨"
    }
  }

  func toggleHistoryPlayback() {
    guard !playback.playbackOperationInProgress else { return }
    guard let sessionID = history.selectedHistorySessionID,
      let assetRootURL = historyPlaybackAssetRootURL,
      let descriptor = historyPlaybackTrackDescriptors[
        playback.selectedHistoryPlaybackTrackID
      ]
    else {
      playback.playbackStatusMessage = "这条记录还没有可播放的本地音频"
      return
    }
    let ranges = selectedHistoryPlaybackRanges()
    guard !ranges.isEmpty else {
      playback.playbackStatusMessage = "所选音轨没有可播放的本地音频"
      return
    }
    playback.playbackOperationInProgress = true
    playback.playbackStatusMessage =
      playback.playbackIsPlaying
      ? "正在暂停…" : "正在准备本机原音…"
    let playbackGeneration = historyPlaybackGeneration
    let trackID = playback.selectedHistoryPlaybackTrackID
    enqueueHistoryPlaybackControl { model in
      defer { model.playback.playbackOperationInProgress = false }
      guard model.historyPlaybackGeneration == playbackGeneration,
        model.history.selectedHistorySessionID == sessionID,
        model.playback.selectedHistoryPlaybackTrackID == trackID
      else { return }
      do {
        if model.playback.playbackIsPlaying {
          await model.historyAudioPlayer.pause()
          model.playback.playbackIsPlaying = false
          model.playback.playbackStatusMessage = "已暂停"
          return
        }
        if model.loadedPlaybackSessionID != sessionID
          || model.loadedPlaybackTrackID != trackID
        {
          model.playback.playbackDuration = try await model.historyAudioPlayer.load(
            ranges: ranges,
            descriptor: descriptor,
            assetRoot: assetRootURL,
            positionSeconds: model.playback.playbackPosition
          )
          model.loadedPlaybackSessionID = sessionID
          model.loadedPlaybackTrackID = trackID
        }
        try await model.historyAudioPlayer.play()
        model.playback.playbackIsPlaying = true
        model.playback.playbackStatusMessage = "正在播放本地原音"
        model.beginHistoryPlaybackPolling(
          generation: playbackGeneration,
          sessionID: sessionID,
          trackID: trackID
        )
      } catch let failure as LocalSessionAudioPlayerError {
        model.playback.playbackIsPlaying = false
        model.playback.playbackStatusMessage = Self.historyPlaybackFailureMessage(failure)
      } catch {
        model.playback.playbackIsPlaying = false
        model.playback.playbackStatusMessage = "无法启动原音播放；请检查当前声音输出设备"
      }
    }
  }

  func seekHistoryPlayback(to seconds: Double) {
    // A seek of the user's own ends a stretch the memory pages were playing.
    playback.stopAt = nil
    history.locatedSegmentID = nil
    playback.playbackPosition = min(max(0, seconds), playback.playbackDuration)
    let requestedPosition = playback.playbackPosition
    historyPlaybackSeekRequestID = UUID()
    let seekRequestID = historyPlaybackSeekRequestID
    let playbackGeneration = historyPlaybackGeneration
    let sessionID = history.selectedHistorySessionID
    let trackID = playback.selectedHistoryPlaybackTrackID
    enqueueHistoryPlaybackControl { model in
      guard model.historyPlaybackGeneration == playbackGeneration,
        model.historyPlaybackSeekRequestID == seekRequestID,
        model.history.selectedHistorySessionID == sessionID,
        model.playback.selectedHistoryPlaybackTrackID == trackID,
        model.loadedPlaybackSessionID == sessionID,
        model.loadedPlaybackTrackID == trackID
      else { return }
      do {
        try await model.historyAudioPlayer.seek(to: requestedPosition)
        let state = await model.historyAudioPlayer.state()
        model.playback.playbackPosition = state.position
        model.playback.playbackIsPlaying = state.isPlaying
        if state.isPlaying, let sessionID {
          model.beginHistoryPlaybackPolling(
            generation: playbackGeneration,
            sessionID: sessionID,
            trackID: trackID
          )
        }
      } catch {
        model.playback.playbackStatusMessage = "无法跳转到这个时间点"
      }
    }
  }

  func seekHistoryPlayback(toMonotonicNanoseconds timestamp: UInt64) {
    if let position = historyPlaybackPosition(
      forMonotonicNanoseconds: timestamp
    ) {
      seekHistoryPlayback(to: position)
    }
  }

  func playHistoryPlayback(toMonotonicNanoseconds timestamp: UInt64) {
    seekHistoryPlayback(toMonotonicNanoseconds: timestamp)
    if !playback.playbackIsPlaying { toggleHistoryPlayback() }
  }

  func locateHistoryTranscriptSegment(_ segment: DictationTranscriptSegment) {
    guard
      historyPlaybackPosition(
        forMonotonicNanoseconds: segment.monotonicStartNanoseconds
      ) != nil
    else {
      history.locatedSegmentID = segment.id
      history.detailStatusMessage = "已选中这段逐字稿；当前原音没有可定位的时间范围"
      return
    }
    seekHistoryPlayback(
      toMonotonicNanoseconds: segment.monotonicStartNanoseconds
    )
    history.locatedSegmentID = segment.id
    history.detailStatusMessage = "已定位到这段逐字稿对应的原音"
  }

  func playHistoryTranscriptSegment(_ segment: DictationTranscriptSegment) {
    guard
      historyPlaybackPosition(
        forMonotonicNanoseconds: segment.monotonicStartNanoseconds
      ) != nil
    else {
      history.locatedSegmentID = segment.id
      history.detailStatusMessage = "这段逐字稿没有可播放的原音时间范围"
      return
    }
    playHistoryPlayback(
      toMonotonicNanoseconds: segment.monotonicStartNanoseconds
    )
    history.locatedSegmentID = segment.id
    history.detailStatusMessage = "已定位到这段逐字稿对应的原音"
  }

  func historyPlaybackPosition(
    forMonotonicNanoseconds timestamp: UInt64
  ) -> Double? {
    let ranges = selectedHistoryPlaybackRanges()
    guard !ranges.isEmpty else { return nil }
    var position = 0.0
    for range in ranges {
      if timestamp >= range.monotonicStartNanoseconds,
        timestamp < range.monotonicEndNanoseconds
      {
        position +=
          Double(timestamp - range.monotonicStartNanoseconds)
          / 1_000_000_000
        return position
      }
      position +=
        Double(
          range.monotonicEndNanoseconds - range.monotonicStartNanoseconds
        ) / 1_000_000_000
    }
    return nil
  }

  func selectedHistoryPlaybackRanges() -> [AudioRangeInput] {
    historyPlaybackRangesByTrack[playback.selectedHistoryPlaybackTrackID]?
      .sorted { $0.monotonicStartNanoseconds < $1.monotonicStartNanoseconds }
      ?? []
  }

  static func historyPlaybackFailureMessage(
    _ failure: LocalSessionAudioPlayerError
  ) -> String {
    switch failure {
    case .sourceMissing:
      "原音文件缺失或校验失败；记录文字仍然保留"
    case .unsupportedFormat:
      "这条原音的格式暂时无法播放；源文件没有被修改"
    case .invalidAudio:
      "原音数据无法解码；源文件没有被修改"
    }
  }

  func updateHistoryPlaybackDurationForSelectedTrack() {
    playback.playbackDuration = selectedHistoryPlaybackRanges().reduce(0) {
      $0 + Double(
        $1.monotonicEndNanoseconds - $1.monotonicStartNanoseconds
      ) / 1_000_000_000
    }
    playback.playbackPosition = min(playback.playbackPosition, playback.playbackDuration)
    export.exportSelectionStart = 0
    export.exportSelectionEnd = playback.playbackDuration
  }

  func historySourcePlaybackPosition(
    segmentIDs: [UUID]
  ) -> Double? {
    let identifiers = Set(segmentIDs)
    guard
      let segment = history.selectedHistoryTranscripts.reversed()
        .flatMap(\.segments)
        .first(where: { identifiers.contains($0.id) })
    else { return nil }
    return historyPlaybackPosition(
      forMonotonicNanoseconds: segment.monotonicStartNanoseconds
    )
  }

  func seekHistorySource(segmentIDs: [UUID]) {
    let identifiers = Set(segmentIDs)
    guard
      let segment = history.selectedHistoryTranscripts.reversed()
        .flatMap(\.segments)
        .first(where: { identifiers.contains($0.id) })
    else {
      history.detailStatusMessage = "这条整理项没有可定位的来源时间戳"
      return
    }
    locateHistoryTranscriptSegment(segment)
  }

  func beginHistoryPlaybackPolling(
    generation: UUID,
    sessionID: SessionID,
    trackID: String
  ) {
    historyPlaybackTask?.cancel()
    historyPlaybackTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        let state = await historyAudioPlayer.state()
        guard historyPlaybackGeneration == generation,
          history.selectedHistorySessionID == sessionID,
          playback.selectedHistoryPlaybackTrackID == trackID,
          loadedPlaybackSessionID == sessionID,
          loadedPlaybackTrackID == trackID
        else { return }
        playback.playbackPosition = state.position
        playback.playbackDuration = state.duration
        playback.playbackIsPlaying = state.isPlaying
        // Playing one stretch (a voice to confirm): pause at its end.
        if let stop = playback.stopAt, stop.sessionID == sessionID, state.isPlaying,
          state.position >= stop.position
        {
          playback.stopAt = nil
          toggleHistoryPlayback()
        }
        if let failure = state.failure {
          playback.playbackStatusMessage = Self.historyPlaybackFailureMessage(failure)
        } else if !state.isPlaying, state.position >= state.duration,
          state.duration > 0
        {
          playback.playbackStatusMessage = "原音播放完毕"
        }
        if !state.isPlaying { return }
        try? await Task.sleep(for: .milliseconds(200))
      }
    }
  }

  func stopHistoryPlayback(resetSelection: Bool = true) {
    historyPlaybackGeneration = UUID()
    historyPlaybackSeekRequestID = UUID()
    historyPlaybackTask?.cancel()
    historyPlaybackTask = nil
    enqueueHistoryPlaybackControl { model in
      await model.historyAudioPlayer.stop()
    }
    playback.playbackPosition = 0
    playback.playbackDuration = 0
    export.exportSelectionStart = 0
    export.exportSelectionEnd = 0
    playback.playbackIsPlaying = false
    playback.playbackOperationInProgress = false
    loadedPlaybackSessionID = nil
    loadedPlaybackTrackID = ""
    historyWaveformTask?.cancel()
    historyWaveformTask = nil
    playback.waveformSamples = []
    if resetSelection {
      historyPlaybackAssetRootURL = nil
      playback.selectedHistoryPlaybackTrackID = ""
      playback.playbackTrackIDs = []
      playback.playbackTrackRoles = [:]
      historyPlaybackTrackDescriptors = [:]
      historyPlaybackRangesByTrack = [:]
    }
    if resetSelection { playback.playbackStatusMessage = "" }
  }

  /// AVAudioEngine commands must observe the same order as UI commands. A
  /// detached stop from an old selection can otherwise arrive after a new
  /// track has loaded and silently stop the new playback.
  func enqueueHistoryPlaybackControl(
    _ operation: @escaping @MainActor (DictationAppModel) async -> Void
  ) {
    let previous = historyPlaybackControlTask
    historyPlaybackControlTask = Task { @MainActor [weak self] in
      await previous?.value
      guard let self else { return }
      await operation(self)
    }
  }

  func loadHistoryWaveform() {
    historyWaveformTask?.cancel()
    playback.waveformSamples = []
    guard let assetRootURL = historyPlaybackAssetRootURL,
      let descriptor = historyPlaybackTrackDescriptors[
        playback.selectedHistoryPlaybackTrackID
      ]
    else { return }
    let ranges = selectedHistoryPlaybackRanges()
    guard !ranges.isEmpty else { return }
    let generation = historyPlaybackGeneration
    let sessionID = history.selectedHistorySessionID
    let trackID = playback.selectedHistoryPlaybackTrackID
    historyWaveformTask = Task { [weak self] in
      guard let self else { return }
      do {
        let samples = try await historyWaveformSampler.sample(
          ranges: ranges,
          descriptor: descriptor,
          assetRoot: assetRootURL
        )
        guard !Task.isCancelled else { return }
        guard historyPlaybackGeneration == generation,
          history.selectedHistorySessionID == sessionID,
          playback.selectedHistoryPlaybackTrackID == trackID
        else { return }
        playback.waveformSamples = samples
        playback.playbackStatusMessage =
          samples.isEmpty
          ? "原音可播放，但波形暂时无法显示"
          : "本机原音和波形已就绪"
      } catch {
        playback.playbackStatusMessage = "波形无法读取；原始音频仍保留"
      }
    }
  }

  /// Plays a record's retained source audio from the history list without
  /// leaving the list; a second press pauses.
  func playHistoryItem(_ item: DictationHistoryItem) {
    playback.stopAt = nil
    if history.selectedHistorySessionID == item.sessionID {
      // While its tracks are still loading, the earlier press starts playback.
      if !playback.playbackTrackIDs.isEmpty { toggleHistoryPlayback() }
      return
    }
    beginHistoryNavigation(item, returningTo: nil, presentingDetail: false)
    Task { [weak self] in
      guard let self else { return }
      await refreshSelectedSpeakerDetails(sessionID: item.sessionID)
      guard history.selectedHistorySessionID == item.sessionID, !playback.playbackTrackIDs.isEmpty
      else { return }
      toggleHistoryPlayback()
    }
  }

  func mutateHistoryPlaybackFixtureSpeaker(
    _ speakerID: SessionSpeakerID,
    speaker transformSpeaker: (SessionSpeakerSummary) -> SessionSpeakerSummary,
    occurrence transformOccurrence: (SpeakerOccurrenceSummary)
      -> SpeakerOccurrenceSummary
  ) {
    historyPlaybackFixturePersonUndoStack.append(
      (people.selectedSessionSpeakers, selectedSessionOccurrences, people.personSummaries)
    )
    people.selectedSessionSpeakers = people.selectedSessionSpeakers.map {
      $0.id == speakerID ? transformSpeaker($0) : $0
    }
    selectedSessionOccurrences = selectedSessionOccurrences.map {
      $0.sessionSpeakerID == speakerID ? transformOccurrence($0) : $0
    }
    if var fixture = historyPlaybackUIFixture {
      fixture.speakers = people.selectedSessionSpeakers
      fixture.occurrences = selectedSessionOccurrences
      historyPlaybackUIFixture = fixture
      people.personReviewCandidates = Self.personReviewCandidates(from: fixture)
    }
  }

  func applyHistoryPlaybackUIFixture(
    _ fixture: HistoryPlaybackUIFixture
  ) {
    guard history.selectedHistorySessionID == fixture.sessionID else { return }
    people.selectedSessionSpeakers = fixture.speakers
    selectedSessionOccurrences = fixture.occurrences
    people.personSummaries = Self.browsablePersonSummaries(fixture.people)
    people.personReviewCandidates = Self.personReviewCandidates(from: fixture)
    history.selectedHistoryTranscripts = [fixture.transcript]
    history.selectedHistoryDocuments = []
    history.selectedHistorySourceAssets = []
    history.selectedHistoryTimelineEvents = []
    history.selectedHistorySourceContexts = []
    history.transcriptEditDraft = fixture.transcript.content
    historyTranscriptEditSessionID = fixture.sessionID
    historyPlaybackAssetRootURL = fixture.assetRootURL
    let trackID = fixture.descriptor.id.rawValue.uuidString
    playback.playbackTrackRoles = [trackID: fixture.descriptor.role]
    historyPlaybackTrackDescriptors = [trackID: fixture.descriptor]
    historyPlaybackRangesByTrack = [trackID: fixture.ranges]
    playback.playbackTrackIDs = [trackID]
    playback.selectedHistoryPlaybackTrackID = trackID
    updateHistoryPlaybackDurationForSelectedTrack()
    loadHistoryWaveform()
    playback.playbackStatusMessage = "本机原音已就绪"
    people.speakerIdentityStatusMessage = "人物关系与原音均使用本机合成测试数据"
  }

  nonisolated static func historyPlaybackTrackPriority(
    _ role: SourceTrackRole?
  ) -> Int {
    switch role {
    case .systemRemote: 0
    case .importedSource: 1
    case .roomMicrophone: 2
    case .microphoneLocal: 3
    case nil: 4
    }
  }

  static func makeHistoryPlaybackUIFixture() throws
    -> HistoryPlaybackUIFixture
  {
    let sessionID = SessionID(
      UUID(uuidString: "41000000-0000-4000-8000-000000000001")!
    )
    let trackID = TrackID(
      UUID(uuidString: "42000000-0000-4000-8000-000000000001")!
    )
    let sampleRate: UInt32 = 44_100
    let durationSeconds = 32
    let frameCount = Int(sampleRate) * durationSeconds
    var pcm = Data(count: frameCount * MemoryLayout<UInt32>.size)
    pcm.withUnsafeMutableBytes { rawBuffer in
      let samples = rawBuffer.bindMemory(to: UInt32.self)
      for frame in 0..<frameCount {
        let time = Double(frame) / Double(sampleRate)
        let frequency = time < 10 ? 220.0 : time < 20 ? 330.0 : 440.0
        let envelope = 0.18 + 0.06 * sin(2 * .pi * time / 4)
        let sample = Float(sin(2 * .pi * frequency * time) * envelope)
        samples[frame] = sample.bitPattern.littleEndian
      }
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "bestASR-history-playback-ui-fixture",
      isDirectory: true
    )
    if FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    let assetReference = "history-playback-fixture.f32le.pcm"
    try pcm.write(
      to: root.appendingPathComponent(assetReference),
      options: .atomic
    )
    let digest = SHA256.hash(data: pcm)
      .map { String(format: "%02x", $0) }
      .joined()
    let monotonicStart: UInt64 = 1_000_000_000
    let monotonicEnd = monotonicStart + UInt64(durationSeconds) * 1_000_000_000
    let range = AudioRangeInput(
      sourceID: sessionID.rawValue,
      trackID: trackID.rawValue,
      assetReference: assetReference,
      contentDigest: digest,
      monotonicStartNanoseconds: monotonicStart,
      monotonicEndNanoseconds: monotonicEnd,
      sampleRateHertz: sampleRate,
      channelCount: 1
    )
    let descriptor = CaptureTrackDescriptor(
      id: trackID,
      role: .microphoneLocal,
      deviceUID: "bestasr-history-playback-ui-fixture",
      sampleRateHertz: sampleRate,
      channelCount: 1,
      encoding: .float32LittleEndian,
      interleaved: true
    )
    let segments = [
      DictationTranscriptSegment(
        id: UUID(uuidString: "43000000-0000-4000-8000-000000000001")!,
        monotonicStartNanoseconds: monotonicStart,
        monotonicEndNanoseconds: monotonicStart + 10_000_000_000,
        text: "第一段本地播放测试逐字稿。",
        confidence: 0.98
      ),
      DictationTranscriptSegment(
        id: UUID(uuidString: "43000000-0000-4000-8000-000000000002")!,
        monotonicStartNanoseconds: monotonicStart + 10_000_000_000,
        monotonicEndNanoseconds: monotonicStart + 20_000_000_000,
        text: "第二段用于验证播放进度和前后跳转。",
        confidence: 0.97
      ),
      DictationTranscriptSegment(
        id: UUID(uuidString: "43000000-0000-4000-8000-000000000003")!,
        monotonicStartNanoseconds: monotonicStart + 20_000_000_000,
        monotonicEndNanoseconds: monotonicEnd,
        text: "第三段用于验证点击逐字稿时跳到原音。",
        confidence: 0.96
      ),
    ]
    let transcript = DictationPersistedTranscriptRecord(
      id: TranscriptRevisionID(
        UUID(uuidString: "44000000-0000-4000-8000-000000000001")!
      ),
      sessionID: sessionID,
      inputRevision: 8,
      parentID: nil,
      kind: .final,
      content: TranscriptTextJoiner.join(segments.map(\.text)),
      modelArtifactID: "bestasr-history-playback-ui-fixture-v1",
      configHash: nil,
      languageHints: ["zh"],
      audioRanges: [range],
      segments: segments,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let candidatePersonID = PersonID(
      UUID(uuidString: "45000000-0000-4000-8000-000000000001")!
    )
    let confirmedPersonID = PersonID(
      UUID(uuidString: "45000000-0000-4000-8000-000000000002")!
    )
    let firstSpeakerID = SessionSpeakerID(
      UUID(uuidString: "46000000-0000-4000-8000-000000000001")!
    )
    let secondSpeakerID = SessionSpeakerID(
      UUID(uuidString: "46000000-0000-4000-8000-000000000002")!
    )
    let fixtureDate = Date(timeIntervalSince1970: 1_700_000_000)
    let revision = try Revision(1)
    let candidatePerson = PersonSummary(
      person: Person(
        id: candidatePersonID,
        revision: revision,
        displayName: "王芳",
        aliases: [],
        createdAt: fixtureDate,
        updatedAt: fixtureDate
      ),
      occurrenceCount: 2,
      embeddingCount: 1,
      sessionCount: 1,
      speechDurationNanoseconds: 22_000_000_000,
      latestOccurrenceAt: fixtureDate
    )
    let confirmedPerson = PersonSummary(
      person: Person(
        id: confirmedPersonID,
        revision: revision,
        displayName: "李华",
        aliases: [],
        createdAt: fixtureDate,
        updatedAt: fixtureDate
      ),
      occurrenceCount: 1,
      embeddingCount: 1,
      sessionCount: 1,
      speechDurationNanoseconds: 10_000_000_000,
      latestOccurrenceAt: fixtureDate
    )
    let speakers = [
      SessionSpeakerSummary(
        id: firstSpeakerID,
        stableOrdinal: 1,
        personID: candidatePersonID,
        displayName: "王芳",
        associationStatus: .candidate,
        confidence: try Confidence(0.74),
        speechDurationNanoseconds: 22_000_000_000,
        occurrenceCount: 2
      ),
      SessionSpeakerSummary(
        id: secondSpeakerID,
        stableOrdinal: 2,
        personID: confirmedPersonID,
        displayName: "李华",
        associationStatus: .userConfirmed,
        confidence: try Confidence(1),
        speechDurationNanoseconds: 10_000_000_000,
        occurrenceCount: 1
      ),
    ]
    let occurrences = [
      SpeakerOccurrenceSummary(
        id: SpeakerOccurrenceID(
          UUID(uuidString: "47000000-0000-4000-8000-000000000001")!
        ),
        sessionID: sessionID,
        sessionSpeakerID: firstSpeakerID,
        stableOrdinal: 1,
        monotonicStartNanoseconds: segments[0].monotonicStartNanoseconds,
        monotonicEndNanoseconds: segments[0].monotonicEndNanoseconds,
        personID: candidatePersonID,
        personDisplayName: "王芳",
        associationStatus: .candidate
      ),
      SpeakerOccurrenceSummary(
        id: SpeakerOccurrenceID(
          UUID(uuidString: "47000000-0000-4000-8000-000000000002")!
        ),
        sessionID: sessionID,
        sessionSpeakerID: secondSpeakerID,
        stableOrdinal: 2,
        monotonicStartNanoseconds: segments[1].monotonicStartNanoseconds,
        monotonicEndNanoseconds: segments[1].monotonicEndNanoseconds,
        personID: confirmedPersonID,
        personDisplayName: "李华",
        associationStatus: .userConfirmed
      ),
      SpeakerOccurrenceSummary(
        id: SpeakerOccurrenceID(
          UUID(uuidString: "47000000-0000-4000-8000-000000000003")!
        ),
        sessionID: sessionID,
        sessionSpeakerID: firstSpeakerID,
        stableOrdinal: 1,
        monotonicStartNanoseconds: segments[2].monotonicStartNanoseconds,
        monotonicEndNanoseconds: segments[2].monotonicEndNanoseconds,
        personID: candidatePersonID,
        personDisplayName: "王芳",
        associationStatus: .candidate
      ),
    ]
    return HistoryPlaybackUIFixture(
      sessionID: sessionID,
      assetRootURL: root,
      descriptor: descriptor,
      ranges: [range],
      transcript: transcript,
      speakers: speakers,
      occurrences: occurrences,
      people: [candidatePerson, confirmedPerson]
    )
  }
}
