import Foundation
import UserNotifications

/// Everything a running script can reach outside its own JavaScript context.
/// The runtime is written against this, so its tests need no App Group, no
/// network, and no notification centre.
protocol ScriptHost: Sendable {
    /// The script's private dictionary.
    func readPersistent(_ scriptID: UUID) -> [String: String]
    /// Replaces the dictionary wholesale. Throws `ScriptStoreError` when a cap
    /// would be exceeded, which the runtime reports to the script as `false`.
    func writePersistent(_ values: [String: String], for scriptID: UUID) throws
    func perform(_ request: ScriptHTTPRequest) async throws -> ScriptHTTPResponse
    /// Delivers a banner. Best effort and deliberately not awaited: a
    /// notification must never hold a run open.
    func postNotification(title: String, subtitle: String?, body: String)
    /// Queues a switch of the active server. False for an id the environment
    /// snapshot does not contain.
    func selectServer(_ id: UUID) async -> Bool
}

/// The runtime as its callers see it. Declared on its own so the service can be
/// tested against a stand-in and no test outside the runtime's own has to load
/// JavaScriptCore.
protocol ScriptRunning: Sendable {
    func run(_ script: Script, trigger: ScriptRunRecord.Trigger,
             environment: ScriptEnvironment) async -> ScriptResult
}

/// Posts a user-visible banner. Behind a protocol so tests never construct the
/// real notification centre, where delivery is unavailable in an unsigned
/// build.
protocol ScriptNotifying: Sendable {
    func post(title: String, subtitle: String?, body: String)
}

struct SystemScriptNotifier: ScriptNotifying {
    func post(title: String, subtitle: String?, body: String) {
        // The centre is safe to use from any thread but is not marked Sendable,
        // which only the handler's annotation would complain about.
        nonisolated(unsafe) let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            // Nothing is requested here: the app asks for permission through
            // its own UI, and until then a notification is simply not shown.
            // The runtime already recorded the call in the run log.
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
        }
    }
}

/// Performs script-requested HTTP over an ephemeral session, so no cookie,
/// credential, or response cache is shared with the rest of the app.
struct ScriptHTTPClient: Sendable {
    /// Kept below the shortest run budget, so a slow endpoint is reported as a
    /// request failure rather than costing the whole run.
    static let timeout: TimeInterval = 10
    /// Bodies are read only up to here and then the transfer is dropped.
    static let maximumBodyBytes = 5 * 1024 * 1024

    private let session: URLSession

    init(session: URLSession = ScriptHTTPClient.makeSession()) {
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

    func perform(_ request: ScriptHTTPRequest) async throws -> ScriptHTTPResponse {
        guard let url = URL(string: request.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw ScriptHTTPError(message: "Only http and https URLs can be requested.")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = Self.timeout
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        if let body = request.body, !body.isEmpty {
            urlRequest.httpBody = Data(body.utf8)
        }

        do {
            let (stream, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw ScriptHTTPError(message: "The response was not HTTP.")
            }
            var data = Data()
            data.reserveCapacity(min(http.expectedContentLength > 0
                                     ? Int(http.expectedContentLength) : 0,
                                     Self.maximumBodyBytes))
            for try await byte in stream {
                guard data.count < Self.maximumBodyBytes else { break }
                data.append(byte)
            }
            return ScriptHTTPResponse(status: http.statusCode,
                                      headers: Self.headers(from: http),
                                      body: String(decoding: data, as: UTF8.self))
        } catch let error as ScriptHTTPError {
            throw error
        } catch {
            throw ScriptHTTPError(message: error.localizedDescription)
        }
    }

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key] = String(describing: value)
        }
        return headers
    }
}

/// The production host: the App Group store, the ephemeral HTTP client, the
/// system notifier, and a caller-supplied way to switch servers.
struct AppScriptHost: ScriptHost {
    private let store: ScriptStore
    private let notifier: any ScriptNotifying
    private let http: ScriptHTTPClient
    private let switchServer: @MainActor @Sendable (UUID) async -> Bool

    init(store: ScriptStore = ScriptStore(),
         notifier: any ScriptNotifying = SystemScriptNotifier(),
         http: ScriptHTTPClient = ScriptHTTPClient(),
         switchServer: @escaping @MainActor @Sendable (UUID) async -> Bool) {
        self.store = store
        self.notifier = notifier
        self.http = http
        self.switchServer = switchServer
    }

    func readPersistent(_ scriptID: UUID) -> [String: String] {
        store.persistentStore(for: scriptID)
    }

    func writePersistent(_ values: [String: String], for scriptID: UUID) throws {
        try store.savePersistentStore(values, for: scriptID)
    }

    func perform(_ request: ScriptHTTPRequest) async throws -> ScriptHTTPResponse {
        try await http.perform(request)
    }

    func postNotification(title: String, subtitle: String?, body: String) {
        let notifier = notifier
        Task.detached { notifier.post(title: title, subtitle: subtitle, body: body) }
    }

    func selectServer(_ id: UUID) async -> Bool {
        await switchServer(id)
    }
}
