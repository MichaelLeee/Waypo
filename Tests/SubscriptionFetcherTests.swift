import Foundation
import Testing

/// Everything here runs against a synthetic response, so the suite needs no
/// live source. The transfer itself is the only part left to the network.
@Suite
struct SubscriptionFetcherTests {
    @Test
    func onlyHTTPSourcesCanBeRead() {
        #expect(throws: SubscriptionFetchError.unsupportedScheme("ftp")) {
            _ = try SubscriptionFetcher.validatedURL("ftp://example.com/list")
        }
        #expect(throws: SubscriptionFetchError.invalidURL) {
            _ = try SubscriptionFetcher.validatedURL("/relative/path")
        }
        #expect(throws: SubscriptionFetchError.invalidURL) {
            _ = try SubscriptionFetcher.validatedURL("https:///nohost")
        }
    }

    @Test
    func whitespaceAroundASourceURLIsIgnored() throws {
        let url = try SubscriptionFetcher.validatedURL("  https://example.com/list  ")
        #expect(url.absoluteString == "https://example.com/list")
    }

    @Test
    func theAccountReadingComesFromTheResponseHeader() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let http = try response("https://example.com/list", 200, [
            "Subscription-Userinfo": "upload=1024; download=2048; total=4096; expire=1800000000",
        ])
        let result = try SubscriptionFetcher.result(data: Data("proxies: []".utf8),
                                                    response: http, now: now)
        #expect(result.text == "proxies: []")
        #expect(result.userInfo?.uploadBytes == 1024)
        #expect(result.userInfo?.downloadBytes == 2048)
        #expect(result.userInfo?.totalBytes == 4096)
        #expect(result.userInfo?.updatedAt == now)
    }

    @Test
    func aResponseWithoutTheHeaderLeavesTheReadingEmpty() throws {
        let http = try response("https://example.com/list", 200)
        let result = try SubscriptionFetcher.result(data: Data("rules: []".utf8),
                                                    response: http, now: Date())
        #expect(result.userInfo == nil)
        #expect(result.suggestedName == nil)
    }

    @Test
    func anErrorStatusIsReportedAsSuch() throws {
        let http = try response("https://example.com/list", 503)
        #expect(throws: SubscriptionFetchError.httpStatus(503)) {
            _ = try SubscriptionFetcher.result(data: Data(), response: http, now: Date())
        }
    }

    @Test
    func aBodyThatIsNotTextIsRejected() throws {
        let http = try response("https://example.com/list", 200)
        #expect(throws: SubscriptionFetchError.notText) {
            _ = try SubscriptionFetcher.result(data: Data([0xFF, 0xFE, 0xFD]),
                                               response: http, now: Date())
        }
    }

    @Test
    func aProposedNameLosesTheDocumentSuffix() throws {
        let http = try response("https://example.com/list", 200, [
            "Content-Disposition": "attachment; filename=\"provider.yaml\"",
        ])
        #expect(SubscriptionFetcher.suggestedName(from: http) == "provider")
    }

    @Test
    func anEncodedProposedNameIsRead() throws {
        let http = try response("https://example.com/list", 200, [
            "Content-Disposition": "attachment; filename*=UTF-8''encoded.txt",
        ])
        #expect(SubscriptionFetcher.suggestedName(from: http) == "encoded")
    }

    @Test
    func aHeaderWithoutANameProposesNothing() throws {
        let http = try response("https://example.com/list", 200, [
            "Content-Disposition": "attachment",
        ])
        #expect(SubscriptionFetcher.suggestedName(from: http) == nil)
    }

    @Test
    func theHostIsTheNameOfLastResort() {
        #expect(SubscriptionFetcher.hostLabel("https://provider.example.com/sub?token=1")
            == "provider.example.com")
        #expect(SubscriptionFetcher.hostLabel("/relative/path") == nil)
        #expect(SubscriptionFetcher.hostLabel("") == nil)
    }

    private func response(_ url: String, _ status: Int,
                          _ headers: [String: String] = [:]) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(url: URL(string: url)!, statusCode: status,
                                     httpVersion: "HTTP/1.1", headerFields: headers))
    }
}
