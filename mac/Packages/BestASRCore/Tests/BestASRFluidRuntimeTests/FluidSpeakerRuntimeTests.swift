import Foundation
import XCTest

@testable import BestASRFluidRuntime

final class FluidSpeakerRuntimeTests: XCTestCase {
  func testPinnedAHCReceivesSimilarityThatPreservesCommunityDistance() {
    let config = FluidSpeakerClusteringPolicy.configuration(expectedSpeakerRange: nil)
    XCTAssertEqual(config.clustering.threshold, 0.82, accuracy: 1e-12)
    let actualDistance = sqrt(2 - 2 * config.clustering.threshold)
    XCTAssertEqual(
      actualDistance, FluidSpeakerClusteringPolicy.communityDistanceThreshold,
      accuracy: 1e-12
    )
    XCTAssertTrue(config.exposeChunkEmbeddings)
    XCTAssertNil(config.clustering.numSpeakers)
    XCTAssertNil(config.clustering.minSpeakers)
    XCTAssertNil(config.clustering.maxSpeakers)
  }

  func testSpeakerBoundsDoNotResetDistancePolicyOrForceAClusterCount() {
    let config = FluidSpeakerClusteringPolicy.configuration(expectedSpeakerRange: 1...6)
    XCTAssertEqual(config.clustering.threshold, 0.82, accuracy: 1e-12)
    XCTAssertEqual(config.clustering.minSpeakers, 1)
    XCTAssertEqual(config.clustering.maxSpeakers, 6)
    XCTAssertNil(config.clustering.numSpeakers)
    XCTAssertTrue(config.exposeChunkEmbeddings)
  }

  func testClusteringRepairChangesJobProvenanceButNotIdentityEmbeddingSpace() {
    XCTAssertEqual(
      FluidSpeakerPinnedArtifact.pipelineRevision,
      "fluid-speaker-final-v2-community-distance-0.6"
    )
    XCTAssertEqual(
      FluidSpeakerPinnedArtifact.embeddingSpaceID,
      "fluid-community1-embedding-256-v1"
    )
  }
}
