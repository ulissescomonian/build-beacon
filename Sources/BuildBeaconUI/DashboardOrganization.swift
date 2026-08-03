import BuildBeaconKit
import Foundation

enum DashboardProjectFilter: Hashable, Identifiable {
    case all
    case project(DashboardProject)
    case noProject

    var id: String {
        switch self {
        case .all: "all-projects"
        case let .project(project): "project-\(project.id)"
        case .noProject: "no-project"
        }
    }

    var title: String {
        switch self {
        case .all: String(localized: "All Projects", bundle: .module)
        case let .project(project): project.name
        case .noProject: String(localized: "No Project", bundle: .module)
        }
    }
}

struct DashboardProject: Hashable, Identifiable {
    /// A project name is only unique within a workspace. Keep the workspace in the
    /// identity without exposing the implementation detail in the interface.
    let id: String
    let workspaceName: String
    let name: String
}

struct DashboardSection: Identifiable {
    let id: String
    let title: String?
    let observations: [MonitorObservation]
}

enum DashboardOrganization {
    static func projects(in observations: [MonitorObservation]) -> [DashboardProject] {
        var values = Set<DashboardProject>()

        for observation in observations {
            guard let name = normalizedProjectName(of: observation) else { continue }
            values.insert(DashboardProject(
                id: projectID(for: observation, name: name),
                workspaceName: observation.monitor.workspaceName,
                name: name
            ))
        }

        return values.sorted {
            let projectOrder = $0.name.localizedStandardCompare($1.name)
            if projectOrder != .orderedSame { return projectOrder == .orderedAscending }
            return $0.workspaceName.localizedStandardCompare($1.workspaceName) == .orderedAscending
        }
    }

    static func visibleObservations(
        _ observations: [MonitorObservation],
        projectFilter: DashboardProjectFilter,
        searchText: String,
        preferences: MonitorPresentationPreferences
    ) -> [MonitorObservation] {
        let filtered = observations.filter { observation in
            guard !observation.monitor.isHidden else { return false }
            guard matches(projectFilter, observation: observation) else { return false }
            guard matches(searchText, observation: observation) else { return false }

            // A request that completed successfully with no run is safe to hide.
            // An unavailable repository with no cached run still needs attention.
            if preferences.hideRepositoriesWithoutRuns,
               observation.lastKnownRun == nil,
               observation.currentFailure == nil {
                return false
            }
            return true
        }

        return sorted(filtered, preferences: preferences)
    }

    static func sections(
        for observations: [MonitorObservation],
        grouping: MonitorPresentationPreferences.Grouping
    ) -> [DashboardSection] {
        switch grouping {
        case .none:
            return observations.isEmpty ? [] : [
                DashboardSection(id: "all-pipelines", title: nil, observations: observations),
            ]
        case .project:
            let grouped = Dictionary(grouping: observations) { observation -> DashboardProject? in
                guard let name = normalizedProjectName(of: observation) else { return nil }
                return DashboardProject(
                    id: projectID(for: observation, name: name),
                    workspaceName: observation.monitor.workspaceName,
                    name: name
                )
            }

            return grouped.map { project, observations in
                DashboardSection(
                    id: project?.id ?? "no-project",
                    title: project?.name ?? String(localized: "No Project", bundle: .module),
                    observations: observations
                )
            }
            .sorted { lhs, rhs in
                switch (lhs.title, rhs.title) {
                case (nil, nil): lhs.id < rhs.id
                case (nil, _): false
                case (_, nil): true
                case let (left?, right?): left.localizedStandardCompare(right) == .orderedAscending
                }
            }
        }
    }

    /// Approval requests are operational work, not merely another sort state. Keep
    /// them in a compact leading section while preserving the user's chosen order
    /// for both the approval items themselves and every remaining repository.
    static func prioritizedSections(
        for observations: [MonitorObservation],
        grouping: MonitorPresentationPreferences.Grouping
    ) -> [DashboardSection] {
        let approvals = observations.filter { $0.lastKnownRun?.phase == .awaitingApproval }
        guard !approvals.isEmpty else {
            return sections(for: observations, grouping: grouping)
        }

        let remaining = observations.filter { $0.lastKnownRun?.phase != .awaitingApproval }
        return [
            DashboardSection(
                id: "approval-required",
                title: String(localized: "Approval required", bundle: .module),
                observations: approvals
            ),
        ] + sections(for: remaining, grouping: grouping)
    }

    private static func matches(
        _ filter: DashboardProjectFilter,
        observation: MonitorObservation
    ) -> Bool {
        switch filter {
        case .all:
            return true
        case let .project(project):
            guard let name = normalizedProjectName(of: observation) else { return false }
            return project.id == projectID(for: observation, name: name)
        case .noProject:
            return normalizedProjectName(of: observation) == nil
        }
    }

    private static func matches(_ searchText: String, observation: MonitorObservation) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [
            observation.monitor.repositoryName,
            observation.monitor.workspaceName,
            observation.monitor.projectName,
        ]
        .compactMap { $0 }
        .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private static func sorted(
        _ observations: [MonitorObservation],
        preferences: MonitorPresentationPreferences
    ) -> [MonitorObservation] {
        observations.sorted { lhs, rhs in
            // A successful poll without a pipeline is not pipeline activity. Keep
            // repositories with a real run ahead of no-run placeholders even when
            // "favorites first" is enabled.
            if preferences.sortOrder == .recentActivity {
                let activityPresence = compareActivityPresence(lhs, rhs)
                if activityPresence != .orderedSame {
                    return activityPresence == .orderedAscending
                }
            }

            if preferences.favoritesFirst,
               lhs.monitor.isFavorite != rhs.monitor.isFavorite {
                return lhs.monitor.isFavorite
            }

            let order = compare(lhs, rhs, sortOrder: preferences.sortOrder)
            if order != .orderedSame { return order == .orderedAscending }
            return stableName(lhs).localizedStandardCompare(stableName(rhs)) == .orderedAscending
        }
    }

    private static func compare(
        _ lhs: MonitorObservation,
        _ rhs: MonitorObservation,
        sortOrder: MonitorPresentationPreferences.SortOrder
    ) -> ComparisonResult {
        switch sortOrder {
        case .status:
            let left = statusRank(lhs)
            let right = statusRank(rhs)
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        case .project:
            return projectSortName(lhs).localizedStandardCompare(projectSortName(rhs))
        case .repository:
            return lhs.monitor.repositoryName.localizedStandardCompare(rhs.monitor.repositoryName)
        case .recentActivity:
            switch (pipelineActivityDate(lhs), pipelineActivityDate(rhs)) {
            case let (left?, right?):
                if left == right { return .orderedSame }
                return left > right ? .orderedAscending : .orderedDescending
            case (.some, .none):
                return .orderedAscending
            case (.none, .some):
                return .orderedDescending
            case (.none, .none):
                return .orderedSame
            }
        }
    }

    private static func compareActivityPresence(
        _ lhs: MonitorObservation,
        _ rhs: MonitorObservation
    ) -> ComparisonResult {
        switch (lhs.lastKnownRun, rhs.lastKnownRun) {
        case (.some, .none): .orderedAscending
        case (.none, .some): .orderedDescending
        case (.some, .some), (.none, .none): .orderedSame
        }
    }

    private static func statusRank(_ observation: MonitorObservation) -> Int {
        if observation.currentFailure != nil { return 0 }
        return switch observation.lastKnownRun?.phase {
        case .failed?, .errored?, .expired?: 0
        case .awaitingApproval?: 1
        case .running?, .queued?: 2
        case .succeeded?: 3
        case .stopped?, .unknown?, nil: 4
        }
    }

    private static func pipelineActivityDate(_ observation: MonitorObservation) -> Date? {
        guard let run = observation.lastKnownRun else { return nil }
        return run.completedAt
            ?? run.startedAt
            ?? observation.lastSuccessfulObservationAt
    }

    private static func stableName(_ observation: MonitorObservation) -> String {
        return "\(observation.monitor.workspaceName)\u{1F}\(observation.monitor.repositoryName)"
    }

    private static func projectSortName(_ observation: MonitorObservation) -> String {
        return "\(normalizedProjectName(of: observation) ?? "~")\u{1F}\(observation.monitor.workspaceName)"
    }

    private static func normalizedProjectName(of observation: MonitorObservation) -> String? {
        let name = observation.monitor.projectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    private static func projectID(for observation: MonitorObservation, name: String) -> String {
        return "\(observation.monitor.workspaceSlug.lowercased())\u{1F}\(name.lowercased())"
    }
}
