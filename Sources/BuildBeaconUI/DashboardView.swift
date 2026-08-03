import BuildBeaconKit
import Foundation
import SwiftUI

public struct DashboardView: View {
    @Bindable private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @State private var filter: DashboardFilter = .all
    @State private var projectFilter: DashboardProjectFilter = .all
    @State private var searchText = ""

    public init(model: AppModel) {
        self.model = model
    }

    private var statusFiltered: [MonitorObservation] {
        model.sortedObservations.filter { observation in
            let phase = observation.lastKnownRun?.phase
            return switch filter {
            case .all: true
            case .recent: model.isActivityUnseen(observation)
            case .attention:
                observation.currentFailure != nil
                    || phase == .failed
                    || phase == .errored
                    || phase == .expired
                    || phase == .stopped
                    || isUnknown(phase)
            case .running: phase == .running || phase == .queued
            case .approval: phase == .awaitingApproval
            }
        }
    }

    private func isUnknown(_ phase: PipelinePhase?) -> Bool {
        if case .unknown? = phase { return true }
        return false
    }

    private var activePresentationPreferences: MonitorPresentationPreferences {
        guard filter == .recent else { return model.monitorPresentation }
        var recent = model.monitorPresentation
        recent.sortOrder = .recentActivity
        recent.favoritesFirst = false
        return recent
    }

    private var filtered: [MonitorObservation] {
        DashboardOrganization.visibleObservations(
            statusFiltered,
            projectFilter: projectFilter,
            searchText: searchText,
            preferences: activePresentationPreferences
        )
    }

    private var sections: [DashboardSection] {
        DashboardOrganization.prioritizedSections(for: filtered, grouping: model.monitorPresentation.grouping)
    }

    private var projects: [DashboardProject] {
        DashboardOrganization.projects(in: model.sortedObservations)
    }

    public var body: some View {
        NavigationSplitView {
            List {
                Section("Status") {
                    ForEach(DashboardFilter.allCases) { item in
                        SidebarChoice(
                            title: item.title,
                            systemImage: item.systemImage,
                            isSelected: filter == item,
                            badgeCount: item == .recent ? model.unseenActivityCount : nil
                        ) {
                            filter = item
                        }
                    }
                }

                Section("Projects") {
                    SidebarChoice(
                        title: DashboardProjectFilter.all.title,
                        systemImage: "square.grid.2x2",
                        isSelected: projectFilter == .all
                    ) {
                        projectFilter = .all
                    }

                    ForEach(projects) { project in
                        SidebarChoice(
                            title: project.name,
                            systemImage: "folder",
                            isSelected: projectFilter == .project(project),
                            subtitle: project.workspaceName
                        ) {
                            projectFilter = .project(project)
                        }
                    }

                    if model.sortedObservations.contains(where: { $0.monitor.projectName?.isEmpty != false }) {
                        SidebarChoice(
                            title: DashboardProjectFilter.noProject.title,
                            systemImage: "tray",
                            isSelected: projectFilter == .noProject
                        ) {
                            projectFilter = .noProject
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 185)
        } content: {
            VStack(spacing: 0) {
                DashboardRefreshStatus(model: model)
                Divider()

                if !model.isConnected {
                    ContentUnavailableView(
                        "Connect Bitbucket",
                        systemImage: "bolt.horizontal.circle",
                        description: Text("Open Settings to connect your account.")
                    )
                } else if model.configuration.monitors.isEmpty {
                    ContentUnavailableView(
                        "No Monitors",
                        systemImage: "tray",
                        description: Text("Add a repository in Settings to begin monitoring.")
                    )
                } else if model.sortedObservations.isEmpty {
                    ContentUnavailableView(
                        "Waiting for Pipeline Data",
                        systemImage: "arrow.clockwise",
                        description: Text("Build Beacon is preparing the first reliable snapshot.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView(
                        "No Matching Pipelines",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Adjust the status, project, or view filters to see more repositories.")
                    )
                } else {
                    List(selection: monitorSelection) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.observations, id: \.monitor.id) { observation in
                                    MonitorDashboardRow(
                                        observation: observation,
                                        refreshIntervalSeconds: model.refreshIntervalSeconds,
                                        approvalDetectedAt: model.approvalDetectedAt(for: observation.monitor.id),
                                        isUnseen: model.isActivityUnseen(observation),
                                        isFavoriteToggleDisabled: model.isMutatingMonitors,
                                        openApproval: {
                                            guard let run = observation.lastKnownRun else { return }
                                            model.openPipelineBuildURL(
                                                monitor: observation.monitor,
                                                buildNumber: run.buildNumber
                                            )
                                        },
                                        toggleFavorite: {
                                            withAnimation(
                                                reduceMotion
                                                    ? nil
                                                    : .easeInOut(
                                                        duration: DashboardRepositoryRowMetrics.favoriteReorderAnimationDuration
                                                    )
                                            ) {
                                                _ = model.beginFavoriteToggle(for: observation.monitor.id)
                                            }
                                        }
                                    )
                                    .tag(observation.monitor.id)
                                    .listRowInsets(EdgeInsets(
                                        top: 0,
                                        leading: 8,
                                        bottom: 0,
                                        trailing: 8
                                    ))
                                }
                            } header: {
                                if let title = section.title {
                                    Text(title)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pipelines")
            .searchable(text: $searchText, prompt: "Search repositories")
        } detail: {
            if let selected = model.selectedObservation {
                PipelineDetailView(
                    observation: selected,
                    refreshIntervalSeconds: model.refreshIntervalSeconds,
                    selectedHistory: model.selectedHistory,
                    notificationBuildNumber: model.selectedNotificationBuildNumber,
                    approvalDetectedAt: model.approvalDetectedAt(for: selected.monitor.id),
                    openURL: model.openPipelineURL,
                    openNotificationBuild: { buildNumber in
                        model.openPipelineBuildURL(
                            monitor: selected.monitor,
                            buildNumber: buildNumber
                        )
                    },
                    openApproval: {
                        guard let run = selected.lastKnownRun else { return }
                        model.openPipelineBuildURL(
                            monitor: selected.monitor,
                            buildNumber: run.buildNumber
                        )
                    },
                    openCommit: model.openCommitURL,
                    openPullRequest: model.openPullRequestURL
                )
            } else {
                ContentUnavailableView(
                    "Select a Pipeline",
                    systemImage: "rectangle.and.hand.point.up.left",
                    description: Text("Choose a monitored repository to inspect its latest run.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettings()
                } label: {
                    Label("Open Settings", systemImage: "gearshape")
                }
                .help("Open Settings")
                .accessibilityLabel("Open Settings")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    ZStack {
                        Image(systemName: "arrow.clockwise")
                            .opacity(model.isRefreshing ? 0 : 1)
                        if model.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .frame(width: 28, height: 28)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRefreshing || !model.isConnected)
                .accessibilityLabel(model.isRefreshing ? "Refreshing pipelines" : "Refresh pipelines")
            }

            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker("Group by", selection: presentationBinding(\.grouping)) {
                        Text("No grouping").tag(MonitorPresentationPreferences.Grouping.none)
                        Text("Project").tag(MonitorPresentationPreferences.Grouping.project)
                    }

                    Picker("Sort by", selection: presentationBinding(\.sortOrder)) {
                        Text("Status").tag(MonitorPresentationPreferences.SortOrder.status)
                        Text("Project").tag(MonitorPresentationPreferences.SortOrder.project)
                        Text("Repository").tag(MonitorPresentationPreferences.SortOrder.repository)
                        Text("Recent activity").tag(MonitorPresentationPreferences.SortOrder.recentActivity)
                    }

                    Divider()

                    Toggle("Favorites first", isOn: presentationBinding(\.favoritesFirst))
                    Toggle("Hide repositories without runs", isOn: presentationBinding(\.hideRepositoriesWithoutRuns))
                } label: {
                    Label("View options", systemImage: "slider.horizontal.3")
                }
                .accessibilityLabel("View options")
            }
        }
        .overlay(alignment: .top) {
            if let error = model.errorMessage {
                ErrorBanner(message: error) { model.errorMessage = nil }
                    .padding()
            }
        }
        .task { await model.start() }
        .task(id: model.selectedMonitorID) {
            await model.loadHistory()
        }
        .onChange(of: filtered.map(\.monitor.id)) { _, visibleIDs in
            guard filter != .recent,
                  let selectedMonitorID = model.selectedMonitorID,
                  !visibleIDs.contains(selectedMonitorID) else { return }
            model.selectedMonitorID = nil
        }
    }

    /// The list is the user-owned selection surface. Programmatic changes (routing a
    /// notification, restoring a snapshot, or clearing an invalid filter selection)
    /// update `selectedMonitorID` directly and must not silently acknowledge activity.
    private var monitorSelection: Binding<MonitorID?> {
        Binding(
            get: { model.selectedMonitorID },
            set: { monitorID in
                Task { await model.selectMonitor(monitorID) }
            }
        )
    }

    private func presentationBinding<Value>(
        _ keyPath: WritableKeyPath<MonitorPresentationPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.monitorPresentation[keyPath: keyPath] },
            set: { value in
                var updated = model.monitorPresentation
                updated[keyPath: keyPath] = value
                Task { await model.saveMonitorPresentation(updated) }
            }
        )
    }
}

private enum DashboardFilter: String, CaseIterable, Identifiable {
    case all
    case recent
    case attention
    case running
    case approval

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: String(localized: "All", bundle: .module)
        case .recent: String(localized: "Recent", bundle: .module)
        case .attention: String(localized: "Attention", bundle: .module)
        case .running: String(localized: "Running", bundle: .module)
        case .approval: String(localized: "Approval", bundle: .module)
        }
    }
    var systemImage: String {
        switch self {
        case .all: "rectangle.3.group"
        case .recent: "clock.badge.checkmark"
        case .attention: "exclamationmark.octagon"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .approval: "pause.circle"
        }
    }
}

private struct MonitorDashboardRow: View {
    let observation: MonitorObservation
    let refreshIntervalSeconds: Int
    let approvalDetectedAt: Date?
    let isUnseen: Bool
    let isFavoriteToggleDisabled: Bool
    let openApproval: () -> Void
    let toggleFavorite: () -> Void

    private var state: ObservationVisualState {
        observation.visualState(refreshIntervalSeconds: refreshIntervalSeconds)
    }

    private var summary: DashboardRunSummaryDisplay {
        DashboardRunSummaryPresentation.display(
            for: observation.lastKnownRun,
            fallbackBranchName: observation.monitor.id.target.displayName,
            approvalDetectedAt: approvalDetectedAt
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            StatusGlyph(
                symbol: state.symbolName,
                color: state.tint,
                label: state.title,
                size: 18
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(observation.monitor.repositoryName)
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isUnseen {
                        Text("NEW")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.16), in: Capsule())
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityLabel("New activity")
                    }
                }
                HStack(spacing: 5) {
                    if let author = summary.author {
                        Text(author)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                    }
                    if observation.lastKnownRun != nil {
                        if summary.author != nil {
                            Text("·")
                        }
                        PipelineRunOriginBadge(display: summary.origin)
                    }
                    if observation.monitor.isProduction {
                        ProductionBadge()
                    }
                    if let reference = summary.origin.reference {
                        if summary.author != nil || summary.origin.badgeTitle != nil {
                            Text("·")
                        }
                        Text(reference)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let metadata = summary.metadata {
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(summary.contextualStep == nil ? .secondary : state.tint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let run = observation.lastKnownRun,
                   PipelineDetailPresentation.shouldShowApprovalAction(for: run) {
                    Button {
                        openApproval()
                    } label: {
                        Label("Open approval in Bitbucket", systemImage: "safari")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Open this pending approval in Bitbucket")
                    .accessibilityLabel("Open approval in Bitbucket for \(observation.monitor.repositoryName)")
                    .accessibilityHint("Opens the pending build approval in Bitbucket")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: toggleFavorite) {
                Image(systemName: observation.monitor.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(observation.monitor.isFavorite ? .yellow : .secondary)
                    .frame(width: 22, height: 22)
                    .frame(
                        width: DashboardRepositoryRowMetrics.favoriteButtonHitTargetSize,
                        height: DashboardRepositoryRowMetrics.favoriteButtonHitTargetSize
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(isFavoriteToggleDisabled)
            .help(observation.monitor.isFavorite ? "Remove from favorites" : "Add to favorites")
            .accessibilityLabel(observation.monitor.isFavorite ? "Remove \(observation.monitor.repositoryName) from favorites" : "Add \(observation.monitor.repositoryName) to favorites")

            VStack(alignment: .trailing, spacing: 3) {
                if let run = observation.lastKnownRun {
                    Text("#\(run.buildNumber)")
                        .font(.body.monospacedDigit())
                        .lineLimit(1)
                    if let activityDate = run.completedAt ?? run.startedAt {
                        Text(activityDate, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityLabel(ageAccessibilityLabel(for: activityDate))
                    } else if let hash = run.commitHash {
                        Text(String(hash.prefix(7)))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: DashboardRepositoryRowMetrics.metadataColumnWidth, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .frame(minHeight: DashboardRepositoryRowMetrics.minimumHeight)
        .listRowBackground(isUnseen ? Color.accentColor.opacity(0.08) : Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityValue(summary.accessibilityLabel ?? state.title)
    }

    private func ageAccessibilityLabel(for date: Date) -> String {
        let format = String(
            localized: "pipeline.summary.accessibility.age.format",
            defaultValue: "Build age: %@",
            bundle: .module
        )
        return String(format: format, date.formatted(.relative(presentation: .named)))
    }
}

private struct ProductionBadge: View {
    var body: some View {
        Text("Production")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.orange.opacity(0.14), in: Capsule())
            .overlay {
                Capsule().strokeBorder(.orange.opacity(0.38), lineWidth: 1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Production monitor")
    }
}

private struct SidebarChoice: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var subtitle: String?
    var badgeCount: Int?
    let action: () -> Void

    init(
        title: String,
        systemImage: String,
        isSelected: Bool,
        subtitle: String? = nil,
        badgeCount: Int? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.subtitle = subtitle
        self.badgeCount = badgeCount
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let badgeCount, badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .accessibilityLabel(
                            String.localizedStringWithFormat(
                                String(localized: "%lld new activities", bundle: .module),
                                Int64(badgeCount)
                            )
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct DashboardRefreshStatus: View {
    @Bindable var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: 9) {
                StatusGlyph(
                    symbol: model.aggregateState.symbolName,
                    color: model.aggregateState.tint,
                    label: model.aggregateState.title,
                    size: 14
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.freshnessText)
                        .font(.caption.weight(.medium))
                    Text(nextRefreshText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing pipelines")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    private var nextRefreshText: String {
        guard let snapshot = model.snapshot else {
            return model.isConnected
                ? String(localized: "Preparing automatic checks", bundle: .module)
                : String(localized: "Connect an account to begin monitoring", bundle: .module)
        }
        guard let nextRefreshAt = snapshot.nextRefreshAt else {
            return snapshot.aggregateState == .unavailable
                ? String(localized: "Automatic checks are paused until the connection is restored", bundle: .module)
                : String(localized: "No automatic check is scheduled", bundle: .module)
        }
        let format = String(localized: "Next check %@", bundle: .module)
        return String(format: format, nextRefreshAt.formatted(.relative(presentation: .named)))
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message).lineLimit(2)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 5, y: 2)
        .accessibilityElement(children: .combine)
    }
}
