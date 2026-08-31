import Foundation

/// `--run` mode: full-tunnel study mode. Loads the app's configuration file,
/// brings up a real utun device, and hands it to the engine with
/// engine-managed routes. No NetworkExtension and no special entitlements are
/// involved; root is required because the engine rewrites the system routes.
func runTunnel(unit: Int32, address: String, peerAddress: String, configPath: String) async -> Int32 {
#if canImport(Libbox)
    guard let configData = FileManager.default.contents(atPath: configPath) else {
        FileHandle.standardError.write("configuration file not found: \(configPath)\n".data(using: .utf8)!)
        return 1
    }
    let configuration: TunnelConfiguration
    do {
        configuration = try JSONDecoder().decode(TunnelConfiguration.self, from: configData)
    } catch {
        FileHandle.standardError.write("cannot decode configuration: \(error)\n".data(using: .utf8)!)
        return 1
    }
    if configuration.servers.isEmpty {
        FileHandle.standardError.write("configuration has no servers\n".data(using: .utf8)!)
        return 1
    }

    do {
        let utun = try UtunInterface(unit: unit)
        print("created \(utun.name)")
        try run("/sbin/ifconfig", [utun.name, address, peerAddress, "up"])

        let flow = UtunPacketFlow(fileDescriptor: utun.fileDescriptor)
        let engine = LibboxCoreEngine(tunFileDescriptor: utun.fileDescriptor, autoRoute: true)
        try await engine.start(configuration: configuration, packetFlow: flow)
        print("tunnel running on \(utun.name) via \(configuration.servers[0].name) — Ctrl+C to stop")
        dispatchMain()
        return 0
    } catch {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        return 1
    }
#else
    FileHandle.standardError.write("--run requires the packaged core library (build with Libbox.xcframework)\n".data(using: .utf8)!)
    return 1
#endif
}
