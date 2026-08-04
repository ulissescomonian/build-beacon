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

    func testRepositoryRowMinimumHeightExpandsForInlineAction() {
        XCTAssertEqual(DashboardRepositoryRowMetrics.minimumHeight(hasInlineAction: false), 64)
        XCTAssertEqual(DashboardRepositoryRowMetrics.minimumHeight(hasInlineAction: true), 84)
    }

    func testRepositoryRowLayoutRevisionChangesOnlyWhenInlineActionChanges() {
        let compactRevision = DashboardRepositoryRowMetrics.layoutRevision(hasInlineAction: false)
        let actionRevision = DashboardRepositoryRowMetrics.layoutRevision(hasInlineAction: true)

        XCTAssertEqual(compactRevision, DashboardRepositoryRowMetrics.layoutRevision(hasInlineAction: false))
        XCTAssertEqual(actionRevision, DashboardRepositoryRowMetrics.layoutRevision(hasInlineAction: true))
        XCTAssertNotEqual(compactRevision, actionRevision)
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
