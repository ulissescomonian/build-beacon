import Foundation

public struct BitbucketPullRequestActionClientConfiguration: Sendable {
    public var baseURL: URL
    public var userAgent: String
    public var requestTimeout: TimeInterval
    public var maximumReadAttempts: Int
    public var maximumRetryDelay: TimeInterval
    public var maximumMergeTaskPolls: Int
    public var mergeTaskPollInterval: TimeInterval

    public init(
        baseURL: URL = URL(string: "https://api.bitbucket.org/2.0")!,
        userAgent: String = "BuildBeacon/1.0 (macOS)",
        requestTimeout: TimeInterval = 15,
        maximumReadAttempts: Int = 3,
        maximumRetryDelay: TimeInterval = 5,
        maximumMergeTaskPolls: Int = 20,
        mergeTaskPollInterval: TimeInterval = 1
    ) {
        self.baseURL = baseURL
        self.userAgent = userAgent
        self.requestTimeout = max(1, requestTimeout)
        self.maximumReadAttempts = max(1, maximumReadAttempts)
        self.maximumRetryDelay = max(0, maximumRetryDelay)
        self.maximumMergeTaskPolls = max(1, maximumMergeTaskPolls)
        self.mergeTaskPollInterval = max(0, mergeTaskPollInterval)
    }
}

/// A narrowly scoped client for the one approved Bitbucket mutation flow.
/// It never participates in polling and never retries either POST request.
public actor BitbucketPullRequestActionClient: PullRequestActionServicing {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let credentialStore: any PullRequestActionCredentialStoring
    private let runValidator: any PullRequestActionRunValidating
    private let transport: any HTTPTransport
    private let configuration: BitbucketPullRequestActionClientConfiguration
    private let now: @Sendable () -> Date
    private let sleep: Sleep
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        credentialStore: any PullRequestActionCredentialStoring = KeychainPullRequestActionCredentialStore(),
        runValidator: any PullRequestActionRunValidating,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        configuration: BitbucketPullRequestActionClientConfiguration = .init(),
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping Sleep = { delay in
            guard delay > 0 else { return }
            try await Task.sleep(for: .seconds(delay))
        }
    ) {
        self.credentialStore = credentialStore
        self.runValidator = runValidator
        self.transport = transport
        self.configuration = configuration
        self.now = now
        self.sleep = sleep

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        self.encoder = JSONEncoder()
    }

    public var isConfigured: Bool {
        get async {
            (try? await credentialStore.exists()) == true
        }
    }

    public func configure(
        _ credential: AccountCredential,
        expectedAccountID: AccountID
    ) async throws {
        let email = credential.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !credential.token.isEmpty, !expectedAccountID.rawValue.isEmpty else {
            throw PullRequestActionError.invalidCredentials
        }
        let submitted = AccountCredential(email: email, token: credential.token)
        let user: BitbucketUserDTO = try await read(
            url: try makeURL(path: ["user"]),
            credential: submitted
        )
        guard matchesExpectedAccount(user, expected: expectedAccountID) else {
            throw PullRequestActionError.accountMismatch
        }
        do {
            try await credentialStore.save(PullRequestActionCredentialRecord(
                credential: submitted,
                expectedAccountID: expectedAccountID
            ))
        } catch {
            throw PullRequestActionError.temporarilyUnavailable
        }
    }

    public func disconnectPullRequestActions() async throws {
        do {
            try await credentialStore.delete()
        } catch {
            throw PullRequestActionError.temporarilyUnavailable
        }
    }

    public func preflight(
        _ target: PullRequestActionTarget
    ) async throws -> PullRequestMergePreflight {
        let record = try await requiredCredential(expectedAccountID: target.accountID)
        try await runValidator.validatePullRequestActionRun(target)
        return try await freshPreflight(target, record: record)
    }

    public func approveAndMerge(
        _ preflight: PullRequestMergePreflight,
        strategy: PullRequestMergeStrategy
    ) async throws -> PullRequestMergeOutcome {
        try await executeApproveAndMerge(preflight, strategy: strategy) { _ in }
    }

    public func approveAndMerge(
        _ preflight: PullRequestMergePreflight,
        strategy: PullRequestMergeStrategy,
        progress: @escaping @Sendable (PullRequestActionOperationPhase) async -> Void
    ) async throws -> PullRequestMergeOutcome {
        try await executeApproveAndMerge(preflight, strategy: strategy, progress: progress)
    }

    private func executeApproveAndMerge(
        _ preflight: PullRequestMergePreflight,
        strategy: PullRequestMergeStrategy,
        progress: @escaping @Sendable (PullRequestActionOperationPhase) async -> Void
    ) async throws -> PullRequestMergeOutcome {
        let target = preflight.target
        let record = try await requiredCredential(expectedAccountID: target.accountID)
        var approvalConfirmed = preflight.alreadyApproved

        await progress(.revalidatingBeforeApproval)
        try await validateActionIdentity(record)
        try await runValidator.validatePullRequestActionRun(target)
        let beforeApproval = try await freshPreflight(target, record: record)
        guard beforeApproval.availableStrategies.contains(strategy) else {
            throw PullRequestActionError.invalidTarget
        }

        if !beforeApproval.alreadyApproved {
            await progress(.approving)
            let approvalURL = try makeURL(path: pullRequestPath(target) + ["approve"])
            let response: HTTPResponse
            do {
                response = try await sendWrite(
                    request(url: approvalURL, method: "POST", credential: record.credential)
                )
            } catch let error as PullRequestActionError {
                if Self.isAmbiguousWrite(error) { return .outcomeUnknown }
                throw error
            }
            guard (200..<300).contains(response.response.statusCode) else {
                let error = mapStatus(response.response)
                if Self.isAmbiguousWrite(error) { return .outcomeUnknown }
                throw error
            }
            let participant: BitbucketPullRequestParticipantDTO
            do {
                participant = try decoder.decode(BitbucketPullRequestParticipantDTO.self, from: response.data)
            } catch {
                return .outcomeUnknown
            }
            guard participant.approved == true,
                  matchesExpectedAccount(participant.user, expected: target.accountID) else {
                return .outcomeUnknown
            }
            approvalConfirmed = true
        } else {
            approvalConfirmed = true
        }

        await progress(.revalidatingBeforeMerge)
        do {
            try await validateActionIdentity(record)
            try await runValidator.validatePullRequestActionRun(target)
        } catch let error as PullRequestActionError {
            return approvalConfirmed
                ? .approvedButNotMerged(reason: partialReason(for: error))
                : .outcomeUnknown
        } catch {
            return approvalConfirmed ? .approvedButNotMerged(reason: .providerRejected) : .outcomeUnknown
        }
        let beforeMerge: PullRequestMergePreflight
        do {
            beforeMerge = try await freshPreflight(target, record: record)
        } catch let error as PullRequestActionError {
            if approvalConfirmed {
                return .approvedButNotMerged(reason: partialReason(for: error))
            }
            throw error
        }
        guard beforeMerge.availableStrategies.contains(strategy) else {
            return .approvedButNotMerged(reason: .providerRejected)
        }

        let mergeURL = try makeURL(path: pullRequestPath(target) + ["merge"])
        let body: Data
        do {
            body = try encoder.encode(BitbucketPullRequestMergeBody(
                mergeStrategy: strategy.rawValue,
                closeSourceBranch: beforeMerge.closeSourceBranch
            ))
        } catch {
            return .approvedButNotMerged(reason: .providerRejected)
        }

        let mergeResponse: HTTPResponse
        await progress(.merging)
        do {
            mergeResponse = try await sendWrite(
                request(url: mergeURL, method: "POST", credential: record.credential, body: body)
            )
        } catch let error as PullRequestActionError {
            if Self.isAmbiguousWrite(error) { return .outcomeUnknown }
            if approvalConfirmed {
                return .approvedButNotMerged(reason: partialReason(for: error))
            }
            throw error
        }

        switch mergeResponse.response.statusCode {
        case 200:
            break
        case 202:
            await progress(.waitingForProvider)
            guard let taskURL = validatedMergeTaskURL(
                mergeResponse.response.value(forHTTPHeaderField: "Location"),
                target: target
            ) else {
                return .outcomeUnknown
            }
            let terminal = try await waitForMergeTask(taskURL, credential: record.credential)
            switch terminal {
            case .completed:
                break
            case .rejected:
                return .approvedButNotMerged(reason: .providerRejected)
            case .unknown:
                return .outcomeUnknown
            }
        default:
            let error = mapStatus(mergeResponse.response)
            if Self.isAmbiguousWrite(error) { return .outcomeUnknown }
            if approvalConfirmed {
                return .approvedButNotMerged(reason: partialReason(for: error))
            }
            throw error
        }

        await progress(.waitingForProvider)
        return try await confirmedMergeOutcome(target, record: record)
    }

    private func freshPreflight(
        _ target: PullRequestActionTarget,
        record: PullRequestActionCredentialRecord
    ) async throws -> PullRequestMergePreflight {
        try validate(target)
        let pullRequest: BitbucketPullRequestDTO = try await read(
            url: try makeURL(path: pullRequestPath(target)),
            credential: record.credential
        )
        guard pullRequest.id == target.pullRequestID else {
            throw PullRequestActionError.invalidTarget
        }
        guard normalized(pullRequest.state) == "OPEN" else {
            throw PullRequestActionError.pullRequestNotOpen
        }
        guard pullRequest.draft != true else {
            throw PullRequestActionError.pullRequestNotOpen
        }
        guard nonempty(pullRequest.source?.branch?.name) == target.sourceBranch,
              nonempty(pullRequest.destination?.branch?.name) == target.destinationBranch else {
            throw PullRequestActionError.staleRun
        }
        guard normalizedHash(pullRequest.source?.commit?.hash) == normalizedHash(target.expectedSourceCommitHash) else {
            throw PullRequestActionError.sourceHeadChanged
        }

        let strategies = pullRequest.destination?.branch?.mergeStrategies?
            .compactMap { PullRequestMergeStrategy(rawValue: $0.lowercased()) }
            ?? []
        guard !strategies.isEmpty else {
            throw PullRequestActionError.malformedResponse
        }
        let providerDefault = pullRequest.destination?.branch?.defaultMergeStrategy
            .flatMap { PullRequestMergeStrategy(rawValue: $0.lowercased()) }
        let defaultStrategy = providerDefault.flatMap { strategies.contains($0) ? $0 : nil }
            ?? strategies[0]
        let approved = pullRequest.participants?.contains {
            $0.approved == true && matchesExpectedAccount($0.user, expected: target.accountID)
        } ?? false

        return PullRequestMergePreflight(
            target: target,
            title: nonempty(pullRequest.title) ?? "PR #\(target.pullRequestID)",
            webURL: allowedWebURL(pullRequest.links?.html?.href),
            availableStrategies: strategies,
            defaultStrategy: defaultStrategy,
            closeSourceBranch: pullRequest.closeSourceBranch ?? false,
            alreadyApproved: approved
        )
    }

    private func confirmedMergeOutcome(
        _ target: PullRequestActionTarget,
        record: PullRequestActionCredentialRecord
    ) async throws -> PullRequestMergeOutcome {
        let pullRequest: BitbucketPullRequestDTO
        do {
            pullRequest = try await read(
                url: try makeURL(path: pullRequestPath(target)),
                credential: record.credential
            )
        } catch is PullRequestActionError {
            return .outcomeUnknown
        } catch {
            return .outcomeUnknown
        }
        switch normalized(pullRequest.state) {
        case "MERGED":
            return .merged(mergeCommitHash: nonempty(pullRequest.mergeCommit?.hash))
        case "DECLINED", "SUPERSEDED":
            return .approvedButNotMerged(reason: .providerRejected)
        default:
            return .outcomeUnknown
        }
    }

    private enum MergeTaskTerminal {
        case completed
        case rejected
        case unknown
    }

    private func waitForMergeTask(
        _ url: URL,
        credential: AccountCredential
    ) async throws -> MergeTaskTerminal {
        for attempt in 0..<configuration.maximumMergeTaskPolls {
            if Task.isCancelled { return .unknown }
            let task: BitbucketMergeTaskDTO
            do {
                task = try await read(url: url, credential: credential)
            } catch let error as PullRequestActionError {
                switch error {
                case .mergeChecksPending, .mergeConflict, .independentApprovalRequired, .branchRestriction:
                    return .rejected
                default:
                    return .unknown
                }
            } catch {
                return .unknown
            }
            if normalized(task.mergeResult?.state) == "MERGED" { return .completed }
            switch normalized(task.taskStatus) {
            case "SUCCESS", "SUCCESSFUL", "COMPLETED":
                return .completed
            case "FAILED", "ERROR", "REJECTED":
                return .rejected
            case "PENDING", "IN_PROGRESS", "RUNNING":
                if attempt + 1 < configuration.maximumMergeTaskPolls {
                    do {
                        try await sleep(configuration.mergeTaskPollInterval)
                    } catch is CancellationError {
                        return .unknown
                    }
                }
            default:
                return .unknown
            }
        }
        return .unknown
    }

    private func requiredCredential(
        expectedAccountID: AccountID
    ) async throws -> PullRequestActionCredentialRecord {
        let record: PullRequestActionCredentialRecord
        do {
            guard let loaded = try await credentialStore.load() else {
                throw PullRequestActionError.notConfigured
            }
            record = loaded
        } catch let error as PullRequestActionError {
            throw error
        } catch {
            throw PullRequestActionError.temporarilyUnavailable
        }
        guard record.expectedAccountID == expectedAccountID else {
            throw PullRequestActionError.accountMismatch
        }
        return record
    }

    private func validateActionIdentity(
        _ record: PullRequestActionCredentialRecord
    ) async throws {
        let user: BitbucketUserDTO = try await read(
            url: try makeURL(path: ["user"]),
            credential: record.credential
        )
        guard matchesExpectedAccount(user, expected: record.expectedAccountID) else {
            throw PullRequestActionError.accountMismatch
        }
    }

    private func read<Value: Decodable>(
        url: URL,
        credential: AccountCredential
    ) async throws -> Value {
        var attempt = 0
        while true {
            try checkCancellation()
            attempt += 1
            let response: HTTPResponse
            do {
                response = try await transport.send(request(url: url, method: "GET", credential: credential))
            } catch {
                let mapped = mapTransport(error)
                guard Self.isRetryableRead(mapped), attempt < configuration.maximumReadAttempts else {
                    throw mapped
                }
                try await sleep(readBackoff(attempt: attempt))
                continue
            }
            guard (200..<300).contains(response.response.statusCode) else {
                let mapped = mapStatus(response.response)
                guard Self.isRetryableRead(mapped), attempt < configuration.maximumReadAttempts else {
                    throw mapped
                }
                try await sleep(retryDelay(response.response, attempt: attempt))
                continue
            }
            do {
                return try decoder.decode(Value.self, from: response.data)
            } catch {
                throw PullRequestActionError.malformedResponse
            }
        }
    }

    /// Write requests are deliberately sent exactly once.
    private func sendWrite(_ request: URLRequest) async throws -> HTTPResponse {
        try checkCancellation()
        do {
            return try await transport.send(request)
        } catch {
            throw mapTransport(error)
        }
    }

    private func request(
        url: URL,
        method: String,
        credential: AccountCredential,
        body: Data? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = configuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let raw = "\(credential.email):\(credential.token)"
        request.setValue("Basic \(Data(raw.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeURL(path: [String]) throws -> URL {
        guard isAllowedAPIURL(configuration.baseURL),
              var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw PullRequestActionError.invalidTarget
        }
        let encoded = try path.map { segment -> String in
            guard !segment.isEmpty,
                  let value = segment.addingPercentEncoding(withAllowedCharacters: .bitbucketPathSegmentAllowed) else {
                throw PullRequestActionError.invalidTarget
            }
            return value
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = basePath + "/" + encoded.joined(separator: "/")
        components.query = nil
        guard let url = components.url, isAllowedAPIURL(url) else {
            throw PullRequestActionError.invalidTarget
        }
        return url
    }

    private func pullRequestPath(_ target: PullRequestActionTarget) -> [String] {
        [
            "repositories", target.workspaceSlug, target.repositorySlug,
            "pullrequests", String(target.pullRequestID),
        ]
    }

    private func validatedMergeTaskURL(
        _ rawValue: String?,
        target: PullRequestActionTarget
    ) -> URL? {
        guard let rawValue = nonempty(rawValue),
              let candidate = URL(string: rawValue, relativeTo: configuration.baseURL)?.absoluteURL,
              isAllowedAPIURL(candidate),
              let expectedPrefix = try? makeURL(path: pullRequestPath(target) + ["merge", "task-status"]),
              candidate.path.hasPrefix(expectedPrefix.path + "/"),
              candidate.query == nil,
              candidate.fragment == nil,
              candidate.user == nil,
              candidate.password == nil else {
            return nil
        }
        return candidate
    }

    private func validate(_ target: PullRequestActionTarget) throws {
        guard target.pullRequestID > 0,
              target.buildNumber > 0,
              !target.accountID.rawValue.isEmpty,
              nonempty(target.workspaceSlug) != nil,
              nonempty(target.repositorySlug) != nil,
              nonempty(target.sourceBranch) != nil,
              nonempty(target.destinationBranch) != nil,
              nonempty(target.expectedSourceCommitHash) != nil else {
            throw PullRequestActionError.invalidTarget
        }
    }

    private func isAllowedAPIURL(_ url: URL) -> Bool {
        guard let base = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              base.scheme?.lowercased() == "https",
              base.host?.lowercased() == "api.bitbucket.org",
              components.scheme?.lowercased() == base.scheme?.lowercased(),
              components.host?.lowercased() == base.host?.lowercased(),
              components.port == base.port,
              components.user == nil,
              components.password == nil else {
            return false
        }
        let basePath = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        return components.path == basePath || components.path.hasPrefix(basePath + "/")
    }

    private func mapTransport(_ error: Error) -> PullRequestActionError {
        if error is CancellationError { return .cancelled }
        guard let apiError = error as? BitbucketAPIError else { return .temporarilyUnavailable }
        return switch apiError {
        case .invalidCredentials, .missingCredential: .invalidCredentials
        case .insufficientPermissions: .insufficientPermissions
        case let .rateLimited(retryAt): .rateLimited(retryAt: retryAt)
        case .offline: .offline
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .malformedResponse, .responseTooLarge, .pagination, .invalidURL, .unsafeRedirect:
            .malformedResponse
        case .server, .transport: .temporarilyUnavailable
        case .notFound: .pullRequestNotOpen
        }
    }

    private func allowedWebURL(_ value: String?) -> URL? {
        guard let value = nonempty(value),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "bitbucket.org",
              components.port == nil,
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return components.url
    }

    private func mapStatus(_ response: HTTPURLResponse) -> PullRequestActionError {
        switch response.statusCode {
        case 401: .invalidCredentials
        case 403: .insufficientPermissions
        case 404: .pullRequestNotOpen
        case 409: .mergeChecksPending
        case 429: .rateLimited(retryAt: retryAt(response))
        case 500...599: .temporarilyUnavailable
        default: .temporarilyUnavailable
        }
    }

    private func retryAt(_ response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 {
            return now().addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: raw)
    }

    private func retryDelay(_ response: HTTPURLResponse, attempt: Int) -> TimeInterval {
        if let retryAt = retryAt(response) {
            return max(0, retryAt.timeIntervalSince(now()))
        }
        return readBackoff(attempt: attempt)
    }

    private func readBackoff(attempt: Int) -> TimeInterval {
        min(configuration.maximumRetryDelay, pow(2, Double(max(0, attempt - 1))) * 0.25)
    }

    private func partialReason(
        for error: PullRequestActionError
    ) -> PullRequestApprovedButNotMergedReason {
        switch error {
        case .sourceHeadChanged, .staleRun: .sourceHeadChanged
        case .pullRequestNotOpen: .pullRequestClosed
        case .pipelineNotSuccessful: .pipelineNotSuccessful
        case .mergeConflict: .mergeConflict
        case .independentApprovalRequired: .independentApprovalRequired
        case .branchRestriction, .insufficientPermissions: .branchRestriction
        case .mergeChecksPending: .mergeChecksPending
        case .invalidCredentials, .rateLimited, .offline, .timedOut,
                .temporarilyUnavailable, .malformedResponse, .cancelled, .outcomeUnknown,
                .notConfigured, .accountMismatch:
            .validationUnavailable
        default: .providerRejected
        }
    }

    private static func isAmbiguousWrite(_ error: PullRequestActionError) -> Bool {
        switch error {
        case .offline, .timedOut, .temporarilyUnavailable, .malformedResponse, .cancelled, .outcomeUnknown:
            true
        default:
            false
        }
    }

    private static func isRetryableRead(_ error: PullRequestActionError) -> Bool {
        switch error {
        case .offline, .timedOut, .temporarilyUnavailable, .rateLimited:
            true
        default:
            false
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw PullRequestActionError.cancelled }
    }

    private func matchesExpectedAccount(
        _ user: BitbucketUserDTO?,
        expected: AccountID
    ) -> Bool {
        let expectedValue = expected.rawValue
        return nonempty(user?.uuid) == expectedValue || nonempty(user?.accountID) == expectedValue
    }

    private func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
    }

    private func normalizedHash(_ value: String?) -> String? {
        nonempty(value)?.lowercased()
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

private extension CharacterSet {
    static let bitbucketPathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#")
        return set
    }()
}
