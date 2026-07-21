import BuildBeaconKit
import Foundation
import SwiftUI

public struct MenuBarContentView: View {
    @Bindable private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private let openDashboard: @MainActor () -> Void

    public init(model: AppModel, openDashboard: @escaping @MainActor () -> Void) {
        self.model = model
        self.openDashboard = openDashboard
    }

    private var observations: [MonitorObservation] {
        model.sortedObservations
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if !model.isConnected {
                ContentUnavailableView {
                    Label("Connect Bitbucket", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text("Monitor pipeline health directly from the menu bar.")
                } actions: {
                    Button("Get Started") { openWindow(id: "onboarding") }
                        .buttonStyle(.borderedProminent)
                }
                .frame(height: 190)
                .padding(.horizontal, 16)
            } else if model.configuration.monitors.isEmpty {
                ContentUnavailableView {
                    Label("No Monitors", systemImage: "tray")
                } description: {
                    Text("Add a repository in Settings to begin monitoring.")
                } actions: {
                    Button("Open Settings") { openSettings() }
                }
                .frame(height: 180)
                .padding(.horizontal, 16)
            } else if observations.isEmpty {
                ContentUnavailableView(
                    "Waiting for Pipeline Data",
                    systemImage: "arrow.clockwise",
                    description: Text("Build Beacon is preparing the first reliable snapshot.")
                )
                .frame(height: 180)
                .padding(.horizontal, 16)
            } else {
                statusSummary
                priorityMonitorAction

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(observations.prefix(12)), id: \.monitor.id) { observation in
                            MonitorCompactRow(
                                observation: observation,
                                refreshIntervalSeconds: model.refreshIntervalSeconds
                            ) {
                                model.selectedMonitorID = observation.monitor.id
                                Task { await model.markActivitySeen(for: observation) }
                                openDashboard()
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 420)

                if observations.count > 12 {
                    Button {
                        openDashboard()
                    } label: {
                        Label("Show all \(observations.count) monitors", systemImage: "list.bullet")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }

            Divider()
            actions
        }
        .frame(width: 360)
        .background(.regularMaterial)
        .onAppear { model.startIfNeeded() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusGlyph(
                symbol: BuildBeaconBrand.symbolName,
                color: Color.accentColor,
                label: "Build Beacon",
                size: 22
            )

            VStack(alignment: .leading, spacing: 3) {
                Text("Build Beacon")
                    .font(.headline)
                Text(model.aggregateState.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(model.freshnessText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing pipelines")
            }
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Build Beacon. \(model.aggregateState.title). \(model.freshnessText).")
        .help("\(model.aggregateState.title). \(model.freshnessText)")
    }

    /// Keeps the most important operational counts visible without changing the
    /// height of the popover as pipelines transition between states.
    private var statusSummary: some View {
        let summary = MenuStatusSummary(
            observations: observations,
            aggregateState: model.aggregateState
        )

        return HStack(spacing: 6) {
            if summary.hasActionablePipelines {
                if summary.pipelineFailureCount > 0 {
                    MenuStatusPill(
                        title: String(localized: "\(summary.pipelineFailureCount) needs attention"),
                        symbol: "exclamationmark.octagon.fill",
                        tint: .red,
                        accessibilityLabel: String(localized: "\(summary.pipelineFailureCount) monitored pipelines need attention")
                    )
                }
                if summary.approvalCount > 0 {
                    MenuStatusPill(
                        title: String(localized: "\(summary.approvalCount) awaiting approval"),
                        symbol: "pause.circle.fill",
                        tint: .blue,
                        accessibilityLabel: String(localized: "\(summary.approvalCount) monitored pipelines are awaiting approval")
                    )
                }
                if summary.runningCount > 0 {
                    MenuStatusPill(
                        title: String(localized: "\(summary.runningCount) running"),
                        symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                        tint: .orange,
                        accessibilityLabel: String(localized: "\(summary.runningCount) monitored pipelines are running or queued")
                    )
                }
                if summary.reviewCount > 0 {
                    MenuStatusPill(
                        title: String(localized: "\(summary.reviewCount) needs attention"),
                        symbol: "questionmark.circle",
                        tint: .secondary,
                        accessibilityLabel: String(localized: "\(summary.reviewCount) monitored pipelines need attention")
                    )
                }
            } else if summary.isHealthy {
                MenuStatusPill(
                    title: String(localized: "All observed pipelines are healthy"),
                    symbol: "checkmark.circle.fill",
                    tint: .green,
                    accessibilityLabel: String(localized: "All observed pipelines are healthy")
                )
            } else if let availabilityTitle = summary.availabilityTitle {
                MenuStatusPill(
                    title: availabilityTitle,
                    symbol: summary.availabilitySymbol,
                    tint: .secondary,
                    accessibilityLabel: availabilityTitle
                )
            }

            Spacer(minLength: 0)

            if summary.hasActionablePipelines,
               let availabilityTitle = summary.availabilityTitle {
                Label(availabilityTitle, systemImage: summary.availabilitySymbol)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(availabilityTitle)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(.quaternary.opacity(0.45))
        .accessibilityElement(children: .contain)
        .help("\(summary.accessibilityDescription). \(model.freshnessText)")
    }

    private var priorityMonitorAction: some View {
        Group {
            if let observation = observations.first {
                Button {
                    model.selectedMonitorID = observation.monitor.id
                    Task { await model.markActivitySeen(for: observation) }
                    openDashboard()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.right.circle")
                            .foregroundStyle(observation.visualState(
                                refreshIntervalSeconds: model.refreshIntervalSeconds
                            ).tint)
                        Text("Open priority monitor")
                            .font(.caption.weight(.semibold))
                        Text(observation.monitor.repositoryName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Open priority monitor, \(observation.monitor.repositoryName)"))
                .accessibilityHint(String(localized: "Opens the most urgent monitored pipeline in the dashboard"))
                .help(String(localized: "Open \(observation.monitor.repositoryName), the highest-priority monitored pipeline"))
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 2) {
            MenuActionButton(title: "Refresh Now", systemImage: "arrow.clockwise", shortcut: "⌘R") {
                Task { await model.refresh() }
            }
            .disabled(model.isRefreshing || !model.isConnected)

            MenuActionButton(title: "Open Dashboard…", systemImage: "rectangle.3.group", shortcut: "⌘O") {
                openDashboard()
            }

            MenuActionButton(title: "Settings…", systemImage: "gearshape", shortcut: "⌘,") {
                openSettings()
            }

            MenuActionButton(title: "Quit Build Beacon", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
    }
}

private struct MenuStatusSummary {
    let pipelineFailureCount: Int
    let runningCount: Int
    let approvalCount: Int
    let reviewCount: Int
    let availabilityFailureCount: Int
    let hasAuthenticationFailure: Bool
    let hasOfflineFailure: Bool
    let aggregateState: AggregateState

    init(observations: [MonitorObservation], aggregateState: AggregateState) {
        pipelineFailureCount = observations.count { observation in
            return switch observation.lastKnownRun?.phase {
            case .failed?, .errored?, .expired?: true
            default: false
            }
        }
        approvalCount = observations.count { observation in
            observation.currentFailure == nil && observation.lastKnownRun?.phase == .awaitingApproval
        }
        runningCount = observations.count { observation in
            guard observation.currentFailure == nil else { return false }
            return switch observation.lastKnownRun?.phase {
            case .queued?, .running?: true
                default: false
            }
        }
        reviewCount = observations.count { observation in
            guard observation.currentFailure == nil else { return false }
            return switch observation.lastKnownRun?.phase {
            case .stopped?, .unknown?: true
            default: false
            }
        }
        availabilityFailureCount = observations.count { $0.currentFailure != nil }
        hasAuthenticationFailure = observations.contains { observation in
            switch observation.currentFailure {
            case .invalidCredentials?, .insufficientPermissions?: true
            default: false
            }
        }
        hasOfflineFailure = observations.contains { observation in
            switch observation.currentFailure {
            case .offline?, .timedOut?: true
            default: false
            }
        }
        self.aggregateState = aggregateState
    }

    var hasActionablePipelines: Bool {
        pipelineFailureCount > 0 || runningCount > 0 || approvalCount > 0 || reviewCount > 0
    }

    var isHealthy: Bool {
        aggregateState == .healthy
    }

    var availabilityTitle: String? {
        return switch aggregateState {
        case .unavailable:
            hasAuthenticationFailure
                ? String(localized: "Authentication required")
                : hasOfflineFailure
                    ? String(localized: "Offline · showing last known result")
                    : availabilityFailureCount > 0
                        ? String(localized: "Connection needs attention")
                        : String(localized: "Unavailable")
        case .stale:
            String(localized: "Data is stale")
        default:
            nil
        }
    }

    var availabilitySymbol: String {
        aggregateState == .stale ? "clock.badge.exclamationmark" : "wifi.exclamationmark"
    }

    var accessibilityDescription: String {
        var components: [String] = []
        if pipelineFailureCount > 0 {
            components.append(String(localized: "\(pipelineFailureCount) needs attention"))
        }
        if approvalCount > 0 { components.append(String(localized: "\(approvalCount) awaiting approval")) }
        if runningCount > 0 { components.append(String(localized: "\(runningCount) running")) }
        if reviewCount > 0 { components.append(String(localized: "\(reviewCount) needs attention")) }
        if let availabilityTitle { components.append(availabilityTitle) }
        if !components.isEmpty { return components.joined(separator: ", ") }
        return isHealthy
            ? String(localized: "All observed pipelines are healthy")
            : String(localized: "Unavailable")
    }
}

private struct MenuStatusPill: View {
    let title: String
    let symbol: String
    let tint: Color
    let accessibilityLabel: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .accessibilityLabel(accessibilityLabel)
    }
}

private struct MonitorCompactRow: View {
    let observation: MonitorObservation
    let refreshIntervalSeconds: Int
    let action: () -> Void

    private var state: ObservationVisualState {
        observation.visualState(refreshIntervalSeconds: refreshIntervalSeconds)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                StatusGlyph(
                    symbol: state.symbolName,
                    color: state.tint,
                    label: state.title
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(observation.monitor.repositoryName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(observation.lastKnownRun?.branchName ?? observation.monitor.id.target.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(state.title)
                        .font(.caption.weight(.medium))
                    if let build = observation.lastKnownRun?.buildNumber {
                        Text("#\(build)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens pipeline details")
    }
}

private struct MenuActionButton: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    let action: () -> Void

    init(title: String, systemImage: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
