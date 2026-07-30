import Foundation
import XCTest
@testable import BuildBeaconKit

final class BitbucketClientTests: XCTestCase, @unchecked Sendable {
    func testValidateUsesBasicAuthAndRedactsCredentialDescription() async throws {
        let credential = AccountCredential(email: "person@example.com", token: "super-secret")
        let transport = RecordingTransport { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.bitbucket.org/2.0/user?pagelen=100")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "BuildBeaconTests/1")
            let expectedAuthorization = "Basic \(Data("person@example.com:super-secret".utf8).base64EncodedString())"
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization") == expectedAuthorization)
            return .json(#"{"uuid":"{account}","display_name":"A Person"}"#)
        }
        let client = makeClient(store: InMemoryCredentialStore(), transport: transport)

        let profile = try await client.validate(credential: credential)

        XCTAssertEqual(profile.id.rawValue, "{account}")
        XCTAssertEqual(profile.email, "person@example.com")
        XCTAssertFalse(String(describing: credential).contains("super-secret"))
        XCTAssertFalse(String(describing: credential).contains("person@example.com"))
    }

    func testWorkspacesFollowPaginationAndDeduplicateUUIDs() async throws {
        let accountID = AccountID(rawValue: "account")
        let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
        let transport = SequencedTransport(responses: [
            .json(#"{"values":[{"type":"workspace_access","administrator":true,"workspace":{"uuid":"1","slug":"one","name":"One"}},{"type":"workspace_access","administrator":false,"workspace":{"uuid":"2","slug":"two","name":"Two"}}],"next":"https://api.bitbucket.org/2.0/user/workspaces?page=2"}"#),
            .json(#"{"values":[{"type":"workspace_access","administrator":false,"workspace":{"uuid":"2","slug":"two","name":"Duplicate"}},{"type":"workspace_access","administrator":true,"workspace":{"uuid":"3","slug":"three"}}]}"#),
        ])
        let client = makeClient(store: store, transport: transport)

        let workspaces = try await client.listWorkspaces(accountID: accountID)

        XCTAssertEqual(workspaces.map(\.id.rawValue), ["1", "2", "3"])
        XCTAssertEqual(workspaces.map(\.name), ["One", "Two", "three"])
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.url?.absoluteString), [
            "https://api.bitbucket.org/2.0/user/workspaces?pagelen=100",
            "https://api.bitbucket.org/2.0/user/workspaces?page=2",
        ])
    }

    func testWorkspacesAcceptsLegacyDirectWorkspaceRecords() async throws {
        let accountID = AccountID(rawValue: "account")
        let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
        let client = makeClient(
            store: store,
            transport: SequencedTransport(responses: [
                .json(#"{"values":[{"uuid":"legacy","slug":"legacy-workspace","name":"Legacy"}]}"#),
            ])
        )

        let workspaces = try await client.listWorkspaces(accountID: accountID)

        XCTAssertEqual(workspaces, [WorkspaceInfo(id: .init(rawValue: "legacy"), slug: "legacy-workspace", name: "Legacy")])
    }

    func testWorkspacesRejectsAccessRecordWithoutWorkspaceOrWorkspaceIdentity() async throws {
        let accountID = AccountID(rawValue: "account")
        let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)

        for response in [
            HTTPResponse.json(#"{"values":[{"type":"workspace_access","administrator":true}]}"#),
            .json(#"{"values":[{"type":"workspace_access","administrator":true,"workspace":{"uuid":"missing-slug"}}]}"#),
        ] {
            let client = makeClient(store: store, transport: SequencedTransport(responses: [response]))
            await XCTAssertThrowsErrorAsync(try await client.listWorkspaces(accountID: accountID)) { error in
                XCTAssertEqual(error as? BitbucketAPIError, .malformedResponse)
            }
        }
    }

    func testPaginationRejectsForeignNextBeforeSendingCredential() async throws {
        let accountID = AccountID(rawValue: "account")
        let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
        let transport = SequencedTransport(responses: [
            .json(#"{"values":[{"uuid":"1","slug":"one","name":"One"}],"next":"https://evil.example/steal"}"#),
        ])
        let client = makeClient(store: store, transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.listWorkspaces(accountID: accountID)) { error in
            XCTAssertEqual(error as? BitbucketAPIError, .pagination(.invalidNextURL(partialItemCount: 1)))
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testPaginationDetectsCycleAndReportsPartialCount() async throws {
        let accountID = AccountID(rawValue: "account")
        let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
        let first = "https://api.bitbucket.org/2.0/user/workspaces?pagelen=100"
        let transport = SequencedTransport(responses: [
            .json(#"{"values":[{"uuid":"1","slug":"one","name":"One"}],"next":"https://api.bitbucket.org/2.0/user/workspaces?page=2"}"#),
            .json("{\"values\":[{\"uuid\":\"2\",\"slug\":\"two\",\"name\":\"Two\"}],\"next\":\"\(first)\"}"),
        ])
        let client = makeClient(store: store, transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.listWorkspaces(accountID: accountID)) { error in
            XCTAssertEqual(error as? BitbucketAPIError, .pagination(.cycleDetected(partialItemCount: 2)))
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testPaginationPageCapReportsHowManyItemsWereCollected() async throws {
        let accountID = AccountID(rawValue: "account")
        let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
        let transport = SequencedTransport(responses: [
            .json(#"{"values":[{"uuid":"1","slug":"one","name":"One"}],"next":"https://api.bitbucket.org/2.0/user/workspaces?page=2"}"#),
        ])
        let configuration = BitbucketClientConfiguration(
            userAgent: "BuildBeaconTests/1",
            maximumPages: 1,
            maximumAttempts: 1
        )
        let client = BitbucketClient(credentialStore: store, transport: transport, configuration: configuration)

        await XCTAssertThrowsErrorAsync(try await client.listWorkspaces(accountID: accountID)) { error in
            XCTAssertEqual(
                error as? BitbucketAPIError,
                .pagination(.pageLimitExceeded(limit: 1, partialItemCount: 1))
            )
        }
    }

    func testRepositoriesAndBranchesEncodePathSegmentsAndMapMetadata() async throws {
        let accountID = AccountID(rawValue: "account")
        let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
        let workspace = WorkspaceInfo(id: .init(rawValue: "w"), slug: "team space", name: "Team")
        let transport = SequencedTransport(responses: [
            .json(#"{"values":[{"uuid":"repo","slug":"mobile app","name":"Mobile","project":{"key":"APP","name":"Apps"},"mainbranch":{"name":"main"}}]}"#),
            .json(#"{"values":[{"name":"feature/a"},{"name":"main"}]}"#),
        ])
        let client = makeClient(store: store, transport: transport)

        let repositories = try await client.listRepositories(in: workspace, accountID: accountID)
        let branches = try await client.listBranches(in: repositories[0], accountID: accountID)

        XCTAssertEqual(repositories[0].projectKey, "APP")
        XCTAssertEqual(repositories[0].defaultBranch, "main")
        XCTAssertEqual(branches, [.init(name: "feature/a"), .init(name: "main", isDefault: true)])
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.path, "/2.0/repositories/team space")
        XCTAssertEqual(requests[1].url?.path, "/2.0/repositories/team space/mobile app/refs/branches")
    }

    func testLatestPipelineUsesServerSideBranchFilterAndLoadsSteps() async throws {
        let accountID = AccountID(rawValue: "account")
        let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
        let transport = SequencedTransport(responses: [
            .json(#"{"values":[{"uuid":"{pipeline}","build_number":42,"state":{"name":"COMPLETED","result":{"name":"FAILED"}},"target":{"ref_name":"feature/a","commit":{"hash":"abcdef"}},"created_on":"2026-07-21T10:00:00Z"}]}"#),
            .json(#"{"values":[{"uuid":"{step}","name":"Tests","state":{"name":"PAUSED"}}]}"#),
            .json(#"{"hash":"abcdef","message":"Ship pipeline context\n\nMore detail","author":{"user":{"display_name":"A Developer"}},"date":"2026-07-21T09:58:00Z","links":{"html":{"href":"https://bitbucket.org/team/app/commits/abcdef"}}}"#),
            .json(#"{"values":[{"id":17,"title":"Ship context","state":"OPEN","links":{"html":{"href":"https://bitbucket.org/team/app/pull-requests/17"}}}]}"#),
        ])
        let client = makeClient(store: store, transport: transport)
        let monitor = MonitorConfiguration(
            id: .init(
                accountID: accountID,
                workspaceID: .init(rawValue: "workspace"),
                repositoryID: .init(rawValue: "repository"),
                target: .branch(exactName: "feature/a")
            ),
            workspaceSlug: "team",
            workspaceName: "Team",
            repositorySlug: "app",
            repositoryName: "App"
        )

        let fetchedPipeline = try await client.latestPipeline(for: monitor)
        let pipeline = try XCTUnwrap(fetchedPipeline)

        XCTAssertEqual(pipeline.buildNumber, 42)
        XCTAssertEqual(pipeline.phase, .failed)
        XCTAssertEqual(pipeline.steps.first?.phase, .awaitingApproval)
        XCTAssertEqual(pipeline.commitContext?.message, "Ship pipeline context")
        XCTAssertEqual(pipeline.commitContext?.authorName, "A Developer")
        XCTAssertEqual(pipeline.commitContext?.webURL?.host, "bitbucket.org")
        XCTAssertEqual(pipeline.pullRequest?.id, 17)
        XCTAssertEqual(pipeline.pullRequest?.title, "Ship context")
        let requests = await transport.requests
        let pipelineQuery = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(pipelineQuery.first(where: { $0.name == "q" })?.value, #"target.ref_name="feature/a""#)
        XCTAssertEqual(requests[1].url?.path, "/2.0/repositories/team/app/pipelines/{pipeline}/steps")
        XCTAssertEqual(requests[2].url?.path, "/2.0/repositories/team/app/commit/abcdef")
        XCTAssertEqual(requests[3].url?.path, "/2.0/repositories/team/app/commit/abcdef/pullrequests")
    }

    func testLatestPipelineSuppressesOptionalPullRequestFailuresAndUnsafeLinks() async throws {
        for response in [
            HTTPResponse.status(401), .status(403), .status(404), .status(202), .json("not json"),
        ] {
            let accountID = AccountID(rawValue: "account")
            let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
            let transport = SequencedTransport(responses: [
                .json(#"{"values":[{"uuid":"p","build_number":1,"state":{"name":"COMPLETED","result":{"name":"SUCCESSFUL"}},"target":{"commit":{"hash":"abcdef"}}}]}"#),
                .json(#"{"values":[]}"#),
                .json(#"{"hash":"abcdef","message":"Safe pipeline","links":{"html":{"href":"https://evil.example/commit"}}}"#),
                response,
            ])
            let client = makeClient(store: store, transport: transport)

            let fetchedPipeline = try await client.latestPipeline(for: monitor(accountID: accountID))
            let pipeline = try XCTUnwrap(fetchedPipeline)

            XCTAssertEqual(pipeline.commitContext?.message, "Safe pipeline")
            XCTAssertNil(pipeline.commitContext?.webURL)
            XCTAssertNil(pipeline.pullRequest)
        }
    }

    func testLatestPipelineCachesCommitAndPullRequestContextPerRepositoryAndHash() async throws {
        let accountID = AccountID(rawValue: "account")
        let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
        let pipeline = #"{"values":[{"uuid":"p","build_number":1,"state":{"name":"COMPLETED","result":{"name":"SUCCESSFUL"}},"target":{"commit":{"hash":"abcdef"}}}]}"#
        let transport = SequencedTransport(responses: [
            .json(pipeline), .json(#"{"values":[]}"#),
            .json(#"{"hash":"abcdef","message":"Cached"}"#), .json(#"{"values":[]}"#),
            .json(pipeline), .json(#"{"values":[]}"#),
        ])
        let client = makeClient(store: store, transport: transport)

        _ = try await client.latestPipeline(for: monitor(accountID: accountID))
        _ = try await client.latestPipeline(for: monitor(accountID: accountID))

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(requests.filter { $0.url?.path.contains("/commit/abcdef") == true }.count, 2)
    }

    func testLatestPipelineCommitContextCacheIsIsolatedByAccount() async throws {
        let firstAccount = AccountID(rawValue: "account-one")
        let secondAccount = AccountID(rawValue: "account-two")
        let store = InMemoryCredentialStore()
        await store.save(.init(email: "one@example.com", token: "one"), accountID: firstAccount)
        await store.save(.init(email: "two@example.com", token: "two"), accountID: secondAccount)
        let pipeline = #"{"values":[{"uuid":"p","build_number":1,"state":{"name":"COMPLETED","result":{"name":"SUCCESSFUL"}},"target":{"commit":{"hash":"same-hash"}}}]}"#
        let transport = SequencedTransport(responses: [
            .json(pipeline), .json(#"{"values":[]}"#),
            .json(#"{"hash":"same-hash","message":"First account"}"#), .json(#"{"values":[]}"#),
            .json(pipeline), .json(#"{"values":[]}"#),
            .json(#"{"hash":"same-hash","message":"Second account"}"#), .json(#"{"values":[]}"#),
        ])
        let client = makeClient(store: store, transport: transport)

        let firstFetchedPipeline = try await client.latestPipeline(for: monitor(accountID: firstAccount))
        let secondFetchedPipeline = try await client.latestPipeline(for: monitor(accountID: secondAccount))
        let firstPipeline = try XCTUnwrap(firstFetchedPipeline)
        let secondPipeline = try XCTUnwrap(secondFetchedPipeline)

        XCTAssertEqual(firstPipeline.commitContext?.message, "First account")
        XCTAssertEqual(secondPipeline.commitContext?.message, "Second account")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 8)
        XCTAssertEqual(requests.filter { $0.url?.path.contains("/commit/same-hash") == true }.count, 4)
    }

    func testUnknownPipelineStateIsPreservedWithoutBecomingSuccess() async throws {
        let accountID = AccountID(rawValue: "account")
        let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
        let transport = SequencedTransport(responses: [
            .json(#"{"values":[{"uuid":"p","build_number":1,"state":{"name":"TELEPORTING","result":{"name":"MAYBE"}}}]}"#),
            .json(#"{"values":[]}"#),
        ])
        let client = makeClient(store: store, transport: transport)

        let fetchedPipeline = try await client.latestPipeline(for: monitor(accountID: accountID))
        let pipeline = try XCTUnwrap(fetchedPipeline)

        XCTAssertEqual(pipeline.phase, .unknown(remoteState: "TELEPORTING", remoteResult: "MAYBE"))
    }

    func testDefaultBranchFetchesCurrentRepositoryMetadataThenFiltersServerSide() async throws {
        let accountID = AccountID(rawValue: "account")
        let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
        let transport = SequencedTransport(responses: [
            .json(#"{"uuid":"r","slug":"app","mainbranch":{"name":"trunk"}}"#),
            .json(#"{"values":[]}"#),
        ])
        let client = makeClient(store: store, transport: transport)
        var defaultMonitor = monitor(accountID: accountID)
        defaultMonitor = MonitorConfiguration(
            id: .init(
                accountID: accountID,
                workspaceID: defaultMonitor.id.workspaceID,
                repositoryID: defaultMonitor.id.repositoryID,
                target: .defaultBranch
            ),
            workspaceSlug: defaultMonitor.workspaceSlug,
            workspaceName: defaultMonitor.workspaceName,
            repositorySlug: defaultMonitor.repositorySlug,
            repositoryName: defaultMonitor.repositoryName
        )

        let pipeline = try await client.latestPipeline(for: defaultMonitor)

        XCTAssertNil(pipeline)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/2.0/repositories/team/app")
        let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "q" })?.value, #"target.ref_name="trunk""#)
    }

    func testStatusTaxonomyDoesNotRetryPermanentFailures() async throws {
        for (status, expected) in [
            (401, BitbucketAPIError.invalidCredentials),
            (403, .insufficientPermissions),
            (404, .notFound),
        ] {
            let transport = SequencedTransport(responses: [.status(status)])
            let client = makeClient(store: InMemoryCredentialStore(), transport: transport)
            await XCTAssertThrowsErrorAsync(try await client.validate(credential: .init(email: "a", token: "b"))) { error in
                XCTAssertEqual(error as? BitbucketAPIError, expected)
            }
            let requestCount = await transport.requestCount
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testServerAndRedirectStatusesMapWithoutResponseDetails() async throws {
        for (status, expected) in [
            (302, BitbucketAPIError.unsafeRedirect),
            (500, .server(status: 500)),
            (503, .server(status: 503)),
        ] {
            let transport = SequencedTransport(responses: [.status(status)])
            let configuration = BitbucketClientConfiguration(userAgent: "BuildBeaconTests/1", maximumAttempts: 1)
            let client = BitbucketClient(
                credentialStore: InMemoryCredentialStore(),
                transport: transport,
                configuration: configuration
            )
            await XCTAssertThrowsErrorAsync(try await client.validate(credential: .init(email: "a", token: "b"))) { error in
                XCTAssertEqual(error as? BitbucketAPIError, expected)
            }
        }
    }

    func test429NeverTruncatesServerRetryAfterToBackoffMaximum() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let transport = SequencedTransport(responses: [
            .status(429, headers: ["Retry-After": "120"]),
            .json(#"{"uuid":"u","display_name":"User"}"#),
        ])
        let delays = DelayRecorder()
        let configuration = BitbucketClientConfiguration(userAgent: "BuildBeaconTests/1", maximumAttempts: 2, maximumRetryDelay: 3)
        let client = BitbucketClient(
            credentialStore: InMemoryCredentialStore(),
            transport: transport,
            configuration: configuration,
            now: { now },
            sleep: { delay in await delays.record(delay) }
        )

        _ = try await client.validate(credential: .init(email: "a", token: "b"))

        let recordedDelays = await delays.values
        let requestCount = await transport.requestCount
        XCTAssertEqual(recordedDelays, [120])
        XCTAssertEqual(requestCount, 2)
    }

    func testRetryAfterIsExposedWhenRetriesAreDisabled() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let transport = SequencedTransport(responses: [.status(429, headers: ["Retry-After": "30"])])
        let configuration = BitbucketClientConfiguration(userAgent: "BuildBeaconTests/1", maximumAttempts: 1)
        let client = BitbucketClient(
            credentialStore: InMemoryCredentialStore(),
            transport: transport,
            configuration: configuration,
            now: { now }
        )

        await XCTAssertThrowsErrorAsync(try await client.validate(credential: .init(email: "a", token: "b"))) { error in
            XCTAssertEqual(error as? BitbucketAPIError, .rateLimited(retryAt: now.addingTimeInterval(30)))
        }
    }

    func testTransportErrorsMapToStableTaxonomy() async throws {
        for error in [BitbucketAPIError.offline, .timedOut, .cancelled, .transport] {
            let transport = FailingTransport(error: error)
            let configuration = BitbucketClientConfiguration(userAgent: "BuildBeaconTests/1", maximumAttempts: 1)
            let client = BitbucketClient(
                credentialStore: InMemoryCredentialStore(),
                transport: transport,
                configuration: configuration
            )
            await XCTAssertThrowsErrorAsync(try await client.validate(credential: .init(email: "a", token: "b"))) { thrown in
                XCTAssertEqual(thrown as? BitbucketAPIError, error)
            }
        }
    }

    func testMalformedJSONAndMissingRequiredIdentityAreRejected() async throws {
        for response in [HTTPResponse.json("{"), .json(#"{"display_name":"No identity"}"#)] {
            let client = makeClient(store: InMemoryCredentialStore(), transport: SequencedTransport(responses: [response]))
            await XCTAssertThrowsErrorAsync(try await client.validate(credential: .init(email: "a", token: "b"))) { error in
                XCTAssertEqual(error as? BitbucketAPIError, .malformedResponse)
            }
        }
    }

    func testFractionalAndInvalidDatesAreDecodedTolerantly() async throws {
        let accountID = AccountID(rawValue: "account")
        let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
        let transport = SequencedTransport(responses: [
            .json(#"{"values":[{"uuid":"p","build_number":1,"state":{"name":"IN_PROGRESS"},"created_on":"2026-07-21T10:00:00.123Z","completed_on":"not-a-date"}]}"#),
            .json(#"{"values":[]}"#),
        ])
        let client = makeClient(store: store, transport: transport)

        let fetchedPipeline = try await client.latestPipeline(for: monitor(accountID: accountID))
        let pipeline = try XCTUnwrap(fetchedPipeline)

        XCTAssertNotNil(pipeline.startedAt)
        XCTAssertNil(pipeline.completedAt)
    }

    func testMapperMatchesDomainReducerForAuditedRemoteStates() {
        let cases: [(String?, String?, PipelinePhase, PipelineStepPhase)] = [
            ("HALTED", nil, .awaitingApproval, .awaitingApproval),
            ("CANCELLED", nil, .stopped, .stopped),
            ("CANCELED", nil, .stopped, .stopped),
            ("COMPLETED", "CANCELLED", .stopped, .stopped),
            ("COMPLETED", "CANCELED", .stopped, .stopped),
            ("COMPLETED", "SUCCEEDED", .succeeded, .succeeded),
            ("COMPLETED", "EXPIRED", .expired, .failed),
        ]

        for (remoteState, remoteResult, expectedPipeline, expectedStep) in cases {
            let result = remoteResult.map { BitbucketResultDTO(name: $0, type: nil) }
            let state = BitbucketStateDTO(name: remoteState, type: nil, result: result, stage: nil)
            XCTAssertEqual(BitbucketMapper.pipelinePhase(state), expectedPipeline)
            XCTAssertEqual(BitbucketMapper.stepPhase(state), expectedStep)
            XCTAssertEqual(
                BitbucketMapper.pipelinePhase(state),
                PipelineStateReducer.reduce(remoteState: remoteState, remoteResult: remoteResult)
            )
            XCTAssertEqual(
                BitbucketMapper.stepPhase(state),
                PipelineStateReducer.reduceStep(remoteState: remoteState, remoteResult: remoteResult)
            )
        }
    }

    func testLatestPipelineResolvesManualStepTriggerAndActiveStepPrecedence() async throws {
        let accountID = AccountID(rawValue: "account")
        let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
        let pipeline = #"{"values":[{"uuid":"p","build_number":1,"state":{"name":"IN_PROGRESS"}}]}"#
        let transport = SequencedTransport(responses: [
            .json(pipeline),
            .json(#"{"values":[{"uuid":"completed","name":"Build","state":{"name":"COMPLETED","result":{"name":"SUCCESSFUL"}}},{"uuid":"manual","name":"Deploy","state":{"name":"PENDING"},"trigger":{"type":"  PIPELINE_STEP_TRIGGER_MANUAL  "}}]}"#),
        ])
        let client = makeClient(store: store, transport: transport)

        let fetchedPipeline = try await client.latestPipeline(for: monitor(accountID: accountID))

        XCTAssertEqual(fetchedPipeline?.phase, .awaitingApproval)
        XCTAssertEqual(fetchedPipeline?.steps.map(\.phase), [.succeeded, .awaitingApproval])
    }

    func testLatestPipelineKeepsRunningWhenManualStepAndRunningStepCoexist() async throws {
        let accountID = AccountID(rawValue: "account")
        let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
        let transport = SequencedTransport(responses: [
            .json(#"{"values":[{"uuid":"p","build_number":1,"state":{"name":"IN_PROGRESS"}}]}"#),
            .json(#"{"values":[{"uuid":"running","name":"Tests","state":{"name":"IN_PROGRESS"}},{"uuid":"manual","name":"Deploy","state":{"name":"PENDING"},"trigger":{"type":"pipeline_step_trigger_manual"}}]}"#),
        ])
        let client = makeClient(store: store, transport: transport)

        let fetchedPipeline = try await client.latestPipeline(for: monitor(accountID: accountID))

        XCTAssertEqual(fetchedPipeline?.phase, .running)
    }

    func testLatestPipelineDoesNotTreatAutomaticOrUnknownTriggerAsApproval() async throws {
        for trigger in ["pipeline_step_trigger_automatic", "pipeline_step_trigger_future"] {
            let accountID = AccountID(rawValue: "account-\(trigger)")
            let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
            let transport = SequencedTransport(responses: [
                .json(#"{"values":[{"uuid":"p","build_number":1,"state":{"name":"IN_PROGRESS"}}]}"#),
                .json("{\"values\":[{\"uuid\":\"pending\",\"name\":\"Next\",\"state\":{\"name\":\"PENDING\"},\"trigger\":{\"type\":\"\(trigger)\"}}]}"),
            ])
            let client = makeClient(store: store, transport: transport)

            let fetchedPipeline = try await client.latestPipeline(for: monitor(accountID: accountID))

            XCTAssertEqual(fetchedPipeline?.phase, .running, "trigger: \(trigger)")
            XCTAssertEqual(fetchedPipeline?.steps.first?.phase, .queued, "trigger: \(trigger)")
        }
    }

    func testLatestPipelineResolvesInProgressStageWithSteps() async throws {
        let cases: [(stage: String, steps: String, expected: PipelinePhase)] = [
            (
                " PAUSED ",
                #"{"values":[{"uuid":"manual","name":"Deploy","state":{"name":"PENDING"},"trigger":{"type":"pipeline_step_trigger_manual"}}]}"#,
                .awaitingApproval
            ),
            (
                "RUNNING",
                #"{"values":[{"uuid":"manual","name":"Deploy","state":{"name":"PENDING"},"trigger":{"type":"pipeline_step_trigger_manual"}}]}"#,
                .awaitingApproval
            ),
            (
                "RUNNING",
                #"{"values":[{"uuid":"running","name":"Tests","state":{"name":"IN_PROGRESS"}}]}"#,
                .running
            ),
            (
                "WAITING_FOR_TELEPORT",
                #"{"values":[{"uuid":"manual","name":"Deploy","state":{"name":"PENDING"},"trigger":{"type":"pipeline_step_trigger_manual"}}]}"#,
                .unknown(remoteState: "WAITING_FOR_TELEPORT", remoteResult: nil)
            ),
        ]

        for testCase in cases {
            let accountID = AccountID(rawValue: "account-stage-\(testCase.stage)")
            let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
            let transport = SequencedTransport(responses: [
                .json("{\"values\":[{\"uuid\":\"p\",\"build_number\":1,\"state\":{\"name\":\"IN_PROGRESS\",\"stage\":{\"name\":\"\(testCase.stage)\"}}}]}"),
                .json(testCase.steps),
            ])
            let client = makeClient(store: store, transport: transport)

            let fetchedPipeline = try await client.latestPipeline(for: monitor(accountID: accountID))

            XCTAssertEqual(fetchedPipeline?.phase, testCase.expected, "stage: \(testCase.stage)")
        }
    }

    func testLatestPipelineMapsOfficialTypeOnlyDiscriminators() async throws {
        let cases: [(pipeline: String, steps: String, phase: PipelinePhase, stepPhase: PipelineStepPhase?)] = [
            (
                #"{"values":[{"uuid":"p","build_number":1,"state":{"type":"pipeline_state_in_progress","stage":{"type":"pipeline_state_in_progress_paused"}}}]}"#,
                #"{"values":[{"uuid":"ready","name":"Deploy","state":{"type":"pipeline_step_state_ready"}}]}"#,
                .awaitingApproval,
                .queued
            ),
            (
                #"{"values":[{"uuid":"p","build_number":1,"state":{"type":"pipeline_state_in_progress","stage":{"type":"pipeline_state_in_progress_running"}}}]}"#,
                #"{"values":[{"uuid":"running","name":"Tests","state":{"type":"pipeline_step_state_in_progress"}}]}"#,
                .running,
                .running
            ),
            (
                #"{"values":[{"uuid":"p","build_number":1,"state":{"type":"pipeline_state_completed","result":{"type":"pipeline_state_completed_successful"}}}]}"#,
                #"{"values":[{"uuid":"complete","name":"Tests","state":{"type":"pipeline_step_state_completed","result":{"type":"pipeline_step_state_completed_successful"}}}]}"#,
                .succeeded,
                .succeeded
            ),
            (
                #"{"values":[{"uuid":"p","build_number":1,"state":{"type":"pipeline_state_completed","result":{"type":"pipeline_state_completed_failed"}}}]}"#,
                #"{"values":[{"uuid":"skipped","name":"Deploy","state":{"type":"pipeline_step_state_completed","result":{"type":"pipeline_step_state_completed_not_run"}}}]}"#,
                .failed,
                .stopped
            ),
            (
                #"{"values":[{"uuid":"p","build_number":1,"state":{"type":"pipeline_state_future"}}]}"#,
                #"{"values":[]}"#,
                .unknown(remoteState: "pipeline_state_future", remoteResult: nil),
                nil
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            let accountID = AccountID(rawValue: "account-type-\(index)")
            let store = InMemoryCredentialStore(credential: .init(email: "a@b.com", token: "token"), accountID: accountID)
            let transport = SequencedTransport(responses: [.json(testCase.pipeline), .json(testCase.steps)])
            let client = makeClient(store: store, transport: transport)

            let fetchedPipeline = try await client.latestPipeline(for: monitor(accountID: accountID))

            XCTAssertEqual(fetchedPipeline?.phase, testCase.phase)
            XCTAssertEqual(fetchedPipeline?.steps.first?.phase, testCase.stepPhase)
        }
    }

    private func makeClient(store: any CredentialStore, transport: any HTTPTransport) -> BitbucketClient {
        BitbucketClient(
            credentialStore: store,
            transport: transport,
            configuration: .init(userAgent: "BuildBeaconTests/1", maximumAttempts: 1)
        )
    }

    private func monitor(accountID: AccountID) -> MonitorConfiguration {
        MonitorConfiguration(
            id: .init(
                accountID: accountID,
                workspaceID: .init(rawValue: "workspace"),
                repositoryID: .init(rawValue: "repository"),
                target: .repositoryLatest
            ),
            workspaceSlug: "team",
            workspaceName: "Team",
            repositorySlug: "app",
            repositoryName: "App"
        )
    }
}

private actor InMemoryCredentialStore: CredentialStore {
    private var values: [AccountID: AccountCredential] = [:]

    init(credential: AccountCredential? = nil, accountID: AccountID? = nil) {
        if let credential, let accountID { values[accountID] = credential }
    }

    func save(_ credential: AccountCredential, accountID: AccountID) { values[accountID] = credential }
    func load(accountID: AccountID) -> AccountCredential? { values[accountID] }
    func delete(accountID: AccountID) { values[accountID] = nil }
}

private actor SequencedTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private(set) var requests: [URLRequest] = []
    var requestCount: Int { requests.count }

    init(responses: [HTTPResponse]) { self.responses = responses }

    func send(_ request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw BitbucketAPIError.transport }
        return responses.removeFirst()
    }
}

private struct RecordingTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) throws -> HTTPResponse
    init(handler: @escaping @Sendable (URLRequest) throws -> HTTPResponse) { self.handler = handler }
    func send(_ request: URLRequest) throws -> HTTPResponse { try handler(request) }
}

private struct FailingTransport: HTTPTransport {
    let error: BitbucketAPIError
    func send(_ request: URLRequest) throws -> HTTPResponse { throw error }
}

private actor DelayRecorder {
    private(set) var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}

private extension HTTPResponse {
    static func json(_ json: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let url = URL(string: "https://api.bitbucket.org/2.0/test")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return HTTPResponse(data: Data(json.utf8), response: response)
    }

    static func status(_ status: Int, headers: [String: String] = [:]) -> HTTPResponse {
        json("{}", status: status, headers: headers)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        verify(error)
    }
}
