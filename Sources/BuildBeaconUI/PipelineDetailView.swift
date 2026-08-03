import BuildBeaconKit
import Foundation
import SwiftUI

public struct PipelineDetailView: View {
    let observation: MonitorObservation
    let refreshIntervalSeconds: Int
    let selectedHistory: [PipelineHistoryEntry]
    let notificationBuildNumber: Int?
    let approvalDetectedAt: Date?
    let mergeReadiness: PullRequestMergeReadinessDisplay?
    let openPipeline: (MonitorObservation) -> Void
    let openNotificationBuild: (Int) -> Void
    let openApproval: () -> Void
    let beginMerge: () -> Void
    let openCommit: (PipelineRun) -> Void
    let openPullRequest: (PipelinePullRequestContext) -> Void

    public init(
        observation: MonitorObservation,
        refreshIntervalSeconds: Int,
        selectedHistory: [PipelineHistoryEntry] = [],
        notificationBuildNumber: Int? = nil,
        approvalDetectedAt: Date? = nil,
        mergeReadiness: PullRequestMergeReadinessDisplay? = nil,
        openURL: @escaping (MonitorObservation) -> Void,
        openNotificationBuild: @escaping (Int) -> Void = { _ in },
        openApproval: @escaping () -> Void = {},
        beginMerge: @escaping () -> Void = {},
        openCommit: @escaping (PipelineRun) -> Void = { _ in },
        openPullRequest: @escaping (PipelinePullRequestContext) -> Void = { _ in }
    ) {
        self.observation = observation
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.selectedHistory = selectedHistory
        self.notificationBuildNumber = notificationBuildNumber
        self.approvalDetectedAt = approvalDetectedAt
        self.mergeReadiness = mergeReadiness
        openPipeline = openURL
        self.openNotificationBuild = openNotificationBuild
        self.openApproval = openApproval
        self.beginMerge = beginMerge
        self.openCommit = openCommit
        self.openPullRequest = openPullRequest
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if let failure = observation.currentFailure {
                    Label(failureTitle(failure), systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }

                if let run = observation.lastKnownRun {
                    runMetadata(run)
                    if PipelineDetailPresentation.shouldShowApprovalAction(for: run) {
                        approvalRequiredCard(run)
                    } else if let mergeReadiness, mergeReadiness.isReady {
                        readyToMergeCard(mergeReadiness)
                    }
                    if PipelineDetailPresentation.shouldShowNotificationBuildCallout(
                        notificationBuildNumber: notificationBuildNumber,
                        currentBuildNumber: run.buildNumber
                    ), let notificationBuildNumber {
                        notificationBuildCallout(notificationBuildNumber)
                    }
                    sourceContext(run)
                    steps(run.steps)
                    timeline
                } else {
                    ContentUnavailableView(
                        "No Pipeline Run",
                        systemImage: "tray",
                        description: Text("No run was returned for this target yet.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(24)
        }
        .navigationTitle(observation.monitor.repositoryName)
        .toolbar {
            Button {
                openPipeline(observation)
            } label: {
                Label("Open in Bitbucket", systemImage: "safari")
            }
            .disabled(observation.lastKnownRun == nil)

            if let run = observation.lastKnownRun,
               PipelineDetailPresentation.shouldShowApprovalAction(for: run) {
                Button {
                    openApproval()
                } label: {
                    Label("Open approval in Bitbucket", systemImage: "checkmark.circle")
                }
                .accessibilityHint("Opens the pending build approval in Bitbucket")
            } else if let mergeReadiness,
                      let target = mergeReadiness.target {
                Button {
                    beginMerge()
                } label: {
                    Label("Approve and merge…", systemImage: "arrow.triangle.merge")
                }
                .accessibilityLabel(
                    PullRequestMergePresentation.actionAccessibilityLabel(
                        target: target,
                        repositoryName: observation.monitor.repositoryName
                    )
                )
                .accessibilityHint("Opens a confirmation. Nothing is merged until you confirm.")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            let state = observation.visualState(refreshIntervalSeconds: refreshIntervalSeconds)
            let originDisplay = PipelineRunOriginPresentation.display(
                for: observation.lastKnownRun?.origin ?? .unknown,
                fallbackBranchName: observation.lastKnownRun?.branchName ?? observation.monitor.id.target.displayName
            )
            StatusGlyph(symbol: state.symbolName, color: state.tint, label: state.title, size: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(observation.monitor.repositoryName)
                        .font(.largeTitle.bold())
                    if observation.lastKnownRun != nil {
                        PipelineRunOriginBadge(display: originDisplay)
                    }
                }
                HStack(spacing: 5) {
                    Text(observation.monitor.workspaceName)
                    if let reference = originDisplay.reference {
                        Text("·")
                        Text(reference)
                    }
                }
                    .foregroundStyle(.secondary)
                if let project = observation.monitor.projectName {
                    Text(project)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func runMetadata(_ run: PipelineRun) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 8) {
            GridRow {
                Text("Build").foregroundStyle(.secondary)
                Text(PipelineDetailPresentation.buildTitle(run.buildNumber)).monospacedDigit()
            }
            GridRow { Text("Status").foregroundStyle(.secondary); Label(run.phase.title, systemImage: run.phase.symbolName) }
            if let hash = run.commitHash {
                GridRow { Text("Commit").foregroundStyle(.secondary); Text(String(hash.prefix(12))).monospaced() }
            }
            if let started = run.startedAt {
                GridRow { Text("Started").foregroundStyle(.secondary); Text(started, format: .dateTime) }
            }
            if let duration = PipelineDetailPresentation.duration(of: run) {
                GridRow { Text("Duration").foregroundStyle(.secondary); Text(duration.formatted(.units())) }
            }
            if let reason = run.failureReason {
                GridRow { Text("Reason").foregroundStyle(.secondary); Text(reason) }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private func approvalRequiredCard(_ run: PipelineRun) -> some View {
        let summary = DashboardRunSummaryPresentation.display(
            for: run,
            approvalDetectedAt: approvalDetectedAt
        )
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.blue)
                .font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Approval required")
                        .font(.body.weight(.semibold))
                    if observation.monitor.isProduction {
                        ProductionDetailBadge()
                    }
                }
                Text(summary.approvalWait ?? "Waiting for approval")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Open approval in Bitbucket") {
                openApproval()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private func readyToMergeCard(_ display: PullRequestMergeReadinessDisplay) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(.green)
                .font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Ready to merge")
                        .font(.body.weight(.semibold))
                    if observation.monitor.isProduction {
                        ProductionDetailBadge()
                    }
                }
                Text(display.detail ?? "All merge prerequisites are available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Approve and merge…") {
                beginMerge()
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .accessibilityHint("Opens a confirmation. Nothing is merged until you confirm.")
        }
        .padding(12)
        .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private func notificationBuildCallout(_ buildNumber: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "bell.badge")
                .foregroundStyle(.secondary)
            Text(PipelineDetailPresentation.notificationBuildCalloutTitle(buildNumber))
                .font(.body.weight(.medium))
            Spacer(minLength: 8)
            Button(PipelineDetailPresentation.openOriginalBuildTitle) {
                openNotificationBuild(buildNumber)
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sourceContext(_ run: PipelineRun) -> some View {
        if run.commitContext != nil || run.pullRequest != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Source")
                    .font(.title2.bold())

                if let commit = run.commitContext {
                    contextCard(
                        title: "Commit",
                        subtitle: commit.message ?? run.commitHash.map { String($0.prefix(12)) } ?? "Commit details unavailable",
                        detail: PipelineDetailPresentation.commitDetail(for: commit),
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        actionTitle: "Open Commit",
                        action: commit.webURL.map { _ in { openCommit(run) } }
                    )
                }

                if let pullRequest = run.pullRequest {
                    contextCard(
                        title: PipelineDetailPresentation.pullRequestTitle(pullRequest.id),
                        subtitle: pullRequest.title,
                        detail: pullRequest.state,
                        systemImage: "arrow.triangle.pull",
                        actionTitle: "Open Pull Request",
                        action: pullRequest.webURL.map { _ in { openPullRequest(pullRequest) } }
                    )
                }
            }
        }
    }

    private func contextCard(
        title: String,
        subtitle: String,
        detail: String?,
        systemImage: String,
        actionTitle: String,
        action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(subtitle).lineLimit(2)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func steps(_ steps: [PipelineStep]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Steps")
                .font(.title2.bold())

            if steps.isEmpty {
                Text("Step details are not available for this run.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                ForEach(steps) { step in
                    HStack(spacing: 12) {
                        StatusGlyph(symbol: step.phase.symbolName, color: step.phase.tint, label: step.phase.title, size: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.name).font(.body.weight(.medium))
                            Text(step.phase.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let start = step.startedAt, let end = step.completedAt {
                            Text(Duration.seconds(end.timeIntervalSince(start)).formatted(.units()))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Runs")
                .font(.title2.bold())

            let entries = PipelineDetailPresentation.timeline(
                current: observation.lastKnownRun,
                monitorID: observation.monitor.id,
                selectedHistory: selectedHistory
            )
            if entries.isEmpty {
                Text("No recent pipeline history is available yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    timelineRow(entry, previous: entries[safe: index + 1])
                }
            }
        }
    }

    private func timelineRow(_ entry: PipelineHistoryEntry, previous: PipelineHistoryEntry?) -> some View {
        HStack(spacing: 12) {
            StatusGlyph(symbol: entry.phase.symbolName, color: entry.phase.tint, label: entry.phase.title, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(PipelineDetailPresentation.buildTitle(entry.buildNumber)).font(.body.weight(.medium))
                Text(entry.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? PipelineDetailPresentation.startTimeUnavailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(PipelineDetailPresentation.durationText(for: entry))
                    .font(.caption.monospacedDigit())
                if let comparison = PipelineDetailPresentation.durationComparison(for: entry, previous: previous) {
                    Text(comparison)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func failureTitle(_ failure: ObservationFailure) -> String {
        switch failure {
        case .invalidCredentials: "Authentication is required. Update the API token in Settings."
        case .insufficientPermissions: "The API token does not have the required permissions."
        case let .rateLimited(retryAt): retryAt.map { "Rate limited until \($0.formatted(date: .omitted, time: .shortened))." } ?? "Bitbucket rate limit reached."
        case .offline: "The network is offline. Showing the last known result."
        case .timedOut: "The request timed out. Showing the last known result."
        case .notFound: "The repository or pipeline could not be found."
        case .malformedResponse: "Bitbucket returned an unsupported response."
        case let .server(status): "Bitbucket returned server error \(status)."
        case .keychain: "The saved credential is unavailable."
        case .persistence: "The local configuration could not be read."
        case .cancelled: "The refresh was cancelled."
        case .unexpected: "An unexpected error occurred."
        }
    }
}

private struct ProductionDetailBadge: View {
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
            .accessibilityLabel("Production monitor")
    }
}

enum PipelineDetailPresentation {
    static func shouldShowApprovalAction(for run: PipelineRun) -> Bool {
        run.phase == .awaitingApproval && run.buildNumber > 0
    }

    static var startTimeUnavailable: String {
        String(
            localized: "pipeline.detail.startTime.unavailable",
            defaultValue: "Start time unavailable",
            bundle: .module
        )
    }

    static func buildTitle(_ buildNumber: Int) -> String {
        let format = String(
            localized: "pipeline.detail.build.title.format",
            defaultValue: "Build #%lld",
            bundle: .module
        )
        return String(format: format, Int64(buildNumber))
    }

    static func pullRequestTitle(_ identifier: Int) -> String {
        let format = String(
            localized: "pipeline.detail.pullRequest.title.format",
            defaultValue: "Pull Request #%lld",
            bundle: .module
        )
        return String(format: format, Int64(identifier))
    }

    static var openOriginalBuildTitle: String {
        String(
            localized: "pipeline.detail.notification.openOriginalBuild",
            defaultValue: "Open Original Build",
            bundle: .module
        )
    }

    static func notificationBuildCalloutTitle(_ buildNumber: Int) -> String {
        let format = String(
            localized: "pipeline.detail.notification.originalBuild.format",
            defaultValue: "Notification was for build #%lld",
            bundle: .module
        )
        return String(format: format, Int64(buildNumber))
    }

    static func shouldShowNotificationBuildCallout(
        notificationBuildNumber: Int?,
        currentBuildNumber: Int
    ) -> Bool {
        notificationBuildNumber.map { $0 != currentBuildNumber } ?? false
    }

    static func duration(of run: PipelineRun) -> Duration? {
        guard let startedAt = run.startedAt, let completedAt = run.completedAt, completedAt >= startedAt else { return nil }
        return .seconds(completedAt.timeIntervalSince(startedAt))
    }

    static func durationText(for run: PipelineRun) -> String {
        guard let duration = duration(of: run) else { return durationUnavailable }
        return duration.formatted(.units())
    }

    static func durationText(for entry: PipelineHistoryEntry) -> String {
        guard let duration = duration(startedAt: entry.startedAt, completedAt: entry.completedAt) else {
            return durationUnavailable
        }
        return duration.formatted(.units())
    }

    static func durationComparison(for run: PipelineRun, previous: PipelineRun?) -> String? {
        guard let current = durationSeconds(startedAt: run.startedAt, completedAt: run.completedAt),
              let previous,
              let prior = durationSeconds(startedAt: previous.startedAt, completedAt: previous.completedAt)
        else { return nil }
        return durationComparison(current: current, prior: prior)
    }

    static func durationComparison(
        for entry: PipelineHistoryEntry,
        previous: PipelineHistoryEntry?
    ) -> String? {
        guard let current = durationSeconds(startedAt: entry.startedAt, completedAt: entry.completedAt),
              let previous,
              let prior = durationSeconds(startedAt: previous.startedAt, completedAt: previous.completedAt)
        else { return nil }
        return durationComparison(current: current, prior: prior)
    }

    static func commitDetail(for context: PipelineCommitContext) -> String? {
        [context.authorName, context.date?.formatted(date: .abbreviated, time: .shortened)]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty
    }

    static func timeline(
        current: PipelineRun?,
        monitorID: MonitorID,
        selectedHistory: [PipelineHistoryEntry]
    ) -> [PipelineHistoryEntry] {
        var seen = Set<PipelineRunID>()
        let currentEntry = current.map {
            PipelineHistoryEntry(
                monitorID: monitorID,
                runID: $0.id,
                buildNumber: $0.buildNumber,
                phase: $0.phase,
                startedAt: $0.startedAt,
                completedAt: $0.completedAt,
                observedAt: $0.completedAt ?? $0.startedAt ?? .now
            )
        }
        return ([currentEntry].compactMap { $0 } + selectedHistory)
            .filter { seen.insert($0.runID).inserted }
    }

    private static func duration(startedAt: Date?, completedAt: Date?) -> Duration? {
        durationSeconds(startedAt: startedAt, completedAt: completedAt).map(Duration.seconds)
    }

    private static func durationSeconds(startedAt: Date?, completedAt: Date?) -> TimeInterval? {
        guard let startedAt, let completedAt, completedAt >= startedAt else { return nil }
        return completedAt.timeIntervalSince(startedAt)
    }

    private static func durationComparison(current: TimeInterval, prior: TimeInterval) -> String {
        let delta = current - prior
        guard delta != 0 else {
            return String(
                localized: "pipeline.detail.duration.same",
                defaultValue: "same duration",
                bundle: .module
            )
        }
        let text = Duration.seconds(abs(delta)).formatted(.units())
        let format = String(
            localized: delta > 0
                ? "pipeline.detail.duration.slower.format"
                : "pipeline.detail.duration.faster.format",
            defaultValue: delta > 0 ? "%@ slower" : "%@ faster",
            bundle: .module
        )
        return String(format: format, text)
    }

    private static var durationUnavailable: String {
        String(
            localized: "pipeline.detail.duration.unavailable",
            defaultValue: "Duration unavailable",
            bundle: .module
        )
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
