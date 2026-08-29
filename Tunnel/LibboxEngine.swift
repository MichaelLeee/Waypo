import Foundation
import NetworkExtension
import os

#if canImport(Libbox)
import Libbox

/// Real engine implementation behind the CoreEngine boundary.
///
/// Lifecycle: Setup -> CommandServer -> startOrReloadService. The engine owns
/// the tun file descriptor; it is handed over by the platform interface in
/// `openTun`, so the PacketFlow argument of `start` is intentionally unused.
final class LibboxCoreEngine: CoreEngine, @unchecked Sendable {
    private let tunnel: NEPacketTunnelProvider
    private let platformInterface: WaypoPlatformInterface
    private let logger = Logger(subsystem: "org.waypo", category: "engine")
    private var commandServer: LibboxCommandServer?

    init(tunnel: NEPacketTunnelProvider) {
        self.tunnel = tunnel
        self.platformInterface = WaypoPlatformInterface(tunnel: tunnel)
    }

    func start(configuration: TunnelConfiguration, packetFlow: any PacketFlow) async throws {
        let configContent = try makeConfigurationContent(configuration)

        let setup = LibboxSetupOptions()
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path
        setup.basePath = cacheDir
        setup.workingPath = cacheDir + "/work"
        setup.tempPath = NSTemporaryDirectory()
        setup.logMaxLines = 500
        setup.debug = false
        setup.appVersion = "0.1.0"
        setup.appMarketingVersion = "0.1.0"
        var setupError: NSError?
        LibboxSetup(setup, &setupError)
        if let setupError { throw setupError }

        var serverError: NSError?
        let server = LibboxNewCommandServer(platformInterface, platformInterface, &serverError)
        if let serverError { throw serverError }
        commandServer = server

        try server.startOrReloadService(configContent, options: LibboxOverrideOptions())
        logger.info("engine started")
    }

    func stop() async {
        try? commandServer?.closeService()
        commandServer?.close()
        commandServer = nil
        logger.info("engine stopped")
    }

    func pause() {
        commandServer?.pause()
    }

    func wakeUp() {
        commandServer?.wake()
    }

    func events() -> AsyncStream<CoreEvent> {
        AsyncStream { $0.finish() }
    }

    func stats() -> AsyncStream<CoreStats> {
        AsyncStream { $0.finish() }
    }

    // MARK: - Configuration mapping

    private func makeConfigurationContent(_ configuration: TunnelConfiguration) throws -> String {
        let server = configuration.servers.first ?? TunnelServer(name: "Primary", host: "203.0.113.10", port: 443)

        let dnsServers: [[String: Any]] = configuration.dnsAddresses.enumerated().map { index, address in
            ["type": "udp", "tag": "dns-\(index)", "server": address]
        }

        let tun: [String: Any] = [
            "type": "tun",
            "tag": "tun-in",
            "address": ["198.18.0.1/30", "fdfe:dcba:9876::1/126"],
            "mtu": configuration.mtu,
            "auto_route": true,
            "strict_route": true,
            "stack": "system",
        ]

        var outbound: [String: Any] = [
            "type": server.transport,
            "tag": "out",
            "server": server.host,
            "server_port": server.port,
        ]
        switch server.transport {
        case "trojan":
            outbound["password"] = server.credentials ?? ""
        case "vless":
            outbound["uuid"] = server.credentials ?? ""
        case "shadowsocks":
            outbound["password"] = server.credentials ?? ""
            outbound["method"] = server.cipher ?? "aes-128-gcm"
        default:
            break
        }
        if server.useTLS {
            outbound["tls"] = ["enabled": true, "server_name": server.serverName ?? server.host]
        }

        let json: [String: Any] = [
            "log": ["level": "info", "timestamp": true],
            "dns": ["servers": dnsServers],
            "inbounds": [tun],
            "outbounds": [outbound, ["type": "direct", "tag": "direct-out"]],
            "route": [
                "rules": [["protocol": "dns", "action": "hijack-dns"]],
                "final": "out",
                "auto_detect_interface": true,
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Applies network settings on behalf of the engine and hands over the tun fd.
final class WaypoPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private static let logger = Logger(subsystem: "org.waypo", category: "engine-platform")
    private let tunnel: NEPacketTunnelProvider

    init(tunnel: NEPacketTunnelProvider) {
        self.tunnel = tunnel
    }

    private var logger: Logger { Self.logger }

    // MARK: - Tun

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options else {
            throw NSError(domain: "Waypo", code: 1, userInfo: [NSLocalizedDescriptionKey: "nil tun options"])
        }
        guard let ret0_ else {
            throw NSError(domain: "Waypo", code: 1, userInfo: [NSLocalizedDescriptionKey: "nil return pointer"])
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        var dnsSettings: NEDNSSettings?
        if options.getDNSMode()?.value != LibboxDNSModeDisabled {
            let dnsServerIterator = try options.getDNSServerAddress()
            var dnsServers: [String] = []
            while dnsServerIterator.hasNext() {
                dnsServers.append(dnsServerIterator.next())
            }
            if !dnsServers.isEmpty {
                let newDNSSettings = NEDNSSettings(servers: dnsServers)
                settings.dnsSettings = newDNSSettings
                dnsSettings = newDNSSettings
            }
        }

        var ipv4Address: [String] = []
        var ipv4Mask: [String] = []
        let ipv4AddressIterator = options.getInet4Address()!
        while ipv4AddressIterator.hasNext() {
            let prefix = ipv4AddressIterator.next()!
            ipv4Address.append(prefix.address())
            ipv4Mask.append(prefix.mask())
        }

        let ipv4Settings = NEIPv4Settings(addresses: ipv4Address, subnetMasks: ipv4Mask)
        var ipv4Routes: [NEIPv4Route] = []
        var ipv4ExcludeRoutes: [NEIPv4Route] = []

        let ipv4RouteIterator = options.getInet4RouteAddress()!
        if ipv4RouteIterator.hasNext() {
            while ipv4RouteIterator.hasNext() {
                let prefix = ipv4RouteIterator.next()!
                ipv4Routes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
            }
        } else {
            ipv4Routes.append(NEIPv4Route.default())
        }

        let ipv4ExcludeIterator = options.getInet4RouteExcludeAddress()!
        while ipv4ExcludeIterator.hasNext() {
            let prefix = ipv4ExcludeIterator.next()!
            ipv4ExcludeRoutes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
        }

        ipv4Settings.includedRoutes = ipv4Routes
        ipv4Settings.excludedRoutes = ipv4ExcludeRoutes
        settings.ipv4Settings = ipv4Settings

        var ipv6Address: [String] = []
        var ipv6Prefixes: [NSNumber] = []
        let ipv6AddressIterator = options.getInet6Address()!
        while ipv6AddressIterator.hasNext() {
            let prefix = ipv6AddressIterator.next()!
            ipv6Address.append(prefix.address())
            ipv6Prefixes.append(NSNumber(value: prefix.prefix()))
        }

        let ipv6Settings = NEIPv6Settings(addresses: ipv6Address, networkPrefixLengths: ipv6Prefixes)
        var ipv6Routes: [NEIPv6Route] = []
        var ipv6ExcludeRoutes: [NEIPv6Route] = []

        let ipv6RouteIterator = options.getInet6RouteAddress()!
        if ipv6RouteIterator.hasNext() {
            while ipv6RouteIterator.hasNext() {
                let prefix = ipv6RouteIterator.next()!
                ipv6Routes.append(NEIPv6Route(destinationAddress: prefix.address(),
                                               networkPrefixLength: NSNumber(value: prefix.prefix())))
            }
        } else {
            ipv6Routes.append(NEIPv6Route.default())
        }

        let ipv6ExcludeIterator = options.getInet6RouteExcludeAddress()!
        while ipv6ExcludeIterator.hasNext() {
            let prefix = ipv6ExcludeIterator.next()!
            ipv6ExcludeRoutes.append(NEIPv6Route(destinationAddress: prefix.address(),
                                                 networkPrefixLength: NSNumber(value: prefix.prefix())))
        }

        ipv6Settings.includedRoutes = ipv6Routes
        ipv6Settings.excludedRoutes = ipv6ExcludeRoutes
        settings.ipv6Settings = ipv6Settings

        settings.mtu = NSNumber(value: options.getMTU())

        let hasDefaultRoute = ipv4Routes.contains {
            $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0"
        }
        if !hasDefaultRoute {
            dnsSettings?.matchDomains = [""]
            dnsSettings?.matchDomainsNoSearch = true
        }

        // The engine calls openTun synchronously on its own thread; the provider
        // and settings are used exactly once here and not touched concurrently,
        // which is what the unsafe annotation attests to.
        nonisolated(unsafe) let tunnelForCall = self.tunnel
        nonisolated(unsafe) let settingsForCall = settings
        try runBlocking {
            try await tunnelForCall.setTunnelNetworkSettings(settingsForCall)
        }

        if let tunFd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = tunFd
            return
        }

        let tunFdFromLoop = LibboxGetTunnelFileDescriptor()
        if tunFdFromLoop != -1 {
            ret0_.pointee = tunFdFromLoop
        } else {
            throw NSError(domain: "Waypo", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing tun file descriptor"])
        }
    }

    /// Bridges the engine's synchronous callbacks to async framework calls.
    /// Runs the async body on a global queue so it never blocks a cooperative
    /// thread while waiting for the semaphore below.
    private func runBlocking(_ body: @escaping @Sendable () async throws -> Void) throws {
        final class ErrorBox: @unchecked Sendable {
            var error: Error?
        }
        let box = ErrorBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            Task {
                do {
                    try await body()
                } catch {
                    box.error = error
                }
                semaphore.signal()
            }
        }
        semaphore.wait()
        if let error = box.error { throw error }
    }

    // MARK: - Interface monitoring

    private var nwMonitor: NWPathMonitor?

    func usePlatformAutoDetectControl() -> Bool { false }

    func autoDetectControl(_: Int32) throws {}

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        nonisolated(unsafe) let listenerForMonitor = listener
        let monitor = NWPathMonitor()
        nwMonitor = monitor
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            Self.updateDefaultInterface(listenerForMonitor, path)
            semaphore.signal()
            monitor.pathUpdateHandler = { path in
                Self.updateDefaultInterface(listenerForMonitor, path)
            }
        }
        monitor.start(queue: DispatchQueue.global())
        semaphore.wait()
    }

    private static func updateDefaultInterface(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: NWPath) {
        guard path.status != .unsatisfied, let interface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(interface.name, interfaceIndex: Int32(interface.index),
                                        isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
        nwMonitor?.cancel()
        nwMonitor = nil
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let nwMonitor else {
            throw NSError(domain: "Waypo", code: 1, userInfo: [NSLocalizedDescriptionKey: "interface monitor not started"])
        }
        let path = nwMonitor.currentPath
        if path.status == .unsatisfied {
            return InterfaceIterator([])
        }
        var interfaces: [LibboxNetworkInterface] = []
        for item in path.availableInterfaces {
            let interface = LibboxNetworkInterface()
            interface.name = item.name
            interface.index = Int32(item.index)
            switch item.type {
            case .wifi: interface.type = LibboxInterfaceTypeWIFI
            case .cellular: interface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet: interface.type = LibboxInterfaceTypeEthernet
            default: interface.type = LibboxInterfaceTypeOther
            }
            interfaces.append(interface)
        }
        return InterfaceIterator(interfaces)
    }

    private final class InterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var iterator: IndexingIterator<[LibboxNetworkInterface]>
        private var nextValue: LibboxNetworkInterface?

        init(_ array: [LibboxNetworkInterface]) {
            iterator = array.makeIterator()
        }

        func hasNext() -> Bool {
            nextValue = iterator.next()
            return nextValue != nil
        }

        func next() -> LibboxNetworkInterface? {
            nextValue
        }
    }

    // MARK: - Service and diagnostics

    func underNetworkExtension() -> Bool { true }

    func includeAllNetworks() -> Bool { false }

    func useProcFS() -> Bool { false }

    func writeLog(_ message: String?) {
        guard let message else { return }
        logger.notice("\(message, privacy: .public)")
    }

    func writeDebugMessage(_ message: String?) {
        guard let message else { return }
        logger.debug("\(message, privacy: .public)")
    }

    func clearDNSCache() {}

    func serviceStop() throws {
        tunnel.cancelTunnelWithError(nil)
    }

    func serviceReload() throws {}

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32,
                             destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        throw NSError(domain: "Waypo", code: 1, userInfo: [NSLocalizedDescriptionKey: "not supported"])
    }

    func readWIFIState() -> LibboxWIFIState? { nil }

    func readWIFISSID() -> String? { nil }

    func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "Waypo", code: 1, userInfo: [NSLocalizedDescriptionKey: "not supported"])
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        LibboxSystemProxyStatus()
    }

    func setSystemProxyEnabled(_ isEnabled: Bool) throws {
        throw NSError(domain: "Waypo", code: 1, userInfo: [NSLocalizedDescriptionKey: "not supported"])
    }

    func triggerNativeCrash() throws {}

    func send(_ notification: LibboxNotification?) throws {}

    func cancelNotification(_ identifier: String?, typeID _: Int32) throws {}

    func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {
        throw NSError(domain: "Waypo", code: 1, userInfo: [NSLocalizedDescriptionKey: "not supported"])
    }

    func closeNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}

    func registerMyInterface(_ name: String?) {}

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }

    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }

    func usePlatformShell() -> Bool { false }

    func checkPlatformShell() throws {
        throw NSError(domain: "Waypo", code: 1, userInfo: [NSLocalizedDescriptionKey: "not supported"])
    }

    func openShellSession(_ user: LibboxPlatformUser?, command: String?, environ: (any LibboxStringIteratorProtocol)?,
                          term: String?, rows: Int32, cols: Int32) throws -> any LibboxShellSessionProtocol {
        throw NSError(domain: "Waypo", code: 1, userInfo: [NSLocalizedDescriptionKey: "not supported"])
    }

    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = NSError(domain: "Waypo", code: 1, userInfo: [NSLocalizedDescriptionKey: "not supported"])
        return ""
    }

    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = NSError(domain: "Waypo", code: 1, userInfo: [NSLocalizedDescriptionKey: "not supported"])
        return ""
    }

    func tailscaleHostname() -> String { "" }

    func usePlatformBridge() -> Bool { false }

    func createBridge(_ options: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
        throw NSError(domain: "Waypo", code: 1, userInfo: [NSLocalizedDescriptionKey: "not supported"])
    }

    func lookupUser(_ username: String?) throws -> LibboxPlatformUser {
        throw NSError(domain: "Waypo", code: 1, userInfo: [NSLocalizedDescriptionKey: "not supported"])
    }
}

#endif
