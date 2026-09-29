import BestASRInferenceQueueProbe
import Foundation
import XCTest

final class InferenceQueueProbeTests: XCTestCase {
  func testBoundedQueueNeverExceedsCapacity() async {
    let queue = BoundedRealtimeQueue<Int>(capacity: 2)
    let first = await queue.offer(1)
    let second = await queue.offer(2)
    let third = await queue.offer(3)
    let count = await queue.count
    let highWatermark = await queue.highWatermark
    let polled = await queue.poll()
    XCTAssertEqual(first, .accepted)
    XCTAssertEqual(second, .accepted)
    XCTAssertEqual(third, .full)
    XCTAssertEqual(count, 2)
    XCTAssertEqual(highWatermark, 2)
    XCTAssertEqual(polled, 1)
  }

  func testExpiredLeaseIsReclaimedAfterStoreReopen() async throws {
    let url = temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try DurableLeaseStore(url: url)
    let job = try await store.enqueue(
      inputRevision: 1,
      modelVersion: "v1",
      configHash: "config"
    )
    let firstOwner = UUID()
    _ = try await store.leaseNext(
      owner: firstOwner,
      now: Date(timeIntervalSince1970: 10),
      duration: 2
    )

    let reopened = try DurableLeaseStore(url: url)
    let recoveredOptional = try await reopened.leaseNext(
      owner: UUID(),
      now: Date(timeIntervalSince1970: 13),
      duration: 2
    )
    let recovered = try XCTUnwrap(recoveredOptional)
    XCTAssertEqual(recovered.id, job.id)
    XCTAssertEqual(recovered.retryCount, 1)
  }

  func testDuplicateCommitIsIdempotent() async throws {
    let url = temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try DurableLeaseStore(url: url)
    _ = try await store.enqueue(
      inputRevision: 1,
      modelVersion: "v1",
      configHash: "config"
    )
    let owner = UUID()
    let leased = try await store.leaseNext(
      owner: owner,
      now: Date(),
      duration: 10
    )
    let job = try XCTUnwrap(leased)
    let firstCommit = try await store.commit(
      jobID: job.id,
      owner: owner,
      resultDigest: "digest"
    )
    let duplicateCommit = try await store.commit(
      jobID: job.id,
      owner: owner,
      resultDigest: "digest"
    )
    XCTAssertEqual(firstCommit, .inserted)
    XCTAssertEqual(duplicateCommit, .duplicate)
    let commits = await store.commits
    XCTAssertEqual(commits.count, 1)
  }

  func testEnqueueUsesStableIdempotencyKey() async throws {
    let url = temporaryStoreURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try DurableLeaseStore(url: url)
    let first = try await store.enqueue(
      inputRevision: 4,
      modelVersion: "v1",
      configHash: "config"
    )
    let second = try await store.enqueue(
      inputRevision: 4,
      modelVersion: "v1",
      configHash: "config"
    )
    XCTAssertEqual(first.id, second.id)
    let jobs = await store.jobs
    XCTAssertEqual(jobs.count, 1)
  }

  private func temporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("jobs.json")
  }
}
