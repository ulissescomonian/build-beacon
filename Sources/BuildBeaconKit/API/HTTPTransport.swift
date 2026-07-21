import Foundation

public struct HTTPResponse: Sendable {
    public let data: Data
    public let response: HTTPURLResponse

    public init(data: Data, response: HTTPURLResponse) {
        self.data = data
        self.response = response
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct HTTPTransportConfiguration: Sendable {
    public var requestTimeout: TimeInterval
    public var resourceTimeout: TimeInterval
    public var maximumResponseBytes: Int

    public init(
        requestTimeout: TimeInterval = 15,
        resourceTimeout: TimeInterval = 30,
        maximumResponseBytes: Int = 5 * 1_024 * 1_024
    ) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.maximumResponseBytes = maximumResponseBytes
    }
}

public final class URLSessionHTTPTransport: NSObject, HTTPTransport, @unchecked Sendable {
    private var session: URLSession!
    private let maximumResponseBytes: Int
    private let stateLock = NSLock()
    private var pendingRequests: [Int: PendingRequest] = [:]

    public convenience init(configuration: HTTPTransportConfiguration = .init()) {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
        sessionConfiguration.timeoutIntervalForResource = configuration.resourceTimeout
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.httpMaximumConnectionsPerHost = 6
        sessionConfiguration.httpAdditionalHeaders = nil
        self.init(
            sessionConfiguration: sessionConfiguration,
            maximumResponseBytes: configuration.maximumResponseBytes
        )
    }

    public init(sessionConfiguration: URLSessionConfiguration, maximumResponseBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
        super.init()
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: self,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pending = PendingRequest(continuation: continuation)
                stateLock.lock()
                pendingRequests[task.taskIdentifier] = pending
                stateLock.unlock()

                if Task.isCancelled {
                    task.cancel()
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private static func contentLength(from response: HTTPURLResponse) -> Int? {
        guard let raw = response.value(forHTTPHeaderField: "Content-Length"),
              let value = Int(raw), value >= 0 else { return nil }
        return value
    }

    static func isAllowedRedirect(from originalURL: URL, to redirectedURL: URL) -> Bool {
        guard let original = URLComponents(url: originalURL, resolvingAgainstBaseURL: false),
              let redirected = URLComponents(url: redirectedURL, resolvingAgainstBaseURL: false),
              original.user == nil, original.password == nil,
              redirected.user == nil, redirected.password == nil,
              original.scheme?.lowercased() == "https",
              redirected.scheme?.lowercased() == "https",
              original.host?.lowercased() == "api.bitbucket.org",
              redirected.host?.lowercased() == "api.bitbucket.org",
              effectivePort(original) == 443,
              effectivePort(redirected) == 443,
              redirected.path == "/2.0" || redirected.path.hasPrefix("/2.0/") else {
            return false
        }
        return true
    }

    private static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        return components.scheme?.lowercased() == "https" ? 443 : nil
    }

    private static func map(_ error: URLError) -> BitbucketAPIError {
        switch error.code {
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff,
             .dataNotAllowed, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            .offline
        case .httpTooManyRedirects, .redirectToNonExistentLocation:
            .unsafeRedirect
        default: .transport
        }
    }
}

extension URLSessionHTTPTransport: URLSessionDataDelegate {
    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            fail(dataTask, with: .malformedResponse)
            completionHandler(.cancel)
            return
        }
        if let contentLength = Self.contentLength(from: httpResponse),
           contentLength > maximumResponseBytes {
            fail(dataTask, with: .responseTooLarge(limit: maximumResponseBytes))
            completionHandler(.cancel)
            return
        }

        stateLock.lock()
        pendingRequests[dataTask.taskIdentifier]?.response = httpResponse
        stateLock.unlock()
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var oversizedRequest: PendingRequest?
        stateLock.lock()
        if let pending = pendingRequests[dataTask.taskIdentifier] {
            if data.count > maximumResponseBytes - pending.data.count {
                oversizedRequest = pendingRequests.removeValue(forKey: dataTask.taskIdentifier)
            } else {
                pending.data.append(data)
            }
        }
        stateLock.unlock()

        if let oversizedRequest {
            dataTask.cancel()
            oversizedRequest.continuation.resume(
                throwing: BitbucketAPIError.responseTooLarge(limit: maximumResponseBytes)
            )
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        stateLock.lock()
        let pending = pendingRequests.removeValue(forKey: task.taskIdentifier)
        stateLock.unlock()
        guard let pending else { return }

        if let apiError = error as? BitbucketAPIError {
            pending.continuation.resume(throwing: apiError)
        } else if let urlError = error as? URLError {
            pending.continuation.resume(throwing: Self.map(urlError))
        } else if error != nil {
            pending.continuation.resume(throwing: BitbucketAPIError.transport)
        } else if let response = pending.response {
            pending.continuation.resume(returning: HTTPResponse(data: pending.data, response: response))
        } else {
            pending.continuation.resume(throwing: BitbucketAPIError.malformedResponse)
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url,
              let redirectedURL = request.url,
              Self.isAllowedRedirect(from: originalURL, to: redirectedURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private func fail(_ task: URLSessionTask, with error: BitbucketAPIError) {
        stateLock.lock()
        let pending = pendingRequests.removeValue(forKey: task.taskIdentifier)
        stateLock.unlock()
        task.cancel()
        pending?.continuation.resume(throwing: error)
    }
}

private final class PendingRequest: @unchecked Sendable {
    let continuation: CheckedContinuation<HTTPResponse, Error>
    var data = Data()
    var response: HTTPURLResponse?

    init(continuation: CheckedContinuation<HTTPResponse, Error>) {
        self.continuation = continuation
    }
}
