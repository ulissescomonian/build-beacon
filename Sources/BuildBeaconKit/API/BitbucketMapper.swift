import Foundation

enum BitbucketMapper {
    static func account(_ dto: BitbucketUserDTO, email: String) throws -> AccountProfile {
        guard let rawID = nonempty(dto.uuid) ?? nonempty(dto.accountID) else {
            throw BitbucketAPIError.malformedResponse
        }
        let displayName = nonempty(dto.displayName) ?? nonempty(dto.nickname) ?? email
        return AccountProfile(id: AccountID(rawValue: rawID), displayName: displayName, email: email)
    }

    static func workspace(_ dto: BitbucketWorkspaceDTO) throws -> WorkspaceInfo {
        guard let uuid = nonempty(dto.uuid),
              let slug = nonempty(dto.slug) else {
            throw BitbucketAPIError.malformedResponse
        }
        return WorkspaceInfo(
            id: WorkspaceID(rawValue: uuid),
            slug: slug,
            name: nonempty(dto.name) ?? slug
        )
    }

    static func repository(_ dto: BitbucketRepositoryDTO, workspace: WorkspaceInfo) throws -> RepositoryInfo {
        guard let uuid = nonempty(dto.uuid),
              let slug = nonempty(dto.slug) else {
            throw BitbucketAPIError.malformedResponse
        }
        return RepositoryInfo(
            id: RepositoryID(rawValue: uuid),
            workspaceID: workspace.id,
            workspaceSlug: nonempty(dto.workspace?.slug) ?? workspace.slug,
            slug: slug,
            name: nonempty(dto.name) ?? slug,
            projectKey: nonempty(dto.project?.key),
            projectName: nonempty(dto.project?.name),
            defaultBranch: nonempty(dto.mainbranch?.name)
        )
    }

    static func branch(_ dto: BitbucketBranchDTO, defaultBranch: String?) throws -> BranchInfo {
        guard let name = nonempty(dto.name) else {
            throw BitbucketAPIError.malformedResponse
        }
        return BranchInfo(name: name, isDefault: name == defaultBranch)
    }

    static func pipeline(
        _ dto: BitbucketPipelineDTO,
        steps: [PipelineStep],
        commitContext: PipelineCommitContext? = nil,
        pullRequest: PipelinePullRequestContext? = nil
    ) throws -> PipelineRun {
        guard let uuid = nonempty(dto.uuid), let buildNumber = dto.buildNumber else {
            throw BitbucketAPIError.malformedResponse
        }
        return PipelineRun(
            id: PipelineRunID(rawValue: uuid),
            buildNumber: buildNumber,
            phase: resolvedPipelinePhase(dto.state, steps: steps),
            branchName: branchName(for: dto.target),
            origin: pipelineOrigin(for: dto.target),
            commitHash: nonempty(dto.target?.commit?.hash),
            startedAt: dto.createdOn,
            completedAt: dto.completedOn,
            failureReason: sanitizedMessage(dto.error?.message),
            steps: steps,
            commitContext: commitContext,
            pullRequest: pullRequest
        )
    }

    private static func pipelineOrigin(for target: BitbucketTargetDTO?) -> PipelineRunOrigin {
        switch target?.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pipeline_pullrequest_target":
            return .pullRequest(
                id: target?.pullRequest?.id,
                sourceBranch: target.flatMap { nonempty($0.source?.branch?.name) ?? nonempty($0.source?.name) },
                destinationBranch: target.flatMap { nonempty($0.destination?.branch?.name) ?? nonempty($0.destination?.name) }
            )
        case "pipeline_ref_target":
            guard target?.refType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "branch" else {
                return .unknown
            }
            return .branch(name: target.flatMap { nonempty($0.refName) })
        default:
            return .unknown
        }
    }

    private static func branchName(for target: BitbucketTargetDTO?) -> String? {
        nonempty(target?.refName)
            ?? nonempty(target?.source?.branch?.name)
            ?? nonempty(target?.source?.name)
    }

    static func commitContext(_ dto: BitbucketCommitDetailsDTO) -> PipelineCommitContext? {
        let message = firstLine(dto.message)
        let author = nonempty(dto.author?.user?.displayName)
            ?? nonempty(dto.author?.displayName)
            ?? nonempty(dto.author?.nickname)
            ?? nonempty(dto.author?.raw)
        let webURL = allowedWebURL(dto.links?.html?.href)
        guard message != nil || author != nil || dto.date != nil || webURL != nil else { return nil }
        return PipelineCommitContext(message: message, authorName: author, date: dto.date, webURL: webURL)
    }

    static func pullRequest(_ dto: BitbucketPullRequestDTO?) -> PipelinePullRequestContext? {
        guard let dto,
              let id = dto.id,
              let title = nonempty(dto.title),
              let state = nonempty(dto.state) else { return nil }
        let author = nonempty(dto.author?.user?.displayName)
            ?? nonempty(dto.author?.displayName)
            ?? nonempty(dto.author?.nickname)
        return PipelinePullRequestContext(
            id: id,
            title: title,
            state: state,
            authorName: author,
            webURL: allowedWebURL(dto.links?.html?.href)
        )
    }

    static func step(_ dto: BitbucketPipelineStepDTO) throws -> PipelineStep {
        guard let uuid = nonempty(dto.uuid) else {
            throw BitbucketAPIError.malformedResponse
        }
        return PipelineStep(
            id: PipelineStepID(rawValue: uuid),
            name: nonempty(dto.name) ?? "Unnamed step",
            phase: stepPhase(dto.state, trigger: dto.trigger),
            startedAt: dto.startedOn,
            completedAt: dto.completedOn
        )
    }

    static func pipelinePhase(_ state: BitbucketStateDTO?) -> PipelinePhase {
        PipelineStateReducer.reduce(
            remoteState: pipelineState(state),
            remoteResult: pipelineResult(state?.result)
        )
    }

    private static func resolvedPipelinePhase(
        _ state: BitbucketStateDTO?,
        steps: [PipelineStep]
    ) -> PipelinePhase {
        let basePhase = pipelinePhase(state)
        guard basePhase == .running else { return basePhase }

        guard let stage = pipelineStage(state?.stage) else {
            return PipelineStateReducer.resolve(
                pipelinePhase: basePhase,
                stepPhases: steps.map(\.phase)
            )
        }

        switch stage.uppercased() {
        case "PAUSED":
            return .awaitingApproval
        case "RUNNING":
            return PipelineStateReducer.resolve(
                pipelinePhase: basePhase,
                stepPhases: steps.map(\.phase)
            )
        default:
            return .unknown(
                remoteState: stage,
                remoteResult: pipelineResult(state?.result)
            )
        }
    }

    static func stepPhase(
        _ state: BitbucketStateDTO?,
        trigger: BitbucketPipelineStepTriggerDTO? = nil
    ) -> PipelineStepPhase {
        PipelineStateReducer.reduceStep(
            remoteState: stepState(state),
            remoteResult: stepResult(state?.result),
            requiresManualTrigger: requiresManualTrigger(trigger)
        )
    }

    private static func pipelineState(_ state: BitbucketStateDTO?) -> String? {
        canonicalValue(
            name: state?.name,
            type: state?.type,
            allowlist: [
                "pending": "PENDING",
                "in_progress": "IN_PROGRESS",
                "completed": "COMPLETED",
                "pipeline_state_pending": "PENDING",
                "pipeline_state_in_progress": "IN_PROGRESS",
                "pipeline_state_completed": "COMPLETED",
            ]
        )
    }

    private static func pipelineStage(_ stage: BitbucketPipelineStageDTO?) -> String? {
        canonicalValue(
            name: stage?.name,
            type: stage?.type,
            allowlist: [
                "running": "RUNNING",
                "paused": "PAUSED",
                "pipeline_state_in_progress_running": "RUNNING",
                "pipeline_state_in_progress_paused": "PAUSED",
            ]
        )
    }

    private static func pipelineResult(_ result: BitbucketResultDTO?) -> String? {
        canonicalValue(
            name: result?.name,
            type: result?.type,
            allowlist: [
                "error": "ERROR",
                "failed": "FAILED",
                "stopped": "STOPPED",
                "expired": "EXPIRED",
                "successful": "SUCCESSFUL",
                "pipeline_state_completed_error": "ERROR",
                "pipeline_state_completed_failed": "FAILED",
                "pipeline_state_completed_stopped": "STOPPED",
                "pipeline_state_completed_expired": "EXPIRED",
                "pipeline_state_completed_successful": "SUCCESSFUL",
            ]
        )
    }

    private static func stepState(_ state: BitbucketStateDTO?) -> String? {
        canonicalValue(
            name: state?.name,
            type: state?.type,
            allowlist: [
                "pending": "PENDING",
                "ready": "PENDING",
                "in_progress": "IN_PROGRESS",
                "completed": "COMPLETED",
                "pipeline_step_state_pending": "PENDING",
                "pipeline_step_state_ready": "PENDING",
                "pipeline_step_state_in_progress": "IN_PROGRESS",
                "pipeline_step_state_completed": "COMPLETED",
            ]
        )
    }

    private static func stepResult(_ result: BitbucketResultDTO?) -> String? {
        canonicalValue(
            name: result?.name,
            type: result?.type,
            allowlist: [
                "error": "ERROR",
                "failed": "FAILED",
                "stopped": "STOPPED",
                "not_run": "NOT_RUN",
                "expired": "EXPIRED",
                "successful": "SUCCESSFUL",
                "pipeline_step_state_completed_error": "ERROR",
                "pipeline_step_state_completed_failed": "FAILED",
                "pipeline_step_state_completed_stopped": "STOPPED",
                "pipeline_step_state_completed_not_run": "NOT_RUN",
                "pipeline_step_state_completed_expired": "EXPIRED",
                "pipeline_step_state_completed_successful": "SUCCESSFUL",
            ]
        )
    }

    private static func canonicalValue(
        name: String?,
        type: String?,
        allowlist: [String: String]
    ) -> String? {
        guard let value = firstNonempty(name, type) else { return nil }
        return allowlist[value.lowercased()] ?? value
    }

    private static func firstNonempty(_ values: String?...) -> String? {
        values.lazy.compactMap(nonempty).first
    }

    private static func requiresManualTrigger(_ trigger: BitbucketPipelineStepTriggerDTO?) -> Bool {
        guard let type = nonempty(trigger?.type) else { return false }
        return type.lowercased() == "pipeline_step_trigger_manual"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func sanitizedMessage(_ value: String?) -> String? {
        guard let value = nonempty(value) else { return nil }
        let withoutControlCharacters = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
        }
        let sanitized = String(String.UnicodeScalarView(withoutControlCharacters)).replacingOccurrences(of: "\n", with: " ")
        return String(sanitized.prefix(512))
    }

    private static func firstLine(_ value: String?) -> String? {
        guard let value = nonempty(value) else { return nil }
        let first = value.split(whereSeparator: { $0.isNewline }).first.map(String.init)
        return sanitizedMessage(first)
    }

    private static func allowedWebURL(_ value: String?) -> URL? {
        guard let value = nonempty(value),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "bitbucket.org",
              components.port == nil || components.port == 443,
              let url = components.url else { return nil }
        return url
    }
}
