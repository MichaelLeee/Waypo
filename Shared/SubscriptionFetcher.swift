import Foundation

/// Why a fetch produced no document. The cases are distinct so the caller can
/// say which part went wrong instead of repeating a transport message.
enum SubscriptionFetchError: Error, Equatable, LocalizedError {
    case invalidURL
    case unsupportedScheme(String)
    case httpStatus(Int)
    case notText
    case tooLarge
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That is not a URL this app can fetch."
        case .unsupportedScheme(let scheme):
            return "Only http and https sources can be fetched; that one uses “\(scheme)”."
        case .httpStatus(let code):
            return "The source returned HTTP \(code)."
        case .notText:
            return "The response was not text this app can read."
        case .tooLarge:
            return "The document is larger than this app will download."
        case .transport(let message):
            return message
        }
    }
}

/// What one fetch produced: the document, whatever the source said about the
/// account, and the name it suggested for the document.
struct SubscriptionFetchResult: Sendable, Equatable {
    var text: String
    var userInfo: SubscriptionUserInfo?
    var suggestedName: String?
}

/// Reads a document that a profile keeps itself current from. Behind a
/// protocol so the refresh logic can be tested against a source that answers
/// from a table instead of the network.
protocol SubscriptionFetching: Sendable {
    func fetch(_ urlString: String, now: Date) async throws -> SubscriptionFetchResult
}

/// Fetches over an ephemeral session, so nothing about the source is shared
/// with the rest of the app.
///
/// A sibling of the scripting HTTP client rather than a reuse of it: this one
/// is GET-only, its cap is larger because a configuration with many servers is
/// bigger than an API response, and a body past the cap is an error rather
/// than a truncation, because importing half a server list silently would be
/// worse than importing none of it.
struct SubscriptionFetcher: SubscriptionFetching {
    /// Long enough for a slow source to answer, short enough that a refresh
    /// cannot hold the app up for long.
    static let timeout: TimeInterval = 30
    /// A document larger than this is not a list of servers.
    static let maximumBodyBytes = 10 * 1024 * 1024
    static let userAgent = "Waypo/1.0"

    private let session: URLSession

    init(session: URLSession = SubscriptionFetcher.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    func fetch(_ urlString: String, now: Date = Date()) async throws -> SubscriptionFetchResult {
        var request = URLRequest(url: try Self.validatedURL(urlString))
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw SubscriptionFetchError.notText }
            var data = Data()
            data.reserveCapacity(Int(min(max(http.expectedContentLength, 0),
                                          Int64(Self.maximumBodyBytes))))
            for try await byte in stream {
                guard data.count < Self.maximumBodyBytes else { throw SubscriptionFetchError.tooLarge }
                data.append(byte)
            }
            return try Self.result(data: data, response: http, now: now)
        } catch let error as SubscriptionFetchError {
            throw error
        } catch {
            throw SubscriptionFetchError.transport(error.localizedDescription)
        }
    }

    /// The scheme and shape rules, kept apart from the request so they can be
    /// tested without a source to talk to.
    static func validatedURL(_ urlString: String) throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw SubscriptionFetchError.invalidURL
        }
        guard scheme == "http" || scheme == "https" else {
            throw SubscriptionFetchError.unsupportedScheme(scheme)
        }
        guard let host = url.host, !host.isEmpty else { throw SubscriptionFetchError.invalidURL }
        return url
    }

    /// The response rules, kept apart from the transfer so the header and the
    /// body can be read out of a synthetic response in a test.
    static func result(data: Data, response: HTTPURLResponse, now: Date) throws
        -> SubscriptionFetchResult {
        guard (200..<300).contains(response.statusCode) else {
            throw SubscriptionFetchError.httpStatus(response.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SubscriptionFetchError.notText
        }
        return SubscriptionFetchResult(
            text: text,
            userInfo: SubscriptionUserInfo.parse(
                response.value(forHTTPHeaderField: "Subscription-Userinfo"), updatedAt: now),
            suggestedName: suggestedName(from: response))
    }

    /// The name the source proposes, when it offers the document as a named
    /// download.
    static func suggestedName(from response: HTTPURLResponse) -> String? {
        guard let disposition = response.value(forHTTPHeaderField: "Content-Disposition") else {
            return nil
        }
        var plain: String?
        var extended: String?
        for field in disposition.split(separator: ";") {
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "filename":
                plain = value
            case "filename*":
                // Encoded as charset'language'value.
                let parts = value.split(separator: "'", maxSplits: 2,
                                        omittingEmptySubsequences: false)
                extended = parts.count == 3 ? String(parts[2]) : nil
            default:
                continue
            }
        }
        return cleanName(extended ?? plain ?? "")
    }

    /// A name to fall back to when neither the document nor the source states
    /// one.
    static func hostLabel(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed)?.host, !host.isEmpty else { return nil }
        return host
    }

    private static func cleanName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [".yaml", ".yml", ".txt", ".conf", ".json"]
        where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
