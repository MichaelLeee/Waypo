import Foundation
import NetworkExtension
import Observation

/// App-side control of the tunnel profile and connection.
@MainActor
@Observable
final class TunnelController {
    private(set) var status: NEVPNStatus = .invalid
    private(set) var lastError: String?
    private(set) var latencies: [TunnelServer.ID: Double] = [:]
    private(set) var isTestingLatency = false
    var configuration: TunnelConfiguration = .default

    private let store = TunnelStore()
    private var manager: NETunnelProviderManager?
    private var observing = false

    var statusLabel: String {
        switch status {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnecting: "Disconnecting…"
        case .disconnected: "Disconnected"
        case .invalid: "Profile not installed"
        case .reasserting: "Reasserting…"
        @unknown default: "Unknown"
        }
    }

    var isActive: Bool { status == .connected || status == .connecting }

    func isActiveServer(_ id: TunnelServer.ID) -> Bool {
        configuration.servers.first?.id == id
    }

    func refresh() async {
        configuration = store.loadConfiguration()
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let manager = managers.first { $0.localizedDescription == Self.profileTitle }
            self.manager = manager
            status = manager?.connection.status ?? .invalid
            observeStatus(of: manager)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggle() async {
        do {
            let manager = try await loadOrCreateManager()
            switch manager.connection.status {
            case .connected, .connecting, .reasserting:
                manager.connection.stopVPNTunnel()
            case .disconnected, .invalid:
                try manager.connection.startVPNTunnel()
            default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Server management

    func addServer(_ server: TunnelServer) {
        configuration.servers.append(server)
        persist()
    }

    func updateServer(_ server: TunnelServer) {
        guard let index = configuration.servers.firstIndex(where: { $0.id == server.id }) else { return }
        configuration.servers[index] = server
        persist()
    }

    func deleteServer(_ id: TunnelServer.ID) {
        configuration.servers.removeAll { $0.id == id }
        latencies.removeValue(forKey: id)
        persist()
    }

    /// The engine routes through `servers.first`, so activating a server
    /// means moving it to the front of the list.
    func setActiveServer(_ id: TunnelServer.ID) {
        guard let index = configuration.servers.firstIndex(where: { $0.id == id }), index != 0 else { return }
        let server = configuration.servers.remove(at: index)
        configuration.servers.insert(server, at: 0)
        persist()
    }

    // MARK: - Import

    /// Adds servers parsed from share-link text, skipping duplicates.
    /// Returns the number of servers actually added.
    @discardableResult
    func importServers(fromText text: String) -> Int {
        let parsed = ServerImport.parse(text)
        let existing = Set(configuration.servers.map { "\($0.host):\($0.port):\($0.transport)" })
        let fresh = parsed.filter { !existing.contains("\($0.host):\($0.port):\($0.transport)") }
        guard !fresh.isEmpty else { return 0 }
        configuration.servers.append(contentsOf: fresh)
        persist()
        return fresh.count
    }

    // MARK: - Latency

    func checkLatency(for id: TunnelServer.ID) async {
        guard let server = configuration.servers.first(where: { $0.id == id }) else { return }
        latencies[id] = await ServerLatency.measure(host: server.host, port: server.port)
    }

    func checkAllLatencies() async {
        isTestingLatency = true
        defer { isTestingLatency = false }
        let servers = configuration.servers
        let results = await withTaskGroup(of: (TunnelServer.ID, Double?).self) { group in
            for server in servers {
                group.addTask {
                    let latency = await ServerLatency.measure(host: server.host, port: server.port)
                    return (server.id, latency)
                }
            }
            var collected: [TunnelServer.ID: Double] = [:]
            for await (id, latency) in group {
                if let latency {
                    collected[id] = latency
                }
            }
            return collected
        }
        latencies = results
    }

    private func persist() {
        do {
            try store.saveConfiguration(configuration)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static let profileTitle = "Waypo"

#if os(macOS)
    private static let tunnelBundleID = "org.waypo.mac.tunnel"
#else
    private static let tunnelBundleID = "org.waypo.ios.tunnel"
#endif

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        if let manager {
            return manager
        }

        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = managers.first(where: { $0.localizedDescription == Self.profileTitle }) {
            observeStatus(of: existing)
            manager = existing
            return existing
        }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.tunnelBundleID
        proto.serverAddress = configuration.servers.first?.host
        proto.providerConfiguration = ["configVersion": 1]

        let newManager = NETunnelProviderManager()
        newManager.protocolConfiguration = proto
        newManager.localizedDescription = Self.profileTitle
        newManager.isEnabled = true
        try await newManager.saveToPreferences()
        try await newManager.loadFromPreferences()

        observeStatus(of: newManager)
        manager = newManager
        return newManager
    }

    private func observeStatus(of manager: NETunnelProviderManager?) {
        guard manager != nil, !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statusDidChange),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }

    @objc
    nonisolated private func statusDidChange(_ notification: Notification) {
        Task { @MainActor in
            status = manager?.connection.status ?? .invalid
        }
    }
}
