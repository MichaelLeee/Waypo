import NetworkExtension
import os

/// The framework hands out completion handlers without Sendable annotations.
/// Each one is invoked exactly once from a single task, so boxing it keeps the
/// strict-concurrency checks satisfied without changing behavior.
private struct CompletionHandler: @unchecked Sendable {
    private let handler: (Error?) -> Void
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
    func callAsFunction(_ error: Error?) { handler(error) }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "org.waypo", category: "packet-tunnel")

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let config = TunnelStore().loadConfiguration()
        let remoteAddress = config.servers.first?.host ?? "198.18.0.1"
        let logger = self.logger
        let packetFlow = self.packetFlow
        let completion = CompletionHandler(completionHandler)
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
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("stopping tunnel, reason=\(reason.rawValue)")
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: (@Sendable (Data?) -> Void)?) {
        completionHandler?(nil)
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {
    }
}
