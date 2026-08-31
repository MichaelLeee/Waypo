@preconcurrency import NetworkExtension
import os

/// The framework hands out completion handlers without Sendable annotations.
/// Each one is invoked exactly once from a single task, so boxing it keeps the
/// strict-concurrency checks satisfied without changing behavior.
private struct CompletionHandler: @unchecked Sendable {
    private let handler: (Error?) -> Void
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
    func callAsFunction(_ error: Error?) { handler(error) }
}

private struct StopHandler: @unchecked Sendable {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func callAsFunction() { handler() }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "org.waypo", category: "packet-tunnel")

#if canImport(Libbox)
    /// The engine hands itself over to stopTunnel across concurrency domains.
    private final class EngineHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var engine: LibboxCoreEngine?

        func set(_ value: LibboxCoreEngine?) {
            lock.lock()
            engine = value
            lock.unlock()
        }

        func get() -> LibboxCoreEngine? {
            lock.lock()
            defer { lock.unlock() }
            return engine
        }
    }

    private let engineHolder = EngineHolder()
#endif

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let config = TunnelStore().loadConfiguration()
        let completion = CompletionHandler(completionHandler)
        let logger = self.logger

#if canImport(Libbox)
        // The engine applies network settings and claims the tun fd itself.
        let engine = LibboxCoreEngine(tunnel: self)
        engineHolder.set(engine)
        let packetFlow = NetworkExtensionPacketFlow(flow: self.packetFlow)
        Task {
            do {
                try await engine.start(configuration: config, packetFlow: packetFlow)
                logger.info("tunnel up (real engine)")
                completion(nil)
            } catch {
                logger.error("engine start failed: \(error.localizedDescription, privacy: .public)")
                completion(error)
            }
        }
#else
        let remoteAddress = config.servers.first?.host ?? "198.18.0.1"
        let packetFlow = self.packetFlow
        logger.info("starting tunnel, remote=\(remoteAddress, privacy: .public)")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)
        settings.mtu = NSNumber(value: config.mtu)

        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fd00:waypo::1"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6

        settings.dnsSettings = NEDNSSettings(servers: config.dnsAddresses)

        setTunnelNetworkSettings(settings) { error in
            if let error {
                logger.error("network settings failed: \(error.localizedDescription, privacy: .public)")
                completion(error)
                return
            }
            let flow = NetworkExtensionPacketFlow(flow: packetFlow)
            let engine = NullCoreEngine()
            Task {
                do {
                    try await engine.start(configuration: config, packetFlow: flow)
                    logger.info("tunnel up (engine running)")
                    completion(nil)
                } catch {
                    completion(error)
                }
            }
        }
#endif
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("stopping tunnel, reason=\(reason.rawValue)")
#if canImport(Libbox)
        let engine = engineHolder.get()
        engineHolder.set(nil)
        let completion = StopHandler(completionHandler)
        Task {
            await engine?.stop()
            completion()
        }
#else
        completionHandler()
#endif
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: (@Sendable (Data?) -> Void)?) {
#if canImport(Libbox)
        if String(data: messageData, encoding: .utf8) == "logs" {
            let text = engineHolder.get()?.recentLogs().joined(separator: "\n") ?? ""
            completionHandler?(Data(text.utf8))
            return
        }
#endif
        completionHandler?(nil)
    }

    override func sleep(completionHandler: @escaping () -> Void) {
#if canImport(Libbox)
        engineHolder.get()?.pause()
        completionHandler()
#else
        completionHandler()
#endif
    }

    override func wake() {
#if canImport(Libbox)
        engineHolder.get()?.wakeUp()
#endif
    }
}
