import Foundation
import XCTest
@testable import BuildBeaconKit

final class BitbucketPullRequestActionClientTests: XCTestCase, @unchecked Sendable {
    func testConfigurationStatusChecksKeychainPresenceWithoutLoadingTokenData() async {
        let client = BitbucketPullRequestActionClient(
            credentialStore: ExistenceOnlyCredentialStore(),
            runValidator: ActionRunValidator(),
            transport: ActionTransport(steps: [])
        )

        let configured = await client.isConfigured

        XCTAssertTrue(configured)
    }

    func testConfigureValidatesTheExpectedAccountBeforeSaving() async throws {
        let store = ActionCredentialStore()
        let transport = ActionTransport(steps: [
            .response(status: 200, body: #"{"uuid":"account-1","account_id":"opaque-account-id","display_name":"Owner"}"#),
        ], identitySteps: [])
        let client = makeClient(store: store, transport: transport)

        try await client.configure(
            AccountCredential(email: "owner@example.com", token: "write-token"),
            expectedAccountID: AccountID(rawValue: "account-1")
        )

        let storedRecord = await store.record
        let saved = try XCTUnwrap(storedRecord)
        XCTAssertEqual(saved.expectedAccountID.rawValue, "account-1")
        XCTAssertEqual(saved.credential.email, "owner@example.com")
        let configured = await client.isConfigured
        XCTAssertTrue(configured)
    }

    func testConfigureRejectsAnotherAccountWithoutSaving() async {
        let store = ActionCredentialStore()
        let transport = ActionTransport(steps: [
            .response(status: 200, body: #"{"account_id":"another-account"}"#),
        ], identitySteps: [])
        let client = makeClient(store: store, transport: transport)

        await XCTAssertThrowsPullRequestActionError(
            try await client.configure(
                AccountCredential(email: "owner@example.com", token: "write-token"),
                expectedAccountID: AccountID(rawValue: "account-1")
            )
        ) { XCTAssertEqual($0, .accountMismatch) }
        let storedRecord = await store.record
        XCTAssertNil(storedRecord)
    }

    func testSynchronousFlowApprovesOnceMergesOnceAndConfirmsMerged() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: approvedParticipant()),
            .response(status: 200, body: openPullRequest(approved: true)),
            .response(status: 200, body: #"{"state":"MERGED"}"#),
            .response(status: 200, body: mergedPullRequest()),
        ])
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        let outcome = try await client.approveAndMerge(initial, strategy: .squash)

        XCTAssertEqual(outcome, .merged(mergeCommitHash: "merge123"))
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST", "GET", "POST", "GET"])
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 2)
        XCTAssertTrue(requests[2].url?.path.hasSuffix("/pullrequests/41/approve") == true)
        XCTAssertTrue(requests[4].url?.path.hasSuffix("/pullrequests/41/merge") == true)
        let mergeBody = try XCTUnwrap(requests[4].httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: mergeBody) as? [String: Any])
        XCTAssertEqual(object["merge_strategy"] as? String, "squash")
        XCTAssertEqual(object["close_source_branch"] as? Bool, true)
    }

    func testSynchronousFlowPublishesTheRealOperationPhases() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: approvedParticipant()),
            .response(status: 200, body: openPullRequest(approved: true)),
            .response(status: 200, body: #"{"state":"MERGED"}"#),
            .response(status: 200, body: mergedPullRequest()),
        ])
        let phases = ActionPhaseRecorder()
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        _ = try await client.approveAndMerge(initial, strategy: .squash) { phase in
            await phases.record(phase)
        }

        let recorded = await phases.values
        XCTAssertEqual(recorded, [
            .revalidatingBeforeApproval,
            .approving,
            .revalidatingBeforeMerge,
            .merging,
            .waitingForProvider,
        ])
    }

    func testApproveTransportFailureIsUnknownAndNeverRetried() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .failure(.timedOut),
        ])
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        let outcome = try await client.approveAndMerge(initial, strategy: .squash)

        XCTAssertEqual(outcome, .outcomeUnknown)
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST"])
    }

    func testApproveOversizedResponseIsUnknownAndNeverRetried() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .failure(.responseTooLarge(limit: 1_024)),
        ])
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        let outcome = try await client.approveAndMerge(initial, strategy: .squash)

        XCTAssertEqual(outcome, .outcomeUnknown)
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST"])
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/approve") == true }.count, 1)
    }

    func testApproveServerFailureIsUnknownAndNeverRetried() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .response(status: 503, body: #"{"type":"error"}"#),
        ])
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        let outcome = try await client.approveAndMerge(initial, strategy: .squash)

        XCTAssertEqual(outcome, .outcomeUnknown)
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST"])
    }

    func testSourceHeadChangeAfterApproveStopsBeforeMerge() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: approvedParticipant()),
            .response(status: 200, body: openPullRequest(head: "different")),
        ])
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        let outcome = try await client.approveAndMerge(initial, strategy: .squash)

        XCTAssertEqual(outcome, .approvedButNotMerged(reason: .sourceHeadChanged))
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST", "GET"])
    }

    func testMergeTransportFailureIsUnknownAndNeverRetried() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: approvedParticipant()),
            .response(status: 200, body: openPullRequest(approved: true)),
            .failure(.offline),
        ])
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        let outcome = try await client.approveAndMerge(initial, strategy: .squash)

        XCTAssertEqual(outcome, .outcomeUnknown)
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST", "GET", "POST"])
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/merge") == true }.count, 1)
    }

    func testMergeMalformedResponseIsUnknownAndNeverRetried() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: approvedParticipant()),
            .response(status: 200, body: openPullRequest(approved: true)),
            .failure(.malformedResponse),
        ])
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        let outcome = try await client.approveAndMerge(initial, strategy: .squash)

        XCTAssertEqual(outcome, .outcomeUnknown)
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST", "GET", "POST"])
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/merge") == true }.count, 1)
    }

    func testMergeServerFailureIsUnknownAndNeverRetried() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: approvedParticipant()),
            .response(status: 200, body: openPullRequest(approved: true)),
            .response(status: 503, body: #"{"type":"error"}"#),
        ])
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        let outcome = try await client.approveAndMerge(initial, strategy: .squash)

        XCTAssertEqual(outcome, .outcomeUnknown)
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/merge") == true }.count, 1)
    }

    func testAsyncMergePollsOnlyValidatedTaskThenConfirmsMerged() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let taskURL = "https://api.bitbucket.org/2.0/repositories/epicway/bladecp-warp/pullrequests/41/merge/task-status/task-1"
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: approvedParticipant()),
            .response(status: 200, body: openPullRequest(approved: true)),
            .response(status: 202, headers: ["Location": taskURL], body: ""),
            .response(status: 200, body: #"{"task_status":"PENDING"}"#),
            .response(status: 200, body: #"{"task_status":"SUCCESS"}"#),
            .response(status: 200, body: mergedPullRequest()),
        ])
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        let outcome = try await client.approveAndMerge(initial, strategy: .mergeCommit)

        XCTAssertEqual(outcome, .merged(mergeCommitHash: "merge123"))
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.count, 8)
        XCTAssertEqual(requests[5].url?.absoluteString, taskURL)
        XCTAssertEqual(requests[6].url?.absoluteString, taskURL)
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 2)
    }

    func testAsyncMergeRejectsForeignTaskLocationWithoutSendingCredential() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: approvedParticipant()),
            .response(status: 200, body: openPullRequest(approved: true)),
            .response(status: 202, headers: ["Location": "https://evil.example/task"], body: ""),
        ])
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        let outcome = try await client.approveAndMerge(initial, strategy: .squash)

        XCTAssertEqual(outcome, .outcomeUnknown)
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.count, 5)
    }

    func testAsyncTaskMalformedResponseIsUnknown() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let taskURL = "https://api.bitbucket.org/2.0/repositories/epicway/bladecp-warp/pullrequests/41/merge/task-status/task-1"
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: approvedParticipant()),
            .response(status: 200, body: openPullRequest(approved: true)),
            .response(status: 202, headers: ["Location": taskURL], body: ""),
            .response(status: 200, body: #"{"unexpected":true}"#),
        ])
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        let outcome = try await client.approveAndMerge(initial, strategy: .squash)

        XCTAssertEqual(outcome, .outcomeUnknown)
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.count, 6)
    }

    func testFinalVerificationFailureIsUnknown() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: approvedParticipant()),
            .response(status: 200, body: openPullRequest(approved: true)),
            .response(status: 200, body: #"{"state":"MERGED"}"#),
            .response(status: 503, body: #"{"type":"error"}"#),
        ])
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        let outcome = try await client.approveAndMerge(initial, strategy: .squash)

        XCTAssertEqual(outcome, .outcomeUnknown)
    }

    func testFinalVerificationOpenStateIsUnknown() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: approvedParticipant()),
            .response(status: 200, body: openPullRequest(approved: true)),
            .response(status: 200, body: #"{"state":"MERGED"}"#),
            .response(status: 200, body: openPullRequest(approved: true)),
        ])
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        let outcome = try await client.approveAndMerge(initial, strategy: .squash)

        XCTAssertEqual(outcome, .outcomeUnknown)
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 2)
    }

    func testIdentityMismatchBeforeApproveStopsWithoutAnyPost() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(
            steps: [.response(status: 200, body: openPullRequest())],
            identitySteps: [
                .response(
                    status: 200,
                    body: #"{"uuid":"another-account","account_id":"another-atlassian-account"}"#
                ),
            ]
        )
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        await XCTAssertThrowsPullRequestActionError(
            try await client.approveAndMerge(initial, strategy: .squash)
        ) { XCTAssertEqual($0, .accountMismatch) }

        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod != "POST" })
    }

    func testIdentityMismatchBeforeMergeStopsWithoutMergePost() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(
            steps: [
                .response(status: 200, body: openPullRequest()),
                .response(status: 200, body: openPullRequest()),
                .response(status: 200, body: approvedParticipant()),
            ],
            identitySteps: [
                .response(status: 200, body: actionIdentity()),
                .response(
                    status: 200,
                    body: #"{"uuid":"another-account","account_id":"another-atlassian-account"}"#
                ),
            ]
        )
        let client = makeClient(store: store, transport: transport)
        let initial = try await client.preflight(target())

        let outcome = try await client.approveAndMerge(initial, strategy: .squash)

        XCTAssertEqual(outcome, .approvedButNotMerged(reason: .validationUnavailable))
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/approve") == true }.count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.url?.path.hasSuffix("/merge") != true })
    }

    func testCancellationDuringAsyncMergePollingIsUnknown() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let taskURL = "https://api.bitbucket.org/2.0/repositories/epicway/bladecp-warp/pullrequests/41/merge/task-status/task-1"
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: approvedParticipant()),
            .response(status: 200, body: openPullRequest(approved: true)),
            .response(status: 202, headers: ["Location": taskURL], body: ""),
            .response(status: 200, body: #"{"task_status":"PENDING"}"#),
        ])
        let pollingStarted = expectation(description: "merge task polling started")
        let client = makeClient(store: store, transport: transport) { _ in
            pollingStarted.fulfill()
            try await Task.sleep(for: .seconds(30))
        }
        let initial = try await client.preflight(target())

        let operation = Task {
            try await client.approveAndMerge(initial, strategy: .squash)
        }
        await fulfillment(of: [pollingStarted], timeout: 1)
        operation.cancel()
        let outcome = try await operation.value

        XCTAssertEqual(outcome, .outcomeUnknown)
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.filter { $0.url?.path.contains("/task-status/") == true }.count, 1)
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 2)
    }

    func testPreflightRejectsChangedHeadWithoutAnyPost() async {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest(head: "new-head")),
        ])
        let client = makeClient(store: store, transport: transport)

        await XCTAssertThrowsPullRequestActionError(try await client.preflight(target())) {
            XCTAssertEqual($0, .sourceHeadChanged)
        }
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    }

    func testRemotePipelineFailureStopsPreflightBeforePullRequestRead() async {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(steps: [])
        let validator = ActionRunValidator(results: [.pipelineNotSuccessful])
        let client = makeClient(store: store, transport: transport, runValidator: validator)

        await XCTAssertThrowsPullRequestActionError(try await client.preflight(target())) {
            XCTAssertEqual($0, .pipelineNotSuccessful)
        }
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertTrue(requests.isEmpty)
    }

    func testRemotePipelineFailureAfterApproveStopsBeforeMerge() async throws {
        let store = ActionCredentialStore(record: credentialRecord())
        let transport = ActionTransport(steps: [
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: openPullRequest()),
            .response(status: 200, body: approvedParticipant()),
        ])
        let validator = ActionRunValidator(results: [nil, nil, .pipelineNotSuccessful])
        let client = makeClient(store: store, transport: transport, runValidator: validator)
        let initial = try await client.preflight(target())

        let outcome = try await client.approveAndMerge(initial, strategy: .squash)

        XCTAssertEqual(outcome, .approvedButNotMerged(reason: .pipelineNotSuccessful))
        let requests = nonIdentityRequests(await transport.requests)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST"])
    }

    private func makeClient(
        store: ActionCredentialStore,
        transport: ActionTransport,
        runValidator: ActionRunValidator = ActionRunValidator(),
        sleep: @escaping BitbucketPullRequestActionClient.Sleep = { _ in }
    ) -> BitbucketPullRequestActionClient {
        BitbucketPullRequestActionClient(
            credentialStore: store,
            runValidator: runValidator,
            transport: transport,
            configuration: .init(
                userAgent: "BuildBeaconTests/1",
                maximumReadAttempts: 1,
                maximumMergeTaskPolls: 3,
                mergeTaskPollInterval: 0
            ),
            sleep: sleep
        )
    }

    private func target() -> PullRequestActionTarget {
        let accountID = AccountID(rawValue: "account-1")
        let monitorID = MonitorID(
            accountID: accountID,
            workspaceID: WorkspaceID(rawValue: "workspace"),
            repositoryID: RepositoryID(rawValue: "repository"),
            target: .repositoryLatest
        )
        return PullRequestActionTarget(
            accountID: accountID,
            monitorID: monitorID,
            workspaceSlug: "epicway",
            repositorySlug: "bladecp-warp",
            pullRequestID: 41,
            runID: PipelineRunID(rawValue: "pipeline-87"),
            buildNumber: 87,
            expectedSourceCommitHash: "head123",
            sourceBranch: "feature/ready",
            destinationBranch: "dev",
            isProduction: false
        )
    }

    private func credentialRecord() -> PullRequestActionCredentialRecord {
        PullRequestActionCredentialRecord(
            credential: AccountCredential(email: "owner@example.com", token: "write-token"),
            expectedAccountID: AccountID(rawValue: "account-1")
        )
    }

    private func approvedParticipant() -> String {
        #"{"approved":true,"user":{"uuid":"account-1","account_id":"opaque-account-id"}}"#
    }

    private func actionIdentity() -> String {
        #"{"uuid":"account-1","account_id":"opaque-account-id"}"#
    }

    private func nonIdentityRequests(_ requests: [URLRequest]) -> [URLRequest] {
        requests.filter { $0.url?.path != "/2.0/user" }
    }

    private func openPullRequest(head: String = "head123", approved: Bool = false) -> String {
        """
        {
          "id": 41,
          "title": "Ready change",
          "state": "OPEN",
          "draft": false,
          "close_source_branch": true,
          "source": {"branch":{"name":"feature/ready"},"commit":{"hash":"\(head)"}},
          "destination": {"branch":{"name":"dev","merge_strategies":["merge_commit","squash"],"default_merge_strategy":"squash"}},
          "participants": \(approved ? #"[{"approved":true,"user":{"uuid":"account-1","account_id":"opaque-account-id"}}]"# : "[]"),
          "links": {"html":{"href":"https://bitbucket.org/epicway/bladecp-warp/pull-requests/41"}}
        }
        """
    }

    private func mergedPullRequest() -> String {
        #"{"id":41,"state":"MERGED","merge_commit":{"hash":"merge123"}}"#
    }
}

private actor ActionRunValidator: PullRequestActionRunValidating {
    private var results: [PullRequestActionError?]

    init(results: [PullRequestActionError?] = []) {
        self.results = results
    }

    func validatePullRequestActionRun(_ target: PullRequestActionTarget) async throws {
        guard !results.isEmpty else { return }
        if let error = results.removeFirst() { throw error }
    }
}

private actor ActionPhaseRecorder {
    private(set) var values: [PullRequestActionOperationPhase] = []

    func record(_ phase: PullRequestActionOperationPhase) {
        values.append(phase)
    }
}

private actor ActionCredentialStore: PullRequestActionCredentialStoring {
    private(set) var record: PullRequestActionCredentialRecord?

    init(record: PullRequestActionCredentialRecord? = nil) {
        self.record = record
    }

    func save(_ record: PullRequestActionCredentialRecord) async throws {
        self.record = record
    }

    func load() async throws -> PullRequestActionCredentialRecord? { record }

    func delete() async throws { record = nil }
}

private actor ExistenceOnlyCredentialStore: PullRequestActionCredentialStoring {
    func save(_ record: PullRequestActionCredentialRecord) async throws {}
    func load() async throws -> PullRequestActionCredentialRecord? {
        throw PullRequestActionError.outcomeUnknown
    }
    func exists() async throws -> Bool { true }
    func delete() async throws {}
}

private actor ActionTransport: HTTPTransport {
    enum Step: Sendable {
        case response(status: Int, headers: [String: String] = [:], body: String)
        case failure(BitbucketAPIError)
    }

    private var steps: [Step]
    private var identitySteps: [Step]?
    private(set) var requests: [URLRequest] = []

    var requestCount: Int { requests.count }

    init(steps: [Step], identitySteps: [Step]? = nil) {
        self.steps = steps
        self.identitySteps = identitySteps
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if request.url?.path == "/2.0/user" {
            if identitySteps == nil {
                return response(
                    for: request,
                    status: 200,
                    headers: [:],
                    body: #"{"uuid":"account-1","account_id":"opaque-account-id"}"#
                )
            }
            if identitySteps?.isEmpty == false {
                return try consume(identitySteps!.removeFirst(), for: request)
            }
        }
        guard !steps.isEmpty else { throw BitbucketAPIError.transport }
        return try consume(steps.removeFirst(), for: request)
    }

    private func consume(_ step: Step, for request: URLRequest) throws -> HTTPResponse {
        switch step {
        case let .failure(error):
            throw error
        case let .response(status, headers, body):
            return response(for: request, status: status, headers: headers, body: body)
        }
    }

    private func response(
        for request: URLRequest,
        status: Int,
        headers: [String: String],
        body: String
    ) -> HTTPResponse {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return HTTPResponse(data: Data(body.utf8), response: response)
    }
}

private func XCTAssertThrowsPullRequestActionError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (PullRequestActionError) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected PullRequestActionError", file: file, line: line)
    } catch let error as PullRequestActionError {
        verify(error)
    } catch {
        XCTFail("Unexpected error type", file: file, line: line)
    }
}
