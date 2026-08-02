import BuildBeaconKit
@testable import BuildBeaconUI
import XCTest

final class PipelineRunOriginPresentationTests: XCTestCase {
    func testBranchDisplaysBadgeAndBranchName() {
        let display = PipelineRunOriginPresentation.display(for: .branch(name: "develop"))

        XCTAssertEqual(display.badgeTitle, PipelineRunOriginPresentation.branchBadgeTitle)
        XCTAssertEqual(display.reference, "develop")
        XCTAssertNotNil(display.accessibilityLabel)
    }

    func testPullRequestDisplaysIdentifierAndBranchDirection() {
        let display = PipelineRunOriginPresentation.display(
            for: .pullRequest(id: 482, sourceBranch: "feat/dashboard", destinationBranch: "dev")
        )

        XCTAssertTrue(display.badgeTitle?.contains("482") == true)
        XCTAssertEqual(display.reference, "feat/dashboard → dev")
        XCTAssertTrue(display.accessibilityLabel?.contains("482") == true)
    }

    func testLongPullRequestReferencePreservesBothSemanticEndpoints() {
        let source = "feature/very-long-name-that-needs-middle-truncation-in-the-dashboard"
        let destination = "release/2026-08"
        let display = PipelineRunOriginPresentation.display(
            for: .pullRequest(id: 483, sourceBranch: source, destinationBranch: destination)
        )

        XCTAssertEqual(display.reference, "\(source) → \(destination)")
        XCTAssertTrue(display.reference?.hasSuffix(destination) == true)
    }

    func testPartialPullRequestUsesAvailableReferenceAndGenericBadge() {
        let display = PipelineRunOriginPresentation.display(
            for: .pullRequest(id: nil, sourceBranch: nil, destinationBranch: "main")
        )

        XCTAssertEqual(display.badgeTitle, PipelineRunOriginPresentation.pullRequestBadgeTitle)
        XCTAssertEqual(display.reference, "main")
        XCTAssertNotNil(display.accessibilityLabel)
    }

    func testUnknownDoesNotClaimAnOriginAndKeepsLegacyReference() {
        let display = PipelineRunOriginPresentation.display(for: .unknown, fallbackBranchName: "release")

        XCTAssertNil(display.badgeTitle)
        XCTAssertEqual(display.reference, "release")
        XCTAssertNil(display.accessibilityLabel)
    }

    func testOriginStringsExistInEnglishAndBrazilianPortuguese() throws {
        for localization in ["en", "pt-BR"] {
            let strings = try localizedStrings(for: localization)
            for key in [
                "pipeline.origin.badge.branch",
                "pipeline.origin.badge.pullRequest",
                "pipeline.origin.badge.pullRequest.format",
                "pipeline.origin.accessibility.branch",
                "pipeline.origin.accessibility.pullRequest",
                "pipeline.origin.accessibility.pullRequest.format"
            ] {
                XCTAssertTrue(strings.contains("\"\(key)\""), "Missing \(key) for \(localization)")
            }
        }
    }

    private func localizedStrings(for localization: String) throws -> String {
        let path = try XCTUnwrap(
            Bundle.module.path(
                forResource: "Localizable",
                ofType: "strings",
                inDirectory: nil,
                forLocalization: localization
            )
        )
        return try String(contentsOfFile: path, encoding: .utf8)
    }
}
