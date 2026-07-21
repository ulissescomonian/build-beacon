import Foundation

public enum BitbucketAPIError: Error, Equatable, Sendable, ObservationFailureProviding {
    case missingCredential
    case invalidURL
    case invalidCredentials
    case insufficientPermissions
    case notFound
    case rateLimited(retryAt: Date?)
    case server(status: Int)
    case timedOut
    case offline
    case cancelled
    case malformedResponse
    case responseTooLarge(limit: Int)
    case unsafeRedirect
    case pagination(PaginationFailure)
    case transport

    public var observationFailure: ObservationFailure {
        switch self {
        case .invalidCredentials, .missingCredential: .invalidCredentials
        case .insufficientPermissions: .insufficientPermissions
        case let .rateLimited(retryAt): .rateLimited(retryAt: retryAt)
        case .offline: .offline
        case .timedOut: .timedOut
        case .notFound: .notFound
        case .malformedResponse, .responseTooLarge, .pagination, .invalidURL, .unsafeRedirect:
            .malformedResponse
        case let .server(status): .server(status: status)
        case .cancelled: .cancelled
        case .transport: .unexpected
        }
    }
}

public enum PaginationFailure: Error, Equatable, Sendable {
    case pageLimitExceeded(limit: Int, partialItemCount: Int)
    case itemLimitExceeded(limit: Int, partialItemCount: Int)
    case cycleDetected(partialItemCount: Int)
    case invalidNextURL(partialItemCount: Int)
    case emptyPageWithNext(partialItemCount: Int)
}
