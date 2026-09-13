@preconcurrency import NetworkExtension
import os
import WidgetKit

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

/// Samples this process's memory while the tunnel is up.
///
/// The app-side figure comes from the harness, which is a different process
/// without the extension loader or the device's limit. This is the only place
/// the real number can be read, so the readings are labelled by phase and kept
/// for the app to collect: the interesting quantity is not the current value
/// but how the value moves between phases.
///
/// The lock is what keeps the timer and the message handler off each other's
/// memory; sampling itself is a synchronous `task_info` call and never touches
/// the packet path.
private final class MemorySampler: @unchecked Sendable {
    /// Frequent enough to catch a slow climb, rare enough to be free.
    static let interval: TimeInterval = 60

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "org.waypo.memory")
    private var trace = MemoryTrace()
    private var timer: DispatchSourceTimer?

    func mark(_ label: String) {
        lock.lock()
        trace.mark(label)
        lock.unlock()
    }

    /// Starts the periodic sampling and records the opening reading. Calling
    /// it twice is harmless; a stop before a start is a no-op.
    func start() {
        mark("extension-start")
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + Self.interval,
                        repeating: .seconds(Int(Self.interval)))
        // Weakly, so the timer does not keep the provider alive and the
        // provider does not keep the timer's handler alive.
        source.setEventHandler { [weak self] in self?.mark("extension-periodic") }
        source.resume()
        timer = source
    }

    func stop() {
        mark("extension-stop")
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    func snapshot() -> MemoryTrace {
        lock.lock()
        defer { lock.unlock() }
        return trace
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "org.waypo", category: "packet-tunnel")
    private let memorySampler = MemorySampler()

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
        memorySampler.start()

#if canImport(Libbox)
        // The engine applies network settings and claims the tun fd itself.
        let engine = LibboxCoreEngine(tunnel: self)
        engineHolder.set(engine)
        let packetFlow = NetworkExtensionPacketFlow(flow: self.packetFlow)
        Task {
            do {
                try await engine.start(configuration: config, packetFlow: packetFlow)
                memorySampler.mark("extension-engine-started")
                logger.info("tunnel up (real engine)")
                TunnelStore().saveStatusMirror(NEVPNStatus.connected.rawValue)
                WidgetCenter.shared.reloadAllTimelines()
                completion(nil)
            } catch {
                logger.error("engine start failed: \(error.localizedDescription, privacy: .public)")
                TunnelStore().saveStatusMirror(NEVPNStatus.disconnected.rawValue)
                WidgetCenter.shared.reloadAllTimelines()
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
                    memorySampler.mark("extension-engine-started")
                    logger.info("tunnel up (engine running)")
                    TunnelStore().saveStatusMirror(NEVPNStatus.connected.rawValue)
                    WidgetCenter.shared.reloadAllTimelines()
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
        memorySampler.stop()
        TunnelStore().saveStatusMirror(NEVPNStatus.disconnected.rawValue)
        WidgetCenter.shared.reloadAllTimelines()
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
        // Answered in every build: the trace records what this process costs
        // regardless of which engine is inside it.
        if messageData == Data("memory".utf8) {
            completionHandler?(try? JSONEncoder().encode(memorySampler.snapshot()))
            return
        }
#if canImport(Libbox)
        if let message = String(data: messageData, encoding: .utf8) {
            if message == "logs" {
                let text = engineHolder.get()?.recentLogs().joined(separator: "\n") ?? ""
                completionHandler?(Data(text.utf8))
                return
            }
            if message == "stats" {
                if let stats = engineHolder.get()?.currentStats(),
                   let data = try? JSONEncoder().encode(stats) {
                    completionHandler?(data)
                } else {
                    completionHandler?(nil)
                }
                return
            }
            if message == "groups" {
                completionHandler?(try? JSONEncoder().encode(engineHolder.get()?.currentGroups() ?? []))
                return
            }
            if message == "connections" {
                completionHandler?(try? JSONEncoder().encode(engineHolder.get()?.currentConnections() ?? []))
                return
            }
            if message.hasPrefix("close ") {
                engineHolder.get()?.closeConnection(id: String(message.dropFirst("close ".count)))
                completionHandler?(nil)
                return
            }
            if message.hasPrefix("select ") {
                // "select <group> <member>" targets one group; the one-token
                // legacy form keeps selecting within the top-level selector.
                let parts = message.dropFirst("select ".count).split(separator: " ")
                if parts.count == 2 {
                    engineHolder.get()?.selectOutbound(group: String(parts[0]), tag: String(parts[1]))
                } else if parts.count == 1 {
                    engineHolder.get()?.selectOutbound(group: "out", tag: String(parts[0]))
                }
                completionHandler?(nil)
                return
            }
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
