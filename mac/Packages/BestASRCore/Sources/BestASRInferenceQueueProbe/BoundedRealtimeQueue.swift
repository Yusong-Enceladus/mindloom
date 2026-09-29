import Foundation

public enum QueueOfferResult: String, Codable, Sendable {
  case accepted
  case full
}

public actor BoundedRealtimeQueue<Element: Sendable> {
  public let capacity: Int
  private var elements: [Element] = []
  private var observedHighWatermark = 0

  public init(capacity: Int) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  public func offer(_ element: Element) -> QueueOfferResult {
    guard elements.count < capacity else { return .full }
    elements.append(element)
    observedHighWatermark = max(observedHighWatermark, elements.count)
    return .accepted
  }

  public func poll() -> Element? {
    guard !elements.isEmpty else { return nil }
    return elements.removeFirst()
  }

  public var count: Int { elements.count }
  public var highWatermark: Int { observedHighWatermark }
}
