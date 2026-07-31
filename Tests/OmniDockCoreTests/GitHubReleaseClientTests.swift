import XCTest
@testable import OmniDockCore

final class GitHubReleaseClientTests: XCTestCase {
    override func tearDown() {
        UpdateURLProtocol.handler = nil
        super.tearDown()
    }

    func testClientCachesReleaseAndUsesConditionalRequest() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let cache = GitHubReleaseCache(defaults: defaults)
        let session = makeSession()
        let responseDate = Date(timeIntervalSince1970: 100)
        var requestCount = 0

        UpdateURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["ETag": "\"release-1\""]
                    )!,
                    Self.releaseData(tag: "1.2.2")
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"release-1\"")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 304,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        let client = GitHubReleaseClient(
            session: session,
            cache: cache,
            now: { responseDate }
        )
        let initial = try await client.fetchLatestRelease()
        let cached = try await client.fetchLatestRelease()

        XCTAssertEqual(initial.release.version?.displayValue, "1.2.2")
        XCTAssertFalse(initial.wasNotModified)
        XCTAssertTrue(cached.wasNotModified)
        XCTAssertEqual(cached.checkedAt, responseDate)
    }

    func testClientReportsRateLimit() async throws {
        UpdateURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: ["X-RateLimit-Remaining": "0"]
                )!,
                Data()
            )
        }

        do {
            _ = try await GitHubReleaseClient(
                session: makeSession(),
                cache: GitHubReleaseCache(
                    defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
                )
            ).fetchLatestRelease()
            XCTFail("Expected rate limit error")
        } catch {
            XCTAssertEqual(error as? GitHubReleaseClientError, .rateLimited)
        }
    }

    func testClientRejectsPrereleaseResponse() async throws {
        UpdateURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Self.releaseData(tag: "1.3.0-beta.1", prerelease: true)
            )
        }

        do {
            _ = try await GitHubReleaseClient(
                session: makeSession(),
                cache: GitHubReleaseCache(
                    defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
                )
            ).fetchLatestRelease()
            XCTFail("Expected no release error")
        } catch {
            XCTAssertEqual(error as? GitHubReleaseClientError, .noPublishedRelease)
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func releaseData(
        tag: String,
        prerelease: Bool = false
    ) -> Data {
        let object: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/quanzhankeji/OmniDock/releases/tag/\(tag)",
            "draft": false,
            "prerelease": prerelease,
            "assets": []
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }
}

private final class UpdateURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let (response, data) = try XCTUnwrap(Self.handler)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
