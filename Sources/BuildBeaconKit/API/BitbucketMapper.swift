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
            phase: pipelinePhase(dto.state),
            branchName: nonempty(dto.target?.refName),
            commitHash: nonempty(dto.target?.commit?.hash),
            startedAt: dto.createdOn,
            completedAt: dto.completedOn,
            failureReason: sanitizedMessage(dto.error?.message),
            steps: steps,
            commitContext: commitContext,
            pullRequest: pullRequest
        )
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
        return PipelinePullRequestContext(id: id, title: title, state: state, webURL: allowedWebURL(dto.links?.html?.href))
    }

    static func step(_ dto: BitbucketPipelineStepDTO) throws -> PipelineStep {
        guard let uuid = nonempty(dto.uuid) else {
            throw BitbucketAPIError.malformedResponse
        }
        return PipelineStep(
            id: PipelineStepID(rawValue: uuid),
            name: nonempty(dto.name) ?? "Unnamed step",
            phase: stepPhase(dto.state),
            startedAt: dto.startedOn,
            completedAt: dto.completedOn
        )
    }

    static func pipelinePhase(_ state: BitbucketStateDTO?) -> PipelinePhase {
        PipelineStateReducer.reduce(
            remoteState: nonempty(state?.name ?? state?.type),
            remoteResult: nonempty(state?.result?.name ?? state?.result?.type)
        )
    }

    static func stepPhase(_ state: BitbucketStateDTO?) -> PipelineStepPhase {
        PipelineStateReducer.reduceStep(
            remoteState: nonempty(state?.name ?? state?.type),
            remoteResult: nonempty(state?.result?.name ?? state?.result?.type)
        )
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
