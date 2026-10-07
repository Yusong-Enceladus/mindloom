import BestASRAudioJournal
import BestASRCandidateAdapters
import BestASRDictation
import BestASRDomain
import BestASRFluidRuntime
import BestASRInference
import BestASRPersistence
import BestASRQwenRuntime
import Foundation
import OSLog

// Dictation's word timings, later (ALIGNMENT recommendation 1, adopted
// 2026-10-06; DICTATION_ARCHITECTURE §15.7). A dictation is recognized
// without them so the aligner never sits in memory next to the recognizer;
// each recognizer window is stored as one segment marked pending
// (`DeferredWordAlignment`). Its sentences are timed here, with the aligner
// alone in memory: when the idle timer releases the recognizer (an hour after
// the last dictation, ten minutes after a launch nobody dictated into), when
// memory pressure ends and the recognizer is not in memory, when the user
// opens such a dictation in History and the recognizer is not in memory, or
// when the user exports it (the recognizer is released first). Until then
// the window plays, follows and exports as one sentence.

/// A pending window as one revision holds it. A user's edit copies the
/// window with its ID, its text unchanged or edited; each version is timed
/// against its own text, and a copy with the same text takes the same
/// sentences.
struct DeferredWindowKey: Hashable, Sendable {
  let segmentID: UUID
  let start: UInt64
  let end: UInt64
  let text: String

  init(_ segment: DictationTranscriptSegment) {
    segmentID = segment.id
    start = segment.monotonicStartNanoseconds
    end = segment.monotonicEndNanoseconds
    text = segment.text
  }
}

extension LocalDictationRuntime {
  /// How many revisions one pass takes; the rest wait for the next.
  static let wordAlignmentBatch = 50

  /// Starts timing pending sentences in the background, or joins the pass
  /// that is running; nil when it cannot run now: a dictation in flight or
  /// a press warming the recognizer, memory pressure, no recognizer runtime
  /// to time with, or the recognizer in memory. `sessionID` limits it to one
  /// dictation (History, exports). `releasingRecognizer` (exports): release
  /// a recognizer that is in memory first, so the aligner is alone; the
  /// next press loads it again while the user speaks. Without it, a pass
  /// waits for the recognizer to leave (review 2026-10-07: opening a
  /// dictation in History right after it loaded the aligner next to the
  /// resident recognizer, about 5.1 GB).
  @discardableResult
  func startDeferredWordAlignment(
    sessionID: SessionID? = nil, releasingRecognizer: Bool = false
  ) -> Task<Int, Never>? {
    // Never next to a dictation: the press stops a pass (`warmFinalASRIfIdle`).
    guard memoryPressure == .normal, finalASRWarmupRuntime != nil, finalSpeculation == nil,
      sessionsAwaitingInsertion.isEmpty, finalASRWarmupTask == nil
    else { return nil }
    if let running = wordAlignmentTask { return running }
    guard !recognizerResident || releasingRecognizer else { return nil }
    let releaseFirst = recognizerResident
    let task = Task { [weak self] () -> Int in
      guard let self else { return 0 }
      if releaseFirst {
        guard !Task.isCancelled, await self.releaseIdleModels([.recognizer]) else {
          await self.finishDeferredWordAlignment()
          return 0
        }
      }
      let timed = await self.timeDeferredWords(sessionID: sessionID)
      await self.finishDeferredWordAlignment()
      return timed
    }
    wordAlignmentTask = task
    return task
  }

  /// Times pending sentences now and waits; the number of windows timed.
  /// For History (`releasingRecognizer` false: only when the recognizer is
  /// not in memory) and exports (true).
  func alignDeferredWords(sessionID: SessionID, releasingRecognizer: Bool = false) async -> Int {
    guard
      let task = startDeferredWordAlignment(
        sessionID: sessionID, releasingRecognizer: releasingRecognizer)
    else { return 0 }
    let timed = await task.value
    // A pass for every dictation may have been running; this one's turn.
    guard
      let again = try? await repository.deferredWordAlignmentWork(
        modelArtifactID: QwenASRPinnedArtifact.artifactID, sessionID: sessionID, limit: 1),
      again.contains(where: {
        $0.pendingSegments.contains { !wordAlignmentFailures.contains(DeferredWindowKey($0)) }
      }),
      let retry = startDeferredWordAlignment(
        sessionID: sessionID, releasingRecognizer: releasingRecognizer)
    else { return timed }
    return timed + (await retry.value)
  }

  /// A dictation starts, or memory is short: stop timing, and let the
  /// aligner go once the load or the window in hand is done.
  func stopDeferredWordAlignment() {
    if let task = wordAlignmentTask {
      task.cancel()
    } else if let runtime = finalASRWarmupRuntime {
      // Loaded by something else (a recording's recognition): dictation
      // must not hold it.
      Task { await runtime.releaseAlignment() }
    }
  }

  func finishDeferredWordAlignment() async {
    wordAlignmentTask = nil
    await finalASRWarmupRuntime?.releaseAlignment()
  }

  /// One pass: every pending window of up to `wordAlignmentBatch`
  /// revisions (finished dictations' final transcripts and the user's
  /// edits of them), newest first, until cancelled. Returns the windows
  /// replaced.
  func timeDeferredWords(sessionID: SessionID?) async -> Int {
    guard let runtime = finalASRWarmupRuntime,
      let work = try? await repository.deferredWordAlignmentWork(
        modelArtifactID: QwenASRPinnedArtifact.artifactID, sessionID: sessionID,
        limit: Self.wordAlignmentBatch),
      !work.isEmpty
    else { return 0 }
    let started = ContinuousClock.now
    var timed = 0
    // Sentences of the windows timed in this pass: an edit's unchanged
    // copy of a window takes them without aligning it again.
    var timedWindows: [DeferredWindowKey: [DictationTranscriptSegment]] = [:]
    for item in work {
      guard !Task.isCancelled else { break }
      let pending = item.pendingSegments.filter {
        !wordAlignmentFailures.contains(DeferredWindowKey($0))
      }
      guard !pending.isEmpty else { continue }
      let sessionID = item.transcript.sessionID
      var audio: (windows: [AudioRangeInput], loader: Float32PCMFileLoader)?
      var audioUnavailable = false
      for segment in pending {
        guard !Task.isCancelled else { break }
        let key = DeferredWindowKey(segment)
        do {
          let sentences: [DictationTranscriptSegment]
          if let known = timedWindows[key] {
            sentences = known
          } else {
            if audio == nil, !audioUnavailable {
              audio = await preparedDeferredWordAudio(sessionID: sessionID)
              audioUnavailable = audio == nil
            }
            guard let audio else {
              wordAlignmentFailures.insert(key)
              continue
            }
            let samples = try await Self.samples(
              of: segment, in: audio.windows, loader: audio.loader)
            guard !Task.isCancelled else { break }
            let windowSentences = try await runtime.timeDeferredWindow(
              samples: samples, text: segment.text,
              language: Self.alignmentLanguage(item.transcript.languageHints),
              replacing: segment.id, startNanoseconds: segment.monotonicStartNanoseconds,
              endNanoseconds: segment.monotonicEndNanoseconds)
            guard let clamped = Self.clamp(windowSentences, to: segment) else {
              throw LocalDictationRuntimeError.modelNotReady
            }
            timedWindows[key] = clamped
            sentences = clamped
          }
          if try await repository.replaceDeferredWordAlignmentSegment(
            transcriptID: item.transcript.id, pending: segment, with: sentences)
          {
            timed += 1
          }
        } catch is CancellationError {
          break
        } catch let error as InferenceEngineError where error.category == .cancelled {
          break
        } catch {
          wordAlignmentFailures.insert(key)
        }
      }
      if let audio {
        await journal.discardInferenceAudio(sessionID: sessionID, preparedAudio: audio.windows)
      }
    }
    let elapsed = ContinuousClock.now - started
    localDictationRuntimeLogger.notice(
      "word timings: windows=\(timed, privacy: .public) failed=\(self.wordAlignmentFailures.count, privacy: .public) ms=\(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000, privacy: .public)"
    )
    return timed
  }

  /// The recording as it is now (an idle pass may have rewritten it at
  /// 16 kHz since; the times stay), cut the way recognition cuts it; nil
  /// when it cannot be read.
  func preparedDeferredWordAudio(
    sessionID: SessionID
  ) async -> (windows: [AudioRangeInput], loader: Float32PCMFileLoader)? {
    guard
      let recovery = try? await journal.recover(sessionID: sessionID),
      recovery.state == .sealed, !recovery.ranges.isEmpty,
      let windows = try? await journal.prepareInferenceAudio(
        sessionID: sessionID, sourceAudio: recovery.ranges)
    else { return nil }
    guard
      let loader = try? Float32PCMFileLoader(
        rootDirectory: journal.assetRootURL,
        maximumSamples: QwenASRPinnedArtifact.maximumSamples)
    else {
      await journal.discardInferenceAudio(sessionID: sessionID, preparedAudio: windows)
      return nil
    }
    return (windows, loader)
  }

  /// The 16 kHz samples of a pending segment's time range, cut from the
  /// inference windows that cover it (one, unless the recording was
  /// rewritten and cut differently since).
  nonisolated static func samples(
    of segment: DictationTranscriptSegment, in windows: [AudioRangeInput],
    loader: some SenseVoiceAudioSampleLoading
  ) async throws -> [Float] {
    let covering = windows.filter {
      $0.monotonicStartNanoseconds < segment.monotonicEndNanoseconds
        && $0.monotonicEndNanoseconds > segment.monotonicStartNanoseconds
        && $0.monotonicEndNanoseconds > $0.monotonicStartNanoseconds
    }.sorted { $0.monotonicStartNanoseconds < $1.monotonicStartNanoseconds }
    var samples: [Float] = []
    for window in covering {
      let windowSamples = try await loader.loadSamples(for: window)
      let span = Double(window.monotonicEndNanoseconds - window.monotonicStartNanoseconds)
      func index(_ time: UInt64) -> Int {
        let offset = Double(time - window.monotonicStartNanoseconds) / span
        return min(
          windowSamples.count, max(0, Int((offset * Double(windowSamples.count)).rounded())))
      }
      let from = index(max(window.monotonicStartNanoseconds, segment.monotonicStartNanoseconds))
      let to = index(min(window.monotonicEndNanoseconds, segment.monotonicEndNanoseconds))
      if to > from { samples.append(contentsOf: windowSamples[from..<to]) }
    }
    guard !samples.isEmpty, samples.count <= QwenASRPinnedArtifact.maximumSamples else {
      throw LocalDictationRuntimeError.modelNotReady
    }
    return samples
  }

  /// Sentences timed on the window, kept inside the stored segment (which
  /// may be the window clipped to the recorded audio) and spanning all of
  /// it: the first starts where the window starts and the last ends where
  /// it ends, so the transcript's time span, which a shared space's times
  /// count from (`spaceShareTimeBase`), does not move (review 2026-10-07).
  /// Nil when one would be left with no time of its own.
  nonisolated static func clamp(
    _ sentences: [CandidateRuntimeSegment], to segment: DictationTranscriptSegment
  ) -> [DictationTranscriptSegment]? {
    var result: [DictationTranscriptSegment] = []
    for (index, sentence) in sentences.enumerated() {
      let start =
        index == 0
        ? segment.monotonicStartNanoseconds
        : max(segment.monotonicStartNanoseconds, sentence.monotonicStartNanoseconds)
      let end =
        index == sentences.count - 1
        ? segment.monotonicEndNanoseconds
        : min(segment.monotonicEndNanoseconds, sentence.monotonicEndNanoseconds)
      guard start < end, start >= (result.last?.monotonicEndNanoseconds ?? 0) else {
        return nil
      }
      result.append(
        DictationTranscriptSegment(
          id: sentence.segmentID, monotonicStartNanoseconds: start,
          monotonicEndNanoseconds: end, text: sentence.text,
          confidence: sentence.confidence))
    }
    return result.isEmpty ? nil : result
  }

  /// The aligner reads Chinese wherever the text has Chinese characters;
  /// otherwise it needs the language, which the transcript's hints give.
  nonisolated static func alignmentLanguage(_ hints: [String]) -> String? {
    hints == ["en-US"] ? "English" : nil
  }
}
