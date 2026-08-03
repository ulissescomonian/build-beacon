import BuildBeaconKit
import SwiftUI

struct PullRequestMergeConfirmationView: View {
    let state: PullRequestActionSheetState
    let retainedPreflight: PullRequestMergePreflight?
    let repositoryName: String
    let accountName: String
    let canOpenPullRequest: Bool
    @Binding var selectedStrategy: PullRequestMergeStrategy
    let confirm: (PullRequestMergeStrategy) -> Void
    let retry: () -> Void
    let openPullRequest: () -> Void
    let dismiss: () -> Void

    @AccessibilityFocusState private var resultFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
        }
        .padding(22)
        .frame(width: 540)
        .interactiveDismissDisabled(isExecuting)
        .onChange(of: state) { _, newValue in
            switch newValue {
            case .completed, .failed:
                resultFocused = true
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .loading:
            progress(
                title: PullRequestMergePresentation.operationTitle(.preflighting),
                detail: String(localized: "Build Beacon is checking the current pull request state in Bitbucket.", bundle: .module),
                allowsCancel: true
            )
        case let .confirmation(preflight):
            confirmation(preflight)
        case let .executing(preflight, phase):
            progress(
                title: PullRequestMergePresentation.operationTitle(phase),
                detail: executionDetail(preflight),
                allowsCancel: false
            )
        case let .completed(outcome):
            result(
                PullRequestMergePresentation.outcome(outcome),
                context: retainedPreflight.flatMap {
                    PullRequestMergePresentation.outcomeContext(outcome, preflight: $0)
                },
                allowsRetry: shouldAllowRefresh(for: outcome)
            )
        case let .failed(error):
            result(
                PullRequestMergePresentation.error(error),
                context: nil,
                allowsRetry: error != .outcomeUnknown
            )
        }
    }

    private func confirmation(_ preflight: PullRequestMergePreflight) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Approve and merge pull request?", systemImage: "arrow.triangle.merge")
                .font(.title2.bold())
            Text(PullRequestMergePresentation.confirmationMessage(preflight: preflight, accountName: accountName))
                .foregroundStyle(.secondary)

            if preflight.target.isProduction {
                Label("Production merge", systemImage: "exclamationmark.triangle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            confirmationGrid(preflight)

            Picker("Merge strategy", selection: $selectedStrategy) {
                ForEach(preflight.availableStrategies, id: \.self) { strategy in
                    Text(PullRequestMergePresentation.strategyTitle(strategy)).tag(strategy)
                }
            }
            .pickerStyle(.radioGroup)

            HStack {
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Approve and merge", role: .destructive) {
                    confirm(selectedStrategy)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!preflight.availableStrategies.contains(selectedStrategy))
            }
        }
        .onAppear {
            if !preflight.availableStrategies.contains(selectedStrategy) {
                selectedStrategy = preflight.defaultStrategy
            }
        }
    }

    private func confirmationGrid(_ preflight: PullRequestMergePreflight) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            confirmationRow("Repository", repositoryName)
            confirmationRow("Pull request", "#\(preflight.target.pullRequestID) · \(preflight.title)")
            confirmationRow("Branches", "\(preflight.target.sourceBranch) → \(preflight.target.destinationBranch)")
            GridRow {
                Text("Expected commit").foregroundStyle(.secondary)
                Text(String(preflight.target.expectedSourceCommitHash.prefix(12)))
                    .monospaced()
                    .accessibilityValue(preflight.target.expectedSourceCommitHash)
            }
            confirmationRow("Pipeline build", "#\(preflight.target.buildNumber)")
            confirmationRow(
                "Source branch after merge",
                preflight.closeSourceBranch
                    ? String(localized: "Close source branch", bundle: .module)
                    : String(localized: "Keep source branch open", bundle: .module)
            )
            confirmationRow(
                "Environment",
                preflight.target.isProduction
                    ? String(localized: "Production", bundle: .module)
                    : String(localized: "Not marked as production", bundle: .module)
            )
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func confirmationRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func progress(title: String, detail: String, allowsCancel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(title)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
            Text(
                allowsCancel
                    ? "You can cancel while Build Beacon checks merge readiness."
                    : "Do not close Build Beacon until this operation finishes."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            if allowsCancel {
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel, action: dismiss)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
    }

    private func result(
        _ display: PullRequestMergeResultDisplay,
        context: String?,
        allowsRetry: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(display.title, systemImage: display.symbolName)
                .font(.title2.bold())
                .foregroundStyle(resultColor(display.kind))
                .accessibilityFocused($resultFocused)
            Text(display.message)
                .foregroundStyle(.secondary)
            if let context {
                Text(context)
                    .font(.body.weight(.medium))
            }
            HStack {
                if canOpenPullRequest {
                    Button("Open pull request", action: openPullRequest)
                }
                Spacer()
                if allowsRetry {
                    Button("Refresh status", action: retry)
                }
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func executionDetail(_ preflight: PullRequestMergePreflight) -> String {
        let format = String(
            localized: "pullRequest.merge.execution.detail.format",
            defaultValue: "PR #%lld in %@ is being processed using %@.",
            bundle: .module
        )
        return String(
            format: format,
            Int64(preflight.target.pullRequestID),
            repositoryName,
            PullRequestMergePresentation.strategyTitle(selectedStrategy)
        )
    }

    private func resultColor(_ kind: PullRequestMergeResultDisplay.Kind) -> Color {
        switch kind {
        case .merged: .green
        case .approvedButNotMerged: .orange
        case .unknown: .yellow
        case .failed: .red
        }
    }

    private var isExecuting: Bool {
        if case .executing = state { return true }
        return false
    }

    private func shouldAllowRefresh(for outcome: PullRequestMergeOutcome) -> Bool {
        if case .approvedButNotMerged = outcome { return true }
        return false
    }
}
