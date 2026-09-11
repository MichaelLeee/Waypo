import Foundation

/// A `ScriptHost` that keeps everything in memory, so a runtime test needs no
/// App Group, no network, and no notification centre.
final class FakeScriptHost: ScriptHost, @unchecked Sendable {
    enum HTTPOutcome: Sendable {
        case response(ScriptHTTPResponse)
        case failure(String)
        /// Never answers, so only the run's own budget can end it.
        case never
    }

    struct Notification: Sendable, Equatable {
        var title: String
        var subtitle: String?
        var body: String
    }

    private let lock = NSLock()
    private var storage: [UUID: [String: String]] = [:]
    private var queued: [HTTPOutcome] = []
    private var recordedRequests: [ScriptHTTPRequest] = []
    private var recordedNotifications: [Notification] = []
    private var recordedSwitches: [UUID] = []
    private var storedDefault: HTTPOutcome = .response(
        ScriptHTTPResponse(status: 200, headers: [:], body: ""))
    private var refuseWrites = false
    private var answerSwitches = true

    // MARK: - Setting up

    /// Answers every request this way unless a one-off was queued.
    var defaultOutcome: HTTPOutcome {
        get { locked { storedDefault } }
        set { locked { storedDefault = newValue } }
    }

    /// Queues a one-off answer, consumed in order before `defaultOutcome`.
    func enqueue(_ outcome: HTTPOutcome) {
        locked { queued.append(outcome) }
    }

    func seed(_ values: [String: String], for scriptID: UUID) {
        locked { storage[scriptID] = values }
    }

    var refusesWrites: Bool {
        get { locked { refuseWrites } }
        set { locked { refuseWrites = newValue } }
    }

    /// What `selectServer` reports back, for a case where the caller wants the
    /// switch refused for a reason other than an unknown id.
    var answersSwitches: Bool {
        get { locked { answerSwitches } }
        set { locked { answerSwitches = newValue } }
    }

    // MARK: - Inspecting

    var requests: [ScriptHTTPRequest] { locked { recordedRequests } }
    var notifications: [Notification] { locked { recordedNotifications } }
    var switches: [UUID] { locked { recordedSwitches } }
    func stored(_ scriptID: UUID) -> [String: String] { locked { storage[scriptID] ?? [:] } }

    // MARK: - ScriptHost

    func readPersistent(_ scriptID: UUID) -> [String: String] {
        locked { storage[scriptID] ?? [:] }
    }

    func writePersistent(_ values: [String: String], for scriptID: UUID) throws {
        try locked {
            guard !refuseWrites else { throw ScriptStoreError.persistentStoreFull }
            storage[scriptID] = values
        }
    }

    func perform(_ request: ScriptHTTPRequest) async throws -> ScriptHTTPResponse {
        let outcome = locked { () -> HTTPOutcome in
            recordedRequests.append(request)
            return queued.isEmpty ? storedDefault : queued.removeFirst()
        }
        switch outcome {
        case .response(let response):
            return response
        case .failure(let message):
            throw ScriptHTTPError(message: message)
        case .never:
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            throw ScriptHTTPError(message: "unreachable")
        }
    }

    func postNotification(title: String, subtitle: String?, body: String) {
        locked { recordedNotifications.append(Notification(title: title, subtitle: subtitle,
                                                           body: body)) }
    }

    func selectServer(_ id: UUID) async -> Bool {
        locked { () -> Bool in
            recordedSwitches.append(id)
            return answerSwitches
        }
    }

    // MARK: - Locking

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Records what would have been shown, so `AppScriptHost` can be exercised
/// without constructing the real notification centre.
final class FakeScriptNotifier: ScriptNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [FakeScriptHost.Notification] = []

    var posted: [FakeScriptHost.Notification] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func post(title: String, subtitle: String?, body: String) {
        lock.lock()
        recorded.append(FakeScriptHost.Notification(title: title, subtitle: subtitle, body: body))
        lock.unlock()
    }
}

/// A `ScriptRunning` stand-in, so the service can be tested without loading
/// JavaScriptCore and without waiting for real scripts.
final class FakeScriptRunner: ScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(script: Script, trigger: ScriptRunRecord.Trigger)] = []
    private var storedResult = ScriptResult(outcome: .success, duration: 0)

    /// The result every run reports.
    var result: ScriptResult {
        get { locked { storedResult } }
        set { locked { storedResult = newValue } }
    }

    var runs: [(script: Script, trigger: ScriptRunRecord.Trigger)] { locked { recorded } }

    func run(_ script: Script, trigger: ScriptRunRecord.Trigger,
             environment: ScriptEnvironment) async -> ScriptResult {
        locked { recorded.append((script, trigger)) }
        return result
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Polls until `condition` holds. The runtime deliberately finishes work off
/// its own queue, so a test that must observe that work waits for it rather
/// than guessing at a duration.
func waitUntil(_ condition: @Sendable () -> Bool, timeout: TimeInterval = 2) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}
