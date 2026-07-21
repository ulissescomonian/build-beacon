import BuildBeaconKit
import Foundation
import SwiftUI

struct ObservationVisualState {
    let symbolName: String
    let title: String
    let tint: Color
}

extension MonitorObservation {
    func visualState(refreshIntervalSeconds: Int, now: Date = Date()) -> ObservationVisualState {
        if let failure = currentFailure {
            let title = switch failure {
            case .invalidCredentials: "Authentication required"
            case .insufficientPermissions: "Permission required"
            case .rateLimited: "Rate limited"
            case .offline: "Offline · showing last known result"
            case .timedOut: "Timed out · showing last known result"
            default: "Unavailable · showing last known result"
            }
            return ObservationVisualState(symbolName: "wifi.exclamationmark", title: title, tint: .secondary)
        }

        switch FreshnessPolicy.freshness(
            of: self,
            now: now,
            refreshIntervalSeconds: refreshIntervalSeconds
        ) {
        case .unavailable:
            return ObservationVisualState(symbolName: "wifi.exclamationmark", title: "Unavailable", tint: .secondary)
        case .stale:
            return ObservationVisualState(symbolName: "clock.badge.exclamationmark", title: "Data is stale", tint: .secondary)
        case .fresh:
            guard let phase = lastKnownRun?.phase else {
                return ObservationVisualState(symbolName: "tray", title: "No Pipeline Run", tint: .secondary)
            }
            return ObservationVisualState(symbolName: phase.symbolName, title: phase.title, tint: phase.tint)
        }
    }
}

public extension AggregateState {
    var symbolName: String {
        switch self {
        case .attentionRequired: "exclamationmark.octagon.fill"
        case .unavailable: "wifi.exclamationmark"
        case .stale: "clock.badge.exclamationmark"
        case .awaitingApproval: "pause.circle.fill"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .healthy: "checkmark.circle.fill"
        case .configuredWithoutMonitors: "tray"
        case .notConnected: "bolt.horizontal.circle"
        }
    }

    var title: String {
        switch self {
        case .attentionRequired: "Attention required"
        case .unavailable: "Unavailable"
        case .stale: "Data is stale"
        case .awaitingApproval: "Awaiting approval"
        case .running: "Builds running"
        case .healthy: "All pipelines healthy"
        case .configuredWithoutMonitors: "No monitors selected"
        case .notConnected: "Connect Bitbucket"
        }
    }

    var tint: Color {
        switch self {
        case .attentionRequired: .red
        case .unavailable, .stale: .secondary
        case .awaitingApproval: .blue
        case .running: .orange
        case .healthy: .green
        case .configuredWithoutMonitors, .notConnected: .secondary
        }
    }
}

public extension PipelinePhase {
    var symbolName: String {
        switch self {
        case .queued: "clock"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .awaitingApproval: "pause.circle.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .errored: "exclamationmark.triangle.fill"
        case .expired: "hourglass.badge.minus"
        case .stopped: "stop.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var title: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .awaitingApproval: "Awaiting approval"
        case .succeeded: "Healthy"
        case .failed: "Failed"
        case .errored: "Error"
        case .expired: "Expired"
        case .stopped: "Stopped"
        case .unknown: "Unknown"
        }
    }

    var tint: Color {
        switch self {
        case .succeeded: .green
        case .running, .queued: .orange
        case .awaitingApproval: .blue
        case .failed, .errored, .expired: .red
        case .stopped, .unknown: .secondary
        }
    }
}

public extension PipelineStepPhase {
    var symbolName: String {
        switch self {
        case .queued: "clock"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .awaitingApproval: "pause.circle.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .stopped: "stop.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var title: String {
        switch self {
        case .queued: "Pending"
        case .running: "Running"
        case .awaitingApproval: "Awaiting approval"
        case .succeeded: "Completed"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .unknown: "Unknown"
        }
    }

    var tint: Color {
        switch self {
        case .succeeded: .green
        case .running, .queued: .orange
        case .awaitingApproval: .blue
        case .failed: .red
        case .stopped, .unknown: .secondary
        }
    }
}

public struct StatusGlyph: View {
    private let symbol: String
    private let color: Color
    private let label: String
    private let size: CGFloat

    public init(symbol: String, color: Color, label: String, size: CGFloat = 15) {
        self.symbol = symbol
        self.color = color
        self.label = label
        self.size = size
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel(label)
    }
}
