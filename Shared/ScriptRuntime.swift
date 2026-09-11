import Foundation
import JavaScriptCore

/// Runs one script in a fresh JavaScript context on a queue of its own.
///
/// Every run is independent: the only state that survives is the script's
/// private dictionary. One run cannot block another, because nothing is shared
/// between them but the abandoned-run tally below.
///
/// Scripts run in the app process only. Nothing under `Tunnel/` refers to this
/// type, so the packet tunnel provider never loads JavaScript.
final class ScriptRuntime: ScriptRunning {
    /// A person asked for this run, so it gets longer to answer.
    static let manualBudget: TimeInterval = 30
    /// A scheduled or event run overlaps whatever else the app is doing, so it
    /// is held to a shorter leash.
    static let scheduledBudget: TimeInterval = 15
    /// After this many runs have had to be abandoned, scripting stops until
    /// the app is relaunched.
    static let abandonedRunLimit = 3

    static let pausedMessage =
        "Scripting is paused. \(abandonedRunLimit) runs had to be stopped, so restart the app to continue."

    static func timeoutMessage(_ budget: TimeInterval) -> String {
        "The script did not finish within \(Int(budget.rounded())) seconds."
    }

    private let host: any ScriptHost
    private let manualBudget: TimeInterval
    private let scheduledBudget: TimeInterval
    private let abandoned = AbandonedRuns()
    private let watchdog = DispatchQueue(label: "org.waypo.script.watchdog")

    init(host: any ScriptHost,
         manualBudget: TimeInterval = ScriptRuntime.manualBudget,
         scheduledBudget: TimeInterval = ScriptRuntime.scheduledBudget) {
        self.host = host
        self.manualBudget = manualBudget
        self.scheduledBudget = scheduledBudget
    }

    func run(_ script: Script, trigger: ScriptRunRecord.Trigger,
             environment: ScriptEnvironment) async -> ScriptResult {
        guard abandoned.canStart else {
            return ScriptResult(outcome: .skipped, output: Self.pausedMessage, duration: 0)
        }
        let budget = trigger == .manual ? manualBudget : scheduledBudget
        let run = ScriptRun(script: script, trigger: trigger, environment: environment,
                            budget: budget, host: host, abandoned: abandoned,
                            watchdog: watchdog)
        return await run.start()
    }
}

/// Process-lifetime tally of runs that had to be abandoned. A run stopped while
/// still executing keeps its queue and context for the life of the process, so
/// the count is a ceiling on what one launch can leak.
private final class AbandonedRuns: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var canStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count < ScriptRuntime.abandonedRunLimit
    }

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// Decides, exactly once, how a run ended. Every path that could end a run —
/// the script returning, its last callback returning, `$done`, the watchdog —
/// goes through here, so no two of them can both claim the result.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var evaluated = false
    private var pending = 0
    private var failure: String?
    private var capturedOutput: String?
    private var lines: [String] = []
    private var continuation: CheckedContinuation<ScriptOutcome, Never>?

    func attach(_ continuation: CheckedContinuation<ScriptOutcome, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// False once anything has decided the outcome. A callback arriving after
    /// `$done`, or after the watchdog fired, is dropped rather than touching
    /// JavaScript again.
    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished
    }

    var output: String? {
        lock.lock()
        defer { lock.unlock() }
        return capturedOutput
    }

    var log: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func appendLog(_ line: String) {
        lock.lock()
        if !finished { lines.append(line) }
        lock.unlock()
    }

    func recordFailure(_ message: String) {
        lock.lock()
        if failure == nil { failure = message }
        lock.unlock()
    }

    @discardableResult
    func finish(_ outcome: ScriptOutcome, output: String? = nil) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        if let output {
            capturedOutput = output
        } else if outcome == .error {
            // The exception the script died of is the only useful thing to
            // show, so it stands in for output the script never produced.
            capturedOutput = failure ?? "The script stopped with an error."
        }
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
        return true
    }

    /// The script's own top level has returned.
    func markEvaluated() {
        lock.lock()
        evaluated = true
        let settled = pending == 0 && !finished
        let failure = self.failure
        lock.unlock()
        if settled { finish(failure == nil ? .success : .error) }
    }

    func beginPending() {
        lock.lock()
        pending += 1
        lock.unlock()
    }

    /// A request stops counting only after its callback has returned to
    /// JavaScript, so a `$done` inside the callback is seen first.
    func endPending() {
        lock.lock()
        pending -= 1
        let settled = evaluated && pending == 0 && !finished
        let failure = self.failure
        lock.unlock()
        if settled { finish(failure == nil ? .success : .error) }
    }
}

/// One run: its own queue, its own JavaScript context, and the bridge between
/// them. Nothing here outlives the run except on the timeout path, where the
/// queue is deliberately left to drain or hang.
private final class ScriptRun: @unchecked Sendable {
    private let script: Script
    private let trigger: ScriptRunRecord.Trigger
    private let environment: ScriptEnvironment
    private let budget: TimeInterval
    private let host: any ScriptHost
    private let abandoned: AbandonedRuns
    private let watchdog: DispatchQueue
    private let queue: DispatchQueue
    private let state = RunState()
    private let environmentJSON: String
    private let startedAt = Date()

    /// Mutated only on `queue`, which is also where JavaScript runs, so the
    /// bridge sees one consistent view without a second lock.
    private var persistent: [String: String] = [:]
    private var context: JSContext?

    init(script: Script, trigger: ScriptRunRecord.Trigger, environment: ScriptEnvironment,
         budget: TimeInterval, host: any ScriptHost, abandoned: AbandonedRuns,
         watchdog: DispatchQueue) {
        self.script = script
        self.trigger = trigger
        self.environment = environment
        self.budget = budget
        self.host = host
        self.abandoned = abandoned
        self.watchdog = watchdog
        self.queue = DispatchQueue(label: "org.waypo.script.\(script.id.uuidString)")
        self.environmentJSON = Self.encode(environment)
    }

    func start() async -> ScriptResult {
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<ScriptOutcome, Never>) in
            state.attach(continuation)
            // A script spinning in a loop cannot be interrupted, so the
            // watchdog only decides the result and leaves the queue to be
            // abandoned.
            watchdog.asyncAfter(deadline: .now() + budget) { [self] in
                if state.finish(.timeout, output: ScriptRuntime.timeoutMessage(budget)) {
                    abandoned.record()
                }
            }
            queue.async { [self] in evaluate() }
        }
        // The context holds every bridge function, and each of them holds this
        // run back, so the context is dropped once the result is decided. A run
        // that had to be abandoned never reaches here and keeps its queue; those
        // are the runs `AbandonedRuns` counts.
        queue.async { [self] in context = nil }
        return ScriptResult(outcome: outcome, output: state.output, log: state.log,
                            duration: Date().timeIntervalSince(startedAt))
    }

    // MARK: - Evaluation

    private func evaluate() {
        guard state.isOpen else { return }
        guard let context = JSContext() else {
            state.finish(.error, output: "The script engine could not be started.")
            return
        }
        self.context = context
        persistent = host.readPersistent(script.id)
        context.exceptionHandler = { [state] _, exception in
            state.recordFailure(exception?.toString() ?? "The script stopped with an error.")
        }
        installBridge(in: context)
        context.setObject(script.argument ?? "", forKeyedSubscript: "$argument" as NSString)
        context.setObject(environmentJSON, forKeyedSubscript: "__waypo_environment" as NSString)
        context.evaluateScript(Self.bootstrap, withSourceURL: nil)
        context.evaluateScript(script.source, withSourceURL: nil)
        state.markEvaluated()
    }

    /// The whole Swift-to-JavaScript surface: a handful of small functions the
    /// bootstrap script assembles into the friendly API.
    ///
    /// Values crossing back into JavaScript are built with the `JSValue`
    /// initialisers rather than handed over as Swift scalars, so a boolean or
    /// a missing string arrives as the script expects it.
    private func installBridge(in context: JSContext) {
        let host = self.host

        let done: @convention(block) (JSValue?) -> Void = { [self] value in
            guard let value, !value.isUndefined, !value.isNull else {
                state.finish(.success)
                return
            }
            state.finish(.success, output: value.toString())
        }
        context.setObject(done, forKeyedSubscript: "__host_done" as NSString)

        let log: @convention(block) (JSValue?, JSValue?) -> Void = { [self] level, message in
            let name = level.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() }
            let parsed = name.flatMap { ScriptLogLevel(rawValue: $0) } ?? .log
            state.appendLog(parsed.prefix + (message?.toString() ?? ""))
        }
        context.setObject(log, forKeyedSubscript: "__host_log" as NSString)

        let storeRead: @convention(block) (JSValue?) -> JSValue? = { [self] key in
            let name = key.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() }
            guard let name, let value = persistent[name] else {
                return JSValue(nullIn: context)
            }
            return JSValue(object: value, in: context)
        }
        context.setObject(storeRead, forKeyedSubscript: "__host_storeRead" as NSString)

        let storeWrite: @convention(block) (JSValue?, JSValue?) -> JSValue? = { [self] key, value in
            let name = key.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() }
            guard let name, !name.isEmpty else {
                return JSValue(bool: false, in: context)
            }
            var updated = persistent
            if let value, !value.isUndefined, !value.isNull {
                updated[name] = value.toString()
            } else {
                updated.removeValue(forKey: name)
            }
            do {
                try host.writePersistent(updated, for: script.id)
            } catch {
                // A refused write leaves the stored copy untouched, so the run
                // keeps working from the dictionary it already had.
                return JSValue(bool: false, in: context)
            }
            persistent = updated
            return JSValue(bool: true, in: context)
        }
        context.setObject(storeWrite, forKeyedSubscript: "__host_storeWrite" as NSString)

        let selectServer: @convention(block) (JSValue?) -> JSValue? = { [self] raw in
            let text = raw.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() }
            guard let id = text.flatMap(UUID.init(uuidString:)),
                  environment.servers.contains(where: { $0.id == id })
            else {
                return JSValue(bool: false, in: context)
            }
            Task.detached { [host] in _ = await host.selectServer(id) }
            return JSValue(bool: true, in: context)
        }
        context.setObject(selectServer, forKeyedSubscript: "__host_selectServer" as NSString)

        let notify: @convention(block) (JSValue?, JSValue?, JSValue?) -> Void = { [self] title, subtitle, body in
            let text = title.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() } ?? ""
            guard !text.isEmpty else { return }
            let sub = subtitle.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() }
            // Recorded either way, so a banner that never appears because the
            // app was never granted permission still shows up in the run log.
            state.appendLog("[notify] \(text)")
            host.postNotification(title: text,
                                  subtitle: sub.flatMap { $0.isEmpty ? nil : $0 },
                                  body: body?.toString() ?? "")
        }
        context.setObject(notify, forKeyedSubscript: "__host_notify" as NSString)

        let http: @convention(block) (JSValue?, JSValue?, JSValue?, JSValue?, JSValue?) -> Void = { [self] identifier, method, url, headers, body in
            let identifier = identifier.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() }
            guard let identifier else { return }
            state.beginPending()
            let address = url.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() } ?? ""
            guard !address.isEmpty else {
                requestFinished(identifier: identifier, error: "The request had no URL.")
                return
            }
            let name = method.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() } ?? ""
            guard let parsed = ScriptHTTPRequest.Method(rawValue: name) else {
                requestFinished(identifier: identifier, error: "That request method is not supported.")
                return
            }
            let text = body.flatMap { $0.isUndefined || $0.isNull ? nil : $0.toString() }
            let request = ScriptHTTPRequest(method: parsed, url: address,
                                            headers: Self.headers(fromJSON: headers?.toString()),
                                            body: (text?.isEmpty ?? true) ? nil : text)
            Task.detached { [self] in
                do {
                    let response = try await host.perform(request)
                    queue.async { [self] in
                        requestFinished(identifier: identifier, response: response)
                    }
                } catch {
                    let message = (error as? ScriptHTTPError)?.message ?? error.localizedDescription
                    queue.async { [self] in
                        requestFinished(identifier: identifier, error: message)
                    }
                }
            }
        }
        context.setObject(http, forKeyedSubscript: "__host_http" as NSString)
    }

    // MARK: - Request completion

    /// Runs on `queue`. The callback goes first, so a `$done` inside it is the
    /// result the run reports.
    private func requestFinished(identifier: String, response: ScriptHTTPResponse) {
        guard state.isOpen else { return }
        deliver(identifier: identifier, error: nil, response: response)
        state.endPending()
    }

    private func requestFinished(identifier: String, error: String) {
        guard state.isOpen else { return }
        deliver(identifier: identifier, error: error, response: nil)
        state.endPending()
    }

    private func deliver(identifier: String, error: String?, response: ScriptHTTPResponse?) {
        guard let context,
              let deliver = context.objectForKeyedSubscript("__host_deliver"),
              !deliver.isUndefined
        else { return }
        var arguments: [Any] = [identifier]
        if let error {
            arguments.append(error)
        } else {
            arguments.append(NSNull())
        }
        if let response {
            arguments.append(response.status)
            arguments.append(Self.encode(response.headers))
            arguments.append(response.body)
        } else {
            arguments.append(NSNull())
            arguments.append(NSNull())
            arguments.append(NSNull())
        }
        _ = deliver.call(withArguments: arguments)
    }

    // MARK: - Encoding

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "null" }
        return text
    }

    private static func headers(fromJSON text: String?) -> [String: String] {
        guard let text, let data = text.data(using: .utf8),
              let headers = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return headers
    }

    /// Builds the script-facing API on top of the bridge functions, so the
    /// Swift side stays small enough to read in one sitting.
    ///
    /// Every call into Swift passes a value of one kind only — a string, or
    /// `null` where absence is meaningful — which keeps the bridge's argument
    /// types unambiguous.
    private static let bootstrap = #"""
    (function () {
      var waiting = {};
      var nextIdentifier = 0;
      var global = (function () { return this; })();

      // The host may already define a name as a read-only property, so the
      // value is installed as an ordinary writable property where that is
      // allowed and assigned directly otherwise.
      function define(name, value) {
        try {
          Object.defineProperty(global, name, { value: value, writable: true,
                                                enumerable: true, configurable: true });
        } catch (error) {
          global[name] = value;
        }
      }

      function toText(value) {
        if (value === undefined || value === null) { return null; }
        if (typeof value === 'string') { return value; }
        try { return JSON.stringify(value); } catch (error) { return String(value); }
      }

      function toJSON(text, fallback) {
        if (text === undefined || text === null) { return fallback; }
        try { return JSON.parse(text); } catch (error) { return fallback; }
      }

      function describe(args) {
        var parts = [];
        for (var index = 0; index < args.length; index++) {
          var value = args[index];
          parts.push(typeof value === 'string' ? value : toText(value));
        }
        return parts.join(' ');
      }

      define('$done', function (value) { __host_done(toText(value)); });

      define('console', {
        log: function () { __host_log('log', describe(arguments)); },
        warn: function () { __host_log('warn', describe(arguments)); },
        error: function () { __host_log('error', describe(arguments)); }
      });

      define('$persistentStore', {
        read: function (key) { return __host_storeRead(String(key)); },
        write: function (value, key) { return __host_storeWrite(String(key), toText(value)); }
      });

      function request(method, options, callback) {
        var settings = (typeof options === 'string') ? { url: options } : (options || {});
        var identifier = String(nextIdentifier++);
        waiting[identifier] = (typeof callback === 'function') ? callback : function () {};
        __host_http(identifier, method, String(settings.url || ''),
                    toText(settings.headers || {}), toText(settings.body));
      }

      define('$httpClient', {
        get: function (options, callback) { request('GET', options, callback); },
        post: function (options, callback) { request('POST', options, callback); },
        put: function (options, callback) { request('PUT', options, callback); },
        delete: function (options, callback) { request('DELETE', options, callback); }
      });

      define('__host_deliver', function (identifier, error, status, headers, body) {
        var callback = waiting[identifier];
        delete waiting[identifier];
        if (!callback) { return; }
        var answered = !(status === undefined || status === null);
        callback(error === undefined ? null : error,
                 answered ? { status: status, headers: toJSON(headers, {}) } : null,
                 body === undefined ? null : body);
      });

      define('$notify', function (title, subtitle, body) {
        __host_notify(String(title),
                      (subtitle === undefined || subtitle === null) ? '' : String(subtitle),
                      (body === undefined || body === null) ? '' : String(body));
      });

      define('$notification', { post: $notify });

      var environment = toJSON(__waypo_environment, {});

      define('$waypo', {
        profile: environment.profile || null,
        status: environment.status || 'invalid',
        isActive: environment.isActive === true,
        activeServerID: environment.activeServerID || null,
        version: environment.version || null,
        servers: (environment.servers || []).map(function (server) {
          return { id: server.id, name: server.name, transport: server.transport,
                   active: server.id === environment.activeServerID };
        }),
        selectServer: function (id) { return __host_selectServer(String(id)); }
      });
    })();
    """#
}
