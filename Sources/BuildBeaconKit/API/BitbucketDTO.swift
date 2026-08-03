import Foundation

struct BitbucketPage<Value: Decodable>: Decodable {
    let values: [Value]
    let next: String?
}

struct BitbucketUserDTO: Decodable, Sendable {
    let uuid: String?
    let accountID: String?
    let displayName: String?
    let nickname: String?
    let user: BitbucketNestedUserDTO?

    enum CodingKeys: String, CodingKey {
        case uuid
        case accountID = "account_id"
        case displayName = "display_name"
        case nickname, user
    }
}

struct BitbucketNestedUserDTO: Decodable, Sendable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

struct BitbucketWorkspaceDTO: Decodable {
    let uuid: String?
    let slug: String?
    let name: String?
}

/// The `/user/workspaces` endpoint returns `workspace_access` records whose
/// actual workspace is nested under `workspace`. Older responses used the
/// workspace directly, so accept that shape as a compatibility fallback.
struct BitbucketWorkspaceAccessDTO: Decodable {
    let workspace: BitbucketWorkspaceDTO

    private enum CodingKeys: String, CodingKey {
        case workspace
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.workspace) {
            workspace = try container.decode(BitbucketWorkspaceDTO.self, forKey: .workspace)
        } else {
            workspace = try BitbucketWorkspaceDTO(from: decoder)
        }
    }
}

struct BitbucketRepositoryDTO: Decodable {
    let uuid: String?
    let slug: String?
    let name: String?
    let workspace: BitbucketWorkspaceDTO?
    let project: BitbucketProjectDTO?
    let mainbranch: BitbucketBranchDTO?
}

struct BitbucketProjectDTO: Decodable {
    let key: String?
    let name: String?
}

struct BitbucketBranchDTO: Decodable {
    let name: String?
}

struct BitbucketPipelineDTO: Decodable {
    let uuid: String?
    let buildNumber: Int?
    let state: BitbucketStateDTO?
    let target: BitbucketTargetDTO?
    let createdOn: Date?
    let completedOn: Date?
    let error: BitbucketMessageDTO?

    enum CodingKeys: String, CodingKey {
        case uuid
        case buildNumber = "build_number"
        case state, target, error
        case createdOn = "created_on"
        case completedOn = "completed_on"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try? container.decode(String.self, forKey: .uuid)
        buildNumber = try? container.decode(Int.self, forKey: .buildNumber)
        state = try? container.decode(BitbucketStateDTO.self, forKey: .state)
        target = try? container.decode(BitbucketTargetDTO.self, forKey: .target)
        createdOn = container.decodeLossyDate(forKey: .createdOn)
        completedOn = container.decodeLossyDate(forKey: .completedOn)
        error = try? container.decode(BitbucketMessageDTO.self, forKey: .error)
    }
}

struct BitbucketPipelineStepDTO: Decodable {
    let uuid: String?
    let name: String?
    let state: BitbucketStateDTO?
    let trigger: BitbucketPipelineStepTriggerDTO?
    let startedOn: Date?
    let completedOn: Date?

    enum CodingKeys: String, CodingKey {
        case uuid, name, state, trigger
        case startedOn = "started_on"
        case completedOn = "completed_on"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try? container.decode(String.self, forKey: .uuid)
        name = try? container.decode(String.self, forKey: .name)
        state = try? container.decode(BitbucketStateDTO.self, forKey: .state)
        trigger = try? container.decode(BitbucketPipelineStepTriggerDTO.self, forKey: .trigger)
        startedOn = container.decodeLossyDate(forKey: .startedOn)
        completedOn = container.decodeLossyDate(forKey: .completedOn)
    }
}

struct BitbucketPipelineStepTriggerDTO: Decodable {
    let type: String?
}

struct BitbucketStateDTO: Decodable {
    let name: String?
    let type: String?
    let result: BitbucketResultDTO?
    let stage: BitbucketPipelineStageDTO?
}

struct BitbucketResultDTO: Decodable {
    let name: String?
    let type: String?
}

struct BitbucketPipelineStageDTO: Decodable {
    let name: String?
    let type: String?
}

struct BitbucketTargetDTO: Decodable {
    let type: String?
    let refType: String?
    let refName: String?
    let source: BitbucketPipelineTargetReferenceDTO?
    let destination: BitbucketPipelineTargetReferenceDTO?
    let pullRequest: BitbucketPipelineTargetPullRequestDTO?
    let commit: BitbucketCommitDTO?

    enum CodingKeys: String, CodingKey {
        case type
        case refType = "ref_type"
        case refName = "ref_name"
        case source, destination, commit
        case pullRequest = "pullrequest"
    }
}

struct BitbucketPipelineTargetReferenceDTO: Decodable {
    let name: String?
    let branch: BitbucketBranchDTO?

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self) {
            name = string
            branch = nil
            return
        }

        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            name = nil
            branch = nil
            return
        }
        name = try? container.decode(String.self, forKey: .name)
        branch = try? container.decode(BitbucketBranchDTO.self, forKey: .branch)
    }

    private enum CodingKeys: String, CodingKey {
        case name, branch
    }
}

struct BitbucketPipelineTargetPullRequestDTO: Decodable {
    let id: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let integer = try? container.decode(Int.self, forKey: .id) {
            id = integer
        } else if let string = try? container.decode(String.self, forKey: .id),
                  let integer = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            id = integer
        } else {
            id = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
    }
}

struct BitbucketCommitDTO: Decodable, Sendable {
    let hash: String?
}

struct BitbucketCommitDetailsDTO: Decodable, Sendable {
    let hash: String?
    let message: String?
    let author: BitbucketCommitAuthorDTO?
    let date: Date?
    let links: BitbucketLinksDTO?

    enum CodingKeys: String, CodingKey {
        case hash, message, author, date, links
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = try? container.decode(String.self, forKey: .hash)
        message = try? container.decode(String.self, forKey: .message)
        author = try? container.decode(BitbucketCommitAuthorDTO.self, forKey: .author)
        date = container.decodeLossyDate(forKey: .date)
        links = try? container.decode(BitbucketLinksDTO.self, forKey: .links)
    }
}

struct BitbucketCommitAuthorDTO: Decodable, Sendable {
    let raw: String?
    let displayName: String?
    let nickname: String?
    let user: BitbucketUserDTO?

    enum CodingKeys: String, CodingKey {
        case raw
        case displayName = "display_name"
        case nickname, user
    }
}

struct BitbucketPullRequestDTO: Decodable, Sendable {
    let id: Int?
    let title: String?
    let state: String?
    let author: BitbucketUserDTO?
    let links: BitbucketLinksDTO?
    let source: BitbucketPullRequestEndpointDTO?
    let destination: BitbucketPullRequestEndpointDTO?
    let participants: [BitbucketPullRequestParticipantDTO]?
    let draft: Bool?
    let closeSourceBranch: Bool?
    let mergeCommit: BitbucketCommitDTO?

    enum CodingKeys: String, CodingKey {
        case id, title, state, author, links, source, destination, participants, draft
        case closeSourceBranch = "close_source_branch"
        case mergeCommit = "merge_commit"
    }
}

struct BitbucketPullRequestEndpointDTO: Decodable, Sendable {
    let repository: BitbucketPullRequestRepositoryDTO?
    let branch: BitbucketPullRequestBranchDTO?
    let commit: BitbucketCommitDTO?
}

struct BitbucketPullRequestRepositoryDTO: Decodable, Sendable {
    let uuid: String?
    let fullName: String?

    enum CodingKeys: String, CodingKey {
        case uuid
        case fullName = "full_name"
    }
}

struct BitbucketPullRequestBranchDTO: Decodable, Sendable {
    let name: String?
    let mergeStrategies: [String]?
    let defaultMergeStrategy: String?

    enum CodingKeys: String, CodingKey {
        case name
        case mergeStrategies = "merge_strategies"
        case defaultMergeStrategy = "default_merge_strategy"
    }
}

struct BitbucketPullRequestParticipantDTO: Decodable, Sendable {
    let user: BitbucketUserDTO?
    let approved: Bool?
    let state: String?
}

struct BitbucketMergeTaskDTO: Decodable, Sendable {
    let taskStatus: String?
    let mergeResult: BitbucketPullRequestDTO?

    enum CodingKeys: String, CodingKey {
        case taskStatus = "task_status"
        case mergeResult = "merge_result"
    }
}

struct BitbucketPullRequestMergeBody: Encodable, Sendable {
    let type = "pullrequest"
    let mergeStrategy: String
    let closeSourceBranch: Bool

    enum CodingKeys: String, CodingKey {
        case type
        case mergeStrategy = "merge_strategy"
        case closeSourceBranch = "close_source_branch"
    }
}

struct BitbucketLinksDTO: Decodable, Sendable {
    let html: BitbucketLinkDTO?
}

struct BitbucketLinkDTO: Decodable, Sendable {
    let href: String?
}

struct BitbucketMessageDTO: Decodable {
    let message: String?
}

private extension KeyedDecodingContainer {
    func decodeLossyDate(forKey key: Key) -> Date? {
        guard let value = try? decode(String.self, forKey: key) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}
