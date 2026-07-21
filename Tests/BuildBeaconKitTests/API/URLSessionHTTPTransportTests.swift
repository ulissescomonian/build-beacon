import Foundation
import XCTest
@testable import BuildBeaconKit

final class URLSessionHTTPTransportTests: XCTestCase, @unchecked Sendable {
    override func tearDown() {
        URLProtocolStub.handler = nil
        URLProtocolStub.onStop = nil
        super.tearDown()
    }

    func testURLProtocolStubProvidesResponseWithoutRealNetwork() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"ok\":true}".utf8))
        }
        let transport = makeTransport(limit: 1_024)
        let response = try await transport.send(URLRequest(url: URL(string: "https://api.bitbucket.org/2.0/user")!))
        XCTAssertEqual(response.response.statusCode, 200)
        XCTAssertEqual(String(decoding: response.data, as: UTF8.self), "{\"ok\":true}")
    }

    func testContentLengthOverLimitIsRejected() async throws {
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "999"]
            )!
            return (response, Data("small".utf8))
        }
        let transport = makeTransport(limit: 10)
        await XCTAssertThrowsTransportError(try await transport.send(URLRequest(url: URL(string: "https://api.bitbucket.org/2.0/user")!))) {
            XCTAssertEqual($0, .responseTooLarge(limit: 10))
        }
    }

    func testActualBodyOverLimitIsRejectedWithoutContentLength() async throws {
        let cancellation = expectation(description: "oversized task cancelled")
        URLProtocolStub.onStop = { cancellation.fulfill() }
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(repeating: 65, count: 11))
        }
        let transport = makeTransport(limit: 10)
        await XCTAssertThrowsTransportError(try await transport.send(URLRequest(url: URL(string: "https://api.bitbucket.org/2.0/user")!))) {
            XCTAssertEqual($0, .responseTooLarge(limit: 10))
        }
        await fulfillment(of: [cancellation], timeout: 1)
    }

    func testRedirectValidationRequiresFullHTTPSOriginAndAPIRoot() {
        let source = URL(string: "https://api.bitbucket.org/2.0/user")!
        XCTAssertTrue(
            URLSessionHTTPTransport.isAllowedRedirect(
                from: source,
                to: URL(string: "https://api.bitbucket.org:443/2.0/user?page=2")!
            )
        )
        XCTAssertFalse(
            URLSessionHTTPTransport.isAllowedRedirect(
                from: source,
                to: URL(string: "https://api.bitbucket.org:8443/2.0/user")!
            )
        )
        XCTAssertFalse(
            URLSessionHTTPTransport.isAllowedRedirect(
                from: source,
                to: URL(string: "https://api.bitbucket.org/not-api")!
            )
        )
        XCTAssertFalse(
            URLSessionHTTPTransport.isAllowedRedirect(
                from: source,
                to: URL(string: "http://api.bitbucket.org/2.0/user")!
            )
        )
    }

    private func makeTransport(limit: Int) -> URLSessionHTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSessionHTTPTransport(sessionConfiguration: configuration, maximumResponseBytes: limit)
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var onStop: (@Sendable () -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { Self.onStop?() }
}

private func XCTAssertThrowsTransportError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (BitbucketAPIError) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch let error as BitbucketAPIError {
        verify(error)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
