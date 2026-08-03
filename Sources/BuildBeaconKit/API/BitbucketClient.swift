import Foundation

private struct CommitContextCacheKey: Hashable, Sendable {
    let accountID: AccountID
    let workspaceSlug: String
    let repositorySlug: String
    let commitHash: String
}

private enum PullRequestEnrichment: Hashable, Sendable {
    case associatedWithCommit
    case exactID(Int)
    case none
}

private struct CachedCommitContext: Sendable {
    let commit: BitbucketCommitDetailsDTO
}

/// Bounded actor cache for the immutable context associated with a repository commit.
/// The cache owns a simple insertion order instead of relying on incidental dictionary order.
private actor CommitContextCache {
    private let capacity: Int
    private var values: [CommitContextCacheKey: CachedCommitContext] = [:]
    private var insertionOrder: [CommitContextCacheKey] = []

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    func value(for key: CommitContextCacheKey) -> CachedCommitContext? {
        values[key]
    }

    func insert(_ value: CachedCommitContext, for key: CommitContextCacheKey) {
        guard values[key] == nil else {
            values[key] = value
            return
        }
        while insertionOrder.count >= capacity, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            values.removeValue(forKey: oldest)
        }
        insertionOrder.append(key)
        values[key] = value
    }
}

public struct BitbucketClientConfiguration: Sendable {
    public var baseURL: URL
    public var userAgent: String
    public var pageSize: Int
    public var maximumPages: Int
    public var maximumItems: Int
    public var maximumAttempts: Int
    public var maximumRetryDelay: TimeInterval

    public init(
        baseURL: URL = URL(string: "https://api.bitbucket.org/2.0")!,
        userAgent: String = "BuildBeacon/1.0 (macOS)",
        pageSize: Int = 100,
        maximumPages: Int = 100,
        maximumItems: Int = 10_000,
        maximumAttempts: Int = 3,
        maximumRetryDelay: TimeInterval = 5
    ) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.pageSize = max(1, min(pageSize, 100))
        self.maximumPages = max(1, maximumPages)
        self.maximumItems = max(1, maximumItems)
        self.maximumAttempts = max(1, maximumAttempts)
        self.maximumRetryDelay = max(0, maximumRetryDelay)
    }
}

public actor BitbucketClient: BitbucketService, PullRequestActionRunValidating {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let credentialStore: any CredentialStore
    private let transport: any HTTPTransport
    private let configuration: BitbucketClientConfiguration
    private let now: @Sendable () -> Date
    private let sleep: Sleep
    private let decoder: JSONDecoder
    private let commitContextCache = CommitContextCache()

    public init(
        credentialStore: any CredentialStore,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        configuration: BitbucketClientConfiguration = .init(),
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping Sleep = { delay in
            guard delay > 0 else { return }
            try await Task.sleep(for: .seconds(delay))
        }
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
        self.configuration = configuration
        self.now = now
        self.sleep = sleep
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func validate(credential: AccountCredential) async throws -> AccountProfile {
        let dto: BitbucketUserDTO = try await get(
            endpoint: Endpoint(path: ["user"]),
            credential: credential
        )
        return try BitbucketMapper.account(dto, email: credential.email)
    }

    public func listWorkspaces(accountID: AccountID) async throws -> [WorkspaceInfo] {
        let credential = try await requiredCredential(for: accountID)
        let accessRecords: [BitbucketWorkspaceAccessDTO] = try await paginate(
            endpoint: Endpoint(path: ["user", "workspaces"]),
            credential: credential,
            identity: { $0.workspace.uuid }
        )
        return try accessRecords.map { try BitbucketMapper.workspace($0.workspace) }
    }

    public func listRepositories(in workspace: WorkspaceInfo, accountID: AccountID) async throws -> [RepositoryInfo] {
        let credential = try await requiredCredential(for: accountID)
        let dtos: [BitbucketRepositoryDTO] = try await paginate(
            endpoint: Endpoint(path: ["repositories", workspace.slug], query: [URLQueryItem(name: "sort", value: "name")]),
            credential: credential,
            identity: { $0.uuid }
        )
        return try dtos.map { try BitbucketMapper.repository($0, workspace: workspace) }
    }

    public func listBranches(in repository: RepositoryInfo, accountID: AccountID) async throws -> [BranchInfo] {
        let credential = try await requiredCredential(for: accountID)
        let dtos: [BitbucketBranchDTO] = try await paginate(
            endpoint: Endpoint(
                path: ["repositories", repository.workspaceSlug, repository.slug, "refs", "branches"],
                query: [URLQueryItem(name: "sort", value: "name")]
            ),
            credential: credential,
            identity: { $0.name }
        )
        return try dtos.map { try BitbucketMapper.branch($0, defaultBranch: repository.defaultBranch) }
    }

    public func latestPipeline(for monitor: MonitorConfiguration) async throws -> PipelineRun? {
        let credential = try await requiredCredential(for: monitor.id.accountID)
        var query = [
            URLQueryItem(name: "sort", value: "-created_on"),
            URLQueryItem(name: "pagelen", value: "1"),
        ]
        switch monitor.id.target {
        case .repositoryLatest:
            break
        case .defaultBranch:
            let repository: BitbucketRepositoryDTO = try await get(
                endpoint: Endpoint(path: ["repositories", monitor.workspaceSlug, monitor.repositorySlug]),
                credential: credential
            )
            guard let defaultBranch = repository.mainbranch?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !defaultBranch.isEmpty else {
                throw BitbucketAPIError.malformedResponse
            }
            query.append(URLQueryItem(name: "q", value: "target.ref_name=\"\(escapedFilterLiteral(defaultBranch))\""))
        case let .branch(exactName):
            query.append(URLQueryItem(name: "q", value: "target.ref_name=\"\(escapedFilterLiteral(exactName))\""))
        }

        let page: BitbucketPage<BitbucketPipelineDTO> = try await get(
            endpoint: Endpoint(
                path: ["repositories", monitor.workspaceSlug, monitor.repositorySlug, "pipelines"],
                query: query
            ),
            credential: credential
        )
        guard let pipelineDTO = page.values.first else { return nil }
        guard let pipelineID = pipelineDTO.uuid, !pipelineID.isEmpty else {
            throw BitbucketAPIError.malformedResponse
        }
        let stepDTOs: [BitbucketPipelineStepDTO] = try await paginate(
            endpoint: Endpoint(
                path: ["repositories", monitor.workspaceSlug, monitor.repositorySlug, "pipelines", pipelineID, "steps"]
            ),
            credential: credential,
            identity: { $0.uuid }
        )
        let steps = try stepDTOs.map(BitbucketMapper.step)
        let commitHash = pipelineDTO.target?.commit?.hash?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pullRequestEnrichment: PullRequestEnrichment
        if pipelineDTO.target?.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pipeline_pullrequest_target" {
            pullRequestEnrichment = pipelineDTO.target?.pullRequest?.id.map(PullRequestEnrichment.exactID) ?? .none
        } else {
            pullRequestEnrichment = .associatedWithCommit
        }
        let context: CachedCommitContext?
        if let commitHash, !commitHash.isEmpty {
            context = try? await cachedCommitContext(
                accountID: monitor.id.accountID,
                workspaceSlug: monitor.workspaceSlug,
                repositorySlug: monitor.repositorySlug,
                commitHash: commitHash,
                credential: credential
            )
        } else {
            context = nil
        }
        var pullRequest: PipelinePullRequestContext?
        switch pullRequestEnrichment {
        case let .exactID(id):
            pullRequest = BitbucketMapper.pullRequest(await optionalPullRequest(
                workspaceSlug: monitor.workspaceSlug,
                repositorySlug: monitor.repositorySlug,
                id: id,
                credential: credential
            ))
        case .associatedWithCommit:
            if let commitHash, !commitHash.isEmpty {
                pullRequest = BitbucketMapper.pullRequest(await optionalPullRequest(
                    workspaceSlug: monitor.workspaceSlug,
                    repositorySlug: monitor.repositorySlug,
                    commitHash: commitHash,
                    credential: credential
                ))
            } else {
                pullRequest = nil
            }
        case .none:
            pullRequest = nil
        }
        return try BitbucketMapper.pipeline(
            pipelineDTO,
            steps: steps,
            commitContext: context.flatMap { BitbucketMapper.commitContext($0.commit) },
            pullRequest: pullRequest
        )
    }

    public func validatePullRequestActionRun(_ target: PullRequestActionTarget) async throws {
        do {
            let credential = try await requiredCredential(for: target.accountID)
            let dto: BitbucketPipelineDTO = try await get(
                endpoint: Endpoint(path: [
                    "repositories", target.workspaceSlug, target.repositorySlug,
                    "pipelines", target.runID.rawValue,
                ]),
                credential: credential
            )
            let run = try BitbucketMapper.pipeline(dto, steps: [])
            guard run.id == target.runID,
                  run.buildNumber == target.buildNumber,
                  run.phase == .succeeded,
                  run.commitHash?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    == target.expectedSourceCommitHash.lowercased(),
                  case let .pullRequest(id, source, destination) = run.origin,
                  id == target.pullRequestID,
                  source == target.sourceBranch,
                  destination == target.destinationBranch else {
                throw PullRequestActionError.pipelineNotSuccessful
            }
        } catch let error as PullRequestActionError {
            throw error
        } catch let error as BitbucketAPIError {
            throw Self.pullRequestActionError(error)
        } catch {
            throw PullRequestActionError.temporarilyUnavailable
        }
    }

    private func cachedCommitContext(
        accountID: AccountID,
        workspaceSlug: String,
        repositorySlug: String,
        commitHash: String,
        credential: AccountCredential
    ) async throws -> CachedCommitContext {
        let key = CommitContextCacheKey(
            accountID: accountID,
            workspaceSlug: workspaceSlug,
            repositorySlug: repositorySlug,
            commitHash: commitHash
        )
        if let cached = await commitContextCache.value(for: key) {
            return cached
        }
        let commit: BitbucketCommitDetailsDTO = try await get(
            endpoint: Endpoint(path: ["repositories", workspaceSlug, repositorySlug, "commit", commitHash]),
            credential: credential
        )
        let context = CachedCommitContext(commit: commit)
        await commitContextCache.insert(context, for: key)
        return context
    }

    private func optionalPullRequest(
        workspaceSlug: String,
        repositorySlug: String,
        commitHash: String,
        credential: AccountCredential
    ) async -> BitbucketPullRequestDTO? {
        do {
            let page: BitbucketPage<BitbucketPullRequestDTO> = try await get(
                endpoint: Endpoint(
                    path: ["repositories", workspaceSlug, repositorySlug, "commit", commitHash, "pullrequests"],
                    query: [URLQueryItem(name: "pagelen", value: "1")]
                ),
                credential: credential
            )
            return page.values.first
        } catch is CancellationError {
            return nil
        } catch let error as BitbucketAPIError {
            switch error {
            case .invalidCredentials, .insufficientPermissions, .notFound, .malformedResponse,
                    .server(status: 202):
                return nil
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    private func optionalPullRequest(
        workspaceSlug: String,
        repositorySlug: String,
        id: Int,
        credential: AccountCredential
    ) async -> BitbucketPullRequestDTO? {
        do {
            let pullRequest: BitbucketPullRequestDTO = try await get(
                endpoint: Endpoint(
                    path: ["repositories", workspaceSlug, repositorySlug, "pullrequests", String(id)]
                ),
                credential: credential
            )
            return pullRequest
        } catch {
            return nil
        }
    }

    private func requiredCredential(for accountID: AccountID) async throws -> AccountCredential {
        do {
            guard let credential = try await credentialStore.load(accountID: accountID) else {
                throw BitbucketAPIError.missingCredential
            }
            return credential
        } catch let error as BitbucketAPIError {
            throw error
        } catch {
            throw BitbucketAPIError.transport
        }
    }

    private func paginate<Value: Decodable & Sendable>(
        endpoint: Endpoint,
        credential: AccountCredential,
        identity: (Value) -> String?
    ) async throws -> [Value] {
        var nextURL = try makeURL(endpoint)
        var visited = Set<URL>()
        var seenIDs = Set<String>()
        var result: [Value] = []
        var pageCount = 0

        while true {
            try checkCancellation()
            guard pageCount < configuration.maximumPages else {
                throw BitbucketAPIError.pagination(.pageLimitExceeded(limit: configuration.maximumPages, partialItemCount: result.count))
            }
            guard visited.insert(nextURL).inserted else {
                throw BitbucketAPIError.pagination(.cycleDetected(partialItemCount: result.count))
            }
            pageCount += 1

            let page: BitbucketPage<Value> = try await get(url: nextURL, credential: credential)
            for value in page.values {
                if result.count >= configuration.maximumItems {
                    throw BitbucketAPIError.pagination(.itemLimitExceeded(limit: configuration.maximumItems, partialItemCount: result.count))
                }
                if let id = identity(value), !id.isEmpty {
                    guard seenIDs.insert(id).inserted else { continue }
                }
                result.append(value)
            }

            guard let rawNext = page.next else { return result }
            guard !page.values.isEmpty else {
                throw BitbucketAPIError.pagination(.emptyPageWithNext(partialItemCount: result.count))
            }
            guard let candidate = URL(string: rawNext), isAllowedAPIURL(candidate) else {
                throw BitbucketAPIError.pagination(.invalidNextURL(partialItemCount: result.count))
            }
            nextURL = candidate
        }
    }

    private func get<Value: Decodable>(endpoint: Endpoint, credential: AccountCredential) async throws -> Value {
        try await get(url: makeURL(endpoint), credential: credential)
    }

    private func get<Value: Decodable>(url: URL, credential: AccountCredential) async throws -> Value {
        guard isAllowedAPIURL(url) else { throw BitbucketAPIError.invalidURL }
        let response = try await sendWithRetry(makeRequest(url: url, credential: credential))
        do {
            return try decoder.decode(Value.self, from: response.data)
        } catch {
            throw BitbucketAPIError.malformedResponse
        }
    }

    private func sendWithRetry(_ request: URLRequest) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            try checkCancellation()
            attempt += 1
            do {
                let response = try await transport.send(request)
                if (200..<300).contains(response.response.statusCode) { return response }
                let mapped = mapStatus(response.response)
                guard shouldRetry(status: response.response.statusCode), attempt < configuration.maximumAttempts else {
                    throw mapped
                }
                try await sleep(retryDelay(for: response.response, attempt: attempt))
            } catch let error as BitbucketAPIError {
                guard shouldRetry(error), attempt < configuration.maximumAttempts else { throw error }
                try await sleep(backoff(attempt: attempt))
            } catch is CancellationError {
                throw BitbucketAPIError.cancelled
            } catch {
                throw BitbucketAPIError.transport
            }
        }
    }

    private func makeRequest(url: URL, credential: AccountCredential) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        let raw = "\(credential.email):\(credential.token)"
        let encoded = Data(raw.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeURL(_ endpoint: Endpoint) throws -> URL {
        guard isAllowedAPIURL(configuration.baseURL),
              var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw BitbucketAPIError.invalidURL
        }
        let encodedSegments = try endpoint.path.map { segment -> String in
            guard !segment.isEmpty,
                  let encoded = segment.addingPercentEncoding(withAllowedCharacters: .urlPathSegmentAllowed) else {
                throw BitbucketAPIError.invalidURL
            }
            return encoded
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = basePath + "/" + encodedSegments.joined(separator: "/")
        var query = endpoint.query
        if !query.contains(where: { $0.name == "pagelen" }) {
            query.append(URLQueryItem(name: "pagelen", value: String(configuration.pageSize)))
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, isAllowedAPIURL(url) else { throw BitbucketAPIError.invalidURL }
        return url
    }

    private func isAllowedAPIURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              configuration.baseURL.scheme?.lowercased() == "https",
              configuration.baseURL.host?.lowercased() == "api.bitbucket.org",
              components.scheme?.lowercased() == configuration.baseURL.scheme?.lowercased(),
              components.host?.lowercased() == configuration.baseURL.host?.lowercased(),
              components.port == configuration.baseURL.port else { return false }
        let basePath = configuration.baseURL.path.hasSuffix("/")
            ? String(configuration.baseURL.path.dropLast())
            : configuration.baseURL.path
        return components.path == basePath || components.path.hasPrefix(basePath + "/")
    }

    private func mapStatus(_ response: HTTPURLResponse) -> BitbucketAPIError {
        switch response.statusCode {
        case 401: .invalidCredentials
        case 403: .insufficientPermissions
        case 404: .notFound
        case 429: .rateLimited(retryAt: retryAt(response))
        case 300...399: .unsafeRedirect
        case 500...599: .server(status: response.statusCode)
        default: .server(status: response.statusCode)
        }
    }

    private func shouldRetry(status: Int) -> Bool { status == 429 || status == 503 || (500...599).contains(status) }

    private func shouldRetry(_ error: BitbucketAPIError) -> Bool {
        switch error {
        case .offline, .timedOut, .transport: true
        default: false
        }
    }

    private func retryDelay(for response: HTTPURLResponse, attempt: Int) -> TimeInterval {
        if let retryAt = retryAt(response) {
            return max(0, retryAt.timeIntervalSince(now()))
        }
        return backoff(attempt: attempt)
    }

    private func retryAt(_ response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 { return now().addingTimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: raw)
    }

    private func backoff(attempt: Int) -> TimeInterval {
        let exponential = min(configuration.maximumRetryDelay, pow(2, Double(max(0, attempt - 1))) * 0.25)
        guard exponential > 0 else { return 0 }
        return Double.random(in: exponential * 0.75...exponential)
    }

    private func escapedFilterLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw BitbucketAPIError.cancelled }
    }

    private static func pullRequestActionError(_ error: BitbucketAPIError) -> PullRequestActionError {
        switch error {
        case .missingCredential, .invalidCredentials: .invalidCredentials
        case .insufficientPermissions: .insufficientPermissions
        case let .rateLimited(retryAt): .rateLimited(retryAt: retryAt)
        case .timedOut: .timedOut
        case .offline: .offline
        case .cancelled: .cancelled
        case .notFound: .staleRun
        case .malformedResponse, .responseTooLarge, .unsafeRedirect, .pagination, .invalidURL:
            .malformedResponse
        case .server, .transport: .temporarilyUnavailable
        }
    }
}

private struct Endpoint: Sendable {
    let path: [String]
    let query: [URLQueryItem]

    init(path: [String], query: [URLQueryItem] = []) {
        self.path = path
        self.query = query
    }
}

private extension CharacterSet {
    static let urlPathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#")
        return set
    }()
}
