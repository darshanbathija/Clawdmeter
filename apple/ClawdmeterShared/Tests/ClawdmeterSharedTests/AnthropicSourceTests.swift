import XCTest
@testable import ClawdmeterShared

/// Tests `AnthropicSource` against a `URLProtocol`-based mock so we can simulate
/// the Phase 0 Data Source Contract responses without hitting the network.
final class AnthropicSourceTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeSource() -> AnthropicSource {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let tokenProvider = StubTokenProvider(token: "sk-ant-oat01-fake")
        return AnthropicSource(tokenProvider: tokenProvider, urlSession: session)
    }

    func test_poll_happyPath_parsesContractHeaders() async throws {
        MockURLProtocol.responder = { _ in
            (
                statusCode: 200,
                headers: [
                    "date": "Thu, 14 May 2026 07:40:31 GMT",
                    "anthropic-ratelimit-unified-5h-utilization": "0.05",
                    "anthropic-ratelimit-unified-5h-reset": "1778756400",
                    "anthropic-ratelimit-unified-5h-status": "allowed",
                    "anthropic-ratelimit-unified-7d-utilization": "0.26",
                    "anthropic-ratelimit-unified-7d-reset": "1779238800",
                    "anthropic-ratelimit-unified-7d-status": "allowed",
                    "anthropic-ratelimit-unified-representative-claim": "five_hour",
                    "anthropic-organization-id": "test-org",
                ],
                body: Data()
            )
        }

        let source = makeSource()
        let usage = try await source.poll()
        XCTAssertEqual(usage.sessionPct, 5)
        XCTAssertEqual(usage.weeklyPct, 26)
        XCTAssertEqual(usage.sessionEpoch, 1_778_756_400)
        XCTAssertEqual(usage.weeklyEpoch, 1_779_238_800)
        XCTAssertEqual(usage.status, .allowed)
        XCTAssertEqual(usage.representativeClaim, .fiveHour)
        XCTAssertEqual(usage.organizationID, "test-org")
    }

    func test_poll_compositeStatus_limitedIfEitherWindowLimited() async throws {
        MockURLProtocol.responder = { _ in
            (
                statusCode: 200,
                headers: [
                    "date": "Thu, 14 May 2026 07:40:31 GMT",
                    "anthropic-ratelimit-unified-5h-utilization": "0.95",
                    "anthropic-ratelimit-unified-5h-reset": "1778756400",
                    "anthropic-ratelimit-unified-5h-status": "limited",
                    "anthropic-ratelimit-unified-7d-utilization": "0.50",
                    "anthropic-ratelimit-unified-7d-reset": "1779238800",
                    "anthropic-ratelimit-unified-7d-status": "allowed",
                ],
                body: Data()
            )
        }

        let usage = try await makeSource().poll()
        XCTAssertEqual(usage.status, .limited)
    }

    func test_poll_401_throwsUnauthenticated() async {
        MockURLProtocol.responder = { _ in (401, [:], Data()) }
        do {
            _ = try await makeSource().poll()
            XCTFail("Expected throw")
        } catch AISourceError.unauthenticated {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_poll_429_throwsRateLimitedWithRetryAfter() async {
        MockURLProtocol.responder = { _ in (429, ["Retry-After": "60"], Data()) }
        do {
            _ = try await makeSource().poll()
            XCTFail("Expected throw")
        } catch AISourceError.rateLimited(let retry) {
            XCTAssertEqual(retry, 60)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_poll_missingContractHeaders_throwsContractViolation() async {
        // 200 but no rate-limit headers — Phase 0 contract violated.
        MockURLProtocol.responder = { _ in
            (200, ["date": "Thu, 14 May 2026 07:40:31 GMT"], Data())
        }
        do {
            _ = try await makeSource().poll()
            XCTFail("Expected throw")
        } catch AISourceError.dataSourceContractViolation {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_poll_500_throwsNetworkFailure() async {
        MockURLProtocol.responder = { _ in (500, [:], Data()) }
        do {
            _ = try await makeSource().poll()
            XCTFail("Expected throw")
        } catch AISourceError.networkFailure {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_refreshCredentials_boundedRetry_throwsAuthExpiredAfterTwoAttempts() async throws {
        // E7: bounded refresh per 10-min window
        let provider = AlwaysFailRefreshProvider()
        let source = AnthropicSource(tokenProvider: provider)

        // 2 attempts allowed
        _ = try? await source.refreshCredentialsIfNeeded()
        _ = try? await source.refreshCredentialsIfNeeded()

        // 3rd: throw .authExpired
        do {
            _ = try await source.refreshCredentialsIfNeeded()
            XCTFail("Expected authExpired throw")
        } catch AISourceError.authExpired {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Helpers

    private final class StubTokenProvider: TokenProvider {
        let token: String?
        init(token: String?) { self.token = token }
        var currentAccessToken: String? { token }
        var hasToken: Bool { token != nil }
        func refreshIfNeeded() async throws -> Bool { false }
    }

    private final class AlwaysFailRefreshProvider: TokenProvider {
        var currentAccessToken: String? { "stub" }
        var hasToken: Bool { true }
        func refreshIfNeeded() async throws -> Bool { false }
    }
}

/// Test-only URLProtocol that lets each test set a per-request responder.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (statusCode: Int, headers: [String: String], body: Data))? = nil

    static func reset() {
        responder = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let responder = MockURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (status, headers, body) = responder(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/2",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
