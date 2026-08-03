import BuildBeaconKit
import Foundation

struct DashboardRunSummaryDisplay: Equatable {
    let author: String?
    let origin: PipelineRunOriginDisplay
    let contextualStep: String?
    let duration: String?
    let approvalWait: String?

    var metadata: String? {
        let text = [contextualStep, approvalWait, duration].compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    var accessibilityLabel: String? {
        let label = [author, origin.accessibilityLabel ?? origin.badgeTitle, origin.reference, contextualStep, approvalWait, durationAccessibilityLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
        return label.isEmpty ? nil : label
    }

    private var durationAccessibilityLabel: String? {
        guard let duration else { return nil }
        let format = String(
            localized: "pipeline.summary.accessibility.duration.format",
            defaultValue: "Build duration: %@",
            bundle: .module
        )
        return String(format: format, duration)
    }
}

enum DashboardRunSummaryPresentation {
    static func display(
        for run: PipelineRun?,
        fallbackBranchName: String? = nil,
        approvalDetectedAt: Date? = nil,
        now: Date = .now
    ) -> DashboardRunSummaryDisplay {
        guard let run else {
            return DashboardRunSummaryDisplay(
                author: nil,
                origin: PipelineRunOriginPresentation.display(for: .unknown, fallbackBranchName: fallbackBranchName),
                contextualStep: nil,
                duration: nil,
                approvalWait: nil
            )
        }

        return DashboardRunSummaryDisplay(
            author: author(for: run),
            origin: PipelineRunOriginPresentation.display(
                    for: run.origin,
                    fallbackBranchName: run.branchName ?? fallbackBranchName
            ),
            contextualStep: contextualStep(for: run),
            duration: PipelineDetailPresentation.duration(of: run)?.formatted(.units()),
            approvalWait: approvalWait(for: run, detectedAt: approvalDetectedAt, now: now)
        )
    }

    private static func author(for run: PipelineRun) -> String? {
        switch run.origin {
        case .pullRequest:
            return nonempty(run.pullRequest?.authorName) ?? authorUnavailable
        case .branch:
            return nonempty(run.commitContext?.authorName) ?? authorUnavailable
        case .unknown:
            return nil
        }
    }

    private static func contextualStep(for run: PipelineRun) -> String? {
        let step: PipelineStep?
        let format: String

        switch run.phase {
        case .failed:
            step = run.steps.first { $0.phase == .failed }
            format = failedStepFormat
        case .running:
            step = run.steps.first { $0.phase == .running }
                ?? run.steps.first { $0.phase == .queued }
            format = runningStepFormat
        case .awaitingApproval:
            step = run.steps.first { $0.phase == .awaitingApproval }
            format = approvalStepFormat
        case .queued:
            step = run.steps.first { $0.phase == .queued }
            format = queuedStepFormat
        case .succeeded, .errored, .expired, .stopped, .unknown:
            return nil
        }

        guard let step else { return nil }
        return String(format: format, step.name)
    }

    private static func approvalWait(for run: PipelineRun, detectedAt: Date?, now: Date) -> String? {
        guard run.phase == .awaitingApproval,
              let detectedAt,
              now >= detectedAt else { return nil }
        let elapsed = Duration.seconds(now.timeIntervalSince(detectedAt)).formatted(.units())
        let format = String(
            localized: "pipeline.summary.approval.detected.format",
            defaultValue: "Detected %@ ago",
            bundle: .module
        )
        return String(format: format, elapsed)
    }

    private static var authorUnavailable: String {
        String(localized: "pipeline.summary.author.unavailable", defaultValue: "Author unavailable", bundle: .module)
    }

    private static var failedStepFormat: String {
        String(localized: "pipeline.summary.step.failed.format", defaultValue: "Failed in %@", bundle: .module)
    }

    private static var runningStepFormat: String {
        String(localized: "pipeline.summary.step.running.format", defaultValue: "Running %@", bundle: .module)
    }

    private static var approvalStepFormat: String {
        String(localized: "pipeline.summary.step.approval.format", defaultValue: "Awaiting approval in %@", bundle: .module)
    }

    private static var queuedStepFormat: String {
        String(localized: "pipeline.summary.step.queued.format", defaultValue: "Queued: %@", bundle: .module)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
