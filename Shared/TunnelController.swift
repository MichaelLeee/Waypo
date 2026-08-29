import Foundation
import NetworkExtension
import Observation

/// App-side control of the tunnel profile and connection.
@MainActor
@Observable
final class TunnelController {
    private(set) var status: NEVPNStatus = .invalid
    private(set) var lastError: String?

    private let store = TunnelStore()
    private var manager: NETunnelProviderManager?
    private var observing = false

    var configuration: TunnelConfiguration {
        store.loadConfiguration()
    }

    func saveConfiguration(_ config: TunnelConfiguration) {
        do {
            try store.saveConfiguration(config)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() async {
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
