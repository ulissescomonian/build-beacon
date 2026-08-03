import BuildBeaconKit
@testable import BuildBeaconUI
import XCTest

final class DashboardRunSummaryPresentationTests: XCTestCase {
    func testPullRequestUsesOnlyPullRequestAuthor() {
        let display = DashboardRunSummaryPresentation.display(for: run(
            origin: .pullRequest(id: 18, sourceBranch: "feature/summary", destinationBranch: "develop"),
            commitAuthor: "Commit Author",
            pullRequestAuthor: "Pull Request Author"
        ))

        XCTAssertEqual(display.author, "Pull Request Author")
        XCTAssertEqual(display.origin.badgeStyle, .pullRequest)
        XCTAssertEqual(display.origin.reference, "feature/summary → develop")
    }

    func testBranchUsesCommitAuthor() {
        let display = DashboardRunSummaryPresentation.display(for: run(
            origin: .branch(name: "develop"),
            commitAuthor: "Commit Author",
            pullRequestAuthor: "Pull Request Author"
        ))

        XCTAssertEqual(display.author, "Commit Author")
        XCTAssertEqual(display.origin.badgeStyle, .branch)
    }

    func testUnknownOriginDoesNotInventAnAuthor() {
        let display = DashboardRunSummaryPresentation.display(for: run(
            origin: .unknown,
            commitAuthor: "Commit Author",
            pullRequestAuthor: "Pull Request Author"
        ))

        XCTAssertNil(display.author)
    }

    func testKnownOriginWithoutAuthorUsesLocalizedFallback() {
        let display = DashboardRunSummaryPresentation.display(for: run(origin: .branch(name: "main")))

        XCTAssertEqual(
            display.author,
            String(
                localized: "pipeline.summary.author.unavailable",
                defaultValue: "Author unavailable",
                bundle: .module
            )
        )
    }

    func testNoRunDoesNotShowAuthor() {
        let display = DashboardRunSummaryPresentation.display(for: nil, fallbackBranchName: "develop")

        XCTAssertNil(display.author)
        XCTAssertNil(display.contextualStep)
        XCTAssertEqual(display.origin.reference, "develop")
    }

    func testFailedRunShowsFirstFailedStepOnly() {
        let display = DashboardRunSummaryPresentation.display(for: run(
            phase: .failed,
            steps: [
                step("Build", .succeeded),
                step("Deploy sandbox", .failed),
                step("Later", .failed)
            ]
        ))

        XCTAssertTrue(display.contextualStep?.contains("Deploy sandbox") == true)
    }

    func testRunningRunFallsBackToQueuedStep() {
        let display = DashboardRunSummaryPresentation.display(for: run(
            phase: .running,
            steps: [step("Deploy sandbox", .queued)]
        ))

        XCTAssertTrue(display.contextualStep?.contains("Deploy sandbox") == true)
    }

    func testQueuedRunShowsFirstQueuedStep() {
        let display = DashboardRunSummaryPresentation.display(for: run(
            phase: .queued,
            steps: [
                step("Build", .succeeded),
                step("Deploy sandbox", .queued),
                step("Later", .queued)
            ]
        ))

        XCTAssertTrue(display.contextualStep?.contains("Deploy sandbox") == true)
    }

    func testAwaitingApprovalRunShowsApprovalStep() {
        let display = DashboardRunSummaryPresentation.display(for: run(
            phase: .awaitingApproval,
            steps: [step("Production", .awaitingApproval)]
        ))

        XCTAssertTrue(display.contextualStep?.contains("Production") == true)
    }

    func testAwaitingApprovalRunShowsTimeSinceDetection() {
        let detectedAt = Date(timeIntervalSinceReferenceDate: 100)
        let now = Date(timeIntervalSinceReferenceDate: 220)
        let display = DashboardRunSummaryPresentation.display(
            for: run(phase: .awaitingApproval),
            approvalDetectedAt: detectedAt,
            now: now
        )

        XCTAssertEqual(
            display.approvalWait,
            String(
                format: String(
                    localized: "pipeline.summary.approval.detected.format",
                    defaultValue: "Detected %@ ago",
                    bundle: .module
                ),
                Duration.seconds(120).formatted(.units())
            )
        )
    }

    func testNonApprovalRunDoesNotShowTimeSinceDetection() {
        let display = DashboardRunSummaryPresentation.display(
            for: run(phase: .running),
            approvalDetectedAt: Date(timeIntervalSinceReferenceDate: 100),
            now: Date(timeIntervalSinceReferenceDate: 220)
        )

        XCTAssertNil(display.approvalWait)
    }

    func testSuccessfulRunDoesNotShowContextualStep() {
        let display = DashboardRunSummaryPresentation.display(for: run(
            phase: .succeeded,
            steps: [step("Deploy sandbox", .failed)]
        ))

        XCTAssertNil(display.contextualStep)
    }

    func testCompletedRunShowsDurationInSummaryMetadata() {
        let display = DashboardRunSummaryPresentation.display(for: run(
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            completedAt: Date(timeIntervalSinceReferenceDate: 90)
        ))

        let duration = Duration.seconds(90).formatted(.units())
        XCTAssertEqual(display.duration, duration)
        XCTAssertEqual(display.metadata, duration)
        XCTAssertTrue(display.accessibilityLabel?.contains(duration) == true)
    }

    func testRunWithoutCompletedDurationOmitsSummaryDuration() {
        let display = DashboardRunSummaryPresentation.display(for: run(
            startedAt: Date(timeIntervalSinceReferenceDate: 0)
        ))

        XCTAssertNil(display.duration)
        XCTAssertNil(display.metadata)
    }

    func testFailedRunCombinesContextualStepAndDuration() {
        let display = DashboardRunSummaryPresentation.display(for: run(
            phase: .failed,
            steps: [step("Deploy sandbox", .failed)],
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            completedAt: Date(timeIntervalSinceReferenceDate: 90)
        ))

        XCTAssertTrue(display.metadata?.contains("Deploy sandbox") == true)
        XCTAssertTrue(display.metadata?.contains(Duration.seconds(90).formatted(.units())) == true)
        XCTAssertTrue(display.metadata?.contains(" · ") == true)
    }

    func testSummaryStringsExistInEnglishAndBrazilianPortuguese() throws {
        for localization in ["en", "pt-BR"] {
            let strings = try localizedStrings(for: localization)
            for key in [
                "pipeline.summary.author.unavailable",
                "pipeline.summary.step.failed.format",
                "pipeline.summary.step.running.format",
                "pipeline.summary.step.approval.format",
                "pipeline.summary.step.queued.format",
                "pipeline.summary.approval.detected.format",
                "pipeline.summary.accessibility.duration.format",
                "pipeline.summary.accessibility.age.format"
            ] {
                XCTAssertTrue(strings.contains("\"\(key)\""), "Missing \(key) for \(localization)")
            }
        }
    }

    private func run(
        phase: PipelinePhase = .succeeded,
        origin: PipelineRunOrigin = .branch(name: "develop"),
        commitAuthor: String? = nil,
        pullRequestAuthor: String? = nil,
        steps: [PipelineStep] = [],
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) -> PipelineRun {
        PipelineRun(
            id: PipelineRunID(rawValue: "run"),
            buildNumber: 12,
            phase: phase,
            branchName: "develop",
            origin: origin,
            startedAt: startedAt,
            completedAt: completedAt,
            steps: steps,
            commitContext: PipelineCommitContext(authorName: commitAuthor),
            pullRequest: PipelinePullRequestContext(
                id: 18,
                title: "Summary",
                state: "OPEN",
                authorName: pullRequestAuthor
            )
        )
    }

    private func step(_ name: String, _ phase: PipelineStepPhase) -> PipelineStep {
        PipelineStep(id: PipelineStepID(rawValue: name), name: name, phase: phase)
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
