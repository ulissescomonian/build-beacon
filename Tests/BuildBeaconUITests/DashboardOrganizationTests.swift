import BuildBeaconKit
@testable import BuildBeaconUI
import XCTest

final class DashboardOrganizationTests: XCTestCase {
    func testProjectsKeepSameNameInDifferentWorkspacesDistinct() {
        let observations = [
            observation("ios", workspace: "Mobile", workspaceSlug: "mobile", project: "Apps"),
            observation("android", workspace: "Platform", workspaceSlug: "platform", project: "Apps"),
        ]

        let projects = DashboardOrganization.projects(in: observations)

        XCTAssertEqual(projects.count, 2)
        XCTAssertNotEqual(projects[0].id, projects[1].id)
    }

    func testHideNoRunKeepsUnavailableObservationVisible() {
        let empty = observation("empty")
        let offline = observation("offline", failure: .offline)
        let preferences = MonitorPresentationPreferences(hideRepositoriesWithoutRuns: true)

        let visible = DashboardOrganization.visibleObservations(
            [empty, offline],
            projectFilter: .all,
            searchText: "",
            preferences: preferences
        )

        XCTAssertEqual(visible.map(\.monitor.repositoryName), ["offline"])
    }

    func testProjectFilterAndSearchAreCombined() {
        let mobileAPI = observation("Mobile API", project: "Mobile")
        let mobileWeb = observation("Mobile Web", project: "Mobile")
        let platformAPI = observation("Platform API", project: "Platform")
        let mobileProject = try! XCTUnwrap(DashboardOrganization.projects(in: [mobileAPI]).first)

        let visible = DashboardOrganization.visibleObservations(
            [mobileAPI, mobileWeb, platformAPI],
            projectFilter: .project(mobileProject),
            searchText: "api",
            preferences: .init()
        )

        XCTAssertEqual(visible.map(\.monitor.repositoryName), ["Mobile API"])
    }

    func testFavoritesComeFirstWithoutChangingStatusSortWithinOtherItems() {
        let failed = observation("failed", phase: .failed)
        let favoriteHealthy = observation("favorite", phase: .succeeded, favorite: true)
        let healthy = observation("healthy", phase: .succeeded)

        let visible = DashboardOrganization.visibleObservations(
            [healthy, favoriteHealthy, failed],
            projectFilter: .all,
            searchText: "",
            preferences: .init(sortOrder: .status, favoritesFirst: true)
        )

        XCTAssertEqual(visible.map(\.monitor.repositoryName), ["favorite", "failed", "healthy"])
    }

    func testStatusSortPlacesApprovalAfterFailuresAndBeforeActivePipelines() {
        let failed = observation("failed", phase: .failed)
        let approval = observation("approval", phase: .awaitingApproval)
        let running = observation("running", phase: .running)
        let healthy = observation("healthy", phase: .succeeded)

        let visible = DashboardOrganization.visibleObservations(
            [healthy, running, approval, failed],
            projectFilter: .all,
            searchText: "",
            preferences: .init(sortOrder: .status, favoritesFirst: false)
        )

        XCTAssertEqual(visible.map(\.monitor.repositoryName), ["failed", "approval", "running", "healthy"])
    }

    func testPrioritizedSectionsPlaceApprovalsBeforeEveryOtherGroup() {
        let approval = observation("approval", project: "Zebra", phase: .awaitingApproval)
        let other = observation("other", project: "Alpha", phase: .succeeded)

        let sections = DashboardOrganization.prioritizedSections(
            for: [other, approval],
            grouping: .project
        )

        XCTAssertEqual(sections.first?.id, "approval-required")
        XCTAssertEqual(sections.first?.observations.map(\.monitor.repositoryName), ["approval"])
        XCTAssertEqual(sections.dropFirst().flatMap(\.observations).map(\.monitor.repositoryName), ["other"])
    }

    func testPrioritizedSectionsKeepsNormalSectionsWhenNoApprovalExists() {
        let first = observation("first", project: "Alpha", phase: .succeeded)
        let second = observation("second", project: "Beta", phase: .running)

        let sections = DashboardOrganization.prioritizedSections(
            for: [first, second],
            grouping: .project
        )

        XCTAssertEqual(sections.map(\.title), ["Alpha", "Beta"])
    }

    func testPrioritizedSectionsPlacePipelineApprovalBeforeReadyToMerge() {
        let approval = observation("approval", phase: .awaitingApproval)
        let mergeReady = observation("ready", readyToMerge: true)
        let healthy = observation("healthy", phase: .succeeded)

        let sections = DashboardOrganization.prioritizedSections(
            for: [healthy, mergeReady, approval],
            grouping: .none
        )

        XCTAssertEqual(sections.map(\.id), ["approval-required", "ready-to-merge", "all-pipelines"])
        XCTAssertEqual(sections[0].observations.map(\.monitor.repositoryName), ["approval"])
        XCTAssertEqual(sections[1].observations.map(\.monitor.repositoryName), ["ready"])
        XCTAssertEqual(sections[2].observations.map(\.monitor.repositoryName), ["healthy"])
    }

    func testReadyToMergeSectionUsesCandidateEvidenceWithoutActionsCredential() {
        let mergeReady = observation("ready", readyToMerge: true)

        let sections = DashboardOrganization.prioritizedSections(
            for: [mergeReady],
            grouping: .none
        )

        XCTAssertEqual(sections.map(\.id), ["ready-to-merge"])
        XCTAssertEqual(sections[0].observations.map(\.monitor.repositoryName), ["ready"])
    }

    func testReadyToMergeSectionIncludesCandidateWhenMonitorActionOptInIsDisabled() {
        let mergeCandidate = observation("ready", readyToMerge: true, actionOptIn: false)

        let sections = DashboardOrganization.prioritizedSections(
            for: [mergeCandidate],
            grouping: .none
        )

        XCTAssertEqual(sections.map(\.id), ["ready-to-merge"])
    }

    func testProjectGroupingPlacesUnassignedInOwnSection() {
        let mobile = observation("mobile", project: "Mobile")
        let unassigned = observation("misc")

        let sections = DashboardOrganization.sections(
            for: [mobile, unassigned],
            grouping: .project
        )

        XCTAssertEqual(
            sections.map(\.title),
            ["Mobile", String(localized: "No Project", bundle: .module)]
        )
    }

    func testRecentActivitySortsNewestRunFirst() {
        let old = observation("old", phase: .succeeded, startedAt: Date(timeIntervalSince1970: 100))
        let new = observation("new", phase: .succeeded, startedAt: Date(timeIntervalSince1970: 200))

        let visible = DashboardOrganization.visibleObservations(
            [old, new],
            projectFilter: .all,
            searchText: "",
            preferences: .init(sortOrder: .recentActivity, favoritesFirst: false)
        )

        XCTAssertEqual(visible.map(\.monitor.repositoryName), ["new", "old"])
    }

    func testRecentActivityIgnoresFavoritesSoNewestActivityRemainsFirst() {
        let favoriteOld = observation(
            "favorite old",
            phase: .succeeded,
            favorite: true,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let new = observation("new", phase: .succeeded, startedAt: Date(timeIntervalSince1970: 200))

        let visible = DashboardOrganization.visibleObservations(
            [favoriteOld, new],
            projectFilter: .all,
            searchText: "",
            preferences: .init(sortOrder: .recentActivity, favoritesFirst: false)
        )

        XCTAssertEqual(visible.map(\.monitor.repositoryName), ["new", "favorite old"])
    }

    func testRecentActivityAlwaysPlacesNoRunRepositoriesLast() {
        let noRunFavorite = observation("aaa no run", favorite: true)
        let noRun = observation("zzz no run")
        let undatedRun = observation("undated run", phase: .succeeded, failure: .offline)
        let oldRun = observation(
            "old run",
            phase: .succeeded,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let newRun = observation(
            "new run",
            phase: .succeeded,
            startedAt: Date(timeIntervalSince1970: 200)
        )

        let visible = DashboardOrganization.visibleObservations(
            [noRun, undatedRun, oldRun, noRunFavorite, newRun],
            projectFilter: .all,
            searchText: "",
            preferences: .init(sortOrder: .recentActivity, favoritesFirst: true)
        )

        XCTAssertEqual(
            visible.map(\.monitor.repositoryName),
            ["new run", "old run", "undated run", "aaa no run", "zzz no run"]
        )
    }

    private func observation(
        _ repository: String,
        workspace: String = "Workspace",
        workspaceSlug: String = "workspace",
        project: String? = nil,
        phase: PipelinePhase? = nil,
        favorite: Bool = false,
        failure: ObservationFailure? = nil,
        startedAt: Date? = nil,
        readyToMerge: Bool = false,
        actionOptIn: Bool? = nil
    ) -> MonitorObservation {
        let id = MonitorID(
            accountID: AccountID(rawValue: "account"),
            workspaceID: WorkspaceID(rawValue: workspaceSlug),
            repositoryID: RepositoryID(rawValue: repository),
            target: .repositoryLatest
        )
        let monitor = MonitorConfiguration(
            id: id,
            workspaceSlug: workspaceSlug,
            workspaceName: workspace,
            repositorySlug: repository.lowercased().replacingOccurrences(of: " ", with: "-"),
            repositoryName: repository,
            projectName: project,
            isPinned: favorite,
            allowsPullRequestActions: actionOptIn ?? readyToMerge
        )
        let resolvedPhase = phase ?? (readyToMerge ? .succeeded : nil)
        let run = resolvedPhase.map {
            PipelineRun(
                id: PipelineRunID(rawValue: "run-\(repository)"),
                buildNumber: 1,
                phase: $0,
                origin: readyToMerge
                    ? .pullRequest(id: 12, sourceBranch: "feature", destinationBranch: "develop")
                    : .unknown,
                commitHash: readyToMerge ? "abcdef" : nil,
                startedAt: startedAt,
                pullRequest: readyToMerge
                    ? PipelinePullRequestContext(
                        id: 12,
                        title: "Ready",
                        state: "OPEN",
                        sourceCommitHash: "abcdef"
                    )
                    : nil
            )
        }
        return MonitorObservation(
            monitor: monitor,
            lastKnownRun: run,
            attemptedAt: Date(timeIntervalSince1970: 300),
            lastSuccessfulObservationAt: failure == nil ? Date(timeIntervalSince1970: 300) : nil,
            currentFailure: failure
        )
    }
}
