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



// MemorySearch: moved out of DictationAppModel.swift without change; see
// DICTATION_ARCHITECTURE.md §13.5.
extension DictationAppModel {
  func searchMemory() {
    startMemorySearch(openFirstResult: false)
  }

  func openFirstMemorySearchResult() {
    startMemorySearch(openFirstResult: true)
  }

  func openMemorySearchHistoryItem(_ item: DictationHistoryItem) {
    openHistoryItem(item, locating: memorySearch.searchQuery)
  }

  func openMemorySearchPerson(_ summary: PersonSummary) {
    beginEditingPerson(summary)
    requestedNavigationSectionID = "people"
  }

  func openMemorySearchEvent(_ summary: EventSummary) {
    beginEditingEvent(summary)
    requestedNavigationSectionID = "events"
  }

  func startMemorySearch(openFirstResult: Bool) {
    memorySearchTask?.cancel()
    let query = memorySearch.searchQuery.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let requestID = UUID()
    memorySearchRequestID = requestID
    guard !query.isEmpty else {
      memorySearch.searchInProgress = false
      memorySearch.searchHistoryItems = []
      memorySearch.searchPersonSummaries = []
      memorySearch.searchEventSummaries = []
      memorySearch.searchStatusMessage = "搜索逐字稿、整理、人物、事件和来源"
      return
    }
    if fixtureMode {
      publishFixtureMemorySearch(query: query)
      if openFirstResult { openPublishedMemorySearchResult(query: query) }
      return
    }
    guard let repository else {
      memorySearch.searchStatusMessage = "本机记忆暂时无法读取"
      return
    }
    memorySearch.searchInProgress = true
    memorySearch.searchStatusMessage = "正在这台 Mac 上搜索…"
    memorySearchTask = Task { [weak self] in
      guard let self else { return }
      do {
        if !openFirstResult {
          try await Task<Never, Never>.sleep(nanoseconds: 180_000_000)
        }
        try Task.checkCancellation()
        async let history = repository.searchHistory(
          query: query,
          mode: nil,
          status: nil,
          limit: 12
        )
        async let events = repository.eventSummaries(query: query)
        async let people = repository.personSummaries()
        let (historyResults, eventResults, peopleResults) = try await (
          history, events, people
        )
        guard memorySearchRequestID == requestID, !Task.isCancelled else {
          return
        }
        memorySearch.searchHistoryItems = historyResults
        memorySearch.searchEventSummaries = Array(eventResults.prefix(6))
        memorySearch.searchPersonSummaries = Array(
          peopleResults.filter {
            Self.personSummary($0, matches: query)
          }.prefix(6)
        )
        finishMemorySearchStatus()
        if openFirstResult { openPublishedMemorySearchResult(query: query) }
      } catch is CancellationError {
        return
      } catch {
        guard memorySearchRequestID == requestID else { return }
        memorySearch.searchInProgress = false
        memorySearch.searchStatusMessage = "本机搜索没有完成；录音和索引没有变化"
      }
    }
  }

  func publishFixtureMemorySearch(query: String) {
    self.memorySearch.searchHistoryItems = history.historyItems.filter { item in
      item.title.localizedCaseInsensitiveContains(query)
        || (item.preferredText ?? "").localizedCaseInsensitiveContains(query)
        || item.personDisplayNames.contains(where: {
          $0.localizedCaseInsensitiveContains(query)
        })
    }
    self.memorySearch.searchPersonSummaries = Array(
      people.personSummaries.filter {
        Self.personSummary($0, matches: query)
      }.prefix(6)
    )
    self.memorySearch.searchEventSummaries = Array(
      events.summaries.filter { summary in
        summary.event.title.localizedCaseInsensitiveContains(query)
          || summary.event.notes.localizedCaseInsensitiveContains(query)
      }.prefix(6)
    )
    finishMemorySearchStatus()
  }

  func openPublishedMemorySearchResult(query: String) {
    let normalized = query.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    if let person = memorySearch.searchPersonSummaries.first(where: {
      ($0.person.displayName ?? "").caseInsensitiveCompare(normalized)
        == .orderedSame
    }) {
      openMemorySearchPerson(person)
    } else if let event = memorySearch.searchEventSummaries.first(where: {
      $0.event.title.caseInsensitiveCompare(normalized) == .orderedSame
    }) {
      openMemorySearchEvent(event)
    } else if let history = memorySearch.searchHistoryItems.first {
      openMemorySearchHistoryItem(history)
    } else if let event = memorySearch.searchEventSummaries.first {
      openMemorySearchEvent(event)
    } else if let person = memorySearch.searchPersonSummaries.first {
      openMemorySearchPerson(person)
    }
  }
}
