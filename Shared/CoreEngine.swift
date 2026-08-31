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
