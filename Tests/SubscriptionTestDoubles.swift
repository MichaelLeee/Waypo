import Foundation

/// A fetch log that outlives the struct that writes to it, so a value-type
/// fetcher can record what it was asked for while a test reads it back.
final class SubscriptionFetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ url: String) {
        lock.lock()
        entries.append(url)
        lock.unlock()
    }

    var requested: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

/// Answers from a table instead of the network, so the refresh and import
/// paths can be exercised without a source to talk to.
struct FakeSubscriptionFetcher: SubscriptionFetching {
    enum Answer: Sendable {
        case result(SubscriptionFetchResult)
        case failure(SubscriptionFetchError)
    }

    private let answers: [String: Answer]
    private let fallback: Answer
    private let log: SubscriptionFetchLog

    init(answers: [String: Answer] = [:], fallback: Answer,
         log: SubscriptionFetchLog = SubscriptionFetchLog()) {
        self.answers = answers
        self.fallback = fallback
        self.log = log
    }

    var requested: [String] { log.requested }

    static func serving(_ text: String, userInfo: SubscriptionUserInfo? = nil,
                        suggestedName: String? = nil,
                        for url: String) -> FakeSubscriptionFetcher {
        FakeSubscriptionFetcher(
            answers: [url: .result(SubscriptionFetchResult(
                text: text, userInfo: userInfo, suggestedName: suggestedName))],
            fallback: .failure(.invalidURL))
    }

    /// Answers every source with the same document.
    static func alwaysServing(_ text: String, userInfo: SubscriptionUserInfo? = nil,
                              suggestedName: String? = nil) -> FakeSubscriptionFetcher {
        FakeSubscriptionFetcher(
            fallback: .result(SubscriptionFetchResult(
                text: text, userInfo: userInfo, suggestedName: suggestedName)))
    }

    static func failing(_ error: SubscriptionFetchError,
                        for url: String) -> FakeSubscriptionFetcher {
        FakeSubscriptionFetcher(answers: [url: .failure(error)],
                                fallback: .failure(.invalidURL))
    }

    func fetch(_ urlString: String, now: Date) async throws -> SubscriptionFetchResult {
        log.record(urlString)
        switch answers[urlString] ?? fallback {
        case .result(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}
