import Foundation

/// The narrow boundary between the app and the tunnel engine.
/// Engine implementations plug in behind this protocol and its C-ABI
/// counterpart — nothing above this layer may know which engine is running.
struct CoreStats: Sendable, Codable {
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var activeConnections: Int = 0
}

enum CoreEvent: Sendable {
    case started
    case stopped(reason: String)
    case error(message: String)
}

/// Live view of one engine group as reported by the engine's group stream.
/// Member tags are server ids; latency is absent until the engine has
/// measured it.
struct PolicyGroupState: Sendable, Codable, Equatable {
    struct Member: Sendable, Codable, Equatable {
        var tag: String
        var latencyMs: Int?
    }

    var tag: String
    var kind: String
    var selected: String?
    var members: [Member]
}

/// Live view of one connection tracked by the engine.
struct EngineConnection: Sendable, Codable, Equatable, Identifiable {
    var id: String
    var network: String
    var destination: String
    var domain: String?
    var outbound: String
    var rule: String?
    var upload: UInt64
    var download: UInt64
    /// Creation timestamp as reported by the engine.
    var createdAt: Int64 = 0
}

/// Folds the engine's connection-event stream (full snapshots plus
/// new/update/close deltas keyed by connection id) into the live list the
/// inspector shows. Pure logic so the folding rules are unit-testable.
struct ConnectionTracker: Sendable, Equatable {
    private var connectionsByID: [String: EngineConnection] = [:]

    var connections: [EngineConnection] {
        connectionsByID.values.sorted { $0.createdAt > $1.createdAt }
    }

    var isEmpty: Bool { connectionsByID.isEmpty }

    mutating func reset() {
        connectionsByID.removeAll()
    }

    mutating func upsert(_ connection: EngineConnection) {
        connectionsByID[connection.id] = connection
    }

    /// Traffic deltas for a connection the engine no longer describes in
    /// full; ignored when the id is unknown.
    mutating func addTraffic(id: String, upload: UInt64, download: UInt64) {
        guard var connection = connectionsByID[id] else { return }
        connection.upload &+= upload
        connection.download &+= download
        connectionsByID[id] = connection
    }

    mutating func close(id: String) {
        connectionsByID.removeValue(forKey: id)
    }
}

protocol CoreEngine: Sendable {
    func start(configuration: TunnelConfiguration, packetFlow: any PacketFlow) async throws
    func stop() async
    func events() -> AsyncStream<CoreEvent>
    func stats() -> AsyncStream<CoreStats>
}

/// Placeholder engine so the scaffold builds and runs end-to-end.
/// The tunnel comes up with routes and DNS but the data path is not implemented yet.
struct NullCoreEngine: CoreEngine {
    func start(configuration: TunnelConfiguration, packetFlow: any PacketFlow) async throws {}
    func stop() async {}

    func events() -> AsyncStream<CoreEvent> {
        AsyncStream { $0.finish() }
    }

    func stats() -> AsyncStream<CoreStats> {
        AsyncStream { $0.finish() }
    }
}
