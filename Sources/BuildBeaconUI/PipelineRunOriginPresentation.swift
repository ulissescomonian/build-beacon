import BuildBeaconKit
import SwiftUI

struct PipelineRunOriginDisplay: Equatable {
    let badgeTitle: String?
    let reference: String?
    let accessibilityLabel: String?
    let badgeStyle: PipelineRunOriginBadgeStyle?
}

enum PipelineRunOriginBadgeStyle: Equatable {
    case branch
    case pullRequest
}

enum PipelineRunOriginPresentation {
    static func display(for run: PipelineRun) -> PipelineRunOriginDisplay {
        display(for: run.origin, fallbackBranchName: run.branchName)
    }

    static func display(
        for origin: PipelineRunOrigin,
        fallbackBranchName: String? = nil
    ) -> PipelineRunOriginDisplay {
        let fallback = nonempty(fallbackBranchName)

        switch origin {
        case let .branch(name):
            let branchName = nonempty(name) ?? fallback
            return PipelineRunOriginDisplay(
                badgeTitle: branchBadgeTitle,
                reference: branchName,
                accessibilityLabel: branchAccessibilityLabel,
                badgeStyle: .branch
            )

        case let .pullRequest(id, sourceBranch, destinationBranch):
            let badgeTitle = pullRequestBadgeTitle(id: id)
            return PipelineRunOriginDisplay(
                badgeTitle: badgeTitle,
                reference: pullRequestReference(
                    sourceBranch: sourceBranch,
                    destinationBranch: destinationBranch,
                    fallback: fallback
                ),
                accessibilityLabel: pullRequestAccessibilityLabel(id: id),
                badgeStyle: .pullRequest
            )

        case .unknown:
            return PipelineRunOriginDisplay(
                badgeTitle: nil,
                reference: fallback,
                accessibilityLabel: nil,
                badgeStyle: nil
            )
        }
    }

    static var branchBadgeTitle: String {
        String(
            localized: "pipeline.origin.badge.branch",
            defaultValue: "Branch",
            bundle: .module
        )
    }

    static var pullRequestBadgeTitle: String {
        String(
            localized: "pipeline.origin.badge.pullRequest",
            defaultValue: "PR",
            bundle: .module
        )
    }

    static func pullRequestBadgeTitle(id: Int?) -> String {
        guard let id else { return pullRequestBadgeTitle }
        let format = String(
            localized: "pipeline.origin.badge.pullRequest.format",
            defaultValue: "PR #%lld",
            bundle: .module
        )
        return String(format: format, Int64(id))
    }

    private static var branchAccessibilityLabel: String {
        String(
            localized: "pipeline.origin.accessibility.branch",
            defaultValue: "Branch pipeline",
            bundle: .module
        )
    }

    private static func pullRequestAccessibilityLabel(id: Int?) -> String {
        guard let id else {
            return String(
                localized: "pipeline.origin.accessibility.pullRequest",
                defaultValue: "Pull request pipeline",
                bundle: .module
            )
        }
        let format = String(
            localized: "pipeline.origin.accessibility.pullRequest.format",
            defaultValue: "Pull request number %lld",
            bundle: .module
        )
        return String(format: format, Int64(id))
    }

    private static func pullRequestReference(
        sourceBranch: String?,
        destinationBranch: String?,
        fallback: String?
    ) -> String? {
        let source = nonempty(sourceBranch)
        let destination = nonempty(destinationBranch)

        switch (source, destination) {
        case let (.some(source), .some(destination)):
            return "\(source) → \(destination)"
        case let (.some(source), nil):
            return source
        case let (nil, .some(destination)):
            return destination
        case (nil, nil):
            return fallback
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct PipelineRunOriginBadge: View {
    let display: PipelineRunOriginDisplay

    init(run: PipelineRun) {
        display = PipelineRunOriginPresentation.display(for: run)
    }

    init(display: PipelineRunOriginDisplay) {
        self.display = display
    }

    var body: some View {
        if let title = display.badgeTitle {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(foregroundStyle)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(backgroundStyle, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(borderStyle, lineWidth: 1)
                }
                .accessibilityLabel(display.accessibilityLabel ?? title)
        }
    }

    private var foregroundStyle: Color {
        switch display.badgeStyle {
        case .pullRequest:
            .pink
        case .branch, .none:
            .secondary
        }
    }

    private var backgroundStyle: Color {
        switch display.badgeStyle {
        case .pullRequest:
            .pink.opacity(0.16)
        case .branch, .none:
            .secondary.opacity(0.12)
        }
    }

    private var borderStyle: Color {
        switch display.badgeStyle {
        case .pullRequest:
            .pink.opacity(0.42)
        case .branch, .none:
            .secondary.opacity(0.22)
        }
    }
}
