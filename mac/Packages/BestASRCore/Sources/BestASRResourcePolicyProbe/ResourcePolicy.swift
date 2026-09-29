import Foundation

public enum ResourceWorkClass: String, Codable, CaseIterable, Sendable {
  case capture
  case finalASR = "final-asr"
  case journal
  case liveASR = "live-asr"
  case localText = "local-text"
  case speaker

  public var priorityRank: Int {
    switch self {
    case .capture:
      return 0
    case .journal:
      return 1
    case .liveASR:
      return 2
    case .finalASR:
      return 3
    case .speaker, .localText:
      return 4
    }
  }
}

public enum ResourceMemoryPressure: String, Codable, Sendable {
  case critical
  case normal
  case warning
}

public enum ResourceThermalPressure: String, Codable, Sendable {
  case critical
  case fair
  case nominal
  case serious
}

public struct ResourcePressureSnapshot: Codable, Equatable, Sendable {
  public let snapshotID: UUID
  public let memoryPressure: ResourceMemoryPressure
  public let thermalPressure: ResourceThermalPressure
  public let inferenceBacklog: Int
  public let inferenceBacklogCapacity: Int
  public let recordingActive: Bool

  public init(
    snapshotID: UUID,
    memoryPressure: ResourceMemoryPressure,
    thermalPressure: ResourceThermalPressure,
    inferenceBacklog: Int,
    inferenceBacklogCapacity: Int,
    recordingActive: Bool
  ) {
    self.snapshotID = snapshotID
    self.memoryPressure = memoryPressure
    self.thermalPressure = thermalPressure
    self.inferenceBacklog = inferenceBacklog
    self.inferenceBacklogCapacity = inferenceBacklogCapacity
    self.recordingActive = recordingActive
  }
}

public enum ResourceDirectiveAction: String, Codable, Sendable {
  case deferDurably = "defer-durably"
  case run
  case throttle
  case unloadAndDefer = "unload-and-defer"
}

public struct ResourceWorkDirective: Codable, Equatable, Sendable {
  public let workClass: ResourceWorkClass
  public let priorityRank: Int
  public let action: ResourceDirectiveAction
  public let reasonCodes: [String]

  public init(
    workClass: ResourceWorkClass,
    priorityRank: Int,
    action: ResourceDirectiveAction,
    reasonCodes: [String]
  ) {
    self.workClass = workClass
    self.priorityRank = priorityRank
    self.action = action
    self.reasonCodes = reasonCodes
  }
}

public enum ResourcePolicyState: String, Codable, Sendable {
  case degradedLive = "degraded-live"
  case normal
}

public enum ResourcePolicyTransition: String, Codable, Sendable {
  case enteredDegraded = "entered-degraded"
  case noChange = "no-change"
  case recovered
  case remainedDegraded = "remained-degraded"
}

public struct ResourcePolicyDecision: Codable, Equatable, Sendable {
  public let snapshotID: UUID
  public let state: ResourcePolicyState
  public let transition: ResourcePolicyTransition
  public let directives: [ResourceWorkDirective]
  public let observableReasonCodes: [String]

  public init(
    snapshotID: UUID,
    state: ResourcePolicyState,
    transition: ResourcePolicyTransition,
    directives: [ResourceWorkDirective],
    observableReasonCodes: [String]
  ) {
    self.snapshotID = snapshotID
    self.state = state
    self.transition = transition
    self.directives = directives
    self.observableReasonCodes = observableReasonCodes
  }

  public func directive(for workClass: ResourceWorkClass) -> ResourceWorkDirective? {
    directives.first { $0.workClass == workClass }
  }
}

public enum ResourcePolicyError: Error, Equatable, Sendable {
  case invalidBacklog
}

public actor ResourcePolicyController {
  private var state = ResourcePolicyState.normal

  public init() {}

  public func evaluate(
    _ snapshot: ResourcePressureSnapshot
  ) throws -> ResourcePolicyDecision {
    guard
      snapshot.inferenceBacklog >= 0,
      snapshot.inferenceBacklogCapacity > 0,
      snapshot.inferenceBacklog <= snapshot.inferenceBacklogCapacity
    else {
      throw ResourcePolicyError.invalidBacklog
    }

    let reasons = reasonCodes(snapshot)
    let degraded = !reasons.isEmpty
    let nextState: ResourcePolicyState = degraded ? .degradedLive : .normal
    let transition: ResourcePolicyTransition
    switch (state, nextState) {
    case (.normal, .normal):
      transition = .noChange
    case (.normal, .degradedLive):
      transition = .enteredDegraded
    case (.degradedLive, .degradedLive):
      transition = .remainedDegraded
    case (.degradedLive, .normal):
      transition = .recovered
    }
    state = nextState

    return ResourcePolicyDecision(
      snapshotID: snapshot.snapshotID,
      state: nextState,
      transition: transition,
      directives: ResourceWorkClass.allCases
        .sorted {
          if $0.priorityRank == $1.priorityRank {
            return $0.rawValue < $1.rawValue
          }
          return $0.priorityRank < $1.priorityRank
        }
        .map {
          directive(for: $0, reasons: reasons)
        },
      observableReasonCodes: reasons
    )
  }

  private func reasonCodes(_ snapshot: ResourcePressureSnapshot) -> [String] {
    var reasons: [String] = []
    switch snapshot.memoryPressure {
    case .normal:
      break
    case .warning:
      reasons.append("memory-warning")
    case .critical:
      reasons.append("memory-critical")
    }
    switch snapshot.thermalPressure {
    case .nominal, .fair:
      break
    case .serious:
      reasons.append("thermal-serious")
    case .critical:
      reasons.append("thermal-critical")
    }
    if snapshot.inferenceBacklog == snapshot.inferenceBacklogCapacity {
      reasons.append("backlog-full")
    }
    return reasons
  }

  private func directive(
    for workClass: ResourceWorkClass,
    reasons: [String]
  ) -> ResourceWorkDirective {
    let reasonSet = Set(reasons)
    let action: ResourceDirectiveAction
    switch workClass {
    case .capture, .journal:
      action = .run
    case .liveASR:
      if reasonSet.contains("memory-critical")
        || reasonSet.contains("thermal-critical")
        || reasonSet.contains("backlog-full")
      {
        action = .deferDurably
      } else if !reasons.isEmpty {
        action = .throttle
      } else {
        action = .run
      }
    case .finalASR:
      action = reasons.isEmpty ? .run : .deferDurably
    case .speaker, .localText:
      if reasonSet.contains("memory-warning")
        || reasonSet.contains("memory-critical")
      {
        action = .unloadAndDefer
      } else {
        action = reasons.isEmpty ? .run : .deferDurably
      }
    }
    return ResourceWorkDirective(
      workClass: workClass,
      priorityRank: workClass.priorityRank,
      action: action,
      reasonCodes: action == .run ? [] : reasons
    )
  }
}
