import Foundation

struct BitbucketPage<Value: Decodable>: Decodable {
    let values: [Value]
    let next: String?
}

struct BitbucketUserDTO: Decodable {
    let uuid: String?
    let accountID: String?
    let displayName: String?
    let nickname: String?

    enum CodingKeys: String, CodingKey {
        case uuid
        case accountID = "account_id"
        case displayName = "display_name"
        case nickname
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
    let startedOn: Date?
    let completedOn: Date?

    enum CodingKeys: String, CodingKey {
        case uuid, name, state
        case startedOn = "started_on"
        case completedOn = "completed_on"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try? container.decode(String.self, forKey: .uuid)
        name = try? container.decode(String.self, forKey: .name)
        state = try? container.decode(BitbucketStateDTO.self, forKey: .state)
        startedOn = container.decodeLossyDate(forKey: .startedOn)
        completedOn = container.decodeLossyDate(forKey: .completedOn)
    }
}

struct BitbucketStateDTO: Decodable {
    let name: String?
    let type: String?
    let result: BitbucketResultDTO?
}

struct BitbucketResultDTO: Decodable {
    let name: String?
    let type: String?
}

struct BitbucketTargetDTO: Decodable {
    let refName: String?
    let commit: BitbucketCommitDTO?

    enum CodingKeys: String, CodingKey {
        case refName = "ref_name"
        case commit
    }
}

struct BitbucketCommitDTO: Decodable {
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
    let links: BitbucketLinksDTO?
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
