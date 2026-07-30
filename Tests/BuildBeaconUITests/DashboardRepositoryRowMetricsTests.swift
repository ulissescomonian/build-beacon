import CoreGraphics
@testable import BuildBeaconUI
import XCTest

final class DashboardRepositoryRowMetricsTests: XCTestCase {
    func testRepositoryRowMinimumHeightIsStableAndValid() {
        XCTAssertEqual(DashboardRepositoryRowMetrics.minimumHeight, 64)
        XCTAssertGreaterThan(DashboardRepositoryRowMetrics.minimumHeight, 0)
        XCTAssertTrue(DashboardRepositoryRowMetrics.minimumHeight.isFinite)
        XCTAssertEqual(DashboardRepositoryRowMetrics.metadataColumnWidth, 76)
        XCTAssertGreaterThan(DashboardRepositoryRowMetrics.metadataColumnWidth, 0)
        XCTAssertTrue(DashboardRepositoryRowMetrics.metadataColumnWidth.isFinite)
    }

    func testFavoriteReorderAnimationDurationIsShortAndValid() {
        XCTAssertEqual(DashboardRepositoryRowMetrics.favoriteReorderAnimationDuration, 0.18)
        XCTAssertGreaterThan(DashboardRepositoryRowMetrics.favoriteReorderAnimationDuration, 0)
        XCTAssertLessThanOrEqual(DashboardRepositoryRowMetrics.favoriteReorderAnimationDuration, 0.25)
        XCTAssertTrue(DashboardRepositoryRowMetrics.favoriteReorderAnimationDuration.isFinite)
    }

    func testFavoriteButtonHitTargetIsAccessibleAndValid() {
        XCTAssertEqual(DashboardRepositoryRowMetrics.favoriteButtonHitTargetSize, 36)
        XCTAssertGreaterThanOrEqual(DashboardRepositoryRowMetrics.favoriteButtonHitTargetSize, 32)
        XCTAssertTrue(DashboardRepositoryRowMetrics.favoriteButtonHitTargetSize.isFinite)
    }
}
