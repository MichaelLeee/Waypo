import Foundation

/// Which trigger starts a script.
enum ScriptKind: String, Codable, CaseIterable, Sendable {
    case manual
    case cron
    case event
}

/// Lifecycle moments a script can subscribe to. Raw values are the stable
/// wire names; the UI supplies its own copy.
enum ScriptEvent: String, Codable, CaseIterable, Sendable {
    case tunnelConnected = "tunnel.connected"
    case tunnelDisconnected = "tunnel.disconnected"
    case appLaunched = "app.launched"
    case appForeground = "app.foreground"
}

/// Where a script came from. Imported scripts never auto-run.
enum ScriptOrigin: String, Codable, Sendable {
    case user
    case imported
}

/// How a run ended.
enum ScriptOutcome: String, Codable, Sendable {
    case success
    case timeout
    case error
    case skipped
}

/// One script definition. Stored under its own App Group key rather than
/// inside `TunnelConfiguration`, so script source is never serialized into
/// the payload the packet tunnel provider reads.
struct Script: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var kind: ScriptKind
    var source: String
    /// Plain global exposed to the script as `$argument`.
    var argument: String?
    /// Present for `kind == .cron`.
    var schedule: ScriptSchedule?
    /// Present for `kind == .event`.
    var event: ScriptEvent?
    var isEnabled: Bool
    var origin: ScriptOrigin
    var createdAt: Date
    var updatedAt: Date
    var lastRunAt: Date?
    /// Anchor the scheduler measures the next fire from. Manual runs
    /// deliberately do not move it.
    var lastScheduledFireAt: Date?
    var lastOutcome: ScriptOutcome?

    init(id: UUID = UUID(), name: String, kind: ScriptKind = .manual, source: String = "",
         argument: String? = nil, schedule: ScriptSchedule? = nil, event: ScriptEvent? = nil,
         isEnabled: Bool = true, origin: ScriptOrigin = .user, createdAt: Date = Date(),
         updatedAt: Date = Date(), lastRunAt: Date? = nil,
         lastScheduledFireAt: Date? = nil, lastOutcome: ScriptOutcome? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.source = source
        self.argument = argument
        self.schedule = schedule
        self.event = event
        self.isEnabled = isEnabled
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRunAt = lastRunAt
        self.lastScheduledFireAt = lastScheduledFireAt
        self.lastOutcome = lastOutcome
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, source, argument, schedule, event, isEnabled, origin
        case createdAt, updatedAt, lastRunAt, lastScheduledFireAt, lastOutcome
    }

    /// Every field past `name` is optional with a default, so a stored script
    /// written by an older build still decodes. A schedule that no longer
    /// parses (`try?` flattens the optional) leaves the script without one
    /// rather than failing the whole decode.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = container.decodeStringEnum(ScriptKind.self, forKey: .kind) ?? .manual
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        argument = try container.decodeIfPresent(String.self, forKey: .argument)
        schedule = (try? container.decodeIfPresent(ScriptSchedule.self, forKey: .schedule)) ?? nil
        event = container.decodeStringEnum(ScriptEvent.self, forKey: .event)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        origin = container.decodeStringEnum(ScriptOrigin.self, forKey: .origin) ?? .user
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastScheduledFireAt = try container.decodeIfPresent(Date.self, forKey: .lastScheduledFireAt)
        lastOutcome = container.decodeStringEnum(ScriptOutcome.self, forKey: .lastOutcome)
    }
}

/// One completed run, kept for the history list. `scriptName` is captured at
/// run time so history survives the script being renamed or deleted.
struct ScriptRunRecord: Codable, Hashable, Sendable, Identifiable {
    enum Trigger: String, Codable, Hashable, Sendable {
        case manual
        case schedule
        case event
    }

    var id: UUID
    var scriptID: UUID
    var scriptName: String
    var trigger: Trigger
    var startedAt: Date
    var duration: TimeInterval
    var outcome: ScriptOutcome
    /// Whatever `$done` produced, already truncated by the store.
    var output: String?
    /// Captured `console` output, oldest first.
    var log: [String]

    init(id: UUID = UUID(), scriptID: UUID, scriptName: String, trigger: Trigger,
         startedAt: Date, duration: TimeInterval, outcome: ScriptOutcome,
         output: String? = nil, log: [String] = []) {
        self.id = id
        self.scriptID = scriptID
        self.scriptName = scriptName
        self.trigger = trigger
        self.startedAt = startedAt
        self.duration = duration
        self.outcome = outcome
        self.output = output
        self.log = log
    }
}

/// A network request a script asked for. The scheme is validated before
/// anything is sent; only `http` and `https` are allowed through.
struct ScriptHTTPRequest: Sendable {
    enum Method: String, Sendable, CaseIterable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    var method: Method
    var url: String
    var headers: [String: String]
    var body: String?
}

/// What came back. A non-2xx status is still a response, not an error, so the
/// script can decide what to do with it.
struct ScriptHTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: String
}

/// Why a request produced no response at all. `message` is what the script
/// receives as its callback's error argument.
struct ScriptHTTPError: Error, Sendable {
    var message: String
}

/// The console channel a captured line came from.
enum ScriptLogLevel: String, Sendable, CaseIterable {
    case log
    case warn
    case error

    var prefix: String {
        switch self {
        case .log: ""
        case .warn: "[warn] "
        case .error: "[error] "
        }
    }
}

/// A read-only snapshot of the app handed to a run as `$waypo`. Built on the
/// main actor before the run starts, so a running script never reaches back
/// into the controller.
struct ScriptEnvironment: Codable, Sendable {
    struct Server: Codable, Sendable {
        var id: UUID
        var name: String
        var transport: String
    }

    var profile: String
    /// One of `connected`, `connecting`, `disconnecting`, `disconnected`,
    /// `reasserting`, `invalid`. A plain string so a script can compare it
    /// without knowing the platform type behind it.
    var status: String
    var isActive: Bool
    var activeServerID: UUID?
    var version: String
    var servers: [Server]

    static let empty = ScriptEnvironment(profile: "", status: "invalid",
                                         isActive: false, activeServerID: nil,
                                         version: "", servers: [])
}

/// What one run produced. The caps are applied here so nothing downstream has
/// to remember them.
struct ScriptResult: Sendable {
    var outcome: ScriptOutcome
    var output: String?
    /// Captured console lines, oldest first.
    var log: [String]
    var duration: TimeInterval

    init(outcome: ScriptOutcome, output: String? = nil, log: [String] = [],
         duration: TimeInterval) {
        self.outcome = outcome
        self.output = output.map {
            ScriptLimits.truncate($0, toUTF8Bytes: ScriptLimits.outputBytes)
        }
        self.log = ScriptLimits.truncateLog(log)
        self.duration = duration
    }
}

extension KeyedDecodingContainer {
    /// Decodes a string-backed enum, returning nil when the key is absent,
    /// the value is the wrong shape, or the case no longer exists. Keeps a
    /// removed case from failing the decode of everything around it.
    func decodeStringEnum<T: RawRepresentable>(_ type: T.Type, forKey key: Key) -> T?
    where T.RawValue == String {
        guard let raw = try? decode(String.self, forKey: key) else { return nil }
        return T(rawValue: raw)
    }
}
